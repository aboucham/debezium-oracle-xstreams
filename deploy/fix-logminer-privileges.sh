#!/bin/bash
# Fix LogMiner privileges for existing deployments
# Grants all required privileges for LogMiner CDC operations

set -e

NAMESPACE="strimzi"

echo "=== Granting LogMiner privileges to c##dbzuser ==="
echo ""

ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ORACLE_POD" ]; then
    echo "✗ Oracle pod not found"
    exit 1
fi

echo "Oracle pod: ${ORACLE_POD}"
echo ""

oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Required for LogMiner to create flush table and other objects
GRANT CREATE TABLE TO c##dbzuser;
GRANT RESOURCE TO c##dbzuser;
GRANT CONNECT TO c##dbzuser;

-- Required for LogMiner streaming
GRANT EXECUTE_CATALOG_ROLE TO c##dbzuser;
GRANT SELECT_CATALOG_ROLE TO c##dbzuser;
GRANT SELECT ANY TRANSACTION TO c##dbzuser;
GRANT LOGMINING TO c##dbzuser;

-- Verify privileges
SET PAGESIZE 50
PROMPT System Privileges:
SELECT privilege FROM dba_sys_privs WHERE grantee = 'C##DBZUSER' ORDER BY privilege;
PROMPT
PROMPT Roles:
SELECT granted_role FROM dba_role_privs WHERE grantee = 'C##DBZUSER' ORDER BY granted_role;
EXIT;
EOF
"

echo ""
echo "✓ LogMiner privileges granted to c##dbzuser"
echo ""
echo "Granted privileges:"
echo "  System Privileges:"
echo "    - CREATE TABLE (for LOG_MINING_FLUSH table)"
echo "    - SELECT ANY TRANSACTION (read transaction metadata)"
echo "    - LOGMINING (direct log mining privilege)"
echo "  Roles:"
echo "    - RESOURCE (create database objects)"
echo "    - CONNECT (establish database connections)"
echo "    - EXECUTE_CATALOG_ROLE (execute DBMS_LOGMNR)"
echo "    - SELECT_CATALOG_ROLE (query data dictionary)"
echo ""
echo "Now restart the connector:"
echo "  oc delete kafkaconnector oracle-logminer-connector -n ${NAMESPACE}"
echo "  sleep 5"
echo "  oc apply -f deploy/kafkaconnector-oracle-logminer-final.yaml"
