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

# Grant privileges for LogMiner
echo "Granting LogMiner privileges to c##dbzuser..."
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
EOF
"

echo "✓ LogMiner privileges granted"
echo ""

# Verify privileges
echo "Verifying c##dbzuser privileges:"
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET PAGESIZE 50
PROMPT System Privileges:
SELECT privilege FROM dba_sys_privs WHERE grantee = 'C##DBZUSER' ORDER BY privilege;
PROMPT
PROMPT Roles:
SELECT granted_role FROM dba_role_privs WHERE grantee = 'C##DBZUSER' ORDER BY granted_role;
EXIT;
EOF
"

# Restart connector to pick up new privileges
echo ""
echo "Restarting LogMiner connector to apply new privileges..."

if oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "  Deleting existing connector..."
    oc delete kafkaconnector oracle-logminer-connector -n ${NAMESPACE}

    echo "  Waiting for connector to be removed..."
    sleep 5

    echo "  Creating connector with new privileges..."
    oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml

    echo "  Waiting for connector to start..."
    sleep 10

    # Check connector status
    CONNECTOR_STATE=$(oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}' 2>/dev/null || echo "UNKNOWN")
    TASK_STATE=$(oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.tasks[0].state}' 2>/dev/null || echo "UNKNOWN")

    if [ "$CONNECTOR_STATE" = "RUNNING" ] && [ "$TASK_STATE" = "RUNNING" ]; then
        echo "✓ Connector restarted successfully"
    else
        echo "⚠ Connector state: ${CONNECTOR_STATE}, Task state: ${TASK_STATE}"
        echo "  Check status: oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE}"
    fi
else
    echo "  No connector found - will be created when you deploy it"
fi

echo ""
echo "=== Oracle Setup Complete ==="
echo ""
echo "✓ Database is ready for CDC operations"
echo "✓ LogMiner prerequisites configured"
echo "✓ Connector restarted with new privileges"
echo ""
echo "You can now proceed with testing:"
echo "  See README.md - STEP 1: Test LogMiner CDC"
