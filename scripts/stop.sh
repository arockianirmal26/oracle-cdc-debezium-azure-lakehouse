#!/usr/bin/env bash
# Stops the cluster and frees CPU/RAM on your laptop.
# All data is kept; ./scripts/start.sh brings everything back as it was.
set -euo pipefail
source "$(dirname "$0")/common.sh"

minikube stop -p "$PROFILE"
