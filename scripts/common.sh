# Shared settings, sourced by the other scripts (not run directly).

# Dedicated minikube profile, so this project never touches your other clusters.
PROFILE=oracle-cdc
NAMESPACE=oracle

# Repo root, no matter where the script is called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Always talk to *this* cluster, even if your current kubectl context is different.
kc() { kubectl --context "$PROFILE" "$@"; }
