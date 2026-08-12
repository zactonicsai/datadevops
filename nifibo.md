# Apache NiFi: Build It, Fix It, and Replace It

**A beginner-friendly guide (written so a middle schooler can follow it)**

Updated: August 2026 · Newest NiFi version: **2.11.0** (released 2026-08-03)

---

## Table of Contents

1. [What is NiFi? (The big picture)](#1-what-is-nifi-the-big-picture)
2. [The words you need to know](#2-the-words-you-need-to-know)
3. [Latest facts you must know in 2026](#3-latest-facts-you-must-know-in-2026)
4. [Part 1 — Step-by-step: build your first flow](#4-part-1--step-by-step-build-your-first-flow)
5. [Part 2 — The troubleshooting guide](#5-part-2--the-troubleshooting-guide)
6. [Part 3 — How to review a processor](#6-part-3--how-to-review-a-processor)
7. [Part 4 — How to review a whole flow](#7-part-4--how-to-review-a-whole-flow)
8. [Part 5 — How to decompose a flow (the 6-box method)](#8-part-5--how-to-decompose-a-flow-the-6-box-method)
9. [Part 6 — Rebuild it as a shell command-line flow](#9-part-6--rebuild-it-as-a-shell-command-line-flow)
10. [Part 7 — Rebuild it as a Python flow](#10-part-7--rebuild-it-as-a-python-flow)
11. [Part 8 — Rebuild it as AWS Lambda](#11-part-8--rebuild-it-as-aws-lambda)
12. [Part 9 — Rebuild it with Ansible](#12-part-9--rebuild-it-with-ansible)
13. [Part 10 — The big translation table](#13-part-10--the-big-translation-table)
14. [Part 11 — What you lose when you leave NiFi](#14-part-11--what-you-lose-when-you-leave-nifi)
15. [Part 12 — Safe migration plan](#15-part-12--safe-migration-plan)
16. [Pros and cons of every option](#16-pros-and-cons-of-every-option)
17. [Best practices checklist](#17-best-practices-checklist)
18. [Cheat sheet](#18-cheat-sheet)

---

## 1. What is NiFi? (The big picture)

Imagine a **school mail room**.

Letters arrive at the front door. A worker picks up each letter, checks the address, maybe stamps it, maybe puts three small letters into one big envelope, and then drops it in the right mailbox. If a mailbox is full, the worker stops and waits instead of dumping letters on the floor.

**Apache NiFi is that mail room, but for computer data.**

NiFi is a free program from the Apache Software Foundation. It was originally built by the U.S. National Security Agency and given to the open-source world in 2014. You use it by dragging boxes onto a screen and drawing arrows between them. Each box does one small job. The arrows are the conveyor belts.

### Why do people use NiFi?

- You can see data moving **live** on the screen. That is rare and really nice.
- It **remembers** every single piece of data it ever touched (this is called *provenance*), so you can answer "what happened to file X at 3:07 a.m.?"
- If the place you are sending data to goes down, NiFi **holds the data safely on disk** and keeps trying later.
- It has 300+ ready-made boxes for talking to S3, Kafka, databases, FTP, HTTP, Azure, Google Cloud, and more. You don't write code for most of them.

### Why do people leave NiFi?

- It is a **big Java server**. It wants a lot of memory (4–16 GB is normal) and a real machine or container running all the time.
- A tiny job — "copy one file every night" — needs the whole mail room built just for one letter. That is expensive.
- Reviewing a flow in a code review is painful, because the "code" is a giant JSON file made by dragging boxes.
- Cloud services like AWS Lambda now do many of the same jobs for pennies.

This guide teaches you **both**: how to run NiFi well, and how to safely tear a flow apart and rebuild it as a shell script, a Python script, a Lambda function, or an Ansible playbook.

---

## 2. The words you need to know

Learn these ten words and 90% of NiFi makes sense.

| Word | Kid-friendly meaning | Real meaning |
|---|---|---|
| **FlowFile** | One letter in the mail room | One piece of data: the *content* (the bytes) plus *attributes* (sticky notes like `filename`, `uuid`, `path`) |
| **Processor** | One worker who does one job | A box on the canvas, e.g. `FetchFile`, `InvokeHTTP`, `PutS3Object` |
| **Connection** | The conveyor belt between two workers | An arrow, which is really a **queue** that holds FlowFiles |
| **Relationship** | Which belt a letter goes on | Each processor has outputs like `success`, `failure`, `retry`, `original` |
| **Process Group** | A room full of workers | A folder that holds a bunch of processors so the screen isn't a mess |
| **Controller Service** | Shared tool everyone borrows | Shared settings, e.g. one database connection pool used by 5 processors |
| **Parameter Context** | The named settings sheet | Where you store values like bucket names and passwords (replaced old "Variables") |
| **Back Pressure** | "Mailbox full — stop bringing letters" | When a queue hits its limit, the upstream processor pauses automatically |
| **Provenance** | The security camera recording | A searchable history of every event for every FlowFile |
| **Bulletin** | The red sticky note on a worker's forehead | A short error/warning message shown in the UI for ~5 minutes |

Two more that matter for troubleshooting:

- **Repositories** — NiFi keeps three folders on disk: the **FlowFile repo** (the sticky notes + where each letter is), the **Content repo** (the actual bytes), and the **Provenance repo** (the camera footage). If any of these disks fill up, NiFi stops. This is the #1 cause of outages.
- **Penalization vs. Yield** — *Penalize* means "put this one letter aside for 30 seconds." *Yield* means "this whole worker takes a 1-second break." NiFi does these automatically when something fails.

---

## 3. Latest facts you must know in 2026

These are the up-to-date facts. A lot of blog posts online are from the NiFi 1.x days and are now **wrong**.

| Fact | Details |
|---|---|
| Current version | **NiFi 2.11.0**, released **2026-08-03**. Only the newest release gets security fixes. |
| Java version | **Java 21 is the minimum** for NiFi 2. Java 8 and 11 will not work. |
| NiFi 1.x | Version **1.28.1** was the last of the 1.x line, and its end-of-support date was **2024-12-08**. If you are still on 1.x, you are running unpatched software. |
| Templates | **Gone.** NiFi 2 removed XML templates. Use **flow definitions** (JSON) or a Git-backed registry instead. |
| Variables / Variable Registry | **Gone.** Use **Parameter Contexts** instead. They support sensitive (secret) values; variables did not. |
| NiFi Registry | **Deprecated** after a community vote in **February 2026**, and planned for removal in NiFi 3.0. The replacement is a **Git-based Flow Registry Client** — your flows live in a GitHub/GitLab repo. |
| Jython / Python in `ExecuteScript` | **Removed** in NiFi 2. `ExecuteScript` now supports only **Groovy and Clojure**. |
| New Python API | NiFi 2 lets you write **real processors in Python 3**. There are three base classes: `FlowFileTransform`, `RecordTransform`, and `FlowFileSource`. Note: you can only build **processors** this way — not controller services or reporting tasks. |
| Repository encryption | Removed in NiFi 2. Use disk-level encryption instead. |

> **Rule of thumb:** if a tutorial tells you to use a Template, a Variable, or a Jython script — it is out of date.

---

## 4. Part 1 — Step-by-step: build your first flow

We will build a small, real flow: **watch a folder, pick up new CSV files, add a timestamp to the name, and drop them in an output folder.**

This takes about 20 minutes.

### Step 0 — What you need

- Docker installed (easiest path), **or** Java 21 installed if you want to run the zip file.
- 4 GB of free RAM.
- A web browser.

### Step 1 — Start NiFi

Docker is the fastest way. Run this one command:

```bash
docker run --name nifi \
  -p 8443:8443 \
  -e SINGLE_USER_CREDENTIALS_USERNAME=admin \
  -e SINGLE_USER_CREDENTIALS_PASSWORD=changeThisPassword123 \
  -v "$HOME/nifi-in:/data/in" \
  -v "$HOME/nifi-out:/data/out" \
  -d apache/nifi:2.11.0
```

What each line does:

- `-p 8443:8443` — opens the web page on your computer's port 8443.
- `SINGLE_USER_CREDENTIALS_*` — sets your login. **The password must be at least 12 characters** or NiFi refuses to start.
- `-v` lines — share two folders from your computer into the container, so NiFi can read and write real files.
- `-d` — run in the background.

Make those two folders first:

```bash
mkdir -p ~/nifi-in ~/nifi-out
```

Watch it boot (it takes 1–2 minutes):

```bash
docker logs -f nifi
```

When you see a line saying the server has started, press `Ctrl+C` to stop watching.

**Not using Docker?** Download `nifi-2.11.0-bin.zip` from https://nifi.apache.org/download/, unzip it, then:

```bash
export JAVA_HOME=/path/to/java-21
./bin/nifi.sh set-single-user-credentials admin changeThisPassword123
./bin/nifi.sh start
./bin/nifi.sh status
```

### Step 2 — Log in

Open **https://localhost:8443/nifi**

- Your browser will scream about the certificate. That is expected — NiFi makes its own self-signed certificate. Click "Advanced" → "Proceed".
- Use `localhost`, **not** `127.0.0.1`. Java 21 checks the hostname against the certificate, and `127.0.0.1` fails.
- Log in with `admin` / `changeThisPassword123`.

You should now see a big empty grey canvas. That is your mail room floor.

### Step 3 — Add the first processor: `ListFile`

1. In the top toolbar, find the **processor icon** (a box with a plus). Drag it onto the canvas.
2. A search box appears. Type `ListFile`. Select it, click **Add**.
3. Double-click the new box to configure it.
4. Go to the **Properties** tab and set:
   - `Input Directory` = `/data/in`
   - `File Filter` = `.*\.csv` (this is a regular expression meaning "anything ending in .csv")
5. Go to the **Scheduling** tab and set `Run Schedule` = `10 sec` (check for new files every 10 seconds).
6. Click **Apply**.

**What does `ListFile` do?** It looks in a folder and makes one FlowFile *per file it sees* — but only the sticky notes, not the contents. It remembers what it already saw (this is called *state*), so it will not pick up the same file twice.

### Step 4 — Add `FetchFile`

1. Drag another processor. Search `FetchFile`. Add it.
2. Open it. The default property `File to Fetch` is `${absolute.path}/${filename}` — leave it. Those `${...}` things are **Expression Language**, NiFi's way of reading a sticky note.
3. On the **Relationships** tab, check **terminate** for `not.found`, `permission.denied`, and `failure` (for now — in real life you would route these to an alert).
4. Apply.

**What does `FetchFile` do?** It reads the actual bytes off disk and attaches them to the FlowFile.

### Step 5 — Add `UpdateAttribute` to rename the file

1. Drag a processor, search `UpdateAttribute`, add it.
2. Open it, go to **Properties**, click the **+** to add a custom property:
   - Property name: `filename`
   - Value: `${filename:substringBeforeLast('.')}_${now():format('yyyyMMdd-HHmmss')}.csv`
3. Apply.

That expression means: "take the filename, chop off the extension, glue on today's date and time, then add `.csv` back."

### Step 6 — Add `PutFile`

1. Drag a processor, search `PutFile`, add it.
2. Set `Directory` = `/data/out`.
3. On the **Relationships** tab, check **terminate** for `success` and `failure`. (`PutFile` is the end of the line, so nothing comes after it.)
4. Apply.

### Step 7 — Connect the boxes

Hover over the edge of `ListFile`. A circle-with-arrow appears. Drag from `ListFile` to `FetchFile`. A dialog asks which relationship — check **success** — and click **Add**.

Do the same for:

- `FetchFile` → `UpdateAttribute` (relationship: **success**)
- `UpdateAttribute` → `PutFile` (relationship: **success**)

Your flow now looks like:

```
[ListFile] --success--> [FetchFile] --success--> [UpdateAttribute] --success--> [PutFile]
```

### Step 8 — Start it

Click on an empty spot on the canvas to deselect, then press the **Play ▶** button in the Operate panel (or right-click the canvas → Start). All four boxes should turn green.

### Step 9 — Test it

Drop a file in the input folder:

```bash
echo "name,score
ada,99
alan,97" > ~/nifi-in/students.csv
```

Wait about 10 seconds, then look:

```bash
ls -l ~/nifi-out/
# students_20260812-141530.csv
```

🎉 **You just built a working data pipeline.**

### Step 10 — Look at the security camera (provenance)

Right-click `PutFile` → **View data provenance**. You will see a list of events. Click the ℹ️ icon on one, then the **Lineage** tab. You get a picture of everything that ever happened to that one file — created, fetched, renamed, sent. Keep this in mind; it is NiFi's superpower and the thing you will miss most if you leave.

### Step 11 — Save your work properly

Right-click on empty canvas → **Download flow definition** → **Without external services**. You now have a JSON file. **This JSON file is your source code.** Put it in Git. We will read it later when we decompose the flow.

---

## 5. Part 2 — The troubleshooting guide

### 5.1 The 5-minute triage checklist

When something breaks, do these in order. Do not skip ahead — 80% of problems are found in the first three steps.

1. **Look for red boxes and yellow triangles on the canvas.** A yellow ⚠️ means the processor is *invalid* (misconfigured). A red square means *stopped*. Hover over the icon to read why.
2. **Read the bulletins.** The little red rectangle on the top-right of a processor is a bulletin. Hover to read it. Bulletins expire after ~5 minutes, so check the **Bulletin Board** in the global menu for recent ones.
3. **Look at the queues.** Is one arrow holding 10,000 FlowFiles? That is where the traffic jam is. The problem is the processor *right after* that arrow.
4. **Check the logs.** In Docker: `docker exec nifi tail -100 logs/nifi-app.log`. On a server: `tail -f $NIFI_HOME/logs/nifi-app.log`.
5. **Check disk space.** `df -h`. If any repository disk is over ~90%, that is your problem.

### 5.2 Where everything lives

| Thing | Location |
|---|---|
| Main log (errors, stack traces) | `$NIFI_HOME/logs/nifi-app.log` |
| Startup/shutdown log | `$NIFI_HOME/logs/nifi-bootstrap.log` |
| Who logged in / did what | `$NIFI_HOME/logs/nifi-user.log` |
| Main settings | `$NIFI_HOME/conf/nifi.properties` |
| Memory settings (heap) | `$NIFI_HOME/conf/bootstrap.conf` |
| Log level settings | `$NIFI_HOME/conf/logback.xml` |
| The flow itself | `$NIFI_HOME/conf/flow.json.gz` |
| Data repositories | `content_repository/`, `flowfile_repository/`, `provenance_repository/` |

Handy commands:

```bash
# start / stop / check
./bin/nifi.sh start
./bin/nifi.sh stop
./bin/nifi.sh status

# dump a full diagnostics report (threads, memory, repo sizes) - very useful
./bin/nifi.sh diagnostics /tmp/nifi-diag.txt

# what is eating the disk?
du -sh content_repository provenance_repository flowfile_repository
```

### 5.3 The symptom → cause → fix table

#### Startup problems

| Symptom | Likely cause | Fix |
|---|---|---|
| NiFi won't start, no error in app log | Wrong Java version | Needs **Java 21+**. Run `java -version`. Set `JAVA_HOME` in `bin/nifi-env.sh`. |
| `Address already in use` | Port 8443 is taken | `lsof -i :8443`, kill it, or change `nifi.web.https.port` in `nifi.properties`. |
| Docker container exits right away | Password shorter than 12 characters | Use a 12+ character password in `SINGLE_USER_CREDENTIALS_PASSWORD`. |
| Starts, then dies after a few minutes | Not enough heap memory | Edit `conf/bootstrap.conf`: `java.arg.2=-Xms4g` and `java.arg.3=-Xmx4g`. |
| `FlowFile Repository failed to update` on boot | Repo corrupted after a hard kill | Restore from backup. Never `kill -9` NiFi; always use `nifi.sh stop`. |

#### Login and network problems

| Symptom | Likely cause | Fix |
|---|---|---|
| Browser shows an SNI or certificate error | You used `127.0.0.1` or an IP | Use `https://localhost:8443/nifi` or the real hostname in the certificate. |
| "Untrusted certificate" warning | Self-signed cert (normal) | Click through it, or install a real certificate. |
| Login page loads, credentials rejected | Password was regenerated | Search `nifi-app.log` for "Generated Username" / "Generated Password", or re-run `set-single-user-credentials`. |
| Logged in but everything is greyed out | You have no permission policies | Log in as the initial admin and grant yourself policies under **Users & Policies**. |

#### Processor problems

| Symptom | Likely cause | Fix |
|---|---|---|
| ⚠️ Yellow triangle, "is invalid" | A required property is blank, or a relationship isn't connected/terminated | Hover the triangle. It literally lists what is wrong. Connect or terminate *every* relationship. |
| Processor is green but does nothing | Nothing is triggering it, or the schedule is huge | Check **Scheduling** tab. Also check whether the upstream queue is empty. |
| Processor "runs" but the count is 0 | Back pressure from downstream | Look at the queue *after* it — is it at its limit? |
| Same file processed over and over | `ListFile`/`ListS3` state got cleared, or two nodes both running it | Right-click → **View state**. Set the processor to run on **Primary Node Only** in a cluster. |
| `ExecuteScript` won't accept Python | Jython was removed in NiFi 2 | Use **Groovy**, or write a real **Python processor** with the new Python API. |
| `InvokeHTTP` gives `Read timed out` | Remote server is slow | Raise `Read Timeout`, add a `Retry` relationship loop with a `RetryFlowFile` processor. |
| `PutSQL` / `ExecuteSQL` fails with driver errors | Missing JDBC jar | Point `Database Driver Location(s)` at the actual `.jar` file path on the NiFi machine. |

#### Data flow problems

| Symptom | Likely cause | Fix |
|---|---|---|
| Queue keeps growing, never shrinks | Downstream processor is slower than upstream | Increase **Concurrent Tasks** on the slow processor, or slow down the source. |
| Everything froze at once | Back pressure chain reaction — one full queue paused everything upstream | Find the *last* full queue in the chain; that's the real bottleneck. |
| FlowFiles disappear | Something is auto-terminating a relationship | Check for auto-terminated `failure` relationships. Route failures to a "dead letter" `PutFile` instead. |
| Data comes out corrupted or truncated | Merging/splitting misconfigured, or wrong character set | Check `MergeContent` demarcators and `Character Set` properties. |
| Duplicate records downstream | Retries after partial success | Add `DetectDuplicate` or make the destination *idempotent* (safe to write twice). |

#### Performance and memory problems

| Symptom | Likely cause | Fix |
|---|---|---|
| `OutOfMemoryError: Java heap space` | Processors loading whole files into memory (`SplitText` on a huge file, big `MergeContent`) | Split in two stages (1M lines → 10k lines). Raise heap. Use **record-based** processors instead. |
| NiFi grinds to a halt, high CPU | Too many concurrent tasks fighting for threads | Lower Concurrent Tasks; raise `Max Timer Driven Thread Count` only to about 2–4× your CPU cores. |
| Disk full | Content repo keeps data as long as any FlowFile references it, plus archive | Lower `nifi.content.repository.archive.max.retention.period` and `...max.usage.percentage` in `nifi.properties`. |
| Provenance repo huge | Default retention too long | Lower `nifi.provenance.repository.max.storage.time` (e.g. `24 hours`) and `max.storage.size`. |
| Slow for no reason | All three repositories on one spinning disk | Put content, flowfile, and provenance repos on **separate disks**. This is the single biggest performance win. |

#### Cluster problems

| Symptom | Likely cause | Fix |
|---|---|---|
| Node won't join, "flow fingerprint mismatch" | Node has a different flow than the cluster | Stop the node, delete its `conf/flow.json.gz`, restart — it will pull the cluster's copy. |
| Node keeps disconnecting | ZooKeeper timeout or long garbage-collection pause | Tune heap, raise `nifi.cluster.node.connection.timeout`. |
| Work is uneven across nodes | Source processor runs on one node only | Add a **load-balanced connection** (set Load Balance Strategy = Round Robin on the arrow). |

### 5.4 Reading a stack trace without fear

A Java error looks scary. You only need two things:

1. **The last "Caused by:" line.** That is the real reason.
2. **The processor name** at the start of the line, e.g. `PutS3Object[id=abc-123]`.

Example:

```
ERROR [Timer-Driven Process Thread-7] o.a.n.p.aws.s3.PutS3Object PutS3Object[id=1a2b] failed to process
  ...
  Caused by: java.net.UnknownHostException: my-bucket.s3.amazonaws.com
```

Translation: "the S3 box could not find that address" → check DNS, the bucket name, or the region. Ignore the 40 lines in the middle.

### 5.5 Turning up the logging

Edit `conf/logback.xml` and add a line for the class you care about. NiFi picks up changes without a restart (within ~30 seconds):

```xml
<logger name="org.apache.nifi.processors.standard.InvokeHTTP" level="DEBUG"/>
```

Turn it back to `INFO` when you are done — DEBUG logging can fill a disk fast.

### 5.6 Troubleshooting with the REST API

Sometimes the UI is too slow or you want to script your checks. Get a token first:

```bash
NIFI=https://localhost:8443
TOKEN=$(curl -sk -X POST "$NIFI/nifi-api/access/token" \
  -d "username=admin&password=changeThisPassword123")

# system health: heap, threads, repo usage
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$NIFI/nifi-api/system-diagnostics" | jq '.systemDiagnostics.aggregateSnapshot |
     {heapUtilization, usedHeap, availableProcessors, totalThreads}'

# every current bulletin (i.e. every recent error)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$NIFI/nifi-api/flow/bulletin-board" | jq -r '.bulletinBoard.bulletins[]
     | "\(.bulletin.timestamp) \(.bulletin.level) \(.bulletin.sourceName): \(.bulletin.message)"'

# find the fullest queues (your bottleneck)
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$NIFI/nifi-api/flow/process-groups/root/status?recursive=true" \
  | jq -r '.. | .connectionStatusSnapshots? // empty | .[]
     | "\(.connectionStatusSnapshot.name)\t\(.connectionStatusSnapshot.queued)"' | sort -k2 -hr | head
```

Save that last one as `nifi-hotspots.sh`. It answers "where is it stuck?" in one second.

---

## 6. Part 3 — How to review a processor

Before you can replace a flow, you have to *understand* it. Reviewing one processor is like reading one worker's job description. Ask these **10 questions** every single time.

### The 10-question processor review

| # | Question | Where to find the answer | Why it matters for replacement |
|---|---|---|---|
| 1 | **What type is it?** | The name on the box (e.g. `InvokeHTTP`) | Tells you which shell/Python tool replaces it |
| 2 | **What starts it?** | Scheduling tab → Timer / CRON / Event-driven | Becomes cron, EventBridge, or an S3 trigger |
| 3 | **How often?** | Scheduling tab → Run Schedule | `0 sec` means "as fast as possible" — a red flag |
| 4 | **How many at once?** | Scheduling tab → Concurrent Tasks | Tells you if you need parallelism in the rewrite |
| 5 | **Does it run everywhere or on one node?** | Scheduling tab → Execution | "Primary node only" = a singleton job |
| 6 | **What are its settings?** | Properties tab | These become your script's config/env vars |
| 7 | **Does it keep state?** | Right-click → View state | State = "what did I already process?" You must recreate this |
| 8 | **Where do failures go?** | Relationships tab + the arrows | Auto-terminated `failure` = data silently dropped. Note it! |
| 9 | **Does it touch the file contents or just the sticky notes?** | Read the docs | Attribute-only work is usually trivial to rewrite |
| 10 | **How much data goes through it?** | Status history (right-click → View status history) | 5 files/day → Lambda. 5,000 files/second → maybe keep NiFi |

### Doing the review from the command line

You do not have to click through 40 processors. Export the flow definition JSON (Step 11 earlier), then use `jq`.

**List every processor, its type, and its schedule:**

```bash
jq -r '
  [.. | objects | select(.type? and .name? and .scheduling? != null)] as $p
  | .flowContents | .. | objects | select(has("bundle") and has("scheduledState"))
  | "\(.name)\t\(.type | split(".") | last)\t\(.schedulingStrategy)\t\(.schedulingPeriod)\t\(.concurrentlySchedulableTaskCount)"
' my-flow.json | column -t
```

**A simpler, more reliable version** (works on any NiFi 2 flow definition):

```bash
# every processor: name, class, schedule
jq -r '.. | objects | select(.componentType? == "PROCESSOR")
  | "\(.name) | \(.type|split(".")|last) | \(.schedulingStrategy) \(.schedulingPeriod) | tasks=\(.concurrentlySchedulableTaskCount)"' \
  my-flow.json

# every property that is actually set (this is your config list)
jq -r '.. | objects | select(.componentType? == "PROCESSOR")
  | .name as $n | .properties | to_entries[] | select(.value != null)
  | "\($n)\t\(.key)\t\(.value)"' my-flow.json | column -t -s $'\t'

# every connection: from -> to, on which relationship
jq -r '.. | objects | select(.componentType? == "CONNECTION")
  | "\(.source.name) --\(.selectedRelationships|join(","))--> \(.destination.name)"' my-flow.json

# find auto-terminated failure paths (silent data loss!)
jq -r '.. | objects | select(.componentType? == "PROCESSOR")
  | select(.autoTerminatedRelationships? | index("failure"))
  | "DANGER: \(.name) silently drops failures"' my-flow.json

# find every external system the flow talks to
jq -r '.. | objects | select(.componentType? == "PROCESSOR") | .properties | to_entries[]
  | .value | strings | select(test("https?://|s3://|jdbc:|kafka|sftp://"))' my-flow.json | sort -u
```

Those five commands give you a complete inventory in under a minute. **Save the output — it is the specification for your replacement script.**

### Red flags to look for in a review

- 🚩 `Run Schedule = 0 sec` on a source processor → it spins the CPU constantly.
- 🚩 `failure` auto-terminated → data is being thrown away silently.
- 🚩 Passwords typed directly into a property instead of a **sensitive parameter**.
- 🚩 `ExecuteScript` or `ExecuteStreamCommand` doing heavy lifting → the "NiFi flow" is really just a script wearing a costume. **These are the easiest to replace.**
- 🚩 `SplitText` with a huge line count followed by `MergeContent` → classic memory killer; use record processors.
- 🚩 A processor with 20 concurrent tasks on a 4-core box → thread starvation.
- 🚩 No `RetryFlowFile` anywhere → transient network blips become permanent failures.

---

## 7. Part 4 — How to review a whole flow

One processor is a worker. A whole flow is the **business process**. Review it in four passes.

### Pass 1 — Draw the map

Use the connection dump from above and turn it into a picture. A quick trick:

```bash
# turn the flow into a Graphviz diagram
{
  echo 'digraph flow { rankdir=LR; node[shape=box,style=rounded];'
  jq -r '.. | objects | select(.componentType? == "CONNECTION")
    | "\"\(.source.name)\" -> \"\(.destination.name)\" [label=\"\(.selectedRelationships|join(","))\"];"' my-flow.json
  echo '}'
} > flow.dot
dot -Tpng flow.dot -o flow.png     # needs graphviz installed
```

Now you can *see* the flow on one page, including the dead ends.

### Pass 2 — Answer the "business" questions

Write these answers down in a one-page document. If you cannot answer them, you are not ready to replace anything.

1. **What is the input?** (files in a folder? an API? a Kafka topic? a database table?)
2. **What is the output?** (S3? a database? an email? another API?)
3. **When does it run?** (every 5 minutes? when a file lands? once at 2 a.m.?)
4. **How much data?** (10 KB/day or 10 TB/day? 100 files or 10 million?)
5. **How fast must it be?** (does anyone care if it takes 30 minutes?)
6. **What happens if it fails?** (does someone get paged? does data get lost? can you just re-run it?)
7. **Can it safely run twice on the same data?** (this is called *idempotency* — it decides how simple your rewrite can be)
8. **Who owns it and who consumes the output?**

### Pass 3 — Measure it

Right-click the process group → **View status history**. Look at the last 30 days:

- Bytes in / out per 5 minutes
- Tasks and task duration
- Queue depths

**Why this matters:** most flows people are afraid to touch turn out to move a few hundred megabytes a day. That is a Lambda job, not a cluster job.

### Pass 4 — Score it for replacement

Give the flow points. Higher score = easier to replace.

| Question | Yes | No |
|---|---|---|
| Under ~50 GB/day total? | +2 | 0 |
| Runs on a schedule (not continuous streaming)? | +2 | 0 |
| Fewer than ~15 processors? | +2 | 0 |
| No Kafka/JMS/streaming sources? | +1 | 0 |
| No back-pressure tuning needed? | +1 | 0 |
| Safe to re-run on the same data (idempotent)? | +2 | 0 |
| No one needs the provenance UI for audits? | +2 | -3 |
| Nobody edits the flow through the UI weekly? | +1 | -2 |
| Each unit of work finishes in under 15 minutes? | +2 | 0 |

**Score guide:**

- **12+** → Replace it. Shell or Lambda will be simpler and cheaper.
- **7–11** → Replaceable, but you must rebuild retries and logging carefully.
- **Under 7** → Keep NiFi. You would end up rebuilding NiFi badly.

---

## 8. Part 5 — How to decompose a flow (the 6-box method)

**Decompose** just means "break the big thing into small parts you understand."

Every data flow ever built, in any tool, is made of the same **six boxes**. Your job is to sort each NiFi processor into one of these six boxes. Once you do that, rewriting it is almost mechanical.

```
┌──────────┐   ┌────────┐   ┌───────────┐   ┌───────┐   ┌──────┐
│ 1 TRIGGER│──▶│2 SOURCE│──▶│3 TRANSFORM│──▶│4 ROUTE│──▶│5 SINK│
└──────────┘   └────────┘   └───────────┘   └───────┘   └──────┘
                          ▲                                   │
                          └──────── 6 GUARDRAILS ─────────────┘
                    (retries, state, dedupe, alerts, logging)
```

| Box | Question it answers | NiFi examples | Replacement examples |
|---|---|---|---|
| **1 Trigger** | *When does work start?* | Scheduling tab, `GenerateFlowFile`, `ListenHTTP` | `cron`, `systemd timer`, S3 event, EventBridge Scheduler, `inotifywait` |
| **2 Source** | *Where does data come from?* | `ListFile`+`FetchFile`, `ConsumeKafka`, `InvokeHTTP`, `ExecuteSQL`, `FetchS3Object` | `find`, `curl`, `psql`, `boto3`, `requests` |
| **3 Transform** | *How does the data change?* | `ConvertRecord`, `JoltTransformJSON`, `UpdateAttribute`, `ReplaceText`, `CompressContent` | `jq`, `awk`, `sed`, `pandas`, `duckdb`, `gzip` |
| **4 Route** | *Which data goes where?* | `RouteOnAttribute`, `RouteOnContent`, `ValidateRecord` | `if`/`case`, Python `if`, a filter function |
| **5 Sink** | *Where does it end up?* | `PutS3Object`, `PutSQL`, `PutSFTP`, `PublishKafka`, `PutFile` | `aws s3 cp`, `psql \copy`, `sftp`, `boto3` |
| **6 Guardrails** | *What keeps it honest?* | Back pressure, `RetryFlowFile`, `DetectDuplicate`, provenance, bulletins, `PutEmail` | `set -euo pipefail`, retry loops, a state file, DLQ, CloudWatch alarms, logging |

### The decomposition worksheet

Fill in this table for your flow. This is the **single most important artifact** in the whole migration — it is the contract your new code must satisfy.

| Box | NiFi processors involved | What it actually does (plain English) | Config values | Replacement plan |
|---|---|---|---|---|
| Trigger | | | | |
| Source | | | | |
| Transform | | | | |
| Route | | | | |
| Sink | | | | |
| Guardrails | | | | |

### Worked example: decomposing a real flow

Here is a typical flow you will meet in the wild — a nightly vendor-file loader:

```
[ListSFTP] ─▶ [FetchSFTP] ─▶ [ValidateRecord] ─┬─valid──▶ [ConvertRecord CSV→JSON] ─▶ [PutS3Object]
                                                │                                          │
                                                └─invalid─▶ [PutFile /data/quarantine]      └─▶ [PutSQL audit row]
                                                                    │
                                                              [PutEmail alert]
```

Decomposed:

| Box | NiFi processors | Plain English | Config | Replacement plan |
|---|---|---|---|---|
| **Trigger** | `ListSFTP` scheduled `0 2 * * *` (CRON) | Runs at 2 a.m. daily | CRON `0 0 2 * * ?` | `cron` line, or EventBridge Scheduler |
| **Source** | `ListSFTP` + `FetchSFTP` | Download new `*.csv` from vendor SFTP | host, port 22, user, key, `/outbound` | `sftp` + `get -r`, or Python `paramiko` |
| **Transform** | `ConvertRecord` (CSV reader → JSON writer) | Turn CSV rows into JSON | schema, headers=true | `python -c` with `csv`+`json`, or `duckdb`, or `mlr` |
| **Route** | `ValidateRecord` | Good rows go on, bad rows quarantined | Avro schema | `if` on validation result |
| **Sink** | `PutS3Object`, `PutSQL`, `PutFile` | Upload to S3, write an audit row, save bad rows | bucket, prefix, JDBC URL | `aws s3 cp`, `psql -c INSERT`, `mv` |
| **Guardrails** | `ListSFTP` state, `PutEmail`, retry loop | Don't re-download old files; email on failure | SMTP host | State file of processed names; `trap` + `mail`/SNS |

**Notice what happened:** an 8-box canvas turned into six plain sentences. Everything from here is just typing.

### Two rules before you write any code

1. **Recreate the state.** If `ListSFTP` remembered which files it saw, your script *must* remember too — otherwise you will reprocess a year of files on the first run. A state file, a DynamoDB table, or "move the file after processing" all work.
2. **Recreate the failure paths.** Every arrow that went somewhere other than `success` is a requirement. If you drop it, you have quietly changed the business behavior.

---

## 9. Part 6 — Rebuild it as a shell command-line flow

Shell is the right choice when the flow is basically "move a file, run a tool on it, put it somewhere else."

### The core idea: a pipeline is just a pipeline

NiFi's canvas and the Unix pipe are the same idea. Look:

```
NiFi:  [FetchFile] ─▶ [ConvertRecord] ─▶ [CompressContent] ─▶ [PutS3Object]

Shell:  cat input.csv | mlr --icsv --ojson cat | gzip -c | aws s3 cp - s3://bucket/out.json.gz
```

Each `|` is a connection. Each command is a processor. The difference is that NiFi's queues live on disk (so nothing is lost if you reboot), and a pipe lives in memory (so a reboot loses everything). That difference is exactly what your guardrails section has to make up for.

### Step-by-step: build the shell version

**Step 1 — Make the skeleton safe.** Every production shell script starts the same way:

```bash
#!/usr/bin/env bash
set -euo pipefail          # e=stop on error, u=stop on undefined var, pipefail=catch errors mid-pipe
IFS=$'\n\t'
```

**Step 2 — Put config at the top**, never buried in the logic:

```bash
SFTP_HOST="${SFTP_HOST:?set SFTP_HOST}"
SFTP_USER="${SFTP_USER:?set SFTP_USER}"
REMOTE_DIR="${REMOTE_DIR:-/outbound}"
S3_BUCKET="${S3_BUCKET:?set S3_BUCKET}"
WORK_DIR="${WORK_DIR:-/var/tmp/vendorload}"
STATE_FILE="${STATE_FILE:-/var/lib/vendorload/seen.txt}"
```

**Step 3 — Add logging and a failure trap** (this is your bulletin board + `PutEmail`):

```bash
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$1" "${*:2}" >&2; }
fail() { log ERROR "$*"; exit 1; }
trap 'log ERROR "line $LINENO failed"; notify "vendorload FAILED on $(hostname)"' ERR
```

**Step 4 — Add the state file** (this replaces `ListSFTP`'s memory):

```bash
mkdir -p "$(dirname "$STATE_FILE")" "$WORK_DIR"
touch "$STATE_FILE"
already_seen() { grep -Fxq "$1" "$STATE_FILE"; }
mark_seen()   { printf '%s\n' "$1" >> "$STATE_FILE"; }
```

**Step 5 — Write the flow, one box at a time.**

### The complete script

```bash
#!/usr/bin/env bash
# vendorload.sh - replaces the NiFi "nightly vendor load" flow
# Boxes: Trigger=cron | Source=sftp | Transform=csv->json | Route=validate | Sink=s3+psql | Guardrails=below
set -euo pipefail
IFS=$'\n\t'

# ---------- CONFIG (was: NiFi Parameter Context) ----------
SFTP_HOST="${SFTP_HOST:?}"; SFTP_USER="${SFTP_USER:?}"; SFTP_KEY="${SFTP_KEY:-$HOME/.ssh/vendor_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/outbound}"
S3_BUCKET="${S3_BUCKET:?}"; S3_PREFIX="${S3_PREFIX:-vendor/daily}"
WORK_DIR="${WORK_DIR:-/var/tmp/vendorload}"
QUARANTINE="${QUARANTINE:-/var/lib/vendorload/quarantine}"
STATE_FILE="${STATE_FILE:-/var/lib/vendorload/seen.txt}"
LOCK_FILE="/var/lock/vendorload.lock"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# ---------- GUARDRAILS ----------
log()  { printf '%s run=%s [%s] %s\n' "$(date -u +%FT%TZ)" "$RUN_ID" "$1" "${*:2}" >&2; }
notify() { aws sns publish --topic-arn "${SNS_TOPIC:-}" --subject "vendorload" --message "$1" >/dev/null 2>&1 || true; }
trap 'rc=$?; [ $rc -ne 0 ] && { log ERROR "failed at line $LINENO (rc=$rc)"; notify "vendorload FAILED run=$RUN_ID"; }' EXIT

# only one copy at a time (this replaces "Primary Node Only")
exec 9>"$LOCK_FILE"; flock -n 9 || { log WARN "already running, exiting"; exit 0; }

mkdir -p "$WORK_DIR" "$QUARANTINE" "$(dirname "$STATE_FILE")"; touch "$STATE_FILE"

# retry helper (this replaces RetryFlowFile + penalization)
retry() {
  local n=0 max=${RETRIES:-4} delay=5
  until "$@"; do
    n=$((n+1)); [ "$n" -ge "$max" ] && return 1
    log WARN "attempt $n failed: $*; sleeping ${delay}s"
    sleep "$delay"; delay=$((delay*2))          # exponential backoff
  done
}

# ---------- BOX 2: SOURCE (was ListSFTP + FetchSFTP) ----------
log INFO "listing $SFTP_HOST:$REMOTE_DIR"
listing=$(sftp -q -i "$SFTP_KEY" "$SFTP_USER@$SFTP_HOST" <<< "ls -1 $REMOTE_DIR/*.csv" | tail -n +2)

count=0
while IFS= read -r remote; do
  [ -z "$remote" ] && continue
  base=$(basename "$remote")
  grep -Fxq "$base" "$STATE_FILE" && { log DEBUG "skip $base (already seen)"; continue; }

  local_csv="$WORK_DIR/$base"
  log INFO "fetching $base"
  retry sftp -q -i "$SFTP_KEY" "$SFTP_USER@$SFTP_HOST:$remote" "$local_csv" || { log ERROR "fetch failed $base"; continue; }

  # ---------- BOX 4: ROUTE (was ValidateRecord) ----------
  header=$(head -1 "$local_csv")
  if [ "$header" != "order_id,customer,amount,order_date" ]; then
      log WARN "bad header in $base -> quarantine"
      mv "$local_csv" "$QUARANTINE/"; notify "vendorload quarantined $base (bad header)"; continue
  fi
  if ! awk -F, 'NR>1 && ($3 !~ /^[0-9]+(\.[0-9]+)?$/) { exit 1 }' "$local_csv"; then
      log WARN "non-numeric amount in $base -> quarantine"
      mv "$local_csv" "$QUARANTINE/"; continue
  fi

  # ---------- BOX 3: TRANSFORM (was ConvertRecord CSV -> JSON, then CompressContent) ----------
  out_json="$WORK_DIR/${base%.csv}.json.gz"
  python3 -c '
import csv,json,sys
w=sys.stdout
for row in csv.DictReader(open(sys.argv[1])):
    row["amount"]=float(row["amount"])
    w.write(json.dumps(row)+"\n")
' "$local_csv" | gzip -c > "$out_json"

  # ---------- BOX 5: SINK (was PutS3Object + PutSQL) ----------
  key="$S3_PREFIX/dt=$(date -u +%F)/$(basename "$out_json")"
  retry aws s3 cp "$out_json" "s3://$S3_BUCKET/$key" --only-show-errors \
    || { log ERROR "upload failed $base"; continue; }

  rows=$(( $(wc -l < "$local_csv") - 1 ))
  retry psql "$PGURL" -v ON_ERROR_STOP=1 -c \
    "INSERT INTO load_audit(file_name,row_count,s3_key,loaded_at) VALUES ('$base',$rows,'$key',now())"

  # ---------- GUARDRAIL: record state only AFTER full success ----------
  printf '%s\n' "$base" >> "$STATE_FILE"
  rm -f "$local_csv" "$out_json"
  count=$((count+1))
  log INFO "done $base rows=$rows key=$key"
done <<< "$listing"

log INFO "run complete files=$count"
```

### Step 6 — The trigger (was the Scheduling tab)

**Option A: cron** (simple, everywhere):

```cron
# m h dom mon dow
0 2 * * *  SFTP_HOST=sftp.vendor.com SFTP_USER=svc S3_BUCKET=my-bucket /opt/jobs/vendorload.sh >> /var/log/vendorload.log 2>&1
```

**Option B: systemd timer** (better — gives you logs, retries, and status):

```ini
# /etc/systemd/system/vendorload.service
[Unit]
Description=Vendor CSV load (replaces NiFi flow)
[Service]
Type=oneshot
EnvironmentFile=/etc/vendorload.env
ExecStart=/opt/jobs/vendorload.sh
```

```ini
# /etc/systemd/system/vendorload.timer
[Unit]
Description=Run vendor load nightly
[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=300
Persistent=true          # if the machine was off at 2am, run at next boot
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now vendorload.timer
systemctl list-timers vendorload.timer
journalctl -u vendorload.service -n 100 --no-pager      # this is your new nifi-app.log
```

**Option C: event-driven** (replaces `ListenHTTP`/`GetFile` real-time behavior):

```bash
inotifywait -m -e close_write --format '%w%f' /data/in \
  | while read -r f; do /opt/jobs/process_one.sh "$f"; done
```

### Testing your shell flow

```bash
bash -n vendorload.sh                 # syntax check
shellcheck vendorload.sh              # linter - catches 90% of shell bugs, install it
bash -x vendorload.sh                 # trace every line as it runs
DRY_RUN=1 ./vendorload.sh             # add a dry-run switch to your script
```

### Shell pros and cons

| Pros | Cons |
|---|---|
| Zero infrastructure — runs on any Linux box | No UI; nobody can "see" the flow |
| Trivial to read in a Git diff | Error handling must be written by hand |
| Starts in milliseconds, uses ~1 MB RAM | Quoting and spaces in filenames cause real bugs |
| Uses tools already installed | No back pressure — a burst can overwhelm you |
| Free | Hard to maintain past ~200 lines |
| Easy to test locally | No built-in provenance/audit trail |

**Use shell when:** the flow is under ~10 steps, runs on a schedule, and mostly moves/converts files.
**Don't use shell when:** you need parallelism, complex data structures, or more than ~200 lines.

---

## 10. Part 7 — Rebuild it as a Python flow

Python is the sweet spot for most NiFi replacements. It handles JSON, CSV, APIs, and errors far better than shell, and it is still just a file you can read.

### The design: build the same six boxes as functions

The trick is to write **one small function per box**, then a `main()` that wires them together. That way the code *looks like* the canvas.

### The complete Python version

```python
#!/usr/bin/env python3
"""vendorload.py - replaces the NiFi 'nightly vendor load' flow.

Box map:
  1 TRIGGER    -> cron/systemd calls main()
  2 SOURCE     -> fetch_new_files()      (was ListSFTP + FetchSFTP)
  3 TRANSFORM  -> csv_to_jsonl()         (was ConvertRecord + CompressContent)
  4 ROUTE      -> validate()             (was ValidateRecord)
  5 SINK       -> upload(), audit()      (was PutS3Object + PutSQL)
  6 GUARDRAILS -> retry(), State, logging, quarantine, lock
"""
from __future__ import annotations

import csv, gzip, json, logging, os, sys, time, fcntl
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Callable, Any

import boto3            # pip install boto3
import paramiko         # pip install paramiko

# ---------------- CONFIG (was: Parameter Context) ----------------
@dataclass(frozen=True)
class Config:
    sftp_host: str = os.environ["SFTP_HOST"]
    sftp_user: str = os.environ["SFTP_USER"]
    sftp_key:  str = os.environ.get("SFTP_KEY", str(Path.home() / ".ssh/vendor_ed25519"))
    remote_dir: str = os.environ.get("REMOTE_DIR", "/outbound")
    bucket: str = os.environ["S3_BUCKET"]
    prefix: str = os.environ.get("S3_PREFIX", "vendor/daily")
    work_dir: Path = Path(os.environ.get("WORK_DIR", "/var/tmp/vendorload"))
    quarantine: Path = Path(os.environ.get("QUARANTINE", "/var/lib/vendorload/quarantine"))
    state_file: Path = Path(os.environ.get("STATE_FILE", "/var/lib/vendorload/seen.json"))
    expected_header: tuple = ("order_id", "customer", "amount", "order_date")

log = logging.getLogger("vendorload")

# ---------------- GUARDRAILS ----------------
def setup_logging() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format='{"ts":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}',
        stream=sys.stderr,
    )

def retry(fn: Callable[..., Any], *args, attempts: int = 4, base: float = 2.0, **kw) -> Any:
    """Replaces RetryFlowFile + penalization: exponential backoff."""
    for i in range(1, attempts + 1):
        try:
            return fn(*args, **kw)
        except Exception as exc:
            if i == attempts:
                raise
            wait = base ** i
            log.warning("attempt %d/%d failed (%s); retrying in %.0fs", i, attempts, exc, wait)
            time.sleep(wait)

class State:
    """Replaces the processor's stored state ('what have I already seen?')."""
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.seen: set[str] = set(json.loads(path.read_text())) if path.exists() else set()

    def __contains__(self, name: str) -> bool:
        return name in self.seen

    def add(self, name: str) -> None:
        self.seen.add(name)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(sorted(self.seen)))
        tmp.replace(self.path)          # atomic write, so a crash can't corrupt state

class SingleRun:
    """Replaces 'Execution: Primary Node Only' - stops two copies running at once."""
    def __init__(self, path="/var/lock/vendorload.lock"):
        self.fh = open(path, "w")
    def __enter__(self):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log.warning("another run in progress; exiting")
            sys.exit(0)
        return self
    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)

# ---------------- BOX 2: SOURCE ----------------
def sftp_client(cfg: Config) -> paramiko.SFTPClient:
    ssh = paramiko.SSHClient()
    ssh.load_system_host_keys()
    ssh.set_missing_host_key_policy(paramiko.RejectPolicy())   # never AutoAddPolicy in production
    ssh.connect(cfg.sftp_host, username=cfg.sftp_user, key_filename=cfg.sftp_key, timeout=30)
    return ssh.open_sftp()

def list_new(cfg: Config, sftp: paramiko.SFTPClient, state: State) -> Iterator[str]:
    for name in sorted(sftp.listdir(cfg.remote_dir)):
        if name.endswith(".csv") and name not in state:
            yield name

def fetch(cfg: Config, sftp, name: str) -> Path:
    dest = cfg.work_dir / name
    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    retry(sftp.get, f"{cfg.remote_dir}/{name}", str(dest))
    log.info("fetched %s (%d bytes)", name, dest.stat().st_size)
    return dest

# ---------------- BOX 4: ROUTE ----------------
class ValidationError(Exception):
    pass

def validate(cfg: Config, path: Path) -> int:
    with path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        if tuple(reader.fieldnames or ()) != cfg.expected_header:
            raise ValidationError(f"header was {reader.fieldnames}, expected {cfg.expected_header}")
        rows = 0
        for i, row in enumerate(reader, start=2):
            try:
                float(row["amount"])
            except (TypeError, ValueError):
                raise ValidationError(f"line {i}: amount={row.get('amount')!r} is not a number")
            rows += 1
    return rows

# ---------------- BOX 3: TRANSFORM ----------------
def csv_to_jsonl_gz(src: Path, dst: Path) -> Path:
    """Streams row by row - never loads the whole file into memory."""
    with src.open(newline="") as fin, gzip.open(dst, "wt", encoding="utf-8") as fout:
        for row in csv.DictReader(fin):
            row["amount"] = float(row["amount"])
            row["ingested_at"] = datetime.now(timezone.utc).isoformat()
            fout.write(json.dumps(row) + "\n")
    return dst

# ---------------- BOX 5: SINK ----------------
def upload(cfg: Config, path: Path) -> str:
    key = f"{cfg.prefix}/dt={datetime.now(timezone.utc):%Y-%m-%d}/{path.name}"
    retry(boto3.client("s3").upload_file, str(path), cfg.bucket, key)
    log.info("uploaded s3://%s/%s", cfg.bucket, key)
    return key

def audit(name: str, rows: int, key: str) -> None:
    import psycopg                       # pip install "psycopg[binary]"
    with psycopg.connect(os.environ["PGURL"]) as conn:
        conn.execute(
            "INSERT INTO load_audit(file_name,row_count,s3_key,loaded_at) VALUES (%s,%s,%s,now())",
            (name, rows, key),
        )

def quarantine(cfg: Config, path: Path, reason: str) -> None:
    cfg.quarantine.mkdir(parents=True, exist_ok=True)
    path.rename(cfg.quarantine / path.name)
    log.error("QUARANTINED %s: %s", path.name, reason)

# ---------------- MAIN: the canvas, in code ----------------
def main() -> int:
    setup_logging()
    cfg = Config()
    state = State(cfg.state_file)
    ok = failed = 0

    with SingleRun(), sftp_client(cfg) as sftp:
        for name in list_new(cfg, sftp, state):
            local = None
            try:
                local = fetch(cfg, sftp, name)                       # SOURCE
                rows = validate(cfg, local)                          # ROUTE
                out = csv_to_jsonl_gz(local, cfg.work_dir / f"{local.stem}.jsonl.gz")  # TRANSFORM
                key = upload(cfg, out)                               # SINK
                audit(name, rows, key)                               # SINK
                state.add(name)                                      # GUARDRAIL: only after success
                out.unlink(missing_ok=True); local.unlink(missing_ok=True)
                ok += 1
            except ValidationError as exc:
                if local: quarantine(cfg, local, str(exc))
                state.add(name)          # bad file: don't retry forever
                failed += 1
            except Exception:
                log.exception("failed processing %s - will retry next run", name)
                failed += 1              # do NOT add to state, so it retries tomorrow

    log.info("run complete ok=%d failed=%d", ok, failed)
    return 1 if failed else 0

if __name__ == "__main__":
    sys.exit(main())
```

### Why this design is good

- Each of the six boxes is **one function**, so the code reads like the canvas.
- `state.add(name)` happens **only after full success** — that is how you get "at-least-once delivery" like NiFi's.
- A validation failure quarantines and *moves on*; a network failure leaves the file unprocessed so it retries. That distinction is exactly what NiFi's `failure` vs `retry` relationships mean.
- Everything streams. `csv_to_jsonl_gz` never loads the whole file, so a 10 GB file uses a few megabytes of RAM. (This is the fix for NiFi's classic `SplitText` out-of-memory problem too.)

### Testing your Python flow

```bash
python -m pytest tests/                    # unit test validate() and csv_to_jsonl_gz()
python -m mypy vendorload.py               # type checking
ruff check vendorload.py                   # fast linter
LOG_LEVEL=DEBUG python vendorload.py       # verbose run
```

A tiny example test — this is something you simply cannot do with a NiFi canvas:

```python
def test_validate_rejects_bad_amount(tmp_path):
    p = tmp_path / "x.csv"
    p.write_text("order_id,customer,amount,order_date\n1,ada,abc,2026-01-01\n")
    with pytest.raises(ValidationError, match="not a number"):
        validate(Config(), p)
```

### Bonus: keep NiFi but write the logic in Python

If you must stay on NiFi, NiFi 2 lets you write a **real processor in Python**. Drop this in `$NIFI_HOME/python/extensions/` and restart:

```python
from nifiapi.flowfiletransform import FlowFileTransform, FlowFileTransformResult
from nifiapi.properties import PropertyDescriptor, StandardValidators
import csv, io, json

class CsvToJson(FlowFileTransform):
    class Java:
        implements = ['org.apache.nifi.python.processor.FlowFileTransform']
    class ProcessorDetails:
        version = '1.0.0'
        description = 'Convert CSV content to newline-delimited JSON.'
        tags = ['csv', 'json']

    AMOUNT_FIELD = PropertyDescriptor(
        name="Numeric Field",
        description="Field to cast to a number",
        default_value="amount",
        validators=[StandardValidators.NON_EMPTY_VALIDATOR],
    )

    def getPropertyDescriptors(self):
        return [self.AMOUNT_FIELD]

    def transform(self, context, flowfile):
        field = context.getProperty(self.AMOUNT_FIELD).getValue()
        text = flowfile.getContentsAsBytes().decode("utf-8")
        out = io.StringIO()
        n = 0
        for row in csv.DictReader(io.StringIO(text)):
            row[field] = float(row[field])
            out.write(json.dumps(row) + "\n")
            n += 1
        return FlowFileTransformResult(
            relationship="success",
            contents=out.getvalue().encode("utf-8"),
            attributes={"record.count": str(n), "mime.type": "application/x-ndjson"},
        )
```

The three Python base classes you can extend are `FlowFileTransform` (change one FlowFile), `RecordTransform` (change record by record), and `FlowFileSource` (create FlowFiles from nothing). Remember: **Python can only make processors** — not controller services or reporting tasks.

### Python pros and cons

| Pros | Cons |
|---|---|
| Real error handling, real tests, real types | Needs Python + dependency management (venv, `uv`, or a container) |
| Handles JSON/CSV/APIs naturally | Slower than compiled tools on huge files |
| Massive library ecosystem (`pandas`, `boto3`, `duckdb`, `requests`) | You must build retries/state yourself |
| Reviewable in a normal pull request | No UI for non-engineers |
| Same code runs locally, on a server, or in Lambda | Dependency drift over years |

**Use Python when:** there is any real logic, any API calls, or anything you want to unit test.

---

## 11. Part 8 — Rebuild it as AWS Lambda

Lambda is a way to run a small piece of code **without owning a server**. AWS starts a container, runs your function, and shuts it down. You pay only for the milliseconds you use.

### When Lambda is a great fit

- The flow is **event-driven**: "when a file lands in S3, do something."
- Each unit of work finishes quickly.
- Volume is bursty — quiet all day, then 10,000 files at once.

### The hard limits you must check first

| Limit | Value | What to do if you exceed it |
|---|---|---|
| Max run time | **15 minutes** per invocation | Split the work: one Lambda per file, or use AWS Batch / ECS / Step Functions |
| Memory | 128 MB – 10,240 MB | More memory also gives you more CPU — often *cheaper* to raise it |
| Temp disk (`/tmp`) | 512 MB by default, configurable to 10 GB | Stream to/from S3 instead of writing to disk |
| Deployment package | 250 MB unzipped (zip), 10 GB (container image) | Use a container image or a Lambda layer |
| Concurrency | 1,000 per region by default | Set **reserved concurrency** so you don't melt your database |

> **The 15-minute rule is the deal-breaker.** If one item of work can take longer than 15 minutes, Lambda is the wrong tool. Restructure so each invocation handles one file, not the whole batch.

### Step-by-step: the Lambda version

**Step 1 — Change the trigger from "poll" to "push."**

NiFi polls: "any new files? any new files?" Lambda listens: S3 tells it the moment a file appears. This is usually a *better* design.

```
Vendor uploads to S3  →  S3 Event Notification  →  Lambda  →  transform  →  S3 output + audit
                                                      ↓ on failure
                                                   SQS Dead Letter Queue  →  alarm
```

If the source really is SFTP, use **AWS Transfer Family** to put an SFTP front door on an S3 bucket. Then the vendor still uses SFTP, but you get S3 events for free.

**Step 2 — Write the handler.**

```python
# lambda_function.py - replaces the NiFi flow, one file per invocation
import csv, gzip, io, json, os, urllib.parse
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
OUT_BUCKET = os.environ["OUT_BUCKET"]
OUT_PREFIX = os.environ.get("OUT_PREFIX", "vendor/daily")
QUARANTINE_PREFIX = os.environ.get("QUARANTINE_PREFIX", "quarantine")
EXPECTED = ("order_id", "customer", "amount", "order_date")


class ValidationError(Exception):
    pass


def transform(body: str) -> tuple[bytes, int]:
    """BOX 3+4: validate and convert CSV -> gzipped NDJSON."""
    reader = csv.DictReader(io.StringIO(body))
    if tuple(reader.fieldnames or ()) != EXPECTED:
        raise ValidationError(f"bad header: {reader.fieldnames}")

    buf = io.BytesIO()
    n = 0
    with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
        for i, row in enumerate(reader, start=2):
            try:
                row["amount"] = float(row["amount"])
            except (TypeError, ValueError):
                raise ValidationError(f"line {i}: amount not numeric")
            row["ingested_at"] = datetime.now(timezone.utc).isoformat()
            gz.write((json.dumps(row) + "\n").encode())
            n += 1
    return buf.getvalue(), n


def handler(event, context):
    results = []
    for record in event["Records"]:                       # BOX 1: TRIGGER (S3 event)
        src_bucket = record["s3"]["bucket"]["name"]
        src_key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        print(json.dumps({"msg": "start", "key": src_key, "request_id": context.aws_request_id}))

        # BOX 2: SOURCE
        body = s3.get_object(Bucket=src_bucket, Key=src_key)["Body"].read().decode("utf-8")

        try:
            payload, rows = transform(body)
        except ValidationError as exc:
            # BOX 4: ROUTE - the 'invalid' relationship
            s3.copy_object(
                Bucket=src_bucket,
                CopySource={"Bucket": src_bucket, "Key": src_key},
                Key=f"{QUARANTINE_PREFIX}/{os.path.basename(src_key)}",
                MetadataDirective="REPLACE",
                Metadata={"quarantine-reason": str(exc)[:1000]},
            )
            print(json.dumps({"msg": "quarantined", "key": src_key, "reason": str(exc)}))
            continue                                       # do NOT raise: bad data must not retry forever

        # BOX 5: SINK
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        out_key = f"{OUT_PREFIX}/dt={day}/{os.path.basename(src_key).replace('.csv', '.jsonl.gz')}"
        s3.put_object(Bucket=OUT_BUCKET, Key=out_key, Body=payload, ContentType="application/gzip")

        print(json.dumps({"msg": "done", "key": src_key, "out": out_key, "rows": rows}))
        results.append({"source": src_key, "output": out_key, "rows": rows})

    return {"processed": len(results), "results": results}
```

**Key design decisions in that code, and why:**

| Decision | Reason |
|---|---|
| Bad data → quarantine and `continue` | If you `raise`, Lambda retries the same bad file forever. Bad data is *not* a transient error. |
| Transient errors → let the exception `raise` | Lambda's automatic retry + the DLQ are your `RetryFlowFile` and dead-letter path. |
| Stream through `io.BytesIO`, never `/tmp` | Avoids the disk limit and is faster. |
| `print(json.dumps(...))` | Structured JSON logs → queryable in CloudWatch Logs Insights. This is your replacement for provenance. |
| `unquote_plus` on the key | S3 event keys are URL-encoded; forgetting this breaks any filename with a space. |

**Step 3 — Deploy it.** Here is a minimal AWS SAM template:

```yaml
# template.yaml
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31

Resources:
  VendorLoad:
    Type: AWS::Serverless::Function
    Properties:
      FunctionName: vendor-load
      Runtime: python3.13
      Handler: lambda_function.handler
      MemorySize: 1024          # more memory = more CPU = often cheaper overall
      Timeout: 300              # 5 min; hard ceiling is 900
      Architectures: [arm64]    # Graviton: ~20% cheaper than x86
      Environment:
        Variables:
          OUT_BUCKET: !Ref OutputBucket
          OUT_PREFIX: vendor/daily
      DeadLetterQueue:          # replaces your 'failure' relationship
        Type: SQS
        TargetArn: !GetAtt FailureQueue.Arn
      Policies:
        - S3ReadPolicy:  { BucketName: !Ref InputBucket }
        - S3CrudPolicy:  { BucketName: !Ref OutputBucket }
        - SQSSendMessagePolicy: { QueueName: !GetAtt FailureQueue.QueueName }
      Events:
        NewCsv:
          Type: S3
          Properties:
            Bucket: !Ref InputBucket
            Events: s3:ObjectCreated:*
            Filter:
              S3Key:
                Rules:
                  - Name: prefix, Value: incoming/
                  - Name: suffix, Value: .csv

  InputBucket:
    Type: AWS::S3::Bucket
  OutputBucket:
    Type: AWS::S3::Bucket
  FailureQueue:
    Type: AWS::SQS::Queue
    Properties:
      MessageRetentionPeriod: 1209600   # 14 days

  # Alarm = your PutEmail processor
  FailureAlarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: vendor-load-errors
      Namespace: AWS/Lambda
      MetricName: Errors
      Dimensions: [{ Name: FunctionName, Value: !Ref VendorLoad }]
      Statistic: Sum
      Period: 300
      EvaluationPeriods: 1
      Threshold: 1
      ComparisonOperator: GreaterThanOrEqualToThreshold
```

```bash
sam build && sam deploy --guided
sam logs -n VendorLoad --tail            # your new nifi-app.log
sam local invoke VendorLoad -e events/s3-put.json   # test on your laptop
```

**Step 4 — For scheduled (not event-driven) flows**, replace the S3 trigger with EventBridge Scheduler:

```yaml
      Events:
        Nightly:
          Type: ScheduleV2
          Properties:
            ScheduleExpression: "cron(0 2 * * ? *)"
            ScheduleExpressionTimezone: "America/New_York"   # handles daylight saving for you
```

**Step 5 — For multi-step flows, add Step Functions.** If your NiFi flow had branches and joins, Step Functions is the visual replacement — it even gives you a canvas and a run history that feels a bit like NiFi's provenance.

```
Step Functions state machine:
  Fetch → Validate → Choice ─(valid)→ Transform → Load → Notify
                       └────(invalid)→ Quarantine → Alert
  With built-in Retry{IntervalSeconds, BackoffRate, MaxAttempts} and Catch blocks.
```

### Watch out for these Lambda traps

- **Cold starts** — the first invocation after idle takes an extra 0.2–2 seconds. Usually fine for data jobs.
- **Retries are automatic and can double-write.** S3-triggered async invocations retry twice by default. Make your writes **idempotent** (same input → same output key), or you will get duplicates.
- **VPC access.** If the Lambda must reach a private database, put it in a VPC — then it needs a NAT Gateway to reach the internet, which costs money.
- **Concurrency vs. your database.** 1,000 Lambdas hitting a small RDS instance will kill it. Set reserved concurrency, or use RDS Proxy.
- **No shared queue.** NiFi's queues held data safely. In Lambda, if you want a buffer, you must add SQS or Kinesis explicitly.

### Lambda pros and cons

| Pros | Cons |
|---|---|
| No servers to patch, monitor, or pay for when idle | Hard 15-minute ceiling |
| Scales from 0 to thousands automatically | Vendor lock-in to AWS |
| Native retries, DLQ, metrics, and alarms | Debugging is harder — no live canvas |
| Costs pennies for small flows | VPC/networking adds complexity and cost |
| Deploys as code (SAM/CDK/Terraform) | Cold starts; per-invocation limits |
| Per-file failure isolation is automatic | Not good for continuous streaming or huge files |

---

## 12. Part 9 — Rebuild it with Ansible

**Important honesty first:** Ansible is a **configuration and orchestration** tool, not a data-streaming tool. It is designed to run a series of steps on one or more machines, on demand or on a schedule.

### Ansible is the right answer when...

- The NiFi flow was really a **batch job orchestrator**: "run this, then that, then copy files to these 12 servers."
- The work is **fan-out across many hosts** — the one thing shell and Lambda are bad at.
- The job is **occasional** (nightly, weekly) and someone kicks it off.
- You already use Ansible/AWX and want the flow visible in the same place as everything else.

### Ansible is the wrong answer when...

- Data arrives continuously.
- You need per-record handling or fast loops (Ansible loops are slow).
- The flow runs every minute (Ansible has high startup overhead).

### The playbook version

```yaml
# vendorload.yml - replaces the NiFi flow as an orchestrated batch job
- name: Vendor CSV load
  hosts: etl_workers
  gather_facts: true
  strategy: free                 # hosts run independently, don't wait for each other
  max_fail_percentage: 0         # any host failing fails the run

  vars:
    work_dir: /var/tmp/vendorload
    state_file: /var/lib/vendorload/seen.json
    quarantine: /var/lib/vendorload/quarantine
    s3_bucket: "{{ lookup('env', 'S3_BUCKET') }}"
    sftp_host: sftp.vendor.com
    run_id: "{{ ansible_date_time.iso8601_basic_short }}"

  pre_tasks:
    # BOX 6 GUARDRAIL: make sure the environment is sane before touching data
    - name: Ensure directories exist
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        mode: "0750"
        owner: etl
      loop: [ "{{ work_dir }}", "{{ quarantine }}", "{{ state_file | dirname }}" ]

    - name: Ensure required tools are installed
      ansible.builtin.package:
        name: [python3, awscli, rsync]
        state: present
      become: true

    - name: Check there is enough free disk
      ansible.builtin.assert:
        that: >-
          (ansible_mounts | selectattr('mount','equalto','/var') | first).size_available > 5368709120
        fail_msg: "Less than 5 GB free on /var - refusing to run"

  tasks:
    # BOX 2: SOURCE
    - name: Fetch new vendor files
      ansible.builtin.command:
        cmd: >-
          sftp -q -o BatchMode=yes -i /etc/etl/vendor_key
          {{ sftp_host }}:/outbound/*.csv {{ work_dir }}/
      register: fetch
      changed_when: fetch.rc == 0
      retries: 3                       # BOX 6: retry, like RetryFlowFile
      delay: 30
      until: fetch.rc == 0

    - name: List downloaded files
      ansible.builtin.find:
        paths: "{{ work_dir }}"
        patterns: "*.csv"
      register: found

    # BOX 3+4: TRANSFORM and ROUTE - reuse the Python script you already wrote!
    - name: Validate and convert each file
      ansible.builtin.command:
        cmd: "/opt/etl/vendorload.py --one-file {{ item.path }}"
      loop: "{{ found.files }}"
      loop_control:
        label: "{{ item.path | basename }}"
      register: convert
      failed_when: convert.rc not in [0, 3]     # rc=3 means "quarantined", which is expected
      changed_when: convert.rc == 0

    # BOX 5: SINK
    - name: Upload results to S3
      amazon.aws.s3_object:
        bucket: "{{ s3_bucket }}"
        object: "vendor/daily/dt={{ ansible_date_time.date }}/{{ item | basename }}"
        src: "{{ item }}"
        mode: put
      loop: "{{ (found.files | map(attribute='path') | list) | map('regex_replace', '\\.csv$', '.jsonl.gz') | list }}"

    - name: Clean up work directory
      ansible.builtin.file:
        path: "{{ item.path }}"
        state: absent
      loop: "{{ found.files }}"

  handlers:
    - name: Alert on-call
      community.general.slack:
        token: "{{ slack_token }}"
        msg: "vendorload run {{ run_id }} failed on {{ inventory_hostname }}"

  post_tasks:
    - name: Report
      ansible.builtin.debug:
        msg: "run={{ run_id }} host={{ inventory_hostname }} files={{ found.files | length }}"
```

### Where Ansible really shines: fan-out

This is the thing NiFi, shell, and Lambda all handle awkwardly and Ansible does in three lines — pushing the same result to 50 machines at once:

```yaml
- name: Distribute the processed file to all app servers
  hosts: app_servers
  tasks:
    - name: Copy reference data
      ansible.builtin.copy:
        src: /shared/output/reference.json
        dest: /opt/app/data/reference.json
        mode: "0644"
      notify: Reload app

  handlers:
    - name: Reload app
      ansible.builtin.systemd_service:
        name: myapp
        state: reloaded
```

### Triggering Ansible

| Method | Command | Best for |
|---|---|---|
| Cron | `0 2 * * * ansible-playbook /opt/etl/vendorload.yml` | Simple, no extra tools |
| AWX / Ansible Automation Platform | Schedule in the web UI | Teams — gives you a UI, run history, RBAC, and logs (the closest thing to NiFi's UI) |
| CI pipeline | GitLab CI / GitHub Actions scheduled job | Teams already living in Git |
| Event-driven Ansible | Rulebooks reacting to webhooks/Kafka | Turning events into playbook runs |

### Testing your playbook

```bash
ansible-playbook vendorload.yml --syntax-check
ansible-lint vendorload.yml
ansible-playbook vendorload.yml --check --diff      # dry run: shows what would change
ansible-playbook vendorload.yml --limit etl01 -vv   # one host, verbose
```

### Ansible pros and cons

| Pros | Cons |
|---|---|
| Excellent at running steps across many machines | Not a data-streaming tool — no queues, no back pressure |
| Idempotent by design (safe to re-run) | Slow: high startup cost, slow loops |
| YAML is readable by ops people | YAML gets ugly for real logic (`when:`, `loop:`, Jinja everywhere) |
| Huge module library (AWS, files, databases, SSH) | Poor at per-record data handling |
| AWX gives you a UI, schedule, and audit log | Debugging Jinja templating is painful |
| Already deployed at most companies | Needs SSH access and an inventory |

**Best practice:** use Ansible as the **conductor**, and put the actual data logic in the Python script. The playbook decides *where and when*; Python decides *what*. Do not try to write data transformations in YAML.

---

## 13. Part 10 — The big translation table

Print this. It is the fastest way to convert a canvas into code.

### Sources

| NiFi processor | Shell | Python | AWS |
|---|---|---|---|
| `GetFile` / `ListFile`+`FetchFile` | `find /in -name '*.csv' -newer .last` | `pathlib.Path('/in').glob('*.csv')` | S3 event → Lambda |
| `ListSFTP` / `FetchSFTP` | `sftp`, `lftp mirror`, `rsync -e ssh` | `paramiko`, `fabric` | AWS Transfer Family → S3 |
| `InvokeHTTP` (GET) | `curl -fsSL --retry 3 url` | `requests.get(url, timeout=30)` | Lambda + `urllib3` |
| `ListenHTTP` / `HandleHttpRequest` | `nc -l`, a tiny `python -m http.server` | FastAPI / Flask | API Gateway → Lambda |
| `ConsumeKafka` | `kcat -C -b broker -t topic` | `confluent_kafka.Consumer` | MSK → Lambda event source mapping |
| `ExecuteSQL` / `QueryDatabaseTable` | `psql -c "COPY (...) TO STDOUT CSV"` | `psycopg`, `sqlalchemy`, `pandas.read_sql` | Lambda + RDS Proxy, or Glue |
| `FetchS3Object` / `ListS3` | `aws s3 cp` / `aws s3 ls` | `boto3.client('s3').get_object` | native |
| `GenerateFlowFile` (heartbeat) | `while true; do ...; sleep 60; done` | `while True: ... time.sleep(60)` | EventBridge Scheduler |
| `TailFile` | `tail -F /var/log/app.log` | `subprocess` + `tail -F`, or `watchdog` | CloudWatch Agent |
| `GetSQS` | `aws sqs receive-message` | `boto3` SQS | SQS event source → Lambda |

### Transforms

| NiFi processor | Shell | Python |
|---|---|---|
| `ConvertRecord` (CSV↔JSON↔Avro↔Parquet) | `mlr --icsv --ojson cat`, `duckdb -c "COPY ... TO ..."` | `csv`+`json`, `pandas`, `pyarrow`, `duckdb` |
| `JoltTransformJSON` / `JoltTransformRecord` | `jq '{id:.a, name:.b}'` | dict comprehension, or the `jolt` idea done in code |
| `UpdateAttribute` | shell variables | a dict of metadata |
| `ReplaceText` | `sed 's/old/new/g'`, `awk` | `re.sub`, `str.replace` |
| `SplitText` | `split -l 10000 file part_` | read in chunks / `itertools.islice` |
| `SplitRecord` | `csvsplit`, `awk` | chunked generator |
| `MergeContent` / `MergeRecord` | `cat part_* > all`, `paste` | write to one open file handle |
| `CompressContent` | `gzip -c`, `zstd -19` | `gzip`, `zstandard` |
| `EncryptContent` | `gpg -c`, `openssl enc` | `cryptography` |
| `CalculateRecordStats` | `awk '{s+=$3} END{print s}'` | `sum(...)`, `pandas.describe()` |
| `HashContent` | `sha256sum` | `hashlib.sha256` |
| `EvaluateJsonPath` | `jq -r '.field'` | `data["field"]`, `jsonpath-ng` |
| `ExtractText` | `grep -oP`, `sed -n` | `re.search` |
| `QueryRecord` (SQL over a flowfile) | `duckdb -c "SELECT ... FROM 'f.csv'"` | `duckdb.sql(...)`, `pandas.query` |

### Routing and control

| NiFi processor | Shell | Python |
|---|---|---|
| `RouteOnAttribute` | `if [[ "$x" == y ]]; then ... fi` | `if/elif/else` |
| `RouteOnContent` | `grep -q pattern && ...` | `if pattern in text:` |
| `ValidateRecord` / `ValidateJson` | `jq -e 'has("id")'`, `csvclean` | `pydantic`, `jsonschema`, `cerberus` |
| `RouteText` | `awk '/pat/{print > "a"} !/pat/{print > "b"}'` | write to two file handles |
| `DistributeLoad` | `xargs -P4`, GNU `parallel` | `concurrent.futures.ThreadPoolExecutor` |
| `ControlRate` | `sleep` between items, `pv -L 1m` | token bucket, `time.sleep` |
| `Wait` / `Notify` | lock files, `flock` | `threading.Event`, a state table |

### Sinks

| NiFi processor | Shell | Python | AWS |
|---|---|---|---|
| `PutFile` | `mv`/`cp` (write to `.tmp` then `mv`!) | `Path.write_bytes` + atomic `replace()` | EFS |
| `PutS3Object` | `aws s3 cp` | `boto3 upload_file` | native |
| `PutSQL` / `PutDatabaseRecord` | `psql -c`, `\copy` | `psycopg.executemany`, `COPY` | RDS / Redshift |
| `PutSFTP` | `sftp`, `rsync` | `paramiko.put` | Transfer Family |
| `PublishKafka` | `kcat -P` | `confluent_kafka.Producer` | MSK |
| `PutEmail` | `mail -s`, `sendmail` | `smtplib`, `boto3 ses` | SES / SNS |
| `PutElasticsearch*` | `curl -XPOST .../_bulk` | `elasticsearch-py` | OpenSearch |

### Guardrails (never skip these in the rewrite)

| NiFi feature | Shell | Python | AWS |
|---|---|---|---|
| Back pressure | `flock`, bounded `xargs -P`, `sleep` | bounded `Queue(maxsize=N)`, semaphore | SQS + reserved concurrency |
| `RetryFlowFile` | `until cmd; do sleep $((d*=2)); done` | `tenacity`, hand-rolled `retry()` | Lambda retries, Step Functions `Retry` |
| Processor state | a state file (`seen.txt`) | JSON/SQLite state, atomic replace | DynamoDB table, or S3 object tags |
| `failure` relationship | `|| { log; mv "$f" dead/; }` | `except:` → quarantine dir | SQS Dead Letter Queue |
| Provenance | `logger`, structured log lines | JSON logging | CloudWatch Logs + X-Ray |
| Bulletins/alerts | `mail`, `curl` to Slack webhook | `logging` + SNS | CloudWatch Alarms → SNS |
| Guaranteed delivery | write-then-`mv` (atomic rename) | atomic `Path.replace()` | S3 is durable; use SQS for buffering |
| Primary-node-only | `flock -n` | `fcntl.flock` | Lambda reserved concurrency = 1 |
| Cluster load balancing | GNU `parallel --sshloginfile` | multiprocessing / Celery | Lambda concurrency, ECS tasks |

---

## 14. Part 11 — What you lose when you leave NiFi

Be honest about this list before you migrate. Each row is real work.

| What NiFi gave you free | What it actually did | Cost to rebuild |
|---|---|---|
| **Provenance** | Full lineage for every record: where it came from, every change, where it went | Medium–High. Structured logs + a run table get you 70%. Full lineage needs OpenLineage / Marquez / DataHub. |
| **Back pressure** | Automatically slowed the producer when the consumer fell behind | Medium. Use SQS, bounded queues, or concurrency limits. |
| **Guaranteed delivery** | Data survived a reboot, mid-flight | Medium. Write to durable storage (S3/SQS) between steps, never memory. |
| **The live canvas** | Non-engineers could *see* the flow working | High to replace. Best answers: a Grafana dashboard, Step Functions' visual graph, or an Airflow/Dagster UI. |
| **Drag-and-drop editing** | Ops staff could change a path without a deploy | Replace with config files + a fast CI pipeline. Honestly, most teams see this as an upgrade. |
| **300+ connectors** | S3, Kafka, JDBC, SFTP, Azure, GCP already written and tested | Low–Medium. Python libraries cover almost everything, but you own the error handling. |
| **Clustering** | Add a node, get more throughput | Medium. Lambda gives this free; on servers you need your own sharding. |
| **Fine-grained security** | Per-processor permissions and audit log | Medium. IAM roles + Git history + CI approvals. |

### The honest verdict

**Keep NiFi if:** you have continuous streaming, many connector types, real audit/compliance requirements for lineage, or non-engineers who maintain flows.

**Leave NiFi if:** your flows are scheduled batch jobs, your volumes are modest, your team is engineers who prefer Git, or you are paying for a cluster that idles 23 hours a day.

**The most common real outcome:** teams keep NiFi for 3–5 genuinely streaming flows and move the other 40 nightly batch jobs to Lambda or scripts. That is usually the right answer.

---

## 15. Part 12 — Safe migration plan

Never do a big-bang switch. Follow these nine steps.

1. **Inventory.** Export every flow definition to JSON, run the `jq` commands from Part 3, and build one spreadsheet of every flow, its volume, and its owner.
2. **Score.** Use the scoring table in Part 4. Sort by score, highest first.
3. **Pick the easiest flow first.** You want an early, boring win — not the scariest flow.
4. **Decompose** it with the 6-box worksheet. Get the owner to confirm your plain-English description is right. **This is where you catch the surprises.**
5. **Write the replacement** with tests. Add logging on day one, not later.
6. **Run in parallel (shadow mode).** For 1–2 weeks, run both. Write the new output to a *different* location.
7. **Diff the outputs, automatically:**
   ```bash
   # compare NiFi output vs new output, ignoring timestamps
   diff <(jq -S 'del(.ingested_at)' nifi_out/*.json | sort) \
        <(jq -S 'del(.ingested_at)' new_out/*.json  | sort) && echo "IDENTICAL ✅"

   # or compare checksums of everything
   diff <(cd nifi_out && find . -type f -exec sha256sum {} \; | sort -k2) \
        <(cd new_out  && find . -type f -exec sha256sum {} \; | sort -k2)
   ```
8. **Cut over, but leave NiFi ready.** Stop the NiFi processors (don't delete them) and point consumers at the new output. Keep the flow definition JSON in Git.
9. **Decommission after 30 clean days.** Delete the process group, and only then shrink the cluster.

### Rollback plan (write this before you cut over)

| If this happens | Do this |
|---|---|
| New job produces wrong data | Restart the NiFi process group; it still has state, it will resume |
| New job is too slow | Keep both running; NiFi handles backlog while you optimize |
| Data was missed during the gap | Clear the state file / reset the processor state and re-run for that date range |

**Make sure you can answer "how do I re-run yesterday?" before you go live.** Add a `--since YYYY-MM-DD` flag to your script. You will use it.

---

## 16. Pros and cons of every option

### Side-by-side comparison

| | **NiFi** | **Shell** | **Python** | **Lambda** | **Ansible** |
|---|---|---|---|---|---|
| Setup effort | High | None | Low | Medium | Low |
| Cost at low volume | High ($$$ idle server) | ~Free | ~Free | Pennies | ~Free |
| Cost at high volume | Good | N/A | Good | Can get expensive | Poor |
| Visual UI | ⭐ Excellent | None | None | Partial (Step Functions) | AWX gives one |
| Unit testing | Very hard | Hard | ⭐ Easy | Easy | Medium |
| Code review / Git diff | Painful (JSON blob) | ⭐ Easy | ⭐ Easy | ⭐ Easy | Easy |
| Error handling | ⭐ Built in | Manual | Manual (good libs) | ⭐ Built in (DLQ, retries) | Built in (`retries:`) |
| Data lineage / audit | ⭐ Best in class | Logs only | Logs only | CloudWatch/X-Ray | Logs only |
| Back pressure | ⭐ Built in | Manual | Manual | Via SQS | None |
| Streaming/continuous | ⭐ Excellent | Poor | OK | OK (Kinesis/SQS) | ✗ No |
| Scheduled batch | Good | ⭐ Excellent | ⭐ Excellent | ⭐ Excellent | ⭐ Excellent |
| Long jobs (> 15 min) | ✅ | ✅ | ✅ | ❌ hard limit | ✅ |
| Fan-out to many servers | OK | Poor | Medium | N/A | ⭐ Excellent |
| Non-engineers can maintain | ⭐ Yes | No | No | No | Somewhat |
| Vendor lock-in | None | None | None | ⭐ AWS only | None |
| Big-file handling | ⭐ Excellent | ⭐ Excellent | Good | Poor (limits) | Poor |

### Quick decision tree

```
Is data continuous/streaming (Kafka, constant firehose)?
├── YES ──▶ Keep NiFi (or move to Flink / Kafka Connect)
└── NO
    │
    Does one unit of work take more than 15 minutes?
    ├── YES ──▶ Python on a server (cron/systemd) or AWS Batch / ECS / Step Functions
    └── NO
        │
        Is the trigger an event (file lands, message arrives)?
        ├── YES ──▶ AWS Lambda
        └── NO (it's a schedule)
            │
            Does it need to run across many servers?
            ├── YES ──▶ Ansible (calling a Python script)
            └── NO
                │
                Is there any real logic, parsing, or API calls?
                ├── YES ──▶ Python + systemd timer
                └── NO  ──▶ Shell script + cron
```

---

## 17. Best practices checklist

### If you keep NiFi

- ✅ Run **NiFi 2.11.0** on **Java 21**. Upgrade off 1.x — it is unsupported.
- ✅ Put the three repositories on **separate disks**. Biggest single performance win.
- ✅ Use **Parameter Contexts** for all config; mark passwords **sensitive**. Never type a secret into a property.
- ✅ Version flows with a **Git-based Flow Registry Client** (NiFi Registry is deprecated and will be removed in 3.0).
- ✅ **Never auto-terminate `failure`.** Route it to a dead-letter `PutFile` or an alert.
- ✅ Prefer **record-based processors** (`ConvertRecord`, `QueryRecord`, `PutDatabaseRecord`) over split/merge. They are faster and use far less memory.
- ✅ Name every processor for what it *does* ("Fetch vendor CSV"), not its class name.
- ✅ Set `Run Schedule` to something sane. `0 sec` on a source burns CPU.
- ✅ Keep heap at 4–8 GB. Bigger heaps cause long garbage-collection pauses that disconnect cluster nodes.
- ✅ Set provenance retention to something you actually need (e.g. 24–72 hours), not forever.
- ✅ Back up `conf/flow.json.gz` before every change.
- ✅ Use a **Process Group per business flow**, and label the group with the owner's name.

### If you replace NiFi

- ✅ Write the **6-box decomposition worksheet first**. No code until it is signed off.
- ✅ Make everything **idempotent**: re-running must be safe.
- ✅ **Record state only after full success.** This is the single most common migration bug.
- ✅ Distinguish **bad data** (quarantine, don't retry) from **transient failure** (retry with backoff).
- ✅ Log in **structured JSON** with a run ID on every line. This is your provenance replacement.
- ✅ Write files **atomically**: write to `name.tmp`, then rename. A rename is atomic; a half-written file is not.
- ✅ Add a **`--since` / `--reprocess` flag** on day one.
- ✅ Alert on **"the job didn't run"**, not just "the job failed." Silence is the scariest failure.
- ✅ Put config in **environment variables or a config file**, never hardcoded.
- ✅ Add a **lock** so two copies can't run at once.
- ✅ **Shadow-run and diff** before cutting over.
- ✅ Keep the old NiFi flow definition in Git, even after you delete it from the canvas.

### Anti-patterns to avoid

- ❌ Rewriting a streaming flow as a cron job "because cron is simpler." It isn't, at 3 a.m.
- ❌ Putting data transformation logic in Ansible YAML.
- ❌ Using `ExecuteStreamCommand` in NiFi to run a shell script — you now have *both* systems' problems. If you're doing this, just move the whole flow out.
- ❌ Migrating your hardest flow first.
- ❌ Deleting NiFi flows before 30 clean days on the new system.
- ❌ Forgetting the failure paths because "they never fire." They fire.

---

## 18. Cheat sheet

### NiFi operations

```bash
# lifecycle
./bin/nifi.sh start | stop | restart | status
./bin/nifi.sh diagnostics /tmp/diag.txt
./bin/nifi.sh set-single-user-credentials admin myLongPassword123

# logs
tail -f logs/nifi-app.log
grep -E "ERROR|WARN" logs/nifi-app.log | tail -50
tail -f logs/nifi-user.log        # who did what

# docker
docker run --name nifi -p 8443:8443 \
  -e SINGLE_USER_CREDENTIALS_USERNAME=admin \
  -e SINGLE_USER_CREDENTIALS_PASSWORD=changeThisPassword123 \
  -d apache/nifi:2.11.0
docker logs -f nifi
docker exec -it nifi bash

# disk check (the #1 outage cause)
du -sh content_repository provenance_repository flowfile_repository
df -h
```

### Flow review one-liners

```bash
# processors + schedules
jq -r '.. | objects | select(.componentType?=="PROCESSOR")
  | "\(.name)\t\(.type|split(".")|last)\t\(.schedulingPeriod)"' flow.json | column -t

# connections
jq -r '.. | objects | select(.componentType?=="CONNECTION")
  | "\(.source.name) -[\(.selectedRelationships|join(","))]-> \(.destination.name)"' flow.json

# silent data loss
jq -r '.. | objects | select(.componentType?=="PROCESSOR")
  | select(.autoTerminatedRelationships?|index("failure")) | "DROPS FAILURES: \(.name)"' flow.json

# every external endpoint
jq -r '.. | objects | select(.componentType?=="PROCESSOR") | .properties|to_entries[].value
  | strings | select(test("https?://|s3://|jdbc:|sftp://"))' flow.json | sort -u
```

### The six boxes (memorize this)

```
TRIGGER → SOURCE → TRANSFORM → ROUTE → SINK
                       ↑
                   GUARDRAILS (retry, state, dedupe, alert, log)
```

### Safe-script header (copy this every time)

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$1" "${*:2}" >&2; }
trap 'log ERROR "failed at line $LINENO"' ERR
exec 9>/var/lock/myjob.lock; flock -n 9 || exit 0
```

### Useful links

- Download & release notes — https://nifi.apache.org/download/
- NiFi 2 component docs — https://nifi.apache.org/components/
- Python Developer's Guide — https://nifi.apache.org/nifi-docs/python-developer-guide.html
- Migration guidance (1.x → 2.x) — https://cwiki.apache.org/confluence/display/NIFI/Migration+Guidance
- Release notes — https://cwiki.apache.org/confluence/display/NIFI/Release+Notes

---

## Final word

The most important idea in this whole guide is the **6-box decomposition**. NiFi, shell, Python, Lambda, and Ansible are all just different clothing on the same six boxes: *trigger, source, transform, route, sink, guardrails.*

Once you can look at a canvas and say out loud, in six plain sentences, what it does — the tool you use to rebuild it stops being scary. It is just a choice.
