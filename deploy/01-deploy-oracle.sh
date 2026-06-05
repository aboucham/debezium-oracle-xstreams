#!/bin/bash
# Deploy Oracle Database with proper security permissions
set -e

NAMESPACE="strimzi"
SERVICE_ACCOUNT="oracle-sa"

echo "=== Step 1: Deploy Oracle Database ==="
echo ""

# Check if in correct namespace
oc project ${NAMESPACE} 2>/dev/null || oc new-project ${NAMESPACE}

# Check if Quay pull secret exists
echo "Checking for Quay.io pull secret..."
if ! oc get secret quay-pull-secret -n ${NAMESPACE} &>/dev/null; then
    echo ""
    echo "⚠ Quay.io pull secret not found"
    echo "Please create the secret to pull Oracle database image:"
    echo ""
    echo "oc create secret docker-registry quay-pull-secret \\"
    echo "  --docker-server=quay.io \\"
    echo "  --docker-username=\"YOUR_USERNAME\" \\"
    echo "  --docker-password=\"YOUR_PASSWORD\" \\"
    echo "  --docker-email=\"your@email.com\" \\"
    echo "  -n ${NAMESPACE}"
    echo ""
    read -p "Press Enter after creating the secret, or Ctrl+C to cancel..."
fi

# Create service account
echo "Creating service account ${SERVICE_ACCOUNT}..."
oc create sa ${SERVICE_ACCOUNT} -n ${NAMESPACE} 2>/dev/null || echo "  Service account already exists"

# Grant anyuid SCC to service account
echo "Granting anyuid security context constraint..."
oc adm policy add-scc-to-user anyuid -z ${SERVICE_ACCOUNT} -n ${NAMESPACE} 2>/dev/null || echo "  SCC already granted"

# Verify SCC
echo "Verifying SCC permissions..."
if oc adm policy who-can use scc anyuid -n ${NAMESPACE} | grep -q "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"; then
    echo "  ✓ anyuid SCC granted to ${SERVICE_ACCOUNT}"
else
    echo "  ✗ Failed to grant anyuid SCC"
    exit 1
fi

# Deploy Oracle database
echo ""
echo "Deploying Oracle database..."
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/oracle-complete.yaml

echo ""
echo "Waiting for Oracle pod to be Running..."
ORACLE_POD=""
for i in {1..60}; do
    ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l app=oracle-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ORACLE_POD" ]; then
        POD_STATUS=$(oc get pod ${ORACLE_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$POD_STATUS" = "Running" ]; then
            echo "✓ Oracle pod ${ORACLE_POD} is Running"
            break
        fi
        echo "  Pod status: ${POD_STATUS} (attempt ${i}/60)"
    else
        echo "  Waiting for pod to be created... (${i}/60)"
    fi
    sleep 5
done

if [ -z "$ORACLE_POD" ] || [ "$POD_STATUS" != "Running" ]; then
    echo "✗ Oracle pod not running after 5 minutes"
    exit 1
fi

echo ""
echo "=== Oracle Pod Deployed and Running ==="
echo ""
echo "⚠ NOTE: Database is initializing in the background (3-5 minutes)"
echo "The pod is running but the database is NOT ready yet."
echo ""
echo "You can continue with the next steps while Oracle initializes."
echo ""
echo "To check database initialization progress:"
echo "  oc logs -f ${ORACLE_POD} -n ${NAMESPACE}"
echo ""
echo "Look for this message to confirm database is ready:"
echo "  'DATABASE IS READY TO USE!'"
