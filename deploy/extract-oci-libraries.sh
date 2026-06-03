#!/bin/bash
# Extract OCI native libraries from Oracle database pod

NAMESPACE="strimzi"
POD_LABEL="app=oracle-db"

echo "=== Extracting OCI Native Libraries from Oracle Pod ==="
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

# 2. Create local directory for OCI libraries
echo "Step 2: Creating local directory for OCI libraries..."
mkdir -p build/oci-libs
mkdir -p oci-libs-temp

echo ""
echo "Step 3: Finding OCI libraries in Oracle pod..."

# First, let's see what's available
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "find /opt/oracle -name '*.so' -o -name 'libociei.so' 2>/dev/null | head -20"

echo ""
echo "Step 4: Extracting core OCI libraries..."

# Core OCI libraries needed for XStreams
OCI_LIBS=(
    "libclntsh.so.19.1"
    "libclntshcore.so.19.1"
    "libons.so"
    "libociei.so"
    "libociicus.so"
    "libnnz19.so"
    "libocci.so.19.1"
)

# Try to find and copy each library
for lib in "${OCI_LIBS[@]}"; do
    echo "  Looking for ${lib}..."

    # Find the library path in the Oracle pod
    LIB_PATH=$(oc exec ${ORACLE_POD} -n ${NAMESPACE} -- bash -c "find /opt/oracle/product/19c/dbhome_1/lib -name '${lib}' 2>/dev/null | head -1")

    if [ -n "$LIB_PATH" ]; then
        echo "    Found: ${LIB_PATH}"
        oc cp ${NAMESPACE}/${ORACLE_POD}:${LIB_PATH} ./oci-libs-temp/${lib} 2>/dev/null

        if [ $? -eq 0 ]; then
            echo "    ✓ Copied ${lib}"
        else
            echo "    ✗ Failed to copy ${lib}"
        fi
    else
        echo "    ⚠ Not found: ${lib}"
    fi
done

echo ""
echo "Step 5: Extracting entire lib directory with actual files (not just symlinks)..."
echo "  This creates a ~2GB archive and will take 2-3 minutes..."

# Important: Use -h flag with tar to dereference symbolic links (copy actual files)
echo "  Creating tar archive in Oracle pod..."
oc exec ${ORACLE_POD} -n ${NAMESPACE} -- tar chzf /tmp/oci-libs.tar.gz -C /opt/oracle/product/19c/dbhome_1 lib 2>&1 &
TAR_PID=$!

# Show progress while tar is running
COUNT=0
while kill -0 $TAR_PID 2>/dev/null; do
    echo -n "."
    sleep 2
    COUNT=$((COUNT + 1))
    if [ $COUNT -gt 90 ]; then  # 3 minutes timeout
        echo ""
        echo "  ✗ Tar creation timed out after 3 minutes"
        kill $TAR_PID 2>/dev/null
        exit 1
    fi
done
wait $TAR_PID
TAR_EXIT=$?

echo ""
if [ $TAR_EXIT -eq 0 ]; then
    echo "  ✓ Created archive in pod (with dereferenced symlinks)"

    echo "  Copying archive from pod to local (2GB, ~1-2 minutes)..."
    oc cp ${NAMESPACE}/${ORACLE_POD}:/tmp/oci-libs.tar.gz ./oci-libs.tar.gz

    if [ $? -eq 0 ]; then
        ARCHIVE_SIZE=$(ls -lh oci-libs.tar.gz | awk '{print $5}')
        echo "  ✓ Copied archive to local (${ARCHIVE_SIZE})"

        echo "  Extracting archive..."
        # Extract to build/oci-libs
        tar xzf oci-libs.tar.gz -C ./build/oci-libs --strip-components=1
        echo "  ✓ Extracted to build/oci-libs/"

        # Cleanup
        echo "  Cleaning up..."
        oc exec ${ORACLE_POD} -n ${NAMESPACE} -- rm -f /tmp/oci-libs.tar.gz 2>/dev/null || true
        rm -f oci-libs.tar.gz
    else
        echo "  ✗ Failed to copy archive from pod"
        exit 1
    fi
else
    echo "  ✗ Failed to create tar archive in pod"
    exit 1
fi

echo ""
echo "Step 6: Verifying extracted libraries..."
ls -lh build/oci-libs/*.so* 2>/dev/null | head -20

echo ""
echo "Step 7: Creating symbolic links for version-agnostic names..."
cd build/oci-libs

# Create symlinks for common library names
ln -sf libclntsh.so.19.1 libclntsh.so 2>/dev/null
ln -sf libclntshcore.so.19.1 libclntshcore.so 2>/dev/null
ln -sf libocci.so.19.1 libocci.so 2>/dev/null

cd ../..

echo ""
echo "=== OCI Libraries Extracted ==="
echo "Location: build/oci-libs/"
echo "Total size:"
du -sh build/oci-libs/

echo ""
echo "Next steps:"
echo "  1. Review build/oci-libs/ contents"
echo "  2. Run: ./update-dockerfile-for-oci.sh"
echo "  3. Rebuild: ./download-dbz-oracle-xs-plugins.sh"
echo "  4. Build image: ./build-kafka-connect-dbz-oracle-xs-plugins.sh"
