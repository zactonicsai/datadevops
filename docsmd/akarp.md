# Karpenter on EKS — Complete Example for Scheduled Scale-to-Zero Data Platforms

This is the deep-dive on the "let Karpenter handle the nodes" pattern from the earlier guides. The idea in one line:

> **You scale the *pods* to zero on a schedule (KEDA/CronJob). Karpenter notices the nodes are empty and deletes them by itself. In the morning, pods come back, Karpenter launches fresh nodes in seconds.**

You never write a node schedule. You never touch a node group. Karpenter is the janitor that closes empty classrooms and opens new ones on demand.

> **Versions used here:** Karpenter **1.13.0** (current 1.x line) on **Kubernetes 1.30+**, using the **stable v1 APIs** — `NodePool` (`karpenter.sh/v1`) and `EC2NodeClass` (`karpenter.k8s.aws/v1`). The old `Provisioner`/`AWSNodeTemplate` (v1beta1) objects are gone. If you're on v0.x, migrate before following this.

---

## Table of Contents

1. [How Karpenter fits the scale-to-zero pattern](#1-how-it-fits)
2. [The two objects you configure](#2-the-two-objects)
3. [Prerequisites & the one golden rule](#3-prerequisites)
4. [Install — CLI / Helm](#4-install)
5. [Install — Terraform](#5-terraform)
6. [The full data-platform example (Kafka, NiFi, OpenSearch)](#6-full-example)
7. [Consolidation: the knob that saves the money](#7-consolidation)
8. [Protecting stateful pods from disruption](#8-protecting-stateful)
9. [Disruption budgets: freeze churn during windows](#9-budgets)
10. [Tying it to the schedule (the full daily cycle)](#10-daily-cycle)
11. [Team tracking with tags & labels](#11-tags)
12. [Verify & observe](#12-verify)
13. [Gotchas checklist](#13-gotchas)

---

## 1. How Karpenter fits the scale-to-zero pattern <a name="1-how-it-fits"></a>

Traditional autoscaling (Cluster Autoscaler) works on **fixed node groups** — you predefine instance types and Auto Scaling Groups. Karpenter is different: it watches for **unschedulable pods**, then launches the *cheapest node that fits* in seconds, and — critically for us — **removes nodes as soon as they're no longer needed.**

The daily cycle for a scheduled data platform:

```
7:00 PM  KEDA scales NiFi → 0
7:20 PM  KEDA scales Kafka → 0        (pods are now gone)
7:25 PM  Karpenter sees empty nodes → terminates EC2 instances   💰 savings start
         ... cluster runs on ~zero data-plane nodes overnight ...
7:00 AM  KEDA scales Kafka → 3        (3 pods now Pending)
7:00 AM  Karpenter sees Pending pods → launches nodes in ~60s
7:20 AM  KEDA scales NiFi → 3         (NiFi's init container waits for Kafka)
7:20 AM  Karpenter launches more nodes for NiFi
```

**You only schedule pods.** Nodes follow automatically. That is the whole point.

---

## 2. The two objects you configure <a name="2-the-two-objects"></a>

Karpenter's v1 model has exactly two things you write (a third, `NodeClaim`, is created internally — you don't touch it):

| Object | API group | What it holds |
|---|---|---|
| **NodePool** | `karpenter.sh/v1` | The *shape* of nodes allowed: which instance families/sizes, spot vs on-demand, disruption policy, limits, budgets |
| **EC2NodeClass** | `karpenter.k8s.aws/v1` | The *AWS specifics*: AMI family, the IAM role nodes assume, subnet & security-group selectors, disk config |

```
   Pending Pod
        │
        ▼
   NodePool  ──references──►  EC2NodeClass  ──launches──►  EC2 instance
 (what shape?)              (how, on AWS?)
```

One EC2NodeClass can back many NodePools.

---

## 3. Prerequisites & the one golden rule <a name="3-prerequisites"></a>

You need:

- An EKS cluster on Kubernetes **1.30+**
- CLIs: `aws`, `kubectl`, `helm`, and `eksctl` (optional but handy)
- Permission to create IAM roles
- **Tagged subnets and security groups** — Karpenter finds them by tag:

```bash
export CLUSTER_NAME=my-cluster

# Tag each subnet Karpenter should launch nodes into
aws ec2 create-tags \
  --resources subnet-aaaa subnet-bbbb subnet-cccc \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}

# Tag the cluster security group
aws ec2 create-tags \
  --resources sg-xxxx \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
```

> Missing tags = Karpenter launches nothing and logs a "selector matched no subnets/security groups" error. This is the #1 first-time mistake.

### 🔑 The golden rule

**Karpenter must NOT run on a node that Karpenter manages.** If it did, consolidating that node would kill the controller mid-decision. Run the Karpenter controller itself on a **small managed node group** (2 nodes) or on **Fargate**. Everything else — Kafka, NiFi, OpenSearch — runs on Karpenter-provisioned capacity.

---

## 4. Install — CLI / Helm <a name="4-install"></a>

### Step 1 — Create the node IAM role and controller role

The Getting Started flow provisions two IAM roles via CloudFormation:

- `KarpenterNodeRole-<cluster>` — the role EC2 nodes assume
- `KarpenterControllerRole-<cluster>` — the role the controller uses to call EC2

```bash
export KARPENTER_VERSION=1.13.0
export CLUSTER_NAME=my-cluster
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Deploy the IAM roles + SQS interruption queue via the official CloudFormation template
TEMPOUT=$(mktemp)
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "${TEMPOUT}"

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
```

This also creates the **SQS interruption queue** — Karpenter listens on it for Spot interruption notices, scheduled maintenance, and instance-stop events so it can gracefully move pods before the node dies.

### Step 2 — Let the node role join the cluster

```bash
eksctl create iamidentitymapping \
  --cluster "${CLUSTER_NAME}" \
  --arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --username "system:node:{{EC2PrivateDNSName}}" \
  --group system:bootstrappers \
  --group system:nodes
```

### Step 3 — Install Karpenter with Helm

```bash
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=Karpenter-${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --wait
```

> Modern setups prefer **EKS Pod Identity** over IRSA; if you use it, drop the service-account role annotation and associate the role via `aws eks create-pod-identity-association` instead.

### Step 4 — Verify the controller is up

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter
```

---

## 5. Install — Terraform <a name="5-terraform"></a>

The community `terraform-aws-eks` project ships a `karpenter` sub-module that builds all the IAM plumbing. Then `helm_release` installs the controller and you apply the NodePool/EC2NodeClass as manifests.

```hcl
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  # Use EKS Pod Identity (simpler than IRSA)
  enable_pod_identity             = true
  create_pod_identity_association = true

  # The node role needs SSM + ECR pull; the module attaches these
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# Install the Karpenter controller
resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.13.0"

  set {
    name  = "settings.clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }
}
```

Then apply the NodePool + EC2NodeClass. You can inline them with `kubernetes_manifest` or (cleaner) keep them as YAML applied by your GitOps tool:

```hcl
resource "kubernetes_manifest" "ec2nodeclass_data" {
  manifest = yamldecode(file("${path.module}/manifests/ec2nodeclass-data.yaml"))
}

resource "kubernetes_manifest" "nodepool_data" {
  manifest   = yamldecode(file("${path.module}/manifests/nodepool-data.yaml"))
  depends_on = [kubernetes_manifest.ec2nodeclass_data]
}
```

> ⚠️ `kubernetes_manifest` reads the CRD schema at *plan* time, so the Karpenter CRDs must already exist. In practice, apply the controller first (`terraform apply -target=helm_release.karpenter`), then the NodePools — or manage the manifests with Argo CD / Flux instead of Terraform to avoid the ordering headache.

---

## 6. The full data-platform example (Kafka, NiFi, OpenSearch) <a name="6-full-example"></a>

Here's a realistic two-NodePool setup: a **system** pool (on-demand, stable, for the platform's brains) and a **data** pool (mixed spot/on-demand, for the heavy stateful services).

### EC2NodeClass (shared AWS config)

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: data-platform
spec:
  amiFamily: AL2023
  amiSelectorTerms:
    - alias: al2023@latest        # pin to a version in prod, e.g. al2023@v20250601
  role: "KarpenterNodeRole-my-cluster"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  # Give data nodes a big, fast root disk for Kafka/OpenSearch segments
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        iops: 10000
        throughput: 500
        deleteOnTermination: true
  # Tags applied to every EC2 instance Karpenter launches (for cost tracking — see §11)
  tags:
    team: data-engineering
    cost-center: cc-4521
    environment: dev
    managed-by: karpenter
```

### NodePool 1 — system (small, always-on-ish, on-demand)

For CoreDNS, KEDA, operators, and the Karpenter-adjacent glue that should be stable.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: system
spec:
  template:
    metadata:
      labels:
        pool: system
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: data-platform
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]         # system = stable, no spot
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["large", "xlarge"]
      expireAfter: 720h                  # recycle nodes every 30 days for fresh AMIs
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "100"
    memory: 200Gi
```

### NodePool 2 — data (heavy, spot-friendly, stateful workloads)

For Kafka, NiFi, OpenSearch. Wide instance selection = better spot availability and cheaper packing.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: data
spec:
  template:
    metadata:
      labels:
        pool: data
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: data-platform
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]    # allow Graviton for extra savings
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"] # spot-first, falls back to on-demand
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["r", "m"]            # r = memory-heavy, good for Kafka/OpenSearch
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["xlarge", "2xlarge", "4xlarge"]
      expireAfter: 720h
  disruption:
    # WhenEmptyOrUnderutilized removes empty nodes AND repacks underused ones.
    # This is what deletes nodes after your pods scale to zero at night.
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    budgets:
      - nodes: "20%"                     # normally, disrupt at most 20% at once
  limits:
    cpu: "1000"
    memory: 4000Gi
```

> **Weighting / fallback:** Karpenter prefers Spot automatically when both are allowed and will fall back to on-demand if Spot is unavailable. For strict "prefer on-demand for stateful" you'd split into separate pools with `weight:` or use taints — see §8.

---

## 7. Consolidation: the knob that saves the money <a name="7-consolidation"></a>

This is the heart of the scale-to-zero story.

| Policy | Behavior | Use for |
|---|---|---|
| `WhenEmpty` | Only removes nodes that have **zero** non-daemonset pods | Conservative; **safest for stateful** data nodes |
| `WhenEmptyOrUnderutilized` | Removes empty nodes **and** repacks underutilized ones onto fewer nodes | Default; maximum savings |

`consolidateAfter` = how long a node must sit empty/underutilized before Karpenter acts. Short (`1m`) reacts fast at night; longer (`15m`) avoids thrashing on bursty workloads.

**For scheduled scale-to-zero, both policies delete the empty overnight nodes** — because after pods hit zero, the nodes are genuinely empty. The difference only matters *during the day*:

- `WhenEmptyOrUnderutilized` will also try to **move** a running Kafka pod to pack it more tightly → risky for stateful services mid-day.
- `WhenEmpty` leaves running pods alone and only cleans up once they're gone.

**Recommendation for a data platform:**

```yaml
# data pool: be gentle during the day, but still clean up at night
disruption:
  consolidationPolicy: WhenEmpty      # don't shuffle running Kafka/OpenSearch
  consolidateAfter: 2m                # but reclaim fast once pods scale to zero
```

You still get the full overnight savings (empty nodes disappear), without Karpenter reshuffling stateful pods during business hours. Combine with §8 for belt-and-suspenders.

---

## 8. Protecting stateful pods from disruption <a name="8-protecting-stateful"></a>

Karpenter has two disruption modes and you must guard against both for Kafka/NiFi/OpenSearch:

1. **Voluntary** — consolidation, drift, expiry (Karpenter's own decisions)
2. **Involuntary** — Spot interruptions, hardware failures (AWS's decisions)

### Tool 1 — `karpenter.sh/do-not-disrupt` annotation

Put this on any pod Karpenter must never voluntarily evict:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
spec:
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"   # Karpenter won't touch this pod's node
    spec:
      terminationGracePeriodSeconds: 300       # let brokers hand off leadership
      containers:
        - name: kafka
          # ...
```

> This blocks **voluntary** disruption only. Karpenter won't consolidate, drift, or expire a node running this pod. It does **not** protect against Spot reclaim — for that, run stateful services **on-demand** (see below).

### Tool 2 — keep stateful services off Spot

Split the data pool, or add a taint + on-demand-only pool for the truly stateful tier:

```yaml
# on-demand pool for Kafka/OpenSearch masters — no Spot surprises
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: data-stateful
spec:
  template:
    spec:
      taints:
        - key: workload
          value: stateful
          effect: NoSchedule
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]           # no Spot for quorum services
        # ... instance requirements ...
  disruption:
    consolidationPolicy: WhenEmpty          # only reclaim when truly empty
    consolidateAfter: 2m
```

Then tolerate the taint on Kafka/OpenSearch:

```yaml
spec:
  tolerations:
    - key: workload
      operator: Equal
      value: stateful
      effect: NoSchedule
```

### Tool 3 — PodDisruptionBudgets

Protect quorum during any drain:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kafka-pdb
spec:
  minAvailable: 2          # never drop below 2 of 3 brokers at once
  selector:
    matchLabels:
      app: kafka
```

### Tool 4 — `terminationGracePeriod` on the NodePool

A hard ceiling on how long Karpenter waits for a node to drain — even `do-not-disrupt` pods get force-removed after this (useful so a stuck pod can't block a node forever):

```yaml
spec:
  template:
    spec:
      terminationGracePeriod: 1h     # NodePool-level hard cap on drain time
```

> Order of protection: `do-not-disrupt` (won't start draining) → PDB (won't break quorum while draining) → `terminationGracePeriod` (won't wait forever). Use all three for data services.

---

## 9. Disruption budgets: freeze churn during windows <a name="9-budgets"></a>

Budgets cap how much Karpenter can disrupt, and can **schedule zero-disruption windows** — e.g., "never consolidate during business hours" so your data platform is rock-steady while people use it.

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: data
spec:
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    budgets:
      # Rule 1: normally, disrupt at most 20% of data nodes at once
      - nodes: "20%"

      # Rule 2: during business hours (9am–5pm Mon–Fri UTC), allow ZERO disruption.
      #         Keeps Kafka/NiFi/OpenSearch untouched while teams work.
      - schedule: "0 9 * * mon-fri"
        duration: 8h
        nodes: "0"
```

When multiple budgets overlap, **the most restrictive wins** — so during 9–5 the `"0"` rule freezes all voluntary disruption. Outside the window, the 20% rule applies and overnight empties get cleaned up.

> Note the schedule here is **UTC** by default — adjust the cron to your timezone. This budget is about *disruption pacing*, separate from the KEDA cron that scales pods. They work together: KEDA scales pods to zero at night → budgets allow Karpenter to reclaim the empties.

---

## 10. Tying it to the schedule (the full daily cycle) <a name="10-daily-cycle"></a>

Here's how Karpenter and the pod scheduler cooperate across a full day. **You configure the pod schedule; Karpenter reacts.**

```yaml
# KEDA scales the pods — Karpenter is NOT scheduled, it just responds
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-hours
  namespace: data-platform
spec:
  scaleTargetRef:
    kind: StatefulSet
    name: kafka
  minReplicaCount: 0
  triggers:
    - type: cron
      metadata:
        timezone: America/New_York
        start: "0 7 * * 1-5"     # Kafka up at 7:00 → Karpenter launches nodes ~60s later
        end: "20 19 * * 1-5"     # Kafka down at 7:20 PM (last)
        desiredReplicas: "3"
```

Timeline:

| Time | Pod action (KEDA) | Karpenter reaction |
|---|---|---|
| 7:00 AM | Kafka → 3 replicas | 3 pods Pending → launches `r`-family nodes in ~60s |
| 7:20 AM | NiFi → 3 (init waits for Kafka) | launches nodes for NiFi as its pods schedule |
| 9:00 AM | — | disruption **frozen** by budget (business hours) |
| 5:00 PM | — | budget window ends; normal 20% pacing resumes |
| 7:00 PM | NiFi → 0 | NiFi nodes become empty |
| 7:20 PM | Kafka → 0 | Kafka nodes become empty |
| ~7:22 PM | — | `consolidateAfter` elapses → **terminates all empty data nodes** 💰 |
| overnight | 0 data pods | 0 data nodes — you pay only for EBS + the tiny system pool |

**Result:** roughly 12 hours × 5 days of compute cost eliminated, with zero node-level scheduling on your part.

---

## 11. Team tracking with tags & labels <a name="11-tags"></a>

Karpenter propagates tags and labels so you can attribute cost per team (the question from the first guide).

### AWS tags on the EC2 instances

Set in the EC2NodeClass `spec.tags` (shown in §6). Every instance Karpenter launches gets them, so **Cost Explorer / CUR** can group spend by `team` and `cost-center`:

```yaml
spec:
  tags:
    team: data-engineering
    cost-center: cc-4521
    environment: dev
```

### Kubernetes labels on the nodes

Set in the NodePool `spec.template.metadata.labels`. Useful for `nodeSelector`, and picked up by **EKS split cost allocation** to attribute node cost down to individual pods/teams:

```yaml
spec:
  template:
    metadata:
      labels:
        team: data-engineering
        pool: data
        cost-center: cc-4521
```

### Enforce it

A Kyverno policy can reject any NodePool/EC2NodeClass missing `team` and `cost-center` tags, so no untagged (untrackable) capacity ever gets created. Turn on **split cost allocation data for EKS** in your Cost and Usage Report, and now every team sees exactly what their overnight-sleeping cluster costs — and how much the schedule saved them.

---

## 12. Verify & observe <a name="12-verify"></a>

```bash
# See NodePools and their status
kubectl get nodepools
kubectl describe nodepool data

# See EC2NodeClass readiness (must be Ready or nothing schedules)
kubectl get ec2nodeclass data-platform -o wide

# Watch Karpenter's decisions live
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter | grep -E "launched|terminated|consolidat"

# See nodes Karpenter created (they carry karpenter.sh/nodepool label)
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Watch the internal capacity requests
kubectl get nodeclaims
```

**Test the whole loop** with a dummy workload:

```bash
# Scale a test deployment up → watch Karpenter launch a node
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7
kubectl scale deployment inflate --replicas=5
kubectl set resources deployment inflate --requests=cpu=1

# Scale to zero → watch the node get terminated after consolidateAfter
kubectl scale deployment inflate --replicas=0
# ...within a couple minutes: "deprovisioning via consolidation, terminating node"
```

Key metrics to dashboard (Karpenter exposes Prometheus metrics on `:8080/metrics`):

- `karpenter_nodes_created_total` / `karpenter_nodes_terminated_total`
- `karpenter_voluntary_disruption_decisions_total`
- `karpenter_pods_startup_duration_seconds`

---

## 13. Gotchas checklist <a name="13-gotchas"></a>

- [ ] **Karpenter controller runs on a managed node group or Fargate** — never on Karpenter-managed nodes. (The golden rule.)
- [ ] **Subnets and security groups are tagged** `karpenter.sh/discovery: <cluster>`. No tags = no nodes.
- [ ] **EC2NodeClass shows `Ready`** — if AMI/subnet/SG discovery fails, referencing NodePools are ignored silently.
- [ ] **Cluster Autoscaler is disabled** if you previously ran it — the two fight over the same pods.
- [ ] **Stateful services use `do-not-disrupt` + on-demand + PDB** — don't let consolidation or Spot reclaim break Kafka/OpenSearch quorum.
- [ ] **`WhenEmpty` for stateful pools** so Karpenter doesn't shuffle running data pods mid-day; you still get overnight empty-node cleanup.
- [ ] **`consolidateAfter` tuned** — short enough to reclaim nodes soon after nightly scale-down, long enough to avoid daytime thrash.
- [ ] **Disruption budget freezes business hours** if you want zero churn while teams work.
- [ ] **`expireAfter` set** (e.g., 720h) so nodes recycle onto patched AMIs; pin `amiSelectorTerms` to a version in prod (don't use `@latest`, it causes drift).
- [ ] **EBS volumes persist** and still cost money overnight — that's fine, it's the EC2 compute (the big cost) that Karpenter removes. For truly ephemeral data, consider instance-store.
- [ ] **Interruption queue configured** so Spot/maintenance events drain gracefully instead of hard-killing pods.
- [ ] **Init containers still required** on NiFi — Karpenter makes nodes appear fast, but it does nothing about Kafka-before-NiFi ordering. That's the pod scheduler's job.
- [ ] **Timezones**: KEDA cron uses `timezone`; Karpenter disruption-budget schedules default to **UTC**. Don't mix them up.

---

## The One-Sentence Summary

**Schedule your pods to zero with KEDA, set `consolidationPolicy` so empty nodes disappear, protect the stateful ones with `do-not-disrupt` + on-demand + PDBs — and Karpenter turns your overnight idle cluster into near-zero compute spend without you ever writing a node schedule.**
