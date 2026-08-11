# Running Kafka on AWS EKS with Strimzi — The Complete Beginner-Friendly Guide

*Written in plain language, like a friendly teacher explaining things step by step.*

This guide is **specifically for AWS EKS** (Amazon's managed Kubernetes). It covers deploying Kafka with Strimzi, adding a **Kafka UI** (a web dashboard for humans), sending logs to **AWS CloudWatch**, and running **Grafana + Prometheus pods** for monitoring.

Based on **Strimzi 1.0.0 / 1.1.0**, **Kafka 4.0**, and 2025–2026 AWS best practices.

---

## Table of Contents

1. [The Big Picture (What We're Building)](#1-the-big-picture-what-were-building)
2. [Vocabulary You Need to Know](#2-vocabulary-you-need-to-know)
3. [Prerequisites: What You Need First](#3-prerequisites-what-you-need-first)
4. [Scenario A: Prepare Your EKS Cluster (EBS Storage)](#4-scenario-a-prepare-your-eks-cluster-ebs-storage)
5. [Scenario B: Install the Strimzi Operator](#5-scenario-b-install-the-strimzi-operator)
6. [Scenario C: Deploy a Kafka Cluster on EKS (with Metrics On)](#6-scenario-c-deploy-a-kafka-cluster-on-eks-with-metrics-on)
7. [Scenario D: Create Topics](#7-scenario-d-create-topics)
8. [Scenario E: Security & User Management](#8-scenario-e-security--user-management)
9. [Scenario F: Deploy a Kafka UI (Web Dashboard)](#9-scenario-f-deploy-a-kafka-ui-web-dashboard)
10. [Scenario G: Monitoring with Prometheus + Grafana Pods](#10-scenario-g-monitoring-with-prometheus--grafana-pods)
11. [Scenario H: Send Logs to AWS CloudWatch (Fluent Bit)](#11-scenario-h-send-logs-to-aws-cloudwatch-fluent-bit)
12. [Scenario I: Upgrading Strimzi and Kafka](#12-scenario-i-upgrading-strimzi-and-kafka)
13. [Scenario J: Scaling on EKS](#13-scenario-j-scaling-on-eks)
14. [Everyday Operations Cheat Sheet](#14-everyday-operations-cheat-sheet)
15. [EKS Best Practices Checklist](#15-eks-best-practices-checklist)
16. [Reference Links](#16-reference-links)

---

## 1. The Big Picture (What We're Building)

Imagine a giant **post office** for computer programs. Programs write letters (**messages**), drop them into labeled mailboxes (**topics**), and other programs pick them up. That post office is **Apache Kafka**.

Running that post office by hand is hard. **Kubernetes** is a robot city-manager that runs software "buildings" (**containers**) for you. **AWS EKS** is Amazon's version of that robot — they run the hard parts of Kubernetes so you don't have to. **Strimzi** is the expert manager you hire *inside* EKS who knows exactly how to run the Kafka post office correctly.

Here's the whole system we're going to build, and what each piece does:

| Piece | Its job (in plain words) |
|-------|--------------------------|
| **AWS EKS** | The managed Kubernetes "city" where everything lives. |
| **EBS (gp3) disks** | Amazon's hard drives that store your Kafka messages safely. |
| **Strimzi Operator** | The robot manager that builds and runs Kafka for you. |
| **Kafka cluster** | The actual post office (brokers + controllers). |
| **Kafka UI** | A friendly website where humans can click around and see topics/messages. |
| **Prometheus** | A robot that constantly collects health numbers ("metrics") from Kafka. |
| **Grafana** | A website that draws pretty graphs from Prometheus' numbers. |
| **Fluent Bit → CloudWatch** | A courier that ships all the text logs to AWS CloudWatch for safekeeping and searching. |

**Two kinds of watching, and why you want both:**

- **Metrics (Prometheus + Grafana):** Numbers over time — "how many messages per second?", "how far behind is this consumer?" Great for graphs and alerts.
- **Logs (Fluent Bit + CloudWatch):** The actual text diary each program writes — "ERROR: disk full at 3:04pm." Great for figuring out *why* something broke.

Think of metrics as the car's **dashboard gauges**, and logs as the **mechanic's written notes**. You need both to run things well.

---

## 2. Vocabulary You Need to Know

| Word | Simple Meaning |
|------|----------------|
| **EKS** | Amazon's managed Kubernetes service. AWS runs the control plane for you. |
| **Node / Worker Node** | An EC2 virtual computer where your pods actually run. |
| **Pod** | The smallest "building" in Kubernetes; runs one piece of software. |
| **Namespace** | A labeled folder inside Kubernetes to keep things organized. |
| **kubectl** | The command tool you type to talk to Kubernetes. Say "koob-cuttle." |
| **eksctl** | A helper command tool made just for creating/managing EKS things. |
| **Helm** | An "app-store installer" for Kubernetes. Installs big things in one command. |
| **EBS** | Elastic Block Store — Amazon's attachable hard drives. Kafka stores data here. |
| **gp3** | The current-generation, fast, cost-efficient EBS disk type. Use this. |
| **CSI Driver** | The translator that lets Kubernetes create AWS EBS disks automatically. |
| **StorageClass** | A "recipe" telling Kubernetes what kind of disk to make (e.g., gp3, encrypted). |
| **Operator** | An expert robot that manages a specific app. Strimzi is Kafka's operator. |
| **KRaft** | The modern way Kafka manages itself, **without** the old ZooKeeper helper. |
| **KafkaNodePool** | A "team" of Kafka nodes with the same settings (brokers or controllers). |
| **Broker** | A Kafka worker that stores and serves messages. |
| **Controller** | A Kafka manager that tracks cluster metadata (who's doing what). |
| **Topic** | A labeled mailbox where one kind of message goes. |
| **Metrics** | Numbers describing health (throughput, lag, CPU). Collected by Prometheus. |
| **Logs** | Text lines that programs write. Shipped to CloudWatch by Fluent Bit. |
| **Prometheus** | The tool that scrapes and stores metric numbers over time. |
| **Grafana** | The tool that turns Prometheus numbers into visual dashboards. |
| **PodMonitor** | A small rule that tells Prometheus, "collect metrics from these pods." |
| **CloudWatch** | AWS's central place to store and search logs and metrics. |
| **Fluent Bit** | A lightweight courier that reads pod logs and ships them to CloudWatch. |
| **DaemonSet** | A rule that runs **one copy of a pod on every node** (used for Fluent Bit). |
| **IRSA** | "IAM Roles for Service Accounts" — the safe way to give a pod AWS permissions. |
| **IAM** | AWS's permission system (who can do what in your AWS account). |

> **KRaft vs ZooKeeper:** Old tutorials mention ZooKeeper everywhere — **ignore that for new setups**. Since Kafka 4.0 and modern Strimzi, **KRaft is the only way**, and it's simpler. This whole guide uses KRaft.

---

## 3. Prerequisites: What You Need First

Before starting, make sure you have these installed and set up on your computer:

```bash
# 1. AWS CLI — talks to your AWS account
aws --version

# 2. kubectl — talks to Kubernetes
kubectl version --client

# 3. eksctl — helper for EKS
eksctl version

# 4. helm — the app-store installer
helm version
```

You also need:

- An **AWS account** and credentials configured (`aws configure`).
- A **running EKS cluster**. If you don't have one, create a simple one like this:

```bash
eksctl create cluster \
  --name my-kafka-eks \
  --region us-east-1 \
  --version 1.31 \
  --nodegroup-name kafka-nodes \
  --node-type m6i.xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 6 \
  --managed
```

**Command breakdown (in plain words):**

- `--name my-kafka-eks` → Name of your Kubernetes cluster.
- `--region us-east-1` → Which AWS data-center region to build in.
- `--node-type m6i.xlarge` → The size of each worker computer. (For real Kafka, pick memory-friendly instances. **Tip:** AWS **Graviton** instances like `m7g.xlarge` can be ~30% cheaper for Kafka, and Strimzi has ARM images — worth considering.)
- `--nodes 3` → Start with 3 worker computers.
- `--nodes-min 3 --nodes-max 6` → Allow growing from 3 up to 6 automatically.
- `--managed` → Let AWS manage the worker group for you.

This takes about **15–20 minutes**. When it's done, check it worked:

```bash
kubectl get nodes
```

You should see 3 nodes with status `Ready`.

📚 *Reference: [Deploying and scaling Kafka on Amazon EKS (AWS Blog)](https://aws.amazon.com/blogs/containers/deploying-and-scaling-apache-kafka-on-amazon-eks/)*

---

## 4. Scenario A: Prepare Your EKS Cluster (EBS Storage)

**The story:** Kafka needs to save messages onto real hard drives so nothing is lost if a pod restarts. On AWS, those drives are **EBS volumes**. But here's a surprise: **EKS can't create EBS drives by default** — you must install a small translator called the **EBS CSI Driver** first. Then we write a "recipe" (StorageClass) for fast **gp3** disks.

> **Important Kafka rule:** Kafka needs **block storage** (like EBS). Never use file storage like NFS or EFS for Kafka data — it doesn't work properly.

### Step 1 — Install the EBS CSI Driver (the translator)

The easiest modern way is to add it as an EKS "managed add-on." First, connect the driver to AWS permissions using IRSA:

```bash
# Create the IAM permission link so the driver can make EBS volumes
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster my-kafka-eks \
  --region us-east-1 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole
```

Then install the add-on itself:

```bash
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster my-kafka-eks \
  --region us-east-1 \
  --service-account-role-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/AmazonEKS_EBS_CSI_DriverRole \
  --force
```

**What this does:** Installs the software that lets Kubernetes automatically create and attach AWS EBS drives whenever Kafka asks for one. The `$(aws sts get-caller-identity ...)` part automatically fills in your AWS account number.

### Step 2 — Create a gp3 StorageClass (the disk recipe)

Save this as `gp3-storageclass.yaml`.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-kafka
provisioner: ebs.csi.aws.com        # Use the AWS EBS driver we just installed
parameters:
  type: gp3                          # The fast, modern disk type
  fsType: xfs                        # XFS is Strimzi's recommended file system
  encrypted: "true"                  # Always encrypt Kafka data at rest
  iops: "3000"                       # Disk speed: input/output operations per second
  throughput: "250"                  # Disk speed: megabytes per second
reclaimPolicy: Retain                # KEEP the disk if the claim is deleted (safety!)
volumeBindingMode: WaitForFirstConsumer  # Make the disk in the SAME zone as the pod
allowVolumeExpansion: true           # Let us grow disks later without downtime
```

**Why these settings matter (plain language):**

- **`type: gp3`** — The current best EBS type. It lets you tune speed and size independently, and it's cheaper than the old gp2.
- **`fsType: xfs`** — Strimzi officially recommends the XFS file system for best Kafka performance.
- **`encrypted: "true"`** — Scrambles the data on disk so a stolen drive is useless. Always do this for real data.
- **`reclaimPolicy: Retain`** — If someone deletes the storage claim, **keep the actual disk**. This is a safety net against accidentally wiping your data.
- **`volumeBindingMode: WaitForFirstConsumer`** — **Critical on AWS!** EBS disks live in one Availability Zone (AZ). This setting waits to create the disk until it knows which AZ the pod landed in, so the pod and disk are always in the same zone.
- **`allowVolumeExpansion: true`** — Lets you make disks bigger later just by editing a number.

Apply it:

```bash
kubectl apply -f gp3-storageclass.yaml
```

Check it's there:

```bash
kubectl get storageclass
```

```
NAME              PROVISIONER       RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION
gp2 (default)     ebs.csi.aws.com   Delete          WaitForFirstConsumer   true
gp3-kafka         ebs.csi.aws.com   Retain          WaitForFirstConsumer   true
```

📚 *Reference: [EKS Storage Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/cost-opt-storage.html) · [Strimzi Node Pools: Storage](https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/)*

---

## 5. Scenario B: Install the Strimzi Operator

**The story:** Now we hire the expert manager (the Strimzi Cluster Operator). It will watch for our wish-lists and build Kafka. Always step one before any Kafka.

### Step 1 — Make a namespace (folder) for Kafka

```bash
kubectl create namespace kafka
```

### Step 2 — Install the operator with Helm (recommended for EKS)

We use Helm because upgrades later become one clean command.

```bash
# Add the Strimzi "app store" location
helm repo add strimzi https://strimzi.io/charts/

# Refresh the list of versions
helm repo update

# Install the operator into the kafka namespace
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --set watchAnyNamespace=false
```

**Command breakdown:**

- `helm install strimzi-operator` → Install and name this release `strimzi-operator`.
- `strimzi/strimzi-kafka-operator` → The specific chart to install.
- `--namespace kafka` → Put it in the `kafka` folder.
- `--set watchAnyNamespace=false` → Tell the operator to only manage Kafka in the `kafka` namespace (safer and simpler for starting out).

### Step 3 — Confirm the manager is awake

```bash
kubectl get pods -n kafka
```

Wait for **STATUS = Running**:

```
NAME                                        READY   STATUS    RESTARTS   AGE
strimzi-cluster-operator-6d8f5b8c9-abcde    1/1     Running   0          40s
```

📚 *Reference: [Deploying the Cluster Operator with Helm](https://strimzi.io/docs/operators/latest/deploying#deploying-cluster-operator-helm-chart-str)*

---

## 6. Scenario C: Deploy a Kafka Cluster on EKS (with Metrics On)

**The story:** The manager is hired. Now we describe our post office. On EKS we make three important choices: (1) use our **gp3-kafka** storage, (2) spread brokers across **Availability Zones** for resilience, and (3) turn on **metrics** right away so Prometheus can watch it later.

### Step 1 — Turn on metrics with a ConfigMap

Kafka can expose its internal health numbers, but you have to switch that on. We do this with a **ConfigMap** (a small settings file). Save as `kafka-metrics-config.yaml`.

```yaml
kind: ConfigMap
apiVersion: v1
metadata:
  name: kafka-metrics
  labels:
    app: strimzi
data:
  kafka-metrics-config.yml: |
    # This tells Kafka which internal numbers to publish for Prometheus.
    # (This is the standard Strimzi example config — safe to use as-is.)
    lowercaseOutputName: true
    rules:
      - pattern: "kafka.server<type=(.+), name=(.+)PerSec\\w*, topic=(.+)><>Count"
        name: kafka_server_$1_$2_total
        labels:
          topic: "$3"
      - pattern: "kafka.server<type=(.+), name=(.+)PerSec\\w*><>Count"
        name: kafka_server_$1_$2_total
      - pattern: "kafka.(\\w+)<type=(.+), name=(.+)><>Value"
        name: kafka_$1_$2_$3
      - pattern: "kafka.server<type=(.+), name=(.+), clientId=(.+), topic=(.+), partition=(.*)><>Value"
        name: kafka_server_$1_$2
        labels:
          clientId: "$3"
          topic: "$4"
          partition: "$5"
```

Apply it:

```bash
kubectl apply -f kafka-metrics-config.yaml -n kafka
```

> **Note:** The rules above are a trimmed example. For the full, official metrics rules, copy Strimzi's `examples/metrics/kafka-metrics.yaml` from their [GitHub repo](https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/metrics). It's long but battle-tested.

### Step 2 — Write the Kafka cluster YAML

Save as `kafka-cluster-eks.yaml`. This uses **separate controller and broker pools**, our **gp3-kafka** storage, **AZ spreading**, and hooks up **metrics + Kafka Exporter** (for consumer-lag numbers).

```yaml
# ---------- TEAM 1: Controllers (the managers) ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 3                        # 3 controllers (odd number = good for voting)
  roles:
    - controller
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi
        class: gp3-kafka             # Use our AWS gp3 storage recipe
        deleteClaim: false
---
# ---------- TEAM 2: Brokers (the workers) ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 3                        # 3 brokers
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 100Gi                  # Brokers hold real data, so bigger disks
        class: gp3-kafka
        deleteClaim: false
  template:
    pod:
      # Spread the 3 brokers across 3 different AWS Availability Zones.
      # If one whole zone goes down, Kafka keeps running.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              strimzi.io/cluster: my-cluster
              strimzi.io/pool-name: broker
---
# ---------- THE KAFKA CLUSTER ITSELF ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  annotations:
    strimzi.io/node-pools: enabled   # Turn on node pools
    strimzi.io/kraft: enabled        # Turn on KRaft (no ZooKeeper!)
spec:
  kafka:
    version: 4.0.0
    metadataVersion: 4.0-IV3
    replicas: 3                      # Required by schema; node pools set the real count
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
      # Safety settings so losing a broker never loses data:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    # Turn ON metrics using the ConfigMap we made:
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics
          key: kafka-metrics-config.yml
    storage:
      type: jbod
      volumes:
        - id: 0
          type: persistent-claim
          size: 100Gi
          class: gp3-kafka
          deleteClaim: false
  entityOperator:                    # Helpers that manage topics and users
    topicOperator: {}
    userOperator: {}
  # Kafka Exporter adds consumer-lag and topic-level metrics (very useful!)
  kafkaExporter:
    topicRegex: ".*"                 # Watch all topics
    groupRegex: ".*"                 # Watch all consumer groups
  # Cruise Control auto-balances data across brokers (needed for scaling later)
  cruiseControl: {}
```

**Key EKS-specific things explained:**

- **`class: gp3-kafka`** on every volume — points Kafka at our fast AWS storage recipe.
- **`topologySpreadConstraints` with `topologyKey: zone`** — This forces the 3 brokers into 3 different AWS Availability Zones. If one AWS zone has an outage, your other 2 brokers keep the post office open. This is one of the most important resilience settings on any cloud.
- **`metricsConfig`** — Switches on the health-number feed for Prometheus.
- **`kafkaExporter`** — A bonus component that specifically tracks **consumer lag** (how far behind your reading apps are). This is the #1 thing teams want to watch.

### Step 3 — Deploy it

```bash
kubectl apply -f kafka-cluster-eks.yaml -n kafka
```

### Step 4 — Watch it build (this creates real EBS volumes!)

```bash
kubectl get pods -n kafka -w
```

Behind the scenes, Strimzi is asking AWS to create EBS gp3 disks and attach them. Wait until everything is `Running`:

```
NAME                          READY   STATUS    RESTARTS   AGE
my-cluster-broker-3           1/1     Running   0          3m
my-cluster-broker-4           1/1     Running   0          3m
my-cluster-broker-5           1/1     Running   0          3m
my-cluster-controller-0       1/1     Running   0          3m
my-cluster-controller-1       1/1     Running   0          3m
my-cluster-controller-2       1/1     Running   0          3m
my-cluster-entity-operator    2/2     Running   0          2m
my-cluster-kafka-exporter     1/1     Running   0          1m
```

### Step 5 — Confirm the cluster is truly ready

```bash
kubectl get kafka my-cluster -n kafka
```

Look for **READY = True** and **METADATA STATE = KRaft**. 🎉

You can also confirm the EBS volumes were created:

```bash
kubectl get pvc -n kafka
```

Each broker and controller should have a `Bound` claim using `gp3-kafka`.

📚 *Reference: [Deploying a Kafka cluster](https://strimzi.io/docs/operators/latest/deploying#kafka-cluster-str) · [Metrics setup](https://strimzi.io/docs/operators/latest/deploying#assembly-metrics-str)*

---

## 7. Scenario D: Create Topics

**The story:** The post office is open but has no mailboxes. Let's add one called `orders`.

Save as `orders-topic.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3                      # 3 "lanes" for parallel speed
  replicas: 3                        # 3 copies for safety
  config:
    retention.ms: 604800000          # Keep messages 7 days, then auto-delete
    min.insync.replicas: 2           # At least 2 copies must confirm each write
```

```bash
kubectl apply -f orders-topic.yaml -n kafka
kubectl get kafkatopics -n kafka
```

- **`partitions: 3`** — Like a 3-lane highway; more lanes = more messages at once. You can add lanes later but not easily remove them, so don't overdo it.
- **`replicas: 3`** — Every message stored on 3 brokers. Lose one disk, two copies remain.
- **`retention.ms: 604800000`** — 7 days in milliseconds (7 × 24 × 60 × 60 × 1000). Stops disks from filling forever.

> **Best practice:** Always define topics as YAML files (declarative). Save them in Git so your setup is repeatable and reviewable.

📚 *Reference: [Managing topics with KafkaTopic](https://strimzi.io/docs/operators/latest/deploying#config-topics-str)*

---

## 8. Scenario E: Security & User Management

**The story:** Right now anyone inside the cluster can connect. For real data, add two locks: **encryption** (scramble data in transit) and **authentication** (require an ID card). Then create users with only the permissions they need.

### The 3 layers of Kafka security

| Layer | Question it answers | Example |
|-------|--------------------|---------|
| **Encryption (TLS)** | "Can spies read my data as it travels?" | No — it's scrambled. |
| **Authentication** | "Who are you?" | Prove it with a certificate or password. |
| **Authorization (ACLs)** | "What are you allowed to do?" | You may read `orders`, not write to it. |

### Step 1 — Require authentication + turn on the rules system

Update the `tls` listener and add authorization in your `Kafka` resource:

```yaml
spec:
  kafka:
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true                    # Encryption ON
        authentication:
          type: tls                  # Require a certificate (mutual TLS / mTLS)
    authorization:
      type: simple                   # Turn on ACL rules ("deny by default")
```

Apply it. Strimzi does a careful **rolling update** — restarting brokers one at a time so the post office never fully closes.

```bash
kubectl apply -f kafka-cluster-eks.yaml -n kafka
```

**Your authentication options:**

| Type | What it is | When to use it |
|------|-----------|----------------|
| **`tls`** (mTLS) | Both sides show certificates. Strimzi makes them for you. | App-to-Kafka inside your systems. Most secure default. |
| **`scram-sha-512`** | Username + password (password never sent in the clear). | When certificates are hard to distribute. |
| **`oauth`** | Log in via a central identity system (Keycloak, Okta, etc.). | Big companies with single sign-on. |

> **Strimzi handles certificates for you.** The scary part of security is usually creating and rotating certificates. Strimzi generates and auto-renews them quietly in the background. You mostly never touch them.

### Step 2 — Create a user with least-privilege permissions

> **The Golden Rule — "Least Privilege":** Give every user the *smallest* set of permissions needed. Never hand "admin everything" to an app that only reads one topic.

Save as `app-orders-user.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: app-orders
  labels:
    strimzi.io/cluster: my-cluster
spec:
  authentication:
    type: tls                        # This user logs in with a certificate
  authorization:
    type: simple
    acls:
      # Allow READING from the "orders" topic
      - resource:
          type: topic
          name: orders
          patternType: literal
        operations:
          - Read
          - Describe
        host: "*"
      # Allow this app's consumer group to track its reading progress
      - resource:
          type: group
          name: orders-app-group
          patternType: literal
        operations:
          - Read
  # Fairness limits so one app can't hog the whole cluster:
  quotas:
    producerByteRate: 1048576        # Max 1 MB/sec writing
    consumerByteRate: 2097152        # Max 2 MB/sec reading
    requestPercentage: 50            # Max 50% of a broker's request time
```

**Reading this like a sentence:** "User `app-orders` logs in with a certificate. It may **Read** and **Describe** the `orders` topic and use the `orders-app-group` consumer group. It can do nothing else, and it's speed-limited for fairness."

**Operation meanings:** `Read` = consume messages; `Write` = produce messages; `Describe` = look up topic info (needed alongside Read/Write); `Create`/`Delete` = make/remove topics.

```bash
kubectl apply -f app-orders-user.yaml -n kafka
kubectl get kafkausers -n kafka
```

### Step 3 — Get the user's login credentials

When you create the user, Strimzi automatically makes a **Secret** (a safe locker) named `app-orders` holding the certificate and keys the app needs:

```bash
kubectl get secret app-orders -n kafka -o jsonpath='{.data}' | jq
```

Inside you'll find `user.crt` (certificate), `user.key` (private key), and `ca.crt` (the cluster's authority cert). Your application uses these three to prove its identity and connect securely.

📚 *Reference: [Securing Kafka](https://strimzi.io/docs/operators/latest/deploying#assembly-securing-access-str) · [Managing users](https://strimzi.io/docs/operators/latest/deploying#assembly-securing-kafka-authorization-str)*

---

## 9. Scenario F: Deploy a Kafka UI (Web Dashboard)

**The story:** Typing commands to see topics is tiring. A **Kafka UI** is a friendly website where you click around to see topics, browse messages, check consumer lag, and more. We'll deploy the popular open-source **Kafbat UI** (the actively maintained successor to the well-known "provectus/kafka-ui").

### Step 1 — Add the Kafbat UI Helm repository

```bash
helm repo add kafbat-ui https://kafbat.github.io/helm-charts
helm repo update
```

### Step 2 — Write a small config file pointing it at your cluster

Save as `kafka-ui-values.yaml`. This tells the UI how to reach your Kafka.

```yaml
yamlApplicationConfig:
  kafka:
    clusters:
      - name: my-cluster
        # The internal address Strimzi created for your brokers:
        bootstrapServers: my-cluster-kafka-bootstrap.kafka.svc:9092
  auth:
    type: disabled          # No login on the UI itself (fine for internal/testing)
  management:
    health:
      ldap:
        enabled: false

# Keep the UI reachable only inside the cluster for now (we'll port-forward):
service:
  type: ClusterIP
```

**Plain-language notes:**

- **`bootstrapServers: my-cluster-kafka-bootstrap.kafka.svc:9092`** — This is the automatic "front door" address Strimzi creates. The pattern is `<cluster-name>-kafka-bootstrap.<namespace>.svc:<port>`.
- **`auth.type: disabled`** — For a quick internal dashboard this is fine. For production, enable login (the chart supports OAuth/LDAP).
- **`service.type: ClusterIP`** — Keeps the UI private inside the cluster. We'll reach it safely with port-forwarding. (To expose it to the internet on EKS, you'd switch to a LoadBalancer or an Ingress with the AWS Load Balancer Controller — but keep it protected!)

### Step 3 — Install the UI

```bash
helm install kafka-ui kafbat-ui/kafka-ui \
  --namespace kafka \
  --values kafka-ui-values.yaml
```

### Step 4 — Open the dashboard in your browser

```bash
kubectl port-forward svc/kafka-ui 8080:80 -n kafka
```

**What port-forward does:** Builds a private tunnel from your laptop's port `8080` to the UI pod inside EKS. Now open your browser to:

```
http://localhost:8080
```

You'll see a dashboard listing your `my-cluster`, its topics (like `orders`), messages inside them, consumer groups, and their lag. Much friendlier than commands!

> **Security warning for production:** If you expose the Kafka UI to the internet, **always** put authentication in front of it and connect it to Kafka using the **TLS listener (9093) with credentials**, not the plaintext 9092 port. An open Kafka UI on the internet is a serious risk.

📚 *Reference: [Kafbat UI (GitHub)](https://github.com/kafbat/kafka-ui) · [Kafbat Helm charts](https://github.com/kafbat/helm-charts)*

---

## 10. Scenario G: Monitoring with Prometheus + Grafana Pods

**The story:** We turned on Kafka's metrics earlier. Now we deploy the two robots that use them: **Prometheus** (collects the numbers) and **Grafana** (draws the graphs). Both run as **pods inside your EKS cluster**. The cleanest way is the **kube-prometheus-stack** Helm chart, which installs Prometheus, Grafana, and Alertmanager all together.

### Step 1 — Make a monitoring namespace

```bash
kubectl create namespace monitoring
```

### Step 2 — Add the Prometheus community Helm repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 3 — Install the whole monitoring stack

Save this small config as `monitoring-values.yaml` first. It makes Prometheus notice Strimzi's monitors and sets a Grafana password.

```yaml
prometheus:
  prometheusSpec:
    # Let Prometheus find PodMonitors in ALL namespaces, not just its own:
    podMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    # Give Prometheus its own gp3 disk so it remembers metrics across restarts:
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3-kafka
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

grafana:
  adminPassword: "ChangeMe123!"      # Login password for Grafana (change this!)
  service:
    type: ClusterIP                  # Keep Grafana private; we'll port-forward
  persistence:
    enabled: true
    storageClassName: gp3-kafka
    size: 10Gi
```

Now install:

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring-values.yaml
```

**What just happened:** Helm deployed Prometheus pods, a Grafana pod, and Alertmanager — all onto your EKS nodes, each with its own gp3 disk. The two `...SelectorNilUsesHelmValues: false` lines are the magic that lets Prometheus pick up the Kafka monitors we're about to create.

Check they're running:

```bash
kubectl get pods -n monitoring
```

### Step 4 — Tell Prometheus to scrape Kafka (PodMonitors)

A **PodMonitor** is a rule that says "collect metrics from these specific pods." Strimzi's pods expose metrics on port `9404` (Kafka) and the Kafka Exporter has its own. Save as `kafka-podmonitors.yaml`:

```yaml
# Collect the main Kafka broker/controller metrics (port 9404)
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: kafka-resources-metrics
  namespace: monitoring
  labels:
    app: strimzi
spec:
  selector:
    matchExpressions:
      - key: "strimzi.io/kind"
        operator: In
        values: ["Kafka"]
  namespaceSelector:
    matchNames:
      - kafka                        # Look in the kafka namespace
  podMetricsEndpoints:
    - path: /metrics
      port: tcp-prometheus           # Strimzi names the metrics port this
      relabelings:
        - separator: ;
          regex: __meta_kubernetes_pod_label_(strimzi_io_.+)
          replacement: $1
          action: labelmap
---
# Collect Kafka Exporter metrics (consumer lag, topic stats)
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: kafka-exporter-metrics
  namespace: monitoring
  labels:
    app: strimzi
spec:
  selector:
    matchLabels:
      strimzi.io/kind: KafkaExporter
  namespaceSelector:
    matchNames:
      - kafka
  podMetricsEndpoints:
    - path: /metrics
      port: tcp-prometheus
```

Apply it:

```bash
kubectl apply -f kafka-podmonitors.yaml
```

**In plain words:** The first rule grabs the big pile of Kafka broker/controller numbers. The second grabs the Kafka Exporter's consumer-lag numbers. The `namespaceSelector` tells Prometheus (living in `monitoring`) to reach across into the `kafka` namespace to collect them.

### Step 5 — Open Grafana and log in

```bash
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring
```

Open your browser to `http://localhost:3000`. Log in with:

- Username: `admin`
- Password: `ChangeMe123!` (whatever you set in the values file)

Prometheus is **already connected** as a data source by this chart — no setup needed.

### Step 6 — Import Strimzi's ready-made Kafka dashboards

Strimzi publishes beautiful pre-built dashboards. You don't have to build graphs by hand.

1. In Grafana, click the **+** menu → **Import**.
2. Grab the dashboard JSON files from Strimzi's GitHub: the `examples/metrics/grafana-dashboards` folder. Useful ones include:
   - `strimzi-kafka.json` — overall Kafka health.
   - `strimzi-kafka-exporter.json` — consumer lag and topic details.
   - `strimzi-operators.json` — how the Strimzi operator itself is doing.
3. Paste the JSON (or upload the file) and pick **Prometheus** as the data source.

Now you have live graphs of message throughput, consumer lag, partition health, CPU, and more — all updating in real time. 🎉

> **Tip:** If a graph shows "No Data," it's usually because there's no traffic yet. Produce some test messages (see the cheat sheet) and watch the graphs come alive.

📚 *Reference: [Strimzi Metrics & Grafana dashboards](https://strimzi.io/docs/operators/latest/deploying#assembly-metrics-str) · [Grafana dashboards on GitHub](https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/metrics/grafana-dashboards) · [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)*

---

## 11. Scenario H: Send Logs to AWS CloudWatch (Fluent Bit)

**The story:** Metrics are numbers; **logs** are the actual text diaries your pods write ("ERROR: connection refused"). To keep and search these safely, we ship them to **AWS CloudWatch** using a lightweight courier called **Fluent Bit**. Fluent Bit runs as a **DaemonSet** — one copy on every EKS node — reading all container logs and forwarding them.

> **Difference recap:** Prometheus/Grafana = **numbers and graphs**. CloudWatch logs = **searchable text of what happened**. You want both.

### Step 1 — Give Fluent Bit permission to write to CloudWatch (IRSA)

On AWS, a pod needs an IAM role to touch CloudWatch. We use **IRSA** (IAM Roles for Service Accounts) — the safe, modern way.

First, make the CloudWatch namespace:

```bash
kubectl create namespace amazon-cloudwatch
```

Now create a service account tied to an IAM role that can write logs:

```bash
eksctl create iamserviceaccount \
  --name fluent-bit \
  --namespace amazon-cloudwatch \
  --cluster my-kafka-eks \
  --region us-east-1 \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts
```

**Plain-language breakdown:**

- `--name fluent-bit` → The Kubernetes identity Fluent Bit will use.
- `--attach-policy-arn ...CloudWatchAgentServerPolicy` → An official AWS permission set that allows creating log groups and writing logs.
- `--approve` → Yes, actually create the IAM role.

**Why IRSA?** Instead of pasting AWS secret keys into your pods (dangerous!), IRSA lets the pod borrow a proper IAM role automatically. It's the AWS-recommended approach.

### Step 2 — Install the CloudWatch Container Insights + Fluent Bit quick start

AWS provides a one-shot install. First set your names:

```bash
ClusterName=my-kafka-eks
RegionName=us-east-1
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off' || FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
```

Then create the little info ConfigMap Fluent Bit reads:

```bash
kubectl create configmap fluent-bit-cluster-info \
  --from-literal=cluster.name=${ClusterName} \
  --from-literal=http.server=${FluentBitHttpServer} \
  --from-literal=http.port=${FluentBitHttpPort} \
  --from-literal=read.head=${FluentBitReadFromHead} \
  --from-literal=read.tail=${FluentBitReadFromTail} \
  --from-literal=logs.region=${RegionName} \
  -n amazon-cloudwatch
```

Finally, deploy Fluent Bit as a DaemonSet:

```bash
kubectl apply -f https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/fluent-bit/fluent-bit.yaml
```

**What this does:** Places one Fluent Bit pod on each EKS worker node. Each pod tails the container log files on its node and streams them to CloudWatch Logs, automatically creating log groups.

### Step 3 — Confirm Fluent Bit is running everywhere

```bash
kubectl get pods -n amazon-cloudwatch
```

You should see one `fluent-bit-xxxxx` pod **per node** (that's what DaemonSet means):

```
NAME               READY   STATUS    RESTARTS   AGE
fluent-bit-4k2n9   1/1     Running   0          60s
fluent-bit-7xj3p   1/1     Running   0          60s
fluent-bit-9mq8d   1/1     Running   0          60s
```

### Step 4 — Find your Kafka logs in CloudWatch

Go to the **AWS Console → CloudWatch → Log groups**. You'll find groups like:

```
/aws/containerinsights/my-kafka-eks/application    ← your pod logs (including Kafka)
/aws/containerinsights/my-kafka-eks/dataplane      ← Kubernetes system logs
/aws/containerinsights/my-kafka-eks/host           ← node-level logs
```

Open `/aws/containerinsights/my-kafka-eks/application` and you'll see log streams for your Kafka broker pods, the operator, the Kafka UI — everything. You can now **search** all your Kafka logs in one place, set up **CloudWatch alarms**, and keep logs for as long as you need.

> **Cost note:** CloudWatch charges by volume of logs ingested and stored. Kafka can be chatty. Set a **retention period** on your log groups (e.g., 30 days) and consider filtering out noisy debug logs to control cost.

📚 *Reference: [Set up Fluent Bit for CloudWatch (AWS)](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-logs-FluentBit.html) · [Container Insights + Fluent Bit (AWS re:Post)](https://repost.aws/knowledge-center/eks-fluent-bit-container-insights)*

---

## 12. Scenario I: Upgrading Strimzi and Kafka

**The story:** New versions bring security fixes and features. Upgrading has **two parts, in order**: first the **operator**, then **Kafka itself**.

> ⚠️ **Big warning:** From **Strimzi 1.0.0**, only the new `v1` API is supported. Older `v1beta2` files must be converted **before** upgrading to 1.0.0. Always read release notes and **back up your YAML and data** first.

### Part 1 — Upgrade the operator (clean with Helm)

```bash
helm repo update

helm upgrade strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka
```

Confirm it restarted:

```bash
kubectl get pods -n kafka -l name=strimzi-cluster-operator
```

### Part 2 — Upgrade Kafka itself (change two numbers, in order)

Edit your `Kafka` resource. **Do these one at a time:**

**Step 1:** Bump only `version` (e.g., `3.9.0` → `4.0.0`) and apply:

```yaml
spec:
  kafka:
    version: 4.0.0             # ⬅️ Change this FIRST
    metadataVersion: 3.9-IV0   # ⬅️ Leave this alone for now
```

```bash
kubectl apply -f kafka-cluster-eks.yaml -n kafka
kubectl get pods -n kafka -w    # Watch the rolling upgrade (one broker at a time)
```

**Step 2:** Once every pod is `Running` and the cluster is ready, bump `metadataVersion` to match and apply again:

```yaml
spec:
  kafka:
    version: 4.0.0
    metadataVersion: 4.0-IV3   # ⬅️ NOW update this
```

**Why two steps?** `metadataVersion` is like upgrading the building's foundation. You only do it *after* confirming all workers moved into the new building. Doing `version` first keeps an easy escape route if something goes wrong.

Check what you're actually running:

```bash
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.kafkaVersion}'
```

📚 *Reference: [Upgrading Strimzi](https://strimzi.io/docs/operators/latest/deploying#assembly-upgrade-str)*

---

## 13. Scenario J: Scaling on EKS

**The story:** Your app got popular. Add more brokers. With node pools this is easy — and on EKS, remember new brokers need new nodes and rebalancing.

### Step 1 — Increase broker count

Edit the **broker** KafkaNodePool: change `replicas` from 3 to 5.

```yaml
spec:
  replicas: 5    # ⬅️ Was 3
```

```bash
kubectl apply -f kafka-cluster-eks.yaml -n kafka
```

> **EKS tip:** If your nodes are full, the new broker pods will be stuck `Pending` until more EC2 nodes exist. Make sure your node group can grow (the `--nodes-max` from earlier) or use **Karpenter/Cluster Autoscaler** to add nodes automatically.

### Step 2 — Rebalance data onto the new brokers (Cruise Control)

New brokers start **empty**. Use Cruise Control (we enabled it earlier) to spread data evenly. Save as `rebalance.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: my-rebalance
  labels:
    strimzi.io/cluster: my-cluster
spec:
  mode: add-brokers
  brokers: [6, 7]        # The IDs of the newly added brokers
```

```bash
kubectl apply -f rebalance.yaml -n kafka

# Strimzi calculates a plan ("proposal"). Approve it to start moving data:
kubectl annotate kafkarebalance my-rebalance strimzi.io/rebalance=approve -n kafka

# Watch progress:
kubectl get kafkarebalance my-rebalance -n kafka
```

When status reaches `Ready`, data is balanced across all 5 brokers. Without this step, your new brokers sit idle and you don't get the performance you paid for.

📚 *Reference: [Scaling clusters](https://strimzi.io/docs/operators/latest/deploying#scaling-clusters-str) · [Cruise Control](https://strimzi.io/docs/operators/latest/deploying#cruise-control-concept-str)*

---

## 14. Everyday Operations Cheat Sheet

Assume everything is in the `kafka` namespace unless noted.

### Looking at things

```bash
kubectl get strimzi -n kafka        # See EVERYTHING Strimzi manages
kubectl get k  -n kafka             # Kafka clusters (short name)
kubectl get kt -n kafka             # Topics
kubectl get ku -n kafka             # Users
kubectl get knp -n kafka            # Node pools
kubectl get pvc -n kafka            # The EBS volumes in use
kubectl describe kafka my-cluster -n kafka   # Deep detail for troubleshooting
```

### Reading logs (three ways)

```bash
# Live from a pod (fastest for right-now debugging)
kubectl logs my-cluster-broker-3 -n kafka -f

# The operator's diary — #1 place to see why something failed
kubectl logs -n kafka -l name=strimzi-cluster-operator -f

# Historical / searchable → AWS Console → CloudWatch → Log groups
#   /aws/containerinsights/my-kafka-eks/application
```

### Send and receive a test message

Producer (type messages, Enter to send):

```bash
kubectl -n kafka run kafka-producer -ti \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic orders
```

Consumer (in a second terminal, watch messages arrive):

```bash
kubectl -n kafka run kafka-consumer -ti \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic orders --from-beginning
```

Then watch the numbers move in **Grafana** and the logs appear in **CloudWatch**.

### Open your dashboards

```bash
# Kafka UI
kubectl port-forward svc/kafka-ui 8080:80 -n kafka          # http://localhost:8080

# Grafana
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring   # http://localhost:3000

# Prometheus (optional, to check raw metrics/targets)
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
```

### Deleting things (careful!)

```bash
kubectl delete kafkatopic orders -n kafka        # One topic
kubectl delete kafkauser app-orders -n kafka     # One user
kubectl delete kafka my-cluster -n kafka         # ⚠️ The ENTIRE cluster
```

> Because you set `deleteClaim: false` and `reclaimPolicy: Retain`, deleting the cluster does **not** auto-wipe your EBS disks. To reclaim that storage (and stop paying for it), delete the PVCs and check the EBS volumes in the AWS Console afterward.

---

## 15. EKS Best Practices Checklist

**AWS / EKS Specifics**
- ✅ Install the **EBS CSI driver** and use a **gp3** StorageClass (encrypted, XFS).
- ✅ Use **`volumeBindingMode: WaitForFirstConsumer`** so disks and pods share an AZ.
- ✅ Spread brokers across **3 Availability Zones** with topology spread constraints.
- ✅ Use **IRSA** for AWS permissions (Fluent Bit, EBS driver) — never hardcode keys.
- ✅ Set **`reclaimPolicy: Retain`** and **`deleteClaim: false`** to protect data.
- ✅ Consider **Graviton (arm64)** instances for ~30% better price-performance.
- ✅ Enable node autoscaling (**Karpenter** or Cluster Autoscaler) so scaling works.

**Architecture**
- ✅ Use **KRaft mode** for everything new — never start with ZooKeeper.
- ✅ Separate **controller** and **broker** node pools in production.
- ✅ Use an **odd number of controllers** (3 or 5) to avoid tie votes.
- ✅ Run at least **3 brokers** for fault tolerance.

**Data Safety**
- ✅ **Replication factor 3** and **`min.insync.replicas: 2`**.
- ✅ Always use **persistent-claim** storage (never ephemeral) for real data.

**Security**
- ✅ Turn on **TLS encryption** and **authentication** — never leave the door open.
- ✅ Turn on **authorization** (`type: simple`) for "deny by default."
- ✅ Follow **least privilege** with ACLs; add **quotas** for fairness.
- ✅ Protect the **Kafka UI** with auth if exposed; connect it via the TLS listener.

**Observability**
- ✅ Turn on **metrics** (`metricsConfig`) and **Kafka Exporter** from day one.
- ✅ Run **Prometheus + Grafana** pods; import Strimzi's ready-made dashboards.
- ✅ Ship logs to **CloudWatch** with Fluent Bit; set **log retention** to control cost.
- ✅ Watch **consumer lag** — it's the #1 early warning that something's wrong.

**Operations**
- ✅ Keep all YAML in **Git** (Infrastructure as Code).
- ✅ Upgrade **operator first**, then Kafka `version`, then `metadataVersion`.
- ✅ **Read release notes** before every upgrade (especially 1.0.0's v1 API change).
- ✅ Use **Cruise Control** to rebalance after scaling.

---

## 16. Reference Links

**Strimzi Official**
- Strimzi Homepage — https://strimzi.io/
- Deploying and Managing Strimzi — https://strimzi.io/docs/operators/latest/deploying
- Configuring Strimzi — https://strimzi.io/docs/operators/latest/configuring.html
- Metrics example files (GitHub) — https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/metrics
- Grafana dashboards (GitHub) — https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/metrics/grafana-dashboards
- Releases & changelog — https://github.com/strimzi/strimzi-kafka-operator/releases
- Node Pools: Storage & Scheduling (blog) — https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/

**AWS EKS**
- Deploying & scaling Kafka on EKS (AWS Blog) — https://aws.amazon.com/blogs/containers/deploying-and-scaling-apache-kafka-on-amazon-eks/
- EKS Storage Best Practices — https://docs.aws.amazon.com/eks/latest/best-practices/cost-opt-storage.html
- EBS CSI Driver add-on — https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
- Data on EKS (Kafka blueprints) — https://github.com/awslabs/data-on-eks

**AWS CloudWatch + Fluent Bit**
- Set up Fluent Bit for CloudWatch — https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-logs-FluentBit.html
- Container Insights + Fluent Bit (re:Post) — https://repost.aws/knowledge-center/eks-fluent-bit-container-insights
- EKS Workshop: Fluent Bit — https://www.eksworkshop.com/docs/observability/logging/pod-logging/fluentbit-setup

**Monitoring Stack**
- kube-prometheus-stack Helm chart — https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Prometheus Operator (PodMonitor docs) — https://prometheus-operator.dev/

**Kafka UI**
- Kafbat UI (GitHub) — https://github.com/kafbat/kafka-ui
- Kafbat Helm charts — https://github.com/kafbat/helm-charts

**Apache Kafka**
- Apache Kafka docs — https://kafka.apache.org/documentation/

---

*You now have a full AWS EKS Kafka platform: gp3 storage, a Strimzi-managed KRaft cluster spread across zones, secured with TLS and per-user ACLs, a friendly Kafka UI, Prometheus + Grafana dashboards, and all logs flowing to CloudWatch. Start small, get each piece working end to end, then apply the production checklist. Happy streaming! 🚀*
