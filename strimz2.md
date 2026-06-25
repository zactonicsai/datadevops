# Deploying Strimzi Kafka on Amazon EKS — A Complete Team Guide

*A step-by-step, plain-language handbook for standing up production-grade Apache Kafka on Kubernetes using the Strimzi operator. Includes AWS CLI, Terraform, and Ansible examples, plus testing and troubleshooting.*

**Last reviewed:** June 2026
**Target versions:** Strimzi 1.0.x (v1 API, KRaft-only) · Apache Kafka 4.x · Amazon EKS with Kubernetes 1.30+

---

## Table of Contents

1. [Kafka explained like you're in middle school](#1-kafka-explained-like-youre-in-middle-school)
2. [What Strimzi is and why we use it](#2-what-strimzi-is-and-why-we-use-it)
3. [Architecture of what we're building](#3-architecture-of-what-were-building)
4. [Prerequisites and tools](#4-prerequisites-and-tools)
5. [Step 1 — Create the EKS cluster](#5-step-1--create-the-eks-cluster)
6. [Step 2 — Install the Strimzi operator](#6-step-2--install-the-strimzi-operator)
7. [Step 3 — Deploy a simple Kafka cluster](#7-step-3--deploy-a-simple-kafka-cluster)
8. [Step 4 — Deploy a production Kafka cluster](#8-step-4--deploy-a-production-kafka-cluster)
9. [Step 5 — Create topics and users](#9-step-5--create-topics-and-users)
10. [Automating the whole thing with Ansible](#10-automating-the-whole-thing-with-ansible)
11. [Testing the deployment](#11-testing-the-deployment)
12. [Troubleshooting](#12-troubleshooting)
13. [Operations cheat sheet](#13-operations-cheat-sheet)
14. [Cleanup](#14-cleanup)
15. [Appendix — versions and references](#15-appendix--versions-and-references)

---

## 1. Kafka explained like you're in middle school

Imagine the school cafeteria has a **conveyor belt**. Kids on one side drop lunch trays onto the belt. Kids on the other side pick trays off the belt. The two groups never have to meet, talk, or wait for each other. The belt just keeps moving, and it remembers the order trays were placed.

That conveyor belt is **Apache Kafka**. It's software that lets one set of programs send messages and another set of programs receive them, without the senders and receivers ever talking directly. Kafka holds onto the messages for a while (hours, days, or forever if you want), so receivers can read them whenever they're ready — even if they were offline when the message arrived.

Here are the words Kafka people use, with the cafeteria picture next to each:

| Kafka word | What it means | Cafeteria picture |
|---|---|---|
| **Message / Event** | A single piece of data (e.g., "user clicked Buy") | One lunch tray |
| **Producer** | A program that sends messages | The kid placing trays on the belt |
| **Consumer** | A program that reads messages | The kid taking trays off the belt |
| **Topic** | A named belt for one kind of data | "Pizza belt" vs. "Salad belt" |
| **Partition** | A topic split into parallel lanes for speed | Three belts side-by-side, all carrying pizza |
| **Offset** | The position number of a message in a lane | "Tray #57 on lane 2" |
| **Broker** | One Kafka server that stores data and serves it | One belt motor + storage room |
| **Cluster** | Several brokers working as a team | The whole cafeteria's belt system |
| **Consumer group** | A team of consumers sharing the work | Several kids splitting the unloading |
| **Replication** | Keeping copies of data on other brokers | Photocopying each tray's contents and storing copies elsewhere |

**Why partitions matter (the speed trick):** If one belt can carry 100 trays a minute but you need 300, you run three belts. A topic with three partitions can be read by three consumers at the same time — three times the speed. This is how Kafka scales to millions of messages per second.

**Why replication matters (the safety trick):** Each partition has one **leader** copy and one or more **follower** copies on different brokers. If the broker holding the leader crashes, a follower instantly takes over. You set how many copies with the **replication factor**. A replication factor of 3 means three brokers each hold the data, so you can lose two and still be fine.

**Two settings you'll see everywhere — and why they keep your data safe:**

- `replication.factor = 3` — keep 3 copies of every partition.
- `min.insync.replicas = 2` — a write is only confirmed once at least 2 of those copies have it.

Together these mean: a producer's message is "safe" only when two brokers have it. You can lose one broker without losing data or blocking writes. This combination (3 and 2) is the standard production setting.

### What KRaft is (and why ZooKeeper is gone)

Older Kafka needed a separate helper system called **ZooKeeper** to keep track of which broker is in charge, what topics exist, and so on — like a cafeteria manager with a clipboard standing in a separate office. Running that second system was extra work and extra things to break.

Modern Kafka replaced ZooKeeper with **KRaft** (pronounced "craft"), where Kafka manages its own clipboard internally using a voting protocol called Raft. In KRaft, nodes take one of these roles:

- **Controller** — the managers. They hold the cluster's metadata (the master list of topics, partitions, and who's in charge) and vote among themselves on decisions.
- **Broker** — the workers. They store the actual messages and serve producers and consumers.
- **Dual-role** — a node that does both. Fine for development; in production you separate them.

> **Important:** As of Strimzi 0.46+ and Strimzi 1.0, ZooKeeper is fully removed. All new clusters use KRaft. This guide is KRaft-only. If you read an older tutorial that mentions ZooKeeper, it's out of date.

---

## 2. What Strimzi is and why we use it

Running Kafka by hand on Kubernetes is painful: you'd have to write StatefulSets, generate TLS certificates, wire up storage, handle rolling restarts safely, and manage upgrades — all error-prone.

**Strimzi** is a Kubernetes **operator** that does all of that for you. An operator is a program that runs inside Kubernetes and knows how to operate a specific piece of software the way an expert human would. You tell Strimzi *what* you want ("a 3-broker Kafka cluster with TLS"), and it figures out *how* to make and maintain it.

The magic is **Custom Resources (CRs)**. Strimzi adds new object types to Kubernetes so you can describe Kafka in YAML, the same way you describe Pods or Services:

| Custom Resource | What you use it for |
|---|---|
| `Kafka` | The overall cluster: version, listeners, config, operators |
| `KafkaNodePool` | A group of nodes with a role (controller/broker), replica count, storage |
| `KafkaTopic` | Declare a topic in YAML — Strimzi creates it in Kafka |
| `KafkaUser` | Declare a user with permissions — Strimzi creates credentials |
| `KafkaConnect` | Run Kafka Connect for moving data in/out |
| `KafkaMirrorMaker2` | Replicate data between clusters |
| `KafkaRebalance` | Ask Cruise Control to rebalance data across brokers |

What you get for free: automated provisioning, rolling upgrades one broker at a time (no downtime), automatic TLS certificate generation and rotation, topic and user management as code, Prometheus metrics, and Cruise Control for automatic rebalancing.

Strimzi runs three kinds of operators:

- **Cluster Operator** — the main one. Watches `Kafka` and `KafkaNodePool` resources and builds the cluster. You install this first.
- **Topic Operator** — watches `KafkaTopic` resources and creates/updates topics.
- **User Operator** — watches `KafkaUser` resources and manages credentials and permissions.

The Topic and User Operators run together as the **Entity Operator**, which the Cluster Operator deploys for you when you ask for it in the `Kafka` resource.

---

## 3. Architecture of what we're building

Here's the full picture, from AWS infrastructure up to your applications:

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Account / Region (e.g. us-east-1)                            │
│                                                                   │
│  ┌─────────────────────── VPC ──────────────────────────────┐    │
│  │  3 Availability Zones (az-a, az-b, az-c)                  │    │
│  │                                                           │    │
│  │   Private subnets            Private subnets              │    │
│  │   ┌──────────────────── EKS Cluster ──────────────────┐   │   │
│  │   │                                                    │   │   │
│  │   │  Node group (EC2 worker nodes, spread over 3 AZs)  │   │   │
│  │   │                                                    │   │   │
│  │   │   ┌─ namespace: kafka ──────────────────────────┐  │   │   │
│  │   │   │                                             │  │   │   │
│  │   │   │  Strimzi Cluster Operator (1 pod)           │  │   │   │
│  │   │   │                                             │  │   │   │
│  │   │   │  Controllers (3 pods)  ← KRaft metadata     │  │   │   │
│  │   │   │  Brokers     (3 pods)  ← message storage    │  │   │   │
│  │   │   │       │  each broker → EBS gp3 volume (PVC)  │  │   │   │
│  │   │   │  Entity Operator (topic + user operator)    │  │   │   │
│  │   │   │                                             │  │   │   │
│  │   │   │  Services:                                  │  │   │   │
│  │   │   │   my-cluster-kafka-bootstrap:9092 (plain)   │  │   │   │
│  │   │   │   my-cluster-kafka-bootstrap:9093 (TLS)     │  │   │   │
│  │   │   └─────────────────────────────────────────────┘  │   │   │
│  │   └────────────────────────────────────────────────────┘   │   │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│   EBS (gp3 volumes for Kafka data)   Route53 / NLB (optional      │
│                                       for external access)        │
└───────────────────────────────────────────────────────────────────┘
```

**The layers, bottom to top:**

1. **AWS networking (VPC + subnets)** — a private network across 3 Availability Zones (AZs) so a whole datacenter can fail and Kafka keeps running.
2. **EKS** — Amazon's managed Kubernetes. AWS runs the control plane; you run worker nodes (EC2 instances).
3. **Worker nodes** — EC2 machines spread across the 3 AZs where your pods actually run.
4. **Strimzi Cluster Operator** — installed once; manages everything Kafka.
5. **Kafka cluster** — controller pods and broker pods, each broker with its own EBS volume.
6. **Services** — stable network names your apps connect to (the "bootstrap" address).

> **Why 3 AZs and 3 brokers?** Kafka's safe defaults need at least 3 brokers (replication factor 3). Spreading them across 3 AZs means losing one AZ leaves 2 brokers up — still enough to serve data and accept writes.

---

## 4. Prerequisites and tools

Install these on your workstation (or your CI runner). Versions shown are known-good as of mid-2026; newer is generally fine.

| Tool | Why | Quick check |
|---|---|---|
| AWS CLI v2 | Talk to AWS | `aws --version` |
| `kubectl` 1.30+ | Talk to Kubernetes | `kubectl version --client` |
| `eksctl` | Easiest way to make EKS clusters | `eksctl version` |
| `helm` 3.x | Install Strimzi via its chart | `helm version` |
| Terraform 1.6+ | Infrastructure as code (alternative to eksctl) | `terraform version` |
| Ansible 2.15+ | Orchestrate the end-to-end flow | `ansible --version` |

**AWS permissions:** the identity you use needs rights to create EKS clusters, EC2 instances, VPCs, IAM roles, and EBS volumes. For a first run, an admin-level role is simplest; tighten later.

**Configure AWS credentials:**

```bash
aws configure
# Enter: Access Key, Secret Key, default region (e.g. us-east-1), output (json)

# Verify it works and note your account ID:
aws sts get-caller-identity
```

Set a few shell variables we'll reuse throughout:

```bash
export AWS_REGION=us-east-1
export CLUSTER_NAME=kafka-eks
export K8S_VERSION=1.31
export STRIMZI_VERSION=0.51.0   # latest 0.x; or use the 1.0.x chart
```

> **TIP — pick your Kubernetes version deliberately.** Strimzi 0.51 / 1.0 require Kubernetes **1.30 or newer**. EKS supports several versions at once; choosing 1.30 or 1.31 gives you headroom. Don't pick the absolute newest EKS version on day one unless you've tested it — give yourself a stable target.

---

## 5. Step 1 — Create the EKS cluster

You have four common ways to create the cluster. Pick **one**. We show all four so your team can use whichever fits your workflow. `eksctl` is fastest to learn; Terraform is best for cross-cloud infrastructure-as-code; CloudFormation is the AWS-native IaC choice; the raw AWS CLI is shown so you understand what's happening underneath. (Fun fact: `eksctl` actually generates CloudFormation stacks behind the scenes.)

### Option A — eksctl (fastest, recommended for first-timers)

`eksctl` creates the VPC, subnets across 3 AZs, the EKS control plane, a managed node group, and the IAM roles — all from one config file.

Create `cluster.yaml`:

```yaml
# cluster.yaml — EKS cluster sized for a small Kafka deployment
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: kafka-eks
  region: us-east-1
  version: "1.31"

# Spread across 3 Availability Zones for high availability
availabilityZones: ["us-east-1a", "us-east-1b", "us-east-1c"]

# IAM OIDC provider lets pods get fine-grained AWS permissions (needed for the EBS CSI driver)
iam:
  withOIDC: true

managedNodeGroups:
  - name: kafka-workers
    instanceType: m6i.xlarge      # 4 vCPU, 16 GB RAM — comfortable for brokers
    desiredCapacity: 3            # one node per AZ
    minSize: 3
    maxSize: 6
    volumeSize: 100               # GB, root volume for the node itself
    privateNetworking: true       # nodes have no public IPs
    labels:
      workload: kafka
    tags:
      project: kafka-platform

# Managed add-ons; the EBS CSI driver is required so Kafka can get persistent volumes
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true
```

Create the cluster (takes ~15–20 minutes):

```bash
eksctl create cluster -f cluster.yaml
```

When it finishes, `eksctl` automatically updates your kubeconfig. Verify:

```bash
kubectl get nodes
# You should see 3 nodes in Ready state, one per AZ.
```

### Option B — Terraform (recommended for production / IaC)

Terraform lets you version-control your infrastructure and review changes before applying. This uses the community `eks` and `vpc` modules, which encode AWS best practices.

Create `main.tf`:

```hcl
# main.tf — EKS cluster + VPC for Strimzi Kafka
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  region = var.region
}

variable "region"       { default = "us-east-1" }
variable "cluster_name" { default = "kafka-eks" }
variable "k8s_version"  { default = "1.31" }

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ---------- VPC across 3 AZs ----------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # cheaper for dev; set false for prod (one NAT per AZ)
  enable_dns_hostnames = true

  # Tags required so Kubernetes load balancers can discover subnets
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# ---------- EKS cluster + managed node group ----------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.k8s_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Install the EBS CSI driver so Kafka can claim persistent volumes
  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    aws-ebs-csi-driver     = { most_recent = true }
  }

  enable_irsa = true  # IAM Roles for Service Accounts (OIDC)

  eks_managed_node_groups = {
    kafka_workers = {
      instance_types = ["m6i.xlarge"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      labels         = { workload = "kafka" }
    }
  }

  tags = { project = "kafka-platform" }
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "region"           { value = var.region }
```

Apply it:

```bash
terraform init
terraform plan      # review what will be created
terraform apply     # type 'yes' to confirm  (~15–20 min)

# Point kubectl at the new cluster:
aws eks update-kubeconfig --name kafka-eks --region us-east-1
kubectl get nodes
```

> **NOTE — IRSA and the EBS CSI driver.** Kafka needs persistent disks. On EKS those come from EBS volumes provisioned by the **EBS CSI driver**, which needs AWS permissions. Both `eksctl` (`ebsCSIController: true`) and the Terraform module (`enable_irsa` + the addon) wire this up. If you skip it, broker pods get stuck in `Pending` because their storage can never be created.

### Option C — raw AWS CLI (to understand the moving parts)

You normally won't do this by hand, but it's useful to see what the tools above automate. The short version: create the cluster control plane, then a node group.

```bash
# 1) Create the cluster control plane (assumes a cluster IAM role and subnets already exist)
aws eks create-cluster \
  --name kafka-eks \
  --region us-east-1 \
  --kubernetes-version 1.31 \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/eksClusterRole \
  --resources-vpc-config subnetIds=subnet-aaa,subnet-bbb,subnet-ccc

# 2) Wait until it is ACTIVE (several minutes)
aws eks wait cluster-active --name kafka-eks --region us-east-1

# 3) Create a managed node group across the 3 subnets
aws eks create-nodegroup \
  --cluster-name kafka-eks \
  --nodegroup-name kafka-workers \
  --region us-east-1 \
  --node-role arn:aws:iam::<ACCOUNT_ID>:role/eksNodeRole \
  --subnets subnet-aaa subnet-bbb subnet-ccc \
  --instance-types m6i.xlarge \
  --scaling-config minSize=3,maxSize=6,desiredSize=3

aws eks wait nodegroup-active \
  --cluster-name kafka-eks --nodegroup-name kafka-workers --region us-east-1

# 4) Install the EBS CSI driver add-on
aws eks create-addon --cluster-name kafka-eks --addon-name aws-ebs-csi-driver --region us-east-1

# 5) Update kubeconfig
aws eks update-kubeconfig --name kafka-eks --region us-east-1
```

> **WARNING — the AWS CLI does not create everything for you.** Unlike eksctl/Terraform, the raw `create-cluster` call assumes the VPC, subnets, IAM roles (`eksClusterRole`, `eksNodeRole`), and the OIDC provider already exist. This is exactly the toil eksctl and Terraform remove. Use the CLI path for learning, not for building real clusters.

### Option D — CloudFormation (AWS-native infrastructure as code)

CloudFormation is AWS's own infrastructure-as-code service. You describe your infrastructure in a YAML (or JSON) **template**, and AWS creates and tracks everything as a single unit called a **stack**. If you're an all-AWS shop and prefer not to add Terraform, this keeps everything inside the AWS toolchain. Think of it like Terraform, but built into AWS and only for AWS resources.

> **The pattern:** create the VPC and networking, then create the EKS cluster, then create a managed node group, then add the EBS CSI driver. We split this into two stacks — a VPC stack and a cluster stack — because reusing one network across clusters is common, and smaller stacks are easier to update and roll back.

**Stack 1 — the VPC and networking.** Save as `vpc-stack.yaml`:

```yaml
# vpc-stack.yaml — VPC across 3 AZs for an EKS Kafka cluster
AWSTemplateFormatVersion: "2010-09-09"
Description: VPC with public and private subnets across 3 AZs for EKS

Parameters:
  ClusterName:
    Type: String
    Default: kafka-eks

Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - { Key: Name, Value: !Sub "${ClusterName}-vpc" }

  InternetGateway:
    Type: AWS::EC2::InternetGateway
  GatewayAttach:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref Vpc
      InternetGatewayId: !Ref InternetGateway

  # ---- Public subnets (one per AZ) ----
  PublicSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.101.0/24
      AvailabilityZone: !Select [0, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags:
        - { Key: "kubernetes.io/role/elb", Value: "1" }     # so public load balancers find this subnet
  PublicSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.102.0/24
      AvailabilityZone: !Select [1, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags:
        - { Key: "kubernetes.io/role/elb", Value: "1" }
  PublicSubnet3:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.103.0/24
      AvailabilityZone: !Select [2, !GetAZs ""]
      MapPublicIpOnLaunch: true
      Tags:
        - { Key: "kubernetes.io/role/elb", Value: "1" }

  # ---- Private subnets (one per AZ) — worker nodes live here ----
  PrivateSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.1.0/24
      AvailabilityZone: !Select [0, !GetAZs ""]
      Tags:
        - { Key: "kubernetes.io/role/internal-elb", Value: "1" }   # so internal load balancers find this subnet
  PrivateSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.2.0/24
      AvailabilityZone: !Select [1, !GetAZs ""]
      Tags:
        - { Key: "kubernetes.io/role/internal-elb", Value: "1" }
  PrivateSubnet3:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.0.3.0/24
      AvailabilityZone: !Select [2, !GetAZs ""]
      Tags:
        - { Key: "kubernetes.io/role/internal-elb", Value: "1" }

  # ---- NAT gateway so private nodes can reach the internet (pull images, etc.) ----
  NatEip:
    Type: AWS::EC2::EIP
    Properties: { Domain: vpc }
  NatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEip.AllocationId
      SubnetId: !Ref PublicSubnet1

  # ---- Route tables ----
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref Vpc }
  PublicDefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttach
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway
  PublicAssoc1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PublicRouteTable, SubnetId: !Ref PublicSubnet1 }
  PublicAssoc2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PublicRouteTable, SubnetId: !Ref PublicSubnet2 }
  PublicAssoc3:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PublicRouteTable, SubnetId: !Ref PublicSubnet3 }

  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties: { VpcId: !Ref Vpc }
  PrivateDefaultRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway
  PrivateAssoc1:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PrivateRouteTable, SubnetId: !Ref PrivateSubnet1 }
  PrivateAssoc2:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PrivateRouteTable, SubnetId: !Ref PrivateSubnet2 }
  PrivateAssoc3:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: { RouteTableId: !Ref PrivateRouteTable, SubnetId: !Ref PrivateSubnet3 }

# Outputs are exported so the cluster stack can import these IDs by name
Outputs:
  VpcId:
    Value: !Ref Vpc
    Export: { Name: !Sub "${ClusterName}-VpcId" }
  PrivateSubnets:
    Value: !Join [",", [!Ref PrivateSubnet1, !Ref PrivateSubnet2, !Ref PrivateSubnet3]]
    Export: { Name: !Sub "${ClusterName}-PrivateSubnets" }
  PublicSubnets:
    Value: !Join [",", [!Ref PublicSubnet1, !Ref PublicSubnet2, !Ref PublicSubnet3]]
    Export: { Name: !Sub "${ClusterName}-PublicSubnets" }
```

**Stack 2 — the EKS cluster, node group, and IAM roles.** Save as `eks-stack.yaml`:

```yaml
# eks-stack.yaml — EKS control plane + managed node group + EBS CSI add-on
AWSTemplateFormatVersion: "2010-09-09"
Description: EKS cluster and managed node group for Strimzi Kafka

Parameters:
  ClusterName:
    Type: String
    Default: kafka-eks
  KubernetesVersion:
    Type: String
    Default: "1.31"
  NodeInstanceType:
    Type: String
    Default: m6i.xlarge

Resources:
  # ---- IAM role the EKS control plane assumes ----
  ClusterRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: eks.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

  # ---- IAM role each worker node assumes ----
  NodeRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal: { Service: ec2.amazonaws.com }
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
        - arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
        - arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicy   # lets nodes manage EBS volumes for Kafka

  # ---- The EKS control plane ----
  Cluster:
    Type: AWS::EKS::Cluster
    Properties:
      Name: !Ref ClusterName
      Version: !Ref KubernetesVersion
      RoleArn: !GetAtt ClusterRole.Arn
      ResourcesVpcConfig:
        EndpointPublicAccess: true
        EndpointPrivateAccess: true
        SubnetIds: !Split
          - ","
          - !ImportValue
              "Fn::Sub": "${ClusterName}-PrivateSubnets"

  # ---- Managed node group: 3 nodes across the 3 private subnets ----
  NodeGroup:
    Type: AWS::EKS::Nodegroup
    Properties:
      ClusterName: !Ref Cluster
      NodegroupName: kafka-workers
      NodeRole: !GetAtt NodeRole.Arn
      InstanceTypes: [!Ref NodeInstanceType]
      ScalingConfig: { MinSize: 3, DesiredSize: 3, MaxSize: 6 }
      Subnets: !Split
        - ","
        - !ImportValue
            "Fn::Sub": "${ClusterName}-PrivateSubnets"
      Labels: { workload: kafka }

  # ---- EBS CSI driver add-on (required for Kafka persistent storage) ----
  EbsCsiAddon:
    Type: AWS::EKS::Addon
    DependsOn: NodeGroup
    Properties:
      ClusterName: !Ref Cluster
      AddonName: aws-ebs-csi-driver
      ResolveConflicts: OVERWRITE

Outputs:
  ClusterName:
    Value: !Ref Cluster
  ClusterEndpoint:
    Value: !GetAtt Cluster.Endpoint
```

Deploy both stacks in order with the AWS CLI:

```bash
# 1) Create the networking stack
aws cloudformation deploy \
  --template-file vpc-stack.yaml \
  --stack-name kafka-eks-vpc \
  --parameter-overrides ClusterName=kafka-eks \
  --region us-east-1

# 2) Create the cluster stack (CAPABILITY_IAM is required because it creates IAM roles)
aws cloudformation deploy \
  --template-file eks-stack.yaml \
  --stack-name kafka-eks-cluster \
  --parameter-overrides ClusterName=kafka-eks KubernetesVersion=1.31 \
  --capabilities CAPABILITY_IAM \
  --region us-east-1

# 3) Point kubectl at the new cluster
aws eks update-kubeconfig --name kafka-eks --region us-east-1
kubectl get nodes
```

> **NOTE — how the two stacks connect.** The VPC stack publishes subnet IDs with `Export`, and the cluster stack pulls them in with `!ImportValue`. This is CloudFormation's way of sharing values between stacks. The trade-off: you can't delete or modify an exported value while another stack still imports it, so always delete the cluster stack *before* the VPC stack.

> **WARNING — CloudFormation is more verbose by design.** Notice this option is far longer than eksctl for the same result — CloudFormation makes you spell out every subnet, route, and IAM role explicitly. That verbosity is also its strength: every resource is tracked in one stack, changes are previewed as **change sets**, and `delete-stack` cleanly removes everything. If you want AWS-native IaC and full control, use this. If you just want a cluster fast, eksctl (which actually generates CloudFormation under the hood) is simpler.

To tear down later, delete in reverse order:

```bash
aws cloudformation delete-stack --stack-name kafka-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name kafka-eks-cluster --region us-east-1
aws cloudformation delete-stack --stack-name kafka-eks-vpc --region us-east-1
```

### Set up a storage class for Kafka

Kafka brokers store data on disk. On EKS, we want fast `gp3` EBS volumes. Create a StorageClass that uses the EBS CSI driver:

```yaml
# storageclass-gp3.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # create the disk in the same AZ as the pod
allowVolumeExpansion: true                # lets you grow disks later without downtime
parameters:
  type: gp3
  fsType: ext4
```

```bash
kubectl apply -f storageclass-gp3.yaml
kubectl get storageclass
```

> **TIP — `WaitForFirstConsumer` prevents a classic mistake.** Without it, Kubernetes might create the EBS volume in `az-a` but schedule the broker pod in `az-b` — and an EBS volume can't cross AZs, so the pod never starts. `WaitForFirstConsumer` makes Kubernetes decide the pod's AZ first, then create the disk there.

---

## 6. Step 2 — Install the Strimzi operator

The Strimzi Cluster Operator is the brain that turns your YAML into a running Kafka cluster. Install it **once** per cluster. We show the Helm method (recommended) and the plain-YAML method.

First, create a dedicated namespace so Kafka is isolated from everything else:

```bash
kubectl create namespace kafka
```

### Method 1 — Helm (recommended)

```bash
# Add the Strimzi Helm repository
helm repo add strimzi https://strimzi.io/charts/
helm repo update

# Install the operator into the 'kafka' namespace
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --version 0.51.0 \
  --set watchNamespaces="{kafka}"     # operator only watches the 'kafka' namespace
```

> **NOTE — CRDs and upgrades.** The Helm chart installs the Custom Resource Definitions (the `Kafka`, `KafkaNodePool`, etc. types) for you on first install. But `helm upgrade` does **not** upgrade CRDs automatically — you must apply them manually when moving to a new version, e.g. `kubectl apply -f https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.51.0/strimzi-crds-0.51.0.yaml`. Always upgrade CRDs *before* upgrading the operator.

### Method 2 — Plain YAML

```bash
# Download and apply the install bundle, with the namespace pinned to 'kafka'
kubectl create -f \
  "https://strimzi.io/install/latest?namespace=kafka" \
  -n kafka
```

### Verify the operator is running

```bash
kubectl get pods -n kafka
# Expect something like:
# NAME                                        READY   STATUS    RESTARTS
# strimzi-cluster-operator-7d6cb4f8b9-x2k4p   1/1     Running   0

# Confirm the custom resource types are installed:
kubectl get crd | grep strimzi
# kafkas.kafka.strimzi.io
# kafkanodepools.kafka.strimzi.io
# kafkatopics.kafka.strimzi.io
# kafkausers.kafka.strimzi.io   ... and more
```

If the operator pod is `Running` and the CRDs are listed, you're ready to create a Kafka cluster.

> **WARNING — security advisories.** Strimzi 0.50.1 and 0.51.0 fixed CVE-2026-27133 and CVE-2026-27134 (affecting 0.47.0+). Always install a patched version. Strimzi also signs its container images with cosign; in regulated environments you can verify signatures before deploying.

---

## 7. Step 3 — Deploy a simple Kafka cluster

Let's start with the smallest thing that works, so you can see the pieces before adding production complexity. This is a **single dual-role node** — one pod that's both controller and broker — using ephemeral (temporary) storage. **Development only.**

Two resources work together. The `KafkaNodePool` describes the nodes; the `Kafka` resource describes the cluster and links to the pool by a label.

```yaml
# kafka-simple.yaml — development cluster (single node, ephemeral, KRaft)
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster      # ← links this pool to the Kafka named "my-cluster"
spec:
  replicas: 1
  roles:
    - controller
    - broker                            # this node does both jobs
  storage:
    type: ephemeral                     # data lives only as long as the pod; DEV ONLY
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled      # use the KafkaNodePool model
    strimzi.io/kraft: enabled           # use KRaft (no ZooKeeper)
spec:
  kafka:
    version: 4.0.0
    metadataVersion: 4.0-IV3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      # With one broker, every replication factor must be 1
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}                   # enable topic management via KafkaTopic
    userOperator: {}                    # enable user management via KafkaUser
```

Deploy it and wait for Strimzi to build the cluster:

```bash
kubectl apply -f kafka-simple.yaml

# Watch the operator do its work (Ctrl-C when Ready):
kubectl get kafka my-cluster -n kafka -w

# The clean way to block until it's ready:
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

### Understanding each part of the simple cluster

- **`apiVersion: kafka.strimzi.io/v1beta2`** — the API group for Strimzi resources. (Strimzi 1.0 introduces a `v1` API; `v1beta2` is still widely used and accepted. Match whatever your installed CRDs support.)
- **The two annotations** — `node-pools: enabled` tells Strimzi to use `KafkaNodePool` objects; `kraft: enabled` selects KRaft mode. Both are standard now.
- **`listeners`** — the doors clients knock on. `plain` (9092) is unencrypted, for inside-the-cluster traffic during testing. `tls` (9093) is encrypted. `type: internal` means only reachable inside Kubernetes.
- **`config`** — raw Kafka broker settings. With a single broker, every replication number is forced to `1` (you can't keep 3 copies on 1 machine).
- **`entityOperator`** — switches on the Topic and User Operators so you can manage topics/users as YAML.

After it's ready, look at what Strimzi created for you:

```bash
kubectl get pods -n kafka
# my-cluster-dual-role-0              1/1 Running   (the Kafka node)
# my-cluster-entity-operator-...     2/2 Running   (topic + user operator)

kubectl get svc -n kafka
# my-cluster-kafka-bootstrap   ClusterIP   ...   9091,9092,9093
# ^ this "bootstrap" service is the address your apps connect to
```

The **bootstrap service** is important: clients connect to it, and it points them at the right brokers. Your apps never hardcode individual broker addresses — they use `my-cluster-kafka-bootstrap:9092`.

---

## 8. Step 4 — Deploy a production Kafka cluster

Now the real thing. Differences from the simple cluster:

- **Separate controllers and brokers** (two node pools) — controllers stay stable while brokers scale.
- **3 brokers + 3 controllers** spread across AZs.
- **Persistent `gp3` storage** so data survives pod restarts.
- **Safe replication** (`replication.factor: 3`, `min.insync.replicas: 2`).
- **Resource requests/limits and JVM heap** sized sensibly.
- **Rack awareness** so replicas land in different AZs.
- **Pod anti-affinity** so two brokers never share a node.

```yaml
# kafka-production.yaml — production cluster (KRaft, 3 controllers + 3 brokers)
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  namespace: kafka
  labels:
    strimzi.io/cluster: prod-kafka
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi                 # controllers only store metadata; small is fine
        deleteClaim: false         # keep the disk if the pod/cluster is deleted
        class: gp3
  resources:
    requests: { memory: 2Gi, cpu: "1" }
    limits:   { memory: 4Gi, cpu: "2" }
  jvmOptions:
    -Xms: 1024m
    -Xmx: 1024m                    # heap < requests.memory; leave room for page cache
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  namespace: kafka
  labels:
    strimzi.io/cluster: prod-kafka
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 500Gi                # brokers store the actual messages
        deleteClaim: false
        class: gp3
  resources:
    requests: { memory: 8Gi, cpu: "2" }
    limits:   { memory: 16Gi, cpu: "4" }
  jvmOptions:
    -Xms: 4096m
    -Xmx: 4096m
  template:
    pod:
      # Never put two broker pods on the same EC2 node
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: strimzi.io/pool-name
                    operator: In
                    values: ["broker"]
              topologyKey: kubernetes.io/hostname
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: prod-kafka
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 4.0.0
    metadataVersion: 4.0-IV3
    # Rack awareness: spread partition replicas across AZs using the node's zone label
    rack:
      topologyKey: topology.kubernetes.io/zone
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls                # require client certificates (mutual TLS)
      - name: external
        port: 9094
        type: loadbalancer         # exposes Kafka outside the cluster via an AWS NLB
        tls: true
        authentication:
          type: tls
    authorization:
      type: simple                 # turn on ACLs (permissions per user/topic)
    config:
      # The safe production trio:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      # Spread replicas across racks/AZs automatically:
      replica.selector.class: org.apache.kafka.common.replica.RackAwareReplicaSelector
  entityOperator:
    topicOperator: {}
    userOperator: {}
  # Cruise Control enables automated rebalancing (used by KafkaRebalance)
  cruiseControl: {}
```

Deploy and wait:

```bash
kubectl apply -f kafka-production.yaml
kubectl wait kafka/prod-kafka --for=condition=Ready --timeout=600s -n kafka

kubectl get pods -n kafka
# prod-kafka-controller-0/1/2   (KRaft controllers)
# prod-kafka-broker-0/1/2       (brokers, each with its own gp3 volume)
# prod-kafka-entity-operator-...
# prod-kafka-cruise-control-...
```

### Why each production choice matters

| Choice | Plain-language reason |
|---|---|
| Separate controller & broker pools | You can scale brokers (more storage/throughput) without disturbing the metadata managers. Controllers stay rock-stable. |
| `replication.factor: 3` + `min.insync.replicas: 2` | Survive losing one broker with zero data loss and no write blocking. |
| `rack` + `RackAwareReplicaSelector` | Copies of data land in different AZs, so an AZ outage never takes all copies. |
| Persistent `gp3` `deleteClaim: false` | Data survives pod restarts; disks aren't deleted if you remove the cluster by accident. |
| Pod anti-affinity | Two brokers won't share one EC2 node, so one node failure costs you only one broker. |
| Heap (`-Xmx`) well below memory limit | Kafka relies heavily on the OS page cache for speed; leaving RAM free is faster than a huge heap. |
| `authorization: simple` + TLS auth | Only known clients with certificates can connect, and only to topics they're allowed. |
| `cruiseControl: {}` | Lets you rebalance data automatically when you add/remove brokers. |

> **WARNING — `loadbalancer` listeners cost money and open the door.** The `external` listener creates a real AWS Network Load Balancer (one per broker plus a bootstrap), which costs money and is internet-reachable. Only add it if clients live outside the cluster. For app-to-Kafka traffic inside EKS, the internal `tls` listener is enough. Also note: the older `ingress` listener type is deprecated as of 2026 — prefer `loadbalancer` or `nodeport`.

---

## 9. Step 5 — Create topics and users

Because the Entity Operator is running, you create topics and users by applying YAML — no `kafka-topics.sh` needed.

### Create a topic

```yaml
# topic-orders.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders
  namespace: kafka
  labels:
    strimzi.io/cluster: prod-kafka
spec:
  partitions: 6        # 6 lanes → up to 6 consumers reading in parallel
  replicas: 3          # 3 copies for safety (must be ≤ number of brokers)
  config:
    retention.ms: 604800000     # keep messages 7 days
    segment.bytes: 1073741824   # 1 GB log segments
```

```bash
kubectl apply -f topic-orders.yaml
kubectl get kafkatopic -n kafka
```

> **NOTE — choosing partition count.** Partitions are your parallelism unit: a topic with 6 partitions supports at most 6 consumers in one group doing work simultaneously. More partitions = more parallelism but more overhead. A common starting point is 3–12 for moderate workloads; you can increase later (but never decrease).

### Create a user with permissions

```yaml
# user-orders-app.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: orders-app
  namespace: kafka
  labels:
    strimzi.io/cluster: prod-kafka
spec:
  authentication:
    type: tls                    # this user authenticates with a client certificate
  authorization:
    type: simple
    acls:
      # Allowed to read and write the "orders" topic
      - resource: { type: topic, name: orders, patternType: literal }
        operations: [Read, Write, Describe]
      # Allowed to join consumer groups starting with "orders-"
      - resource: { type: group, name: orders-, patternType: prefix }
        operations: [Read]
```

```bash
kubectl apply -f user-orders-app.yaml

# Strimzi generates a Secret holding the user's certificate and key:
kubectl get secret orders-app -n kafka -o yaml
```

Your application mounts that secret to authenticate. The User Operator created the credentials and applied the ACLs to Kafka automatically.

---

## 10. Automating the whole thing with Ansible

The steps above are great for learning, but you don't want to run them by hand every time. Ansible can drive the entire flow — create the EKS cluster, install Strimzi, and deploy Kafka — as one repeatable playbook. This is the "glue" that ties Terraform/eksctl, Helm, and kubectl together.

> **The pattern:** Ansible calls Terraform (or eksctl) for infrastructure, then uses the `kubernetes.core` collection to talk to the cluster. Install that collection first.

```bash
ansible-galaxy collection install kubernetes.core community.general
pip install kubernetes   # the Python client the modules use
```

Project layout:

```
kafka-eks-ansible/
├── inventory.ini
├── playbook.yml
├── group_vars/all.yml
└── files/
    ├── storageclass-gp3.yaml
    ├── kafka-production.yaml
    ├── topic-orders.yaml
    └── user-orders-app.yaml
```

`group_vars/all.yml` — central place for variables:

```yaml
# group_vars/all.yml
region: us-east-1
cluster_name: kafka-eks
k8s_version: "1.31"
strimzi_version: "0.51.0"
kafka_namespace: kafka
```

`playbook.yml` — the end-to-end automation:

```yaml
# playbook.yml — provision EKS, install Strimzi, deploy Kafka
- name: Deploy Strimzi Kafka on EKS
  hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - group_vars/all.yml

  tasks:
    # ---------- 1. Infrastructure via Terraform ----------
    - name: Provision EKS cluster with Terraform
      community.general.terraform:
        project_path: "../terraform"
        state: present
        force_init: true
      register: tf

    - name: Update kubeconfig for the new cluster
      ansible.builtin.command: >
        aws eks update-kubeconfig
        --name {{ cluster_name }} --region {{ region }}
      changed_when: false

    # ---------- 2. Storage class ----------
    - name: Apply gp3 StorageClass
      kubernetes.core.k8s:
        state: present
        src: files/storageclass-gp3.yaml

    # ---------- 3. Namespace ----------
    - name: Create kafka namespace
      kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: "{{ kafka_namespace }}"

    # ---------- 4. Install Strimzi operator via Helm ----------
    - name: Add Strimzi Helm repo
      kubernetes.core.helm_repository:
        name: strimzi
        repo_url: https://strimzi.io/charts/

    - name: Install Strimzi Cluster Operator
      kubernetes.core.helm:
        name: strimzi-operator
        chart_ref: strimzi/strimzi-kafka-operator
        chart_version: "{{ strimzi_version }}"
        release_namespace: "{{ kafka_namespace }}"
        create_namespace: false
        values:
          watchNamespaces: ["{{ kafka_namespace }}"]
        wait: true

    # ---------- 5. Deploy Kafka cluster ----------
    - name: Deploy production Kafka cluster
      kubernetes.core.k8s:
        state: present
        namespace: "{{ kafka_namespace }}"
        src: files/kafka-production.yaml

    - name: Wait for Kafka cluster to be Ready
      kubernetes.core.k8s_info:
        api_version: kafka.strimzi.io/v1beta2
        kind: Kafka
        name: prod-kafka
        namespace: "{{ kafka_namespace }}"
      register: kafka_status
      until: >
        kafka_status.resources[0].status.conditions
        | selectattr('type','equalto','Ready')
        | selectattr('status','equalto','True') | list | length > 0
      retries: 60
      delay: 10

    # ---------- 6. Topics and users ----------
    - name: Create topics and users
      kubernetes.core.k8s:
        state: present
        namespace: "{{ kafka_namespace }}"
        src: "{{ item }}"
      loop:
        - files/topic-orders.yaml
        - files/user-orders-app.yaml

    - name: Done
      ansible.builtin.debug:
        msg: "Kafka cluster prod-kafka is ready in namespace {{ kafka_namespace }}."
```

Run the whole thing with one command:

```bash
ansible-playbook playbook.yml
```

> **TIP — idempotency is the point.** Ansible (and Terraform, and `kubectl apply`) are *declarative*: running the playbook twice doesn't create duplicates — it converges the cluster to the described state. This means you can re-run it safely after a change, and it only fixes what drifted.

---

## 11. Testing the deployment

After deployment, prove it actually works. The simplest test uses Kafka's built-in command-line tools from a temporary pod inside the cluster.

### Quick smoke test: produce and consume

Open two terminals.

**Terminal 1 — start a consumer** (reads from the topic):

```bash
kubectl -n kafka run kafka-consumer -ti --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --restart=Never -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server prod-kafka-kafka-bootstrap:9092 \
    --topic orders --from-beginning
```

**Terminal 2 — start a producer** (sends messages):

```bash
kubectl -n kafka run kafka-producer -ti --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --restart=Never -- \
  bin/kafka-console-producer.sh \
    --bootstrap-server prod-kafka-kafka-bootstrap:9092 \
    --topic orders
```

Type a few lines in Terminal 2 and press Enter after each. They should appear in Terminal 1 within a second. That round-trip proves producers, brokers, storage, and consumers all work.

> **NOTE — the `:9092` plain listener.** These quick tests use the unencrypted internal listener. If your production cluster only exposes TLS with client-cert auth (as ours does), you'll instead mount the `orders-app` secret and point the tools at `:9093` with a TLS config file. For a first smoke test, temporarily add a plain internal listener, or test from a pod that has the certs mounted.

### Check the cluster's own opinion of its health

```bash
# Overall status and conditions:
kubectl get kafka prod-kafka -n kafka -o jsonpath='{.status.conditions}' | jq

# Is every broker "in sync"? List topics and describe one:
kubectl -n kafka run kafka-admin -ti --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 --restart=Never -- \
  bin/kafka-topics.sh --bootstrap-server prod-kafka-kafka-bootstrap:9092 \
    --describe --topic orders
# Look at the "Isr" (in-sync replicas) column — it should list all 3 replicas.
```

### Performance / load test

Kafka ships with load generators to check throughput:

```bash
# Producer performance: send 1 million 1KB records
kubectl -n kafka run perf -ti --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 --restart=Never -- \
  bin/kafka-producer-perf-test.sh \
    --topic orders \
    --num-records 1000000 \
    --record-size 1024 \
    --throughput -1 \
    --producer-props bootstrap.servers=prod-kafka-kafka-bootstrap:9092
# Reports records/sec, MB/sec, and latency percentiles.
```

### Resilience test (the real proof)

Kill a broker and watch Kafka heal itself:

```bash
# Delete one broker pod
kubectl delete pod prod-kafka-broker-1 -n kafka

# Watch it come back; meanwhile producers/consumers keep working because
# replication.factor=3 and min.insync.replicas=2 tolerate one broker down.
kubectl get pods -n kafka -w
```

If your producer/consumer from the smoke test keeps running through this, your replication settings are correct.

---

## 12. Troubleshooting

A field guide to the problems you'll most likely hit, why they happen, and how to fix them.

### Where to look first

```bash
# 1. The Kafka resource's status conditions — Strimzi tells you what's wrong here
kubectl get kafka prod-kafka -n kafka -o yaml | less   # read status: section

# 2. The Cluster Operator log — the brain's diagnostics
kubectl logs deployment/strimzi-cluster-operator -n kafka -f

# 3. A specific broker's log
kubectl logs prod-kafka-broker-0 -n kafka

# 4. Kubernetes events (scheduling, image pulls, volume mounts)
kubectl get events -n kafka --sort-by='.lastTimestamp'
```

### Common problems and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Broker pods stuck `Pending` | No nodes with enough CPU/RAM, or storage can't be provisioned | `kubectl describe pod <pod> -n kafka`; check node capacity and that the EBS CSI driver + gp3 StorageClass exist |
| PVC stuck `Pending` | EBS CSI driver missing or lacks IAM permissions | Confirm `aws-ebs-csi-driver` add-on installed and IRSA/role attached |
| `kafka` resource `Ready: False` forever | Bad config (e.g. replication factor > broker count) | Read `status.conditions`; check operator log for the exact validation error |
| Pods `Pending` only after a node dies | Anti-affinity can't find a free node | Ensure node group `maxSize` allows enough nodes; cluster-autoscaler or Karpenter helps |
| `CrashLoopBackOff` on a broker | Heap too large for memory limit, or corrupted volume | Lower `-Xmx` below `resources.limits.memory`; inspect broker log |
| Clients can't connect | Wrong bootstrap address, listener, or missing TLS certs | Use `*-kafka-bootstrap`, correct port (9092 plain / 9093 TLS), mount the KafkaUser secret |
| `NotEnoughReplicasException` on produce | Fewer in-sync replicas than `min.insync.replicas` | A broker is down/behind; restore it so ISR ≥ 2 |
| Operator ignores your Kafka resource | It's in a namespace the operator doesn't watch | Set `watchNamespaces` to include that namespace, or install operator there |
| Topic not created from `KafkaTopic` | Entity Operator / Topic Operator not enabled | Add `entityOperator.topicOperator: {}` to the Kafka spec |

### Reading status conditions

The fastest diagnosis is almost always in the resource status:

```bash
kubectl get kafka prod-kafka -n kafka \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

A healthy cluster shows `Ready=True`. Anything else prints the reason and a human-readable message pointing at the misconfiguration.

> **TIP — when in doubt, describe the pod.** `kubectl describe pod <pod> -n kafka` shows the Events section at the bottom: failed scheduling, image pull errors, and volume mount failures all surface there in plain English. It solves the majority of "pod won't start" cases.

---

## 13. Operations cheat sheet

Day-to-day commands you'll reach for.

```bash
# --- Status ---
kubectl get kafka,kafkanodepool,kafkatopic,kafkauser -n kafka
kubectl get pods -n kafka -o wide                 # see which node/AZ each pod is on
kubectl get pvc -n kafka                           # broker disks

# --- Scale brokers up (e.g. 3 → 5) ---
kubectl patch kafkanodepool broker -n kafka \
  --type merge -p '{"spec":{"replicas":5}}'

# --- Rebalance data after scaling (uses Cruise Control) ---
cat <<EOF | kubectl apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: rebalance-now
  namespace: kafka
  labels:
    strimzi.io/cluster: prod-kafka
spec:
  mode: full
EOF
kubectl get kafkarebalance rebalance-now -n kafka -o yaml   # then approve it:
kubectl annotate kafkarebalance rebalance-now -n kafka \
  strimzi.io/rebalance=approve

# --- Grow a broker disk (gp3 allows online expansion) ---
# Edit the node pool's storage size upward; allowVolumeExpansion must be true.
kubectl edit kafkanodepool broker -n kafka      # change size: 500Gi → 1000Gi

# --- Upgrade Kafka version (change spec.kafka.version, Strimzi does a rolling upgrade) ---
kubectl edit kafka prod-kafka -n kafka

# --- Watch a rolling update happen safely ---
kubectl get pods -n kafka -w
```

> **NOTE — scaling down needs care.** Before reducing broker count, move the data off the brokers you'll remove (Cruise Control / `KafkaRebalance` with the right mode), or you'll lose partitions. Scaling *up* then rebalancing is always safe; scaling *down* is the dangerous direction.

---

## 14. Cleanup

Delete in reverse order of creation to avoid orphaned resources. **This destroys data.**

```bash
# 1. Application resources
kubectl delete kafkatopic --all -n kafka
kubectl delete kafkauser --all -n kafka

# 2. The Kafka cluster and node pools
kubectl delete kafka prod-kafka -n kafka
kubectl delete kafkanodepool --all -n kafka

# 3. The operator
helm uninstall strimzi-operator -n kafka

# 4. PVCs (only deleted automatically if deleteClaim was true)
kubectl delete pvc --all -n kafka

# 5. Namespace
kubectl delete namespace kafka

# 6. The EKS cluster itself
#    Terraform:
terraform destroy
#    or eksctl:
eksctl delete cluster --name kafka-eks --region us-east-1
#    or CloudFormation (delete cluster stack first, then VPC stack):
aws cloudformation delete-stack --stack-name kafka-eks-cluster --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name kafka-eks-cluster --region us-east-1
aws cloudformation delete-stack --stack-name kafka-eks-vpc --region us-east-1
```

> **WARNING — leftover AWS resources cost money.** Load balancers created by `loadbalancer` listeners and EBS volumes with `deleteClaim: false` can survive cluster deletion and keep billing you. After teardown, check the EC2 console for stray Load Balancers and Volumes, and the CloudFormation console (if you used eksctl) for stacks that didn't delete.

---

## 15. Appendix — versions and references

### Version compatibility (as of June 2026)

| Component | Recommended | Notes |
|---|---|---|
| Strimzi operator | 0.51.0 / 1.0.x | 1.0 supports only the `v1` API; KRaft-only since 0.46 |
| Apache Kafka | 4.0.x | Selected via `spec.kafka.version` |
| Kubernetes (EKS) | 1.30 or 1.31 | Strimzi 0.51+ requires **1.30+** |
| EBS CSI driver | latest add-on | Required for persistent storage |
| Helm | 3.x | For installing the operator chart |

### Key facts to remember

- **KRaft only.** ZooKeeper is fully removed in current Strimzi. Use controller + broker node pools.
- **The safe trio:** `replication.factor: 3`, `min.insync.replicas: 2`, across 3 AZs.
- **Storage:** `gp3` EBS with `WaitForFirstConsumer` and `allowVolumeExpansion: true`.
- **Connect via the bootstrap service**, not individual brokers.
- **Upgrade CRDs before the operator**; `helm upgrade` won't do CRDs for you.
- **Patch your operator:** avoid versions affected by CVE-2026-27133 / 27134.

### Official references

- Strimzi documentation: <https://strimzi.io/docs/operators/latest/deploying>
- Strimzi releases & CVEs: <https://github.com/strimzi/strimzi-kafka-operator/releases>
- Strimzi Helm chart: <https://artifacthub.io/packages/helm/strimzi/strimzi-kafka-operator>
- Amazon EKS user guide: <https://docs.aws.amazon.com/eks/>
- eksctl: <https://eksctl.io/>
- Terraform AWS EKS module: <https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest>
- AWS CloudFormation EKS resources: <https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/AWS_EKS.html>
- Apache Kafka documentation: <https://kafka.apache.org/documentation/>

---


