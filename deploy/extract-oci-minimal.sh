#!/bin/bash
# Extract minimal Oracle Instant Client for OCI driver
# This extracts only essential files (~400-500MB instead of 2.5GB)

NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

echo "=== Extracting Minimal Oracle Instant Client for OCI Driver ==="
echo ""

# 1. Auto-detect the Oracle database pod
echo "Step 1: Detecting Oracle database pod..."
ORACLE_POD=$(oc get pods -n ${NAMESPACE} -l ${POD_LABEL} -o jsonpath='{.items[0].metadata.name}')

if [ -z "$ORACLE_POD" ]; then
    echo "Error: No Oracle database pod found with label ${POD_LABEL}"
    exit 1
fi

echo "Found Oracle pod: ${ORACLE_POD}"
echo ""

# 2. Create directory structure
echo "Step 2: Creating directory structure..."
rm -rf build/oracle-instantclient
mkdir -p build/oracle-instantclient/lib
mkdir -p build/oracle-instantclient/network/admin
mkdir -p build/oracle-instantclient/network/mesg
mkdir -p build/oracle-instantclient/oracore/mesg
mkdir -p build/oracle-instantclient/rdbms/mesg
mkdir -p build/oracle-instantclient/nls/data

echo ""
echo "Step 3: Extracting essential OCI libraries..."
echo "This will take 2-3 minutes..."

# Create extraction script in the pod
cat > /tmp/extract-minimal.sh << 'EOF'
#!/bin/bash
# Run inside Oracle pod to extract minimal Instant Client

ORACLE_HOME=/opt/oracle/product/19c/dbhome_1
TARGET=/tmp/oracle-minimal

# Clean up any previous extraction
rm -rf ${TARGET}
mkdir -p ${TARGET}/lib
mkdir -p ${TARGET}/network/admin
mkdir -p ${TARGET}/network/mesg
mkdir -p ${TARGET}/oracore/mesg
mkdir -p ${TARGET}/rdbms/mesg
mkdir -p ${TARGET}/nls/data

echo "Extracting essential libraries..."
# Core OCI libraries (using -L to dereference symlinks)
cd ${ORACLE_HOME}/lib
cp -L libclntsh.so.* ${TARGET}/lib/ 2>/dev/null || true
cp -L libclntshcore.so.* ${TARGET}/lib/ 2>/dev/null || true
cp -L libocijdbc*.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libnnz*.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libocci.so.* ${TARGET}/lib/ 2>/dev/null || true
cp -L libociei.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libociicus.so ${TARGET}/lib/ 2>/dev/null || true
cp -L liboramysql*.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libaio.so* ${TARGET}/lib/ 2>/dev/null || true

# Copy libnsl from system lib (RHEL 8 Oracle pod has libnsl-2.17.so)
cp -L /lib64/libnsl*.so* ${TARGET}/lib/ 2>/dev/null || true

# Additional required libraries
cp -L libmql1.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libipc1.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libskgxp*.so.* ${TARGET}/lib/ 2>/dev/null || true
cp -L libskgxn2.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libocr*.so.* ${TARGET}/lib/ 2>/dev/null || true
cp -L libons.so ${TARGET}/lib/ 2>/dev/null || true
cp -L libclntsh.so ${TARGET}/lib/ 2>/dev/null || true

# Symlinks
cd ${TARGET}/lib
ln -sf libclntsh.so.19.1 libclntsh.so 2>/dev/null
ln -sf libclntshcore.so.19.1 libclntshcore.so 2>/dev/null
ln -sf libocci.so.19.1 libocci.so 2>/dev/null

echo "Extracting English message files..."
# Create tar archive of message files with simple bash globbing
cd ${ORACLE_HOME}
# Use ls and xargs to create tar - more reliable than complex find commands
ls network/mesg/*us.* 2>/dev/null | xargs tar rf /tmp/mesg.tar 2>/dev/null || true
ls oracore/mesg/*us.* 2>/dev/null | xargs tar rf /tmp/mesg.tar 2>/dev/null || true
ls rdbms/mesg/*us.* 2>/dev/null | xargs tar rf /tmp/mesg.tar 2>/dev/null || true
# Also add critical ora* message files
ls rdbms/mesg/oraus.* rdbms/mesg/lrmus.* 2>/dev/null | xargs tar rf /tmp/mesg.tar 2>/dev/null || true

# Extract the message tar to target
if [ -f /tmp/mesg.tar ]; then
    tar xf /tmp/mesg.tar -C ${TARGET} 2>/dev/null || true
    rm -f /tmp/mesg.tar
fi

echo "Extracting essential NLS data files..."
# Essential NLS data files (AL32UTF8 character set and common ones)
cp ${ORACLE_HOME}/nls/data/lx*0001.nlb ${TARGET}/nls/data/ 2>/dev/null || true
cp ${ORACLE_HOME}/nls/data/lx*00e2.nlb ${TARGET}/nls/data/ 2>/dev/null || true
cp ${ORACLE_HOME}/nls/data/lx1boot.nlb ${TARGET}/nls/data/ 2>/dev/null || true

echo "Creating TNS admin directory structure..."
mkdir -p ${TARGET}/network/admin

echo "Creating archive..."
cd /tmp
tar czf oracle-minimal.tar.gz oracle-minimal/

echo "Extraction complete. Archive size:"
ls -lh oracle-minimal.tar.gz
EOF

# Copy script to pod and execute
echo "  Uploading extraction script to pod..."
oc cp /tmp/extract-minimal.sh ${NAMESPACE}/${ORACLE_POD}:/tmp/extract-minimal.sh

echo "  Running extraction in pod..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash /tmp/extract-minimal.sh

if [ $? -ne 0 ]; then
    echo "  ✗ Extraction failed in pod"
    exit 1
fi

echo ""
echo "Step 4: Copying archive from pod..."
oc cp ${NAMESPACE}/${ORACLE_POD}:/tmp/oracle-minimal.tar.gz ./oracle-minimal.tar.gz

if [ $? -ne 0 ]; then
    echo "  ✗ Failed to copy archive from pod"
    exit 1
fi

ARCHIVE_SIZE=$(ls -lh oracle-minimal.tar.gz | awk '{print $5}')
echo "  ✓ Downloaded archive (${ARCHIVE_SIZE})"

echo ""
echo "Step 5: Extracting archive locally..."
tar xzf oracle-minimal.tar.gz
mv oracle-minimal/* build/oracle-instantclient/
rmdir oracle-minimal
rm -f oracle-minimal.tar.gz

echo ""
echo "Step 6: Creating TNS configuration files..."
cat > build/oracle-instantclient/network/admin/tnsnames.ora << 'EOFTNS'
ORCLCDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = oracle-db)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ORCLCDB)
    )
  )
EOFTNS

cat > build/oracle-instantclient/network/admin/sqlnet.ora << 'EOFSQL'
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT)
SQLNET.ALLOWED_LOGON_VERSION_SERVER=8
SQLNET.ALLOWED_LOGON_VERSION_CLIENT=8
EOFSQL

echo "  ✓ Created tnsnames.ora and sqlnet.ora"

echo ""
echo "Step 7: Cleaning up temporary files in pod..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- rm -rf /tmp/oracle-minimal /tmp/oracle-minimal.tar.gz /tmp/extract-minimal.sh 2>/dev/null || true

echo ""
echo "Step 8: Verifying extracted structure..."
echo ""
echo "Directory structure:"
find build/oracle-instantclient -type d | head -20

echo ""
echo "Essential libraries:"
ls -lh build/oracle-instantclient/lib/*.so* 2>/dev/null | head -10

echo ""
echo "Message files:"
echo "  Network: $(ls build/oracle-instantclient/network/mesg/*us.* 2>/dev/null | wc -l) files"
echo "  Oracore: $(ls build/oracle-instantclient/oracore/mesg/*us.* 2>/dev/null | wc -l) files"
echo "  RDBMS: $(ls build/oracle-instantclient/rdbms/mesg/*us.* 2>/dev/null | wc -l) files"

echo ""
echo "Total size:"
du -sh build/oracle-instantclient/

echo ""
echo "=== Minimal Oracle Instant Client Extracted ==="
echo ""
echo "Next steps:"
echo "  1. Run: ./deploy/download-dbz-oracle-xs-plugins.sh"
echo "  2. Build image: ./deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh"
