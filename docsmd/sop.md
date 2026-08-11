# Cloud Infrastructure Team SOP

## Data, ELT, Analytics & Messaging on AWS

> **Primary Standard Operating Procedure** for the team that builds and runs the cloud foundation beneath our
> **data ELT systems**, **applications**, **analytics & data-management tools**, and **messaging middleware**.
> It explains *what* we run, *why* we run it, the *exact steps* to operate it safely, and where to *automate*.

|                  |                                                                    |
|------------------|--------------------------------------------------------------------|
|**Document type** |Internal Standard Operating Procedure (SOP)                         |
|**Version**       |2.0                                                                 |
|**Audience**      |Cloud / Platform / Infrastructure Engineers, Data Engineers, On-call|
|**Reading level** |Beginner-friendly with copy-paste examples                          |
|**Scope**         |AWS · Terraform · ELT · Analytics · Messaging · Automation          |
|**Review cadence**|Every 6 months                                                      |

-----

## Table of Contents

1. [Start Here](#0-start-here)
1. [Key Concepts, Explained Simply](#1-key-concepts-explained-simply)
1. [Infrastructure Team Responsibilities — The Full Task List](#2-infrastructure-team-responsibilities--the-full-task-list)
1. [How the Pieces Fit Together](#3-how-the-pieces-fit-together)
1. [Service Catalog](#4-service-catalog)
1. [Data ELT & Pipelines](#5-data-elt--pipelines)
1. [Analytics & Data Management](#6-analytics--data-management)
1. [Messaging & Middleware](#7-messaging--middleware)
1. [Automation Layer — Lambda, AMIs & Triggers](#8-automation-layer--lambda-amis--triggers)
1. [AI & Search](#9-ai--search)
1. [Standard Operating Procedure — Step by Step](#10-standard-operating-procedure--step-by-step)
1. [Operational Runbooks](#11-operational-runbooks)
1. [Best Practices Checklist](#12-best-practices-checklist)
1. [Automation Opportunities](#13-automation-opportunities)
1. [Glossary](#14-glossary)
1. [References & Official Docs](#15-references--official-docs)

-----

## 0. Start Here

Our company runs on data. Information arrives from many places — apps, websites, sensors, partner files — and it has
to be **moved, cleaned, stored, searched, and turned into answers**. The software that does this is the *data
application unit*. The **Infrastructure team** (that’s us) builds and looks after the “ground” all of it stands on:
networks, security, servers, databases, pipelines, message buses, dashboards, and the automation that ties them
together.

We describe that whole setup as **text files** using **Terraform** — an idea called **Infrastructure as Code (IaC)**.
The files are like a recipe: anyone can read it, suggest changes, and re-cook the exact same result every time.

> **Our mission in one sentence:** provide a **safe, reliable, observable, and cost-aware** cloud foundation that
> lets data and application teams move fast — by turning repeatable work into reviewed, automated code.

### The four worlds we support

Everything in this document falls under one of these four areas. They overlap, and one pipeline often touches all four.

|Area                             |What it means                                                                                                                                          |
|---------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
|**① Data ELT systems**           |Moving data from source to destination and reshaping it: **E**xtract, **L**oad, **T**ransform. Tools like Glue, DMS, Airflow/MWAA, dbt, Step Functions.|
|**② Applications**               |The services that produce and consume data: web apps, APIs, workers, batch jobs, ML jobs — running on EKS, ECS, Lambda, or EC2.                        |
|**③ Analytics & data management**|Turning stored data into answers and keeping it well-governed: warehouses, query engines, catalogs, BI dashboards, and data governance.                |
|**④ Messaging middleware**       |The “post office” that passes messages between systems reliably: Kafka/MSK, Kinesis, SNS, SQS, EventBridge, and message brokers.                       |

### Why code instead of clicking?

- **“It worked on my machine”** — code makes every environment (dev, test, production) match. No mystery differences.
- **Slow, risky changes** — a reviewed code change is safer than someone clicking in a console at midnight.
- **“How is this built?”** — the code *is* the documentation. New teammates read it to understand everything.

-----

## 1. Key Concepts, Explained Simply

The building-block words used across this guide.

|Term                      |Plain-language meaning                                                                                                                                                                |
|--------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|**Cloud / AWS**           |Renting computers and services over the internet from Amazon instead of buying our own machines. We pay only for what we use.                                                         |
|**Terraform / IaC**       |The tool that reads our recipe files and tells AWS to create, change, or delete things to match.                                                                                      |
|**ELT vs ETL**            |Two orders for the same chores. **ETL** transforms data *before* loading it; **ELT** loads raw data first, then transforms it inside a powerful warehouse. ELT is common in the cloud.|
|**Pipeline**              |A series of automatic steps that data flows through — like an assembly line that picks up, reshapes, and delivers data.                                                               |
|**Middleware**            |Software “glue” that sits between systems and passes messages so they can talk without being directly wired together.                                                                 |
|**Data warehouse vs lake**|A **lake** stores raw files of any shape cheaply (S3). A **warehouse** stores clean, organized tables built for fast questions (Redshift). Many teams use both (“lakehouse”).         |
|**Environment**           |`dev` for trying things, `staging` for final testing, `prod` is the real one customers use.                                                                                           |
|**Plan & Apply**          |`plan` previews what would change; `apply` makes it real. Always read the plan first.                                                                                                 |
|**Idempotent**            |Safe to run more than once with the same result (important for retries).                                                                                                              |
|**Blast radius**          |How much can break if one thing goes wrong. We keep it small by separating layers.                                                                                                    |

-----

## 2. Infrastructure Team Responsibilities — The Full Task List

This is the complete “menu of duties” for an infrastructure team supporting data ELT, applications, analytics, data
management, and messaging middleware. Each domain lists the concrete tasks we own. The **`[AUTO]`** marker flags
tasks with strong automation potential — see [§13 Automation Opportunities](#13-automation-opportunities).

### A · Foundation — Network, Identity & Secrets *(always-on)*

The base layer everything else stands on: the private network, who is allowed to do what, and how secrets and keys
are stored.

- Design & build VPCs, subnets (public / private / isolated), routing
- NAT, internet gateways, VPC endpoints, PrivateLink **`[AUTO]`**
- DNS (Route 53), private zones, service discovery
- Cross-account / cross-region connectivity (Transit Gateway, peering)
- IAM roles, policies, permission boundaries, IRSA on EKS
- Single sign-on (IAM Identity Center) & access reviews **`[AUTO]`**
- Secrets (Secrets Manager / SSM) & rotation **`[AUTO]`**
- KMS encryption keys & key lifecycle

### B · Compute & Application Platforms *(applications)*

Where applications run.

- Provision & upgrade EKS (Kubernetes) clusters & node groups
- ECS / Fargate for container apps
- Lambda functions for event-driven work **`[AUTO]`**
- EC2 fleets & golden AMI pipelines **`[AUTO]`**
- Autoscaling (Karpenter / Cluster Autoscaler / ASGs)
- Container registries (ECR) & image scanning **`[AUTO]`**
- Load balancers, ingress, service mesh
- GPU node groups for ML / inference

### C · Data Stores & Storage *(data)*

Every place data rests.

- Relational databases (RDS / Aurora Postgres & MySQL)
- NoSQL (DynamoDB), in-memory (ElastiCache)
- Search & vector indexes (OpenSearch)
- Data warehouse (Redshift)
- S3 data lake zones (raw / curated / consumption)
- Block & file storage (EBS, EFS, FSx)
- Schema, index, partition & table management
- Backup, snapshot & point-in-time recovery **`[AUTO]`**

### D · Data ELT & Pipelines *(ELT)*

Moving and reshaping data. See [§5](#5-data-elt--pipelines) for examples.

- Ingestion / extract (DMS, Kinesis, connectors) **`[AUTO]`**
- Transformation jobs (Glue, Spark, dbt) **`[AUTO]`**
- Orchestration (Step Functions, MWAA / Airflow) **`[AUTO]`**
- Data catalog & crawlers (Glue Data Catalog)
- Pipeline scheduling, retries & backfills **`[AUTO]`**
- Data quality checks & validation gates **`[AUTO]`**
- Change-data-capture (CDC) streams
- Pipeline cost & performance tuning

### E · Analytics & Data Management *(analytics)*

Turning stored data into answers, kept well-governed. See [§6](#6-analytics--data-management).

- Query engines (Athena, Redshift Spectrum)
- Big-data processing (EMR, Spark)
- BI & dashboards (QuickSight) provisioning
- Data governance & fine-grained access (Lake Formation)
- Data classification, lineage & cataloging
- Retention & lifecycle policies **`[AUTO]`**
- Cost controls on query/scan volumes **`[AUTO]`**
- Data sharing & access provisioning

### F · Messaging & Middleware *(middleware)*

The “post office” between systems. See [§7](#7-messaging--middleware).

- Kafka streaming (MSK) — topics, ACLs, schema registry
- Streaming ingest (Kinesis Data Streams / Firehose)
- Pub/sub notifications (SNS) & fan-out **`[AUTO]`**
- Queues (SQS) & dead-letter queues **`[AUTO]`**
- Event routing (EventBridge) **`[AUTO]`**
- Managed brokers (Amazon MQ — RabbitMQ / ActiveMQ)
- Throughput, partition & retention tuning
- Delivery guarantees & replay strategy

### G · Observability *(always-on)*

Being able to *see* what’s happening.

- Metrics (Prometheus / CloudWatch) **`[AUTO]`**
- Dashboards (Grafana) **`[AUTO]`**
- Logs collection & retention **`[AUTO]`**
- Traces (OpenTelemetry / X-Ray)
- Alerts, SLOs & on-call routing **`[AUTO]`**
- Pipeline & data freshness monitoring **`[AUTO]`**
- Synthetic checks & health probes
- Runbooks tied to alerts

### H · Reliability & Operations *(always-on)*

Keeping things running.

- High availability across Availability Zones
- Disaster recovery (cross-region) & DR drills **`[AUTO]`**
- Patching & version upgrades **`[AUTO]`**
- Capacity planning & autoscaling
- Incident management & postmortems
- Drift detection & remediation **`[AUTO]`**
- Change management & release gating
- Maintenance windows & comms

### I · Security, Compliance & Cost *(guardrails)*

The guardrails that keep everything safe and affordable.

- Encryption in transit & at rest, everywhere
- Least-privilege access & audit logging (CloudTrail)
- Policy-as-code guardrails (OPA / SCPs) **`[AUTO]`**
- Vulnerability & config scanning **`[AUTO]`**
- Data residency & compliance evidence
- Tagging standards for cost & ownership **`[AUTO]`**
- Budgets, anomaly alerts & rightsizing (FinOps) **`[AUTO]`**
- Reusable module registry & golden paths

> **Rule of thumb:** if a task is done more than once, or must be the same across environments, it belongs in
> Terraform and — where the `[AUTO]` marker appears — behind automation, not in a person’s memory or a console click.

-----

## 3. How the Pieces Fit Together

### The data journey (left to right)

Data flows through stages. The infrastructure team owns every box and the connections between them.

```
  SOURCES        INGEST/EXTRACT     STORE (LAKE)      TRANSFORM        SERVE/ANALYZE
  apps      ──▶  Kinesis / DMS  ──▶  S3 raw zone  ──▶  Glue / Spark ──▶  Redshift / Athena
  websites  ──▶  Firehose       ──▶  S3 curated   ──▶  dbt          ──▶  OpenSearch
  partners  ──▶  Kafka (MSK)    ──▶  (catalog)    ──▶  (quality)    ──▶  QuickSight (BI)
                      │                                                      │
                      └────────────── MESSAGING MIDDLEWARE ──────────────────┘
                         SNS · SQS · EventBridge route events between stages
                                          │
                            OBSERVABILITY watches every box
                         Prometheus · Grafana · CloudWatch · Alerts
```

### We build in layers (a cake)

Each layer sits on the one below. We keep each layer’s Terraform memory (state) separate, so a mistake in one layer
can’t accidentally break another — limiting the *“blast radius.”*

|Layer                            |Contents                                          |
|---------------------------------|--------------------------------------------------|
|**5 · Analytics & AI**           |Redshift, Athena, QuickSight, Ollama, agents      |
|**4 · ELT & Pipelines**          |Glue, DMS, MWAA/Airflow, Step Functions, dbt      |
|**3 · Data Services & Messaging**|MSK, Kinesis, SNS/SQS, OpenSearch, Aurora, S3 lake|
|**2 · Platform**                 |EKS, ECS, Lambda, AMI pipelines, Observability    |
|**1 · Foundation**               |Network (VPC), Identity (IAM), Secrets, KMS keys  |


> **Build bottom-up · Destroy top-down.**

### Recommended repository layout

```
# Infrastructure repository — reusable modules + per-environment values
infra/
├── modules/
│   ├── network/       # VPC, subnets, endpoints
│   ├── platform/      # EKS, ECS, Lambda, AMI pipelines
│   ├── data-stores/   # Aurora, OpenSearch, Redshift, S3 lake
│   ├── elt/           # Glue, DMS, MWAA, Step Functions
│   ├── messaging/     # MSK, Kinesis, SNS, SQS, EventBridge
│   ├── automation/    # Lambdas, triggers, build pipelines
│   └── observability/ # Prometheus + Grafana + alerts
├── envs/
│   ├── dev/      # { main.tf, dev.tfvars, backend.tf }
│   ├── staging/
│   └── prod/
└── policies/          # OPA / Sentinel guardrails
```

-----

## 4. Service Catalog

The core data services we provision, with the recommended Terraform module and the key best practices for each.

### Kafka — Amazon MSK

A super-fast, durable conveyor belt for events. Producers write to “topics”; many consumers read independently and
can replay history.

- **Module:** `terraform-aws-modules/msk-kafka-cluster/aws`
- Use **MSK Serverless** for bursty traffic; **provisioned** clusters for steady, predictable load.
- For durability: replication factor **3**, `min.insync.replicas = 2`.
- Prefer **IAM authentication** over SCRAM passwords; ship broker logs to CloudWatch + S3.
- Clusters take **15–30 minutes** to build — set generous timeouts in automation.

### OpenSearch — search, logs & vectors

The same cluster can serve application search, log analytics, and AI vector search (k-NN).

- **Module:** `terraform-aws-modules/opensearch/aws`
- Create the **service-linked role** once before first deploy:
  
  ```bash
  aws iam create-service-linked-role --aws-service-name es.amazonaws.com
  ```
- Use dedicated master nodes for stability; enable **zone awareness** across AZs.
- For company login, the idealo SAML module supports Okta / Azure AD.

### Postgres — Aurora

Amazon’s Postgres-compatible database that self-heals and scales storage automatically.

- **Modules:** `terraform-aws-modules/rds-aurora/aws`, `aws-ia/rds-aurora/aws`
- **Serverless v2** scales capacity with load (`db.serverless`), saving money during quiet periods.
- Always enable encryption and automated backups.
- For disaster recovery, an Aurora **global database** replicates to a second region.

### Spark & NiFi — on EKS

Heavy data processing.

- **Blueprints:** AWS **Data on EKS** (`awslabs.github.io/data-on-eks`); `terraform-aws-modules/eks/aws`
- Three ways to run Spark: **EMR Serverless** (no clusters), **EMR on EKS**, or the **Spark Operator** on your own EKS.
- The NiFi blueprint wires up Prometheus and Grafana for you.

### Storage choices

- **EBS** — a virtual hard drive for one machine (databases, nodes).
- **EFS** — a shared folder many machines mount at once.
- **S3** — object storage for files; the backbone of the data lake.
- **Lake zones:** *raw* (as-received) → *curated* (cleaned) → *consumption* (ready). Catalog with Glue; govern with Lake Formation.

### Monitoring — Prometheus & Grafana

- **Module:** `aws-observability/terraform-aws-observability-accelerator` (Managed Prometheus + Managed Grafana + ADOT collector)
- **Prometheus** stores time-series metrics; **Grafana** visualizes and alerts.
- Managed (AMP + AMG) reduces upkeep; self-hosted in EKS gives more control.

-----

## 5. Data ELT & Pipelines

An ELT pipeline is an assembly line for data: **extract** it from a source, **load** it into the lake or warehouse,
then **transform** it into clean, useful tables. The infrastructure team provisions the engines and the orchestrator
that runs them on schedule, with retries and alerts.

### Which tool for which job?

|Need                                         |Tool              |In one line                               |
|---------------------------------------------|------------------|------------------------------------------|
|Copy a database into AWS (incl. live changes)|AWS DMS           |Database Migration Service; great for CDC.|
|Stream events in real time                   |Kinesis / Firehose|Continuous ingest into S3/Redshift.       |
|Transform big data without servers           |AWS Glue          |Serverless Spark + a data catalog.        |
|Transform inside the warehouse (SQL)         |dbt on Redshift   |Analysts write SQL models.                |
|Coordinate many steps with logic             |Step Functions    |Visual state machine; serverless.         |
|Rich scheduling & dependencies               |MWAA (Airflow)    |Managed Airflow for complex DAGs.         |

### AWS Glue — serverless transform & catalog

Glue runs Spark jobs without you managing a cluster, and keeps a **Data Catalog** — a table of contents for the lake
so query tools know what’s there.

```hcl
resource "aws_glue_catalog_database" "lake" {
  name = "analytics_${var.environment}"
}

resource "aws_glue_crawler" "raw" {        # discovers tables in S3 automatically
  name          = "raw-crawler-${var.environment}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.lake.name
  s3_target { path = "s3://${var.lake_bucket}/raw/" }
  schedule      = "cron(0 */6 * * ? *)"     # re-scan every 6 hours
}

resource "aws_glue_job" "transform" {
  name         = "curate-${var.environment}"
  role_arn     = aws_iam_role.glue.arn
  glue_version = "4.0"
  command {
    script_location = "s3://${var.scripts_bucket}/curate.py"
    python_version  = "3"
  }
  default_arguments = {
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}
```

### Orchestration — Step Functions & MWAA

An orchestrator is the conductor: it runs pipeline steps in the right order, waits for each, retries failures, and
alerts on problems. **Step Functions** is serverless and simple; **MWAA** (managed Airflow) suits complex,
code-heavy schedules.

```hcl
resource "aws_sfn_state_machine" "elt" {
  name     = "elt-${var.environment}"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    StartAt = "Extract",
    States = {
      Extract   = { Type = "Task", Resource = aws_lambda_function.extract.arn, Next = "Transform" },
      Transform = { Type = "Task", Resource = aws_glue_job.transform.arn,
                    Retry = [{ ErrorEquals = ["States.ALL"], MaxAttempts = 2 }], Next = "Notify" },
      Notify    = { Type = "Task", Resource = "arn:aws:states:::sns:publish",
                    Parameters = { TopicArn = aws_sns_topic.alerts.arn, "Message.$" = "$.summary" }, End = true }
    }
  })
}
```

> **Tip:** build retries and a final SNS “notify” step into every pipeline. Send failures to the alerts topic
> (see [§7](#7-messaging--middleware)) so on-call hears about a broken pipeline within minutes.

### AWS DMS — ingest & change-data-capture

DMS copies a source database into AWS and can keep streaming **ongoing changes** (CDC) so the lake stays fresh
without re-copying everything.

-----

## 6. Analytics & Data Management

Once data is clean and stored, people need to ask questions of it — and the organization needs to keep it
well-governed (who can see what, how long we keep it, where it came from).

|Service              |What it does                                                                                                                                        |
|---------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
|**Amazon Athena**    |Ask questions of files in S3 using plain SQL — no servers. You pay per data scanned, so we use compressed, partitioned **Parquet** to keep cost low.|
|**Amazon Redshift**  |A data warehouse: clean, organized tables tuned for fast, repeated business questions. Use **Serverless** for variable workloads.                   |
|**Amazon EMR**       |Managed big-data processing (Spark, Hive, Presto) for heavy custom jobs that need more control than Glue.                                           |
|**Amazon QuickSight**|BI dashboards and charts for business users, reading from Redshift/Athena. We provision access and data sources.                                    |

### Data governance — Lake Formation & the Catalog

Governance answers: *who can see which tables and columns, where did this data come from, and how long do we keep
it?* **Lake Formation** grants fine-grained (table- and column-level) permissions on top of the Glue Catalog, so
sensitive columns stay protected.

**Our duties here:** register lake locations, define permissions as code, set S3 lifecycle rules for retention, tag
data by sensitivity, and keep lineage via the catalog. Combine with KMS encryption and CloudTrail audit logs for a
complete governance story.

-----

## 7. Messaging & Middleware

Messaging middleware is the **post office** between systems. Instead of wiring every app directly to every other app
(fragile and tangled), apps drop messages with the post office, which delivers them reliably. This lets systems be
added, removed, or restarted without breaking each other (“loose coupling”).

### Pick the right messaging tool

|Pattern                                    |Tool              |Use when…                                          |
|-------------------------------------------|------------------|---------------------------------------------------|
|High-throughput event streaming with replay|MSK (Kafka)       |Many consumers, ordered logs, keep history.        |
|Simple managed streaming into AWS          |Kinesis / Firehose|Real-time ingest to S3/Redshift, less ops.         |
|Broadcast one message to many              |SNS               |Fan-out notifications to many subscribers.         |
|Reliable work queue, one consumer pace     |SQS               |Buffer tasks; never drop one.                      |
|Route events by rules between services     |EventBridge       |“When X happens, do Y” automation.                 |
|Classic broker protocols (AMQP/MQTT)       |Amazon MQ         |Lifting an app that already uses RabbitMQ/ActiveMQ.|

### SNS + SQS + EventBridge — the serverless trio

The classic cloud pattern: **SNS** broadcasts, **SQS** buffers, and **EventBridge** routes by rules. Combine them
as **SNS → SQS** to broadcast widely *and* process reliably.

```hcl
resource "aws_sns_topic" "events" {
  name              = "data-${var.environment}-events"
  kms_master_key_id = "alias/aws/sns"      # encrypt at rest
}

resource "aws_sqs_queue" "work" {
  name                       = "data-${var.environment}-work"
  visibility_timeout_seconds = 120
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn   # poison messages go here
    maxReceiveCount     = 5
  })
}

resource "aws_sns_topic_subscription" "fanout" {
  topic_arn = aws_sns_topic.events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.work.arn       # SNS → SQS fan-out
}
```

> **Always add a dead-letter queue (DLQ).** Without one, a message that always fails can retry forever and block the
> queue. Full trigger patterns are in [§8 Automation Layer](#8-automation-layer--lambda-amis--triggers).

-----

## 8. Automation Layer — Lambda, AMIs & Triggers

This layer is the **robots that do the chores**. Small programs run automatically when something happens, golden
server images are baked on a schedule, and notifications keep everyone informed. It ties the other sections
together: a pipeline finishes, a trigger fires, a Lambda reacts, SNS notifies.

```
  EVENT ──▶ TRIGGER ──▶ LAMBDA / PIPELINE ──▶ SNS ──▶ SUBSCRIBERS
  S3 upload      S3 notification      transform data       email / SMS
  schedule       EventBridge cron     start a build        Slack (Lambda)
  state change   EventBridge rule     call AWS APIs        SQS queue
  queue msg      SQS mapping          bake an AMI          another Lambda
```

### Lambda functions

A small program that runs only when triggered — no servers to manage. Needs four things: **code**, an **IAM role**
(least privilege), **config** (memory, timeout, subnet), and a **trigger**.

```hcl
resource "aws_lambda_function" "processor" {
  function_name = "${var.app_type}-${var.environment}-processor"
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = "main.handler"
  timeout       = 60
  memory_size   = 512
  architectures = ["arm64"]              # cheaper & often faster

  vpc_config {                            # run in private subnets to reach data
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment { variables = { SNS_TOPIC_ARN = aws_sns_topic.events.arn } }
}

resource "aws_cloudwatch_log_group" "processor" {
  name              = "/aws/lambda/${aws_lambda_function.processor.function_name}"
  retention_in_days = 30                  # control log cost
}
```

> **Make handlers idempotent** — safe to run twice — because most AWS events are delivered *at least once*. Set
> `reserved_concurrent_executions` on prod to protect databases from overload.

### Triggers — what wakes the robots

|Trigger             |Fires when…               |Best for                  |
|--------------------|--------------------------|--------------------------|
|S3 notification     |a file is uploaded/deleted|reacting to new data      |
|EventBridge rule    |a service changes state   |service automation, builds|
|EventBridge schedule|a cron time is reached    |nightly jobs, cleanup     |
|SQS event source    |messages wait in a queue  |steady batch processing   |
|SNS subscription    |a topic gets a message    |fan-out reactions         |

```hcl
# Example: run a Lambda every night at 2 AM UTC
resource "aws_scheduler_schedule" "nightly" {
  name                = "${var.app_type}-${var.environment}-nightly"
  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 2 * * ? *)"
  target {
    arn      = aws_lambda_function.processor.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ task = "nightly-cleanup" })
  }
}
```

### AMI build automation — golden images

A **golden AMI** is a pre-baked, patched, tested server disk image. Launching from it is faster and more consistent
than configuring each server by hand. **EC2 Image Builder** runs a repeatable pipeline: *base image → install →
test → distribute*, on a schedule.

```hcl
resource "aws_imagebuilder_image_pipeline" "this" {
  name                             = "${var.app_type}-${var.environment}-pipeline"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.this.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this.arn

  schedule {
    schedule_expression = "cron(0 3 ? * sun *)"   # weekly, Sunday 3 AM
    pipeline_execution_start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  }
  image_tests_configuration {
    image_tests_enabled = true                    # a failed test fails the build
    timeout_minutes     = 90
  }
}
```

> **The full loop:** schedule (or manual event) → Image Builder bakes & tests the AMI → an EventBridge rule
> catches the result → SNS notifies the team with the new AMI ID or the failure reason. Build instances run in a
> **private subnet** with a least-privilege profile.

*(For the complete automation playbook — execution roles, S3/SQS triggers, custom build pipelines for any app type,
and subnet/configuration patterns — see the companion `cloud-automation-sop.md`.)*

-----

## 9. AI & Search

The platform also supports lightweight AI and semantic search, layered on the data services above.

|Capability                          |Tool           |Notes                                                                                                              |
|------------------------------------|---------------|-------------------------------------------------------------------------------------------------------------------|
|**Text classification & embeddings**|fastText       |Runs efficiently on CPUs — no GPU needed. Good for tagging documents, detecting languages, lightweight enrichment. |
|**Self-hosted LLMs**                |Ollama         |Run open-weight models on a GPU node group in EKS; keep the endpoint private to the VPC for privacy-sensitive data.|
|**Vector search**                   |OpenSearch k-NN|Store embeddings (lists of numbers capturing meaning) so a search for “car” can match “automobile.”                |
|**AI agents**                       |Python on EKS  |Containers that summarize alerts, draft reports, answer questions. Scoped via IRSA; read-only by default.          |


> **Safety:** each agent gets a narrowly-scoped IAM role via IRSA. Agents may read freely but must **never change
> production** without human approval. Use Karpenter to add GPUs only when needed.

-----

## 10. Standard Operating Procedure — Step by Step

The official routine for making any infrastructure change — a database, a pipeline, a queue, a Lambda. Follow it
every time.

### Part A — One-time setup (per engineer)

```bash
# 1. Install tools
terraform -version
aws --version
git --version

# 2. Log in securely (single sign-on, never long-lived keys)
aws sso login --profile data-platform

# 3. Get the code
git clone https://git.company.com/cloud/infra.git && cd infra
```

### Part B — Making a change (every time)

1. **Start a fresh branch:** `git checkout -b add-glue-pipeline`
1. **Move into `dev` & edit** the module or `dev.tfvars`: `cd envs/dev`
1. **Initialize, format, validate:**
   
   ```bash
   terraform init
   terraform fmt && terraform validate
   ```
1. **Preview & read the plan carefully.** Watch for unexpected `destroy` / `-/+ replace` on data stores. If you see it, **STOP**.
   
   ```bash
   terraform plan -out=tfplan
   ```
1. **Open a pull request for review** (automated scans & policy-as-code run here):
   
   ```bash
   git add . && git commit -m "Add Glue curate pipeline"
   git push origin add-glue-pipeline
   ```
1. **Apply to dev, then test end-to-end:** `terraform apply tfplan`
1. **Promote:** staging → prod (prod needs a second approver and runs from CI).

### Part C — Test a trigger / pipeline end-to-end (in dev)

|What      |How to test                                                                                |
|----------|-------------------------------------------------------------------------------------------|
|S3 trigger|Upload a sample file to the watched prefix; confirm the Lambda ran (its log group).        |
|SNS       |`aws sns publish --topic-arn <arn> --message "test"`; confirm every subscriber received it.|
|SQS       |`aws sqs send-message --queue-url <url> --message-body '{}'`.                              |
|Pipeline  |Start the Step Function / Glue job manually; confirm the SNS notification arrives.         |
|Lambda    |`aws logs tail "/aws/lambda/<name>" --follow` while you invoke it.                         |

### The golden rules

1. Always `plan` before `apply`, and read every line.
1. dev → staging → prod, never skip straight to prod.
1. Every change goes through a reviewed pull request.
1. Never store secrets in code; use Secrets Manager.
1. If a plan wants to destroy data, stop and ask.
1. Build retries + SNS notify into every pipeline.

-----

## 11. Operational Runbooks

Short, calm step-lists for common situations — read during stressful moments.

|Situation                           |What to do                                                                                                                                                         |
|------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|**Terraform state is locked**       |Someone’s running it or a run crashed. Wait. If sure no one is, confirm the owner and `terraform force-unlock <ID>`. Never force-unlock during an active apply.    |
|**Plan wants to destroy a database**|STOP, don’t apply. Usually a name/setting changed and Terraform reads it as “replace.” Check edits; add `lifecycle { prevent_destroy = true }` on critical stores. |
|**Drift (reality ≠ code)**          |Someone changed something by hand. `terraform plan` shows the gap; re-apply code to fix, or update code to keep the change. Then stop manual edits.                |
|**Pipeline failed**                 |Read the SNS failure message → the job’s CloudWatch logs. Common: a transform error or a data-quality gate failed. Fix and re-run; use backfill for missed windows.|
|**Messages piling up in SQS**       |Consumer too slow or failing. Check Lambda concurrency, raise `batch_size`, inspect the **DLQ** for poison messages.                                               |
|**SNS subscriber not receiving**    |Email subs must be **confirmed**. Check the topic policy allows the publisher and any filter policy isn’t excluding the message.                                   |
|**Kafka consumer lag growing**      |Consumers can’t keep up. Scale consumers, add partitions, or check for a stuck consumer. Watch lag metrics in Grafana.                                             |
|**AMI build failed**                |Read the SNS message → Image Builder logs. Common: a package install or a `test` phase returned non-zero. Fix the component, re-run.                               |
|**Costs spiked**                    |Check Cost Explorer + tags. Common: oversized instances, idle GPUs, big Athena scans, or NAT data charges. Rightsize in dev first.                                 |

-----

## 12. Best Practices Checklist

**Code & structure**

- Prefer trusted registry modules over hand-written resources
- Pin every module & provider version
- Separate state per layer (network / platform / data / elt)
- One module per service, environments via `.tfvars`
- Remote state (S3 + DynamoDB lock), never on laptops

**Safety & review**

- Plan before apply; read the output
- Pull-request review for every change
- Policy-as-code (OPA / Sentinel) + scans (checkov, tflint)
- `prevent_destroy` on critical data stores
- Prod applies run from CI with a second approver

**Data, ELT & analytics**

- Store lake data as compressed, partitioned Parquet
- Build retries + data-quality gates into pipelines
- Notify SNS on every pipeline success/failure
- Govern with Lake Formation; tag data by sensitivity
- Set S3 lifecycle/retention; cap Athena scan volumes

**Messaging & automation**

- Encrypt topics & queues (KMS); scope policies to principals
- Use SNS → SQS fan-out; always add a DLQ
- Make Lambda handlers idempotent (at-least-once delivery)
- Set log retention; cap Lambda concurrency on prod
- Bake & test golden AMIs on a schedule

**Security**

- Encryption in transit & at rest, on by default
- Least-privilege IAM; use IRSA on EKS
- Secrets in Secrets Manager / SSM, never in code
- Private networking + VPC endpoints
- Audit logging (CloudTrail) & regular access reviews

**Reliability & cost**

- Backups, snapshots & tested disaster recovery
- Spread across Availability Zones
- Autoscaling; Karpenter for just-in-time GPUs
- Consistent tagging for cost & ownership
- Budgets & anomaly alerts (FinOps)

-----

## 13. Automation Opportunities

Every task with an `[AUTO]` marker in [§2](#2-infrastructure-team-responsibilities--the-full-task-list) maps to a
concrete automation here. The goal: replace repetitive manual work with reviewed, self-running code so the team’s
time goes to harder problems.

|Opportunity              |Trigger → Mechanism                                |Payoff                                         |
|-------------------------|---------------------------------------------------|-----------------------------------------------|
|Golden AMI patching      |Weekly schedule → EC2 Image Builder → SNS          |Always-patched, tested images; no manual builds|
|Pipeline orchestration   |Schedule/event → Step Functions / MWAA             |Reliable ELT with retries & alerts             |
|Data-quality gates       |Post-load → Glue/Lambda checks → block + notify    |Bad data stopped before it spreads             |
|Catalog refresh          |New files → Glue crawler (scheduled)               |Query tools always see current tables          |
|Secret rotation          |Rotation schedule → Secrets Manager + Lambda       |Fresh credentials, zero manual effort          |
|Drift remediation        |Scheduled `plan` in CI → alert / auto-apply        |Reality stays matched to code                  |
|Backup & DR drills       |Schedule → snapshot + restore test → report        |Proven recovery, not just hoped-for            |
|Cost guardrails          |Budget threshold → SNS → ticket; rightsizing report|Surprises caught early                         |
|Image & config scanning  |On push → ECR scan / checkov → fail build          |Vulnerabilities blocked at the gate            |
|Self-service provisioning|Module registry + golden paths → PR template       |Teams provision safely without us in the loop  |
|Auto-remediation         |Alarm → EventBridge → Lambda fixes & notifies      |Common issues resolve before paging a human    |
|Log/metric onboarding    |New service → Observability Accelerator module     |Dashboards & alerts from day one               |


> **⚠ Guardrail for auto-remediation & AI agents:** automation may **read** freely and take **safe, reversible**
> actions (restart, scale, refresh). Anything that **changes production infrastructure** — especially
> `terraform apply` — needs a human approver. Give automation least-privilege, read-mostly roles by default.

-----

## 14. Glossary

|Term              |Meaning                                             |
|------------------|----------------------------------------------------|
|**ELT / ETL**     |Extract, Load, Transform (order varies).            |
|**Pipeline**      |Automated steps data flows through.                 |
|**Middleware**    |Software glue passing messages between systems.     |
|**Data lake**     |Cheap storage for raw files of any shape (S3).      |
|**Data warehouse**|Clean tables tuned for fast questions (Redshift).   |
|**CDC**           |Change-data-capture; streaming live DB changes.     |
|**DAG**           |The step-and-dependency graph of a pipeline.        |
|**Catalog**       |Table of contents for the lake (Glue).              |
|**Partition**     |Slicing data (e.g. by date) for speed & cost.       |
|**Fan-out**       |One message delivered to many subscribers.          |
|**DLQ**           |Dead-letter queue for repeatedly-failing messages.  |
|**Idempotent**    |Safe to run more than once.                         |
|**AMI**           |A reusable, pre-configured server disk image.       |
|**IRSA**          |Scoped AWS permissions for a Kubernetes app.        |
|**Drift**         |When real infrastructure no longer matches the code.|
|**Blast radius**  |How much can break if one thing goes wrong.         |

-----

## 15. References & Official Docs

|Topic                    |Resource                                                                                                                                                                                                                         |
|-------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|Terraform                |<https://developer.hashicorp.com/terraform/docs> · <https://registry.terraform.io/>                                                                                                                                              |
|Kafka (MSK)              |<https://docs.aws.amazon.com/msk/>                                                                                                                                                                                               |
|OpenSearch               |<https://docs.aws.amazon.com/opensearch-service/>                                                                                                                                                                                |
|Postgres (Aurora)        |<https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/>                                                                                                                                                                  |
|Glue (ELT)               |<https://docs.aws.amazon.com/glue/latest/dg/what-is-glue.html>                                                                                                                                                                   |
|DMS (ingest/CDC)         |<https://docs.aws.amazon.com/dms/latest/userguide/Welcome.html>                                                                                                                                                                  |
|Step Functions           |<https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html>                                                                                                                                                              |
|MWAA (Airflow)           |<https://docs.aws.amazon.com/mwaa/latest/userguide/what-is-mwaa.html>                                                                                                                                                            |
|Redshift                 |<https://docs.aws.amazon.com/redshift/latest/mgmt/welcome.html>                                                                                                                                                                  |
|Athena                   |<https://docs.aws.amazon.com/athena/latest/ug/what-is.html>                                                                                                                                                                      |
|Lake Formation           |<https://docs.aws.amazon.com/lake-formation/latest/dg/what-is-lake-formation.html>                                                                                                                                               |
|QuickSight               |<https://docs.aws.amazon.com/quicksight/latest/user/welcome.html>                                                                                                                                                                |
|SNS / SQS / EventBridge  |<https://docs.aws.amazon.com/sns/latest/dg/welcome.html> · <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html> · <https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-what-is.html>|
|Lambda                   |<https://docs.aws.amazon.com/lambda/latest/dg/welcome.html>                                                                                                                                                                      |
|EC2 Image Builder        |<https://docs.aws.amazon.com/imagebuilder/latest/userguide/what-is-image-builder.html>                                                                                                                                           |
|Observability Accelerator|<https://github.com/aws-observability/terraform-aws-observability-accelerator>                                                                                                                                                   |
|Data on EKS (Spark/NiFi) |<https://awslabs.github.io/data-on-eks/>                                                                                                                                                                                         |
|fastText / Ollama        |<https://fasttext.cc/> · <https://ollama.com/>                                                                                                                                                                                   |
|AWS Well-Architected     |<https://aws.amazon.com/architecture/well-architected/>                                                                                                                                                                          |

-----

*Cloud Infrastructure Team SOP · v2.0 · Primary Standard Operating Procedure · Pair with `cloud-automation-sop.md`. Review every 6 months.*