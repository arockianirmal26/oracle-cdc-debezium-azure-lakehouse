#!/usr/bin/env bash
# Opens a tunnel from localhost:1521 on your laptop to the Oracle Service in the
# cluster, so DBeaver can connect. Keep this terminal open while you work;
# Ctrl+C closes the tunnel (Oracle itself keeps running).
set -euo pipefail
source "$(dirname "$0")/common.sh"

LOCAL_PORT="${1:-1521}"   # pass another port if 1521 is taken: ./scripts/connect.sh 15210

echo "Forwarding localhost:$LOCAL_PORT -> oracle:1521   (Ctrl+C to stop)"
kc -n "$NAMESPACE" port-forward svc/oracle "$LOCAL_PORT:1521"
