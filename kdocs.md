# Kafka Administration: Complete Reference Guide

A comprehensive, beginner-friendly guide to Apache Kafka CLI commands, admin tasks, tools, directory structure, and real-world use cases. Explained in simple (middle-school) terms.

> **Version note:** This guide targets the **latest Kafka, 4.3.0** (released May 2026), distributed as `kafka_2.13-4.3.0.tgz` and requiring **Java 17 or newer**. The biggest change in the 4.x line: **Kafka no longer uses ZooKeeper at all** — it runs purely in **KRaft mode**, where Kafka manages its own metadata. ZooKeeper commands and configs still appear in older 3.x installs, so they’re noted here as *legacy* where relevant.

-----

## Table of Contents

1. [Mental Model: What Is Kafka?](#1-mental-model-what-is-kafka)
1. [Where the Commands Live (Default Paths)](#2-where-the-commands-live-default-paths)
1. [Kafka Directory Structure](#3-kafka-directory-structure)
1. [CLI Commands with Example Outputs](#4-cli-commands-with-example-outputs)
1. [Complete `bin/` Directory Reference (Every Script)](#5-complete-bin-directory-reference-every-script)
1. [Kafka Connect from the CLI](#6-kafka-connect-from-the-cli)
1. [Complete `config/` Directory Reference (Every File)](#7-complete-config-directory-reference-every-file)
1. [Admin Tasks Explained Simply](#8-admin-tasks-explained-simply)
1. [Tools Beyond the CLI](#9-tools-beyond-the-cli)
1. [Use Cases (Real-World Scenarios)](#10-use-cases-real-world-scenarios)
1. [Cheat Sheet: Task → Tool](#11-cheat-sheet-task--tool)
1. [Quick Tips & Gotchas](#12-quick-tips--gotchas)

-----

## 1. Mental Model: What Is Kafka?

Think of Kafka like a giant **post office** for data. Messages get sent in, sorted into mailboxes (called **topics**), and picked up by whoever needs them. As an admin, you’re the **postmaster**: you set up mailboxes, check that mail is flowing, fix jams, and make sure nobody loses their letters.

A few key words you’ll see everywhere:

|Term                  |Simple meaning                                                                                                |
|----------------------|--------------------------------------------------------------------------------------------------------------|
|**Broker**            |One Kafka server. A cluster is a team of brokers working together.                                            |
|**Topic**             |A labeled folder where similar messages go (e.g. `orders`, `logins`).                                         |
|**Partition**         |A “drawer” inside a topic. Splitting into drawers lets many people work at once.                              |
|**Replication factor**|How many photocopies of each drawer exist on different servers, so nothing is lost if one breaks.             |
|**Producer**          |Something that sends messages in.                                                                             |
|**Consumer**          |Something that reads messages out.                                                                            |
|**Consumer group**    |A team of consumers sharing the reading work.                                                                 |
|**Offset**            |A bookmark — which message a consumer has read up to.                                                         |
|**Lag**               |How many messages are piling up unread (consumers falling behind).                                            |
|**ZooKeeper / KRaft** |The “manager” that keeps the cluster organized. Older Kafka used ZooKeeper; newer Kafka uses KRaft (built in).|

-----

## 2. Where the Commands Live (Default Paths)

Kafka’s command-line tools are scripts that ship inside the folder you download. The exact location depends on **how** you installed Kafka.

### Vanilla Apache Kafka (downloaded `.tgz`)

When you unzip the official download, everything sits under one folder, commonly called `$KAFKA_HOME`.

```
/opt/kafka/                         <- a common choice for $KAFKA_HOME
~/kafka_2.13-4.3.0/                 <- if you unzipped it in your home folder
```

The scripts are in the `bin/` subfolder:

|Operating system|Default script path    |File extension|
|----------------|-----------------------|--------------|
|Linux / macOS   |`/opt/kafka/bin/`      |`.sh`         |
|Windows         |`C:\kafka\bin\windows\`|`.bat`        |

So the full path to a command looks like:

```bash
# Linux / macOS
/opt/kafka/bin/kafka-topics.sh ...

# Windows
C:\kafka\bin\windows\kafka-topics.bat ...
```

**Tip:** Add `bin/` to your `PATH` so you can just type `kafka-topics.sh` from anywhere:

```bash
export KAFKA_HOME=/opt/kafka
export PATH=$PATH:$KAFKA_HOME/bin
```

### Package-manager and vendor installs

Different installers put files in different places. Here are the common ones:

|Install method          |Scripts location                                                 |Notes                                                             |
|------------------------|-----------------------------------------------------------------|------------------------------------------------------------------|
|Apache `.tgz` (manual)  |`$KAFKA_HOME/bin/`                                               |You choose where to unzip.                                        |
|Homebrew (macOS)        |`/opt/homebrew/bin/` (Apple Silicon) or `/usr/local/bin/` (Intel)|Scripts are symlinked, no `.sh` suffix (e.g. just `kafka-topics`).|
|Confluent Platform (tar)|`$CONFLUENT_HOME/bin/`                                           |Adds extra tools like `confluent`, `kafka-rest`.                  |
|Confluent (deb/rpm)     |`/usr/bin/`                                                      |Scripts named without `.sh` (e.g. `kafka-topics`).                |
|Docker image            |`/opt/kafka/bin/` or `/usr/bin/` inside the container            |Run via `docker exec -it <container> kafka-topics.sh ...`         |

### Default config files

Configuration files live in the `config/` folder:

```
$KAFKA_HOME/config/server.properties      <- broker settings (ZooKeeper mode)
$KAFKA_HOME/config/kraft/server.properties <- broker settings (KRaft mode)
$KAFKA_HOME/config/zookeeper.properties    <- ZooKeeper settings (older clusters)
$KAFKA_HOME/config/consumer.properties     <- default consumer settings
$KAFKA_HOME/config/producer.properties     <- default producer settings
```

### Default data and log locations

|What                                                       |Default path                               |Set by                             |
|-----------------------------------------------------------|-------------------------------------------|-----------------------------------|
|Message data (“log dirs”)                                  |`/tmp/kraft-combined-logs` (sample default)|`log.dirs` in `server.properties`  |
|ZooKeeper data                                             |`/tmp/zookeeper`                           |`dataDir` in `zookeeper.properties`|
|Broker operational logs (text logs about the server itself)|`$KAFKA_HOME/logs/`                        |`log4j` config                     |


> ⚠️ **Important:** The sample `log.dirs` points under `/tmp` (e.g. `/tmp/kraft-combined-logs`), which is fine for testing but **terrible for production** — many systems wipe `/tmp` on reboot, which deletes all your data. Always change `log.dirs` to a permanent disk in real deployments.

-----

## 3. Kafka Directory Structure

Here’s what a freshly unzipped Kafka folder looks like:

```
kafka_2.13-4.3.0/
├── bin/                       # All the CLI commands (the tools) — full list in Section 5
│   ├── kafka-topics.sh
│   ├── kafka-console-producer.sh
│   ├── kafka-console-consumer.sh
│   ├── kafka-consumer-groups.sh
│   ├── kafka-configs.sh
│   ├── kafka-acls.sh
│   ├── kafka-reassign-partitions.sh
│   ├── kafka-server-start.sh
│   ├── kafka-server-stop.sh
│   ├── kafka-storage.sh           # format storage (required in KRaft)
│   ├── kafka-metadata-quorum.sh   # inspect KRaft controllers
│   ├── connect-distributed.sh     # Kafka Connect (cluster mode)
│   ├── connect-standalone.sh      # Kafka Connect (single process)
│   ├── kafka-streams-application-reset.sh
│   └── windows/               # .bat versions of every script
│       ├── kafka-topics.bat
│       └── ...
├── config/                    # Configuration files — full list in Section 7
│   ├── server.properties      # Main broker+controller config (KRaft; the default in 4.x)
│   ├── consumer.properties
│   ├── producer.properties
│   ├── connect-distributed.properties   # Connect worker (cluster)
│   ├── connect-standalone.properties    # Connect worker (single)
│   ├── connect-log4j2.yaml
│   ├── connect-file-source.properties   # example connector
│   ├── connect-file-sink.properties     # example connector
│   ├── log4j2.yaml            # logging config (was log4j.properties pre-4.0)
│   ├── tools-log4j2.yaml
│   └── kraft/                 # Role-specific KRaft samples
│       ├── server.properties      # combined broker + controller
│       ├── broker.properties      # broker-only role
│       └── controller.properties  # controller-only role
├── libs/                      # Java .jar files Kafka needs to run (don't touch)
├── logs/                      # Text logs about the running server
├── licenses/                  # Legal stuff
├── LICENSE
└── NOTICE
```

> In **Kafka 4.x** there is no `zookeeper.properties` and no `zookeeper-*` scripts — they were removed. If you see those, you’re looking at a 3.x (or older) install.

And here’s what the **data directory** (`log.dirs`) looks like once Kafka is running and you’ve created a topic called `orders` with 2 partitions:

```
/tmp/kraft-combined-logs/              # or your configured log.dirs path
├── orders-0/                          # Partition 0 of "orders"
│   ├── 00000000000000000000.log       # The actual messages, stored in segments
│   ├── 00000000000000000000.index     # Speeds up finding messages by offset
│   ├── 00000000000000000000.timeindex # Speeds up finding messages by time
│   └── leader-epoch-checkpoint
├── orders-1/                          # Partition 1 of "orders"
│   ├── 00000000000000000000.log
│   ├── 00000000000000000000.index
│   └── 00000000000000000000.timeindex
├── __consumer_offsets-0/              # Internal topic: tracks consumer bookmarks
│   └── ... (50 of these by default)
├── meta.properties                    # Identifies this broker / cluster
├── recovery-point-offset-checkpoint
└── replication-offset-checkpoint
```

**What this means in plain terms:** each topic-partition is its own subfolder. Inside, messages are written into `.log` “segment” files (like pages in a notebook). The `.index` and `.timeindex` files are like a table of contents that helps Kafka jump straight to the right message instead of reading from the start every time.

-----

## 4. CLI Commands with Example Outputs

> All examples assume `bin/` is on your `PATH`. Otherwise, prefix with the full path (e.g. `/opt/kafka/bin/kafka-topics.sh`).
> 
> `--bootstrap-server localhost:9092` tells the command which broker to talk to. Port **9092** is Kafka’s default.

### 4.1 Topic Management — `kafka-topics.sh`

**Create a topic:**

```bash
kafka-topics.sh --create --topic orders \
  --bootstrap-server localhost:9092 \
  --partitions 3 --replication-factor 2
```

Expected output:

```
Created topic orders.
```

**List all topics:**

```bash
kafka-topics.sh --list --bootstrap-server localhost:9092
```

Expected output:

```
__consumer_offsets
logins
orders
payments
```

**Describe a topic (see its details):**

```bash
kafka-topics.sh --describe --topic orders --bootstrap-server localhost:9092
```

Expected output:

```
Topic: orders   TopicId: NPaShDBcRWq8a3v9Yx2lQg   PartitionCount: 3   ReplicationFactor: 2   Configs: segment.bytes=1073741824
    Topic: orders   Partition: 0    Leader: 1   Replicas: 1,2   Isr: 1,2
    Topic: orders   Partition: 1    Leader: 2   Replicas: 2,3   Isr: 2,3
    Topic: orders   Partition: 2    Leader: 3   Replicas: 3,1   Isr: 3,1
```

**How to read this:** Each partition has a **Leader** (the broker currently in charge of it), a list of **Replicas** (all brokers holding a copy), and **Isr** = “In-Sync Replicas” (copies that are fully up to date). If `Isr` is shorter than `Replicas`, a copy is falling behind or a broker is down — a sign to investigate.

**Add partitions (you can only go up, never down):**

```bash
kafka-topics.sh --alter --topic orders --partitions 6 \
  --bootstrap-server localhost:9092
```

**Delete a topic:**

```bash
kafka-topics.sh --delete --topic orders --bootstrap-server localhost:9092
```

-----

### 4.2 Sending & Reading Messages (for testing)

**Producer — type messages and send them:**

```bash
kafka-console-producer.sh --topic orders --bootstrap-server localhost:9092
```

What you’ll see (the `>` is a prompt waiting for you to type):

```
>order #1001 shipped
>order #1002 cancelled
>(press Ctrl+C to stop)
```

**Consumer — read messages:**

```bash
kafka-console-consumer.sh --topic orders --from-beginning \
  --bootstrap-server localhost:9092
```

Expected output:

```
order #1001 shipped
order #1002 cancelled
```

`--from-beginning` reads the entire history. Without it, you only see **new** messages that arrive after you start watching.

**Read with keys and extra detail:**

```bash
kafka-console-consumer.sh --topic orders --from-beginning \
  --property print.key=true --property print.timestamp=true \
  --bootstrap-server localhost:9092
```

Expected output:

```
CreateTime:1718700000000   user-42    order #1001 shipped
CreateTime:1718700005000   user-87    order #1002 cancelled
```

-----

### 4.3 Consumer Groups — `kafka-consumer-groups.sh`

**List all consumer groups:**

```bash
kafka-consumer-groups.sh --list --bootstrap-server localhost:9092
```

Expected output:

```
order-processor
email-service
analytics-pipeline
```

**Describe a group (check its LAG):**

```bash
kafka-consumer-groups.sh --describe --group order-processor \
  --bootstrap-server localhost:9092
```

Expected output:

```
GROUP            TOPIC    PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG   CONSUMER-ID         HOST          CLIENT-ID
order-processor  orders   0          1050            1050            0     consumer-1-abc...   /10.0.0.5     consumer-1
order-processor  orders   1          1048            1100            52    consumer-2-def...   /10.0.0.6     consumer-2
order-processor  orders   2          990             990             0     consumer-3-ghi...   /10.0.0.7     consumer-3
```

**How to read this:** `CURRENT-OFFSET` is where the consumer has read up to. `LOG-END-OFFSET` is the newest message available. **`LAG` is the gap between them.** In the example, partition 1 is 52 messages behind — consumers are slightly slower than producers there. A LAG that keeps growing means you need more or faster consumers.

**Reset offsets (rewind to re-read everything):**

```bash
kafka-consumer-groups.sh --reset-offsets --to-earliest \
  --group order-processor --topic orders --execute \
  --bootstrap-server localhost:9092
```

Expected output:

```
GROUP            TOPIC   PARTITION  NEW-OFFSET
order-processor  orders  0          0
order-processor  orders  1          0
order-processor  orders  2          0
```

> The group must be **stopped** (no active consumers) to reset offsets. Swap `--execute` for `--dry-run` to preview without changing anything.

-----

### 4.4 Configuration — `kafka-configs.sh`

**View a topic’s settings:**

```bash
kafka-configs.sh --describe --topic orders \
  --bootstrap-server localhost:9092
```

Expected output:

```
Dynamic configs for topic orders are:
  retention.ms=604800000 sensitive=false synonyms={DYNAMIC_TOPIC_CONFIG:retention.ms=604800000}
  cleanup.policy=delete sensitive=false synonyms={...}
```

**Change a setting (keep messages 7 days = 604,800,000 ms):**

```bash
kafka-configs.sh --alter --topic orders \
  --add-config retention.ms=604800000 \
  --bootstrap-server localhost:9092
```

Expected output:

```
Completed updating config for topic orders.
```

-----

### 4.5 Checking disk usage (quick example)

```bash
kafka-log-dirs.sh --describe --bootstrap-server localhost:9092 \
  --topic-list orders
```

Expected (trimmed) output:

```json
{"brokers":[{"broker":1,"logDirs":[{"logDir":"/var/lib/kafka-logs",
"partitions":[{"partition":"orders-0","size":10485760,"offsetLag":0}]}]}]}
```

That `size` is in bytes — here partition `orders-0` is using about 10 MB. The full inventory of every other command is in Section 5.

-----

## 5. Complete `bin/` Directory Reference (Every Script)

Below is every script shipped in Kafka 4.x’s `bin/` folder, grouped by what you’d use it for. On Linux/macOS they end in `.sh`; identical `.bat` versions live in `bin/windows/`. Run any script with no arguments to print its full help.

> **How to read these tables:** the “What it does” column is the plain-terms job. You’ve already seen detailed examples for the most common ones in Section 4; the rest are summarized here so you know they exist and when to reach for them.

### 5.1 Server & cluster lifecycle

|Script                    |What it does (plain terms)                                                                                                         |
|--------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
|`kafka-server-start.sh`   |Turn a broker ON. Pass it a config file: `kafka-server-start.sh config/server.properties`. Ends with `Kafka Server started`.       |
|`kafka-server-stop.sh`    |Turn a broker OFF gracefully.                                                                                                      |
|`kafka-storage.sh`        |**KRaft only, required once before first start.** Generates a cluster ID and formats the metadata/log directories. See Section 5.6.|
|`kafka-metadata-quorum.sh`|Inspect the KRaft controller “quorum” — who’s the leader, who are the voters. Replaces the old ZooKeeper health checks.            |
|`kafka-cluster.sh`        |Cluster-wide actions like printing or unregistering the cluster ID.                                                                |
|`kafka-features.sh`       |View or upgrade/downgrade cluster **feature levels** (e.g. the `metadata.version`) as you roll out new Kafka versions.             |

### 5.2 Topics, messages & groups (the everyday tools)

|Script                                                         |What it does (plain terms)                                                                              |
|---------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
|`kafka-topics.sh`                                              |Create, list, describe, alter, delete topics. (Section 4.1)                                             |
|`kafka-console-producer.sh`                                    |Type messages in and send them, for testing. (Section 4.2)                                              |
|`kafka-console-consumer.sh`                                    |Read messages out to your screen, for testing. (Section 4.2)                                            |
|`kafka-consumer-groups.sh`                                     |List groups, check **lag**, reset offsets. (Section 4.3)                                                |
|`kafka-configs.sh`                                             |View and change settings on topics, brokers, users, clients. (Section 4.4)                              |
|`kafka-get-offsets.sh`                                         |Ask a topic for its earliest/latest offsets (how many messages, and the boundaries).                    |
|`kafka-delete-records.sh`                                      |Permanently delete messages **before** a given offset (e.g. to purge bad data or free space).           |
|`kafka-leader-election.sh`                                     |Manually trigger a new leader election for partitions (e.g. to rebalance leadership after a restart).   |
|`kafka-verifiable-producer.sh` / `kafka-verifiable-consumer.sh`|Test/validation producers and consumers that print machine-readable results — used in automated testing.|

### 5.3 Data movement, balancing & replication

|Script                         |What it does (plain terms)                                                                                                    |
|-------------------------------|------------------------------------------------------------------------------------------------------------------------------|
|`kafka-reassign-partitions.sh` |Move partitions between brokers to balance load or drain a broker. (Section 10, Use Case F)                                   |
|`kafka-replica-verification.sh`|Check that replicas (the backup copies) actually match across brokers.                                                        |
|`kafka-mirror-maker.sh`        |Copy data from one cluster to another (older MirrorMaker; for DR/migration). MirrorMaker 2 is usually run via Connect instead.|

### 5.4 Security & access control

|Script                      |What it does (plain terms)                                                                      |
|----------------------------|------------------------------------------------------------------------------------------------|
|`kafka-acls.sh`             |Grant or revoke permissions — who may read/write/manage which topics and groups.                |
|`kafka-delegation-tokens.sh`|Create/renew/expire delegation tokens (lightweight credentials for clients in secured clusters).|

### 5.5 Kafka Connect (move data in/out of external systems)

|Script                   |What it does (plain terms)                                                                    |
|-------------------------|----------------------------------------------------------------------------------------------|
|`connect-distributed.sh` |Start a Connect **worker in cluster mode** (scalable, fault-tolerant). See Section 6.         |
|`connect-standalone.sh`  |Start a Connect worker as a **single process** (simple, good for one-off jobs). See Section 6.|
|`connect-mirror-maker.sh`|Run **MirrorMaker 2** (cross-cluster replication) on top of Connect.                          |
|`connect-plugin-path.sh` |List and inspect installed Connect plugins (connectors/transforms) on the plugin path.        |

### 5.6 Kafka Streams

|Script                              |What it does (plain terms)                                                                                               |
|------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
|`kafka-streams-application-reset.sh`|Reset a Streams app so it can reprocess input from the start — clears its offsets and internal topics. See example below.|

**Example — resetting a Streams application:**

```bash
kafka-streams-application-reset.sh \
  --application-id my-streams-app \
  --input-topics orders \
  --bootstrap-server localhost:9092
```

Expected output:

```
Reset-offsets for input topics [orders]
Following input topics offsets will be reset to (for consumer group my-streams-app)
Topic: orders Partition: 0 Offset: 0
Topic: orders Partition: 1 Offset: 0
Done.
```

> ⚠️ **Stop all instances of the app first.** Running this against a live app can corrupt its state. Verify the group is inactive with `kafka-consumer-groups.sh` before resetting.

### 5.7 Performance testing & debugging

|Script                        |What it does (plain terms)                                                                |
|------------------------------|------------------------------------------------------------------------------------------|
|`kafka-producer-perf-test.sh` |Stress-test write speed: e.g. `50000 records sent, 9803.9 records/sec`.                   |
|`kafka-consumer-perf-test.sh` |Stress-test read speed (throughput in MB/sec and records/sec).                            |
|`kafka-log-dirs.sh`           |Report disk usage per partition (Section 4.5).                                            |
|`kafka-dump-log.sh`           |Decode and peek inside raw `.log` segment files for deep debugging.                       |
|`kafka-jmx.sh`                |Read JMX metrics (Kafka’s built-in health numbers) straight from the command line.        |
|`kafka-e2e-latency.sh`        |Measure end-to-end produce→consume latency.                                               |
|`kafka-broker-api-versions.sh`|List which API versions a broker supports — handy for diagnosing client/broker mismatches.|

### 5.8 Format-only example: first-time KRaft setup

Because Kafka 4.x is KRaft-only, a brand-new cluster needs a one-time format step before the very first start:

```bash
# 1. Generate a unique cluster ID
KAFKA_CLUSTER_ID="$(bin/kafka-storage.sh random-uuid)"

# 2. Format the storage directories using that ID and your config
bin/kafka-storage.sh format --standalone \
  -t "$KAFKA_CLUSTER_ID" \
  -c config/server.properties

# 3. Now start the server
bin/kafka-server-start.sh config/server.properties
```

Expected output of the format step:

```
Formatting metadata directory /var/lib/kafka-logs with metadata.version 4.3-IV0.
```

> You only format **once** per node. Re-formatting wipes metadata, so don’t repeat it on an existing cluster.

-----

## 6. Kafka Connect from the CLI

**Kafka Connect** is the built-in way to move data **into** Kafka (from databases, files, queues) and **out of** Kafka (to S3, Elasticsearch, data warehouses) — without writing custom code. You run “connectors,” which are reusable plugins. Think of Connect as a set of **pre-built adapters** that plug your other systems into the Kafka post office.

Connect runs in two modes:

|Mode           |Script                  |When to use it                                                                                                |
|---------------|------------------------|--------------------------------------------------------------------------------------------------------------|
|**Standalone** |`connect-standalone.sh` |One process, config from files. Simple; great for a single source like tailing a log file. No fault tolerance.|
|**Distributed**|`connect-distributed.sh`|A scalable, fault-tolerant cluster of workers managed over a REST API. The production choice.                 |

### 6.1 Standalone mode

You give it one **worker** config plus one or more **connector** configs:

```bash
connect-standalone.sh config/connect-standalone.properties \
  config/connect-file-source.properties \
  config/connect-file-sink.properties
```

The first file configures the worker (where Kafka is, how data is serialized); the remaining files each define a connector. All run together in one process.

### 6.2 Distributed mode

You start the worker with only its worker config — connectors are added later over the REST API:

```bash
connect-distributed.sh config/connect-distributed.properties
```

Expected (trimmed) startup output:

```
[INFO] Kafka Connect started
[INFO] REST server listening at http://localhost:8083/, advertising URL http://localhost:8083/
```

### 6.3 Managing connectors over REST (port 8083)

In distributed mode you control everything through Connect’s REST interface, which **listens on port 8083 by default**.

**List installed connector plugins:**

```bash
curl http://localhost:8083/connector-plugins
```

**Create a connector** (send it a JSON config):

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "file-source",
    "config": {
      "connector.class": "FileStreamSource",
      "tasks.max": "1",
      "file": "/var/log/app.log",
      "topic": "app-logs"
    }
  }'
```

**List running connectors:**

```bash
curl http://localhost:8083/connectors
```

Expected output:

```json
["file-source"]
```

**Check a connector’s status:**

```bash
curl http://localhost:8083/connectors/file-source/status
```

Expected output:

```json
{"name":"file-source","connector":{"state":"RUNNING","worker_id":"10.0.0.5:8083"},
"tasks":[{"id":0,"state":"RUNNING","worker_id":"10.0.0.5:8083"}],"type":"source"}
```

**Pause, resume, or delete a connector:**

```bash
curl -X PUT    http://localhost:8083/connectors/file-source/pause
curl -X PUT    http://localhost:8083/connectors/file-source/resume
curl -X DELETE http://localhost:8083/connectors/file-source
```

> **Source vs. sink, in plain terms:** a **source** connector pulls data *into* Kafka (e.g. database → topic). A **sink** connector pushes data *out of* Kafka (e.g. topic → S3). The example above is a source reading a log file into the `app-logs` topic.

-----

## 7. Complete `config/` Directory Reference (Every File)

Configuration files are plain-text `key=value` files (logging uses YAML in 4.x). Here’s what each one in `config/` controls. You point a startup script at the file you want, e.g. `kafka-server-start.sh config/server.properties`.

### 7.1 `server.properties` — the main broker/controller config

The single most important file: it defines what this Kafka node *is* and how it behaves. In KRaft mode (Kafka 4.x) one node can be a broker, a controller, or both. Key settings you’ll actually touch:

|Setting                           |Plain meaning                                                                                  |
|----------------------------------|-----------------------------------------------------------------------------------------------|
|`process.roles`                   |What this node does: `broker`, `controller`, or `broker,controller` (combined). KRaft-specific.|
|`node.id`                         |A unique number identifying this node in the cluster.                                          |
|`controller.quorum.voters`        |The list of controller nodes (id@host:port) that vote on metadata — KRaft’s brain.             |
|`listeners`                       |The address/port this node listens on (default broker port `9092`).                            |
|`advertised.listeners`            |The address clients are told to connect back on (important behind NAT/containers).             |
|`log.dirs`                        |**Where message data is stored on disk.** Change this from the default for production.         |
|`num.partitions`                  |Default partition count for auto-created topics.                                               |
|`default.replication.factor`      |Default number of copies for new topics.                                                       |
|`offsets.topic.replication.factor`|Copies of the internal offsets topic (set ≥3 in production).                                   |
|`log.retention.hours`             |How long messages are kept by default (168 hours = 7 days).                                    |
|`log.segment.bytes`               |How big each `.log` segment file grows before rolling over.                                    |


> The samples in `config/kraft/` (`server.properties`, `broker.properties`, `controller.properties`) are the same file tuned for the three role choices: combined, broker-only, and controller-only. Pick the one matching the node’s job.

### 7.2 `producer.properties` — default producer settings

Defaults used by the console producer and as a template for your own producers.

|Setting                   |Plain meaning                                                                                |
|--------------------------|---------------------------------------------------------------------------------------------|
|`bootstrap.servers`       |Which broker(s) to connect to.                                                               |
|`compression.type`        |Compress messages before sending (`none`, `gzip`, `snappy`, `lz4`, `zstd`) to save bandwidth.|
|`acks`                    |How many copies must confirm a write before it’s “done” (`all` = safest).                    |
|`batch.size` / `linger.ms`|How much to batch messages for efficiency vs. latency.                                       |

### 7.3 `consumer.properties` — default consumer settings

Defaults used by the console consumer and as a template for your own consumers.

|Setting             |Plain meaning                                                       |
|--------------------|--------------------------------------------------------------------|
|`bootstrap.servers` |Which broker(s) to connect to.                                      |
|`group.id`          |Which consumer group this consumer joins (shared reading).          |
|`auto.offset.reset` |Where to start if there’s no saved bookmark: `earliest` or `latest`.|
|`enable.auto.commit`|Whether the bookmark (offset) is saved automatically.               |

### 7.4 `connect-distributed.properties` — Connect worker (cluster mode)

Settings for a distributed Connect worker. Connectors are *not* listed here — they’re added via REST.

|Setting                                                               |Plain meaning                                                                |
|----------------------------------------------------------------------|-----------------------------------------------------------------------------|
|`bootstrap.servers`                                                   |The Kafka cluster Connect reads/writes through.                              |
|`group.id`                                                            |Connect cluster name — workers with the same id share the work.              |
|`key.converter` / `value.converter`                                   |How data is serialized (e.g. JSON, Avro).                                    |
|`config.storage.topic`, `offset.storage.topic`, `status.storage.topic`|Internal topics where Connect stores connector configs, progress, and status.|
|`*.storage.replication.factor`                                        |Copies of those internal topics (≥3 in production).                          |
|`plugin.path`                                                         |Folder(s) where connector plugins are installed.                             |
|`listeners`                                                           |The REST API address (default port `8083`).                                  |

### 7.5 `connect-standalone.properties` — Connect worker (single process)

Like the distributed file, but for one process. The key difference:

|Setting                       |Plain meaning                                                                                        |
|------------------------------|-----------------------------------------------------------------------------------------------------|
|`offset.storage.file.filename`|A **local file** (not a Kafka topic) where progress is saved, since there’s no cluster to coordinate.|

Plus the same `bootstrap.servers`, converters, and `plugin.path` as above.

### 7.6 Example connector configs

|File                            |What it demonstrates                                                                                            |
|--------------------------------|----------------------------------------------------------------------------------------------------------------|
|`connect-file-source.properties`|A source connector that reads lines from a file into a Kafka topic. Sets `connector.class`, `file`, and `topic`.|
|`connect-file-sink.properties`  |A sink connector that writes messages from a topic out to a file.                                               |

These are templates to copy and adapt, not production connectors.

### 7.7 Logging configuration

|File                 |What it controls                                                                                               |
|---------------------|---------------------------------------------------------------------------------------------------------------|
|`log4j2.yaml`        |Logging for the broker/server: log levels, file locations, rotation. (Was `log4j.properties` before Kafka 4.0.)|
|`tools-log4j2.yaml`  |Logging for the CLI tools (so command output isn’t drowned in log noise).                                      |
|`connect-log4j2.yaml`|Logging specifically for Kafka Connect workers.                                                                |

### 7.8 Legacy files (3.x and earlier only — **not** in Kafka 4.x)

|File                             |What it was for                                                               |
|---------------------------------|------------------------------------------------------------------------------|
|`zookeeper.properties`           |Configured the embedded ZooKeeper (data dir, client port `2181`). Gone in 4.x.|
|`connect-mirror-maker.properties`|Config for MirrorMaker 2 replication (still used where MM2 is deployed).      |
|`trogdor.conf`                   |Config for Trogdor, Kafka’s internal test/fault-injection framework.          |

-----

## 8. Admin Tasks Explained Simply

### Task 1: Creating and managing topics

A topic is a labeled folder where similar messages go. When you create one you choose **partitions** (how many drawers, so many workers can read at once) and **replication factor** (how many backup copies on other servers). More partitions = more parallel speed. More replicas = more safety.

*Tools:* `kafka-topics.sh`, or GUIs like AKHQ, Conduktor, Kafdrop.

### Task 2: Monitoring health

You watch the cluster like a school nurse taking everyone’s temperature. Key questions: Is every broker alive? Is anyone falling behind (lag)? Is disk filling up? You set alerts so you hear about problems *before* users do.

*Tools:* Prometheus + Grafana (collect numbers, draw graphs), JMX metrics (Kafka’s built-in health readings), CMAK.

### Task 3: Managing consumer groups and lag

Picture a relay race. Producers drop batons (messages); consumers pick them up. **Lag** is how many batons are piling up uncollected. Growing lag means consumers can’t keep up — add more consumers or make them faster.

*Tools:* `kafka-consumer-groups.sh`, Burrow.

### Task 4: Balancing and scaling

Over time some brokers get more crowded than others, like one lunch line being way longer. You redistribute partitions so the work is even, and add brokers when traffic grows.

*Tools:* `kafka-reassign-partitions.sh`, Cruise Control (auto-balances for you).

### Task 5: Security

You decide who gets a key to which folders. **Authentication** checks *who you are* (like showing a student ID). **Authorization** checks *what you’re allowed to do* (only teachers enter the staff room). **Encryption** scrambles data so eavesdroppers can’t read it.

*Tools:* `kafka-acls.sh`, SSL/TLS (encryption), SASL/Kerberos (logins).

### Task 6: Backup and disaster recovery

You keep copies somewhere safe so a disaster doesn’t erase everything, and mirror data to another cluster (like a sister school in another city) for safety.

*Tools:* MirrorMaker 2, Confluent Replicator.

### Task 7: Connecting Kafka to other systems

Often you want data to flow in from a database or out to cloud storage automatically, without writing custom code.

*Tools:* Kafka Connect (plug-in connectors for databases, S3, etc.).

### Task 8: Processing data in motion

Sometimes you transform messages as they flow — filtering, counting, combining — before storing them.

*Tools:* Kafka Streams (a code library), ksqlDB (do it with SQL-like commands).

-----

## 9. Tools Beyond the CLI

|Tool                    |Category       |What it’s for                                         |
|------------------------|---------------|------------------------------------------------------|
|**AKHQ**                |Web GUI        |Browse topics, messages, consumer groups in a browser |
|**Conduktor**           |Desktop/Web GUI|Friendly all-in-one admin and monitoring              |
|**Kafdrop**             |Web GUI        |Lightweight topic and message viewer                  |
|**CMAK** (Kafka Manager)|Web GUI        |Manage clusters, topics, partitions                   |
|**Prometheus + Grafana**|Monitoring     |Collect metrics and draw dashboards                   |
|**Burrow**              |Monitoring     |Specialized consumer-lag tracking                     |
|**Cruise Control**      |Automation     |Auto-balances partitions across brokers               |
|**Kafka Connect**       |Integration    |Move data in/out of databases, S3, Elasticsearch, etc.|
|**Kafka Streams**       |Processing     |Transform data in real time (Java/Scala library)      |
|**ksqlDB**              |Processing     |Stream processing using SQL-like queries              |
|**MirrorMaker 2**       |Replication    |Copy data between clusters for backup/DR              |
|**Schema Registry**     |Governance     |Enforce and version the “shape” of your messages      |

-----

## 10. Use Cases (Real-World Scenarios)

### Use Case A: Spin up a new topic for an order system

**Goal:** A shopping site needs a place to record every order event.

```bash
kafka-topics.sh --create --topic orders \
  --partitions 6 --replication-factor 3 \
  --bootstrap-server localhost:9092
```

**Why these numbers:** 6 partitions let up to 6 consumers process orders in parallel during busy sales. Replication factor 3 means two brokers can fail and you still keep your data.
**Expected result:** `Created topic orders.` — and the order service can start producing immediately.

-----

### Use Case B: “Our emails are going out late!” — diagnosing lag

**Goal:** Find out why the email service is slow.

```bash
kafka-consumer-groups.sh --describe --group email-service \
  --bootstrap-server localhost:9092
```

**What you look for:** A large, growing `LAG` column. If lag is 50,000 and climbing, the email consumers can’t keep up.
**Fix:** Add more consumer instances to the group (up to the number of partitions), or speed up each consumer. Re-run the command to confirm lag shrinks back toward 0.

-----

### Use Case C: Free up disk space by shortening retention

**Goal:** A logging topic is eating the disk. You only need 3 days of logs, not the default 7.

```bash
kafka-configs.sh --alter --topic app-logs \
  --add-config retention.ms=259200000 \
  --bootstrap-server localhost:9092
```

**Expected result:** `Completed updating config for topic app-logs.` Kafka will delete log segments older than 3 days on its next cleanup, reclaiming disk.

-----

### Use Case D: Replay history to rebuild a broken database

**Goal:** A downstream database got corrupted. You want to re-feed it every message from the start.

```bash
# 1. Stop the consumers in the group first, then:
kafka-consumer-groups.sh --reset-offsets --to-earliest \
  --group db-sync --topic orders --execute \
  --bootstrap-server localhost:9092
# 2. Restart the consumers — they reprocess from offset 0
```

**Why this works:** Kafka keeps messages even after they’re read (until retention expires), so rewinding the bookmark lets you replay the entire history. This is one of Kafka’s superpowers.

-----

### Use Case E: Lock down a topic with permissions

**Goal:** Only the payment service may write to the `payments` topic.

```bash
kafka-acls.sh --add --allow-principal User:payment-svc \
  --operation Write --topic payments \
  --bootstrap-server localhost:9092 \
  --command-config admin.properties
```

**Expected result:** A confirmation listing the new ACL. Now any other identity trying to write to `payments` is rejected.

-----

### Use Case F: Rebalance after adding a new broker

**Goal:** You added broker #4 to the cluster, but it’s sitting empty while the old brokers are overloaded.

```bash
# Generate a reassignment plan, then execute it:
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file plan.json --execute
```

**Expected result:** `Successfully started partition reassignment for ...`. Data gradually moves to broker #4 until the load is even. Verify with `--verify`.

-----

### Use Case G: Quick health check before going home

**Goal:** Confirm the cluster is healthy at end of day.

```bash
# Are all partitions fully replicated? (no under-replicated partitions)
kafka-topics.sh --describe --under-replicated-partitions \
  --bootstrap-server localhost:9092
```

**Expected result:** **No output = good news** (every partition has all its copies in sync). If lines appear, some replicas are lagging or a broker is down — investigate before leaving.

-----

## 11. Cheat Sheet: Task → Tool

|Admin Task                  |CLI Command                                                    |Bigger Tool          |
|----------------------------|---------------------------------------------------------------|---------------------|
|Format storage (first start)|`kafka-storage.sh format`                                      |—                    |
|Start / stop a broker       |`kafka-server-start.sh` / `kafka-server-stop.sh`               |—                    |
|Make / change topics        |`kafka-topics.sh`                                              |AKHQ, Conduktor      |
|Test send / receive         |`kafka-console-producer.sh` / `kafka-console-consumer.sh`      |Conduktor            |
|Watch lag                   |`kafka-consumer-groups.sh`                                     |Burrow               |
|Change settings             |`kafka-configs.sh`                                             |—                    |
|Purge old messages          |`kafka-delete-records.sh`                                      |—                    |
|Permissions                 |`kafka-acls.sh`                                                |—                    |
|Balance load                |`kafka-reassign-partitions.sh`                                 |Cruise Control       |
|Check controllers (KRaft)   |`kafka-metadata-quorum.sh`                                     |—                    |
|Monitor health              |`kafka-log-dirs.sh`, `kafka-topics.sh --describe`              |Prometheus + Grafana |
|Connect systems             |`connect-distributed.sh` / `connect-standalone.sh` + REST :8083|Kafka Connect        |
|Backup / mirror             |`connect-mirror-maker.sh`                                      |MirrorMaker 2        |
|Reset a Streams app         |`kafka-streams-application-reset.sh`                           |Kafka Streams        |
|Process streams             |—                                                              |Kafka Streams, ksqlDB|
|Enforce message shape       |—                                                              |Schema Registry      |

-----

## 12. Quick Tips & Gotchas

- **Default port is 9092.** Almost every command needs `--bootstrap-server localhost:9092` (or your broker’s address).
- **`--zookeeper` is dead.** Old guides used `--zookeeper`; modern Kafka uses `--bootstrap-server` for nearly everything. If a command rejects `--zookeeper`, switch to `--bootstrap-server`.
- **Change `log.dirs` for production.** The sample path lives under `/tmp` and can be wiped on reboot. Point it at a permanent disk.
- **Partitions only go up.** You can add partitions but never remove them. Plan ahead.
- **Replication factor can’t exceed broker count.** Asking for 3 copies with only 2 brokers fails.
- **Stop consumers before resetting offsets.** Offset resets only work when the group has no active members.
- **No output is often good output.** Commands like `--under-replicated-partitions` print nothing when everything is healthy.
- **KRaft is now the only mode.** As of Kafka 4.0, ZooKeeper is **removed entirely** — there are no `zookeeper-*` scripts or `zookeeper.properties`. You use `kafka-storage.sh` (one-time format) and `kafka-metadata-quorum.sh` (health) instead. If you’re on a 3.x cluster, ZooKeeper may still be present; 3.9 is the last line that supports it.
- **Windows users:** use the `.bat` files in `bin\windows\` and back-slashes in paths.

-----

*Reference guide — Apache Kafka administration. Targets the latest release, Kafka 4.3.0 (May 2026), which is KRaft-only and requires Java 17+. Where commands or files differ in older 3.x installs, this is noted inline.*