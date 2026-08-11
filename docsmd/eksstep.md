# Building a Multi-App EKS Auto Mode Platform with Terraform
### Kafka + Keycloak + an EC2 test box, with separate state per layer, and an onboarding path for NiFi and web apps

**Written for beginners.** Every idea is explained with a plain-English picture first, then the real commands and real code.

**Last verified:** August 2026. Versions used are the current ones as of this date (see the [Version Matrix](#version-matrix)).

---

## Table of Contents

1. [The Big Picture (read this first)](#1-the-big-picture)
2. [Background: What Every Piece Actually Is](#2-background-what-every-piece-actually-is)
3. [The Layer Design (and why separate state files matter)](#3-the-layer-design)
4. [PART A — The 45-Minute Quick Start (one working example)](#part-a--the-45-minute-quick-start)
5. [PART B — The Full Build, Layer by Layer](#part-b--the-full-build-layer-by-layer)
    - [Layer 00 — Bootstrap (the state bucket)](#layer-00--bootstrap)
    - [Layer 10 — Network (VPC)](#layer-10--network)
    - [Layer 15 — Toolbox EC2 (your test machine)](#layer-15--toolbox-ec2)
    - [Layer 20 — EKS Auto Mode Cluster](#layer-20--eks-auto-mode-cluster)
    - [Layer 30 — Platform (shared cluster plumbing)](#layer-30--platform)
    - [Layer 40 — Node Pools (one per app, independently updatable)](#layer-40--node-pools)
    - [Layer 50 — Apps: Kafka](#layer-50a--kafka-strimzi)
    - [Layer 50 — Apps: Keycloak](#layer-50b--keycloak)
6. [PART C — tfvars: One Codebase, Three Environments](#part-c--tfvars-one-codebase-three-environments)
7. [PART D — Onboarding Guide for New Apps (NiFi, web apps)](#part-d--onboarding-guide-for-new-apps)
8. [PART E — Day-2 Operations](#part-e--day-2-operations)
9. [PART F — Best Practices, Pros & Cons, Costs](#part-f--best-practices-pros--cons-costs)
10. [PART G — Troubleshooting](#part-g--troubleshooting)
11. [Appendix: Glossary, Cheat Sheet, Version Matrix](#appendix)

---

# 1. The Big Picture

## 1.1 The school analogy

Imagine you are building a **school**.

| Real thing | What it is in our school |
|---|---|
| **AWS** | The city where the school is built |
| **VPC** (network) | The land, the fence, and the roads |
| **EKS cluster** | The school itself — the principal's office plus classrooms |
| **EKS control plane** | The principal's office. It decides who goes where. AWS runs it for you. |
| **Auto Mode** | A magic staffing agency. When a new class needs a room and a teacher, it *automatically* rents the right-sized room and hires the teacher. When the class ends, it returns the room so you stop paying. |
| **Node** (EC2 machine) | One classroom |
| **NodePool** | A *rule* like "science classes must go in labs with sinks" |
| **Pod** | One class in session |
| **Kafka** | The school's mail conveyor belt. Anyone can drop a letter on the belt; anyone can read letters off the belt. Letters stay on the belt for a while so latecomers can still read them. |
| **Keycloak** | The front-desk ID office. It checks who you are and gives you a badge. Every other app just checks the badge. |
| **NiFi** | The mailroom sorter — takes mail from one place, reshapes it, moves it somewhere else |
| **Terraform** | The blueprint + the construction crew |
| **Terraform state file** | The crew's notebook: "we already built these 214 things" |
| **tfvars file** | The size sheet: "the *dev* school has 1 classroom; the *prod* school has 30" |
| **The toolbox EC2** | The caretaker's workshop on school grounds — a small machine that already has all the tools |

## 1.2 What you will have when you finish

```
                        Internet
                            |
                     [ ALB (auto-created) ]
                            |
+---------------------------|-----------------------------------+
|  VPC (10.0.0.0/16)        |                                    |
|                           v                                    |
|   +--------------------------------------------------------+   |
|   |          EKS CLUSTER  (Auto Mode = ON)                 |   |
|   |                                                        |   |
|   |  system pool     kafka pool      keycloak pool   apps  |   |
|   |  (built-in)      (custom)        (custom)        pool  |   |
|   |  +--------+      +---------+     +----------+   +----+ |   |
|   |  | core   |      | broker  |     | keycloak |   |nifi| |   |
|   |  | dns    |      | broker  |     | keycloak |   |web | |   |
|   |  | etc    |      | broker  |     |          |   |    | |   |
|   |  +--------+      +---------+     +----------+   +----+ |   |
|   +--------------------------------------------------------+   |
|                                                                |
|   [ Toolbox EC2 ]  <- you connect here to run terraform/kubectl |
|   [ RDS Postgres ] <- Keycloak's database                       |
+----------------------------------------------------------------+

State in S3:
  s3://acme-tfstate-dev-<acct>/dev/10-network/terraform.tfstate
  s3://acme-tfstate-dev-<acct>/dev/20-cluster/terraform.tfstate
  s3://acme-tfstate-dev-<acct>/dev/40-nodepool-kafka/terraform.tfstate
  ... one small notebook per layer, per environment
```

## 1.3 The one rule that shapes everything

> **If two things need to change on different schedules, they get different state files.**

The Kafka team wants to change Kafka's machine sizes on Tuesday. The web team wants to change theirs on Thursday. If both live in one giant state file, every change makes Terraform re-plan the *entire* platform, and one person's `terraform apply` can block or break the other's. Splitting them means the Kafka team runs `terraform apply` in **one small folder** that touches **only Kafka's node pool**.

---

# 2. Background: What Every Piece Actually Is

## 2.1 Kubernetes and EKS in 90 seconds

**Kubernetes (K8s)** is software that runs *containers* (packaged applications) on a fleet of machines. You tell it *what* you want ("I want 3 copies of my web app, each with 1 CPU"), and it figures out *where* to put them.

Kubernetes has two halves:

- **Control plane** — the brain. Stores desired state, schedules work.
- **Data plane** — the muscles. The actual EC2 machines (called **nodes**) that run your containers.

**Amazon EKS** is AWS running the control plane for you. Historically *you* still had to manage the data plane: pick instance types, patch operating systems, install an autoscaler, install a CSI storage driver, install a load balancer controller, install CoreDNS... a long shopping list.

## 2.2 What EKS Auto Mode changes

**EKS Auto Mode** (launched Dec 2024, now the default recommendation for new clusters) moves the data plane to AWS too.

With Auto Mode ON, AWS manages, inside your cluster:

- **Compute** — provisioning and scaling EC2 nodes on demand (this is Karpenter, built into the control plane)
- **Pod networking + service networking + cluster DNS**
- **Block storage** (an EBS CSI driver)
- **Load balancing** (an ALB/NLB controller)
- **Pod Identity agent** (how pods get IAM permissions)
- **Node monitoring agent**
- **Node OS patching** — AWS publishes new node images roughly weekly with security fixes

Two Auto Mode behaviours you must design around:

1. **Nodes are disposable.** Auto Mode nodes have a **maximum lifetime of 21 days** by default, and Auto Mode will replace or consolidate nodes whenever it can save money. Your app *must* survive a node disappearing. (This is why our Kafka setup uses 3 brokers and PodDisruptionBudgets.)
2. **You cannot SSH into nodes.** Nodes are locked down and immutable. Debug with `kubectl debug` and CloudWatch instead.

### Auto Mode vs. the alternatives

| Option | Pros | Cons | Best for |
|---|---|---|---|
| **EKS Auto Mode** | Least to manage; AWS patches nodes; autoscaling, storage, LB, DNS included; fast to stand up | ~12% management fee on top of EC2 cost; no SSH to nodes; can't run custom AMIs or arbitrary DaemonSets that need host access; less knob-twiddling | Most teams, especially small platform teams (**our choice**) |
| **Managed Node Groups** | Cheapest per node; full control of AMI; SSH possible | You install/patch/upgrade autoscaler, CSI, LB controller yourself; slower scaling | Teams with strict AMI/compliance requirements |
| **Self-managed Karpenter** | Most flexible scheduling; no management fee | You own Karpenter upgrades, IAM, NodePools, failure modes | Large teams with dedicated platform engineers |
| **Fargate** | No nodes at all | No DaemonSets, no privileged pods, limited storage, pricier per pod | Simple stateless microservices |

> **Cost note:** the Auto Mode management fee is roughly **12% on top of the EC2 instance price** (it varies by instance family — always check the current EKS pricing page). A `m7g.large` at ~$0.0816/hr becomes ~$0.091/hr. For a small platform this is usually far cheaper than the engineer-hours it replaces.

## 2.3 Terraform in 90 seconds

Terraform reads `.tf` files that *describe* infrastructure, compares them to a **state file** (a JSON record of what it already built), and makes the minimum changes needed.

```
your .tf files  ──┐
                  ├──> terraform plan ──> "I will add 3, change 1, destroy 0"
state file      ──┘
```

Three commands matter:

| Command | What it does | Analogy |
|---|---|---|
| `terraform init` | Downloads plugins, connects to the state file | Open the notebook, get your tools |
| `terraform plan` | Shows what *would* change | Sketch the change on paper first |
| `terraform apply` | Actually makes the change | Build it |

**State locking:** if two people run `apply` at once, they can corrupt state. Terraform prevents this with a lock. Modern Terraform (**1.10+ experimental, 1.11+ GA**) does this natively in S3 with `use_lockfile = true` — a tiny `.tflock` object written next to the state using an S3 conditional write. **The old DynamoDB lock table (`dynamodb_table`) is now deprecated.** If a tutorial tells you to create a DynamoDB table, it predates Terraform 1.10.

## 2.4 Kafka in 90 seconds

**Kafka** is a durable, ordered message log.

```
Producer app  --> [ topic: "orders" ] --> Consumer app A (billing)
                   partition 0: [m1][m2][m3][m4]
                   partition 1: [m5][m6][m7]      --> Consumer app B (analytics)
```

- A **topic** is a named conveyor belt (e.g. `orders`).
- A topic is split into **partitions** so many machines can work in parallel.
- Messages are **kept for a set time** (e.g. 7 days), not deleted on read. That's the superpower: new consumers can replay history.
- A **broker** is one Kafka server. We run 3 for safety.
- Modern Kafka (4.x) uses **KRaft** — Kafka manages its own metadata. **ZooKeeper is gone.** Any guide mentioning ZooKeeper is out of date.

We run Kafka via the **Strimzi operator**. An "operator" is a program inside the cluster that knows how to run a specific piece of software. You write a short YAML file saying "I want a 3-broker Kafka"; Strimzi creates the StatefulSets, storage, certificates, and handles rolling upgrades.

### Kafka on Kubernetes vs. Amazon MSK

| | Strimzi on EKS (our choice) | Amazon MSK / MSK Serverless |
|---|---|---|
| **Pros** | Runs on the node pool you control; same tooling as everything else; no per-broker AWS bill; full Kafka feature access; portable to any K8s | Fully managed; AWS patches brokers; no K8s storage worries; easy multi-AZ |
| **Cons** | You own upgrades, storage sizing, and disaster recovery; stateful workloads on disposable nodes take care | Costs more; less control; runs outside the cluster so you manage a second network/security model |
| **Pick this when** | You already run K8s and want one operating model | Kafka is critical and you have no K8s storage expertise |

## 2.5 Keycloak in 90 seconds

**Keycloak** is an open-source identity server. It implements OpenID Connect / OAuth2 / SAML.

```
User --> Web App --> "who are you?" --> Keycloak login page
                                            |
User logs in once  <----- token ------------+
                     |
Same token works for NiFi, Grafana, the admin console...  (Single Sign-On)
```

Keycloak needs a **real database** in production — we use Amazon RDS PostgreSQL. Running Keycloak with its dev in-memory database is fine for a laptop and a disaster in prod.

## 2.6 Why an EC2 "toolbox"

You asked for an EC2 to test Terraform. This is a genuinely good pattern, and here's why:

1. **Private cluster access.** Best practice is a private EKS API endpoint. A machine *inside* the VPC can reach it; your laptop can't.
2. **Identical tool versions.** No more "works on my machine" because Priya has Terraform 1.9 and Sam has 1.13.
3. **IAM roles instead of long-lived keys.** The EC2 instance assumes a role. No access keys on laptops.
4. **A safe rehearsal space.** Run `terraform plan` against dev from a box that only has dev permissions.

We connect with **AWS Systems Manager Session Manager** — no SSH keys, no port 22 open, no bastion in a public subnet. Every session is logged.

---

# 3. The Layer Design

## 3.1 The layers

Each box below is **its own folder, its own state file, its own `terraform apply`.**

| # | Layer | What it owns | Changes how often | Blast radius if broken |
|---|---|---|---|---|
| 00 | `bootstrap` | S3 state bucket | Once a year | Everything (but it's tiny and simple) |
| 10 | `network` | VPC, subnets, NAT, endpoints | Rarely | High |
| 15 | `toolbox` | Test/admin EC2 + its IAM role | Sometimes | None |
| 20 | `cluster` | EKS control plane, Auto Mode on, access entries | Quarterly (K8s upgrades) | High |
| 30 | `platform` | StorageClass, IngressClass, namespaces, operators (Strimzi, Keycloak) | Monthly | Medium |
| 40 | `nodepool-kafka` | Kafka's NodeClass + NodePool | **Whenever Kafka team wants** | Only Kafka |
| 40 | `nodepool-keycloak` | Keycloak's NodeClass + NodePool | Whenever the IAM team wants | Only Keycloak |
| 40 | `nodepool-apps` | Shared general app pool (NiFi, web apps) | Whenever | Only those apps |
| 50 | `app-kafka` | Kafka cluster CR, topics, users | Weekly | Only Kafka |
| 50 | `app-keycloak` | RDS, Keycloak CR, realm, Ingress | Weekly | Only Keycloak |

Dependencies flow **downhill only** — a layer may read from layers above it, never below:

```
00 bootstrap
     |
10 network ─────────┬──────────────┐
     |              |              |
15 toolbox      20 cluster         |
     |              |              |
     └──> (role) ───┘              |
                    |              |
                30 platform <──────┘
                    |
        ┌───────────┼────────────┐
   40 np-kafka  40 np-keycloak  40 np-apps
        |           |            |
   50 kafka    50 keycloak   50 nifi / 50 webapp
```

## 3.2 How layers talk to each other

**Option A — `terraform_remote_state` (what we use).** A lower layer reads the upper layer's state file directly.

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/10-network/terraform.tfstate"
    region = var.region
  }
}

# then use it:
subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
```

- **Pros:** simple, no extra services, type-safe-ish, fails loudly if the upstream layer doesn't exist yet.
- **Cons:** the reader needs S3 read access to the *whole* upstream state (which may contain secrets); it couples you to that layer's output names.

**Option B — SSM Parameter Store.** Upper layer *writes* `/platform/dev/vpc_id`, lower layer *reads* it.

- **Pros:** no access to raw state; works even if the upstream is not Terraform; easy to inspect (`aws ssm get-parameter`).
- **Cons:** more moving parts; values can go stale silently; no automatic dependency error.

**Option C — data sources / tag lookups.** `data "aws_vpc" { tags = { Name = "dev-platform" } }`.

- **Pros:** zero coupling to Terraform at all.
- **Cons:** silently picks the wrong thing if tags are inconsistent. Requires tagging discipline.

> **Best practice:** use `terraform_remote_state` for infrastructure IDs (VPC, subnets, cluster name), and **never put secrets in outputs**. Put secrets in AWS Secrets Manager and read them by name.

## 3.3 Repository layout

```
platform-infra/
├── modules/                        # reusable building blocks (no state of their own)
│   ├── app-nodepool/               # <-- the magic module for onboarding new apps
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── app-namespace/
│
├── layers/
│   ├── 00-bootstrap/
│   │   ├── main.tf
│   │   └── envs/{dev,stage,prod}.tfvars
│   ├── 10-network/
│   │   ├── main.tf  variables.tf  outputs.tf  backend.tf  versions.tf
│   │   └── envs/
│   │       ├── dev.tfvars       dev.s3.tfbackend
│   │       ├── stage.tfvars     stage.s3.tfbackend
│   │       └── prod.tfvars      prod.s3.tfbackend
│   ├── 15-toolbox/
│   ├── 20-cluster/
│   ├── 30-platform/
│   ├── 40-nodepool-kafka/
│   ├── 40-nodepool-keycloak/
│   ├── 40-nodepool-apps/
│   ├── 50-app-kafka/
│   └── 50-app-keycloak/
│
├── scripts/
│   └── tf.sh                       # tiny wrapper so nobody forgets a flag
└── README.md
```

---

# PART A — The 45-Minute Quick Start

**Goal:** by the end of this part you will have a running EKS Auto Mode cluster in `dev`, with its state in S3, and a "hello world" pod running on a node that Auto Mode created for you. This is the smallest complete example. Parts B onward add Kafka, Keycloak, node pools, and onboarding.

## A.0 Prerequisites

Install on your laptop (or skip straight to the toolbox EC2 in Layer 15):

```bash
terraform -version     # need >= 1.11 (for use_lockfile GA)
aws --version          # AWS CLI v2
kubectl version --client
helm version            # optional but handy
```

Configure AWS credentials and confirm you are in the right account:

```bash
aws sts get-caller-identity
```

You should see your account ID. **Write it down.**

## A.1 Step 1 — Create the state bucket (Layer 00)

This is the chicken-and-egg layer: it creates the S3 bucket where *every other layer* stores its state, so it can't store its state there itself. It uses **local state**, and you commit that state file to git. It's tiny and only changes once a year.

```bash
mkdir -p platform-infra/layers/00-bootstrap && cd platform-infra/layers/00-bootstrap
```

`main.tf`:

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # NOTE: local state on purpose. Commit terraform.tfstate for this layer only.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Layer     = "00-bootstrap"
      Env       = var.env
    }
  }
}

variable "region" { type = string }
variable "env"    { type = string }
variable "org"    { type = string }

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.org}-tfstate-${var.env}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Safety net: you really do not want to lose this bucket.
  lifecycle { prevent_destroy = true }
}

# Versioning is MANDATORY for S3 native locking and for recovering a bad apply.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Keep old versions for 90 days, then clean up so the bucket doesn't grow forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# Refuse any request that isn't TLS.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

output "state_bucket" { value = aws_s3_bucket.state.id }
```

`envs/dev.tfvars`:

```hcl
region = "us-east-1"
env    = "dev"
org    = "acme"
```

Run it:

```bash
terraform init
terraform apply -var-file=envs/dev.tfvars
terraform output state_bucket
# acme-tfstate-dev-123456789012
```

> **Why no DynamoDB table?** Terraform 1.10 added S3-native locking (`use_lockfile`), and 1.11 made it GA and deprecated `dynamodb_table`. S3 does a *conditional write* to create a `.tflock` object — if it already exists you get a `412 PreconditionFailed` and Terraform tells you who holds the lock. One less resource, one less bill, one less IAM policy.

**Best practice:** in a real company you'd have **three AWS accounts** (dev / stage / prod) and run this bootstrap once per account. Blast radius stops at the account boundary. If you're on one account for now, that's fine — the bucket name includes the env, so keys never collide.

## A.2 Step 2 — The network (Layer 10)

```bash
mkdir -p ../10-network/envs && cd ../10-network
```

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy = "terraform"
      Layer     = "10-network"
      Env       = var.env
    }
  }
}
```

`backend.tf` — notice it is **almost empty**. Backends cannot use variables, so we leave the values out and pass them at `init` time. This is called **partial backend configuration**, and it is the standard way to point one codebase at three environments.

```hcl
terraform {
  backend "s3" {
    # bucket, key, region come from -backend-config=envs/<env>.s3.tfbackend
    encrypt      = true
    use_lockfile = true
  }
}
```

`envs/dev.s3.tfbackend`:

```hcl
bucket = "acme-tfstate-dev-123456789012"
key    = "dev/10-network/terraform.tfstate"
region = "us-east-1"
```

`variables.tf`:

```hcl
variable "region"          { type = string }
variable "env"             { type = string }
variable "org"             { type = string }
variable "vpc_cidr"        { type = string }
variable "az_count"        { type = number, default = 3 }
variable "single_nat_gateway" {
  type        = bool
  default     = false
  description = "true = one NAT (cheap, dev). false = one NAT per AZ (resilient, prod)."
}
variable "enable_flow_logs" { type = bool, default = false }
```

> Small Terraform note: `variable "x" { type = number, default = 3 }` on one line is shown here for compactness. In real files write it across multiple lines — Terraform accepts both, but multi-line is the convention.

`main.tf`:

```hcl
locals {
  name = "${var.org}-${var.env}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private subnets (4091 usable IPs each) - pods take IPs too, so be generous.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 200)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_flow_log                      = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role  = var.enable_flow_logs

  # THESE TAGS ARE NOT OPTIONAL.
  # The Auto Mode load balancer controller finds subnets by these tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

output "vpc_id"             { value = module.vpc.vpc_id }
output "vpc_cidr"           { value = module.vpc.vpc_cidr_block }
output "private_subnet_ids" { value = module.vpc.private_subnets }
output "public_subnet_ids"  { value = module.vpc.public_subnets }
output "azs"                { value = local.azs }
```

`envs/dev.tfvars`:

```hcl
region             = "us-east-1"
env                = "dev"
org                = "acme"
vpc_cidr           = "10.10.0.0/16"
az_count           = 2
single_nat_gateway = true    # dev saves ~$65/month with one NAT
enable_flow_logs   = false
```

Run:

```bash
terraform init -backend-config=envs/dev.s3.tfbackend
terraform apply -var-file=envs/dev.tfvars
```

**~3 minutes.** You now have a VPC.

> **Why tag subnets?** Auto Mode's load balancer controller scans your subnets and needs to know which ones are OK for internet-facing load balancers (`kubernetes.io/role/elb`) and which for internal ones (`kubernetes.io/role/internal-elb`). Miss these tags and your Ingress will sit forever with no address — one of the top-3 most common Auto Mode support cases.

## A.3 Step 3 — The cluster (Layer 20)

```bash
mkdir -p ../20-cluster/envs && cd ../20-cluster
```

`backend.tf` is identical to Layer 10's (partial config). `envs/dev.s3.tfbackend` differs only in the key:

```hcl
bucket = "acme-tfstate-dev-123456789012"
key    = "dev/20-cluster/terraform.tfstate"
region = "us-east-1"
```

`main.tf`:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/10-network/terraform.tfstate"
    region = var.region
  }
}

locals {
  cluster_name = "${var.org}-${var.env}"
  net          = data.terraform_remote_state.network.outputs
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.net.vpc_id
  subnet_ids = local.net.private_subnet_ids

  # ---- THIS IS AUTO MODE ----
  compute_config = {
    enabled    = true
    node_pools = var.builtin_node_pools   # ["general-purpose","system"]
  }
  # Also create the node IAM role that our CUSTOM NodeClasses (Layer 40) will reuse.
  create_auto_mode_iam_resources = true

  # API access
  endpoint_public_access       = var.endpoint_public_access
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Whoever runs terraform becomes a cluster admin.
  enable_cluster_creator_admin_permissions = true

  # Everyone else gets in via access entries - NOT the old aws-auth ConfigMap.
  access_entries = var.access_entries

  # Control plane logs -> CloudWatch
  enabled_log_types = var.enabled_log_types

  tags = {
    Env   = var.env
    Layer = "20-cluster"
  }
}

output "cluster_name"       { value = module.eks.cluster_name }
output "cluster_endpoint"   { value = module.eks.cluster_endpoint }
output "cluster_arn"        { value = module.eks.cluster_arn }
output "cluster_ca_data"    { value = module.eks.cluster_certificate_authority_data }
output "cluster_version"    { value = module.eks.cluster_version }
output "node_iam_role_arn"  { value = module.eks.node_iam_role_arn }
output "node_iam_role_name" { value = module.eks.node_iam_role_name }
output "cluster_security_group_id" { value = module.eks.cluster_primary_security_group_id }
```

> **Version drift warning:** module output names occasionally change between major versions. After `apply`, run `terraform output` and confirm these names exist for the module version you pinned. If `node_iam_role_arn` isn't there, check the module's `outputs.tf` on GitHub for the tag you pinned.

`variables.tf`:

```hcl
variable "region"       { type = string }
variable "env"          { type = string }
variable "org"          { type = string }
variable "state_bucket" { type = string }

variable "kubernetes_version" {
  type        = string
  description = "Stay ONE minor behind the newest EKS release in prod."
}

variable "builtin_node_pools" {
  type        = list(string)
  default     = ["general-purpose", "system"]
  description = "Auto Mode's built-in pools. 'system' hosts CoreDNS etc."
}

variable "endpoint_public_access"       { type = bool, default = false }
variable "endpoint_public_access_cidrs" { type = list(string), default = [] }

variable "enabled_log_types" {
  type    = list(string)
  default = ["api", "audit", "authenticator"]
}

variable "access_entries" {
  type        = any
  default     = {}
  description = "Map of IAM principals -> cluster permissions"
}
```

`envs/dev.tfvars`:

```hcl
region             = "us-east-1"
env                = "dev"
org                = "acme"
state_bucket       = "acme-tfstate-dev-123456789012"
kubernetes_version = "1.34"

builtin_node_pools = ["general-purpose", "system"]

# DEV ONLY: public endpoint locked to the office IP so laptops can reach it.
endpoint_public_access       = true
endpoint_public_access_cidrs = ["203.0.113.10/32"]

enabled_log_types = ["api", "audit"]
```

Run:

```bash
terraform init -backend-config=envs/dev.s3.tfbackend
terraform apply -var-file=envs/dev.tfvars
```

**~12 minutes.** Go get a drink.

### Connect to it

```bash
aws eks update-kubeconfig --region us-east-1 --name acme-dev
kubectl get nodes
# No resources found      <-- THIS IS CORRECT AND EXPECTED
```

**Zero nodes is the right answer.** Auto Mode only creates nodes when there is a pod that needs one. This is the single biggest "wait, is it broken?" moment for newcomers. It's not broken — it's the whole point.

```bash
kubectl get nodepools
# NAME              NODECLASS   NODES   READY   AGE
# general-purpose   default     0       True    2m
# system            default     0       True    2m
```

## A.4 Step 4 — Prove it works

Ask for a pod and watch a machine appear out of thin air.

```bash
kubectl create deployment hello --image=public.ecr.aws/nginx/nginx:latest --replicas=2
kubectl get pods -w
# hello-...  Pending    <-- no node yet
# ... about 45-90 seconds ...
# hello-...  Running

kubectl get nodes
# NAME                  STATUS   ROLES    AGE   VERSION
# i-0abc...             Ready    <none>   40s   v1.34.x
```

Auto Mode saw a Pending pod, picked an instance type that fits, launched it, joined it to the cluster, and scheduled your pod. You wrote zero autoscaler config.

Now delete it and watch the node go away (takes a few minutes as consolidation kicks in):

```bash
kubectl delete deployment hello
```

**That's the quick start.** You have a real cluster with remote, locked state. Everything after this is adding capability on top.

---

# PART B — The Full Build, Layer by Layer

Part A built layers 00, 10 and 20. Now we add the rest.

---

## Layer 15 — Toolbox EC2

**What it is:** a small Amazon Linux 2023 EC2 instance in a private subnet, with Terraform, kubectl, Helm and the AWS CLI pre-installed, reachable only through AWS Systems Manager Session Manager (no SSH, no public IP, no open ports).

**Why:** private cluster access, identical tool versions for everyone, IAM-role credentials instead of access keys, and a safe place to rehearse `terraform plan`.

`layers/15-toolbox/main.tf`:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/10-network/terraform.tfstate"
    region = var.region
  }
}

locals {
  name = "${var.org}-${var.env}-toolbox"
  net  = data.terraform_remote_state.network.outputs
}

# Always get the current AL2023 image instead of hardcoding an AMI ID.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------- IAM ----------
resource "aws_iam_role" "toolbox" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets Session Manager connect. No SSH keys anywhere.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.toolbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read/write the Terraform state bucket (including the .tflock object).
resource "aws_iam_role_policy" "tfstate" {
  name = "${local.name}-tfstate"
  role = aws_iam_role.toolbox.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = "arn:aws:s3:::${var.state_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::${var.state_bucket}/${var.env}/*"
      }
    ]
  })
}

# What the box may do to AWS. In dev this is broad; in prod, narrow it.
resource "aws_iam_role_policy_attachment" "infra" {
  role       = aws_iam_role.toolbox.name
  policy_arn = var.infra_policy_arn   # e.g. PowerUserAccess in dev, custom in prod
}

resource "aws_iam_instance_profile" "toolbox" {
  name = local.name
  role = aws_iam_role.toolbox.name
}

# ---------- Network ----------
resource "aws_security_group" "toolbox" {
  name        = local.name
  description = "Toolbox EC2 - egress only"
  vpc_id      = local.net.vpc_id

  egress {
    description = "All outbound (needs internet for terraform providers, ECR, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # NO ingress rules at all. Session Manager works outbound-only.
}

# ---------- The instance ----------
resource "aws_instance" "toolbox" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.net.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.toolbox.id]
  iam_instance_profile   = aws_iam_instance_profile.toolbox.name

  metadata_options {
    http_tokens                 = "required"   # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf -y update
    dnf -y install git jq unzip dnf-plugins-core

    # Terraform from the official HashiCorp repo
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    dnf -y install terraform

    # kubectl - 'stable.txt' always points at the newest release
    KVER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
    curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/$KVER/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl

    # Helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    # Convenience for the default ssm-user
    cat >/etc/profile.d/platform.sh <<'PROFILE'
    export AWS_REGION=${var.region}
    export ENV=${var.env}
    alias k=kubectl
    PROFILE

    echo "toolbox ready" > /var/log/toolbox-ready
  EOT

  tags = { Name = local.name }
}

output "toolbox_role_arn"    { value = aws_iam_role.toolbox.arn }
output "toolbox_instance_id" { value = aws_instance.toolbox.id }
```

`envs/dev.tfvars`:

```hcl
region            = "us-east-1"
env               = "dev"
org               = "acme"
state_bucket      = "acme-tfstate-dev-123456789012"
instance_type     = "t3.small"
root_volume_gb    = 30
infra_policy_arn  = "arn:aws:iam::aws:policy/PowerUserAccess"
```

Apply, then connect:

```bash
terraform init -backend-config=envs/dev.s3.tfbackend
terraform apply -var-file=envs/dev.tfvars

aws ssm start-session --target $(terraform output -raw toolbox_instance_id)
# you're in. no SSH key, no bastion, no port 22.
```

### Wire the toolbox into the cluster (edit Layer 20)

The toolbox has an IAM role, but the cluster doesn't know it yet. Add to `20-cluster/main.tf`:

```hcl
data "terraform_remote_state" "toolbox" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/15-toolbox/terraform.tfstate"
    region = var.region
  }
}
```

and in `envs/dev.tfvars` — or better, computed in `main.tf` so you don't paste ARNs:

```hcl
locals {
  toolbox_access_entry = {
    toolbox = {
      principal_arn = data.terraform_remote_state.toolbox.outputs.toolbox_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

module "eks" {
  # ...
  access_entries = merge(local.toolbox_access_entry, var.access_entries)
}
```

Then re-apply Layer 20 and test from the toolbox:

```bash
aws eks update-kubeconfig --region us-east-1 --name acme-dev
kubectl get nodepools
```

> **Access entries, not aws-auth.** EKS used to control access through a `aws-auth` ConfigMap that was famously easy to lock yourself out of. Access entries are a real AWS API — they can be managed by Terraform, audited by CloudTrail, and scoped per-namespace. The EKS Terraform module **v21 removed the aws-auth submodule entirely.** Use access entries.

### Common access-policy ARNs

| Policy | Who gets it |
|---|---|
| `AmazonEKSClusterAdminPolicy` | Platform team, CI, toolbox |
| `AmazonEKSAdminPolicy` | Team leads (scoped to namespaces) |
| `AmazonEKSEditPolicy` | Developers (scoped to their namespace) |
| `AmazonEKSViewPolicy` | Support / on-call read-only |

Namespace-scoped example:

```hcl
access_entries = {
  nifi_team = {
    principal_arn = "arn:aws:iam::123456789012:role/nifi-developers"
    policy_associations = {
      edit = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
        access_scope = {
          type       = "namespace"
          namespaces = ["nifi"]
        }
      }
    }
  }
}
```

---

## Layer 30 — Platform

**What it is:** the shared plumbing that every app needs but no single app owns.

This layer creates:
1. A **StorageClass** — Auto Mode does *not* create one for you
2. An **IngressClass + IngressClassParams** — so apps can just say `ingressClassName: alb`
3. **Operators** — Strimzi (for Kafka) and Keycloak
4. Optionally: cert-manager, external-dns, metrics-server

### Providers for Kubernetes layers

Every layer from 30 down needs to talk to Kubernetes. Use the `exec` auth plugin so the token is fetched fresh at runtime — never store a token in state.

`layers/30-platform/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.11"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.0" }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/20-cluster/terraform.tfstate"
    region = var.region
  }
}

locals { c = data.terraform_remote_state.cluster.outputs }

provider "aws" { region = var.region }

provider "kubernetes" {
  host                   = local.c.cluster_endpoint
  cluster_ca_certificate = base64decode(local.c.cluster_ca_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.c.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.c.cluster_endpoint
    cluster_ca_certificate = base64decode(local.c.cluster_ca_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.c.cluster_name, "--region", var.region]
    }
  }
}
```

> **Helm provider v3 note:** the `kubernetes` block changed from a repeated block to an attribute (`kubernetes = { ... }`) in v3. If you copy a v2 example you'll get a confusing error. Pin the version and match the syntax.

### 30.1 StorageClass — the one everyone forgets

```hcl
resource "kubernetes_storage_class_v1" "auto_ebs" {
  metadata {
    name = "auto-ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # THE KEY LINE. Auto Mode uses its own provisioner, NOT ebs.csi.aws.com
  storage_provisioner = "ebs.csi.eks.amazonaws.com"

  # Don't create the disk until a pod is actually scheduled, so the disk
  # lands in the same AZ as the pod. Getting this wrong = pods stuck Pending.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"   # use "Retain" in prod for Kafka

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  allowed_topologies {
    match_label_expressions {
      key    = "eks.amazonaws.com/compute-type"
      values = ["auto"]
    }
  }
}
```

> **Read this twice:** the classic EBS CSI driver is `ebs.csi.aws.com`. Auto Mode's is `ebs.csi.eks.amazonaws.com`. They are different drivers and volumes are **not** interchangeable — migrating between them requires volume snapshots. If your pods are stuck `Pending` with "waiting for a volume to be created", this is almost always why.

A second class for Kafka, with `Retain` so a deleted PVC doesn't delete your data:

```hcl
resource "kubernetes_storage_class_v1" "kafka_retain" {
  metadata { name = "kafka-gp3-retain" }
  storage_provisioner    = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Retain"
  parameters = {
    type       = "gp3"
    encrypted  = "true"
    iops       = "5000"
    throughput = "500"
  }
  allowed_topologies {
    match_label_expressions {
      key    = "eks.amazonaws.com/compute-type"
      values = ["auto"]
    }
  }
}
```

### 30.2 IngressClass — how apps get a load balancer

```hcl
# AWS-specific ALB settings live in a CRD that Auto Mode installs for you.
resource "kubernetes_manifest" "ingressclassparams_alb" {
  manifest = {
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "IngressClassParams"
    metadata   = { name = "alb" }
    spec = {
      scheme = var.alb_scheme        # "internet-facing" or "internal"
      group  = { name = "${var.env}-shared" }   # <-- ALB SHARING. See note below.
    }
  }
}

resource "kubernetes_ingress_class_v1" "alb" {
  metadata {
    name = "alb"
    annotations = {
      "ingressclass.kubernetes.io/is-default-class" = "true"
    }
  }
  spec {
    controller = "eks.amazonaws.com/alb"
    parameters {
      api_group = "eks.amazonaws.com"
      kind      = "IngressClassParams"
      name      = "alb"
    }
  }
  depends_on = [kubernetes_manifest.ingressclassparams_alb]
}
```

> **Money-saving tip:** the `group.name` field makes every Ingress that uses this class **share one ALB** instead of creating its own. An ALB costs roughly $16–22/month plus data processing. Ten apps with ten ALBs is real money; ten apps on one shared ALB is one bill. Use one shared group per environment for internal apps, and dedicated ALBs only where you need isolation.
>
> **Auto Mode gotcha:** with Auto Mode, ALB configuration through `alb.ingress.kubernetes.io/*` annotations is **not** supported the way it is with the standalone AWS Load Balancer Controller. Configuration goes in `IngressClassParams`. If you need two different ALB configurations, create two IngressClass/IngressClassParams pairs (e.g. `alb-public` and `alb-internal`).

### 30.3 Namespaces

```hcl
resource "kubernetes_namespace_v1" "app" {
  for_each = toset(var.namespaces)   # ["kafka","keycloak","nifi","web"]
  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/managed-by"    = "terraform"
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}
```

### 30.4 The Strimzi operator (for Kafka)

```hcl
resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = var.strimzi_version      # e.g. "1.1.0"
  namespace  = "kafka"
  create_namespace = false              # Layer 30 already made it

  # Watch only the namespaces we list, not the whole cluster.
  set = [
    {
      name  = "watchNamespaces[0]"
      value = "kafka"
    },
    {
      name  = "resources.requests.memory"
      value = "256Mi"
    }
  ]

  depends_on = [kubernetes_namespace_v1.app]
}
```

> **CRD upgrade warning:** Strimzi ships Custom Resource Definitions with the chart. Helm will install CRDs on first install but **does not upgrade them on `helm upgrade`** in all cases. Before bumping a Strimzi major version, read the release notes and follow the CRD upgrade instructions — Strimzi 1.0 removed the old `v1beta2` API entirely in favour of `kafka.strimzi.io/v1`. Never skip this step.

### 30.5 The Keycloak operator

Keycloak ships its operator as plain manifests rather than a first-party Helm chart. Terraform's `kubernetes_manifest` needs each document declared individually, which is painful for a 2000-line bundle. The pragmatic, widely-used approach is a controlled escape hatch:

```hcl
locals {
  kc_base = "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${var.keycloak_version}/kubernetes"
}

resource "terraform_data" "keycloak_operator" {
  # Re-runs ONLY when the version changes, not on every apply.
  triggers_replace = [var.keycloak_version, local.c.cluster_name]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --region ${var.region} --name ${local.c.cluster_name}
      kubectl apply -n keycloak -f ${local.kc_base}/keycloaks.k8s.keycloak.org-v1.yml
      kubectl apply -n keycloak -f ${local.kc_base}/keycloakrealmimports.k8s.keycloak.org-v1.yml
      kubectl apply -n keycloak -f ${local.kc_base}/kubernetes.yml
    EOT
  }

  depends_on = [kubernetes_namespace_v1.app]
}
```

**Pros and cons of the escape hatch:**

| | `local-exec` + kubectl | `kubernetes_manifest` per document | Community Helm chart |
|---|---|---|---|
| Pros | Works with any upstream bundle; trivial to update | Real Terraform state, real diffs, real destroy | Clean lifecycle, values file |
| Cons | Not in state — Terraform can't show a diff or destroy it; needs kubectl on the runner | Must split the YAML yourself; requires cluster reachable at *plan* time | Chart may lag upstream releases |

If you want everything in state, the `alekc/kubectl` provider (the maintained fork of the older `gavinbunney/kubectl`) gives you `kubectl_file_documents` to split a multi-doc YAML automatically:

```hcl
data "http" "kc_operator" { url = "${local.kc_base}/kubernetes.yml" }

data "kubectl_file_documents" "kc" { content = data.http.kc_operator.response_body }

resource "kubectl_manifest" "kc" {
  for_each          = data.kubectl_file_documents.kc.manifests
  yaml_body         = each.value
  override_namespace = "keycloak"
}
```

Pick one and be consistent. Mixing them across layers is how teams end up confused about who owns what.


---

## Layer 40 — Node Pools

This is the heart of your request: **each app gets its own node pool, in its own state file, so it can be updated independently.**

### 40.1 What NodeClass and NodePool actually mean

Two objects, two jobs:

| Object | API | Answers the question | Analogy |
|---|---|---|---|
| **NodeClass** | `eks.amazonaws.com/v1` | *How is the machine built?* Which subnets, which security groups, which IAM role, how big the disk | The classroom's construction spec: wiring, plumbing, door locks |
| **NodePool** | `karpenter.sh/v1` | *What machines are allowed, and who may sit in them?* Instance families, spot vs on-demand, CPU ceiling, labels, taints | The scheduling rule: "science classes go in rooms with sinks, max 8 rooms" |

> **Critical:** EKS Auto Mode uses **its own** `NodeClass` (`eks.amazonaws.com/v1`), **not** open-source Karpenter's `EC2NodeClass`. Copying an `EC2NodeClass` from a blog post will fail. The `NodePool` object *is* the same as Karpenter's, which is why Karpenter's NodePool docs are still useful reading.

### 40.2 Taints and tolerations — the velvet rope

A **taint** on a node says "you may not sit here unless you have a pass." A **toleration** on a pod is the pass.

```
kafka NodePool  --taint-->  dedicated=kafka:NoSchedule
                                  ^
Kafka pods carry a matching toleration ......... they may enter
A random web pod has no toleration ............. it is turned away
```

Combine with a **label** plus a **nodeSelector** so Kafka pods don't wander onto the general pool either:

```
kafka NodePool  --label-->  workload=kafka
Kafka pods carry:  nodeSelector: { workload: kafka }
```

**The taint keeps others out. The nodeSelector keeps you in.** You need both.

### 40.3 The reusable module

`modules/app-nodepool/variables.tf`:

```hcl
variable "name"               { type = string }
variable "node_iam_role_name" { type = string }
variable "cluster_name"       { type = string }

variable "subnet_ids" {
  type        = list(string)
  description = "Where nodes are launched. Usually the private subnets."
}

variable "security_group_ids" {
  type = list(string)
}

variable "instance_families" {
  type    = list(string)
  default = ["m7g", "m7i", "c7g", "r7g"]
}

variable "instance_sizes" {
  type    = list(string)
  default = ["large", "xlarge", "2xlarge"]
}

variable "architectures" {
  type        = list(string)
  default     = ["arm64"]
  description = "Graviton (arm64) is roughly 20% cheaper. Confirm your images are multi-arch."
}

variable "capacity_types" {
  type        = list(string)
  default     = ["on-demand"]
  description = "Use ['spot'] or ['spot','on-demand'] for interruptible workloads."
}

variable "cpu_limit" {
  type        = number
  default     = 100
  description = "Hard ceiling on total vCPU this pool may create. YOUR COST GUARDRAIL."
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "ebs_size_gib"   { type = number, default = 80 }
variable "ebs_iops"       { type = number, default = 3000 }
variable "ebs_throughput" { type = number, default = 125 }

variable "expire_after" {
  type        = string
  default     = "336h"
  description = "Force node replacement after this long. Auto Mode maximum is 21 days (504h)."
}

variable "consolidation_policy" {
  type        = string
  default     = "WhenEmptyOrUnderutilized"
  description = "WhenEmptyOrUnderutilized = aggressive savings. WhenEmpty = gentler, fewer restarts."
}

variable "consolidate_after"         { type = string, default = "1m" }
variable "termination_grace_period"  { type = string, default = "24h" }
variable "disruption_budget"         { type = string, default = "10%" }
```

`modules/app-nodepool/main.tf`:

```hcl
resource "kubernetes_manifest" "nodeclass" {
  manifest = {
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata   = { name = var.name }
    spec = {
      # The IAM ROLE NAME (not the ARN) that nodes will assume.
      role = var.node_iam_role_name

      subnetSelectorTerms        = [for id in var.subnet_ids : { id = id }]
      securityGroupSelectorTerms = [for id in var.security_group_ids : { id = id }]

      ephemeralStorage = {
        size       = "${var.ebs_size_gib}Gi"
        iops       = var.ebs_iops
        throughput = var.ebs_throughput
      }

      # Tags applied to the EC2 instances and volumes this class creates.
      tags = merge(var.labels, {
        Name      = "${var.cluster_name}-${var.name}"
        NodePool  = var.name
        ManagedBy = "terraform"
      })
    }
  }
}

resource "kubernetes_manifest" "nodepool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = var.name }
    spec = {
      template = {
        metadata = { labels = var.labels }
        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = var.name
          }

          requirements = [
            {
              key      = "eks.amazonaws.com/instance-family"
              operator = "In"
              values   = var.instance_families
            },
            {
              key      = "eks.amazonaws.com/instance-size"
              operator = "In"
              values   = var.instance_sizes
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = var.architectures
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.capacity_types
            },
          ]

          taints = [
            for t in var.taints : {
              key    = t.key
              value  = t.value
              effect = t.effect
            }
          ]

          expireAfter            = var.expire_after
          terminationGracePeriod = var.termination_grace_period
        }
      }

      # Cost guardrail. Auto Mode refuses to exceed this.
      limits = { cpu = tostring(var.cpu_limit) }

      disruption = {
        consolidationPolicy = var.consolidation_policy
        consolidateAfter    = var.consolidate_after
        budgets             = [{ nodes = var.disruption_budget }]
      }

      # Higher weight wins when several pools could satisfy the same pod.
      weight = 10
    }
  }

  depends_on = [kubernetes_manifest.nodeclass]
}

output "nodepool_name" { value = var.name }
output "node_selector" { value = var.labels }
output "tolerations"   { value = var.taints }
```

> **`kubernetes_manifest` caveat:** this resource contacts the Kubernetes API **during `terraform plan`**, not only during apply. So (a) the cluster must exist and be reachable when you plan, and (b) you cannot plan Layer 40 in a CI job with no cluster access. That is fine in our layered design, since Layer 20 always runs first — but it is exactly why some teams prefer the `alekc/kubectl` provider, whose `kubectl_manifest` does not need API access at plan time. Both are valid; know the trade-off before you commit.

### 40.4 Kafka's node pool — `layers/40-nodepool-kafka`

```hcl
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/20-cluster/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.env}/10-network/terraform.tfstate"
    region = var.region
  }
}

locals {
  c = data.terraform_remote_state.cluster.outputs
  n = data.terraform_remote_state.network.outputs
}

# provider "kubernetes" block is identical to Layer 30 - omitted here for brevity

module "kafka_pool" {
  source = "../../modules/app-nodepool"

  name               = "kafka"
  cluster_name       = local.c.cluster_name
  node_iam_role_name = local.c.node_iam_role_name
  subnet_ids         = local.n.private_subnet_ids
  security_group_ids = [local.c.cluster_security_group_id]

  # Kafka is memory- and disk-hungry, and hates being interrupted.
  instance_families = var.instance_families
  instance_sizes    = var.instance_sizes
  architectures     = ["arm64"]
  capacity_types    = ["on-demand"]     # never spot for brokers

  cpu_limit      = var.cpu_limit
  ebs_size_gib   = var.ebs_size_gib
  ebs_iops       = var.ebs_iops
  ebs_throughput = var.ebs_throughput

  labels = {
    workload = "kafka"
    tier     = "data"
  }

  taints = [{
    key    = "dedicated"
    value  = "kafka"
    effect = "NoSchedule"
  }]

  # Gentler disruption for a stateful system.
  consolidation_policy     = "WhenEmpty"
  consolidate_after        = "10m"
  disruption_budget        = "1"        # replace ONE node at a time, never more
  expire_after             = var.expire_after
  termination_grace_period = "1h"
}
```

`envs/dev.tfvars`:

```hcl
region       = "us-east-1"
env          = "dev"
org          = "acme"
state_bucket = "acme-tfstate-dev-123456789012"

instance_families = ["m7g", "r7g"]
instance_sizes    = ["large"]
cpu_limit         = 16
ebs_size_gib      = 80
ebs_iops          = 3000
ebs_throughput    = 125
expire_after      = "336h"
```

`envs/prod.tfvars`:

```hcl
region       = "us-east-1"
env          = "prod"
org          = "acme"
state_bucket = "acme-tfstate-prod-999888777666"

instance_families = ["r7g", "r7i"]      # memory-optimised
instance_sizes    = ["2xlarge", "4xlarge"]
cpu_limit         = 256
ebs_size_gib      = 500
ebs_iops          = 8000
ebs_throughput    = 750
expire_after      = "504h"              # 21 days = Auto Mode maximum
```

**Now the payoff.** The Kafka team wants bigger machines:

```bash
cd layers/40-nodepool-kafka
vim envs/prod.tfvars                        # bump instance_sizes
terraform plan  -var-file=envs/prod.tfvars
terraform apply -var-file=envs/prod.tfvars
```

Terraform touched **exactly two Kubernetes objects**. It never read, planned, or risked the VPC, the cluster, the platform layer, Keycloak, or anyone else's node pool. The web team can be applying their own layer in the same second and neither blocks the other, because they hold different S3 locks on different state files.

### 40.5 The other pools

`layers/40-nodepool-keycloak` — same shape, different values:

```hcl
module "keycloak_pool" {
  source = "../../modules/app-nodepool"

  name               = "keycloak"
  cluster_name       = local.c.cluster_name
  node_iam_role_name = local.c.node_iam_role_name
  subnet_ids         = local.n.private_subnet_ids
  security_group_ids = [local.c.cluster_security_group_id]

  instance_families = ["m7g", "c7g"]
  instance_sizes    = ["large", "xlarge"]
  capacity_types    = ["on-demand"]
  cpu_limit         = var.cpu_limit

  labels = { workload = "keycloak", tier = "platform" }
  taints = [{ key = "dedicated", value = "keycloak", effect = "NoSchedule" }]
}
```

`layers/40-nodepool-apps` — the shared pool for NiFi, web apps, and everything else. **No taint**, so anything may land here by default.

```hcl
module "apps_pool" {
  source = "../../modules/app-nodepool"

  name               = "apps"
  cluster_name       = local.c.cluster_name
  node_iam_role_name = local.c.node_iam_role_name
  subnet_ids         = local.n.private_subnet_ids
  security_group_ids = [local.c.cluster_security_group_id]

  instance_families = ["m7g", "m7i", "c7g"]
  instance_sizes    = ["medium", "large", "xlarge"]
  capacity_types    = var.capacity_types   # dev: ["spot"], prod: ["on-demand"]
  cpu_limit         = var.cpu_limit

  labels = { workload = "apps", tier = "application" }
  taints = []                              # open to all
}
```

### 40.6 Verify

```bash
kubectl get nodepools
# NAME              NODECLASS         NODES   READY   AGE
# apps              apps              0       True    1m
# general-purpose   default           0       True    2h
# kafka             kafka             0       True    3m
# keycloak          keycloak          0       True    2m
# system            default           1       True    2h

kubectl describe nodepool kafka | head -40
kubectl get nodeclass kafka -o yaml
```

---

## Layer 50a — Kafka (Strimzi)

**What it is:** the actual Kafka cluster, described in a few Terraform resources, landing on the `kafka` node pool built in Layer 40.

### 50a.1 The pieces

Modern Strimzi (1.x) requires:

- **KafkaNodePool** custom resources — one or more, each declaring `roles: [controller]`, `[broker]`, or both
- **KRaft mode** — no ZooKeeper, ever again
- API version **`kafka.strimzi.io/v1`** — Strimzi 1.0 removed the older `v1beta2`

> **Naming collision alert:** Strimzi's `KafkaNodePool` and Auto Mode's `NodePool` are completely different things that unfortunately share a name. Strimzi's = *groups of Kafka processes*. Auto Mode's = *groups of EC2 machines*. In this document: Layer 40 = machines, Layer 50 = Kafka processes.

Two layouts:

| Layout | Shape | Pros | Cons | Use when |
|---|---|---|---|---|
| **Combined** | 3 nodes, each `[controller, broker]` | Cheapest, simplest | Controller and broker compete for CPU; can't scale them independently | dev / stage |
| **Separated** | 3 controllers + N brokers | Metadata stays healthy under broker load; scale brokers freely | 3 extra pods to pay for | prod |

### 50a.2 The code — `layers/50-app-kafka/main.tf`

```hcl
locals {
  cluster = "${var.org}-${var.env}"
  ns      = "kafka"

  # Pods need BOTH: node affinity to get in, toleration to be allowed.
  placement = {
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "workload"
              operator = "In"
              values   = ["kafka"]
            }]
          }]
        }
      }
      # Spread brokers across AZs so one AZ outage cannot break the quorum.
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          labelSelector = {
            matchLabels = { "strimzi.io/cluster" = local.cluster }
          }
          topologyKey = "topology.kubernetes.io/zone"
        }]
      }
    }
    tolerations = [{
      key      = "dedicated"
      operator = "Equal"
      value    = "kafka"
      effect   = "NoSchedule"
    }]
  }
}

# ---------- Controllers: the KRaft quorum (the brain) ----------
resource "kubernetes_manifest" "controllers" {
  count = var.separate_controllers ? 1 : 0

  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "controller"
      namespace = local.ns
      labels    = { "strimzi.io/cluster" = local.cluster }
    }
    spec = {
      replicas = 3                     # ALWAYS odd. 3 tolerates 1 failure.
      roles    = ["controller"]
      storage = {
        type = "jbod"
        volumes = [{
          id            = 0
          type          = "persistent-claim"
          size          = "20Gi"
          class         = var.storage_class
          deleteClaim   = false
          kraftMetadata = "shared"
        }]
      }
      resources = {
        requests = { memory = "1Gi", cpu = "500m" }
        limits   = { memory = "2Gi", cpu = "1" }
      }
      template = { pod = local.placement }
    }
  }
}

# ---------- Brokers: where the data lives ----------
resource "kubernetes_manifest" "brokers" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"
    metadata = {
      name      = var.separate_controllers ? "broker" : "combined"
      namespace = local.ns
      labels    = { "strimzi.io/cluster" = local.cluster }
    }
    spec = {
      replicas = var.broker_replicas
      roles    = var.separate_controllers ? ["broker"] : ["controller", "broker"]
      storage = {
        type = "jbod"
        volumes = [{
          id          = 0
          type        = "persistent-claim"
          size        = var.broker_storage_size
          class       = var.storage_class
          deleteClaim = false          # NEVER true for brokers
        }]
      }
      resources = {
        requests = { memory = var.broker_memory_request, cpu = var.broker_cpu_request }
        limits   = { memory = var.broker_memory_limit,   cpu = var.broker_cpu_limit }
      }
      jvmOptions = {
        "-Xms" = var.broker_heap
        "-Xmx" = var.broker_heap
      }
      template = { pod = local.placement }
    }
  }
}

# ---------- The Kafka cluster itself ----------
resource "kubernetes_manifest" "kafka" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"
    metadata = {
      name      = local.cluster
      namespace = local.ns
    }
    spec = {
      kafka = {
        version         = var.kafka_version
        metadataVersion = var.kafka_metadata_version

        listeners = [
          {
            name = "plain"
            port = 9092
            type = "internal"
            tls  = false
          },
          {
            name           = "tls"
            port           = 9093
            type           = "internal"
            tls            = true
            authentication = { type = "tls" }
          },
        ]

        authorization = { type = "simple" }

        config = {
          "offsets.topic.replication.factor"         = var.replication_factor
          "transaction.state.log.replication.factor" = var.replication_factor
          "transaction.state.log.min.isr"            = var.min_isr
          "default.replication.factor"               = var.replication_factor
          "min.insync.replicas"                      = var.min_isr
          "auto.create.topics.enable"                = false
          "log.retention.hours"                      = var.retention_hours
        }
      }

      entityOperator = {
        topicOperator = { template = { pod = local.placement } }
        userOperator  = { template = { pod = local.placement } }
      }

      # Cruise Control rebalances partitions across brokers automatically.
      cruiseControl = var.enable_cruise_control ? { template = { pod = local.placement } } : null
    }
  }

  depends_on = [
    kubernetes_manifest.brokers,
    kubernetes_manifest.controllers,
  ]
}
```

### 50a.3 Topics as code

```hcl
variable "topics" {
  type = map(object({
    partitions = number
    replicas   = number
    config     = optional(map(string), {})
  }))
  default = {}
}

resource "kubernetes_manifest" "topics" {
  for_each = var.topics

  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaTopic"
    metadata = {
      name      = each.key
      namespace = local.ns
      labels    = { "strimzi.io/cluster" = local.cluster }
    }
    spec = {
      partitions = each.value.partitions
      replicas   = each.value.replicas
      config     = each.value.config
    }
  }

  depends_on = [kubernetes_manifest.kafka]
}
```

### 50a.4 The environment files — this is where dev and prod really diverge

`envs/dev.tfvars`:

```hcl
region       = "us-east-1"
env          = "dev"
org          = "acme"
state_bucket = "acme-tfstate-dev-123456789012"

separate_controllers = false      # combined nodes: cheap
broker_replicas      = 3
broker_storage_size  = "20Gi"
storage_class        = "kafka-gp3-retain"

broker_memory_request = "2Gi"
broker_memory_limit   = "3Gi"
broker_cpu_request    = "500m"
broker_cpu_limit      = "2"
broker_heap           = "1g"

kafka_version          = "4.1.0"
kafka_metadata_version = "4.1"
replication_factor     = 3
min_isr                = 2
retention_hours        = 24
enable_cruise_control  = false

topics = {
  orders = { partitions = 3, replicas = 3 }
  events = { partitions = 6, replicas = 3, config = { "retention.ms" = "86400000" } }
}
```

`envs/prod.tfvars`:

```hcl
region       = "us-east-1"
env          = "prod"
org          = "acme"
state_bucket = "acme-tfstate-prod-999888777666"

separate_controllers = true       # dedicated controllers
broker_replicas      = 6
broker_storage_size  = "1000Gi"
storage_class        = "kafka-gp3-retain"

broker_memory_request = "16Gi"
broker_memory_limit   = "16Gi"    # requests == limits gives Guaranteed QoS
broker_cpu_request    = "4"
broker_cpu_limit      = "8"
broker_heap           = "6g"      # ~40% of container memory; the rest is page cache

kafka_version          = "4.1.0"
kafka_metadata_version = "4.1"
replication_factor     = 3
min_isr                = 2
retention_hours        = 168      # 7 days
enable_cruise_control  = true

topics = {
  orders = { partitions = 24, replicas = 3, config = { "min.insync.replicas" = "2" } }
  events = { partitions = 48, replicas = 3 }
  audit  = { partitions = 12, replicas = 3, config = { "retention.ms" = "2592000000" } }
}
```

> **Check version compatibility before you set `kafka_version`.** Each Strimzi release bundles a specific set of Kafka images and refuses unknown versions — the Strimzi release notes list them. Bump `metadataVersion` **after** every broker is running the new Kafka version, never before, and never downgrade it.

> **Why `broker_heap` is only ~40% of the memory limit:** Kafka gets most of its speed from the operating system's page cache, not from the JVM heap. A 16 GiB container with a 6 GiB heap leaves ~10 GiB of page cache. Give the heap everything and you make Kafka *slower*.

### 50a.5 Verify

```bash
kubectl -n kafka get kafka,kafkanodepool,pods
kubectl -n kafka get kafka acme-dev -o jsonpath='{.status.listeners}' | jq

# Nodes should have appeared in the kafka pool
kubectl get nodes -l workload=kafka

# Watch Strimzi's own view of readiness
kubectl -n kafka wait kafka/acme-dev --for=condition=Ready --timeout=15m
```

The bootstrap address other apps use inside the cluster:

```
acme-dev-kafka-bootstrap.kafka.svc.cluster.local:9092    (plaintext, internal)
acme-dev-kafka-bootstrap.kafka.svc.cluster.local:9093    (TLS + mTLS auth)
```

### 50a.6 Kafka on disposable nodes — the survival checklist

Auto Mode *will* replace nodes underneath you. Kafka must not care. Non-negotiables:

- [ ] `replication_factor >= 3` and `min.insync.replicas = 2` — a broker can die with zero data loss
- [ ] Pod anti-affinity on `topology.kubernetes.io/zone` — no two brokers in one AZ
- [ ] NodePool `disruption.budgets = [{ nodes = "1" }]` — one node replaced at a time
- [ ] `terminationGracePeriod: 1h` — Kafka needs time to hand off partition leadership
- [ ] `deleteClaim: false` plus a `Retain` StorageClass — losing a pod never loses a disk
- [ ] On-demand capacity for brokers; spot only for consumers and Connect workers
- [ ] Install the **Strimzi Drain Cleaner** so evictions go through Strimzi's rolling logic instead of a blunt pod kill
- [ ] Actually test it: `kubectl delete node <one-kafka-node>` in dev and watch the cluster heal

---

## Layer 50b — Keycloak

**What it is:** the identity server that every other app will use for login, plus its PostgreSQL database and its public URL.

### 50b.1 Why RDS and not a database pod

Keycloak stores users, sessions, realms, and clients in a relational database. You have three options:

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Amazon RDS PostgreSQL** | Automated backups, point-in-time restore, Multi-AZ failover, patching handled | Costs money; lives outside the cluster | **Use this.** Losing your identity database locks everyone out of everything. |
| **CloudNativePG operator in-cluster** | Everything in one place; cheap; good operator | You own backups, failover testing, and PVC lifecycle on disposable nodes | Fine if you have the expertise |
| **Keycloak's dev-file / dev-mem database** | Zero setup | Data vanishes on restart. Not a database. | Laptop demos only |

### 50b.2 The database

`layers/50-app-keycloak/rds.tf`:

```hcl
resource "random_password" "kc_db" {
  length  = 32
  special = false          # some JDBC URLs choke on exotic characters
}

resource "aws_secretsmanager_secret" "kc_db" {
  name                    = "${var.org}/${var.env}/keycloak/db"
  recovery_window_in_days = var.env == "prod" ? 30 : 0
}

resource "aws_secretsmanager_secret_version" "kc_db" {
  secret_id = aws_secretsmanager_secret.kc_db.id
  secret_string = jsonencode({
    username = "keycloak"
    password = random_password.kc_db.result
  })
}

resource "aws_security_group" "kc_db" {
  name   = "${var.org}-${var.env}-keycloak-db"
  vpc_id = local.n.vpc_id

  ingress {
    description     = "Postgres from the EKS cluster only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [local.c.cluster_security_group_id]
  }
}

resource "aws_db_subnet_group" "kc" {
  name       = "${var.org}-${var.env}-keycloak"
  subnet_ids = local.n.private_subnet_ids
}

resource "aws_db_instance" "keycloak" {
  identifier     = "${var.org}-${var.env}-keycloak"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "keycloak"
  username = "keycloak"
  password = random_password.kc_db.result

  db_subnet_group_name   = aws_db_subnet_group.kc.name
  vpc_security_group_ids = [aws_security_group.kc_db.id]
  publicly_accessible    = false

  multi_az                = var.db_multi_az
  backup_retention_period = var.db_backup_days
  deletion_protection     = var.env == "prod"
  skip_final_snapshot     = var.env != "prod"
  final_snapshot_identifier = var.env == "prod" ? "${var.org}-prod-keycloak-final" : null

  performance_insights_enabled = var.env == "prod"
  auto_minor_version_upgrade   = true
}
```

### 50b.3 Hand the credentials to Kubernetes

```hcl
resource "kubernetes_secret_v1" "kc_db" {
  metadata {
    name      = "keycloak-db"
    namespace = "keycloak"
  }
  data = {
    username = "keycloak"
    password = random_password.kc_db.result
  }
  type = "Opaque"
}
```

> **Better for production:** install the **External Secrets Operator** or the **AWS Secrets Store CSI driver** so the password is pulled from Secrets Manager at pod start and never lands in the Terraform state file at all. The example above puts the password in state — acceptable for dev with an encrypted state bucket, not ideal for prod. Whatever you choose, restrict who can read the state bucket.

### 50b.4 The Keycloak resource

```hcl
resource "kubernetes_manifest" "keycloak" {
  manifest = {
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "Keycloak"
    metadata = {
      name      = "keycloak"
      namespace = "keycloak"
    }
    spec = {
      instances = var.keycloak_replicas

      db = {
        vendor        = "postgres"
        host          = aws_db_instance.keycloak.address
        port          = 5432
        database      = "keycloak"
        usernameSecret = { name = "keycloak-db", key = "username" }
        passwordSecret = { name = "keycloak-db", key = "password" }
      }

      hostname = {
        hostname = var.keycloak_hostname       # e.g. "auth.dev.acme.example"
      }

      # The ALB terminates TLS; Keycloak trusts the X-Forwarded-* headers.
      proxy = { headers = "xforwarded" }

      http = {
        httpEnabled = true                     # plain HTTP behind the ALB
      }

      # We manage the Ingress ourselves so we control the IngressClass.
      ingress = { enabled = false }

      resources = {
        requests = { cpu = var.kc_cpu_request, memory = var.kc_mem_request }
        limits   = { cpu = var.kc_cpu_limit,   memory = var.kc_mem_limit }
      }

      # Land on the keycloak node pool from Layer 40.
      scheduling = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [{
                matchExpressions = [{
                  key      = "workload"
                  operator = "In"
                  values   = ["keycloak"]
                }]
              }]
            }
          }
        }
        tolerations = [{
          key      = "dedicated"
          operator = "Equal"
          value    = "keycloak"
          effect   = "NoSchedule"
        }]
      }
    }
  }

  depends_on = [
    aws_db_instance.keycloak,
    kubernetes_secret_v1.kc_db,
  ]
}
```

> **Version note:** the Keycloak CRD group is `k8s.keycloak.org` and the served version has been `v2alpha1` across the 26.x line. Confirm against the operator version you installed with `kubectl get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[*].name}'` before you apply.

### 50b.5 The Ingress

```hcl
resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = "keycloak"
  }
  spec {
    ingress_class_name = "alb"
    rule {
      host = var.keycloak_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "keycloak-service"
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.keycloak]
}
```

TLS certificate and DNS: request an ACM certificate for `auth.dev.acme.example`, reference it in the shared `IngressClassParams` (`spec.certificateARNs`), and create the Route 53 record — either with a Terraform `aws_route53_record` pointing at the ALB, or by installing **external-dns** in Layer 30 so DNS records appear automatically from Ingress annotations.

### 50b.6 A realm as code

A **realm** is a walled garden of users and apps. Never use the built-in `master` realm for your applications — keep `master` for Keycloak administrators only.

```hcl
resource "kubernetes_manifest" "realm" {
  manifest = {
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "KeycloakRealmImport"
    metadata = {
      name      = "platform"
      namespace = "keycloak"
    }
    spec = {
      keycloakCRName = "keycloak"
      realm = {
        realm           = "platform"
        enabled         = true
        displayName     = "Acme Platform"
        registrationAllowed = false
        sslRequired     = "external"

        clients = [
          {
            clientId                  = "nifi"
            enabled                   = true
            protocol                  = "openid-connect"
            publicClient              = false
            standardFlowEnabled       = true
            redirectUris              = ["https://nifi.${var.domain}/*"]
            webOrigins                = ["https://nifi.${var.domain}"]
          },
          {
            clientId            = "webapp"
            enabled             = true
            protocol            = "openid-connect"
            publicClient        = true
            standardFlowEnabled = true
            redirectUris        = ["https://app.${var.domain}/*"]
            webOrigins          = ["https://app.${var.domain}"]
          },
        ]

        roles = {
          realm = [
            { name = "platform-admin" },
            { name = "platform-user" },
          ]
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.keycloak]
}
```

> **KeycloakRealmImport imports once.** It creates the realm if it is missing; it does not continuously reconcile every field afterwards. Treat it as *seeding*. For ongoing, fully declarative realm management, use the dedicated `keycloak/keycloak` Terraform provider (which talks to Keycloak's admin API) in a separate small layer, or manage realms through GitOps.

### 50b.7 tfvars

`envs/dev.tfvars`:

```hcl
region       = "us-east-1"
env          = "dev"
org          = "acme"
state_bucket = "acme-tfstate-dev-123456789012"
domain       = "dev.acme.example"

keycloak_hostname = "auth.dev.acme.example"
keycloak_replicas = 1

db_engine_version    = "16.4"
db_instance_class    = "db.t4g.micro"
db_allocated_storage = 20
db_max_storage       = 50
db_multi_az          = false
db_backup_days       = 1

kc_cpu_request = "250m"
kc_mem_request = "768Mi"
kc_cpu_limit   = "1"
kc_mem_limit   = "1536Mi"
```

`envs/prod.tfvars`:

```hcl
region       = "us-east-1"
env          = "prod"
org          = "acme"
state_bucket = "acme-tfstate-prod-999888777666"
domain       = "acme.example"

keycloak_hostname = "auth.acme.example"
keycloak_replicas = 3            # HA. Sessions replicate between instances.

db_engine_version    = "16.4"
db_instance_class    = "db.r7g.large"
db_allocated_storage = 100
db_max_storage       = 500
db_multi_az          = true      # automatic failover to a standby in another AZ
db_backup_days       = 30

kc_cpu_request = "1"
kc_mem_request = "2Gi"
kc_cpu_limit   = "2"
kc_mem_limit   = "2Gi"
```

### 50b.8 Verify

```bash
kubectl -n keycloak get keycloak,pods
kubectl -n keycloak get ingress

# First-run admin password (bootstrap only - rotate it immediately)
kubectl -n keycloak get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d; echo

open https://auth.dev.acme.example
```

---

# PART C — tfvars: One Codebase, Three Environments

## C.1 The core idea

You write the recipe **once**. The `.tfvars` file is the serving size.

```
main.tf  ──────────────────────────┐
(the recipe: "make a Kafka         │
 cluster with N brokers")          │
                                   ├──> dev   = 3 small brokers
envs/dev.tfvars   (N = 3, small)   │
envs/stage.tfvars (N = 3, medium)  ├──> stage = 3 medium brokers
envs/prod.tfvars  (N = 6, large)   │
                                   └──> prod  = 6 large brokers
```

**The rule: no `if env == "prod"` scattered through your `.tf` files.** If dev and prod differ, that difference is a *variable*, and its value lives in the tfvars file. When your `main.tf` starts filling up with environment conditionals, the code stops being reviewable — you can no longer read it and know what prod looks like.

## C.2 The two files every environment needs

A common beginner trap: **the backend block cannot use variables.** Terraform reads the backend before it evaluates variables, so `bucket = var.state_bucket` is a syntax error.

The answer is **partial backend configuration** — leave the values out of the code and pass them at `init` time.

**File 1 — `envs/dev.s3.tfbackend`** (where the state lives):

```hcl
bucket = "acme-tfstate-dev-123456789012"
key    = "dev/40-nodepool-kafka/terraform.tfstate"
region = "us-east-1"
```

**File 2 — `envs/dev.tfvars`** (what to build):

```hcl
region            = "us-east-1"
env               = "dev"
org               = "acme"
state_bucket      = "acme-tfstate-dev-123456789012"
instance_sizes    = ["large"]
cpu_limit         = 16
```

Used together:

```bash
terraform init  -backend-config=envs/dev.s3.tfbackend
terraform plan  -var-file=envs/dev.tfvars
terraform apply -var-file=envs/dev.tfvars
```

**Switching environments requires `init -reconfigure`**, because the state location itself changes:

```bash
terraform init -reconfigure -backend-config=envs/prod.s3.tfbackend
terraform plan -var-file=envs/prod.tfvars
```

> Forget `-reconfigure` and Terraform will either reuse the old backend or offer to *copy dev's state into prod's bucket*. Read that prompt. Never blindly answer "yes" to "Do you want to copy existing state to the new backend?"

## C.3 Stop people from making mistakes: `tf.sh`

Two flags, two files, ten layers, three environments. Someone will eventually plan dev's variables against prod's state. Remove the possibility:

`scripts/tf.sh`:

```bash
#!/usr/bin/env bash
# Usage: ./scripts/tf.sh <env> <layer> <command> [extra args...]
# Example: ./scripts/tf.sh prod 40-nodepool-kafka plan
set -euo pipefail

ENV="${1:?usage: tf.sh <env> <layer> <command>}"
LAYER="${2:?usage: tf.sh <env> <layer> <command>}"
CMD="${3:?usage: tf.sh <env> <layer> <command>}"
shift 3

case "$ENV" in
  dev|stage|prod) ;;
  *) echo "ERROR: env must be dev, stage or prod (got '$ENV')"; exit 1 ;;
esac

DIR="layers/${LAYER}"
[[ -d "$DIR" ]] || { echo "ERROR: no such layer: $DIR"; exit 1; }

BACKEND="envs/${ENV}.s3.tfbackend"
VARS="envs/${ENV}.tfvars"
cd "$DIR"
[[ -f "$BACKEND" ]] || { echo "ERROR: missing $DIR/$BACKEND"; exit 1; }
[[ -f "$VARS"    ]] || { echo "ERROR: missing $DIR/$VARS"; exit 1; }

# Loud confirmation before touching production.
if [[ "$ENV" == "prod" && "$CMD" =~ ^(apply|destroy)$ ]]; then
  echo "=============================================="
  echo "  You are about to $CMD PRODUCTION: $LAYER"
  echo "=============================================="
  read -r -p "Type the word 'production' to continue: " CONFIRM
  [[ "$CONFIRM" == "production" ]] || { echo "Aborted."; exit 1; }
fi

terraform init -reconfigure -backend-config="$BACKEND" -input=false

case "$CMD" in
  plan)    terraform plan    -var-file="$VARS" -lock-timeout=10m "$@" ;;
  apply)   terraform apply   -var-file="$VARS" -lock-timeout=10m "$@" ;;
  destroy) terraform destroy -var-file="$VARS" -lock-timeout=10m "$@" ;;
  output)  terraform output "$@" ;;
  *)       terraform "$CMD" "$@" ;;
esac
```

Now nobody has to remember anything:

```bash
./scripts/tf.sh dev  40-nodepool-kafka plan
./scripts/tf.sh prod 40-nodepool-kafka apply
```

> `-lock-timeout=10m` means a second run **waits politely** for the lock instead of failing instantly. This matters in CI where two pipeline runs can overlap.

## C.4 What actually differs between environments

| Setting | dev | stage | prod | Why |
|---|---|---|---|---|
| `az_count` | 2 | 3 | 3 | Fewer AZs = fewer NAT gateways = cheaper dev |
| `single_nat_gateway` | `true` | `false` | `false` | One NAT saves ~$65/mo but is a single point of failure |
| `endpoint_public_access` | `true` (IP-restricted) | `false` | `false` | Laptop convenience in dev; private-only in prod |
| `kubernetes_version` | newest | newest | newest **minus one** | Prove upgrades in dev first |
| `capacity_types` | `["spot"]` | `["spot","on-demand"]` | `["on-demand"]` | Spot is ~70% cheaper and can vanish |
| `cpu_limit` per pool | 16 | 64 | 256 | Cost guardrail matched to real need |
| `broker_replicas` | 3 | 3 | 6 | Prod needs throughput headroom |
| `db_multi_az` | `false` | `false` | `true` | Automatic failover costs double |
| `db_backup_days` | 1 | 7 | 30 | Recovery window matched to risk |
| `deletion_protection` | `false` | `false` | `true` | Prod cannot be deleted by accident |
| `retention_hours` (Kafka) | 24 | 72 | 168 | Storage is the main Kafka cost |
| `enable_flow_logs` | `false` | `false` | `true` | Flow logs are surprisingly expensive |

## C.5 Sharing values without copy-paste

Values repeated in every tfvars file drift over time. Two clean fixes:

**Layered tfvars** — Terraform merges multiple `-var-file` flags, last one wins:

```bash
terraform apply -var-file=../../common.tfvars -var-file=envs/prod.tfvars
```

```hcl
# common.tfvars - true for every environment
org    = "acme"
region = "us-east-1"
tags = {
  CostCenter = "platform"
  Owner      = "platform-team@acme.example"
}
```

**Derived defaults in locals** — encode the *policy* once in code:

```hcl
locals {
  is_prod = var.env == "prod"

  # Sensible defaults derived from the env; tfvars can still override.
  backup_days = coalesce(var.db_backup_days, local.is_prod ? 30 : 1)
  multi_az    = coalesce(var.db_multi_az, local.is_prod)
}
```

Use this sparingly — it is the *one* acceptable form of environment conditional, because it lives in a single `locals` block you can read at a glance rather than being sprinkled through the file.

## C.6 Guardrails: validation and preconditions

Catch mistakes at `plan` time, not at 3 a.m.

```hcl
variable "env" {
  type = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "cpu_limit" {
  type = number
  validation {
    condition     = var.cpu_limit > 0 && var.cpu_limit <= 1000
    error_message = "cpu_limit must be between 1 and 1000 vCPU."
  }
}

variable "broker_replicas" {
  type = number
  validation {
    condition     = var.broker_replicas >= 3
    error_message = "Kafka needs at least 3 brokers to survive a node failure."
  }
}

# Cross-variable rules go in a check block or a lifecycle precondition.
check "prod_safety" {
  assert {
    condition     = var.env != "prod" || var.db_multi_az
    error_message = "Production databases must be Multi-AZ."
  }
  assert {
    condition     = var.env != "prod" || !contains(var.capacity_types, "spot")
    error_message = "Production Kafka brokers must not run on spot capacity."
  }
}
```

## C.7 Workspaces vs. directories vs. tfvars

You will see three approaches in the wild:

| Approach | How | Pros | Cons |
|---|---|---|---|
| **tfvars + partial backend** *(this guide)* | One dir, `-var-file` and `-backend-config` per env | Separate state per env; explicit; different backends/accounts per env; easy to review | Two flags to remember (solved by `tf.sh`) |
| **Terraform workspaces** | `terraform workspace select prod` | One command to switch; state auto-namespaced | All envs share **one backend and one AWS account**; easy to apply to the wrong workspace; `terraform.workspace` conditionals creep into code |
| **Directory per environment** | `envs/prod/main.tf` with its own copy of everything | Total isolation; prod can drift deliberately | Massive duplication; a fix in dev must be copied 3 times |

**Recommendation:** tfvars + partial backend, with **one AWS account per environment**. Workspaces are best for short-lived ephemeral copies (a per-pull-request preview environment), not for the dev/stage/prod ladder.

## C.8 Secrets do not go in tfvars

`.tfvars` files are committed to git. Never put a password, key, or token in one.

| Kind of value | Where it goes | How Terraform reads it |
|---|---|---|
| Sizes, counts, names, CIDRs | `envs/*.tfvars` in git | `-var-file` |
| Passwords, API keys | AWS Secrets Manager / SSM SecureString | `data "aws_secretsmanager_secret_version"` |
| CI-injected values | Environment variables | `TF_VAR_my_value` |
| Generated passwords | `random_password` + immediately store in Secrets Manager | Resource + data source |

Add to `.gitignore`:

```gitignore
*.auto.tfvars
secrets.tfvars
.terraform/
terraform.tfstate
terraform.tfstate.backup
!layers/00-bootstrap/terraform.tfstate
crash.log
*.tfplan
```

---

# PART D — Onboarding Guide for New Apps

**Give this section to any team that wants to run something on the platform.** It is written to be copy-pasted into your internal wiki.

## D.1 The promise

> "Bring us a container image and answer six questions. You get a namespace, a node pool sized for you, a DNS name with TLS, storage, Kafka access, and single sign-on. You will be able to change your own node pool without asking us, and without being able to break anyone else."

## D.2 The six questions

Every new app fills in this form. It becomes the app's `envs/*.tfvars`.

| # | Question | Example answer | Which variable it sets |
|---|---|---|---|
| 1 | What is the app called? | `nifi` | `app_name` (namespace, pool, labels) |
| 2 | Does it need its **own** node pool or can it share `apps`? | Own — needs 16 GiB memory and persistent disk | new Layer 40 vs. reuse |
| 3 | How much compute at peak? | 8 vCPU, 32 GiB across all pods | `cpu_limit`, `instance_sizes` |
| 4 | Can it survive being interrupted? | No — stateful | `capacity_types = ["on-demand"]` |
| 5 | Does it need storage, and can it lose it? | Yes, 100 GiB, must not lose it | `storage_class = "...-retain"` |
| 6 | Does it need a public URL, Kafka, or SSO? | All three | Ingress, KafkaUser, Keycloak client |

**Decision rule for question 2:**

```
Do you need a taint (nobody else on your machines)?          -> own pool
Do you need instance types the shared pool doesn't offer
   (GPU, high memory, local NVMe)?                           -> own pool
Do you need different disruption behaviour (slow drains)?    -> own pool
Otherwise                                                     -> use the shared 'apps' pool
```

Most web apps share. Data systems get their own.

## D.3 Onboarding a new app that SHARES the apps pool (the easy path)

**Example: a web application.** Nothing in Layer 40 changes at all.

Create `layers/50-app-webapp/`:

```hcl
resource "kubernetes_namespace_v1" "webapp" {
  metadata {
    name = "webapp"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "kubernetes_deployment_v1" "webapp" {
  metadata {
    name      = "webapp"
    namespace = kubernetes_namespace_v1.webapp.metadata[0].name
  }
  spec {
    replicas = var.replicas
    selector { match_labels = { app = "webapp" } }
    template {
      metadata { labels = { app = "webapp" } }
      spec {
        # Land on the shared apps pool. No toleration needed - it has no taint.
        node_selector = { workload = "apps" }

        # Spread copies across AZs so one AZ outage doesn't take the app down.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "webapp" } }
        }

        container {
          name  = "webapp"
          image = var.image
          port { container_port = 8080 }

          resources {
            requests = { cpu = var.cpu_request, memory = var.mem_request }
            limits   = { cpu = var.cpu_limit,   memory = var.mem_limit }
          }

          liveness_probe {
            http_get { path = "/healthz", port = 8080 }
            initial_delay_seconds = 10
          }
          readiness_probe {
            http_get { path = "/ready", port = 8080 }
            initial_delay_seconds = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "webapp" {
  metadata {
    name      = "webapp"
    namespace = kubernetes_namespace_v1.webapp.metadata[0].name
  }
  spec {
    selector = { app = "webapp" }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

# REQUIRED on Auto Mode: nodes get replaced. Tell Kubernetes your minimum.
resource "kubernetes_pod_disruption_budget_v1" "webapp" {
  metadata {
    name      = "webapp"
    namespace = kubernetes_namespace_v1.webapp.metadata[0].name
  }
  spec {
    min_available = var.min_available    # e.g. "50%"
    selector { match_labels = { app = "webapp" } }
  }
}

resource "kubernetes_ingress_v1" "webapp" {
  metadata {
    name      = "webapp"
    namespace = kubernetes_namespace_v1.webapp.metadata[0].name
  }
  spec {
    ingress_class_name = "alb"          # joins the SHARED ALB from Layer 30
    rule {
      host = var.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "webapp"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}
```

Backend + tfvars, then:

```bash
./scripts/tf.sh dev 50-app-webapp apply
```

**Total platform-team work: zero.** The app team owns this folder.

## D.4 Onboarding an app that needs its OWN pool

**Example: Apache NiFi.** NiFi holds flowfile repositories on disk, uses lots of memory, and must not be interrupted mid-flow. It gets its own pool.

### Step 1 — Copy the node pool layer

```bash
cp -r layers/40-nodepool-apps layers/40-nodepool-nifi
cd layers/40-nodepool-nifi
```

Edit `main.tf` — usually only the module block changes:

```hcl
module "nifi_pool" {
  source = "../../modules/app-nodepool"

  name               = "nifi"
  cluster_name       = local.c.cluster_name
  node_iam_role_name = local.c.node_iam_role_name
  subnet_ids         = local.n.private_subnet_ids
  security_group_ids = [local.c.cluster_security_group_id]

  instance_families = var.instance_families     # ["r7g","r7i"] - memory heavy
  instance_sizes    = var.instance_sizes
  architectures     = ["arm64"]
  capacity_types    = ["on-demand"]
  cpu_limit         = var.cpu_limit
  ebs_size_gib      = var.ebs_size_gib

  labels = { workload = "nifi", tier = "data" }
  taints = [{ key = "dedicated", value = "nifi", effect = "NoSchedule" }]

  # NiFi hates surprise restarts.
  consolidation_policy     = "WhenEmpty"
  consolidate_after        = "30m"
  disruption_budget        = "1"
  termination_grace_period = "2h"
}
```

Update the three backend files so the **key is unique** — this is the step people forget:

```hcl
# envs/dev.s3.tfbackend
bucket = "acme-tfstate-dev-123456789012"
key    = "dev/40-nodepool-nifi/terraform.tfstate"     # <-- MUST be unique
region = "us-east-1"
```

> **The #1 onboarding bug:** copying a layer and forgetting to change the `key`. Two layers then share one state file, and the second `apply` silently deletes everything the first one built. Make this a mandatory item on your PR checklist.

### Step 2 — Apply the pool

```bash
./scripts/tf.sh dev 40-nodepool-nifi apply
kubectl get nodepool nifi
```

### Step 3 — Deploy NiFi into it

`layers/50-app-nifi/main.tf` — every NiFi pod carries the matching nodeSelector and toleration:

```hcl
locals {
  placement_node_selector = { workload = "nifi" }
  placement_tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "nifi"
    effect   = "NoSchedule"
  }]
}

resource "helm_release" "nifi" {
  name       = "nifi"
  namespace  = "nifi"
  repository = var.nifi_chart_repo
  chart      = "nifi"
  version    = var.nifi_chart_version

  values = [yamlencode({
    replicaCount = var.replicas

    nodeSelector = local.placement_node_selector
    tolerations  = local.placement_tolerations

    persistence = {
      enabled      = true
      storageClass = var.storage_class      # from Layer 30
      size         = var.storage_size
    }

    resources = {
      requests = { cpu = var.cpu_request, memory = var.mem_request }
      limits   = { cpu = var.cpu_limit,   memory = var.mem_limit }
    }

    # Single sign-on through Keycloak (see step 5)
    auth = {
      oidc = {
        enabled          = true
        discoveryUrl     = "https://${var.keycloak_hostname}/realms/platform/.well-known/openid-configuration"
        clientId         = "nifi"
        clientSecretName = "nifi-oidc"
      }
    }
  })]
}
```

### Step 4 — Give NiFi access to Kafka

Strimzi manages Kafka users and permissions declaratively. Add to the **NiFi** layer (not the Kafka layer — the consumer asks for access, and their request is reviewed):

```hcl
resource "kubernetes_manifest" "nifi_kafka_user" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaUser"
    metadata = {
      name      = "nifi"
      namespace = "kafka"
      labels    = { "strimzi.io/cluster" = "${var.org}-${var.env}" }
    }
    spec = {
      authentication = { type = "tls" }
      authorization = {
        type = "simple"
        acls = [
          {
            resource  = { type = "topic", name = "events", patternType = "literal" }
            operations = ["Read", "Describe"]
          },
          {
            resource  = { type = "group", name = "nifi-", patternType = "prefix" }
            operations = ["Read"]
          },
          {
            resource  = { type = "topic", name = "nifi-out-", patternType = "prefix" }
            operations = ["Write", "Describe", "Create"]
          },
        ]
      }
    }
  }
}
```

Strimzi creates a Kubernetes Secret named `nifi` in the `kafka` namespace containing the client certificate. Copy it into the `nifi` namespace (with Reflector, External Secrets, or a small Terraform data + resource pair) and point NiFi at:

```
Bootstrap:  acme-dev-kafka-bootstrap.kafka.svc.cluster.local:9093
Security:   SSL, client cert from the 'nifi' secret
```

> **Least privilege, in practice:** NiFi may *read* `events`, and may *write* only to topics starting with `nifi-out-`. It cannot touch `orders` or `audit`. Write the ACLs narrowly on day one — widening later is a one-line PR; narrowing later is a fight.

### Step 5 — Add single sign-on

The Keycloak client already exists (we defined `nifi` in the realm in Layer 50b). Fetch its secret and hand it to NiFi:

```hcl
resource "kubernetes_secret_v1" "nifi_oidc" {
  metadata {
    name      = "nifi-oidc"
    namespace = "nifi"
  }
  data = {
    clientSecret = var.nifi_oidc_secret   # from Secrets Manager, not git
  }
}
```

### Step 6 — Give the team access to their namespace only

Back in Layer 20, add an access entry:

```hcl
access_entries = {
  nifi_team = {
    principal_arn = "arn:aws:iam::123456789012:role/nifi-developers"
    policy_associations = {
      edit = {
        policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
        access_scope = {
          type       = "namespace"
          namespaces = ["nifi"]
        }
      }
    }
  }
}
```

They can now `kubectl` inside `nifi` and nowhere else.

## D.5 The onboarding checklist (copy into your PR template)

**Node pool layer (only if the app needs its own pool)**

- [ ] Layer directory follows the naming convention `40-nodepool-<app>`
- [ ] **`key` in every `*.s3.tfbackend` is unique and matches the directory name**
- [ ] `cpu_limit` is set to a real number, not the default
- [ ] `labels` includes `workload = "<app>"`
- [ ] `taints` uses `dedicated=<app>:NoSchedule` if isolation is needed
- [ ] `capacity_types` is `["on-demand"]` for anything stateful
- [ ] `architectures` matches the container images (is the image multi-arch?)
- [ ] `disruption_budget` and `termination_grace_period` reflect how the app fails

**App layer**

- [ ] Namespace created with a Pod Security Standard label
- [ ] Every pod has a matching `nodeSelector` **and** `toleration`
- [ ] Resource `requests` set on every container (Auto Mode sizes nodes from requests — no requests means bad bin-packing)
- [ ] `readinessProbe` and `livenessProbe` defined
- [ ] **PodDisruptionBudget** exists (nodes get replaced; this is not optional)
- [ ] `topologySpreadConstraints` across `topology.kubernetes.io/zone`
- [ ] PVCs use a StorageClass from Layer 30 with the right reclaim policy
- [ ] Ingress uses `ingressClassName: alb` and a hostname you actually own
- [ ] Kafka access requested via a `KafkaUser` with **narrow** ACLs
- [ ] OIDC client added to the Keycloak realm
- [ ] Team's IAM role added to Layer 20 access entries, namespace-scoped
- [ ] Cost tags applied (`CostCenter`, `Owner`)
- [ ] `dev` applied and smoke-tested before `stage`; `stage` before `prod`

## D.6 Onboarding a *new environment* (bonus)

Adding `stage` to an existing platform:

```bash
# 1. New AWS account (recommended) and state bucket
./scripts/tf.sh stage 00-bootstrap apply

# 2. Add envs/stage.tfvars and envs/stage.s3.tfbackend to EVERY layer
for d in layers/*/; do
  cp "$d/envs/dev.tfvars"       "$d/envs/stage.tfvars"
  cp "$d/envs/dev.s3.tfbackend" "$d/envs/stage.s3.tfbackend"
  sed -i 's/dev/stage/g' "$d/envs/stage.tfvars" "$d/envs/stage.s3.tfbackend"
done
# 3. REVIEW every generated file by hand. sed is a starting point, not an answer.

# 4. Apply in dependency order
for L in 10-network 15-toolbox 20-cluster 30-platform \
         40-nodepool-kafka 40-nodepool-keycloak 40-nodepool-apps \
         50-app-kafka 50-app-keycloak; do
  ./scripts/tf.sh stage "$L" apply
done
```

That the whole environment is reproducible from one loop is the *point* of the layered design.

---

# PART E — Day-2 Operations

## E.1 Order of operations

**Building up** (dependencies first):

```
00-bootstrap -> 10-network -> 15-toolbox -> 20-cluster -> 30-platform
             -> 40-nodepool-* -> 50-app-*
```

**Tearing down** (exact reverse):

```
50-app-* -> 40-nodepool-* -> 30-platform -> 20-cluster -> 15-toolbox -> 10-network
```

> **Destroy warning that costs people real money:** `terraform destroy` on the cluster layer does **not** clean up things created *by controllers inside* the cluster — ALBs, EBS volumes, ENIs, security groups made by the load balancer controller and the CSI driver. They are not in Terraform state, so they survive as orphans and keep billing. **Always delete Kubernetes Services and Ingresses first**, wait for the ALBs to disappear from the EC2 console, then destroy the cluster layer. Then go hunting for leftovers.

## E.2 Updating one app's node pool without touching anything else

The scenario you designed for:

```bash
# Kafka team, Tuesday 10:00 - needs more memory
cd layers/40-nodepool-kafka
vim envs/prod.tfvars                  # instance_sizes = ["4xlarge"]
../../scripts/tf.sh prod 40-nodepool-kafka plan
# Plan: 0 to add, 1 to change, 0 to destroy.
../../scripts/tf.sh prod 40-nodepool-kafka apply

# Web team, Tuesday 10:01 - completely unaffected, running in parallel
./scripts/tf.sh prod 40-nodepool-apps apply
```

**What happens in the cluster:** changing a NodePool does *not* immediately kill running nodes. Auto Mode applies the new requirements to *future* nodes, and gradually replaces existing ones according to `disruption.budgets` and `expireAfter`. To force it faster:

```bash
# Drain a specific node so a replacement is created with the new spec
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data

# Or delete the NodeClaim, which is Auto Mode's record of that node
kubectl get nodeclaims
kubectl delete nodeclaim <name>
```

Do this **one node at a time** for stateful workloads.

## E.3 Upgrading Kubernetes

Auto Mode makes this much less scary, because AWS handles node images. The process:

```bash
# 1. Check for problems FIRST. EKS tells you about deprecated APIs.
aws eks list-insights --cluster-name acme-dev
aws eks describe-insight --cluster-name acme-dev --id <id>

# 2. Bump dev
vim layers/20-cluster/envs/dev.tfvars     # kubernetes_version = "1.35"
./scripts/tf.sh dev 20-cluster apply      # ~10-15 min, control plane only

# 3. Soak dev for at least a week. Run your integration tests.
# 4. Repeat for stage. Soak.
# 5. Prod, in a maintenance window.
```

Rules:

- **One minor version at a time.** 1.33 to 1.35 must go through 1.34.
- **Upgrades are one-way.** There is no downgrade. Test in dev.
- **Prod stays one minor behind the newest release.** Let the newest version's bugs be someone else's problem.
- Auto Mode replaces nodes with the new version automatically after the control plane upgrade, respecting your disruption budgets and PDBs.
- Watch for **deprecated API removals** — that is what breaks upgrades, not the upgrade itself. `kubectl` plus `kube-no-trouble` (kubent) will find them.

## E.4 Upgrading operators

| Component | How | Danger |
|---|---|---|
| **Strimzi** | Bump `strimzi_version` in Layer 30 | **CRDs.** Read the release notes. Strimzi 1.0 removed the `v1beta2` API. Follow the CRD upgrade instructions exactly. |
| **Kafka itself** | Bump `kafka_version`, apply, wait for the rolling restart, **then** bump `metadataVersion` | Bump `metadataVersion` too early and older brokers cannot rejoin. It is a one-way door. |
| **Keycloak** | Bump `keycloak_version` in Layer 30 (operator) and re-apply | Database schema migration runs on first start. **Snapshot RDS first.** Some upgrades require deleting and recreating operator objects — check the release notes. |
| **Terraform modules** | Bump the `version` constraint, `terraform init -upgrade`, then **read the plan carefully** | Major bumps can force-replace resources. A plan showing "1 to destroy" on your VPC is not a plan you apply. |

## E.5 When someone leaves a lock behind

```bash
terraform plan -var-file=envs/prod.tfvars
# Error: Error acquiring the state lock
#   Lock Info:
#     ID:        1a2b3c...
#     Who:       priya@laptop
#     Created:   2026-08-04 09:12:31

# 1. ASK PRIYA FIRST. She may be mid-apply.
# 2. Only if you are certain the process is dead:
terraform force-unlock 1a2b3c...
```

Force-unlocking during a live apply is one of the few ways to genuinely corrupt state. Because the bucket has versioning enabled, you can recover:

```bash
aws s3api list-object-versions \
  --bucket acme-tfstate-prod-999888777666 \
  --prefix prod/20-cluster/terraform.tfstate

aws s3api get-object \
  --bucket acme-tfstate-prod-999888777666 \
  --key prod/20-cluster/terraform.tfstate \
  --version-id <previous-good-version> \
  restored.tfstate

terraform state push restored.tfstate
```

This is exactly why versioning was mandatory back in Layer 00.

## E.6 Drift detection

Things change outside Terraform — a console click, an operator writing back a field.

```bash
# Nightly in CI, per layer. Exit code 2 = drift detected.
terraform plan -var-file=envs/prod.tfvars -detailed-exitcode -lock=false
```

| Exit code | Meaning |
|---|---|
| 0 | No changes. All good. |
| 1 | Error. |
| 2 | Drift. Something changed outside Terraform — investigate. |

Alert on 2. Expect some noise from Kubernetes resources where controllers add fields; use `lifecycle { ignore_changes = [...] }` for the genuinely-managed-elsewhere ones.

## E.7 CI/CD outline

```yaml
# Conceptual pipeline - adapt to GitHub Actions / GitLab / whatever
on: pull_request
jobs:
  plan:
    strategy:
      matrix:
        layer: [10-network, 20-cluster, 30-platform,
                40-nodepool-kafka, 40-nodepool-keycloak, 40-nodepool-apps,
                50-app-kafka, 50-app-keycloak]
    steps:
      - assume role via OIDC       # no long-lived AWS keys in CI, ever
      - terraform fmt -check -recursive
      - terraform validate
      - tflint
      - checkov / tfsec            # security scanning
      - ./scripts/tf.sh dev ${{ matrix.layer }} plan
      - post plan as a PR comment

on: push to main
jobs:
  apply-dev:     auto
  apply-stage:   auto after dev succeeds
  apply-prod:    MANUAL APPROVAL required
```

Because each layer is independent, this matrix runs **in parallel** and a failure in one layer doesn't block the others.

---

# PART F — Best Practices, Pros & Cons, Costs

## F.1 Top 20 best practices

**Terraform**
1. Pin every provider and module to a **specific major version** (`~> 21.0`), and commit `.terraform.lock.hcl`.
2. Use S3 native locking (`use_lockfile = true`); DynamoDB lock tables are deprecated.
3. Enable **versioning** on the state bucket. It is your undo button.
4. Never hand-edit a state file. Use `terraform state mv` / `import` / `rm`.
5. Keep layers small enough that a `plan` finishes in under 60 seconds.
6. `terraform fmt` and `validate` in CI, on every PR.
7. Use `prevent_destroy` on state buckets, prod databases, and anything holding data.
8. No secrets in `.tfvars`. Secrets Manager or SSM SecureString only.

**EKS Auto Mode**
9. Tag your subnets (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`) or load balancers will never appear.
10. Create a StorageClass with `ebs.csi.eks.amazonaws.com`. Auto Mode does not make one for you.
11. Set **`limits.cpu` on every NodePool.** It is the only thing between you and a runaway bill.
12. Set resource **requests** on every container. Auto Mode picks instance sizes from requests.
13. Every workload gets a **PodDisruptionBudget**. Nodes are replaced constantly.
14. Use `topologySpreadConstraints` across zones for anything with more than one replica.
15. Prefer **Graviton (arm64)** — roughly 20% cheaper — but verify your images are multi-arch.
16. Use access entries, never the `aws-auth` ConfigMap.
17. Private API endpoint in prod; reach it from the toolbox EC2.

**Platform**
18. One AWS account per environment. It is the strongest blast-radius boundary that exists.
19. Share one ALB per environment with Ingress groups; ALBs are billed individually.
20. Write down the runbook for "a node disappeared" and actually rehearse it in dev.

## F.2 Anti-patterns

| Anti-pattern | Why it hurts | Do instead |
|---|---|---|
| One giant state file | 20-minute plans; one person's apply blocks everyone; one mistake destroys everything | Layers |
| `count = var.env == "prod" ? 3 : 1` scattered everywhere | Nobody can read the code and know what prod looks like | Variables + tfvars |
| Hardcoded AMI IDs | Rots within weeks; different per region | SSM parameter data source |
| `terraform apply -auto-approve` on prod | No human sees the plan | Manual approval gate |
| Committing `terraform.tfstate` (except bootstrap) | Merge conflicts; secrets in git | Remote state |
| Latest tags on containers and charts | Not reproducible; surprise upgrades | Pin exact versions |
| One ALB per Ingress | $16-22/month each, forever | Ingress group sharing |
| Spot capacity for Kafka brokers | Two brokers reclaimed at once = data at risk | On-demand for stateful |
| Skipping PodDisruptionBudgets | Auto Mode drains all your replicas at once | Always set a PDB |
| Storing Kafka data on `emptyDir` | Node replacement = total data loss | PVC + Retain StorageClass |

## F.3 Rough monthly cost sketch (us-east-1, illustrative only)

Prices change constantly. Use the AWS Pricing Calculator for real numbers. This is for a sense of proportion.

**Dev environment**

| Item | Estimate |
|---|---|
| EKS control plane | ~$73 |
| 1 NAT gateway | ~$33 + data |
| 3 small Kafka nodes (`m7g.large`, on-demand) | ~$180 |
| Auto Mode management fee (~12%) | ~$22 |
| 1 apps node (spot) | ~$15 |
| Kafka EBS (3 x 20 GiB gp3) | ~$5 |
| RDS `db.t4g.micro` single-AZ | ~$13 |
| Shared ALB | ~$18 |
| Toolbox `t3.small` | ~$15 |
| **Total** | **~$375/month** |

**Prod environment**

| Item | Estimate |
|---|---|
| EKS control plane | ~$73 |
| 3 NAT gateways | ~$100 + data |
| 6 Kafka brokers (`r7g.2xlarge`) + 3 controllers | ~$2,600 |
| Auto Mode management fee | ~$310 |
| Kafka EBS (6 x 1000 GiB gp3 with provisioned IOPS) | ~$700 |
| Keycloak nodes (3 x `m7g.large`) | ~$180 |
| Apps nodes (variable) | ~$400 |
| RDS `db.r7g.large` Multi-AZ | ~$450 |
| Shared ALB + data processing | ~$60 |
| Control plane logs, flow logs, CloudWatch | ~$150 |
| **Total** | **~$5,000/month** |

**Biggest savings levers, in order:**
1. `limits.cpu` on every NodePool — caps the worst case
2. Graviton everywhere (~20% off compute)
3. Spot for stateless workloads (~70% off)
4. `single_nat_gateway = true` in dev (~$65/month)
5. Shorter Kafka retention (storage is usually the #1 Kafka line item)
6. Shared ALBs
7. Compute Savings Plans once your baseline is predictable

## F.4 Security checklist

- [ ] Private EKS API endpoint in prod; access via the toolbox EC2
- [ ] Session Manager instead of SSH; no key pairs, no port 22, no public bastion
- [ ] IMDSv2 required (`http_tokens = "required"`) on every EC2
- [ ] EBS encryption on by default in every StorageClass
- [ ] RDS `storage_encrypted = true`, private subnets, security group scoped to the cluster SG
- [ ] Pod Security Standards enforced per namespace (`restricted` where possible)
- [ ] NetworkPolicies so `webapp` cannot reach the `kafka` namespace directly
- [ ] EKS Pod Identity (not node IAM roles) for AWS access from pods
- [ ] Control plane audit logs to CloudWatch, retention set
- [ ] Secrets in Secrets Manager, surfaced via External Secrets Operator
- [ ] Terraform state bucket: TLS-only policy, versioning, encryption, no public access
- [ ] CI uses OIDC role assumption, never static AWS keys
- [ ] Kafka: TLS listeners with `simple` authorization and per-app ACLs
- [ ] Keycloak `master` realm reserved for admins; apps live in their own realm
- [ ] Rotate the Keycloak bootstrap admin password immediately after install

---

# PART G — Troubleshooting

### Pods stuck `Pending` forever

```bash
kubectl describe pod <pod> | tail -30
kubectl get nodepools
kubectl get nodeclaims
kubectl describe nodepool <pool>
```

| Message | Cause | Fix |
|---|---|---|
| `didn't match Pod's node affinity/selector` | No NodePool has your label | Check `labels` in Layer 40 matches the pod's `nodeSelector` |
| `had untolerated taint` | Pod lacks the toleration | Add the toleration matching your pool's taint |
| `nodepool limits exceeded` | You hit `limits.cpu` | Raise `cpu_limit` in tfvars — deliberately |
| `waiting for a volume to be created` | Wrong StorageClass provisioner | Must be `ebs.csi.eks.amazonaws.com`, not `ebs.csi.aws.com` |
| No message, just waits | Requested instance type unavailable in your AZs | Widen `instance_families` / `instance_sizes` |

### Ingress has no ADDRESS

1. Are the subnets tagged? `kubernetes.io/role/elb` on public, `kubernetes.io/role/internal-elb` on private. This is the cause about half the time.
2. Does the IngressClass exist and does its `controller` equal `eks.amazonaws.com/alb`?
3. `kubectl describe ingress <name>` — read the events.
4. Are you using `alb.ingress.kubernetes.io/*` annotations? Auto Mode wants that config in `IngressClassParams` instead.

### `terraform plan` fails with "the Kubernetes API is unreachable"

`kubernetes_manifest` needs API access at plan time.

```bash
aws eks update-kubeconfig --region us-east-1 --name acme-dev
kubectl get ns                      # prove connectivity first
```

If the endpoint is private, run from the toolbox EC2. If your CI cannot reach the cluster, switch that layer to the `alekc/kubectl` provider.

### Strimzi Kafka stuck `NotReady`

```bash
kubectl -n kafka get kafka -o yaml | yq '.items[].status.conditions'
kubectl -n kafka logs deploy/strimzi-cluster-operator --tail=100
kubectl -n kafka get pvc
```

Usual suspects: unsupported `kafka_version` for that operator; PVCs pending (StorageClass problem); pods cannot schedule (taint/toleration mismatch); `metadataVersion` set ahead of the broker version.

### Keycloak `CrashLoopBackOff`

```bash
kubectl -n keycloak logs statefulset/keycloak-statefulset --tail=100
```

Usual suspects: RDS security group doesn't allow the cluster SG on 5432; wrong secret keys (`usernameSecret` / `passwordSecret` names must match the Secret's keys); hostname not set (Keycloak refuses to start in production mode without one); `proxy.headers` missing so it builds `http://` redirect URLs behind an HTTPS ALB.

### Node disappeared and took my app with it

That is Auto Mode doing its job. The app is what needs fixing:

```bash
kubectl get pdb -A                  # do you even have one?
kubectl get nodeclaims -o wide      # what replaced it, and when
kubectl get events -A --sort-by=.lastTimestamp | tail -40
```

Add a PDB, add topology spread constraints, raise `terminationGracePeriod`, tighten `disruption.budgets`.

### "Error acquiring the state lock"

See [E.5](#e5-when-someone-leaves-a-lock-behind). Ask the human named in the lock before force-unlocking.

---

# Appendix

## A. Glossary

| Term | Plain English |
|---|---|
| **ACL** | A rule saying which user may read or write which Kafka topic |
| **ALB** | AWS Application Load Balancer — the front door for web traffic |
| **Auto Mode** | EKS feature where AWS manages nodes, storage, networking and load balancing for you |
| **CRD** | Custom Resource Definition — teaches Kubernetes a new object type (e.g. `Kafka`) |
| **Drift** | Reality no longer matches your Terraform code |
| **IRSA / Pod Identity** | Ways for a pod to get AWS permissions without stored keys |
| **KRaft** | Kafka's built-in metadata system that replaced ZooKeeper |
| **NodeClaim** | Auto Mode's record of one node it created |
| **NodeClass** | *How* to build a node (subnets, IAM role, disk) |
| **NodePool** | *What* nodes are allowed and who may use them |
| **Operator** | A program inside the cluster that knows how to run a specific piece of software |
| **PDB** | PodDisruptionBudget — "never take more than N of my pods down at once" |
| **PVC** | PersistentVolumeClaim — a pod asking for a disk |
| **Realm** | A Keycloak walled garden of users, roles and apps |
| **State file** | Terraform's record of what it has already built |
| **StorageClass** | A template describing what kind of disk to create |
| **Taint / Toleration** | A "keep out" sign on a node / the pass that lets you past it |

## B. Command cheat sheet

```bash
# ---- Terraform ----
./scripts/tf.sh dev 40-nodepool-kafka plan
./scripts/tf.sh prod 20-cluster apply
terraform init -reconfigure -backend-config=envs/prod.s3.tfbackend
terraform state list
terraform state show module.eks.aws_eks_cluster.this[0]
terraform output -raw cluster_endpoint
terraform force-unlock <LOCK_ID>

# ---- Cluster access ----
aws eks update-kubeconfig --region us-east-1 --name acme-dev
aws ssm start-session --target i-0abc123
aws eks list-access-entries --cluster-name acme-dev

# ---- Auto Mode ----
kubectl get nodepools
kubectl get nodeclasses
kubectl get nodeclaims -o wide
kubectl describe nodepool kafka
kubectl get nodes -L workload,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# ---- Kafka ----
kubectl -n kafka get kafka,kafkanodepool,kafkatopic,kafkauser
kubectl -n kafka wait kafka/acme-dev --for=condition=Ready --timeout=15m
kubectl -n kafka logs deploy/strimzi-cluster-operator -f

# ---- Keycloak ----
kubectl -n keycloak get keycloak,pods,ingress
kubectl -n keycloak get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d

# ---- Debugging ----
kubectl get events -A --sort-by=.lastTimestamp | tail -40
kubectl describe pod <pod> -n <ns>
kubectl top nodes    # needs metrics-server
```

## C. Version Matrix

Verified current as of **August 2026**. Always re-check before you pin — this is the section that ages fastest.

| Component | Version used here | Notes |
|---|---|---|
| Terraform | `>= 1.11` | 1.11 made `use_lockfile` GA and deprecated `dynamodb_table` |
| AWS provider | `~> 6.0` | v6 GA June 2025; per-resource `region` support |
| Kubernetes provider | `~> 2.38` | `kubernetes_manifest` needs API access at plan time |
| Helm provider | `~> 3.0` | v3 changed `kubernetes` from a block to an attribute |
| `terraform-aws-modules/eks` | `~> 21.0` | v21 removed the `aws-auth` submodule; `compute_config` = Auto Mode |
| `terraform-aws-modules/vpc` | `~> 6.0` | Requires AWS provider v6 |
| EKS Kubernetes version | `1.34` (dev may run `1.35`) | EKS added 1.35 support in January 2026. Prod stays one minor behind. |
| Strimzi operator | `1.1.0` | Uses `kafka.strimzi.io/v1`; `v1beta2` removed in 1.0 |
| Apache Kafka | `4.1.x` | KRaft only. Check your Strimzi release notes for the exact supported list. |
| Keycloak | `26.7.x` | CRD group `k8s.keycloak.org`, version `v2alpha1` |
| PostgreSQL (RDS) | `16.x` | Keycloak supports a range; check the Keycloak docs |

## D. Where to read more

- Amazon EKS User Guide — Auto Mode: node classes, node pools, storage classes, ALB configuration
- `terraform-aws-modules/terraform-aws-eks` on GitHub — the `examples/` directory has a working Auto Mode example
- `aws-samples/sample-aws-eks-auto-mode` — deployable Terraform examples, including a cleanup script for orphaned resources
- Strimzi documentation — "Deploying and Managing" and "Configuring" for your exact operator version
- Keycloak Operator Guide — installation, hostname, and high-availability configuration
- Terraform S3 backend docs — the authoritative word on `use_lockfile`

## E. What to do next

1. **Do the quick start (Part A).** Don't read ahead; build it. It costs a few dollars and an hour.
2. Add the toolbox EC2 and confirm you can reach the cluster through Session Manager.
3. Add Layer 30 and deploy anything with a PVC to prove your StorageClass works.
4. Add **one** node pool with a taint, and deploy a pod that tolerates it. Watch the node appear.
5. Only then add Kafka. It is the most demanding workload in this guide.
6. Add Keycloak, then wire one app to it for SSO.
7. Write the onboarding page (Part D) into your wiki and let a real team try it. Their questions will tell you what your platform is missing.
