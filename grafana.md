# Adding an EKS Node Group and Building a Full Observability Stack (Grafana + Prometheus + Loki)

**A complete, beginner-friendly walkthrough using AWS CLI, kubectl, and Helm**

Last verified: August 2026 · Amazon EKS 1.36 · kube-prometheus-stack 88.x · Loki community chart 18.x · Grafana Alloy

---

## Table of contents

**PART A — Do it once, step by step**
1. [The 60-second summary](#1-the-60-second-summary)
2. [Background: what all these words mean](#2-background-what-all-these-words-mean)
3. [What you need before you start](#3-what-you-need-before-you-start)
4. [Step 1 — Log in to AWS and point at the right cluster](#step-1--log-in-to-aws-and-point-at-the-right-cluster)
5. [Step 2 — Create the IAM role your nodes will wear](#step-2--create-the-iam-role-your-nodes-will-wear)
6. [Step 3 — Find your subnets](#step-3--find-your-subnets)
7. [Step 4 — Create the managed node group](#step-4--create-the-managed-node-group)
8. [Step 5 — Re-point kubectl and verify the new nodes](#step-5--re-point-kubectl-and-verify-the-new-nodes)
9. [Step 6 — Turn on the add-ons the stack needs](#step-6--turn-on-the-add-ons-the-stack-needs)
10. [Step 7 — Create the S3 bucket and permissions for Loki](#step-7--create-the-s3-bucket-and-permissions-for-loki)
11. [Step 8 — Add the Helm repositories](#step-8--add-the-helm-repositories)
12. [Step 9 — Install Prometheus + Grafana](#step-9--install-prometheus--grafana)
13. [Step 10 — Install Loki](#step-10--install-loki)
14. [Step 11 — Install Grafana Alloy (the log courier)](#step-11--install-grafana-alloy-the-log-courier)
15. [Step 12 — Wire Loki into Grafana](#step-12--wire-loki-into-grafana)
16. [Step 13 — Open Grafana and prove it all works](#step-13--open-grafana-and-prove-it-all-works)

**PART B — All the details and background**
17. [The complete file tree](#17-the-complete-file-tree)
18. [Deep background: how each piece actually works](#18-deep-background-how-each-piece-actually-works)
19. [Options, pros and cons](#19-options-pros-and-cons)
20. [Best practices checklist](#20-best-practices-checklist)
21. [Troubleshooting](#21-troubleshooting)
22. [What this costs](#22-what-this-costs)
23. [Cleanup](#23-cleanup)
24. [Command reference card](#24-command-reference-card)

---

## 1. The 60-second summary

You have an EKS cluster. You want to do two things:

1. **Add a node group** — give your cluster more worker computers to run programs on.
2. **Install an observability stack** — three programs that watch your cluster and show you what's happening:
   - **Prometheus** collects *numbers* (CPU is at 62%, memory is at 3.1 GB).
   - **Loki** collects *text* (the log lines your programs print out).
   - **Grafana** draws *pictures* of both so a human can understand them.

Here is the whole thing in one picture:

```
                        YOUR AWS ACCOUNT
   ┌────────────────────────────────────────────────────────────┐
   │                                                            │
   │   EKS CONTROL PLANE  (AWS runs this — you never see it)    │
   │        the "principal's office" of the cluster             │
   │                          ▲                                 │
   │                          │ nodes check in here             │
   │   ┌──────────────────────┴───────────────────────────┐     │
   │   │             NODE GROUP  "app-ng-1"               │     │
   │   │   ┌────────────┐  ┌────────────┐                 │     │
   │   │   │  EC2 node  │  │  EC2 node  │   ← YOU ADD     │     │
   │   │   │            │  │            │      THESE      │     │
   │   │   │  [Alloy]   │  │  [Alloy]   │  ← 1 per node   │     │
   │   │   │  [pods…]   │  │  [pods…]   │                 │     │
   │   │   └─────┬──────┘  └─────┬──────┘                 │     │
   │   └─────────┼───────────────┼────────────────────────┘     │
   │             │ logs          │ logs                         │
   │             ▼               ▼                              │
   │        ┌─────────┐                    ┌──────────────┐     │
   │        │  LOKI   │───chunks/index────▶│  S3 BUCKET   │     │
   │        └────┬────┘                    └──────────────┘     │
   │             │                                              │
   │        ┌────┴──────┐   scrapes metrics   ┌──────────────┐  │
   │        │  GRAFANA  │◀───────────────────▶│  PROMETHEUS  │  │
   │        └───────────┘                     └──────────────┘  │
   │             ▲                                              │
   └─────────────┼──────────────────────────────────────────────┘
                 │
             YOU, in a browser
```

Total time: **about 45–60 minutes**, most of it waiting for AWS.

---

## 2. Background: what all these words mean

Imagine your cluster is a **school**.

| Kubernetes word | School version | What it really is |
|---|---|---|
| **Cluster** | The whole school | A group of computers working as one system |
| **Control plane** | The principal's office | The brain that decides what runs where. On EKS, **AWS owns and runs this for you.** |
| **Node** | One classroom | One EC2 virtual computer that actually runs your programs |
| **Node group** | A whole wing of identical classrooms | A set of nodes that share the same settings, built and replaced as a unit |
| **Pod** | A group project at one desk | The smallest unit Kubernetes runs — one or more containers that live and die together |
| **Namespace** | A grade level (7th grade, 8th grade) | A folder that keeps different teams' stuff separated |
| **DaemonSet** | "One hall monitor per classroom" | A rule that says: run exactly one copy of this pod on *every* node |
| **Deployment** | "I want 3 copies of this, always" | A rule that keeps N copies of a pod running |
| **Service** | The school's phone directory | A stable name + address for a group of pods that keep getting replaced |

### Why a *node group* and not just "a server"?

If you added servers one at a time by hand, you'd have to:
- pick an operating system image, and update it every month when a security patch lands
- install the Kubernetes agent (`kubelet`) on it
- tell it your cluster's address and give it credentials
- register it, and un-register it when you delete it

A **managed node group** does all of that for you. You describe what you want ("2 to 6 medium Linux machines"), and AWS creates an Auto Scaling Group behind the scenes, boots the machines from an EKS-optimized image, joins them to your cluster, and — when you ask for an update — drains and replaces them one at a time so nothing goes down.

Think of it as ordering "a wing of 4 identical classrooms, please keep them clean and repainted" instead of building each classroom brick by brick.

### The three tools you'll type commands into

| Tool | Talks to | Analogy |
|---|---|---|
| **`aws`** (AWS CLI) | Amazon's APIs | Talking to the **landlord** — "build me more classrooms" |
| **`kubectl`** | The Kubernetes API server | Talking to the **principal** — "what's happening in the school right now?" |
| **`helm`** | The Kubernetes API server, but in bulk | The **app store** — installs 40 related files with one command |

A **Helm chart** is a zip file of Kubernetes YAML templates with blanks in them. A **values file** is your answers to fill in the blanks. `helm install` = "take this template, fill it in with my answers, and send the result to the cluster."

### The three observability tools

Your school again:

- **Prometheus** is the **school nurse** who walks around every 30 seconds and writes down everyone's temperature and pulse. Numbers over time. That's a *metric*.
- **Loki** is the **school library archive** that stores everyone's diary entries. Text with a timestamp. That's a *log*.
- **Grafana** is the **big display wall** in the lobby that turns the nurse's clipboard and the library's diaries into charts anyone can read.
- **Grafana Alloy** is the **mail carrier**. It sits in every classroom, picks up the diary pages, and delivers them to the library. Logs don't walk to Loki by themselves — something has to carry them.

> ⚠️ **Important 2026 update:** The old mail carrier was called **Promtail**. Promtail reached end-of-life on **March 2, 2026**, and was removed from Loki entirely in version 3.7.3. Its code was merged into **Grafana Alloy**. If you find an older tutorial that installs Promtail, that tutorial is out of date. This guide uses Alloy.

### Metrics vs. logs — why you need both

| | Metrics (Prometheus) | Logs (Loki) |
|---|---|---|
| Answers | "**Is** something wrong?" | "**Why** is it wrong?" |
| Shape | Numbers on a timeline | Lines of text |
| Example | `http_requests_failed = 412` | `ERROR: could not connect to db, timeout after 30s` |
| Cost to store | Cheap (a number is tiny) | Expensive (text is big) |
| Good at | Alerting, dashboards, trends | Debugging one specific incident |

A metric tells you the building is on fire. A log tells you it started in the chemistry lab.

---

## 3. What you need before you start

### Software versions

Run these and check you're not on something ancient:

```bash
aws --version      # want v2.x   (v1 is deprecated — upgrade if you see "aws-cli/1.")
kubectl version --client
helm version       # want v3.x
```

Install or upgrade:

```bash
# AWS CLI v2 (Linux x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install --update

# kubectl — match your cluster's minor version, ±1 is fine
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm 3
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

> **kubectl version rule:** kubectl may be at most one minor version away from the cluster. A 1.34 kubectl works fine on a 1.35 cluster. A 1.28 kubectl on a 1.36 cluster will produce weird errors.

### Kubernetes versions currently on EKS (August 2026)

As of August 2026, EKS supports Kubernetes 1.36 as its newest available version, with 1.35, 1.34 and 1.33 also available. EKS gained 1.35 support in January 2026 and 1.36 support in June 2026. Older versions fall off standard support and get expensive — Amazon standard support lasts 14 months after a version's initial release in EKS, after which the version enters extended support, which costs several times more per cluster-hour.

> ⚠️ **Amazon Linux 2 is gone.** From EKS 1.33 onward, AL2 is no longer supported and new node groups default to **AL2023**. Use `--ami-type AL2023_x86_64_STANDARD`.

### Permissions you need

Your IAM user or role needs, at minimum:

- `eks:DescribeCluster`, `eks:CreateNodegroup`, `eks:DescribeNodegroup`, `eks:ListNodegroups`, `eks:CreateAddon`, `eks:CreatePodIdentityAssociation`
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole`
- `ec2:DescribeSubnets`, `ec2:DescribeSecurityGroups`
- `s3:CreateBucket` and friends
- Kubernetes-side admin on the cluster (see the access-entry note in Step 1)

### Set your variables once

Everything below uses these. Set them now and keep this shell open.

**File: `env.sh`**

```bash
#!/usr/bin/env bash
# Source this in every terminal you use:  source env.sh

export AWS_REGION="us-east-1"
export CLUSTER="demo-eks"                 # <-- your existing cluster name
export NODEGROUP="app-ng-1"
export NS="observability"                 # namespace for the whole stack

export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export NODE_ROLE_NAME="${CLUSTER}-nodegroup-role"
export NODE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}"

# S3 bucket names are globally unique across all of AWS, so we glue the
# account id on the end to avoid collisions with strangers.
export LOKI_BUCKET="loki-chunks-${CLUSTER}-${ACCOUNT_ID}"
export LOKI_ROLE_NAME="${CLUSTER}-loki-s3-role"
export EBS_ROLE_NAME="${CLUSTER}-ebs-csi-role"

echo "Account: $ACCOUNT_ID | Region: $AWS_REGION | Cluster: $CLUSTER"
```

```bash
chmod +x env.sh
source env.sh
```

---

# PART A — Do it once, step by step

## Step 1 — Log in to AWS and point at the right cluster

### 1a. Prove who you are

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "AIDA...",
    "Account": "111122223333",
    "Arn": "arn:aws:iam::111122223333:user/you"
}
```

**What this did:** asked AWS "who am I?" using whatever credentials are on this machine. If this fails, log in first:

```bash
# Option A — SSO (what most companies use now)
aws configure sso                       # first time only
aws sso login --profile my-profile
export AWS_PROFILE=my-profile

# Option B — long-lived access keys (fine for learning, avoid in production)
aws configure
```

### 1b. See which clusters exist

```bash
aws eks list-clusters --region "$AWS_REGION"
```

```json
{ "clusters": [ "demo-eks", "staging-eks" ] }
```

### 1c. ⭐ Point kubectl at the right cluster

**This is the command people forget.** It writes an entry into `~/.kube/config` describing how to reach the cluster and how to get a token for it.

```bash
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER" \
  --alias "$CLUSTER"
```

```
Added new context demo-eks to /home/you/.kube/config
```

The `--alias` flag is a small kindness to your future self: without it, the context is named the full ARN (`arn:aws:eks:us-east-1:111122223333:cluster/demo-eks`), which is horrible to type.

### 1d. ⭐ Confirm you're aimed at the right place

Run this **every single time** before you run something destructive:

```bash
kubectl config get-contexts          # * marks the active one
kubectl config use-context "$CLUSTER"
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
```

Expected:

```
demo-eks
Kubernetes control plane is running at https://ABC123.gr7.us-east-1.eks.amazonaws.com

NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-1-42.ec2.internal     Ready    <none>   9d    v1.36.1-eks-1b2c3d4
```

> 💡 **Make a safety habit.** Put this function in your `~/.bashrc`:
> ```bash
> whereami() {
>   echo "AWS : $(aws sts get-caller-identity --query Arn --output text)"
>   echo "K8s : $(kubectl config current-context)"
>   echo "NS  : $(kubectl config view --minify -o jsonpath='{..namespace}')"
> }
> ```
> Type `whereami` before anything scary. It has saved more production clusters than any tool.

### 1e. If `kubectl get nodes` says "Unauthorized"

Your AWS identity is valid but has no *Kubernetes* permissions. Modern EKS uses **access entries** (the old `aws-auth` ConfigMap is deprecated):

```bash
MY_ARN=$(aws sts get-caller-identity --query Arn --output text)

aws eks create-access-entry \
  --cluster-name "$CLUSTER" \
  --principal-arn "$MY_ARN" \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name "$CLUSTER" \
  --principal-arn "$MY_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

**In plain terms:** AWS IAM says *who you are*. Kubernetes RBAC says *what you may do inside the cluster*. Access entries are the bridge between the two. Being an AWS admin does not automatically make you a Kubernetes admin.

---

## Step 2 — Create the IAM role your nodes will wear

Every EC2 node needs an identity so it can pull container images from ECR, register with the cluster, and manage network interfaces.

**File: `node-trust-policy.json`**

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

**What a trust policy is:** a role is like a costume hanging in a closet. The trust policy is the sign on the closet saying *who is allowed to put this costume on*. Here it says "EC2 instances may wear this."

```bash
aws iam create-role \
  --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file://node-trust-policy.json \
  --description "Instance role for EKS managed nodes in $CLUSTER"

# The three permission sets a node needs:
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly

aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```

| Policy | Plain English |
|---|---|
| `AmazonEKSWorkerNodePolicy` | "You may knock on the cluster's door and say you belong here." |
| `AmazonEC2ContainerRegistryPullOnly` | "You may download container images from ECR — download only, no uploading." |
| `AmazonEKS_CNI_Policy` | "You may hand out IP addresses to pods on this machine." |

> 💡 **Best practice:** `AmazonEC2ContainerRegistryPullOnly` is newer and tighter than the older `AmazonEC2ContainerRegistryReadOnly`. Use it unless something breaks.
>
> 💡 **Advanced best practice:** the CNI policy is *broad*, and everything on the node inherits the node role. Production clusters move it off the node role and onto the `aws-node` service account using EKS Pod Identity instead. We keep it on the node role here for simplicity.

Verify:

```bash
aws iam list-attached-role-policies --role-name "$NODE_ROLE_NAME" --output table
```

---

## Step 3 — Find your subnets

Nodes live inside subnets — think of a **subnet as one neighborhood in one building of the city (Availability Zone)**. You want nodes in at least two zones so that losing one zone doesn't kill everything.

```bash
# Which subnets does the cluster itself know about?
aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output table

VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# List them with their AZ and whether they auto-assign public IPs
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

Pick **two private subnets in two different AZs** and save them:

```bash
export SUBNET_A="subnet-0aaa111bbb222ccc3"
export SUBNET_B="subnet-0ddd444eee555fff6"
```

> ⚠️ **Private subnets need a route out.** Nodes must reach the EKS API endpoint and pull container images. A private subnet with no NAT Gateway and no VPC endpoints will produce nodes that boot, sit there, and never join. If you see `NodeCreationFailure: Instances failed to join the kubernetes cluster`, this is the reason 80% of the time.
>
> ⚠️ **Subnet tags for load balancers.** If you'll later create LoadBalancer Services, private subnets need `kubernetes.io/role/internal-elb=1` and public subnets need `kubernetes.io/role/elb=1`.

---

## Step 4 — Create the managed node group

This is the main event.

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$SUBNET_A" "$SUBNET_B" \
  --scaling-config minSize=2,maxSize=6,desiredSize=2 \
  --instance-types m7i.large \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --disk-size 50 \
  --labels workload=general,environment=demo \
  --update-config maxUnavailablePercentage=33 \
  --node-repair-config enabled=true \
  --tags Owner=platform-team,Project=observability-demo \
  --region "$AWS_REGION"
```

### Every flag, explained

| Flag | What it means, plainly |
|---|---|
| `--cluster-name` | Which school gets the new wing |
| `--nodegroup-name` | The name on the door. Cannot be changed later. |
| `--node-role` | The costume the machines wear (Step 2) |
| `--subnets` | Which neighborhoods to build in. Two AZs = survives one AZ failure. |
| `--scaling-config` | `min` = never go below; `max` = ceiling the autoscaler may reach; `desired` = start here |
| `--instance-types` | The size of each machine. `m7i.large` = 2 vCPU, 8 GiB RAM. |
| `--ami-type` | Which operating system image. `AL2023_x86_64_STANDARD` is the current default. |
| `--capacity-type` | `ON_DEMAND` (reliable, full price) or `SPOT` (up to ~70–90% cheaper, can be taken back with 2 minutes' notice) |
| `--disk-size` | Root EBS volume in GiB. 20 is the default and it is **too small** — container images fill it fast. |
| `--labels` | Sticky notes on each node. Pods can then say "only schedule me on `workload=general`." |
| `--update-config` | During an upgrade, how many nodes may be offline at once. 33% = replace roughly a third at a time. |
| `--node-repair-config` | **Turn this on.** EKS watches for nodes that go unhealthy and automatically replaces them. |
| `--tags` | AWS-level tags for cost allocation. Different from Kubernetes labels! |

### Watch it build

```bash
# Poll the status yourself
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --query 'nodegroup.{Status:status,Health:health,Created:createdAt}' --output table

# Or just block until it's ready (usually 3–6 minutes)
aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"

echo "Node group is ACTIVE"
```

**What is happening behind the scenes while you wait:**

1. EKS creates an EC2 **Launch Template** describing the machine.
2. It creates an **Auto Scaling Group** using that template.
3. The ASG boots 2 instances from the AL2023 EKS-optimized AMI.
4. Each instance runs a bootstrap script that configures `kubelet` with your cluster's endpoint, CA certificate, and name.
5. `kubelet` registers with the control plane; the node appears as `NotReady`.
6. The VPC CNI plugin starts, attaches network interfaces, and claims IPs.
7. `kube-proxy` and CoreDNS pods land; the node flips to `Ready`.

---

## Step 5 — Re-point kubectl and verify the new nodes

⭐ **You asked for the "point at the right cluster" commands after the steps too — here they are.**

Adding a node group does not change your kubeconfig, but re-running this is harmless, takes one second, and guarantees you're looking at the right cluster:

```bash
source env.sh

aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER" --alias "$CLUSTER"
kubectl config use-context "$CLUSTER"
kubectl config current-context
```

Now confirm the new machines showed up:

```bash
kubectl get nodes -o wide
```

```
NAME                         STATUS   ROLES    AGE   VERSION               INSTANCE-TYPE
ip-10-0-1-42.ec2.internal    Ready    <none>   9d    v1.36.1-eks-1b2c3d4   t3.medium
ip-10-0-1-88.ec2.internal    Ready    <none>   2m    v1.36.1-eks-1b2c3d4   m7i.large   ← new
ip-10-0-2-31.ec2.internal    Ready    <none>   2m    v1.36.1-eks-1b2c3d4   m7i.large   ← new
```

More checks:

```bash
# Only the nodes from this node group
kubectl get nodes -l eks.amazonaws.com/nodegroup="$NODEGROUP"

# Did our custom label land?
kubectl get nodes -L workload,topology.kubernetes.io/zone,node.kubernetes.io/instance-type

# How much room is left?
kubectl top nodes            # needs metrics-server; kube-prometheus-stack does not install it

# Any node complaining?
kubectl describe node <node-name> | sed -n '/Conditions:/,/Addresses:/p'
```

### Everyday node group operations

```bash
# Scale up or down without recreating anything
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=2,maxSize=10,desiredSize=4

# Roll to the latest patched AMI (drains nodes one batch at a time)
aws eks update-nodegroup-version \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"

# Move a node's pods off it before maintenance
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node-name>

# List every node group on the cluster
aws eks list-nodegroups --cluster-name "$CLUSTER"
```

---

## Step 6 — Turn on the add-ons the stack needs

Prometheus, Grafana and Loki all want to save data to disk that survives a pod restart. On EKS that means EBS volumes, and **EKS does not ship a working default StorageClass**. This trips up almost everyone. Fix it now.

### 6a. Pod Identity agent

```bash
aws eks create-addon \
  --cluster-name "$CLUSTER" \
  --addon-name eks-pod-identity-agent

aws eks wait addon-active --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent
```

**What this is:** a tiny helper on every node that hands AWS credentials to specific pods. It's the modern replacement for the older, fiddlier "IRSA" method. EKS Pod Identity is a simpler method than IAM roles for service accounts, as this method doesn't use OIDC identity providers.

### 6b. EBS CSI driver + its permissions

```bash
# Role the driver will wear
cat > pod-identity-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": [ "sts:AssumeRole", "sts:TagSession" ]
    }
  ]
}
EOF

aws iam create-role --role-name "$EBS_ROLE_NAME" \
  --assume-role-policy-document file://pod-identity-trust.json

aws iam attach-role-policy --role-name "$EBS_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

aws eks create-addon \
  --cluster-name "$CLUSTER" \
  --addon-name aws-ebs-csi-driver

aws eks wait addon-active --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER" \
  --namespace kube-system \
  --service-account ebs-csi-controller-sa \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${EBS_ROLE_NAME}"

kubectl -n kube-system rollout restart deployment ebs-csi-controller
```

Note the trust policy needs **both** `sts:AssumeRole` and `sts:TagSession`. Leaving out `TagSession` is a classic silent failure.

### 6c. A gp3 StorageClass, set as default

**File: `gp3-storageclass.yaml`**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # create the disk in the same AZ as the pod
allowVolumeExpansion: true                # you can grow it later without recreating
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
  fsType: ext4
```

```bash
# If an old default exists, un-default it first
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  2>/dev/null || true

kubectl apply -f gp3-storageclass.yaml
kubectl get storageclass
```

```
NAME            PROVISIONER             DEFAULT   ALLOWVOLUMEEXPANSION
gp3 (default)   ebs.csi.aws.com         true      true
```

> **Why `WaitForFirstConsumer` matters:** EBS volumes are locked to one Availability Zone. If Kubernetes creates the disk in `us-east-1a` but then schedules the pod onto a node in `us-east-1b`, the pod can never start. `WaitForFirstConsumer` says "wait until you know where the pod is going, *then* make the disk there."

> **Why gp3 over gp2:** gp3 is roughly 20% cheaper per GB and lets you set IOPS and throughput independently of size.

---

## Step 7 — Create the S3 bucket and permissions for Loki

Loki keeps a small index and a large pile of compressed log "chunks." Storing those on EBS is expensive and doesn't scale. **S3 is the right home for them** — it's roughly 10x cheaper per GB and effectively infinite.

> ⚠️ **Do not use the chart's built-in MinIO.** The Loki chart's builtin MinIO dependency is deprecated and will be removed 2026-10-31, and setting `minio.enabled=true` now fails chart rendering unless you also set an override flag. Use real S3.

```bash
# Create the bucket (us-east-1 is special — it takes no LocationConstraint)
if [ "$AWS_REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$LOKI_BUCKET" --region us-east-1
else
  aws s3api create-bucket --bucket "$LOKI_BUCKET" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

# Lock the front door
aws s3api put-public-access-block --bucket "$LOKI_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Encrypt at rest
aws s3api put-bucket-encryption --bucket "$LOKI_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# Clean up abandoned multipart uploads so you stop paying for garbage
cat > loki-lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$LOKI_BUCKET" --lifecycle-configuration file://loki-lifecycle.json
```

> ⚠️ **Do not add an S3 expiration rule for the chunks themselves.** Loki's own compactor handles retention. If S3 deletes chunks that Loki's index still points at, queries return errors.

### The IAM policy Loki needs

**File: `loki-s3-policy.json`** (run the `envsubst` command below to fill in the bucket name)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListTheBucket",
      "Effect": "Allow",
      "Action": [ "s3:ListBucket" ],
      "Resource": "arn:aws:s3:::LOKI_BUCKET_NAME"
    },
    {
      "Sid": "ReadWriteObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::LOKI_BUCKET_NAME/*"
    }
  ]
}
```

Note the two separate statements: `ListBucket` acts on the **bucket** (no `/*`), while object actions act on the **things inside** it (`/*`). Getting this wrong is the #1 cause of `AccessDenied` in Loki.

```bash
sed -i "s|LOKI_BUCKET_NAME|${LOKI_BUCKET}|g" loki-s3-policy.json

aws iam create-role --role-name "$LOKI_ROLE_NAME" \
  --assume-role-policy-document file://pod-identity-trust.json

aws iam put-role-policy --role-name "$LOKI_ROLE_NAME" \
  --policy-name loki-s3-access \
  --policy-document file://loki-s3-policy.json
```

### Create the namespace and bind the role to Loki's service account

```bash
kubectl create namespace "$NS"

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER" \
  --namespace "$NS" \
  --service-account loki \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${LOKI_ROLE_NAME}"

# Confirm
aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --output table
```

**What just happened, in plain terms:** you told AWS "any pod in the `observability` namespace that uses the service account named `loki` should automatically receive credentials for this IAM role." No access keys, no secrets in YAML, no OIDC setup. The credentials rotate on their own.

---

## Step 8 — Add the Helm repositories

⭐ **Point at the right cluster one more time before installing anything.** Helm reads the same kubeconfig kubectl does — if your context is wrong, you will install a monitoring stack into the wrong cluster, and you will not enjoy finding out.

```bash
source env.sh
kubectl config use-context "$CLUSTER"
kubectl config current-context      # STOP and read this line
kubectl get nodes                   # sanity check
```

Now the repos:

```bash
# Prometheus + Grafana + Alertmanager, all in one chart
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Grafana Labs — for Alloy
helm repo add grafana https://grafana.github.io/helm-charts

# Loki now lives in the COMMUNITY repo, not the grafana one
helm repo add grafana-community https://grafana-community.github.io/helm-charts

helm repo update
```

> ⚠️ **This changed in 2026.** Effective March 16, 2026, the Grafana Loki Helm chart was forked to a new repository, grafana-community/helm-charts. The chart still in `grafana/loki` is maintained for Grafana Enterprise Logs customers only. If you install `grafana/loki` you'll get the old 6.x line. Use `grafana-community/loki` (chart 18.x).

Check what's available:

```bash
helm search repo kube-prometheus-stack --versions | head -5
helm search repo grafana-community/loki --versions | head -5
helm search repo grafana/alloy --versions | head -5

# Always worth a look before you install something with 4,000 settings
helm show values grafana-community/loki --version 18.7.6 > loki-all-values-reference.yaml
```

---

## Step 9 — Install Prometheus + Grafana

`kube-prometheus-stack` is the standard bundle. It bundles Prometheus, Grafana, Alertmanager, Node Exporter, kube-state-metrics, and the Prometheus Operator into a single Helm install.

**File: `prometheus-values.yaml`**

```yaml
# ---------------------------------------------------------------------------
# kube-prometheus-stack values
# Chart: prometheus-community/kube-prometheus-stack (88.x)
# ---------------------------------------------------------------------------

fullnameOverride: kps

# ===========================================================================
# PROMETHEUS — the thing that collects numbers
# ===========================================================================
prometheus:
  prometheusSpec:
    # How long to keep metrics. 15 days is a sane starting point.
    retention: 15d
    retentionSize: 45GB

    # ⭐ THE MOST IMPORTANT FOUR LINES IN THIS FILE ⭐
    # By default Prometheus only picks up ServiceMonitors created by THIS
    # Helm release. Setting these to false means "watch every namespace and
    # every ServiceMonitor, no matter who created it." Without this,
    # Prometheus will silently ignore Loki's and Alloy's metrics.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false

    # Where Prometheus stores its database
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

    resources:
      requests: { cpu: 300m, memory: 2Gi }
      limits:   { memory: 4Gi }          # no CPU limit on purpose — see notes

    # Add a "cluster" label to every metric so multi-cluster dashboards work
    externalLabels:
      cluster: demo-eks

# ===========================================================================
# GRAFANA — the thing that draws pictures
# ===========================================================================
grafana:
  enabled: true

  # For a demo. In production use `admin.existingSecret` instead. See notes.
  adminPassword: "ChangeMe-Please-123!"

  persistence:
    enabled: true
    storageClassName: gp3
    size: 10Gi

  # The sidecar watches the cluster for ConfigMaps with certain labels and
  # loads them into Grafana automatically. This is how we bolt Loki on
  # in Step 12 without touching this chart again.
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
    datasources:
      enabled: true
      label: grafana_datasource
      labelValue: "1"
      searchNamespace: ALL

  # Nice-to-have community dashboards, pulled from grafana.com by ID
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: community
          orgId: 1
          folder: Community
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/community
  dashboards:
    community:
      node-exporter-full:
        gnetId: 1860          # the classic node dashboard
        revision: 37
        datasource: Prometheus
      loki-logs:
        gnetId: 13639         # Loki log dashboard
        revision: 2
        datasource: Loki

  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 512Mi }

  grafana.ini:
    server:
      root_url: "http://localhost:3000"
    users:
      viewers_can_edit: true
    # Turn on the Explore > Logs experience
    feature_toggles:
      enable: "lokiLogsDataplane"

# ===========================================================================
# ALERTMANAGER — the thing that pages you at 3am
# ===========================================================================
alertmanager:
  enabled: true
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests: { storage: 5Gi }

# ===========================================================================
# EXPORTERS — the little agents that produce the numbers
# ===========================================================================
nodeExporter:
  enabled: true                # one per node: CPU, RAM, disk, network
kubeStateMetrics:
  enabled: true                # counts of deployments, pods, restarts, etc.

# ===========================================================================
# EKS-SPECIFIC: AWS runs the control plane, so we cannot scrape it.
# Leaving these on produces permanently-red targets and confusing alerts.
# ===========================================================================
kubeEtcd:
  enabled: false
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: true                # this one IS reachable on EKS
```

Install it:

```bash
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace "$NS" \
  --create-namespace \
  -f prometheus-values.yaml \
  --wait --timeout 15m
```

`upgrade --install` means "install if it's new, upgrade if it exists." Use it always — it's safe to re-run.

Watch it come up:

```bash
kubectl get pods -n "$NS" -w        # Ctrl-C when everything is Running
kubectl get pvc -n "$NS"            # all should say Bound, not Pending
```

```
NAME                                   READY   STATUS    RESTARTS   AGE
alertmanager-kps-alertmanager-0        2/2     Running   0          2m
kps-grafana-7d9f8c6b4-x2klm            3/3     Running   0          2m
kps-kube-state-metrics-6b8d-abc12      1/1     Running   0          2m
kps-operator-5f7c9d8b6-qq4mn           1/1     Running   0          2m
kps-prometheus-node-exporter-4xk9p     1/1     Running   0          2m
kps-prometheus-node-exporter-p2n8v     1/1     Running   0          2m
prometheus-kps-prometheus-0            2/2     Running   0          2m
```

> **If PVCs stay `Pending`:** your StorageClass isn't working. Go back to Step 6 and check `kubectl get sc` and `kubectl -n kube-system logs deploy/ebs-csi-controller`.

---

## Step 10 — Install Loki

**File: `loki-values.yaml`** — replace `BUCKET_NAME_HERE` and `REGION_HERE` (a `sed` command follows).

```yaml
# ---------------------------------------------------------------------------
# Loki values
# Chart: grafana-community/loki (18.x)  — NOT grafana/loki
# ---------------------------------------------------------------------------

# "Monolithic" = everything in one process. Simple, and fine well past 100 GB/day.
# It was called "SingleBinary" before chart 12.0 and is now the chart default.
deploymentMode: Monolithic

loki:
  # false = one shared tenant. Turn on only if you need hard multi-team isolation.
  auth_enabled: false

  # ---- How data is laid out on disk/S3 ----
  # v13 + tsdb is the current recommended combination. The "from" date must be
  # in the past; never edit an existing entry — add a NEW one with a future date.
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  # ---- Where the data goes ----
  # No accessKey/secretKey! EKS Pod Identity injects credentials at runtime.
  storage:
    type: s3
    bucketNames:
      chunks: BUCKET_NAME_HERE
      ruler: BUCKET_NAME_HERE
      admin: BUCKET_NAME_HERE
    s3:
      region: REGION_HERE
      s3forcepathstyle: false

  limits_config:
    retention_period: 720h            # 30 days
    volume_enabled: true              # enables the Logs Volume histogram in Grafana
    max_query_series: 5000
    reject_old_samples: true
    reject_old_samples_max_age: 168h
    allow_structured_metadata: true
    ingestion_rate_mb: 10             # per tenant, per second
    ingestion_burst_size_mb: 20
    max_cache_freshness_per_query: 10m
    split_queries_by_interval: 15m

  compactor:
    retention_enabled: true           # ⭐ without this, retention_period does NOTHING
    delete_request_store: s3
    working_directory: /var/loki/compactor
    retention_delete_delay: 2h

  querier:
    max_concurrent: 4

  server:
    http_listen_port: 3100
    grpc_server_max_recv_msg_size: 33554432
    grpc_server_max_send_msg_size: 33554432

# ---- The service account Pod Identity is bound to (Step 7) ----
serviceAccount:
  create: true
  name: loki                          # MUST match --service-account in Step 7

# ---- The single Loki process ----
singleBinary:
  replicas: 1                         # use 3 for HA; requires memberlist ring
  persistence:
    enabled: true
    storageClass: gp3
    size: 20Gi                        # working space only — real data is in S3
  resources:
    requests: { cpu: 300m, memory: 1Gi }
    limits:   { memory: 3Gi }

# ---- Caches: DISABLED for a small cluster ----
# ⚠️ These default to ON and each requests ~8 GiB of memory. On a two-node
# demo cluster they will sit Pending forever and you will be very confused.
# Turn them back on for production.
chunksCache:
  enabled: false
resultsCache:
  enabled: false

# ---- The nginx front door that fans requests to the right component ----
gateway:
  enabled: true
  replicas: 1

# ---- Let Prometheus scrape Loki's own health metrics ----
monitoring:
  serviceMonitor:
    enabled: true
    labels:
      release: kps                    # tidy; our selectors are open anyway
  rules:
    enabled: true                     # recording rules
  alerts:
    enabled: true                     # alert rules (split from rules in 18.0)

# ---- Extras we don't need for a first install ----
lokiCanary:
  enabled: false                      # a synthetic log generator for self-testing
test:
  enabled: false
minio:
  enabled: false                      # deprecated; we use real S3
```

Fill in the placeholders and install:

```bash
sed -i "s|BUCKET_NAME_HERE|${LOKI_BUCKET}|g; s|REGION_HERE|${AWS_REGION}|g" loki-values.yaml
grep -n "BUCKET_NAME_HERE\|REGION_HERE" loki-values.yaml   # should print nothing

# Dry run first — this renders the templates without touching the cluster
helm upgrade --install loki grafana-community/loki \
  --namespace "$NS" \
  --version 18.7.6 \
  -f loki-values.yaml \
  --dry-run --debug > /tmp/loki-rendered.yaml
echo "Rendered OK — $(wc -l < /tmp/loki-rendered.yaml) lines"

# For real
helm upgrade --install loki grafana-community/loki \
  --namespace "$NS" \
  --version 18.7.6 \
  -f loki-values.yaml \
  --wait --timeout 10m
```

Verify:

```bash
kubectl get pods -n "$NS" -l app.kubernetes.io/name=loki
kubectl get svc  -n "$NS" | grep loki

# ⭐ Note the exact service names — you need them in Step 11 and 12
```

```
NAME                TYPE        CLUSTER-IP       PORT(S)
loki                ClusterIP   172.20.14.201    3100/TCP,9095/TCP
loki-gateway        ClusterIP   172.20.155.33    80/TCP
loki-headless       ClusterIP   None             3100/TCP
loki-memberlist     ClusterIP   None             7946/TCP
```

Prove Loki is alive and can see S3:

```bash
kubectl -n "$NS" logs -l app.kubernetes.io/name=loki --tail=40

# Should say "ready"
kubectl -n "$NS" run curl-test --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s http://loki-gateway.observability.svc.cluster.local/ready

# Confirm the pod really got AWS credentials from Pod Identity
kubectl -n "$NS" exec -it loki-0 -- env | grep AWS_
```

You should see `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`. If those are missing, the Pod Identity association didn't take — check the service account name matches exactly, then `kubectl -n $NS rollout restart statefulset loki`.

---

## Step 11 — Install Grafana Alloy (the log courier)

Loki is a warehouse. Nothing is in it yet. Alloy is the truck.

**File: `alloy-values.yaml`**

```yaml
# ---------------------------------------------------------------------------
# Grafana Alloy — runs one pod per node, tails container logs, ships to Loki
# Chart: grafana/alloy
# ---------------------------------------------------------------------------

controller:
  type: daemonset                     # one per node, including future nodes

alloy:
  # Alloy needs to read the pod log files on the host
  mounts:
    varlog: true
    dockercontainers: true

  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 512Mi }

  # ---- The pipeline itself, in Alloy's configuration language ----
  configMap:
    create: true
    content: |-
      // ==================================================================
      // 1. DISCOVER — ask the Kubernetes API for every pod in the cluster
      // ==================================================================
      discovery.kubernetes "pods" {
        role = "pod"
      }

      // ==================================================================
      // 2. LABEL — turn Kubernetes metadata into Loki labels.
      //    ⚠️ Keep this list SHORT. Every unique label combination creates
      //    a separate stream in Loki. High-cardinality labels (pod IDs,
      //    request IDs, user IDs) will destroy performance and cost.
      // ==================================================================
      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_node_name"]
          target_label  = "node"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace",
                           "__meta_kubernetes_pod_label_app_kubernetes_io_name"]
          separator     = "/"
          target_label  = "job"
        }
      }

      // ==================================================================
      // 3. READ — tail the logs of every discovered container
      // ==================================================================
      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.process.enrich.receiver]
      }

      // ==================================================================
      // 4. PROCESS — stamp every line with the cluster name, and drop
      //    the noisiest health-check lines to save money
      // ==================================================================
      loki.process "enrich" {
        stage.static_labels {
          values = {
            cluster = "demo-eks",
          }
        }

        stage.drop {
          expression = ".*(kube-probe|health|/healthz|ELB-HealthChecker).*"
          drop_counter_reason = "healthcheck_noise"
        }

        forward_to = [loki.write.default.receiver]
      }

      // ==================================================================
      // 5. WRITE — push to Loki through its gateway service
      // ==================================================================
      loki.write "default" {
        endpoint {
          url = "http://loki-gateway.observability.svc.cluster.local/loki/api/v1/push"
        }
        external_labels = {}
      }

      // ==================================================================
      // 6. SELF-MONITOR — expose Alloy's own health so Prometheus sees it
      // ==================================================================
      logging {
        level  = "info"
        format = "logfmt"
      }

rbac:
  create: true                        # Alloy must be allowed to list pods

# Let Prometheus scrape Alloy's own metrics
serviceMonitor:
  enabled: true
  additionalLabels:
    release: kps
```

```bash
helm upgrade --install alloy grafana/alloy \
  --namespace "$NS" \
  -f alloy-values.yaml \
  --wait --timeout 5m
```

Verify — you should see exactly one Alloy pod per node:

```bash
kubectl get pods -n "$NS" -l app.kubernetes.io/name=alloy -o wide
kubectl get nodes --no-headers | wc -l         # same number

kubectl -n "$NS" logs -l app.kubernetes.io/name=alloy --tail=30
```

Look for lines mentioning `loki.write` and no repeated connection errors. If you see `connection refused`, the Loki service name in the config is wrong — go back and compare it with the `kubectl get svc` output from Step 10.

> 💡 **Alloy has a built-in web UI** that draws your pipeline as a live graph. Great for debugging:
> ```bash
> kubectl -n "$NS" port-forward daemonset/alloy 12345:12345
> # open http://localhost:12345
> ```

---

## Step 12 — Wire Loki into Grafana

Grafana already knows about Prometheus (its own chart set that up). It does not know about Loki. We tell it using a ConfigMap that the Grafana sidecar will find and load automatically — no `helm upgrade` needed.

**File: `loki-datasource.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: observability
  labels:
    grafana_datasource: "1"        # ⭐ this label is what makes the sidecar notice it
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        uid: loki
        url: http://loki-gateway.observability.svc.cluster.local
        isDefault: false
        editable: true
        jsonData:
          timeout: 60
          maxLines: 1000
          # ---- The magic that connects logs back to metrics ----
          # Click a trace/pod in a log line and jump to its metrics.
          derivedFields:
            - name: TraceID
              matcherRegex: "trace_id=(\\w+)"
              url: "$${__value.raw}"
              datasourceUid: prometheus
```

```bash
kubectl apply -f loki-datasource.yaml

# The sidecar picks it up within ~60 seconds. Watch it happen:
kubectl -n "$NS" logs -l app.kubernetes.io/name=grafana -c grafana-sc-datasources --tail=20
```

You should see a line about writing `loki-datasource.yaml`.

> **Why a ConfigMap instead of editing `prometheus-values.yaml`?** Because it decouples the two charts. You can uninstall and reinstall Loki, or add Tempo later, without ever touching the Prometheus release. This is the pattern real platform teams use.

### Now the three tools are connected. Here's the full wiring:

```
   Alloy ──logs──▶ Loki ──stores──▶ S3
     │              │
     │ metrics      │ metrics
     ▼              ▼
   Prometheus ◀── kube-state-metrics, node-exporter, kubelet
     │
     │ (datasource: auto-configured by kube-prometheus-stack)
     ▼
   GRAFANA ◀── (datasource: our ConfigMap) ── Loki
```

Every arrow is now real:
1. **Alloy → Loki**: `loki.write` endpoint in `alloy-values.yaml`
2. **Loki → S3**: `loki.storage` + Pod Identity
3. **Prometheus → Loki/Alloy**: their `ServiceMonitor`s + our `serviceMonitorSelectorNilUsesHelmValues: false`
4. **Grafana → Prometheus**: automatic, same chart
5. **Grafana → Loki**: the ConfigMap in this step

---

## Step 13 — Open Grafana and prove it all works

```bash
# Get the admin password (do this even if you set it — proves the secret exists)
kubectl get secret kps-grafana -n "$NS" \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# Open a tunnel
kubectl port-forward -n "$NS" svc/kps-grafana 3000:80
```

Browse to **http://localhost:3000** — user `admin`, password from above.

### Test 1 — Are both datasources healthy?

**Connections → Data sources.** Click **Prometheus**, scroll down, **Save & test** → green. Repeat for **Loki** → green.

### Test 2 — Do metrics work?

**Explore → Prometheus.** Paste:

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="observability"}[5m])) by (pod)
```

You should see lines. More useful queries:

```promql
# Nodes that exist, by node group
count(kube_node_info) by (node)

# Memory used vs. requested, per pod
sum(container_memory_working_set_bytes{namespace!=""}) by (namespace)

# Pods that keep crashing
sum(increase(kube_pod_container_status_restarts_total[1h])) by (namespace, pod) > 0

# Is Loki healthy?
rate(loki_distributor_bytes_received_total[5m])
```

### Test 3 — Do logs work?

**Explore → Loki.** Try:

```logql
{namespace="observability"}
```

Then:

```logql
# Only Loki's own logs
{namespace="observability", container="loki"}

# Errors anywhere, case-insensitive
{namespace=~".+"} |~ "(?i)error"

# Count errors per namespace over 5 minutes — a metric made FROM logs
sum by (namespace) (count_over_time({namespace=~".+"} |~ "(?i)error" [5m]))

# Parse JSON logs and filter on a field
{namespace="observability"} | json | level="error"
```

### Test 4 — Generate a log on purpose and watch it arrive

```bash
kubectl create deployment log-maker --image=busybox -n default -- \
  /bin/sh -c 'i=0; while true; do echo "hello from the tutorial line=$i"; i=$((i+1)); sleep 2; done'

kubectl get pods -n default -w
```

Then in Grafana Explore:

```logql
{namespace="default", container="busybox"} |= "hello from the tutorial"
```

Within ~15 seconds you should see lines streaming in. **This is the moment the whole pipeline is proven end-to-end:** container → Alloy → Loki → S3 → Grafana.

Clean up the test:

```bash
kubectl delete deployment log-maker -n default
```

### Test 5 — Confirm data really landed in S3

```bash
aws s3 ls "s3://${LOKI_BUCKET}/" --recursive --human-readable --summarize | tail -20
```

You should see objects under a `loki_index_.../` prefix and a `fake/` prefix (the "fake" tenant is what Loki calls the single tenant when `auth_enabled: false` — it's normal, not a bug).

### Test 6 — Is Prometheus scraping Loki and Alloy?

```bash
kubectl port-forward -n "$NS" svc/kps-prometheus 9090:9090
```

Open **http://localhost:9090/targets** and search for `loki` and `alloy`. Both should be **UP**. If they're missing entirely, you forgot `serviceMonitorSelectorNilUsesHelmValues: false`.

**🎉 That's the whole thing built.** Everything below is background, options, and the details you'll want when this stops being a demo.

---

# PART B — All the details and background

## 17. The complete file tree

Everything you created, in one place:

```
eks-observability/
├── env.sh                      # variables — source this in every shell
│
├── STEP 2 — node group IAM
│   └── node-trust-policy.json  # "EC2 may wear this costume"
│
├── STEP 6 — storage
│   ├── pod-identity-trust.json # "EKS Pod Identity may wear this costume"
│   └── gp3-storageclass.yaml   # default StorageClass, encrypted, expandable
│
├── STEP 7 — Loki's S3
│   ├── loki-lifecycle.json     # abort abandoned multipart uploads after 7d
│   └── loki-s3-policy.json     # least-privilege bucket access
│
├── STEP 9 — metrics
│   └── prometheus-values.yaml  # kube-prometheus-stack config
│
├── STEP 10 — logs storage
│   └── loki-values.yaml        # Loki config (S3, retention, schema)
│
├── STEP 11 — log shipping
│   └── alloy-values.yaml       # DaemonSet + the Alloy pipeline
│
└── STEP 12 — wiring
    └── loki-datasource.yaml    # ConfigMap the Grafana sidecar auto-loads
```

**Put this directory in Git.** Every one of these files is the source of truth for a piece of live infrastructure. If you only have them on your laptop, you have a time bomb.

A one-shot script that runs the whole thing:

**File: `install-all.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail          # stop on the first error, catch unset variables

source ./env.sh

echo "=== Confirming context ==="
kubectl config use-context "$CLUSTER"
kubectl config current-context
kubectl get nodes

echo "=== Prometheus + Grafana ==="
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n "$NS" --create-namespace -f prometheus-values.yaml --wait --timeout 15m

echo "=== Loki ==="
helm upgrade --install loki grafana-community/loki \
  -n "$NS" --version 18.7.6 -f loki-values.yaml --wait --timeout 10m

echo "=== Alloy ==="
helm upgrade --install alloy grafana/alloy \
  -n "$NS" -f alloy-values.yaml --wait --timeout 5m

echo "=== Grafana datasource ==="
kubectl apply -f loki-datasource.yaml

echo "=== Done ==="
kubectl get pods -n "$NS"
```

---

## 18. Deep background: how each piece actually works

### 18.1 What a managed node group really is, underneath

When you run `create-nodegroup`, EKS builds three AWS objects and keeps them in sync:

```
   aws eks create-nodegroup
            │
            ├──▶ EC2 Launch Template
            │      (AMI id, instance type, disk size, user-data bootstrap script,
            │       security groups, IMDSv2 settings, tags)
            │
            ├──▶ Auto Scaling Group
            │      (min/max/desired, which subnets, which launch template version)
            │
            └──▶ Nodegroup record in the EKS control plane
                   (health status, labels, taints, update strategy)
```

The **user-data** script on each instance is what actually joins the node. On AL2023 it's a `nodeadm` YAML config that tells `kubelet`:
- the cluster's API endpoint (`https://XXXX.gr7.us-east-1.eks.amazonaws.com`)
- the cluster's CA certificate, so it can verify it's talking to the right server
- the cluster name and CIDR
- node labels and taints to register with

Then `kubelet` uses the node's IAM role, via the EC2 Instance Metadata Service, to get a token and register.

**Why updates are safe:** when you run `update-nodegroup-version`, EKS creates a *new* launch template version, then does a rolling replacement respecting your `maxUnavailable` setting and any PodDisruptionBudgets you've defined. It cordons a node, drains it, waits, terminates it, and lets the ASG launch a replacement from the new template.

### 18.2 Node group labels vs. taints vs. tags

Three similar-sounding things people constantly mix up:

| | Where it lives | What it does | Example |
|---|---|---|---|
| **Kubernetes label** | On the Node object | *Attracts* pods. Pods opt in via `nodeSelector`. | `workload=general` |
| **Kubernetes taint** | On the Node object | *Repels* pods. Pods must have a matching `toleration` to land. | `dedicated=gpu:NoSchedule` |
| **AWS tag** | On the EC2 instance / ASG | Billing, automation, and search. Kubernetes never sees it. | `CostCenter=eng-1234` |

Labels say "you may come here." Taints say "stay away unless you have a permission slip." Use taints for expensive or special hardware so ordinary pods don't squat on your GPU nodes.

```bash
# Create a tainted GPU node group
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name gpu-ng \
  --node-role "$NODE_ROLE_ARN" --subnets "$SUBNET_A" \
  --instance-types g5.xlarge \
  --ami-type AL2023_x86_64_NVIDIA \
  --scaling-config minSize=0,maxSize=4,desiredSize=0 \
  --labels workload=gpu \
  --taints key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE
```

### 18.3 How Prometheus discovers things

Prometheus does **not** get told about your services. It goes looking. That's called *service discovery*, and in Kubernetes it works through a custom resource called a **ServiceMonitor**:

```
1. Loki's Helm chart creates a ServiceMonitor object saying:
      "scrape any Service with label app.kubernetes.io/name=loki,
       on port http-metrics, at path /metrics, every 30s"

2. The Prometheus OPERATOR (a controller from kube-prometheus-stack)
   watches for ServiceMonitor objects.

3. When it finds one, it regenerates Prometheus's config file
   and reloads Prometheus — no restart, no manual editing.

4. Prometheus starts hitting http://loki:3100/metrics every 30 seconds
   and storing whatever numbers come back.
```

**This is why `serviceMonitorSelectorNilUsesHelmValues: false` matters so much.** By default the operator only trusts ServiceMonitors that carry a `release: kps` label — the ones its own chart made. Setting the flag to `false` tells it "trust everything, everywhere." For a single-team cluster that's what you want. For a large multi-team cluster you'd instead set an explicit `serviceMonitorSelector` and require teams to label their monitors correctly.

### 18.4 How Loki is different from Elasticsearch (and why it's cheap)

The classic log system (Elasticsearch, Splunk) does a **full-text index**: it reads every word of every log line and builds a giant searchable dictionary. That's why search is instant — and why it costs a fortune in CPU and disk.

Loki does something deliberately lazier:

```
   A log line arrives:
     {namespace="prod", app="checkout", pod="checkout-7f8-x2k"}
     "2026-08-24T10:15:02Z ERROR payment declined for order 88213"
          │                                  │
          ▼                                  ▼
     INDEXED (tiny)                    NOT INDEXED (compressed blob)
     Only the labels in {}             The actual text
     go into the index.                goes into a "chunk" in S3.
```

To search, Loki uses the labels to narrow down to a handful of chunks, pulls those from S3, decompresses them, and **greps** through them in parallel. It's brute force — but brute force over 200 MB is fast and cheap, while indexing 200 GB is neither.

**The practical consequence:** *labels are precious, log content is free.*

```logql
{app="checkout"} |= "order 88213"     ← GOOD. One label, then grep.
{order_id="88213"}                    ← DISASTER. A label per order = millions
                                        of streams. This is called a
                                        "cardinality explosion" and it will
                                        take Loki down.
```

**Rule of thumb: fewer than ~10 label values per label, and fewer than about 10–15 labels total.** Never label with: user IDs, request IDs, trace IDs, timestamps, IP addresses, URLs with parameters, or anything unbounded.

### 18.5 Loki's storage layout, and the schema config

```
S3 bucket
├── fake/                          ← the tenant. "fake" = the single tenant
│   ├── 01J8XK.../                   when auth_enabled: false. Normal.
│   │   └── <compressed chunks>
│   └── ...
└── loki_index_19962/              ← index files, one per 24h period
    └── ...
```

The `schemaConfig` block is the single most dangerous part of `loki-values.yaml`:

```yaml
schemaConfig:
  configs:
    - from: "2024-04-01"
      store: tsdb
      object_store: s3
      schema: v13
```

- **Never edit an existing entry.** Loki uses the `from` date to know which format to read old data with. Change it and old logs become unreadable.
- **To change format, append a new entry with a future date:**
  ```yaml
    - from: "2024-04-01"     # existing, untouched
      schema: v13
      ...
    - from: "2026-09-01"     # new; tomorrow or later
      schema: v14
      ...
  ```
- `v13` + `tsdb` is the current recommended combination.

### 18.6 Retention: two settings that must agree

```yaml
loki:
  limits_config:
    retention_period: 720h      # "delete logs older than 30 days"
  compactor:
    retention_enabled: true     # "...and actually mean it"
```

**If `retention_enabled` is false, `retention_period` does nothing at all** and your S3 bill grows forever. This catches an enormous number of people. The compactor is a background process that merges index files and, when retention is on, marks old chunks for deletion.

Per-team retention is possible with `overrides`:

```yaml
loki:
  structuredConfig:
    limits_config:
      retention_period: 720h
      retention_stream:
        - selector: '{namespace="prod"}'
          priority: 1
          period: 2160h            # prod keeps 90 days
        - selector: '{namespace="dev"}'
          priority: 2
          period: 168h             # dev keeps 7 days
```

### 18.7 EKS Pod Identity vs. IRSA — what changed

Both solve the same problem: *how does a pod get AWS credentials without you pasting an access key into a YAML file?*

**IRSA (2019, still fully supported)** works through OpenID Connect. Your cluster publishes an OIDC identity document; you register that document as an identity provider in IAM; each IAM role's trust policy names your specific cluster's OIDC URL and service account. It works everywhere, including outside AWS — but a role's trust policy is tied to one cluster, so ten clusters means ten trust policies to maintain.

**Pod Identity (2023, now the default recommendation for EC2-based EKS)** replaces all that with an AWS-managed agent. You create the IAM role once with no cluster-specific trust, then create one association per cluster with a single CLI command — adding a fourth cluster takes one command with no IAM policy editing.

| | IRSA | Pod Identity |
|---|---|---|
| Setup | OIDC provider + per-cluster trust policy | Install one add-on |
| Role reuse across clusters | ❌ each cluster needs its own trust entry | ✅ one role, N associations |
| Works on Fargate | ✅ | ❌ |
| Works on EKS Anywhere / self-managed | ✅ | ❌ (EKS-in-the-cloud only) |
| Works on Windows nodes | ✅ | ❌ |
| Cross-account | Possible, awkward | Supported and cleaner |
| Session tags for ABAC | Manual | Automatic |

Choose Pod Identity for new standard Linux EC2 clusters, complex multi-cluster topologies, or heavy cross-account service paths; stick with IRSA if your footprint depends on Fargate profiles, Windows nodes, or hybrid topologies like EKS Anywhere. Mixing both in one cluster is supported — if a role trusts both, Pod Identity wins.

### 18.8 Why Promtail is gone

Promtail reached end of life on March 2, 2026. Commercial support has ended, no future support or updates will be provided, and all future feature development happens in Grafana Alloy. It was deprecated in Loki 3.0 and removed entirely as of Loki 3.7.3.

The reason is consolidation. Grafana was maintaining separate collectors for logs (Promtail), metrics (Grafana Agent), traces, and profiles. Alloy is their distribution of the OpenTelemetry Collector, and everything was folded into it.

Practical differences when you migrate:
- Config language changes from YAML to Alloy's component syntax (there's an automated converter: `alloy convert --source-format=promtail`)
- Alloy exposes different internal metric names, so Promtail dashboards need updating
- Alloy can also scrape Prometheus metrics, receive OTLP, and handle traces — one agent instead of three

---

## 19. Options, pros and cons

### 19.1 How to get compute into an EKS cluster

| Option | How it works | Pros | Cons | Choose when |
|---|---|---|---|---|
| **Managed node group** *(this guide)* | You declare instance types + min/max; AWS runs the ASG | Predictable; explicit control of AMI, disk, kernel params; free (pay only EC2); easy to reason about | You pick instance types; slower scaling (3–4 min); one instance family per group means many groups | Learning; steady predictable workloads; regulated environments where you must own every layer |
| **Self-managed Karpenter** | A controller watches for unschedulable pods and calls the EC2 API directly | Brings nodes online in 45–60 seconds vs. 3–4 minutes for ASG-based scaling; bin-packs and consolidates; native Spot with on-demand fallback | You run and upgrade the controller; a learning curve of a day or two | Bursty workloads; cost-sensitive fleets; you have platform engineers |
| **EKS Auto Mode** | AWS runs Karpenter for you, on Bottlerocket, with add-ons preinstalled | Least operational work; automatic AMI rotation; respects PDBs on upgrade | ~12% management surcharge per node; no custom AMIs; no host access; less visibility | Small teams; greenfield; "just make it work" |
| **Fargate** | One micro-VM per pod, no nodes at all | Zero node management; strong isolation | No DaemonSets (so **no Alloy, no node-exporter**); pricier per vCPU; slower cold start | Isolated batch jobs; not a fit for this observability stack |
| **Self-managed EC2 / ASG** | You build everything | Total control | You own AMIs, bootstrap, upgrades, draining | Very unusual requirements only |

For most AWS-native teams in 2026, Karpenter (or EKS Auto Mode) is the better default; for multi-cloud environments, Cluster Autoscaler with node groups remains the more consistent choice.

A common production pattern combines them: a **small on-demand managed node group** for critical add-ons (CoreDNS, the Karpenter controller itself, monitoring), and **Karpenter with Spot** for application workloads. Cluster add-ons stay stable; apps get cheap.

### 19.2 On-Demand vs. Spot vs. Reserved

| | On-Demand | Spot | Savings Plan / RI |
|---|---|---|---|
| Price | Baseline | ~70–90% off | ~30–50% off |
| Can be taken away | No | Yes, 2-minute warning | No |
| Best for | Databases, stateful apps, cluster add-ons | Stateless web, batch, CI, dev | Your steady baseline |

Spot best practices: use several instance types per node group so you're not dependent on one pool going scarce; use `capacity-optimized` allocation; run the AWS Node Termination Handler (or Karpenter, which handles it natively); and never run stateful singletons on Spot.

### 19.3 Loki deployment modes

| Mode | Processes | Handles | Complexity |
|---|---|---|---|
| **Monolithic** *(this guide, and the chart default since v12)* | 1 binary, all roles | comfortably up to ~100 GB/day | Low |
| **SimpleScalable** | read / write / backend split | up to ~1 TB/day | Medium — **but deprecated, removed in Loki 4.0** |
| **Distributed** | ~10 separate microservices | many TB/day | High |

Start Monolithic. Move to Distributed only when you've measured a real bottleneck. Note that SimpleScalable is deprecated and will be removed in Loki 4.0 — plan to migrate to Monolithic or Distributed.

### 19.4 Which monitoring chart?

| Option | Pros | Cons |
|---|---|---|
| **kube-prometheus-stack** *(this guide)* | Community standard; everything in one chart; hundreds of prebuilt dashboards and alerts; fully self-hosted | Big and opinionated; CRD upgrades need manual `kubectl apply` |
| **Grafana k8s-monitoring chart** | Grafana Labs released version 4 in April 2026, described as the most significant update since the chart's introduction; sends metrics, logs, traces and profiles from one place | Designed primarily for shipping *to* Grafana Cloud |
| **Amazon Managed Prometheus + Managed Grafana** | AWS runs it; no storage to babysit; scales without thought | Per-sample pricing gets expensive; less customizable; still need collectors |
| **Datadog / New Relic** | Polished; support contract | Expensive at scale; vendor lock-in |

### 19.5 Log collectors

| Collector | Pros | Cons |
|---|---|---|
| **Grafana Alloy** *(this guide)* | Actively developed; one agent for logs + metrics + traces; OTLP native; live pipeline UI | Newer config language to learn |
| **Promtail** | Simple, familiar | ☠️ **EOL March 2026, removed from Loki 3.7.3.** Do not start here. |
| **Fluent Bit** | Very low memory; huge ecosystem of outputs | Separate config language; less Loki-native |
| **OpenTelemetry Collector** | Vendor-neutral standard | More config; Loki has a native OTLP endpoint but the mapping needs care |

---

## 20. Best practices checklist

### Node groups
- ✅ Spread across **at least two Availability Zones**
- ✅ Use **AL2023** — AL2 is unsupported from EKS 1.33
- ✅ Set `--disk-size 50` or more; the 20 GiB default fills up
- ✅ Turn on `--node-repair-config enabled=true`
- ✅ Use `--update-config maxUnavailablePercentage=33` rather than replacing everything at once
- ✅ Separate node groups by *purpose* (system / general / gpu / spot), not by whim
- ✅ Define **PodDisruptionBudgets** for anything important, or node upgrades will happily take all your replicas down at once
- ✅ Enforce IMDSv2 (`HttpTokens=required`) via a launch template
- ✅ `minSize` ≥ 2 for anything you care about
- ❌ Don't put the CNI policy on the node role in production — use Pod Identity for `aws-node`
- ❌ Don't run stateful workloads on Spot

### Kubectl safety
- ✅ Use `--alias` on `update-kubeconfig`
- ✅ Run `kubectl config current-context` before anything destructive
- ✅ Install `kubectx`/`kubens`, or add the `whereami` function from Step 1
- ✅ Add the context name to your shell prompt (`kube-ps1`) — red for prod
- ✅ Use `--dry-run=client -o yaml` to preview
- ✅ Use separate AWS profiles per environment so a stale token fails loudly

### Helm
- ✅ **Pin chart versions** (`--version 18.7.6`). Unpinned installs are irreproducible.
- ✅ Always `helm upgrade --install`, never bare `helm install`
- ✅ Keep values files in Git; never use long chains of `--set`
- ✅ `helm diff upgrade` (from the helm-diff plugin) before production changes
- ✅ `helm rollback <release> <revision>` exists — know it before you need it
- ✅ Read the chart's `UPGRADING.md` before crossing a major version
- ⚠️ Helm does **not** upgrade CRDs on `helm upgrade`. For kube-prometheus-stack major versions you must `kubectl apply --server-side` the new CRDs manually first.

### Prometheus
- ✅ Set retention by both time and size
- ✅ Give it a PVC on gp3
- ✅ Set memory **requests and limits**, but **no CPU limit** (CPU throttling on a scrape-heavy process causes missed scrapes)
- ✅ `externalLabels.cluster` so multi-cluster dashboards can tell clusters apart
- ✅ Disable `kubeEtcd`, `kubeControllerManager`, `kubeScheduler` on EKS
- ⚠️ Watch cardinality: `sum(scrape_samples_scraped) by (job)` will show you which target is flooding you

### Loki
- ✅ **S3, always.** Never `filesystem` in production, never the built-in MinIO
- ✅ `compactor.retention_enabled: true` alongside `retention_period`
- ✅ Keep labels few and low-cardinality
- ✅ Disable `chunksCache`/`resultsCache` on small clusters, enable them on big ones
- ✅ Use Pod Identity, never static access keys
- ✅ Set `volume_enabled: true` for the log-volume histogram in Grafana
- ❌ Never edit an existing `schemaConfig` entry

### Grafana
- ✅ Store the admin password in a Kubernetes Secret, not in values:
  ```bash
  kubectl create secret generic grafana-admin -n observability \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
  ```
  ```yaml
  grafana:
    admin:
      existingSecret: grafana-admin
      userKey: admin-user
      passwordKey: admin-password
  ```
- ✅ Wire up SSO (OIDC/SAML) instead of shared local accounts
- ✅ Manage dashboards as code (ConfigMaps with the sidecar label), not by clicking
- ✅ Don't expose Grafana on a public LoadBalancer without auth and TLS in front

### Security
- ✅ Encrypt the S3 bucket and block all public access
- ✅ Encrypt EBS volumes (`encrypted: "true"` in the StorageClass)
- ✅ Use least-privilege IAM — scope to the exact bucket ARN
- ✅ Turn on EKS control plane audit logging:
  ```bash
  aws eks update-cluster-config --name "$CLUSTER" \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}'
  ```
- ✅ NetworkPolicies to limit who can reach Loki's push endpoint
- ✅ Scan images; run containers as non-root

---

## 21. Troubleshooting

### Nodes never become `Ready`

```bash
aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --query 'nodegroup.health'
```

| Message | Cause | Fix |
|---|---|---|
| `NodeCreationFailure: Instances failed to join` | No route to the API endpoint | Private subnet needs a NAT Gateway or VPC endpoints for EKS/ECR/S3/STS |
| `AccessDenied` | Node role missing policies | Re-check Step 2 |
| `InsufficientFreeAddresses` | Subnet is out of IPs | Use a bigger subnet or enable CNI prefix delegation |
| `Ec2SubnetInvalidConfiguration` | Subnet AZ doesn't support the instance type | Pick a different type or AZ |
| Node is `Ready` but pods stay `Pending` | No capacity, or a taint | `kubectl describe pod <name>` and read the Events |

### `error: You must be logged in to the server (Unauthorized)`

```bash
aws sts get-caller-identity                      # is your AWS session alive?
aws sso login                                    # if not
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER"
aws eks list-access-entries --cluster-name "$CLUSTER"   # do you have one?
```

### PVCs stuck `Pending`

```bash
kubectl describe pvc <name> -n "$NS"
kubectl get storageclass
kubectl -n kube-system logs deploy/ebs-csi-controller -c csi-provisioner --tail=50
```

Usual causes: no default StorageClass; EBS CSI driver not installed; the driver's Pod Identity association missing or missing `sts:TagSession`.

### Loki: `AccessDenied` on S3

```bash
kubectl -n "$NS" logs loki-0 | grep -i "access\|denied\|s3"
kubectl -n "$NS" exec loki-0 -- env | grep AWS_
aws eks list-pod-identity-associations --cluster-name "$CLUSTER"
```

Checklist: service account name in `loki-values.yaml` matches `--service-account` exactly; namespace matches; trust policy has both `sts:AssumeRole` and `sts:TagSession`; the IAM policy has *two* statements (bucket and bucket/*); restart the pod after creating the association.

### No logs appear in Grafana

Walk the pipeline in order:

```bash
# 1. Is Alloy running on every node?
kubectl get pods -n "$NS" -l app.kubernetes.io/name=alloy -o wide

# 2. Is Alloy erroring?
kubectl -n "$NS" logs -l app.kubernetes.io/name=alloy --tail=50 | grep -i error

# 3. Is Alloy actually sending? (this metric should be climbing)
kubectl -n "$NS" exec -it daemonset/alloy -- \
  wget -qO- localhost:12345/metrics | grep loki_write_sent_bytes_total

# 4. Is Loki receiving?
kubectl -n "$NS" exec -it loki-0 -- \
  wget -qO- localhost:3100/metrics | grep distributor_bytes_received

# 5. What label sets does Loki know about?
kubectl -n "$NS" port-forward svc/loki-gateway 3100:80
curl -s "http://localhost:3100/loki/api/v1/labels" | jq
curl -s "http://localhost:3100/loki/api/v1/label/namespace/values" | jq
```

Whichever step is zero is where the break is.

### `too many outstanding requests` / `maximum of series reached`

Cardinality. Find the offender:

```logql
topk(10, count by (__name__)({namespace=~".+"}))
```

Then remove that label from the `discovery.relabel` block in `alloy-values.yaml`.

### Prometheus pod gets OOMKilled

Raise the memory limit, cut retention, or reduce scrape targets. Find what's flooding you:

```promql
topk(10, count by (job) ({__name__=~".+"}))
sum(scrape_samples_scraped) by (job)
```

### Helm upgrade fails on CRDs

```bash
# kube-prometheus-stack major version bumps need CRDs applied manually first
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.89.0/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
```

Always read the chart's upgrade notes for the exact CRD URLs for your target version.

---

## 22. What this costs

Rough monthly estimate, `us-east-1`, small production-ish setup:

| Item | Quantity | Approx / month |
|---|---|---|
| EKS control plane | 1 cluster | ~$73 |
| Node group: 2 × `m7i.large` on-demand | 24/7 | ~$140 |
| Same on Spot | 24/7 | ~$45 |
| EBS gp3 for Prometheus | 50 GiB | ~$4 |
| EBS gp3 for Grafana + Alertmanager + Loki | ~35 GiB | ~$3 |
| S3 for Loki chunks | 100 GiB | ~$2.30 |
| S3 requests | moderate | ~$1–5 |
| NAT Gateway | 1 | ~$33 + data |
| **Total, on-demand** | | **≈ $260/mo** |
| **Total, Spot nodes** | | **≈ $165/mo** |

Ways to cut it:
- **Spot for stateless workloads** — the single biggest lever
- **Graviton (`m7g.large`)** — roughly 20% cheaper for equal performance, and everything in this stack has arm64 images (use `--ami-type AL2023_ARM_64_STANDARD`)
- **Drop Loki retention** to 7 or 14 days for non-prod
- **Drop the health-check log noise** — the `stage.drop` block in `alloy-values.yaml` often removes 30–50% of log volume
- **Shorten Prometheus retention** to 7 days and ship long-term data to Amazon Managed Prometheus or Thanos
- **VPC endpoints for S3 and ECR** instead of routing that traffic through NAT — often pays for itself quickly

> ⚠️ **The extended-support trap:** letting your cluster fall out of standard support multiplies the control-plane fee several times over. Upgrade before your version's end-of-standard-support date. Check yours: `aws eks describe-cluster --name "$CLUSTER" --query 'cluster.version'`.

---

## 23. Cleanup

Delete in this order — reverse of creation — or you'll leave orphaned resources behind.

```bash
source env.sh

# 1. Helm releases
helm uninstall alloy -n "$NS"
helm uninstall loki  -n "$NS"
helm uninstall kps   -n "$NS"

# 2. PVCs — Helm does NOT delete these, and you keep paying for them
kubectl delete pvc --all -n "$NS"

# 3. Namespace
kubectl delete namespace "$NS"

# 4. Pod Identity associations
for A in $(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" \
           --query 'associations[].associationId' --output text); do
  aws eks delete-pod-identity-association --cluster-name "$CLUSTER" --association-id "$A"
done

# 5. S3 bucket (must be empty first — this deletes your logs permanently)
aws s3 rm "s3://${LOKI_BUCKET}" --recursive
aws s3api delete-bucket --bucket "$LOKI_BUCKET"

# 6. IAM roles
aws iam delete-role-policy --role-name "$LOKI_ROLE_NAME" --policy-name loki-s3-access
aws iam delete-role --role-name "$LOKI_ROLE_NAME"
aws iam detach-role-policy --role-name "$EBS_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam delete-role --role-name "$EBS_ROLE_NAME"

# 7. Node group (takes several minutes)
aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"

# 8. Node role
for P in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryPullOnly AmazonEKS_CNI_Policy; do
  aws iam detach-role-policy --role-name "$NODE_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/${P}"
done
aws iam delete-role --role-name "$NODE_ROLE_NAME"

# 9. Tidy up your kubeconfig
kubectl config delete-context "$CLUSTER"
```

Then check for stragglers — unattached EBS volumes are the classic silent cost:

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' --output table
```

---

## 24. Command reference card

### Point at the right cluster (do this constantly)

```bash
aws sts get-caller-identity
aws eks list-clusters --region "$AWS_REGION"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER" --alias "$CLUSTER"
kubectl config get-contexts
kubectl config use-context "$CLUSTER"
kubectl config current-context
kubectl config set-context --current --namespace="$NS"
kubectl cluster-info
```

### Node groups

```bash
aws eks list-nodegroups --cluster-name "$CLUSTER"
aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"
aws eks create-nodegroup   --cluster-name "$CLUSTER" --nodegroup-name NG --node-role ARN \
    --subnets S1 S2 --scaling-config minSize=2,maxSize=6,desiredSize=2 \
    --instance-types m7i.large --ami-type AL2023_x86_64_STANDARD
aws eks update-nodegroup-config  --cluster-name "$CLUSTER" --nodegroup-name NG \
    --scaling-config minSize=2,maxSize=10,desiredSize=4
aws eks update-nodegroup-version --cluster-name "$CLUSTER" --nodegroup-name NG
aws eks delete-nodegroup   --cluster-name "$CLUSTER" --nodegroup-name NG
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name NG
```

### Nodes

```bash
kubectl get nodes -o wide
kubectl get nodes -L workload,topology.kubernetes.io/zone
kubectl get nodes -l eks.amazonaws.com/nodegroup="$NODEGROUP"
kubectl describe node <node>
kubectl top nodes
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
```

### Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add grafana-community    https://grafana-community.github.io/helm-charts
helm repo update
helm search repo <chart> --versions
helm show values <repo>/<chart> --version X.Y.Z
helm upgrade --install <name> <repo>/<chart> -n "$NS" -f values.yaml --version X.Y.Z --wait
helm list -n "$NS"
helm history <name> -n "$NS"
helm get values <name> -n "$NS"
helm rollback <name> <revision> -n "$NS"
helm uninstall <name> -n "$NS"
```

### Debugging

```bash
kubectl get pods -n "$NS" -o wide
kubectl describe pod <pod> -n "$NS"
kubectl logs <pod> -n "$NS" --tail=100 -f
kubectl logs <pod> -n "$NS" --previous          # logs from the crashed instance
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -30
kubectl exec -it <pod> -n "$NS" -- sh
kubectl port-forward -n "$NS" svc/kps-grafana 3000:80
kubectl port-forward -n "$NS" svc/kps-prometheus 9090:9090
kubectl port-forward -n "$NS" svc/loki-gateway 3100:80
kubectl port-forward -n "$NS" daemonset/alloy 12345:12345
```

### Useful LogQL

```logql
{namespace="prod"}                                          # everything in prod
{namespace="prod", container="api"} |= "ERROR"              # substring match
{namespace="prod"} |~ "(?i)(error|fatal|panic)"             # regex, case-insensitive
{namespace="prod"} != "healthcheck"                         # exclude
{namespace="prod"} | json | level="error"                   # parse JSON, filter field
{namespace="prod"} | logfmt | duration > 5s                 # parse logfmt, compare
sum by (pod) (rate({namespace="prod"} |= "ERROR" [5m]))     # error rate per pod
sum by (namespace) (count_over_time({namespace=~".+"}[1h])) # log volume per namespace
```

### Useful PromQL

```promql
count(kube_node_info)                                                    # node count
kube_node_status_condition{condition="Ready",status="true"}              # ready nodes
sum(rate(container_cpu_usage_seconds_total[5m])) by (namespace)          # CPU by ns
sum(container_memory_working_set_bytes) by (namespace)                   # memory by ns
sum(increase(kube_pod_container_status_restarts_total[1h])) by (pod) > 0 # crashers
kube_pod_status_phase{phase="Pending"} == 1                              # stuck pods
100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)  # node CPU %
```

---

## Where to go next

1. **Alerting** — write `PrometheusRule` objects and route them through Alertmanager to Slack or PagerDuty. Start with the four "golden signals": latency, traffic, errors, saturation.
2. **Tempo for traces** — the third pillar. Same Grafana, same pattern, and Alloy already speaks OTLP so it can ship traces too.
3. **Ingress + TLS** — expose Grafana properly with the AWS Load Balancer Controller, cert-manager, and OIDC login. Note that upstream Kubernetes retired Ingress NGINX in March 2026, so use Gateway API or the AWS Load Balancer Controller rather than starting a new Ingress NGINX deployment.
4. **GitOps** — put all of this in Argo CD or Flux so a Git commit, not a person's laptop, is what changes production.
5. **Karpenter** — once you understand node groups, this is the natural next step for cost and speed.
6. **Cost visibility** — add OpenCost or Kubecost to see spend per namespace.

### Official documentation

- Amazon EKS User Guide — https://docs.aws.amazon.com/eks/latest/userguide/
- EKS Best Practices Guide — https://docs.aws.amazon.com/eks/latest/best-practices/
- Grafana Loki — https://grafana.com/docs/loki/latest/
- Grafana Alloy — https://grafana.com/docs/alloy/latest/
- kube-prometheus-stack chart — https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Loki community chart — https://github.com/grafana-community/helm-charts

---

*Verified August 2026. Kubernetes and this ecosystem move fast — before a production rollout, check `helm show values` for the chart versions you pin and skim the upstream release notes.*
