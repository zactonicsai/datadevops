# Safely Turning EKS Nodes and Pods Off and On with Karpenter — A Complete, Dependency-Aware Tutorial

**Level:** Explained from the ground up (middle-school friendly language, production-grade content)
**Last verified:** July 2026 · Karpenter **v1.13.x** (stable `v1` API) · EKS Pod Identity · Kubernetes 1.31+

---

## Table of Contents

1. [Background: What problem are we solving?](#1-background)
2. [How Karpenter actually works (the mental model)](#2-how-karpenter-works)
3. [The Golden Rule: scale pods, not nodes](#3-the-golden-rule)
4. [Step-by-step setup (the main example)](#4-step-by-step-setup)
   - Step 0: Prerequisites
   - Step 1: Create the EKS cluster
   - Step 2: IAM roles and interruption queue
   - Step 3: Install Karpenter with Helm
   - Step 4: EC2NodeClass and NodePool
   - Step 5: Make workloads safe to disrupt (PDBs, grace periods, do-not-disrupt)
   - Step 6: Dependency-ordered shutdown and startup (the core of this tutorial)
   - Step 7: Align Karpenter disruption budgets with your schedule
   - Step 8: Test everything
5. [Why "just use EventBridge to kill the nodes" fails](#5-why-eventbridge-only-fails)
6. [Options compared: pros and cons](#6-options-compared)
7. [Best practices checklist](#7-best-practices)
8. [Troubleshooting](#8-troubleshooting)
9. [Glossary](#9-glossary)

---

<a name="1-background"></a>
## 1. Background: What problem are we solving?

Imagine your company runs applications on **Amazon EKS** (Elastic Kubernetes Service). EKS is Amazon's managed version of **Kubernetes**, the system that runs your application containers ("pods") on a fleet of virtual servers ("nodes", which are EC2 instances).

Every node costs money **every hour it runs**, even at 3 AM on a Sunday when nobody is using your dev environment. A very common cost-saving goal is:

> "Turn everything off at night and on weekends, and turn it back on in the morning — **without breaking anything**."

The "without breaking anything" part is where most teams get hurt. Applications have **dependencies**:

```
          depends on            depends on
Frontend ───────────► Backend ───────────► Database / Cache / Queue
```

- If you kill the **database** while the **backend** is still writing to it, you can corrupt or lose data.
- If you start the **frontend** before the **backend** is ready, users (or health checks, or synthetic monitors) see errors, alerts fire, and on-call engineers get paged for a "self-inflicted outage."

So a *safe* shutdown must happen **top-down** (consumers first, providers last):

```
SHUTDOWN ORDER:  1. Frontend  →  2. Backend  →  3. Database/Stateful services
STARTUP ORDER:   1. Database/Stateful services  →  2. Backend  →  3. Frontend
```

Startup is the mirror image (**bottom-up**), and each tier must be **verified healthy** before the next one starts.

**Karpenter** is the piece that handles the *nodes*. It is an open-source Kubernetes node autoscaler, originally built by AWS and donated to the CNCF, that launches right-sized EC2 instances in about 45–60 seconds when pods need them, and — crucially for us — **deletes nodes the moment they are empty**. That second behavior is what lets us turn "scale the pods to zero" into "the EC2 bill goes to (almost) zero" automatically and safely.

### Why not the old Cluster Autoscaler?

| | Karpenter | Cluster Autoscaler (CAS) |
|---|---|---|
| How it adds nodes | Calls EC2 `RunInstances` directly | Resizes pre-defined Auto Scaling Groups |
| Speed | ~45–60 seconds | ~3–4 minutes |
| Instance choice | Picks the cheapest instance that fits, from hundreds of types | Only the types in your ASGs |
| Removing empty nodes | Built-in "consolidation" that actively bin-packs and deletes | Slower, more conservative scale-down |
| Graceful node removal | Cordons + drains, respects PodDisruptionBudgets | Also drains, but via ASG lifecycle |

Run **one or the other, never both** — they both watch for unschedulable pods and will fight each other. (Note: **EKS Auto Mode** is AWS's fully-managed flavor of Karpenter; the concepts in this tutorial apply there too, but this guide covers self-managed Karpenter, which gives you full control over the settings we need.)

---

<a name="2-how-karpenter-works"></a>
## 2. How Karpenter actually works (the mental model)

Karpenter runs **inside your cluster** as a Deployment (in the `kube-system` namespace, per current guidance). It watches two things:

### 2.1 Scale UP: pending pods

1. You create pods (e.g., a Deployment scales from 0 → 5 replicas).
2. The Kubernetes scheduler can't place some pods → they sit in **`Pending`**.
3. Karpenter sees the pending pods, reads their CPU/memory **requests**, node selectors, affinities, and topology constraints.
4. It computes the cheapest EC2 instance type(s) that satisfy everything and calls the EC2 API **directly** (no Auto Scaling Groups involved).
5. The node registers with the cluster, the pods schedule, done. Typically under a minute.

### 2.2 Scale DOWN: consolidation and disruption

Karpenter continuously asks: *"Can I delete or replace a node and still fit all its pods somewhere cheaper?"* When the answer is yes, it **disrupts** the node using a careful, Kubernetes-native procedure:

1. **Taint (cordon)** the node so no new pods land on it.
2. **Evict** pods gracefully via the Eviction API — this **respects PodDisruptionBudgets (PDBs)** and pod `terminationGracePeriodSeconds`, so apps get their SIGTERM and time to finish in-flight work.
3. Only after the node is drained, **terminate** the EC2 instance and delete the node object.

This is the exact machinery we will exploit: **if we scale all pods to zero, every Karpenter node becomes empty, and Karpenter's "consolidate when empty" policy deletes the EC2 instances for us — gracefully, and for free.**

### 2.3 The three objects you configure

| Object | API | What it answers |
|---|---|---|
| **NodePool** | `karpenter.sh/v1` | *What kinds of nodes may exist?* (instance families, spot vs on-demand, limits, disruption policy) |
| **EC2NodeClass** | `karpenter.k8s.aws/v1` | *How is each node configured on AWS?* (AMI, subnets, security groups, IAM role, disks) |
| **NodeClaim** | `karpenter.sh/v1` | Created *by* Karpenter — one per node it launches. You read these, you don't write them. |

> **Historical note:** older tutorials mention `Provisioner` and `AWSNodeTemplate`. Those are the deprecated alpha/beta APIs (pre-1.0). Everything since Karpenter 1.0 uses `NodePool` + `EC2NodeClass` on the stable `v1` API — that's what we use here.

---

<a name="3-the-golden-rule"></a>
## 3. The Golden Rule: scale pods, not nodes

This is the single most important idea in this tutorial:

> **In a Karpenter cluster, nodes are a *consequence*, not a *target*. You never turn nodes off directly. You scale workloads to zero, and Karpenter removes the now-empty nodes safely. You scale workloads back up, and Karpenter creates nodes for them.**

Why? Because Karpenter's entire job is to make the node fleet match the pods' needs. If pods still exist and you delete their nodes out from under them (with EventBridge, a Lambda, a cron that calls `aws ec2 terminate-instances`, etc.):

- The pods become `Pending` again, and **Karpenter immediately launches replacement nodes**. You and Karpenter are now in a tug-of-war, and Karpenter wins — your "shutdown" lasts about 60 seconds and you pay for extra instance churn.
- The pods that were running got **no graceful shutdown** — no SIGTERM handling, no connection draining, PDBs ignored. Section 5 covers this failure mode in depth.

So the safe architecture looks like this:

```
                       (in dependency order, with health checks)
┌──────────────┐  scales deployments   ┌─────────────┐  pods gone   ┌────────────┐
│ Scheduler    │ ────────────────────► │ Kubernetes  │ ───────────► │ Karpenter  │
│ (CronJob or  │  frontend → backend   │ Deployments │  nodes empty │ drains &   │
│  downscaler) │  → database           │ scale to 0  │              │ deletes EC2│
└──────────────┘                       └─────────────┘              └────────────┘
```

Everything in Step 4–7 builds this picture.

---

<a name="4-step-by-step-setup"></a>
## 4. Step-by-step setup (the main example)

We will build a small but realistic environment:

- An EKS cluster named `demo-cluster`.
- Karpenter v1.13.x installed the modern way (**EKS Pod Identity**, `kube-system` namespace).
- One NodePool for application workloads.
- A three-tier demo app: `frontend` → `backend` → `postgres` (StatefulSet).
- A **dependency-aware scheduler** (Kubernetes CronJobs + a small ordered script) that shuts the tiers down top-down at 20:00 and brings them back bottom-up at 07:00 on weekdays.
- Karpenter settings tuned so empty nodes disappear quickly and safely.

> **Copy-paste convention:** every command uses environment variables set in Step 0, so you can adapt names/regions by changing one block.

### Step 0 — Prerequisites

Install these CLIs (any recent version):

- `aws` (AWS CLI v2) — authenticated with permissions to create IAM roles, EKS clusters, EC2, SQS, CloudFormation
- `eksctl` (≥ 0.19x) — creates the cluster and IAM plumbing
- `kubectl` — matching your cluster's Kubernetes minor version
- `helm` (v3) — installs Karpenter

Set your variables:

```bash
export AWS_REGION="us-east-1"
export CLUSTER_NAME="demo-cluster"
export K8S_VERSION="1.33"                 # check the Karpenter compatibility matrix
export KARPENTER_VERSION="1.13.0"         # check https://github.com/aws/karpenter-provider-aws/releases
export KARPENTER_NAMESPACE="kube-system"  # current recommended namespace
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

> **Why `kube-system`?** Karpenter's own docs now recommend installing the controller in `kube-system` so its API requests are treated as critical-cluster-component traffic (higher API Priority and Fairness class). It also signals "do not touch" to humans.

### Step 1 — Create the EKS cluster

The key details in this config:

1. A **small managed node group** (2 nodes) that Karpenter does **not** manage. The Karpenter controller, CoreDNS, and other critical add-ons live here. **Never run Karpenter on nodes Karpenter manages** — it could consolidate away the node it's running on, decapitating itself. This baseline group is also what stays up overnight (it's tiny and cheap), so the control loop that must wake everything up in the morning is always alive.
2. The **`karpenter.sh/discovery` tag** on subnets/security groups — Karpenter finds its networking by looking for this tag.
3. **Pod Identity** association for the Karpenter service account (simpler than the older IRSA/OIDC approach and now the preferred method).

```bash
cat > cluster.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}

iam:
  withOIDC: true
  podIdentityAssociations:
    - namespace: "${KARPENTER_NAMESPACE}"
      serviceAccountName: karpenter
      roleName: ${CLUSTER_NAME}-karpenter
      permissionPolicyARNs:
        - arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}

iamIdentityMappings:
  - arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}"
    username: system:node:{{EC2PrivateDNSName}}
    groups:
      - system:bootstrappers
      - system:nodes

managedNodeGroups:
  - name: system-baseline
    instanceType: m6i.large
    minSize: 2
    desiredCapacity: 2
    maxSize: 3
    labels:
      role: system-baseline

addons:
  - name: eks-pod-identity-agent
EOF
```

**Do not create the cluster yet** — the config above references two IAM resources (`KarpenterControllerPolicy` and `KarpenterNodeRole`) that must exist first. Karpenter publishes a CloudFormation template that creates them **plus the Spot-interruption SQS queue and EventBridge rules** (yes — this is the one place EventBridge is genuinely useful here, as an *input* to Karpenter, not a node-killer; more in Section 5):

```bash
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
  -o karpenter-cfn.yaml

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file karpenter-cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

Now create the cluster (takes ~15–20 minutes):

```bash
eksctl create cluster -f cluster.yaml
```

### Step 2 — What that IAM/queue setup gave you (understand it, don't skip it)

Two roles and one queue now exist:

| Resource | Used by | Purpose |
|---|---|---|
| `${CLUSTER_NAME}-karpenter` (controller role) | Karpenter pod, via Pod Identity | Call EC2 (`RunInstances`, `TerminateInstances`, `Describe*`), pass the node role, read the SQS queue |
| `KarpenterNodeRole-${CLUSTER_NAME}` (node role) | Every EC2 node Karpenter launches | Join the cluster, pull images (ECR), use SSM |
| SQS queue `${CLUSTER_NAME}` + EventBridge rules | Karpenter (consumer) | EC2 pushes **Spot interruption warnings, rebalance recommendations, scheduled maintenance, and instance state-change events** into the queue; Karpenter reads them and gracefully drains affected nodes *before* AWS pulls the plug |

That last row matters: without the interruption queue, a Spot reclaim terminates nodes with **no cordon/drain**, exactly the kind of ungraceful death we're building this whole tutorial to avoid.

### Step 3 — Install Karpenter with Helm

```bash
helm registry logout public.ecr.aws 2>/dev/null || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set replicas=2 \
  --wait
```

Verify:

```bash
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter
kubectl logs -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter --tail=20
```

You should see two `Running` controller pods (2 replicas = leader election + high availability) and logs ending in "starting controller" type messages, with no IAM errors.

### Step 4 — EC2NodeClass and NodePool

**EC2NodeClass** — the AWS "hardware spec" for nodes:

```yaml
# ec2nodeclass.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "KarpenterNodeRole-demo-cluster"     # <-- your node role name
  amiSelectorTerms:
    - alias: al2023@latest                   # Amazon Linux 2023, auto-updating
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "demo-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "demo-cluster"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        encrypted: true
```

> **Production tip:** `al2023@latest` is convenient, but it means new nodes can silently pick up a new AMI. For change control, pin a version (e.g., `alias: al2023@v20260701`) and roll it deliberately — Karpenter's **drift** feature will then replace old-AMI nodes gracefully when you update the pin.

**NodePool** — the policy for what nodes may exist and *how they may be disrupted*. The `disruption` block is the heart of our shutdown behavior:

```yaml
# nodepool.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: apps
spec:
  template:
    metadata:
      labels:
        pool: apps
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]          # add "spot" later once PDBs/grace are proven
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["4"]
      expireAfter: 720h                  # recycle nodes monthly (patched AMIs)
      terminationGracePeriod: 30m        # hard cap: a draining node may block at most 30m
  limits:
    cpu: "200"                           # safety fuse: max 200 vCPU in this pool
    memory: 800Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m                 # wait 2m of quiet before consolidating
    budgets:
      - nodes: "20%"                     # normally, disrupt at most 20% of nodes at once
```

Key lines explained:

- **`consolidationPolicy: WhenEmptyOrUnderutilized`** — Karpenter removes empty nodes *and* repacks underutilized ones. This is what deletes your nodes after the pods scale to zero. (`WhenEmpty` is the conservative alternative: only fully-empty nodes are removed, never repacking — fewer daytime disruptions, slightly higher cost.)
- **`consolidateAfter: 2m`** — a debounce. A node must be empty/underutilized for 2 minutes before Karpenter acts, so a brief gap between pods doesn't trigger churn. During our nightly shutdown this means: pods gone at 20:05 → nodes terminating by ~20:07.
- **`terminationGracePeriod: 30m`** (on the node template) — an upper bound on how long a *node* may take to drain. A misbehaving pod (or an overly strict PDB) can't hold a node hostage forever; after 30 minutes Karpenter forcibly finishes. Tune to your slowest legitimate shutdown.
- **`limits`** — a cost fuse. Even if someone deploys 10,000 replicas at 2 AM, this pool cannot exceed 200 vCPU.
- **`budgets`** — rate-limits *voluntary* disruption. We'll add schedule-aware budgets in Step 7.

Apply and test:

```bash
kubectl apply -f ec2nodeclass.yaml -f nodepool.yaml

# Prove scale-up works: this deployment fits nowhere on the baseline nodes
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.9 --replicas=5
kubectl set resources deployment inflate --requests=cpu=1
kubectl get nodeclaims -w        # a NodeClaim appears, then a node in ~60s

# Prove scale-DOWN works: this is our whole shutdown mechanism in miniature
kubectl scale deployment inflate --replicas=0
kubectl get nodeclaims -w        # after ~consolidateAfter, the node drains and vanishes
kubectl delete deployment inflate
```

If you watched a node appear and then gracefully disappear, **you have just executed the core of the entire on/off system**: pods → 0 ⇒ nodes → 0. Everything from here on is about doing that *in the right order* and *safely for real applications*.

### Step 5 — Make workloads safe to disrupt

Before any automated on/off, every workload needs three protections. This is the difference between "graceful" and "yanked power cord."

**5a. Real `preStop`/SIGTERM handling and `terminationGracePeriodSeconds`.**
When a pod is evicted, Kubernetes sends SIGTERM, waits up to `terminationGracePeriodSeconds` (default 30s), then SIGKILLs. Your app must use that window to stop accepting new work and finish in-flight work.

```yaml
# excerpt from the backend Deployment pod template
spec:
  terminationGracePeriodSeconds: 60
  containers:
    - name: backend
      lifecycle:
        preStop:
          exec:
            command: ["sh", "-c", "sleep 10"]   # let the LB/endpoints deregister first
```

For the **database StatefulSet**, be generous — e.g. `terminationGracePeriodSeconds: 120` so PostgreSQL can flush and checkpoint. (And of course: EBS-backed PersistentVolumes, so data survives the node's death entirely.)

**5b. PodDisruptionBudgets (PDBs).**
A PDB tells the Eviction API "never take my availability below X *during voluntary disruptions*." Karpenter's daytime consolidation honors PDBs, so this keeps repacking from ever taking your app down:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: shop
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: backend
```

> **Important interaction:** PDBs constrain *evictions*, not *scaling*. When our nightly job runs `kubectl scale --replicas=0`, that is a scaling operation — the PDB does not block it (with 0 desired replicas the PDB becomes moot). This is exactly what we want: PDBs guard against Karpenter/upgrades surprising us during the day, while the intentional, ordered shutdown proceeds unimpeded.

**5c. `karpenter.sh/do-not-disrupt` for the truly untouchable.**
Any pod annotated like this will never be voluntarily evicted by Karpenter (batch jobs mid-run, a migration, a singleton you must move by hand):

```yaml
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"
```

Use it sparingly — every such pod pins its node and blocks consolidation (until the NodePool's `terminationGracePeriod` cap). It also works on a whole node (`kubectl annotate node <n> karpenter.sh/do-not-disrupt=true`) for live debugging.

### Step 6 — Dependency-ordered shutdown and startup (the core)

Now the centerpiece. We'll deploy the three-tier app, declare each tier's **order** with a label, and run two CronJobs — one that scales tiers down **top-down**, one that scales them up **bottom-up and waits for health at each step**.

**6a. The demo application** (namespace `shop`, three tiers, each labeled with its tier number — 1 is the most fundamental):

```yaml
# app.yaml (abbreviated to the parts that matter)
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    scale-schedule: "office-hours"        # opt-in marker for the scheduler
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: shop
  labels: { app: postgres, tier: "1" }    # tier 1 = base of the dependency tree
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres, tier: "1" } }
    spec:
      terminationGracePeriodSeconds: 120
      containers:
        - name: postgres
          image: postgres:16
          ports: [{ containerPort: 5432 }]
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 5
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 20Gi } }   # EBS via the EBS CSI driver
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: shop
  labels: { app: backend, tier: "2" }     # tier 2 depends on tier 1
spec:
  replicas: 3
  selector: { matchLabels: { app: backend } }
  template:
    metadata: { labels: { app: backend, tier: "2" } }
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: backend
          image: myrepo/backend:2.4.1
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }  # /healthz checks its DB connection!
          lifecycle:
            preStop: { exec: { command: ["sh","-c","sleep 10"] } }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: shop
  labels: { app: frontend, tier: "3" }    # tier 3 = top of the tree
spec:
  replicas: 3
  selector: { matchLabels: { app: frontend } }
  template:
    metadata: { labels: { app: frontend, tier: "3" } }
    spec:
      containers:
        - name: frontend
          image: myrepo/frontend:2.4.1
          readinessProbe:
            httpGet: { path: /, port: 80 }
```

Two design points that make ordering *work*:

- **Readiness probes must verify dependencies.** The backend's `/healthz` should actually check its database connection. That way, "backend rollout complete" genuinely means "backend can serve," and starting the frontend afterward is safe. This is the Kubernetes-idiomatic way to encode dependencies — probes and ordered orchestration, not `sleep 60`.
- **Tier numbers are data, not code.** New services just declare a `tier` label; the scheduler scripts below need no changes.

**6b. RBAC for the scheduler.** The CronJobs run *inside the cluster* (on the always-on baseline node group) under a ServiceAccount with the minimum rights: read/scale Deployments and StatefulSets.

```yaml
# scheduler-rbac.yaml
apiVersion: v1
kind: Namespace
metadata: { name: scale-scheduler }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: scale-scheduler, namespace: scale-scheduler }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: scale-scheduler }
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["namespaces", "pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: scale-scheduler }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: scale-scheduler }
subjects:
  - { kind: ServiceAccount, name: scale-scheduler, namespace: scale-scheduler }
```

**6c. The ordered scripts, stored in a ConfigMap.** Shutdown walks tiers **high → low**; startup walks **low → high** and *gates* on `kubectl rollout status` (which waits for readiness probes) before advancing. Before scaling a workload to 0, it **saves the current replica count in an annotation**, so startup restores exactly what was there (and plays nicely with manual scaling changes).

```yaml
# scheduler-scripts.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: scale-scripts
  namespace: scale-scheduler
data:
  scale-down.sh: |
    #!/bin/sh
    set -eu
    ANNOT="scale-scheduler/restore-replicas"
    NAMESPACES=$(kubectl get ns -l scale-schedule=office-hours -o name | cut -d/ -f2)

    # Collect the tier numbers present, highest first (consumers before providers)
    TIERS=$(for ns in $NAMESPACES; do
              kubectl get deploy,statefulset -n "$ns" -o jsonpath='{range .items[*]}{.metadata.labels.tier}{"\n"}{end}'
            done | grep -E '^[0-9]+$' | sort -run)

    for tier in $TIERS; do
      echo "=== SCALE DOWN tier $tier ==="
      for ns in $NAMESPACES; do
        for ref in $(kubectl get deploy,statefulset -n "$ns" -l "tier=$tier" -o name); do
          replicas=$(kubectl get "$ref" -n "$ns" -o jsonpath='{.spec.replicas}')
          [ "$replicas" = "0" ] && continue
          kubectl annotate "$ref" -n "$ns" "$ANNOT=$replicas" --overwrite
          kubectl scale "$ref" -n "$ns" --replicas=0
        done
      done
      # Gate: wait until every pod of this tier is actually GONE before
      # touching the tier below it (grace periods are respected here).
      for ns in $NAMESPACES; do
        deadline=$(( $(date +%s) + 600 ))
        while [ "$(kubectl get pods -n "$ns" -l "tier=$tier" --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
          [ "$(date +%s)" -gt "$deadline" ] && { echo "TIMEOUT waiting for tier $tier in $ns"; exit 1; }
          sleep 5
        done
      done
      echo "=== tier $tier fully stopped ==="
    done
    echo "Shutdown complete. Karpenter will now consolidate the empty nodes."

  scale-up.sh: |
    #!/bin/sh
    set -eu
    ANNOT="scale-scheduler/restore-replicas"
    NAMESPACES=$(kubectl get ns -l scale-schedule=office-hours -o name | cut -d/ -f2)

    # Lowest tier first (providers before consumers)
    TIERS=$(for ns in $NAMESPACES; do
              kubectl get deploy,statefulset -n "$ns" -o jsonpath='{range .items[*]}{.metadata.labels.tier}{"\n"}{end}'
            done | grep -E '^[0-9]+$' | sort -un)

    for tier in $TIERS; do
      echo "=== SCALE UP tier $tier ==="
      for ns in $NAMESPACES; do
        for ref in $(kubectl get deploy,statefulset -n "$ns" -l "tier=$tier" -o name); do
          # Restore the replica count saved by scale-down.sh (note: the key
          # contains a '/', which jsonpath treats literally — only '.' needs escaping)
          replicas=$(kubectl get "$ref" -n "$ns" \
            -o jsonpath='{.metadata.annotations.scale-scheduler/restore-replicas}' 2>/dev/null || echo "")
          [ -z "$replicas" ] && replicas=1     # sensible default if never annotated
          kubectl scale "$ref" -n "$ns" --replicas="$replicas"
        done
      done
      # Gate: wait for FULL readiness of this tier (probes green) before the
      # next tier starts. rollout status blocks until ready or timeout.
      for ns in $NAMESPACES; do
        for ref in $(kubectl get deploy,statefulset -n "$ns" -l "tier=$tier" -o name); do
          kubectl rollout status "$ref" -n "$ns" --timeout=15m
        done
      done
      echo "=== tier $tier healthy ==="
    done
    echo "Startup complete, all tiers verified healthy in dependency order."
```

> **Production note:** shell + kubectl is shown here because it's transparent and dependency-free. For anything larger, port the same logic to Python/Go with the official Kubernetes client library (better error handling, structured logs, retries), or adopt a ready-made tool from Section 6 — kube-downscaler, for instance, stores the same "previous replicas" annotation for you. The *logic* — annotate, scale to 0, gate on the tier being fully stopped/healthy, then move to the next tier — is what matters, not the language.

**6d. The CronJobs.** Down at 20:00, up at 07:00, Monday–Friday (cron in your cluster's local timezone via `timeZone`, a stable field since Kubernetes 1.27):

```yaml
# scheduler-cronjobs.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-scale-down
  namespace: scale-scheduler
spec:
  schedule: "0 20 * * 1-5"
  timeZone: "America/New_York"
  concurrencyPolicy: Forbid           # never run two shutdowns at once
  startingDeadlineSeconds: 3600       # if missed (e.g. controller down), run within 1h or skip
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 3600
      template:
        spec:
          serviceAccountName: scale-scheduler
          restartPolicy: Never
          nodeSelector: { role: system-baseline }   # runs on the always-on nodes
          containers:
            - name: scale-down
              image: bitnami/kubectl:1.33
              command: ["/bin/sh", "/scripts/scale-down.sh"]
              volumeMounts: [{ name: scripts, mountPath: /scripts }]
          volumes:
            - name: scripts
              configMap: { name: scale-scripts, defaultMode: 0755 }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: morning-scale-up
  namespace: scale-scheduler
spec:
  schedule: "0 7 * * 1-5"
  timeZone: "America/New_York"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 3600
  jobTemplate:
    spec:
      backoffLimit: 3                 # startup failures retry a bit harder
      activeDeadlineSeconds: 5400
      template:
        spec:
          serviceAccountName: scale-scheduler
          restartPolicy: Never
          nodeSelector: { role: system-baseline }
          containers:
            - name: scale-up
              image: bitnami/kubectl:1.33
              command: ["/bin/sh", "/scripts/scale-up.sh"]
              volumeMounts: [{ name: scripts, mountPath: /scripts }]
          volumes:
            - name: scripts
              configMap: { name: scale-scripts, defaultMode: 0755 }
```

```bash
kubectl apply -f scheduler-rbac.yaml -f scheduler-scripts.yaml -f scheduler-cronjobs.yaml -f app.yaml
```

**What the whole evening now looks like:**

```
20:00:00  CronJob fires (on the always-on baseline node)
20:00:05  tier 3 (frontend)  → 0   ... pods drain via SIGTERM/grace ... gone by 20:00:45
20:00:50  tier 2 (backend)   → 0   ... in-flight requests finish     ... gone by 20:01:55
20:02:00  tier 1 (postgres)  → 0   ... flush + checkpoint (120s max) ... gone by 20:03:30
20:03:30  All app pods gone. Karpenter's `apps` NodePool nodes are now EMPTY.
20:05:30  consolidateAfter (2m) elapses → Karpenter taints, "drains" (nothing left), 
          terminates the EC2 instances, deletes the NodeClaims.
20:06:00  EC2 bill for the apps pool: $0/hour until 07:00. Baseline (2 small nodes) stays.

07:00:00  CronJob fires. tier 1 → 1 replica → pod Pending (no app nodes exist!)
07:00:10  Karpenter sees the pending postgres pod → launches a right-sized node
07:01:20  node Ready → postgres scheduled → readiness probe green → rollout gate passes
07:01:25  tier 2 → 3 replicas → more pending pods → Karpenter adds capacity → healthy
07:03:00  tier 3 → 3 replicas → healthy. Full stack verified up, bottom-up, by ~07:04.
```

Notice something elegant: **the startup script never talks to Karpenter or EC2 at all.** It just sets desired pod state and waits for health; nodes materialize as a side effect. This is the Golden Rule paying off.

### Step 7 — Align Karpenter's disruption budgets with your schedule

One refinement makes the system noticeably calmer. During the *day*, you may want consolidation to be gentle (or off) so repacking never bothers users; during the *shutdown window*, you want it fast and unrestricted. NodePool budgets support exactly this with cron-scheduled entries:

```yaml
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    budgets:
      # Business hours: only 10% of nodes may be voluntarily disrupted at once,
      # and *underutilized*-driven repacking is blocked entirely.
      - nodes: "10%"
      - nodes: "0"
        reasons: ["Underutilized"]
        schedule: "0 7 * * 1-5"
        duration: 13h
      # Nights & weekends: no limits — drain everything as fast as PDBs allow.
      - nodes: "100%"
        schedule: "0 20 * * 1-5"
        duration: 11h
```

Budgets with a `schedule` + `duration` are active only in that window; multiple active budgets combine with the **most restrictive** winning. The net effect: rock-stable days, instant teardown at night.

### Step 8 — Test everything (before trusting it overnight)

```bash
# 1. Dry-run the shutdown NOW by triggering the CronJob manually:
kubectl create job --from=cronjob/nightly-scale-down manual-down -n scale-scheduler
kubectl logs -f job/manual-down -n scale-scheduler        # watch tiers stop in order

# 2. Watch Karpenter remove the empty nodes:
kubectl get nodeclaims -w
kubectl get nodes -l pool=apps -w                          # should drop to zero

# 3. Bring it back and watch order + health gating:
kubectl create job --from=cronjob/morning-scale-up manual-up -n scale-scheduler
kubectl logs -f job/manual-up -n scale-scheduler

# 4. Verify data survived (the real test of "safe"):
kubectl exec -n shop postgres-0 -- psql -U postgres -c "select count(*) from orders;"

# 5. Inspect Karpenter's own view of events:
kubectl get events -A --field-selector source=karpenter --sort-by='.lastTimestamp' | tail -30
```

Run the pair a few times, then let the schedule take over. Add alerts on CronJob failures (`kube_job_status_failed` in Prometheus) — a failed *scale-up* job at 07:00 is a page-worthy event.

---

<a name="5-why-eventbridge-only-fails"></a>
## 5. Why "just use EventBridge to kill the nodes" fails

A very tempting shortcut looks like this:

> "I'll create an **Amazon EventBridge scheduled rule** at 20:00 that triggers a **Lambda**, and the Lambda calls `ec2:StopInstances` / `ec2:TerminateInstances` on the worker nodes (or sets an ASG to 0). Another rule at 07:00 starts them again. Done — no Kubernetes changes needed!"

This design is simple, which is exactly why it's popular — and it fails in at least eight distinct ways on a Karpenter-managed EKS cluster. Let's go through them, because understanding *why* it fails teaches you how Kubernetes and Karpenter really think.

### Failure 1 — Karpenter immediately undoes your shutdown (the tug-of-war)

This is the fatal one. Terminating a node **does not remove the pods' desired state**. Your Deployments still say `replicas: 3`. Within seconds:

1. The node dies → its pods are gone → the ReplicaSet controller creates replacement pods.
2. The replacement pods are `Pending` (their nodes just vanished).
3. **Karpenter sees pending pods — that's literally its job — and launches brand-new EC2 instances**, often within 60–90 seconds.

Your "shutdown" achieved: a brief outage, a burst of instance churn (which you pay for), and a cluster that is fully back up a couple of minutes later. EventBridge kills nodes; Karpenter resurrects them; repeat. The only way to "win" this fight is to break Karpenter (scale its controller to 0, or set NodePool limits to 0) — at which point you've built a second, hidden shutdown system anyway, and you've disabled the component that also handles Spot interruptions and drift. **You cannot turn off a self-healing system by attacking its outputs; you must change its inputs (the pods).**

### Failure 2 — No cordon, no drain, no grace: data loss for stateful workloads

`TerminateInstances` is the cloud equivalent of pulling the power cord. Compare the two paths:

| | Kubernetes-native drain (Karpenter / kubectl drain) | EventBridge → EC2 terminate |
|---|---|---|
| Node cordoned first (no new pods land) | ✅ | ❌ |
| Pods receive SIGTERM | ✅ | Only if the OS shutdown propagates in time — with terminate, effectively ❌ |
| `preStop` hooks run | ✅ | ❌ |
| `terminationGracePeriodSeconds` honored | ✅ (e.g., PostgreSQL's 120s flush) | ❌ |
| PodDisruptionBudgets respected | ✅ | ❌ — PDBs only guard the *Eviction API*; EC2 has never heard of them |
| In-flight requests drain from the load balancer | ✅ | ❌ — connections reset mid-request |

For the PostgreSQL StatefulSet in our example, EC2-level termination at an arbitrary moment means killed WAL writes and an unclean shutdown — recovery usually works, but "usually" is not a word you want near your database, and under load it's how you get corrupted state, split-brain in clustered stores (Kafka, Elasticsearch), and lost messages.

### Failure 3 — Zero dependency ordering

EventBridge fires one event at one moment. Every instance dies **simultaneously**: the frontend, the backend mid-transaction, and the database it was writing to, all in the same second. The entire top-down ordering problem this tutorial exists to solve — consumers stop before providers, each tier verified quiet before the next — is structurally unexpressible in "a timer that terminates instances." You could build a chain of Lambdas and Step Functions that terminates instances in waves… but instances don't map to tiers (Karpenter bin-packs the frontend, backend, and database onto the *same* nodes!), so tier-ordered *node* termination is not even a coherent concept.

### Failure 4 — `StopInstances` breaks Karpenter's ownership model

"Fine, I'll *stop* instances instead of terminating, so they resume with their disks in the morning." Also broken:

- Karpenter's model is **immutable, disposable nodes** tracked by NodeClaims. A stopped instance's kubelet stops heartbeating → the node goes `NotReady` / `Unknown` → its pods sit in limbo (stateful pods can stay stuck `Terminating`, and StatefulSet semantics prevent replacements until the old pod is confirmed dead).
- Karpenter's health/liveness controllers treat unreachable nodes as failed and will **delete the NodeClaim and terminate the stopped instance**, replacing it with a fresh one. Your carefully stopped instance gets garbage-collected.
- Even when a stopped instance is restarted, it often comes back with a new lease on life the cluster no longer recognizes cleanly (expired certificates/bootstrap tokens on long stops, stale IPs in the VPC CNI's warm pool, etc.). Karpenter nodes are cattle, not pets — stopping them is treating cattle like pets.

### Failure 5 — Fire-and-forget: no feedback loop, no verification

EventBridge invokes the Lambda and considers the job done. There is no built-in answer to any of these questions:

- Did *every* workload actually stop, or did tier 2 hang?
- Did the morning startup produce a *healthy* system, or did the backend crash-loop because the database wasn't ready yet?
- Did the Lambda time out halfway through the instance list (15-minute hard cap), leaving half a cluster running all night — or worse, half a cluster *up* in the morning?

Our in-cluster CronJob design has feedback at every step: `kubectl scale` is acknowledged by the API server, the gate loops watch actual pod state, `rollout status` blocks on real readiness probes, and a failed step fails the Job → retries per `backoffLimit` → fires your alerting. A partial failure is *visible and retried*, not silent.

### Failure 6 — Race conditions and timing skew

Two clocks with no coordination: EventBridge fires at 07:00 wall time; the cluster has its own state. Real-world collisions people hit: the morning start racing a nightly EKS control-plane maintenance window; the shutdown racing a still-running batch job or a deploy pipeline (EventBridge doesn't know your CD system just started a rollout); a Spot interruption arriving mid-Lambda so the instance list is stale and the Lambda errors on a terminated instance ID. The in-cluster approach reads live state at execution time by construction.

### Failure 7 — It fights the billing model too

Karpenter's value is *right-sizing*: in the morning it launches exactly the capacity today's pods need, possibly different instance types than yesterday's. Start-stopping fixed instances freezes yesterday's node shapes forever, so you lose consolidation, drift-based AMI updates, and Spot flexibility — you've reinvented a static node group with extra steps.

### Failure 8 — Security and blast radius

The Lambda needs IAM permission to terminate/stop EC2 instances — typically scoped by tags, and tag-scoping mistakes are how a "dev shutdown Lambda" terminates a production node (a genre of postmortem with many entries). Our scheduler's ServiceAccount can do exactly one thing: patch the `scale` subresource of Deployments/StatefulSets. The worst possible bug is "pods scaled at the wrong time" — never "instances gone."

### So is EventBridge useless here? No — it has exactly two good roles

1. **As Karpenter's input for interruption handling** (already in your setup from Step 1/2): EventBridge rules route EC2 Spot interruption warnings, rebalance recommendations, and health events into the SQS queue that Karpenter consumes to *gracefully drain* nodes ahead of AWS-initiated termination. Here EventBridge informs the Kubernetes-native machinery instead of bypassing it — that's the correct direction of the arrow.
2. **As an external clock, if you insist on one**: an EventBridge Scheduler rule may trigger a Lambda whose only action is a Kubernetes API call — patch replicas / create the scale-down Job — never an EC2 call. That's legitimate (useful if you want the schedule managed in AWS-land or across many clusters), though for a single cluster the in-cluster CronJob is simpler: no Lambda runtime, no NAT/VPC networking to the API server, no IAM-to-RBAC mapping to maintain, and the schedule lives in Git with the workloads it controls.

**The principle to remember:** *EventBridge may tell Kubernetes what you want; it must never touch the EC2 instances underneath Kubernetes.* Desired state goes in through the front door (the API server); Karpenter handles the hardware.

---

<a name="6-options-compared"></a>
## 6. Options compared: pros and cons

There are several sound ways to implement the "scale pods on a schedule" layer on top of Karpenter. All of them obey the Golden Rule; they differ in flexibility and operational cost.

### Option A — Kubernetes CronJobs + ordered script (what this tutorial built)

**Pros:** Full control over ordering and health gating; zero external dependencies; runs where the state lives; RBAC-scoped blast radius; everything in Git; easy to test (`kubectl create job --from=cronjob/...`).
**Cons:** You own the script (edge cases, logging, retries); shell gets clumsy past ~3 tiers (graduate to Python/Go); per-cluster, not fleet-wide.
**Best for:** Teams that need *explicit dependency ordering* — i.e., the exact problem in this tutorial.

### Option B — kube-downscaler (open-source annotation-based downscaler)

A controller where each workload declares its own schedule via annotations, e.g. `downscaler/uptime: "Mon-Fri 07:00-20:00 America/New_York"`; it scales to 0 outside the window and restores the saved replica count inside it.

**Pros:** Battle-tested; per-workload schedules with almost no code; handles replica save/restore for you; excludes/forces via annotations; supports Deployments, StatefulSets, HPAs, CronJobs suspension.
**Cons:** **No dependency ordering or health gating** — every workload flips at its own boundary independently. You can *approximate* ordering with staggered windows (DB 06:50–20:10, backend 06:55–20:05, frontend 07:00–20:00), but that's time-based hoping, not verified readiness.
**Best for:** Dev/test environments with many independent apps and weak ordering needs.

### Option C — KEDA cron scaler

KEDA (Kubernetes Event-Driven Autoscaling) `ScaledObject`s with a `cron` trigger scale each workload between 0 and N on a schedule — and can *combine* the schedule with load-based triggers (queue depth, RPS), so "on during office hours *or* whenever there's work" is expressible.

**Pros:** CRD-native and GitOps-friendly; scale-to-zero plus real autoscaling in one tool; great for event-driven/queue workers.
**Cons:** Same gap as B — per-workload, no cross-workload ordering or dependency verification; another controller to operate; HPA interactions to understand.
**Best for:** Clusters already using KEDA, or workloads that should also scale on demand, with ordering handled elsewhere (or not needed).

### Option D — EventBridge Scheduler → Lambda → *Kubernetes API* (not EC2!)

The redeemed version of the anti-pattern: the Lambda authenticates to the cluster (aws-auth/Access Entries) and creates the same ordered Jobs / patches the same replicas as Option A.

**Pros:** Central scheduling across many clusters/accounts; schedule visible to non-Kubernetes teams; AWS-native audit trail.
**Cons:** Most moving parts (Lambda runtime + networking to a possibly-private API endpoint + IAM↔RBAC mapping); ordering logic still has to live somewhere (usually… a script, so you've built Option A with extra steps); cold-start/timeout considerations.
**Best for:** Platform teams orchestrating scheduled scaling across a fleet from one place.

### Option E — Do less: rely on Karpenter alone + `WhenEmptyOrUnderutilized`

No schedule at all: aggressive consolidation plus workloads that naturally idle to low replicas (HPA `minReplicas`, KEDA to zero) shrink the cluster organically.

**Pros:** Nothing to build.
**Cons:** HPA can't go below `minReplicas: 1`, so baseline pods pin baseline nodes all night; no ordering; savings far smaller than a true off-hours shutdown.
**Best for:** Production clusters that must stay on 24/7 anyway — where this *is* the whole strategy, complemented by the office-hours pattern only in pre-prod.

### Quick chooser

| Need | Pick |
|---|---|
| Strict dependency order + health gating | **A** (this tutorial) |
| Many independent dev apps, minimal effort | **B** kube-downscaler |
| Schedule *and* load-based scale-to-zero | **C** KEDA |
| One schedule pane for many clusters | **D** EventBridge → K8s API |
| Cluster can never go down anyway | **E** consolidation only |

These compose: many real setups use **A for the ordered stateful core**, **B or C for the long tail of independent services**, and Karpenter budgets (Step 7) tying node behavior to the clock.

---

<a name="7-best-practices"></a>
## 7. Best practices checklist

**Karpenter layer**
- ☐ Karpenter on a small always-on managed node group (or Fargate) — never on its own nodes; 2 replicas.
- ☐ `kube-system` namespace; Pod Identity for credentials; interruption SQS queue configured.
- ☐ NodePool `limits` set (cost fuse) and `terminationGracePeriod` set (drain-time cap).
- ☐ `consolidateAfter` tuned (1–5 min) to balance churn vs. cost.
- ☐ Schedule-aware disruption budgets: conservative by day, `100%` in the off-hours window.
- ☐ Pin AMIs (`al2023@vYYYYMMDD`) in production; let drift roll them deliberately.
- ☐ Monitor: `karpenter_nodeclaims_*` metrics, controller logs, and Karpenter events.

**Workload layer**
- ☐ Every pod sets CPU/memory **requests** (Karpenter sizes nodes from requests — missing requests = mis-sized nodes).
- ☐ Readiness probes verify *dependencies*, not just process liveness.
- ☐ `preStop` + `terminationGracePeriodSeconds` sized to real shutdown work; generous for databases.
- ☐ PDBs on everything with >1 replica; `karpenter.sh/do-not-disrupt` only where truly needed.
- ☐ State on PVs (EBS/EFS), never on node disks; verify the EBS CSI driver tolerates node churn.

**Scheduling layer**
- ☐ Tier labels as data; shutdown high→low, startup low→high, **gated** at each tier.
- ☐ Save/restore replica counts via annotation (don't hardcode).
- ☐ `concurrencyPolicy: Forbid`, `activeDeadlineSeconds`, `startingDeadlineSeconds` on the CronJobs.
- ☐ Alert on failed scale-up Jobs (07:00 failure = page); log tier timings to spot drift.
- ☐ A documented manual override: how to force everything up *now* (spoiler: `kubectl create job --from=cronjob/morning-scale-up force-up -n scale-scheduler`).
- ☐ Never let anything outside Kubernetes call `ec2:TerminateInstances` / `StopInstances` on Karpenter nodes.

---

<a name="8-troubleshooting"></a>
## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nodes don't disappear after pods scale to 0 | A leftover pod (check DaemonSets are tolerated/ignored automatically, but stray Jobs, orphan pods, or `do-not-disrupt` pods block it); or a `0-nodes` budget window is active | `kubectl describe node <n>` → look at non-DaemonSet pods; check `kubectl get nodepool apps -o yaml` budget windows; check Karpenter events |
| Nodes vanish but reappear at night | Something still creates pods off-hours (a CronJob you forgot, a monitoring stack in a labeled namespace) | Audit `kubectl get cronjobs -A`; exclude/suspend them in the shutdown script (kube-downscaler can suspend CronJobs too) |
| Morning startup: backend crash-loops | Tier gating not actually waiting (readiness probe passes without checking the DB) | Make `/healthz` verify downstream connectivity; the `rollout status` gate then does its job |
| Pods `Pending` forever in the morning | NodePool `limits` reached; instance requirements unsatisfiable; subnet IP exhaustion; Karpenter itself was scaled down | `kubectl describe pod` events + Karpenter logs — it logs exactly why it can't provision |
| Consolidation never repacks by day | Every pod carries a strict PDB (`maxUnavailable: 0`) or `do-not-disrupt` | Loosen PDBs to allow 1 disruption; reserve `do-not-disrupt` for exceptions |
| Spot nodes die without draining | Interruption queue missing/mis-named | `aws sqs list-queues | grep $CLUSTER_NAME`; check `settings.interruptionQueue` Helm value |
| StatefulSet pod stuck `Terminating` at shutdown | Node died un-gracefully underneath it (someone terminated EC2 directly — see Section 5) | Confirm nothing external touches the instances; recover with `kubectl delete pod --force` only after confirming the node is truly gone |

---

<a name="9-glossary"></a>
## 9. Glossary

- **Node** — an EC2 virtual machine that runs pods.
- **Pod** — the smallest deployable unit in Kubernetes; one or more containers.
- **Deployment / StatefulSet** — controllers that keep N replicas of a pod running (StatefulSet adds stable identity + storage, used for databases).
- **Karpenter** — CNCF node autoscaler that launches/removes EC2 capacity to match pod needs. Configured via **NodePool** (policy) and **EC2NodeClass** (AWS specifics); tracks each node with a **NodeClaim**.
- **Consolidation** — Karpenter continuously deleting empty nodes and repacking underutilized ones.
- **Disruption budget (NodePool)** — Karpenter-side rate limit on how many nodes may be voluntarily disrupted at once, optionally on a cron schedule.
- **PodDisruptionBudget (PDB)** — Kubernetes-side guarantee of minimum availability during voluntary evictions.
- **Cordon / Drain** — mark a node unschedulable / gracefully evict its pods.
- **Eviction API** — the "polite" way to remove pods; the only path that honors PDBs.
- **SIGTERM / grace period / preStop** — the shutdown handshake every pod gets during graceful termination — and doesn't get when EC2 instances are terminated directly.
- **EKS Pod Identity** — the current, simpler mechanism for giving pods AWS IAM permissions (successor to IRSA for this use case).
- **EventBridge** — AWS's event bus/scheduler. In this architecture: great as Karpenter's interruption-event *input*, acceptable as an external *clock* that talks to the Kubernetes API, catastrophic as a direct node-killer.
- **Spot interruption** — AWS reclaiming a Spot instance with a 2-minute warning; Karpenter consumes these warnings (via SQS) to drain proactively.
- **Drift** — Karpenter detecting that a live node no longer matches its NodePool/EC2NodeClass spec (e.g., new AMI pin) and gracefully replacing it.

---

### The one-paragraph summary

Declare each service's tier as a label. On a schedule that runs *inside* the cluster on a small always-on node group, scale tiers to zero top-down (consumers → providers), gating on each tier being fully stopped; Karpenter then drains and deletes the empty nodes on its own within minutes. In the morning, scale tiers up bottom-up, gating on real readiness probes; Karpenter materializes right-sized nodes for the pending pods automatically. Tune NodePool disruption budgets so consolidation is gentle by day and unrestricted at night. And never, ever have EventBridge (or anything else) stop or terminate the EC2 instances directly — that path skips cordon, drain, SIGTERM, grace periods, and PDBs, loses stateful data, and Karpenter will simply relaunch the nodes anyway. **Scale the pods; the nodes follow.**
