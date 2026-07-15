# Deploying Data Applications on AWS EKS with Helm
### A Complete What / Why / How Tutorial — Kafka, NiFi, PostgreSQL, OpenSearch & More (with GitLab CI/CD)

> **Last updated:** July 2026
> **Audience:** Anyone comfortable with a terminal. Every concept is explained from scratch — no prior Kubernetes expertise assumed.

---

## Table of Contents

1. [Background: The Building Blocks Explained Simply](#1-background-the-building-blocks-explained-simply)
2. [Step-by-Step Setup: Your First Deployment (PostgreSQL on EKS)](#2-step-by-step-setup-your-first-deployment-postgresql-on-eks)
3. [The Big Idea: Charts vs. Operators (and why it matters in 2026)](#3-the-big-idea-charts-vs-operators)
4. [Apache Kafka on EKS (Strimzi Operator)](#4-apache-kafka-on-eks)
5. [Apache NiFi on EKS](#5-apache-nifi-on-eks)
6. [PostgreSQL on EKS (CloudNativePG, in depth)](#6-postgresql-on-eks-in-depth)
7. [OpenSearch on EKS](#7-opensearch-on-eks)
8. [Honorable Mentions: Redis/Valkey, MinIO, Airflow, Spark](#8-honorable-mentions)
9. [Storage, Networking & Security on EKS (the stuff that bites you)](#9-storage-networking--security-on-eks)
10. [GitLab CI/CD Pipelines for Helm on EKS](#10-gitlab-cicd-pipelines-for-helm-on-eks)
11. [Best Practices Checklist](#11-best-practices-checklist)
12. [Pros & Cons Summary Tables](#12-pros--cons-summary-tables)
13. [Troubleshooting Cheat Sheet](#13-troubleshooting-cheat-sheet)

---

## 1. Background: The Building Blocks Explained Simply

Before touching a terminal, let's understand every word in the title.

### 1.1 What is Kubernetes?

Imagine you run a huge cafeteria. You have hundreds of cooks (your programs) that need kitchens (computers) to work in. Instead of you personally assigning every cook to a kitchen, you hire a **manager** who:

- Assigns cooks to whichever kitchen has space
- Replaces a cook immediately if one gets sick (a program crashes)
- Adds more cooks when the lunch rush hits (auto-scaling)

**Kubernetes (K8s)** is that manager, but for software. It runs your applications inside **containers** (lightweight, portable boxes that hold a program plus everything it needs) and spreads them across a fleet of servers called **nodes**.

Key Kubernetes words you'll see constantly:

| Term | Middle-school explanation |
|---|---|
| **Pod** | The smallest unit — one running copy of your app (one "cook") |
| **Node** | A server (a "kitchen") that pods run on |
| **Deployment** | A rule like "always keep 3 copies of this app running" |
| **StatefulSet** | Like a Deployment, but for apps that need to remember things (databases). Each pod gets a stable name and its own disk |
| **Service** | A stable phone number for a group of pods, so others can call them even when pods come and go |
| **PersistentVolume (PV)** | A disk that survives even if the pod using it dies |
| **Namespace** | A labeled folder that keeps groups of apps separated |
| **Secret / ConfigMap** | Safe boxes for passwords / plain boxes for settings |
| **CRD (Custom Resource Definition)** | A way to teach Kubernetes new words, like "Kafka cluster" — used by operators (explained later) |

### 1.2 What is AWS EKS?

Running Kubernetes yourself is hard — the "control plane" (the manager's brain) needs constant care. **Amazon EKS (Elastic Kubernetes Service)** is AWS saying: *"We'll run the brain for you; you just bring the worker nodes."*

**Why EKS instead of do-it-yourself Kubernetes?**

✅ Pros:
- AWS patches, backs up, and scales the control plane (99.95% SLA)
- Deep integration with AWS: IAM for permissions, EBS/EFS for disks, ELB for load balancers, CloudWatch for logs
- **EKS Auto Mode** (GA since re:Invent 2024) can even manage the worker nodes, storage and networking add-ons for you

❌ Cons:
- ~$73/month per cluster just for the control plane (before any nodes)
- AWS-specific glue (IAM, VPC CNI) means some lock-in
- You still own everything *inside* the cluster: upgrades of your apps, security policies, etc.

### 1.3 What is Helm?

Installing an app on Kubernetes normally means writing 10–30 YAML files (Deployment, Service, ConfigMap, Secret, ...). That's tedious and error-prone.

**Helm is the "app store + installer" for Kubernetes.**

- A **chart** = a zip-like package of YAML templates for an app
- **values.yaml** = the settings sheet you fill in (how much memory? how many replicas? what password?)
- A **release** = one installed copy of a chart in your cluster
- A **repository** = a website hosting charts (like an app store shelf)

One command replaces those 30 files:

```bash
helm install my-database cnpg/cloudnative-pg --values my-settings.yaml
```

**Why Helm?**

✅ Pros:
- One-command install/upgrade/rollback (`helm rollback my-app 3` = time machine!)
- Templating: one chart, many environments (dev/stage/prod) by swapping values files
- Huge ecosystem — nearly every serious open-source project publishes a chart
- Releases are versioned; `helm history` shows every change

❌ Cons:
- Templated YAML (Go templates) can get ugly and hard to debug (`helm template` helps)
- Helm only knows "install/upgrade" — it can't do smart, app-aware operations like "safely fail over the database primary" (that's what **operators** are for — Section 3)
- A badly written chart is worse than plain YAML

### 1.4 ⚠️ Important 2025/2026 context: the Bitnami change

For ~10 years, most tutorials said "just use the Bitnami chart" for Kafka, Postgres, etc. **That advice is now outdated.** In **August–September 2025**, Broadcom (Bitnami's owner) moved almost all free versioned Bitnami container images to a frozen, unsupported `bitnamilegacy` repository and put maintained images behind a paid "Bitnami Secure Images" subscription. Old pipelines pulling `bitnami/postgresql:15.x` broke or now run unpatched images.

**What this tutorial uses instead (current best practice):**

| App | Modern choice | Type |
|---|---|---|
| Kafka | **Strimzi** | Operator (CNCF) |
| PostgreSQL | **CloudNativePG (CNPG)** | Operator (CNCF) |
| OpenSearch | **Official OpenSearch charts / operator** | Chart or Operator |
| NiFi | **Apache NiFi community chart / NiFiKop** | Chart or Operator |
| Redis-compatible | **Valkey** (official chart) or Redis Operator | Chart / Operator |

This is not just a workaround — for stateful data systems, operators were already the better answer. Section 3 explains why.

### 1.5 Why run data applications on EKS at all?

You might ask: *"AWS already sells managed Kafka (MSK), Postgres (RDS/Aurora), and OpenSearch (Amazon OpenSearch Service). Why self-host on EKS?"*

Great question. Honest answer: **often you shouldn't.** But teams choose EKS self-hosting when:

- **Cost at scale** — managed services carry a premium; large clusters can be far cheaper self-run (if you value your engineers' time correctly!)
- **Version/feature control** — need a Kafka feature or Postgres extension the managed service doesn't offer
- **Portability** — same Helm charts run on EKS, GKE, AKS, on-prem — no cloud lock-in
- **Data locality/compliance** — everything stays inside your VPC and your control
- **Unified platform** — one GitOps workflow for *all* infrastructure

**Rule of thumb:** small team, standard needs → use managed services. Platform team, special needs, big scale → self-host with operators on EKS.

---

## 2. Step-by-Step Setup: Your First Deployment (PostgreSQL on EKS)

We start hands-on, exactly one example, end to end. Everything else in the tutorial builds on this. We will:

1. Create an EKS cluster
2. Install the disk driver (EBS CSI)
3. Install the CloudNativePG operator **with Helm**
4. Deploy a real 2-node PostgreSQL cluster
5. Connect and verify

### 2.0 Prerequisites

Install these command-line tools (all free):

```bash
# macOS (Homebrew shown; Linux/Windows: see each tool's docs)
brew install awscli eksctl kubectl helm

# Verify
aws --version      # aws-cli/2.x
eksctl version     # 0.2xx
kubectl version --client
helm version       # v3.x  (Helm 3 only — Helm 2 is long dead)
```

Configure AWS credentials (an IAM user/role that can create EKS clusters):

```bash
aws configure
# Enter Access Key, Secret Key, region (e.g. us-east-1), output json
```

> 💰 **Cost warning:** this walkthrough creates real AWS resources: ~$0.10/hr for the EKS control plane + 2 × m5.large nodes (~$0.19/hr) + EBS volumes. Delete everything at the end (step 2.7)! Total for a 2-hour play session: roughly $1–2.

### 2.1 Create the EKS cluster

`eksctl` is the official CLI that turns one YAML file into a full cluster (VPC, subnets, nodes, IAM — everything).

Create `cluster.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: data-tutorial
  region: us-east-1
  version: "1.33"          # use a currently supported EKS version

iam:
  withOIDC: true            # enables IAM Roles for Service Accounts (IRSA) — needed later

managedNodeGroups:
  - name: general
    instanceType: m5.large  # 2 vCPU / 8 GiB — fine for the tutorial
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    volumeSize: 50          # GiB root disk per node
    labels:
      workload: general

addons:
  - name: aws-ebs-csi-driver      # lets Kubernetes create EBS disks
    wellKnownPolicies:
      ebsCSIController: true      # eksctl wires up the IAM policy for you
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
```

Create it (takes ~15 minutes — grab a coffee):

```bash
eksctl create cluster -f cluster.yaml
```

When it finishes, your `kubectl` is automatically pointed at the new cluster:

```bash
kubectl get nodes
# NAME                             STATUS   ROLES    AGE   VERSION
# ip-192-168-12-34.ec2.internal    Ready    <none>   2m    v1.33.x
# ip-192-168-56-78.ec2.internal    Ready    <none>   2m    v1.33.x
```

**What just happened (why each piece exists):**
- A **VPC** with public+private subnets was created — pods live in private subnets (safer)
- The **EBS CSI driver** addon was installed — without it, no PersistentVolumes = no databases!
- **OIDC/IRSA** was enabled — this lets individual pods assume IAM roles (e.g., "the backup pod may write to S3") instead of giving the whole node god-powers. This is *the* EKS security best practice.

### 2.2 Create a StorageClass for databases

A **StorageClass** is a menu item for disks. EKS ships a default `gp2` class, but modern best practice is **gp3** (cheaper, faster baseline, tunable IOPS).

Create `storageclass.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"                 # encrypt-at-rest — always do this
volumeBindingMode: WaitForFirstConsumer   # IMPORTANT — see note below
allowVolumeExpansion: true          # lets you grow disks later without downtime
reclaimPolicy: Delete
```

```bash
kubectl apply -f storageclass.yaml
# Remove default flag from old gp2 so gp3 wins:
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

> 🧠 **Why `WaitForFirstConsumer`?** EBS volumes live in *one* availability zone (AZ). If Kubernetes creates the disk first (in AZ-a) and then schedules your pod in AZ-b, the pod can never mount it. `WaitForFirstConsumer` says: *"wait until you know where the pod will run, then create the disk in that same AZ."* This one line prevents the most common stateful-workload failure on EKS.

### 2.3 Install the CloudNativePG operator with Helm

Now the Helm part. Add the repo, install the operator:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace
```

Check it:

```bash
kubectl get pods -n cnpg-system
# cnpg-cloudnative-pg-xxxxx   1/1   Running
```

**What did we just install?** Not PostgreSQL itself! We installed an **operator** — a robot DBA that lives in the cluster and understands a new Kubernetes resource type called `Cluster` (a CRD). We tell the robot *what* we want ("a 2-node Postgres 17 cluster"); the robot figures out *how* (StatefulSet-like pods, replication, failover, backups).

### 2.4 Deploy a PostgreSQL cluster

Create `pg-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-db
  namespace: databases
spec:
  instances: 2                    # 1 primary + 1 streaming replica
  imageName: ghcr.io/cloudnative-pg/postgresql:17.5

  storage:
    size: 20Gi
    storageClass: gp3

  resources:
    requests:
      cpu: "500m"
      memory: 1Gi
    limits:
      memory: 1Gi                 # memory limit = request (best practice for DBs)

  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "200"

  bootstrap:
    initdb:
      database: appdb
      owner: appuser              # password auto-generated into a Secret

  affinity:                        # spread primary & replica across AZs
    topologyKey: topology.kubernetes.io/zone
```

Deploy:

```bash
kubectl create namespace databases
kubectl apply -f pg-cluster.yaml

# Watch it come up (takes ~1 minute)
kubectl get cluster -n databases -w
# NAME     AGE   INSTANCES   READY   STATUS                     PRIMARY
# app-db   90s   2           2       Cluster in healthy state   app-db-1
```

The operator created **three Services** automatically:

| Service | Purpose |
|---|---|
| `app-db-rw` | Always points to the **primary** (writes go here) |
| `app-db-ro` | Load-balances across **replicas** (read-only queries) |
| `app-db-r` | Any instance |

### 2.5 Connect and test

```bash
# Get the auto-generated password for appuser
kubectl get secret app-db-app -n databases \
  -o jsonpath='{.data.password}' | base64 -d; echo

# Run a temporary Postgres client pod and connect
kubectl run psql-client --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:17.5 \
  -n databases -- \
  psql "host=app-db-rw user=appuser dbname=appdb password=<PASTE_PASSWORD>"
```

Inside psql:

```sql
CREATE TABLE hello (id serial, msg text);
INSERT INTO hello (msg) VALUES ('It works on EKS!');
SELECT * FROM hello;
```

### 2.6 Watch the magic: kill the primary

This is the whole point of operators. Delete the primary pod on purpose:

```bash
kubectl delete pod app-db-1 -n databases
kubectl get cluster -n databases -w
```

Within seconds the operator **promotes the replica to primary** and repoints `app-db-rw`. Your data survives; apps reconnect automatically. No human DBA at 3 a.m. That's the "why" of operators in one command.

### 2.7 Clean up (avoid charges!)

```bash
kubectl delete cluster app-db -n databases     # deletes pods + PVCs (data!)
helm uninstall cnpg -n cnpg-system
eksctl delete cluster -f cluster.yaml           # tears down everything (~10 min)
```

🎉 **You have now:** created an EKS cluster, configured storage properly, installed an operator via Helm, run a highly-available Postgres, and survived a failover. Everything else in this tutorial is variations on this pattern.

---

## 3. The Big Idea: Charts vs. Operators

You'll deploy data apps on Kubernetes in one of two ways. Understanding the difference is the most important concept in this tutorial.

### 3.1 Plain Helm chart ("install and hope")

A classic chart renders StatefulSets, Services, ConfigMaps. Helm applies them and walks away. Helm has no idea what a "Kafka partition" or "Postgres primary" is.

- Great for **stateless** apps (web servers, APIs) and simple single-node dev databases
- Risky for production stateful systems: upgrades, failovers, rebalancing are *your* problem

### 3.2 Operator ("hire a robot expert")

An **operator** is a program running inside the cluster that encodes an expert human's knowledge. You install the operator (usually *with a Helm chart* — the two compose!), then declare high-level custom resources (`kind: Kafka`, `kind: Cluster`). The operator continuously reconciles reality toward your declaration and handles the scary Day-2 stuff: failover, rolling upgrades in the right order, certificate rotation, rebalancing, backups.

### 3.3 Comparison

| | Plain chart | Operator |
|---|---|---|
| Install complexity | ⭐ Low | ⭐⭐ Medium (operator first, then CRs) |
| Day-2 ops (upgrade/failover/scale) | ❌ Manual, risky | ✅ Automated, app-aware |
| Fits GitOps | ✅ | ✅✅ (CRs are tiny, readable YAML) |
| Custom tweaking | ✅ Full template control | ⚠️ Only what the operator exposes |
| Best for | Stateless apps, dev/test data stores | **Production stateful systems** |

> 📌 **Rule for this tutorial:** *Operators for stateful production data systems; plain charts for everything else.* Post-Bitnami, this is also the direction the community has converged on: Strimzi for Kafka, CloudNativePG/Crunchy for Postgres, operators for Redis, etc.

---

## 4. Apache Kafka on EKS

### 4.1 What is Kafka?

Imagine a school announcement board that never erases anything. Anyone can pin messages (**producers**), anyone can read them at their own pace (**consumers**), and the board keeps everything in order. **Apache Kafka** is that board for software: a distributed, append-only **event log**.

Core vocabulary:

| Term | Meaning |
|---|---|
| **Topic** | A named board ("orders", "clicks") |
| **Partition** | A topic split into lanes so many readers/writers work in parallel |
| **Broker** | One Kafka server; a cluster has several |
| **Consumer group** | A team of readers sharing the work of one topic |
| **Replication factor** | How many brokers keep a copy of each partition (3 = survive 2 failures... usually pick 3) |
| **KRaft** | Kafka's built-in consensus mode. **ZooKeeper is gone** — Kafka 4.x is KRaft-only. Any tutorial showing ZooKeeper is outdated. |

### 4.2 Why Kafka (and why on EKS)?

**Why Kafka at all:** it decouples systems. The checkout service publishes "order placed" once; billing, shipping, analytics, and fraud detection each consume it independently. If billing is down for an hour, events wait safely in the log.

**Why Kafka on EKS with Strimzi rather than Amazon MSK:**

✅ Self-hosted (Strimzi) pros: any Kafka version/config, full ACL and plugin control, potentially much cheaper at scale, portable, Kafka Connect/MirrorMaker2 managed by the same operator.
❌ Cons: you own upgrades, capacity planning, on-call. MSK is genuinely easier for small teams.

**Strimzi** is a CNCF project and the de-facto standard Kafka operator. It manages brokers, users, topics, TLS certs, rolling upgrades, Cruise-Control rebalancing — all through CRDs.

### 4.3 How: install Strimzi with Helm

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update

helm install strimzi strimzi/strimzi-kafka-operator \
  --namespace kafka --create-namespace \
  --set watchAnyNamespace=false        # only watch the 'kafka' namespace (safer default)
```

### 4.4 How: declare a production-shaped Kafka cluster (KRaft)

Modern Strimzi uses **KafkaNodePools** — groups of nodes with roles. Small clusters can combine roles; production separates **controllers** (the brain) from **brokers** (the data movers).

`kafka-cluster.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controllers
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  replicas: 3
  roles: [controller]
  storage:
    type: persistent-claim
    size: 20Gi
    class: gp3
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: brokers
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  replicas: 3
  roles: [broker]
  storage:
    type: persistent-claim
    size: 100Gi
    class: gp3
  resources:
    requests: { cpu: "1", memory: 4Gi }
    limits:   { memory: 4Gi }
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-kafka
  namespace: kafka
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: 4.0.0
    listeners:
      - name: tls                    # in-cluster, TLS-encrypted
        port: 9093
        type: internal
        tls: true
        authentication:
          type: tls
    config:
      default.replication.factor: 3
      min.insync.replicas: 2         # a write must land on 2 copies before "OK"
      offsets.topic.replication.factor: 3
    rack:                            # spread brokers across AZs = survive an AZ outage
      topologyKey: topology.kubernetes.io/zone
  entityOperator:                    # manages KafkaTopic / KafkaUser CRDs
    topicOperator: {}
    userOperator: {}
```

```bash
kubectl apply -f kafka-cluster.yaml
kubectl get kafka -n kafka -w      # wait for READY
```

### 4.5 Topics and users as YAML (GitOps gold)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: 604800000          # keep 7 days
    compression.type: producer
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: orders-service
  namespace: kafka
  labels:
    strimzi.io/cluster: my-kafka
spec:
  authentication:
    type: tls                        # Strimzi issues a client certificate Secret
  authorization:
    type: simple
    acls:
      - resource: { type: topic, name: orders }
        operations: [Read, Write, Describe]
```

Now topics and permissions live in Git, reviewed via merge requests — no more "who created this topic?" mysteries.

### 4.6 Quick smoke test

```bash
kubectl -n kafka run producer -it --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 -- \
  bin/kafka-console-producer.sh \
    --bootstrap-server my-kafka-kafka-bootstrap:9092 --topic orders
# type a few lines, Ctrl-C

kubectl -n kafka run consumer -it --rm \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 -- \
  bin/kafka-console-consumer.sh \
    --bootstrap-server my-kafka-kafka-bootstrap:9092 \
    --topic orders --from-beginning
```

### 4.7 Kafka-on-EKS best practices

- **3+ brokers, RF=3, min.insync.replicas=2** — the classic durable trio
- **Spread across 3 AZs** with the `rack` config (⚠️ cross-AZ data transfer costs money — use `follower fetching`/rack-aware consumers to reduce it)
- **gp3 storage**, and consider dedicated node groups (`nodeAffinity` + taints) so noisy neighbors don't steal broker IO
- Never delete a broker PVC manually; scale via Strimzi + Cruise Control rebalancing
- Upgrades: bump `spec.kafka.version` in Git — Strimzi does the rolling restart in the safe order

---

## 5. Apache NiFi on EKS

### 5.1 What is NiFi?

**Apache NiFi** is a visual **data plumbing** tool. Picture a drag-and-drop canvas where you connect boxes: *"pull files from SFTP → convert CSV to JSON → mask the email column → publish to Kafka."* Each box is a **processor** (300+ built in), the arrows are **connections** with back-pressure, and every piece of data (a **FlowFile**) carries full provenance — a paper trail of everywhere it's been.

### 5.2 Why NiFi?

✅ Pros:
- Low-code: analysts and engineers build flows visually, changes are live (no redeploy)
- Guaranteed delivery, back-pressure, prioritization built in
- Data provenance = audit heaven for regulated industries
- Perfect "edge glue" feeding Kafka: NiFi collects/cleans, Kafka distributes

❌ Cons:
- **Stateful and cluster-fussy** — NiFi 2.x still coordinates via ZooKeeper; running it well on K8s takes care
- Heavy on memory/disk (three internal repositories: FlowFile, Content, Provenance)
- Visual flows are harder to code-review than pure code (though NiFi Registry + versioned flows help)
- Not a compute engine — for heavy transforms use Spark/Flink; NiFi is for *moving and routing*

### 5.3 How: deploy options

| Option | What it is | Verdict |
|---|---|---|
| Community Helm chart (e.g. `cetic/nifi` heritage forks) | Plain chart, StatefulSet | OK for dev/small; check maintenance status before adopting |
| **NiFiKop** (Konpyūtāika fork) | NiFi operator with `NifiCluster` CRDs | Best for production automation |
| Roll your own StatefulSet | Full control | Only if you must |

Example with a community chart (dev-grade, single node):

```bash
helm repo add cetic https://cetic.github.io/helm-charts
helm repo update
```

`nifi-values.yaml`:

```yaml
replicaCount: 1                      # start single-node; cluster mode needs ZooKeeper tuning

image:
  tag: "2.4.0"                       # NiFi 2.x — Java 21, Python processors, much faster

auth:
  singleUser:
    username: admin
    # never commit real passwords — inject via CI/CD or ExternalSecrets (Section 9)

persistence:
  enabled: true
  storageClass: gp3
  # NiFi's three repos benefit from separate volumes in production:
  configStorage:      { size: 1Gi }
  flowfileRepoStorage:{ size: 10Gi }
  contentRepoStorage: { size: 50Gi }
  provenanceRepoStorage: { size: 20Gi }

resources:
  requests: { cpu: "1", memory: 4Gi }
  limits:   { memory: 4Gi }

service:
  type: ClusterIP                    # expose via Ingress + TLS, never a raw public LB
```

```bash
helm install nifi cetic/nifi -n nifi --create-namespace -f nifi-values.yaml
kubectl port-forward svc/nifi 8443:8443 -n nifi
# open https://localhost:8443/nifi
```

### 5.4 NiFi-on-EKS best practices

- **Version your flows** with NiFi Registry (also chartable) — flows-in-Git, promote dev→prod
- Separate EBS volumes per repository; content repo grows fastest — set `allowVolumeExpansion`
- Set JVM heap ≈ 50–75% of container memory via chart values; NiFi off-heaps content
- For production clustering, prefer **NiFiKop**: it automates scaling, rolling upgrades, and per-node config that plain charts fumble
- Put NiFi behind an ALB Ingress with OIDC (Cognito/Okta) — the single-user login is dev-only

---

## 6. PostgreSQL on EKS (in depth)

Section 2 got Postgres running; here's the production picture and the "why" behind CloudNativePG.

### 6.1 What is PostgreSQL?

The world's most-loved open-source **relational database**: tables, SQL, ACID transactions (all-or-nothing changes), plus superpowers via extensions — JSONB documents, PostGIS maps, **pgvector** for AI embeddings.

### 6.2 Why CloudNativePG (CNPG)?

CNPG (a CNCF project, originally by EDB) is an operator that treats Postgres as a first-class Kubernetes citizen — it doesn't even use StatefulSets; it manages instances directly for smarter failover.

✅ What the operator gives you that a plain chart never will:
- **Automated failover** with correct fencing (no split-brain "two primaries" disasters)
- **Continuous backup to S3** (WAL archiving via Barman) + **point-in-time recovery** — restore to "yesterday 14:03:59"
- Rolling **minor upgrades** by updating one image tag; declarative **major upgrades**
- `-rw` / `-ro` services = free read/write splitting
- Native Prometheus metrics

Alternatives, honestly compared:

| Operator | Flavor | Notes |
|---|---|---|
| **CloudNativePG** | Vanilla PG, CNCF | Simplest CRs, S3-native backups, huge momentum — default choice |
| **Crunchy PGO** | Enterprise-ish | Very complete (pgBackRest, pgBouncer built-in), heavier |
| **Zalando postgres-operator** | Patroni-based | Battle-tested, older style |
| Plain chart | — | Dev/test only |

### 6.3 Production add-ons (the "how")

**Backups to S3 with IRSA (no keys in YAML!):**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-db
  namespace: databases
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:17.5

  serviceAccountTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/cnpg-backup-role

  backup:
    barmanObjectStore:
      destinationPath: s3://my-company-db-backups/app-db
      s3Credentials:
        inheritFromIAMRole: true        # 🔑 IRSA — the pod's IAM role signs S3 calls
      wal:
        compression: gzip
    retentionPolicy: "30d"

  storage: { size: 100Gi, storageClass: gp3 }
```

Scheduled full backups + a one-line restore:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: app-db-nightly
  namespace: databases
spec:
  schedule: "0 0 2 * * *"        # 02:00 daily (6 fields — seconds first!)
  cluster:
    name: app-db
---
# Disaster recovery: bootstrap a NEW cluster from S3, recovered to a moment in time
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: app-db-restored
spec:
  instances: 3
  bootstrap:
    recovery:
      source: app-db
      recoveryTarget:
        targetTime: "2026-07-14 14:03:59+00"
  externalClusters:
    - name: app-db
      barmanObjectStore:
        destinationPath: s3://my-company-db-backups/app-db
        s3Credentials: { inheritFromIAMRole: true }
```

### 6.4 Postgres-on-EKS best practices

- **3 instances across 3 AZs** for production (`affinity.topologyKey: topology.kubernetes.io/zone`)
- Memory limit = memory request → pods get the *Guaranteed* QoS class and are last to be evicted
- Use **PgBouncer** (CNPG has a `Pooler` CRD) when you have many short-lived connections
- **Test your restores** monthly. An untested backup is a hope, not a backup
- Watch disk usage; `allowVolumeExpansion: true` + editing `storage.size` grows EBS online

---

## 7. OpenSearch on EKS

### 7.1 What is OpenSearch?

**OpenSearch** (the open-source, Apache-2.0 fork of Elasticsearch 7.10, born in 2021) is a **search and analytics engine**. Instead of scanning rows like a database, it builds an **inverted index** — like the index at the back of a textbook — so searching billions of log lines or products takes milliseconds. It ships with **OpenSearch Dashboards** (the Kibana equivalent) and now includes vector/k-NN search for AI apps.

Typical jobs: log analytics (the "S" in ELK-style stacks), full-text product search, security analytics (SIEM), vector search.

Node roles you'll configure:

| Role | Job |
|---|---|
| **cluster_manager** (formerly "master") | Brain: tracks cluster state. Always run **3** (quorum) |
| **data** | Muscles: hold indices, do the searching. Scale these |
| **ingest / coordinating** | Optional pre-processors / request routers at scale |

### 7.2 Why self-host vs Amazon OpenSearch Service?

✅ Self-host pros: no per-instance service premium, any plugin, full config control, same GitOps flow as everything else.
❌ Cons: JVM tuning, shard management, upgrades are on you — OpenSearch is the most ops-heavy system in this tutorial. If your team is small, the managed service is honestly a fine call.

### 7.3 How: official Helm charts

```bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts/
helm repo update
```

`opensearch-values.yaml` (small production-shaped cluster):

```yaml
clusterName: logs
nodeGroup: nodes

replicas: 3
roles: [cluster_manager, data, ingest]   # combined roles OK ≤ ~5 nodes; split beyond that

persistence:
  enabled: true
  storageClass: gp3
  size: 200Gi

resources:
  requests: { cpu: "1", memory: 8Gi }
  limits:   { memory: 8Gi }

opensearchJavaOpts: "-Xms4g -Xmx4g"      # heap = 50% of RAM, and never > ~31 GB

config:
  opensearch.yml: |
    cluster.routing.allocation.awareness.attributes: zone
    plugins.security.ssl.http.enabled: true

# Since OpenSearch 2.12+, you MUST supply the initial admin password:
extraEnvs:
  - name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: opensearch-admin
        key: password

sysctlInit:
  enabled: true                           # sets vm.max_map_count=262144 on the node
```

```bash
kubectl create ns search
kubectl create secret generic opensearch-admin -n search \
  --from-literal=password='A-Strong-Passw0rd!'   # in real life: ExternalSecrets

helm install opensearch opensearch/opensearch -n search -f opensearch-values.yaml
helm install dashboards opensearch/opensearch-dashboards -n search \
  --set opensearchHosts="https://opensearch-cluster-master:9200"
```

Verify:

```bash
kubectl port-forward svc/opensearch-cluster-master 9200 -n search
curl -ku admin:'A-Strong-Passw0rd!' https://localhost:9200/_cluster/health?pretty
# "status" : "green"
```

> There is also an **OpenSearch Kubernetes Operator** (`opensearch-operator` Helm chart) that manages `OpenSearchCluster` CRDs — rolling upgrades, draining nodes before removal, cert management. Same chart-vs-operator tradeoff as everywhere: choose the operator once you're serious.

### 7.4 OpenSearch-on-EKS best practices

- **Heap = 50% of container RAM, capped ~31 GB** (compressed-pointers cliff); the other 50% is the OS file cache OpenSearch relies on for speed
- **3 dedicated cluster_manager nodes** once you pass ~5 data nodes
- Keep shards **10–50 GB** each; thousands of tiny shards will melt the managers
- Use **ISM policies** (Index State Management) to roll over and delete old log indices automatically — otherwise the disk-full pager will find you
- Zone awareness + `topologySpreadConstraints` across 3 AZs
- Snapshots to S3 via the `repository-s3` plugin + IRSA role

---

## 8. Honorable Mentions

Same patterns, quick pointers:

| App | What/Why (one-liner) | Current how |
|---|---|---|
| **Valkey** (Redis-compatible) | In-memory cache/queue; Valkey is the Linux-Foundation fork that stayed open-source after Redis' 2024 license change | Official `valkey` charts, or ot-container-kit Redis/Valkey operator for HA sentinel/cluster |
| **MinIO** | S3-compatible object storage in-cluster (dev/test, or on-prem parity) | MinIO operator/chart — but on AWS, prefer real S3 |
| **Apache Airflow** | Workflow scheduler ("cron with a brain and a UI") | **Official `apache-airflow/airflow` chart** — excellent, supports KubernetesExecutor |
| **Apache Spark** | Big-data compute engine | **Kubeflow Spark Operator** — submit `SparkApplication` CRDs |
| **ClickHouse** | Blazing-fast analytics/OLAP DB | Altinity ClickHouse operator |
| **Prometheus + Grafana** | Metrics for ALL of the above | `kube-prometheus-stack` chart — install this in every cluster, first |


---

## 9. Storage, Networking & Security on EKS (the stuff that bites you)

Data apps fail on EKS for platform reasons more often than app reasons. Learn these once.

### 9.1 Storage

| Choice | Use for | Notes |
|---|---|---|
| **EBS gp3 (CSI)** | Databases, Kafka, OpenSearch | Default. Single-AZ! → `WaitForFirstConsumer`, spread replicas across AZs |
| EBS io2 | Extreme-IOPS DBs | $$$; measure before paying |
| **EFS (CSI)** | Shared ReadWriteMany volumes (rare for data apps) | NFS latency — never put a database on EFS |
| Instance store (NVMe) | Ultra-fast ephemeral (some Kafka/ClickHouse setups) | Data dies with the node — only with RF≥3 and confidence |

Golden rules: encrypt everything (`encrypted: "true"`), enable `allowVolumeExpansion`, and remember **PVCs outlive Helm releases** — `helm uninstall` usually leaves disks (and costs) behind; check `kubectl get pvc`.

### 9.2 Networking essentials

- **In-cluster traffic** (app → Postgres): plain `ClusterIP` services — never expose databases publicly
- **Web UIs** (NiFi, Dashboards, Grafana): **AWS Load Balancer Controller** (installed via Helm!) + `Ingress` → ALB with TLS via ACM, ideally OIDC auth
- **External Kafka clients**: Strimzi `type: loadbalancer` or `ingress` listeners — mind cross-AZ + NLB costs
- **NetworkPolicies**: default-deny per namespace, then allow only app→DB ports. Think firewall rules as YAML

### 9.3 Security best practices (EKS-specific)

1. **IRSA everywhere** — pods get IAM roles via service-account annotations (you saw it in the CNPG backup). Never node-wide credentials, never access keys in Secrets
2. **Secrets management** — Kubernetes Secrets are only base64-encoded. Use **External Secrets Operator** (Helm-installable) to sync from AWS Secrets Manager:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opensearch-admin
  namespace: search
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secrets-manager, kind: ClusterSecretStore }
  target: { name: opensearch-admin }
  data:
    - secretKey: password
      remoteRef: { key: prod/opensearch/admin-password }
```

3. **Pod Security Standards**: label namespaces `pod-security.kubernetes.io/enforce: restricted` where charts allow
4. **Dedicated node groups** for heavy data apps (taints + tolerations) so a runaway web app can't starve Kafka
5. **Scan charts before deploy**: `helm template ... | kubesec/trivy` in CI (next section!)

---

## 10. GitLab CI/CD Pipelines for Helm on EKS

### 10.1 What & why

**CI/CD** = robots that test and ship your changes. **GitLab CI** reads `.gitlab-ci.yml` in your repo and runs **jobs** in **stages** on **runners**.

Why pipe Helm through CI/CD instead of `helm upgrade` from laptops?

- Every change is reviewed (merge request) and recorded (Git history = audit log)
- No "works on my machine" — same pinned tool versions every time
- Lint/diff/scan gates catch mistakes *before* they hit prod
- Rollback = revert the commit

### 10.2 Repo layout (values-per-environment pattern)

```
data-platform/
├── .gitlab-ci.yml
├── charts/                      # your own umbrella/app charts (optional)
├── releases/
│   ├── cnpg-operator/
│   │   ├── Chart.lock
│   │   └── values/ { dev.yaml, prod.yaml }
│   ├── strimzi/ ...
│   └── opensearch/ ...
└── manifests/                   # operator CRs (Kafka, Cluster, KafkaTopic...)
    ├── dev/  kafka.yaml  pg-cluster.yaml
    └── prod/ kafka.yaml  pg-cluster.yaml
```

One repo, one pipeline, environments differ only by values files and CR folders.

### 10.3 Authentication: GitLab → EKS with OIDC (no long-lived keys!)

Old way: paste an AWS access key into GitLab variables. Modern way: **OIDC federation** — GitLab mints a short-lived ID token per job; AWS trusts it and hands back temporary credentials.

One-time AWS setup: create an IAM OIDC identity provider for `https://gitlab.com` (or your self-hosted URL), then a role `gitlab-deployer` whose trust policy allows tokens where `sub` matches your project/branch, e.g.:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/gitlab.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "gitlab.com:aud": "https://gitlab.com" },
    "StringLike":  { "gitlab.com:sub": "project_path:mygroup/data-platform:ref_type:branch:ref:main" }
  }
}
```

Grant that role Kubernetes access with an EKS **access entry**:

```bash
aws eks create-access-entry --cluster-name data-tutorial \
  --principal-arn arn:aws:iam::123456789012:role/gitlab-deployer
aws eks associate-access-policy --cluster-name data-tutorial \
  --principal-arn arn:aws:iam::123456789012:role/gitlab-deployer \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
# (Tighten to a namespaced policy for real prod.)
```

### 10.4 The full `.gitlab-ci.yml`

```yaml
# .gitlab-ci.yml — Helm data platform pipeline
stages: [validate, security, diff, deploy-dev, deploy-prod]

variables:
  AWS_REGION: us-east-1
  CLUSTER_NAME: data-tutorial
  ROLE_ARN: arn:aws:iam::123456789012:role/gitlab-deployer
  HELM_VERSION: "3.18.0"          # pin your tools!

# ---------- Reusable snippets ----------
.aws_auth: &aws_auth
  id_tokens:
    AWS_ID_TOKEN:
      aud: https://gitlab.com
  before_script:
    - export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s" \
        $(aws sts assume-role-with-web-identity \
          --role-arn "$ROLE_ARN" \
          --role-session-name "gitlab-${CI_PIPELINE_ID}" \
          --web-identity-token "$AWS_ID_TOKEN" \
          --duration-seconds 3600 \
          --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
          --output text))
    - aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

.tools_image: &tools_image
  image: alpine/k8s:1.33.1        # bundles kubectl+helm+aws-cli; or build your own

# ---------- 1) VALIDATE ----------
helm-lint:
  stage: validate
  <<: *tools_image
  script:
    - helm repo add cnpg https://cloudnative-pg.github.io/charts
    - helm repo add strimzi https://strimzi.io/charts/
    - helm repo add opensearch https://opensearch-project.github.io/helm-charts/
    - helm repo update
    # Lint every values file renders cleanly
    - |
      for env in dev prod; do
        helm template cnpg cnpg/cloudnative-pg \
          -f releases/cnpg-operator/values/$env.yaml > /dev/null
        helm template os opensearch/opensearch \
          -f releases/opensearch/values/$env.yaml > /dev/null
      done
    - helm lint charts/* || true   # your own charts, if any

kube-validate:
  stage: validate
  <<: *tools_image
  script:
    # Validate raw operator CRs against schemas (offline)
    - kubectl apply --dry-run=client -f manifests/dev/
    - kubectl apply --dry-run=client -f manifests/prod/

# ---------- 2) SECURITY ----------
trivy-scan:
  stage: security
  image: aquasec/trivy:latest
  script:
    # Scan rendered manifests for misconfigurations (runs as root? no limits? etc.)
    - trivy config --exit-code 1 --severity HIGH,CRITICAL manifests/
  allow_failure: false

secret-detection:                  # GitLab's built-in scanner — free tier included
  stage: security
  include: []                      # (or use: include: template: Security/Secret-Detection.gitlab-ci.yml)
  image: registry.gitlab.com/security-products/secrets:latest
  script: [ "/analyzer run" ]
  allow_failure: false

# ---------- 3) DIFF (show what WOULD change on prod) ----------
helm-diff-prod:
  stage: diff
  <<: *tools_image
  <<: *aws_auth
  script:
    - helm plugin install https://github.com/databus23/helm-diff || true
    - helm repo add opensearch https://opensearch-project.github.io/helm-charts/ && helm repo update
    - helm diff upgrade opensearch opensearch/opensearch -n search
        -f releases/opensearch/values/prod.yaml --allow-unreleased | tee diff.txt
    - kubectl diff -f manifests/prod/ | tee -a diff.txt || true   # exit 1 = has diffs, that's fine
  artifacts:
    paths: [diff.txt]
    expire_in: 1 week
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

# ---------- 4) DEPLOY DEV (auto on main) ----------
deploy-dev:
  stage: deploy-dev
  <<: *tools_image
  <<: *aws_auth
  environment:
    name: dev
  script:
    - helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
    # Operators first (idempotent upgrade --install), pinned versions!
    - helm upgrade --install cnpg cnpg/cloudnative-pg
        -n cnpg-system --create-namespace
        --version 0.26.1
        -f releases/cnpg-operator/values/dev.yaml
        --atomic --timeout 10m
    # Then the CRs (Kafka clusters, PG clusters, topics...)
    - kubectl apply -f manifests/dev/
    # Gate: wait until things are actually healthy
    - kubectl wait --for=condition=Ready cluster/app-db -n databases --timeout=300s
  rules:
    - if: $CI_COMMIT_BRANCH == "main"

# ---------- 5) DEPLOY PROD (manual approval) ----------
deploy-prod:
  stage: deploy-prod
  <<: *tools_image
  <<: *aws_auth
  environment:
    name: production
    url: https://grafana.mycompany.com/d/data-platform
  script:
    - helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
    - helm upgrade --install cnpg cnpg/cloudnative-pg
        -n cnpg-system --create-namespace
        --version 0.26.1
        -f releases/cnpg-operator/values/prod.yaml
        --atomic --timeout 15m
    - kubectl apply -f manifests/prod/
    - kubectl wait --for=condition=Ready cluster/app-db -n databases --timeout=600s
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual                 # a human clicks the button
  needs: [deploy-dev]
```

**Why each design choice (the teaching bits):**

| Choice | Why |
|---|---|
| `--atomic` | If the upgrade fails or times out, Helm auto-rolls back. No half-deployed releases |
| `--version 0.26.1` pinned | "latest" in prod = surprise upgrades at 2 a.m. Pin, bump deliberately via MR |
| `helm diff` on MRs | Reviewers see the *actual* Kubernetes changes, not just YAML edits |
| `when: manual` on prod | Cheap, effective change control; pair with GitLab *protected environments* for approver rules |
| `kubectl wait` gates | "Deployed" ≠ "healthy". The pipeline only goes green when the operator says Ready |
| OIDC auth | Zero long-lived AWS keys to leak or rotate |
| `environment:` blocks | GitLab tracks what's deployed where, enables rollback UI & review apps |

### 10.5 Leveling up: GitOps (pull-based) with Argo CD or Flux

The pipeline above is **push-based** (CI shoves changes into the cluster). The next maturity level is **pull-based GitOps**: install **Argo CD** or **Flux** (via Helm, naturally) in the cluster; it watches your Git repo and continuously syncs. Your GitLab pipeline then only *lints, scans, and merges* — no cluster credentials in CI at all.

✅ GitOps pros: cluster state always equals Git (drift auto-corrected), better security (no external kubeconfigs), great multi-cluster story.
❌ Cons: one more system to run; debugging "why won't it sync" is a new skill.

Flux even has a `HelmRelease` CRD — Helm releases themselves become YAML in Git:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: opensearch, namespace: search }
spec:
  interval: 10m
  chart:
    spec:
      chart: opensearch
      version: "3.x"
      sourceRef: { kind: HelmRepository, name: opensearch }
  valuesFrom:
    - kind: ConfigMap
      name: opensearch-prod-values
```

**Recommendation:** start push-based (simpler to learn/debug), adopt Argo CD/Flux once you have >1 cluster or >1 team.

---

## 11. Best Practices Checklist

**Helm hygiene**
- [ ] Helm 3 only; pin chart versions AND app image tags
- [ ] One values file per environment; zero secrets in values files
- [ ] `helm diff` in MRs; `--atomic --timeout` on every upgrade
- [ ] Know that `helm uninstall` keeps PVCs — clean up disks deliberately

**EKS platform**
- [ ] gp3 default StorageClass, encrypted, `WaitForFirstConsumer`, expandable
- [ ] IRSA for every pod that touches AWS; OIDC for CI — no static keys anywhere
- [ ] 3 AZs; spread stateful replicas with topology keys; budget for cross-AZ traffic
- [ ] Dedicated node groups (taints) for Kafka/OpenSearch
- [ ] kube-prometheus-stack installed before any data app; alerts on disk %, replication lag, under-replicated partitions

**Data apps**
- [ ] Operators for production state: Strimzi, CloudNativePG, OpenSearch operator, NiFiKop
- [ ] Replication ≥ 3 (Kafka RF, PG instances, OpenSearch replicas) — one copy is zero copies
- [ ] Backups to S3 + **scheduled restore tests**
- [ ] Memory limits = requests for databases (Guaranteed QoS)
- [ ] Never expose data ports publicly; UIs behind ALB + OIDC

**Pipeline**
- [ ] Stages: validate → security scan → diff → dev auto → prod manual
- [ ] Health gates (`kubectl wait`) after deploy
- [ ] Protected branches + protected environments for prod

---

## 12. Pros & Cons Summary Tables

**Deployment method**

| Method | Pros | Cons | Use when |
|---|---|---|---|
| Plain Helm chart | Simple, fast, huge catalog | No Day-2 smarts | Stateless apps, dev data stores |
| Operator (via Helm) | Automated failover/upgrades/backups | More moving parts, learn CRDs | Production stateful systems |
| AWS managed service | Least ops | $$$, less control, lock-in | Small teams, standard needs |

**Per application**

| App | Best self-host route | Managed alternative | Biggest self-host gotcha |
|---|---|---|---|
| Kafka | Strimzi (KRaft, node pools) | Amazon MSK | Cross-AZ traffic bills; storage planning |
| NiFi | NiFiKop / community chart | (none direct on AWS) | Repo disk growth; clustering complexity |
| PostgreSQL | CloudNativePG | RDS / Aurora | Untested backups; connection storms → PgBouncer |
| OpenSearch | Official charts / operator | Amazon OpenSearch Service | Heap & shard sizing; index lifecycle |

**CI/CD flavor**

| Flavor | Pros | Cons |
|---|---|---|
| Push (GitLab runs helm) | Simple, everything in one pipeline | CI holds cluster creds; drift possible |
| Pull GitOps (Argo/Flux) | Drift-proof, most secure, multi-cluster | Extra system, new debugging skills |

---

## 13. Troubleshooting Cheat Sheet

| Symptom | Likely cause | First command |
|---|---|---|
| Pod `Pending` forever | No node capacity, or PVC can't bind (AZ mismatch) | `kubectl describe pod X` → Events |
| `ImagePullBackOff` on old charts | You're still pointing at retired `bitnami/*` images | Switch to the modern chart/operator (Sections 4–7) |
| PVC `Pending` | EBS CSI addon missing or IAM policy absent | `kubectl get pods -n kube-system \| grep ebs` |
| Helm upgrade "another operation in progress" | Previous run crashed mid-flight | `helm rollback <rel>` or `helm history` then fix |
| OpenSearch pods crash-loop at start | `vm.max_map_count` too low / admin password missing | Enable `sysctlInit`; set `OPENSEARCH_INITIAL_ADMIN_PASSWORD` |
| Kafka clients time out from outside | Advertised listeners vs LB mismatch | Check Strimzi external listener status |
| CNPG cluster stuck not-Ready | Storage or affinity unsatisfiable | `kubectl describe cluster app-db`; `kubectl cnpg status app-db` (plugin) |
| Everything slow, nodes hot | No requests/limits, noisy neighbors | `kubectl top pods -A`; add resources + dedicated node groups |

---

## Final Words

You now have the full mental model:

1. **EKS** gives you managed Kubernetes; you bring storage classes, IRSA and node groups.
2. **Helm** packages installs; **operators** (installed by Helm) run your databases like expert robots.
3. Post-2025, the winning stack is **Strimzi + CloudNativePG + official OpenSearch + NiFiKop**, not the old Bitnami defaults.
4. **GitLab CI with OIDC** lints, scans, diffs, deploys dev automatically and prod on a button — and Git becomes your audit log and time machine.

Deploy the Section 2 walkthrough once for real, break the primary on purpose, restore a backup, and you'll know more than most production teams. Happy shipping! 🚀
