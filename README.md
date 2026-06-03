# Debezium Oracle XStreams on OpenShift

Complete automated deployment of Debezium Oracle Connector with XStreams support on OpenShift using Strimzi Kafka.

## Overview

This project deploys a complete Change Data Capture (CDC) pipeline with:
- **Strimzi Kafka** (KRaft mode) - Event streaming platform  
- **Oracle Database 19c** - Source database with XStreams API enabled
- **Debezium Oracle Connector** - CDC connector using XStreams for high performance
- **Kafka Console UI** - Web interface for Kafka management

**XStreams** offers superior performance compared to LogMiner:
- **Throughput**: 100,000+ events/second (vs ~50,000 for LogMiner)
- **Latency**: Sub-second (vs 1-3 seconds)
- **Overhead**: Lower resource usage

This project handles the complexity of extracting and configuring **OCI native libraries** required for XStreams.

## Prerequisites

- OpenShift cluster with Strimzi operator installed cluster-wide
- `oc` CLI tool configured and authenticated
- Access to Red Hat Container Registry (registry.redhat.io)
- Quay.io account credentials for Oracle database image
- Cluster-admin rights (required for granting anyuid SCC to Oracle database)

## Components

- **Debezium Oracle Connector**: 3.4.3.Final-redhat-00001
- **AMQ Streams Base Image**: 3.2.0 (contains Kafka 4.2)
- **Kafka Version**: 4.2.0
- **Strimzi**: Kubernetes Operator for Apache Kafka
- **Oracle XStreams**: Native CDC library
- **Groovy**: 3.0.x (scripting support)

**Note:** AMQ Streams and Kafka use different versioning:
- AMQ Streams image tag: `kafka-42-rhel9:3.2.0` (AMQ Streams 3.2.0)
- Kafka version inside: 4.2.0 (referenced in `kafka-connect.yaml`)

## Quick Start

### Automated Deployment (Recommended)

Deploy everything with a single command:

```bash
./deploy-all.sh
```

This script will:
1. Deploy Kafka cluster and Console UI (auto-detects OpenShift domain)
2. Deploy Oracle database with proper security permissions
3. Extract OCI native libraries from Oracle pod
4. Build custom Kafka Connect image with OCI support
5. Deploy Kafka Connect cluster
6. Deploy and configure the Debezium Oracle connector

**Note:** You'll need to provide Quay.io credentials when prompted for the Oracle database image.

### Manual Step-by-Step Deployment

If you prefer to run steps individually:

```bash
# Step 1: Deploy Kafka cluster and Console UI
./01-deploy-kafka.sh

# Step 2: Deploy Oracle database
./02-deploy-oracle.sh

# Step 3: Extract OCI libraries and build Kafka Connect
./03-build-kafka-connect.sh

# Step 4: Deploy Kafka Connect and connector
./04-deploy-connector.sh
```

## Key Features

### Automatic OpenShift Domain Detection

The deployment scripts automatically detect your OpenShift cluster domain for the Kafka Console UI:

```bash
# Auto-detects from OpenShift ingress configuration
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
```

No manual configuration needed - the Console UI hostname is automatically set to `my-console.<cluster-domain>`.

### Oracle Database Security Context Fix

The deployment automatically handles OpenShift security context constraints:
1. Creates a dedicated service account (`oracle-sa`)  
2. Grants `anyuid` SCC to allow Oracle to run as UID 54321
3. Configures the deployment to use this service account

This solves the common error: `"unable to validate against any security context constraint"`

## Deployment Steps

### Step 0: Prerequisites - Red Hat Registry Access

Before building, you need access to Red Hat Container Registry to pull the AMQ Streams base image.

**Interactive setup:**
```bash
./create-registry-secret.sh
```

**Manual setup:**
```bash
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_REDHAT_USERNAME \
  --docker-password=YOUR_REDHAT_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi
```

Get your credentials from: https://access.redhat.com/terms-based-registry/

### Step 1: Extract OCI Native Libraries (for XStreams)

**Important**: XStreams requires OCI native libraries. Extract them from the Oracle database pod:

```bash
./extract-oci-libraries.sh
```

This extracts all necessary `.so` files (libclntsh.so, libociei.so, etc.) to `build/oci-libs/`.

**Skip this step** if you only want LogMiner support (but this project is optimized for XStreams).

### Step 2: Download Oracle Drivers and Debezium Plugins

This single script handles Oracle driver extraction, Debezium component downloads, and OCI library integration:

```bash
./download-dbz-oracle-xs-plugins.sh
```

This script will:
1. **Auto-detect the Oracle database pod** using label selector `app=oracle-db`
2. **Extract Oracle drivers** from the pod:
   - `xstreams.jar` from `/opt/oracle/product/19c/dbhome_1/rdbms/jlib/`
   - `ojdbc8.jar` from `/opt/oracle/product/19c/dbhome_1/jdbc/lib/`
3. **Download Debezium Oracle connector** (3.4.3.Final) from Red Hat Maven
4. **Download Debezium scripting support** and Groovy runtime libraries
5. **Organize all components** into the plugin directory structure

This creates the following structure:
```
build/
├── Dockerfile                     (auto-generated)
└── plugins/
    └── debezium-oracle-connector/
        ├── debezium-connector-oracle/ (extracted from plugin.zip)
        ├── debezium-scripting/        (extracted from scripting.zip)
        ├── groovy-*.jar               (3 Groovy runtime libraries)
        ├── ojdbc8.jar                 (copied from Oracle pod)
        └── xstreams.jar               (copied from Oracle pod)
```

**Note:** The `build/` directory is excluded from git (see `.gitignore`) and contains only what's needed for the Docker build, making the upload to OpenShift much faster.

### Step 3: Build Custom Kafka Connect Image

Build and push the custom Kafka Connect image to OpenShift internal registry:

```bash
./build-kafka-connect-dbz-oracle-xs-plugins.sh
```

This script:
1. Verifies the `build/` directory and Dockerfile exist
2. Creates ImageStream `debezium-connect` in the `strimzi` namespace (if needed)
3. Creates a binary build configuration (if needed)
4. Configures Dockerfile-based build strategy
5. Attaches Red Hat registry pull secret
6. **Uploads only the `build/` directory** (fast!) to OpenShift
7. Follows the build log output

**Performance:** By uploading only the `build/` directory instead of the entire project, this step is significantly faster.

### Step 4: Deploy Kafka Connect

Deploy the Kafka Connect cluster using the custom image:

```bash
oc apply -f kafka-connect.yaml
```

Verify the deployment:
```bash
oc get kafkaconnect -n strimzi
oc get pods -n strimzi -l strimzi.io/cluster=debezium-connect
```

### Step 5: Deploy XStreams Connector

```bash
oc apply -f kafkaconnector-oracle-xs.yaml
```

Monitor connector startup:
```bash
./verify-connector.sh
oc logs -f debezium-connect-connect-0 -n strimzi | grep -i xstream
```

### Step 6: Verify OCI Libraries

Test that OCI libraries are properly loaded:

```bash
./test-oci-libraries.sh
```

Expected output:
```
✅ OCI libraries are properly installed
```

### Alternative: LogMiner (without OCI)

If you prefer LogMiner over XStreams (lower performance but simpler setup):

```bash
# Skip Step 1 (no OCI libraries needed)
# Run Step 2-4 as normal
# Apply LogMiner connector instead:
oc apply -f kafkaconnector-oracle-logminer.yaml
```

See [XSTREAMS_VS_LOGMINER.md](XSTREAMS_VS_LOGMINER.md) for comparison.

## Verification

Check connector status:
```bash
oc get kafkaconnector oracle-source-connector -n strimzi -o yaml
```

View Kafka Connect logs:
```bash
oc logs -f deployment/debezium-connect-connect -n strimzi
```

List Kafka topics:
```bash
oc exec -it kafka-cluster-kafka-0 -n strimzi -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

## Troubleshooting

### Oracle Pod Fails to Start - SCC Error

If you see an error like:
```
pods "oracle-db-xxx-" is forbidden: unable to validate against any security context constraint
```

**Solution:** The `02-deploy-oracle.sh` script automatically fixes this by:
1. Creating service account `oracle-sa`  
2. Granting `anyuid` SCC

If deploying manually:
```bash
# Create service account
oc create sa oracle-sa -n strimzi

# Grant anyuid SCC
oc adm policy add-scc-to-user anyuid -z oracle-sa -n strimzi

# Verify
oc adm policy who-can use scc anyuid -n strimzi | grep oracle-sa
```

### Kafka Console UI Domain

The deployment scripts auto-detect the OpenShift cluster domain. If auto-detection fails, you'll be prompted to enter it manually.

To find your cluster domain:
```bash
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```

Example: `apps.cluster-name.region.domain.com`

### libnsl.so.1 Missing Error

If Kafka Connect fails with:
```
libnsl.so.1: cannot open shared object file: No such file or directory
```

This means the Dockerfile wasn't built with `libnsl2` package. The `download-dbz-oracle-xs-plugins.sh` script automatically adds this dependency.

Rebuild:
```bash
./download-dbz-oracle-xs-plugins.sh  # Regenerates Dockerfile with libnsl2
./build-kafka-connect-dbz-oracle-xs-plugins.sh  # Rebuilds image
```

### Red Hat registry pull secret missing

If you get an error about missing pull secret:

```bash
# Interactive creation
./create-registry-secret.sh

# Or manual creation
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi
```

### Oracle pod not found
If the script cannot find the Oracle database pod:
```bash
# Verify the pod exists and has the correct label
oc get pods -n strimzi -l app=oracle-db

# If using a different namespace, edit the NAMESPACE variable in the script
```

### Driver extraction errors
Ensure the Oracle database pod is running and the paths are correct:
```bash
# Verify the files exist in the pod
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')
oc exec -it ${ORACLE_POD} -n strimzi -- ls -l /opt/oracle/product/19c/dbhome_1/rdbms/jlib/xstreams.jar
oc exec -it ${ORACLE_POD} -n strimzi -- ls -l /opt/oracle/product/19c/dbhome_1/jdbc/lib/ojdbc8.jar
```

### Build directory not found
If the build script cannot find the build directory:
```bash
# Run the download script first
./download-dbz-oracle-xs-plugins.sh
```

### Build failures
Check Red Hat registry credentials:
```bash
oc get secret registry-redhat-io -n strimzi
```

View build logs:
```bash
oc logs -f bc/debezium-connect -n strimzi
```

### Connector failures
Check connector logs for specific errors:
```bash
oc logs -f deployment/debezium-connect-connect -n strimzi | grep -i error
```

### XStreams configuration issues
Verify XStreams is properly configured in the Oracle database:
```sql
-- Check if XStream is configured
SELECT * FROM DBA_XSTREAM_OUTBOUND;
```

## File Descriptions

### Main Deployment Files
| File | Purpose |
|------|---------|
| `oracle-complete.yaml` | All-in-one Oracle deployment (PVC + Deployment + Service) |
| `oracle-service.yaml` | Standalone Oracle service definition |
| `kafkaconnector-oracle-xs.yaml` | Debezium Oracle connector configuration |
| `kafka-connect.yaml` | Strimzi KafkaConnect custom resource |
| `DEPLOYMENT.md` | Detailed Oracle database deployment guide |

### Setup Scripts
| File | Purpose |
|------|---------|
| `create-registry-secret.sh` | Interactive script to create Red Hat registry pull secret |
| `extract-oci-libraries.sh` | **Extract OCI native libraries from Oracle pod (for XStreams)** |
| `download-dbz-oracle-xs-plugins.sh` | Extract Oracle drivers, download Debezium, integrate OCI libs |
| `build-kafka-connect-dbz-oracle-xs-plugins.sh` | Build custom Kafka Connect image in OpenShift |
| `update-dockerfile-for-oci.sh` | Manually update Dockerfile for OCI support (if needed) |

### Diagnostic Scripts
| File | Purpose |
|------|---------|
| `test-oci-libraries.sh` | **Verify OCI libraries are loaded in Kafka Connect (XStreams)** |
| `test-service-connectivity.sh` | Test Oracle service DNS and TCP connectivity |
| `test-oracle-connection.sh` | Test JDBC connection from Kafka Connect pod |
| `verify-connector.sh` | Check Kafka connector status and logs |
| `verify-oracle-logminer-setup.sh` | Check Oracle LogMiner prerequisites |
| `find-oracle-service.sh` | Find Oracle service name and details |
| `check-current-build.sh` | Check current build status |
| `troubleshoot-build.sh` | Full build diagnostics |
| `test-all-url-formats.sh` | Test different JDBC URL formats |
| `diagnose-jdbc-driver.sh` | Diagnose JDBC driver configuration |

### Generated Files
| File | Purpose |
|------|---------|
| `build/Dockerfile` | Container image definition (auto-generated, base: kafka-42-rhel9:3.2.0) |
| `build/plugins/` | Plugin directory with all JARs (auto-generated) |

### Legacy Files (can be removed after migration)
| File | Purpose |
|------|---------|
| `oracle-pvc.yaml` | Oracle PVC (included in oracle-complete.yaml) |
| `oracle-deployment.yaml` | Oracle Deployment (included in oracle-complete.yaml) |

## Architecture

```
┌─────────────────┐
│  Oracle 19c DB  │
│  (XStreams)     │
└────────┬────────┘
         │ CDC
         ▼
┌─────────────────┐
│ Kafka Connect   │
│ (Debezium)      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Kafka Cluster  │
│  (Strimzi)      │
└─────────────────┘
```

## References

- [Debezium Oracle Connector Documentation](https://debezium.io/documentation/reference/connectors/oracle.html)
- [Strimzi Documentation](https://strimzi.io/documentation/)
- [Oracle XStreams Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/xstrm/)

## License

See your organization's license terms for Debezium, Oracle, and Red Hat components.
