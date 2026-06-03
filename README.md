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

## Quick Start (Remote Deployment)

**Deploy everything without cloning the repository:**

```bash
# One-line deployment - no local files needed
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/deploy-all.sh)
```

This remote deployment will:
1. Deploy Kafka cluster and Console UI (auto-detects OpenShift domain)
2. Deploy Oracle database with proper security permissions
3. Extract OCI native libraries from Oracle pod
4. Build custom Kafka Connect image with OCI support
5. Deploy Kafka Connect cluster
6. Deploy and configure the Debezium Oracle connector

**Note:** You'll need to provide Quay.io credentials when prompted for the Oracle database image.

## Components

- **Debezium Oracle Connector**: 3.4.3.Final-redhat-00001
- **AMQ Streams Base Image**: 3.2.0 (contains Kafka 4.2)
- **Kafka Version**: 4.2.0
- **Strimzi**: Kubernetes Operator for Apache Kafka
- **Oracle XStreams**: Native CDC library
- **Groovy**: 3.0.x (scripting support)

**Note:** AMQ Streams and Kafka use different versioning:
- AMQ Streams image tag: `kafka-42-rhel9:3.2.0` (AMQ Streams 3.2.0)
- Kafka version inside: 4.2.0 (referenced in `deploy/kafka-connect.yaml`)

## Local Deployment

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

# Step 3: Extract OCI libraries and build Kafka Connect
./deploy/03-build-kafka-connect.sh

# Step 4: Deploy Kafka Connect and connector
./deploy/04-deploy-connector.sh
```

### Option 3: Step-by-Step Remote Deployment

Run individual deployment steps without cloning:

```bash
# Step 1: Deploy Kafka cluster and Console UI
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/01-deploy-kafka.sh)

# Step 2: Deploy Oracle database
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/02-deploy-oracle.sh)

# Step 3: Extract OCI libraries and build Kafka Connect
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/03-build-kafka-connect.sh)

# Step 4: Deploy Kafka Connect and connector
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
- Calls `deploy/extract-oci-libraries.sh` to extract OCI native libraries from Oracle pod
- Calls `deploy/download-dbz-oracle-xs-plugins.sh` to download Debezium plugins and Oracle drivers
- Calls `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` to build custom image
- Creates optimized `build/` directory with plugins and OCI libraries
- Builds and pushes custom Kafka Connect image to OpenShift registry

**Script 04: Deploy Connector** (`deploy/04-deploy-connector.sh`)
- Deploys Kafka Connect cluster using custom image
- Waits for Kafka Connect pod to be ready
- Applies Debezium Oracle connector configuration
- Verifies connector is running

### Manual YAML Deployment (Remote)

If you want to apply YAML files directly without cloning:

```bash
# Deploy Oracle database
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/oracle-complete.yaml

# Deploy Kafka Connect cluster
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafka-connect.yaml

# Deploy LogMiner connector (Phase 1 - simpler, working)
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer.yaml

# Or deploy XStreams connector (Phase 2 - requires OCI build)
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-xstreams-final.yaml
```

### Alternative: LogMiner vs XStreams

**LogMiner** (Phase 1 - Working):
- Uses JDBC Thin driver (pure Java, no native libraries)
- Performance: ~50,000 events/second
- Latency: 1-3 seconds
- Simpler setup, no OCI libraries needed
- Use: `deploy/kafkaconnector-oracle-logminer.yaml`

**XStreams** (Phase 2 - Requires OCI):
- Uses JDBC OCI driver (requires Oracle Instant Client)
- Performance: ~100,000+ events/second
- Latency: Sub-second
- Complex setup, requires 2.5GB Oracle Instant Client libraries
- Use: `deploy/kafkaconnector-oracle-xstreams-final.yaml`

## Verification

Check connector status:
```bash
# For LogMiner connector
oc get kafkaconnector inventory-connector-oracle-logminer -n strimzi -o yaml

# For XStreams connector
oc get kafkaconnector inventory-connector-oracle-xs -n strimzi -o yaml
```

View Kafka Connect logs:
```bash
oc logs -f debezium-connect-connect-0 -n strimzi
```

List Kafka topics:
```bash
oc exec -it kafka-cluster-kafka-0 -n strimzi -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

Access Kafka Console UI:
```bash
# Get the Console URL
oc get route my-console -n strimzi -o jsonpath='{.spec.host}'
```

## Troubleshooting

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

### Kafka Console UI Domain

The deployment scripts auto-detect the OpenShift cluster domain. If auto-detection fails, you'll be prompted to enter it manually.

To find your cluster domain:
```bash
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```

Example: `apps.cluster-name.region.domain.com`

### Oracle Pod Not Found

If the script cannot find the Oracle database pod:
```bash
# Verify the pod exists and has the correct label
oc get pods -n strimzi -l app=oracle-db

# Check pod status
oc get pods -n strimzi -l app=oracle-db -o wide
```

### Build Failures

Check Red Hat registry credentials:
```bash
oc get secret registry-redhat-io -n strimzi
```

View build logs:
```bash
oc logs -f bc/debezium-connect -n strimzi
```

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

### XStreams Specific Issues

If using XStreams connector and getting `SQLFeatureNotSupportedException: Unsupported feature: getOCIHandles`:
- This means the connector is using JDBC Thin driver instead of OCI driver
- XStreams requires Oracle Instant Client libraries (2.5GB)
- Ensure the Kafka Connect image was built with OCI libraries via `deploy/03-build-kafka-connect.sh`

## Project Structure

```
debezium-oracle-xstreams/
├── README.md                                    # This file
├── .gitignore                                   # Git ignore patterns
└── deploy/                                      # All deployment files
    ├── 01-deploy-kafka.sh                      # Step 1: Deploy Kafka cluster and Console UI
    ├── 02-deploy-oracle.sh                     # Step 2: Deploy Oracle database with SCC
    ├── 03-build-kafka-connect.sh               # Step 3: Extract OCI, download plugins, build image
    ├── 04-deploy-connector.sh                  # Step 4: Deploy connector configuration
    ├── deploy-all.sh                           # One-command automated deployment
    ├── extract-oci-libraries.sh                # Extract OCI native libraries from Oracle pod
    ├── download-dbz-oracle-xs-plugins.sh       # Download Debezium plugins and Oracle drivers
    ├── build-kafka-connect-dbz-oracle-xs-plugins.sh  # Build custom Kafka Connect image
    ├── oracle-complete.yaml                    # Oracle database deployment (PVC + Deployment + Service)
    ├── kafka-connect.yaml                      # Kafka Connect cluster configuration
    ├── kafkaconnector-oracle-logminer.yaml     # LogMiner connector (Phase 1 - working)
    └── kafkaconnector-oracle-xstreams-final.yaml  # XStreams connector (Phase 2 - requires OCI)
```

## File Descriptions

### Deployment Scripts

| File | Purpose | Can Run Remotely |
|------|---------|------------------|
| `deploy/deploy-all.sh` | One-command automated deployment of entire stack | ✅ Yes |
| `deploy/01-deploy-kafka.sh` | Deploy Kafka cluster and Console UI with auto-detected domain | ✅ Yes |
| `deploy/02-deploy-oracle.sh` | Deploy Oracle database with anyuid SCC permissions | ✅ Yes |
| `deploy/03-build-kafka-connect.sh` | Extract OCI, download plugins, build custom image | ✅ Yes |
| `deploy/04-deploy-connector.sh` | Deploy Kafka Connect and Debezium connector | ✅ Yes |

### Build Helper Scripts

| File | Purpose |
|------|---------|
| `deploy/extract-oci-libraries.sh` | Extract OCI native libraries from Oracle pod (2.5GB for XStreams) |
| `deploy/download-dbz-oracle-xs-plugins.sh` | Download Debezium plugins, extract Oracle drivers (xstreams.jar, ojdbc8.jar) |
| `deploy/build-kafka-connect-dbz-oracle-xs-plugins.sh` | Build and push custom Kafka Connect image to OpenShift registry |

### YAML Configurations

| File | Purpose | Can Apply Remotely |
|------|---------|---------------------|
| `deploy/oracle-complete.yaml` | Oracle database deployment (PVC + Deployment + Service) | ✅ Yes |
| `deploy/kafka-connect.yaml` | Kafka Connect cluster configuration with custom image | ✅ Yes |
| `deploy/kafkaconnector-oracle-logminer.yaml` | LogMiner connector config (Thin driver, 50k events/sec) | ✅ Yes |
| `deploy/kafkaconnector-oracle-xstreams-final.yaml` | XStreams connector config (OCI driver, 100k+ events/sec) | ✅ Yes |

### Generated Files (Not in Repository)

| File | Purpose |
|------|---------|
| `build/Dockerfile` | Auto-generated container image definition (base: kafka-42-rhel9:3.2.0) |
| `build/plugins/` | Auto-generated plugin directory with Debezium and Oracle JARs |
| `build/oci-libs/` | Extracted OCI native libraries from Oracle pod (for XStreams only) |

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
