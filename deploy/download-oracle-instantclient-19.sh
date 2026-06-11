#!/bin/bash
# Download Oracle Instant Client 19.x to match Oracle 19c database
set -e

echo "=== Downloading Oracle Instant Client 19.x for XStream Support ==="
echo ""

# Configuration
INSTANT_CLIENT_VERSION="19.24.0.0.0"
NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

# Create directories
echo "Step 1: Creating directory structure..."
rm -rf build/oracle-instantclient
mkdir -p build/oracle-instantclient/lib
mkdir -p build/oracle-instantclient/network/admin
mkdir -p build/plugins/debezium-oracle-connector

echo ""
echo "Step 2: Downloading Debezium Oracle Connector 3.4.3.Final..."
cd build/plugins/debezium-oracle-connector
curl -sL https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/3.4.3.Final/debezium-connector-oracle-3.4.3.Final-plugin.tar.gz -o dbz-oracle.tar.gz
tar -xzf dbz-oracle.tar.gz
rm dbz-oracle.tar.gz
cd ../../..

echo "  ✓ Debezium Oracle Connector 3.4.3.Final downloaded"

echo ""
echo "Step 3: Downloading Oracle Instant Client 19.24 Basic package..."
echo "  Source: Oracle official download"
echo ""

# Download Instant Client Basic 19.24
INSTANT_CLIENT_URL="https://download.oracle.com/otn_software/linux/instantclient/1924000/instantclient-basic-linux.x64-19.24.0.0.0dbru.zip"

if [ ! -f "instantclient-basic-19.24.zip" ]; then
    echo "  Downloading Instant Client Basic (~82MB)..."
    curl -L -o instantclient-basic-19.24.zip "${INSTANT_CLIENT_URL}" || {
        echo ""
        echo "  ⚠ Download failed. Please manually download from:"
        echo "  https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html"
        echo "  File: instantclient-basic-linux.x64-19.24.0.0.0dbru.zip"
        echo "  Save to: $(pwd)/instantclient-basic-19.24.zip"
        echo ""
        exit 1
    }
fi

echo "  ✓ Instant Client Basic downloaded"

echo ""
echo "Step 4: Extracting Instant Client..."
unzip -q -o instantclient-basic-19.24.zip
mv instantclient_19_24/* build/oracle-instantclient/lib/
rmdir instantclient_19_24

echo "  ✓ Instant Client extracted"

echo ""
echo "Step 5: Copying Oracle libraries from database pod..."

# Get Oracle pod
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l ${POD_LABEL} -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ORACLE_POD" ]; then
    echo "Error: No Oracle database pod found"
    exit 1
fi

echo "  Oracle pod: ${ORACLE_POD}"

# Copy libnsl (required on RHEL 9)
echo "  Copying libnsl..."
oc cp ${NAMESPACE}/${ORACLE_POD}:/lib64/libnsl.so.1 build/oracle-instantclient/lib/libnsl.so.1 2>/dev/null || \
oc cp ${NAMESPACE}/${ORACLE_POD}:/usr/lib64/libnsl.so.1 build/oracle-instantclient/lib/libnsl.so.1 2>/dev/null || \
echo "  Note: libnsl not found in Oracle pod, will use system library"

# Copy xstreams.jar from Instant Client package
echo "  Copying xstreams.jar from Instant Client..."
cp build/oracle-instantclient/lib/xstreams.jar build/plugins/debezium-oracle-connector/xstreams.jar

echo "  ✓ xstreams.jar copied from IC 19"

echo ""
echo "Step 6: Downloading ojdbc11.jar (Debezium requirement)..."
curl -sL https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/21.15.0.0/ojdbc11-21.15.0.0.jar -o build/plugins/debezium-oracle-connector/ojdbc11.jar

echo "  ✓ ojdbc11.jar 21.15.0.0 downloaded"

echo ""
echo "Step 7: Creating Dockerfile..."
cat > build/Dockerfile <<'EOF'
FROM registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0

USER root:root

# Install system dependencies required by Oracle Instant Client 19.x
# libaio: Required for OCI async I/O operations
# libnsl2: Provides libnsl.so.1 compatibility library (required by IC 19.x on RHEL 9)
RUN microdnf install -y libaio libnsl2 && microdnf clean all

# Create directory structure for Kafka Connect plugins
RUN mkdir -p /opt/kafka/plugins/

# Create Oracle Instant Client directory
RUN mkdir -p /opt/oracle/instantclient

# Copy Kafka Connect plugins (Debezium with ojdbc11.jar and xstreams.jar)
COPY ./plugins/ /opt/kafka/plugins/

# Copy Oracle Instant Client 19.x structure
# This includes: lib/, network/admin/, etc.
COPY ./oracle-instantclient/ /opt/oracle/instantclient/

# Create libnsl.so.1 symlink for Oracle IC 19.x compatibility
# RHEL 9 libnsl2 provides libnsl.so.3, but IC 19.x expects libnsl.so.1
RUN ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1

# Set Oracle environment variables
ENV ORACLE_HOME=/opt/oracle/instantclient
ENV TNS_ADMIN=/opt/oracle/instantclient/network/admin
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient/lib:$LD_LIBRARY_PATH
ENV NLS_LANG=AMERICAN_AMERICA.AL32UTF8

# Set file permissions
RUN chmod -R 755 /opt/kafka/plugins/ && \
    chmod -R 755 /opt/oracle/instantclient/

# Switch back to unprivileged user
USER 1001
EOF

echo "  ✓ Dockerfile created"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Debezium connector:"
ls -lh build/plugins/debezium-oracle-connector/debezium-connector-oracle/*.jar | head -3
echo ""
echo "Instant Client libraries:"
ls -lh build/oracle-instantclient/lib/*.so* | head -5
echo ""
echo "JDBC drivers:"
ls -lh build/plugins/debezium-oracle-connector/*.jar 2>/dev/null || echo "  (in debezium-connector-oracle directory)"
echo ""
echo "Dockerfile:"
ls -lh build/Dockerfile
echo ""
