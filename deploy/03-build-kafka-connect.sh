#!/bin/bash
# Download Oracle Instant Client 19.x and build Kafka Connect image
set -e

NAMESPACE="strimzi"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy"

echo "=== Step 3: Build Kafka Connect with Oracle Instant Client 19.x ==="
echo ""

# Detect if running locally or remotely
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -f "${SCRIPT_DIR}/download-oracle-instantclient-19.sh" ]; then
    EXEC_MODE="local"
else
    EXEC_MODE="remote"
fi

# Check if in correct namespace
oc project ${NAMESPACE} 2>/dev/null || {
    echo "Error: Namespace ${NAMESPACE} not found"
    exit 1
}

# Wait for Oracle pod to be Running (to extract instantclient files)
echo "Checking Oracle pod status..."
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$ORACLE_POD" ]; then
    echo "✗ Oracle pod not found"
    echo "Run step 1 first: ./01-deploy-oracle.sh"
    exit 1
fi

POD_STATUS=$(oc get pod ${ORACLE_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Oracle pod not running (status: ${POD_STATUS})"
    echo "Wait for pod to be Running before building"
    exit 1
fi

echo "✓ Oracle pod ${ORACLE_POD} is Running"
echo ""
echo "Note: We only need the pod running to extract instantclient files."
echo "Database initialization can continue in the background."

# Download Oracle Instant Client 19.x and Debezium components
echo ""
echo "Downloading Oracle Instant Client 19.24 and Debezium components..."
echo "This will take 5-8 minutes (downloading 85MB Oracle IC + extracting from Oracle pod)..."
if [ "$EXEC_MODE" = "local" ]; then
    bash "${SCRIPT_DIR}/download-oracle-instantclient-19.sh"
else
    bash <(curl -s "${GITHUB_RAW_BASE}/download-oracle-instantclient-19.sh")
fi

# Verify Oracle Instant Client 19.x was downloaded
echo ""
echo "Verifying Oracle Instant Client 19.x..."
if [ ! -f "build/oracle-instantclient/lib/libocijdbc19.so" ]; then
    echo "✗ Critical library libocijdbc19.so not found"
    echo "Download may have failed. Check build/oracle-instantclient/lib/ directory"
    exit 1
fi

if [ ! -f "build/plugins/debezium-oracle-connector/ojdbc11.jar" ]; then
    echo "✗ ojdbc11.jar not found"
    echo "Download may have failed. Check build/plugins/debezium-oracle-connector/ directory"
    exit 1
fi

IC_SIZE=$(du -sh build/oracle-instantclient 2>/dev/null | awk '{print $1}')
echo "✓ Oracle Instant Client 19.x downloaded (${IC_SIZE})"

OJDBC_SIZE=$(ls -lh build/plugins/debezium-oracle-connector/ojdbc11.jar | awk '{print $5}')
echo "✓ ojdbc11.jar found (${OJDBC_SIZE})"

# Verify Dockerfile was created
echo ""
echo "Verifying Dockerfile configuration..."
if ! grep -q "COPY ./oracle-instantclient/" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile not configured for Oracle Instant Client"
    exit 1
fi

if ! grep -q "ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile missing libnsl symlink configuration"
    exit 1
fi

echo "✓ Dockerfile configured with Oracle Instant Client 19.x and libnsl"

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
