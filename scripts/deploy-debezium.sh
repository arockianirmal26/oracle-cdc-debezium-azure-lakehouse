#!/usr/bin/env bash
# Deploys Debezium Server into the cluster (or updates it). Safe to re-run.
#
# Needs: Oracle running (./scripts/start.sh) and the Azure resources created
# (terraform apply in infra/azure). Offsets are kept across re-runs, so a
# redeploy resumes streaming instead of re-snapshotting.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DBZ_NS=debezium

# The Debezium DB password comes from .env, the Event Hubs key from Terraform.
# Both go straight into the Secret and are never printed. They're passed as
# files (process substitution), not arguments, so they don't show up in `ps`.
DBZ_PASSWORD=$(grep '^DBZ_PASSWORD=' "$ROOT/.env" | cut -d= -f2-)
[[ -n "$DBZ_PASSWORD" ]] || { echo "DBZ_PASSWORD missing in .env" >&2; exit 1; }

EH_CONNECTION_STRING=$(terraform -chdir="$ROOT/infra/azure" output -raw debezium_connection_string 2>/dev/null) || {
  echo "No Terraform output found. Run 'terraform apply' in infra/azure first." >&2
  exit 1
}

kc apply -f "$ROOT/k8s/debezium/namespace.yaml"

echo "==> Creating secret debezium-credentials"
kc -n "$DBZ_NS" create secret generic debezium-credentials \
  --from-file=DBZ_PASSWORD=<(printf %s "$DBZ_PASSWORD") \
  --from-file=EH_CONNECTION_STRING=<(printf %s "$EH_CONNECTION_STRING") \
  --dry-run=client -o yaml | kc apply --server-side -f -

echo "==> Deploying Debezium Server"
kc apply -k "$ROOT/k8s/debezium"

echo "==> Waiting for Debezium to become ready"
kc -n "$DBZ_NS" rollout status statefulset/debezium --timeout=5m

echo
echo "Debezium is running. Follow it with:"
echo "  kubectl --context $PROFILE -n $DBZ_NS logs -f debezium-0"
