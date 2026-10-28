#!/usr/bin/env bash
# Deletes the whole minikube profile, including the database and all its data.
# Use it to start from a clean, freshly seeded database (run ./scripts/start.sh afterwards).
set -euo pipefail
source "$(dirname "$0")/common.sh"

read -r -p "This deletes the '$PROFILE' cluster and all Oracle data. Continue? [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Aborted."; exit 0; }

minikube delete -p "$PROFILE"
