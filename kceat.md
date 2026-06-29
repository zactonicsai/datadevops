# Kubernetes + Strimzi Kafka Cheat Sheet

*A beginner-friendly guide to running Kafka on Kubernetes (AWS EKS), with operations, maintenance, and patching.*

---

## Table of Contents

1. [What Kubernetes Is](#1-what-kubernetes-is)
2. [Core Resource Types](#2-core-resource-types)
3. [Essential kubectl Commands](#3-essential-kubectl-commands)
4. [What Strimzi Is](#4-what-strimzi-is)
5. [Strimzi Custom Resource Types](#5-strimzi-custom-resource-types)
6. [Tutorial: Set Up Kafka with Strimzi](#6-tutorial-set-up-kafka-with-strimzi)
7. [Strimzi-Specific Commands](#7-strimzi-specific-commands)
8. [Best Practices](#8-best-practices)
9. [Routine Health Checks](#9-routine-health-checks)
10. [Maintenance Activities](#10-maintenance-activities)
11. [AMI Updates & Node Patching (AWS)](#11-ami-updates--node-patching-aws)
12. [Patching the EKS Control Plane](#12-patching-the-eks-control-plane)
13. [Maintenance Cadence](#13-maintenance-cadence)
14. [Quick Mental Model](#14-quick-mental-model)

---

## 1. What Kubernetes Is

Think of Kubernetes (written "k8s") as a **manager for a team of computers**. You tell it what you want running, and it figures out where to put things, restarts anything that breaks, and keeps everything healthy. You don't manage individual computers — you tell the manager your goal.

`kubectl` is how you talk to that manager. It's a command you type into your terminal.

---

## 2. Core Resource Types

These are the "things" Kubernetes manages. The ones that matter most:

- **Pod** — The smallest unit. One or more containers running together. Think of it as a single running program.
- **Deployment** — Manages a set of identical Pods. If one dies, it makes a new one. Good for *stateless* apps (apps that don't need to remember anything).
- **StatefulSet** — Like a Deployment, but for apps that need a stable identity and storage that sticks around. **Kafka uses this**, because each Kafka server needs to remember its data.
- **Service** — A stable address for reaching Pods. Pods come and go and change IPs, so a Service gives you one reliable "phone number."
- **ConfigMap** — Stores settings/config as plain text.
- **Secret** — Like a ConfigMap, but for passwords and sensitive data.
- **Namespace** — A folder to keep your stuff organized and separate from other people's stuff.
- **PersistentVolumeClaim (PVC)** — A request for disk space that survives Pod restarts. Kafka needs this so messages aren't lost.
- **Node** — An actual machine in the cluster (one of the "team of computers").

---

## 3. Essential kubectl Commands

### Looking at things

- `kubectl get pods`
  Lists all pods in your current namespace. Your first check to see what's running.
- `kubectl get pods -n my-namespace`
  Same, but for a specific namespace. `-n` means "in this namespace."
- `kubectl get all`
  Lists everything — pods, services, deployments, and more — in one shot.
- `kubectl describe pod my-pod`
  Shows detailed info about one pod: its events, why it might be failing, what node it's on.
- `kubectl logs my-pod`
  Shows a pod's logs (the text output the program printed). Your main debugging tool.
- `kubectl logs -f my-pod`
  Follows the logs live, like a streaming feed. `-f` means "follow." Press Ctrl+C to stop.

### Creating and changing things

- `kubectl apply -f file.yaml`
  Creates or updates resources from a YAML file. **This is the main way you do things.** It's safe to run repeatedly — it only changes what's different.
- `kubectl delete -f file.yaml`
  Deletes whatever that YAML file describes.
- `kubectl delete pod my-pod`
  Deletes one pod by name. (If a Deployment manages it, a new one is created automatically.)
- `kubectl edit deployment my-app`
  Opens a resource in your text editor so you can change it live.

### Getting inside / debugging

- `kubectl exec -it my-pod -- bash`
  Opens a shell *inside* a running pod so you can poke around. `-it` means "interactive terminal" (so you can type). Everything after `--` is the command to run inside.
- `kubectl get events`
  Shows recent cluster events. Excellent for spotting errors like "out of memory" or "image not found."
- `kubectl get pods -o wide`
  Lists pods with extra columns, including which node each pod is running on. `-o wide` means "wider output."

### Scaling

- `kubectl scale deployment my-app --replicas=3`
  Changes how many copies of an app run. `--replicas=3` means "run 3 copies."

> **Quick key:** `-f` = "from this file" · `-n` = "in this namespace" · `-it` = "interactive terminal" · `-o` = "output format"

---

## 4. What Strimzi Is

Kafka is software for sending streams of messages between programs — like a **post office that handles huge amounts of mail reliably**. But running Kafka on Kubernetes by hand is complicated.

**Strimzi** makes Kafka easy on Kubernetes. It's an **operator** — a robot assistant that already knows how Kafka should work. You just describe the Kafka cluster you want, and Strimzi builds and maintains it for you.

---

## 5. Strimzi Custom Resource Types

Once Strimzi is installed, Kubernetes understands these extra "things":

- **Kafka** — Describes your whole Kafka cluster (how many servers, how much storage, etc.).
- **KafkaTopic** — A "channel" or category that messages go into.
- **KafkaUser** — A user account with permissions for Kafka.
- **KafkaConnect** — Connects Kafka to outside systems like databases.
- **KafkaBridge** — Lets apps talk to Kafka over HTTP instead of Kafka's native protocol.
- **KafkaRebalance** — Asks Strimzi (via Cruise Control) to spread data evenly across servers.

---

## 6. Tutorial: Set Up Kafka with Strimzi

### Step 1 — Make a namespace to keep things tidy

- `kubectl create namespace kafka`
  Creates a folder called `kafka` to hold all your Kafka resources.

### Step 2 — Install the Strimzi operator (the robot assistant)

- `kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka`
  Downloads and installs Strimzi into the `kafka` namespace.
- `kubectl get pods -n kafka`
  Checks the operator is running. You should see a pod named like `strimzi-cluster-operator-...`.

### Step 3 — Describe the Kafka cluster you want

Save this as `kafka-cluster.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
spec:
  kafka:
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    storage:
      type: persistent-claim
      size: 10Gi
    config:
      offsets.topic.replication.factor: 3
      default.replication.factor: 3
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

This says: run **3 Kafka servers**, each with 10Gi of disk that survives restarts. `replicas: 3` means three copies, so if one dies your data is safe.

### Step 4 — Hand it to Kubernetes

- `kubectl apply -f kafka-cluster.yaml -n kafka`
  Sends your description to Kubernetes. Strimzi now starts building everything.

### Step 5 — Wait until it's ready

- `kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka`
  Pauses until the cluster reports "Ready," or gives up after 300 seconds. Strimzi is doing the heavy lifting in the background.

### Step 6 — Make a topic (a channel for messages)

Save this as `topic.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 3
```

- `kubectl apply -f topic.yaml -n kafka`
  Creates the topic `my-topic` with 3 partitions and 3 copies of the data.

### Step 7 — Test it

- Send messages (a "producer"):

  ```bash
  kubectl -n kafka run kafka-producer -ti \
    --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 \
    --rm=true --restart=Never -- \
    bin/kafka-console-producer.sh \
    --bootstrap-server my-cluster-kafka-bootstrap:9092 \
    --topic my-topic
  ```

  This starts a temporary pod that lets you type messages. Each line you type and Enter becomes a message. `--rm=true` deletes the pod when you exit.

- Read messages back (a "consumer"), in another terminal:

  ```bash
  kubectl -n kafka run kafka-consumer -ti \
    --image=quay.io/strimzi/kafka:latest-kafka-3.7.0 \
    --rm=true --restart=Never -- \
    bin/kafka-console-consumer.sh \
    --bootstrap-server my-cluster-kafka-bootstrap:9092 \
    --topic my-topic --from-beginning
  ```

  The messages you typed appear here. `--from-beginning` means "show me all messages from the start." **That's Kafka working.**

> **Note:** `my-cluster-kafka-bootstrap:9092` is the **Service** — the stable "phone number" your apps use to reach Kafka, no matter which pods are alive.

---

## 7. Strimzi-Specific Commands

- `kubectl get kafka -n kafka`
  Lists your Kafka clusters and whether they're ready.
- `kubectl get kafkatopic -n kafka`
  Lists all topics (message channels).
- `kubectl get kafkauser -n kafka`
  Lists all Kafka user accounts.
- `kubectl describe kafka my-cluster -n kafka`
  Shows detailed status of your cluster, including warnings and conditions.
- `kubectl get pods -n kafka`
  Shows all Kafka and Zookeeper pods.
- `kubectl logs my-cluster-kafka-0 -n kafka`
  Shows logs from the first Kafka server (broker number 0).

---

## 8. Best Practices

*Set these up once, early — they prevent the most common outages.*

### Spread brokers across machines and zones

If all 3 brokers land on one node and that node dies, you lose everything. Use **anti-affinity** so each broker sits on a different node, ideally a different AWS Availability Zone. Add under `spec.kafka`:

```yaml
    template:
      pod:
        affinity:
          podAntiAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              - labelSelector:
                  matchExpressions:
                    - key: strimzi.io/name
                      operator: In
                      values: [my-cluster-kafka]
                topologyKey: topology.kubernetes.io/zone
```

### Always set CPU/memory requests and limits

Without them, one greedy pod can starve the others. Add under `spec.kafka`:

```yaml
    resources:
      requests:
        memory: 4Gi
        cpu: "1"
      limits:
        memory: 4Gi
        cpu: "2"
```

- **requests** = the minimum the pod is guaranteed.
- **limits** = the maximum it's allowed to use.

### Use replication ≥ 3 and require 2 in-sync copies

A message isn't considered "saved" until at least 2 brokers have it — so you can lose a broker without losing data. Add under `spec.kafka.config`:

```yaml
      min.insync.replicas: 2
      default.replication.factor: 3
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
```

### Other key practices

- **Use fast, reliable storage.** On AWS, use `gp3` EBS volumes (good speed, cheaper than gp2). **Never** use `emptyDir` storage for real Kafka — it vanishes when the pod restarts.
- **Turn on TLS and authentication** for any cluster beyond a test toy. Strimzi can do this with a few lines in the listener config.
- **Enable monitoring.** Strimzi can expose metrics to Prometheus, viewed in Grafana. This is how you catch problems *before* they become outages.

---

## 9. Routine Health Checks

*Run these regularly to catch trouble early.*

- `kubectl get kafka my-cluster -n kafka`
  Is the whole cluster healthy? Look for **Ready: True** in the output.
- `kubectl get pods -n kafka -o wide`
  Are all pods running and not crashing? Watch the **RESTARTS** column — climbing numbers mean trouble.
- `kubectl get events -n kafka --sort-by=.lastTimestamp`
  Shows recent errors or warnings, newest last.
- `kubectl exec my-cluster-kafka-0 -n kafka -- df -h /var/lib/kafka`
  How full are the disks? A Kafka broker filling its disk is a common cause of outages.
- `kubectl exec my-cluster-kafka-0 -n kafka -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions`
  Are any partitions missing copies? **If this returns nothing, that's good** — every partition has all its replicas.
- `kubectl get pods -n kafka -l name=strimzi-cluster-operator`
  Is the operator (robot assistant) itself alive? `-l` filters by label.
- `kubectl logs deploy/strimzi-cluster-operator -n kafka --tail=50`
  Shows the operator's last 50 log lines. `--tail=50` limits how much you see.

---

## 10. Maintenance Activities

*Scheduled tasks to keep the cluster healthy over time.*

### Watch certificate expiry

Strimzi auto-renews its security certificates, but check when they expire:

- `kubectl get secret my-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -enddate`
  Pulls the certificate out of the Secret, decodes it, and prints its expiry date.

### Set a maintenance time window

So Strimzi only does disruptive work (cert renewal, rolling restarts) during off-hours. Add to `spec` of the Kafka resource:

```yaml
  maintenanceTimeWindows:
    - "* * 2-4 * * ?"   # only between 2am and 4am
```

### Rebalance data across brokers

Use Cruise Control after adding brokers or when load is lopsided. First enable it under `spec.cruiseControl: {}`. Then save this as `rebalance.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: rebalance
  labels:
    strimzi.io/cluster: my-cluster
spec: {}
```

- `kubectl apply -f rebalance.yaml -n kafka`
  Asks Strimzi to calculate a plan for spreading data evenly.
- `kubectl describe kafkarebalance rebalance -n kafka`
  Shows the proposed plan so you can review it before approving.
- `kubectl annotate kafkarebalance rebalance strimzi.io/rebalance=approve -n kafka`
  Approves the plan and starts the rebalance. An *annotation* is a note you attach to a resource to tell Strimzi to act.

### Manually trigger a rolling restart

For example, after a config change that needs it:

- `kubectl annotate statefulset my-cluster-kafka strimzi.io/manual-rolling-update=true -n kafka`
  Tells Strimzi to restart brokers **one at a time**, waiting for each to be healthy — so the cluster stays up the whole time.

---

## 11. AMI Updates & Node Patching (AWS)

Your Kafka pods run on EC2 machines (**nodes**). Each machine runs an operating-system image called an **AMI**. AWS regularly publishes new AMIs with security patches, so you periodically replace your nodes with fresh ones. The trick is doing it **without taking Kafka down**.

> This section assumes **EKS** (Kubernetes on AWS), since AMIs are an AWS concept.

### Step 1 — See what AMI version your nodes are on

- `aws eks describe-nodegroup --cluster-name my-cluster --nodegroup-name my-nodegroup --query 'nodegroup.releaseVersion'`
  Reports the current AMI release version of your node group. `--query` filters the output to just the part you want.

### Step 2 — Find the latest available EKS AMI

- For Amazon Linux 2 nodes (swap `1.30` for your Kubernetes version):

  ```bash
  aws ssm get-parameters \
    --names /aws/service/eks/optimized-ami/1.30/amazon-linux-2/recommended/image_id \
    --query 'Parameters[0].Value' --output text
  ```

  Asks AWS for the newest patched image ID. AWS publishes these in a public parameter store.

- For Amazon Linux 2023, the path is instead:

  ```
  /aws/service/eks/optimized-ami/1.30/amazon-linux-2023/x86_64/standard/recommended/image_id
  ```

### Step 3 — Make sure Kafka can survive losing a broker

- `kubectl get pdb -n kafka`
  Shows the **PodDisruptionBudget** — Strimzi creates one that allows only **1** Kafka pod down at a time. This is what stops AWS from taking down too many brokers at once.

Also re-confirm no under-replicated partitions (see [Health Checks](#9-routine-health-checks)) **before** you start.

### Step 4 — Update the node group's AMI

- `aws eks update-nodegroup-version --cluster-name my-cluster --nodegroup-name my-nodegroup`
  For **managed** node groups, this one command does a safe rolling replacement: it spins up new patched nodes, drains the old ones while respecting your PodDisruptionBudget, and removes them. Updates to the latest AMI for the node group's current Kubernetes version.

### Step 5 — Watch the rollout

- `aws eks list-updates --name my-cluster --nodegroup-name my-nodegroup`
  Lists update operations and gives you the update ID.
- `aws eks describe-update --name my-cluster --nodegroup-name my-nodegroup --update-id <id-from-above>`
  Shows the status of a specific update (in progress, successful, or failed).
- `kubectl get pods -n kafka -o wide -w`
  Watches pods migrate to the new nodes in real time. `-w` means "watch" — it keeps updating until you press Ctrl+C.

> ⚠️ **Do not use `--force`** on `update-nodegroup-version` with Kafka. Force ignores the PodDisruptionBudget and can knock out multiple brokers at once, causing data loss or downtime. Let it respect the PDB even if it's slower.

### Manual node patching (self-managed nodes)

For self-managed nodes, where the command above doesn't apply — do this **one node at a time**:

- `kubectl cordon ip-10-0-1-23.ec2.internal`
  Marks the node "unschedulable" so no *new* pods land on it. Existing pods keep running for now.
- `kubectl drain ip-10-0-1-23.ec2.internal --ignore-daemonsets --delete-emptydir-data`
  Safely moves pods off the node. The PodDisruptionBudget protects Kafka. `--ignore-daemonsets` skips system pods that run on every node; `--delete-emptydir-data` allows evicting pods with temporary local data.
- `kubectl get kafka my-cluster -n kafka`
  Wait for Kafka to report **Ready** again before touching the next node.
- `kubectl uncordon ip-10-0-1-23.ec2.internal`
  After the node is patched/replaced, allows scheduling on it again.

> **Golden rule for Kafka:** one node at a time, wait for green between each. Replication keeps your data safe **only if** you don't take down multiple brokers simultaneously.

---

## 12. Patching the EKS Control Plane

Separate from node AMIs, the **Kubernetes version** itself gets upgraded. Always upgrade the control plane **first**, then the nodes.

- `aws eks describe-cluster --name my-cluster --query 'cluster.version'`
  Shows the current Kubernetes version of your cluster.
- `aws eks update-cluster-version --name my-cluster --kubernetes-version 1.30`
  Upgrades the control plane. Go **one minor version at a time** (e.g. 1.29 → 1.30, never skip to 1.31).
- `aws eks update-nodegroup-version --cluster-name my-cluster --nodegroup-name my-nodegroup --kubernetes-version 1.30`
  Brings the node group up to match the new control-plane version.

> Before any version upgrade, **check the Strimzi compatibility docs** — each Strimzi release supports specific Kubernetes and Kafka versions. Upgrade the Strimzi operator *before* jumping Kafka versions, and always test in staging first.

---

## 13. Maintenance Cadence

A simple rhythm to keep things healthy:

- **Daily** — Glance at pod restarts, under-replicated partitions, and disk usage.
- **Weekly** — Review events and operator logs; check certificate expiry dates.
- **Monthly** — Apply node AMI patches; review resource usage and rebalance if lopsided.
- **Quarterly** — Plan Kubernetes / Strimzi / Kafka version upgrades (test in staging first).

---

## 14. Quick Mental Model

You write YAML describing what you want → `kubectl apply` sends it to the manager → Kubernetes (with Strimzi's help for Kafka) makes it real and keeps it healthy.

**You describe the goal; it handles the work.**

---

*End of cheat sheet.*
