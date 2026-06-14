# Cloud Team Engineering Guide

## Reusable Kafka, Zookeeper, and NiFi Clusters on AWS

*Terraform • Ansible • Packer • GitLab CI/CD • Strimzi*

Build clean Amazon Linux servers, bake security-patched base AMIs, install
software with Ansible, and promote dev → test → staging across connected and
airgapped GitLab environments.

_A comprehensive onboarding reference for new team members._

---
## Table of Contents

- [1. Introduction and How to Use This Guide](#1-introduction-and-how-to-use-this-guide)
  - [1.1 Who this guide is for](#11-who-this-guide-is-for)
  - [1.2 How the guide is organized](#12-how-the-guide-is-organized)
  - [1.3 The tools at a glance](#13-the-tools-at-a-glance)
- [2. The Big Picture: Architecture and Workflow](#2-the-big-picture-architecture-and-workflow)
  - [2.1 The three factories](#21-the-three-factories)
  - [2.2 How a change flows from a laptop to production](#22-how-a-change-flows-from-a-laptop-to-production)
  - [2.3 Target end-state for each cluster](#23-target-end-state-for-each-cluster)
- [3. AWS Foundations: Accounts, IAM, Roles, and Networking](#3-aws-foundations-accounts-iam-roles-and-networking)
  - [3.1 IAM: who is allowed to do what](#31-iam-who-is-allowed-to-do-what)
    - [3.1.1 The pieces you will use](#311-the-pieces-you-will-use)
    - [3.1.2 Example: a role for your EC2 instances](#312-example-a-role-for-your-ec2-instances)
    - [3.1.3 A separate role for the CI/CD pipeline](#313-a-separate-role-for-the-cicd-pipeline)
  - [3.2 Networking: VPC, subnets, and how nodes find each other](#32-networking-vpc-subnets-and-how-nodes-find-each-other)
    - [3.2.1 Public vs private subnets](#321-public-vs-private-subnets)
    - [3.2.2 A simple, reusable subnet plan](#322-a-simple-reusable-subnet-plan)
    - [3.2.3 Security groups: the per-server firewall](#323-security-groups-the-per-server-firewall)
- [4. Building Base AMIs: Clean Amazon Linux + Security Patches](#4-building-base-amis-clean-amazon-linux-security-patches)
  - [4.1 Why bake an image instead of patching live servers](#41-why-bake-an-image-instead-of-patching-live-servers)
  - [4.2 The tool: Packer](#42-the-tool-packer)
    - [4.2.1 Project layout for the image factory](#421-project-layout-for-the-image-factory)
    - [4.2.2 Finding the latest Amazon Linux automatically](#422-finding-the-latest-amazon-linux-automatically)
    - [4.2.3 The build block: apply patches, then harden](#423-the-build-block-apply-patches-then-harden)
  - [4.3 Bringing in the security team’s patches](#43-bringing-in-the-security-teams-patches)
    - [Pattern A — Internal patched repository (recommended)](#pattern-a-internal-patched-repository-recommended)
    - [Pattern B — A bundle of .rpm files handed over by security](#pattern-b-a-bundle-of-rpm-files-handed-over-by-security)
    - [4.3.1 The cleanup step (do not skip it)](#431-the-cleanup-step-do-not-skip-it)
  - [4.4 Running a bake and reading the result](#44-running-a-bake-and-reading-the-result)
  - [4.5 Keeping AMIs fresh as new patches arrive](#45-keeping-amis-fresh-as-new-patches-arrive)
    - [4.5.1 The refresh loop](#451-the-refresh-loop)
- [5. Terraform: Building the Servers (Reusable Modules)](#5-terraform-building-the-servers-reusable-modules)
  - [5.1 Core ideas in two minutes](#51-core-ideas-in-two-minutes)
  - [5.2 Remote state and locking (do this first)](#52-remote-state-and-locking-do-this-first)
  - [5.3 A clean, reusable repository layout](#53-a-clean-reusable-repository-layout)
  - [5.4 The reusable cluster-node module](#54-the-reusable-cluster-node-module)
    - [modules/cluster-node/variables.tf](#modulescluster-nodevariablestf)
    - [modules/cluster-node/main.tf](#modulescluster-nodemaintf)
    - [modules/cluster-node/outputs.tf](#modulescluster-nodeoutputstf)
  - [5.5 Wiring it together in an environment](#55-wiring-it-together-in-an-environment)
  - [5.6 The core Terraform commands](#56-the-core-terraform-commands)
- [6. Ansible: Installing and Configuring the Software](#6-ansible-installing-and-configuring-the-software)
  - [6.1 Key ideas](#61-key-ideas)
  - [6.2 Dynamic inventory: let Ansible find the servers automatically](#62-dynamic-inventory-let-ansible-find-the-servers-automatically)
  - [6.3 A clean role layout](#63-a-clean-role-layout)
    - [6.3.1 ansible.cfg](#631-ansiblecfg)
  - [6.4 Example role: install Java + Kafka](#64-example-role-install-java-kafka)
    - [roles/kafka/tasks/main.yml](#roleskafkatasksmainyml)
    - [roles/kafka/handlers/main.yml](#roleskafkahandlersmainyml)
    - [roles/kafka/templates/server.properties.j2 (excerpt)](#roleskafkatemplatesserverpropertiesj2-excerpt)
  - [6.5 The master playbook](#65-the-master-playbook)
  - [6.6 The Terraform → Ansible handoff](#66-the-terraform-ansible-handoff)
- [7. Kafka and Zookeeper Clusters (Four Ways)](#7-kafka-and-zookeeper-clusters-four-ways)
  - [7.1 Picking your path](#71-picking-your-path)
  - [7.2 Zookeeper cluster (for the classic paths)](#72-zookeeper-cluster-for-the-classic-paths)
    - [roles/zookeeper/templates/zoo.cfg.j2](#roleszookeepertemplateszoocfgj2)
    - [roles/zookeeper/tasks/main.yml (key parts)](#roleszookeepertasksmainyml-key-parts)
  - [7.3 Path A: Kafka with Zookeeper on EC2](#73-path-a-kafka-with-zookeeper-on-ec2)
  - [7.4 Path B: Kafka without Zookeeper (KRaft) on EC2](#74-path-b-kafka-without-zookeeper-kraft-on-ec2)
    - [server.properties for KRaft (template excerpt)](#serverproperties-for-kraft-template-excerpt)
    - [One-time storage format (run once per cluster)](#one-time-storage-format-run-once-per-cluster)
  - [7.5 Paths C and D: Kafka with Strimzi on Kubernetes](#75-paths-c-and-d-kafka-with-strimzi-on-kubernetes)
    - [7.5.1 Install the operator](#751-install-the-operator)
    - [7.5.2 Path C — Strimzi with Zookeeper](#752-path-c-strimzi-with-zookeeper)
    - [7.5.3 Path D — Strimzi with KRaft (no Zookeeper)](#753-path-d-strimzi-with-kraft-no-zookeeper)
- [8. NiFi Cluster Setup](#8-nifi-cluster-setup)
  - [8.1 How NiFi clusters coordinate](#81-how-nifi-clusters-coordinate)
  - [8.2 Key settings the Ansible role templates](#82-key-settings-the-ansible-role-templates)
  - [8.3 Bring up the cluster and verify](#83-bring-up-the-cluster-and-verify)
  - [8.4 Connecting NiFi to Kafka (the common job)](#84-connecting-nifi-to-kafka-the-common-job)
- [9. GitLab: Directory Structure, Pipelines, and Promotion](#9-gitlab-directory-structure-pipelines-and-promotion)
  - [9.1 The dev-area directory structure](#91-the-dev-area-directory-structure)
  - [9.2 Branching and the promotion model](#92-branching-and-the-promotion-model)
  - [9.3 The pipeline stages](#93-the-pipeline-stages)
    - [9.3.1 Stage 1 — checks (fast feedback)](#931-stage-1-checks-fast-feedback)
    - [9.3.2 Stage 2 — security scanning](#932-stage-2-security-scanning)
    - [9.3.3 Stage 3 — plan (preview before any change)](#933-stage-3-plan-preview-before-any-change)
    - [9.3.4 Stages 4–6 — deploy dev → test → staging](#934-stages-46-deploy-dev-test-staging)
  - [9.4 Protecting environments with approvals](#94-protecting-environments-with-approvals)
- [10. GitLab Setup, Roles, and Secure CI/CD](#10-gitlab-setup-roles-and-secure-cicd)
  - [10.1 GitLab roles: who can do what](#101-gitlab-roles-who-can-do-what)
    - [10.1.1 The member roles you will assign](#1011-the-member-roles-you-will-assign)
    - [10.1.2 Step by step: create the group, project, and members](#1012-step-by-step-create-the-group-project-and-members)
  - [10.2 Best practices for a secure GitLab](#102-best-practices-for-a-secure-gitlab)
    - [10.2.1 Accounts and access](#1021-accounts-and-access)
    - [10.2.2 Protecting code and branches](#1022-protecting-code-and-branches)
    - [10.2.3 Secrets: never commit them, store them safely](#1023-secrets-never-commit-them-store-them-safely)
    - [10.2.4 Runners: where your jobs actually execute](#1024-runners-where-your-jobs-actually-execute)
    - [10.2.5 Instance and operational hardening](#1025-instance-and-operational-hardening)
  - [10.3 Connecting GitLab to AWS with OIDC (no stored keys)](#103-connecting-gitlab-to-aws-with-oidc-no-stored-keys)
    - [10.3.1 One-time AWS setup](#1031-one-time-aws-setup)
    - [10.3.2 The GitLab job side](#1032-the-gitlab-job-side)
  - [10.4 Step by step: a secure Terraform pipeline](#104-step-by-step-a-secure-terraform-pipeline)
    - [10.4.1 Step 1 — define stages and shared settings](#1041-step-1-define-stages-and-shared-settings)
    - [10.4.2 Step 2 — format and validate (the "check" stage)](#1042-step-2-format-and-validate-the-check-stage)
    - [10.4.3 Step 3 — security scanning for Terraform (the heart of this section)](#1043-step-3-security-scanning-for-terraform-the-heart-of-this-section)
    - [10.4.4 Step 4 — plan (preview every change, with AWS access)](#1044-step-4-plan-preview-every-change-with-aws-access)
    - [10.4.5 Step 5 — deploy dev → test → staging (apply the approved plan)](#1045-step-5-deploy-dev-test-staging-apply-the-approved-plan)
    - [10.4.6 Step 6 — lock the environments (the clicks that make it safe)](#1046-step-6-lock-the-environments-the-clicks-that-make-it-safe)
    - [10.4.7 The finished pipeline at a glance](#1047-the-finished-pipeline-at-a-glance)
- [11. Two GitLab Instances: Dev Side and Airgapped Side](#11-two-gitlab-instances-dev-side-and-airgapped-side)
  - [11.1 Why airgap, and what it costs you](#111-why-airgap-and-what-it-costs-you)
  - [11.2 What must cross the gap](#112-what-must-cross-the-gap)
  - [11.3 Syncing the two GitLabs with a Git bundle](#113-syncing-the-two-gitlabs-with-a-git-bundle)
    - [On the dev side — create the bundle](#on-the-dev-side-create-the-bundle)
    - [Move it across, then on the airgapped side — apply the bundle](#move-it-across-then-on-the-airgapped-side-apply-the-bundle)
  - [11.4 Mirroring packages and container images](#114-mirroring-packages-and-container-images)
    - [11.4.1 OS packages and tarballs](#1141-os-packages-and-tarballs)
    - [11.4.2 Container images (for Strimzi/EKS or runners)](#1142-container-images-for-strimzieks-or-runners)
    - [11.4.3 Terraform providers and Ansible collections](#1143-terraform-providers-and-ansible-collections)
  - [11.5 AMIs inside the airgap](#115-amis-inside-the-airgap)
  - [11.6 Keeping the two sides aligned over time](#116-keeping-the-two-sides-aligned-over-time)
- [12. Cross-Cutting Best Practices and Security](#12-cross-cutting-best-practices-and-security)
  - [12.1 Security hardening summary](#121-security-hardening-summary)
  - [12.2 Reliability and operations](#122-reliability-and-operations)
  - [12.3 Cost awareness](#123-cost-awareness)
  - [12.4 Making it reusable and extendable](#124-making-it-reusable-and-extendable)
- [13. Troubleshooting Quick-Reference](#13-troubleshooting-quick-reference)
- [14. Glossary (Plain-English)](#14-glossary-plain-english)
- [15. Quick-Start Checklist for a New Engineer](#15-quick-start-checklist-for-a-new-engineer)

---

# 1. Introduction and How to Use This Guide

**Welcome.** This guide teaches a new cloud team member how to build reusable, repeatable clusters for **Kafka**, **Zookeeper**, and **NiFi** on AWS. We use two tools together: Terraform builds the servers (the “hardware”), and Ansible installs the software (the “programs”). We bake hardened base images called AMIs that already include your security team’s patches, and we keep them fresh as new patches arrive. Everything is driven from the command line and from GitLab pipelines, and it works across two GitLab servers — one on the normal “dev side” and one on an isolated “airgapped side.”

> **🟣 IN PLAIN TERMS**
>
> Think of building a cluster like opening a new pizza shop. Terraform is the construction crew that builds the building and runs the wiring (the servers and network). The AMI is a pre-approved building blueprint your safety inspector already signed off on, so every new shop starts safe. Ansible is the team that walks in and installs the ovens, fridges, and cash registers (the software). GitLab is the manager’s binder of checklists that makes sure every shop is built the same correct way, every time.

## 1.1 Who this guide is for

- New cloud engineers who have an AWS login but have not yet built infrastructure here.
- Engineers who know one tool (say Terraform) but not the others (Ansible, GitLab CI, AMI baking).
- Anyone who needs to support both the connected dev environment and the airgapped environment.

## 1.2 How the guide is organized

Each major step follows the same pattern so you always know where to look:

- **What and why** — a plain-English explanation, often with a simple real-world comparison.
- **Do it** — exact commands and code you can copy.
- **Best Practice boxes** — how the pros keep it clean and reusable.
- **Gotcha boxes** — the traps that cost people hours.
- **Troubleshooting boxes** — what to do when the step fails.

> **ℹ️ NOTE**
>
> Conventions used throughout: text in this monospace style is a command, file path, or code you type. Replace anything in ANGLE BRACKETS like <account-id> with your real value. Lines starting with $ are run in your terminal; do not type the $ itself.

## 1.3 The tools at a glance

| Tool | Plain-English job | What it produces |
| --- | --- | --- |
| Packer | Bakes a reusable golden image with patches pre-installed | A base AMI (an ID like ami-0abc123) |
| Terraform | Builds servers, networks, security groups, IAM from text files | Running EC2 instances and AWS resources |
| Ansible | Logs into the servers and installs/configures software | A working Kafka / Zookeeper / NiFi node |
| GitLab CI | Runs the steps automatically and enforces checks/approvals | Pipelines that promote dev → test → staging |
| Strimzi | Runs Kafka on Kubernetes using simple YAML (optional path) | A Kafka cluster managed by an operator |

# 2. The Big Picture: Architecture and Workflow

Before any commands, hold the whole system in your head. There are three “factories” and they run in order.

## 2.1 The three factories

1. **Image factory (Packer):** Start from the latest Amazon Linux image, add the security team’s patches, and save the result as your own base AMI. Re-run whenever new patches arrive.
1. **Infrastructure factory (Terraform):** Use that base AMI to launch the right number of servers, with the right network, firewall rules, and permissions.
1. **Software factory (Ansible):** Connect to those servers and turn them into Kafka brokers, Zookeeper nodes, or NiFi nodes — configured and clustered.

> **🟣 IN PLAIN TERMS**
>
> Cookies: Packer makes the dough that already has the safe ingredients mixed in. Terraform presses the dough onto baking trays in the right shape and number. Ansible decorates each cookie into exactly the kind you ordered. Because each step is written down, you can make the same batch again next month without remembering anything.

## 2.2 How a change flows from a laptop to production

A new team member should picture this path every time they make a change:

```
Developer laptop  ──git push──▶  GitLab (dev side)
                                   │
                                   ▼
                         Pipeline runs checks
                    (format, validate, security scan)
                                   │
                 ┌─────────────────┼─────────────────┐
                 ▼                 ▼                 ▼
              DEV env           TEST env          STAGING env
           (auto deploy)   (deploy on merge)  (deploy w/ approval)
                                   │
                          export artifacts
                                   │
                                   ▼
                    Airgapped GitLab (separate side)
                                   │
                                   ▼
                 Same pipeline, deploys to secure env
```

Two ideas make this safe and reusable:

- **Everything is code in Git.** No clicking around in the AWS Console for real resources. If it is not in Git, it does not exist.
- **Promotion, not rebuilding.** The exact same code and images move from dev to test to staging. You change only small settings (called variables), never the logic.

> **✅ BEST PRACTICE**
>
> Adopt “immutable infrastructure.” When something needs to change, you build a new AMI or new server and replace the old one, instead of logging in and hand-editing a running box. This keeps every environment identical and makes rollbacks easy: just point back at the previous AMI.

## 2.3 Target end-state for each cluster

| Cluster | Typical size to start | Talks to | Why it exists |
| --- | --- | --- | --- |
| Zookeeper | 3 nodes (odd number) | Kafka (classic mode) | Keeps the cluster’s “who is in charge” bookkeeping |
| Kafka | 3 brokers | Zookeeper or KRaft | Stores and streams messages between systems |
| NiFi | 3 nodes | Kafka, databases, files | Moves and transforms data with a drag-and-drop flow |

> **ℹ️ NOTE**
>
> Modern Kafka can run without Zookeeper using a built-in mode called KRaft. This guide covers both: the classic “Kafka + Zookeeper” setup and the newer “Kafka without Zookeeper.” We also cover running Kafka on Kubernetes with Strimzi, and on plain EC2 without Strimzi.

# 3. AWS Foundations: Accounts, IAM, Roles, and Networking

You must understand permissions and networking before building anything, because most real-world failures are “access denied” or “the servers cannot talk to each other.” We keep this concrete and simple.

## 3.1 IAM: who is allowed to do what

**IAM (Identity and Access Management)** is the AWS security guard. It decides which people and which machines can take which actions on which resources.

> **🟣 IN PLAIN TERMS**
>
> IAM is like the badge system at a building. A user is a person’s badge. A role is a temporary visitor badge that anyone (or any machine) can borrow for a specific job. A policy is the printed list taped to the door saying “this badge may open these doors.” You never tape your house key to the door — likewise you never hard-code passwords into servers; you let them borrow a role.

### 3.1.1 The pieces you will use

| IAM thing | Plain meaning | You use it for |
| --- | --- | --- |
| User | A login for a human | Your own console/CLI access (ideally via SSO) |
| Group | A bucket of users with shared permissions | Putting all cloud engineers in one place |
| Role | A borrowable identity for machines or pipelines | EC2 instances and GitLab runners acting on AWS |
| Policy | A document listing allowed actions | Granting exactly the permissions needed |
| Instance profile | A wrapper that attaches a role to an EC2 server | Letting a Kafka box read from S3 with no keys |

> **✅ BEST PRACTICE**
>
> - Use roles for machines, never long-lived access keys on servers. A role hands out short-lived credentials automatically and rotates them for you.
> - Follow least privilege: start with almost nothing and add permissions until the task works. It is safer to grant one more action than to start with “allow everything.”
> - Separate roles by job. The role a Kafka server uses should not be the same role your Terraform pipeline uses.

### 3.1.2 Example: a role for your EC2 instances

Servers often need to read configuration or certificates from S3 and write logs/metrics. Here is a minimal trust policy (who may assume the role) and permission policy (what it may do).

**Trust policy** — lets EC2 assume the role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permission policy** — read one config bucket, write to a logs bucket, and publish metrics:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadClusterConfig",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::mycorp-cluster-config",
        "arn:aws:s3:::mycorp-cluster-config/*"
      ]
    },
    {
      "Sid": "WriteLogs",
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::mycorp-cluster-logs/*"
    },
    {
      "Sid": "PublishMetrics",
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*"
    }
  ]
}
```

#### Create it — AWS CLI

Save the two JSON documents above as files, then create the role, attach the policy, and wrap it in an instance profile so EC2 can use it:

```bash
# 1) Create the role with the trust policy (who may assume it)
aws iam create-role \
  --role-name cluster-node-role \
  --assume-role-policy-document file://ec2-trust.json

# 2) Attach the permission policy (what it may do)
aws iam put-role-policy \
  --role-name cluster-node-role \
  --policy-name cluster-node-permissions \
  --policy-document file://ec2-permissions.json

# 3) Wrap the role in an instance profile and add the role to it
aws iam create-instance-profile --instance-profile-name cluster-node-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name cluster-node-profile \
  --role-name cluster-node-role
```

#### Create it — AWS Web Console

1. IAM → Roles → Create role → Trusted entity type: "AWS service" → Use case: EC2 → Next.
1. On "Add permissions," click Create policy, paste the permission JSON on the JSON tab, name it cluster-node-permissions, then select it back on the role.
1. Name the role cluster-node-role → Create role. (The console automatically creates a matching instance profile of the same name.)
1. Later, when launching an instance: Advanced details → IAM instance profile → choose cluster-node-role. Terraform does this for you via iam\_instance\_profile.

> **ℹ️ NOTE**
>
> The CLI needs an explicit instance profile (steps 2-3 above); the Console makes one for you automatically when you create an EC2 role. Either way, EC2 attaches the PROFILE, which contains the role.

> **⚠️ GOTCHA**
>
> - A trust policy and a permission policy are two different things. Beginners attach the permission policy but forget the trust policy, then wonder why EC2 “cannot assume” the role.
> - Listing a bucket needs the bucket ARN (no /\*). Reading objects needs the /\* form. You usually need BOTH lines, as shown.

### 3.1.3 A separate role for the CI/CD pipeline

Your GitLab pipeline needs power to create servers, networks, and AMIs. Give the pipeline its own role and let GitLab assume it using OpenID Connect (OIDC) so there are no stored AWS keys in GitLab.

```
# Trust policy snippet: only your GitLab project, on protected branches, may assume this role
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/gitlab.mycorp.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "gitlab.mycorp.com:aud": "https://gitlab.mycorp.com" },
    "StringLike":   { "gitlab.mycorp.com:sub": "project_path:platform/clusters:ref_type:branch:ref:main" }
  }
}
```

> **✅ BEST PRACTICE**
>
> Scope the pipeline role to specific branches (like main) and specific projects using the “sub” condition above. This means a random branch or a forked project cannot deploy to your cloud, even if someone pushes code.

> **🔧 TROUBLESHOOTING**
>
> - “is not authorized to perform: sts:AssumeRole” → the trust policy is missing or the Principal/Condition does not match the caller. Print the caller identity with: aws sts get-caller-identity.
> - “AccessDenied” on a specific action → read the error; it names the exact Action and Resource missing. Add just that, then retry.
> - Use the IAM Policy Simulator in the console to test “can this role do X on Y?” before deploying.

## 3.2 Networking: VPC, subnets, and how nodes find each other

A **VPC** is your own private slice of the AWS network. Inside it you carve out **subnets** — smaller address ranges, each living in one Availability Zone (a separate data center). Where you place your nodes decides reliability and what can reach them.

> **🟣 IN PLAIN TERMS**
>
> The VPC is your apartment building. Each subnet is one floor. Availability Zones are separate buildings across town — if one building loses power, the others keep working. You spread your 3 Kafka brokers across 3 buildings so a single outage never takes the whole cluster down.

### 3.2.1 Public vs private subnets

| Subnet type | Can reach the internet? | Reachable from internet? | Put here |
| --- | --- | --- | --- |
| Public | Yes (via Internet Gateway) | Yes, if you allow it | Load balancers, bastion/jump host |
| Private | Outbound only (via NAT) or none | No | Kafka, Zookeeper, NiFi nodes |

> **✅ BEST PRACTICE**
>
> Put all data nodes (Kafka, Zookeeper, NiFi) in PRIVATE subnets. They should never be directly reachable from the internet. Reach them through a bastion host or, better, via SSM Session Manager (no open SSH port at all).

### 3.2.2 A simple, reusable subnet plan

Use one big VPC range split into private and public subnets across three AZs. A clean, easy-to-read plan:

| Purpose | AZ | CIDR (address range) | Approx usable IPs |
| --- | --- | --- | --- |
| Private app A | us-east-1a | 10.20.0.0/22 | ~1,019 |
| Private app B | us-east-1b | 10.20.4.0/22 | ~1,019 |
| Private app C | us-east-1c | 10.20.8.0/22 | ~1,019 |
| Public A | us-east-1a | 10.20.240.0/24 | ~251 |
| Public B | us-east-1b | 10.20.241.0/24 | ~251 |
| Public C | us-east-1c | 10.20.242.0/24 | ~251 |

> **ℹ️ NOTE**
>
> A /22 gives roughly a thousand IPs per subnet — plenty for clusters that grow. AWS reserves 5 IPs in every subnet, which is why the usable count is a little below the math.

#### Create it — AWS CLI

In real life Terraform builds the network (Section 5), but it is worth knowing the manual commands so you can verify or bootstrap by hand:

```bash
# Create the VPC and capture its ID
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 \
  --query 'Vpc.VpcId' --output text)

# Create one private subnet in us-east-1a
aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.20.0.0/22 --availability-zone us-east-1a

# Create a public subnet, an internet gateway, and attach it
SUBNET_PUB=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.20.240.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"
```

#### Create it — AWS Web Console

1. VPC → Your VPCs → Create VPC → choose "VPC and more" to let the wizard create subnets, route tables, and a gateway in one step.
1. Set the IPv4 CIDR to 10.20.0.0/16, pick 3 Availability Zones, and ask for public + private subnets per AZ.
1. Let it create a NAT gateway only if private subnets need outbound internet (it costs money — skip it for airgapped designs).
1. Click Create VPC, then review the Resource map it draws so you can confirm the layout matches the table above.

> **⚠️ GOTCHA**
>
> - Subnets cannot be resized after creation. Plan /22 or larger for data tiers so you do not run out of IPs mid-project.
> - Each subnet lives in exactly one AZ. To survive an AZ outage you MUST spread nodes across at least three subnets in three AZs.
> - Private subnets with no NAT cannot reach the internet at all — fine for airgapped, but then your software must come from internal mirrors, not the public internet.

### 3.2.3 Security groups: the per-server firewall

A **security group** is a firewall attached to each server. It lists which inbound and outbound traffic is allowed. The cleanest pattern is to let a group reference itself, so “any node in this group may talk to any other node in this group.”

| Cluster | Port | Purpose | Who is allowed in |
| --- | --- | --- | --- |
| Zookeeper | 2181 | Client connections | Kafka brokers SG |
| Zookeeper | 2888, 3888 | Peer + leader election | Zookeeper SG (itself) |
| Kafka | 9092 | Plaintext/SASL clients | App + NiFi SGs |
| Kafka | 9093 | TLS clients | App + NiFi SGs |
| Kafka | 9094 | Inter-broker | Kafka SG (itself) |
| Kafka (KRaft) | 9095 | Controller quorum | Kafka SG (itself) |
| NiFi | 8443 | Secure web UI / API | Admin CIDR / load balancer |
| NiFi | 11443 | Cluster (node-to-node) | NiFi SG (itself) |

> **✅ BEST PRACTICE**
>
> - Reference security groups by ID, not by IP, for node-to-node rules. Then scaling up adds nodes automatically into the allowed set.
> - Open only the ports a tier truly needs. Start closed; add one rule at a time while testing with a tool like nc (netcat).
> - Keep admin/SSH access off the internet entirely; use SSM Session Manager so there is no port 22 open anywhere.

#### Create it — AWS CLI

Example: a Kafka security group that allows brokers to talk to each other on the inter-broker port (the self-referencing pattern):

```bash
# Create the group
SG_KAFKA=$(aws ec2 create-security-group \
  --group-name kafka-sg --description "Kafka brokers" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text)

# Allow the group to reach ITSELF on the inter-broker port (note: --source-group)
aws ec2 authorize-security-group-ingress --group-id "$SG_KAFKA" \
  --protocol tcp --port 9094 --source-group "$SG_KAFKA"

# Allow clients in the app security group to reach Kafka on 9092
aws ec2 authorize-security-group-ingress --group-id "$SG_KAFKA" \
  --protocol tcp --port 9092 --source-group "$SG_APP"
```

#### Create it — AWS Web Console

1. EC2 → Security Groups → Create security group → name kafka-sg, pick your VPC.
1. Under Inbound rules → Add rule → Custom TCP → port 9094 → Source: start typing the same group’s name and select it (self-reference).
1. Add another rule: Custom TCP → port 9092 → Source: the app security group.
1. Leave outbound as "all" (the default) unless your policy requires tightening it → Create security group.

> **ℹ️ NOTE**
>
> Selecting a security group as the "source" is the click-equivalent of --source-group on the CLI. This is what lets new brokers join the allowed set automatically as you scale.

> **🔧 TROUBLESHOOTING**
>
> - Nodes cannot cluster → check the self-referencing rule exists on the RIGHT ports (e.g., 2888/3888 for Zookeeper, 9094 for Kafka).
> - Connection “hangs” then times out → almost always a security group or subnet route problem, not the app. Confirm with: nc -vz <private-ip> <port>.
> - Connection “refused” immediately → the network is fine but the service is not listening yet; check the service with systemctl status.
> - Cross-AZ but same VPC still failing → check the route table attached to the subnet and any Network ACLs (NACLs), which are a second, stateless firewall layer.

# 4. Building Base AMIs: Clean Amazon Linux + Security Patches

An **AMI (Amazon Machine Image)** is a saved snapshot of a server’s disk that you can stamp out into many identical servers. Our goal: start from the **latest official Amazon Linux** image, layer on the **security team’s patches**, and save the result as our own “golden” base AMI. Every cluster server is then launched from this trusted image.

> **🟣 IN PLAIN TERMS**
>
> Buying a new laptop, you do not hand it to a coworker straight from the box. You first install the company antivirus and the latest updates, then save that setup as the “standard company laptop.” The base AMI is exactly that standard setup, but for servers — and you can clone it a hundred times in seconds.

## 4.1 Why bake an image instead of patching live servers

- **Consistency:** every server starts identical, so “it works on that box but not this one” disappears.
- **Speed:** patches are already applied, so new servers boot ready in minutes, not after a long update.
- **Auditability:** each AMI has a version and a record of exactly which patches it contains.
- **Rollback:** if a new image misbehaves, relaunch from the previous AMI ID.

## 4.2 The tool: Packer

**Packer** (by HashiCorp, the makers of Terraform) automates baking. You describe the starting image and the steps to run, and Packer launches a temporary server, runs your steps, and saves the result as an AMI — then deletes the temporary server.

### 4.2.1 Project layout for the image factory

```hcl
ami-factory/
├── base/
│   ├── base.pkr.hcl          # Packer template for the golden base image
│   ├── variables.pkr.hcl     # Inputs (region, instance type, patch source)
│   └── scripts/
│       ├── 00-wait-cloud-init.sh
│       ├── 10-apply-security-patches.sh
│       ├── 20-cis-hardening.sh
│       └── 99-cleanup.sh
├── ansible/                  # Optional: run Ansible during the bake
│   └── hardening.yml
└── .gitlab-ci.yml            # Pipeline that builds + tags AMIs on a schedule
```

### 4.2.2 Finding the latest Amazon Linux automatically

Never hard-code a starting AMI ID — it goes stale. Let Packer look up the newest official Amazon Linux 2023 image at build time using a source\_ami\_filter.

```hcl
# base/base.pkr.hcl
packer {
  required_plugins {
    amazon = { source = "github.com/hashicorp/amazon", version = ">= 1.3.0" }
    ansible = { source = "github.com/hashicorp/ansible", version = ">= 1.1.0" }
  }
}

source "amazon-ebs" "al2023" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ec2-user"

  # Always grab the NEWEST official Amazon Linux 2023 image as our starting point
  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-6.1-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["137112412989"]   # Amazon's official account
    most_recent = true
  }

  # Name and tag the resulting AMI so it is easy to find and audit
  ami_name = "mycorp-base-al2023-{{timestamp}}"
  tags = {
    Name          = "mycorp-base-al2023"
    BaseOS        = "AmazonLinux2023"
    PatchBaseline = var.patch_baseline_id
    BakedBy       = "packer"
    BakeDate      = "{{isotime \"2006-01-02\"}}"
  }
  # Encrypt the image so snapshots are safe at rest
  encrypt_boot = true
}
```

> **⚠️ GOTCHA**
>
> - owners = ["137112412989"] is Amazon’s real account for official images. Filtering only by name without owners can match someone else’s look-alike image — a security risk. Always pin the owner.
> - most\_recent = true is what keeps you on the latest base. If you ever pin a fixed ID “to be safe,” you have quietly opted out of upstream security fixes.

### 4.2.3 The build block: apply patches, then harden

```hcl
build {
  sources = ["source.amazon-ebs.al2023"]

  provisioner "shell" {
    scripts = [
      "scripts/00-wait-cloud-init.sh",
      "scripts/10-apply-security-patches.sh",
      "scripts/20-cis-hardening.sh"
    ]
    # Give scripts the patch source as an environment variable
    environment_vars = ["PATCH_REPO=${var.patch_repo_url}"]
  }

  # Optional: run an Ansible playbook for deeper hardening (CIS, auditd, etc.)
  provisioner "ansible" {
    playbook_file = "../ansible/hardening.yml"
  }

  provisioner "shell" { scripts = ["scripts/99-cleanup.sh"] }

  # Write a manifest so the pipeline knows the new AMI ID
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
```

## 4.3 Bringing in the security team’s patches

There are two common ways the security team delivers patches. Support whichever your company uses; both fit cleanly into the script step above.

### Pattern A — Internal patched repository (recommended)

Security maintains an internal yum/dnf mirror that contains the approved, tested package versions. Your servers point at that mirror instead of the public one, so “update everything” always means “apply approved patches.”

```bash
#!/usr/bin/env bash
# scripts/10-apply-security-patches.sh
set -euo pipefail

# Point dnf at the internal, security-approved mirror
sudo tee /etc/yum.repos.d/mycorp-security.repo >/dev/null <<EOF
[mycorp-security]
name=MyCorp Security-Approved Packages
baseurl=${PATCH_REPO}
enabled=1
gpgcheck=1
gpgkey=${PATCH_REPO}/RPM-GPG-KEY-mycorp
priority=1
EOF

# Refresh metadata and apply ALL available approved updates
sudo dnf clean all
sudo dnf -y --refresh upgrade

# Record exactly what is installed for the audit trail
rpm -qa | sort > /tmp/installed-packages.txt
sudo dnf updateinfo list installed > /tmp/patch-report.txt || true
echo "Patches applied from ${PATCH_REPO}"
```

### Pattern B — A bundle of .rpm files handed over by security

Sometimes security gives you a folder (or an S3 prefix) of approved .rpm files. Pull them in and install them directly.

```bash
#!/usr/bin/env bash
# Alternative 10-apply-security-patches.sh (RPM bundle from S3)
set -euo pipefail

mkdir -p /tmp/patches
# The instance profile must allow s3:GetObject on this bucket (see IAM section)
aws s3 sync "s3://mycorp-security-patches/al2023/latest/" /tmp/patches/

# Verify signatures, then install everything in the bundle
sudo rpm --import /tmp/patches/RPM-GPG-KEY-mycorp
sudo dnf -y install /tmp/patches/*.rpm

rpm -qa | sort > /tmp/installed-packages.txt
```

> **✅ BEST PRACTICE**
>
> - Always keep gpgcheck=1 and import the security team’s signing key. This proves a package really came from them and was not tampered with.
> - Save /tmp/installed-packages.txt and the patch report into your logs bucket. Auditors will ask “exactly what was on that image?” and you will have the answer.
> - Tag the AMI with the patch baseline ID/date (shown earlier). Tags are how you later prove an environment is current.

### 4.3.1 The cleanup step (do not skip it)

```bash
#!/usr/bin/env bash
# scripts/99-cleanup.sh — remove anything that should not be cloned a hundred times
set -euo pipefail
sudo dnf clean all
sudo rm -rf /var/log/* /tmp/* /var/tmp/*
# Remove the unique machine id and SSH host keys so each clone regenerates its own
sudo truncate -s 0 /etc/machine-id
sudo rm -f /etc/ssh/ssh_host_*
# Wipe shell history
cat /dev/null > ~/.bash_history && history -c || true
```

> **⚠️ GOTCHA**
>
> - If you forget to clear /etc/machine-id and SSH host keys, every server cloned from the image shares the same identity — which breaks logging, some clustering, and trips security scanners.
> - Never leave secrets, AWS keys, or test credentials on the image. Anything on the disk is baked into every copy.

## 4.4 Running a bake and reading the result

```bash
$ cd ami-factory/base
$ packer init .
$ packer validate -var "region=us-east-1" -var "patch_repo_url=https://repo.mycorp.com/al2023" .
$ packer build  -var "region=us-east-1" -var "patch_repo_url=https://repo.mycorp.com/al2023" .

# After it finishes, the new AMI ID is in manifest.json:
$ jq -r '.builds[-1].artifact_id' manifest.json
us-east-1:ami-0abc123def4567890
```

#### Verify and share it — AWS CLI

Confirm the image exists, is encrypted, and carries your tags; share it to other accounts if your org uses a separate build account:

```bash
# Inspect the new image and its tags
aws ec2 describe-images --image-ids ami-0abc123def4567890 \
  --query 'Images[0].{Name:Name,State:State,Enc:BlockDeviceMappings[0].Ebs.Encrypted}'

# (Optional) share the AMI with another account
aws ec2 modify-image-attribute --image-id ami-0abc123def4567890 \
  --launch-permission "Add=[{UserId=222233334444}]"
```

#### Verify it — AWS Web Console

1. EC2 → AMIs (left menu, under Images) → set the filter to "Owned by me."
1. Find mycorp-base-al2023-… → check Status = Available and the Tags tab shows your patch baseline/date.
1. Open the AMI → Permissions tab to share it with other accounts, or Storage tab to confirm the snapshot is Encrypted.
1. To test it: Launch instance from AMI → pick a private subnet and the cluster-node profile → confirm it boots.

> **🔧 TROUBLESHOOTING**
>
> - “No AMI found matching filter” → your name pattern is wrong for the current Amazon Linux naming, or owners is wrong. List candidates: aws ec2 describe-images --owners 137112412989 --filters "Name=name,Values=al2023-ami-2023.\*" --query "Images[].Name".
> - Build hangs at SSH → the temporary instance has no route out, or its security group blocks SSH. Packer can use a temporary security group; ensure the subnet has internet (or use a private subnet with the right endpoints for airgapped builds).
> - dnf upgrade fails to reach the mirror → wrong baseurl, or the build subnet cannot reach the internal repo. Test from a manual instance first with: dnf repolist -v.
> - GPG check failed → the signing key was not imported or the package is unsigned. Confirm the key path and that security actually signed the bundle.

## 4.5 Keeping AMIs fresh as new patches arrive

A base image is only trustworthy if it is current. Automate re-baking so new patches flow in without anyone remembering to do it.

### 4.5.1 The refresh loop

1. Security publishes new approved packages to the internal mirror (or a new RPM bundle).
1. A scheduled GitLab pipeline runs Packer on a cadence (for example, weekly) and on demand.
1. Packer produces a NEW AMI ID and tags it with the build date and patch baseline.
1. The new AMI ID is written to a parameter in AWS SSM Parameter Store, e.g. /mycorp/ami/base-al2023/latest.
1. Terraform reads that parameter, so the next deploy automatically uses the freshest image.
1. Old AMIs are kept for a while (for rollback), then de-registered on a retention schedule.

Publish the new AMI ID so the rest of the system can find it without code changes:

```bash
# At the end of a successful bake (in the pipeline)
NEW_AMI=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d: -f2)
aws ssm put-parameter \
  --name "/mycorp/ami/base-al2023/latest" \
  --type String --overwrite \
  --value "$NEW_AMI"
echo "Published $NEW_AMI as the new base image"
```

Terraform then looks it up, so you never paste an AMI ID by hand:

```hcl
# In Terraform — read the latest baked AMI from SSM
data "aws_ssm_parameter" "base_ami" {
  name = "/mycorp/ami/base-al2023/latest"
}
# Use data.aws_ssm_parameter.base_ami.value as the ami for instances
```

> **✅ BEST PRACTICE**
>
> - Promote AMIs like code: publish to /…/base-al2023/dev first, test, then copy the value to /…/staging and /…/prod. Each environment points at its own parameter, so a fresh image is proven before staging sees it.
> - Keep at least the last 2–3 AMIs and their snapshots. Rollback is just changing the parameter back to a previous ID and re-running the deploy.
> - Re-bake on a schedule AND whenever a critical CVE drops. Do not wait for the weekly run during an emergency.

> **⚠️ GOTCHA**
>
> - A new AMI does NOT update already-running servers. To apply it you must replace instances (rolling replacement). Plan that rollout; baking alone is not patching the fleet.
> - De-registering an AMI does not delete its underlying EBS snapshots — those keep costing money. Clean up snapshots too, but only after you are sure no one needs that rollback point.
> - AMIs are per-region. If you run in two regions, copy the AMI to each region and publish a parameter per region.

> **🔧 TROUBLESHOOTING**
>
> - New servers still on old packages → they launched from an old AMI ID. Confirm Terraform read the SSM parameter and that the parameter actually updated (aws ssm get-parameter --name …).
> - Scheduled bake did not run → check the GitLab pipeline schedule and that the schedule’s target branch is correct and protected.

# 5. Terraform: Building the Servers (Reusable Modules)

**Terraform** turns text files into real AWS resources. You write what you want (3 Kafka brokers in these subnets, with this security group and this role), and Terraform figures out how to create, change, or delete resources to match. Because it is text in Git, anyone can read exactly what exists and reproduce it.

> **🟣 IN PLAIN TERMS**
>
> Terraform is like a LEGO instruction booklet that can also build itself. You write the instructions once; running it builds the model. Change a number from 3 to 5 and re-run, and it adds exactly the 2 missing pieces — it does not knock down and rebuild the whole thing.

## 5.1 Core ideas in two minutes

| Term | Plain meaning |
| --- | --- |
| Resource | One thing Terraform manages (an EC2 instance, a subnet, a role) |
| Provider | The plugin that talks to a platform (the AWS provider) |
| Variable | An input you can change per environment (count, instance size) |
| Output | A value Terraform gives back (the broker IP addresses) |
| State | Terraform’s memory file of what it has built |
| Module | A reusable folder of resources you can call many times |

## 5.2 Remote state and locking (do this first)

Terraform records what it built in a **state file**. Never keep it only on your laptop. Store it in S3 and use a DynamoDB table for locking so two people cannot change the same environment at once.

```hcl
# backend.tf — where Terraform keeps its memory
terraform {
  backend "s3" {
    bucket         = "mycorp-tfstate"
    key            = "clusters/dev/terraform.tfstate"   # one key per environment
    region         = "us-east-1"
    dynamodb_table = "mycorp-tflock"                     # prevents concurrent writes
    encrypt        = true
  }
}
```

#### Bootstrap the backend — AWS CLI

The state bucket and lock table must exist BEFORE the first terraform init. Create them once, by hand:

```bash
# 1) Create the private, versioned, encrypted state bucket
aws s3api create-bucket --bucket mycorp-tfstate --region us-east-1
aws s3api put-bucket-versioning --bucket mycorp-tfstate \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket mycorp-tfstate \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket mycorp-tfstate \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 2) Create the DynamoDB lock table (partition key MUST be named LockID)
aws dynamodb create-table --table-name mycorp-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

#### Bootstrap the backend — AWS Web Console

1. S3 → Create bucket → name mycorp-tfstate → enable Bucket Versioning → enable Default encryption → keep "Block all public access" ON → Create.
1. DynamoDB → Create table → table name mycorp-tflock → Partition key: LockID (type String) → On-demand capacity → Create table.
1. Back in your env folder, run terraform init; Terraform connects to the bucket and table defined in backend.tf.

> **ℹ️ NOTE**
>
> The DynamoDB partition key MUST be exactly LockID (case-sensitive) — Terraform looks for that name. A wrong key name is the most common reason locking silently fails to work.

> **⚠️ GOTCHA**
>
> - The state file can contain sensitive values. Keep the bucket private and encrypted, and never commit a local terraform.tfstate to Git.
> - Use a SEPARATE state key per environment (dev/test/staging). Sharing one state across environments is the classic way to accidentally destroy prod.

## 5.3 A clean, reusable repository layout

Separate the reusable building blocks (modules) from the per-environment settings. This is the heart of “reusable and extendable.”

```text
terraform-clusters/
├── modules/
│   ├── network/            # VPC, subnets, route tables (often shared)
│   ├── cluster-node/        # ONE reusable definition of a node group
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── kafka/               # wraps cluster-node with Kafka specifics
│   ├── zookeeper/
│   └── nifi/
├── envs/
│   ├── dev/
│   │   ├── main.tf          # calls the modules with dev settings
│   │   ├── backend.tf
│   │   └── dev.tfvars
│   ├── test/
│   └── staging/
└── .gitlab-ci.yml
```

> **✅ BEST PRACTICE**
>
> Write a module ONCE, call it THREE times (dev/test/staging) with different variables. The logic lives in modules/; only numbers and names live in envs/. This is what makes promotion safe — staging runs the exact same module code as dev.

## 5.4 The reusable cluster-node module

A single module describes “a group of identical nodes spread across AZs.” Kafka, Zookeeper, and NiFi all reuse it. Inputs make it flexible.

### modules/cluster-node/variables.tf

```hcl
variable "name"          { type = string }                 # e.g. "kafka"
variable "node_count"    { type = number, default = 3 }
variable "instance_type" { type = string, default = "m6i.large" }
variable "ami_id"        { type = string }                 # from the SSM lookup
variable "subnet_ids"    { type = list(string) }           # one per AZ
variable "vpc_id"        { type = string }
variable "ingress_ports" {                                  # list of allowed ports
  type    = list(object({ port = number, source_sg = string }))
  default = []
}
variable "self_ports"    { type = list(number), default = [] }  # node-to-node ports
variable "ebs_size_gb"   { type = number, default = 100 }
variable "instance_profile" { type = string }
variable "tags"          { type = map(string), default = {} }
```

### modules/cluster-node/main.tf

```hcl
# One security group for this node group
resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = var.name })
}

# Allow node-to-node traffic on the cluster ports (self-reference)
resource "aws_security_group_rule" "self" {
  for_each          = toset([for p in var.self_ports : tostring(p)])
  type              = "ingress"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "tcp"
  security_group_id = aws_security_group.this.id
  source_security_group_id = aws_security_group.this.id
}

# Allow approved clients in on each declared port
resource "aws_security_group_rule" "ingress" {
  count                    = length(var.ingress_ports)
  type                     = "ingress"
  from_port                = var.ingress_ports[count.index].port
  to_port                  = var.ingress_ports[count.index].port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.this.id
  source_security_group_id = var.ingress_ports[count.index].source_sg
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.this.id
}

# The nodes themselves — spread evenly across the provided subnets/AZs
resource "aws_instance" "node" {
  count                  = var.node_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[count.index % length(var.subnet_ids)]
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = var.instance_profile

  root_block_device {
    volume_size = var.ebs_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, {
    Name        = "${var.name}-${count.index + 1}"
    ClusterRole = var.name
    NodeIndex   = count.index + 1
  })
}
```

### modules/cluster-node/outputs.tf

```hcl
output "private_ips"       { value = aws_instance.node[*].private_ip }
output "instance_ids"      { value = aws_instance.node[*].id }
output "security_group_id" { value = aws_security_group.this.id }
```

> **ℹ️ NOTE**
>
> count.index % length(subnet\_ids) is a tidy trick: it places node 1 in subnet A, node 2 in B, node 3 in C, node 4 back in A, and so on. That guarantees an even spread across AZs no matter how many nodes you ask for.

## 5.5 Wiring it together in an environment

Now the dev environment calls the module three times — once per cluster — passing the baked AMI and the right ports. This file is short because all the heavy logic is in the module.

```hcl
# envs/dev/main.tf
provider "aws" { region = var.region }

data "aws_ssm_parameter" "base_ami" {
  name = "/mycorp/ami/base-al2023/dev"
}

module "zookeeper" {
  source           = "../../modules/cluster-node"
  name             = "zookeeper"
  node_count       = 3
  ami_id           = data.aws_ssm_parameter.base_ami.value
  subnet_ids       = var.private_subnet_ids
  vpc_id           = var.vpc_id
  self_ports       = [2888, 3888]
  ingress_ports    = [{ port = 2181, source_sg = module.kafka.security_group_id }]
  instance_profile = var.node_instance_profile
  tags             = var.common_tags
}

module "kafka" {
  source           = "../../modules/cluster-node"
  name             = "kafka"
  node_count       = 3
  instance_type    = "m6i.xlarge"
  ebs_size_gb      = 500
  ami_id           = data.aws_ssm_parameter.base_ami.value
  subnet_ids       = var.private_subnet_ids
  vpc_id           = var.vpc_id
  self_ports       = [9094, 9095]   # inter-broker + KRaft controller
  ingress_ports    = [{ port = 9092, source_sg = module.nifi.security_group_id }]
  instance_profile = var.node_instance_profile
  tags             = var.common_tags
}

module "nifi" {
  source           = "../../modules/cluster-node"
  name             = "nifi"
  node_count       = 3
  ami_id           = data.aws_ssm_parameter.base_ami.value
  subnet_ids       = var.private_subnet_ids
  vpc_id           = var.vpc_id
  self_ports       = [11443]
  instance_profile = var.node_instance_profile
  tags             = var.common_tags
}
```

> **⚠️ GOTCHA**
>
> - Two modules referencing each other’s security\_group\_id (Kafka ↔ NiFi) can create a chicken-and-egg cycle. If Terraform complains about a cycle, break it by defining the security group rules in a small separate step, or reference by a known SG created in the network module.
> - Changing instance\_type or AMI may force Terraform to REPLACE the instance (destroy + create). Always read the plan’s “+/-” and “-/+” markers before approving — that is your warning that data on the box will be lost unless it lives on separate storage.

## 5.6 The core Terraform commands

```bash
$ cd envs/dev
$ terraform init                       # download providers, connect to state
$ terraform fmt -recursive             # auto-format files (keep diffs clean)
$ terraform validate                   # catch syntax/type errors early
$ terraform plan -var-file=dev.tfvars -out=plan.bin   # PREVIEW the changes
$ terraform apply plan.bin             # make exactly the previewed changes
$ terraform output                     # see IPs/IDs for the next (Ansible) step
```

> **✅ BEST PRACTICE**
>
> - Always run plan and READ it before apply. Treat any “destroy” line as a stop sign until you understand why.
> - Save the plan to a file (-out) and apply THAT exact plan. This guarantees you apply what you reviewed, not whatever changed in between.
> - Run terraform fmt and validate in the pipeline so badly formatted or invalid code cannot be merged.

> **🔧 TROUBLESHOOTING**
>
> - “Error acquiring the state lock” → someone else is running, or a previous run crashed. Confirm no one is active, then: terraform force-unlock <LOCK\_ID> (use with care).
> - “Error: creating EC2 Instance: UnauthorizedOperation” → the pipeline/role lacks an EC2 permission. The message names it; add it to the pipeline role.
> - Plan wants to replace everything unexpectedly → you likely changed the state backend key or region, so Terraform thinks nothing exists. Verify backend.tf matches the environment.
> - Drift (console changes made by hand) → run terraform plan to see differences, then either import the change or let Terraform reset it. Discourage console edits to avoid this entirely.

# 6. Ansible: Installing and Configuring the Software

Terraform gave us bare (but patched) servers. **Ansible** now logs into them and installs Java, Kafka, Zookeeper, or NiFi, writes the config files, and starts the services. Ansible is “agentless”: it connects over SSH (or SSM) and runs tasks; nothing special needs to be pre-installed on the targets.

> **🟣 IN PLAIN TERMS**
>
> If Terraform built the empty kitchen, Ansible is the printed recipe card that installs the oven, plugs in the fridge, and sets the thermostat — the same way in every kitchen. Run the card again and it checks each step; anything already done is left alone (this is called being “idempotent”).

## 6.1 Key ideas

| Term | Plain meaning |
| --- | --- |
| Inventory | The list of servers to manage, grouped by role |
| Playbook | A YAML file of steps to run on those servers |
| Role | A reusable bundle of tasks/files/templates (e.g., “kafka”) |
| Task | One action (install a package, copy a file, start a service) |
| Handler | A task that runs only when notified (e.g., “restart kafka”) |
| Idempotent | Safe to run repeatedly; only changes what is not already correct |

## 6.2 Dynamic inventory: let Ansible find the servers automatically

Do not paste IP addresses into a file by hand — they change. Use the AWS EC2 dynamic inventory plugin, which asks AWS for instances and groups them by your tags (remember ClusterRole from the Terraform module).

```
# inventory/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  tag:Environment: dev
keyed_groups:
  # Make a group per ClusterRole tag: e.g. tag_ClusterRole_kafka
  - key: tags.ClusterRole
    prefix: tag_ClusterRole
hostnames:
  - private-ip-address
compose:
  ansible_host: private_ip_address
```

```bash
$ ansible-inventory -i inventory/aws_ec2.yml --graph
@all:
  |--@tag_ClusterRole_kafka:
  |  |--10.20.0.11
  |  |--10.20.4.12
  |  |--10.20.8.13
  |--@tag_ClusterRole_zookeeper:
  |  |--10.20.0.21
  |  ...
```

> **✅ BEST PRACTICE**
>
> - Group by tags, not IPs. When Terraform adds a 4th broker, it automatically appears in the kafka group on the next run — zero inventory edits.
> - Connect over SSM Session Manager instead of SSH where possible (community.aws / aws\_ssm connection). Then you need no open SSH port and no SSH keys to manage.

## 6.3 A clean role layout

```bash
ansible/
├── ansible.cfg
├── inventory/
│   └── aws_ec2.yml
├── group_vars/
│   ├── all.yml                 # settings shared by everything
│   ├── tag_ClusterRole_kafka.yml
│   └── tag_ClusterRole_zookeeper.yml
├── roles/
│   ├── common/                 # java, users, limits, log dirs
│   ├── zookeeper/
│   ├── kafka/
│   └── nifi/
├── site.yml                    # the master playbook
└── requirements.yml            # external collections/roles
```

### 6.3.1 ansible.cfg

```
[defaults]
inventory = inventory/aws_ec2.yml
host_key_checking = False
retry_files_enabled = False
roles_path = roles
remote_user = ec2-user

[privilege_escalation]
become = True
become_method = sudo
```

## 6.4 Example role: install Java + Kafka

A role keeps tasks, templates, and triggers together. Here is the heart of a Kafka role. Notice every task is declarative (“ensure this is true”), which is what makes re-runs safe.

### roles/kafka/tasks/main.yml

```
- name: Ensure Java 17 is installed
  ansible.builtin.dnf:
    name: java-17-amazon-corretto-headless
    state: present

- name: Create kafka system user
  ansible.builtin.user:
    name: kafka
    system: true
    shell: /sbin/nologin

- name: Download Kafka from the internal mirror
  ansible.builtin.get_url:
    url: "{{ kafka_mirror }}/kafka_2.13-{{ kafka_version }}.tgz"
    dest: /opt/kafka.tgz
    checksum: "sha512:{{ kafka_sha512 }}"      # verify integrity

- name: Unpack Kafka
  ansible.builtin.unarchive:
    src: /opt/kafka.tgz
    dest: /opt/
    remote_src: true
    creates: "/opt/kafka_2.13-{{ kafka_version }}"

- name: Symlink /opt/kafka -> versioned dir (easy upgrades)
  ansible.builtin.file:
    src: "/opt/kafka_2.13-{{ kafka_version }}"
    dest: /opt/kafka
    state: link

- name: Write broker config from a template
  ansible.builtin.template:
    src: server.properties.j2
    dest: /opt/kafka/config/server.properties
    owner: kafka
  notify: restart kafka

- name: Install the kafka systemd unit
  ansible.builtin.template:
    src: kafka.service.j2
    dest: /etc/systemd/system/kafka.service
  notify: restart kafka

- name: Enable and start Kafka
  ansible.builtin.systemd:
    name: kafka
    enabled: true
    state: started
    daemon_reload: true
```

### roles/kafka/handlers/main.yml

```
- name: restart kafka
  ansible.builtin.systemd:
    name: kafka
    state: restarted
```

The broker config is a template, so each node fills in its own ID and the right Zookeeper/controller addresses. Ansible computes a unique broker id from the host’s position in the group:

### roles/kafka/templates/server.properties.j2 (excerpt)

```ini
broker.id={{ groups['tag_ClusterRole_kafka'].index(inventory_hostname) }}
listeners=PLAINTEXT://{{ ansible_host }}:9092,INTERNAL://{{ ansible_host }}:9094
inter.broker.listener.name=INTERNAL
log.dirs=/data/kafka
num.partitions=6
default.replication.factor=3
min.insync.replicas=2
{% if kafka_mode == 'zookeeper' %}
zookeeper.connect={{ groups['tag_ClusterRole_zookeeper'] | map('regex_replace','$',':2181') | join(',') }}
{% endif %}
```

> **ℹ️ NOTE**
>
> This single template supports BOTH modes. When kafka\_mode is "zookeeper" it writes the zookeeper.connect line; for KRaft you set kafka\_mode to "kraft" and the controller settings are written instead (full KRaft config is in the Kafka section).

## 6.5 The master playbook

```
# site.yml — run roles against the right groups, in the right order
- name: Base setup on every node
  hosts: all
  roles: [common]

- name: Zookeeper layer (only in classic mode)
  hosts: tag_ClusterRole_zookeeper
  roles: [zookeeper]

- name: Kafka brokers
  hosts: tag_ClusterRole_kafka
  serial: 1            # one broker at a time = rolling, no downtime
  roles: [kafka]

- name: NiFi nodes
  hosts: tag_ClusterRole_nifi
  roles: [nifi]
```

> **✅ BEST PRACTICE**
>
> - serial: 1 on Kafka means Ansible upgrades/restarts one broker, waits for it to be healthy, then moves on. This keeps the cluster available during changes.
> - Pin versions (kafka\_version, kafka\_sha512) in group\_vars and verify checksums. “Latest” downloads make builds non-reproducible and are a supply-chain risk.
> - Put data on a SEPARATE mounted volume (e.g., /data) so replacing the OS/AMI never wipes Kafka logs or NiFi repositories.

## 6.6 The Terraform → Ansible handoff

Two clean ways to connect the two tools. Both avoid copy-pasting IPs.

1. **Tag-based (recommended):** Terraform tags instances with Environment and ClusterRole; Ansible’s dynamic inventory finds them by those tags. The two tools stay loosely coupled and each can run independently.
1. **Output-based:** Terraform writes its outputs (IPs) to a file and the pipeline passes them to Ansible. Simple, but more brittle than tags.

```bash
# Typical pipeline sequence (command line equivalent)
$ cd envs/dev && terraform apply plan.bin          # build servers (tags applied)
$ cd ../../ansible
$ ansible-inventory -i inventory/aws_ec2.yml --graph   # confirm hosts show up
$ ansible-playbook site.yml                        # install + configure software
```

> **⚠️ GOTCHA**
>
> - Newly created instances may not be SSH/SSM-ready the instant Terraform finishes. Add a wait (Ansible wait\_for\_connection, or a pipeline sleep/retry) or the first play fails with “unreachable.”
> - If the dynamic inventory returns zero hosts, your tag filter does not match. Re-check the exact tag KEYS and VALUES Terraform applied (case-sensitive).
> - Ansible runs as ec2-user then sudo. If a task needs root and you forgot become: true, you get “Permission denied.”

> **🔧 TROUBLESHOOTING**
>
> - “UNREACHABLE … Failed to connect” → security group blocks 22 (or SSM agent/role missing), wrong user, or instance still booting. Test: ansible all -m ping.
> - “FAILED … checksum mismatch” → the downloaded file does not match kafka\_sha512; the mirror file changed or the version/sha pair is wrong. Update the pinned values together.
> - Service won’t start → run journalctl -u kafka -n 100 on the node; common causes are wrong JAVA path, bad server.properties, or /data not mounted/owned by kafka.
> - Change not taking effect → a handler did not fire. Confirm the task reports “changed” and that notify matches the handler name exactly.

# 7. Kafka and Zookeeper Clusters (Four Ways)

**Kafka** is a system for sending and storing streams of messages — like a super-durable, replayable group chat that other programs read from and write to. **Zookeeper** is the older helper that keeps track of cluster bookkeeping. Newer Kafka can do that bookkeeping itself using **KRaft** (no Zookeeper). We cover both, and we cover running on plain servers (without Strimzi) and on Kubernetes (with Strimzi).

> **🟣 IN PLAIN TERMS**
>
> Kafka is a conveyor belt in a factory. Producers drop boxes (messages) on the belt; consumers pick them up further down. The belt remembers the boxes for a while, so a worker who steps away can catch up later. Zookeeper is the old shift supervisor with a clipboard tracking which belt is which. KRaft replaces that supervisor with a built-in system so Kafka manages itself.

## 7.1 Picking your path

| Path | Bookkeeping | Runs on | Best when |
| --- | --- | --- | --- |
| A. Classic on EC2 | Zookeeper | EC2 (Terraform/Ansible) | You want full control, no Kubernetes |
| B. KRaft on EC2 | Built-in (no ZK) | EC2 (Terraform/Ansible) | New build, simpler ops, fewer moving parts |
| C. With Strimzi (ZK) | Zookeeper | Kubernetes (EKS) | You already run Kubernetes; want operators |
| D. With Strimzi (KRaft) | Built-in (no ZK) | Kubernetes (EKS) | Kubernetes + newest Kafka model |

> **ℹ️ NOTE**
>
> Zookeeper is being retired from Kafka over time. For brand-new clusters, prefer KRaft (paths B or D). Keep classic Zookeeper (paths A or C) when integrating with existing tooling that expects it.

## 7.2 Zookeeper cluster (for the classic paths)

Zookeeper needs an ODD number of nodes (3 or 5) so it can always reach a majority vote. Each node gets a unique id in a myid file and knows about its peers.

### roles/zookeeper/templates/zoo.cfg.j2

```ini
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data/zookeeper
clientPort=2181
{% for host in groups['tag_ClusterRole_zookeeper'] %}
server.{{ loop.index }}={{ host }}:2888:3888
{% endfor %}
```

### roles/zookeeper/tasks/main.yml (key parts)

```
- name: Create data dir
  ansible.builtin.file: { path: /data/zookeeper, state: directory, owner: zookeeper }

- name: Write this node's unique id
  ansible.builtin.copy:
    dest: /data/zookeeper/myid
    content: "{{ groups['tag_ClusterRole_zookeeper'].index(inventory_hostname) + 1 }}"

- name: Deploy zoo.cfg
  ansible.builtin.template: { src: zoo.cfg.j2, dest: /opt/zookeeper/conf/zoo.cfg }
  notify: restart zookeeper
```

> **⚠️ GOTCHA**
>
> - Use 3 or 5 nodes, never an even number. With 4 nodes you tolerate the same single failure as 3 but with more chances to break — even counts give no extra safety.
> - server.N in zoo.cfg MUST match the number in each node’s myid file. A mismatch causes endless leader-election errors (visible on ports 2888/3888).
> - Zookeeper is sensitive to disk latency. Put dataDir on fast storage (gp3) and never on a network filesystem.

> **🔧 TROUBLESHOOTING**
>
> - Check health quickly: echo stat | nc localhost 2181 — it should report a Mode of leader or follower.
> - “Cannot open channel to N at election address” → peer unreachable: check the self-referencing security group rule on 2888 and 3888, and that all nodes are up.
> - Split brain / no leader → likely an even node count, clock skew, or only a minority of nodes running. Ensure a majority is healthy.

## 7.3 Path A: Kafka with Zookeeper on EC2

With Zookeeper running, set kafka\_mode: zookeeper in group\_vars and run the Kafka role. The template writes zookeeper.connect for you. Then verify.

```
# group_vars/tag_ClusterRole_kafka.yml
kafka_mode: zookeeper
kafka_version: "3.7.1"
kafka_mirror: "https://repo.mycorp.com/kafka"
kafka_sha512: "<paste the checksum security/you verified>"
```

```bash
# Create a topic and test end-to-end (run from any broker)
$ /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
    --create --topic demo --partitions 6 --replication-factor 3
$ echo "hello cluster" | /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server localhost:9092 --topic demo
$ /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 --topic demo --from-beginning --max-messages 1
hello cluster
```

## 7.4 Path B: Kafka without Zookeeper (KRaft) on EC2

KRaft removes Zookeeper. Some brokers also act as “controllers” that hold the metadata. You generate one shared cluster id, format each node’s storage with it, then start. The same Ansible role handles this when kafka\_mode is "kraft".

### server.properties for KRaft (template excerpt)

```ini
process.roles=broker,controller
node.id={{ groups['tag_ClusterRole_kafka'].index(inventory_hostname) }}
controller.quorum.voters={% for h in groups['tag_ClusterRole_kafka'] -%}
{{ loop.index0 }}@{{ h }}:9095{{ "," if not loop.last }}
{%- endfor %}
listeners=PLAINTEXT://{{ ansible_host }}:9092,CONTROLLER://{{ ansible_host }}:9095
controller.listener.names=CONTROLLER
log.dirs=/data/kafka
```

### One-time storage format (run once per cluster)

```bash
# Generate a single cluster UUID, share it to all nodes (e.g., via a fact or SSM)
$ KAFKA_CLUSTER_ID=$(/opt/kafka/bin/kafka-storage.sh random-uuid)

# On EACH broker, format its log dir with that SAME id
$ /opt/kafka/bin/kafka-storage.sh format \
    -t "$KAFKA_CLUSTER_ID" \
    -c /opt/kafka/config/server.properties
# then start the service as usual (systemctl start kafka)
```

> **⚠️ GOTCHA**
>
> - Every node must be formatted with the SAME cluster id. Generate it once and distribute it; do not run random-uuid on each node.
> - controller.quorum.voters must list the controllers identically on every node, using node.id@host:9095. A mismatch means the quorum never forms and brokers wait forever at startup.
> - For production, many teams separate dedicated controller nodes from brokers. Combined roles (as above) are simpler and fine for smaller clusters.

> **🔧 TROUBLESHOOTING**
>
> - Broker stuck at boot in KRaft → quorum not forming: check that 9095 is open node-to-node (self SG rule) and the voters list matches everywhere.
> - “No readable meta.properties” or id errors → the log dir was not formatted, or was formatted with a different cluster id. Re-format an empty data dir with the shared id.
> - Inspect quorum health: /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status.

> **✅ BEST PRACTICE**
>
> - Set replication.factor=3 and min.insync.replicas=2 with producer acks=all so no single broker loss causes data loss.
> - Spread brokers across 3 AZs (your Terraform module already does this) so an AZ outage leaves a majority alive.
> - Turn on TLS (port 9093) and SASL authentication before any non-test use. Plaintext 9092 is for local testing only.

## 7.5 Paths C and D: Kafka with Strimzi on Kubernetes

**Strimzi** is an “operator” for Kubernetes: you describe the Kafka cluster you want in a short YAML file, and Strimzi creates and babysits all the pieces (brokers, storage, and Zookeeper or KRaft controllers). You manage Kafka the same way you manage other Kubernetes apps.

> **🟣 IN PLAIN TERMS**
>
> Without Strimzi you assemble the bicycle yourself (paths A/B). With Strimzi you tell a robot mechanic “I want a 3-speed bike,” and it builds it, keeps the tires inflated, and fixes a flat automatically. The trade-off: you now also have to own the robot’s home — the Kubernetes cluster.

### 7.5.1 Install the operator

```bash
# Assumes you have an EKS cluster and kubectl/helm configured
$ kubectl create namespace kafka
$ helm repo add strimzi https://strimzi.io/charts/
$ helm install strimzi-operator strimzi/strimzi-kafka-operator -n kafka
$ kubectl get pods -n kafka     # the cluster operator pod should be Running
```

### 7.5.2 Path C — Strimzi with Zookeeper

```yaml
# kafka-zk.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata: { name: my-cluster, namespace: kafka }
spec:
  kafka:
    replicas: 3
    listeners:
      - { name: plain, port: 9092, type: internal, tls: false }
      - { name: tls,   port: 9093, type: internal, tls: true }
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
    storage:
      type: persistent-claim
      size: 500Gi
      class: gp3
  zookeeper:
    replicas: 3
    storage: { type: persistent-claim, size: 100Gi, class: gp3 }
  entityOperator: { topicOperator: {}, userOperator: {} }
```

### 7.5.3 Path D — Strimzi with KRaft (no Zookeeper)

Newer Strimzi uses KafkaNodePools plus a KRaft annotation. Controllers and brokers are declared as pools; there is no zookeeper section at all.

```yaml
# kafka-kraft.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: kafka
  labels: { strimzi.io/cluster: my-cluster }
spec:
  replicas: 3
  roles: [controller]
  storage: { type: persistent-claim, size: 50Gi, class: gp3 }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: kafka
  labels: { strimzi.io/cluster: my-cluster }
spec:
  replicas: 3
  roles: [broker]
  storage: { type: persistent-claim, size: 500Gi, class: gp3 }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    listeners:
      - { name: tls, port: 9093, type: internal, tls: true }
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
  entityOperator: { topicOperator: {}, userOperator: {} }
```

```bash
$ kubectl apply -f kafka-kraft.yaml -n kafka
$ kubectl get kafka,kafkanodepool -n kafka
$ kubectl get pods -n kafka -w        # watch brokers/controllers come up
```

> **✅ BEST PRACTICE**
>
> - With Strimzi, create topics and users as Kubernetes objects (KafkaTopic, KafkaUser). They become version-controlled YAML you can promote across environments like everything else.
> - Use the gp3 storage class and set storage sizes deliberately — on Kubernetes the volumes are claimed automatically, but resizing later still needs care.
> - Keep the Strimzi operator version and Kafka version compatible; read the operator’s upgrade notes before bumping either.

> **⚠️ GOTCHA**
>
> - You cannot freely flip an existing Strimzi cluster between Zookeeper and KRaft by editing YAML; migration is a defined, version-gated procedure. Decide the mode up front for a new cluster.
> - Strimzi means you now operate EKS too: node groups, the EBS CSI driver for storage, and IAM Roles for Service Accounts (IRSA). That is real extra surface area — only choose Strimzi if you want Kubernetes.
> - Persistent volumes are not deleted just because you delete the Kafka object, depending on reclaim policy. Clean up PVCs to avoid silent storage costs.

> **🔧 TROUBLESHOOTING**
>
> - Pods stuck Pending → no nodes with enough CPU/memory, or no volume can be provisioned. Check kubectl describe pod and that the EBS CSI driver + gp3 storage class exist.
> - Operator not reconciling → check its logs: kubectl logs deploy/strimzi-cluster-operator -n kafka.
> - Clients cannot connect from outside the cluster → internal listeners are cluster-only; you need an external listener (type loadbalancer/nodeport/ingress) and matching security groups.

# 8. NiFi Cluster Setup

**Apache NiFi** moves data from place to place and transforms it along the way, using a visual drag-and-drop flow in a web browser. A NiFi cluster runs several nodes that share the workload and coordinate through an embedded service. NiFi often reads from and writes to Kafka, so it usually lives right next to your Kafka cluster.

> **🟣 IN PLAIN TERMS**
>
> NiFi is like a system of pipes and valves you draw on a screen. You connect a “read from Kafka” valve to a “change the format” valve to a “save to a database” valve, and data flows through automatically. A cluster is just several identical pipe-rooms sharing the work so more water moves at once.

## 8.1 How NiFi clusters coordinate

Modern NiFi uses a built-in coordination service so you do not need a separate Zookeeper for it. One node is elected coordinator and one becomes the primary node (which runs “run-once” source tasks). All nodes run the same flow.

| Port | Purpose |
| --- | --- |
| 8443 | Secure web UI and REST API (what users connect to) |
| 11443 | Cluster node-to-node protocol |
| 6342 | Cluster load-balancing of queued data |
| 2881 (embedded) | Built-in coordination (if using embedded ZooKeeper) |

## 8.2 Key settings the Ansible role templates

The NiFi role writes nifi.properties so each node knows it is clustered and how to reach its peers. The important lines:

```
# roles/nifi/templates/nifi.properties.j2 (excerpt)
nifi.cluster.is.node=true
nifi.cluster.node.address={{ ansible_host }}
nifi.cluster.node.protocol.port=11443
nifi.cluster.load.balance.port=6342
nifi.web.https.host={{ ansible_host }}
nifi.web.https.port=8443

# Repositories on the SEPARATE data volume so they survive AMI swaps
nifi.flowfile.repository.directory=/data/nifi/flowfile_repository
nifi.content.repository.directory.default=/data/nifi/content_repository
nifi.provenance.repository.directory.default=/data/nifi/provenance_repository

# Embedded coordination (simple); or point to external Zookeeper if standardized
nifi.state.management.embedded.zookeeper.start={{ 'true' if nifi_embedded_zk else 'false' }}
```

> **✅ BEST PRACTICE**
>
> - Always run NiFi over HTTPS (8443) with real authentication (OIDC/LDAP). NiFi can move sensitive data, so an open, unauthenticated UI is a serious risk.
> - Put all four repositories (flowfile, content, provenance, database) on the separate /data volume. They hold in-flight data and must outlive any OS/AMI replacement.
> - Size the content repository disk generously; back-pressure and large files fill it faster than people expect.

## 8.3 Bring up the cluster and verify

```bash
$ ansible-playbook site.yml --limit tag_ClusterRole_nifi
# Then check that all nodes joined the cluster:
$ curl -k https://<nifi-node>:8443/nifi-api/controller/cluster | jq '.cluster.nodes[].status'
"CONNECTED"
"CONNECTED"
"CONNECTED"
```

## 8.4 Connecting NiFi to Kafka (the common job)

In the NiFi UI you use processors named ConsumeKafka and PublishKafka. They need the broker addresses and, in production, TLS/SASL settings that match your Kafka listeners.

- **Bootstrap servers:** a comma-separated list of broker host:9092 (or :9093 for TLS).
- **Security protocol:** PLAINTEXT for local tests; SSL or SASL\_SSL in production.
- **Topic:** the topic to read or write, e.g. demo.

> **ℹ️ NOTE**
>
> Because NiFi and Kafka are in the same VPC and their security groups allow NiFi’s SG into Kafka on 9092/9093 (set in the Terraform module), connectivity “just works” once you enter the broker list. If it does not, it is almost always a security group or TLS-trust issue, not NiFi itself.

> **⚠️ GOTCHA**
>
> - NiFi clustering requires the nodes’ clocks to be in sync and their certificates to trust each other. Certificate/host-name mismatches are the #1 reason nodes fail to join.
> - All nodes must run the SAME NiFi version and the SAME set of custom NARs (extensions). A version drift between nodes breaks the cluster.
> - The “primary node” runs source processors once for the whole cluster. If you configure a source processor to run on “all nodes,” you can get duplicate reads.

> **🔧 TROUBLESHOOTING**
>
> - Node won’t join → check 11443 is open node-to-node (self SG rule), clocks are synced (chrony), and certs include the right hostnames (SAN).
> - UI loads but shows “Cluster has no Coordinator” → coordination service not healthy; check logs/nifi-app.log and the embedded ZK (or external ZK) status.
> - Kafka processors stuck → wrong bootstrap list, blocked port, or TLS trust missing; test from the node: nc -vz <broker> 9092 first.
> - Out of disk → content repository filled; add capacity to /data or tune back-pressure thresholds on the queues.

# 9. GitLab: Directory Structure, Pipelines, and Promotion

**GitLab** stores your code and runs your automation (CI/CD pipelines). The pipeline is a checklist that runs on every change: it formats and validates code, scans for security problems, and then deploys to dev, test, and finally staging — with approvals where you want a human to look first.

> **🟣 IN PLAIN TERMS**
>
> GitLab CI is an assembly line with quality-control stations. Your code rides the belt; at each station a robot checks something (Is it formatted? Is it valid? Any known security holes?). Only code that passes every station gets shipped to the next room (dev, then test, then staging). A human signs off before the most important room.

## 9.1 The dev-area directory structure

Keep one well-organized repository (a “monorepo”) so the AMI factory, Terraform, Ansible, and pipeline live together and move as one. A clean structure new members can navigate:

```text
clusters-platform/                 # the GitLab project (dev area root)
├── ami-factory/                   # Packer templates + patch scripts (Section 4)
├── terraform-clusters/
│   ├── modules/                   # reusable building blocks (Section 5)
│   └── envs/
│       ├── dev/                   # dev variables + backend
│       ├── test/
│       └── staging/
├── ansible/                       # roles + dynamic inventory (Section 6)
├── strimzi/                       # Kubernetes YAML for the Strimzi paths
├── pipelines/                     # shared CI templates included by .gitlab-ci.yml
│   ├── checks.yml
│   ├── terraform.yml
│   └── ansible.yml
├── docs/                          # this guide, runbooks, diagrams
├── .gitlab-ci.yml                 # the top-level pipeline
├── .pre-commit-config.yaml        # local checks before you even push
└── README.md                      # start here: how to run everything
```

> **✅ BEST PRACTICE**
>
> - Put a README at the root and in each major folder. A new engineer should find “how do I run dev?” in under a minute.
> - Keep environment differences to small \*.tfvars files and group\_vars. The logic stays shared; only values differ per environment.
> - Use .pre-commit hooks (terraform fmt, yamllint, ansible-lint) so problems are caught on the laptop before they reach a pipeline.

## 9.2 Branching and the promotion model

Use simple, protected branches that map to environments. Work happens on short-lived feature branches and merges via Merge Requests (MRs) that must pass checks.

| Branch | Maps to | Who can merge | Deploys how |
| --- | --- | --- | --- |
| feature/* | nothing (just checks) | Anyone (via MR) | Runs validation only |
| main | dev environment | Merge after review | Auto-deploy to dev |
| test | test environment | Maintainer | Deploy on merge to test |
| staging | staging environment | Maintainer + approval | Manual “play” + approval |

> **🟣 IN PLAIN TERMS**
>
> Branches are like drafts of a school essay in separate folders. “feature” is your scratch draft. “main” is the version your study group reviewed (dev). “test” and “staging” are cleaner copies you only update after the previous one looked good. You never scribble directly on the final copy.

## 9.3 The pipeline stages

Define stages once at the top; jobs attach to a stage. A typical flow:

```yaml
# .gitlab-ci.yml (top level)
stages: [check, security, plan, deploy-dev, deploy-test, deploy-staging]

include:
  - local: pipelines/checks.yml
  - local: pipelines/terraform.yml
  - local: pipelines/ansible.yml

variables:
  TF_ROOT: terraform-clusters/envs
```

### 9.3.1 Stage 1 — checks (fast feedback)

```yaml
# pipelines/checks.yml
terraform-fmt:
  stage: check
  image: hashicorp/terraform:1.9
  script:
    - terraform fmt -check -recursive terraform-clusters
yaml-lint:
  stage: check
  image: cytopia/yamllint
  script: ["yamllint ansible strimzi"]
ansible-lint:
  stage: check
  image: quay.io/ansible/ansible-lint
  script: ["ansible-lint ansible"]
```

### 9.3.2 Stage 2 — security scanning

Scan infrastructure code for misconfigurations (open security groups, unencrypted volumes) and scan for secrets accidentally committed.

```yaml
# pipelines/checks.yml (continued)
iac-scan:
  stage: security
  image: aquasec/trivy
  script:
    - trivy config terraform-clusters --severity HIGH,CRITICAL --exit-code 1
secret-scan:
  stage: security
  image: zricethezav/gitleaks
  script: ["gitleaks detect --source . --no-banner"]
```

> **✅ BEST PRACTICE**
>
> - Fail the pipeline on HIGH/CRITICAL findings (exit-code 1). A pipeline that warns but passes gets ignored; one that blocks gets fixed.
> - Run secret scanning on every MR. The cheapest leaked credential to fix is the one that never gets merged.

### 9.3.3 Stage 3 — plan (preview before any change)

```yaml
# pipelines/terraform.yml
.plan_template: &plan
  image: hashicorp/terraform:1.9
  script:
    - cd $TF_ROOT/$ENV
    - terraform init
    - terraform validate
    - terraform plan -var-file=$ENV.tfvars -out=plan.bin
  artifacts:
    paths: ["$TF_ROOT/$ENV/plan.bin"]   # save the EXACT plan for apply
    expire_in: 1 day

plan-dev:
  <<: *plan
  stage: plan
  variables: { ENV: dev }
```

### 9.3.4 Stages 4–6 — deploy dev → test → staging

Each deploy applies the reviewed plan, then runs Ansible. Dev is automatic on main; test runs on its branch; staging requires a manual click and an approval.

```yaml
# pipelines/terraform.yml (continued)
.deploy_template: &deploy
  image: hashicorp/terraform:1.9
  script:
    - cd $TF_ROOT/$ENV
    - terraform init
    - terraform apply -auto-approve plan.bin     # apply the SAVED plan only

deploy-dev:
  <<: *deploy
  stage: deploy-dev
  variables: { ENV: dev }
  environment: { name: dev }
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'           # auto on main

deploy-test:
  <<: *deploy
  stage: deploy-test
  variables: { ENV: test }
  environment: { name: test }
  rules:
    - if: '$CI_COMMIT_BRANCH == "test"'

deploy-staging:
  <<: *deploy
  stage: deploy-staging
  variables: { ENV: staging }
  environment: { name: staging }
  rules:
    - if: '$CI_COMMIT_BRANCH == "staging"'
      when: manual                                # require a human click
  allow_failure: false
```

After each Terraform deploy, the matching Ansible job installs/updates software:

```yaml
# pipelines/ansible.yml
.configure_template: &configure
  image: quay.io/ansible/ansible-runner
  script:
    - cd ansible
    - ansible all -m ping            # confirm reachability first
    - ansible-playbook site.yml

configure-dev:
  <<: *configure
  stage: deploy-dev
  needs: ["deploy-dev"]
  variables: { ANSIBLE_ENV: dev }
```

## 9.4 Protecting environments with approvals

In the GitLab UI, configure environment protections so promotion is controlled:

- **Protected branches:** main, test, and staging cannot be pushed to directly — only via MR.
- **Required approvals:** require at least one reviewer (two for staging) before merge.
- **Protected environments:** restrict who can run the staging deploy job to senior engineers.
- **CODEOWNERS file:** auto-request the right reviewers for changes to sensitive folders (e.g., IAM).

> **⚠️ GOTCHA**
>
> - A pipeline is only as trustworthy as its branch protections. If anyone can push to main, “auto-deploy to dev” becomes “anyone can deploy.” Lock branches first.
> - Re-running an OLD pipeline can apply a STALE plan. Prefer re-running the plan stage so apply uses a fresh, reviewed plan, or set plan artifacts to expire quickly.
> - Pipeline jobs run with the pipeline role’s AWS permissions. Keep that role least-privilege and scoped per environment (Section 3.1.3), or a dev job could touch staging.

> **🔧 TROUBLESHOOTING**
>
> - Job fails “no runner” → no GitLab runner is registered/online with the required tag. Check Settings → CI/CD → Runners.
> - Deploy job can’t reach AWS → OIDC trust or role ARN wrong; print identity in the job with aws sts get-caller-identity.
> - Plan artifact missing at apply → it expired or the plan job did not run; re-run plan then deploy.
> - Ansible step “0 hosts matched” → tag filter/environment mismatch; confirm Terraform tagged the new env and the inventory filter uses that Environment value.

# 10. GitLab Setup, Roles, and Secure CI/CD

Section 9 showed the directory layout and the promotion flow. This section is the hands-on companion: how to **set the project up**, who gets **which role**, how to keep GitLab itself **secure**, and how to build a **pipeline with real security checks for Terraform** step by step. Every step lists the GitLab UI clicks and, where it helps, the equivalent command line.

> **🟣 IN PLAIN TERMS**
>
> Think of GitLab as the workshop where the whole team builds. First we decide who is allowed in the workshop and what tools each person may touch (roles). Then we lock the doors and windows so nobody wanders in (secure GitLab). Finally we set up the conveyor belt that inspects every part for defects before it ships (the secure pipeline). This section walks all three, slowly.

## 10.1 GitLab roles: who can do what

GitLab has two layers of "who can do what." Keep them straight and most access problems disappear.

- **Member roles** — the access level a person has inside a project or group (Guest, Reporter, Developer, Maintainer, Owner).
- **The CI/CD job identity** — the AWS role a pipeline job assumes when it runs (covered in Section 3.1.3 and expanded in 10.5). This is a machine identity, not a person.

### 10.1.1 The member roles you will assign

| Role | Plain meaning | Give it to | Can they deploy? |
| --- | --- | --- | --- |
| Guest | Read issues, very little code access | Stakeholders who just watch | No |
| Reporter | Read code, pull, view pipelines | Analysts, new joiners (week 1) | No |
| Developer | Push branches, open MRs, run dev jobs | Most cloud engineers | Dev only |
| Maintainer | Merge to protected branches, manage CI vars | Senior/lead engineers | Up to staging |
| Owner | Full control, delete project, manage members | Team lead / platform admin | Everything |

> **🟣 IN PLAIN TERMS**
>
> These are like access badges at school. A Guest is a visitor badge — you can sit in the lobby. A Reporter can walk the halls and read the notice board. A Developer has a locker and can hand in homework (open MRs). A Maintainer is a teacher who can actually post the final grades (merge to protected branches). An Owner is the principal.

> **✅ BEST PRACTICE**
>
> - Default new team members to Developer, not Maintainer. Most work — branches, MRs, dev deploys — needs only Developer. Promote to Maintainer when someone is trusted to merge to test/staging.
> - Assign roles to GROUPS, not one project at a time. Put "Cloud Engineers" at the group level as Developer; everyone inherits it, and removing someone in one place removes them everywhere.
> - Keep Owners to a small number (2-3). Owners can delete the project and rewrite protections. Fewer owners means a smaller blast radius if an account is compromised.

> **⚠️ GOTCHA**
>
> - Developer can run pipelines, and pipelines hold AWS power. That is why the pipeline AWS role must be scoped to branches (Section 3.1.3) — otherwise "Developer can deploy to dev" could leak into other environments.
> - A user’s effective access is the HIGHEST of their group and project roles. Granting project-level Maintainer to someone who is group Developer quietly upgrades them. Audit both layers.

### 10.1.2 Step by step: create the group, project, and members

**In the GitLab web UI:**

1. Create a group: top bar → "Create new…" → New group → name it platform. Groups let you share members, variables, and runners across projects.
1. Inside the group: New project → Create blank project → name it clusters-platform. This is the monorepo from Section 9.1.
1. Set the group’s default role: Group → Settings → Members → invite your team, set most to Developer, leads to Maintainer.
1. Turn off project creation by everyone: Group → Settings → General → Permissions → restrict "project creation" to Maintainers, so the structure stays clean.
1. Push the initial structure from your laptop (command line):

```bash
# from inside your local clusters-platform/ folder
git init
git remote add origin git@gitlab.mycorp.com:platform/clusters-platform.git
git checkout -b main
git add .
git commit -m "Initial platform structure"
git push -u origin main
```

> **ℹ️ NOTE**
>
> Prefer SSH (git@…) over HTTPS for day-to-day pushing: add your SSH public key under Preferences → SSH Keys. No password prompts, and nothing to leak in a script.

## 10.2 Best practices for a secure GitLab

A pipeline can only be as trustworthy as the GitLab it runs on. Lock the platform down first, then build pipelines on top. The items below are ordered from "do this on day one" to "do this as you mature."

### 10.2.1 Accounts and access

> **✅ BEST PRACTICE**
>
> - Require two-factor authentication (2FA) for everyone: Admin Area → Settings → General → Sign-in restrictions → "Require all users to set up 2FA." A stolen password alone then cannot log in.
> - Use SSO/SAML against your company identity provider so joining and leaving the company automatically grants and revokes GitLab access. No orphaned accounts.
> - Disable public sign-up on a self-managed instance: Admin Area → Settings → General → Sign-up restrictions → uncheck "Sign-up enabled." Only invited, known people get in.
> - Review members quarterly. Remove anyone who changed teams. Access tends to accumulate; prune it deliberately.

### 10.2.2 Protecting code and branches

> **✅ BEST PRACTICE**
>
> - Protect main, test, and staging: Project → Settings → Repository → Protected branches. Set "Allowed to push" to No one, "Allowed to merge" to Maintainers. All change arrives via Merge Request.
> - Require Merge Request approvals: Project → Settings → Merge requests → require at least 1 approval (2 for staging-bound changes), and turn on "Prevent approval by the author."
> - Add a CODEOWNERS file so sensitive folders (IAM, networking, staging tfvars) auto-request a senior reviewer. A change to permissions should never merge on one junior approval.
> - Turn on "Require a signed commit" for protected branches if your team uses GPG/SSH signing, so the author of every change is cryptographically verifiable.

**Example** CODEOWNERS file at the repo root:

```
# .gitlab/CODEOWNERS  (or repo root)
# These paths require review by the listed owners before merge.

/terraform-clusters/modules/             @platform-leads
/terraform-clusters/envs/staging/        @platform-leads
*iam*                                    @security-team
*.tfvars                                 @platform-leads
/pipelines/                              @platform-leads
```

> **🟣 IN PLAIN TERMS**
>
> CODEOWNERS is a sign-up sheet taped to certain doors. If you want to change what is behind that door (say, the IAM rules), the person whose name is on the sheet has to come and approve it first. The riskier the room, the more senior the name on the sheet.

### 10.2.3 Secrets: never commit them, store them safely

The single most common cloud incident is a leaked credential. GitLab gives you two defenses: keep secrets OUT of git, and catch them if they slip in.

> **✅ BEST PRACTICE**
>
> - Store secrets as masked, protected CI/CD variables: Project → Settings → CI/CD → Variables. "Masked" hides them in job logs; "Protected" exposes them only to protected branches (so a feature branch never sees production secrets).
> - Prefer NO long-lived secrets at all. Use OIDC to assume an AWS role (Section 3.1.3 and 10.5) so the pipeline gets short-lived credentials and there is nothing to leak.
> - Keep a .gitignore that excludes \*.tfvars.secret, \*.pem, \*.key, and .env so they cannot be added by accident.
> - Run gitleaks on every Merge Request (built into the pipeline in 10.4) so a committed secret blocks the merge instead of reaching main.

> **⚠️ GOTCHA**
>
> - Marking a variable "Masked" only hides it in logs — it does NOT encrypt it at rest beyond GitLab’s own storage, and it will not mask values that are too short or contain certain characters. Use real secrets managers (AWS Secrets Manager, Vault) for high-value secrets.
> - A secret committed once is compromised FOREVER, even if you delete it in a later commit — it lives in git history. If one leaks: rotate it immediately, then scrub history. Deleting the file is not enough.
> - CI/CD variables that are NOT marked "Protected" are readable by jobs on any branch, including a branch someone pushed to a fork. Mark production-scoped variables Protected.

### 10.2.4 Runners: where your jobs actually execute

A **runner** is the machine that runs pipeline jobs. Because runners hold your AWS role and clone your code, a careless runner is a serious risk.

> **✅ BEST PRACTICE**
>
> - Prefer project- or group-specific runners for anything that touches AWS, rather than shared runners that also serve untrusted projects.
> - Use ephemeral runners (a fresh VM/container per job, e.g., the Docker or Kubernetes executor) so nothing leaks between jobs and a compromised job cannot poison the next one.
> - Tag runners (e.g., aws, terraform) and require those tags on deploy jobs so only the hardened runners can run them.
> - Patch and rebuild runner hosts on the same cadence as your AMIs (Section 4). A stale runner is an unmonitored server with cloud credentials.

> **🔧 TROUBLESHOOTING**
>
> - Job stuck "pending / waiting for runner" → no online runner matches the job’s tags. Check Settings → CI/CD → Runners; confirm a runner with that tag is green.
> - Job picked up by the wrong runner → tighten tags; set "Run untagged jobs" to off on hardened runners so they only take explicitly tagged work.

### 10.2.5 Instance and operational hardening

- **Keep GitLab patched:** subscribe to GitLab security releases and apply them promptly; self-managed GitLab is internet-adjacent infrastructure.
- **Back up regularly:** automate gitlab-backup and store copies off-box; test a restore at least once so you know it works.
- **Enable audit events:** Admin Area → Monitoring → Audit Events to see who changed protections, members, or variables.
- **Set token expiry:** project/personal access tokens should have short expirations; long-lived tokens are a common breach vector.

## 10.3 Connecting GitLab to AWS with OIDC (no stored keys)

Section 3.1.3 defined the pipeline’s AWS role and its trust policy. Here is the end-to-end setup so a job can call AWS with short-lived credentials and zero stored secrets.

### 10.3.1 One-time AWS setup

1. Create an IAM OIDC identity provider pointing at your GitLab. (Console and CLI both shown below.)
1. Create the pipeline IAM role with the trust policy from Section 3.1.3 (scoped to your project and protected branches).
1. Attach a least-privilege permission policy (it needs EC2, VPC, IAM PassRole for instance profiles, S3 for state, and SSM for the AMI parameter).

**AWS CLI** — create the OIDC provider and role:

```bash
# 1) Register GitLab as an OIDC provider (thumbprint is GitLab's TLS cert)
aws iam create-open-id-connect-provider \
  --url "https://gitlab.mycorp.com" \
  --client-id-list "https://gitlab.mycorp.com" \
  --thumbprint-list "<tls-cert-thumbprint>"

# 2) Create the role with the trust policy file (from Section 3.1.3)
aws iam create-role \
  --role-name gitlab-clusters-pipeline \
  --assume-role-policy-document file://pipeline-trust.json

# 3) Attach a scoped permission policy
aws iam put-role-policy \
  --role-name gitlab-clusters-pipeline \
  --policy-name clusters-deploy \
  --policy-document file://pipeline-permissions.json
```

**AWS Web Console** — the same thing by clicking:

1. IAM → Identity providers → Add provider → choose "OpenID Connect" → Provider URL: https://gitlab.mycorp.com → Audience: https://gitlab.mycorp.com → Add provider.
1. IAM → Roles → Create role → "Web identity" → select the GitLab provider and audience → Next.
1. Attach (or create) the permission policy → Next → name it gitlab-clusters-pipeline → Create role.
1. Open the new role → Trust relationships → Edit → paste the scoped condition (project\_path + ref) from Section 3.1.3 → Update policy.

### 10.3.2 The GitLab job side

In any job that needs AWS, request an ID token and exchange it for AWS credentials. No keys are stored anywhere.

```
# snippet reused by every AWS-touching job
.aws_oidc: &aws_oidc
  id_tokens:
    AWS_ID_TOKEN:
      aud: https://gitlab.mycorp.com
  before_script:
    - >
      export $(aws sts assume-role-with-web-identity
      --role-arn "$AWS_PIPELINE_ROLE_ARN"
      --role-session-name "gitlab-${CI_PIPELINE_ID}"
      --web-identity-token "$AWS_ID_TOKEN"
      --duration-seconds 3600
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
      --output text | awk '{print "AWS_ACCESS_KEY_ID="$1"\nAWS_SECRET_ACCESS_KEY="$2"\nAWS_SESSION_TOKEN="$3}')
    - aws sts get-caller-identity   # prove who we are before doing anything
```

> **✅ BEST PRACTICE**
>
> Store only the ROLE ARN as a CI/CD variable (AWS\_PIPELINE\_ROLE\_ARN) — that is not a secret. There are no access keys to rotate or leak, because the credentials are minted fresh per job and expire in an hour.

> **🔧 TROUBLESHOOTING**
>
> - "Not authorized to perform sts:AssumeRoleWithWebIdentity" → the trust condition does not match this branch/project. Echo $CI\_PROJECT\_PATH and $CI\_COMMIT\_REF\_NAME and compare to the StringLike "sub" condition.
> - "InvalidIdentityToken" → audience mismatch; the aud in id\_tokens must exactly equal the client-id you registered on the OIDC provider.
> - Credentials work in dev but not staging → you likely scoped the trust to one branch; add the staging ref (or use a per-environment role).

## 10.4 Step by step: a secure Terraform pipeline

This is the full build of a pipeline that **checks, scans, plans, and deploys** Terraform safely. We add one stage at a time so you understand what each guard does and why. The finished file lives at *.gitlab-ci.yml* and includes the templates under *pipelines/* (Section 9.1).

> **🟣 IN PLAIN TERMS**
>
> We are building a car wash for code, one station at a time. Station 1 rinses (formatting). Station 2 inspects for damage (security scans). Station 3 shows you a photo of exactly what will change before it happens (plan). Station 4 actually does the work (apply) — and the final, most important station needs a human to press the button.

### 10.4.1 Step 1 — define stages and shared settings

```yaml
# .gitlab-ci.yml
stages: [check, security, plan, deploy-dev, deploy-test, deploy-staging]

include:
  - local: pipelines/terraform.yml
  - local: pipelines/security.yml

variables:
  TF_VERSION: "1.9"
  TF_ROOT: terraform-clusters/envs
  # AWS_PIPELINE_ROLE_ARN is set as a CI/CD variable (not a secret), see 10.3
```

### 10.4.2 Step 2 — format and validate (the "check" stage)

Fast, cheap feedback that catches sloppy or broken code before any scanning or planning. These jobs need no AWS access at all.

```yaml
# pipelines/terraform.yml
tf-fmt:
  stage: check
  image: hashicorp/terraform:1.9
  script:
    - terraform fmt -check -recursive terraform-clusters
tf-validate:
  stage: check
  image: hashicorp/terraform:1.9
  script:
    - cd $TF_ROOT/dev
    - terraform init -backend=false   # validate doesn't need real state
    - terraform validate
```

> **✅ BEST PRACTICE**
>
> Run terraform init -backend=false for validation so the check stage needs no AWS credentials or state lock. Keep credential-holding jobs to the minimum number of stages.

### 10.4.3 Step 3 — security scanning for Terraform (the heart of this section)

This stage is what makes the pipeline "secure." Three complementary scanners catch three different classes of problem:

| Scanner | What it catches | Example finding |
| --- | --- | --- |
| tfsec / Trivy config | Insecure infrastructure settings | Security group open to 0.0.0.0/0; unencrypted EBS |
| Checkov | Policy & compliance violations | S3 bucket without encryption or versioning |
| gitleaks | Secrets committed to git | An AWS access key or password in a file |

```yaml
# pipelines/security.yml
tfsec:
  stage: security
  image: aquasec/tfsec:latest
  script:
    - tfsec terraform-clusters --minimum-severity HIGH
  # fail the pipeline on HIGH/CRITICAL so problems block the merge

checkov:
  stage: security
  image: bridgecrew/checkov:latest
  script:
    - checkov -d terraform-clusters --compact --quiet
      --check CKV_AWS_* --hard-fail-on HIGH

trivy-config:
  stage: security
  image: aquasec/trivy:latest
  script:
    - trivy config terraform-clusters --severity HIGH,CRITICAL --exit-code 1

gitleaks:
  stage: security
  image: zricethezav/gitleaks:latest
  script:
    - gitleaks detect --source . --no-banner --redact
```

> **✅ BEST PRACTICE**
>
> - Make security findings BLOCK the pipeline (non-zero exit on HIGH/CRITICAL). A scan that only warns gets ignored; a scan that blocks gets fixed.
> - Pin scanner image versions (e.g., tfsec:v1.28) so a new scanner release cannot break your pipeline overnight. Bump them deliberately.
> - Use an explicit, reviewed ignore file (.checkov.yaml, .tfsec/) for accepted exceptions, with a comment explaining WHY each is allowed. Never silence a whole rule globally.
> - Export results as artifacts/reports so reviewers see findings in the Merge Request, not just in raw job logs.

> **⚠️ GOTCHA**
>
> - Scanners check the CODE, not the deployed reality. They will not catch drift (someone changed a security group by hand in the console). Pair scanning with drift detection (terraform plan on a schedule).
> - A passing scan is necessary, not sufficient. Scanners encode common mistakes; they do not understand your specific threat model. Human review of IAM and network changes still matters (that’s what CODEOWNERS enforces).
> - Suppressing a finding inline (e.g., a tfsec:ignore comment) with no expiry quietly becomes permanent. Prefer time-bounded, reviewed exceptions.

### 10.4.4 Step 4 — plan (preview every change, with AWS access)

Only now do we touch AWS, and only to PREVIEW. The job assumes the pipeline role via OIDC (10.3), runs a plan, and saves the exact plan as an artifact so the later apply cannot deploy anything different.

```yaml
# pipelines/terraform.yml (continued)
.tf_plan: &tf_plan
  <<: *aws_oidc                       # from 10.3 - short-lived AWS creds
  image: hashicorp/terraform:1.9
  script:
    - cd $TF_ROOT/$ENV
    - terraform init
    - terraform plan -var-file=$ENV.tfvars -out=plan.bin
    - terraform show -no-color plan.bin > plan.txt
  artifacts:
    paths: ["$TF_ROOT/$ENV/plan.bin", "$TF_ROOT/$ENV/plan.txt"]
    expire_in: 1 day

plan-dev:    { <<: *tf_plan, stage: plan, variables: { ENV: dev } }
plan-test:   { <<: *tf_plan, stage: plan, variables: { ENV: test } }
plan-staging:{ <<: *tf_plan, stage: plan, variables: { ENV: staging } }
```

> **✅ BEST PRACTICE**
>
> Attach plan.txt to the Merge Request so a reviewer reads exactly what will change before approving. "Approve the plan, then apply the approved plan" is the core safety loop of infrastructure CI.

### 10.4.5 Step 5 — deploy dev → test → staging (apply the approved plan)

Apply consumes the SAVED plan only. Dev is automatic on main; test runs on its branch; staging needs a manual click by an authorized person and an approval.

```yaml
# pipelines/terraform.yml (continued)
.tf_apply: &tf_apply
  <<: *aws_oidc
  image: hashicorp/terraform:1.9
  script:
    - cd $TF_ROOT/$ENV
    - terraform init
    - terraform apply -auto-approve plan.bin   # the SAVED plan, nothing new

deploy-dev:
  <<: *tf_apply
  stage: deploy-dev
  variables: { ENV: dev }
  environment: { name: dev }
  needs: ["plan-dev"]
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'

deploy-staging:
  <<: *tf_apply
  stage: deploy-staging
  variables: { ENV: staging }
  environment: { name: staging }
  needs: ["plan-staging"]
  rules:
    - if: '$CI_COMMIT_BRANCH == "staging"'
      when: manual                 # a human must click "play"
  allow_failure: false
```

> **⚠️ GOTCHA**
>
> - Re-running an OLD pipeline can apply a STALE plan that no longer matches reality. Prefer re-running the plan stage so apply uses a fresh, reviewed plan; keep plan artifacts short-lived (expire\_in: 1 day).
> - The apply job holds real AWS power. Restrict who can run the manual staging job via Protected Environments (10.4.6), or "manual" just means "anyone with Developer can click it."

### 10.4.6 Step 6 — lock the environments (the clicks that make it safe)

The pipeline YAML is only half the safety. Finish in the GitLab UI:

1. Project → Settings → Repository → Protected branches: main/test/staging → Allowed to push = No one, Allowed to merge = Maintainers.
1. Project → Settings → CI/CD → Protected environments: add staging → "Allowed to deploy" = Maintainers (or a specific group). Now only they can run the manual job.
1. Project → Settings → Merge requests: require approvals (2 for staging-bound), enable "Prevent approval by author," and "Pipelines must succeed."
1. Confirm the CI/CD variable AWS\_PIPELINE\_ROLE\_ARN is set; mark production-scoped variables Protected so feature branches cannot read them.

> **✅ BEST PRACTICE**
>
> Turn on "Pipelines must succeed" and "All discussions resolved" before merge. Combined with required approvals and protected branches, this makes it structurally impossible to ship un-scanned, un-reviewed infrastructure.

### 10.4.7 The finished pipeline at a glance

```
push / Merge Request
        |
   [check]      tf fmt, tf validate            (no AWS)
        |
  [security]    tfsec, checkov, trivy, gitleaks (no AWS, BLOCKS on HIGH)
        |
    [plan]      terraform plan -> plan.bin      (OIDC: short-lived AWS)
        |        (reviewer reads plan.txt in the MR, approves)
        |
 [deploy-dev]   apply plan.bin (auto on main)
        |
 [deploy-test]  apply plan.bin (on test branch)
        |
[deploy-staging] apply plan.bin (manual click + approval, Maintainers only)
```

> **🔧 TROUBLESHOOTING**
>
> - Security stage fails but you cannot see why → open the failing job log; each scanner prints the file, line, and rule ID. Fix the code or add a reviewed, time-bounded exception.
> - Plan succeeds, apply fails with "saved plan is stale" → state changed since the plan. Re-run the plan stage, get fresh approval, then apply.
> - Staging job is greyed out / cannot run → you are not in the Protected Environments allow-list, or the branch is not staging. Check 10.4.6 step 2.
> - Everything passes but nothing deploys → check the rules: blocks; the branch name must match (main/test/staging) for the matching deploy job to appear.

# 11. Two GitLab Instances: Dev Side and Airgapped Side

Many secure programs run **two separate GitLab servers**. The **dev side** is connected to the internet, where engineers write and test code and pull packages. The **airgapped side** is isolated from the internet for security and runs the protected environment. Because the airgapped side cannot reach out, you must deliberately carry approved code and software across the gap.

> **🟣 IN PLAIN TERMS**
>
> Picture two libraries. The first is downtown with internet and new books arriving daily (dev side). The second is a vault with no doors to the outside (airgapped side). To put a book in the vault, a trusted courier copies an approved book onto a sealed drive, an inspector checks it, and only then is it shelved inside. Nothing wanders in on its own.

## 11.1 Why airgap, and what it costs you

- **Why:** isolation dramatically reduces the chance of remote attack or data exfiltration for sensitive workloads.
- **Cost:** no public internet means no pulling from public package repos, container registries, or Terraform/Ansible/Strimzi downloads. Everything must come from internal mirrors that you fill on purpose.

## 11.2 What must cross the gap

Plan for four categories. Each needs a verified, logged transfer.

| Category | Examples | How it is carried |
| --- | --- | --- |
| Source code | Terraform, Ansible, Packer, CI templates | Git bundle of the repo |
| Binaries/packages | Kafka tgz, RPMs, Java, provider plugins | Mirror sync (files + checksums) |
| Container images | Strimzi operator, runner images | Saved image tarballs → internal registry |
| Base AMIs | The patched golden image | Re-baked inside the airgap or exported/imported |

## 11.3 Syncing the two GitLabs with a Git bundle

A **git bundle** packs an entire repository (or just new commits) into a single file you can move across the gap and unpack on the other side. This is the cleanest way to keep the airgapped repo in step with the dev repo.

### On the dev side — create the bundle

```bash
# Clone a full mirror of the project (all branches + tags)
$ git clone --mirror https://gitlab.mycorp.com/platform/clusters-platform.git
$ cd clusters-platform.git

# Bundle EVERYTHING (first transfer)
$ git bundle create /transfer/clusters-full.bundle --all

# OR bundle only what is new since the last sync tag (incremental, smaller)
$ git bundle create /transfer/clusters-delta.bundle last-airgap-sync..main
$ git tag -f last-airgap-sync main      # move the marker for next time
```

### Move it across, then on the airgapped side — apply the bundle

```bash
# After the security review + media transfer puts the file on the airgapped network:
$ git clone /transfer/clusters-full.bundle clusters-platform   # first time
# For later deltas, from inside the existing repo:
$ git pull /transfer/clusters-delta.bundle main

# Then push into the airgapped GitLab
$ git remote add airgap https://gitlab.airgap.mycorp.local/platform/clusters-platform.git
$ git push airgap --all && git push airgap --tags
```

> **✅ BEST PRACTICE**
>
> - Use incremental bundles (range A..B) for routine syncs — they are small and fast. Keep a full bundle as a periodic baseline in case the chain breaks.
> - Sign your tags/commits and verify signatures on the airgapped side, so you can prove what crossed the gap and that it was not altered.
> - Record every transfer (what, when, who, checksum) in a transfer log. Auditors will want this trail.

> **⚠️ GOTCHA**
>
> - A delta bundle only applies if the airgapped repo already has the starting commit of the range. If the chain is broken (a missed sync), the pull fails — fall back to a full bundle.
> - git bundle carries commits, branches, and tags, but NOT GitLab-specific data (MRs, CI variables, issues). Recreate CI/CD variables and protections separately on the airgapped GitLab.
> - Never assume the bundle is safe just because it came from “our” dev side. It must pass the security/malware review at the boundary like anything else.

## 11.4 Mirroring packages and container images

Code alone will not run without its dependencies. Fill internal mirrors on the dev side, export, and load them inside the airgap.

### 11.4.1 OS packages and tarballs

- Maintain an internal dnf/yum mirror (this is also your security-patch mirror from Section 4) and an internal HTTP file store for Kafka/NiFi tarballs.
- Sync new approved files to removable media or an approved one-way transfer, then load into the airgapped mirror. Carry the checksums and verify after copy.

### 11.4.2 Container images (for Strimzi/EKS or runners)

```bash
# Dev side: save images to tar files
$ docker pull quay.io/strimzi/operator:0.43.0
$ docker save quay.io/strimzi/operator:0.43.0 -o /transfer/strimzi-operator.tar

# Airgapped side: load and push to the internal registry
$ docker load -i /transfer/strimzi-operator.tar
$ docker tag quay.io/strimzi/operator:0.43.0 registry.airgap.mycorp.local/strimzi/operator:0.43.0
$ docker push registry.airgap.mycorp.local/strimzi/operator:0.43.0
```

### 11.4.3 Terraform providers and Ansible collections

- **Terraform:** run a provider mirror so init pulls from inside: terraform providers mirror ./providers, copy that folder across, and point Terraform at it with a filesystem mirror in the CLI config.
- **Ansible:** download collections to a tarball with ansible-galaxy collection download, carry them across, and install from the local path.

## 11.5 AMIs inside the airgap

AMIs are region/account-specific, so you generally do not “copy” the dev AMI in. Two clean options:

1. **Re-bake inside (preferred):** run the same Packer template inside the airgapped account, pulling the base OS and patches from the internal mirrors. Same code, same result, no cross-account image movement.
1. **Export/import:** where policy permits, export the image to a file (VM image) and import it inside the airgap. Heavier and slower; use only if re-baking is not possible.

> **✅ BEST PRACTICE**
>
> Keep the Packer template and patch scripts identical on both sides and select the package source by variable (public mirror vs internal mirror). Then “the airgapped build” is just the same build with a different repo URL — nothing special to learn.

## 11.6 Keeping the two sides aligned over time

- **One source of truth:** developers always commit on the dev side; the airgapped side is downstream. Avoid editing code directly in the airgap, or the two will drift.
- **Regular cadence:** schedule syncs (for example weekly) plus on-demand for urgent security patches.
- **Same pipeline both sides:** the .gitlab-ci.yml is identical; only variables differ (mirror URLs, registry host, role ARNs). This is why the structure in Section 9 is reusable across both instances.

> **⚠️ GOTCHA**
>
> - Drift is the silent killer: if someone hand-edits the airgapped repo, the next bundle pull can conflict. Treat the airgapped repo as read-mostly and reconcile carefully if an emergency edit was unavoidable.
> - CI/CD variables, runners, and branch protections do NOT travel in a bundle. Maintain a short checklist to recreate them on the airgapped GitLab whenever they change on dev.
> - Version skew between sides causes confusing failures. Tag what you synced (e.g., release-2025.06) so both sides can state exactly which version they run.

> **🔧 TROUBLESHOOTING**
>
> - git pull of a delta fails with “does not make sense” → the base commit is missing on the airgapped side; apply a full bundle to resync.
> - terraform init fails offline → provider mirror not configured or incomplete; re-run providers mirror on dev for the exact provider versions and re-transfer.
> - Kubernetes can’t pull an image → it is still pointing at a public registry; update the image reference to registry.airgap.mycorp.local and ensure the image was pushed.
> - dnf can’t find a package inside the airgap → the internal mirror lacks it; add the approved RPM to the mirror and refresh metadata (createrepo\_c).

# 12. Cross-Cutting Best Practices and Security

These apply across every section. Skim them now; return to them before going to staging.

## 12.1 Security hardening summary

- **No keys on servers:** use IAM roles/instance profiles everywhere. No AWS access keys baked into AMIs, code, or pipelines (use OIDC).
- **Private by default:** data nodes in private subnets; admin access via SSM Session Manager, not open SSH.
- **Encrypt everything:** EBS volumes, AMIs/snapshots, S3 buckets, and Kafka/NiFi traffic (TLS) all encrypted.
- **Least privilege:** separate roles per job and per environment; name exact resource ARNs in policies.
- **Patch continuously:** re-bake AMIs on a schedule and on critical CVEs; roll the fleet to adopt them.
- **Scan in CI:** IaC scanning and secret scanning block merges on HIGH/CRITICAL findings.
- **Verify integrity:** GPG-check packages, checksum downloads, sign commits/tags for airgap transfers.

## 12.2 Reliability and operations

- **Spread across 3 AZs:** every cluster places nodes in three subnets/AZs so one data-center outage is survivable.
- **Data on separate volumes:** Kafka logs and NiFi repositories live on a /data volume that outlives AMI swaps.
- **Rolling changes:** serial: 1 in Ansible and replication.factor=3/min.insync.replicas=2 in Kafka keep clusters up during updates.
- **Backups:** snapshot data volumes and, for Kafka, consider topic mirroring; test that you can actually restore.
- **Monitoring:** ship metrics/logs to CloudWatch (or your stack); alert on broker under-replication, disk usage, and node health.

## 12.3 Cost awareness

- **Right-size:** start small (e.g., m6i.large), measure, then grow. Oversized instances are the most common waste.
- **Clean up:** de-register old AMIs AND delete their EBS snapshots; remove orphaned PVCs on Kubernetes; tear down unused dev stacks.
- **Tag for cost:** apply consistent tags (Environment, Team, ClusterRole) so spend is attributable.
- **NAT and cross-AZ traffic cost money:** high-volume Kafka across AZs incurs data-transfer charges — expected, but watch it.

## 12.4 Making it reusable and extendable

Everything in this guide is built so a new team can add a fourth cluster type or a fourth environment with almost no new code.

1. **Add a new environment:** copy envs/dev to envs/qa, change the tfvars and backend key, add a deploy job and a branch. The modules are untouched.
1. **Add a new cluster type:** reuse the cluster-node module with new ports, and add an Ansible role for the software. The pattern is identical to Kafka/NiFi.
1. **Change instance size or count:** edit one variable; plan; apply. The AZ-spread logic adjusts automatically.
1. **Adopt a new base image:** re-bake with Packer; the SSM parameter updates; the next deploy uses it. No code edits in Terraform.

# 13. Troubleshooting Quick-Reference

A fast index of the most common failures and where to look. Each step’s section has more detail.

| Symptom | Most likely cause | First thing to try |
| --- | --- | --- |
| AccessDenied / cannot assume role | IAM trust or permission gap | aws sts get-caller-identity; read the exact denied action |
| Connection times out between nodes | Security group / subnet route | nc -vz <ip> <port>; check self-referencing SG rule |
| Connection refused | Service not listening yet | systemctl status <svc>; journalctl -u <svc> |
| Packer: no AMI matches filter | Wrong name pattern or owner | describe-images with the al2023 name filter |
| New servers on old packages | Launched from old AMI ID | Check SSM parameter value Terraform read |
| Terraform state lock error | Concurrent/crashed run | Confirm no one is active; force-unlock <id> carefully |
| Ansible UNREACHABLE | SSH/SSM not ready or blocked | ansible all -m ping; add wait_for_connection |
| Checksum mismatch on download | Version/sha pair wrong | Update kafka_version and kafka_sha512 together |
| Zookeeper: no leader | Even node count / myid mismatch | echo stat \| nc localhost 2181; verify myid vs zoo.cfg |
| KRaft broker stuck at boot | Quorum not forming | Check 9095 SG rule and identical voters list |
| Strimzi pods Pending | No capacity / no volume | kubectl describe pod; check EBS CSI + gp3 class |
| NiFi node won’t join | Cert/hostname or clock skew | Check 11443 rule, chrony sync, cert SANs |
| Pipeline: no runner | Runner offline/untagged | Settings → CI/CD → Runners |
| Airgap delta bundle fails | Missing base commit | Apply a full bundle to resync |

# 14. Glossary (Plain-English)

| Term | Plain meaning |
| --- | --- |
| AMI | A saved server-disk image you stamp into many identical servers |
| Packer | Tool that bakes AMIs by running your steps on a temp server |
| Terraform | Tool that builds AWS resources from text files |
| State (Terraform) | Terraform’s memory file of what it built; kept in S3 |
| Module | A reusable folder of Terraform resources you call repeatedly |
| Ansible | Tool that logs into servers and installs/configures software |
| Idempotent | Safe to run again; only changes what is not already correct |
| Inventory | The list of servers Ansible manages, grouped by tags |
| IAM | AWS permissions system: who/what may do which actions |
| Role / Instance profile | Borrowable identity for machines; no stored keys |
| OIDC | Lets GitLab assume an AWS role with no stored AWS keys |
| VPC / Subnet / AZ | Your private network / a slice of it / a separate data center |
| Security group | A per-server firewall listing allowed ports/sources |
| Kafka | Durable, replayable message stream between systems |
| Zookeeper | Older helper that tracks Kafka cluster bookkeeping |
| KRaft | Kafka’s built-in mode that removes the need for Zookeeper |
| Strimzi | Operator that runs Kafka on Kubernetes from simple YAML |
| NiFi | Visual tool that moves and transforms data between systems |
| Pipeline (CI/CD) | Automated checklist that checks and deploys your code |
| Airgap | A network isolated from the internet for security |
| Git bundle | A single file packing a repo’s commits to move across a gap |

# 15. Quick-Start Checklist for a New Engineer

Your first week, in order. Do these in dev only until you are comfortable.

1. Get AWS SSO access and confirm it: aws sts get-caller-identity.
1. Clone the clusters-platform repo and read the root README and docs/.
1. Install tooling locally: terraform, packer, ansible, awscli, jq, and the pre-commit hooks.
1. Read Sections 3 (IAM/network) and 4 (AMIs) before touching anything.
1. Trigger a base AMI bake in dev and confirm the SSM parameter updated.
1. In envs/dev, run terraform init, fmt, validate, then plan and READ it.
1. Apply the dev plan; confirm instances appear with correct Environment and ClusterRole tags.
1. Run ansible all -m ping, then ansible-playbook site.yml to install the software.
1. Create a Kafka test topic and produce/consume one message (Section 7.3 or 7.4).
1. Open a tiny MR (e.g., a README typo) to watch the full pipeline run its checks.
1. Pair with a senior engineer to observe a promotion to test and the staging approval.
1. Review Section 11 so you understand how changes reach the airgapped side.

> **ℹ️ NOTE**
>
> Golden rule: if it is not in Git, it does not exist. Make every change through code and the pipeline, read every plan before approving, and never hand-edit running servers or the AWS Console for real resources.

**End of guide.** Keep this document in docs/ alongside the code so it versions with the platform and stays accurate as the system evolves.

