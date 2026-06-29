# Kubernetes + Strimzi Kafka Cheat Sheet

*A beginner-friendly guide to running Kafka on Kubernetes (AWS EKS), with operations, maintenance, and patching.*

---

## Table of Contents

1. [What Kubernetes Is](#1-what-kubernetes-is)
2. [Core Resource Types](#2-core-resource-types)
3. [Essential kubectl Commands](#3-essential-kubectl-commands)
4. [What a CRD Is (and Why)](#4-what-a-crd-is-and-why)
5. [What Strimzi Is](#5-what-strimzi-is)
6. [Strimzi Custom Resource Types](#6-strimzi-custom-resource-types)
7. [Tutorial: Set Up Kafka with Strimzi](#7-tutorial-set-up-kafka-with-strimzi)
8. [Strimzi-Specific Commands](#8-strimzi-specific-commands)
9. [Networking: Services, Ingress and Egress](#9-networking-services-ingress-and-egress)
10. [Kafka UI: Seeing Kafka Visually](#10-kafka-ui-seeing-kafka-visually)
11. [Taints and Tolerations](#11-taints-and-tolerations)
12. [Security and Network Policies](#12-security-and-network-policies)
13. [Best Practices](#13-best-practices)
14. [Routine Health Checks](#14-routine-health-checks)
15. [Maintenance Activities](#15-maintenance-activities)
16. [AMI Updates & Node Patching (AWS)](#16-ami-updates--node-patching-aws)
17. [Patching the EKS Control Plane](#17-patching-the-eks-control-plane)
18. [Maintenance Cadence](#18-maintenance-cadence)
19. [Quick Mental Model](#19-quick-mental-model)

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

## 4. What a CRD Is (and Why)

**CRD** stands for **Custom Resource Definition**. It's how you teach Kubernetes a brand-new kind of "thing" it didn't know about before.

### The idea

Out of the box, Kubernetes only understands its built-in resource types — Pod, Deployment, Service, and so on (the ones in [Section 2](#2-core-resource-types)). A **CRD adds a new word to Kubernetes' vocabulary.** Once you install a CRD called `Kafka`, you can suddenly write `kind: Kafka` in a YAML file and Kubernetes accepts it as a real, first-class resource — the same way it accepts `kind: Pod`.

- **Custom** = your own type, not one that ships with Kubernetes.
- **Resource** = a "thing" Kubernetes stores and manages.
- **Definition** = the rulebook describing what that thing looks like (its allowed fields, like `replicas` or `storage`).

### A simple analogy

Think of Kubernetes as a form-processing office that only accepts a fixed set of paper forms. A CRD is like **designing a brand-new form** and handing it to the office, saying "from now on, accept this form too, and here are the rules for filling it out." After that, anyone can submit the new form and the office knows what to do with it.

### Why CRDs exist (why they matter)

- **They let tools extend Kubernetes without changing Kubernetes itself.** You don't have to modify or rebuild Kubernetes to add Kafka support — you just install Strimzi's CRDs.
- **You describe complex software in plain YAML.** Instead of hand-assembling dozens of Pods, Services, and disks, you write one short `Kafka` resource and let the operator build the rest.
- **A CRD usually comes with an operator** (the "robot assistant" from later sections). The CRD defines *what* you can ask for; the operator contains the know-how to actually *make it happen* and keep it healthy.
- **Everything stays consistent.** Your custom resources live in the same place, use the same `kubectl` commands, and follow the same rules as built-in ones.

> **The key connection:** Strimzi works by installing CRDs. When you ran `kubectl create -f '.../install/latest...'` back in the tutorial, part of what got installed were the CRDs for `Kafka`, `KafkaTopic`, `KafkaUser`, and the rest. That's *why* Kubernetes understands those types in the next section — the CRDs taught it.

### CRD commands

- `kubectl get crds`
  Lists every CRD installed in your cluster (you'll see lots, including Strimzi's `kafkas.kafka.strimzi.io`).
- `kubectl get crds | grep strimzi`
  Filters that list to just the Strimzi ones. `grep` keeps only lines containing the word "strimzi."
- `kubectl describe crd kafkas.kafka.strimzi.io`
  Shows the full rulebook for the `Kafka` type — its fields, versions, and validation rules.
- `kubectl explain kafka.spec`
  Explains the available fields under a custom resource, right in your terminal. Great for discovering what you're allowed to configure.

> **Note:** A *CRD* is the definition (the new form's rulebook). A **custom resource (CR)** is an actual filled-in copy of it — for example, your `my-cluster` Kafka resource is a CR based on the `Kafka` CRD.

---

## 5. What Strimzi Is

Kafka is software for sending streams of messages between programs — like a **post office that handles huge amounts of mail reliably**. But running Kafka on Kubernetes by hand is complicated.

**Strimzi** makes Kafka easy on Kubernetes. It's an **operator** — a robot assistant that already knows how Kafka should work. You just describe the Kafka cluster you want, and Strimzi builds and maintains it for you.

---

## 6. Strimzi Custom Resource Types

Once Strimzi is installed, Kubernetes understands these extra "things":

- **Kafka** — Describes your whole Kafka cluster (how many servers, how much storage, etc.).
- **KafkaTopic** — A "channel" or category that messages go into.
- **KafkaUser** — A user account with permissions for Kafka.
- **KafkaConnect** — Connects Kafka to outside systems like databases.
- **KafkaBridge** — Lets apps talk to Kafka over HTTP instead of Kafka's native protocol.
- **KafkaRebalance** — Asks Strimzi (via Cruise Control) to spread data evenly across servers.

---

## 7. Tutorial: Set Up Kafka with Strimzi

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

## 8. Strimzi-Specific Commands

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

## 9. Networking: Services, Ingress and Egress

Once Kafka is running, the big question is: *how do programs actually reach it?* That's networking. Three ideas cover most of it — **Services** (talking inside the cluster), **Ingress** (traffic coming in from outside), and **Egress** (traffic going out).

### Services (svc) — the stable phone number

A Service gives one steady address to a group of pods that keep changing. Pods restart and get new IPs constantly; the Service stays put so nothing breaks. There are a few kinds:

- **ClusterIP** (the default) — reachable **only inside** the cluster. `my-cluster-kafka-bootstrap` is this type — which is why apps *inside* the cluster use that address.
- **NodePort** — opens the same port on every node, so outside traffic can come in through a node's IP and port.
- **LoadBalancer** — asks AWS to create a load balancer with a public address that forwards to your pods.
- **Headless** (`clusterIP: None`) — has no single shared address; instead **each pod gets its own DNS name**. Kafka relies on this so clients can reach a *specific* broker, not just "any" broker.

Commands:

- `kubectl get svc -n kafka`
  Lists all Services. For Kafka you'll see a bootstrap Service plus one per broker.
- `kubectl describe svc my-cluster-kafka-bootstrap -n kafka`
  Shows the Service's address, ports, and which pods it targets.
- `kubectl get endpoints -n kafka`
  Shows the actual pod IPs sitting behind each Service. If a Service "isn't working," empty endpoints here means it's pointing at nothing.

> **Strimzi tip:** Don't hand-create Services for Kafka. Instead add a **listener** and Strimzi makes the right Services for you. To reach Kafka from *outside* AWS, add an external listener:
>
> ```yaml
>     listeners:
>       - name: external
>         port: 9094
>         type: loadbalancer   # asks AWS for a load balancer
>         tls: true
> ```

### Ingress — the front door for traffic coming IN

Think of Ingress as a **receptionist** who directs visitors based on the name they ask for. It routes outside HTTP/HTTPS requests to the right Service by hostname or path. It needs an **ingress controller** running in the cluster (like ingress-nginx or the AWS Load Balancer Controller).

**Important Kafka caveat:** Kafka speaks a raw TCP protocol, *not* HTTP, so a plain Ingress can't carry Kafka traffic directly. So Ingress is mainly for the web tools *around* Kafka — like **Kafka UI** (next section) or the **Kafka Bridge** (which is HTTP). Strimzi *can* expose brokers with an `ingress`-type listener, but that needs an ingress controller with TLS passthrough enabled and a hostname per broker.

Commands:

- `kubectl get ingress -n kafka`
  Lists ingress rules and the external addresses assigned to them.
- `kubectl describe ingress <name> -n kafka`
  Shows the hostnames, paths, target Services, and any errors.

### Egress — traffic going OUT

Egress is connections **leaving** your pods — to other namespaces, AWS services, or the internet. By default, pods can reach anything. You usually only think about egress when **locking things down for security**: restricting where Kafka and its clients are allowed to connect. You do that with NetworkPolicies (see [Security and Network Policies](#12-security-and-network-policies)).

Common task — check what a pod can reach from the inside:

- `kubectl exec -it my-cluster-kafka-0 -n kafka -- bash`
  Opens a shell in a broker so you can test outbound connections (e.g. with `curl` or `nc`). If a connection hangs, egress may be blocked — useful for diagnosing firewall rules.

---

## 10. Kafka UI: Seeing Kafka Visually

The command-line tools work, but a **web dashboard** makes Kafka far easier to explore — you can browse topics, read messages, and watch consumer groups and their "lag" (how far behind readers are), all in a browser.

Several free dashboards exist. A common one is **Kafka UI** (the *kafbat/kafka-ui* project, formerly Provectus); other popular options are **AKHQ**, **Redpanda Console**, and **Conduktor**. Image names and tags change often, so check the project's page for the current one.

Deploy a simple dashboard. Save as `kafka-ui.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kafka-ui
  namespace: kafka
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka-ui
  template:
    metadata:
      labels:
        app: kafka-ui
    spec:
      containers:
        - name: kafka-ui
          image: ghcr.io/kafbat/kafka-ui:latest   # check the project for the current image/tag
          ports:
            - containerPort: 8080
          env:
            - name: KAFKA_CLUSTERS_0_NAME
              value: my-cluster
            - name: KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS
              value: my-cluster-kafka-bootstrap:9092
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-ui
  namespace: kafka
spec:
  selector:
    app: kafka-ui
  ports:
    - port: 8080
      targetPort: 8080
```

Commands:

- `kubectl apply -f kafka-ui.yaml`
  Deploys the dashboard and a Service pointing at it.
- `kubectl port-forward svc/kafka-ui 8080:8080 -n kafka`
  The simplest way to open it. This builds a private tunnel from the in-cluster Service to your own computer. Then visit `http://localhost:8080` in your browser. Press Ctrl+C to close the tunnel. **`port-forward`** is perfect for quick, private access without exposing anything to the internet.
- To share it with a team instead, put an **Ingress** in front of the `kafka-ui` Service (see [Networking](#9-networking-services-ingress-and-egress)).

> ⚠️ **Security:** A Kafka UI can usually read *and write* everything in the cluster. Never expose it publicly without a login. Keep it behind `port-forward`, a VPN, or an authenticated Ingress. If your cluster uses TLS/auth (Section 12), the UI also needs matching security settings (truststore and SASL username/password) in its `env`.

---

## 11. Taints and Tolerations

These control **which pods are allowed to run on which nodes** — useful for reserving powerful machines just for Kafka.

- A **taint** is a "keep out" sign you put on a node.
- A **toleration** is a special pass a pod carries that lets it ignore that sign.

**Analogy:** a taint is a *"staff only"* sign on a door; a toleration is the *staff badge* that lets you through. A node can be tainted so that *only* Kafka brokers (which carry the matching badge) are allowed to run there, keeping noisy neighbors from stealing CPU and disk.

Taints have three "effects":

- **NoSchedule** — don't place *new* pods here unless they tolerate the taint.
- **PreferNoSchedule** — try to avoid placing pods here, but it's allowed if there's no other room.
- **NoExecute** — as above, *and* kick out existing pods that don't tolerate it.

Commands:

- `kubectl taint nodes <node-name> dedicated=kafka:NoSchedule`
  Puts a "keep out" sign on a node. Now only pods that tolerate `dedicated=kafka` can be scheduled there.
- `kubectl taint nodes <node-name> dedicated=kafka:NoSchedule-`
  Removes the taint. The trailing `-` (minus) means "delete this taint."
- `kubectl describe node <node-name>`
  Shows that node's taints and labels, so you can confirm what's set.
- `kubectl get nodes --show-labels`
  Lists nodes with their labels — handy for finding the right AWS node group to target.

To let Kafka brokers run on tainted nodes, give them a matching toleration — and usually steer them there with node affinity to a label. Add under `spec.kafka.template.pod`:

```yaml
    template:
      pod:
        tolerations:
          - key: "dedicated"
            operator: "Equal"
            value: "kafka"
            effect: "NoSchedule"
        affinity:
          nodeAffinity:
            requiredDuringSchedulingIgnoredDuringExecution:
              nodeSelectorTerms:
                - matchExpressions:
                    - key: dedicated
                      operator: In
                      values: [kafka]
```

> **Key point:** A toleration only *lets* a pod onto a tainted node — it doesn't *force* it there. Pair it with **nodeAffinity** (above) to actually pull brokers onto the dedicated nodes. This works hand-in-hand with the broker anti-affinity in [Best Practices](#13-best-practices), which then spreads those brokers across different nodes and zones. On EKS, the usual pattern is a **dedicated node group** for Kafka that you taint, so only brokers land on it.

---

## 12. Security and Network Policies

Securing Kafka has four layers: **encrypt** the traffic, prove **who you are**, control **what you can do**, and **firewall** the network. Strimzi makes all four configurable.

### 1. Encryption (TLS) + Authentication

Swap the plain listener for a secure one. Under `spec.kafka`:

```yaml
    listeners:
      - name: secure
        port: 9093
        type: internal
        tls: true                 # encrypt traffic on the wire
        authentication:
          type: scram-sha-512     # require a username + password login
```

- `tls: true` encrypts the data so no one can eavesdrop.
- `authentication.type` sets how clients prove identity — commonly **scram-sha-512** (username/password) or **tls** (mutual TLS, where each client presents its own certificate).

### 2. Authorization — who can do what

Turn on access control, then grant each user only what they need. Under `spec.kafka`:

```yaml
    authorization:
      type: simple
```

### 3. Create a user with permissions (KafkaUser)

Save as `user.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: my-app
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: my-topic
        operations: [Read, Write]
```

This creates a login named `my-app` that may **only** Read and Write `my-topic` — nothing else. (ACL = Access Control List, the list of what's allowed.)

Commands:

- `kubectl apply -f user.yaml`
  Creates the user. Strimzi generates its password and stores it in a Secret with the same name.
- `kubectl get kafkauser -n kafka`
  Lists users and whether they're ready.
- `kubectl get secret my-app -n kafka -o jsonpath='{.data.password}' | base64 -d`
  Retrieves the generated password so your app can log in. It's stored base64-encoded in the Secret; `base64 -d` decodes it back to plain text.
- `kubectl get secret my-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt`
  Exports the cluster's CA certificate, which clients use to trust the encrypted connection. (This is the same Secret whose expiry you watch in [Maintenance Activities](#15-maintenance-activities).)

### 4. Network Policies — the pod firewall

**Analogy:** a guest list for the door. By default, *any* pod can connect to Kafka. A **NetworkPolicy** says "only pods with this label may reach the brokers," and can also limit where Kafka itself is allowed to send traffic (egress).

Strimzi already creates NetworkPolicies for its internal components, and you can restrict each listener to specific clients with `networkPolicyPeers`:

```yaml
    listeners:
      - name: secure
        port: 9093
        type: internal
        tls: true
        authentication:
          type: scram-sha-512
        networkPolicyPeers:
          - podSelector:
              matchLabels:
                app: my-app      # only pods labeled app=my-app may connect
```

A standalone NetworkPolicy looks like this. Save as `netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-only-my-app-to-kafka
  namespace: kafka
spec:
  podSelector:
    matchLabels:
      strimzi.io/name: my-cluster-kafka   # this rule applies to the Kafka broker pods
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: my-app                 # allow connections only from these pods
      ports:
        - port: 9093
```

Commands:

- `kubectl get networkpolicy -n kafka`
  Lists network policies — you'll see some that Strimzi created automatically.
- `kubectl describe networkpolicy <name> -n kafka`
  Shows exactly who is allowed in and out.
- `kubectl apply -f netpol.yaml`
  Applies your custom firewall rule.

> ⚠️ **Important:** NetworkPolicies only take effect if your cluster's networking plugin enforces them. On EKS, enable NetworkPolicy support in the Amazon VPC CNI add-on, or install **Calico**. Without an enforcing plugin, the rules are silently ignored. (Check current EKS docs, as add-on details change.)

### Quick security checklist

- Use **TLS** on every listener clients connect to.
- Give each app its **own KafkaUser** with the narrowest ACLs that still work.
- **Never** commit generated passwords or certificates to git — read them from Secrets at deploy time.
- Lock down access with `networkPolicyPeers` and/or **NetworkPolicies**.
- Watch the **CA certificate expiry** (see [Maintenance Activities](#15-maintenance-activities)).

---

## 13. Best Practices

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

## 14. Routine Health Checks

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

## 15. Maintenance Activities

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

## 16. AMI Updates & Node Patching (AWS)

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

Also re-confirm no under-replicated partitions (see [Health Checks](#14-routine-health-checks)) **before** you start.

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

## 17. Patching the EKS Control Plane

Separate from node AMIs, the **Kubernetes version** itself gets upgraded. Always upgrade the control plane **first**, then the nodes.

- `aws eks describe-cluster --name my-cluster --query 'cluster.version'`
  Shows the current Kubernetes version of your cluster.
- `aws eks update-cluster-version --name my-cluster --kubernetes-version 1.30`
  Upgrades the control plane. Go **one minor version at a time** (e.g. 1.29 → 1.30, never skip to 1.31).
- `aws eks update-nodegroup-version --cluster-name my-cluster --nodegroup-name my-nodegroup --kubernetes-version 1.30`
  Brings the node group up to match the new control-plane version.

> Before any version upgrade, **check the Strimzi compatibility docs** — each Strimzi release supports specific Kubernetes and Kafka versions. Upgrade the Strimzi operator *before* jumping Kafka versions, and always test in staging first.

---

## 18. Maintenance Cadence

A simple rhythm to keep things healthy:

- **Daily** — Glance at pod restarts, under-replicated partitions, and disk usage.
- **Weekly** — Review events and operator logs; check certificate expiry dates.
- **Monthly** — Apply node AMI patches; review resource usage and rebalance if lopsided.
- **Quarterly** — Plan Kubernetes / Strimzi / Kafka version upgrades (test in staging first).

---

## 19. Quick Mental Model

You write YAML describing what you want → `kubectl apply` sends it to the manager → Kubernetes (with Strimzi's help for Kafka) makes it real and keeps it healthy.

**You describe the goal; it handles the work.**

---

*End of cheat sheet.*
