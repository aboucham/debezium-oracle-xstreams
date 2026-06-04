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

This project handles the complexity of downloading and configuring **Oracle Instant Client 21.x** and **OCI native libraries** required for XStreams.

## Prerequisites

- OpenShift cluster with Strimzi operator installed cluster-wide
- `oc` CLI tool configured and authenticated
- Access to Red Hat Container Registry (registry.redhat.io)
- Quay.io account credentials for Oracle database image
- Cluster-admin rights (required for granting anyuid SCC to Oracle database)

### Required Secrets (Create Before Deployment)

**IMPORTANT:** You must create these two secrets in the `strimzi` namespace before running any deployment scripts:

#### 1. Red Hat Registry Pull Secret

Required to pull the AMQ Streams Kafka base image from Red Hat registry.

```bash
# Create the strimzi namespace if it doesn't exist
oc create namespace strimzi

# Create Red Hat registry pull secret
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_REDHAT_USERNAME \
  --docker-password=YOUR_REDHAT_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi
```

Get your credentials from: https://access.redhat.com/terms-based-registry/

#### 2. Quay.io Pull Secret

Required to pull the Oracle database image from Quay.io.

```bash
# Create Quay.io pull secret
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi
```

**Verify secrets are created:**
```bash
oc get secrets -n strimzi | grep -E 'registry-redhat-io|quay-pull-secret'
```

You should see both secrets listed before proceeding with deployment.

## Quick Start (Remote Deployment)

**Deploy everything without cloning the repository:**

```bash
# One-line deployment - no local files needed
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/deploy-all.sh)
```

**Prerequisites:** Ensure you have created the required secrets (see [Required Secrets](#required-secrets-create-before-deployment) above).

This remote deployment will:
1. Deploy Kafka cluster and Console UI (auto-detects OpenShift domain)
2. Deploy Oracle database with proper security permissions
3. Download Oracle Instant Client 21.15 from Oracle official repository
4. Download ojdbc11 21.15.0.0 JDBC driver from Maven Central
5. Extract xstreams.jar and message files from Oracle pod
6. Build custom Kafka Connect image with Oracle Instant Client 21.x
7. Deploy Kafka Connect cluster with XStreams support
8. Deploy and configure the Debezium Oracle XStreams connector

## Components

- **Debezium Oracle Connector**: 3.4.3.Final-redhat-00001
- **AMQ Streams Base Image**: 3.2.0 (contains Kafka 4.2)
- **Kafka Version**: 4.2.0
- **Strimzi**: Kubernetes Operator for Apache Kafka
- **Oracle Instant Client**: 21.15.0.0 (required for XStreams)
- **Oracle JDBC Driver**: ojdbc11 21.15.0.0 (required for Debezium 3.4+)
- **Oracle XStreams**: Native CDC library from Oracle 19c pod
- **Groovy**: 3.0.x (scripting support)

**Note:** AMQ Streams and Kafka use different versioning:
- AMQ Streams image tag: `kafka-42-rhel9:3.2.0` (AMQ Streams 3.2.0)
- Kafka version inside: 4.2.0 (referenced in `deploy/kafka-connect.yaml`)

**Important:** Debezium 3.4+ requires Oracle Instant Client 21.x or 23.x with ojdbc11. Oracle 19.x components (ojdbc8, Instant Client 19.x) are **not compatible**.

## Local Deployment

**Prerequisites:** Ensure you have created the required secrets (see [Required Secrets](#required-secrets-create-before-deployment) above).

### Option 1: Automated Deployment (Recommended)

Clone the repository and deploy everything with a single command:

```bash
git clone https://github.com/aboucham/debezium-oracle-xstreams.git
cd debezium-oracle-xstreams
./deploy/deploy-all.sh
```

### Option 2: Manual Step-by-Step Deployment

If you prefer to run steps individually:

```bash
git clone https://github.com/aboucham/debezium-oracle-xstreams.git
cd debezium-oracle-xstreams

# Step 1: Deploy Kafka cluster and Console UI
./deploy/01-deploy-kafka.sh

# Step 2: Deploy Oracle database
./deploy/02-deploy-oracle.sh

# Step 3: Download Oracle Instant Client 21.x and build Kafka Connect
./deploy/03-build-kafka-connect.sh

# Step 4: Deploy Kafka Connect and XStreams connector
./deploy/04-deploy-connector.sh
```

### Option 3: Step-by-Step Remote Deployment

Run individual deployment steps without cloning:

```bash
# Step 1: Deploy Kafka cluster and Console UI
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/01-deploy-kafka.sh)

# Step 2: Deploy Oracle database
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/02-deploy-oracle.sh)

# Step 3: Download Oracle Instant Client 21.x and build Kafka Connect
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/03-build-kafka-connect.sh)

# Step 4: Deploy Kafka Connect and XStreams connector
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/04-deploy-connector.sh)
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

### Oracle Instant Client 21.x Automated Download

The deployment automatically downloads and configures Oracle Instant Client 21.15:
1. Downloads Oracle Instant Client 21.15 Basic package (85MB) from Oracle official repository
2. Downloads ojdbc11 21.15.0.0 from Maven Central
3. Extracts xstreams.jar from Oracle 19c pod (as xstreams.jar version must match Oracle database version)
4. Extracts Oracle message files for proper error reporting
5. Extracts libnsl.so.1 from Oracle pod (required for RHEL 9 compatibility)
6. Creates optimized build directory (~925MB total)

## Detailed Deployment Guide

The automated scripts handle all these steps for you, but here's what happens under the hood:

### What the Scripts Do

**Script 01: Deploy Kafka** (`deploy/01-deploy-kafka.sh`)
- Creates Kafka cluster with KRaft mode (no ZooKeeper)
- Auto-detects OpenShift cluster domain
- Deploys Kafka Console UI with auto-configured hostname
- Waits for all Kafka components to be ready

**Script 02: Deploy Oracle** (`deploy/02-deploy-oracle.sh`)
- Creates service account with anyuid SCC permissions
- Deploys Oracle 19c database with XStreams enabled
- Configures proper security context for UID 54321
- Waits for Oracle to be ready

**Script 03: Build Kafka Connect** (`deploy/03-build-kafka-connect.sh`)
- Calls `deploy/download-oracle-instantclient-21.sh` to:
  - Download Oracle Instant Client 21.15 Basic (85MB) from Oracle
  - Download ojdbc11 21.15.0.0 from Maven Central
  - Extract xstreams.jar from Oracle 19c pod
  - Download message files from Oracle pod for error reporting
  - Extract libnsl.so.1 from Oracle pod (RHEL 8 to RHEL 9 compatibility)
  - Download Debezium 3.4.3 components and Groovy libraries
  - Generate optimized Dockerfile with Oracle Instant Client 21.x support
- Calls `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` to:
  - Build custom Kafka Connect image with all components
  - Upload build context to OpenShift (~925MB)
  - Push final image to OpenShift internal registry

**Script 04: Deploy Connector** (`deploy/04-deploy-connector.sh`)
- Deploys Kafka Connect cluster using custom image with Oracle Instant Client 21.x
- Waits for Kafka Connect pod to be ready
- Applies Debezium Oracle XStreams connector configuration
- Verifies connector is running with XStreams adapter

### XStreams Connector Configuration

The XStreams connector requires specific configuration:

```yaml
database.url: "jdbc:oracle:oci:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oracle-db)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=ORCLCDB)))"
database.user: c##dbzuser
database.password: dbz
database.dbname: ORCLCDB
database.connection.adapter: xstream
database.out.server.name: dbzxout
```

Key points:
- **OCI driver URL**: Must use `jdbc:oracle:oci:@` prefix (not `jdbc:oracle:thin:@`)
- **Full TNS descriptor**: Inline connection descriptor avoids tnsnames.ora dependency
- **XStream adapter**: `database.connection.adapter: xstream`
- **XStream server**: Must match server name created in Oracle database (`dbzxout`)

### Manual YAML Deployment (Remote)

If you want to apply YAML files directly without cloning:

```bash
# Deploy Oracle database
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/oracle-complete.yaml

# Deploy Kafka Connect cluster (requires custom image built first)
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafka-connect.yaml

# Deploy XStreams connector (requires Oracle Instant Client 21.x in image)
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-xstreams-final.yaml
```

**Note:** Manual YAML deployment requires you to build the custom Kafka Connect image first using the build scripts.

## Verification

Check connector status:
```bash
# Check XStreams connector
oc get kafkaconnector inventory-connector-oracle-logminer -n strimzi -o yaml
```

View Kafka Connect logs:
```bash
oc logs -f debezium-connect-connect-0 -n strimzi
```

List Kafka topics:
```bash
# Get Kafka pod name
KAFKA_POD=$(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}')

# List topics
oc exec -n strimzi $KAFKA_POD -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

Expected topics:
- `oracle-server` - Main connector topic
- `oracle-server.C__DBZUSER.CUSTOMERS` - Customer table changes
- `schema-changes.oracle.inventory` - Schema history

Access Kafka Console UI:
```bash
# Get the Console URL
oc get route my-console -n strimzi -o jsonpath='{.spec.host}'
```

Test CDC functionality:
```bash
# Get Oracle pod name
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')

# Insert test data
oc exec $ORACLE_POD -n strimzi -- sqlplus -s c##dbzuser/dbz@ORCLCDB <<'EOF'
INSERT INTO CUSTOMERS (id, name, email) VALUES (999, 'XStream Test', 'xstream@test.com');
COMMIT;
EXIT;
EOF

# Watch for changes in Kafka topic (within 1 second with XStreams)
oc exec -n strimzi $KAFKA_POD -- bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic oracle-server.C__DBZUSER.CUSTOMERS \
  --from-beginning \
  --max-messages 1
```

## Troubleshooting

### Missing Required Secrets

**Symptoms:**
- Oracle pod fails to pull image: `ImagePullBackOff` or `ErrImagePull`
- Kafka Connect build fails with registry authentication error
- Build shows: `error: build error: failed to pull image`

**Solution:** Verify both required secrets exist:

```bash
# Check if secrets exist
oc get secrets -n strimzi | grep -E 'registry-redhat-io|quay-pull-secret'
```

If missing, create them:

```bash
# Red Hat registry pull secret (for AMQ Streams base image)
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_REDHAT_USERNAME \
  --docker-password=YOUR_REDHAT_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi

# Quay.io pull secret (for Oracle database image)
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi
```

### Oracle Pod Fails to Start - SCC Error

If you see an error like:
```
pods "oracle-db-xxx-" is forbidden: unable to validate against any security context constraint
```

**Solution:** The `deploy/02-deploy-oracle.sh` script automatically fixes this by:
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

### Oracle Instant Client Download Issues

If Oracle Instant Client download fails:

**Symptoms:**
```
⚠ Automatic download may require Oracle account authentication.
```

**Solution:** The script may require Oracle account authentication for the first download. The download URL uses Oracle's public download endpoint, but if it fails:

1. Manually download from: https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
2. File: `instantclient-basic-linux.x64-21.15.0.0.0dbru.zip`
3. Save to the project root directory as `instantclient-basic-21.15.zip`
4. Re-run the script

### XStreams Specific Issues

**Error: `ORA-26812: An active session currently attached to XStream server`**

This means another connector is already using the XStream server `dbzxout`. Each XStream server supports only one active session.

**Solution:**
```bash
# Delete the duplicate connector
oc delete kafkaconnector <duplicate-connector-name> -n strimzi

# Or restart the Oracle XStream server (in Oracle database)
# Connect as c##dbzadmin and drop/recreate the outbound server
```

**Error: `Unsupported feature: getOCIHandles`**

This means the connector is using JDBC Thin driver instead of OCI driver.

**Solution:**
- Verify the Kafka Connect image was built with Oracle Instant Client 21.x
- Check connector configuration uses `jdbc:oracle:oci:@` (not `jdbc:oracle:thin:@`)
- Verify environment variables are set correctly in Kafka Connect pod

**Error: `no ocijdbc21 in java.library.path`**

The OCI native library cannot be found.

**Solution:**
- Verify Oracle Instant Client libraries are in `/opt/oracle/instantclient/lib`
- Check `java.library.path` system property in `kafka-connect.yaml`
- Check `LD_LIBRARY_PATH` environment variable

### Connector Failures

Check connector logs for specific errors:
```bash
oc logs -f debezium-connect-connect-0 -n strimzi | grep -i error
```

Get connector status:
```bash
oc get kafkaconnector -n strimzi
oc describe kafkaconnector inventory-connector-oracle-logminer -n strimzi
```

### Build Failures

**First, verify the Red Hat registry pull secret exists:**
```bash
oc get secret registry-redhat-io -n strimzi
```

If missing, see [Missing Required Secrets](#missing-required-secrets) above.

**View build logs:**
```bash
oc logs -f bc/debezium-connect -n strimzi
```

**Check build status:**
```bash
oc get builds -n strimzi
oc describe build <build-name> -n strimzi
```

## Project Structure

```
debezium-oracle-xstreams/
├── README.md                                      # This file
├── .gitignore                                     # Git ignore patterns
└── deploy/                                        # All deployment files
    ├── 01-deploy-kafka.sh                        # Step 1: Deploy Kafka cluster and Console UI
    ├── 02-deploy-oracle.sh                       # Step 2: Deploy Oracle database with SCC
    ├── 03-build-kafka-connect.sh                 # Step 3: Download Oracle IC 21.x and build image
    ├── 04-deploy-connector.sh                    # Step 4: Deploy connector configuration
    ├── deploy-all.sh                             # One-command automated deployment
    ├── download-oracle-instantclient-21.sh       # Download Oracle Instant Client 21.15 and components
    ├── download-dbz-oracle-xs-plugins.sh         # Download Debezium plugins (legacy/fallback)
    ├── extract-oci-minimal.sh                    # Extract minimal OCI libs from pod (legacy/fallback)
    ├── extract-oci-libraries.sh                  # Extract full OCI structure from pod (legacy/fallback)
    ├── build-kafka-connect-dbz-oracle-xs-plugins.sh  # Build custom Kafka Connect image
    ├── oracle-complete.yaml                      # Oracle database deployment (PVC + Deployment + Service)
    ├── kafka-connect.yaml                        # Kafka Connect cluster configuration
    └── kafkaconnector-oracle-xstreams-final.yaml # XStreams connector configuration
```

## File Descriptions

### Deployment Scripts

| File | Purpose | Can Run Remotely |
|------|---------|------------------|
| `deploy/deploy-all.sh` | One-command automated deployment of entire stack | ✅ Yes |
| `deploy/01-deploy-kafka.sh` | Deploy Kafka cluster and Console UI with auto-detected domain | ✅ Yes |
| `deploy/02-deploy-oracle.sh` | Deploy Oracle database with anyuid SCC permissions | ✅ Yes |
| `deploy/03-build-kafka-connect.sh` | Download Oracle IC 21.x, build custom Kafka Connect image | ✅ Yes |
| `deploy/04-deploy-connector.sh` | Deploy Kafka Connect and Debezium XStreams connector | ✅ Yes |

### Build Helper Scripts

| File | Purpose |
|------|---------|
| `deploy/download-oracle-instantclient-21.sh` | Download Oracle Instant Client 21.15, ojdbc11, extract xstreams.jar and message files |
| `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` | Build and push custom Kafka Connect image to OpenShift registry |
| `deploy/download-dbz-oracle-xs-plugins.sh` | Legacy: Download Debezium plugins with Oracle 19c components |
| `deploy/extract-oci-minimal.sh` | Legacy: Extract minimal OCI libraries from Oracle pod (~400MB) |
| `deploy/extract-oci-libraries.sh` | Legacy: Extract full OCI structure from Oracle pod (~2.5GB) |

### YAML Configurations

| File | Purpose | Can Apply Remotely |
|------|---------|---------------------|
| `deploy/oracle-complete.yaml` | Oracle database deployment (PVC + Deployment + Service) | ✅ Yes |
| `deploy/kafka-connect.yaml` | Kafka Connect cluster with Oracle Instant Client 21.x support | ✅ Yes |
| `deploy/kafkaconnector-oracle-xstreams-final.yaml` | XStreams connector config (OCI driver, 100k+ events/sec) | ✅ Yes |

### Generated Files (Not in Repository)

| File | Purpose |
|------|---------|
| `build/Dockerfile` | Auto-generated container image definition (base: kafka-42-rhel9:3.2.0) |
| `build/plugins/` | Auto-generated plugin directory with Debezium, ojdbc11, xstreams.jar, Groovy |
| `build/oracle-instantclient/` | Oracle Instant Client 21.15 structure (lib/, network/admin/, message files) |
| `instantclient-basic-21.15.zip` | Downloaded Oracle Instant Client 21.15 Basic package (85MB) |
| `libnsl-2.17.so` | Extracted libnsl from Oracle pod for RHEL 9 compatibility |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Oracle 19c Database                                    │
│  - XStreams Server: dbzxout                             │
│  - User: c##dbzuser                                     │
│  - Schema: C##DBZUSER.CUSTOMERS                         │
└───────────────────────┬─────────────────────────────────┘
                        │ XStreams API
                        │ (OCI Driver)
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Kafka Connect Pod                                      │
│  - Oracle Instant Client 21.15                          │
│  - ojdbc11 21.15.0.0                                    │
│  - Debezium Oracle Connector 3.4.3                      │
│  - XStreams adapter (100k+ events/sec)                  │
└───────────────────────┬─────────────────────────────────┘
                        │ Kafka Protocol
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Kafka Cluster (Strimzi KRaft)                          │
│  - kafka-cluster-broker-0                               │
│  - Topics:                                              │
│    * oracle-server                                      │
│    * oracle-server.C__DBZUSER.CUSTOMERS                 │
│    * schema-changes.oracle.inventory                    │
└─────────────────────────────────────────────────────────┘
```

## Cleanup and Start Fresh

To completely remove all deployed components and start from scratch:

### Option 1: Quick Cleanup (Remove Everything)

```bash
# Delete all resources in strimzi namespace
oc delete namespace strimzi

# Recreate namespace
oc create namespace strimzi

# Recreate required secrets (see Prerequisites section above)
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_REDHAT_USERNAME \
  --docker-password=YOUR_REDHAT_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi

oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi

# Ready to deploy again
```

### Option 2: Selective Cleanup (Keep Secrets and Kafka)

```bash
# Delete only Debezium components
oc delete kafkaconnector --all -n strimzi
oc delete kafkaconnect debezium-connect -n strimzi
oc delete bc debezium-connect -n strimzi
oc delete is debezium-connect -n strimzi

# Delete Oracle database
oc delete deployment oracle-db -n strimzi
oc delete service oracle-db -n strimzi
oc delete pvc oracle-data -n strimzi

# Optionally delete Kafka cluster (keeps Console UI)
oc delete kafka kafka-cluster -n strimzi

# Optionally delete Console UI
oc delete deployment my-console -n strimzi
oc delete service my-console -n strimzi
oc delete route my-console -n strimzi

# Service account and SCC cleanup
oc delete sa oracle-sa -n strimzi
oc adm policy remove-scc-from-user anyuid -z oracle-sa -n strimzi
```

### Option 3: Local Cleanup (Remove Downloaded Files)

If you cloned the repository locally and want to clean up downloaded files:

```bash
cd debezium-oracle-xstreams

# Remove build artifacts
rm -rf build/

# Remove downloaded Oracle components
rm -f instantclient-basic-21.15.zip
rm -f libnsl-2.17.so
rm -f ojdbc8.jar
rm -f xstreams.jar
rm -f oracle-mesg.tar.gz
```

### Verification After Cleanup

```bash
# Verify namespace is clean (should show only secrets and serviceaccounts)
oc get all -n strimzi

# Verify no Kafka resources remain
oc get kafka,kafkaconnect,kafkaconnector -n strimzi

# Verify no builds remain
oc get builds,bc,is -n strimzi

# Verify PVCs are removed
oc get pvc -n strimzi
```

### Start Fresh After Cleanup

Once cleanup is complete, redeploy from scratch:

```bash
# Local deployment
./deploy/deploy-all.sh

# Or remote deployment
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/deploy-all.sh)
```

## References

- [Debezium Oracle Connector Documentation](https://debezium.io/documentation/reference/3.4/connectors/oracle.html)
- [Debezium 3.4 Supported Configurations](https://debezium.io/documentation/reference/3.4/connectors/oracle.html#oracle-supported-topologies)
- [Strimzi Documentation](https://strimzi.io/documentation/)
- [Oracle XStreams Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/xstrm/)
- [Oracle Instant Client Downloads](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html)

## License

See your organization's license terms for Debezium, Oracle, and Red Hat components.
