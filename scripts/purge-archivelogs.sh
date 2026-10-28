#!/usr/bin/env bash
# Deletes archived redo logs older than N hours (default 24) via RMAN.
#
# Why this is needed: in ARCHIVELOG mode Oracle keeps every filled redo log.
# Nothing removes them automatically without a backup strategy, and when the
# recovery area is full the database stops accepting writes.
#
# The retention must be longer than Debezium could ever be down: if the
# connector restarts and the archive log it needs is gone, it has to re-snapshot.
set -euo pipefail
source "$(dirname "$0")/common.sh"

HOURS="${1:-24}"

kc -n "$NAMESPACE" exec -i oracle-0 -- rman target / <<EOF
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE - ${HOURS}/24';
EOF
