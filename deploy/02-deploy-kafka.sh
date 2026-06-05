#!/bin/bash
# Deploy Kafka cluster and Console UI
set -e

NAMESPACE="strimzi"
KAFKA_CR_NAME="kafka-cluster"
KAFKA_LISTENER_NAME="plain"

echo "=== Step 2: Deploy Kafka Cluster and Console UI ==="
echo ""

# Create namespace
echo "Creating namespace ${NAMESPACE}..."
oc new-project ${NAMESPACE} 2>/dev/null || oc project ${NAMESPACE}

# Deploy Kafka cluster
echo "Deploying Kafka cluster (KRaft mode)..."
oc apply -f https://raw.githubusercontent.com/aboucham/strimzi-kafka-tutorial/refs/heads/main/kafka/kafka-cluster-kraft-full.yaml

# Enable auto-create topics for Debezium connector
echo "Enabling auto-create topics..."
sleep 2  # Give the operator a moment to process the Kafka CR
oc patch kafka kafka-cluster -n ${NAMESPACE} --type merge -p '{"spec":{"kafka":{"config":{"auto.create.topics.enable":"true"}}}}' || echo "  Will retry after Kafka is ready"

# Auto-detect OpenShift cluster domain
echo ""
echo "Auto-detecting OpenShift cluster domain..."
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)

if [ -z "$CLUSTER_DOMAIN" ]; then
    echo "⚠ Could not auto-detect cluster domain"
    echo "Please enter your OpenShift cluster domain (e.g., apps.cluster.example.com):"
    read CLUSTER_DOMAIN
fi

export UI_CONSOLE_URL="my-console.${CLUSTER_DOMAIN}"

echo "Using Console URL: ${UI_CONSOLE_URL}"

# Deploy Console
echo "Deploying Kafka Console UI..."
cat <<EOF | envsubst | oc apply -f -
apiVersion: console.streamshub.github.com/v1alpha1
kind: Console
metadata:
  name: my-console
spec:
  hostname: ${UI_CONSOLE_URL}
  kafkaClusters:
    - name: ${KAFKA_CR_NAME}
      namespace: ${NAMESPACE}
      listener: ${KAFKA_LISTENER_NAME}
EOF

echo ""
echo "=== Kafka Cluster and Console Deployed ==="
echo ""
echo "Wait for Kafka pods to be ready (2-3 minutes):"
echo "  oc get pods -n ${NAMESPACE} -w -l strimzi.io/cluster=${KAFKA_CR_NAME}"
echo ""
echo "Console UI will be available at:"
echo "  https://${UI_CONSOLE_URL}"
echo ""
echo "Check Kafka status:"
echo "  oc get kafka ${KAFKA_CR_NAME} -n ${NAMESPACE}"
