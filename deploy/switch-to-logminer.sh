#!/bin/bash
# Switch from XStream back to LogMiner connector
# This script stops XStream and starts LogMiner side-by-side

set -e

NAMESPACE="strimzi"

echo "=========================================="
echo " Switching from XStream to LogMiner"
echo "=========================================="
echo ""

# Step 1: Stop XStream connector
echo "Step 1: Stopping XStream connector..."
if oc get kafkaconnector oracle-xstream-connector -n ${NAMESPACE} >/dev/null 2>&1; then
    oc patch kafkaconnector oracle-xstream-connector -n ${NAMESPACE} --type merge -p '{"spec":{"state":"stopped"}}'
    echo "✓ XStream connector stopped"
else
    echo "⚠ XStream connector not found (skipping)"
fi

echo ""

# Step 2: Start LogMiner connector
echo "Step 2: Starting LogMiner connector..."
if oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} >/dev/null 2>&1; then
    oc patch kafkaconnector oracle-logminer-connector -n ${NAMESPACE} --type merge -p '{"spec":{"state":"running"}}'

    echo "  Waiting for connector to start..."
    sleep 10

    # Check status
    CONNECTOR_STATE=$(oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}' 2>/dev/null || echo "UNKNOWN")
    TASK_STATE=$(oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.tasks[0].state}' 2>/dev/null || echo "UNKNOWN")

    if [ "$CONNECTOR_STATE" = "RUNNING" ] && [ "$TASK_STATE" = "RUNNING" ]; then
        echo "✓ LogMiner connector started successfully"
    else
        echo "⚠ LogMiner connector state: ${CONNECTOR_STATE}, Task state: ${TASK_STATE}"
        echo ""
        echo "Check status with:"
        echo "  oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus}' | jq ."
    fi
else
    echo "✗ LogMiner connector not found"
    echo "  Deploy it first with:"
    echo "  oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml"
    exit 1
fi

echo ""
echo "=========================================="
echo " Switch Complete!"
echo "=========================================="
echo ""
echo "Connector Status:"
echo "  LogMiner:  RUNNING"
echo "  XStream:   STOPPED"
echo ""
echo "Active topic prefix: oracle-logminer.*"
echo ""
echo "To switch back to XStream:"
echo "  oc patch kafkaconnector oracle-logminer-connector -n ${NAMESPACE} --type merge -p '{\"spec\":{\"state\":\"stopped\"}}'"
echo "  oc patch kafkaconnector oracle-xstream-connector -n ${NAMESPACE} --type merge -p '{\"spec\":{\"state\":\"running\"}}'"
echo ""
