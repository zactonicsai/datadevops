# Apache NiFi Administration: Complete Reference Guide

A comprehensive, beginner-friendly guide to Apache NiFi: how it works, its CLI and toolkit commands, admin tasks, tools, directory structure, default paths, example outputs, and real-world use cases. Explained in simple (middle-school) terms.

> **Big difference from Kafka:** Kafka is run almost entirely from the command line. **NiFi is run from a web browser.** You build data pipelines by dragging boxes and arrows on a canvas — like drawing a flowchart that actually moves real data. The command-line tools exist mostly for *administration and automation* (starting the server, backups, deploying flows between environments), not for everyday building. This guide reflects that.

-----

## Table of Contents

1. [Mental Model: What Is NiFi?](#1-mental-model-what-is-nifi)
1. [Where Things Live (Default Paths)](#2-where-things-live-default-paths)
1. [NiFi Directory Structure](#3-nifi-directory-structure)
1. [The `nifi.sh` Server Commands (with Example Outputs)](#4-the-nifish-server-commands-with-example-outputs)
1. [The NiFi Toolkit & CLI (with Example Outputs)](#5-the-nifi-toolkit--cli-with-example-outputs)
1. [Admin Tasks Explained Simply](#6-admin-tasks-explained-simply)
1. [Tools in the NiFi World](#7-tools-in-the-nifi-world)
1. [Use Cases (Real-World Scenarios)](#8-use-cases-real-world-scenarios)
1. [Cheat Sheet: Task → Tool](#9-cheat-sheet-task--tool)
1. [Quick Tips & Gotchas](#10-quick-tips--gotchas)

-----

## 1. Mental Model: What Is NiFi?

Think of NiFi like an automated **mailroom with conveyor belts**. Data items ride along belts, stop at machines that stamp/sort/repackage them, and get routed to the right exit. You design the belt layout by dragging machines onto a canvas and connecting them with arrows. As an admin, you’re the **mailroom manager**: you turn the system on, make sure belts aren’t jammed, control who can rearrange the layout, and keep backup blueprints.

Key words you’ll see everywhere:

|Term                  |Simple meaning                                                                                                                                    |
|----------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
|**FlowFile**          |One item of data riding the conveyor belt. It has **content** (the actual data) and **attributes** (sticky-note labels like filename, size, type).|
|**Processor**         |A machine on the belt that does one job: fetch, transform, route, split, merge, send. The main building block.                                    |
|**Connection**        |The belt (arrow) between two processors. It’s actually a **queue** that holds FlowFiles waiting to be processed.                                  |
|**Relationship**      |The labeled exit from a processor — usually `success` and `failure` — deciding which belt a FlowFile takes next.                                  |
|**Process Group**     |A box that holds a whole sub-flow, so you can fold a complicated layout into one tidy container.                                                  |
|**Controller Service**|A shared helper used by many processors (e.g. a database connection pool, a record reader). Set it up once, reuse everywhere.                     |
|**Back Pressure**     |A safety brake. If a belt’s queue fills up, the upstream machine pauses so nothing overflows.                                                     |
|**Provenance**        |A complete history/receipt of everything that happened to each FlowFile — where it came from, what changed, where it went.                        |
|**Flow**              |Your whole pipeline design, saved to disk as `flow.json.gz`.                                                                                      |
|**NiFi Registry**     |A separate app that version-controls your flows (like Git for pipelines).                                                                         |

-----

## 2. Where Things Live (Default Paths)

When you unzip the official download, everything sits under one folder, commonly called `$NIFI_HOME`.

```
/opt/nifi/                          <- a common choice for $NIFI_HOME
/usr/local/nifi/                    <- another common location
~/nifi-2.0.0/                       <- if you unzipped it in your home folder
```

### Scripts (the commands)

|Operating system|Default script path|Main script   |
|----------------|-------------------|--------------|
|Linux / macOS   |`$NIFI_HOME/bin/`  |`nifi.sh`     |
|Windows         |`%NIFI_HOME%\bin\` |`run-nifi.bat`|

The NiFi **Toolkit** (CLI, encryption, file-manager, etc.) is a *separate* download with its own `bin/`:

```
/opt/nifi-toolkit/bin/cli.sh                 <- the main CLI
/opt/nifi-toolkit/bin/encrypt-config.sh
/opt/nifi-toolkit/bin/file-manager.sh
```

**Tip:** make a symlink so you can type `nifi` from anywhere:

```bash
sudo ln -sf /opt/nifi/bin/nifi.sh /usr/local/bin/nifi
export NIFI_HOME=/opt/nifi
```

### Config files — the `conf/` folder

|File                               |What it controls                                                                                               |
|-----------------------------------|---------------------------------------------------------------------------------------------------------------|
|`conf/nifi.properties`             |The master settings file — ports, security, repository paths, cluster settings. The single most important file.|
|`conf/bootstrap.conf`              |How the Java process launches: memory size (heap), Java options.                                               |
|`conf/authorizers.xml`             |Who is allowed to do what (authorization).                                                                     |
|`conf/login-identity-providers.xml`|How users log in (single-user, LDAP, Kerberos).                                                                |
|`conf/state-management.xml`        |Where processors save their “memory” between runs.                                                             |
|`conf/flow.json.gz`                |**Your actual saved dataflow.** (Older NiFi 1.x used `flow.xml.gz`.)                                           |
|`conf/logback.xml`                 |Logging configuration.                                                                                         |

### Default data locations — the repositories

NiFi stores data in four “repositories.” By default they live under `$NIFI_HOME`, but **in production you should put them on separate fast disks.**

|Repository    |Default path             |What it holds (plain terms)                                          |
|--------------|-------------------------|---------------------------------------------------------------------|
|**FlowFile**  |`./flowfile_repository`  |The labels/attributes and “where is each item right now” bookkeeping.|
|**Content**   |`./content_repository`   |The actual data content of every FlowFile.                           |
|**Provenance**|`./provenance_repository`|The history/receipts of everything that happened.                    |
|**Database**  |`./database_repository`  |Internal NiFi bookkeeping (users, component history).                |

### Operational logs — the `logs/` folder

|File                     |What’s in it                                                                            |
|-------------------------|----------------------------------------------------------------------------------------|
|`logs/nifi-app.log`      |The main application log — **check here first** for errors and the auto-generated login.|
|`logs/nifi-bootstrap.log`|Start/stop and process-launch messages.                                                 |
|`logs/nifi-user.log`     |Who logged in and what they accessed.                                                   |

### Default address & login

- NiFi 2.x (and 1.14+) runs over **HTTPS on port 8443** by default: the default port is 8443, reachable at `https://localhost:8443/nifi`.
- It uses a **self-signed certificate**, so your browser shows a security warning the first time — that’s expected for local/dev use. The self-signed certificate will expire after 60 days; production deployments should provision a certificate from a trusted authority.
- On first startup it generates **a random username and password** and writes them to `logs/nifi-app.log`. Find them with:

```bash
grep "Generated Username" logs/nifi-app.log
grep "Generated Password" logs/nifi-app.log
```

> ⚠️ **Production note:** the defaults (single-user login, auto self-signed cert, repositories under `$NIFI_HOME`) are great for getting started but **not suitable for production**. Real deployments use LDAP/OIDC login, a real certificate, and repositories on dedicated disks.
> 
> ⚠️ **Java 21 required:** NiFi 2.0+ needs Java 21. NiFi 2.0.0 requires Java 21. Older 1.x lines ran on Java 8/11.

-----

## 3. NiFi Directory Structure

Here’s what a freshly unzipped NiFi 2.x folder looks like:

```
nifi-2.0.0/
├── bin/                          # Scripts to run the server
│   ├── nifi.sh                   # start | stop | status | restart | run | diagnostics (Linux/Mac)
│   ├── run-nifi.bat              # Windows launcher
│   └── nifi-env.sh               # sets JAVA_HOME, NIFI_HOME
├── conf/                         # ALL configuration (the control room)
│   ├── nifi.properties           # master settings
│   ├── bootstrap.conf            # JVM memory & options
│   ├── authorizers.xml           # who can do what
│   ├── login-identity-providers.xml
│   ├── state-management.xml
│   ├── logback.xml
│   └── flow.json.gz              # your saved dataflow (created on first save)
├── lib/                          # Java .nar/.jar files NiFi needs (don't touch)
├── logs/                         # Application & user logs
│   ├── nifi-app.log
│   ├── nifi-bootstrap.log
│   └── nifi-user.log
├── extensions/                   # Drop extra .nar plugins here to add processors
├── work/                         # Temp working files NiFi unpacks at runtime
├── run/                          # Holds the PID (process id) file while running
├── content_repository/           # (created at runtime) actual FlowFile content
├── flowfile_repository/          # (created at runtime) FlowFile attributes/state
├── provenance_repository/        # (created at runtime) data history/receipts
├── database_repository/          # (created at runtime) internal bookkeeping
├── README
├── LICENSE
└── NOTICE
```

**The mental split:** `conf/` is the control room (settings + your saved flow), `lib/` and `extensions/` are the machine parts, `logs/` is the diary, and the four `*_repository/` folders are the warehouse where data and its history physically live while flowing through.

-----

## 4. The `nifi.sh` Server Commands (with Example Outputs)

This is the script you use to run the NiFi server itself. Everyday flow-building happens in the browser, not here.

> Examples assume you’re in `$NIFI_HOME` or have the `nifi` symlink. On Windows, use `bin\run-nifi.bat <command>`.

**Start NiFi (in the background):**

```bash
bin/nifi.sh start
```

Expected output:

```
Java home: /usr/lib/jvm/java-21-openjdk
NiFi home: /opt/nifi

Bootstrap Config File: /opt/nifi/conf/bootstrap.conf
```

NiFi keeps booting in the background for a minute or two. Then open `https://localhost:8443/nifi`.

**Check whether it’s running:**

```bash
bin/nifi.sh status
```

Expected output (running):

```
Java home: /usr/lib/jvm/java-21-openjdk
NiFi home: /opt/nifi
Bootstrap Config File: /opt/nifi/conf/bootstrap.conf

2026-06-18 09:14:22,331 INFO [main] org.apache.nifi.bootstrap.Command Apache NiFi is currently running, listening to Bootstrap on port 41234, PID=88123
```

Expected output (not running):

```
Apache NiFi is not running.
```

**Stop NiFi:**

```bash
bin/nifi.sh stop
```

Expected output:

```
Apache NiFi is currently running, PID=88123
Waiting for Apache NiFi to shutdown...
Apache NiFi has finished shutting down.
```

**Run in the foreground (watch logs live; Ctrl-C stops it):**

```bash
bin/nifi.sh run
```

**Restart:**

```bash
bin/nifi.sh restart
```

**Capture a diagnostics snapshot (great for troubleshooting or support tickets):**

```bash
bin/nifi.sh diagnostics diag.txt
```

Expected output:

```
Java home: /usr/lib/jvm/java-21-openjdk
NiFi home: /opt/nifi
Bootstrap Config File: /opt/nifi/conf/bootstrap.conf
2026-06-18 09:20:10,512 INFO [main] org.apache.nifi.bootstrap.Command Successfully wrote diagnostics information to /opt/nifi/diag.txt
```

**Capture a thread dump (for diagnosing hangs/high CPU):**

```bash
bin/nifi.sh dump threaddump.txt
```

Expected output:

```
Successfully wrote thread dump to /opt/nifi/threaddump.txt
```

**Install NiFi as a system service (so it starts on boot):**

```bash
sudo bin/nifi.sh install
# then manage it like any service:
sudo service nifi start
sudo service nifi status
```

|`nifi.sh` command   |What it does                                  |
|--------------------|----------------------------------------------|
|`start`             |Launch NiFi in the background                 |
|`stop`              |Shut NiFi down                                |
|`status`            |Is it running? Show PID                       |
|`run`               |Run in foreground (logs to console)           |
|`restart`           |Stop then start                               |
|`diagnostics <file>`|Write a full health snapshot to a file        |
|`dump <file>`       |Write a JVM thread dump to a file             |
|`install`           |Register as an OS service (auto-start on boot)|

-----

## 5. The NiFi Toolkit & CLI (with Example Outputs)

The **NiFi Toolkit** is a separate download (`nifi-toolkit-<version>-bin.zip`) with command-line tools for administration and automation. The NiFi Toolkit is a collection of command-line utilities and client libraries designed to simplify administrative operations for Apache NiFi and NiFi Registry, providing tools for TLS certificate management, flow management through CLI interfaces, and programmatic access to NiFi and Registry REST APIs.

### 5.1 The CLI — `cli.sh`

The CLI talks to NiFi’s REST API. It works two ways: **interactive** (you get a prompt) or **scriptable** (one command at a time for automation).

**Enter interactive mode:**

```bash
./bin/cli.sh
```

Expected output:

```
              _ ____  _
   _ __  (_)  ___(_)
  | '_ \ | | |_  | |
  | | | || |  _| | |
  |_| |_||_|_|   |_|

  CLI v2.0.0

Type 'help' to see available commands, 'exit' to quit.
#>
```

**Save connection settings so you don’t retype the URL every time** (the “session” concept). This will write the properties into the .nifi-cli.config in the user’s home directory and will allow commands to be executed without specifying a URL.

```bash
#> session set nifi.props /opt/nifi/conf/nifi-cli.properties
```

**List the processor groups currently on the canvas:**

```bash
./bin/cli.sh nifi pg-list -u https://localhost:8443
```

Expected output (simple format):

```
#   Name                  Id                                     Running  Stopped  Invalid
-   --------------------  -------------------------------------  -------  -------  -------
1   Ingest Logs           7a1d...e3f1                            4        0        0
2   Enrich and Route      9c44...b210                            2        1        0
```

**List parameter contexts** (reusable bundles of settings, in plain table or JSON):

```bash
./bin/cli.sh nifi list-param-contexts -u https://localhost:8443 -ot simple
```

Expected output:

```
#   Name              Id
-   ----------------  ------------------------------------
1   Prod-DB-Settings  8067d863-016e-1000-f0f7-265210d3e7dc
2   S3-Credentials    1b2c3d4e-5f60-7081-92a3-b4c5d6e7f809
```

**List registry buckets** (folders of versioned flows):

```bash
./bin/cli.sh registry list-buckets -u http://localhost:18080
```

Expected output:

```
#   Name          Id                                     Description
-   -----------   -------------------------------------  -----------
1   Development   dd323482-c62e-4b18-9f99-c782abd512b4   (empty)
2   Production    d3acee10-1bef-4fa8-a75c-0d0e37f7162e   (empty)
```

**Common CLI commands:**

|Command                                     |What it does                                   |
|--------------------------------------------|-----------------------------------------------|
|`nifi pg-list`                              |List process groups on the canvas              |
|`nifi pg-import`                            |Deploy a flow from the registry onto the canvas|
|`nifi pg-start` / `nifi pg-stop`            |Start/stop all processors in a group           |
|`nifi list-param-contexts`                  |List parameter contexts                        |
|`nifi export-param-context`                 |Export a parameter context to a file           |
|`nifi get-services` / `nifi pg-get-services`|List controller services                       |
|`registry list-buckets`                     |List registry buckets                          |
|`registry import-all-flows`                 |Bulk-load flows into a registry (DR/migration) |
|`registry export-all-flows`                 |Bulk-export all flows (backup)                 |

### 5.2 Other Toolkit Utilities

**Encrypt sensitive config values — `encrypt-config.sh`:**
Protects passwords inside `nifi.properties` and the XML files so they aren’t stored in plain text.

```bash
./bin/encrypt-config.sh -n /opt/nifi/conf/nifi.properties \
  -b /opt/nifi/conf/bootstrap.conf
```

**Back up / install / restore a NiFi installation — `file-manager.sh`:**
The File Manager utility allows system administrators to take a backup of an existing NiFi installation, install a new version of NiFi (while migrating any previous configuration settings) or restore an installation from a previous backup.

```bash
./bin/file-manager.sh -o backup \
  -b /opt/nifi/conf/bootstrap.conf \
  -c /opt/nifi -r /backups/nifi-2026-06-18
```

Expected output:

```
Successfully created backup of NiFi installation to /backups/nifi-2026-06-18
```

**Analyze a saved flow — `flow-analyzer.sh`:**
Reports sizing info like total disk usage and back-pressure thresholds for a flow file.

```bash
./bin/flow-analyzer.sh /opt/nifi/conf/flow.json.gz
```

Expected output (style):

```
Using flow=/opt/nifi/conf/flow.json.gz
Total Bytes Utilized by System=1518 GB
Max Back Pressure Size=1 GB
Max FlowFile Queue Size=10000
Avg FlowFile Queue Size=10000.0
```

**Manage cluster nodes — `node-manager.sh`:**
Node manager supports connecting, disconnecting and removing a node when in a cluster, as well as obtaining the status of a node.

**Send an announcement banner to users — `notify.sh`:**
Notify allows administrators to send messages as a banner to NiFi.

```bash
./bin/notify.sh -d /opt/nifi -b /opt/nifi/conf/bootstrap.conf \
  -m "Maintenance at 5pm — please save your work" -l WARN
```

|Toolkit tool       |What it’s for                                             |
|-------------------|----------------------------------------------------------|
|`cli.sh`           |Interactive/scriptable admin via REST API                 |
|`encrypt-config.sh`|Encrypt passwords in config files                         |
|`file-manager.sh`  |Backup / install / restore / upgrade installations        |
|`flow-analyzer.sh` |Report sizing/back-pressure for a flow file               |
|`node-manager.sh`  |Connect/disconnect/remove/status cluster nodes            |
|`notify.sh`        |Push an announcement banner to the UI                     |
|`s2s.sh`           |Send data into NiFi via Site-to-Site from the command line|

-----

## 6. Admin Tasks Explained Simply

### Task 1: Starting, stopping, and watching the server

Turn the mailroom on and off, and check it’s alive. Mostly `nifi.sh start | stop | status`. For boot-time auto-start, install it as a service.

*Tools:* `nifi.sh`, OS service manager (`systemd`/`service`).

### Task 2: Building and organizing flows

This happens **in the browser**, not the CLI. You drag processors onto the canvas, connect them with arrows, and group related pieces into Process Groups so big pipelines stay readable. Think of it like drawing a flowchart that actually moves data.

*Tools:* the NiFi web UI (canvas).

### Task 3: Monitoring health and flow

You watch the conveyor belts. Is any queue backing up (back pressure kicking in)? Is a processor erroring out? How much CPU/memory/disk is in use? NiFi shows live counts on every connection, plus a System Diagnostics screen.

*Tools:* NiFi UI status bars, Bulletin Board (in-app alerts), `nifi.sh diagnostics`, and external monitoring via reporting tasks → Prometheus/Grafana.

### Task 4: Managing back pressure and queues

Each belt (connection) has a limit on how many items or how many bytes it can hold. When full, NiFi automatically **pauses the upstream machine** so nothing overflows. As admin you tune these limits so fast producers don’t bury slow consumers.

*Tools:* connection settings in the UI; `flow-analyzer.sh` to review thresholds.

### Task 5: Version control of flows

Like saving named drafts of your pipeline so you can roll back. NiFi Registry stores versions in “buckets.” You commit a flow version, and later deploy that exact version to another environment (Dev → Test → Prod).

*Tools:* NiFi Registry, `cli.sh registry ...`.

### Task 6: Security — who can log in and who can do what

**Authentication** checks *who you are* (single-user for testing; LDAP/Kerberos/OIDC for real use). **Authorization** checks *what you’re allowed to do* (view vs. modify vs. admin), configured per-component. **Encryption** (HTTPS + encrypted config) protects data and passwords.

*Tools:* `nifi.properties`, `authorizers.xml`, `login-identity-providers.xml`, `encrypt-config.sh`, TLS certificates.

### Task 7: Data provenance (the receipts)

NiFi records the full history of every FlowFile — its origin, every change, and where it ended up. If someone asks “what happened to this record at 2:05pm?”, provenance shows the whole chain. This is one of NiFi’s signature strengths.

*Tools:* the Data Provenance screen in the UI; provenance repository.

### Task 8: Backups and upgrades

Keep copies of `conf/` (especially `flow.json.gz`) and the repositories. To upgrade, back up, install the new version while migrating config, and restore if needed.

*Tools:* `file-manager.sh`, plus copying `conf/` and repositories.

### Task 9: Clustering and scaling

For more capacity, run several NiFi nodes as one cluster. They coordinate through an embedded or external **ZooKeeper**, share the same flow, and split the data load. One node is elected “coordinator.”

*Tools:* cluster settings in `nifi.properties`, ZooKeeper, `node-manager.sh`.

-----

## 7. Tools in the NiFi World

|Tool                           |Category        |What it’s for                                                                 |
|-------------------------------|----------------|------------------------------------------------------------------------------|
|**NiFi Web UI (canvas)**       |Core            |Build, control, and monitor flows in a browser — the main interface           |
|**NiFi Toolkit CLI (`cli.sh`)**|Admin/Automation|Scriptable control via the REST API                                           |
|**NiFi Registry**              |Versioning      |Git-like version control and Dev→Prod deployment of flows                     |
|**MiNiFi**                     |Edge            |A tiny NiFi for small/edge devices (IoT, sensors) that ships data back to NiFi|
|**`encrypt-config.sh`**        |Security        |Encrypt sensitive values in config files                                      |
|**`file-manager.sh`**          |Ops             |Backup, install, restore, and upgrade installations                           |
|**`flow-analyzer.sh`**         |Ops             |Report flow sizing and back-pressure settings                                 |
|**`node-manager.sh`**          |Cluster         |Connect/disconnect/remove/status cluster nodes                                |
|**ZooKeeper**                  |Cluster         |Coordinates nodes and elects the cluster coordinator                          |
|**Reporting Tasks**            |Monitoring      |Push NiFi metrics out to Prometheus, Grafana, etc.                            |
|**REST API**                   |Integration     |Everything the UI does is available programmatically                          |
|**nipyapi**                    |Integration     |A popular Python library for automating NiFi & Registry                       |

-----

## 8. Use Cases (Real-World Scenarios)

### Use Case A: First launch and finding your login

**Goal:** Start NiFi for the first time and log in.

```bash
bin/nifi.sh start
# wait ~1–2 minutes, then fetch the generated credentials:
grep "Generated Username" logs/nifi-app.log
grep "Generated Password" logs/nifi-app.log
```

Then open `https://localhost:8443/nifi`, accept the self-signed-certificate warning, and log in with those credentials.
**Expected result:** the blank NiFi canvas, ready for you to drag on your first processor.

-----

### Use Case B: Build a simple “watch a folder, log the files” flow

**Goal:** Pull files from a local folder into NiFi (done in the browser).

1. Drag a **GetFile** (or **ListFile** + **FetchFile**) processor onto the canvas; set its *Input Directory* to `/opt/nifi/data-in`.
1. Drag a **LogAttribute** processor below it.
1. Draw an arrow from GetFile → LogAttribute and select the `success` relationship.
1. On LogAttribute, auto-terminate its `success` relationship so finished items are dropped.
1. Start both processors.

**Expected result:** files dropped into `data-in` ride the belt; their attributes appear in `logs/nifi-app.log`. Create a directory named data-in in the NiFi home directory first, or the processor will be invalid.

-----

### Use Case C: A queue is backing up — diagnose back pressure

**Goal:** Find why data has stopped flowing.

In the UI, look at the connection (arrow) between two processors. If it shows something like `10,000 / 10,000` in red, the queue is full and **back pressure** has paused the upstream processor.
**Fix options:** speed up or add concurrency to the slow downstream processor, raise the connection’s back-pressure threshold, or fix the downstream error causing the pile-up. To review thresholds offline:

```bash
./bin/file-manager.sh -o backup ...   # (optional safety backup first)
./bin/flow-analyzer.sh /opt/nifi/conf/flow.json.gz
```

-----

### Use Case D: Version a flow and deploy Dev → Prod

**Goal:** Promote a tested pipeline from the dev server to production unchanged.

```bash
# On the dev side: export everything from the dev registry
./bin/cli.sh registry export-all-flows \
  -u http://nifi-registry-dev:18080 \
  --outputDirectory "/exports"

# On the prod side: import into the prod registry
./bin/cli.sh registry import-all-flows \
  -u http://nifi-registry-prod:18080 \
  --input "/exports" --skipExisting
```

**Why this matters:** the flow you tested is the exact flow that runs in production — no manual re-clicking, no drift. This is the standard NiFi disaster-recovery/migration pattern.

-----

### Use Case E: Lock sensitive passwords out of plain text

**Goal:** Stop storing database passwords as readable text in config.

```bash
./bin/encrypt-config.sh -n /opt/nifi/conf/nifi.properties \
  -b /opt/nifi/conf/bootstrap.conf
```

**Expected result:** sensitive values in the config become encrypted blobs; NiFi decrypts them at startup using a master key referenced in `bootstrap.conf`.

-----

### Use Case F: Give NiFi more memory

**Goal:** A big flow is running out of heap. Increase it.

Edit `conf/bootstrap.conf`:

```properties
# Defaults are conservative; raise for heavier flows
java.arg.2=-Xms2g
java.arg.3=-Xmx4g
```

Then restart:

```bash
bin/nifi.sh restart
```

**Expected result:** NiFi launches with a 2 GB minimum / 4 GB maximum heap, reducing out-of-memory errors on large workloads.

-----

### Use Case G: Safe upgrade to a new NiFi version

**Goal:** Move from one version to the next without losing your flow.

```bash
# 1. Stop the old instance
bin/nifi.sh stop
# 2. Back up the existing install (config + optionally repositories)
./bin/file-manager.sh -o backup -b /opt/nifi/conf/bootstrap.conf \
  -c /opt/nifi -r /backups/nifi-pre-upgrade
# 3. Install the new version, migrating config from the old one
./bin/file-manager.sh -o install -b /opt/nifi/conf/bootstrap.conf \
  -c /opt/nifi -d /opt/nifi-new -m
```

**Expected result:** a fresh version with your settings and flow carried over; if anything breaks, restore from the backup.

-----

## 9. Cheat Sheet: Task → Tool

|Admin Task                 |Command / Place                                                     |Bigger Tool                               |
|---------------------------|--------------------------------------------------------------------|------------------------------------------|
|Start / stop / status      |`nifi.sh start | stop | status`                                     |OS service manager                        |
|Build & connect flows      |NiFi Web UI (canvas)                                                |—                                         |
|Monitor flow & health      |UI status + Bulletin Board                                          |Prometheus + Grafana (via reporting tasks)|
|Troubleshoot hangs         |`nifi.sh diagnostics` / `dump`                                      |—                                         |
|Tune queues / back pressure|Connection settings in UI                                           |`flow-analyzer.sh`                        |
|Version & promote flows    |`cli.sh registry ...`                                               |NiFi Registry                             |
|Scriptable admin           |`cli.sh nifi ...`                                                   |REST API, nipyapi                         |
|Secure passwords           |`encrypt-config.sh`                                                 |—                                         |
|Logins & permissions       |`nifi.properties`, `authorizers.xml`, `login-identity-providers.xml`|LDAP / OIDC / Kerberos                    |
|Backup / upgrade           |`file-manager.sh`                                                   |—                                         |
|Cluster nodes              |`node-manager.sh`                                                   |ZooKeeper                                 |
|Trace data history         |Data Provenance screen                                              |provenance repository                     |

-----

## 10. Quick Tips & Gotchas

- **It’s a browser tool first.** Unlike Kafka, you don’t build pipelines from the CLI — you build them on the canvas at `https://localhost:8443/nifi`. The CLI is for admin/automation.
- **Default is HTTPS on 8443, not HTTP on 8080.** Since NiFi 1.14, the unsecured `http://localhost:8080` default is gone. Expect a self-signed-cert browser warning locally.
- **First login is auto-generated.** Grab the username/password from `logs/nifi-app.log`. They’re random unless you set them.
- **Java 21 for NiFi 2.x.** The 2.0 line requires Java 21; 1.x ran on Java 8/11. Check `JAVA_HOME` if startup fails.
- **The flow file changed format.** NiFi 2.x saves `conf/flow.json.gz`; older 1.x used `conf/flow.xml.gz`. Old CLI examples mentioning `flow.xml.gz` are pre-2.x.
- **Move repositories off the default disk for production.** The four `*_repository` folders default under `$NIFI_HOME`; put them on dedicated fast storage so they don’t compete or fill the root disk.
- **Back pressure is a feature, not a bug.** A full red queue means NiFi is protecting itself. Investigate the slow/erroring downstream step rather than just raising limits.
- **Always back up `conf/` before upgrades.** Especially `flow.json.gz` (your whole pipeline) and the XML security files. `file-manager.sh` automates this.
- **Encrypt sensitive config.** Run `encrypt-config.sh` so database and keystore passwords aren’t sitting in plain text.
- **Tune memory in `bootstrap.conf`.** The default heap is modest. Raise `-Xms`/`-Xmx` for large flows, then restart.
- **Windows users:** use `bin\run-nifi.bat <command>` and the `.bat` toolkit scripts; paths use back-slashes.

-----

*Reference guide — Apache NiFi administration. Examples reflect NiFi 2.x conventions (HTTPS:8443, Java 21, flow.json.gz). Some toolkit tools (file-manager, node-manager, notify) have been available since the 1.x line and remain valid.*