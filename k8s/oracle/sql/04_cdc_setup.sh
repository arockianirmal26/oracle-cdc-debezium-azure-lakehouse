# Prepares the database for Debezium (LogMiner-based CDC).
# Runs once, after 01-03, when the database is first created.
#
# It's a shell script instead of .sql because it needs DBZ_PASSWORD from the
# environment (Kubernetes Secret). The image *sources* non-executable .sh files,
# so: no `exit`, no `set -e` here, or it would take the container entrypoint down.
#
# What it does, in order:
#   1. recovery area + ARCHIVELOG mode   (needs a database restart)
#   2. bigger redo logs                   (20 MB -> 3 x 200 MB)
#   3. minimal supplemental logging       (database level)
#   4. LogMiner user c##dbzuser           (common user, CDB + PDB)
#   5. ALL COLUMNS supplemental logging + read grants on the captured tables

mkdir -p /opt/oracle/oradata/recovery_area

sqlplus -s / as sysdba <<EOF
SET ECHO ON FEEDBACK ON

-- 1) Archived redo logs go to the recovery area on the persistent volume.
--    Debezium reads from online redo logs, and falls back to archived logs when
--    it lags behind, so archive logs must be kept at least as long as the
--    connector could be down. 5G is plenty here; see scripts/purge-archivelogs.sh.
ALTER SYSTEM SET db_recovery_file_dest_size = 5G SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest = '/opt/oracle/oradata/recovery_area' SCOPE=BOTH;

-- Switching to ARCHIVELOG is only possible while the database is mounted, not open.
-- This is the one step that needs downtime on a real system.
SHUTDOWN IMMEDIATE
STARTUP MOUNT
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;

-- 2) The image ships with 2 x 20 MB redo logs. Every log switch makes LogMiner
--    start a new mining session, so tiny logs mean constant overhead.
--    Add three 200 MB groups, move off the old ones, then drop them.
ALTER DATABASE ADD LOGFILE GROUP 4 ('/opt/oracle/oradata/FREE/redo04.log') SIZE 200M;
ALTER DATABASE ADD LOGFILE GROUP 5 ('/opt/oracle/oradata/FREE/redo05.log') SIZE 200M;
ALTER DATABASE ADD LOGFILE GROUP 6 ('/opt/oracle/oradata/FREE/redo06.log') SIZE 200M;
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER SYSTEM CHECKPOINT GLOBAL;
ALTER DATABASE DROP LOGFILE GROUP 1;
ALTER DATABASE DROP LOGFILE GROUP 2;

-- 3) Minimal supplemental logging: adds just enough to the redo stream for
--    LogMiner to reconstruct row changes. Full column logging is enabled per
--    table below, so the extra redo is limited to the captured tables.
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

-- 4) The Debezium user. Common user (c##) because the connector connects to the
--    CDB to run LogMiner and switches into FREEPDB1 to read table data.
--    Its own small tablespace holds the connector's flush table.
CREATE TABLESPACE logminer_tbs DATAFILE '/opt/oracle/oradata/FREE/logminer_tbs.dbf'
    SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE TABLESPACE logminer_tbs DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/logminer_tbs.dbf'
    SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED;
ALTER SESSION SET CONTAINER = CDB\$ROOT;

CREATE USER c##dbzuser IDENTIFIED BY "${DBZ_PASSWORD}"
    DEFAULT TABLESPACE logminer_tbs QUOTA UNLIMITED ON logminer_tbs CONTAINER=ALL;

-- Session + container switching
GRANT CREATE SESSION, SET CONTAINER TO c##dbzuser CONTAINER=ALL;
-- LogMiner itself
GRANT LOGMINING, SELECT ANY TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR_D TO c##dbzuser CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE, EXECUTE_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
-- Redo/archive log metadata the connector polls
GRANT SELECT ON V_\$DATABASE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOG_HISTORY TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOGFILE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$ARCHIVED_LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$ARCHIVE_DEST_STATUS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOGMNR_LOGS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOGMNR_CONTENTS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$LOGMNR_PARAMETERS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$MYSTAT TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$STATNAME TO c##dbzuser CONTAINER=ALL;
-- The connector keeps a small flush table and uses LOCK during the initial snapshot
GRANT CREATE TABLE, CREATE SEQUENCE, LOCK ANY TABLE TO c##dbzuser CONTAINER=ALL;

-- 5) Per captured table:
--    * ALL COLUMNS supplemental logging, so change events carry the full
--      before/after image of a row, not just the changed columns
--    * SELECT (initial snapshot) and FLASHBACK (consistent snapshot as of an SCN)
--    Debezium's docs grant SELECT/FLASHBACK ANY TABLE; table-level grants are
--    the least-privilege version and show exactly what is exposed.
ALTER SESSION SET CONTAINER = FREEPDB1;

ALTER TABLE sales.customers   ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE sales.orders      ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE sales.order_items ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE billing.invoices  ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

GRANT SELECT, FLASHBACK ON sales.customers   TO c##dbzuser;
GRANT SELECT, FLASHBACK ON sales.orders      TO c##dbzuser;
GRANT SELECT, FLASHBACK ON sales.order_items TO c##dbzuser;
GRANT SELECT, FLASHBACK ON billing.invoices  TO c##dbzuser;
EOF

# Dropped redo log groups leave their files behind.
rm -f /opt/oracle/oradata/FREE/redo01.log /opt/oracle/oradata/FREE/redo02.log
