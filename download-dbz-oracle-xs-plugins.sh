#!/bin/bash
set -e

# Configuration
NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

echo "=== Step 1: Extract Oracle JDBC and XStreams drivers from database pod ==="

# 1.1. Automatically detect the Oracle database pod using label selector
echo "Detecting Oracle database pod using label ${POD_LABEL}..."
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l ${POD_LABEL} -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ORACLE_POD" ]; then
    echo "Error: No Oracle database pod found with label ${POD_LABEL} in namespace ${NAMESPACE}"
    echo "Please verify the pod is running: oc get pods -n ${NAMESPACE} -l ${POD_LABEL}"
    exit 1
fi

echo "Found Oracle pod: ${ORACLE_POD}"

# 1.2. Download the native xstreams.jar file directly from the database pod
echo "Downloading xstreams.jar..."
oc cp ${NAMESPACE}/${ORACLE_POD}:/opt/oracle/product/19c/dbhome_1/rdbms/jlib/xstreams.jar ./xstreams.jar

if [ $? -eq 0 ]; then
    echo "✓ xstreams.jar downloaded successfully"
else
    echo "✗ Failed to download xstreams.jar"
    exit 1
fi

# 1.3. Download the official matching ojdbc8.jar file from the database pod
echo "Downloading ojdbc8.jar..."
oc cp ${NAMESPACE}/${ORACLE_POD}:/opt/oracle/product/19c/dbhome_1/jdbc/lib/ojdbc8.jar ./ojdbc8.jar

if [ $? -eq 0 ]; then
    echo "✓ ojdbc8.jar downloaded successfully"
else
    echo "✗ Failed to download ojdbc8.jar"
    exit 1
fi

echo ""
echo "=== Step 2: Download Debezium components and dependencies ==="

# 2.1. Establish your local workspace folder tree structures inside build directory
echo "Creating build directory structure..."
mkdir -p build/plugins/debezium-oracle-connector
cd build/plugins/debezium-oracle-connector

# 2.2. Extract the core Red Hat Build of Debezium Oracle Engine components directly over the network
echo "Downloading Debezium Oracle connector..."
curl -sL https://maven.repository.redhat.com/ga/io/debezium/debezium-connector-oracle/3.4.3.Final-redhat-00001/debezium-connector-oracle-3.4.3.Final-redhat-00001-plugin.zip -o dbz-oracle.zip && unzip -q dbz-oracle.zip && rm dbz-oracle.zip
echo "✓ Debezium Oracle connector downloaded"

# 2.3. Pull down the supplementary Debezium Scripting Engine layer
echo "Downloading Debezium scripting support..."
curl -sL https://maven.repository.redhat.com/ga/io/debezium/debezium-scripting/3.4.3.Final-redhat-00001/debezium-scripting-3.4.3.Final-redhat-00001.zip -o dbz-script.zip && unzip -q dbz-script.zip && rm dbz-script.zip
echo "✓ Debezium scripting support downloaded"

# 2.4. Fetch the foundational Groovy execution dependencies
echo "Downloading Groovy runtime libraries..."
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy/3.0.11/groovy-3.0.11.jar -O
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy-jsr223/3.0.11/groovy-jsr223-3.0.11.jar -O
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy-json/3.0.19/groovy-json-3.0.19.jar -O
echo "✓ Groovy libraries downloaded"

# 2.5. Bring in your verified database driver binaries from earlier steps
echo "Copying Oracle driver files..."
cp ../../../ojdbc8.jar ./
cp ../../../xstreams.jar ./
echo "✓ Oracle drivers copied"

# 2.6. Step back out to the base workspace directory root
cd ../../..

# 2.7. Create Dockerfile in build directory
echo "Creating Dockerfile in build directory..."

# Check if OCI libraries exist (for XStreams support)
if [ -d "build/oci-libs" ] && [ "$(ls -A build/oci-libs)" ]; then
    echo "✓ OCI libraries detected - creating Dockerfile with XStreams support"
    cat > build/Dockerfile <<'EOF'
FROM registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0

USER root:root

# Install system dependencies required by OCI libraries
# libnsl2 is required by libocijdbc19.so but not included by default in RHEL 9
RUN microdnf install -y libnsl2 && microdnf clean all

# Create the target directory path matching Strimzi expectations
RUN mkdir -p /opt/kafka/plugins/

# Create directory for OCI native libraries
RUN mkdir -p /opt/oracle/lib

# Copy the staged build layout artifacts recursively into the root plugin directory path
COPY ./plugins/ /opt/kafka/plugins/

# Copy OCI native libraries for XStreams support
COPY ./oci-libs/ /opt/oracle/lib/

# Set up library path for OCI
ENV LD_LIBRARY_PATH=/opt/oracle/lib:$LD_LIBRARY_PATH
ENV ORACLE_HOME=/opt/oracle

# Establish standard security file-system permissions for execution
RUN chmod -R 755 /opt/kafka/plugins/ && \
    chmod -R 755 /opt/oracle/lib/

# Pivot context parameters safely back onto the default Strimzi unprivileged system UID
USER 1001
EOF
    echo "✓ Dockerfile created with OCI/XStreams support (includes libnsl)"
else
    echo "⚠ OCI libraries not found - creating Dockerfile without XStreams support"
    echo "  For XStreams: run ./extract-oci-libraries.sh before this script"
    cat > build/Dockerfile <<'EOF'
FROM registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0

USER root:root

# Create the target directory path matching Strimzi expectations
RUN mkdir -p /opt/kafka/plugins/

# Copy the staged build layout artifacts recursively into the root plugin directory path
COPY ./plugins/ /opt/kafka/plugins/

# Establish standard security file-system permissions for execution
RUN chmod -R 755 /opt/kafka/plugins/

# Pivot context parameters safely back onto the default Strimzi unprivileged system UID
USER 1001
EOF
    echo "✓ Dockerfile created (LogMiner only, base image: registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0)"
fi

echo ""
echo "=== Plugin setup complete ==="
echo "Build directory structure:"
ls -lh build/plugins/debezium-oracle-connector/*.jar | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo "Next step: ./build-kafka-connect-dbz-oracle-xs-plugins.sh"