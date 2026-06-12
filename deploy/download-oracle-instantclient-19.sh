#!/bin/bash
# Download Oracle Instant Client 21.x for ojdbc11 21.15 compatibility
# Plus xstreams.jar from IC 19.x for Oracle Database 19c compatibility
set -e

echo "=== Downloading Oracle Instant Client 21.x + xstreams.jar from IC 19.x ==="
echo ""

# Configuration
INSTANT_CLIENT_VERSION="21.15.0.0.0"
INSTANT_CLIENT_VERSION_FOR_XSTREAM="19.24.0.0.0"
NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

# Create directories
echo "Step 1: Creating directory structure..."
rm -rf build/oracle-instantclient
mkdir -p build/oracle-instantclient/lib
mkdir -p build/oracle-instantclient/network/admin
mkdir -p build/plugins/debezium-oracle-connector

echo ""
echo "Step 2: Downloading Debezium Oracle Connector 3.4.3.Final-redhat-00001..."
cd build/plugins/debezium-oracle-connector
curl -sL https://maven.repository.redhat.com/ga/io/debezium/debezium-connector-oracle/3.4.3.Final-redhat-00001/debezium-connector-oracle-3.4.3.Final-redhat-00001-plugin.zip -o dbz-oracle.zip
unzip -q dbz-oracle.zip
rm dbz-oracle.zip
cd ../../..

echo "  ✓ Debezium Oracle Connector 3.4.3.Final-redhat-00001 downloaded"

echo ""
echo "Step 3: Downloading Oracle Instant Client 21.15 Basic package (for OCI driver)..."
echo "  Source: Oracle official download"
echo ""

# Download Instant Client Basic 21.15 for OCI driver compatibility with ojdbc11 21.15
INSTANT_CLIENT_21_URL="https://download.oracle.com/otn_software/linux/instantclient/2115000/instantclient-basic-linux.x64-21.15.0.0.0dbru.zip"

if [ ! -f "instantclient-basic-21.15.zip" ]; then
    echo "  Downloading Instant Client 21.15 Basic (~90MB)..."
    curl -L -o instantclient-basic-21.15.zip "${INSTANT_CLIENT_21_URL}" || {
        echo ""
        echo "  ⚠ Download failed. Please manually download from:"
        echo "  https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html"
        echo "  File: instantclient-basic-linux.x64-21.15.0.0.0dbru.zip"
        echo "  Save to: $(pwd)/instantclient-basic-21.15.zip"
        echo ""
        exit 1
    }
fi

echo "  ✓ Instant Client 21.15 Basic downloaded"

echo ""
echo "Step 4: Extracting Instant Client 21.15..."
unzip -q -o instantclient-basic-21.15.zip
mv instantclient_21_15/* build/oracle-instantclient/lib/
rmdir instantclient_21_15

echo "  ✓ Instant Client 21.15 extracted"

echo ""
echo "Step 4b: Downloading Oracle Instant Client 19.24 for xstreams.jar..."
echo "  (xstreams.jar must match Oracle Database version 19c, not JDBC driver)"
echo ""

# Download IC 19.24 just to get xstreams.jar
INSTANT_CLIENT_19_URL="https://download.oracle.com/otn_software/linux/instantclient/1924000/instantclient-basic-linux.x64-19.24.0.0.0dbru.zip"

if [ ! -f "instantclient-basic-19.24.zip" ]; then
    echo "  Downloading Instant Client 19.24 Basic for xstreams.jar..."
    curl -L -o instantclient-basic-19.24.zip "${INSTANT_CLIENT_19_URL}" || {
        echo ""
        echo "  ⚠ Download failed."
        exit 1
    }
fi

echo "  Extracting xstreams.jar from IC 19.24..."
unzip -q -o instantclient-basic-19.24.zip instantclient_19_24/xstreams.jar
mv instantclient_19_24/xstreams.jar build/oracle-instantclient/lib/xstreams.jar
rm -rf instantclient_19_24

echo "  ✓ xstreams.jar from IC 19.24 (for Oracle 19c compatibility)"

echo ""
echo "Step 5: Copying xstreams.jar to Debezium plugin directory..."
cp build/oracle-instantclient/lib/xstreams.jar build/plugins/debezium-oracle-connector/xstreams.jar

echo "  ✓ xstreams.jar (from IC 19.24) copied to plugin directory"

echo ""
echo "Step 6: Downloading Oracle JDBC Driver (ojdbc11 21.15.0.0)..."
# XStream requires ojdbc11 for getOCIHandles() support
curl -sL https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/21.15.0.0/ojdbc11-21.15.0.0.jar -o build/plugins/debezium-oracle-connector/ojdbc11.jar

echo "  ✓ ojdbc11 21.15.0.0 downloaded"

echo ""
echo "Step 7: Creating Dockerfile..."
cat > build/Dockerfile <<'EOF'
FROM registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0

USER root:root

# Install system dependencies required by Oracle Instant Client
# libaio: Required for OCI async I/O operations
# libnsl2: Provides libnsl.so.1 compatibility library (required by IC on RHEL 9)
RUN microdnf install -y libaio libnsl2 && microdnf clean all

# Create directory structure for Kafka Connect plugins
RUN mkdir -p /opt/kafka/plugins/

# Create Oracle Instant Client directory
RUN mkdir -p /opt/oracle/instantclient

# Copy Kafka Connect plugins (Debezium with ojdbc11.jar and xstreams.jar from IC 19.x)
COPY ./plugins/ /opt/kafka/plugins/

# Copy Oracle Instant Client 21.x structure (OCI libraries)
# This includes: lib/ (with libocijdbc21.so, libclntsh.so.21.1), network/admin/, etc.
# Note: xstreams.jar is from IC 19.x for Oracle 19c database compatibility
COPY ./oracle-instantclient/ /opt/oracle/instantclient/

# Create libnsl.so.1 symlink for Oracle IC compatibility
# RHEL 9 libnsl2 provides libnsl.so.3, but IC expects libnsl.so.1
RUN ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1

# No symlink needed for libocijdbc - IC 21.x provides libocijdbc21.so which matches ojdbc11 21.x

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
echo "Instant Client 21.x libraries (OCI driver):"
ls -lh build/oracle-instantclient/lib/*.so* | head -5
echo ""
echo "JDBC driver and xstreams.jar:"
ls -lh build/plugins/debezium-oracle-connector/*.jar
echo ""
echo "Configuration:"
echo "  - IC 21.x libraries for ojdbc11 21.15 OCI compatibility"
echo "  - xstreams.jar from IC 19.x for Oracle 19c database compatibility"
echo ""
echo "Dockerfile:"
ls -lh build/Dockerfile
echo ""
