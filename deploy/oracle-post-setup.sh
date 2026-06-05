#!/bin/bash
# Oracle post-deployment setup - run after database is ready
# Grants required privileges for LogMiner CDC

set -e

NAMESPACE="strimzi"

echo "=== Oracle Post-Deployment Setup ==="
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
    echo ""
    echo "⚠ Database is NOT ready yet"
    echo ""
    echo "Oracle is still initializing. Please wait and try again."
    echo ""
    echo "To monitor progress:"
    echo "  oc logs -f ${ORACLE_POD} -n ${NAMESPACE}"
    echo ""
    echo "Look for this message:"
    echo "  'DATABASE IS READY TO USE!'"
    echo ""
    echo "Or use the wait script:"
    echo "  ./wait-for-oracle-ready.sh"
    exit 1
fi

echo "✓ Database is ready!"
echo ""

# Test connection
echo "Testing database connection..."
CONNECTION_TEST=$(oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "echo 'SELECT 1 FROM DUAL;' | sqlplus -s sys/top_secret@ORCLCDB as sysdba" 2>&1 || echo "FAILED")

if echo "$CONNECTION_TEST" | grep -q "ORA-\|TNS-\|SP2-"; then
    echo "✗ Database connection failed"
    echo "$CONNECTION_TEST"
    exit 1
fi

echo "✓ Database connection verified"
echo ""

# Grant CREATE TABLE privilege for LogMiner
echo "Granting CREATE TABLE privilege to c##dbzuser (required for LogMiner)..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
GRANT CREATE TABLE TO c##dbzuser;
EOF
"

echo "✓ CREATE TABLE privilege granted"
echo ""

# Verify privileges
echo "Verifying c##dbzuser privileges:"
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET PAGESIZE 50
SELECT privilege FROM dba_sys_privs WHERE grantee = 'C##DBZUSER' ORDER BY privilege;
EXIT;
EOF
"

echo ""
echo "=== Oracle Setup Complete ==="
echo ""
echo "✓ Database is ready for CDC operations"
echo "✓ LogMiner prerequisites configured"
echo ""
echo "You can now proceed with testing:"
echo "  See README.md - STEP 1: Test LogMiner CDC"
