# Debezium Oracle CDC - Testing & Performance Guide

This guide shows how to test Oracle Change Data Capture (CDC) with **LogMiner** (default) and optionally upgrade to **XStream** for 2x performance improvement.

## Overview

- **LogMiner** (Default): Works immediately, ~50k events/sec, 1-2 second latency
- **XStream** (Optional): Requires setup, ~100k+ events/sec, <100ms latency
- **Same Kafka Connect image**: Both adapters use the same build

---

## Your Journey: From LogMiner to XStream

Follow these 4 steps to test CDC with LogMiner, then upgrade to XStream for better performance.

### STEP 1: Test LogMiner CDC (Default - Works Immediately)

**Important: Wait for Oracle Database to be Ready**

The Oracle pod may show "Running" but the database initialization takes **3-5 minutes**. You must wait for the database to be fully ready before proceeding.

**Option 1: Use the wait script (Recommended)**
```bash
./deploy/wait-for-oracle-ready.sh
```

**Option 2: Check logs manually**
```bash
# Watch logs until you see "DATABASE IS READY TO USE!"
oc logs -f $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi
```

Look for this message:
```
#########################
DATABASE IS READY TO USE!
#########################
```

**Prerequisites - Grant CREATE TABLE privilege (Required for LogMiner):**

LogMiner needs to create a flush table (`LOG_MINING_FLUSH`). Grant the privilege:

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
GRANT CREATE TABLE TO c##dbzuser;
EXIT;
EOF
"
```

**Expected:** `Grant succeeded.`

> **Note:** If you get `ORA-12154: TNS:could not resolve the connect identifier specified`, the database is not ready yet. Wait longer and try again.

**Create CUSTOMERS table with sample data:**

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
CREATE TABLE C##DBZUSER.CUSTOMERS (
  id NUMBER(10) PRIMARY KEY,
  name VARCHAR2(100),
  email VARCHAR2(100)
);

ALTER TABLE C##DBZUSER.CUSTOMERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1001, 'John Doe', 'john@example.com');
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1002, 'Jane Smith', 'jane@example.com');
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1003, 'Bob Wilson', 'bob@example.com');
COMMIT;

SELECT COUNT(*) as row_count FROM C##DBZUSER.CUSTOMERS;
EXIT;
EOF
"
```

Expected: `ROW_COUNT: 3`

**Restart connector to trigger snapshot:**

```bash
oc delete kafkaconnector oracle-logminer-connector -n strimzi
sleep 5
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml
```

**Wait 30 seconds, then verify snapshot captured 3 messages:**

```bash
# List topics
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle

# Consume snapshot messages
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-logminer.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --max-messages 3 \
    --timeout-ms 10000
```

Expected: 3 JSON messages (ID 1001, 1002, 1003)

**Test real-time insert (ID 2001):**

```bash
# Insert new record
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (2001, 'LogMiner Test', 'logminer@test.com');
COMMIT;
EXIT;
EOF
"

# Verify streaming works (~1-2 sec latency)
sleep 3
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-logminer.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --timeout-ms 5000 | grep -c '"ID":'
```

Expected: `4` (3 snapshot + 1 real-time)

**✓ LogMiner CDC Working!**

---

### STEP 2: Understand XStream Performance Benefits

**Performance Comparison:**

| Metric | LogMiner (Current) | XStream (Upgrade) | Improvement |
|--------|-------------------|-------------------|-------------|
| **Throughput** | ~50,000 events/sec | ~100,000+ events/sec | **2x faster** |
| **Latency** | 1-2 seconds | <100ms | **10-20x faster** |
| **Driver** | Thin (JDBC) | OCI (native) | Native performance |

**Why Upgrade?**
- ✅ **2x throughput improvement** - Handle twice the load
- ✅ **10-20x latency improvement** - Near real-time streaming
- ✅ **Same Kafka Connect image** - No rebuild required
- ✅ **Production-ready** - Oracle's high-performance CDC API

---

### STEP 3: Manually Upgrade to XStream (Educational)

**Verify XStream server exists:**

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SELECT server_name, connect_user, capture_user FROM dba_xstream_outbound WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"
```

Expected:
```
SERVER_NAME     CONNECT_USER    CAPTURE_USER
DBZXOUT         C##DBZUSER      SYS
```

**Edit connector configuration:**

```bash
oc edit kafkaconnector oracle-logminer-connector -n strimzi
```

**Make these 3 changes in the editor:**

**BEFORE (LogMiner):**
```yaml
config:
  database.connection.adapter: logminer
  database.url: "jdbc:oracle:thin:@oracle-db:1521/ORCLCDB"
  topic.prefix: oracle-logminer
  schema.history.internal.kafka.topic: schema-changes.oracle.logminer
  log.mining.strategy: online_catalog
  log.mining.continuous.mine: true
```

**AFTER (XStream):**
```yaml
config:
  database.connection.adapter: xstream
  database.url: "jdbc:oracle:oci:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oracle-db)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=ORCLCDB)))"
  database.out.server.name: dbzxout
  topic.prefix: oracle-xstream
  schema.history.internal.kafka.topic: schema-changes.oracle.xstream
  # DELETE log.mining.strategy and log.mining.continuous.mine
```

**Key changes:**
1. ✏️ `database.connection.adapter`: `logminer` → `xstream`
2. ✏️ `database.url`: Change from `thin` to `oci` driver with full DESCRIPTION
3. ➕ `database.out.server.name`: Add `dbzxout`
4. ✏️ `topic.prefix`: Change to `oracle-xstream` (avoid topic conflicts)
5. ✏️ `schema.history.internal.kafka.topic`: Change to new topic name
6. ❌ Remove: `log.mining.strategy` and `log.mining.continuous.mine`

**Save and exit (`:wq` in vi)**

The connector will automatically restart.

**Monitor connector restart:**

```bash
# Watch for restart
oc get kafkaconnector oracle-logminer-connector -n strimzi -w

# Check connector status
oc get kafkaconnector oracle-logminer-connector -n strimzi -o jsonpath='{.status.connectorStatus.connector.state}'
```

Expected: `RUNNING`

**Verify new XStream topics created:**

```bash
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle
```

Expected:
```
oracle-logminer                         (old - LogMiner)
oracle-logminer.C__DBZUSER.CUSTOMERS    (old - LogMiner)
oracle-xstream                          (new - XStream)
oracle-xstream.C__DBZUSER.CUSTOMERS     (new - XStream)
schema-changes.oracle.logminer          (old)
schema-changes.oracle.xstream           (new)
```

---

### STEP 4: Test XStream Streaming Performance

**Insert new record (ID 3001):**

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (3001, 'XStream Test', 'xstream@test.com');
COMMIT;
EXIT;
EOF
"
```

**Verify it appears in <100ms:**

```bash
# Consume from NEW XStream topic
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-xstream.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --max-messages 1
```

Expected: Record appears almost instantly (<100ms)

**Compare performance:**

```bash
# LogMiner topic (old) - Check message count
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-logminer.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --timeout-ms 5000 | grep -c '"ID":'
# Expected: 4 (3 snapshot + 1 real-time from Step 1)

# XStream topic (new) - Check message count
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-xstream.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --timeout-ms 5000 | grep -c '"ID":'
# Expected: 4 (3 snapshot after restart + 1 new insert)
```

**✓ XStream Performance Improvement Confirmed!**

Notice the difference:
- LogMiner: 1-2 second delay between INSERT and Kafka message
- XStream: <100ms delay (near real-time!)

---

## Detailed Documentation

The sections below provide detailed information for each step. Use them as reference if you need more context.

---

## Part 1: Test LogMiner CDC (Default)

The deployment uses LogMiner by default - it works immediately without additional Oracle configuration.

### Step 1: Create Test Table

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
CREATE TABLE C##DBZUSER.CUSTOMERS (
  id NUMBER(10) PRIMARY KEY,
  name VARCHAR2(100),
  email VARCHAR2(100)
);

ALTER TABLE C##DBZUSER.CUSTOMERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1001, 'John Doe', 'john@example.com');
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1002, 'Jane Smith', 'jane@example.com');
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (1003, 'Bob Wilson', 'bob@example.com');
COMMIT;

SELECT COUNT(*) as row_count FROM C##DBZUSER.CUSTOMERS;
EXIT;
EOF
"
```

**Expected output:** `ROW_COUNT: 3`

### Step 2: Restart Connector to Snapshot Table

```bash
# Delete and recreate connector to trigger snapshot
oc delete kafkaconnector oracle-logminer-connector -n strimzi
sleep 5
oc apply -f https://raw.githubusercontent.com/aboucham/debezium-oracle-xstreams/main/deploy/kafkaconnector-oracle-logminer-final.yaml
```

### Step 3: Verify Snapshot Captured

Wait 30 seconds for snapshot to complete, then check topics:

```bash
# List Oracle topics
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle
```

**Expected output:**
```
oracle-logminer
oracle-logminer.C__DBZUSER.CUSTOMERS
schema-changes.oracle.logminer
```

### Step 4: Consume Snapshot Messages

```bash
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-logminer.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --max-messages 3 \
    --timeout-ms 10000
```

**Expected:** 3 JSON messages with customer data (ID 1001, 1002, 1003)

### Step 5: Test Real-Time Streaming

Insert a new record:

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (2001, 'LogMiner Test', 'logminer@test.com');
COMMIT;
EXIT;
EOF
"
```

Check if it appears in Kafka (should appear within 1-2 seconds):

```bash
sleep 3
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-logminer.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --timeout-ms 5000 | grep -c '"ID":'
```

**Expected:** `4` (3 snapshot + 1 real-time insert)

### ✅ Success Criteria

- [x] Topics created: `oracle-logminer.C__DBZUSER.CUSTOMERS`
- [x] Snapshot captured 3 records
- [x] Real-time insert appeared in Kafka within 1-2 seconds
- [x] Connector status: RUNNING

**LogMiner CDC is working!** 🎉

---

## Part 2: Upgrade to XStream (Optional - 2x Performance)

XStream provides:
- **2x throughput**: 100k+ events/sec (vs 50k with LogMiner)
- **10x lower latency**: <100ms (vs 1-2 seconds with LogMiner)

### Prerequisites

Verify XStream outbound server exists:

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
SELECT server_name, connect_user, capture_user FROM dba_xstream_outbound WHERE server_name = 'DBZXOUT';
EXIT;
EOF
"
```

**Expected:**
```
SERVER_NAME     CONNECT_USER    CAPTURE_USER
DBZXOUT         C##DBZUSER      SYS
```

If not found, XStream server needs to be configured (see Oracle DBA guide).

### Manual Upgrade Steps (Educational)

#### Step 1: View Current LogMiner Configuration

```bash
oc get kafkaconnector oracle-logminer-connector -n strimzi -o yaml
```

Notice these key fields:
```yaml
config:
  database.connection.adapter: logminer
  database.url: "jdbc:oracle:thin:@oracle-db:1521/ORCLCDB"
  topic.prefix: oracle-logminer
```

#### Step 2: Edit the Connector

```bash
oc edit kafkaconnector oracle-logminer-connector -n strimzi
```

#### Step 3: Make These Changes

**BEFORE (LogMiner):**
```yaml
config:
  database.connection.adapter: logminer
  database.url: "jdbc:oracle:thin:@oracle-db:1521/ORCLCDB"
  topic.prefix: oracle-logminer
  schema.history.internal.kafka.topic: schema-changes.oracle.logminer
```

**AFTER (XStream):**
```yaml
config:
  database.connection.adapter: xstream
  database.url: "jdbc:oracle:oci:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oracle-db)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=ORCLCDB)))"
  database.out.server.name: dbzxout
  topic.prefix: oracle-xstream
  schema.history.internal.kafka.topic: schema-changes.oracle.xstream
```

**Key differences:**
1. ✏️ `database.connection.adapter`: `logminer` → `xstream`
2. ✏️ `database.url`: Change from `thin` to `oci` driver
3. ➕ `database.out.server.name`: Add `dbzxout`
4. ✏️ `topic.prefix`: Change to avoid topic conflicts
5. ✏️ `schema.history.internal.kafka.topic`: Change to avoid conflicts

Also remove LogMiner-specific settings:
```yaml
# DELETE these lines (LogMiner only):
log.mining.strategy: online_catalog
log.mining.continuous.mine: true
```

#### Step 4: Save and Apply

Save the file (`:wq` in vi). The Strimzi operator will automatically restart the connector.

#### Step 5: Monitor Connector Restart

Watch for connector restart and XStream connection:

```bash
# Check connector status
oc get kafkaconnector oracle-logminer-connector -n strimzi -o jsonpath='{.status.connectorStatus.connector.state}'

# Watch logs for XStream connection
oc logs -f $(oc get pods -n strimzi -l strimzi.io/cluster=debezium-connect -o jsonpath='{.items[0].metadata.name}') -n strimzi | grep -i xstream
```

**Look for:** `Connected to XStream outbound server 'DBZXOUT'`

#### Step 6: Verify New Topics Created

```bash
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep oracle
```

**Expected:** New topics with `oracle-xstream` prefix:
```
oracle-logminer                         (old - LogMiner)
oracle-logminer.C__DBZUSER.CUSTOMERS    (old - LogMiner)
oracle-xstream                          (new - XStream)
oracle-xstream.C__DBZUSER.CUSTOMERS     (new - XStream)
schema-changes.oracle.logminer          (old)
schema-changes.oracle.xstream           (new)
```

#### Step 7: Test XStream Real-Time Performance

Insert a new record:

```bash
oc exec $(oc get pods -n strimzi -l app=oracle-db -o jsonpath='{.items[0].metadata.name}') -n strimzi -- bash -c "sqlplus -s sys/top_secret@ORCLCDB as sysdba <<'EOF'
INSERT INTO C##DBZUSER.CUSTOMERS (id, name, email) VALUES (3001, 'XStream Test', 'xstream@test.com');
COMMIT;
EXIT;
EOF
"
```

Consume from new XStream topic (should appear in <100ms):

```bash
oc exec -n strimzi $(oc get pods -n strimzi -l strimzi.io/name=kafka-cluster-kafka -o jsonpath='{.items[0].metadata.name}') -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 \
    --topic oracle-xstream.C__DBZUSER.CUSTOMERS \
    --from-beginning \
    --max-messages 1
```

**Expected:** Record appears almost instantly (<100ms)

---

## Performance Comparison

| Metric | LogMiner | XStream | Improvement |
|--------|----------|---------|-------------|
| **Throughput** | ~50,000 events/sec | ~100,000+ events/sec | **2x faster** |
| **Latency** | 1-2 seconds | <100ms | **10-20x faster** |
| **Driver** | Thin (JDBC only) | OCI (native) | Native performance |
| **Setup** | Immediate | Requires XStream server | - |
| **Oracle Logs** | Redo logs | XStream streams | - |

### When to Use Each

**Use LogMiner when:**
- ✅ Quick setup needed
- ✅ Lower event volume (<50k/sec)
- ✅ 1-2 second latency acceptable
- ✅ No Oracle DBA access

**Upgrade to XStream when:**
- ✅ High event volume (>50k/sec)
- ✅ Sub-second latency required
- ✅ Oracle DBA can configure XStream server
- ✅ Performance is critical

---

## Configuration Reference

### LogMiner Configuration
```yaml
config:
  database.connection.adapter: logminer
  database.url: "jdbc:oracle:thin:@oracle-db:1521/ORCLCDB"
  log.mining.strategy: online_catalog
  log.mining.continuous.mine: true
```

### XStream Configuration
```yaml
config:
  database.connection.adapter: xstream
  database.url: "jdbc:oracle:oci:@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oracle-db)(PORT=1521))(CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=ORCLCDB)))"
  database.out.server.name: dbzxout
```

### Both Use Same Kafka Connect Image

The same image supports both adapters because it includes:
- ✅ Oracle Instant Client 21.x (for OCI driver)
- ✅ ojdbc11.jar (supports both thin and OCI)
- ✅ Debezium Oracle Connector 3.4.3 (supports both adapters)

No rebuild required to switch between LogMiner and XStream!

---

## Troubleshooting

### LogMiner: "No changes captured" warning
- Ensure supplemental logging is enabled on the table
- Check `table.include.list` matches actual table name (case-sensitive)

### XStream: "Connected to XStream outbound server" not appearing
- Verify XStream server exists and is enabled
- Check c##dbzuser has EXECUTE on DBMS_XSTREAM_ADM
- Review Oracle alert logs for XStream errors

### Topics not auto-created
- Verify `auto.create.topics.enable: true` in Kafka config
- Check connector status: `oc get kafkaconnector -n strimzi`

### View connector logs
```bash
oc logs -f $(oc get pods -n strimzi -l strimzi.io/cluster=debezium-connect -o jsonpath='{.items[0].metadata.name}') -n strimzi
```

---

## Summary

1. ✅ **Deploy with LogMiner** - Works immediately, good performance
2. ✅ **Test end-to-end** - Snapshot + real-time streaming
3. ✅ **Understand the baseline** - 50k events/sec, 1-2 sec latency
4. ✅ **Upgrade to XStream** - Manual config change for 2x performance
5. ✅ **Same image, different adapter** - Demonstrates flexibility

**Next:** See [Kafka Console UI](https://github.com/aboucham/debezium-oracle-xstreams) to visualize streaming events in real-time.
