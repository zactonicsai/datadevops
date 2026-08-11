# The Friendly Guide: NiFi Deep Dive
## S3 Processors, HTTP POST Processors, and Proving What Passed Through

**Who this is for:** Support engineers who build and troubleshoot NiFi flows that read/write **AWS S3**, **POST data to HTTP APIs**, and need to **produce a record (logs/exports) of every file that passed through**.

**How this guide works:** Same as the main training guide — every topic answers **WHAT** it is, **WHY** it matters, and **HOW** to do it, in plain language with real property values you can copy.

**Version note:** Written for **NiFi 2.x**. Where 1.x differs (you'll meet 1.x during migrations), it's called out. Biggest one up front: the old `PostHTTP` and `GetHTTP` processors are **gone in 2.x** — `InvokeHTTP` does everything now.

---

## Table of Contents

1. [Part 1 — Background: How NiFi Processors Actually Work](#part-1--background)
2. [Part 2 — The AWS S3 Processors](#part-2--the-aws-s3-processors)
3. [Part 3 — HTTP POST with InvokeHTTP (and receiving POSTs)](#part-3--http-post-processors)
4. [Part 4 — Logging & Tracking: The Record of Every File](#part-4--logging--tracking)
5. [Part 5 — Worked Example: S3 → HTTP POST with a Full Audit Trail](#part-5--worked-example)
6. [Quick-Reference Tables (mini cheat sheet)](#quick-reference-tables)

---

# Part 1 — Background
### How NiFi processors actually work (5-minute recap)

## 1.1 The FlowFile — a package with a shipping label

Everything moving through NiFi is a **FlowFile**, and it has exactly two parts:

- **Content** — the actual bytes (the file, the JSON, the CSV). *The stuff inside the box.*
- **Attributes** — key/value sticky notes on the outside (`filename`, `s3.bucket`, `mime.type`, plus anything you add). *The shipping label.*

**WHY you must burn this in:** S3 processors read the *label* to decide what to fetch/put (`${filename}` = which object key), and HTTP processors send the *contents* as the POST body and can send *labels* as headers. Almost every configuration question is really "content or attribute?"

## 1.2 Expression Language — mail-merge for properties

Anywhere you see `${...}` in a property, NiFi fills in a value at runtime:

```
${filename}                          → the FlowFile's filename attribute
${s3.bucket}                         → whatever bucket it came from
${now():format('yyyy/MM/dd')}        → today's date, e.g. 2026/07/02
incoming/${filename:substringAfter('raw/')}   → string surgery on attributes
```

**WHY:** it's how one processor handles a million different files — the property is a *template*, the attributes fill in the blanks.

## 1.3 Relationships — the exits of each box

Every processor has named exits: usually **success** and **failure**, and some have more (InvokeHTTP has five!). Every exit must be either **connected** to a next step or **auto-terminated** (checked in Settings = "throw these away").

**WHY it matters for support:** an unrouted failure isn't silent — the processor turns invalid (yellow ⚠). And a *terminated* failure IS silent — files vanish with no record. Rule of the house: **failure relationships are never auto-terminated on S3/HTTP processors.** They go to a dead-letter branch (Part 5).

## 1.4 Scheduling, tasks, and back-pressure

- **Run Schedule** (`0 sec` = as fast as possible, or timer/cron) and **Concurrent Tasks** (parallel workers) live in each processor's Scheduling tab.
- **Primary Node Only:** on a cluster, some processors (all the `List*` ones) must run on exactly one node or every node would list the same files. Set Execution = *Primary node*.
- **Back-pressure:** each connection (pipe) has a max (default 10,000 FlowFiles / 1 GB). When full, the upstream processor pauses. A red-ringed, fat queue on the canvas = "downstream is slow" — your #1 visual diagnostic.

## 1.5 Controller Services — shared toolboxes

Some settings are shared by many processors (AWS credentials, SSL certificates, record readers). Those live as **Controller Services** (canvas gear icon → Controller Services), created once, referenced by name. Both our S3 and HTTP work depends on two of them, coming right up.

---

# Part 2 — The AWS S3 Processors

## 2.1 S3 in one paragraph

**WHAT:** S3 is AWS's infinite filing cabinet. A **bucket** is a cabinet (globally unique name), and every file inside is an **object** identified by its **key** — the full "path" like `raw/2026/07/02/orders-0001.json`. There are no real folders; the `/`s in keys just *look* like folders. A **prefix** is "every key starting with these characters" — that's how you point NiFi at a "folder."

## 2.2 First, credentials — the ONE right way on EKS/EC2

**WHAT:** Every S3 processor has a property **AWS Credentials Provider Service** pointing at one shared controller service: **`AWSCredentialsProviderControllerService`**.

**HOW to configure it (and WHY this way):**

| Property | Value | Why |
|---|---|---|
| **Use Default Credentials** | `true` | ✅ Makes NiFi use the identity of *where it's running*: the **Pod Identity/IRSA role** on EKS, the **instance profile** on EC2. Zero keys typed anywhere. |
| Access Key / Secret Key | *(empty)* | 🚫 Typing keys here = keys in the flow = keys in Registry/Git = a leak waiting to happen. |
| Assume Role ARN / Session Name | *(optional)* | Only for cross-account: NiFi's own role hops into another account's role. |

So the permission question is never "what's in NiFi" — it's "**what can NiFi's IAM role do?**" (See the IAM table in 2.8.)

> **Support reflex:** any S3 processor throwing `403 AccessDenied` → check the **pod's IAM role policy** first, then the **bucket policy**, then KMS key policy if the bucket is encrypted. It's almost never the processor config.

## 2.3 The reading pattern: `ListS3` → `FetchS3Object`

Reading from S3 is deliberately **two** processors, like a librarian and a courier:

```
ListS3 (librarian: "here are the NEW catalog cards")
   │  emits one tiny FlowFile per object — attributes only, NO content
   ▼
FetchS3Object (courier: "go get the actual book for this card")
   │  downloads the bytes into the FlowFile's content
   ▼
 ...your processing...
```

**WHY split?** The librarian is cheap and runs on one node; the couriers are heavy and can run **in parallel across the whole cluster** (load-balanced connection between them). One processor doing both couldn't scale that way.

### `ListS3` — the librarian with a memory

| Property | Typical value | Notes |
|---|---|---|
| Bucket | `dp-raw-prod` | Or `${...}` if driven by attributes |
| Region | `us-east-1` | |
| AWS Credentials Provider Service | the service from 2.2 | |
| Prefix | `incoming/orders/` | Only list this "folder" |
| **Listing Strategy** | `Tracking Timestamps` | How it remembers what it already listed |
| Minimum Object Age | `30 sec` | ⭐ Skip objects still being uploaded (half-written file protection) |
| **Scheduling → Execution** | `Primary node` | ⭐ Cluster rule for all List processors |
| Run Schedule | `1 min` | Listing is an API call — don't hammer it at 0 sec |

**The memory (state):** ListS3 stores "the newest thing I've seen" so it only emits **new** objects each run. On NiFi 2.x on EKS, this state lives in a **Kubernetes ConfigMap**; on 1.x it lived in ZooKeeper. Right-click → **View state** to see it; **Clear state** makes it re-list *everything* (useful for reprocessing, dangerous by accident!).

**Attributes it writes** (the catalog card): `filename` (= the object key), `s3.bucket`, `s3.lastModified`, `s3.length`, `s3.etag`, `s3.storeClass`, and more.

### `FetchS3Object` — the courier

| Property | Typical value | Notes |
|---|---|---|
| Bucket | `${s3.bucket}` | Reads the sticky note ListS3 wrote |
| Object Key | `${filename}` | Ditto — this default pairing is why List→Fetch "just works" |
| Region / Credentials | same as above | |

Output: FlowFile now has **content** = the object's bytes, plus more `s3.*` attributes. Route `failure` to your dead-letter branch (object deleted between list and fetch? permissions? throttling?).

> **Cluster tip:** make the ListS3→FetchS3Object connection **load-balanced** (connection → Settings → Load Balance Strategy = Round robin) so all nodes share the download work.

## 2.4 Writing: `PutS3Object`

**WHAT:** Uploads each FlowFile's **content** as one S3 object. Big files are handled automatically via **multipart upload** (splits into chunks, uploads in parallel, reassembles).

| Property | Typical value | Notes |
|---|---|---|
| Bucket | `dp-processed-prod` | |
| **Object Key** | `processed/${now():format('yyyy/MM/dd')}/${filename}` | ⭐ Expression Language = date-partitioned layout, self-organizing |
| Region / Credentials | as usual | |
| Content Type | `${mime.type}` | So S3/browsers know what it is |
| Multipart Threshold / Part Size | `5 GB` / `100 MB` (example) | Above threshold → multipart kicks in |
| Server Side Encryption | `aws:kms` (+ key) or bucket default | Match your security standard |
| Storage Class | `STANDARD` (or `INTELLIGENT_TIERING`) | Cost lever |

**Attributes written on success:** `s3.bucket`, `s3.key`, `s3.version` (if versioned bucket), `s3.etag` — your **receipt**. Part 4 shows how to export these receipts as the audit trail.

### ⭐ The small-files trap (the #1 S3 design mistake)

Kafka-to-S3 flows tempt you to write **one object per message** → millions of 1 KB files → S3 PUT costs explode and every downstream reader (Athena, Spark) crawls.

**The fix — always merge first:**

```
ConsumeKafka → MergeRecord (or MergeContent) → UpdateAttribute → PutS3Object
                 │
                 ├─ Minimum Number of Records: 10,000
                 ├─ Max Bin Age: 5 min          ← "ship what you have" timer
                 └─ result: ~100 MB objects, the sweet spot
```

`Max Bin Age` is the safety valve: even on a quiet day, data leaves within 5 minutes.

## 2.5 The rest of the S3 family

| Processor | Job | Notes |
|---|---|---|
| `DeleteS3Object` | Delete `${filename}` from a bucket | Classic "fetch → process → put elsewhere → **delete original**" cleanup. Put it *after* a confirmed success only! |
| `TagS3Object` | Add/replace tags on an object | e.g. tag `processed=true` instead of deleting — lets lifecycle rules do the cleanup |
| `GetS3ObjectMetadata` | Read size/headers/tags **without** downloading | Cheap existence/size checks |
| `CopyS3Object` | Server-side copy bucket→bucket | No bytes travel through NiFi — fast |

## 2.6 Networking note (ties to the main guide)

On EKS in private subnets, S3 traffic should ride a **VPC Gateway Endpoint for S3** (free, keeps traffic off the NAT gateway = faster **and** cheaper). If security uses a special S3 hostname, set the processor's **Endpoint Override URL**. No endpoint + no NAT = the mysterious *"Unable to execute HTTP request: connect timed out"* error.

## 2.7 Retry & failure wiring (the standard S3 pattern)

Modern NiFi has **per-relationship retry built into every processor**: open the processor → Relationships tab → on `failure` tick **Retry**, set *Number of Retry Attempts* = `3`, backoff policy = penalize. Transient S3 blips (throttling, timeouts) self-heal; only *real* failures exit the `failure` relationship — which goes to your dead-letter branch, never to a black hole.

## 2.8 IAM cheat-table — what each processor needs

| Processor | IAM actions on the role | On resource |
|---|---|---|
| `ListS3` | `s3:ListBucket` | `arn:aws:s3:::bucket` *(the bucket itself!)* |
| `FetchS3Object` / `GetS3ObjectMetadata` | `s3:GetObject` (+ `s3:GetObjectVersion` if versioned) | `arn:aws:s3:::bucket/*` |
| `PutS3Object` | `s3:PutObject`, `s3:AbortMultipartUpload` | `bucket/*` |
| `DeleteS3Object` | `s3:DeleteObject` | `bucket/*` |
| `TagS3Object` | `s3:PutObjectTagging` | `bucket/*` |
| Any, if bucket uses SSE-KMS | `kms:Decrypt` (read) / `kms:GenerateDataKey` (write) | the KMS key |

> Note the classic gotcha in row 1: **ListBucket is a *bucket*-level permission, Get/Put are *object*-level (`/*`)**. Mixing them up = 403s that "make no sense."

---

# Part 3 — HTTP POST Processors
### Sending data OUT with `InvokeHTTP` (and a note on receiving)

## 3.1 Meet `InvokeHTTP` — the universal web courier

**WHAT:** `InvokeHTTP` makes any HTTP call — GET, **POST**, PUT, PATCH, DELETE. For POST, it takes the FlowFile's **content** and delivers it as the request **body** to a URL, then tells you exactly how it went.

**WHY it replaced everything:** old NiFi had `PostHTTP`/`GetHTTP` (one-trick processors, removed in 2.x). `InvokeHTTP` is one courier who handles all methods, headers, auth styles, and gives you fine-grained exits for smart error handling.

## 3.2 Core configuration for a POST

| Property | Typical value | Notes |
|---|---|---|
| **HTTP Method** | `POST` | |
| **HTTP URL** | `https://api.partner.com/v1/orders` | Can use EL: `https://api.partner.com/v1/${endpoint}` *(1.x called this "Remote URL")* |
| Send Message Body | `true` | FlowFile **content** becomes the POST body |
| Request Content-Type | `${mime.type}` | Make sure upstream set it (e.g. `application/json`) — APIs reject bodies with missing/wrong type |
| Connection / Response Timeout | `5 sec` / `30 sec` | Don't leave infinite — hung calls clog threads |
| SSL Context Service | `StandardSSLContextService` | Needed for private CAs / mTLS; public HTTPS with well-known CAs works without |
| Request Username / Password | *(for Basic auth)* | Sensitive props — stored encrypted |
| Request OAuth2 Access Token Provider | `StandardOauth2AccessTokenProvider` service | ⭐ The clean way to do Bearer tokens — service fetches & auto-refreshes the token |

**Custom headers = dynamic properties.** Hit **+** on the Properties tab and every property you add becomes a request header:

```
+  X-Api-Key        →  ${api.key}          (attribute set from a Parameter/secret)
+  X-Correlation-Id →  ${uuid}             (FlowFile's own UUID — gold for tracing!)
+  X-Source-Bucket  →  ${s3.bucket}
```

> **Secrets rule (same as always):** the API key value lives in a **Parameter Context** marked *sensitive*, sourced from AWS Secrets Manager — never typed into the canvas, never a plain attribute in Git.

## 3.3 The five exits — where request + response go

This is the part everyone fumbles. InvokeHTTP has **five relationships**:

| Relationship | What lands here | Wire it to |
|---|---|---|
| **Original** | Your outgoing FlowFile, after a **2xx** success | The audit trail (Part 5) — it's your proof of delivery |
| **Response** | A **new** FlowFile whose content = the server's response body | Parse it if you need the API's answer; else auto-terminate |
| **Retry** | Original, after a **5xx** (server's fault — try again later) | Back into InvokeHTTP (a loop) — see 3.4 |
| **No Retry** | Original, after a **4xx** (your fault — retrying won't help) | Dead-letter branch + alert. Fix the request, don't loop it |
| **Failure** | Couldn't even talk (DNS, timeout, TLS, connection refused) | Retry loop or dead-letter, depending on your SLA |

**Attributes stamped on the FlowFiles** (both original and response):

```
invokehttp.status.code      → 200, 404, 503...   ← route/alert on this
invokehttp.status.message   → "OK", "Bad Gateway"
invokehttp.request.url      → what was actually called (after EL)
invokehttp.tx.id            → NiFi's transaction id linking original ↔ response
```

**WHY the 4xx/5xx split matters:** a 5xx (server hiccup) heals with retries; a 400 (bad payload) retried forever = an infinite loop hammering the partner's API. The exits force you to treat them differently — respect that.

## 3.4 The retry loop, done right

```
                    ┌────────────────────────────┐
                    ▼                            │
   ...data... → InvokeHTTP ── Retry ──► RetryFlowFile
                    │                     │ retries_exceeded
              Original (2xx)              ▼
                    │              dead-letter branch
                    ▼               (PutS3Object to s3://…/dlq/
              audit branch           + LogAttribute ERROR + alert)
```

Two good implementations — pick one:

1. **Built-in relationship retry** (simplest): Relationships tab → tick Retry on the `Retry` relationship, attempts=3, penalize. NiFi pauses the file (default penalty 30 s) between goes.
2. **`RetryFlowFile` processor** (visible + tunable): counts attempts in an attribute, routes to `retry` (loop back) until the limit, then `retries_exceeded` → dead-letter. Use when you want the count in the audit trail.

Either way the ending is identical: **exhausted files land somewhere durable (a DLQ prefix in S3) with their attributes intact** — never terminated.

## 3.5 Building the POST body

Three common shapes, three little pre-processor recipes:

| You want to POST… | Put before InvokeHTTP |
|---|---|
| The file as-is (JSON/CSV/binary already in content) | Nothing — just ensure `mime.type` is right (`UpdateAttribute`) |
| A JSON made **from attributes** (e.g., an event notification) | `AttributesToJSON` (Destination = *flowfile-content*, pick attribute list) |
| A reshaped/templated JSON | `JoltTransformJSON` (surgical JSON reshaping) or `ReplaceText` with EL for tiny payloads |
| Many small records as one batched POST | `MergeRecord` first — APIs love arrays, hate 10k tiny calls |

## 3.6 Receiving POSTs (the other direction, briefly)

Sometimes NiFi is the **server** being posted *to*:

- **`ListenHTTP`** — one-processor inbox: listens on a port/path, each incoming POST body becomes a FlowFile, replies `200` automatically. Perfect for webhooks.
- **`HandleHttpRequest` + `HandleHttpResponse`** — the pro pair when *you* control the reply: request comes in → your flow processes → you send back a chosen status/body. (They share a `StandardHttpContextMap` controller service — the coat-check ticket matching each request to its response.)

On EKS, expose these through the **ALB ingress** from the main guide (they're HTTP, so ALB — not NLB), with `inbound-cidrs` locked to the senders.

## 3.7 InvokeHTTP troubleshooting table

| Symptom | Usual culprit |
|---|---|
| Everything → `Failure`, log says `unable to find valid certification path` | Server's CA isn't trusted → add CA to a truststore + `StandardSSLContextService` |
| `Failure` with connect timeout | Private subnet with no route: NAT gateway / VPC endpoint / security group egress |
| `No Retry` with 400 | Body or `Content-Type` wrong — check `mime.type`, view a sample via provenance (Part 4) |
| `No Retry` with 401/403 | Token expired (use the OAuth2 provider service!), wrong header name for the key |
| 413 Payload Too Large | You merged too big — cap `MergeRecord` max size below the API's limit |
| Works in dev, 404 in prod | URL built from a Parameter Context that wasn't updated per environment |

---

# Part 4 — Logging & Tracking
### Getting the record of every flow and every file that passed / was exported

This is the question support gets weekly: *"Did file X go out yesterday? Prove it."* NiFi gives you **four record systems**, from quick-glance to court-grade. Learn all four and which question each answers.

```
1. BULLETINS       "what's erroring RIGHT NOW"          (canvas, last ~5 min)
2. LOG FILES       "what did the app say"               (nifi-app.log & friends)
3. STATUS/COUNTERS "how MANY, how fast"                 (numbers, not names)
4. PROVENANCE ★    "the full history of EACH file"      (the black box recorder)
```

## 4.1 Bulletins — the smoke alarm

A red square on a processor = recent error **bulletins**. Hover to read; global list under ☰ menu → **Bulletin Board**. They expire after ~5 minutes — bulletins tell you *something is wrong now*, never history. Processor's bulletin level is settable (Settings → Bulletin Level); default WARN.

## 4.2 The log files — what the app said

On disk in `logs/` (in the container: `/opt/nifi/nifi-current/logs/`):

| File | Contains | Support use |
|---|---|---|
| **`nifi-app.log`** | The main event: processor errors, stack traces, S3/HTTP exceptions | Your first `grep` for any error |
| **`nifi-user.log`** | Who logged into the UI, auth decisions | "Who changed the flow?" investigations |
| **`nifi-request.log`** | Every HTTP request to NiFi's own API/UI | Audit of UI/API actions |
| `nifi-bootstrap.log` | JVM start/stop | "Why won't it start" |

**On EKS this is already wired for you** (main guide, Part 11): NiFi's chart logs to **stdout** → Fluent Bit → **CloudWatch** group `/aws/containerinsights/<cluster>/application`. So:

```bash
# live, per pod
kubectl logs -n nifi nifi-0 -f | grep -i error

# historical, cluster-wide — CloudWatch Logs Insights:
fields @timestamp, kubernetes.pod_name, log
| filter kubernetes.namespace_name = "nifi" and log like /PutS3Object/
| sort @timestamp desc
```

**Turning up detail on ONE noisy suspect** — edit `conf/logback.xml` (via the chart's config), add a logger for just that class, and NiFi reloads it live (no restart):

```xml
<logger name="org.apache.nifi.processors.aws.s3.PutS3Object" level="DEBUG"/>
```

**`LogAttribute` / `LogMessage` processors** — drop-in "print statements" for the canvas: wire a copy of a connection into `LogAttribute` and every file's attributes get written into `nifi-app.log` at your chosen level. Great for debugging; for a *permanent* audit trail there's a better pattern (4.5).

## 4.3 Status history & counters — the "how many" numbers

- **Per-processor stats:** right-click → **View status history** → graphs of bytes/files in/out over time. *"Did the flow stop at 2 a.m.?"* — this chart answers instantly.
- **Whole-canvas table:** ☰ menu → **Summary** — every processor & connection with 5-min in/out counts; sort by queue size to find the clog.
- Each processor also shows **In / Read-Write / Out** counts for the last 5 min right on its face on the canvas.

These give **volumes**, not file names. For names, you want the star of the show:

## 4.4 Data Provenance ★ — the black box recorder

**WHAT:** NiFi automatically records an **event for every meaningful thing that happens to every FlowFile** — no configuration needed, it's always on. Think airplane black box + package tracking, combined:

| Event type | Meaning | Our processors that emit it |
|---|---|---|
| `CREATE` | FlowFile born inside NiFi | `ListS3` (one per listed object) |
| `FETCH` / `RECEIVE` | Content pulled in from outside — **Transit URI = source** | `FetchS3Object` (`s3://bucket/key`), `ListenHTTP` |
| **`SEND`** | Content delivered to an external system — **Transit URI = destination** | **`PutS3Object`** (`s3://…`), **`InvokeHTTP`** (the URL) ← *your "what was exported" proof* |
| `ROUTE` | Which relationship it took (success? failure?) and why | every processor |
| `ATTRIBUTES_MODIFIED` / `CONTENT_MODIFIED` | Label / contents changed | UpdateAttribute, transforms |
| `FORK` / `JOIN` / `CLONE` | Split / merged / copied | MergeRecord, splits, multi-connections |
| `DROP` | End of life inside NiFi | last processor / auto-terminate |

**HOW to use it (the daily ritual):**

1. ☰ menu → **Data Provenance**.
2. **Search** by `filename` (e.g. `orders-0001.json`), by component (just PutS3Object's events), by time window, or by any attribute value.
3. Each result row: open **ⓘ details** → see *every attribute as it was at that moment*, plus for SEND events the **Transit URI** — literally "this exact file went to `https://api.partner.com/v1/orders` at 14:03:22, got routed to Original."
4. Click **lineage** (the connected-dots icon) → a family-tree graph of the file's whole life: listed → fetched → merged with 9,999 siblings → posted → archived. Right-click nodes to expand parents/children.
5. **View / Download content** as it was **before and after** each event (if the content is still in the archive) — and even **Replay** the file from that point to re-run processing. Replay is the greatest support tool NiFi has.

> **Permissions note:** on a secured cluster, seeing provenance needs the *view provenance* policy, and viewing/replaying content additionally needs *view the data* / *modify the data* on the component. If a teammate "sees no provenance," it's policy, not absence of data.

**How long does it remember?** Provenance lives in its own on-disk repository (its own PVC on EKS, per the main guide) with size/time caps in `nifi.properties` — whichever cap hits first, oldest events are deleted:

```properties
nifi.provenance.repository.max.storage.time=30 days
nifi.provenance.repository.max.storage.size=100 GB
nifi.provenance.repository.implementation=…WriteAheadProvenanceRepository
```

If compliance needs *forever*, don't grow the disk — **export the events**, next section.

## 4.5 Exporting the record (the "prove it, permanently" patterns)

Provenance inside NiFi ages out. Three ways to get the record **out**, weakest → strongest:

### Pattern A — the flow-level audit trail (simple, per-flow, recommended baseline)

Exploit the fact that after `PutS3Object`/`InvokeHTTP` succeed, the FlowFile's **attributes are a complete delivery receipt**. So tee the success path into a tiny audit branch:

```
PutS3Object / InvokeHTTP
      │ success / Original
      ├────────────► (continue main flow…)
      └────────────► UpdateAttribute        add audit.ts=${now():toNumber()}, audit.flow=orders-export
                     AttributesToJSON       Destination=flowfile-content
                                            (uuid, filename, s3.bucket, s3.key, s3.etag,
                                             invokehttp.status.code, invokehttp.request.url, audit.*)
                     MergeContent           newline-delimited JSON, bin age 5 min
                     PutS3Object            → s3://dp-audit-prod/receipts/${now():format('yyyy/MM/dd')}/
```

Result: an append-only ledger in S3 — one JSON line per delivered file — queryable forever with **Athena** ("show every file exported to the partner on July 1"). Cheap, obvious, survives NiFi entirely.

### Pattern B — `SiteToSiteProvenanceReportingTask` (automatic, EVERYTHING)

**WHAT:** a **Reporting Task** (☰ → Controller Settings → Reporting Tasks → +) that continuously packages **all provenance events as JSON** and ships them out via NiFi's site-to-site protocol — typically to an input port on the *same* cluster feeding a tiny "audit sink" flow that writes them to S3 / Kafka / OpenSearch / Splunk.

| Setting | Value |
|---|---|
| Destination URL | `https://nifi.dp-prod.example.com:8443/nifi` (itself) |
| Input Port Name | `provenance-events` |
| Event Type to Include / Component filters | e.g. only `SEND,FETCH,DROP`, or everything |
| Batch Size / schedule | 1000 / 30 sec |

Then on the canvas: `Input Port: provenance-events → MergeContent → PutS3Object (s3://dp-audit-prod/provenance/…)`.

**WHY it's the compliance-grade answer:** zero per-flow effort, captures *every* event including failures and drops, and the retained copy lives outside NiFi's aging repository. (Siblings worth knowing: `SiteToSiteBulletinReportingTask` and `SiteToSiteStatusReportingTask` export errors and metrics the same way.)

### Pattern C — pull via the REST API (ad-hoc investigations, scripts)

Everything the Provenance UI does is an API. Handy for a support script or a one-off compliance pull:

```bash
TOKEN=$(curl -sk -X POST https://nifi:8443/nifi-api/access/token \
        -d 'username=…&password=…')

# submit an async provenance query…
curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST https://nifi:8443/nifi-api/provenance -d '{
    "provenance": { "request": {
      "maxResults": 1000,
      "searchTerms": { "EventType": "SEND" },
      "startDate": "07/01/2026 00:00:00 UTC",
      "endDate":   "07/02/2026 00:00:00 UTC"
  }}}'
# …response contains an id; GET /nifi-api/provenance/{id} until finished=true,
# then read .provenance.results.provenanceEvents[] (transitUri, filename, timestamps)
```

### Which one when?

| Need | Use |
|---|---|
| "Business ledger of what we delivered/exported" | **A** — flow audit trail to S3 (+ Athena) |
| "Security/compliance record of *everything*, retained for years" | **B** — provenance reporting task → S3 |
| "Quick answer for one investigation" | Provenance UI, or **C** via API |
| "Is it healthy / how much flowed" | Status history, Summary, CloudWatch metrics |

---

# Part 5 — Worked Example
### S3 → transform → HTTP POST, with retries, dead-letter, and a full audit trail

The flow you'll build in dev as your training exercise — it exercises *everything* in this guide:

```
                         ┌──────────────────────────────────────────────┐
                         │           process group: orders-export        │
                         │                                              │
 s3://dp-raw/incoming/   │  [1] ListS3 ──► [2] FetchS3Object            │
                         │        (1 min,       │ (load-balanced)       │
                         │      primary node)   ▼                       │
                         │              [3] UpdateAttribute             │
                         │                mime.type=application/json    │
                         │                      ▼                       │
                         │              [4] InvokeHTTP  POST ───────────┼──► https://api.partner.com/v1/orders
                         │               │      │        │      │       │
                         │           Original Response  Retry  NoRetry/ │
                         │               │   (terminate)  │    Failure  │
                         │               ▼                ▼      ▼      │
                         │        [5] audit branch  [6] RetryFlowFile   │
                         │        AttributesToJSON      │ (3 tries)     │
                         │        MergeContent          │ exceeded      │
                         │        PutS3Object ──────────┼───► [7] DLQ:  │
                         │        s3://dp-audit/…       │  PutS3Object  │
                         │                              │  s3://…/dlq/  │
                         │  [8] DeleteS3Object ◄────────┘  +LogAttribute│
                         │   (original, only after       (ERROR)        │
                         │    audit write succeeds)                     │
                         └──────────────────────────────────────────────┘
```

**Key property choices, and the WHY behind each:**

| # | Processor | The decisions that matter |
|---|---|---|
| 1 | `ListS3` | Prefix `incoming/`, Min Object Age `30 sec`, **Primary node**, schedule `1 min` |
| 2 | `FetchS3Object` | Defaults (`${s3.bucket}`/`${filename}`); connection from [1] = **round-robin load balanced**; `failure` retried ×3 then → DLQ |
| 3 | `UpdateAttribute` | `mime.type=application/json`, `audit.flow=orders-export` — the label work |
| 4 | `InvokeHTTP` | POST, OAuth2 token provider service, header `X-Correlation-Id=${uuid}`, timeouts 5s/30s |
| 5 | Audit branch | Pattern A from 4.5 → `s3://dp-audit-prod/receipts/yyyy/MM/dd/` |
| 6 | `RetryFlowFile` | Max 3; `retry` loops back into [4]; count lands in attribute `flowfile.retries` (visible in audit + provenance) |
| 7 | DLQ | `PutS3Object` to `dlq/${now():format('yyyy/MM/dd')}/${filename}` **plus** `LogAttribute` at ERROR (→ CloudWatch alarm on the log pattern) |
| 8 | `DeleteS3Object` | Fires **only** off the audit branch's success — the original is deleted only once delivery is *provably recorded* |

**Now answer the weekly support questions with it:**

- *"Did `orders-0001.json` reach the partner?"* → Provenance search `filename = orders-0001.json` → find the **SEND** event from InvokeHTTP → details show timestamp, Transit URI, status attributes. Or Athena-query the audit bucket.
- *"Everything exported yesterday?"* → Athena over `s3://dp-audit-prod/receipts/2026/07/01/`.
- *"Why is the queue red before InvokeHTTP?"* → partner API is slow/down → check bulletins on [4], `invokehttp.status.code` distribution in provenance, and the Retry loop's depth.
- *"A file's in the DLQ — what happened?"* → its attributes (kept intact!) include `invokehttp.status.code` + `flowfile.retries`; provenance lineage shows every attempt; fix cause, then **Replay** from provenance or re-drop into the flow from the DLQ.

---

# Quick-Reference Tables

**S3 processors at a glance**

| Processor | Direction | Key property | Emits event | Must-know |
|---|---|---|---|---|
| ListS3 | catalog in | Prefix, Listing Strategy | CREATE | Primary node only; has **state** (view/clear via right-click) |
| FetchS3Object | read | `${s3.bucket}`/`${filename}` | FETCH | Load-balance the incoming connection |
| PutS3Object | write | Object Key with EL dates | **SEND** | Merge small files first! |
| DeleteS3Object | delete | after confirmed success only | — | Prefer TagS3Object + lifecycle when nervous |
| GetS3ObjectMetadata | peek | — | — | Size/exists checks without download |

**InvokeHTTP exits:** Original = 2xx proof → audit · Response = server's answer (new file) · Retry = 5xx → loop · No Retry = 4xx → DLQ, don't loop · Failure = couldn't connect → per SLA.

**Key attributes:** `filename` `uuid` `mime.type` `s3.bucket` `s3.key` `s3.etag` `s3.version` `invokehttp.status.code` `invokehttp.request.url` `invokehttp.tx.id`

**Where the records live**

| Question | Tool |
|---|---|
| Erroring right now? | Bulletins (canvas / Bulletin Board) |
| What did it say? | `nifi-app.log` → `kubectl logs` / CloudWatch Logs Insights |
| How many / how fast? | Summary page, View status history |
| This exact file's journey? | **Data Provenance** → search, lineage, view/replay content |
| Permanent export ledger? | Audit branch → S3 receipts (Pattern A) |
| Everything, for compliance? | `SiteToSiteProvenanceReportingTask` → S3 (Pattern B) |
| Scripted pull? | `POST /nifi-api/provenance` (Pattern C) |

**Provenance retention (`nifi.properties`):** `nifi.provenance.repository.max.storage.time` / `.max.storage.size` — first cap hit wins; export (B) before you depend on it.

---

*Pairs with:* `eks-nifi-kafka-training-guide.md` (platform, networking, GitLab promotion) *and* `eks-cheat-sheet.md`.
