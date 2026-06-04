#!/bin/bash
# Complete automated deployment script for Debezium Oracle XStreams on OpenShift
set -e

NAMESPACE="strimzi"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy"

echo "=========================================="
echo " Debezium Oracle XStreams Deployment"
echo "=========================================="
echo ""

# Detect if running locally or remotely
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -f "${SCRIPT_DIR}/01-deploy-kafka.sh" ]; then
    echo "Running in LOCAL mode (scripts found in ${SCRIPT_DIR})"
    EXEC_MODE="local"
else
    echo "Running in REMOTE mode (downloading scripts from GitHub)"
    EXEC_MODE="remote"
fi
echo ""

# Function to execute a script (local or remote)
exec_script() {
    local script_name=$1
    local step_description=$2

    echo "${step_description}"

    if [ "$EXEC_MODE" = "local" ]; then
        # Execute local script
        bash "${SCRIPT_DIR}/${script_name}"
    else
        # Download and execute remote script
        bash <(curl -s "${GITHUB_RAW_BASE}/${script_name}")
    fi
}

# Step 1: Deploy Kafka and Console
exec_script "01-deploy-kafka.sh" "Step 1: Deploying Kafka Cluster and Console UI..."

# Step 2: Deploy Oracle Database
echo ""
exec_script "02-deploy-oracle.sh" "Step 2: Deploying Oracle Database..."

# Step 3: Build Kafka Connect
echo ""
exec_script "03-build-kafka-connect.sh" "Step 3: Building Kafka Connect with Oracle Instant Client 21.x..."

# Step 4: Deploy Connector
echo ""
exec_script "04-deploy-connector.sh" "Step 4: Deploying Oracle XStreams Connector..."

echo ""
echo "=========================================="
echo " Deployment Complete!"
echo "=========================================="
echo ""
echo "Access points:"
CONSOLE_HOST=$(oc get route my-console -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo '<pending>')
echo "  Console UI: https://${CONSOLE_HOST}"
echo ""
echo "Monitor connector:"
echo "  oc get kafkaconnector -n ${NAMESPACE}"
echo "  oc logs -f debezium-connect-connect-0 -n ${NAMESPACE}"
echo ""
echo "Verify XStreams is working:"
KAFKA_POD=$(oc get pods -n ${NAMESPACE} -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$KAFKA_POD" ]; then
    echo "  oc exec -n ${NAMESPACE} ${KAFKA_POD} -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle"
fi
echo ""
