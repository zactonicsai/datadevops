# NiFi flow review guide & AWS conversion cheat sheet

A practical method for reading an Apache NiFi flow definition (the exported JSON), deciding whether it can be simplified, and mapping it to AWS-native services such as Step Functions, Lambda, EventBridge, or Glue.

---

## Part 1 — How to read a NiFi flow definition JSON

A flow definition export has one root object. Read it in this order:

| Section | What it tells you | Why it matters for migration |
|---|---|---|
| `flowContents.name` / `comments` | Intent of the flow | The comments often describe the *business* purpose better than the wiring does |
| `flowContents.processors[]` | The work being done | Each processor becomes a state, a Lambda, or a managed-service feature |
| `flowContents.connections[]` | The actual data path | This is the truth. Ignore positions and labels; trace `source.id` → `destination.id` |
| `selectedRelationships` on each connection | Happy path vs error path | `success`/`matched`/`split` = main flow; `failure`/`unmatched`/`retry` = error handling you must recreate |
| `autoTerminatedRelationships` | Data being dropped | Anything auto-terminated is intentionally discarded — or a bug (unhandled failure) |
| `controllerServices[]` | Shared infrastructure | Credentials, DB pools, SSL contexts, record readers/writers → IAM roles, Secrets Manager, connection config |
| `parameterContexts` / `variables` | Environment config | → SSM Parameter Store, Secrets Manager, or CloudFormation/CDK parameters |
| `inputPorts` / `outputPorts` | Group boundaries | The group's API — becomes your workflow's input event schema and output destinations |
| `schedulingStrategy` / `schedulingPeriod` | Trigger model | Timer/cron polling vs event-driven — the single biggest simplification decision |
| `executionNode: PRIMARY` | Singleton behavior | The processor is stateful or must-not-duplicate → needs dedup/state design in AWS |
| `retryCount`, `backoffMechanism`, `maxBackoffPeriod` | Retry policy | → Step Functions `Retry` blocks or SQS redrive policy |
| `backPressureObjectThreshold` / `DataSizeThreshold` | Buffering assumptions | → SQS queue depth, Lambda reserved concurrency, Kinesis shard limits |

### Reading the connection graph

1. List every processor ID and name.
2. For each connection, note: source → \[relationships] → destination.
3. Identify **sources** (no incoming connections): these define the trigger.
4. Identify **sinks** (all relationships terminated or exiting via output ports): these define the destination.
5. Everything in between is transform/route logic.
6. Now you can state the flow in one sentence: "*Triggered by X, it does Y, and writes to Z, with failures going to W.*" If you can't, the flow needs decomposition before conversion.

### Quick triage with jq

```bash
# Inventory: processor names and types
jq -r '.flowContents.processors[] | "\(.name)\t\(.type)"' flow.json

# The wiring: source -> [rels] -> destination
jq -r '.flowContents.connections[] |
  "\(.source.name) -[\(.selectedRelationships|join(","))]-> \(.destination.name)"' flow.json

# Danger scan: unhandled relationships (empty autoTerminated + check against connections)
jq -r '.flowContents.processors[] |
  "\(.name): autoTerminated=\(.autoTerminatedRelationships)"' flow.json

# Trigger model: who polls, how often, on which node
jq -r '.flowContents.processors[] |
  "\(.name)\t\(.schedulingStrategy)\t\(.schedulingPeriod)\t\(.executionNode)"' flow.json

# Expression Language usage (attribute coupling you must recreate)
jq -r '.flowContents.processors[].properties | to_entries[] |
  select(.value|tostring|test("\\$\\{")) | "\(.key) = \(.value)"' flow.json
```

---

## Part 2 — The review checklist

Work through these eight questions for every flow. Each answer maps to a concrete AWS design choice.

**1. What is the trigger?**
Source processors define it. Polling sources (ListS3, ListFile, GetSQS on a timer, QueryDatabaseTable, GetFTP) can almost always become event-driven in AWS: S3 Event Notifications, EventBridge rules/schedules, SQS event-source mappings, DMS/CDC. Genuine listeners (ListenHTTP, ListenTCP, ConsumeKafka) map to API Gateway, ALB, NLB, or MSK/Lambda consumers. *If the NiFi flow polls, the AWS version usually shouldn't.*

**2. Where is the state?**
Processors annotated `@Stateful` (ListS3, ListFile, TailFile, QueryDatabaseTable with max-value columns, Wait/Notify, DetectDuplicate) keep cluster state. Event-driven redesigns usually eliminate listing state entirely; dedup and watermarks that survive move to DynamoDB; correlation/wait patterns move to Step Functions callbacks (`.waitForTaskToken`) or Map states.

**3. What travels with the data?**
FlowFiles carry content plus attributes, and Expression Language (`${...}`) couples processors through those attributes. Inventory every EL reference — each one is a field in your Step Functions state input, an event payload key, or a Lambda environment/parameter. This inventory *is* your event schema.

**4. What happens on failure?**
Trace every `failure`, `retry`, `unmatched`, and `invalid` relationship. Auto-terminated failure = data silently dropped (decide if that was intentional). Retry loops and penalization become Step Functions `Retry` (with `BackoffRate`, `MaxDelaySeconds`, `JitterStrategy`) plus SQS redrive to a DLQ. Anything routed to alert/log processors becomes `Catch` → SNS/DLQ.

**5. Is content transformed, or just moved?**
Pure movement (fetch → put) needs no compute: S3 replication, `s3:copyObject` SDK tasks in Step Functions, DataSync, Transfer Family, Firehose. Light per-record transforms (Jolt, UpdateRecord, EvaluateJsonPath, ReplaceText) fit Lambda or Firehose transforms. Heavy record processing (large joins, format conversion at scale, MergeContent batching) points to Glue, EMR Serverless, or Firehose buffering.

**6. How big and how often?**
Batch size, run schedule, back-pressure thresholds, and load-balance strategies reveal throughput assumptions. Per-event, seconds-long, idempotent work → Step Functions **Express**. Long-running, human-in-loop, or exactly-once orchestration → Step Functions **Standard**. Sustained streaming → Kinesis/MSK, not Step Functions at all.

**7. What does the flow assume about its host?**
PutFile/GetFile paths, mounted volumes, local scripts (ExecuteStreamCommand), and site-to-site links are host coupling. Decide the cloud-native equivalent early: EFS (Lambda file access), S3 (object semantics), DataSync (on-prem sync), ECS/Batch (arbitrary binaries).

**8. Which parts are just NiFi plumbing?**
Funnels, LogAttribute-for-visibility, UpdateAttribute renames, and routing that exists only to satisfy NiFi's relationship rules often disappear entirely — CloudWatch Logs, X-Ray, and Step Functions execution history replace them for free.

---

## Part 3 — Cheat sheet: NiFi → AWS mapping

### Concepts

| NiFi concept | AWS equivalent |
|---|---|
| FlowFile (content + attributes) | Event payload / S3 object + Step Functions state JSON |
| Connection queue + back pressure | SQS queue (depth, DLQ, redrive) |
| Relationship routing (success/failure) | Step Functions `Next` / `Retry` / `Catch`; EventBridge rules |
| Process group | State machine (or nested state machine) |
| Input/output ports | Workflow input schema / downstream event or queue |
| Controller service (credentials) | IAM role; Secrets Manager; RDS Proxy |
| Parameter context | SSM Parameter Store / Secrets Manager / IaC parameters |
| Expression Language `${attr}` | JSONPath / JSONata in ASL; Lambda event fields |
| Provenance & bulletins | CloudWatch Logs/Metrics, X-Ray, SFN execution history |
| Cluster + primary node | Managed services (no equivalent needed); DynamoDB for singleton state |
| Wait / Notify | `.waitForTaskToken` callbacks; SFN Map/Parallel |
| Prioritizers | SQS FIFO + message groups (limited); usually redesign |
| Site-to-site | EventBridge cross-account; SQS/SNS; PrivateLink |

### Common processors

| NiFi processor | AWS replacement | Notes |
|---|---|---|
| GetSQS | EventBridge Pipe or Lambda SQS trigger | Delete-on-success semantics built in |
| ListS3 / ListFile / ListSFTP | S3 Event Notifications; Transfer Family + events | Kill the polling; backfill once |
| FetchS3Object | `aws-sdk:s3:getObject` / `copyObject` SFN task | No Lambda needed ≤ 5 GB copy |
| PutS3Object | `s3:putObject` SDK task; Firehose to S3 | Multipart >5 GB needs Lambda/Batch Ops |
| PutFile / GetFile | Lambda + EFS; S3; DataSync (on-prem) | Decide what "local" means first |
| GetFTP/SFTP, PutFTP/SFTP | AWS Transfer Family | Managed endpoint, events on upload |
| InvokeHTTP | SFN HTTP Task (EventBridge connection) or Lambda | HTTP Task = zero code for REST calls |
| ListenHTTP / HandleHttpRequest | API Gateway / ALB → Lambda or SFN | |
| ConsumeKafka / PublishKafka | MSK + Lambda ESM; MSK Connect | |
| ConsumeJMS / ActiveMQ | Amazon MQ + Lambda | |
| EvaluateJsonPath / SplitJson | SFN `Pass` + intrinsic functions; Map state | `States.StringToJson`, `ItemsPath` |
| Jolt/UpdateRecord/ConvertRecord | Lambda; Firehose transform; Glue | Volume decides which |
| RouteOnAttribute / RouteOnContent | SFN `Choice`; EventBridge content filtering | |
| MergeContent / MergeRecord | Firehose buffering; Kinesis; SFN batched Map | Hardest pattern — see red flags |
| SplitText / SplitRecord | SFN Distributed Map over S3 objects | Handles millions of items |
| ExecuteSQL / PutDatabaseRecord | Lambda + RDS Proxy; Redshift Data API SDK task; Athena | |
| QueryDatabaseTable (CDC-ish) | AWS DMS; native CDC → Kinesis | |
| ExecuteStreamCommand / ExecuteScript | Lambda (≤15 min) or ECS/Fargate task from SFN | |
| PutEmail / PutSlack | SNS; SFN → SNS/Lambda | |
| Wait / Notify / DetectDuplicate | SFN callbacks; DynamoDB conditional writes | |
| CompressContent / Encrypt | Lambda; S3 SSE for encryption at rest | |
| GenerateFlowFile (test) | SFN test executions; sample events | |

### Retry / error semantics

| NiFi setting | Step Functions / AWS |
|---|---|
| `retryCount` + `PENALIZE_FLOWFILE` | `Retry`: `MaxAttempts`, `IntervalSeconds`, `BackoffRate` |
| `maxBackoffPeriod` | `MaxDelaySeconds` (+ `JitterStrategy: FULL`) |
| `yieldDuration` | Lambda ESM batching window; SQS visibility timeout |
| failure relationship → handler | `Catch` → DLQ / SNS / failure state |
| back pressure thresholds | SQS + `maxReceiveCount` redrive; reserved concurrency |
| FlowFile expiration | SQS message retention; SFN `TimeoutSeconds` |

---

## Part 4 — Choosing the target ("or other options")

Use the *shape* of the flow, not the processor names:

| Flow shape | Best-fit target | Why |
|---|---|---|
| Event → few steps → done (seconds, idempotent, high volume) | **Step Functions Express** (+ Pipes) | Cheap, per-event, built-in retry/catch |
| Long-running, approvals, waits, exactly-once orchestration | **Step Functions Standard** | 1-year executions, callbacks, audit history |
| Single transform, one trigger, no branching | **Lambda alone** | A state machine adds nothing |
| Pure routing/fan-out between systems | **EventBridge** (rules, Pipes) | No code, content filtering |
| Move files, no transform | **DataSync / S3 replication / Transfer Family** | Zero code, managed |
| Stream in, buffer, land in S3/warehouse | **Kinesis Firehose** | Replaces Merge/batch flows outright |
| Heavy ETL, big joins, schema evolution | **Glue / EMR Serverless** | NiFi record processors at scale |
| Complex DAGs of dependent batch jobs, data-eng team owns it | **MWAA (Airflow)** | If the flow is really a scheduler |
| Millions of items per run (per-object work) | **SFN Distributed Map** | Replaces List → Split → per-item flows |

**Rule of thumb:** if the NiFi flow is a line, use Lambda or Pipes; if it branches, retries, or waits, use Step Functions; if it buffers and batches streams, use Firehose/Kinesis; if it schedules other jobs, use Airflow.

### Red flags — flows that will NOT convert simply

- **MergeContent/MergeRecord with correlation attributes** — stateful batching across events; needs Firehose, Kinesis, or a redesign, not a 1:1 port.
- **Wait/Notify pairs** — distributed coordination; becomes SFN callbacks + DynamoDB and deserves its own design session.
- **TailFile / MiNiFi edge collection** — agent problem, not a workflow problem (CloudWatch agent, Kinesis Agent, IoT Greengrass).
- **Site-to-site between clusters** — an integration architecture decision (EventBridge cross-account, PrivateLink).
- **Priority queues / prioritizers** — SQS FIFO helps a little; usually requires rethinking.
- **Very large single files with streaming transforms** — Lambda's memory/tmp limits; consider ECS, Glue, or S3 Object Lambda.
- **Dozens of processors in one group** — decompose into multiple flows first (per the one-sentence test), convert each independently.

---

## Part 5 — Worked micro-example

The `SQS-to-S3-to-Local` flow from this review, run through the checklist:

1. **Trigger:** GetSQS (event-ish) + ListS3 60 s polling → collapse to S3 Event Notifications → SQS. Polling eliminated.
2. **State:** ListS3 cluster state → gone (event-driven); one-time backfill via `aws s3 sync`.
3. **Attributes:** `s3.bucket`, `filename` (+ URL-decoded key) → the Step Functions state input schema.
4. **Failures:** originally unhandled → `Retry` (exp backoff, 10 min cap) + `Catch` → DLQ.
5. **Transform:** none — pure movement → `s3:copyObject` SDK task, zero Lambda (or Lambda+EFS if a filesystem is truly required).
6. **Volume:** per-object, seconds → **Express** workflow.
7. **Host coupling:** PutFile local dir → decide EFS vs S3 vs DataSync (the only open design question).
8. **Plumbing:** SplitJson/EvaluateJsonPath → inline Map + `States.StringToJson`; LogAttribute → CloudWatch, free.

Result: 9 NiFi processors → 1 Pipe + 1 Express state machine with ~4 states.

---

## One-page review template

Copy this into your migration ticket for each flow:

```
Flow name:                       Reviewed by:            Date:
One-sentence summary:  Triggered by ___, it ___, writes to ___, failures go to ___.

Sources (triggers):              Polling? Y/N   Event-driven alternative:
Sinks (destinations):            Host-coupled paths?:
Stateful processors:             State strategy in AWS:
EL attributes used:              -> Event/state schema fields:
Failure paths:                   Auto-terminated failures (bugs?)*:
Retry config:                    -> SFN Retry / SQS redrive:
Controller services:             -> IAM / Secrets / config:
Volume & duration:               -> Express / Standard / Lambda / Firehose:
Red flags present:               Merge / Wait-Notify / Tail / S2S / Priority / >15min / >10GB
Target architecture:             Effort (S/M/L):
Backfill plan:                   Cutover & rollback plan:
```

*Every unhandled or auto-terminated `failure` relationship found during review is a decision to make explicitly in the new design — Step Functions forces you to handle them, which is one of the main reasons the converted version ends up more reliable than the original.*
