#!/bin/bash
# Switch from LogMiner to XStream connector
# This script stops LogMiner and starts XStream side-by-side

set -e

NAMESPACE="strimzi"

echo "=========================================="
echo " Switching from LogMiner to XStream"
echo "=========================================="
echo ""

# Step 1: Stop LogMiner connector
echo "Step 1: Stopping LogMiner connector..."
if oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} >/dev/null 2>&1; then
    oc patch kafkaconnector oracle-logminer-connector -n ${NAMESPACE} --type merge -p '{"spec":{"state":"stopped"}}'
    echo "✓ LogMiner connector stopped"
else
    echo "⚠ LogMiner connector not found (skipping)"
fi

echo ""

# Step 2: Deploy XStream connector (initially stopped)
echo "Step 2: Deploying XStream connector (stopped state)..."
if oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "⚠ XStream connector already exists"
    echo "  Current state: $(oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} -o jsonpath='{.spec.state}')"
else
    oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-xstreams-final.yaml
    echo "✓ XStream connector deployed (stopped)"
fi

echo ""

# Step 3: Start XStream connector
echo "Step 3: Starting XStream connector..."
oc patch kafkaconnector oracle-xstream-connector -n ${NAMESPACE} --type merge -p '{"spec":{"state":"running"}}'

echo "  Waiting for connector to start..."
sleep 10

# Check status
CONNECTOR_STATE=$(oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}' 2>/dev/null || echo "UNKNOWN")
TASK_STATE=$(oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.tasks[0].state}' 2>/dev/null || echo "UNKNOWN")

if [ "$CONNECTOR_STATE" = "RUNNING" ] && [ "$TASK_STATE" = "RUNNING" ]; then
    echo "✓ XStream connector started successfully"
else
    echo "⚠ XStream connector state: ${CONNECTOR_STATE}, Task state: ${TASK_STATE}"
    echo ""
    echo "Check status with:"
    echo "  oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus}' | jq ."
fi

echo ""
echo "=========================================="
echo " Switch Complete!"
echo "=========================================="
echo ""
echo "Connector Status:"
echo "  LogMiner:  STOPPED"
echo "  XStream:   RUNNING"
echo ""
echo "New topic prefix: oracle-xstream.*"
echo ""
echo "To switch back to LogMiner:"
echo "  oc patch kafkaconnector oracle-xstream-connector -n ${NAMESPACE} --type merge -p '{\"spec\":{\"state\":\"stopped\"}}'"
echo "  oc patch kafkaconnector oracle-logminer-connector -n ${NAMESPACE} --type merge -p '{\"spec\":{\"state\":\"running\"}}'"
echo ""
echo "Monitor topics:"
echo "  oc exec -n ${NAMESPACE} \$(oc get pods -n ${NAMESPACE} -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \\"
echo "    bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle"
echo ""
