#!/bin/bash
# Wait for Oracle Database to be fully initialized and ready
set -e

NAMESPACE="strimzi"
MAX_WAIT=600  # 10 minutes
ELAPSED=0

echo "=== Waiting for Oracle Database to be Ready ==="
echo ""

# Get Oracle pod
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ORACLE_POD" ]; then
    echo "✗ Oracle pod not found"
    exit 1
fi

echo "Oracle pod: ${ORACLE_POD}"
echo ""

# Wait for pod to be running first
echo "Step 1: Waiting for pod to be Running..."
while [ $ELAPSED -lt $MAX_WAIT ]; do
    POD_STATUS=$(oc get pod ${ORACLE_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$POD_STATUS" = "Running" ]; then
        echo "✓ Pod is Running"
        break
    fi
    echo "  Pod status: ${POD_STATUS} (${ELAPSED}s/${MAX_WAIT}s)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Pod did not reach Running state"
    exit 1
fi

# Wait for database to be ready (check logs for "DATABASE IS READY TO USE!")
echo ""
echo "Step 2: Waiting for Oracle Database initialization..."
echo "This takes 3-5 minutes - Oracle is creating the database..."
echo ""

ELAPSED=0
DB_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check if database is ready by looking for the ready message in logs
    if oc logs ${ORACLE_POD} -n ${NAMESPACE} 2>/dev/null | grep -q "DATABASE IS READY TO USE"; then
        echo "✓ Database initialization complete!"
        DB_READY=true
        break
    fi

    # Show progress from logs every 30 seconds
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        PROGRESS=$(oc logs ${ORACLE_POD} -n ${NAMESPACE} --tail=10 2>/dev/null | grep "% complete" | tail -1 || echo "")
        if [ -n "$PROGRESS" ]; then
            echo "  Progress: ${PROGRESS} (${ELAPSED}s/${MAX_WAIT}s)"
        else
            echo "  Initializing database... (${ELAPSED}s/${MAX_WAIT}s)"
        fi
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [ "$DB_READY" != "true" ]; then
    echo ""
    echo "✗ Database did not complete initialization within ${MAX_WAIT} seconds"
    echo ""
    echo "Recent logs:"
    oc logs ${ORACLE_POD} -n ${NAMESPACE} --tail=20
    exit 1
fi

# Verify database is actually connectable
echo ""
echo "Step 3: Verifying database connection..."
CONNECTION_TEST=$(oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "echo 'SELECT 1 FROM DUAL;' | sqlplus -s sys/top_secret@ORCLCDB as sysdba" 2>&1 || echo "FAILED")

if echo "$CONNECTION_TEST" | grep -q "ORA-\|TNS-\|SP2-"; then
    echo "✗ Database connection failed"
    echo "$CONNECTION_TEST"
    exit 1
fi

echo "✓ Database connection verified"
echo ""
echo "=== Oracle Database is Ready! ==="
echo ""
echo "Database: ORCLCDB"
echo "Ready for CDC operations"
