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

# Wait for KafkaConnect resource to be ready first
echo ""
echo "Waiting for KafkaConnect resource to be reconciled..."
KC_READY=""
for i in {1..60}; do
    KC_READY=$(oc get kafkaconnect debezium-connect -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [ "$KC_READY" = "True" ]; then
        echo "✓ KafkaConnect resource is ready"
        break
    fi

    # Show what's happening every 10 seconds
    if [ $((i % 2)) -eq 0 ]; then
        KC_STATUS=$(oc get kafkaconnect debezium-connect -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "Waiting for operator...")
        echo "  Status: ${KC_STATUS}"
    fi
    sleep 5
done

if [ "$KC_READY" != "True" ]; then
    echo "⚠ KafkaConnect resource not ready after 5 minutes"
    echo ""
    echo "Debug information:"
    oc get kafkaconnect debezium-connect -n ${NAMESPACE}
    echo ""
    oc describe kafkaconnect debezium-connect -n ${NAMESPACE} | tail -20
    echo ""
    echo "Continuing to wait for pod..."
fi

# Wait for Kafka Connect pod to be ready
echo ""
echo "Waiting for Kafka Connect pod to be created and ready..."
CONNECT_POD=""
for i in {1..120}; do
    CONNECT_POD=$(oc get pods -n ${NAMESPACE} -l strimzi.io/cluster=debezium-connect -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CONNECT_POD" ]; then
        POD_STATUS=$(oc get pod ${CONNECT_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        echo "  Pod ${CONNECT_POD} status: ${POD_STATUS}"

        if [ "$POD_STATUS" = "Running" ]; then
            # Check if pod is actually ready (not just running)
            POD_READY=$(oc get pod ${CONNECT_POD} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$POD_READY" = "True" ]; then
                echo "✓ Kafka Connect pod ${CONNECT_POD} is ready"
                break
            else
                echo "  Pod is running but not ready yet..."
            fi
        elif [ "$POD_STATUS" = "Pending" ]; then
            # Show why it's pending
            PENDING_REASON=$(oc get pod ${CONNECT_POD} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || echo "")
            if [ -n "$PENDING_REASON" ]; then
                echo "  Reason: ${PENDING_REASON}"
            fi
        elif [ "$POD_STATUS" = "Failed" ] || [ "$POD_STATUS" = "CrashLoopBackOff" ]; then
            echo "✗ Pod failed to start"
            oc describe pod ${CONNECT_POD} -n ${NAMESPACE} | tail -30
            exit 1
        fi
    else
        # Show progress every 10 iterations
        if [ $((i % 10)) -eq 0 ]; then
            echo "  Waiting for Kafka Connect pod to be created... (${i}/120)"
            # Check if there are any pods being created
            POD_COUNT=$(oc get pods -n ${NAMESPACE} -l strimzi.io/cluster=debezium-connect --no-headers 2>/dev/null | wc -l)
            echo "  Pods with label strimzi.io/cluster=debezium-connect: ${POD_COUNT}"
        fi
    fi
    sleep 5
done

if [ -z "$CONNECT_POD" ]; then
    echo "✗ Kafka Connect pod was not created after 10 minutes"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check KafkaConnect resource:"
    echo "   oc get kafkaconnect debezium-connect -n ${NAMESPACE}"
    echo "   oc describe kafkaconnect debezium-connect -n ${NAMESPACE}"
    echo ""
    echo "2. Check if Strimzi operator is running:"
    echo "   oc get pods -A | grep strimzi | grep operator"
    echo ""
    echo "3. Check events:"
    echo "   oc get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -20"
    exit 1
fi

if [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Kafka Connect pod not ready after 10 minutes (status: ${POD_STATUS})"
    echo ""
    echo "Pod details:"
    oc describe pod ${CONNECT_POD} -n ${NAMESPACE} | tail -30
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

# Deploy connector (LogMiner by default)
echo ""
echo "Deploying Oracle LogMiner connector (default)..."
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml

echo ""
echo "=== Connector Deployed ==="
echo ""
echo "Monitor connector status:"
echo "  oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE}"
echo ""
echo "Watch connector logs:"
echo "  oc logs -f ${CONNECT_POD} -n ${NAMESPACE} | grep -i logminer"
echo ""
echo "List created topics:"
echo "  oc get kafkatopics -n ${NAMESPACE} | grep oracle-logminer"
echo ""
echo "Verify connector is running:"
echo "  oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}'"
echo ""
echo "Next: Create test table and verify CDC - see README.md"
