# Kafka Administration: Complete Reference Guide

A comprehensive, beginner-friendly guide to Apache Kafka CLI commands, admin tasks, tools, directory structure, and real-world use cases. Explained in simple (middle-school) terms.

-----

## Table of Contents

1. [Mental Model: What Is Kafka?](#1-mental-model-what-is-kafka)
1. [Where the Commands Live (Default Paths)](#2-where-the-commands-live-default-paths)
1. [Kafka Directory Structure](#3-kafka-directory-structure)
1. [CLI Commands with Example Outputs](#4-cli-commands-with-example-outputs)
1. [Admin Tasks Explained Simply](#5-admin-tasks-explained-simply)
1. [Tools Beyond the CLI](#6-tools-beyond-the-cli)
1. [Use Cases (Real-World Scenarios)](#7-use-cases-real-world-scenarios)
1. [Cheat Sheet: Task → Tool](#8-cheat-sheet-task--tool)
1. [Quick Tips & Gotchas](#9-quick-tips--gotchas)

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
~/kafka_2.13-3.7.0/                 <- if you unzipped it in your home folder
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

|What                                                       |Default path       |Set by                             |
|-----------------------------------------------------------|-------------------|-----------------------------------|
|Message data (“log dirs”)                                  |`/tmp/kafka-logs`  |`log.dirs` in `server.properties`  |
|ZooKeeper data                                             |`/tmp/zookeeper`   |`dataDir` in `zookeeper.properties`|
|Broker operational logs (text logs about the server itself)|`$KAFKA_HOME/logs/`|`log4j` config                     |


> ⚠️ **Important:** The default `/tmp/kafka-logs` is fine for testing but **terrible for production** — many systems wipe `/tmp` on reboot, which deletes all your data. Always change `log.dirs` to a permanent disk in real deployments.

-----

## 3. Kafka Directory Structure

Here’s what a freshly unzipped Kafka folder looks like:

```
kafka_2.13-3.7.0/
├── bin/                       # All the CLI commands (the tools)
│   ├── kafka-topics.sh
│   ├── kafka-console-producer.sh
│   ├── kafka-console-consumer.sh
│   ├── kafka-consumer-groups.sh
│   ├── kafka-configs.sh
│   ├── kafka-acls.sh
│   ├── kafka-reassign-partitions.sh
│   ├── kafka-server-start.sh
│   ├── kafka-server-stop.sh
│   ├── kafka-storage.sh
│   ├── zookeeper-server-start.sh
│   └── windows/               # .bat versions of every script
│       ├── kafka-topics.bat
│       └── ...
├── config/                    # Configuration files
│   ├── server.properties      # Main broker config (ZooKeeper mode)
│   ├── zookeeper.properties
│   ├── consumer.properties
│   ├── producer.properties
│   └── kraft/                 # Configs for the newer KRaft mode
│       ├── server.properties
│       ├── broker.properties
│       └── controller.properties
├── libs/                      # Java .jar files Kafka needs to run (don't touch)
├── logs/                      # Text logs about the running server
├── licenses/                  # Legal stuff
├── LICENSE
└── NOTICE
```

And here’s what the **data directory** (`log.dirs`) looks like once Kafka is running and you’ve created a topic called `orders` with 2 partitions:

```
/tmp/kafka-logs/                       # or your configured log.dirs path
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

### 4.5 Other Useful CLI Tools

|Command                                                |What it does (plain terms)               |Typical output                                             |
|-------------------------------------------------------|-----------------------------------------|-----------------------------------------------------------|
|`kafka-server-start.sh config/server.properties`       |Turn a broker ON                         |Streams startup logs ending in `[KafkaServer id=1] started`|
|`kafka-server-stop.sh`                                 |Turn a broker OFF                        |(no output; process stops)                                 |
|`kafka-acls.sh`                                        |Set permissions — who can read/write     |Lists or confirms access rules                             |
|`kafka-reassign-partitions.sh`                         |Move data between brokers to balance load|`Successfully started partition reassignment`              |
|`kafka-leader-election.sh`                             |Pick a new leader broker for a partition |Confirms election per partition                            |
|`kafka-log-dirs.sh --describe`                         |Check disk space used by data            |JSON of partition sizes in bytes                           |
|`kafka-dump-log.sh`                                    |Peek inside raw segment files (debugging)|Decoded record batches                                     |
|`kafka-producer-perf-test.sh`                          |Stress-test sending speed                |`50000 records sent, 9803.9 records/sec...`                |
|`kafka-consumer-perf-test.sh`                          |Stress-test reading speed                |Throughput in MB/sec and records/sec                       |
|`kafka-storage.sh`                                     |Format storage for KRaft mode            |`Formatting ... with metadata.version ...`                 |
|`kafka-metadata-quorum.sh --describe`                  |Check health of KRaft controllers        |Leader ID, voters, observers                               |
|`zookeeper-server-start.sh config/zookeeper.properties`|Start ZooKeeper (older clusters)         |ZooKeeper startup logs                                     |

**Example — checking disk usage:**

```bash
kafka-log-dirs.sh --describe --bootstrap-server localhost:9092 \
  --topic-list orders
```

Expected (trimmed) output:

```json
{"brokers":[{"broker":1,"logDirs":[{"logDir":"/tmp/kafka-logs",
"partitions":[{"partition":"orders-0","size":10485760,"offsetLag":0}]}]}]}
```

That `size` is in bytes — here partition `orders-0` is using about 10 MB.

-----

## 5. Admin Tasks Explained Simply

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

## 6. Tools Beyond the CLI

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

## 7. Use Cases (Real-World Scenarios)

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

## 8. Cheat Sheet: Task → Tool

|Admin Task           |CLI Command                                              |Bigger Tool          |
|---------------------|---------------------------------------------------------|---------------------|
|Make / change topics |`kafka-topics.sh`                                        |AKHQ, Conduktor      |
|Test send / receive  |`kafka-console-producer.sh` / `kafka-console-consumer.sh`|Conduktor            |
|Watch lag            |`kafka-consumer-groups.sh`                               |Burrow               |
|Change settings      |`kafka-configs.sh`                                       |—                    |
|Permissions          |`kafka-acls.sh`                                          |—                    |
|Balance load         |`kafka-reassign-partitions.sh`                           |Cruise Control       |
|Monitor health       |`kafka-log-dirs.sh`, `kafka-topics.sh --describe`        |Prometheus + Grafana |
|Backup / mirror      |—                                                        |MirrorMaker 2        |
|Connect systems      |—                                                        |Kafka Connect        |
|Process streams      |—                                                        |Kafka Streams, ksqlDB|
|Enforce message shape|—                                                        |Schema Registry      |

-----

## 9. Quick Tips & Gotchas

- **Default port is 9092.** Almost every command needs `--bootstrap-server localhost:9092` (or your broker’s address).
- **`--zookeeper` is dead.** Old guides used `--zookeeper`; modern Kafka uses `--bootstrap-server` for nearly everything. If a command rejects `--zookeeper`, switch to `--bootstrap-server`.
- **Change `log.dirs` for production.** The default `/tmp/kafka-logs` can be wiped on reboot. Point it at a permanent disk.
- **Partitions only go up.** You can add partitions but never remove them. Plan ahead.
- **Replication factor can’t exceed broker count.** Asking for 3 copies with only 2 brokers fails.
- **Stop consumers before resetting offsets.** Offset resets only work when the group has no active members.
- **No output is often good output.** Commands like `--under-replicated-partitions` print nothing when everything is healthy.
- **KRaft is the future.** Kafka 3.x+ is phasing out ZooKeeper. In KRaft mode you use `kafka-storage.sh` and `kafka-metadata-quorum.sh` instead of the `zookeeper-*` scripts. Kafka 4.0 removes ZooKeeper entirely.
- **Windows users:** use the `.bat` files in `bin\windows\` and back-slashes in paths.

-----

*Reference guide — Apache Kafka administration. Examples use Kafka 3.x conventions.*