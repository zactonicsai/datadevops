# Running Apache Kafka on AWS with Strimzi — A Step‑by‑Step Guide

*Written so a curious middle‑schooler could follow along. Every command and every line of code is explained. Last updated June 2026.*

---

## How to read this guide

This is long on purpose. You can read it top to bottom, or jump around using this map:

1. **The big picture** — what we are building and the two ways to build it (EKS vs ECS).
2. **AWS concepts first** — every AWS "thing" we need, what it does, why it matters, and how they snap together. No Terraform yet — just ideas, AWS CLI commands, and which Console screens you'd click.
3. **EKS option (recommended)** — Terraform line by line, then Strimzi line by line.
4. **ECS option (alternative)** — Terraform line by line, plus the honest gotchas.
5. **Connecting, testing, securing, and extending.**
6. **Cheat sheets** — CLI commands and a glossary.

A quick promise about versions: software changes fast. As of June 2026 the current pieces are **Amazon EKS Kubernetes 1.34**, **Strimzi 1.0.0** (released April 28, 2026), and the **Terraform AWS provider 6.x** (6.50 at time of writing). Where a version matters, I call it out so you can bump it later.

---

## 1. The big picture

### What is Kafka, in one paragraph?

Imagine a giant, super‑organized bulletin board. Programs called **producers** pin up notes ("messages"). Other programs called **consumers** read those notes. The notes are grouped onto boards called **topics**, and each topic is split into **partitions** so many readers can work at once. Kafka keeps the notes in order and remembers them even if a reader is slow or offline. That is Apache Kafka: a durable, ordered, high‑speed message log.

### What is Strimzi?

Running Kafka by hand is fiddly. **Strimzi** is a piece of software (an "operator") that runs *inside Kubernetes* and runs Kafka *for you*. You hand Strimzi a short YAML file that says "I want a Kafka cluster that looks like this," and Strimzi creates the pods, storage, networking, certificates, users, and topics to match — and keeps fixing them if they drift. Think of Strimzi as a robot Kafka administrator that never sleeps.

> **Important 2026 facts about Strimzi 1.0.0:** It only talks to Kubernetes through the new **`v1` API** (older `v1beta2` is gone). It only runs Kafka in **KRaft mode** (the modern, ZooKeeper‑free design). And it organizes Kafka pods into **node pools** — small groups of nodes with a job, either "controller" (bookkeeping) or "broker" (holding messages). We will see all three in the YAML later.

### The two ways to run Strimzi on AWS

Strimzi is a Kubernetes operator, so it needs a place that speaks Kubernetes. On AWS you have two realistic homes:

- **Amazon EKS** (Elastic Kubernetes Service): real, managed Kubernetes. Strimzi runs here exactly as designed. **This is the recommended path** and most of the guide focuses on it.
- **Amazon ECS** (Elastic Container Service): AWS's *own* container runner. It is **not** Kubernetes. Strimzi cannot run on ECS, because Strimzi *is* a Kubernetes program. So on ECS we do something different: we run Kafka containers directly, without Strimzi. We will build that too, and I will be honest about the trade‑offs.

Here is the headline comparison. Details and gotchas come later, but read this now so the rest makes sense:

| Question | EKS (with Strimzi) | ECS (without Strimzi) |
|---|---|---|
| Does Strimzi work here? | Yes — this is its home. | No. Strimzi needs Kubernetes. |
| Who manages Kafka's lifecycle? | Strimzi (auto certs, users, topics, rolling updates, self‑healing). | You do, by hand or with extra scripts. |
| Learning curve | Higher (Kubernetes + Strimzi). | Lower to start, higher later when you re‑invent what Strimzi gave you. |
| Best for | Teams that want Kafka done *properly* and will keep using it. | Tiny demos, or shops that have banned Kubernetes. |
| Cost shape | EKS control plane fee + nodes. | No control‑plane fee; pay for tasks. |

**Recommendation:** if your goal is "a real Kafka cluster, the modern way," use **EKS + Strimzi**. Use ECS only if something stops you from using Kubernetes.

---

## 2. AWS concepts first — the pieces and how they fit

Before any Terraform, let's understand the AWS building blocks. I'll explain each one with a real‑world picture, say *why* we need it, show the **AWS CLI** command you'd use to look at or make it by hand, and name the **Console** screen where it lives. Later, Terraform will create all of these for us automatically — but you should know what it's making.

Think of the whole system as **building a secure office for Kafka**:

- The **VPC** is the office building.
- **Subnets** are floors — some public (a lobby facing the street), some private (locked back offices).
- The **Internet Gateway** is the front door to the street.
- **NAT Gateways** are a one‑way mail slot: people inside can send letters out, but strangers can't walk in.
- **Route tables** are the hallway signs telling traffic where to go.
- **Security groups** are door guards checking everyone in and out.
- **IAM roles and policies** are employee badges that say exactly which rooms each worker may enter.
- **KMS** is the locksmith that makes encryption keys.
- **EKS or ECS** is the team of workers who actually run Kafka.
- **EBS / EFS** is the filing cabinet where Kafka stores messages on disk.
- **Load balancers** are the receptionist who routes outside visitors to the right worker.

Let's go one at a time.

### 2.1 Region and Availability Zones (AZ)

**What it is.** AWS divides the world into **Regions** (like `us-east-1` in Virginia). Each Region contains several **Availability Zones** — separate data centers a few miles apart with independent power and network. If one AZ has a problem, the others keep running.

**Why we need it.** Kafka stays alive only if it is spread across **at least 3 AZs**. Kafka keeps copies ("replicas") of your data, and KRaft's bookkeeping (the "controller quorum") needs a majority to be healthy. With 3 AZs you can lose one whole data center and still have a majority (2 of 3). With only 2 AZs, losing one leaves you with half — not a majority — and Kafka can freeze.

**AWS CLI — list the AZs in your Region:**

```bash
# "aws ec2 describe-availability-zones" asks EC2 for the zones.
# --region picks which Region to ask about.
# --query is a JMESPath filter: from each item in AvailabilityZones, take ZoneName.
# --output table prints a neat grid instead of raw JSON.
aws ec2 describe-availability-zones \
  --region us-east-1 \
  --query "AvailabilityZones[].ZoneName" \
  --output table
```

**Console screen.** Top‑right Region picker; AZ details appear in **VPC → Subnets** when you choose where a subnet lives.

### 2.2 VPC — Virtual Private Cloud (the building)

**What it is.** A **VPC** is your own private slice of the AWS network: a walled‑off space with an IP address range you choose, such as `10.0.0.0/16`. Nothing from outside can reach inside unless you allow it.

> *What's a `/16`?* IP addresses look like `10.0.3.7`. The `/16` is a "how big is my address block" number. `/16` gives you ~65,000 addresses (lots of room). A bigger number = smaller block: a `/24` is only 256 addresses. We use `/16` for the whole VPC and carve `/24` "subnets" out of it.

**Why we need it.** It is the foundation everything else sits inside. Kafka brokers, the Kubernetes nodes, the load balancers — all live in the VPC. Keeping them in a private network is the first layer of security.

**AWS CLI — create a VPC by hand:**

```bash
# Create a VPC with the 10.0.0.0/16 address range.
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=kafka-vpc}]'
# --cidr-block sets the address range.
# --tag-specifications attaches a human-friendly Name tag so you can find it later.
# The response includes a VpcId like vpc-0abc123... — note it down; other commands need it.
```

**Console screen.** **VPC → Your VPCs → Create VPC.**

### 2.3 Subnets — public and private (the floors)

**What it is.** A **subnet** is a smaller address block inside the VPC, and each subnet lives in exactly one AZ. We make two kinds:

- **Public subnets**: things here *can* have a public internet address. We put load balancers and NAT Gateways here.
- **Private subnets**: things here have **no** public address. We put Kafka and the Kubernetes nodes here, hidden from the internet.

**Why we need it.** Separation. Visitors only ever reach the lobby (public subnet); the valuable stuff (Kafka) sits in locked back rooms (private subnets). Spreading subnets across 3 AZs is what gives Kafka its fault tolerance.

We will create **6 subnets**: 3 public (one per AZ) and 3 private (one per AZ).

**AWS CLI — create one private subnet:**

```bash
aws ec2 create-subnet \
  --vpc-id vpc-0abc123 \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=kafka-private-1a}]'
# --vpc-id ties this subnet to our VPC.
# --cidr-block 10.0.1.0/24 carves a 256-address slice for this subnet.
# --availability-zone pins it to one data center.
```

**Console screen.** **VPC → Subnets → Create subnet.**

### 2.4 Internet Gateway (the front door)

**What it is.** An **Internet Gateway** (IGW) is the component that connects your VPC to the public internet. Without it, your VPC is an island.

**Why we need it.** Public subnets need the IGW so the load balancer can be reached by your apps and so NAT Gateways can fetch updates. Private subnets do **not** attach to it directly — that's what keeps them private.

**AWS CLI:**

```bash
# Create the gateway object...
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=kafka-igw}]'
# ...then attach it to the VPC (it does nothing until attached).
aws ec2 attach-internet-gateway \
  --internet-gateway-id igw-0abc123 \
  --vpc-id vpc-0abc123
```

**Console screen.** **VPC → Internet Gateways.**

### 2.5 NAT Gateway (the one‑way mail slot)

**What it is.** A **NAT Gateway** lets machines in **private** subnets reach *out* to the internet (to download software, pull container images, call AWS APIs) **without** letting anyone reach *in*. It sits in a public subnet and has a public address; private machines send their outbound traffic through it.

**Why we need it.** Our Kubernetes nodes live in private subnets but still must download the Strimzi and Kafka container images and talk to AWS services. NAT lets them do that safely. (For production resilience you'd run one NAT per AZ so a single AZ outage doesn't cut off the others; in a cheap lab you can use one and accept the risk.)

> **Cost gotcha:** NAT Gateways cost money per hour *and* per gigabyte of data. They are one of the most common surprise charges on AWS bills. Three NAT Gateways running 24/7 add up. For a lab, one is fine; for production, weigh resilience vs cost.

**AWS CLI:**

```bash
# NAT needs a fixed public IP, called an Elastic IP. Allocate one first.
aws ec2 allocate-address --domain vpc
# Then create the NAT in a PUBLIC subnet, attaching that Elastic IP.
aws ec2 create-nat-gateway \
  --subnet-id subnet-PUBLIC123 \
  --allocation-id eipalloc-0abc123
# --subnet-id must be a public subnet (it needs internet access itself).
# --allocation-id is the Elastic IP id from the previous command.
```

**Console screen.** **VPC → NAT Gateways.**

### 2.6 Route tables (the hallway signs)

**What it is.** A **route table** is a list of rules that says "to reach address range X, send traffic to Y." Every subnet is associated with one route table.

**Why we need it.** Routes are what *make* a subnet public or private:

- A **public** subnet's route table says: "for the internet (`0.0.0.0/0`), go to the Internet Gateway."
- A **private** subnet's route table says: "for the internet (`0.0.0.0/0`), go to the NAT Gateway."

Same VPC, different signs on the wall — that single difference is the whole "public vs private" idea.

> *What's `0.0.0.0/0`?* It means "every address everywhere" — i.e., the default route for anything not inside the VPC. It's the catch‑all "to the outside world" sign.

**AWS CLI:**

```bash
# Make a route table in the VPC.
aws ec2 create-route-table --vpc-id vpc-0abc123
# Add the "to the internet, use the IGW" rule (this makes its subnets public).
aws ec2 create-route \
  --route-table-id rtb-0abc123 \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id igw-0abc123
# Attach the route table to a subnet.
aws ec2 associate-route-table \
  --route-table-id rtb-0abc123 \
  --subnet-id subnet-PUBLIC123
```

**Console screen.** **VPC → Route Tables.**

### 2.7 Security groups (the door guards)

**What it is.** A **security group** (SG) is a stateful firewall attached to a resource (like a node or a load balancer). It has **inbound** rules ("who may come in") and **outbound** rules ("where may traffic go out"). "Stateful" means if you allow a request in, the reply is automatically allowed back out — you don't write a second rule for replies.

**Why we need it.** Security groups are the tight, per‑resource locks. For Kafka we'll allow:

- Kafka clients → brokers on the Kafka port (**9092**, or **9093/9094** for TLS listeners depending on config).
- Brokers → brokers and brokers → controllers for internal traffic.
- Your admin machine → the Kubernetes API, on **443**.

Everything else is denied by default, which is exactly what we want.

> **Security‑group tip:** the safest rules reference *another security group* instead of an IP range. "Allow traffic from the `kafka-clients` SG" is tighter than "allow `10.0.0.0/16`," because membership is explicit. We'll use this pattern.

**AWS CLI:**

```bash
# Create the SG.
aws ec2 create-security-group \
  --group-name kafka-brokers \
  --description "Kafka broker traffic" \
  --vpc-id vpc-0abc123
# Allow inbound Kafka traffic on 9092 FROM another SG (clients), not from the whole world.
aws ec2 authorize-security-group-ingress \
  --group-id sg-BROKERS \
  --protocol tcp --port 9092 \
  --source-group sg-CLIENTS
# --protocol/--port define what traffic; --source-group says who may send it.
```

**Console screen.** **VPC → Security Groups**, or **EC2 → Security Groups.**

### 2.8 IAM — roles, policies, and why they're the heart of security

**What it is.** **IAM** (Identity and Access Management) decides *who can do what* in AWS. Three words to know:

- **Policy**: a JSON document listing allowed (or denied) actions, like "may read this S3 bucket." It's the *list of permissions*.
- **Role**: an identity that *machines* (not people) assume to get permissions. A role has policies attached. It's the *badge*.
- **Trust policy**: attached to a role, it says *who is allowed to wear the badge* (e.g., "the EKS service may assume this role").

**Why we need it (a lot).** Every AWS service that acts on your behalf does so through a role. We'll create several:

1. **EKS cluster role** — lets the EKS control plane manage AWS resources for the cluster.
2. **Node role** (for EC2 worker nodes) — lets nodes join the cluster, pull images from ECR, and run the networking plugin. Keep this **lean**; a fat node role is a classic over‑privilege mistake.
3. **Pod‑level roles via EKS Pod Identity** — give *specific pods* (not the whole node) the exact AWS permissions they need. As of 2026, **EKS Pod Identity is the recommended way** to give pods AWS permissions; the older "IRSA" approach still works and is still required in a few cases (like Fargate).
4. **(ECS path) Task execution role and task role** — one lets ECS pull images and write logs; the other gives the running container its AWS permissions.

> **The golden rule: least privilege.** Give each role the *smallest* set of permissions that lets it do its job, and nothing more. If a node only needs to pull images and join the cluster, don't also let it delete databases. This single habit prevents a huge share of cloud security incidents.

**AWS CLI — create a role with a trust policy, then attach a policy:**

```bash
# trust.json says "the EKS service is allowed to assume this role."
cat > trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
# Create the role using that trust document.
aws iam create-role \
  --role-name kafka-eks-cluster-role \
  --assume-role-policy-document file://trust.json
# Attach the AWS-managed policy that grants the EKS control-plane permissions.
aws iam attach-role-policy \
  --role-name kafka-eks-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

**Console screen.** **IAM → Roles** and **IAM → Policies.**

### 2.9 KMS — the encryption locksmith

**What it is.** **KMS** (Key Management Service) creates and guards encryption keys. You can ask it for a key and then tell other services "use this key to encrypt my data."

**Why we need it.** Two places:

- **EBS volumes** where Kafka stores messages on disk → encrypt them at rest.
- **Kubernetes Secrets** inside EKS → enable "envelope encryption" with a KMS key so secrets in the cluster's database (etcd) are encrypted with a key you control and can audit.

**AWS CLI:**

```bash
# Make a key and give it a friendly description.
aws kms create-key --description "Kafka data encryption key"
# Optionally make an alias (a nickname) so you don't have to memorize the key id.
aws kms create-alias \
  --alias-name alias/kafka-key \
  --target-key-id <key-id-from-previous-output>
```

**Console screen.** **KMS → Customer managed keys.**

### 2.10 Storage — EBS vs EFS (the filing cabinet)

**What it is.** Kafka must save messages to disk so they survive restarts.

- **EBS** (Elastic Block Store): a fast virtual hard drive attached to one node at a time. This is what Kafka wants — each broker gets its own dedicated, fast disk.
- **EFS** (Elastic File System): a shared network folder many nodes can mount at once. Convenient, but **not** ideal for Kafka's write‑heavy, latency‑sensitive workload.

**Why it matters.** **Use EBS for Kafka brokers.** In Kubernetes, this happens through a **StorageClass** (a template for "what kind of disk to create") and the **EBS CSI driver** (the plugin that actually creates and attaches the disks). Strimzi just asks for "persistent storage of size X," and these pieces fulfill it.

**AWS CLI (you rarely create broker EBS volumes by hand — Kubernetes does — but here's the primitive):**

```bash
aws ec2 create-volume \
  --availability-zone us-east-1a \
  --size 100 \
  --volume-type gp3 \
  --encrypted
# gp3 is the modern general-purpose SSD type: good speed, good price.
# --encrypted turns on at-rest encryption (uses a KMS key).
```

**Console screen.** **EC2 → Volumes**, and **EKS → Add‑ons** for the EBS CSI driver.

### 2.11 EKS vs ECS — what each one actually is

**EKS (Elastic Kubernetes Service).** AWS runs the Kubernetes "control plane" (the brain) for you, and you run "worker nodes" (the muscle) where your pods live. Nodes can be:

- **Managed node groups**: EC2 virtual machines AWS helps you manage. Most control. Good default for Kafka because Kafka likes stable nodes with fast local disks.
- **Fargate**: "serverless" pods with no nodes to manage — but Fargate has **no fast local EBS disk per pod the way Kafka wants**, so it's a poor fit for Kafka brokers (fine for stateless helpers).
- **EKS Auto Mode** (newer): AWS automatically manages nodes, scaling, and patching for you. Convenient; you give up some fine‑grained control. Reasonable for many workloads.

**ECS (Elastic Container Service).** AWS's own (non‑Kubernetes) way to run containers, described as **tasks** grouped into **services**. Launch types:

- **Fargate**: serverless tasks.
- **EC2**: tasks on your own EC2 instances.

**Why the difference matters for us.** Strimzi is a *Kubernetes* operator, so it can only live on **EKS**. On **ECS** there is no Strimzi; you'd run Kafka container images directly and manage everything yourself. That's the core reason this guide treats EKS as the main path.

**AWS CLI — the simplest possible cluster of each (Terraform will do the real thing later):**

```bash
# Bare EKS cluster (needs a role ARN and subnet IDs you created earlier):
aws eks create-cluster \
  --name kafka \
  --role-arn arn:aws:iam::123456789012:role/kafka-eks-cluster-role \
  --resources-vpc-config subnetIds=subnet-PRIV1,subnet-PRIV2,subnet-PRIV3 \
  --kubernetes-version 1.34

# Bare ECS cluster (much simpler object, because it does much less):
aws ecs create-cluster --cluster-name kafka
```

**Console screen.** **EKS → Clusters** or **ECS → Clusters.**

### 2.12 How the pieces fit — the whole picture

Read this paragraph slowly; it ties everything together.

We build a **VPC** and split it into **public and private subnets across 3 AZs**. An **Internet Gateway** connects the public subnets to the world; **NAT Gateways** let the private subnets reach out for software without being reachable themselves; **route tables** enforce that public/private split. Inside the private subnets we run **EKS worker nodes** (or **ECS tasks**). **Security groups** tightly control who may talk to the Kafka ports and the Kubernetes API. **IAM roles** give the cluster, the nodes, and individual pods exactly the AWS permissions they need — no more (least privilege), using **EKS Pod Identity** for pod‑level access. **KMS** encrypts the **EBS** disks where Kafka stores messages and the Kubernetes Secrets inside the cluster. On EKS, **Strimzi** watches for our Kafka YAML and builds the cluster; a **load balancer** lets our apps reach Kafka from outside. On ECS, we'd wire Kafka containers together ourselves. That's the entire office, staffed and locked.

Now we build it for real.
---

## 3. The EKS option — Terraform, line by line

Now we turn every AWS concept from Section 2 into **Terraform**, which is "infrastructure as code": instead of clicking the Console, we write text files describing what we want, and Terraform makes AWS match. The win is that it's repeatable, reviewable, and easy to tear down.

### 3.0 How Terraform thinks (30‑second primer)

- You write **`.tf`** files. Terraform reads *all* `.tf` files in a folder together, so we can split them by topic.
- **`resource`** blocks declare a thing you want ("an EKS cluster named X").
- **`variable`** blocks are inputs you can change without editing the body.
- **`output`** blocks print useful values after it runs.
- **`module`** blocks pull in reusable bundles of resources written by others.
- You run three commands: `terraform init` (download providers/modules), `terraform plan` (preview changes), `terraform apply` (make them real).

We'll lean on two excellent community modules so we don't hand‑write hundreds of lines: the **VPC module** and the **EKS module**. They are the de‑facto standard and save enormous effort. We will still read what they produce.

### 3.1 `versions.tf` — pin your tools

```hcl
# This block tells Terraform which version of Terraform itself, and which
# provider plugins (and versions), this project needs. Pinning versions keeps
# your teammates and your CI on the SAME tools, so "works on my machine" bugs vanish.
terraform {
  required_version = ">= 1.9"          # Need Terraform CLI 1.9 or newer.

  required_providers {
    aws = {
      source  = "hashicorp/aws"        # Where to download the AWS provider from.
      version = "~> 6.0"               # Allow any 6.x (>=6.0, <7.0). 6.x is current in 2026.
    }
    kubernetes = {
      source  = "hashicorp/kubernetes" # Lets Terraform create objects INSIDE the cluster.
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"       # Lets Terraform install Helm charts (we use it for Strimzi).
      version = "~> 2.15"
    }
  }
}
```

*Why this matters:* the AWS provider 6.x line added per‑resource `region` support and made some breaking changes vs 5.x. Pinning to `~> 6.0` means you opt into 6.x deliberately rather than being surprised.

### 3.2 `providers.tf` — point Terraform at AWS and at the cluster

```hcl
# The AWS provider needs to know which Region to operate in.
provider "aws" {
  region = var.region                  # Read the Region from a variable (set in variables.tf).
}

# After we build the cluster, we also want Terraform to talk to Kubernetes and Helm.
# These two providers are configured FROM the cluster's outputs, so they only work
# once the cluster exists. The values come from the EKS module further below.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint                         # The cluster's API URL.
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data) # Its CA cert.
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"                                                        # Use the AWS CLI...
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]      # ...to fetch a login token.
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
```

*Plain English:* the `exec` block is how Terraform logs into Kubernetes. It shells out to `aws eks get-token`, which mints a short‑lived token from your AWS credentials. No passwords stored anywhere.

### 3.3 `variables.tf` — the knobs you can turn

```hcl
# A variable is an input. Giving defaults makes the project run with zero extra config,
# while still letting you override per environment (dev/stage/prod).

variable "region" {
  description = "AWS Region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster."
  type        = string
  default     = "kafka"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. 1.34 is current in standard support as of mid-2026."
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "Address range for the whole VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Which Availability Zones to use. THREE for Kafka fault tolerance."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "node_instance_type" {
  description = "EC2 size for Kafka worker nodes. Kafka likes memory + steady CPU."
  type        = string
  default     = "m6i.xlarge"   # 4 vCPU, 16 GiB RAM — a sane starting point, not tiny.
}
```

### 3.4 `vpc.tf` — the network, via the VPC module

Instead of writing every subnet, route, gateway, and association by hand (easily 200+ lines), we use the standard VPC module. Read the comments to see it building exactly the Section‑2 picture.

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"  # The community-standard VPC module.
  version = "~> 5.13"                         # Pin it.

  name = "${var.cluster_name}-vpc"            # Names all resources, e.g. "kafka-vpc".
  cidr = var.vpc_cidr                         # 10.0.0.0/16 from variables.

  azs = var.azs                               # The 3 AZs.

  # Carve three PRIVATE /24s (one per AZ). Kafka + nodes live here, hidden.
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  # Carve three PUBLIC /24s (one per AZ). Load balancers + NAT live here.
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true   # Create NAT so private subnets can reach out.
  single_nat_gateway   = false  # FALSE = one NAT per AZ (resilient). TRUE saves money but is an AZ-failure risk.
  one_nat_gateway_per_az = true # Explicitly: one NAT in each AZ.

  enable_dns_hostnames = true   # Needed so resources get DNS names (EKS requires this).
  enable_dns_support   = true

  # These tags are MAGIC for EKS: they tell the AWS Load Balancer Controller which
  # subnets to use for public ("elb") vs internal ("internal-elb") load balancers.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
```

*Gotcha worth memorizing:* those subnet **tags** are how Kubernetes load balancers find the right subnets. Forget them and your `Service type=LoadBalancer` will mysteriously fail to place a load balancer. This trips up many first‑timers.

### 3.5 `kms.tf` — keys for encryption

```hcl
# A KMS key dedicated to encrypting Kubernetes Secrets stored in the cluster's etcd.
resource "aws_kms_key" "eks_secrets" {
  description             = "Envelope encryption for EKS secrets"
  deletion_window_in_days = 7      # If you delete the key, AWS waits 7 days (a safety net).
  enable_key_rotation     = true   # AWS auto-rotates the key material yearly. Good hygiene.
}

# A friendly alias so humans can find the key by name.
resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}
```

### 3.6 `eks.tf` — the cluster, nodes, IAM, and add‑ons, via the EKS module

This is the centerpiece. The EKS module wires up the cluster, the worker node group, the **IAM roles** for the cluster and nodes, the **access entries** (modern auth), and the **add‑ons** (networking, DNS, storage driver, Pod Identity agent). Comments explain each line.

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"  # The community-standard EKS module.
  version = "~> 20.31"                        # 20.x understands access entries & Pod Identity.

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version    # "1.34"

  # Put the cluster in our VPC, with worker nodes in the PRIVATE subnets.
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # --- API endpoint exposure ---
  # Allow reaching the Kubernetes API from the internet (so you can run kubectl from your laptop).
  # For a hardened setup you'd set this false and use a bastion/VPN; see the security section.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true   # Also reachable privately from inside the VPC.

  # --- Modern authentication ---
  # "API" mode uses EKS ACCESS ENTRIES (the 2026 recommended way), NOT the old aws-auth ConfigMap.
  authentication_mode = "API"
  # Automatically give the identity that runs Terraform full cluster admin via an access entry,
  # so you aren't locked out after creation. (A common pain with the old ConfigMap approach.)
  enable_cluster_creator_admin_permissions = true

  # --- Encrypt secrets with our KMS key ---
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks_secrets.arn
    resources        = ["secrets"]   # Encrypt Kubernetes Secret objects at rest.
  }

  # --- Control-plane logging ---
  # Send these log types to CloudWatch so you can audit and debug. "audit" is gold for security.
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # --- Cluster add-ons (managed plugins) ---
  cluster_addons = {
    coredns                = {}   # In-cluster DNS so pods can find each other by name.
    kube-proxy             = {}   # Keeps pod networking rules in sync on each node.
    vpc-cni                = {}   # AWS networking plugin: gives pods real VPC IPs.
    aws-ebs-csi-driver     = {}   # Lets Kubernetes create/attach EBS disks (Kafka storage!).
    eks-pod-identity-agent = {}   # Enables EKS Pod Identity (pod-level IAM, the 2026 default).
  }

  # --- Worker nodes: a managed node group ---
  eks_managed_node_groups = {
    kafka = {
      ami_type       = "AL2023_x86_64_STANDARD"  # Amazon Linux 2023 (AL2 is retired from 1.33+).
      instance_types = [var.node_instance_type]  # m6i.xlarge by default.

      min_size     = 3   # Never fewer than 3 (one per AZ) so Kafka can spread out.
      max_size     = 6   # Allow scaling up to 6 under load.
      desired_size = 3   # Start with 3.

      # Give each node a roomy, fast, ENCRYPTED root disk.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100      # GiB
            volume_type           = "gp3"    # Modern SSD.
            encrypted             = true     # At-rest encryption.
            delete_on_termination = true     # Clean up the disk when the node dies.
          }
        }
      }

      # Spread nodes across AZs/subnets (the module already uses the private subnets).
      labels = { workload = "kafka" }  # A Kubernetes label so we can target these nodes.
    }
  }

  tags = {
    Project = "kafka-on-eks"
    Env     = "dev"
  }
}
```

*What just happened, in words:* this one module block created the EKS control plane (K8s 1.34), the **cluster IAM role** and **node IAM role** (with least‑privilege managed policies the module attaches automatically), three encrypted worker nodes spread across three AZs in private subnets, the five add‑ons (including the EBS driver Kafka needs and the Pod Identity agent), KMS secret encryption, audit logging, and an **access entry** making you cluster‑admin so you're not locked out. That's a lot of correct, secure defaults for ~60 lines.

### 3.7 `irsa_ebs.tf` *(optional but tidy)* — let the EBS driver create disks

The EBS CSI driver add‑on needs AWS permission to create and attach volumes. The cleanest 2026 approach is **EKS Pod Identity**; many people still use **IRSA** (IAM Roles for Service Accounts). The EKS module can wire IRSA for you:

```hcl
# Create an IAM role the EBS CSI driver's ServiceAccount can assume, scoped to JUST EBS actions.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true   # Attaches the AWS-managed EBS CSI policy (least privilege for disks).

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn         # Trust THIS cluster's identity.
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"] # Only this exact ServiceAccount.
    }
  }
}
```

*Why scope it so narrowly?* Because if that role were broad, any pod that could use that ServiceAccount would inherit broad AWS power. Tying it to one namespace + one ServiceAccount + one policy is least privilege in action.

### 3.8 `storageclass.tf` — tell Kafka what kind of disk to ask for

```hcl
# A StorageClass is a template: "when someone asks for storage of this class, make a gp3 EBS volume."
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"                       # Kafka's YAML will reference this name.
  }
  storage_provisioner = "ebs.csi.aws.com"   # Use the EBS CSI driver to fulfill requests.
  parameters = {
    type      = "gp3"                  # Modern SSD.
    encrypted = "true"                 # Encrypt the volume (at rest).
  }
  volume_binding_mode    = "WaitForFirstConsumer"  # Create the disk in the SAME AZ as the pod that needs it.
  allow_volume_expansion = true                    # Let us grow disks later without recreating them.
  reclaim_policy         = "Retain"                # Keep data if the claim is deleted (safer for Kafka).

  depends_on = [module.eks]            # Don't create until the cluster (and EBS driver) exist.
}
```

*Critical line:* `WaitForFirstConsumer`. EBS volumes are AZ‑locked — a disk in `us-east-1a` can't attach to a node in `1b`. This setting delays disk creation until Kubernetes knows which AZ the broker landed in, then makes the disk there. Skip it and you'll get pods stuck "pending" because their disk is in the wrong zone. Another classic gotcha.

### 3.9 `outputs.tf` — print what you need next

```hcl
output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Pass this to: aws eks update-kubeconfig --name <this>"
}

output "configure_kubectl" {
  # A ready-to-paste command that points your local kubectl at the new cluster.
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
```

### 3.10 Run it

```bash
terraform init      # Downloads the AWS/kubernetes/helm providers and the VPC/EKS modules.
terraform plan      # Shows EVERYTHING it will create. Read it. Nothing is built yet.
terraform apply     # Type "yes" to build. EKS takes ~10-15 minutes to come up.

# When it finishes, point kubectl at the cluster using the printed command, e.g.:
aws eks update-kubeconfig --name kafka --region us-east-1
# update-kubeconfig writes connection details into ~/.kube/config so kubectl knows the cluster.

kubectl get nodes   # You should see 3 Ready nodes across 3 AZs. 🎉
```

If `kubectl get nodes` shows three `Ready` nodes, your secure, multi‑AZ Kubernetes home for Kafka is live. Next we install Strimzi and ask it for a Kafka cluster.
---

## 4. Installing Strimzi and creating Kafka — line by line

The cluster is empty. Now we install the **Strimzi operator** (the robot Kafka admin) and then hand it YAML describing the Kafka cluster we want.

### 4.1 Install the Strimzi operator with Helm (via Terraform)

**Helm** is a package manager for Kubernetes — like an app store. The Strimzi team publishes an official Helm chart. We install it with the Helm provider so it's part of our code.

```hcl
# helm.tf

# Create a dedicated namespace ("folder") for Kafka so it's isolated from other apps.
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
  }
  depends_on = [module.eks]
}

# Install the Strimzi Cluster Operator from its official Helm chart.
resource "helm_release" "strimzi" {
  name       = "strimzi"                                  # A name for this install.
  repository = "oci://quay.io/strimzi-helm"               # Strimzi publishes via an OCI registry.
  chart      = "strimzi-kafka-operator"                   # The chart name.
  version    = "1.0.0"                                    # Strimzi 1.0.0 (April 2026). Pin it!
  namespace  = kubernetes_namespace.kafka.metadata[0].name # Install into the "kafka" namespace.

  # Tell the operator to ONLY watch the "kafka" namespace (least privilege; avoids cluster-wide power).
  set {
    name  = "watchNamespaces[0]"
    value = "kafka"
  }

  depends_on = [module.eks]
}
```

*What the operator is now doing:* it installed a set of **Custom Resource Definitions (CRDs)** — these teach Kubernetes new object *types* like `Kafka`, `KafkaNodePool`, `KafkaTopic`, and `KafkaUser`. From now on we can create those objects and Strimzi will act on them.

> **Strimzi 1.0.0 gotcha:** only the **`v1`** API exists now (`v1beta2` was removed). Every Strimzi YAML below uses `apiVersion: kafka.strimzi.io/v1`. If you copy an old example using `v1beta2`, it will be rejected. Also, because Strimzi is KRaft‑only now, there is **no ZooKeeper** anywhere — don't look for it.

### 4.2 Understand the four objects we'll create

1. **`KafkaNodePool`** (controllers) — a small group of nodes that do KRaft "bookkeeping" (cluster metadata, leader elections). We'll run **3** for a healthy quorum.
2. **`KafkaNodePool`** (brokers) — the nodes that actually hold your messages. We'll run **3**, one per AZ.
3. **`Kafka`** — the top‑level cluster: which Kafka version, which listeners (doors clients connect to), security, and storage.
4. **`KafkaTopic`** and **`KafkaUser`** — a demo topic and a secured user, both managed as Kubernetes objects.

We create these as plain Kubernetes YAML and apply them. (You *can* embed them in Terraform via `kubernetes_manifest`, but applying YAML with `kubectl` is clearer for learning and avoids a Terraform‑plan‑time chicken‑and‑egg problem where the CRDs don't exist yet.)

### 4.3 `controllers.yaml` — the KRaft controller node pool

```yaml
apiVersion: kafka.strimzi.io/v1          # Strimzi 1.0.0 uses the v1 API.
kind: KafkaNodePool                       # This object type = a pool of Kafka nodes.
metadata:
  name: controllers                       # Name of this pool.
  namespace: kafka                        # Lives in the kafka namespace.
  labels:
    strimzi.io/cluster: my-kafka          # MUST match the Kafka cluster name below. This is the glue.
spec:
  replicas: 3                             # 3 controllers => quorum can tolerate losing 1.
  roles:
    - controller                          # This pool ONLY does controller (KRaft bookkeeping) work.
  storage:
    type: jbod                            # "Just a Bunch Of Disks" — a list of volumes.
    volumes:
      - id: 0
        type: persistent-claim            # Ask Kubernetes for a real (EBS) disk.
        size: 20Gi                        # Controllers need little space (just metadata).
        class: gp3                        # Use the gp3 StorageClass we created in Terraform.
        deleteClaim: false                # Keep the disk if the pod is deleted (safety).
  # Spread the 3 controllers across the 3 AZs so one AZ failure can't kill the quorum.
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1                       # Allow at most 1 more pod in any zone than another.
          topologyKey: topology.kubernetes.io/zone  # Spread by AZ.
          whenUnsatisfiable: DoNotSchedule # Refuse to bunch them up.
          labelSelector:
            matchLabels:
              strimzi.io/pool-name: controllers
```

### 4.4 `brokers.yaml` — the broker node pool

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: brokers
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka          # Same cluster name => part of the same Kafka.
spec:
  replicas: 3                             # 3 brokers, one per AZ.
  roles:
    - broker                              # This pool ONLY holds data / serves clients.
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 100Gi                       # Brokers hold the actual messages — give them room.
        class: gp3
        deleteClaim: false
  resources:                              # Reserve CPU/memory so brokers aren't starved.
    requests:
      cpu: "1"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 8Gi
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              strimzi.io/pool-name: brokers
```

*Why split controllers and brokers into separate pools?* Because they have different needs: controllers want a small disk and rock‑steady availability; brokers want big, fast disks and more CPU/RAM. Separate pools let you size and scale them independently — and Strimzi 1.0.0 organizes KRaft this way by design.

### 4.5 `kafka.yaml` — the cluster itself

This is the brain of the request. Read every line.

```yaml
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: my-kafka                          # The cluster name the pools referenced above.
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled        # We ARE using node pools (required in 1.0.0).
    strimzi.io/kraft: enabled             # KRaft mode (no ZooKeeper). The only mode in 1.0.0.
spec:
  kafka:
    version: 4.0.0                         # The Apache Kafka version Strimzi 1.0.0 ships. Pin it.
    metadataVersion: 4.0-IV3               # KRaft metadata format version matching that Kafka.

    # LISTENERS = the doors clients use to connect. We define three.
    listeners:
      # 1) Internal plaintext door for apps INSIDE the cluster. Simple and fast.
      - name: plain
        port: 9092
        type: internal                     # Only reachable inside Kubernetes.
        tls: false

      # 2) Internal TLS door (encrypted) for in-cluster apps that want security.
      - name: tls
        port: 9093
        type: internal
        tls: true                          # Encrypt traffic; Strimzi auto-issues the certs.

      # 3) External door so apps OUTSIDE the cluster (e.g., on EC2 or your laptop via VPN) can connect.
      #    We use a cloud LoadBalancer. (NOTE: the old "ingress" listener type is DEPRECATED as of
      #    Strimzi 0.51/1.0.0 because the NGINX Ingress controller was archived in March 2026.)
      - name: external
        port: 9094
        type: loadbalancer                 # Creates an AWS Network Load Balancer per broker + bootstrap.
        tls: true                          # Encrypt external traffic.
        authentication:
          type: scram-sha-512              # Require username/password (SCRAM) to connect from outside.
        configuration:
          # Make the load balancers INTERNAL (inside the VPC) instead of internet-facing.
          # Safer default; flip to internet-facing only if you truly need public access.
          bootstrap:
            annotations:
              service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
          brokers:
            - broker: 0
              annotations:
                service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"

    # Cluster-wide Kafka settings. With 3 brokers we set replication so data survives a broker loss.
    config:
      offsets.topic.replication.factor: 3              # Internal offsets topic kept on all 3 brokers.
      transaction.state.log.replication.factor: 3      # Same for the transactions log.
      transaction.state.log.min.isr: 2                 # Need 2 in-sync copies to accept writes (safety).
      default.replication.factor: 3                    # New topics default to 3 copies.
      min.insync.replicas: 2                           # A write must reach 2 copies before it's "done".

  # The Entity Operator manages KafkaTopic and KafkaUser objects (so we can declare them as YAML).
  entityOperator:
    topicOperator: {}                      # Watches KafkaTopic objects.
    userOperator: {}                       # Watches KafkaUser objects (creates SCRAM users, etc.).
```

*The most important safety lines* are `min.insync.replicas: 2` with `default.replication.factor: 3`. Together they mean: keep 3 copies of data, and don't acknowledge a write until at least 2 copies have it. So a single broker (or whole AZ) can fail without data loss and without blocking writes. This is the standard "RF=3, minISR=2" production pattern.

> **Listener gotcha (read this):** Strimzi creates **one load balancer for the bootstrap address plus one per broker** when you use `type: loadbalancer`. With 3 brokers that's **4 NLBs**, each costing money. That's the price of external access. Alternatives: use `type: nodeport` (cheaper, more fiddly), or keep Kafka internal‑only and connect from inside the VPC. Don't be surprised by four load balancers appearing.

### 4.6 `topic.yaml` and `user.yaml` — a demo topic and a secured user

```yaml
# topic.yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: demo-events                       # The topic name apps will produce/consume.
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka          # Which Kafka cluster this topic belongs to.
spec:
  partitions: 6                           # Split into 6 parts for parallelism.
  replicas: 3                             # 3 copies (matches our RF=3 safety pattern).
  config:
    retention.ms: 604800000               # Keep messages 7 days (in milliseconds), then delete.
```

```yaml
# user.yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: app-user                          # The username external clients will use.
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  authentication:
    type: scram-sha-512                   # Password-based auth (matches the external listener).
  authorization:
    type: simple                          # Turn on Kafka ACLs (fine-grained permissions).
    acls:
      # Let this user READ and WRITE only the demo-events topic — nothing else. Least privilege again.
      - resource:
          type: topic
          name: demo-events
          patternType: literal
        operations: [Read, Write, Describe]
      # Allow it to join consumer groups (needed to consume).
      - resource:
          type: group
          name: "*"
          patternType: literal
        operations: [Read]
```

*What Strimzi does with these:* the User Operator creates the SCRAM credentials and stores the password in a **Kubernetes Secret** named after the user (`app-user`). The Topic Operator creates `demo-events` with your settings. You never run a Kafka admin command by hand.

### 4.7 Apply everything and watch it come up

```bash
# Apply the node pools FIRST (the Kafka object references them).
kubectl apply -f controllers.yaml
kubectl apply -f brokers.yaml
# Then the cluster itself.
kubectl apply -f kafka.yaml
# Then the topic and user.
kubectl apply -f topic.yaml
kubectl apply -f user.yaml

# Watch the operator build everything. This can take a few minutes the first time.
kubectl get pods -n kafka -w
# -n kafka = look in the kafka namespace. -w = "watch" (live updates). Ctrl-C to stop watching.

# Ask Strimzi for the cluster's readiness in one shot:
kubectl wait kafka/my-kafka --for=condition=Ready --timeout=600s -n kafka
# "kubectl wait" blocks until the Kafka object reports Ready (or the timeout hits).
```

When `kubectl get pods -n kafka` shows the controller and broker pods `Running` and the Entity Operator up, your Kafka cluster is **live, replicated across three AZs, encrypted, and secured with a SCRAM user**. The next section connects to it and tests sending/receiving messages.
---

## 5. The ECS option — Kafka without Strimzi

You asked to see ECS too. Here's the honest framing, then a working approach, then the gotchas.

### 5.1 The blunt truth up front

**Strimzi does not run on ECS.** Strimzi is a Kubernetes operator; ECS is not Kubernetes. So "Kafka on ECS with Strimzi" is impossible — the two don't combine. On ECS you run Kafka **container images directly** and do yourself all the things Strimzi did automatically: identity, certificates, topic/user management, rolling upgrades, rebalancing, and self‑healing.

So this section is really "**Kafka on ECS, the manual way**." It's a legitimate choice if your organization has standardized on ECS or banned Kubernetes — but go in clear‑eyed.

### 5.2 ECS vocabulary (mapped to what you already know)

| ECS term | What it means | EKS/Strimzi equivalent |
|---|---|---|
| **Task definition** | A blueprint for a container (image, CPU, memory, env, ports, volumes). | Roughly a Pod spec. |
| **Task** | A running instance of a task definition. | A Pod. |
| **Service** | Keeps N copies of a task running and replaces failures. | A Deployment/StatefulSet. |
| **Launch type** | `FARGATE` (serverless) or `EC2` (your instances). | Node type. |
| **Task execution role** | Lets ECS *pull the image and write logs*. | (No direct equiv.) |
| **Task role** | Gives the *running container* its AWS permissions. | Pod Identity / IRSA. |

### 5.3 Storage: the make‑or‑break gotcha for Kafka on ECS

Kafka needs each broker to have its **own durable, fast disk that survives restarts and stays with that broker's identity**. On ECS this is the hard part:

- **Fargate** can attach **EBS** to a task (since 2024), but Fargate tasks are ephemeral and don't have the stable, per‑broker identity model that a Kubernetes StatefulSet gives you. Re‑attaching the *same* volume to the *same* logical broker across restarts takes careful design.
- **EFS** (shared network filesystem) attaches easily to Fargate, but EFS is **not recommended for Kafka** — its latency and semantics don't suit Kafka's write pattern, and you can corrupt data if two brokers ever touch the same files.
- **EC2 launch type** with EBS volumes is the most Kafka‑friendly, but now you're managing EC2 instances *and* doing manual orchestration — at which point EKS would have been easier.

**Bottom line:** stateful Kafka on ECS is swimming upstream. If you must, prefer **EC2 launch type with dedicated EBS volumes per broker**, and accept significant manual work.

### 5.4 A minimal ECS Terraform (EC2 launch type)

This builds the ECS scaffolding. It deliberately stops short of a full production Kafka because doing that *correctly* on ECS is a large project; the comments mark where the hard manual work lives.

```hcl
# ecs.tf  (reuses the SAME module.vpc from the EKS section — networking is identical)

# 1) The ECS cluster: a logical grouping for tasks/services.
resource "aws_ecs_cluster" "kafka" {
  name = "${var.cluster_name}-ecs"
  setting {
    name  = "containerInsights"   # Turn on CloudWatch Container Insights for metrics.
    value = "enabled"
  }
}

# 2) Task EXECUTION role: lets ECS pull images from ECR and ship logs to CloudWatch.
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]   # Only ECS tasks may wear this role.
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.cluster_name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Attach the AWS-managed execution policy (pull image + write logs). Least privilege for the platform.
resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# 3) Task ROLE: permissions for the Kafka container itself (e.g., if it reads from S3/KMS). Keep minimal.
resource "aws_iam_role" "kafka_task" {
  name               = "${var.cluster_name}-kafka-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # Attach only what your Kafka actually needs; by default, nothing extra = most secure.
}

# 4) A security group for the Kafka tasks: allow the Kafka port only from approved sources.
resource "aws_security_group" "kafka_tasks" {
  name        = "${var.cluster_name}-kafka-tasks"
  description = "Kafka broker traffic on ECS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Kafka clients"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]   # Only from inside the VPC. Tighten further with SG references in prod.
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"             # Allow all outbound (to pull images via NAT, etc.).
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5) A CloudWatch log group for the broker logs.
resource "aws_cloudwatch_log_group" "kafka" {
  name              = "/ecs/${var.cluster_name}-kafka"
  retention_in_days = 14
}

# 6) The task definition: the broker blueprint.
resource "aws_ecs_task_definition" "kafka" {
  family                   = "${var.cluster_name}-kafka"
  requires_compatibilities = ["EC2"]      # EC2 launch type (best for Kafka storage).
  network_mode             = "awsvpc"      # Each task gets its own VPC network interface/IP.
  cpu                      = "2048"        # 2 vCPU (in ECS units).
  memory                   = "8192"        # 8 GiB.
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.kafka_task.arn

  # The container definitions are JSON. This runs a Kafka image in KRaft mode.
  container_definitions = jsonencode([{
    name      = "kafka"
    image     = "apache/kafka:4.0.0"       # Official Apache Kafka image, KRaft-capable.
    essential = true
    portMappings = [{ containerPort = 9092, protocol = "tcp" }]
    # KRaft single-node-ish env. For a REAL cluster you must give each broker a unique
    # node id, a shared cluster id, and the full controller-quorum voter list — and wire
    # stable per-broker storage. THIS is the manual work Strimzi would have done for you.
    environment = [
      { name = "KAFKA_NODE_ID",                  value = "1" },
      { name = "KAFKA_PROCESS_ROLES",            value = "broker,controller" },
      { name = "KAFKA_CONTROLLER_QUORUM_VOTERS", value = "1@localhost:9093" },  # <-- must list ALL voters in a real cluster
      { name = "KAFKA_LISTENERS",                value = "PLAINTEXT://:9092,CONTROLLER://:9093" },
      { name = "KAFKA_CONTROLLER_LISTENER_NAMES", value = "CONTROLLER" },
      { name = "KAFKA_INTER_BROKER_LISTENER_NAME", value = "PLAINTEXT" },
      { name = "CLUSTER_ID",                     value = "MkU3OEVBNTcwNTJENDM2Qk" }  # shared across brokers
    ]
    mountPoints = [{ sourceVolume = "kafka-data", containerPath = "/var/lib/kafka/data" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.kafka.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "kafka"
      }
    }
  }])

  # Volume placeholder. Mapping a UNIQUE, durable EBS volume to EACH broker that survives
  # restarts and keeps broker identity is the hard, manual part on ECS.
  volume {
    name = "kafka-data"
  }
}

# 7) The service: keep the broker task running and restart it if it dies.
resource "aws_ecs_service" "kafka" {
  name            = "${var.cluster_name}-kafka"
  cluster         = aws_ecs_cluster.kafka.id
  task_definition = aws_ecs_task_definition.kafka.arn
  desired_count   = 1                       # A real cluster runs 3+, each needing its own identity/disk.
  launch_type     = "EC2"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.kafka_tasks.id]
  }
}
```

*Read the comments marked "manual work."* They are exactly the responsibilities Strimzi shoulders for you on EKS: unique broker IDs, the full controller‑quorum voter list, a shared cluster ID, and stable per‑broker storage. Doing those by hand for a 3‑broker cluster is real engineering.

### 5.5 ECS pros, cons, and gotchas — the honest list

**Pros**
- **No Kubernetes to learn or run.** If your team already lives in ECS, the mental model is smaller.
- **No EKS control‑plane fee.** You pay for tasks/instances, not a managed control plane.
- **Tight AWS integration** (IAM task roles, CloudWatch, ALB/NLB) feels native.
- **Great for *stateless* sidecars** around Kafka (e.g., a REST proxy, exporters).

**Cons**
- **No Strimzi.** You lose automated certs, users, topics, rolling upgrades, rebalancing, and self‑healing — all of it becomes your job.
- **Stateful Kafka is awkward.** Stable per‑broker disks + identity are hard on ECS; easy on Kubernetes StatefulSets/Strimzi.
- **More custom glue.** Quorum voter lists, broker IDs, advertised listeners, scaling — all manual or scripted.
- **Smaller ecosystem** for running Kafka specifically; most Kafka‑on‑cloud tooling targets Kubernetes.

**Gotchas (the ones that bite people)**
1. **EFS for Kafka data = pain or corruption.** Don't. Use EBS (EC2 launch type).
2. **Fargate ephemerality.** Fargate + EBS exists but keeping the *same* volume bonded to the *same* broker across restarts needs careful design.
3. **Advertised listeners.** Clients connect using whatever address the broker *advertises*. Behind a load balancer this must be set correctly or clients will connect to bootstrap then fail to reach individual brokers. (Strimzi handles this for you on EKS.)
4. **Scaling isn't "just raise desired_count."** Each new broker needs a unique ID and must be added to the quorum/replication picture — not automatic.
5. **Upgrades are manual.** Rolling a Kafka version across brokers safely (one at a time, waiting for in‑sync replicas) is exactly the orchestration Strimzi automates and you'd reimplement.

**When ECS is genuinely the right call:** you've been told "no Kubernetes," your Kafka needs are modest, and you have the engineering time to own the stateful bits. Otherwise, **EKS + Strimzi** will be less work *and* more robust.
---

## 6. Connect, test, secure, extend, and clean up

### 6.1 Send and receive a test message (EKS + Strimzi)

The easiest first test runs *inside* the cluster, so we don't fight networking yet. Strimzi ships Kafka's command‑line tools in its image.

```bash
# Start a throwaway pod that has the Kafka CLI tools, attached to our cluster's network.
kubectl -n kafka run kafka-cli --rm -it \
  --image=quay.io/strimzi/kafka:1.0.0-kafka-4.0.0 \
  --restart=Never -- bash
# -n kafka: the namespace.  --rm: delete the pod when we exit.  -it: interactive terminal.
# --image: the Strimzi Kafka image (tools included).  --restart=Never: it's a one-off.

# --- Now you're INSIDE that pod. Send a message to the internal plaintext listener: ---
echo "hello kafka" | bin/kafka-console-producer.sh \
  --bootstrap-server my-kafka-kafka-bootstrap:9092 \
  --topic demo-events
# bootstrap-server: Strimzi creates a Service named "<cluster>-kafka-bootstrap" on port 9092.
# kafka-console-producer.sh reads stdin and sends each line as a message.

# --- Read it back from the beginning: ---
bin/kafka-console-consumer.sh \
  --bootstrap-server my-kafka-kafka-bootstrap:9092 \
  --topic demo-events --from-beginning --timeout-ms 10000
# --from-beginning: read all existing messages.  --timeout-ms: stop after 10s of silence.
# You should see "hello kafka". 🎉  Type exit to leave (the pod self-deletes).
```

### 6.2 Connect from outside (the secured external listener)

External clients use the **SCRAM** user we created. Strimzi stored its password in a Kubernetes Secret. Grab it, then connect to the external bootstrap.

```bash
# Pull the generated password out of the Secret named after the user.
kubectl get secret app-user -n kafka \
  -o jsonpath='{.data.password}' | base64 -d; echo
# -o jsonpath digs out just the password field; base64 -d decodes it (Secrets are base64-encoded).

# Find the EXTERNAL bootstrap address (the load balancer Strimzi created).
kubectl get service my-kafka-kafka-external-bootstrap -n kafka \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

A client then connects with: the external bootstrap host on port **9094**, **TLS enabled**, **SASL mechanism SCRAM‑SHA‑512**, username `app-user`, and that password. (Because we made the load balancer **internal**, you connect from inside the VPC — e.g., an EC2 box or over a VPN. That's the safer default; only switch to internet‑facing if you truly need it and you've locked down the security group.)

### 6.3 Security hardening checklist (do these before "production")

You already have strong defaults (private subnets, KMS‑encrypted EBS and Secrets, audit logging, SCRAM auth + ACLs, least‑privilege node and pod roles, access‑entry auth). Add these:

1. **Make the API endpoint private.** Set `cluster_endpoint_public_access = false` and reach the API via a bastion host or VPN. A public API endpoint with weak RBAC is one of the most exploited EKS weaknesses.
2. **Turn on Kubernetes NetworkPolicies.** The AWS VPC CNI enforces them natively. Default‑deny pod‑to‑pod traffic, then allow only what Kafka clients need. (Use Cilium/Calico if you want L7 rules.)
3. **Use EKS Pod Identity for every pod that needs AWS access** — never give the *node* broad permissions to cover for a pod. Node roles should stay minimal (join + pull images + CNI).
4. **Mutual TLS between clients and Kafka** for the strongest auth, instead of (or on top of) SCRAM. Strimzi can issue client certs via `KafkaUser` with `authentication.type: tls`.
5. **Namespaced RBAC, least privilege.** Developers get access only to their namespace. Reserve `cluster-admin` for break‑glass.
6. **KMS everywhere + key rotation on** (we enabled rotation on the secrets key; do the same for any data keys).
7. **Review access entries and IAM quarterly.** Stale access is a real risk; access accumulates.
8. **Plan version upgrades early.** EKS standard support is ~14 months per Kubernetes version; upgrade at least two months before it lapses so you're never rushed. Watch Strimzi's support matrix too (Strimzi 1.0.0 needs Kubernetes 1.30+).
9. **Pin every version** (Terraform, providers, EKS, Strimzi, Kafka, images). "latest" is how surprise breakage and surprise CVEs sneak in. (Note: Strimzi 0.50.1/0.51.0 fixed CVE‑2026‑27133 and ‑27134 — staying current matters.)

### 6.4 Making it extensible (grow without rewriting)

The whole point of Terraform + Strimzi is that growth is mostly editing numbers and adding small YAML files.

- **More brokers/throughput:** bump `replicas` in `brokers.yaml`. Strimzi adds brokers and (with Cruise Control, below) can rebalance data onto them. Raise the node group `max_size` so there's room.
- **Auto‑rebalancing:** add a **Cruise Control** section to the `Kafka` resource (`spec.cruiseControl: {}`) and Strimzi runs it, enabling `KafkaRebalance` objects that move partitions to balance load automatically — something you'd hand‑build on ECS.
- **More topics/users:** just add more `KafkaTopic` / `KafkaUser` YAML files and `kubectl apply`. They're version‑controlled like everything else.
- **Connectors (integrations):** deploy a `KafkaConnect` resource for moving data in/out (databases, S3, etc.), and `KafkaConnector` objects for each pipeline.
- **HTTP access:** deploy the **Strimzi HTTP Bridge** (a `KafkaBridge` resource) so apps that can't speak the Kafka protocol can produce/consume over plain HTTP/REST.
- **Multi‑environment:** use Terraform **workspaces** or separate state files per env (dev/stage/prod) with different `variables`. Same code, different knobs.
- **Multi‑region / DR:** run a second cluster in another Region and use **MirrorMaker 2** (a `KafkaMirrorMaker2` resource) to replicate topics across Regions.
- **GitOps:** commit the Strimzi YAML to Git and let Argo CD or Flux apply it, so the cluster's desired state is always what's in your repo.

### 6.5 Tear it all down (stop paying)

```bash
# First delete the Kafka workloads so Strimzi removes the load balancers (4 NLBs!) it created.
# Forgetting this leaves orphaned load balancers and EBS volumes still costing money.
kubectl delete -f user.yaml -f topic.yaml -f kafka.yaml -f brokers.yaml -f controllers.yaml -n kafka

# Give the cloud a minute to delete the load balancers, then destroy the infrastructure.
terraform destroy   # Type "yes". Removes the cluster, nodes, NATs, VPC — everything Terraform made.
```

> **Cleanup gotcha:** Strimzi‑created load balancers and EBS volumes are made *by Kubernetes*, not directly by Terraform, so `terraform destroy` may not remove them if the Kafka objects still exist. Delete the Kafka YAML **first**, wait, then destroy. Otherwise you'll find leftover NLBs and disks on next month's bill.

---

## 7. Cheat sheets

### 7.1 The two paths at a glance

| Topic | EKS + Strimzi (recommended) | ECS (manual) |
|---|---|---|
| Kubernetes? | Yes (managed control plane) | No |
| Strimzi works? | Yes | No |
| Kafka lifecycle | Automated by Strimzi | Manual / scripted |
| Stateful storage | Easy (StatefulSet + EBS CSI) | Hard (esp. on Fargate) |
| Certs / users / topics | Declarative YAML, auto | Hand‑rolled |
| Rolling upgrades | Strimzi does it safely | You orchestrate it |
| Cost shape | Control‑plane fee + nodes + LBs | Tasks/instances + LBs |
| Best for | Real, lasting Kafka | No‑Kubernetes shops, small needs |

### 7.2 Key AWS CLI commands used

```bash
aws ec2 describe-availability-zones --region us-east-1   # List AZs.
aws ec2 create-vpc --cidr-block 10.0.0.0/16             # Make a VPC.
aws ec2 create-subnet ...                               # Make a subnet.
aws ec2 create-internet-gateway / attach-internet-gateway
aws ec2 allocate-address --domain vpc                   # Elastic IP for NAT.
aws ec2 create-nat-gateway ...                          # NAT for private egress.
aws ec2 create-route-table / create-route / associate-route-table
aws ec2 create-security-group / authorize-security-group-ingress
aws iam create-role / attach-role-policy                # Roles + permissions.
aws kms create-key / create-alias                       # Encryption keys.
aws eks create-cluster ... --kubernetes-version 1.34    # Bare cluster (Terraform does the real one).
aws eks update-kubeconfig --name kafka --region us-east-1  # Point kubectl at the cluster.
aws ecs create-cluster --cluster-name kafka             # Bare ECS cluster.
```

### 7.3 Key kubectl/Strimzi commands

```bash
kubectl get nodes                                  # Worker nodes (expect 3, Ready).
kubectl get pods -n kafka -w                        # Watch Kafka pods come up.
kubectl wait kafka/my-kafka --for=condition=Ready -n kafka --timeout=600s
kubectl get kafkatopic,kafkauser -n kafka           # See declared topics/users.
kubectl get secret app-user -n kafka -o jsonpath='{.data.password}' | base64 -d
kubectl logs -n kafka <pod>                         # Broker/operator logs for debugging.
```

### 7.4 Terraform commands

```bash
terraform init      # Download providers + modules. Run once (and after version bumps with -upgrade).
terraform fmt       # Auto-format your .tf files neatly.
terraform validate  # Check for syntax/type errors without touching AWS.
terraform plan      # Preview changes. Nothing is built.
terraform apply     # Build/modify infrastructure (asks for "yes").
terraform destroy   # Tear everything down (asks for "yes").
```

---

## 8. Glossary (plain English)

- **Region / Availability Zone (AZ):** A geographic AWS area, divided into separate data centers. Use **3 AZs** so Kafka survives one failing.
- **VPC:** Your private network in AWS — the building everything sits in.
- **Subnet:** A floor of the building, in one AZ. **Public** = can face the internet; **private** = hidden.
- **Internet Gateway:** The front door connecting public subnets to the internet.
- **NAT Gateway:** A one‑way mail slot letting private machines fetch things without being reachable.
- **Route table:** Hallway signs that route traffic; they decide public vs private.
- **Security group:** A per‑resource firewall (the door guard). Stateful: replies are auto‑allowed.
- **IAM policy / role / trust policy:** *What's allowed* / *the badge a machine wears* / *who may wear it*. Always least privilege.
- **EKS Pod Identity / IRSA:** Two ways to give a *specific pod* (not the whole node) AWS permissions. Pod Identity is the 2026 default.
- **Access entries:** The modern, API‑driven way EKS maps IAM identities to cluster permissions, replacing the deprecated `aws-auth` ConfigMap.
- **KMS:** The locksmith that makes/guards encryption keys (for EBS and Kubernetes Secrets).
- **EBS / EFS:** A fast per‑node disk (use this for Kafka) / a shared network folder (avoid for Kafka data).
- **EKS / ECS:** Managed Kubernetes / AWS's own non‑Kubernetes container runner.
- **Node group / Fargate / Auto Mode:** EC2 worker nodes you manage / serverless pods / AWS‑managed nodes.
- **Pod / StatefulSet / Service:** Smallest running unit / a controller for stateful pods with stable identity & storage / a stable network address for pods.
- **StorageClass / EBS CSI driver:** "What kind of disk to make" template / the plugin that actually makes EBS disks.
- **Strimzi operator:** The robot Kafka admin running inside Kubernetes.
- **Kafka / KafkaNodePool / KafkaTopic / KafkaUser:** Strimzi objects for the cluster / a group of controller or broker nodes / a topic / a secured user.
- **KRaft:** Kafka's modern, ZooKeeper‑free design. The only mode in Strimzi 1.0.0.
- **Controller vs broker:** Bookkeeping nodes (metadata, elections) vs data‑holding nodes that serve clients.
- **Listener:** A "door" clients connect to (internal plaintext, internal TLS, external load balancer).
- **Replication factor (RF) / min in‑sync replicas (minISR):** How many copies of data / how many copies must confirm a write. **RF=3, minISR=2** is the safe standard.
- **SCRAM / TLS auth / ACL:** Password login / certificate login / fine‑grained Kafka permissions.
- **Cruise Control / MirrorMaker 2 / Kafka Connect / HTTP Bridge:** Auto‑rebalancer / cross‑cluster replicator / data integration framework / REST gateway to Kafka.
- **Helm:** Kubernetes' app store; we install Strimzi from its Helm chart.
- **Terraform / provider / module / resource:** Infrastructure as code / plugin for a cloud / reusable bundle / one declared thing.

---

### Final word

If you remember nothing else: **use 3 AZs**, **keep Kafka in private subnets**, **encrypt with KMS**, **give every role only what it needs**, **pin your versions**, and **delete the Kafka YAML before `terraform destroy`** so no load balancers or disks are left billing you. On EKS, Strimzi does the hard Kafka work for you; on ECS, that work becomes yours. Choose accordingly — and have fun. 🚀
