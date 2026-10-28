#!/usr/bin/env bash
# Proves the database is ready for CDC, without Debezium:
#   1. as SALES:      INSERT, UPDATE and DELETE one order (net effect: nothing changes)
#   2. as C##DBZUSER: read those three changes back out of the redo log with LogMiner
#
# This is the same mechanism Debezium uses internally. If this works, the
# archive log mode, supplemental logging and grants are all correct.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Runs inside the pod, so the passwords come from the pod's environment (the
# Kubernetes Secret) and never pass through your shell. CONNECT goes over stdin
# so the password isn't on sqlplus's command line either.
kc -n "$NAMESPACE" exec -i oracle-0 -- bash -s <<'POD'
echo "==> 1) Application change as SALES (insert, update, delete)"
{ echo "CONNECT sales/\"${APP_USER_PASSWORD}\"@FREEPDB1"; cat <<'SQL'; } | sqlplus -s /nolog
SET FEEDBACK OFF
VARIABLE id NUMBER
INSERT INTO orders (customer_id, order_date, status, total_amount)
VALUES (1, SYSDATE, 'NEW', 99.90) RETURNING order_id INTO :id;
UPDATE orders SET status = 'PAID' WHERE order_id = :id;
DELETE FROM orders WHERE order_id = :id;
COMMIT;
PRINT id
SQL

echo "==> 2) Reading the changes back from the redo log as C##DBZUSER"
{ echo "CONNECT c##dbzuser/\"${DBZ_PASSWORD}\"@FREE"; cat <<'SQL'; } | sqlplus -s /nolog
SET LINESIZE 220 PAGESIZE 50 FEEDBACK OFF
COLUMN operation FORMAT A8
COLUMN tbl FORMAT A14
COLUMN sql_redo FORMAT A150

-- Register the current online redo log, then mine it.
--   DICT_FROM_ONLINE_CATALOG: resolve object ids to table/column names via the live dictionary
--   COMMITTED_DATA_ONLY:      only return changes from committed transactions
DECLARE
    v_log VARCHAR2(513);
BEGIN
    SELECT f.member INTO v_log
    FROM v$log l JOIN v$logfile f ON f.group# = l.group#
    WHERE l.status = 'CURRENT' AND ROWNUM = 1;

    DBMS_LOGMNR.ADD_LOGFILE(v_log, DBMS_LOGMNR.NEW);
    DBMS_LOGMNR.START_LOGMNR(OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
                                      + DBMS_LOGMNR.COMMITTED_DATA_ONLY);
END;
/

-- The last three changes to SALES.ORDERS: should be INSERT, UPDATE, DELETE.
-- Rows come back in redo order; ROWNUM keeps that order (statements in one
-- transaction can share an SCN, so sorting by SCN alone isn't reliable).
SELECT operation, tbl, sql_redo FROM (
    SELECT operation, tbl, sql_redo, rn FROM (
        SELECT operation, seg_owner || '.' || table_name tbl, sql_redo, ROWNUM rn
        FROM v$logmnr_contents
        WHERE seg_owner = 'SALES' AND table_name = 'ORDERS'
          AND operation IN ('INSERT', 'UPDATE', 'DELETE')
    ) ORDER BY rn DESC FETCH FIRST 3 ROWS ONLY
) ORDER BY rn;

EXEC DBMS_LOGMNR.END_LOGMNR;
SQL
POD
