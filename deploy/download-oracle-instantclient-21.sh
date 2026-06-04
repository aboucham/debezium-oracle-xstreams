#!/bin/bash
# Download Oracle Instant Client 21.x and ojdbc11 for Debezium 3.4 XStream support
# Reference: https://debezium.io/documentation/reference/3.4/connectors/oracle.html

set -e

echo "=== Downloading Oracle Instant Client 21.x for XStream Support ==="
echo ""

# Configuration
INSTANT_CLIENT_VERSION="21.15.0.0.0"
JDBC_VERSION="21.15.0.0"
NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

# Create directories
echo "Step 1: Creating directory structure..."
rm -rf build/oracle-instantclient
mkdir -p build/oracle-instantclient/lib
mkdir -p build/oracle-instantclient/network/admin
mkdir -p build/plugins/debezium-oracle-connector

echo ""
echo "Step 2: Downloading Oracle Instant Client 21.15 Basic package..."
echo "  Source: Oracle official download (requires acceptance of Oracle license)"
echo ""

# Download Instant Client Basic
INSTANT_CLIENT_URL="https://download.oracle.com/otn_software/linux/instantclient/2115000/instantclient-basic-linux.x64-21.15.0.0.0dbru.zip"

if [ ! -f "instantclient-basic-21.15.zip" ]; then
    echo "  Downloading Instant Client Basic (~85MB)..."
    curl -L -o instantclient-basic-21.15.zip "${INSTANT_CLIENT_URL}" || {
        echo ""
        echo "  ⚠ Automatic download may require Oracle account authentication."
        echo ""
        echo "  Please manually download from:"
        echo "  https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html"
        echo "  File: instantclient-basic-linux.x64-21.15.0.0.0dbru.zip"
        echo "  Save to: $(pwd)/instantclient-basic-21.15.zip"
        echo ""
        exit 1
    }
fi

echo "  ✓ Instant Client Basic downloaded"

echo ""
echo "Step 3: Extracting Instant Client..."
# Extract to current directory for reliable path handling
unzip -q instantclient-basic-21.15.zip
IC_DIR=$(ls -d instantclient_21_* 2>/dev/null | head -1)

if [ -z "$IC_DIR" ]; then
    echo "  ✗ Failed to find extracted Instant Client directory"
    exit 1
fi

echo "  Extracted to: ${IC_DIR}"

# Copy libraries
echo "  Copying libraries..."
cp -r ${IC_DIR}/* build/oracle-instantclient/lib/
echo "  ✓ Libraries copied"

# Clean up
rm -rf ${IC_DIR}
echo "  ✓ Cleaned up extracted directory"

echo ""
echo "Step 4: Downloading JDBC driver ojdbc11 ${JDBC_VERSION}..."
curl -sL "https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/${JDBC_VERSION}/ojdbc11-${JDBC_VERSION}.jar" \
    -o build/plugins/debezium-oracle-connector/ojdbc11.jar
echo "  ✓ ojdbc11 ${JDBC_VERSION} downloaded ($(ls -lh build/plugins/debezium-oracle-connector/ojdbc11.jar | awk '{print $5}'))"

echo ""
echo "Step 5: Extracting xstreams.jar from Oracle 19c pod..."
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l ${POD_LABEL} -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ORACLE_POD" ]; then
    echo "  ✗ No Oracle database pod found with label ${POD_LABEL}"
    exit 1
fi

echo "  Found Oracle pod: ${ORACLE_POD}"
oc cp ${NAMESPACE}/${ORACLE_POD}:/opt/oracle/product/19c/dbhome_1/rdbms/jlib/xstreams.jar \
    build/plugins/debezium-oracle-connector/xstreams.jar
echo "  ✓ xstreams.jar extracted ($(ls -lh build/plugins/debezium-oracle-connector/xstreams.jar | awk '{print $5}'))"

echo ""
echo "Step 6: Downloading message files from Oracle pod..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c \
    "cd /opt/oracle/product/19c/dbhome_1 && tar czf /tmp/oracle-mesg.tar.gz \$(find network/mesg oracore/mesg rdbms/mesg -name '*us.*' 2>/dev/null)"

oc cp ${NAMESPACE}/${ORACLE_POD}:/tmp/oracle-mesg.tar.gz ./oracle-mesg.tar.gz
tar xzf oracle-mesg.tar.gz -C build/oracle-instantclient/lib/
rm -f oracle-mesg.tar.gz

# Clean up in pod
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- rm -f /tmp/oracle-mesg.tar.gz

echo "  ✓ Message files extracted"

echo ""
echo "Step 7: Extracting libnsl from Oracle pod (required for RHEL 9)..."
echo "  Oracle pod runs RHEL 8 with libnsl.so.1, which Oracle OCI requires"
echo "  RHEL 9 only has libnsl.so.3, so we extract libnsl.so.1 from the pod"
oc cp ${NAMESPACE}/${ORACLE_POD}:/lib64/libnsl-2.17.so ./libnsl-2.17.so
cp libnsl-2.17.so build/oracle-instantclient/lib/
cd build/oracle-instantclient/lib
ln -sf libnsl-2.17.so libnsl.so.1
ln -sf libnsl.so.1 libnsl.so
cd ../../..
rm -f libnsl-2.17.so
echo "  ✓ libnsl libraries extracted and symlinks created"

echo ""
echo "Step 8: Creating TNS configuration files..."
cat > build/oracle-instantclient/network/admin/tnsnames.ora << 'EOF'
ORCLCDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle-db)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ORCLCDB)
    )
  )
EOF

cat > build/oracle-instantclient/network/admin/sqlnet.ora << 'EOF'
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT)
SQLNET.ALLOWED_LOGON_VERSION_SERVER=8
SQLNET.ALLOWED_LOGON_VERSION_CLIENT=8
EOF

echo "  ✓ Created tnsnames.ora and sqlnet.ora"

echo ""
echo "Step 9: Downloading Debezium components..."
cd build/plugins/debezium-oracle-connector

echo "  Downloading Debezium Oracle connector 3.4.3..."
curl -sL https://maven.repository.redhat.com/ga/io/debezium/debezium-connector-oracle/3.4.3.Final-redhat-00001/debezium-connector-oracle-3.4.3.Final-redhat-00001-plugin.zip \
    -o dbz-oracle.zip && unzip -q dbz-oracle.zip && rm dbz-oracle.zip
echo "  ✓ Debezium Oracle connector downloaded"

echo "  Downloading Debezium scripting support..."
curl -sL https://maven.repository.redhat.com/ga/io/debezium/debezium-scripting/3.4.3.Final-redhat-00001/debezium-scripting-3.4.3.Final-redhat-00001.zip \
    -o dbz-script.zip && unzip -q dbz-script.zip && rm dbz-script.zip
echo "  ✓ Debezium scripting support downloaded"

echo "  Downloading Groovy runtime libraries..."
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy/3.0.11/groovy-3.0.11.jar -O
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy-jsr223/3.0.11/groovy-jsr223-3.0.11.jar -O
curl -sL https://repo1.maven.org/maven2/org/codehaus/groovy/groovy-json/3.0.19/groovy-json-3.0.19.jar -O
echo "  ✓ Groovy libraries downloaded"

cd ../../..

echo ""
echo "Step 10: Creating Dockerfile..."
cat > build/Dockerfile <<'EOF'
FROM registry.redhat.io/amq-streams/kafka-42-rhel9:3.2.0

USER root:root

# Install system dependencies required by Oracle Instant Client 21.x
# Note: libnsl is not available in RHEL 9, we provide it from Oracle pod (RHEL 8)
RUN microdnf install -y libaio && microdnf clean all

# Create directory structure
RUN mkdir -p /opt/kafka/plugins/
RUN mkdir -p /opt/oracle/instantclient

# Copy Kafka Connect plugins (Debezium, JDBC drivers, etc.)
COPY ./plugins/ /opt/kafka/plugins/

# Copy Oracle Instant Client 21.x
COPY ./oracle-instantclient/ /opt/oracle/instantclient/

# Copy libnsl from Oracle Instant Client to system lib (Oracle OCI requires libnsl.so.1 from RHEL 8)
RUN cp -P /opt/oracle/instantclient/lib/libnsl* /usr/lib64/

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

echo "  ✓ Dockerfile created with Oracle Instant Client 21.x support"

echo ""
echo "=== Download Complete ==="
echo ""
echo "Summary:"
echo "  Oracle Instant Client: 21.15.0.0"
echo "  JDBC Driver: ojdbc11 ${JDBC_VERSION}"
echo "  XStreams: Extracted from Oracle 19c pod"
echo "  Debezium: 3.4.3.Final-redhat-00001"
echo ""
echo "Directory sizes:"
du -sh build/oracle-instantclient build/plugins
echo ""
echo "Total build size:"
du -sh build/
echo ""
echo "Next step: ./deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh"
