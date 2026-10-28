#!/usr/bin/env bash
# Starts the local cluster and Oracle. Safe to run again at any time:
# existing data is kept, and already-applied resources are left as they are.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [[ ! -f "$ROOT/.env" ]]; then
  echo "Missing .env. Create it first:  cp .env.example .env" >&2
  exit 1
fi

# The template's placeholder passwords are valid Oracle passwords, so refuse them.
if grep -q '=ChangeMe' "$ROOT/.env"; then
  echo "Set your own passwords in .env first (it still has the ChangeMe placeholders)" >&2
  exit 1
fi

# Catch an outdated .env early; otherwise the pod hangs in CreateContainerConfigError.
for key in ORACLE_PASSWORD APP_USER_PASSWORD DBZ_PASSWORD; do
  grep -q "^$key=." "$ROOT/.env" || { echo "Missing $key in .env (see .env.example)" >&2; exit 1; }
done

# 1) Cluster. Oracle wants ~2-4 GB; the rest is headroom for Debezium.
#    Docker Desktop must allow at least this much memory (Settings > Resources).
echo "==> Starting minikube profile '$PROFILE'"
minikube start -p "$PROFILE" --driver=docker --cpus=4 --memory=6g

# 2) Namespace first, because the Secret has to live inside it.
kc apply -f "$ROOT/k8s/oracle/namespace.yaml"

# 3) Secret from .env. "create --dry-run | apply" makes it idempotent:
#    it creates the Secret the first time and updates it on later runs.
#    Server-side apply, because client-side apply would copy the values into
#    the last-applied-configuration annotation.
echo "==> Creating secret from .env"
kc -n "$NAMESPACE" create secret generic oracle-credentials \
  --from-env-file="$ROOT/.env" \
  --dry-run=client -o yaml | kc apply --server-side -f -

# 4) Everything else (Service, StatefulSet, init-SQL ConfigMap) via kustomize.
echo "==> Deploying Oracle"
kc apply -k "$ROOT/k8s/oracle"

# 5) Wait until Oracle reports healthy. First run creates and seeds the
#    database, so this can take 5-10 minutes; later starts take ~1 minute.
echo "==> Waiting for Oracle to become ready (first start: up to 10 min)"
echo "    Follow progress in another terminal:  kubectl --context $PROFILE -n $NAMESPACE logs -f oracle-0"
kc -n "$NAMESPACE" rollout status statefulset/oracle --timeout=15m

echo
echo "Oracle is up. Next: ./scripts/connect.sh, then connect DBeaver to localhost:1521 / FREEPDB1"
