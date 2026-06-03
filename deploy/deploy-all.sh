#!/bin/bash
# Complete automated deployment script for Debezium Oracle XStreams on OpenShift
set -e

NAMESPACE="strimzi"

echo "=========================================="
echo " Debezium Oracle XStreams Deployment"
echo "=========================================="
echo ""

# Step 1: Deploy Kafka and Console
echo "Step 1: Deploying Kafka Cluster and Console UI..."
./01-deploy-kafka.sh

# Step 2: Deploy Oracle Database
echo ""
echo "Step 2: Deploying Oracle Database..."
./02-deploy-oracle.sh

# Step 3: Build Kafka Connect
echo ""
echo "Step 3: Building Kafka Connect with OCI support..."
./03-build-kafka-connect.sh

# Step 4: Deploy Connector
echo ""
echo "Step 4: Deploying Oracle XStreams Connector..."
./04-deploy-connector.sh

echo ""
echo "=========================================="
echo " Deployment Complete!"
echo "=========================================="
echo ""
echo "Access points:"
echo "  Console UI: https://$(oc get route my-console -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo '<pending>')"
echo ""
echo "Monitor connector:"
echo "  oc get kafkaconnector -n ${NAMESPACE}"
echo "  oc logs -f debezium-connect-connect-0 -n ${NAMESPACE} | grep -i xstream"
echo ""
echo "Check topics:"
echo "  oc get kafkatopics -n ${NAMESPACE} | grep dbserver1"
