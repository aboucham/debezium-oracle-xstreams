#!/bin/bash
# Complete automated deployment script for Debezium Oracle XStreams on OpenShift
# This script continues through all steps even if individual steps encounter errors

NAMESPACE="strimzi"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy"

# Track deployment status
STEP_1_STATUS="pending"
STEP_2_STATUS="pending"
STEP_3_STATUS="pending"
STEP_4_STATUS="pending"

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

# Function to execute a script (local or remote) with error handling
exec_script() {
    local script_name=$1
    local step_num=$2
    local step_description=$3

    echo "=========================================="
    echo "${step_description}"
    echo "=========================================="
    echo ""

    if [ "$EXEC_MODE" = "local" ]; then
        # Execute local script
        bash "${SCRIPT_DIR}/${script_name}"
        local exit_code=$?
    else
        # Download and execute remote script
        bash <(curl -s "${GITHUB_RAW_BASE}/${script_name}")
        local exit_code=$?
    fi

    echo ""
    if [ $exit_code -eq 0 ]; then
        echo "✓ ${step_description} - COMPLETED"
        eval "STEP_${step_num}_STATUS=success"
    else
        echo "✗ ${step_description} - FAILED (exit code: $exit_code)"
        echo "  Continuing with next step..."
        eval "STEP_${step_num}_STATUS=failed"
    fi
    echo ""

    return 0  # Always return success to continue execution
}

# Step 1: Deploy Oracle Database (FIRST - initialize in background)
exec_script "01-deploy-oracle.sh" "1" "Step 1: Deploying Oracle Database"

# Step 2: Deploy Kafka and Console (while Oracle initializes)
exec_script "02-deploy-kafka.sh" "2" "Step 2: Deploying Kafka Cluster and Console UI"

# Step 3: Build Kafka Connect (while Oracle initializes)
exec_script "03-build-kafka-connect.sh" "3" "Step 3: Building Kafka Connect with Oracle Instant Client 19.x"

# Step 4: Deploy Connector
exec_script "04-deploy-connector.sh" "4" "Step 4: Deploying LogMiner Connector"

# Deployment Summary
echo ""
echo "=========================================="
echo " Deployment Summary"
echo "=========================================="
echo ""
echo "Step 1 - Oracle Database:      ${STEP_1_STATUS}"
echo "Step 2 - Kafka Cluster:        ${STEP_2_STATUS}"
echo "Step 3 - Build Kafka Connect:  ${STEP_3_STATUS}"
echo "Step 4 - Deploy Connector:     ${STEP_4_STATUS}"
echo ""

# Check if all steps succeeded
if [ "$STEP_1_STATUS" = "success" ] && [ "$STEP_2_STATUS" = "success" ] && [ "$STEP_3_STATUS" = "success" ] && [ "$STEP_4_STATUS" = "success" ]; then
    echo "=========================================="
    echo " ✓ All Steps Completed Successfully!"
    echo "=========================================="
    echo ""
    echo "Access points:"
    CONSOLE_HOST=$(oc get route my-console -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo '<pending>')
    echo "  Console UI: https://${CONSOLE_HOST}"
    echo ""
    echo "=========================================="
    echo " Deployment Complete! 🚀"
    echo "=========================================="
    echo ""

    # Check Oracle Database readiness
    echo "=========================================="
    echo " Checking Oracle Database Status"
    echo "=========================================="
    echo ""

    ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$ORACLE_POD" ]; then
        if oc logs ${ORACLE_POD} -n ${NAMESPACE} 2>/dev/null | grep -q "DATABASE IS READY TO USE!"; then
            echo "✓ Oracle Database is READY!"
            echo ""
            echo "Running post-deployment setup..."

            # Run oracle post-setup
            if [ "$EXEC_MODE" = "local" ]; then
                bash "${SCRIPT_DIR}/oracle-post-setup.sh"
            else
                bash <(curl -s "${GITHUB_RAW_BASE}/oracle-post-setup.sh")
            fi

            ORACLE_READY=true
        else
            echo "⏳ Oracle Database is still initializing..."
            echo ""
            echo "The database will be ready in approximately 2-3 more minutes."
            echo ""
            echo "To check progress:"
            echo "  oc logs -f ${ORACLE_POD} -n ${NAMESPACE}"
            echo ""
            echo "Look for: 'DATABASE IS READY TO USE!'"
            echo ""
            echo "Once ready, run this to complete setup:"
            if [ "$EXEC_MODE" = "local" ]; then
                echo "  ./deploy/oracle-post-setup.sh"
            else
                echo "  bash <(curl -s ${GITHUB_RAW_BASE}/oracle-post-setup.sh)"
            fi
            echo ""
            ORACLE_READY=false
        fi
    else
        echo "⚠ Could not check Oracle status"
        ORACLE_READY=false
    fi

    echo ""
    echo "=========================================="
    echo " Your Journey: From LogMiner to XStream"
    echo "=========================================="
    echo ""

    if [ "$ORACLE_READY" = "true" ]; then
        echo "STEP 1: Test LogMiner CDC (Ready to Start!)"
    else
        echo "STEP 1: Test LogMiner CDC (Wait for Oracle, then start)"
    fi
    echo "────────────────────────────────────────────────────────"
    echo "Create CUSTOMERS table and insert sample data:"
    echo ""
    echo "  See: https://github.com/aboucham/debezium-oracle-xstreams/blob/main/deploy/README.md#part-1-test-logminer-cdc-default"
    echo ""
    echo "Quick version:"
    echo "  → Create table with 3 sample rows"
    echo "  → Restart connector to trigger snapshot"
    echo "  → Verify 3 messages captured in Kafka"
    echo "  → Test real-time insert (ID 2001)"
    echo "  → Verify streaming works (~1-2 sec latency)"
    echo ""
    echo "✓ LogMiner CDC Working!"
    echo ""
    echo ""
    echo "STEP 2: Understand XStream Performance Benefits"
    echo "────────────────────────────────────────────────────────"
    echo "Performance Comparison:"
    echo ""
    echo "  LogMiner (Current):     50k events/sec,  1-2 sec latency"
    echo "  XStream (Upgrade):     100k+ events/sec, <100ms latency"
    echo ""
    echo "  → 2x throughput improvement"
    echo "  → 10-20x latency improvement"
    echo ""
    echo "See: https://github.com/aboucham/debezium-oracle-xstreams/blob/main/deploy/README.md#performance-comparison"
    echo ""
    echo ""
    echo "STEP 3: Manually Upgrade to XStream (Educational)"
    echo "────────────────────────────────────────────────────────"
    echo "Edit connector configuration to switch adapters:"
    echo ""
    echo "  oc edit kafkaconnector oracle-logminer-connector -n ${NAMESPACE}"
    echo ""
    echo "Change these 3 fields:"
    echo ""
    echo "  BEFORE (LogMiner):"
    echo "    database.connection.adapter: logminer"
    echo "    database.url: jdbc:oracle:thin:@..."
    echo ""
    echo "  AFTER (XStream):"
    echo "    database.connection.adapter: xstream"
    echo "    database.url: jdbc:oracle:oci:@(DESCRIPTION=...)"
    echo "    database.out.server.name: dbzxout"
    echo ""
    echo "Save and the connector will automatically restart."
    echo ""
    echo "Full instructions:"
    echo "  https://github.com/aboucham/debezium-oracle-xstreams/blob/main/deploy/README.md#part-2-upgrade-to-xstream-optional---2x-performance"
    echo ""
    echo ""
    echo "STEP 4: Test XStream Streaming"
    echo "────────────────────────────────────────────────────────"
    echo "After upgrade:"
    echo "  → Insert new record (ID 3001)"
    echo "  → Verify it appears in <100ms"
    echo "  → Compare with LogMiner latency"
    echo "  → See the performance improvement!"
    echo ""
    echo ""
    echo "=========================================="
    echo " Quick Links"
    echo "=========================================="
    echo ""
    echo "  Full Guide:     https://github.com/aboucham/debezium-oracle-xstreams/blob/main/deploy/README.md"
    echo "  Console UI:     https://${CONSOLE_HOST}"
    echo ""
    echo "  Connector Status:"
    echo "    oc get kafkaconnector oracle-logminer-connector -n ${NAMESPACE} -o jsonpath='{.status.connectorStatus.connector.state}'"
    echo ""
    echo "=========================================="
    echo ""
    exit 0
else
    echo "=========================================="
    echo " ⚠ Deployment Completed with Errors"
    echo "=========================================="
    echo ""
    echo "Some steps failed. Please review the logs above for details."
    echo ""
    echo "Check individual component status:"
    echo "  Kafka:         oc get kafka kafka-cluster -n ${NAMESPACE}"
    echo "  Oracle:        oc get pods -n ${NAMESPACE} -l app=oracle-db"
    echo "  Build:         oc get builds -n ${NAMESPACE}"
    echo "  Kafka Connect: oc get kafkaconnect -n ${NAMESPACE}"
    echo "  Connector:     oc get kafkaconnector -n ${NAMESPACE}"
    echo ""
    exit 1
fi
