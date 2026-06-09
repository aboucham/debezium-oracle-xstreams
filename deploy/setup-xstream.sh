#!/bin/bash
# Setup Oracle XStream prerequisites for Debezium connector
# This script must be run AFTER oracle-post-setup.sh
# It configures Archive Log mode, GoldenGate replication, and XStream infrastructure

set -e

NAMESPACE="strimzi"

echo "=========================================="
echo " Oracle XStream Setup"
echo "=========================================="
echo ""
echo "This script will configure Oracle for XStream CDC:"
echo "  1. Enable Archive Log mode"
echo "  2. Enable GoldenGate replication"
echo "  3. Create XStream administrator user (c##dbzadmin)"
echo "  4. Create XStream tablespaces"
echo "  5. Grant XStream privileges to c##dbzuser"
echo "  6. Create XStream outbound server (dbzxout)"
echo "  7. Connect user to outbound server"
echo ""
echo "⚠ WARNING: This will restart the Oracle database!"
echo ""

# Get Oracle pod
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ORACLE_POD" ]; then
    echo "✗ Oracle pod not found"
    exit 1
fi

echo "Oracle pod: ${ORACLE_POD}"
echo ""

# Check if database is ready
echo "Checking if Oracle Database is ready..."
if ! oc logs ${ORACLE_POD} -n ${NAMESPACE} 2>/dev/null | grep -q "DATABASE IS READY TO USE!"; then
    echo "✗ Database is NOT ready yet"
    echo "Run oracle-post-setup.sh first and wait for database to be ready"
    exit 1
fi

echo "✓ Database is ready!"
echo ""

#=============================================================================
# STEP 1: Configure Archive Log Mode and GoldenGate Replication
#=============================================================================
echo "=========================================="
echo " Step 1: Archive Log & GoldenGate Setup"
echo "=========================================="
echo ""

echo "Checking current database log mode..."
LOG_MODE=$(oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "echo 'SELECT log_mode FROM v\$database;' | sqlplus -s sys/top_secret@ORCLCDB as sysdba" | grep -E "ARCHIVELOG|NOARCHIVELOG" | tr -d ' ' || echo "UNKNOWN")

echo "Current log mode: ${LOG_MODE}"

if [ "$LOG_MODE" = "ARCHIVELOG" ]; then
    echo "✓ Archive log mode already enabled"
else
    echo "Enabling archive log mode and GoldenGate replication..."
    echo "⚠ This will restart the database (takes ~2 minutes)..."

    oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Set recovery file destination
alter system set db_recovery_file_dest_size = 5G;
alter system set db_recovery_file_dest = '/opt/oracle/oradata/recovery_area' scope=spfile;

-- Enable GoldenGate replication
alter system set enable_goldengate_replication=true scope=spfile;

-- Shutdown and restart in mount mode
shutdown immediate

-- Wait a moment for clean shutdown
!sleep 5

-- Start in mount mode
startup mount

-- Enable archive log
alter database archivelog;

-- Open database
alter database open;

-- Verify
archive log list;

EXIT;
EOF
"

    echo ""
    echo "Waiting for database to be fully ready after restart..."
    sleep 20

    # Verify archive log is enabled
    LOG_MODE=$(oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "echo 'SELECT log_mode FROM v\$database;' | sqlplus -s sys/top_secret@ORCLCDB as sysdba" | grep -E "ARCHIVELOG|NOARCHIVELOG" | tr -d ' ')

    if [ "$LOG_MODE" = "ARCHIVELOG" ]; then
        echo "✓ Archive log mode enabled successfully"
    else
        echo "✗ Failed to enable archive log mode"
        exit 1
    fi
fi

echo ""

#=============================================================================
# STEP 2: Create XStream Tablespaces
#=============================================================================
echo "=========================================="
echo " Step 2: Create XStream Tablespaces"
echo "=========================================="
echo ""

echo "Creating XStream administrator tablespace..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Check if tablespace already exists
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_tablespaces WHERE tablespace_name = 'XSTREAM_ADM_TBS';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLESPACE xstream_adm_tbs DATAFILE ''/opt/oracle/oradata/ORCLCDB/xstream_adm_tbs.dbf'' SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED';
    DBMS_OUTPUT.PUT_LINE('Tablespace XSTREAM_ADM_TBS created');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Tablespace XSTREAM_ADM_TBS already exists');
  END IF;
END;
/
EXIT;
EOF
"

echo "Creating XStream user tablespace..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Check if tablespace already exists
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_tablespaces WHERE tablespace_name = 'XSTREAM_TBS';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE TABLESPACE xstream_tbs DATAFILE ''/opt/oracle/oradata/ORCLCDB/xstream_tbs.dbf'' SIZE 25M REUSE AUTOEXTEND ON MAXSIZE UNLIMITED';
    DBMS_OUTPUT.PUT_LINE('Tablespace XSTREAM_TBS created');
  ELSE
    DBMS_OUTPUT.PUT_LINE('Tablespace XSTREAM_TBS already exists');
  END IF;
END;
/
EXIT;
EOF
"

echo "✓ XStream tablespaces created"
echo ""

#=============================================================================
# STEP 3: Create XStream Administrator User (c##dbzadmin)
#=============================================================================
echo "=========================================="
echo " Step 3: Create XStream Administrator"
echo "=========================================="
echo ""

echo "Creating c##dbzadmin user..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Check if user already exists
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = 'C##DBZADMIN';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER c##dbzadmin IDENTIFIED BY dbz DEFAULT TABLESPACE xstream_adm_tbs QUOTA UNLIMITED ON xstream_adm_tbs CONTAINER=ALL';
    DBMS_OUTPUT.PUT_LINE('User C##DBZADMIN created');
  ELSE
    DBMS_OUTPUT.PUT_LINE('User C##DBZADMIN already exists');
  END IF;
END;
/

-- Grant session and container privileges
GRANT CREATE SESSION, SET CONTAINER TO c##dbzadmin CONTAINER=ALL;

-- Grant XStream admin privileges for CAPTURE
BEGIN
   DBMS_XSTREAM_AUTH.GRANT_ADMIN_PRIVILEGE(
      grantee                 => 'c##dbzadmin',
      privilege_type          => 'CAPTURE',
      grant_select_privileges => TRUE,
      container               => 'ALL'
   );
END;
/

EXIT;
EOF
"

echo "✓ XStream administrator created"
echo ""

#=============================================================================
# STEP 4: Grant XStream Privileges to c##dbzuser
#=============================================================================
echo "=========================================="
echo " Step 4: Grant XStream Privileges"
echo "=========================================="
echo ""

echo "Granting XStream-specific privileges to c##dbzuser..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Grant additional privileges required for XStream
GRANT SET CONTAINER TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_\$DATABASE TO c##dbzuser CONTAINER=ALL;
GRANT LOCK ANY TABLE TO c##dbzuser CONTAINER=ALL;

-- Verify privileges
SET PAGESIZE 50
PROMPT XStream Privileges for c##dbzuser:
SELECT privilege FROM dba_sys_privs WHERE grantee = 'C##DBZUSER' ORDER BY privilege;

EXIT;
EOF
"

echo "✓ XStream privileges granted to c##dbzuser"
echo ""

#=============================================================================
# STEP 5: Create XStream Outbound Server (dbzxout)
#=============================================================================
echo "=========================================="
echo " Step 5: Create XStream Outbound Server"
echo "=========================================="
echo ""

echo "Creating XStream outbound server 'dbzxout' for C##DBZUSER schema..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s c##dbzadmin/dbz@ORCLCDB <<'EOF'
-- Check if outbound server already exists
DECLARE
  v_count NUMBER;
  tables  DBMS_UTILITY.UNCL_ARRAY;
  schemas DBMS_UTILITY.UNCL_ARRAY;
BEGIN
  SELECT COUNT(*) INTO v_count FROM DBA_XSTREAM_OUTBOUND WHERE server_name = 'DBZXOUT';

  IF v_count = 0 THEN
    -- Create outbound server for C##DBZUSER schema
    tables(1)  := NULL;
    schemas(1) := 'C##DBZUSER';

    DBMS_XSTREAM_ADM.CREATE_OUTBOUND(
      server_name     =>  'dbzxout',
      table_names     =>  tables,
      schema_names    =>  schemas);

    DBMS_OUTPUT.PUT_LINE('XStream outbound server DBZXOUT created for schema C##DBZUSER');
  ELSE
    DBMS_OUTPUT.PUT_LINE('XStream outbound server DBZXOUT already exists');
  END IF;
END;
/

EXIT;
EOF
"

echo "✓ XStream outbound server created"
echo ""

#=============================================================================
# STEP 6: Connect c##dbzuser to Outbound Server
#=============================================================================
echo "=========================================="
echo " Step 6: Connect User to Outbound Server"
echo "=========================================="
echo ""

echo "Connecting c##dbzuser to XStream outbound server..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
BEGIN
  DBMS_XSTREAM_ADM.ALTER_OUTBOUND(
    server_name  => 'dbzxout',
    connect_user => 'c##dbzuser');
END;
/

EXIT;
EOF
"

echo "✓ User connected to outbound server"
echo ""

#=============================================================================
# STEP 7: Verify XStream Configuration
#=============================================================================
echo "=========================================="
echo " Step 7: Verify XStream Configuration"
echo "=========================================="
echo ""

echo "Verifying XStream outbound server configuration..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET PAGESIZE 50
SET LINESIZE 200

PROMPT XStream Outbound Servers:
SELECT server_name, connect_user, capture_name, capture_user
FROM DBA_XSTREAM_OUTBOUND
WHERE server_name = 'DBZXOUT';

PROMPT
PROMPT XStream Capture Process:
SELECT capture_name, status, capture_type
FROM DBA_CAPTURE
WHERE capture_name IN (SELECT capture_name FROM DBA_XSTREAM_OUTBOUND WHERE server_name = 'DBZXOUT');

EXIT;
EOF
"

echo ""
echo "=========================================="
echo " XStream Setup Complete!"
echo "=========================================="
echo ""
echo "✓ Archive log mode enabled"
echo "✓ GoldenGate replication enabled"
echo "✓ XStream administrator (c##dbzadmin) created"
echo "✓ XStream tablespaces created"
echo "✓ XStream privileges granted to c##dbzuser"
echo "✓ XStream outbound server (dbzxout) created"
echo "✓ User connected to outbound server"
echo ""
echo "Oracle is now ready for XStream CDC!"
echo ""
echo "Next steps:"
echo "  1. Switch to XStream connector:"
echo "     bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/switch-to-xstream.sh)"
echo ""
echo "  2. Insert test data and verify streaming:"
echo "     See README.md - STEP 4: Test XStream Streaming"
echo ""
