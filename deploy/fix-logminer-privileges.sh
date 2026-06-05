#!/bin/bash
# Fix LogMiner privileges - grant CREATE TABLE to c##dbzuser
# This is required for LogMiner to create the LOG_MINING_FLUSH table

set -e

NAMESPACE="strimzi"

echo "=== Granting CREATE TABLE privilege to c##dbzuser ==="
echo ""

ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ORACLE_POD" ]; then
    echo "✗ Oracle pod not found"
    exit 1
fi

echo "Oracle pod: ${ORACLE_POD}"
echo ""

oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
-- Grant CREATE TABLE privilege for LogMiner
GRANT CREATE TABLE TO c##dbzuser;

-- Verify privileges
SELECT privilege FROM dba_sys_privs WHERE grantee = 'C##DBZUSER' ORDER BY privilege;
EXIT;
EOF
"

echo ""
echo "✓ CREATE TABLE privilege granted to c##dbzuser"
echo ""
echo "This allows LogMiner to create the LOG_MINING_FLUSH table"
echo "required for CDC operation."
