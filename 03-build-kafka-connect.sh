#!/bin/bash
# Extract OCI libraries and build Kafka Connect image
set -e

NAMESPACE="strimzi"

echo "=== Step 3: Build Kafka Connect with OCI Support ==="
echo ""

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
            echo "✓ Oracle pod ${ORACLE_POD} is ready"
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

# Extract OCI libraries using tar-based approach (more reliable than copying individual files)
echo ""
echo "Extracting OCI libraries from Oracle pod (this will take 2-3 minutes)..."
./extract-oci-libraries.sh

# Verify critical OCI library
echo ""
echo "Verifying OCI library extraction..."
if [ ! -f "build/oci-libs/libocijdbc19.so" ]; then
    echo "✗ Critical library libocijdbc19.so not found"
    echo "Extraction may have failed. Check build/oci-libs/ directory"
    exit 1
fi

FILE_SIZE=$(ls -lh build/oci-libs/libocijdbc19.so | awk '{print $5}')
echo "✓ libocijdbc19.so found (${FILE_SIZE})"

# Download Debezium components
echo ""
echo "Downloading Debezium components and Oracle drivers..."
./download-dbz-oracle-xs-plugins.sh

# Verify Dockerfile was created with OCI support
echo ""
echo "Verifying Dockerfile configuration..."
if ! grep -q "COPY ./oci-libs/" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile not configured for OCI libraries"
    exit 1
fi

if ! grep -q "libnsl2" build/Dockerfile 2>/dev/null; then
    echo "✗ Dockerfile missing libnsl2 dependency"
    exit 1
fi

echo "✓ Dockerfile configured with OCI and libnsl2"

# Build Kafka Connect image
echo ""
echo "Building Kafka Connect image (this will take 5-10 minutes due to 2GB OCI libraries)..."
./build-kafka-connect-dbz-oracle-xs-plugins.sh

echo ""
echo "=== Build Complete ==="
echo ""
echo "Deploy Kafka Connect:"
echo "  oc apply -f kafka-connect.yaml"
echo ""
echo "Wait for Kafka Connect to be ready:"
echo "  oc get pods -n ${NAMESPACE} -w -l strimzi.io/cluster=debezium-connect"
