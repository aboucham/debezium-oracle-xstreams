#!/bin/bash
set -e

# Configuration
NAMESPACE="strimzi"
BUILD_NAME="debezium-connect"
BUILD_DIR="./build"

echo "=== Building Debezium Kafka Connect Image ==="

# Verify build directory exists
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory '$BUILD_DIR' not found"
    echo "Please run ./download-dbz-oracle-xs-plugins.sh first"
    exit 1
fi

# Verify Dockerfile exists
if [ ! -f "$BUILD_DIR/Dockerfile" ]; then
    echo "Error: Dockerfile not found in '$BUILD_DIR'"
    echo "Please run ./download-dbz-oracle-xs-plugins.sh first"
    exit 1
fi

echo "Build directory: $BUILD_DIR"
echo "Build context size:"
du -sh $BUILD_DIR

echo ""
echo "Checking prerequisites..."

# Check if Red Hat registry pull secret exists
if ! oc get secret registry-redhat-io -n ${NAMESPACE} &>/dev/null; then
    echo ""
    echo "❌ Error: Red Hat registry pull secret not found!"
    echo ""
    echo "The secret 'registry-redhat-io' is required to pull images from registry.redhat.io"
    echo ""
    echo "To create the secret, run:"
    echo ""
    echo "  oc create secret docker-registry registry-redhat-io \\"
    echo "    --docker-server=registry.redhat.io \\"
    echo "    --docker-username=YOUR_REDHAT_USERNAME \\"
    echo "    --docker-password=YOUR_REDHAT_PASSWORD \\"
    echo "    --docker-email=YOUR_EMAIL \\"
    echo "    -n ${NAMESPACE}"
    echo ""
    echo "Get your Red Hat credentials from: https://access.redhat.com/terms-based-registry/"
    echo ""
    exit 1
fi

echo "✓ Red Hat registry pull secret exists"

# 1. Create the base tracking ImageStream reference inside OpenShift
echo ""
echo "Step 1: Creating ImageStream..."
oc create imagestream ${BUILD_NAME} -n ${NAMESPACE} 2>/dev/null || echo "ImageStream already exists, skipping..."

# 2. Instantiate a naked build definition configuration framework tagged as a binary engine
echo ""
echo "Step 2: Creating BuildConfig..."
oc new-build --binary --name=${BUILD_NAME} -l app=${BUILD_NAME} -n ${NAMESPACE} 2>/dev/null || echo "BuildConfig already exists, skipping..."

# 3. Patch the strategies map to instruct OpenShift to evaluate our literal local Dockerfile text rules
echo ""
echo "Step 3: Configuring Docker build strategy..."
oc patch bc/${BUILD_NAME} -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"Dockerfile"}}}}' -n ${NAMESPACE}

# 4. Bind your pull secrets to allow OpenShift to read from registry.redhat.io
echo ""
echo "Step 4: Configuring Red Hat registry pull secret..."
oc set build-secret --pull bc/${BUILD_NAME} registry-redhat-io -n ${NAMESPACE}

# 5. Package the local directory path stream payload up to the active runtime compilation engine
echo ""
echo "Step 5: Starting build (uploading from ${BUILD_DIR})..."
echo "This may take a few minutes..."

# Start the build without --follow first to get the build name
BUILD_OUTPUT=$(oc start-build ${BUILD_NAME} --from-dir=${BUILD_DIR} -n ${NAMESPACE} 2>&1)
BUILD_ID=$(echo "$BUILD_OUTPUT" | grep -o "${BUILD_NAME}-[0-9]*" | head -1)

if [ -z "$BUILD_ID" ]; then
    echo "Error: Failed to start build or couldn't parse build ID"
    echo "Output: $BUILD_OUTPUT"
    exit 1
fi

echo "Upload complete!"
echo "Build started: ${BUILD_ID}"
echo "Waiting for build to start (timeout: 2 minutes)..."

# Wait for build to start with a reasonable timeout
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    BUILD_PHASE=$(oc get build ${BUILD_ID} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)

    case "$BUILD_PHASE" in
        "New"|"Pending")
            echo -n "."
            sleep 5
            ELAPSED=$((ELAPSED + 5))
            ;;
        "Running")
            echo ""
            echo "Build is running, following logs..."
            oc logs -f build/${BUILD_ID} -n ${NAMESPACE}
            break
            ;;
        "Complete")
            echo ""
            echo "Build completed successfully!"
            break
            ;;
        "Failed"|"Error"|"Cancelled")
            echo ""
            echo "Build failed with phase: ${BUILD_PHASE}"
            echo "Build logs:"
            oc logs build/${BUILD_ID} -n ${NAMESPACE}
            exit 1
            ;;
        *)
            echo ""
            echo "Unknown build phase: ${BUILD_PHASE}"
            ;;
    esac
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "Warning: Build did not start within ${TIMEOUT} seconds"
    echo "Current build status:"
    oc get build ${BUILD_ID} -n ${NAMESPACE}
    echo ""
    echo "You can:"
    echo "  1. Check build status: oc get build ${BUILD_ID} -n ${NAMESPACE}"
    echo "  2. View build logs: oc logs -f build/${BUILD_ID} -n ${NAMESPACE}"
    echo "  3. Run troubleshooting: ./troubleshoot-build.sh"
    echo "  4. Cancel and retry: oc cancel-build ${BUILD_ID} -n ${NAMESPACE} && ./build-kafka-connect-dbz-oracle-xs-plugins.sh"
    exit 1
fi

# Check final build status
FINAL_PHASE=$(oc get build ${BUILD_ID} -n ${NAMESPACE} -o jsonpath='{.status.phase}')
if [ "$FINAL_PHASE" = "Complete" ]; then
    echo ""
    echo "=== Build complete ==="
    echo "Build ID: ${BUILD_ID}"
    echo "Image: image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/${BUILD_NAME}:latest"
    echo ""
    echo "Next step: oc apply -f kafka-connect.yaml"
else
    echo ""
    echo "Build finished with status: ${FINAL_PHASE}"
    echo "Check logs with: oc logs build/${BUILD_ID} -n ${NAMESPACE}"
    exit 1
fi