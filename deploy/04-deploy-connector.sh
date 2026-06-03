#!/bin/bash
# Deploy Kafka Connect and Oracle XStreams connector
set -e

NAMESPACE="strimzi"

echo "=== Step 4: Deploy Oracle XStreams Connector ==="
echo ""

# Check if in correct namespace
oc project ${NAMESPACE} 2>/dev/null || {
    echo "Error: Namespace ${NAMESPACE} not found"
    exit 1
}

# Deploy Kafka Connect
echo "Deploying Kafka Connect cluster..."
oc apply -f kafka-connect.yaml

# Wait for Kafka Connect to be ready
echo ""
echo "Waiting for Kafka Connect pod to be ready (may take 5-10 minutes)..."
CONNECT_POD=""
for i in {1..120}; do
    CONNECT_POD=$(oc get pods -n ${NAMESPACE} -l strimzi.io/cluster=debezium-connect -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CONNECT_POD" ]; then
        POD_STATUS=$(oc get pod ${CONNECT_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$POD_STATUS" = "Running" ]; then
            # Check if pod is actually ready (not just running)
            POD_READY=$(oc get pod ${CONNECT_POD} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$POD_READY" = "True" ]; then
                echo "✓ Kafka Connect pod ${CONNECT_POD} is ready"
                break
            fi
        fi
    fi
    echo "  Waiting for Kafka Connect pod... (${i}/120)"
    sleep 5
done

if [ -z "$CONNECT_POD" ] || [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Kafka Connect pod not ready after 10 minutes"
    echo "Check deployment: oc get pods -n ${NAMESPACE} -l strimzi.io/cluster=debezium-connect"
    echo "Check logs: oc logs -f ${CONNECT_POD} -n ${NAMESPACE}"
    exit 1
fi

# Verify OCI libraries in the pod
echo ""
echo "Verifying OCI libraries in Kafka Connect pod..."
if oc exec ${CONNECT_POD} -n ${NAMESPACE} -- test -f /opt/oracle/lib/libocijdbc19.so 2>/dev/null; then
    echo "✓ libocijdbc19.so found in pod"
else
    echo "✗ libocijdbc19.so not found in pod"
    echo "Image may not have been built correctly"
    exit 1
fi

if oc exec ${CONNECT_POD} -n ${NAMESPACE} -- test -f /lib64/libnsl.so.1 2>/dev/null; then
    echo "✓ libnsl.so.1 found in pod"
else
    echo "⚠ libnsl.so.1 not found - connector may fail to load OCI library"
fi

# Deploy connector
echo ""
echo "Deploying Oracle XStreams connector..."
oc apply -f kafkaconnector-oracle-xs-oci.yaml

echo ""
echo "=== Connector Deployed ==="
echo ""
echo "Monitor connector status:"
echo "  oc get kafkaconnector oracle-connector -n ${NAMESPACE}"
echo ""
echo "Watch connector logs:"
echo "  oc logs -f ${CONNECT_POD} -n ${NAMESPACE} | grep -i xstream"
echo ""
echo "Check for success message:"
echo "  'XstreamStreamingChangeEventSource - Connected to XStream outbound server'"
echo ""
echo "List created topics:"
echo "  oc get kafkatopics -n ${NAMESPACE} | grep dbserver1"
