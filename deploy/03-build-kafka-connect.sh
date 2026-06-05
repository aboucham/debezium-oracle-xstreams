#!/bin/bash
# Download Oracle Instant Client 21.x and build Kafka Connect image
set -e

NAMESPACE="strimzi"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy"

echo "=== Step 3: Build Kafka Connect with Oracle Instant Client 21.x ==="
echo ""

# Detect if running locally or remotely
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -f "${SCRIPT_DIR}/download-oracle-instantclient-21.sh" ]; then
    EXEC_MODE="local"
else
    EXEC_MODE="remote"
fi

# Check if in correct namespace
oc project ${NAMESPACE} 2>/dev/null || {
    echo "Error: Namespace ${NAMESPACE} not found"
    exit 1
}

# Wait for Oracle pod to be ready
echo "Waiting for Oracle database pod to be ready..."
ORACLE_POD=""
for i in {1..60}; do
    ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ORACLE_POD" ]; then
        POD_STATUS=$(oc get pod ${ORACLE_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$POD_STATUS" = "Running" ]; then
            # Wait a bit more for Oracle to be fully initialized
            echo "✓ Oracle pod ${ORACLE_POD} is running, waiting for initialization..."
            sleep 10

            # Grant CREATE TABLE privilege for LogMiner
            echo "Granting CREATE TABLE privilege to c##dbzuser (required for LogMiner)..."
            oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
GRANT CREATE TABLE TO c##dbzuser;
EXIT;
EOF
" > /dev/null 2>&1 || echo "  Warning: Could not grant privilege (may already exist)"
            echo "✓ LogMiner prerequisites configured"

            break
        fi
    fi
    echo "  Waiting for Oracle pod... (${i}/60)"
    sleep 5
done

if [ -z "$ORACLE_POD" ] || [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Oracle pod not ready after 5 minutes"
    echo "Check Oracle deployment: oc get pods -n ${NAMESPACE} -l app=oracle-db"
    exit 1
fi

# Download Oracle Instant Client 21.x and Debezium components
echo ""
echo "Downloading Oracle Instant Client 21.15 and Debezium components..."
echo "This will take 5-8 minutes (downloading 85MB Oracle IC + extracting from Oracle pod)..."
if [ "$EXEC_MODE" = "local" ]; then
    bash "${SCRIPT_DIR}/download-oracle-instantclient-21.sh"
else
    bash <(curl -s "${GITHUB_RAW_BASE}/download-oracle-instantclient-21.sh")
fi

# Verify Oracle Instant Client 21.x was downloaded
echo ""
echo "Verifying Oracle Instant Client 21.x..."
if [ ! -f "build/oracle-instantclient/lib/libocijdbc21.so" ]; then
    echo "✗ Critical library libocijdbc21.so not found"
    echo "Download may have failed. Check build/oracle-instantclient/lib/ directory"
    exit 1
fi

if [ ! -f "build/plugins/debezium-oracle-connector/ojdbc11.jar" ]; then
    echo "✗ ojdbc11.jar not found"
    echo "Download may have failed. Check build/plugins/debezium-oracle-connector/ directory"
    exit 1
fi

IC_SIZE=$(du -sh build/oracle-instantclient 2>/dev/null | awk '{print $1}')
echo "✓ Oracle Instant Client 21.x downloaded (${IC_SIZE})"

OJDBC_SIZE=$(ls -lh build/plugins/debezium-oracle-connector/ojdbc11.jar | awk '{print $5}')
echo "✓ ojdbc11.jar found (${OJDBC_SIZE})"

# Verify Dockerfile was created
echo ""
echo "Verifying Dockerfile configuration..."
if ! grep -q "COPY ./oracle-instantclient/" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile not configured for Oracle Instant Client"
    exit 1
fi

if ! grep -q "cp -P /opt/oracle/instantclient/lib/libnsl" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile missing libnsl configuration"
    exit 1
fi

echo "✓ Dockerfile configured with Oracle Instant Client 21.x and libnsl"

# Build Kafka Connect image
echo ""
echo "Building Kafka Connect image (this will take 8-12 minutes - uploading ~925MB)..."
if [ "$EXEC_MODE" = "local" ]; then
    bash "${SCRIPT_DIR}/build-kafka-connect-dbz-oracle-xs-plugins.sh"
else
    bash <(curl -s "${GITHUB_RAW_BASE}/build-kafka-connect-dbz-oracle-xs-plugins.sh")
fi

echo ""
echo "=== Build Complete ==="
echo ""
echo "Next step: Deploy Kafka Connect and XStreams connector"
echo "  oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafka-connect.yaml"
echo ""
echo "Wait for Kafka Connect to be ready:"
echo "  oc get pods -n ${NAMESPACE} -w -l strimzi.io/cluster=debezium-connect"
echo ""
