# The AWS Upgrade Guide: Keeping Your Cloud Current

*A complete, beginner-friendly guide to upgrading the things that go stale in AWS — current as of July 2026*

> **Companion note:** This guide covers AWS infrastructure broadly. For a deep, step-by-step walkthrough of **Lambda Python runtime** upgrades specifically, see the separate *Upgrading the Python Version of an AWS Lambda Function* guide. Here, Lambda is just one section among many.

---

## Table of Contents

1. [Why AWS Things Need Upgrading (Background)](#1-background)
2. [The One Big Deadline Driving Everything Right Now](#2-big-deadline)
3. [Quick Start: Upgrade a Base AMI on One Server](#3-quick-start)
4. [The Universal Upgrade Playbook (Works for Everything)](#4-playbook)
5. [AMIs & the Operating System (EC2)](#5-ami)
6. [Auto Scaling Groups & Launch Templates](#6-asg)
7. [Containers: ECS, EKS, and Fargate](#7-containers)
8. [Databases: RDS & Aurora](#8-databases)
9. [Lambda Runtimes (Summary)](#9-lambda)
10. [Elastic Beanstalk & Other Managed Platforms](#10-beanstalk)
11. [Application Load Balancers, TLS, and IMDS](#11-alb-tls)
12. [Container Base Images & Application Dependencies](#12-base-images)
13. [How to Find Everything That Needs Upgrading](#13-finding)
14. [Options Compared: Tools for Doing Upgrades](#14-options)
15. [Gotchas Master List](#15-gotchas)
16. [Key Dates Reference Table](#16-dates)
17. [Glossary](#17-glossary)

---

<a name="1-background"></a>
## 1. Why AWS Things Need Upgrading (Background)

### The core idea

When you run software in the cloud, almost everything you use sits on top of *other* software that its makers keep improving and, eventually, stop supporting. When the makers stop supporting a version — because it's old, or has security holes they won't patch anymore — that version reaches **end-of-life (EOL)** or, in AWS's words, **end-of-support (EOS)**. After that point:

- No more **security patches**, so you're exposed to newly discovered vulnerabilities.
- No more **bug fixes**.
- No more **technical support** from AWS.
- Sometimes, **things break on their own** — an expired security certificate, an incompatible dependency, or a service that simply stops accepting the old version.

Upgrading means moving from an old, unsupported version to a newer, supported one *before* the old one causes problems.

### What actually goes stale in AWS?

Think of your AWS setup as a stack of layers, each of which ages:

1. **The operating system** — usually delivered as an **AMI** (Amazon Machine Image), the template your servers boot from.
2. **The container platform** — Kubernetes versions in EKS, the agent in ECS, the base OS of your worker nodes.
3. **The database engine** — MySQL, PostgreSQL, etc., in RDS and Aurora.
4. **The language runtime** — Python, Node.js, Java, and so on, especially in Lambda.
5. **Your container base images** — the `FROM` line in your Dockerfile.
6. **Your application's own dependencies** — the libraries your code imports.
7. **Security/network defaults** — TLS versions, load-balancer settings, instance metadata service (IMDS) versions.

Each layer has its own clock. This guide walks through each one.

> **Analogy:** Your AWS environment is like a house. The OS is the foundation, the database is the plumbing, the runtime is the electrical wiring, and your app is the furniture. Any of them can wear out, and ignoring one (a cracked foundation) eventually threatens everything above it.

### A key distinction: what AWS upgrades vs. what you upgrade

- **AWS handles automatically:** small **patch** updates within a version (e.g., a minor Linux security patch, a Lambda runtime patch). These are low-risk.
- **You must handle deliberately:** **major** version jumps (e.g., Amazon Linux 2 → 2023, PostgreSQL 13 → 16, Python 3.9 → 3.13). AWS won't force these on you without warning because they can break your workload. That's what this guide is about.

---

<a name="2-big-deadline"></a>
## 2. The One Big Deadline Driving Everything Right Now

If you read only one section, read this one.

### Amazon Linux 2 reaches end-of-life on **June 30, 2026**

**Amazon Linux 2 (AL2)** has been the default operating system for AWS servers for years — on EC2, ECS, EKS, Elastic Beanstalk, and even underneath older Lambda runtimes. On **June 30, 2026**, AWS stops providing security updates, bug fixes, and new packages for it. Kernel live-patching ends too.

The replacement is **Amazon Linux 2023 (AL2023)**, which is supported until **June 2029**.

### Why this touches almost everything

Because AL2 sits under so many services, this single deadline cascades:

- **EC2 instances** running AL2 need a new AMI.
- **EKS worker nodes:** Kubernetes 1.32 was the *last* version to support AL2 AMIs; AWS stopped publishing new EKS-optimized AL2 AMIs in **November 2025**. Newer Kubernetes requires AL2023 or Bottlerocket.
- **ECS / AWS Batch:** AWS is ending support for ECS AL2-optimized AMIs on **June 30, 2026**. As of **January 12, 2026**, AWS Batch already switched its default AMI for new ECS compute environments to AL2023.
- **Lambda:** the Python 3.10 and 3.11 runtimes (and several others) run on AL2 and are on their own deprecation paths.

### Why it's not a one-click fix

There is **no supported in-place upgrade** from AL2 to AL2023. You build or select a new AL2023 image and migrate onto it. AL2023 also changed enough that some things behave differently (see [gotchas](#15-gotchas)) — most notably, the `amazon-linux-extras` mechanism is gone, `cron` isn't installed by default, and the package manager is now `dnf`.

**Bottom line:** If you have anything on Amazon Linux 2, treat mid-2026 as your migration deadline and start now. The rest of this guide shows how, layer by layer.

---

<a name="3-quick-start"></a>
## 3. Quick Start: Upgrade a Base AMI on One Server

Let's do the most common upgrade end-to-end: moving a single EC2 instance from an old AMI (say, Amazon Linux 2) to a fresh Amazon Linux 2023 AMI. This shows the whole pattern in miniature. (For production fleets, use the [safe playbook](#4-playbook) and [Auto Scaling method](#6-asg) instead.)

### Before you start, you need:

- An AWS account with permission to launch EC2 instances
- An existing instance you want to modernize
- About 20 minutes

### Step 1 — Identify what your instance runs today

In your terminal (with the AWS CLI configured):

```bash
# Which AMI is each instance using?
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{ID:InstanceId,AMI:ImageId,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table
```

Then check whether that AMI is Amazon Linux 2:

```bash
aws ec2 describe-images --image-ids ami-xxxxxxxx \
  --query 'Images[0].Name'
# A name like "amzn2-ami-hvm-2.0.20240306-x86_64-gp2"  ← the "amzn2" prefix means AL2
```

### Step 2 — Find the latest AL2023 AMI

AWS publishes the newest AMI IDs in a lookup service (SSM Parameter Store), so you never have to hard-code them:

```bash
# Latest AL2023 x86_64 AMI ID for your region
aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text
```

(For Graviton/ARM instances, replace `x86_64` with `arm64`.)

### Step 3 — Understand what "upgrade" means here

You do **not** upgrade the OS on the running disk in place. Instead, you follow **immutable infrastructure**: launch a *new* instance from the new AMI, move your app and data onto it, verify, then retire the old one. This is safer and repeatable.

### Step 4 — Launch a new instance from the new AMI

The simplest path is the Console:

1. Go to **EC2 → Instances → Launch instances**.
2. Under **Application and OS Images (AMI)**, choose **Amazon Linux 2023**.
3. Pick the same instance type and settings as your old instance (security groups, IAM role, subnet).
4. In **User data** (advanced settings), put your setup script — but remember AL2023 differences (use `dnf`, not `amazon-linux-extras`).
5. Launch.

### Step 5 — Move your workload and validate

- Install your application and its dependencies on the new instance.
- Copy over or reconnect to your data (for databases, use RDS or a proper data-sync — don't store important data only on an instance disk).
- **Test thoroughly.** Confirm the app starts, serves traffic, and behaves identically.

### Step 6 — Cut over traffic, then retire the old instance

- Repoint your load balancer, DNS, or Elastic IP to the new instance.
- Watch metrics and logs for a while.
- Only once you're confident, terminate the old AL2 instance.
- **Keep the old instance stopped (not terminated) as a rollback option** until you're sure.

**That's the core pattern for every OS/AMI upgrade:** new image → new instance → validate → cut over → retire old, with rollback held until confident. Everything else scales this up.

---

<a name="4-playbook"></a>
## 4. The Universal Upgrade Playbook (Works for Everything)

Every upgrade in this guide — OS, database, container, runtime — follows the same seven steps. Learn this once and apply it everywhere.

### Step 1 — Inventory

Find every resource on the old version. You can't upgrade what you can't see. ([How to find things](#13-finding).)

### Step 2 — Read the release notes and breaking changes

Before touching anything, learn what changed between your current version and the target. This is where you discover the traps. Focus on sections titled *Removed*, *Deprecated*, or *Breaking changes*.

### Step 3 — Snapshot / back up (your rollback baseline)

Create a restore point *before* you change anything:

- **EC2:** create an AMI or EBS snapshot of the current instance.
- **RDS/Aurora:** take a manual DB snapshot.
- **Everything:** keep the old configuration in version control.

This is your safety net. Never skip it.

### Step 4 — Test on a copy, never on production first

Spin up a **non-production** copy and upgrade *that*. Run your full test suite. For databases, RDS can restore a snapshot into a throwaway test instance for exactly this.

### Step 5 — Roll out gradually

Don't flip everything at once. Use **canary** (upgrade a small slice first) and **phased rollout** (critical systems last, with the most testing). Watch metrics between each step.

### Step 6 — Keep a rollback path open

Have a tested way back until the new version is proven. Note that some upgrades are **one-way** once complete (major database upgrades can't be reversed; deprecated runtimes can't be reverted after their block dates) — for those, your snapshot *is* the rollback.

### Step 7 — Decommission the old thing only after you're confident

Once the new version has run cleanly in production for a suitable period, remove the old resources. Deleting unused old resources is also the cleanest way to make deprecation warnings disappear.

> **Golden rule:** *Plan early. Validate carefully. Preserve rollback. Decommission only after confidence.*

---

<a name="5-ami"></a>
## 5. AMIs & the Operating System (EC2)

### What an AMI is

An **AMI (Amazon Machine Image)** is a template that contains the operating system and preinstalled software your EC2 server boots from. Choosing an AMI is choosing your server's starting point. "Upgrading the base AMI" means moving your servers to a newer OS image.

### The main task in 2026: Amazon Linux 2 → Amazon Linux 2023

As covered in [Section 2](#2-big-deadline), AL2 ends support **June 30, 2026**. AL2023 is the successor, supported to **June 2029**, with a predictable ~5-year lifecycle per release.

### Options for your new base OS

| Option | Best for | Trade-offs |
|---|---|---|
| **Amazon Linux 2023** | Staying on the AWS-managed path with lowest friction; general workloads | Not a RHEL clone — software certified only on RHEL derivatives may not carry over. Support ends June 2029 (a ~3-year window). |
| **Bottlerocket** | Container-only hosts (EKS/ECS) wanting a minimal, secure, fast-booting OS | Purpose-built for containers; not for general-purpose servers with lots of OS-level customization. |
| **Ubuntu / RHEL / Rocky Linux, etc.** | Teams needing longer support windows or RHEL binary compatibility | You manage more yourself; less tight AWS toolchain integration. |

For most AWS teams, **AL2023 is the natural choice.** Consider alternatives if you specifically need RHEL compatibility or a support window longer than 2029.

### How to do it (immutable infrastructure)

The right approach is **not** an in-place OS upgrade (there isn't a supported one). Instead:

1. Find the latest AL2023 AMI via SSM Parameter Store (see [Quick Start Step 2](#3-quick-start)).
2. Build a new instance (or better, a new [launch template + Auto Scaling Group](#6-asg)) from it.
3. Reinstall your app, accounting for AL2023 differences.
4. Validate, cut over, retire the old instance.

**For stateful single servers** (databases on EC2, etc.), run the new instance in **parallel**, sync data with validation, and do a controlled DNS/IP cutover — never a risky in-place swap.

### Key AL2 → AL2023 gotchas (full list in [Section 15](#15-gotchas))

- `amazon-linux-extras` is **removed** — install packages with `dnf` directly.
- `cron` is **not installed by default** — migrate scheduled jobs to **systemd timers**.
- Package manager is **DNF** (`yum` still works as an alias, so command syntax is rarely the hard part).
- **EPEL compatibility dropped**, **32-bit application support removed**, kernel moves from **5.10 → 6.1**.
- Some packages present in AL2 aren't in AL2023 (e.g., Python 2.7, OpenJDK 7).

---

<a name="6-asg"></a>
## 6. Auto Scaling Groups & Launch Templates

### Why this matters

Most production EC2 fleets don't run hand-launched instances — they use an **Auto Scaling Group (ASG)** that launches instances automatically from a **Launch Template**. The launch template names the AMI. So upgrading the fleet's OS means **updating the launch template's AMI, then rolling the fleet**.

### The clean method: new launch template version + instance refresh

1. **Create a new launch template version** pointing at the new AL2023 AMI. Launch templates are versioned, so the old version stays as a rollback.
2. **Update the ASG** to use the new template version.
3. **Trigger an Instance Refresh** with a canary and health checks. This gradually replaces old instances with new ones, a few at a time, pausing if health checks fail.

In **Terraform**, the pattern looks like:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# For ARM/Graviton instances:
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}
```

Reference `data.aws_ami.al2023.id` in your launch template, then apply — Terraform creates a new template version and (with instance refresh configured) rolls the fleet.

### Best practices

- **Use a canary:** replace one instance first, validate, then continue.
- **Set `max_unavailable` low** (e.g., 1) so capacity stays healthy during the roll.
- **Keep the previous launch template version** so rollback is a one-line pointer change.
- **Health checks gate the rollout** — a failing new AMI stops the refresh instead of taking down the fleet.

---

<a name="7-containers"></a>
## 7. Containers: ECS, EKS, and Fargate

Containers have **two** things that age: the **orchestration platform version** and the **base OS of the worker nodes**. (Plus your container images — see [Section 12](#12-base-images).)

### 7.1 Amazon EKS (Kubernetes)

**EKS runs Kubernetes**, which releases new versions regularly. Each version has a support window; after it, you're on **extended support** (extra cost) or must upgrade.

**Two upgrade tracks to keep straight:**

1. **The Kubernetes control-plane version** (e.g., 1.31 → 1.32 → 1.33). You upgrade this one minor version at a time. Check API deprecations before each step — removed Kubernetes APIs are the classic breakage.
2. **The worker node OS.** This is urgent in 2026: **Kubernetes 1.32 was the last version to support AL2 AMIs.** To run newer Kubernetes you must move nodes to **AL2023** or **Bottlerocket**, which enable **cgroup v2** by default (AL2's cgroup v1 is now in maintenance mode upstream).

**Node OS migration (safe pattern):**
- Add a new node group running AL2023 (or Bottlerocket).
- **Cordon** the old AL2 nodes so no new pods schedule on them.
- **Drain** them gradually, letting workloads reschedule onto the new nodes.
- Validate cluster add-ons and workloads.
- Remove the AL2 node group only after stability is confirmed; keep rollback until then.

In Terraform, the node group AMI type changes like this:

```hcl
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "workers"

  # Before: ami_type = "AL2_x86_64"
  ami_type       = "AL2023_x86_64_STANDARD"   # After
  instance_types = ["m5.large"]

  scaling_config {
    desired_size = 3
    max_size     = 6
    min_size     = 1
  }

  update_config {
    max_unavailable = 1   # roll nodes gradually
  }
}
```

**Choosing between AL2023 and Bottlerocket for nodes:** pick **AL2023** if you need OS-level access or heavy node customization; pick **Bottlerocket** for a minimal, container-optimized, fast-booting node with a smaller attack surface and few customizations.

### 7.2 Amazon ECS

ECS worker instances (in the EC2 launch type) boot from **ECS-optimized AMIs**. The AL2-based ones lose support **June 30, 2026**; move to the **AL2023-based ECS-optimized AMI**. If you use **AWS Batch** on ECS, note its default already switched to AL2023 in January 2026, and Batch will block creating new AL2-based ECS compute environments after June 30, 2026.

**Fargate** (serverless containers) is easier: AWS manages the underlying OS, so you mainly keep your **platform version** current and your **container base images** patched.

### 7.3 The shortcut: use the latest optimized AMI automatically

For both ECS and EKS, reference the latest optimized AMI via SSM Parameter Store rather than hard-coding IDs, so each fleet roll picks up the newest patched image.

---

<a name="8-databases"></a>
## 8. Databases: RDS & Aurora

Databases are the **highest-stakes** upgrades because they hold your data and major upgrades are **one-way**. Take snapshots and test rigorously.

### How database version support works

**RDS** and **Aurora** run engines like **MySQL** and **PostgreSQL**. Each major engine version has an **end of standard support** date (usually tracking the open-source community's EOL). After that date, AWS auto-enrolls you in **RDS Extended Support** — a **paid** program that keeps you patched for **up to 3 years** while you plan your upgrade. If you do nothing for those 3 years, AWS eventually **force-upgrades** you.

**The trade-off:** Extended Support buys time but costs extra (billed hourly, and it adds up). Upgrading before the standard-support date avoids the charge entirely.

### Current examples to act on (as of 2026)

| Engine version | End of standard support | What happens next |
|---|---|---|
| **RDS/Aurora PostgreSQL 13** | **Feb 28, 2026** | Upgrade before Mar 1, 2026 to avoid Extended Support charges. Target PostgreSQL 16+. |
| **RDS MySQL 8.0** | **Jul 31, 2026** | Extended Support year-1 pricing starts Aug 1, 2026. |
| **MySQL 5.7 / PostgreSQL 11** | Already past | Already in Extended Support; upgrade to MySQL 8.0 / a supported PostgreSQL. |
| **Aurora MySQL 2 (5.7-compatible)** | Already past | In Extended Support; move to Aurora MySQL 3. |

*(These dates track community EOL and can shift; always confirm against the live AWS release calendar.)*

### The safe database upgrade procedure

Databases deserve the most careful version of the [universal playbook](#4-playbook):

```bash
# 1. Snapshot first — this is your rollback baseline
aws rds create-db-snapshot \
  --db-instance-identifier my-legacy-db \
  --db-snapshot-identifier pre-upgrade-snapshot

# 2. Restore the snapshot as a TEST instance
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier my-legacy-db-test-upgrade \
  --db-snapshot-identifier pre-upgrade-snapshot \
  --db-instance-class db.m5.large

# 3. Upgrade the TEST instance (not production)
aws rds modify-db-instance \
  --db-instance-identifier my-legacy-db-test-upgrade \
  --engine-version 8.0.46 \
  --allow-major-version-upgrade \
  --apply-immediately
```

Then **run your full application test suite against the upgraded test instance.** Only after it passes do you schedule the production upgrade (in a maintenance window).

### Database-specific gotchas

- **Major upgrades are irreversible** — you cannot roll back a completed major version upgrade. Your pre-upgrade snapshot is the only way back.
- **Mandatory prechecks:** RDS runs automatic compatibility prechecks. If they find problems, RDS cancels the upgrade *before* stopping your instance and writes details to a `PrePatchCompatibility.log` file — read it.
- **Extension/parameter changes** between major versions (e.g., PostgreSQL deprecating certain parameters). Review the engine release notes.
- **Application compatibility:** SQL behavior, drivers, and connection settings can change across major versions. Test the *app*, not just the database.
- **Track Extended Support spend** in Cost Explorer (look for usage types containing `ExtendedSupport`) so surprise charges don't creep in.

---

<a name="9-lambda"></a>
## 9. Lambda Runtimes (Summary)

Lambda functions run on a **runtime** (a language version bundled with an OS). AWS applies small patches automatically but never jumps you across major language versions — you do that deliberately.

**The task:** change the runtime identifier (e.g., `python3.9` → `python3.13`, `nodejs18.x` → `nodejs22.x`) and test.

**Deprecation happens in stages:** the runtime stops getting patches, then new-function creation is blocked (~30+ days later), then existing-function updates are blocked (~60+ days later). **Invocations never stop** — your function keeps running even on a dead runtime, just unpatched and unchangeable.

**Current pressure points:**
- **Python 3.9** is deprecated; function create/update blocks land **Aug 31 / Sep 30, 2026**. Move to **Python 3.13** (or 3.12).
- **Node.js 18** is deprecated (same block dates); move to **Node.js 22**.
- **Python 3.10 / 3.11** run on Amazon Linux 2 and deprecate sooner — prefer 3.12+ which run on AL2023.

**Best practice:** use **versions and aliases** to shift traffic gradually and roll back instantly — but remember you can't roll back to a runtime after its "block update" date.

> For the full step-by-step method, breaking-change list (e.g., `distutils` removed in Python 3.12), and dependency-rebuild guidance, see the dedicated **Lambda Python upgrade guide**.

---

<a name="10-beanstalk"></a>
## 10. Elastic Beanstalk & Other Managed Platforms

### Elastic Beanstalk

**Elastic Beanstalk** deploys your app onto EC2 for you, using a **platform version** that bundles an OS + language runtime + web server. These platforms are versioned and retired over time — and the AL2-based Beanstalk platforms are affected by the **June 30, 2026** AL2 deadline just like everything else.

**How to upgrade:**
1. Check which **platform branch** each environment runs (AL2-based branches are being retired in favor of AL2023-based ones).
2. In the Beanstalk console or CLI, **update the environment's platform version** to the latest AL2023-based branch for your language.
3. Beanstalk supports **immutable** and **blue/green** deployment options — prefer these so you can validate the new platform and roll back by swapping environment URLs.
4. Test in a **clone** of the environment first.

### The general pattern for any managed platform

AWS has many managed services that wrap a runtime or OS (Beanstalk, App Runner, managed workflow services, etc.). The upgrade pattern is always the same: **find the platform/version setting → check the target version's release notes → update it on a non-prod copy → validate → promote → keep rollback.** The universal playbook applies everywhere.

---

<a name="11-alb-tls"></a>
## 11. Application Load Balancers, TLS, and IMDS

Some upgrades aren't about versions of software but about **security defaults** that age.

### TLS / SSL security policies

Load balancers (ALB/NLB) use a **security policy** that defines which TLS versions and ciphers they accept. Old policies permit outdated, weak protocols (e.g., TLS 1.0/1.1). Periodically **update the listener's security policy** to a current one that requires TLS 1.2+ (or 1.3). Test that your clients can still connect before enforcing stricter policies.

### IMDSv2 (Instance Metadata Service)

EC2 instances expose metadata (including credentials) via the **Instance Metadata Service**. The older **IMDSv1** is less secure; **IMDSv2** requires a session token and defends against certain attacks. **AL2023 enables IMDSv2-only by default** — a good reason the OS migration improves your security posture. For existing instances, enforce IMDSv2:

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-xxxxxxxx \
  --http-tokens required \
  --http-endpoint enabled
```

Confirm your applications and SDKs use IMDSv2 (all current AWS SDKs do) before enforcing, so nothing that reads metadata breaks.

### Certificates

TLS certificates expire. Use **AWS Certificate Manager (ACM)** with managed renewal where possible so certs rotate automatically. Watch for anything using manually managed certificates — an expired cert is a classic "it worked yesterday" outage, and deprecated OS/runtimes can hit cert issues too.

---

<a name="12-base-images"></a>
## 12. Container Base Images & Application Dependencies

Even fully serverless setups have two things *you* own and must keep fresh: your **container base images** and your **application dependencies**.

### Container base images (the `FROM` line)

Every Docker image starts `FROM` some base image (e.g., `FROM amazonlinux:2`, `FROM python:3.9`, `FROM node:18`). That base ages exactly like a server OS:

- Base images built on **Amazon Linux 2** should move to **Amazon Linux 2023** base images. Remember the package-manager change to `dnf`/`microdnf` and the removal of `amazon-linux-extras`.
- Language base images (`python:3.9`, `node:18`) should track supported language versions.

**How to stay current:**
1. Update the `FROM` tag to a supported base.
2. Rebuild and **re-test** — a new base can bring newer system libraries that change behavior.
3. **Rebuild regularly**, not just once. For container-based Lambda and ECS/EKS, *you* are responsible for rebuilding from the latest patched base image; AWS won't patch your image for you.
4. Scan images for vulnerabilities (e.g., with Amazon ECR image scanning) and rebuild when the base publishes fixes.

### Application dependencies

The libraries your code imports (via `pip`, `npm`, `maven`, etc.) have their own security fixes and breaking changes.

- Keep dependencies **pinned** (so builds are reproducible) but **updated on a schedule** (so you get security fixes).
- When you jump a major language version, expect some dependencies to need upgrading too — especially anything with **compiled/native components**, which must be rebuilt for the new language version, OS, and CPU architecture (`x86_64` vs `arm64`).
- Automate dependency-update pull requests where you can, and let your test suite gate them.

---

<a name="13-finding"></a>
## 13. How to Find Everything That Needs Upgrading

You can't upgrade what you haven't found. Use these tools to build your inventory across all accounts and regions.

### AWS Trusted Advisor
Has built-in checks that flag deprecated/soon-to-be-deprecated resources (notably Lambda runtimes) with advance notice, scanning all versions. Can email you weekly summaries.

### AWS Health Dashboard
Shows **Scheduled changes** and deprecation notices for your account, with affected-resource lists, at least 180 days ahead for runtimes. (Some notices expire after the deprecation date, so don't rely on it as your only tracker.)

### AWS Config
Records the configuration of your resources over time and can flag resources that violate rules (e.g., "EC2 instances not on approved AMIs," "RDS on unsupported engine versions"). Good for continuous, account-wide detective controls.

### CLI inventory commands

```bash
# EC2 instances and their AMIs
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{ID:InstanceId,AMI:ImageId}' --output table

# RDS instances and engine versions
aws rds describe-db-instances \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Engine:Engine,Version:EngineVersion}' \
  --output table

# Aurora clusters and engine versions
aws rds describe-db-clusters \
  --query 'DBClusters[*].{Cluster:DBClusterIdentifier,Engine:Engine,Version:EngineVersion}' \
  --output table

# Lambda functions on old runtimes
aws lambda list-functions \
  --query 'Functions[?Runtime==`python3.9` || Runtime==`nodejs18.x`].{Name:FunctionName,Runtime:Runtime}' \
  --output table
```

Repeat CLI commands **per region** — most don't search across regions automatically.

### Third-party inventory tools
Asset-management and cloud-governance tools can build a cross-account "what's reaching end of life and when" report, which is invaluable at scale.

> **Tip:** The cheapest upgrade is deletion. Removing resources you no longer use eliminates both the risk and the deprecation warning.

---

<a name="14-options"></a>
## 14. Options Compared: Tools for Doing Upgrades

However you make changes, one principle dominates: **if a resource is managed by Infrastructure as Code, change it there — not by hand.** A manual Console/CLI change to an IaC-managed resource creates **drift** and gets overwritten on the next deploy.

| Approach | Pros | Cons | Best for |
|---|---|---|---|
| **AWS Console** (click) | Easiest to learn; visual; no setup | Doesn't scale; manual mistakes; not tracked in version control | One-off changes, learning |
| **AWS CLI** (scripted) | Scriptable across many resources; good for discovery + bulk changes | Causes drift if the resource is IaC-managed; you handle testing/rollback yourself | Resources *not* under IaC; bulk fixes |
| **Infrastructure as Code** (CloudFormation/SAM/CDK/Terraform) | Tracked, reviewable, repeatable; consistent across environments; easy rollback via version control | Requires resources already defined in IaC; a careless change can hit many resources | **The recommended default** for any team using IaC |
| **AWS-native automation** (Instance Refresh, Systems Manager, managed upgrade paths, AWS Transform custom) | Built-in gradual rollout and health gating; can automate at large scale (incl. code changes) | More to learn; can be overkill for a few resources | Fleets and large organizations |

**Decision shortcut:**
- A handful of resources, not in IaC → **CLI** (or Console for one-offs).
- Anything defined in IaC → **edit the IaC** and deploy.
- Large fleets / many accounts → **native automation** (Instance Refresh for EC2, managed upgrades for RDS/EKS, AWS Transform custom for code-level runtime upgrades).

---

<a name="15-gotchas"></a>
## 15. Gotchas Master List

The traps that most often turn a routine upgrade into an incident, grouped by area.

### Operating system (AL2 → AL2023)
- **`amazon-linux-extras` is gone.** Any user-data script or Dockerfile using it breaks. Use `dnf` directly.
- **`cron` isn't installed by default.** Migrate scheduled jobs to **systemd timers** *before* migrating.
- **EPEL compatibility dropped; 32-bit apps unsupported; kernel 5.10 → 6.1.** Check package availability and any kernel-dependent software.
- **No supported in-place upgrade.** You must move to a new AL2023 image, not upgrade the old disk.
- **Some packages missing in AL2023** (Python 2.7, OpenJDK 7, various legacy tools).

### Containers
- **EKS: removed Kubernetes APIs** are the top cause of broken cluster upgrades — check API deprecations before each minor-version step.
- **EKS node OS: Kubernetes 1.32 was the last to support AL2 AMIs.** Newer Kubernetes needs AL2023/Bottlerocket (cgroup v2).
- **Container base image change** (AL2 → AL2023) switches the package manager and system libraries — rebuild and retest, don't assume identical behavior.

### Databases
- **Major version upgrades are irreversible.** Snapshot first; that snapshot is your only rollback.
- **Prechecks can cancel the upgrade** — read `PrePatchCompatibility.log`.
- **Extended Support charges accrue silently** once standard support ends. Track spend or upgrade before the date.
- **App-level compatibility** (SQL, drivers, deprecated parameters) changes across major versions — test the application.

### Runtimes & dependencies
- **Native/compiled dependencies must be rebuilt** for the new language version, OS, and CPU architecture.
- **Removed standard-library modules** (e.g., Python's `distutils` in 3.12) break code and libraries that used them.
- **You can't roll back a runtime** after its block-update date.
- **Bundle your own dependencies** so automatic patch updates don't surprise you.

### Cross-cutting
- **IaC drift:** never hand-edit an IaC-managed resource; change the template and deploy.
- **Hard-coded AMI/version IDs** go stale — use SSM Parameter Store lookups and `most_recent` data sources.
- **TLS/cert expiry and IMDSv1** are silent risks — modernize security policies and enforce IMDSv2.
- **"Subject to change" dates:** AWS sometimes *extends* deadlines, but plan to the published date — don't bank on extensions.
- **Architecture mismatches:** if you also move x86_64 → arm64 (Graviton) to save cost, every binary dependency and base image must match the new architecture.

---

<a name="16-dates"></a>
## 16. Key Dates Reference Table

*As of July 2026. All dates are AWS's published forecasts and are subject to change — always confirm against live AWS documentation before a major migration.*

### The dominant deadline

| Item | Date | Meaning |
|---|---|---|
| **Amazon Linux 2 end-of-support** | **Jun 30, 2026** | No more AL2 security updates, patches, or packages. Migrate to AL2023 (supported to **June 2029**). |
| EKS AL2-optimized AMIs | Nov 26, 2025 (build cutoff) | AWS stopped publishing new EKS AL2 AMIs; K8s 1.32 was last to support AL2. |
| ECS / AWS Batch AL2 AMIs | Jun 30, 2026 | Support ends; Batch default already AL2023 since Jan 12, 2026. |

### Databases (RDS & Aurora)

| Engine version | End of standard support | Note |
|---|---|---|
| PostgreSQL 13 (RDS & Aurora) | **Feb 28, 2026** | Upgrade before Mar 1 to avoid Extended Support charges; target PG 16+. |
| MySQL 8.0 (RDS) | **Jul 31, 2026** | Extended Support pricing begins Aug 1, 2026. |
| MySQL 5.7 / PostgreSQL 11 | Past | Already in Extended Support (up to 3 years, paid). |
| Aurora MySQL 2 (5.7-compatible) | Past | In Extended Support; move to Aurora MySQL 3. |

*RDS Extended Support = up to **3 years** of paid critical patches after standard support ends, then automatic force-upgrade.*

### Lambda runtimes (selected — see dedicated Lambda guide for full table)

| Runtime | Status | Block create / Block update |
|---|---|---|
| `python3.13` (recommended) | Supported to Jun 30, 2029 | 2029 |
| `python3.12` | Supported to Oct 31, 2028 | 2028–2029 |
| `python3.9` | **Deprecated** | **Aug 31, 2026 / Sep 30, 2026** |
| `nodejs22.x` (recommended) | Supported to Apr 30, 2027 | 2027 |
| `nodejs18.x` | **Deprecated** | **Aug 31, 2026 / Sep 30, 2026** |

*Reminder: Lambda invocations are **never** blocked, even after full deprecation — but you lose patches and the ability to change the function.*

---

<a name="17-glossary"></a>
## 17. Glossary

- **AMI (Amazon Machine Image)** — A template containing the OS and preinstalled software that an EC2 instance boots from.
- **Amazon Linux 2 (AL2) / Amazon Linux 2023 (AL2023)** — AWS's Linux operating systems. AL2 ends support June 30, 2026; AL2023 is the successor (supported to June 2029).
- **Bottlerocket** — A minimal, container-optimized AWS OS for EKS/ECS worker nodes.
- **End-of-life (EOL) / End-of-support (EOS)** — When a version stops receiving security patches, fixes, and support.
- **Deprecation** — The process of retiring a version, usually in stages, once it reaches EOL.
- **Immutable infrastructure** — The practice of replacing servers with new ones built from a new image, rather than upgrading them in place.
- **Auto Scaling Group (ASG)** — A group of EC2 instances that AWS launches/terminates automatically to meet demand.
- **Launch Template** — A versioned definition (including the AMI) that an ASG uses to launch instances.
- **Instance Refresh** — An ASG feature that gradually replaces instances (e.g., to roll out a new AMI) with health checks and canaries.
- **EKS (Elastic Kubernetes Service)** — AWS's managed Kubernetes. Has both a control-plane version and worker-node OS to keep current.
- **cgroup v2** — A Linux resource-control mechanism required by newer Kubernetes; enabled by default on AL2023/Bottlerocket, not on AL2.
- **Cordon / Drain** — Kubernetes actions to stop scheduling new pods on a node (cordon) and move existing pods off it (drain), used when replacing nodes.
- **ECS (Elastic Container Service) / Fargate** — AWS container orchestration; Fargate is the serverless variant where AWS manages the host OS.
- **RDS / Aurora** — AWS's managed relational databases (MySQL, PostgreSQL, etc.).
- **RDS Extended Support** — A paid program that keeps an out-of-standard-support database patched for up to 3 years while you plan an upgrade.
- **Major vs. minor/patch version** — Major versions can contain breaking changes (you upgrade deliberately); minor/patch updates are low-risk (often automatic).
- **Runtime** — The bundled OS + language version a Lambda function or app runs on.
- **Container base image** — The image named in a Dockerfile's `FROM` line; ages like an OS and must be rebuilt to stay patched.
- **Infrastructure as Code (IaC)** — Defining cloud resources in files (CloudFormation, SAM, CDK, Terraform) rather than clicking in the Console.
- **Drift** — When live configuration no longer matches the IaC definition, usually from a manual change.
- **SSM Parameter Store** — An AWS service that publishes the latest AMI IDs (among other things) so you can look them up instead of hard-coding.
- **IMDSv2** — The secure, token-based version of the EC2 Instance Metadata Service; default-on in AL2023.
- **TLS security policy** — The set of TLS versions/ciphers a load balancer accepts; should be updated over time to require TLS 1.2+.
- **Canary / Blue-green deployment** — Rollout techniques that expose a change to a small slice first (canary) or run old and new side by side and switch (blue-green), enabling safe validation and rollback.
