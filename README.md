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
2. Deploy Oracle database 19c with proper security permissions
3. Download Oracle Instant Client 19.x from Oracle official repository
4. Download ojdbc11 21.15.0.0 JDBC driver from Maven Central (Debezium requirement)
5. Extract xstreams.jar from Instant Client 19.x package
6. Build custom Kafka Connect image with Oracle Instant Client 19.x + ojdbc11
7. Deploy Kafka Connect cluster with XStreams support
8. Deploy and configure the Debezium Oracle XStreams connector

## Components

- **Debezium Oracle Connector**: 3.5.2.Final
- **AMQ Streams Base Image**: 3.2.0 (contains Kafka 4.2)
- **Kafka Version**: 4.2.0
- **Strimzi**: Kubernetes Operator for Apache Kafka
- **Oracle Database**: 19.3.0.0.0 Enterprise Edition
- **Oracle Instant Client**: 19.x (native OCI libraries - must match database version)
- **Oracle JDBC Driver**: ojdbc11 21.15.0.0 (Debezium requirement - backward compatible)
- **Oracle XStreams**: xstreams.jar from Instant Client 19.x package
- **Groovy**: 3.0.x (scripting support)

**Note:** AMQ Streams and Kafka use different versioning:
- AMQ Streams image tag: `kafka-42-rhel9:3.2.0` (AMQ Streams 3.2.0)
- Kafka version inside: 4.2.0 (referenced in `deploy/kafka-connect.yaml`)

## Critical Dependencies for XStream

### Understanding Oracle Instant Client and JDBC Drivers

**The Three Essential Components:**

1. **Oracle Instant Client 19.x** (Native OCI Libraries)
   - **Purpose**: Provides native C libraries (`libclntsh.so`, `libocijdbc19.so`) required for Oracle Call Interface (OCI)
   - **Version Requirement**: **Must match Oracle Database version** (19.x for Oracle 19c)
   - **Size**: ~85MB (Basic package)
   - **Location in container**: `/opt/oracle/instantclient/lib/`
   - **Key libraries**:
     - `libclntsh.so.19.1` - Oracle client shared library
     - `libocijdbc19.so` - OCI-JDBC bridge for native connectivity
   - **Environment**: Requires `LD_LIBRARY_PATH=/opt/oracle/instantclient/lib`

2. **ojdbc11.jar (21.15.0.0)** (JDBC Driver)
   - **Purpose**: JDBC driver layer that Debezium uses to communicate with Oracle
   - **Version Requirement**: **Debezium 3.5.2 requires ojdbc11 21.15.0.0** (documented requirement)
   - **Size**: ~5.0MB
   - **Source**: Maven Central
   - **Backward Compatibility**: ojdbc11 21.x works with Oracle 19c, 21c, 23c databases
   - **Location in container**: `/opt/kafka/plugins/debezium-oracle-connector/ojdbc11.jar`
   - **Why not ojdbc8**: Debezium 3.5+ explicitly requires ojdbc11 for XStream support

3. **xstreams.jar** (Oracle XStream API)
   - **Purpose**: Oracle's proprietary XStream client library for high-performance CDC
   - **Version Requirement**: **Must come from Instant Client 19.x package** (matches database)
   - **Size**: ~31KB
   - **Source**: Included in Oracle Instant Client 19.x package (`instantclient_19_x/lib/xstreams.jar`)
   - **Location in container**: `/opt/kafka/plugins/debezium-oracle-connector/xstreams.jar`
   - **Critical**: Do NOT use xstreams.jar from a different Oracle version

### Why This Specific Configuration?

**Oracle Instant Client 19.x (NOT 21.x):**
- Native OCI libraries (`libclntsh.so`) must **exactly match** the Oracle database version
- Oracle Database 19.3.0.0.0 requires Instant Client 19.x native libraries
- Using IC 21.x causes version mismatch errors: `"Incompatible version of libocijdbc"`

**ojdbc11.jar 21.15.0.0 (NOT ojdbc8):**
- Debezium 3.5.2 documentation explicitly requires ojdbc11 21.15.0.0
- JDBC drivers are backward compatible (ojdbc11 works with Oracle 19c)
- The JDBC layer is separate from native OCI libraries

**xstreams.jar from IC 19.x package:**
- Must match the database version for XStream protocol compatibility
- Included in the Instant Client package (`lib/xstreams.jar`)

### Architecture: Two Separate Layers

```
┌─────────────────────────────────────────────────────────┐
│  Debezium Connector (Java)                              │
│                                                          │
│  ┌────────────────────────────────────────────────┐    │
│  │ JDBC Layer                                     │    │
│  │ • ojdbc11.jar (21.15.0.0)                      │    │
│  │ • xstreams.jar (from IC 19.x)                  │    │
│  │ • Debezium Oracle Connector 3.5.2              │    │
│  └─────────────────┬──────────────────────────────┘    │
│                    │ JNI (Java Native Interface)        │
│  ┌─────────────────▼──────────────────────────────┐    │
│  │ Native OCI Layer (C libraries)                 │    │
│  │ • Oracle Instant Client 19.x                   │    │
│  │ • libclntsh.so.19.1                            │    │
│  │ • libocijdbc19.so                              │    │
│  └─────────────────┬──────────────────────────────┘    │
└────────────────────┼──────────────────────────────────┘
                     │ XStream Protocol
┌────────────────────▼──────────────────────────────────┐
│  Oracle Database 19.3.0.0.0                            │
│  • XStream Outbound Server (DBZXOUT)                   │
│  • XStream Capture Process                             │
└─────────────────────────────────────────────────────────┘
```

**Key Points:**
- **JDBC layer (ojdbc11)**: Can be newer than database - provides backward compatibility
- **Native OCI layer (IC 19.x)**: Must exactly match database version - no flexibility
- **XStream API (xstreams.jar)**: Must match database version for protocol compatibility

### RHEL 9 Compatibility

**libnsl.so.1 Requirement:**
- Oracle Instant Client 19.x requires `libnsl.so.1` (from RHEL 8)
- RHEL 9 only provides `libnsl.so.3` via the `libnsl2` package
- **Solution**: Create symlink `libnsl.so.1 → libnsl.so.3`

```dockerfile
# Install libnsl2 package
RUN microdnf install -y libaio libnsl2 && microdnf clean all

# Create compatibility symlink
RUN ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1
```

### What NOT to Do

❌ **DO NOT use Oracle Instant Client 21.x with Oracle Database 19.3**
- Causes: `"Incompatible version of libocijdbc[Jdbc:2115000, Jdbc-OCI:1924000]"`
- Native OCI libraries must match database version

❌ **DO NOT use ojdbc8.jar with Debezium 3.5.2**
- Debezium 3.5.2 explicitly requires ojdbc11 21.15.0.0
- ojdbc8 is not supported for XStream in this version

❌ **DO NOT extract xstreams.jar from Oracle database pod**
- Use the xstreams.jar from Instant Client package instead
- Ensures version consistency and proper packaging

❌ **DO NOT remove bundled ojdbc11.jar from Debezium plugin**
- Keep the ojdbc11.jar that matches Debezium's requirements
- Remove ojdbc8.jar if accidentally included

### Verification Commands

Check installed components in Kafka Connect pod:

```bash
# Check JDBC drivers
oc exec debezium-connect-connect-0 -n strimzi -- ls -lh /opt/kafka/plugins/debezium-oracle-connector/*.jar

# Expected output:
# ojdbc11.jar     (5.0M) - JDBC driver
# xstreams.jar    (31K)  - XStream API

# Check Instant Client libraries
oc exec debezium-connect-connect-0 -n strimzi -- ls -lh /opt/oracle/instantclient/lib/libclntsh.so.19.1

# Check environment variables
oc exec debezium-connect-connect-0 -n strimzi -- env | grep -E "LD_LIBRARY_PATH|ORACLE_HOME"

# Expected:
# ORACLE_HOME=/opt/oracle/instantclient
# LD_LIBRARY_PATH=/opt/oracle/instantclient/lib:...
```

### Download Sources

All components are downloaded from official sources:

1. **Debezium 3.5.2.Final**: Maven Central
   ```
   https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/3.5.2.Final/
   ```

2. **ojdbc11.jar 21.15.0.0**: Maven Central
   ```
   https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc11/21.15.0.0/
   ```

3. **Oracle Instant Client 19.x**: Oracle Official Downloads
   ```
   https://download.oracle.com/otn_software/linux/instantclient/1924000/
   ```
   - File: `instantclient-basic-linux.x64-19.24.0.0.0dbru.zip`
   - Includes: `xstreams.jar`, native libraries, message files

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

# Step 3: Download Oracle Instant Client 19.x and build Kafka Connect
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
- Calls `deploy/download-oracle-instantclient-19.sh` to:
  - Download Oracle Instant Client 19.x Basic (85MB) from Oracle
  - Download ojdbc11 21.15.0.0 from Maven Central (Debezium requirement)
  - Extract xstreams.jar from Instant Client 19.x package
  - Download Debezium 3.5.2 components and Groovy libraries
  - Generate Dockerfile with Oracle IC 19.x + libnsl.so.1 symlink for RHEL 9
- Calls `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` to:
  - Build custom Kafka Connect image with all components
  - Upload build context to OpenShift
  - Push final image to OpenShift internal registry

**Script 04: Deploy Connector** (`deploy/04-deploy-connector.sh`)
- Deploys Kafka Connect cluster using custom image with Oracle IC 19.x + ojdbc11
- Waits for Kafka Connect pod to be ready
- Applies Debezium Oracle XStreams connector configuration
- Verifies connector is running with XStreams adapter

### XStreams Connector Configuration

The XStreams connector requires specific configuration:

```yaml
# Database connection - XStream with OCI driver
database.url: jdbc:oracle:oci:@//oracle-db:1521/ORCLCDB
database.dbname: ORCLCDB
database.user: c##dbzuser
database.password: dbz

# XStream adapter configuration
database.connection.adapter: xstream
xstream.out.server.name: dbzxout

# Topic and filtering
topic.prefix: oracle-xstream
schema.include.list: C##DBZUSER
table.include.list: C##DBZUSER.CUSTOMERS
```

Key points:
- **OCI driver URL**: Must use `jdbc:oracle:oci:@` prefix (not `jdbc:oracle:thin:@`)
- **EZConnect format**: `jdbc:oracle:oci:@//host:port/service_name` (simpler than TNS descriptor)
- **XStream adapter**: `database.connection.adapter: xstream`
- **Correct property**: `xstream.out.server.name` (NOT `database.out.server.name`)
- **XStream server**: Must match server name created in Oracle database (`dbzxout`)
- **Schema filtering**: Use `C##DBZUSER` for CDB-level common user schema

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
2. File: `instantclient-basic-linux.x64-19.24.0.0.0dbru.zip` (Oracle Instant Client 19.24 for Linux x86-64)
3. Save to the project root directory as `instantclient-basic-19.24.zip`
4. Re-run the script

**Important**: Download Instant Client **19.x** (not 21.x or 23.x) to match Oracle Database 19c

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
- Check `LD_LIBRARY_PATH` environment variable points to IC lib directory
- Ensure `libocijdbc19.so` exists (for IC 19.x)
- If using IC 19.x, create symlink: `ln -sf libocijdbc19.so libocijdbc21.so`

**Error: `Incompatible version of libocijdbc`**

Version mismatch between JDBC driver and native OCI libraries.

**Solution:**
- Ensure Oracle Instant Client version matches Oracle Database version
- For Oracle 19c, use IC 19.x (not IC 21.x or 23.x)
- Use ojdbc11.jar 21.15.0.0 for Debezium (backward compatible with Oracle 19c)
- Verify only one ojdbc*.jar file exists in plugin directory (remove ojdbc8.jar if present)

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
| `deploy/download-oracle-instantclient-19.sh` | Download Oracle IC 19.x, ojdbc11 21.15.0.0, extract xstreams.jar, generate Dockerfile |
| `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` | Build and push custom Kafka Connect image to OpenShift registry |
| `deploy/download-dbz-oracle-xs-plugins.sh` | Download Debezium 3.5.2 plugins and Groovy libraries from Maven Central |
| `deploy/setup-xstream.sh` | Configure Oracle XStream outbound server and capture process |
| `deploy/switch-to-xstream.sh` | Switch from LogMiner to XStream connector (validates XStream ready) |

### YAML Configurations

| File | Purpose | Can Apply Remotely |
|------|---------|---------------------|
| `deploy/oracle-complete.yaml` | Oracle database deployment (PVC + Deployment + Service) | ✅ Yes |
| `deploy/kafka-connect.yaml` | Kafka Connect cluster with Oracle Instant Client 21.x support | ✅ Yes |
| `deploy/kafkaconnector-oracle-xstreams-final.yaml` | XStreams connector config (OCI driver, 100k+ events/sec) | ✅ Yes |

### Generated Files (Not in Repository)

| File | Purpose |
|------|---------|
| `build/Dockerfile` | Auto-generated Dockerfile with IC 19.x + libnsl symlink (base: kafka-42-rhel9:3.2.0) |
| `build/plugins/debezium-oracle-connector/` | Debezium 3.5.2, ojdbc11.jar (21.15.0.0), xstreams.jar (from IC 19.x), Groovy |
| `build/oracle-instantclient/lib/` | Oracle Instant Client 19.x native libraries (libclntsh.so.19.1, libocijdbc19.so, etc.) |
| `instantclient-basic-19.24.zip` | Downloaded Oracle Instant Client 19.24 Basic package (~85MB) |

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
│  - Oracle Instant Client 19.x (native OCI)              │
│  - ojdbc11 21.15.0.0 (JDBC driver)                      │
│  - xstreams.jar from IC 19.x                            │
│  - Debezium Oracle Connector 3.5.2                      │
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

### Option 1: Complete Namespace Deletion (Fastest)

Delete the entire namespace and recreate with secrets:

```bash
# Delete the entire strimzi namespace
oc delete namespace strimzi

# Wait for namespace deletion to complete
oc wait --for=delete namespace/strimzi --timeout=300s

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

### Option 2: Step-by-Step Cleanup (Keep Namespace and Secrets)

Clean up all resources without deleting the namespace:

```bash
# Step 1: Delete Kafka connectors
oc delete kafkaconnector --all -n strimzi

# Step 2: Delete Kafka Connect
oc delete kafkaconnect debezium-connect -n strimzi 2>/dev/null || echo "No KafkaConnect found"

# Step 3: Delete BuildConfigs and ImageStreams
oc delete bc debezium-connect -n strimzi 2>/dev/null || echo "No BuildConfig found"
oc delete is debezium-connect -n strimzi 2>/dev/null || echo "No ImageStream found"

# Step 4: Delete Oracle database
oc delete deployment oracle-db -n strimzi 2>/dev/null || echo "No Oracle deployment found"
oc delete service oracle-db -n strimzi 2>/dev/null || echo "No Oracle service found"

# Step 5: Delete Kafka cluster components
# Important: Delete NodePools first, then Kafka resource
oc delete knp broker controller -n strimzi 2>/dev/null || echo "No Kafka NodePools found"
oc delete kafka kafka-cluster -n strimzi 2>/dev/null || echo "No Kafka cluster found"

# Step 6: Delete Console UI
oc delete consoles.console.streamshub.github.com my-console -n strimzi 2>/dev/null || echo "No Console found"

# Step 7: Delete all PVCs (Kafka and Oracle storage)
oc delete pvc --all -n strimzi

# Step 8: Clean up service account and SCC
oc delete sa oracle-sa -n strimzi 2>/dev/null || echo "No service account found"
oc adm policy remove-scc-from-user anyuid -z oracle-sa -n strimzi 2>/dev/null || echo "SCC already removed"
```

**Important Notes:**
- **KafkaNodePools**: Must be deleted before or with the Kafka resource. The deployment creates `broker` and `controller` node pools.
- **Console**: Uses a custom resource `consoles.console.streamshub.github.com` that must be deleted separately.
- **PVCs**: Use `--all` to delete all persistent volume claims (Kafka broker, controller, and Oracle storage).
- **Secrets**: Preserved in both options so you don't need to recreate them.

### Option 3: Local Cleanup (Remove Downloaded Files)

If you cloned the repository locally and want to clean up downloaded files:

```bash
cd debezium-oracle-xstreams

# Remove build artifacts
rm -rf build/

# Remove downloaded Oracle components
rm -f instantclient-basic-19.24.zip
```

### Verification After Cleanup

```bash
# Verify namespace is clean (should show no pods or deployments)
oc get pods -n strimzi

# Verify no Kafka resources remain
oc get kafka,kafkaconnect,kafkaconnector,knp -n strimzi

# Verify no Console remains
oc get consoles.console.streamshub.github.com -n strimzi

# Verify no builds remain
oc get builds,bc,is -n strimzi

# Verify all PVCs are removed
oc get pvc -n strimzi

# Should show: "No resources found in strimzi namespace" for all commands above
# Secrets and service accounts are preserved
oc get secrets,sa -n strimzi
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

- [Debezium Oracle Connector Documentation](https://debezium.io/documentation/reference/stable/connectors/oracle.html)
- [Debezium 3.5 Oracle Connector](https://debezium.io/documentation/reference/3.5/connectors/oracle.html)
- [Debezium Supported Configurations for Oracle](https://debezium.io/documentation/reference/stable/connectors/oracle.html#oracle-supported-topologies)
- [Strimzi Documentation](https://strimzi.io/documentation/)
- [Oracle XStreams Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/xstrm/)
- [Oracle Instant Client 19.x Downloads](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html)
- [Oracle Database 19c Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/)

## License

See your organization's license terms for Debezium, Oracle, and Red Hat components.
