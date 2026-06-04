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
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafka-connect.yaml

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

# Verify Oracle Instant Client 21.x in the pod
echo ""
echo "Verifying Oracle Instant Client 21.x in Kafka Connect pod..."
if oc exec ${CONNECT_POD} -n ${NAMESPACE} -- test -f /opt/oracle/instantclient/lib/libocijdbc21.so 2>/dev/null; then
    echo "✓ libocijdbc21.so found in pod"
else
    echo "✗ libocijdbc21.so not found in pod"
    echo "Image may not have been built correctly with Oracle Instant Client 21.x"
    exit 1
fi

if oc exec ${CONNECT_POD} -n ${NAMESPACE} -- test -f /usr/lib64/libnsl.so.1 2>/dev/null; then
    echo "✓ libnsl.so.1 found in /usr/lib64"
else
    echo "⚠ libnsl.so.1 not found - connector may fail to load OCI library"
fi

if oc exec ${CONNECT_POD} -n ${NAMESPACE} -- test -f /opt/oracle/instantclient/lib/libclntsh.so.21.1 2>/dev/null; then
    echo "✓ Oracle Instant Client 21.x libraries found"
else
    echo "✗ Oracle Instant Client libraries not found"
    exit 1
fi

# Deploy connector
echo ""
echo "Deploying Oracle XStreams connector..."
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-xstreams-final.yaml

echo ""
echo "=== Connector Deployed ==="
echo ""
echo "Monitor connector status:"
echo "  oc get kafkaconnector oracle-xstreams-connector -n ${NAMESPACE}"
echo ""
echo "Watch connector logs:"
echo "  oc logs -f ${CONNECT_POD} -n ${NAMESPACE} | grep -i xstream"
echo ""
echo "Check for success message:"
echo "  'XstreamStreamingChangeEventSource - Connected to XStream outbound server'"
echo ""
echo "List created topics:"
echo "  oc get kafkatopics -n ${NAMESPACE} | grep oracle-xstreams"
echo ""
echo "Verify connector is running:"
echo "  oc get kafkaconnector oracle-xstreams-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}'"
