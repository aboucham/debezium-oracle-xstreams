#!/bin/bash
# Deploy Oracle Database with proper security permissions
set -e

NAMESPACE="strimzi"
SERVICE_ACCOUNT="oracle-sa"

echo "=== Step 2: Deploy Oracle Database ==="
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
oc apply -f oracle-complete.yaml

echo ""
echo "=== Oracle Database Deployment Initiated ==="
echo ""
echo "Wait for Oracle pod to be ready (3-5 minutes):"
echo "  oc get pods -n ${NAMESPACE} -w -l app=oracle-db"
echo ""
echo "Check deployment status:"
echo "  oc get deployment oracle-db -n ${NAMESPACE}"
echo ""
echo "Check logs:"
echo "  oc logs -f deployment/oracle-db -n ${NAMESPACE}"
echo ""
echo "Once running, verify service:"
echo "  oc get svc oracle-db -n ${NAMESPACE}"
