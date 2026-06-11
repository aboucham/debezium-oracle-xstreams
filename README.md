# Debezium Oracle XStreams on OpenShift

Automated deployment of Debezium Oracle Connector with XStreams support on OpenShift using Strimzi Kafka.

## Overview

This project deploys a complete Change Data Capture (CDC) pipeline with:
- **Strimzi Kafka** (KRaft mode) - Event streaming platform  
- **Oracle Database 19c** - Source database with XStreams API enabled
- **Debezium Oracle Connector 3.4.3** - CDC connector using XStreams for high performance

**XStreams Performance:**
- **Throughput**: 100,000+ events/second (vs ~50,000 for LogMiner)
- **Latency**: Sub-second (vs 1-3 seconds)
- **Overhead**: Lower resource usage

## Prerequisites

- OpenShift cluster with Strimzi operator installed cluster-wide
- `oc` CLI tool configured and authenticated
- Cluster-admin rights (required for granting anyuid SCC to Oracle database)

### Required Secrets

**Create these secrets in the `strimzi` namespace before deployment:**

```bash
# Create namespace
oc create namespace strimzi

# 1. Red Hat Registry Pull Secret (for AMQ Streams base image)
oc create secret docker-registry registry-redhat-io \
  --docker-server=registry.redhat.io \
  --docker-username=YOUR_REDHAT_USERNAME \
  --docker-password=YOUR_REDHAT_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi

# Get credentials from: https://access.redhat.com/terms-based-registry/

# 2. Quay.io Pull Secret (for Oracle database image)
oc create secret docker-registry quay-pull-secret \
  --docker-server=quay.io \
  --docker-username=YOUR_QUAY_USERNAME \
  --docker-password=YOUR_QUAY_PASSWORD \
  --docker-email=YOUR_EMAIL \
  -n strimzi

# Verify secrets exist
oc get secrets -n strimzi | grep -E 'registry-redhat-io|quay-pull-secret'
```

## Remote Deployment Guide

Deploy everything without cloning the repository using 4 commands with verification at each step.

### Step 1: Deploy Infrastructure

Deploy Kafka cluster, Oracle database, and Kafka Connect with XStream support:

```bash
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/deploy-all.sh)
```

**What this does:**
- Deploys Kafka cluster (KRaft mode) and Console UI
- Deploys Oracle Database 19c with anyuid SCC
- Downloads Oracle Instant Client 19.x (native OCI libraries)
- Downloads ojdbc11.jar 21.15.0.0 (Debezium requirement)
- Extracts xstreams.jar from Instant Client package
- Builds and deploys custom Kafka Connect image
- Deploys Debezium Oracle connector with LogMiner (initial mode)

**Verify infrastructure is ready:**

```bash
# Check all pods are running
oc get pods -n strimzi

# Expected output:
# NAME                                  READY   STATUS    RESTARTS   AGE
# debezium-connect-connect-0            1/1     Running   0          5m
# kafka-cluster-broker-0                1/1     Running   0          10m
# kafka-cluster-controller-0            1/1     Running   0          10m
# my-console-...                        1/1     Running   0          10m
# oracle-db-...                         1/1     Running   0          8m

# Check Oracle database is ready (look for "DATABASE IS READY TO USE!")
oc logs -n strimzi $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') | grep "READY TO USE"
```

### Step 2: Configure Oracle Database

Configure Oracle users, permissions, create test table, and enable supplemental logging for CDC:

```bash
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/oracle-post-setup.sh)
```

**What this does:**
- Grants LogMiner and XStream privileges to `c##dbzuser`
- Restarts LogMiner connector to apply privileges

**Create CUSTOMERS table and enable supplemental logging:**

```bash
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')

# Create CUSTOMERS table and insert initial data
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s c##dbzuser/dbz@ORCLCDB <<'EOF'
CREATE TABLE CUSTOMERS (
  ID NUMBER(10) PRIMARY KEY,
  NAME VARCHAR2(100),
  EMAIL VARCHAR2(100)
);

INSERT INTO CUSTOMERS (ID, NAME, EMAIL) VALUES (1, 'Alice Smith', 'alice@example.com');
INSERT INTO CUSTOMERS (ID, NAME, EMAIL) VALUES (2, 'Bob Johnson', 'bob@example.com');
INSERT INTO CUSTOMERS (ID, NAME, EMAIL) VALUES (3, 'Charlie Brown', 'charlie@example.com');
COMMIT;
EXIT;
EOF
"

# Enable supplemental logging on CUSTOMERS table
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
ALTER TABLE C##DBZUSER.CUSTOMERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
EXIT;
EOF
"

# Restart connector to trigger snapshot of existing data
oc delete kafkaconnector oracle-logminer-connector -n strimzi
sleep 5
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml
sleep 15
```

**Verify Oracle configuration:**

```bash
# Check LogMiner connector is capturing changes
oc exec -n strimzi debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/oracle-logminer-connector/status | \
  jq '{connector: .connector.state, task: .tasks[0].state}'

# Expected: {"connector": "RUNNING", "task": "RUNNING"}

# Verify snapshot captured the 3 initial rows
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic oracle-logminer.C__DBZUSER.CUSTOMERS --from-beginning --max-messages 5 --timeout-ms 5000 2>/dev/null | \
  jq -r '.payload.after | "ID=\(.ID), NAME=\(.NAME), EMAIL=\(.EMAIL)"'

# Expected output: 3 rows (Alice, Bob, Charlie)

# Test LogMiner CDC is working (real-time streaming)
oc exec $ORACLE_POD -n strimzi -- sqlplus c##dbzuser/dbz@ORCLCDB <<'EOF'
INSERT INTO CUSTOMERS (ID, NAME, EMAIL) VALUES (9001, 'LogMiner Test', 'logminer@test.com');
COMMIT;
EXIT;
EOF

# Check event appeared in Kafka (should appear within 1-3 seconds)
sleep 3
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic oracle-logminer.C__DBZUSER.CUSTOMERS --from-beginning --max-messages 10 --timeout-ms 5000 2>/dev/null | \
  jq -r 'select(.payload.after.ID == 9001) | "✅ LogMiner CDC Working: ID=\(.payload.after.ID), NAME=\(.payload.after.NAME)"'
```

### Step 3: Setup XStream

Configure Oracle XStream outbound server and capture process:

```bash
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/setup-xstream.sh)
```

**What this does:**
- Creates XStream outbound server `DBZXOUT`
- Creates and starts XStream capture process
- Configures XStream to capture changes from `C##DBZUSER.CUSTOMERS`
- Connects `c##dbzuser` to the outbound server

**Verify XStream is ready:**

```bash
# Check XStream outbound server status
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET LINESIZE 150
SET PAGESIZE 50
COLUMN server_name FORMAT A15
COLUMN status FORMAT A15
COLUMN connect_user FORMAT A15
SELECT server_name, status, connect_user 
FROM DBA_XSTREAM_OUTBOUND 
WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"

# ✅ Expected: server_name=DBZXOUT, status=DETACHED, connect_user=C##DBZUSER
# DETACHED means XStream server is ready and waiting for a client to attach

# Check XStream capture process status
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET LINESIZE 150
SET PAGESIZE 50
COLUMN capture_name FORMAT A20
COLUMN status FORMAT A15
SELECT capture_name, status 
FROM DBA_CAPTURE 
WHERE capture_name LIKE 'CAP\$%DBZXOUT%';
EXIT;
EOF
"

# ✅ Expected: capture_name=CAP$_DBZXOUT_*, status=ENABLED
# ENABLED means the capture process is mining redo logs
```

**Understanding XStream Status:**

| Status | Location | Meaning |
|--------|----------|---------|
| **DETACHED** | `DBA_XSTREAM_OUTBOUND.status` | ✅ Server ready, waiting for Debezium client to attach |
| **ENABLED** | `DBA_CAPTURE.status` | ✅ Capture process is mining redo logs |
| **ATTACHED** | `DBA_XSTREAM_OUTBOUND.status` | ✅ Debezium client connected and streaming (after Step 4) |
| **IDLE** | `V$XSTREAM_OUTBOUND_SERVER.state` | ✅ Client attached, waiting for transactions |

### Step 4: Switch to XStream

Stop LogMiner connector and start XStream connector:

```bash
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/switch-to-xstream.sh)
```

**What this does:**
- Verifies XStream prerequisites are ready (DETACHED status, ENABLED capture)
- Stops LogMiner connector
- Starts XStream connector
- Waits for XStream to attach to Oracle

**Verify XStream connector is attached:**

```bash
# Check connector and task are running
oc exec -n strimzi debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/oracle-xstream-connector/status | \
  jq '{connector: .connector.state, task: .tasks[0].state}'

# ✅ Expected: {"connector": "RUNNING", "task": "RUNNING"}

# Check XStream server status changed from DETACHED to ATTACHED
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT server_name || ' | ' || status FROM DBA_XSTREAM_OUTBOUND WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"

# ✅ Expected: DBZXOUT | ATTACHED
# Status changed from DETACHED → ATTACHED means Debezium successfully connected

# Check XStream runtime status (V$ view only shows rows when client attached)
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET LINESIZE 150
SET PAGESIZE 50
COLUMN server_name FORMAT A15
COLUMN state FORMAT A20
SELECT server_name, state, total_messages_sent 
FROM V\$XSTREAM_OUTBOUND_SERVER 
WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"

# ✅ Expected: server_name=DBZXOUT, state=IDLE, total_messages_sent>0
# IDLE state = client connected and ready for transactions
# total_messages_sent > 0 = initial messages sent (snapshot data)
```

### Step 5: Test XStream CDC End-to-End

Verify XStream is capturing and streaming changes:

```bash
# Insert test data
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')
oc exec $ORACLE_POD -n strimzi -- sqlplus c##dbzuser/dbz@ORCLCDB <<'EOF'
INSERT INTO CUSTOMERS (ID, NAME, EMAIL) VALUES (99999, 'XStream Test', 'xstream@test.com');
COMMIT;
EXIT;
EOF

# Verify event appeared in Kafka (sub-second latency with XStream!)
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic oracle-xstream.C__DBZUSER.CUSTOMERS --from-beginning --max-messages 20 --timeout-ms 5000 2>/dev/null | \
  jq -r 'select(.payload.after.ID == 99999) | "✅ XStream CDC Working: ID=\(.payload.after.ID), NAME=\(.payload.after.NAME), OP=\(.payload.op)"'

# Check messages sent counter increased
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SET PAGESIZE 0
SET FEEDBACK OFF
SELECT 'Messages sent: ' || total_messages_sent FROM V\$XSTREAM_OUTBOUND_SERVER WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"

# ✅ Expected: Messages sent counter increases with each insert
```

**Success! XStream is now streaming changes at 100k+ events/second with sub-second latency.**

## Critical Dependencies for XStream

### The Three Essential Components

XStream requires a specific combination of components that work together:

**1. Oracle Instant Client 19.x** (Native OCI Libraries)
- **Purpose**: Provides native C libraries (`libclntsh.so.19.1`, `libocijdbc19.so`) for Oracle Call Interface (OCI)
- **Version Rule**: **Must match Oracle Database version** (19.x for Oracle 19c)
- **Why**: Native OCI libraries communicate directly with the database at the network protocol level
- **Size**: ~85MB
- **Location**: `/opt/oracle/instantclient/lib/` in Kafka Connect pod

**2. ojdbc11.jar (21.15.0.0)** (JDBC Driver)
- **Purpose**: JDBC driver layer that Debezium uses to communicate with Oracle
- **Version Rule**: **Debezium 3.4.3 requires ojdbc11 21.15.0.0** (documented requirement)
- **Why**: Backward compatible - ojdbc11 21.x works with Oracle 19c, 21c, 23c databases
- **Size**: ~5.0MB
- **Source**: Maven Central

**3. xstreams.jar** (XStream API)
- **Purpose**: Oracle's proprietary XStream client library for high-performance CDC
- **Version Rule**: **Must come from Instant Client 19.x package** (matches database)
- **Why**: XStream protocol compatibility requires matching version
- **Size**: ~31KB
- **Source**: Included in Oracle Instant Client 19.x package

### Why This Configuration?

```
┌─────────────────────────────────────────────────────┐
│  Debezium Connector (Java)                          │
│                                                      │
│  ┌────────────────────────────────────────────┐    │
│  │ JDBC Layer                                 │    │
│  │ • ojdbc11.jar (21.15.0.0)                  │◄───┼─── Backward compatible
│  │ • xstreams.jar (from IC 19.x)              │    │    Can be newer than DB
│  └─────────────┬──────────────────────────────┘    │
│                │ JNI (Java Native Interface)        │
│  ┌─────────────▼──────────────────────────────┐    │
│  │ Native OCI Layer (C libraries)             │    │
│  │ • Oracle Instant Client 19.x               │◄───┼─── Must match DB exactly
│  │ • libclntsh.so.19.1                        │    │    No flexibility
│  └─────────────┬──────────────────────────────┘    │
└────────────────┼────────────────────────────────────┘
                 │ XStream Protocol
┌────────────────▼────────────────────────────────────┐
│  Oracle Database 19.3.0.0.0                         │
└─────────────────────────────────────────────────────┘
```

**Key Points:**
- **JDBC layer (ojdbc11)**: Can be newer - provides backward compatibility
- **Native OCI layer (IC 19.x)**: Must exactly match database - no flexibility
- **Two separate layers**: This separation allows mixing versions correctly

### RHEL 9 Compatibility

Oracle Instant Client 19.x requires `libnsl.so.1` (from RHEL 8), but RHEL 9 only provides `libnsl.so.3`:

```dockerfile
# Install libnsl2 package (provides libnsl.so.3)
RUN microdnf install -y libaio libnsl2 && microdnf clean all

# Create compatibility symlink
RUN ln -sf /usr/lib64/libnsl.so.3 /usr/lib64/libnsl.so.1
```

### Common Mistakes to Avoid

❌ **DO NOT use Oracle Instant Client 21.x with Oracle Database 19c**
- Causes: `"Incompatible version of libocijdbc"`

❌ **DO NOT use ojdbc8.jar with Debezium 3.4.3**
- Debezium 3.4.3 requires ojdbc11 21.15.0.0

❌ **DO NOT extract xstreams.jar from Oracle database pod**
- Use xstreams.jar from Instant Client 19.x package instead

## Understanding XStream Status

### Status Flow During Deployment

```
Setup XStream (Step 3)           Switch to XStream (Step 4)         CDC Working
─────────────────────            ────────────────────────           ───────────

DBA_XSTREAM_OUTBOUND.status      DBA_XSTREAM_OUTBOUND.status       V$XSTREAM_OUTBOUND_SERVER.state
      DETACHED          ──────►        ATTACHED           ──────►           IDLE
  (ready for client)           (client connected)              (waiting for data)

DBA_CAPTURE.status               DBA_CAPTURE.status                total_messages_sent
      ENABLED                          ENABLED                    increasing with inserts
  (mining redo logs)           (mining redo logs)
```

### Status Reference

**DBA_XSTREAM_OUTBOUND.status:**
- `DETACHED` - Server configured and ready, waiting for Debezium to connect
- `ATTACHED` - Debezium connector successfully connected and streaming
- `ENABLED` - Alternative ready state (less common)

**DBA_CAPTURE.status:**
- `ENABLED` - Capture process is running and mining redo logs
- `DISABLED` - Capture process is stopped (needs troubleshooting)

**V$XSTREAM_OUTBOUND_SERVER.state:**
- `IDLE` - Client connected, waiting for transactions (normal operational state)
- `WAITING FOR CLIENT` - Server waiting for client (rare)
- (No rows) - No client connected (before switch-to-xstream)

**V$XSTREAM_OUTBOUND_SERVER.total_messages_sent:**
- Starts at 0 or small number (snapshot messages)
- Increases with each database change
- If not increasing after inserts → troubleshoot

## Troubleshooting

### Missing Required Secrets

**Symptoms:** `ImagePullBackOff` on Oracle pod or build fails with registry authentication error

**Solution:**
```bash
# Verify secrets exist
oc get secrets -n strimzi | grep -E 'registry-redhat-io|quay-pull-secret'

# If missing, create them (see Prerequisites section)
```

### XStream Status is Not DETACHED After Step 3

**Symptoms:** XStream server status shows something other than DETACHED

**Solution:**
```bash
# Re-run XStream setup
bash <(curl -s https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/setup-xstream.sh)

# Check Oracle logs for errors
oc logs -n strimzi $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') --tail=100
```

### XStream Does Not Change to ATTACHED After Step 4

**Symptoms:** Status remains DETACHED after running switch-to-xstream

**Solution:**
```bash
# Check connector status for errors
oc exec -n strimzi debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/oracle-xstream-connector/status | jq .

# Check Kafka Connect logs
oc logs -n strimzi debezium-connect-connect-0 --tail=100 | grep -i error

# Verify connector configuration
oc get kafkaconnector oracle-xstream-connector -n strimzi -o yaml
```

### Version Mismatch Errors

**Error:** `"Incompatible version of libocijdbc"`

**Cause:** Oracle Instant Client version doesn't match Oracle Database version

**Solution:**
- Oracle Database 19c requires Instant Client 19.x (not 21.x or 23.x)
- Rebuild Kafka Connect image with correct IC version

### ORA-24962 Error in Oracle Logs

**Error:** `ORA-24962: connect string could not be parsed, error = 303`

**Impact:** This is a **benign error** - XStream continues to work despite this error appearing in Oracle alert log

**Explanation:** Oracle 19c logging issue with internal connection string parsing. The error appears in logs but does not prevent XStream from functioning. You can safely ignore it if:
- XStream server status is ATTACHED
- Capture process status is ENABLED  
- Events are flowing to Kafka

### Events Not Appearing in Kafka

**Check:**
```bash
# 1. Verify connector is running
oc exec -n strimzi debezium-connect-connect-0 -- \
  curl -s http://localhost:8083/connectors/oracle-xstream-connector/status

# 2. Verify XStream is attached
ORACLE_POD=$(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}')
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SELECT status FROM DBA_XSTREAM_OUTBOUND WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"

# 3. Check supplemental logging is enabled
oc exec $ORACLE_POD -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SELECT supplemental_log_data_min FROM V\$DATABASE;
SELECT table_name, log_group_type FROM DBA_LOG_GROUPS WHERE owner = 'C##DBZUSER';
EXIT;
EOF
"
```

## Cleanup

### Complete Cleanup (Delete Everything)

```bash
# Delete the entire namespace
oc delete namespace strimzi

# Wait for deletion to complete
oc wait --for=delete namespace/strimzi --timeout=300s

# Recreate namespace and secrets for fresh start
oc create namespace strimzi

# Recreate required secrets (see Prerequisites section)
```

### Remove Downloaded Files (Local)

```bash
cd debezium-oracle-xstreams
rm -rf build/
rm -f instantclient-basic-19.24.zip
```

## Access Kafka Console UI

```bash
# Get Console URL
oc get route my-console -n strimzi -o jsonpath='{.spec.host}'

# Open in browser
echo "https://$(oc get route my-console -n strimzi -o jsonpath='{.spec.host}')"
```

## Components

- **Debezium Oracle Connector**: 3.4.3.Final
- **Oracle Database**: 19.3.0.0.0 Enterprise Edition
- **Oracle Instant Client**: 19.x (native OCI libraries)
- **Oracle JDBC Driver**: ojdbc11 21.15.0.0
- **Oracle XStreams**: xstreams.jar from IC 19.x
- **Strimzi**: Kubernetes Operator for Apache Kafka
- **Kafka**: 4.2.0 (KRaft mode)

## References

- [Debezium Oracle Connector Documentation](https://debezium.io/documentation/reference/stable/connectors/oracle.html)
- [Oracle XStreams Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/xstrm/)
- [Oracle Instant Client Downloads](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html)
- [Strimzi Documentation](https://strimzi.io/documentation/)
- [Oracle Database 19c Documentation](https://docs.oracle.com/en/database/oracle/oracle-database/19/)

## License

See your organization's license terms for Debezium, Oracle, and Red Hat components.
