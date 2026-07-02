# The Complete Beginner-Friendly Guide to Kafka on Kubernetes with Strimzi

*Written in plain language, like a friendly teacher explaining things step by step.*

Last updated using Strimzi **1.0.0 / 1.1.0** and **Kafka 4.0** best practices (2025–2026).

---

## Table of Contents

1. [What Is All of This? (The Big Picture)](#1-what-is-all-of-this-the-big-picture)
2. [The Important Words You Need to Know](#2-the-important-words-you-need-to-know)
3. [Scenario A: Installing the Strimzi Operator](#3-scenario-a-installing-the-strimzi-operator)
4. [Scenario B: Deploying Your First Kafka Cluster](#4-scenario-b-deploying-your-first-kafka-cluster)
5. [Scenario C: Creating Topics](#5-scenario-c-creating-topics)
6. [Scenario D: Security Setup (Encryption + Authentication)](#6-scenario-d-security-setup-encryption--authentication)
7. [Scenario E: User Management (Creating Users & Permissions)](#7-scenario-e-user-management-creating-users--permissions)
8. [Scenario F: Upgrading Strimzi and Kafka](#8-scenario-f-upgrading-strimzi-and-kafka)
9. [Scenario G: Scaling Your Cluster Bigger](#9-scenario-g-scaling-your-cluster-bigger)
10. [Scenario H: Everyday Operations (Cheat Sheet)](#10-scenario-h-everyday-operations-cheat-sheet)
11. [Best Practices Checklist](#11-best-practices-checklist)
12. [Reference Links](#12-reference-links)

---

## 1. What Is All of This? (The Big Picture)

Imagine a giant **post office** for computer programs. Programs write letters (called **messages**), drop them into labeled mailboxes (called **topics**), and other programs pick up those letters and read them. That post office is **Apache Kafka**. It's used by huge companies to move billions of messages every day.

Now, running that post office is hard work. You have to set up buildings, hire workers, replace broken equipment, and keep everything secure. **Kubernetes** is like a robot city-manager that runs buildings (called **containers**) for you automatically.

But Kubernetes doesn't naturally know how to run a Kafka post office — Kafka is *stateful* (it remembers things and stores data), while Kubernetes normally assumes buildings can be knocked down and rebuilt anytime. That mismatch causes problems.

**Strimzi** is the expert manager you hire that sits inside Kubernetes and knows *exactly* how to run Kafka the right way. It's officially called an **Operator**. You just write a short wish-list in a file, and Strimzi does all the hard setup, upgrades, and repairs for you.

> **In one sentence:** Strimzi lets you run Kafka on Kubernetes by writing simple YAML files instead of doing hundreds of manual steps.

Strimzi is a **Cloud Native Computing Foundation (CNCF)** project, which means it's trusted, open-source, and widely used in the industry.

---

## 2. The Important Words You Need to Know

Think of these like vocabulary words before a big test.

| Word | Simple Meaning |
|------|----------------|
| **Kubernetes (k8s)** | The robot city-manager that runs your containers. |
| **Container / Pod** | A "building" where one piece of software lives and runs. A Pod is Kubernetes' smallest unit. |
| **Namespace** | A labeled folder inside Kubernetes that keeps related things together (like a folder named `kafka`). |
| **YAML file** | A plain-text wish-list where you describe what you want. Very picky about spaces! |
| **Operator** | An expert robot that manages a specific app. Strimzi is the Kafka operator. |
| **Cluster Operator** | The main Strimzi robot. It watches your wish-lists and builds Kafka. You install this **first**. |
| **Custom Resource (CR)** | A new *type* of wish-list that Strimzi teaches Kubernetes to understand (like `Kafka`, `KafkaTopic`, `KafkaUser`). |
| **Broker** | A Kafka worker that actually stores and hands out messages. |
| **Controller** | A Kafka manager that keeps track of who's doing what (the "metadata"). |
| **KRaft** | The modern way Kafka manages itself **without** the old, extra "ZooKeeper" helper. This is now the standard. |
| **ZooKeeper** | The OLD helper Kafka used to need. It's **removed in Kafka 4.0**. You should not use it for anything new. |
| **KafkaNodePool** | A "team" of Kafka nodes that share the same settings. You use these to organize brokers and controllers. |
| **Topic** | A labeled mailbox where messages of one kind go. |
| **Producer** | A program that *writes* messages into topics. |
| **Consumer** | A program that *reads* messages out of topics. |
| **TLS** | Scrambling data so nobody can spy on it while it travels (encryption). |
| **Authentication** | Proving you are who you say you are (like showing an ID card). |
| **Authorization / ACL** | Rules about what you're allowed to do once you're let in (Access Control List). |
| **kubectl** | The command-line tool you type to talk to Kubernetes. Say it "koob-cuttle" or "koob-control." |

> **A note on KRaft vs ZooKeeper:** Older tutorials mention ZooKeeper everywhere. Ignore that for new setups. Since **Kafka 4.0** and modern Strimzi, **KRaft is the only way** and it's simpler and safer. This whole guide uses KRaft.

---

## 3. Scenario A: Installing the Strimzi Operator

**The story:** Before you can run any Kafka, you need to hire the manager (the Cluster Operator). This is always step one.

### Step 1 — Make a folder (namespace) for Kafka

We keep everything tidy inside a namespace called `kafka`.

```bash
kubectl create namespace kafka
```

**What this does:** Creates an empty labeled folder named `kafka` inside Kubernetes.

### Step 2 — Install the Strimzi Cluster Operator

The easiest way is to apply Strimzi's official install file straight from their website.

```bash
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
```

**Let's break this command apart, piece by piece:**

- `kubectl create -f` → "Kubernetes, please create things described in a file."
- `'https://strimzi.io/install/latest?namespace=kafka'` → The file lives online. The `?namespace=kafka` part tells Strimzi to set itself up to watch the `kafka` folder.
- `-n kafka` → Put these newly created things into the `kafka` folder.

### Step 3 — Check that the manager is awake and running

```bash
kubectl get pods -n kafka
```

You're waiting to see something like this, with **STATUS = Running**:

```
NAME                                        READY   STATUS    RESTARTS   AGE
strimzi-cluster-operator-6d8f5b8c9-abcde    1/1     Running   0          45s
```

If it says `Running`, congratulations — the manager is on the job! If it says `ContainerCreating`, just wait a minute and run the command again.

### Alternative: Install with Helm (a popular package tool)

Many teams prefer **Helm** because it makes future upgrades cleaner. Helm is like an "app store installer" for Kubernetes.

```bash
# Add the Strimzi "app store" location
helm repo add strimzi https://strimzi.io/charts/

# Refresh the list of available versions
helm repo update

# Install the operator into the kafka namespace
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka \
  --create-namespace
```

**Why pick Helm?** When it's time to upgrade later, you run one clean `helm upgrade` command instead of re-applying files by hand.

📚 *Reference: [Deploying the Cluster Operator](https://strimzi.io/docs/operators/latest/deploying#cluster-operator-str)*

---

## 4. Scenario B: Deploying Your First Kafka Cluster

**The story:** The manager is hired. Now we tell it, "Please build me an actual Kafka post office with workers." We do this with a YAML wish-list.

### Understanding the plan

For a **production** setup, the best practice is to keep **controllers** (the managers) and **brokers** (the workers) on **separate teams** (node pools). This makes the cluster easier to manage and scale. For quick tests, you can combine both roles on one team.

We'll create **three pieces**:
1. A **controller** node pool (3 nodes — an odd number is important for voting).
2. A **broker** node pool (3 nodes).
3. The **Kafka** resource that ties it all together.

### Step 1 — Write the YAML file

Save this as `my-kafka-cluster.yaml`.

```yaml
# ---------- TEAM 1: The Controllers (the managers) ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controller
  labels:
    strimzi.io/cluster: my-cluster   # Which Kafka cluster this team belongs to
spec:
  replicas: 3                        # 3 controllers (odd number = good for voting)
  roles:
    - controller                     # This team ONLY manages metadata
  storage:
    type: jbod                       # "Just a Bunch Of Disks" — flexible storage
    volumes:
      - id: 0
        type: persistent-claim       # Disk that survives restarts
        size: 20Gi                   # 20 gigabytes per controller
        deleteClaim: false           # Keep the disk even if the node is deleted
---
# ---------- TEAM 2: The Brokers (the workers) ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 3                        # 3 brokers to store and serve messages
  roles:
    - broker                         # This team ONLY handles data
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 100Gi                  # Brokers hold the actual data, so bigger disks
        deleteClaim: false
---
# ---------- THE KAFKA CLUSTER ITSELF ----------
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  annotations:
    strimzi.io/node-pools: enabled   # Turn on node pools
    strimzi.io/kraft: enabled        # Turn on KRaft mode (no ZooKeeper!)
spec:
  kafka:
    version: 4.0.0                   # The Kafka version to run
    metadataVersion: 4.0-IV3         # KRaft metadata format version
    listeners:                       # "Doors" that clients use to connect
      - name: plain
        port: 9092
        type: internal
        tls: false                   # Unencrypted door (inside cluster only)
      - name: tls
        port: 9093
        type: internal
        tls: true                    # Encrypted door
    config:
      # These 3 settings keep your data safe if a node dies.
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
  entityOperator:                    # Helpers that manage topics and users
    topicOperator: {}
    userOperator: {}
```

**Why these numbers matter (in plain terms):**

- **`replicas: 3`** for controllers — Kafka controllers vote on decisions. An odd number (3, 5) prevents tie votes.
- **`replication.factor: 3`** — Every message is copied to 3 brokers. If one broker's disk dies, two copies survive. This is the golden rule of not losing data.
- **`min.insync.replicas: 2`** — At least 2 copies must be safely written before Kafka says "got it." This balances safety and speed.
- **`deleteClaim: false`** — If a node gets removed, **keep its disk**. This protects you from accidentally deleting all your data.

### Step 2 — Apply the wish-list

```bash
kubectl apply -f my-kafka-cluster.yaml -n kafka
```

**What this does:** Hands your wish-list to Strimzi. The operator reads it and starts building all the pods, storage, and network doors automatically.

### Step 3 — Watch it come to life

```bash
kubectl get pods -n kafka -w
```

The `-w` means "**watch**" — the screen keeps updating live. You'll see controllers and brokers appear one by one. Press `Ctrl + C` to stop watching once everything shows `Running`:

```
NAME                          READY   STATUS    RESTARTS   AGE
my-cluster-broker-3           1/1     Running   0          2m
my-cluster-broker-4           1/1     Running   0          2m
my-cluster-broker-5           1/1     Running   0          2m
my-cluster-controller-0       1/1     Running   0          2m
my-cluster-controller-1       1/1     Running   0          2m
my-cluster-controller-2       1/1     Running   0          2m
my-cluster-entity-operator    2/2     Running   0          1m
```

### Step 4 — Ask Strimzi if the cluster is truly ready

```bash
kubectl get kafka my-cluster -n kafka
```

Look for **READY = True**:

```
NAME         DESIRED KAFKA REPLICAS   READY   METADATA STATE   WARNINGS
my-cluster                            True     KRaft
```

`METADATA STATE = KRaft` confirms you're running the modern, ZooKeeper-free way. 🎉

> **Handy tip:** Kafka has a short name `k`. So `kubectl get k -n kafka` does the same thing and saves typing.

📚 *Reference: [Deploying a Kafka cluster](https://strimzi.io/docs/operators/latest/deploying#kafka-cluster-str) · [Node Pools explained](https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/)*

---

## 5. Scenario C: Creating Topics

**The story:** Your post office is open, but it has no mailboxes yet. Let's add a mailbox (topic) called `orders`.

### Step 1 — Write the topic YAML

Save as `orders-topic.yaml`.

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders
  labels:
    strimzi.io/cluster: my-cluster   # Which cluster gets this topic
spec:
  partitions: 3                      # Split the mailbox into 3 lanes for speed
  replicas: 3                        # Keep 3 copies for safety
  config:
    retention.ms: 604800000          # Keep messages for 7 days (in milliseconds)
    segment.bytes: 1073741824        # 1 GB file chunks on disk
```

**Plain-language explanation:**

- **`partitions: 3`** — Think of a highway with 3 lanes instead of 1. More lanes = more messages flowing at once = faster. But you can't easily *reduce* partitions later, so don't go crazy high.
- **`replicas: 3`** — Same safety idea: 3 copies of every message.
- **`retention.ms: 604800000`** — Messages auto-delete after 7 days. (7 days × 24 h × 60 m × 60 s × 1000 ms = 604,800,000.) This stops your disks from filling up forever.

### Step 2 — Create the topic

```bash
kubectl apply -f orders-topic.yaml -n kafka
```

### Step 3 — See all your topics

```bash
kubectl get kafkatopics -n kafka
```

```
NAME     CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
orders   my-cluster   3            3                    True
```

The short name for topics is `kt`, so `kubectl get kt -n kafka` works too.

> **Best practice:** Always create topics as YAML files (this is called "declarative" management). That way your topic setup is saved, version-controlled in Git, and repeatable — instead of typing one-off commands you'll forget.

📚 *Reference: [Managing Topics with KafkaTopic resources](https://strimzi.io/docs/operators/latest/deploying#config-topics-str)*

---

## 6. Scenario D: Security Setup (Encryption + Authentication)

**The story:** Right now, anyone inside the cluster can connect and read your mail. That's fine for a test, but scary for real data. Let's add **two locks**:

1. **Encryption (TLS):** Scramble data so eavesdroppers see gibberish.
2. **Authentication:** Require an ID card to connect at all.

### The 3 layers of Kafka security (simple version)

| Layer | Question it answers | Example |
|-------|--------------------|---------|
| **Encryption (TLS)** | "Can spies read my data as it travels?" | No — it's scrambled. |
| **Authentication** | "Who are you?" | Prove it with a certificate or password. |
| **Authorization (ACLs)** | "What are you allowed to do?" | You may read `orders` but not write to it. |

### Step 1 — Turn on authentication at the "door" (listener)

Update your `Kafka` resource so the TLS listener **requires** an ID. Here we use **mTLS** (mutual TLS — both sides show certificates), which is the most secure common option.

```yaml
spec:
  kafka:
    listeners:
      - name: tls
        port: 9093
        type: internal
        tls: true                    # Encryption ON
        authentication:
          type: tls                  # Require a certificate to connect (mTLS)
    authorization:
      type: simple                   # Turn on the "rules" system (ACLs)
```

**What changed:**

- `authentication.type: tls` → Clients must present a valid certificate. No cert, no entry.
- `authorization.type: simple` → Switches on Kafka's built-in permission rules. Now, by default, users can do **nothing** until you grant them permission (this is good — "deny by default").

Apply the change:

```bash
kubectl apply -f my-kafka-cluster.yaml -n kafka
```

Strimzi will do a careful **rolling update** — restarting brokers one at a time so your cluster never fully goes down.

### The other authentication choices (so you know your options)

| Type | What it is | When to use it |
|------|-----------|----------------|
| **`tls`** (mTLS) | Both sides show certificates. Strimzi makes the certs for you. | Programs talking to Kafka inside your systems. Most secure default. |
| **`scram-sha-512`** | A username + password method (password never sent in the clear). | When certificates are hard to distribute; human-friendly logins. |
| **`oauth`** | Log in using a central identity system (like Keycloak, Okta, Azure AD). | Big companies with single-sign-on. |

### A note on certificates (Strimzi does the hard part)

Kafka security relies on certificates (digital ID cards). The scary part is normally *creating and rotating* them. **Strimzi generates and auto-renews all these certificates for you.** You mostly don't touch them. If you ever need to force a renewal, you annotate the cluster — but for most people, it just works quietly in the background.

📚 *Reference: [Securing Kafka](https://strimzi.io/docs/operators/latest/deploying#assembly-securing-access-str) · [Listener authentication](https://strimzi.io/docs/operators/latest/configuring#assembly-securing-kafka-str)*

---

## 7. Scenario E: User Management (Creating Users & Permissions)

**The story:** Security is on, so nobody can get in yet. Let's create a user named `app-orders` and give it *only* the permissions it needs — the right way.

> **The Golden Rule of Security — "Least Privilege":** Give every user the *smallest* set of permissions they need to do their job. Never give "admin everything" to an app that only reads one topic.

### Step 1 — Create a KafkaUser with specific permissions

Save as `app-orders-user.yaml`.

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
      # PERMISSION 1: Allow READING messages from the "orders" topic
      - resource:
          type: topic
          name: orders
          patternType: literal       # Exact name match
        operations:
          - Read
          - Describe
        host: "*"                    # Allowed to connect from any address

      # PERMISSION 2: Allow this user's consumer group to track its progress
      - resource:
          type: group
          name: orders-app-group
          patternType: literal
        operations:
          - Read
```

**Reading this like a sentence:** "The user `app-orders` logs in with a certificate. It is allowed to **Read** and **Describe** the topic named `orders`, and to use the consumer group `orders-app-group`. It cannot do anything else."

**What the operations mean:**

- **`Read`** — Consume (pick up) messages.
- **`Write`** — Produce (drop off) messages.
- **`Describe`** — Look up basic info about a topic (needed alongside Read/Write).
- **`Create`** — Make new topics.
- **`Delete`** — Remove topics.

If you wanted a *producer* that writes orders, you'd give it `Write` and `Describe` instead of `Read`.

### Step 2 — Create the user

```bash
kubectl apply -f app-orders-user.yaml -n kafka
```

When you do this, Strimzi automatically creates a **Kubernetes Secret** (a safe locker) holding this user's certificate and keys. The locker has the same name as the user: `app-orders`.

### Step 3 — See your users

```bash
kubectl get kafkausers -n kafka
```

```
NAME         CLUSTER      AUTHENTICATION   AUTHORIZATION   READY
app-orders   my-cluster   tls              simple          True
```

Short name is `ku`, so `kubectl get ku -n kafka` also works.

### Step 4 — Get the user's login credentials

The app that connects *as* this user needs the certificate from the secret. Here's how to peek at what's inside:

```bash
kubectl get secret app-orders -n kafka -o jsonpath='{.data}' | jq
```

**Command breakdown:**

- `kubectl get secret app-orders` → Open the locker named `app-orders`.
- `-o jsonpath='{.data}'` → Show only the `data` section (the actual credentials).
- `| jq` → Pipe it into `jq`, a tool that makes the output pretty and readable.

Inside you'll find files like `user.crt` (the certificate), `user.key` (the private key), and `ca.crt` (the cluster's authority certificate). Your application uses these three to prove its identity and connect securely.

### Bonus: Setting usage limits (quotas) so one app can't hog everything

You can stop a greedy app from overwhelming the cluster by adding quotas to the user:

```yaml
spec:
  quotas:
    producerByteRate: 1048576        # Max 1 MB/second of writing
    consumerByteRate: 2097152        # Max 2 MB/second of reading
    requestPercentage: 50            # Max 50% of a broker's request time
```

This is great for **fairness** when many teams share one Kafka cluster.

📚 *Reference: [Managing users with KafkaUser](https://strimzi.io/docs/operators/latest/deploying#assembly-securing-kafka-authorization-str) · [User quotas](https://strimzi.io/docs/operators/latest/configuring#con-configuring-client-quotas-str)*

---

## 8. Scenario F: Upgrading Strimzi and Kafka

**The story:** New versions bring security fixes and features. Upgrading has **two separate parts**, and the order matters:

1. **First**, upgrade the **Strimzi operator** (the manager).
2. **Then**, upgrade **Kafka itself** (the workers).

> ⚠️ **Big warning for modern versions:** Starting with **Strimzi 1.0.0**, only the new `v1` API version of your YAML files is supported. Older `v1beta2` / `v1beta1` files must be converted **before** upgrading to 1.0.0. Always read the release notes for your target version. Also, always **back up your YAML files and data** before upgrading.

### Part 1 — Upgrade the Strimzi Operator

**If you installed with Helm (the clean way):**

```bash
# Refresh the list of available versions
helm repo update

# Upgrade the operator to the newest chart
helm upgrade strimzi-operator strimzi/strimzi-kafka-operator \
  --namespace kafka
```

**If you installed with plain YAML files:**

```bash
# Re-apply the newest install files (this updates the operator + CRDs)
kubectl replace -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
```

**Confirm the operator restarted with the new version:**

```bash
kubectl get pods -n kafka -l name=strimzi-cluster-operator
```

Wait until the operator pod is `Running` and `READY 1/1` again.

### Part 2 — Upgrade Kafka Itself

Here's the beautiful part: with modern Strimzi, you usually just **change two numbers** in your `Kafka` YAML and Strimzi handles the entire careful upgrade.

Edit your `Kafka` resource:

```yaml
spec:
  kafka:
    version: 4.0.0             # ⬅️ Change this to the new Kafka version
    metadataVersion: 4.0-IV3   # ⬅️ Update this AFTER the version upgrade finishes
```

**The safe, recommended order:**

1. **First**, bump only `version` (e.g., from `3.9.0` to `4.0.0`). Apply it.

   ```bash
   kubectl apply -f my-kafka-cluster.yaml -n kafka
   ```

2. **Watch** Strimzi do a rolling upgrade — it restarts brokers one at a time so the post office never closes:

   ```bash
   kubectl get pods -n kafka -w
   ```

3. **Wait** until every pod is `Running` and the cluster is ready:

   ```bash
   kubectl get kafka my-cluster -n kafka
   ```

4. **Then**, and only then, bump `metadataVersion` to match, and apply again. This "locks in" the new version's data format.

**Why two steps?** The `metadataVersion` is like upgrading the building's foundation. You only do it *after* confirming all the workers moved into the new building successfully. If you upgraded the foundation too early and something went wrong, rolling back would be much harder. Doing `version` first keeps an easy escape route.

### How to check what version you're actually running

```bash
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.kafkaVersion}'
```

You can also check which operator version last succeeded:

```bash
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.operatorLastSuccessfulVersion}'
```

📚 *Reference: [Upgrading Strimzi](https://strimzi.io/docs/operators/latest/deploying#assembly-upgrade-str) · [Kafka version upgrades](https://strimzi.io/docs/operators/latest/deploying#proc-upgrade-kafka-kraft-str)*

---

## 9. Scenario G: Scaling Your Cluster Bigger

**The story:** Your app got popular! You need more brokers to handle the traffic. With node pools, this is delightfully easy.

### Step 1 — Change the number of brokers

Edit the **broker** KafkaNodePool and increase `replicas` from 3 to 5:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 5    # ⬅️ Was 3, now 5
  roles:
    - broker
  # ... storage stays the same ...
```

### Step 2 — Apply it

```bash
kubectl apply -f my-kafka-cluster.yaml -n kafka
```

Strimzi adds two new broker pods automatically. You'll see `my-cluster-broker-6` and `my-cluster-broker-7` appear.

### Step 3 — Rebalance the data (very important!)

Adding brokers is only half the job. The new brokers start **empty** — old data doesn't automatically spread onto them. To fix that, Strimzi includes a smart tool called **Cruise Control** that moves partitions around to balance the load evenly.

First, enable Cruise Control in your `Kafka` resource:

```yaml
spec:
  cruiseControl: {}    # Turn on the auto-balancing brain
```

Then create a rebalance request. Save as `rebalance.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: my-rebalance
  labels:
    strimzi.io/cluster: my-cluster
spec:
  mode: add-brokers      # Tell it we just added brokers
  brokers: [6, 7]        # The IDs of the new brokers
```

Apply it, then approve it once Strimzi calculates a plan:

```bash
kubectl apply -f rebalance.yaml -n kafka

# Strimzi comes up with a "proposal." Approve it to start moving data:
kubectl annotate kafkarebalance my-rebalance strimzi.io/rebalance=approve -n kafka
```

Watch its progress:

```bash
kubectl get kafkarebalance my-rebalance -n kafka
```

When the status reaches `Ready`, your data is nicely balanced across all 5 brokers. 🎉

> **Why rebalancing matters:** Without it, your new brokers sit around doing nothing while the old ones stay overworked. Rebalancing shares the load so you actually *get* the extra performance you paid for.

📚 *Reference: [Scaling clusters](https://strimzi.io/docs/operators/latest/deploying#scaling-clusters-str) · [Cruise Control & rebalancing](https://strimzi.io/docs/operators/latest/deploying#cruise-control-concept-str)*

---

## 10. Scenario H: Everyday Operations (Cheat Sheet)

Quick commands you'll use all the time. Assume everything is in the `kafka` namespace.

### Looking at things

```bash
# See EVERYTHING Strimzi manages at once
kubectl get strimzi -n kafka

# List clusters / topics / users (using short names)
kubectl get k  -n kafka     # Kafka clusters
kubectl get kt -n kafka     # Topics
kubectl get ku -n kafka     # Users
kubectl get knp -n kafka    # Node pools

# Get deep details about one thing (great for troubleshooting)
kubectl describe kafka my-cluster -n kafka
```

### Reading logs (when something seems broken)

```bash
# Read the operator's diary — the #1 place to find out what went wrong
kubectl logs -n kafka -l name=strimzi-cluster-operator -f

# Read a specific broker's logs
kubectl logs my-cluster-broker-3 -n kafka
```

The `-f` again means "follow" — keep streaming new lines live.

### Testing by sending and receiving a message

You can jump inside a temporary Kafka pod to try producing and consuming messages by hand.

```bash
# Open a producer (type messages, press Enter to send each one)
kubectl -n kafka run kafka-producer -ti \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic orders
```

Then, in a **second terminal**, open a consumer to watch messages arrive:

```bash
kubectl -n kafka run kafka-consumer -ti \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm=true --restart=Never -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic orders \
  --from-beginning
```

**What's happening:** `--bootstrap-server` is the "front door address" of your Kafka cluster. `my-cluster-kafka-bootstrap` is the automatic service name Strimzi creates. `--from-beginning` tells the consumer to read all messages from the very start. `--rm=true` cleans up the temporary test pod when you're done.

### Deleting things (be careful!)

```bash
# Delete one topic
kubectl delete kafkatopic orders -n kafka

# Delete one user
kubectl delete kafkauser app-orders -n kafka

# Delete the ENTIRE Kafka cluster (⚠️ this removes your Kafka!)
kubectl delete kafka my-cluster -n kafka
```

> **Safety note:** Because you set `deleteClaim: false` earlier, deleting the cluster does **not** automatically wipe the data disks. That's a safety net. To reclaim storage you'd delete the PersistentVolumeClaims separately.

---

## 11. Best Practices Checklist

Print this out and stick it on your wall. ✅

**Architecture**
- ✅ Use **KRaft mode** for everything new. Never start a new project with ZooKeeper.
- ✅ In production, use **separate node pools** for controllers and brokers.
- ✅ Use an **odd number of controllers** (3 or 5) so voting never ties.
- ✅ Run at least **3 brokers** in production for fault tolerance.

**Data Safety**
- ✅ Set **replication factor to 3** so losing one disk never loses data.
- ✅ Set **`min.insync.replicas: 2`** for a good safety/speed balance.
- ✅ Use **`persistent-claim`** storage, never ephemeral, for real data.
- ✅ Keep **`deleteClaim: false`** so disks survive accidental deletions.

**Security**
- ✅ Turn on **TLS encryption** on client-facing listeners.
- ✅ Require **authentication** (mTLS or SCRAM or OAuth) — never leave the door open.
- ✅ Turn on **authorization** (`type: simple`) so it's "deny by default."
- ✅ Follow **least privilege** — give each user only the ACLs it truly needs.
- ✅ Use **quotas** so one noisy app can't starve the others.

**Operations**
- ✅ Keep all YAML in **Git** (Infrastructure as Code) — declarative, repeatable, auditable.
- ✅ Upgrade the **operator first**, then Kafka's `version`, then `metadataVersion`.
- ✅ **Read release notes** before every upgrade, especially for major versions like 1.0.0.
- ✅ Use **Cruise Control** to rebalance after scaling.
- ✅ Watch the **operator logs** first whenever something looks wrong.
- ✅ Keep Strimzi reasonably up to date to get **security (CVE) fixes**.

---

## 12. Reference Links

**Official Strimzi Documentation**
- Strimzi Homepage — https://strimzi.io/
- Deploying and Managing Strimzi (main guide) — https://strimzi.io/docs/operators/latest/deploying
- Configuring Strimzi (all the settings) — https://strimzi.io/docs/operators/latest/configuring.html
- Strimzi Overview (concepts) — https://strimzi.io/docs/operators/latest/overview
- Quick Start guides — https://strimzi.io/quickstarts/
- Downloads & example files — https://strimzi.io/downloads/

**GitHub & Releases**
- Strimzi GitHub repository — https://github.com/strimzi/strimzi-kafka-operator
- Release notes & versions — https://github.com/strimzi/strimzi-kafka-operator/releases
- Design proposals (deep dives) — https://github.com/strimzi/proposals

**Helpful Blog Posts**
- Node Pools & KRaft explained — https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/
- All Strimzi blog posts — https://strimzi.io/blog/

**Apache Kafka**
- Apache Kafka official docs — https://kafka.apache.org/documentation/

---

*You now have the full picture: install the operator, deploy a cluster, make topics, lock it down with security, manage users, upgrade safely, and scale up. Start with a small test cluster, get comfortable, then apply the production best practices. Happy streaming! 🚀*
