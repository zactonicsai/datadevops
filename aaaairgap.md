# Running Keycloak on AWS EKS — Node Groups, Node Pools, Launch Templates, and Offline (Air-Gapped) Helm

**A complete, plain-language guide.**
Written July 2026. Everything here matches the tools as they exist now (EKS 1.34–1.36, Karpenter v1.11.x, Helm 4.1.x, Keycloak 26.6.x).

---

## Table of contents

1. [What you are going to build](#1-what-you-are-going-to-build)
2. [Words you need to know (background)](#2-words-you-need-to-know-background)
3. [Why a *separate* node group for Keycloak?](#3-why-a-separate-node-group-for-keycloak)
4. [What "air-gapped" really means](#4-what-air-gapped-really-means)
5. [Before you start: tools and versions](#5-before-you-start-tools-and-versions)
6. [**THE WALKTHROUGH** — one full example, start to finish](#6-the-walkthrough--one-full-example-start-to-finish)
7. [Every field explained (launch template + node group reference)](#7-every-field-explained)
8. [The other way: a Karpenter **NodePool** instead of a node group](#8-the-other-way-a-karpenter-nodepool)
9. [Air-gapped deep dive: VPC endpoints, ECR, mirroring](#9-air-gapped-deep-dive)
10. [Choices and trade-offs (pros and cons tables)](#10-choices-and-trade-offs)
11. [Best practices checklist](#11-best-practices-checklist)
12. [Troubleshooting](#12-troubleshooting)
13. [Appendix A: one big copy-paste script](#appendix-a-one-big-copy-paste-script)
14. [Appendix B: glossary](#appendix-b-glossary)

---

## 1. What you are going to build

Imagine your Kubernetes cluster is a **school building**.

- The **control plane** is the principal's office. AWS runs it for you. You never touch it.
- The **nodes** are classrooms. Each classroom is really an EC2 virtual machine.
- The **pods** are students. The principal decides which classroom each student sits in.
- **Keycloak** is a very important student. It is your login system. If Keycloak stops, *nobody in your whole company can log in to anything.*

So we are going to build Keycloak its own classroom wing:

```
                    ┌──────────────────────────────────────────┐
                    │        EKS control plane (AWS runs it)   │
                    │        private API endpoint only         │
                    └───────────────────┬──────────────────────┘
                                        │  (private, inside VPC)
   ┌────────────────────────────────────┼─────────────────────────────────┐
   │  Your VPC — no internet gateway, no NAT                              │
   │                                                                      │
   │  ┌──────────────────────┐        ┌──────────────────────────────┐    │
   │  │ node group: general  │        │ node group: keycloak         │    │
   │  │ label: general       │        │ label:  workload=keycloak    │    │
   │  │ no taint             │        │ taint:  dedicated=keycloak   │    │
   │  │ m7i.large  x3        │        │ m7i.xlarge x3 (1 per AZ)     │    │
   │  │                      │        │ built from LAUNCH TEMPLATE   │    │
   │  │ [normal apps]        │        │ [keycloak-0][keycloak-1][-2] │    │
   │  └──────────────────────┘        └──────────────────────────────┘    │
   │                                                                      │
   │  ┌──────────────┐  ┌───────────────┐  ┌──────────────────────────┐   │
   │  │ ECR (private)│  │ RDS PostgreSQL│  │ VPC endpoints:           │   │
   │  │ images+charts│  │  Multi-AZ     │  │ ecr.api ecr.dkr s3 sts   │   │
   │  └──────────────┘  └───────────────┘  │ ec2 eks eks-auth logs... │   │
   │                                       └──────────────────────────┘   │
   └──────────────────────────────────────────────────────────────────────┘
```

By the end you will have:

1. An **EC2 launch template** — the recipe card that says how each Keycloak machine is built (disk size, encryption, security settings, startup config).
2. An **EKS managed node group** — a row of identical machines built from that recipe card, labelled and tainted so *only* Keycloak lands there.
3. A **mirrored Helm chart and container images** sitting inside your own private ECR registry, so nothing is downloaded from the internet.
4. **Keycloak running**, in production mode, talking to a real PostgreSQL database, spread across three Availability Zones.

---

## 2. Words you need to know (background)

Read this table once. Everything after this assumes you know these words.

| Word | What it means, in plain English |
|---|---|
| **EKS** | Elastic Kubernetes Service. AWS runs the Kubernetes "brain" (control plane) for you. You only manage the worker machines and the apps. |
| **Node** | One worker machine. On AWS it is an EC2 instance. |
| **Node group** | An AWS-managed **group of identical nodes**. AWS handles creating, replacing, and upgrading them. The AWS name is "managed node group" (MNG). |
| **Node pool** | Two different things use this name! (a) The generic idea of "a group of similar nodes." (b) A **Karpenter `NodePool`** — a Kubernetes object that says "make me whatever nodes my pods need." Section 8 covers this. |
| **Launch template** | An EC2 recipe card. It stores disk size, security groups, tags, encryption, and the startup script. A node group points at a launch template and stamps out machines from it. |
| **AMI** | Amazon Machine Image. The "operating system snapshot" a node boots from. Today the default for EKS is **Amazon Linux 2023 (AL2023)**. |
| **nodeadm** | The AL2023 program that joins a fresh machine to your cluster. It reads a small YAML file called `NodeConfig` from the launch template's user data. (The old AL2 script `/etc/eks/bootstrap.sh` is gone.) |
| **kubectl** | The remote control for Kubernetes. You type commands, it talks to the control plane. |
| **Helm** | The "app installer" for Kubernetes. A **chart** is the installer package. A **release** is one installed copy. |
| **Values file** | A YAML file of settings you hand to Helm, like a settings menu. |
| **OCI registry** | A container registry (like ECR) that can store **both** container images **and** Helm charts. |
| **ECR** | Elastic Container Registry — AWS's private registry. This is where your offline copies live. |
| **Label** | A sticky note on a node, like `workload=keycloak`. Pods can ask for nodes with that note. |
| **Taint** | A "keep out" sign on a node. Only pods carrying a matching **toleration** (a hall pass) may sit there. |
| **Air-gapped** | The cluster has **no route to the internet at all**. No NAT gateway, no internet gateway. Everything must already be inside. |
| **Keycloak** | Open-source login server (SSO / identity provider). Speaks OpenID Connect and SAML. Current version 26.6.x. |
| **VPC endpoint** | A private doorway from your VPC straight to an AWS service, without using the internet. |

---

## 3. Why a *separate* node group for Keycloak?

You *can* just run Keycloak on your normal nodes. Many people do. But here is why a dedicated group is usually worth it.

**Reason 1 — Keycloak is a "blast radius" service.**
If Keycloak goes down, every app that uses it goes down too. You do not want a badly written batch job eating all the memory on the same machine and getting Keycloak killed by the kernel's out-of-memory killer.

**Reason 2 — Keycloak is a Java app with a particular shape.**
It wants steady memory, benefits from a fixed heap, and hates being interrupted. Java heap tuning is easier when you know exactly what machine size you are on.

**Reason 3 — Compliance and audit.**
Auditors like being able to say "the identity system runs on its own hardware, with its own security group, its own encrypted disks, its own IAM role." A dedicated node group gives you a clean boundary.

**Reason 4 — Different upgrade rhythm.**
You may want to patch general nodes weekly but only touch identity nodes during a planned maintenance window. Separate node groups upgrade separately.

**Reason 5 — Spread across zones cleanly.**
Keycloak clusters using Infinispan really want an odd number of replicas spread across Availability Zones. A dedicated group of exactly 3 nodes in 3 AZs makes that trivial.

**The cost:** you pay for those nodes even when they are half empty. A dedicated 3-node group is typically $150–$400/month more than sharing. For an identity system that is almost always worth it. For a small dev cluster, it is not.

---

## 4. What "air-gapped" really means

People use "air-gapped" for three very different setups. Know which one you are in, because the work is different.

| Level | What it looks like | Can you `docker pull` from the internet? |
|---|---|---|
| **Level 1 — Private cluster** | Nodes in private subnets, but there is a **NAT gateway**. API endpoint may be private. | Yes. Easy mode. |
| **Level 2 — No egress (the usual "air-gapped" on AWS)** | No internet gateway, no NAT. Only **VPC endpoints** to AWS services. ECR reachable privately. | No. You must mirror everything into ECR first, from a separate machine that *does* have internet. |
| **Level 3 — True air gap** | Physically separated network. No connection to anything outside, ever. Files arrive on encrypted media or through a data diode. | No, and you cannot even reach ECR from outside. You copy tarballs by hand. |

This guide targets **Level 2**, and gives you the extra steps for **Level 3** where they differ (search for "sneakernet").

**The key mental model for both:** you need a **"bridge host"** — a laptop, a CI runner, or an EC2 box in a *different*, internet-connected account. The bridge host downloads everything, then pushes it into your private ECR (Level 2) or writes it to a tarball you carry across (Level 3). Your air-gapped cluster only ever talks to ECR.

---

## 5. Before you start: tools and versions

### 5.1 What is current, as of July 2026

| Thing | Current status | Notes |
|---|---|---|
| **Kubernetes on EKS** | 1.33, 1.34, 1.35, 1.36 in standard support. 1.36 is newest. | Standard support = 14 months from release, then 12 months of **extended support at roughly 6× the control-plane price**. Do not drift into extended support by accident. |
| **EKS 1.33** | Standard support **ends 29 July 2026** | If you are on 1.33 today, plan the upgrade now. |
| **Version rollback** | New in July 2026 | EKS can now roll a cluster **back** one minor version within 7 days of an upgrade. A real safety net. |
| **Default node OS** | **AL2023** (Amazon Linux 2 is retired) | Uses `nodeadm` + `NodeConfig`, not `bootstrap.sh`. |
| **Helm** | **Helm 4.x** (4.1.4, April 2026). Helm 3's final feature release is Sept 2026; security fixes end Feb 2027. | Helm 4 has breaking CLI changes — see 5.3. |
| **Karpenter** | v1.11.x. API group `karpenter.sh/v1` (`NodePool`) and `karpenter.k8s.aws/v1` (`EC2NodeClass`). | The old `Provisioner` / `AWSNodeTemplate` objects were removed in v1.0. |
| **Keycloak** | 26.6.x | Health endpoints moved to the **management port 9000**. Admin bootstrap env vars renamed to `KC_BOOTSTRAP_ADMIN_*`. |
| **Bitnami charts** | ⚠️ Changed August 2025. Free Bitnami images moved to a `bitnamilegacy` repo and are no longer updated; the maintained "Bitnami Secure Images" need a paid subscription. | Do **not** start a new air-gapped Keycloak on the free Bitnami path in 2026. See section 10.2 for what to use instead. |
| **Ingress-NGINX** | ⚠️ Retired by the upstream Kubernetes project in **March 2026**. No more bug fixes or security patches. | Existing installs keep working but are a growing risk. Use the **AWS Load Balancer Controller** or the **Gateway API** instead. |

### 5.2 Install the tools on your bridge host

```bash
# AWS CLI v2 (needs to be 2.17+ for current EKS features)
aws --version

# kubectl — stay within one minor version of your cluster
kubectl version --client

# Helm 4
helm version

# eksctl (optional but handy)
eksctl version

# skopeo or crane — for copying images without a Docker daemon.
# Strongly recommended over `docker pull/tag/push` for mirroring.
skopeo --version
```

### 5.3 Helm 4 gotchas that will bite you

These changed from Helm 3 and break old scripts:

| Old (Helm 3) | New (Helm 4) |
|---|---|
| `helm registry login https://myreg.example.com` | `helm registry login myreg.example.com` — **domain only**, no `https://` |
| `--atomic` | `--rollback-on-failure` (old flag warns now, errors later) |
| `--force` | `--force-replace` |
| `HELM_EXPERIMENTAL_OCI=1` | Delete it. OCI is stable and on by default; setting the variable now **errors**. |
| Client-side apply | **Server-Side Apply is the default** |
| `--post-renderer /path/to/binary` | Post-renderers must now be Helm **plugins** |
| Plain-HTTP registries worked loosely | Must pass `--plain-http` explicitly if your registry has no TLS |

Your **charts** need no changes. Only your scripts do.

Helm 4 also lets you install by digest, which is excellent for air-gapped supply-chain proof:

```bash
helm install keycloak oci://myreg.example.com/charts/keycloakx@sha256:abc123...
```

If the digest does not match, Helm refuses to install. Tags can be moved; digests cannot.

---

## 6. THE WALKTHROUGH — one full example, start to finish

We will do this once, completely, with real commands. Read section 7 afterwards for what every single field means.

**The scenario:** You have an EKS 1.34 cluster called `prod-eks` in `us-east-1`. It is a Level-2 air gap: private subnets, VPC endpoints, no NAT. You want Keycloak 26.6.2 running on three dedicated nodes, one per Availability Zone, using an existing RDS PostgreSQL database.

**The two halves:**
- **Part A (steps 1–8):** build the machines. Done with `aws` CLI.
- **Part B (steps 9–16):** get the software in and install it. Done with `skopeo`, `helm`, `kubectl`.

---

### PART A — Build the node group

#### Step 1 — Set your variables

Do this in one terminal and keep it open. Every later command reuses these.

```bash
export AWS_REGION=us-east-1
export CLUSTER=prod-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# The three private subnets, one per AZ. Replace with yours.
export SUBNET_A=subnet-0aaa111
export SUBNET_B=subnet-0bbb222
export SUBNET_C=subnet-0ccc333

export NG_NAME=keycloak-ng
export LT_NAME=keycloak-node-lt
export NODE_ROLE_NAME=EKSKeycloakNodeRole
```

Sanity check that you are pointed at the right cluster:

```bash
aws eks describe-cluster --name "$CLUSTER" \
  --query 'cluster.{status:status,version:version,endpointPublic:resourcesVpcConfig.endpointPublicAccess,vpc:resourcesVpcConfig.vpcId}' \
  --output table
```

You should see `status: ACTIVE`. If `endpointPublic` is `False`, you must run everything from **inside** the VPC (a bastion, VPN, or Direct Connect). That is normal for air-gapped clusters.

#### Step 2 — Get your kubectl config

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl get nodes
```

If `kubectl get nodes` hangs, you are outside the VPC and the API endpoint is private. Fix that before continuing — nothing else will work.

#### Step 3 — Create the IAM role the nodes will wear

Every node needs an IAM role so it can talk to AWS. Think of it as the classroom's ID badge.

```bash
cat > node-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file://node-trust-policy.json
```

Attach the policies:

```bash
# Lets the node register itself with the cluster
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

# Lets the node PULL images from ECR (pull-only is the modern, tighter policy;
# the older AmazonEC2ContainerRegistryReadOnly also works but grants more)
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly

# Lets the VPC CNI hand out pod IP addresses
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

# Optional but very useful in air-gapped land: lets you reach the box with
# SSM Session Manager instead of opening SSH
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

```bash
export NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" \
  --query 'Role.Arn' --output text)
echo "$NODE_ROLE_ARN"
```

> **Best practice:** `AmazonEKS_CNI_Policy` on the node role gives *every pod on the node* those permissions, because pods can reach the instance metadata service. The tighter modern approach is to move the CNI to its own identity using **EKS Pod Identity** and drop this policy from the node role. Do that when you have time; it is not required for this walkthrough.

#### Step 4 — Write the launch template's user data

This is the startup instruction sheet the machine reads the moment it boots. On AL2023, it is a **MIME multipart** document containing a `NodeConfig` object.

```bash
cat > user-data.txt << 'EOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: 58
      kubeReserved:
        cpu: "200m"
        memory: "1Gi"
        ephemeral-storage: "2Gi"
      systemReserved:
        cpu: "100m"
        memory: "512Mi"
      evictionHard:
        memory.available: "500Mi"
        nodefs.available: "10%"
    flags:
      - "--node-labels=workload=keycloak,tier=identity"

--//--
EOF
```

**Read this carefully — three rules that cause 90% of "my nodes never join" tickets:**

1. **Indentation must be exact.** YAML inside MIME is unforgiving. One stray space and `nodeadm` fails silently and the node never registers.
2. **No trailing blank lines after `--//--`.**
3. **Because we are *not* setting a custom AMI**, we can leave out `spec.cluster` (name, apiServerEndpoint, certificateAuthority, cidr). EKS injects its own `NodeConfig` with those fields and **merges** it with ours. If you *do* pin a custom AMI ID in the launch template, you **must** supply all four cluster fields yourself — see step 4b.

**Step 4b — the custom-AMI variant (only if you pin an AMI ID):**

```bash
API=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.endpoint' --output text)
CA=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.certificateAuthority.data' --output text)
CIDR=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

cat > user-data-custom-ami.txt << EOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER}
    apiServerEndpoint: ${API}
    certificateAuthority: ${CA}
    cidr: ${CIDR}
  kubelet:
    flags:
      - "--node-labels=workload=keycloak,tier=identity"

--//--
EOF
```

Why the difference? Under AL2, the node called the `DescribeCluster` API at boot to learn these values. AL2023 stopped doing that, because thousands of nodes scaling up at once would throttle the API. So the values are baked in instead.

Now base64-encode it, because the EC2 API wants user data pre-encoded:

```bash
export USERDATA_B64=$(base64 -w0 user-data.txt)   # macOS: base64 -i user-data.txt | tr -d '\n'
```

#### Step 5 — Create the launch template

```bash
cat > lt-data.json << EOF
{
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": {
        "VolumeSize": 100,
        "VolumeType": "gp3",
        "Iops": 3000,
        "Throughput": 125,
        "Encrypted": true,
        "DeleteOnTermination": true
      }
    }
  ],
  "MetadataOptions": {
    "HttpEndpoint": "enabled",
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 2
  },
  "Monitoring": { "Enabled": true },
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        { "Key": "Name", "Value": "eks-${CLUSTER}-keycloak-node" },
        { "Key": "Environment", "Value": "production" },
        { "Key": "Workload", "Value": "keycloak" },
        { "Key": "CostCenter", "Value": "platform-identity" }
      ]
    },
    {
      "ResourceType": "volume",
      "Tags": [
        { "Key": "Name", "Value": "eks-${CLUSTER}-keycloak-vol" }
      ]
    }
  ],
  "UserData": "${USERDATA_B64}"
}
EOF

aws ec2 create-launch-template \
  --launch-template-name "$LT_NAME" \
  --version-description "keycloak nodes v1 - AL2023, gp3 100GB encrypted, IMDSv2" \
  --launch-template-data file://lt-data.json
```

Save the ID:

```bash
export LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
echo "$LT_ID"
```

**Notice what is NOT in there:**

- **No `ImageId`.** Leaving it out means EKS picks the correct, current EKS-optimized AL2023 AMI for your cluster version, and can upgrade it for you later. Pin an AMI only if you have a hardened golden image you must use.
- **No `InstanceType`.** We set instance types on the node group instead, which lets us list several types for better Spot/capacity flexibility. **If you put `InstanceType` in the launch template, you may not pass `--instance-types` to the node group.** Pick one place, not both.
- **No `SecurityGroupIds`.** Leaving it out means the node group inherits the cluster security group, which already has the right rules. Add your own only if you need extra rules — and if you do, you must *also* include the cluster security group or nodes cannot talk to the control plane.
- **No `KeyName`.** Use SSM Session Manager, not SSH keys. Fewer doors, fewer locks to manage.

#### Step 6 — Create the managed node group

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG_NAME" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
  --instance-types m7i.xlarge m6i.xlarge \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --update-config maxUnavailable=1 \
  --launch-template "id=${LT_ID},version=1" \
  --labels workload=keycloak,tier=identity \
  --taints 'key=dedicated,value=keycloak,effect=NO_SCHEDULE' \
  --tags Environment=production,Workload=keycloak \
  --region "$AWS_REGION"
```

Watch it come up (this takes 3–6 minutes):

```bash
aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME"
aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" \
  --query 'nodegroup.{status:status,health:health,version:version,ami:releaseVersion}'
```

**Why `ON_DEMAND` and not Spot?** Spot instances can be taken away with two minutes' notice. Keycloak sessions and the Infinispan cache do not enjoy that. Run identity on On-Demand. Save Spot for stateless batch work.

**Why `minSize=3`?** One node per AZ. If an AZ fails, two Keycloak replicas survive, which is still a working quorum.

**Why `maxUnavailable=1`?** During upgrades, EKS replaces one node at a time. Two at a time on a 3-node identity cluster is asking for an outage.

#### Step 7 — Verify the nodes

```bash
kubectl get nodes -l workload=keycloak -o wide
```

You should see three nodes, `Ready`. Check the taint actually landed:

```bash
kubectl get nodes -l workload=keycloak \
  -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,TAINTS:.spec.taints
```

Expected output shape:

```
NAME                          ZONE         TAINTS
ip-10-0-1-15.ec2.internal     us-east-1a   [map[effect:NoSchedule key:dedicated value:keycloak]]
ip-10-0-2-88.ec2.internal     us-east-1b   [map[effect:NoSchedule key:dedicated value:keycloak]]
ip-10-0-3-41.ec2.internal     us-east-1c   [map[effect:NoSchedule key:dedicated value:keycloak]]
```

Three nodes, three different zones, all tainted. 

#### Step 8 — Prove nothing else can land there

```bash
kubectl run tainttest --image=public.ecr.aws/docker/library/busybox:latest \
  --overrides='{"spec":{"nodeSelector":{"workload":"keycloak"}}}' \
  --restart=Never -- sleep 60

kubectl get pod tainttest   # should be Pending
kubectl describe pod tainttest | grep -A3 Events
```

You should see a message about the pod not tolerating the taint. That is the proof your fence works. Clean up:

```bash
kubectl delete pod tainttest --ignore-not-found
```

---

### PART B — Get Keycloak in, offline

#### Step 9 — Pick your chart (and why)

Since the Bitnami catalog change of August 2025, the free Bitnami Keycloak chart is no longer a good foundation for a new air-gapped production install — the images it points at are frozen in a `bitnamilegacy` repo, and the maintained ones need a paid subscription.

For this walkthrough we use the **codecentric `keycloakx` chart**, because:

- It pulls the **official upstream image**, `quay.io/keycloak/keycloak`, which Red Hat maintains and patches.
- It is built for the modern Quarkus Keycloak (v17+), not the ancient WildFly one.
- It is actively released — chart 7.2.0 tracks Keycloak 26.6.2.
- It expects an external database, which is what you want in production anyway.

Section 10.2 compares this against the Keycloak Operator, HelmForge, and writing your own chart. All four are reasonable; this one is the shortest path.

```bash
# ON THE BRIDGE HOST (has internet)
helm repo add codecentric https://codecentric.github.io/helm-charts
helm repo update
helm search repo codecentric/keycloakx --versions | head -5
```

#### Step 10 — Download the chart *with its dependencies baked in*

This is the step everyone gets wrong. A chart can depend on other charts. If you just copy the `.tgz` and your air-gapped cluster tries to resolve a dependency, it will reach for the internet and fail.

```bash
export CHART_VERSION=7.2.0

helm pull codecentric/keycloakx --version "$CHART_VERSION" --untar --untardir ./work

# Resolve and vendor every dependency INTO the chart directory
cd ./work/keycloakx
helm dependency update      # writes sub-charts into ./charts/
ls charts/                  # confirm they are physically there
cd ../..

# Repackage — now the .tgz is fully self-contained
helm package ./work/keycloakx --destination ./offline
ls -lh ./offline/
```

Verify it is truly self-contained:

```bash
tar -tzf ./offline/keycloakx-${CHART_VERSION}.tgz | grep '^keycloakx/charts/' || echo "no dependencies (fine)"
```

#### Step 11 — Find every image the chart will pull

A chart that renders happily is still useless if one image is missing. Ask the chart what it wants:

```bash
helm template kc ./offline/keycloakx-${CHART_VERSION}.tgz \
  | grep -E '^\s+image:' \
  | sed 's/.*image:\s*//' | tr -d '"' | sort -u
```

Then add anything the chart does not render but you know you need — init containers, the DB checker, and anything your values file switches on:

```
quay.io/keycloak/keycloak:26.6.2
docker.io/library/busybox:1.36          # used by the dbchecker init container
```

> **Do this every time you upgrade the chart.** A minor chart bump can quietly add a new sidecar image, and in an air-gapped cluster that means `ImagePullBackOff` at 2am.

#### Step 12 — Mirror the images into ECR

Create the repositories first — ECR does not auto-create them:

```bash
for repo in keycloak/keycloak library/busybox; do
  aws ecr create-repository \
    --repository-name "$repo" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability IMMUTABLE \
    --encryption-configuration encryptionType=AES256 2>/dev/null || echo "$repo exists"
done
```

`IMMUTABLE` tags mean nobody can quietly replace `26.6.2` with different bits later. For an identity system, insist on this.

Now copy. **Use `skopeo`, not `docker`** — no daemon needed, it preserves multi-architecture manifests, and it is far faster:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | skopeo login --username AWS --password-stdin "$ECR"

skopeo copy --all \
  docker://quay.io/keycloak/keycloak:26.6.2 \
  docker://${ECR}/keycloak/keycloak:26.6.2

skopeo copy --all \
  docker://docker.io/library/busybox:1.36 \
  docker://${ECR}/library/busybox:1.36
```

`--all` copies every architecture in the manifest list. Skip it and you may copy only amd64, then wonder why your Graviton nodes fail.

Record the digests. These are your supply-chain receipts:

```bash
skopeo inspect docker://${ECR}/keycloak/keycloak:26.6.2 --format '{{.Digest}}'
```

**For Level 3 (true air gap) — the sneakernet version:**

```bash
# On the bridge host, write to a file
skopeo copy --all docker://quay.io/keycloak/keycloak:26.6.2 \
  oci-archive:keycloak-26.6.2.tar:keycloak:26.6.2

# Carry keycloak-26.6.2.tar and the chart .tgz across on approved media.
# On the inside host:
skopeo copy --all oci-archive:keycloak-26.6.2.tar:keycloak:26.6.2 \
  docker://${ECR}/keycloak/keycloak:26.6.2
```

#### Step 13 — Push the Helm chart into ECR too

ECR stores Helm charts as OCI artifacts. The repository name must match the **chart name**.

```bash
aws ecr create-repository --repository-name keycloakx --region "$AWS_REGION" 2>/dev/null || true

# Helm 4: domain only, NO https://
aws ecr get-login-password --region "$AWS_REGION" \
  | helm registry login "$ECR" --username AWS --password-stdin

helm push ./offline/keycloakx-${CHART_VERSION}.tgz "oci://${ECR}"
```

Confirm from inside the air gap:

```bash
helm show chart "oci://${ECR}/keycloakx" --version "$CHART_VERSION"
```

> **Alternative if you dislike OCI:** copy the `.tgz` to an S3 bucket (reachable via the S3 gateway endpoint) and install straight from the local file path. `helm install kc ./keycloakx-7.2.0.tgz -f values.yaml` works perfectly and needs no registry at all. It is less tidy for versioning, but it is the simplest thing that works.

#### Step 14 — Create the namespace and the secrets

```bash
kubectl create namespace keycloak

kubectl -n keycloak create secret generic keycloak-db \
  --from-literal=username=keycloak \
  --from-literal=password='<put-a-strong-password-here>'

kubectl -n keycloak create secret generic keycloak-bootstrap-admin \
  --from-literal=username=tempadmin \
  --from-literal=password='<another-strong-password>'
```

> **Security note:** the bootstrap admin is a *temporary* account for first login. Log in, create a real admin user with MFA, then delete the temporary one and this secret. Do not leave `tempadmin` alive in production.
>
> For anything long-lived, use **AWS Secrets Manager** with the External Secrets Operator or the Secrets Store CSI driver, so passwords never sit in a Kubernetes Secret as plain base64.

#### Step 15 — Write the values file

This is where the node group work pays off. The `nodeSelector` and `tolerations` blocks are what pin Keycloak onto the nodes you built.

```bash
cat > keycloak-values.yaml << EOF
# ---------------------------------------------------------------------------
# Three replicas: one per Availability Zone, matching our 3-node group.
# ---------------------------------------------------------------------------
replicas: 3

# ---------------------------------------------------------------------------
# IMAGE — points at YOUR ECR, never at the internet.
# ---------------------------------------------------------------------------
image:
  repository: ${ECR}/keycloak/keycloak
  tag: "26.6.2"
  pullPolicy: IfNotPresent

# ---------------------------------------------------------------------------
# THE PART THAT USES OUR NODE GROUP
# nodeSelector = "only put me on nodes wearing this label"
# tolerations  = "I have the hall pass for the keep-out sign"
# You need BOTH. A selector alone gets you a Pending pod.
# ---------------------------------------------------------------------------
nodeSelector:
  workload: keycloak

tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "keycloak"
    effect: "NoSchedule"

# Spread the three pods across three zones. whenUnsatisfiable: DoNotSchedule
# means "refuse to schedule rather than put two in one zone."
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: keycloakx

# Belt and braces: also avoid two pods on the same node.
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: keycloakx

# ---------------------------------------------------------------------------
# RESOURCES — requests == limits for memory. Java plus a memory limit plus
# bursting equals an OOMKill you did not plan for.
# ---------------------------------------------------------------------------
resources:
  requests:
    cpu: "1000m"
    memory: "2Gi"
  limits:
    cpu: "2000m"
    memory: "2Gi"

# ---------------------------------------------------------------------------
# START COMMAND. --optimized skips the build step at boot, which cuts
# startup from ~60s to ~10s. It requires a pre-built image (see note below).
# If you use the stock upstream image, drop --optimized.
# ---------------------------------------------------------------------------
command:
  - "/opt/keycloak/bin/kc.sh"
args:
  - "start"

# ---------------------------------------------------------------------------
# KEYCLOAK CONFIGURATION via environment variables.
# ---------------------------------------------------------------------------
extraEnv: |
  # --- Database (external RDS PostgreSQL) ---
  - name: KC_DB
    value: "postgres"
  - name: KC_DB_URL
    value: "jdbc:postgresql://keycloak-db.abc123.us-east-1.rds.amazonaws.com:5432/keycloak"
  - name: KC_DB_USERNAME
    valueFrom:
      secretKeyRef:
        name: keycloak-db
        key: username
  - name: KC_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak-db
        key: password
  - name: KC_DB_POOL_INITIAL_SIZE
    value: "5"
  - name: KC_DB_POOL_MIN_SIZE
    value: "5"
  - name: KC_DB_POOL_MAX_SIZE
    value: "20"

  # --- Hostname. In production mode this is REQUIRED. ---
  - name: KC_HOSTNAME
    value: "https://sso.internal.example.com"
  - name: KC_HOSTNAME_STRICT
    value: "true"

  # --- We terminate TLS at the load balancer, so Keycloak speaks plain HTTP
  #     internally but must trust the X-Forwarded-* headers. ---
  - name: KC_HTTP_ENABLED
    value: "true"
  - name: KC_PROXY_HEADERS
    value: "xforwarded"

  # --- Health and metrics live on management port 9000 in Keycloak 25+. ---
  - name: KC_HEALTH_ENABLED
    value: "true"
  - name: KC_METRICS_ENABLED
    value: "true"

  # --- Clustering. Infinispan finds its friends through DNS on the
  #     headless service. Change the name if your release name differs. ---
  - name: KC_CACHE
    value: "ispn"
  - name: KC_CACHE_STACK
    value: "kubernetes"
  - name: JAVA_OPTS_APPEND
    value: >-
      -Djgroups.dns.query=keycloak-keycloakx-headless.keycloak.svc.cluster.local
      -XX:MaxRAMPercentage=70
      -XX:+UseG1GC

  # --- First-boot admin. Delete after you create a real admin. ---
  - name: KC_BOOTSTRAP_ADMIN_USERNAME
    valueFrom:
      secretKeyRef:
        name: keycloak-bootstrap-admin
        key: username
  - name: KC_BOOTSTRAP_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: keycloak-bootstrap-admin
        key: password

# ---------------------------------------------------------------------------
# HEALTH PROBES — port 9000, not 8080.
# startupProbe is generous because a cold Keycloak runs DB migrations.
# ---------------------------------------------------------------------------
health:
  enabled: true

startupProbe: |
  httpGet:
    path: /health/started
    port: 9000
  initialDelaySeconds: 15
  periodSeconds: 5
  failureThreshold: 60

readinessProbe: |
  httpGet:
    path: /health/ready
    port: 9000
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 3

livenessProbe: |
  httpGet:
    path: /health/live
    port: 9000
  initialDelaySeconds: 60
  periodSeconds: 15
  timeoutSeconds: 5
  failureThreshold: 4

# ---------------------------------------------------------------------------
# Wait for the database before starting. Uses the mirrored busybox.
# ---------------------------------------------------------------------------
dbchecker:
  enabled: true
  image:
    repository: ${ECR}/library/busybox
    tag: "1.36"

# ---------------------------------------------------------------------------
# SECURITY CONTEXT — run as a normal user, no root, no extra powers.
# ---------------------------------------------------------------------------
podSecurityContext:
  fsGroup: 1000
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

securityContext:
  runAsUser: 1000
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]

# ---------------------------------------------------------------------------
# Keep at least 2 of 3 alive during node drains and upgrades.
# ---------------------------------------------------------------------------
podDisruptionBudget:
  enabled: true
  minAvailable: 2

# ---------------------------------------------------------------------------
# Ingress via the AWS Load Balancer Controller (ALB).
# Ingress-NGINX was retired upstream in March 2026 — do not build on it.
# ---------------------------------------------------------------------------
ingress:
  enabled: true
  ingressClassName: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:${ACCOUNT_ID}:certificate/REPLACE-ME
    alb.ingress.kubernetes.io/healthcheck-path: /health/ready
    alb.ingress.kubernetes.io/healthcheck-port: "9000"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  rules:
    - host: sso.internal.example.com
      paths:
        - path: /
          pathType: Prefix
EOF
```

> **Important — check the key names against *your* chart version.** Chart authors rename things between releases. Before you install, always run:
>
> ```bash
> helm show values "oci://${ECR}/keycloakx" --version "$CHART_VERSION" > chart-defaults.yaml
> ```
>
> and compare your file against `chart-defaults.yaml`. A misspelled key does not error — Helm silently ignores it, and you get a default you did not want. This is the single most common Helm mistake.

#### Step 16 — Install

Always dry-run first:

```bash
helm install keycloak "oci://${ECR}/keycloakx" \
  --version "$CHART_VERSION" \
  --namespace keycloak \
  --values keycloak-values.yaml \
  --dry-run --debug > rendered.yaml

# Read it. Confirm every image points at your ECR:
grep -E 'image:' rendered.yaml
```

If that looks right, install for real:

```bash
helm install keycloak "oci://${ECR}/keycloakx" \
  --version "$CHART_VERSION" \
  --namespace keycloak \
  --values keycloak-values.yaml \
  --wait \
  --timeout 10m \
  --rollback-on-failure     # Helm 4 name for the old --atomic
```

Watch it:

```bash
kubectl -n keycloak get pods -w
kubectl -n keycloak logs -f statefulset/keycloak-keycloakx
```

#### Step 17 — Verify everything

```bash
# 1. All three pods running, on three different nodes?
kubectl -n keycloak get pods -o wide

# 2. Did they actually land on the Keycloak node group?
kubectl -n keycloak get pods -o json \
  | jq -r '.items[] | "\(.metadata.name) -> \(.spec.nodeName)"'

# 3. Did the cluster form? Look for the Infinispan view.
kubectl -n keycloak logs statefulset/keycloak-keycloakx | grep -i "ISPN000094\|view"
# You want to see a view with 3 members.

# 4. Health check from inside
kubectl -n keycloak exec -it keycloak-keycloakx-0 -- \
  curl -s localhost:9000/health/ready

# 5. Reach the admin console (port-forward, since it is internal)
kubectl -n keycloak port-forward svc/keycloak-keycloakx-http 8080:80
# then open http://localhost:8080 in a browser on that machine
```

**If the Infinispan view shows 1 member instead of 3, your three Keycloaks are three lonely islands.** Sessions will break as the load balancer bounces users around. Fix the `jgroups.dns.query` value — it must exactly match your headless service's DNS name. Find it with:

```bash
kubectl -n keycloak get svc | grep headless
```

#### Step 18 — Post-install hardening

```bash
# Log in as tempadmin, create a real admin with MFA, then:
kubectl -n keycloak delete secret keycloak-bootstrap-admin
# and remove the KC_BOOTSTRAP_ADMIN_* block from values, then helm upgrade
```

Also lock down pod-to-pod traffic:

```bash
cat > keycloak-netpol.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-default-deny
  namespace: keycloak
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keycloak-allow
  namespace: keycloak
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: keycloakx
  policyTypes: [Ingress]
  ingress:
    # Allow the load balancer / other pods to reach the app port
    - ports:
        - port: 8080
          protocol: TCP
    # Allow Keycloak pods to reach each other for Infinispan clustering
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: keycloakx
      ports:
        - port: 7800
          protocol: TCP
EOF

kubectl apply -f keycloak-netpol.yaml
```

Note that the **management port 9000 is deliberately not exposed to everything** — only your monitoring namespace should reach it. Add a rule for that when you wire up Prometheus.

**You are done with the main path.** Everything below is reference, alternatives, and depth.

---

## 7. Every field explained

### 7.1 Launch template fields

| Field | What it does | Recommendation |
|---|---|---|
| `ImageId` | Which AMI to boot. | **Leave it out** unless you have a hardened golden image. Omitting it lets EKS pick and upgrade the right AL2023 AMI for your cluster version. If you set it, `amiType` becomes `CUSTOM` and you own all AMI upgrades forever. |
| `InstanceType` | Machine size. | **Leave it out**; set `--instance-types` on the node group instead so you can list several. Setting both is an error. |
| `KeyName` | SSH key pair. | Leave it out. Use SSM Session Manager. |
| `SecurityGroupIds` | Firewall rules. | Leave it out to inherit the cluster security group. If you set it, **you must include the cluster SG too**, or nodes cannot reach the control plane. |
| `BlockDeviceMappings` | Disks. `/dev/xvda` is the AL2023 root device. | `gp3`, 100 GB minimum for Keycloak (container images plus logs), `Encrypted: true`, always. |
| `Ebs.Iops` / `Throughput` | gp3 performance knobs. | 3000 IOPS / 125 MB/s is the free baseline. Enough for a node running Keycloak with an external DB. |
| `Ebs.KmsKeyId` | Customer-managed encryption key. | If you use one, the **node role and the EKS service must be allowed to use it in the key policy**, or instances fail with "Client error on launch". This is a classic trap. |
| `MetadataOptions.HttpTokens` | `required` forces IMDSv2. | **Always `required`.** IMDSv1 lets a compromised pod steal node credentials via a simple HTTP GET. |
| `HttpPutResponseHopLimit` | How many network hops metadata replies survive. | `2` — one hop for the container network, one for the host. `1` breaks pods that need metadata. |
| `Monitoring.Enabled` | Detailed CloudWatch metrics (1-minute instead of 5-minute). | `true` for production identity workloads. Small extra cost, much better incident data. |
| `TagSpecifications` | Tags on instances and volumes. | Tag everything. Cost allocation and incident response both depend on it. |
| `UserData` | The MIME + `NodeConfig` startup document, **base64 encoded**. | See section 6, step 4. Indentation is critical. |

**Versioning launch templates:** a launch template has numbered versions. You never edit a version; you create a new one.

```bash
# Make version 2 with a bigger disk
aws ec2 create-launch-template-version \
  --launch-template-name "$LT_NAME" \
  --version-description "v2 - 200GB disk" \
  --source-version 1 \
  --launch-template-data '{"BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]}'

# Roll the node group onto it — EKS replaces nodes one at a time
aws eks update-nodegroup-version \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG_NAME" \
  --launch-template "id=${LT_ID},version=2"
```

> **Do not use `$Latest` or `$Default` as the version** in a node group. It sounds convenient. It means a change someone makes for an unrelated reason can silently trigger a node replacement across your identity cluster. Pin the number.

### 7.2 Node group fields

| Field | What it does | Recommendation |
|---|---|---|
| `--node-role` | The IAM role every node wears. | Give Keycloak nodes their **own** role, not a shared one. Least privilege. |
| `--subnets` | Where nodes go. | Three private subnets in three AZs. Tag them `kubernetes.io/role/internal-elb=1` if you want internal ALBs there. |
| `--instance-types` | Allowed sizes. List several. | `m7i.xlarge m6i.xlarge` — two generations gives you capacity flexibility without changing the CPU architecture. Do **not** mix x86 and arm64 in one group unless every image is multi-arch. |
| `--ami-type` | Which AMI family. | `AL2023_x86_64_STANDARD`. Others: `AL2023_ARM_64_STANDARD` (Graviton, ~20% cheaper), `AL2023_x86_64_NVIDIA` (GPU), `BOTTLEROCKET_*` (minimal, immutable OS), `WINDOWS_*`. Becomes `CUSTOM` automatically if your LT pins an AMI. |
| `--capacity-type` | `ON_DEMAND` or `SPOT`. | `ON_DEMAND` for Keycloak. Always. |
| `--scaling-config` | min / max / desired node count. | `min=3` so an AZ failure still leaves a working cluster. `max` gives headroom for rolling upgrades. |
| `--update-config` | `maxUnavailable` or `maxUnavailablePercentage`. | `maxUnavailable=1`. Slower upgrades, no outages. |
| `--labels` | Node labels, set at the node-group level. | `workload=keycloak`. Setting labels here is better than in user data, because EKS keeps them consistent across replacements. |
| `--taints` | Keep-out signs. Format `key=K,value=V,effect=E`. | Effects are `NO_SCHEDULE`, `NO_EXECUTE`, `PREFER_NO_SCHEDULE`. Use `NO_SCHEDULE` — `NO_EXECUTE` evicts pods already running, which is rarely what you want at creation time. |
| `--launch-template` | `id=...,version=N` or `name=...,version=N`. | Pin the version number. |
| `--tags` | Tags on the node group AWS resource (not the EC2 instances). | Instance tags come from the launch template; these are separate. Set both. |

### 7.3 The Keycloak values that matter most

| Value | Why it matters |
|---|---|
| `nodeSelector` | Without it, pods can land anywhere. With it, only your labelled nodes. |
| `tolerations` | Without it, the taint blocks your own pods too. **You need both, always.** |
| `topologySpreadConstraints` | Without it, all three replicas can land in one AZ and one AZ failure takes you fully down. |
| `podAntiAffinity` | Stops two replicas sharing a node. |
| `resources` limits == requests (memory) | Java plus bursting plus a hard limit equals an OOMKill. Pin them equal. |
| `KC_HOSTNAME` | In production mode Keycloak refuses to start without it. It is also what goes in the tokens it issues — get it wrong and every redirect breaks. |
| `KC_PROXY_HEADERS=xforwarded` | Without it, Keycloak thinks every request came from the load balancer's IP over plain HTTP and builds broken redirect URLs. |
| `KC_CACHE_STACK=kubernetes` + `jgroups.dns.query` | Without these, your replicas do not form a cluster and users get logged out randomly. |
| `podDisruptionBudget.minAvailable: 2` | Without it, a node drain can take all three pods at once. |

---

## 8. The other way: a Karpenter NodePool

Everything above used a **managed node group** — a fixed row of desks you build in advance. **Karpenter** is the opposite idea: it watches for pods that cannot be scheduled and creates *exactly the right machine* for them, in about 30–60 seconds, then deletes it when it is no longer needed.

Karpenter v1.11.x uses two objects:

- **`NodePool`** (`karpenter.sh/v1`) — the Kubernetes-side rules: what pods are allowed, what instance shapes are acceptable, when to clean up.
- **`EC2NodeClass`** (`karpenter.k8s.aws/v1`) — the AWS-side details: AMI, subnets, security groups, IAM role, disks. It is the launch-template equivalent.

> The old `Provisioner` and `AWSNodeTemplate` objects were **removed in Karpenter v1.0**. If you find a tutorial using them, it is out of date.

### 8.1 Prerequisites

```bash
# Karpenter finds subnets and security groups by TAG. No tags, no nodes.
aws ec2 create-tags --resources "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER}

aws ec2 create-tags --resources sg-0abc123 \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER}
```

**Karpenter cannot create the node it runs on.** You still need at least one small managed node group to host the Karpenter controller itself. Everyone forgets this.

### 8.2 The EC2NodeClass (the "launch template" equivalent)

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: keycloak
spec:
  # Which IAM role the nodes wear
  role: "EKSKeycloakNodeRole"

  # Which AMI. "alias" lets Karpenter track the current EKS-optimized AL2023.
  # Pin to a specific version (e.g. al2023@v20260701) in regulated environments.
  amiSelectorTerms:
    - alias: al2023@latest

  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-eks

  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: prod-eks

  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        iops: 3000
        throughput: 125
        encrypted: true
        deleteOnTermination: true

  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required          # IMDSv2 only
    httpPutResponseHopLimit: 2

  tags:
    Name: karpenter-keycloak-node
    Workload: keycloak
    Environment: production

  # Optional extra startup config, same nodeadm format as a launch template
  userData: |
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          kubeReserved:
            cpu: "200m"
            memory: "1Gi"
```

### 8.3 The NodePool

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: keycloak
spec:
  template:
    metadata:
      labels:
        workload: keycloak
        tier: identity
    spec:
      # The same keep-out sign as our managed node group
      taints:
        - key: dedicated
          value: keycloak
          effect: NoSchedule

      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: keycloak

      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]          # identity does NOT run on Spot
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m7i.xlarge", "m6i.xlarge", "m7i.2xlarge"]
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["us-east-1a", "us-east-1b", "us-east-1c"]

      # Replace nodes after 30 days so they always run fresh, patched AMIs
      expireAfter: 720h
      # Give pods a full day to drain before forcing termination
      terminationGracePeriod: 24h

  # A hard ceiling so a runaway loop cannot spend your whole budget
  limits:
    cpu: "48"
    memory: 192Gi

  disruption:
    # Only consolidate when a node is empty or clearly underused
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      # Never disrupt more than one identity node at a time
      - nodes: "1"
      # And never during business hours at all
      - nodes: "0"
        schedule: "0 8 * * mon-fri"
        duration: 10h
```

Apply and test:

```bash
kubectl apply -f ec2nodeclass.yaml -f nodepool.yaml
kubectl get nodepool keycloak
kubectl get ec2nodeclass keycloak     # must show Ready
```

Your Keycloak `values.yaml` needs **no changes at all** — the same `nodeSelector` and `tolerations` work, because the NodePool applies the same label and taint.

### 8.4 Karpenter in an air-gapped cluster

Karpenter works air-gapped, but needs extra care:

- Mirror the Karpenter controller image and chart into ECR like everything else.
- Karpenter calls the **EC2, Pricing, SSM, and SQS** APIs. You need VPC endpoints for `ec2`, `ssm`, `sqs`, and `pricing` (pricing is not available as a VPC endpoint in every region — if it is missing, Karpenter falls back to its built-in price data, which is fine but slightly stale).
- `alias: al2023@latest` resolves through **SSM Parameter Store**, so the `ssm` VPC endpoint is mandatory. Without it, `EC2NodeClass` sits `NotReady` forever and you get no nodes.
- The **interruption queue** (SQS) is optional but recommended so Karpenter reacts gracefully to Spot reclaims and scheduled maintenance.

### 8.5 Node group vs NodePool: which for Keycloak?

| | Managed node group | Karpenter NodePool |
|---|---|---|
| **Node startup** | 3–6 minutes | 30–60 seconds |
| **Predictability** | High — fixed count, fixed shape | Lower — Karpenter picks shapes |
| **Cost efficiency** | Lower (you pay for idle) | Higher (aggressive bin-packing and consolidation) |
| **Extra components to run** | None | The Karpenter controller, its IAM, its CRDs, its SQS queue |
| **AZ spread** | You control it exactly | Controlled by `requirements` and pod topology spread |
| **Node churn** | Only when you say so | Continuous consolidation, unless you set budgets |
| **Air-gapped complexity** | Simple | More VPC endpoints, more to mirror |
| **Best for** | Steady, must-not-move workloads | Bursty, heterogeneous workloads |

**Recommendation for Keycloak specifically:** a **managed node group**. Keycloak's load is steady, its cluster state is sensitive to node churn, and you gain almost nothing from consolidation on three nodes. Use Karpenter for your *other* workloads on the same cluster — the two coexist happily as long as the taints keep them apart.

If you *do* use Karpenter for Keycloak, set `disruption.budgets` conservatively as shown above, or Karpenter's consolidation will cheerfully recycle your identity nodes in the middle of the workday.

### 8.6 A third option: EKS Auto Mode

EKS Auto Mode is AWS running the whole data plane for you — nodes, scaling, patching, core add-ons, all managed. It is Karpenter under the hood with AWS holding the wheel.

- **Pro:** almost nothing to operate. Version rollback even handles worker nodes for you now.
- **Con:** a management fee on top of EC2 cost; much less control over the node image and bootstrap; harder to satisfy strict compliance requirements about node hardening; and in air-gapped environments you have less visibility into what it pulls.
- **Verdict for a regulated air-gapped identity platform:** usually no. For a general-purpose cluster where you would rather not think about nodes: yes, seriously consider it.

---

## 9. Air-gapped deep dive

### 9.1 The complete VPC endpoint list

Without these, your air-gapped cluster is a very expensive brick. Interface endpoints cost roughly $7–8/month each plus data processing — budget about $100–150/month for the full set across three AZs.

| Service name | Type | Needed for | Required? |
|---|---|---|---|
| `com.amazonaws.<region>.ecr.api` | Interface | ECR authentication and metadata | **Yes** |
| `com.amazonaws.<region>.ecr.dkr` | Interface | The Docker pull protocol | **Yes** |
| `com.amazonaws.<region>.s3` | **Gateway** | The actual image layer bytes live in S3 | **Yes** |
| `com.amazonaws.<region>.ec2` | Interface | The AWS cloud provider integration | **Yes** |
| `com.amazonaws.<region>.sts` | Interface | IRSA token exchange | **Yes** if you use IRSA |
| `com.amazonaws.<region>.eks` | Interface | EKS API calls from inside the VPC | Yes for management |
| `com.amazonaws.<region>.eks-auth` | Interface | **EKS Pod Identity** credential fetch | **Yes** if you use Pod Identity |
| `com.amazonaws.<region>.logs` | Interface | CloudWatch Logs | If logging to CloudWatch |
| `com.amazonaws.<region>.elasticloadbalancing` | Interface | AWS Load Balancer Controller | **Yes** if you use ALB/NLB ingress |
| `com.amazonaws.<region>.autoscaling` | Interface | Cluster Autoscaler | If using Cluster Autoscaler |
| `com.amazonaws.<region>.ssm` | Interface | SSM parameters (AMI lookup), Session Manager | Yes for Karpenter; yes for SSM shell |
| `com.amazonaws.<region>.ssmmessages` | Interface | SSM Session Manager | For shell access |
| `com.amazonaws.<region>.ec2messages` | Interface | SSM agent | For shell access |
| `com.amazonaws.<region>.sqs` | Interface | Karpenter interruption queue | Karpenter only |
| `com.amazonaws.<region>.kms` | Interface | Encrypted EBS and secrets | If using customer-managed keys |
| `com.amazonaws.<region>.secretsmanager` | Interface | Pulling DB passwords | If using Secrets Manager |
| `com.amazonaws.<region>.xray` | Interface | Tracing | Optional |

Creating one, with private DNS on (this is what makes `ecr.us-east-1.amazonaws.com` resolve to the private address):

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.${AWS_REGION}.ecr.dkr \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
  --security-group-ids sg-0endpoint123 \
  --private-dns-enabled
```

**Two things that break this:**

1. **The endpoint's security group must allow inbound HTTPS (443) from your node security group.** If it does not, everything times out with no useful error.
2. **Your VPC needs `enableDnsSupport` and `enableDnsHostnames` set to true**, or private DNS does nothing.

The S3 one is a **gateway** endpoint, which works differently — it adds routes to your route tables, not an ENI:

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --vpc-endpoint-type Gateway \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --route-table-ids rtb-0aaa rtb-0bbb rtb-0ccc
```

Test from a node:

```bash
kubectl debug node/ip-10-0-1-15.ec2.internal -it --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- \
  bash -c 'curl -sv https://api.ecr.us-east-1.amazonaws.com 2>&1 | head -20'
```

If the resolved IP is a `10.x` address, private DNS is working. A public IP means it is not.

### 9.2 The full offline inventory

For a working air-gapped EKS cluster, you must mirror **more than just Keycloak**. Here is the checklist people forget:

| Category | Items |
|---|---|
| **Keycloak** | `quay.io/keycloak/keycloak:26.6.2`, the chart `.tgz`, the dbchecker image |
| **Core add-ons** | VPC CNI, CoreDNS, kube-proxy — these come from EKS-managed add-ons and pull from **public ECR**, so you need the `ecr` endpoints even for them, or you must mirror them |
| **Storage** | EBS CSI driver images (if you use PVCs anywhere) |
| **Networking** | AWS Load Balancer Controller image + chart |
| **Autoscaling** | Karpenter or Cluster Autoscaler image + chart |
| **Observability** | Prometheus, Grafana, Fluent Bit, or whatever you use |
| **Secrets** | External Secrets Operator or Secrets Store CSI driver |
| **Your own apps** | Everything, obviously |
| **Base images** | Any image referenced by an init container or job you did not think about |

> **The discipline that saves you:** keep a file called `airgap-manifest.yaml` in git listing every image and chart with its exact version **and digest**. Every release, update it, mirror from it, and diff it. This one habit prevents most air-gapped outages.

Example:

```yaml
# airgap-manifest.yaml
charts:
  - name: keycloakx
    version: 7.2.0
    source: https://codecentric.github.io/helm-charts
    dest: ${ECR}/keycloakx
images:
  - source: quay.io/keycloak/keycloak:26.6.2
    digest: sha256:REPLACE
    dest: ${ECR}/keycloak/keycloak:26.6.2
  - source: docker.io/library/busybox:1.36
    digest: sha256:REPLACE
    dest: ${ECR}/library/busybox:1.36
```

A tiny mirror script that reads it:

```bash
#!/usr/bin/env bash
set -euo pipefail
yq -r '.images[] | .source + " " + .dest' airgap-manifest.yaml | \
while read -r src dst; do
  echo "==> $src  ->  $dst"
  repo="${dst#*/}"; repo="${repo%:*}"
  aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability IMMUTABLE >/dev/null
  skopeo copy --all "docker://$src" "docker://$dst"
done
```

### 9.3 ECR pull-through cache — the middle path

If you are at Level 1 or a soft Level 2 (some controlled egress allowed), **ECR pull-through cache** saves enormous effort. You define a rule once, and the first pull of any image fetches and caches it automatically.

```bash
aws ecr create-pull-through-cache-rule \
  --ecr-repository-prefix quay \
  --upstream-registry-url quay.io \
  --credential-arn arn:aws:secretsmanager:...   # if the upstream needs auth
```

Then reference images as `${ECR}/quay/keycloak/keycloak:26.6.2` and ECR fetches them on demand.

**The catch:** the *first* pull needs outbound internet from ECR's side, and if you use interface endpoints, AWS documents that the first pull-through fetch requires a NAT path. So this is **not** a true air-gap solution. It is excellent for Level 1 and for your bridge/staging environment.

### 9.4 Building an optimized Keycloak image (recommended)

Keycloak has a build step that pre-computes its configuration. Doing it at container build time instead of every pod start cuts startup from about 60 seconds to about 10, and lets you add your own trusted CA certificates — which air-gapped environments almost always need.

```dockerfile
# Dockerfile — build on the bridge host, push to ECR
FROM quay.io/keycloak/keycloak:26.6.2 AS builder

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn
ENV KC_CACHE_STACK=kubernetes
ENV KC_FEATURES=token-exchange,admin-fine-grained-authz

# Add your internal certificate authority so Keycloak trusts your LDAP,
# your SMTP relay, and your internal services.
COPY internal-ca.crt /tmp/internal-ca.crt
USER root
RUN keytool -importcert -noprompt -trustcacerts \
      -alias internal-ca -file /tmp/internal-ca.crt \
      -keystore /opt/keycloak/conf/truststores/internal.p12 \
      -storetype PKCS12 -storepass changeit
USER 1000

RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.6.2
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

```bash
docker build -t ${ECR}/keycloak/keycloak-optimized:26.6.2-1 .
docker push ${ECR}/keycloak/keycloak-optimized:26.6.2-1
```

Then in `values.yaml`, point `image.repository` at the optimized image and change the args:

```yaml
image:
  repository: <account>.dkr.ecr.us-east-1.amazonaws.com/keycloak/keycloak-optimized
  tag: "26.6.2-1"
args:
  - "start"
  - "--optimized"
```

> `--optimized` **only** works with a pre-built image. Using it on the stock image gives you a confusing startup failure.

### 9.5 Verifying supply chain integrity offline

Because you cannot check with the internet later, check now and record it:

```bash
# Verify the upstream chart's provenance if it is signed
helm verify ./offline/keycloakx-7.2.0.tgz

# Record digests of everything
skopeo inspect docker://${ECR}/keycloak/keycloak:26.6.2 --format '{{.Digest}}' >> receipts.txt

# Scan before it goes in — you cannot scan easily once it is inside
trivy image quay.io/keycloak/keycloak:26.6.2 --severity HIGH,CRITICAL
```

Then install by digest so nothing can be swapped later:

```bash
helm install keycloak "oci://${ECR}/keycloakx@sha256:<chart-digest>" -f values.yaml
```

---

## 10. Choices and trade-offs

### 10.1 How to run worker nodes

| Option | Pros | Cons | Use it when |
|---|---|---|---|
| **Managed node group** | AWS handles provisioning, draining, upgrades. Simple. Predictable. Works air-gapped with the fewest moving parts. | Slower scaling. You pay for idle capacity. Fixed instance shapes. | **Steady workloads like Keycloak.** The default choice. |
| **Self-managed node group** | Total control — any OS, any bootstrap, any AMI. | You own upgrades, draining, and every failure. Significant ongoing work. | You have hard requirements the managed path cannot meet (an unusual OS, a specific kernel). |
| **Karpenter NodePool** | Fast (30–60s), excellent bin-packing, big cost savings on bursty clusters, automatic AMI drift replacement. | A controller to run and upgrade. More VPC endpoints. Continuous node churn unless budgeted. | Bursty, varied workloads. Large clusters. |
| **EKS Auto Mode** | Least operational work of all. AWS manages nodes and core add-ons end to end. | Management fee. Least control. Harder to prove compliance about node hardening. | Teams who do not want to think about nodes at all. |
| **Fargate** | No nodes whatsoever. Strong pod isolation. | No DaemonSets, no privileged pods, limited to certain sizes, no GPUs, slower starts, and it does not fit Keycloak's clustering well. | Small, isolated, stateless workloads. **Not Keycloak.** |

### 10.2 How to deploy Keycloak

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **codecentric `keycloakx` chart** | Uses the official upstream image. Actively maintained (7.2.0 → Keycloak 26.6.2). Plain Helm, easy to mirror. External DB by design. | Community-maintained, not by the Keycloak team. Values keys change between majors. | **Good default for air-gapped Helm.** Used in this guide. |
| **Keycloak Operator (official)** | Maintained by the Keycloak project. CRD-driven: `Keycloak` and `KeycloakRealmImport` objects. Handles StatefulSet, discovery, and rolling updates for you. Realm config as code. | Two things to mirror and upgrade (operator + Keycloak). Less direct control over the generated manifests. Fewer Helm-shaped escape hatches. | **Best long-term choice** if you are comfortable with operators. Strongest for realm-as-code. |
| **Bitnami `keycloak` chart** | Historically the most popular. Great docs. | ⚠️ Since Aug 2025 the free images moved to a frozen `bitnamilegacy` repo; the maintained secure images need a paid subscription. | **Do not start here in 2026.** Migrate if you are on it. |
| **HelmForge `keycloak` chart** | Explicitly built as a Bitnami replacement. Tracks the official `quay.io/keycloak/keycloak` image. Apache 2.0, Cosign-signed. Enforces production-mode safety checks at render time. | Newer, smaller community, shorter track record. | Worth evaluating, especially if you liked Bitnami's values structure. |
| **Write your own chart / plain manifests** | You control every byte. Nothing to mirror but images. Easiest to audit. | You maintain it forever, including every Keycloak upgrade quirk. | Reasonable for teams with strong platform engineering and strict audit needs. |

### 10.3 Where the database goes

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Amazon RDS PostgreSQL, Multi-AZ** | Managed backups, automatic failover, point-in-time recovery, patching. Lives in your VPC, so it works air-gapped with no extra work. | Costs more than a pod. | **Do this.** Keycloak's database *is* your identity data. |
| **Aurora PostgreSQL** | Faster failover, better read scaling, storage auto-grows. | More expensive. Version support lags plain PostgreSQL slightly. | Good at large scale. |
| **PostgreSQL in the cluster (a sub-chart)** | Free. One `helm install`. | You now operate a database on Kubernetes. Backups, failover, and upgrades are yours. A bad node drain can lose data. | **Development only.** Never production. |
| **CloudNativePG operator** | A genuinely good Postgres-on-Kubernetes operator with real HA and backups. | Still your responsibility. Another operator to mirror and upgrade. | Defensible if you have no RDS access — but RDS is easier. |

### 10.4 How traffic gets in

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **AWS Load Balancer Controller → ALB** | Native AWS. ACM certificates, WAF, access logs, health checks on port 9000. Internal scheme keeps it inside the VPC. | An extra controller to run. One ALB per Ingress unless you use group annotations. | **Recommended.** |
| **NLB (Service type LoadBalancer)** | Layer 4, very fast, preserves source IP, TLS passthrough possible. | No path routing, no WAF, and you must terminate TLS in Keycloak itself. | Good when you need end-to-end TLS to the pod. |
| **Ingress-NGINX** | Familiar. Huge ecosystem. | ⚠️ **Retired upstream in March 2026.** No more security patches. | Do not build new systems on it. Plan migration if you are on it. |
| **Gateway API** | The Kubernetes project's direction of travel. Cleaner role separation. | Newer; controller support varies. | Where things are heading. Consider it for greenfield. |

---

## 11. Best practices checklist

### Cluster and nodes

- [ ] Stay in **standard support**. Extended support costs roughly 6× on the control plane and forces an upgrade eventually anyway.
- [ ] Upgrade one minor version at a time. Use **cluster insights** first: `aws eks list-insights --cluster-name $CLUSTER`.
- [ ] Know that **version rollback** now exists (7-day window) — but treat it as a safety net, not a plan.
- [ ] `HttpTokens: required` (IMDSv2) on every launch template, no exceptions.
- [ ] Encrypt every EBS volume.
- [ ] Never use `$Latest` for a launch template version in a node group.
- [ ] Separate IAM roles per node group. Do not share one role across the cluster.
- [ ] Prefer **EKS Pod Identity** over IRSA for new setups — simpler, no OIDC provider trust juggling, and it needs only the `eks-auth` endpoint.
- [ ] `maxUnavailable=1` for anything that matters.
- [ ] Use **SSM Session Manager**, not SSH keys.
- [ ] Tag everything: `Environment`, `Workload`, `CostCenter`, `Owner`.

### Keycloak specifically

- [ ] **External database, always.** RDS Multi-AZ.
- [ ] **Three replicas** across **three AZs**. Odd number for clean Infinispan quorum.
- [ ] Verify the cluster actually formed — check the Infinispan view count after every deploy.
- [ ] Memory `requests == limits`, and `-XX:MaxRAMPercentage=70` so the JVM stays under the limit.
- [ ] `PodDisruptionBudget` with `minAvailable: 2`.
- [ ] Production mode with `KC_HOSTNAME` set and `KC_HOSTNAME_STRICT=true`.
- [ ] `KC_PROXY_HEADERS=xforwarded` when behind a load balancer.
- [ ] Health probes on **port 9000**, not 8080.
- [ ] Generous `startupProbe` — database migrations on a first boot take time.
- [ ] Delete the bootstrap admin after creating a real one. Enforce MFA on all admins.
- [ ] Do **not** expose the admin console publicly. Use a separate internal hostname (`KC_HOSTNAME_ADMIN`) or block `/admin` at the load balancer.
- [ ] Back up the database *and* export realms regularly. Test a restore.
- [ ] Never skip a Keycloak major version — database migrations are sequential. Test upgrades on a copy of production data first.
- [ ] NetworkPolicy: allow 8080 from the ingress, 7800 between Keycloak pods, 9000 only from monitoring.

### Air-gapped

- [ ] Maintain `airgap-manifest.yaml` in git with versions **and digests**.
- [ ] Re-run "find every image" after **every** chart version bump.
- [ ] `IMMUTABLE` tags in ECR.
- [ ] `scanOnPush=true`, and scan on the bridge host before mirroring.
- [ ] Vendor chart dependencies into the `.tgz` before copying it across.
- [ ] Test the whole install in a **staging air-gapped** environment first. A staging cluster with internet access proves nothing.
- [ ] Set an ECR lifecycle policy so old images do not accumulate forever.
- [ ] Document the bridge-host procedure so it is not one person's private knowledge.

---

## 12. Troubleshooting

| Symptom | Most likely cause | How to check | Fix |
|---|---|---|---|
| **Nodes never appear in `kubectl get nodes`** | Bad user-data indentation, or `nodeadm` failed | EC2 console → instance → Actions → Monitor → Get system log. Or `sudo journalctl -u nodeadm-config -u nodeadm-run` via SSM. | Fix the YAML spacing. No tabs, no trailing lines after `--//--`. |
| Same, with a custom AMI | Missing `spec.cluster` fields | Look for `nodeadm` errors about missing cluster metadata | Add `name`, `apiServerEndpoint`, `certificateAuthority`, `cidr` (step 4b) |
| Same, air-gapped | Missing VPC endpoints | `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=vpc-xxx` | Add `ecr.api`, `ecr.dkr`, `s3` gateway, `ec2`, `sts` |
| Same | Endpoint security group blocks the nodes | Check inbound 443 from the node SG | Open 443 from node SG to endpoint SG |
| **"Client error on launch"** | KMS key policy does not allow the node role or EKS | `aws kms get-key-policy --key-id ...` | Add the node role and `AWSServiceRoleForAutoScaling` to the key policy |
| **Pod stuck `Pending`** | Toleration missing | `kubectl describe pod X \| grep -A5 Events` — look for "had untolerated taint" | Add the `tolerations` block to values |
| Pod stuck `Pending` | `nodeSelector` matches nothing | `kubectl get nodes --show-labels \| grep workload` | Fix the label or the selector |
| Pod stuck `Pending` | Topology spread cannot be satisfied | Events mention "didn't match pod topology spread constraints" | You need at least as many nodes as zones. Check all three nodes are `Ready`. |
| **`ImagePullBackOff`** | Image not mirrored | `kubectl describe pod X \| grep -i image` | Mirror it. Re-run the "find every image" step. |
| `ImagePullBackOff` | Node role lacks ECR pull rights | Check attached policies on the node role | Attach `AmazonEC2ContainerRegistryPullOnly` |
| `ImagePullBackOff` | Wrong architecture mirrored | `skopeo inspect --raw docker://... \| jq .manifests` | Re-copy with `skopeo copy --all` |
| **Keycloak `CrashLoopBackOff`** | Cannot reach the database | `kubectl logs` — look for JDBC connection errors | Check RDS security group allows 5432 from the node SG |
| Keycloak crash | `KC_HOSTNAME` missing in production mode | Logs say hostname is not configured | Set `KC_HOSTNAME` |
| Keycloak crash | `--optimized` on a non-optimized image | Logs mention a missing build | Remove `--optimized` or build the image (section 9.4) |
| **Users randomly logged out** | Replicas did not cluster | `kubectl logs ... \| grep ISPN000094` — view shows 1 member | Fix `jgroups.dns.query` to match the real headless service DNS name |
| **Infinite redirect loop at login** | Proxy headers not trusted | Redirects point at `http://` or an internal IP | Set `KC_PROXY_HEADERS=xforwarded` and `KC_HOSTNAME` |
| **ALB shows targets unhealthy** | Health check hitting 8080 instead of 9000 | ALB target group health check config | Set `alb.ingress.kubernetes.io/healthcheck-port: "9000"` and path `/health/ready` |
| **Helm: "chart not found"** | Repo name does not match chart name in ECR | `aws ecr describe-repositories` | The ECR repo must be named exactly `keycloakx` |
| **Helm: registry login fails** | Helm 4 rejects the `https://` prefix | — | `helm registry login myreg.example.com` — domain only |
| **Helm: `HELM_EXPERIMENTAL_OCI` error** | Leftover Helm 3 environment variable | `env \| grep HELM` | `unset HELM_EXPERIMENTAL_OCI` |
| **Helm: dependency download fails** | Dependencies not vendored | `tar -tzf chart.tgz \| grep charts/` | Run `helm dependency update` before `helm package` |
| **A value in `values.yaml` has no effect** | Key name is wrong — Helm ignores unknown keys silently | `helm show values <chart> > defaults.yaml` and diff | Match the chart's actual key names |
| **Karpenter launches nothing** | Subnets or security groups not tagged | `kubectl describe ec2nodeclass keycloak` | Add `karpenter.sh/discovery=<cluster>` tags |
| Karpenter `EC2NodeClass NotReady` | `alias: al2023@latest` cannot reach SSM | Controller logs | Add the `ssm` VPC endpoint |

### Useful diagnostic one-liners

```bash
# Why is this pod not scheduling?
kubectl -n keycloak describe pod <pod> | sed -n '/Events/,$p'

# What does the node actually think its labels and taints are?
kubectl get node <node> -o jsonpath='{.metadata.labels}{"\n"}{.spec.taints}{"\n"}'

# Node group health, straight from the AWS side
aws eks describe-nodegroup --cluster-name $CLUSTER --nodegroup-name $NG_NAME \
  --query 'nodegroup.health.issues'

# What did the launch template actually contain?
aws ec2 describe-launch-template-versions --launch-template-id $LT_ID \
  --versions 1 --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
  --output text | base64 -d

# Get a shell on a node without SSH
aws ssm start-session --target i-0abc123

# Everything Helm actually applied
helm -n keycloak get manifest keycloak | less
helm -n keycloak get values keycloak
helm -n keycloak history keycloak
```

---

## Appendix A: one big copy-paste script

This is Part A (nodes) end to end. Read it before running it. Replace every `REPLACE-ME`.

```bash
#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIGURE ME ----------
export AWS_REGION=us-east-1
export CLUSTER=REPLACE-ME
export SUBNET_A=REPLACE-ME
export SUBNET_B=REPLACE-ME
export SUBNET_C=REPLACE-ME
# ----------------------------------

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export ECR=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
export NG_NAME=keycloak-ng
export LT_NAME=keycloak-node-lt
export NODE_ROLE_NAME=EKSKeycloakNodeRole

echo "==> 1/5 IAM role"
cat > /tmp/trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust.json 2>/dev/null || echo "  role exists"
for p in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryPullOnly \
         AmazonEKS_CNI_Policy AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/$p"
done
NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query Role.Arn --output text)

echo "==> 2/5 user data"
cat > /tmp/user-data.txt << 'EOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: 58
      kubeReserved:
        cpu: "200m"
        memory: "1Gi"
        ephemeral-storage: "2Gi"
    flags:
      - "--node-labels=workload=keycloak,tier=identity"

--//--
EOF
USERDATA_B64=$(base64 -w0 /tmp/user-data.txt 2>/dev/null || base64 -i /tmp/user-data.txt | tr -d '\n')

echo "==> 3/5 launch template"
cat > /tmp/lt.json << EOF
{
  "BlockDeviceMappings":[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":100,
    "VolumeType":"gp3","Iops":3000,"Throughput":125,"Encrypted":true,
    "DeleteOnTermination":true}}],
  "MetadataOptions":{"HttpEndpoint":"enabled","HttpTokens":"required",
    "HttpPutResponseHopLimit":2},
  "Monitoring":{"Enabled":true},
  "TagSpecifications":[{"ResourceType":"instance","Tags":[
    {"Key":"Name","Value":"eks-${CLUSTER}-keycloak-node"},
    {"Key":"Workload","Value":"keycloak"}]}],
  "UserData":"${USERDATA_B64}"
}
EOF
aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
  --version-description "keycloak nodes v1" \
  --launch-template-data file:///tmp/lt.json 2>/dev/null || echo "  LT exists"
LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text)

echo "==> 4/5 node group (this takes ~5 minutes)"
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
  --instance-types m7i.xlarge m6i.xlarge \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --update-config maxUnavailable=1 \
  --launch-template "id=${LT_ID},version=1" \
  --labels workload=keycloak,tier=identity \
  --taints 'key=dedicated,value=keycloak,effect=NO_SCHEDULE' \
  --tags Workload=keycloak

aws eks wait nodegroup-active --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME"

echo "==> 5/5 verify"
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl get nodes -l workload=keycloak -o wide
echo "Done. LT_ID=$LT_ID  NODE_ROLE_ARN=$NODE_ROLE_ARN"
```

### Tearing it down

```bash
helm -n keycloak uninstall keycloak
kubectl delete namespace keycloak
aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME"
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME"
aws ec2 delete-launch-template --launch-template-name "$LT_NAME"
# IAM role last — detach policies first
```

---

## Appendix B: glossary

**AL2023** — Amazon Linux 2023, the default EKS node operating system today.
**AMI** — Amazon Machine Image; the disk snapshot a node boots from.
**Bridge host** — a machine with internet access used to download and mirror artifacts into an air-gapped environment.
**CRD** — Custom Resource Definition; how operators add new object types like `NodePool` to Kubernetes.
**Digest** — the `sha256:...` fingerprint of an image or chart. Unlike a tag, it cannot be changed.
**Drain** — safely evicting all pods from a node before shutting it down.
**EC2NodeClass** — Karpenter's AWS-side node settings object; the launch-template equivalent.
**Headless service** — a Kubernetes Service with no cluster IP, used so pods can find each other by DNS. Keycloak clustering depends on it.
**Infinispan** — the in-memory data grid Keycloak uses to share sessions between replicas.
**IRSA** — IAM Roles for Service Accounts; the older way to give pods AWS permissions. Needs the `sts` endpoint.
**JGroups** — the library Infinispan uses to discover and talk to peers.
**Launch template** — the EC2 recipe card for building instances.
**Managed node group** — an AWS-managed group of worker nodes.
**MNG** — abbreviation for managed node group.
**nodeadm** — the AL2023 program that joins a node to an EKS cluster using a `NodeConfig` YAML document.
**NodePool** — Karpenter's Kubernetes-side rules object.
**OCI** — Open Container Initiative; the standard that lets registries store both images and Helm charts.
**PDB** — PodDisruptionBudget; a rule limiting how many pods can be down at once during voluntary disruptions.
**Pod Identity** — the modern EKS way to give pods AWS permissions. Needs the `eks-auth` endpoint.
**Realm** — a Keycloak tenant: its own users, clients, and settings.
**skopeo** — a tool for copying container images between registries without a Docker daemon.
**Sneakernet** — moving data physically, on removable media, because there is no network path.
**Taint / toleration** — a keep-out sign on a node, and the hall pass a pod needs to ignore it.
**Topology spread constraint** — a rule that spreads pods evenly across zones or nodes.
**VPC endpoint** — a private doorway from your VPC to an AWS service, bypassing the internet.

---

## A note on verification

Command syntax, chart value keys, and API fields all drift between versions. Before you run anything here against production:

1. `helm show values <your-chart> --version <your-version>` and compare against the values file in section 6.
2. `aws eks create-nodegroup help` to confirm flags for your AWS CLI version.
3. Test the entire sequence in a staging environment that has the **same** network restrictions as production. A staging cluster with internet access will not catch the problems that matter.

*Guide written July 2026 against EKS 1.34–1.36, Karpenter v1.11.x, Helm 4.1.x, Keycloak 26.6.x.*
