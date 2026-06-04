#!/bin/bash
# Complete automated deployment script for Debezium Oracle XStreams on OpenShift
set -e

NAMESPACE="strimzi"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy"

echo "=========================================="
echo " Debezium Oracle XStreams Deployment"
echo "=========================================="
echo ""

# Verify required secrets exist before starting deployment
echo "Checking prerequisites..."
MISSING_SECRETS=0

if ! oc get secret registry-redhat-io -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "  ✗ Missing secret: registry-redhat-io"
    echo "    Required to pull AMQ Streams base image from registry.redhat.io"
    MISSING_SECRETS=1
else
    echo "  ✓ Secret registry-redhat-io exists"
fi

if ! oc get secret quay-pull-secret -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "  ✗ Missing secret: quay-pull-secret"
    echo "    Required to pull Oracle database image from quay.io"
    MISSING_SECRETS=1
else
    echo "  ✓ Secret quay-pull-secret exists"
fi

if [ $MISSING_SECRETS -eq 1 ]; then
    echo ""
    echo "ERROR: Required secrets are missing!"
    echo ""
    echo "Please create the missing secrets before running this script:"
    echo ""
    echo "# Create Red Hat registry pull secret"
    echo "oc create secret docker-registry registry-redhat-io \\"
    echo "  --docker-server=registry.redhat.io \\"
    echo "  --docker-username=YOUR_REDHAT_USERNAME \\"
    echo "  --docker-password=YOUR_REDHAT_PASSWORD \\"
    echo "  --docker-email=YOUR_EMAIL \\"
    echo "  -n ${NAMESPACE}"
    echo ""
    echo "# Create Quay.io pull secret"
    echo "oc create secret docker-registry quay-pull-secret \\"
    echo "  --docker-server=quay.io \\"
    echo "  --docker-username=YOUR_QUAY_USERNAME \\"
    echo "  --docker-password=YOUR_QUAY_PASSWORD \\"
    echo "  --docker-email=YOUR_EMAIL \\"
    echo "  -n ${NAMESPACE}"
    echo ""
    echo "For more information, see:"
    echo "https://github.com/aboucham/debezium-oracle-xstreams#required-secrets-create-before-deployment"
    exit 1
fi

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
