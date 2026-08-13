# Kubernetes, Explained Like You're in Middle School

### A complete guide to the control plane, metrics server, nodes, node groups, pods, high availability, updates, monitoring — plus AWS EKS, Azure AKS, and three hands-on tutorials

**Last updated: August 13, 2026**
**Current Kubernetes version: 1.36 (1.37 lands August 26, 2026)**

---

## How to use this guide

1. **Part 1** is a 20-minute hands-on setup you can do on your own laptop. Do this first. Everything after it will make ten times more sense.
2. **Parts 2–11** explain every important piece of Kubernetes, in plain language, using a grocery store and a school as the running examples.
3. **Parts 12–14** cover Amazon EKS, Azure AKS, and how they compare.
4. **Parts 15–17** are three complete step-by-step tutorials: Hello World on EKS, Hello World on AKS, and a Kafka message cluster on either one.
5. **Parts 18–21** cover security, cost control, Helm/GitOps/CI-CD, and Terraform infrastructure as code.
6. **Part 22** is an appendix of thirteen complete, ready-to-use example files (also provided as separate downloadable files).
7. **Parts 23–24** are the troubleshooting runbook and a complete master troubleshooting reference covering every common failure, how to identify it, and what to do about it.
8. **Part 25** is a deep dive on Amazon EKS with an expanded, bullet-by-bullet comparison against Azure AKS.
9. **Parts 26–27** are the history of how Kubernetes changed over the years, plus a cheat sheet, glossary, and debugging flowchart.

> **The one-sentence version:** Kubernetes is a robot manager for a very large store. You tell it *what you want* ("I always want 5 cashiers working"), and it constantly checks reality, notices when reality doesn't match, and fixes it — forever, without you asking.

---

# PART 1 — Do this first: your own cluster in 20 minutes

We're going to build a tiny Kubernetes cluster on your laptop, run a "Hello World" website on it, install the **metrics server**, and watch Kubernetes automatically add more copies of the website when it gets busy.

This costs $0 and nothing here can break your computer.

## Step 0 — Install four tools

| Tool | What it is | Install |
|---|---|---|
| **Docker Desktop** (or Podman / Colima) | Runs containers | https://docs.docker.com/get-started/get-docker/ |
| **kind** | Makes a fake Kubernetes cluster inside Docker | `brew install kind` (Mac) / `choco install kind` (Windows) |
| **kubectl** | The remote control for Kubernetes | `brew install kubectl` / `choco install kubernetes-cli` |
| **helm** *(optional, used later)* | An "app store installer" for Kubernetes | `brew install helm` |

Check they work:

```bash
docker version
kind version
kubectl version --client
```

## Step 1 — Create a 3-node cluster

Make a file called `kind-cluster.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane      # the manager's office
  - role: worker             # a shelf where work happens
  - role: worker             # a second shelf
```

Now build it:

```bash
kind create cluster --name hello --config kind-cluster.yaml
```

Wait about 60 seconds. Then look at your cluster:

```bash
kubectl get nodes
```

You should see three "computers" (they're really containers pretending to be computers):

```
NAME                  STATUS   ROLES           AGE   VERSION
hello-control-plane   Ready    control-plane   57s   v1.34.x
hello-worker          Ready    <none>          45s   v1.34.x
hello-worker2         Ready    <none>          45s   v1.34.x
```

**What just happened:** you built a store. One office (control plane), two shelf areas (workers).

## Step 2 — Look inside the office

```bash
kubectl get pods -n kube-system
```

You'll see names like `kube-apiserver-...`, `etcd-...`, `kube-scheduler-...`, `kube-controller-manager-...`, `coredns-...`, `kube-proxy-...`. **These are the control plane** — the store's management team. Part 3 explains each one. Just notice they exist.

## Step 3 — Deploy Hello World

Create `hello.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment                    # "I want N copies of this app, always"
metadata:
  name: hello
spec:
  replicas: 2                       # two copies
  selector:
    matchLabels:
      app: hello
  template:                         # the recipe card for one copy
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: web
          image: nginxdemos/hello:plain-text
          ports:
            - containerPort: 80
          resources:
            requests:               # "I need at least this much"
              cpu: 50m
              memory: 32Mi
            limits:                 # "never let me eat more than this"
              cpu: 200m
              memory: 128Mi
          readinessProbe:           # "am I ready for customers?"
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:            # "am I still alive?"
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service                       # one stable phone number for all copies
metadata:
  name: hello
spec:
  selector:
    app: hello                      # sends traffic to any pod with this label
  ports:
    - port: 80
      targetPort: 80
```

Apply it and watch:

```bash
kubectl apply -f hello.yaml
kubectl get pods -w        # press Ctrl+C when both say Running
```

See it in a browser:

```bash
kubectl port-forward service/hello 8080:80
```

Open http://localhost:8080 — you'll see a page that prints the **pod name** serving you. Refresh a few times; the name changes. That's load balancing.

## Step 4 — Break something on purpose

```bash
kubectl delete pod -l app=hello        # delete BOTH copies
kubectl get pods
```

They're already coming back. **You never asked for that.** The Deployment's controller noticed "I want 2, I have 0" and fixed it. That is the single most important idea in Kubernetes: *desired state vs. actual state, reconciled forever.*

## Step 5 — Install the metrics server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

On kind (and most home labs) the kubelet uses a self-signed certificate, so add one flag for testing only:

```bash
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl -n kube-system rollout status deployment metrics-server
```

Wait ~30 seconds for the first measurements, then:

```bash
kubectl top nodes
kubectl top pods
```

You just installed the cluster's **weighing scale**. Without it, `kubectl top` and autoscaling on CPU do not work.

## Step 6 — Make it scale itself

```bash
kubectl autoscale deployment hello --cpu-percent=50 --min=2 --max=10
kubectl get hpa
```

Now generate load in a second terminal:

```bash
kubectl run load --rm -it --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://hello; done"
```

Back in terminal one, watch:

```bash
kubectl get hpa -w
kubectl get pods -w
```

Within a couple of minutes you'll see replicas climb from 2 toward 10. Stop the load (Ctrl+C) and after ~5 minutes it scales back down. **The HPA read the numbers the metrics server collected and acted on them.**

## Step 7 — Do a rolling update with zero downtime

```bash
kubectl set image deployment/hello web=nginxdemos/hello:plain-text
kubectl rollout status deployment/hello
kubectl rollout history deployment/hello
kubectl rollout undo deployment/hello        # instant rollback
```

Kubernetes replaced pods **a few at a time**, waiting for each new one to pass its readiness probe before killing an old one. The website never went down.

## Step 8 — Clean up

```bash
kind delete cluster --name hello
```

**You have now personally used**: nodes, pods, Deployments, ReplicaSets, Services, labels & selectors, probes, resource requests/limits, the metrics server, the HPA, rolling updates, and rollbacks. The rest of this guide explains *why* each of those exists and how to run them for real.

---

# PART 2 — Background: why Kubernetes exists at all

## The problem, told as a grocery store

Imagine you own one grocery store. You have one cash register. When it breaks, the store is closed. When 400 customers show up at once, you have one line and everybody is furious. When you want to remodel, you close for a week.

That's a **single server running one application**. This is how software worked for a long time, and it had four permanent problems:

1. **Fragility** — one machine dies, the app dies.
2. **Waste** — you buy a machine big enough for Black Friday, then it sits 90% idle in February.
3. **"Works on my machine"** — the app ran fine on the developer's laptop and crashed on the server because a library version differed.
4. **Slow, scary updates** — updating meant downtime and no easy way back.

## The three inventions that led here

**1. Virtual machines (~2000s).** One physical computer pretends to be many computers. Better, but each fake computer carries a full operating system — like giving every cashier their own separate building.

**2. Containers (Docker, 2013).** A container packages your app *plus* everything it needs to run — but shares the host's operating system kernel. Think of a **meal kit box**: all ingredients, pre-measured, sealed, and it cooks identically in any kitchen. Containers start in milliseconds and are tiny compared to VMs. "Works on my machine" mostly disappeared.

**3. Orchestration (Kubernetes, 2014).** Once you have 500 meal kits and 40 kitchens, somebody has to decide which box goes in which kitchen, restart the burnt ones, and add kitchens on Thanksgiving. That's orchestration. Kubernetes is that manager.

## Where Kubernetes came from

- Google had been running everything in containers internally for a decade with a system called **Borg** (and its successor Omega). Borg is why Google could run search across millions of machines.
- In **June 2014**, Google open-sourced a clean-room rewrite of those ideas as **Kubernetes** — Greek for *helmsman* or *pilot*, which is why the logo is a ship's wheel. "K8s" is shorthand: K, eight letters, s.
- **July 2015**: version 1.0 shipped, and Google donated it to the newly formed **Cloud Native Computing Foundation (CNCF)**, so no single company owns it.
- **2016–2018**: the "orchestrator wars" against Docker Swarm and Apache Mesos ended. Kubernetes won so completely that AWS, Microsoft, and Docker all shipped Kubernetes products.
- **Today (2026)**: essentially every cloud provider offers managed Kubernetes; a new minor version ships about every four months, and each version is supported for roughly 14 months.

## The one idea that makes Kubernetes different: declarative control loops

Most tools are **imperative**: "start this program, now stop that one." You give orders and hope.

Kubernetes is **declarative**: you write down the world you want, and dozens of small robots ("controllers") each run the same infinite loop:

```
loop forever:
    what do I WANT?      (read desired state from the API)
    what do I HAVE?      (observe actual state)
    are they different?  (if yes, take one small step to close the gap)
```

**School analogy:** the attendance policy says "every classroom has one teacher." A robot walks the hallway forever. Room 12 has no teacher? Send a substitute. It doesn't matter *why* the teacher vanished — sick, quit, hit by a bus. The loop just keeps fixing.

This is why Kubernetes is self-healing without anyone writing "if crash then restart" logic. Everything in the rest of this guide — Deployments, autoscalers, node repair, load balancers — is just another control loop.

---

# PART 3 — The complete map (grocery store edition)

Keep this table nearby. Every term in this guide maps to something in a store.

| Kubernetes thing | Grocery store thing | Job in one line |
|---|---|---|
| **Cluster** | The whole store | Everything, working as one system |
| **Node** | One employee / one workstation | A computer that runs your work |
| **Node group / node pool** | A department (bakery, deli, cashiers) | A set of identical, interchangeable nodes |
| **Pod** | One task station with its tools | The smallest unit Kubernetes runs |
| **Container** | The meal kit box being cooked | Your actual app + its dependencies |
| **kube-apiserver** | The front desk / intercom | The only way to ask for or change anything |
| **etcd** | The store's official ledger | The written truth of what should exist |
| **kube-scheduler** | The shift manager | Decides which node each new pod goes to |
| **kube-controller-manager** | Department supervisors | The fix-it robots that reconcile state |
| **cloud-controller-manager** | The liaison to the mall management | Talks to AWS/Azure for load balancers, disks, node info |
| **kubelet** | The employee's own to-do list & badge reader | The agent on each node that runs pods |
| **kube-proxy** | The store's internal phone routing | Makes Service IPs actually work on each node |
| **Container runtime (containerd)** | The oven | Actually runs the container |
| **CoreDNS** | The store directory ("Dairy → aisle 4") | Turns names into IP addresses |
| **CNI plugin** | The hallways between departments | Gives every pod an IP and lets pods talk |
| **metrics-server** | The scale in the produce section | Measures live CPU/memory for scaling |
| **Service** | The department's phone extension | One stable address for a changing set of pods |
| **Ingress / Gateway** | The front doors and signage | Lets outside customers reach the right department |
| **Deployment** | The staffing plan | "Always 5 cashiers, replace them gently when updating" |
| **ConfigMap / Secret** | The policy binder / the safe | Settings and passwords, kept out of the app image |
| **PersistentVolume** | The walk-in freezer | Storage that survives when a pod dies |
| **Namespace** | A floor or a franchise inside the store | A way to divide one cluster into separate areas |

---

# PART 4 — The control plane, component by component

The **control plane** is the management office. It doesn't stock shelves; it decides what should happen. In a cloud service like EKS or AKS, **the cloud provider runs the entire control plane for you** and you never see these pods — but knowing what they do is how you debug real problems.

## 4.1 kube-apiserver — the front desk

**What it is:** a REST API server. It is the *only* door into the cluster. `kubectl`, the dashboard, every controller, every node — all of them talk only to the API server.

**Store analogy:** the front desk with the intercom. Nobody is allowed to shout across the store. If the deli needs more ham, they call the front desk. The front desk writes it in the ledger and announces it.

**How it works, in order, for every single request:**
1. **Authentication** — who are you? (certificate, token, cloud IAM identity)
2. **Authorization** — are you allowed? (RBAC: Role-Based Access Control)
3. **Admission control** — should this be modified or rejected? (mutating webhooks add defaults; validating webhooks enforce policy, e.g. "no container may run as root")
4. **Validation & persistence** — write it to etcd
5. **Watch notification** — tell everyone who is watching that something changed

**Why it matters for availability:** if the API server is down, *existing pods keep running* — the store keeps selling groceries — but **nothing new can be created, scaled, or healed**. That's why managed clouds run multiple API server replicas across availability zones behind a load balancer.

**Best practices**
- Never expose it to the whole internet without restriction. Use private endpoints or IP allow-lists.
- Use RBAC with least privilege; no human should routinely hold `cluster-admin`.
- Set API Priority and Fairness / rate limits so one runaway script can't starve the cluster.
- Watch the `apiserver_request_duration_seconds` metric — a slow API server is the first symptom of a sick cluster.

## 4.2 etcd — the official ledger

**What it is:** a distributed key-value database. It stores **100% of cluster state**: every object, every setting, every secret.

**Store analogy:** the store's legal ledger book. Not the shelves themselves — the *record* of what should be on the shelves, who works here, and what the policies are. Burn the ledger and you don't lose today's groceries, but you lose the ability to rebuild the store.

**Key facts a beginner should know:**
- It uses the **Raft consensus algorithm**: a majority ("quorum") of members must agree before a write is accepted. That's why you run an **odd number** — 3 or 5.
- 3 members survive 1 failure. 5 members survive 2. **4 members survive only 1** — an even number buys you nothing and costs you speed. This is the classic exam question.
- It is extremely sensitive to **disk latency**. etcd on slow disks is the #1 cause of mysterious cluster slowness. Always use fast SSDs.
- Secrets live here, so **encryption at rest** matters (EKS can use AWS KMS; AKS can use Azure Key Vault KMS).

**Best practices**
- Back it up on a schedule *and practice restoring it*. An untested backup is a rumor.
- Keep the database under a few GB; don't store huge ConfigMaps or thousands of stale objects.
- On EKS/AKS, all of this is AWS's/Microsoft's job — a strong argument for managed Kubernetes.

## 4.3 kube-scheduler — the shift manager

**What it is:** the component that decides **which node** a brand-new pod runs on. It doesn't start the pod; it just writes down the assignment.

**Store analogy:** a new task appears ("restock cereal"). The shift manager looks at who's available, who has the right training, who isn't already overloaded, and assigns it. Then that employee does the work.

**How it decides — two phases:**

**Phase 1: Filtering (who is even possible?)** Nodes are eliminated if they:
- don't have enough free CPU/memory for the pod's **requests**
- don't match the pod's **nodeSelector** or **node affinity** (e.g. "must have a GPU", "must be in zone us-east-1a")
- have a **taint** the pod doesn't **tolerate**
- have no free ports the pod needs, or full disk pressure

**Phase 2: Scoring (of the possible ones, who is best?)** Surviving nodes get points for:
- spreading pods away from identical siblings (**topology spread constraints**, **pod anti-affinity**)
- already having the container image cached (faster start)
- balanced resource usage
- honoring **inter-pod affinity** ("put me near the cache")

Highest score wins. Ties are broken randomly.

**The three tools you'll actually use:**

| Tool | Plain meaning | Example |
|---|---|---|
| **nodeSelector / node affinity** | "I want to run on nodes *like this*" | `disktype: ssd`, `karpenter.sh/capacity-type: on-demand` |
| **Taints & tolerations** | The node says "keep out unless invited" | A GPU node is tainted so ordinary web pods don't waste it |
| **Topology spread constraints** | "Spread my copies across zones/nodes" | Never put all 3 replicas in one availability zone |

**Best practices**
- **Always set resource requests.** The scheduler is blind without them — it will happily cram 40 pods onto one node and then everything thrashes.
- Use `topologySpreadConstraints` with `topologyKey: topology.kubernetes.io/zone` for anything that must survive a data-center failure.
- Use taints to reserve expensive nodes (GPU, memory-optimized) for the workloads that need them.

## 4.4 kube-controller-manager — the supervisors

**What it is:** one program running dozens of control loops. Each one watches a type of object and fixes drift.

**The important ones:**

| Controller | What it watches for | Store analogy |
|---|---|---|
| **Deployment controller** | Deployment changes | Rewrites the staffing plan and rolls out new shifts gradually |
| **ReplicaSet controller** | "Do I have N pods?" | Counts cashiers; hires or sends home to match |
| **Node controller** | Nodes going silent | Notices an employee stopped answering; after ~40s marks `NotReady`, after ~5min starts evicting their work |
| **Job / CronJob controller** | One-off and scheduled work | Runs the nightly inventory count |
| **StatefulSet controller** | Ordered, identity-keeping pods | Manages numbered stations (0,1,2) that own their own freezer |
| **DaemonSet controller** | One pod per node | Puts a fire extinguisher in every room |
| **Endpoint/EndpointSlice controller** | Which pods are healthy and behind a Service | Keeps the department phone list current |
| **PV/PVC controllers** | Storage claims | Assigns freezer space when someone requests it |

**Why it matters:** this is *why* your app heals itself. You never write the recovery logic.

**Best practice:** understand the node controller's timing. Between a node dying and its pods being rescheduled, there is a real gap (roughly 40 seconds to notice, then a 5-minute default eviction grace). Users feel that gap unless you already have replicas on other nodes. **Redundancy beats fast recovery.**

## 4.5 cloud-controller-manager — the mall liaison

**What it is:** the piece that knows how to talk to AWS, Azure, GCP, etc. It was deliberately split out of the core so Kubernetes itself stays cloud-neutral.

**What it does:** creates a real AWS NLB or Azure Load Balancer when you make a `Service` of type `LoadBalancer`; attaches EBS/Azure Disk volumes; labels nodes with their region and zone; removes node objects when the underlying VM is deleted.

**Store analogy:** your store is inside a mall. When you need a bigger loading dock or another parking spot, you don't build it — you call mall management. The cloud-controller-manager is that phone call.

## 4.6 The node components (on every worker)

### kubelet — the employee themself
The agent on each node. It watches the API server for "pods assigned to me," then tells the container runtime to pull images and start containers. It runs the **probes**, reports node and pod status back, and enforces limits.

**Store analogy:** the employee who checks their task list, does the work, and reports "done" or "I'm stuck."

Also: the kubelet is who **evicts** pods when the node runs low on memory or disk, and who reports the metrics the metrics-server scrapes.

### kube-proxy — internal phone routing
Programs the node's networking rules (iptables, or increasingly **eBPF** via Cilium) so that traffic sent to a Service's virtual IP actually reaches a real pod.

*Note: IPVS mode in kube-proxy was deprecated in 1.35 and removed in 1.36. Modern clusters use iptables mode or replace kube-proxy entirely with eBPF-based networking.*

### Container runtime — the oven
**containerd** (or CRI-O) actually runs containers. Docker-as-a-runtime was removed from Kubernetes in **1.24** (the famous "dockershim removal"); images built with Docker still work perfectly, because the image format is a shared standard.

### The three probes (memorize these)

| Probe | Question it asks | What happens if it fails |
|---|---|---|
| **startupProbe** | "Have you finished booting yet?" | Keeps the other probes from firing too early on slow apps |
| **readinessProbe** | "Are you ready for customers *right now*?" | Pod is pulled out of the Service — **no traffic**, but not killed |
| **livenessProbe** | "Are you alive, or hung?" | Container is **killed and restarted** |

**Store analogy:** readiness = the cashier turned their lane light off because they're restocking. Liveness = the cashier is asleep at the register and needs to be woken up (restarted).

**Best practices**
- Every serious workload gets a readiness probe. Without it, Kubernetes sends traffic to pods that are still starting → 502 errors during every deploy.
- Be careful with liveness probes: a too-aggressive one causes restart loops during a traffic spike, which makes the outage *worse*. When in doubt, readiness only.
- Use a startupProbe for slow-booting apps (Java, big ML models) instead of huge `initialDelaySeconds`.

---

# PART 5 — Workload objects: what you actually deploy

## 5.1 Pod — the smallest unit

A **pod** is one or more containers that always live and die together, share an IP address, and can share files.

**Store analogy:** a task station. Usually one worker (one container). Sometimes a worker plus a helper who does one small side job — a **sidecar**, like a log shipper or a service-mesh proxy. They share the same counter and the same phone.

Key facts:
- Pods are **mortal and disposable**. They get a new IP every time. Never point anything at a pod IP.
- You rarely create pods directly. You create a Deployment, and *it* creates pods.
- **Init containers** run to completion *before* the main containers (e.g. "wait for the database", "download config").
- **Sidecar containers** got a proper, ordered lifecycle (they start before and shut down after the main container) — this graduated to stable in Kubernetes 1.33.

## 5.2 The workload controllers

| Object | Use it for | Store analogy | Key behavior |
|---|---|---|---|
| **Deployment** | Stateless apps: web servers, APIs | The cashier staffing plan | Any pod is interchangeable; rolling updates; instant rollback |
| **ReplicaSet** | (Created by Deployments; you rarely touch it) | One specific version of the staffing plan | Just keeps N pods alive |
| **StatefulSet** | Databases, Kafka, anything with its own disk or identity | Numbered freezer stations 0,1,2 | Stable names, stable storage, ordered startup/shutdown |
| **DaemonSet** | Log collectors, monitoring agents, CNI, kube-proxy | A fire extinguisher in every room | Exactly one pod per node, automatically on new nodes too |
| **Job** | One-off tasks that must finish | Tonight's inventory count | Runs to completion, retries on failure |
| **CronJob** | Scheduled tasks | The 3 a.m. floor cleaning | Creates a Job on a cron schedule |

**When to use StatefulSet vs Deployment:** if a pod needs to be *the same pod* after a restart — same name, same disk — it's a StatefulSet. `kafka-0` must come back as `kafka-0` with its own data. A web server doesn't care, so it's a Deployment.

## 5.3 Configuration and secrets

- **ConfigMap** — non-secret settings (feature flags, URLs, config files). The policy binder on the manager's desk.
- **Secret** — passwords, API keys, TLS certificates. The safe. Warning: by default Secrets are only **base64-encoded, not encrypted** inside etcd. Turn on encryption at rest, and prefer pulling real secrets from **AWS Secrets Manager** or **Azure Key Vault** via the Secrets Store CSI driver.

**Best practice:** never bake config or credentials into the container image. Same image, different ConfigMap, is how one build goes to dev, staging, and production.

## 5.4 Storage

| Object | Meaning |
|---|---|
| **PersistentVolume (PV)** | An actual piece of storage that exists (an EBS volume, an Azure Disk) |
| **PersistentVolumeClaim (PVC)** | A request: "I need 20Gi of fast storage" |
| **StorageClass** | The catalog of storage types available, and who provisions them |
| **CSI driver** | The standard plug that lets any storage vendor work with Kubernetes |

**Store analogy:** the PVC is the request form for freezer space; the StorageClass is the price list ("walk-in freezer" vs "chest freezer"); the PV is the actual freezer you were given; the CSI driver is the contractor who installs it.

**Best practices**
- Use `volumeBindingMode: WaitForFirstConsumer` so the disk is created in the *same availability zone* as the pod. Otherwise you get pods that can never schedule.
- A pod using a zonal disk (EBS, Azure Disk) is pinned to that zone. Plan HA accordingly.
- You can usually grow a volume; you can almost never shrink one.

## 5.5 Namespaces, quotas, and RBAC

- **Namespace** — a folder inside the cluster. `team-a`, `team-b`, `production`. Names must be unique *within* a namespace, not across the cluster.
- **ResourceQuota** — "team-a may use at most 100 CPUs and 400Gi of memory total." The department budget.
- **LimitRange** — default requests/limits for pods that forgot to set them.
- **RBAC** (Role, ClusterRole, RoleBinding, ClusterRoleBinding) — who can do what, where. A Role is namespace-scoped; a ClusterRole is cluster-wide.
- **ServiceAccount** — the identity a *pod* uses to talk to the API server (and, via IRSA/Pod Identity/Workload Identity, to talk to AWS or Azure).

**Best practice:** one namespace per team or per environment, with a ResourceQuota, a LimitRange, and a default-deny NetworkPolicy. That trio prevents 80% of "one team broke the cluster" incidents.

---

# PART 6 — Services and networking: how anything finds anything

## 6.1 The problem

Pods die and get new IPs constantly. If the checkout system memorized the deli worker's personal cell number, it breaks every time the deli worker changes shift. You need a **department extension** that always rings whoever is on duty.

That's a **Service**.

## 6.2 The Service types

| Type | What it does | Store analogy | When to use |
|---|---|---|---|
| **ClusterIP** (default) | A stable virtual IP reachable only *inside* the cluster | Internal extension 4-1-2-2 | Almost everything: app→database, app→cache |
| **NodePort** | Opens the same high port (30000–32767) on every node | A side door with a number, on every wall | Rarely; mostly a building block or for on-prem |
| **LoadBalancer** | Asks the cloud for a real load balancer with a public IP | The official front entrance with a street address | Exposing something to the internet |
| **ExternalName** | A DNS alias to something outside | "For pharmacy, call the store across town" | Pointing at a managed database |
| **Headless** (`clusterIP: None`) | No virtual IP; DNS returns each pod's own IP | The direct extension of each numbered station | StatefulSets — Kafka, databases, anything where clients must reach a *specific* member |

## 6.3 How a Service actually works

1. The Service has a **selector**, e.g. `app: hello`.
2. The **EndpointSlice controller** continuously lists which pods match that label *and* are passing their readiness probe.
3. **kube-proxy** (or eBPF) programs each node so traffic to the Service IP is rewritten to one of those pod IPs.
4. **CoreDNS** makes it findable by name.

**The DNS name format** — memorize this one:

```
<service-name>.<namespace>.svc.cluster.local
```

Inside the same namespace, `http://hello` is enough. From another namespace, `http://hello.production`.

## 6.4 Ingress and the Gateway API — the front doors

A `LoadBalancer` Service per app gets expensive fast (one cloud load balancer each). **Ingress** gives you *one* front door that routes by hostname and path:

```
shop.example.com/          → frontend service
shop.example.com/api       → api service
admin.example.com/         → admin service
```

An Ingress object is just a rulebook; an **Ingress controller** (NGINX, AWS Load Balancer Controller, Azure App Routing) is the actual doorman that reads it.

**IMPORTANT 2026 CHANGE:** The Kubernetes project **retired Ingress NGINX in March 2026** — no more bug fixes or security patches. If you're using it, plan a migration. The successor is the **Gateway API**, a richer, role-aware replacement (`GatewayClass` → `Gateway` → `HTTPRoute`) that supports traffic splitting, header matching, and cleanly separates the platform team's config from the app team's routes. Alternatives include Envoy Gateway, Istio, Traefik, HAProxy, and the cloud-native controllers on EKS and AKS.

Also note: the `Service.spec.externalIPs` field was **deprecated in Kubernetes 1.36** (removal planned for 1.43). Migrate to LoadBalancer, NodePort, or Gateway API.

## 6.5 NetworkPolicy — internal doors that lock

By default **every pod can talk to every other pod**. That's a flat store where anyone can walk into the pharmacy stockroom.

A **NetworkPolicy** restricts that: "only pods labeled `app: api` may connect to `app: database` on port 5432." It requires a CNI that supports it (Calico, Cilium, AWS VPC CNI with policy enforcement, Azure CNI Powered by Cilium).

**Best practice:** start each namespace with a default-deny-ingress policy, then explicitly allow what's needed. This is the single highest-value security control in Kubernetes.

---

# PART 7 — The metrics server, in depth

## 7.1 What it is

The **metrics-server** is a small, cluster-wide aggregator that collects **live CPU and memory usage** from every kubelet and serves it through the Kubernetes **Metrics API** (`metrics.k8s.io`).

**Store analogy:** the produce scale. It tells you what something weighs *right now*. It does not remember what it weighed yesterday, and it doesn't tell you about flavor, temperature, or sales.

## 7.2 Why it exists

Before it, there was **Heapster**, which tried to be a full monitoring pipeline and was deprecated in 1.11 and removed in 1.13. The lesson learned: split the jobs.

- **Core metrics pipeline** = metrics-server. Small, fast, in-memory, only CPU and RAM. Feeds *automation*.
- **Full monitoring pipeline** = Prometheus + Grafana (or Azure Monitor / CloudWatch). Historical, many metrics, dashboards, alerts. Feeds *humans*.

## 7.3 How it works

1. Every **kubelet** already measures container CPU and memory (via cAdvisor built into it) and exposes a `/metrics/resource` endpoint.
2. metrics-server scrapes every kubelet, **by default every 15 seconds**.
3. It keeps only the **most recent** sample **in memory**. No database. No history.
4. It registers itself as an **APIService** through the API aggregation layer, so `metrics.k8s.io` looks like a native part of the Kubernetes API.
5. Anything that asks the API server for metrics gets served transparently.

**Who consumes it:**
- `kubectl top nodes` / `kubectl top pods`
- **HorizontalPodAutoscaler (HPA)** — add/remove pod copies based on CPU or memory
- **VerticalPodAutoscaler (VPA)** — recommend or set better requests/limits
- The Kubernetes Dashboard and many schedulers/tools

## 7.4 Installing it

**Vanilla / self-managed:**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**High availability (2+ replicas, needs at least 2 nodes):**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/high-availability-1.21+.yaml
```
For HA, also enable `--enable-aggregator-routing=true` on the API server so requests load-balance across replicas. (On managed clouds you can't set that flag; the provider handles it.)

**Via Helm:**
```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm install metrics-server metrics-server/metrics-server -n kube-system
```

**On Amazon EKS:** *not installed by default.* Install it as an EKS **community add-on** (console → Add-ons → Get more add-ons → Metrics Server, or `aws eks create-addon --addon-name metrics-server`). AWS packages and lifecycle-manages it but support for the software itself comes from the community. On **Fargate**, use the add-on version — it's preconfigured on port 10251 because port 10250 is reserved by Fargate.

**On Azure AKS:** *installed and managed for you* as part of every cluster. `kubectl top` works out of the box. Don't install a second copy.

## 7.5 Troubleshooting the two errors you will hit

| Symptom | Cause | Fix |
|---|---|---|
| `error: Metrics API not available` | metrics-server isn't installed, or hasn't taken its first sample | Install it; wait 30–60s |
| Pod logs show `x509: certificate signed by unknown authority` | The kubelet's serving cert isn't signed by the cluster CA (common on kind, minikube, kubeadm, some on-prem) | Proper fix: enable kubelet serving certificate rotation and approve the CSRs. Test-only fix: `--kubelet-insecure-tls` |
| `unable to fully scrape metrics ... connection refused` | Security group / NSG / firewall blocks port 10250 | Allow TCP 10250 from metrics-server pods to all nodes |
| HPA shows `<unknown>/50%` | The pods have **no CPU requests** | HPA calculates a *percentage of the request*. No request = no percentage. Set requests. |

## 7.6 Pros and cons

**Pros**
- Tiny footprint; scales to thousands of nodes on a few hundred MB
- Zero configuration for the common case
- It's the *standard* — HPA and VPA expect it
- No database to operate or back up

**Cons / limits**
- **No history.** You cannot ask "what was CPU at 3 a.m.?"
- **Only CPU and memory.** No disk, no network, no request latency, no queue depth
- **Not for billing, capacity planning, or alerting** — the project explicitly says don't use it as a monitoring solution
- ~15-second granularity means it lags fast spikes
- Single replica by default = a brief blind spot during upgrades

## 7.7 Best practices

1. **Install it everywhere.** Autoscaling silently doesn't work without it.
2. **Always set CPU requests** on anything you want to autoscale.
3. Run **2 replicas** in production with a PodDisruptionBudget.
4. **Pair it with Prometheus** (or Azure Monitor managed Prometheus / CloudWatch Container Insights). metrics-server for robots, Prometheus for humans.
5. For scaling on *anything else* — queue length, requests per second, Kafka lag, HTTP p95 — add **Prometheus Adapter** or **KEDA**. KEDA is the easier path and is a first-class AKS add-on and a common EKS install.
6. Don't scrape it as your monitoring source; scrape kubelet/cAdvisor directly with Prometheus instead.

---

# PART 8 — High availability and fault tolerance

**High availability (HA)** = the store stays open. **Fault tolerance** = things break and customers never notice.

The core rule: **assume everything fails.** Nodes fail. Zones fail. Your app has bugs. Cloud providers do maintenance without asking. Design so that no single failure is visible.

## 8.1 The layers of redundancy

| Layer | What can fail | How you survive it |
|---|---|---|
| **Container** | App crashes | Liveness probe restarts it; `restartPolicy: Always` |
| **Pod** | Pod is evicted or the node dies | `replicas: 3+` in a Deployment |
| **Node** | A VM dies or is drained | Spread replicas across nodes (`topologySpreadConstraints`) |
| **Rack / zone** | An entire availability zone loses power | Node groups in **3 AZs**, spread by zone |
| **Region** | A whole region has an outage | A second cluster in another region + global DNS/traffic manager |
| **Control plane** | API server or etcd fails | Managed clouds do this for you (multi-AZ, 3–5 etcd members) |

## 8.2 The eight settings that actually give you HA

**1. Replicas ≥ 3 (odd numbers for quorum systems)**
Two replicas means one node drain takes you to 50% capacity. Three is the practical minimum for anything user-facing.

**2. Topology spread constraints — spread across zones AND nodes**
```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule       # hard rule for zones
    labelSelector:
      matchLabels: { app: hello }
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway      # soft rule for nodes
    labelSelector:
      matchLabels: { app: hello }
```
*Store analogy:* don't put all four fire extinguishers in one closet.

**3. PodDisruptionBudget (PDB) — the "you may not close every lane at once" rule**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: hello-pdb
spec:
  minAvailable: 2          # or: maxUnavailable: 1
  selector:
    matchLabels: { app: hello }
```
A PDB stops **voluntary** disruptions (node drains, cluster upgrades, autoscaler consolidation) from taking too many replicas at once. It does **not** protect against a node exploding — that's involuntary.

**Warning, learned the hard way:** a PDB of `minAvailable: 1` on a 1-replica Deployment will **block your cluster upgrade forever**. Always have more replicas than the PDB requires.

**4. Resource requests and limits — and QoS classes**

| QoS class | How you get it | Who gets killed first when a node runs out of memory |
|---|---|---|
| **Guaranteed** | requests == limits, for every container | Last |
| **Burstable** | requests set, limits higher or unset | Middle |
| **BestEffort** | nothing set | **First** |

*Best practice:* always set memory `requests == limits` (memory is not compressible — exceeding it means OOMKill). For CPU, set requests but consider leaving limits off or generous, since CPU limits cause **throttling** that looks like a mysterious latency problem.

**5. Anti-affinity for critical pairs**
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels: { app: database }
        topologyKey: kubernetes.io/hostname
```
Never put two database replicas on the same physical machine.

**6. PriorityClass and preemption**
Give critical system pods a high `priorityClassName` so that when the cluster is full, low-priority batch jobs get evicted to make room for the checkout system — not the other way around.

**7. Graceful shutdown**
When a pod is terminated it gets `SIGTERM`, then `terminationGracePeriodSeconds` (default 30) to finish in-flight work. Add a `preStop` hook `sleep 5–15` so the load balancer stops sending new traffic *before* the app stops accepting it. This single trick eliminates most "random 502s during deploy."

**8. Multiple node groups across zones**
One node group per AZ (or a single group spanning AZs, depending on the autoscaler). Never run production on a single-AZ node group.

## 8.3 What failure actually looks like, second by second

A node loses power at 12:00:00.

| Time | What happens |
|---|---|
| 12:00:00 | Node stops sending heartbeats |
| ~12:00:40 | Node controller marks it `NotReady`. **Service endpoints for its pods are removed → traffic stops going there.** |
| 12:00:40–12:05:40 | Default 5-minute toleration window. Pods still exist "on paper." |
| ~12:05:40 | Pods are evicted and rescheduled elsewhere |
| +30–90s | New pods pull images, start, pass readiness, take traffic |

**The lesson:** recovery takes *minutes*, not seconds. The only thing that makes an outage invisible is **already having healthy replicas somewhere else.** Redundancy first, recovery second.

---

# PART 9 — Updates and rollouts, without downtime

## 9.1 Rolling updates (the default)

When you change a Deployment's image, Kubernetes creates a **new ReplicaSet** and shifts pods over gradually.

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 25%   # how many of the desired count may be missing
    maxSurge: 25%         # how many EXTRA pods may exist temporarily
```

- `maxUnavailable: 0` + `maxSurge: 1` = safest (always at full capacity, adds one at a time, slowest)
- `maxUnavailable: 25%` + `maxSurge: 25%` = the default, a good balance
- The old ReplicaSet is kept (see `revisionHistoryLimit`) so rollback is instant

Commands:
```bash
kubectl set image deployment/hello web=myrepo/hello:v2
kubectl rollout status deployment/hello      # watch, and fail the CI job if it stalls
kubectl rollout history deployment/hello
kubectl rollout undo deployment/hello        # back one version
kubectl rollout undo deployment/hello --to-revision=3
kubectl rollout pause deployment/hello       # freeze mid-rollout to inspect
```

**Store analogy:** you're retraining cashiers on a new register. You don't send all ten to training at once (store closes). You send two, wait until they're certified *and serving customers* (readiness probe), then send two more.

## 9.2 The advanced strategies

| Strategy | How it works | Pros | Cons |
|---|---|---|---|
| **Rolling** | Replace gradually | Built-in, no extra cost, zero downtime | Both versions run at once — your API must be compatible with itself |
| **Blue/Green** | Stand up v2 fully, flip the Service selector | Instant switch, instant rollback | Double the resources during the switch |
| **Canary** | Send 5% of traffic to v2, watch, then 25%, 50%, 100% | Catches bad releases with tiny blast radius | Needs traffic-splitting (Gateway API, Istio) and good metrics |
| **Recreate** | Kill all old, then start new | Simple; required when two versions can't coexist (e.g. exclusive DB lock) | **Guaranteed downtime** |
| **Feature flags** | Ship the code dark, turn it on per user | Decouples deploy from release; fastest "rollback" | App-level work, flag debt |

**Tools:** Argo Rollouts and Flux/Flagger automate canary and blue/green with automatic rollback based on metrics.

**Golden rule:** during a rolling update, **v1 and v2 run simultaneously.** So database migrations must be backward compatible — add columns, never rename or drop in the same release. This is the "expand / migrate / contract" pattern.

## 9.3 Updating the cluster itself

Cluster upgrades happen in a strict order:

```
1. Read the release notes for EVERY version you're crossing (deprecations bite here)
2. Upgrade the CONTROL PLANE first
3. Upgrade the ADD-ONS (CNI, CoreDNS, CSI drivers, load balancer controller)
4. Upgrade the NODE GROUPS / node pools
5. Upgrade your own tooling (kubectl, Helm charts)
```

**Version skew policy:** worker nodes may be **up to 3 minor versions behind** the control plane (this widened from 2 in Kubernetes 1.28), but never ahead. `kubectl` may be one minor version either side.

**How nodes get upgraded (surge upgrade):**
1. Launch a **new** node running the new version
2. **Cordon** the old node (`kubectl cordon`) — no new pods land there
3. **Drain** it (`kubectl drain --ignore-daemonsets --delete-emptydir-data`) — evict pods gracefully, respecting PDBs
4. Pods reschedule onto healthy nodes
5. Terminate the old node
6. Repeat

**Store analogy:** remodeling one aisle at a time while the store stays open, and you *build the new aisle before you demolish the old one*.

**Upgrade best practices**
- Upgrade **one minor version at a time**. You cannot skip minor versions on the control plane.
- Never let your cluster fall out of support. Kubernetes supports only the latest 3 minor versions (~14 months each).
- Test in a non-production cluster with the same add-ons first.
- Scan for **deprecated APIs before** upgrading: `kubectl-convert`, `pluto`, or `kubent`.
- Check your PDBs won't deadlock the drain.
- Do it during a maintenance window with monitoring open.
- Keep add-ons in a version matrix — a CNI or CSI driver too old for the new Kubernetes is a very common upgrade failure.

**Recent good news:** as of **July 2026, Amazon EKS supports version rollback** — you can revert the control plane to the previous minor version within 7 days of an upgrade, preserving etcd data, workloads, and volumes. That's a real safety net that didn't exist before.

---

# PART 10 — Nodes, node groups, and pods: best practices

## 10.1 What a node group / node pool actually is

A **node group** (AWS) or **node pool** (Azure) is a set of identical nodes managed as one unit: same instance type, same OS image, same Kubernetes version, same labels and taints, one scaling configuration.

**Store analogy:** a department. Everyone in the bakery has the same training, the same equipment, and the same schedule. You hire and train the bakery as a group, not one person at a time.

## 10.2 How many node groups should you have?

**Have more than one when workloads genuinely differ:**

| Node group | Why it's separate |
|---|---|
| **system** | CoreDNS, metrics-server, CNI, ingress controller. Small, on-demand, tainted so app pods can't crowd them out. |
| **general** | Ordinary stateless apps. On-demand or a spot/on-demand mix. |
| **spot / batch** | Interruptible jobs at 60–90% discount. Tainted; only tolerant workloads land here. |
| **gpu** | Expensive; tainted so nothing else wastes them. |
| **memory-optimized** | Caches, in-memory databases. |
| **windows** | Windows containers require Windows nodes. |

**Don't** create a node group per team or per app "just in case." Every extra group is more surface to patch, upgrade, and pay for. Taints + labels + requests handle most separation inside a shared pool.

## 10.3 Node sizing: a few big or many small?

| | Fewer, larger nodes | More, smaller nodes |
|---|---|---|
| **Cost efficiency** | Better bin-packing, less per-node OS overhead | More waste (each node reserves CPU/RAM for the OS + kubelet) |
| **Blast radius** | One node dying takes many pods | One node dying takes few pods |
| **Pods per node limits** | Can hit the ~110-pod cap or the cloud's IP-per-node limits | Rarely a problem |
| **Scaling granularity** | Chunky, expensive steps | Smooth, cheap steps |
| **Startup time** | Fewer, slower events | More frequent, faster events |

**Practical rule:** medium nodes (8–16 vCPU) for general workloads, and make sure **no single node holds more than ~10% of any critical app's replicas.** Also: your **largest pod must fit on your smallest node**, or it can never schedule.

## 10.4 Autoscaling: the three kinds (know the difference)

| Autoscaler | Changes | Trigger | Store analogy |
|---|---|---|---|
| **HPA** (Horizontal Pod Autoscaler) | Number of **pods** | CPU/memory (via metrics-server), or custom metrics via KEDA/Prometheus Adapter | Open more checkout lanes |
| **VPA** (Vertical Pod Autoscaler) | **Size** of pods (requests/limits) | Observed usage over time | Give each cashier a bigger desk |
| **Cluster Autoscaler / Karpenter** | Number of **nodes** | Pods that are `Pending` because nothing fits | Hire more employees |

**Do not run HPA and VPA on the same metric for the same workload** — they fight. (VPA in "recommendation only" mode alongside HPA is fine.)

**Cluster Autoscaler vs Karpenter:**
- **Cluster Autoscaler** works within pre-defined node groups: it adds or removes nodes in an existing group. Predictable, mature.
- **Karpenter** (AWS-born, now also the engine behind Azure's Node Auto Provisioning) is **groupless**: it looks at the pending pods and provisions *exactly the right instance type* directly, in seconds, and consolidates underused nodes. Much better cost efficiency and speed, more moving parts to understand.
- **In-place pod resizing** graduated to **stable in Kubernetes 1.35** — you can now change a running pod's CPU/memory without restarting it. This makes vertical scaling far less disruptive than it used to be.

## 10.5 Node lifecycle operations you should know

```bash
kubectl cordon <node>     # stop scheduling new pods here
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data   # evict everything gracefully
kubectl uncordon <node>   # allow scheduling again
kubectl describe node <node>   # conditions, capacity, allocatable, events
kubectl get nodes -o wide --show-labels
```

**Node conditions to watch:** `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`, `NetworkUnavailable`.

**Allocatable vs capacity:** a 4 vCPU node does **not** give you 4 vCPU of pods. The OS, kubelet, and eviction thresholds reserve a chunk. `kubectl describe node` shows `Allocatable` — that's your real budget. On small nodes this overhead can be 15–25%, which is a strong argument against tiny nodes.

## 10.6 Node group best practices checklist

- ✅ Span **at least 3 availability zones**
- ✅ Use **managed** node groups (AWS) / AKS-managed pools, not hand-built VMs
- ✅ Enable **auto-repair** (both EKS and AKS can detect and replace unhealthy nodes)
- ✅ Use the latest **optimized OS image** (Amazon Linux 2023 or Bottlerocket; Ubuntu 24.04 or Azure Linux 3.0). *Amazon Linux 2 is gone as of EKS 1.34; Azure Linux 2.0 ended support in 2025.*
- ✅ Taint the **system** pool; put system add-ons there with tolerations
- ✅ Mix **spot and on-demand** with a floor of on-demand capacity for baseline traffic
- ✅ Set **maxSurge** on node group updates so upgrades add capacity before removing it
- ✅ Label nodes meaningfully (`workload-type`, `capacity-type`) and schedule with those labels
- ✅ Enable **node auto-repair** and consider **maintenance windows** so churn happens at 3 a.m.
- ✅ Keep node OS images patched monthly — node image upgrades are separate from Kubernetes version upgrades

## 10.7 Pod best practices checklist

- ✅ Set requests and limits on **every** container
- ✅ readinessProbe on everything; livenessProbe carefully; startupProbe for slow starters
- ✅ Run as **non-root**, read-only root filesystem, drop all Linux capabilities
- ✅ Pin image tags to a digest or a specific version — **never `:latest`** in production
- ✅ `terminationGracePeriodSeconds` + a `preStop` sleep for clean shutdowns
- ✅ One concern per container; use sidecars/init containers rather than shell scripts that start three daemons
- ✅ Send logs to **stdout/stderr**, not files inside the container
- ✅ Use a ServiceAccount with cloud identity (IRSA / EKS Pod Identity / Azure Workload Identity) instead of storing cloud keys in Secrets
- ✅ Apply **Pod Security Admission** (`restricted` profile) at the namespace level — PodSecurityPolicy was removed back in 1.25

---

# PART 11 — Monitoring and observability

## 11.1 The three pillars, plus events

| Pillar | Question it answers | Tool | Store analogy |
|---|---|---|---|
| **Metrics** | "How many? How fast? How much?" | Prometheus, Azure Monitor, CloudWatch | The sales counter and the scale |
| **Logs** | "What exactly happened at 3:04?" | Loki, CloudWatch Logs, Azure Log Analytics, Elastic | The security camera footage |
| **Traces** | "Where did this one request spend its time?" | OpenTelemetry + Jaeger/Tempo/X-Ray/App Insights | Following one customer through the whole store |
| **Events** | "What did Kubernetes itself decide to do?" | `kubectl get events --sort-by=.lastTimestamp` | The manager's shift log |

**Beginner tip:** 80% of "why won't my pod start" questions are answered by two commands:
```bash
kubectl describe pod <name>          # look at the Events section at the bottom
kubectl logs <name> --previous       # logs from the container that just crashed
```

## 11.2 The standard monitoring stack

```
kubelet/cAdvisor ─┐
kube-state-metrics ├─→ Prometheus ─→ Grafana (dashboards)
node-exporter     ─┘        └──────→ Alertmanager (pages a human)
```

- **cAdvisor** (inside kubelet) — per-container CPU, memory, disk, network
- **node-exporter** (DaemonSet) — the node's own OS metrics
- **kube-state-metrics** — the *state of objects*: how many replicas are desired vs ready, is this deployment stuck, is this PVC pending. Different from resource usage; you need both.
- **Prometheus** — scrapes and stores time series
- **Grafana** — draws it
- **Alertmanager** — routes alerts, deduplicates, silences during maintenance

The easy install is `kube-prometheus-stack` (Helm) which bundles all of it. On EKS there's **Amazon Managed Service for Prometheus + Managed Grafana + CloudWatch Container Insights**; on AKS there's **Azure Monitor managed service for Prometheus + Azure Managed Grafana + Container Insights**, all of which remove the "who monitors the monitoring" problem.

## 11.3 What to actually alert on

Alert on **symptoms users feel**, not on every twitch:

| Alert | Why |
|---|---|
| Error rate > X% for 5 min | Users are seeing failures |
| p95 latency > SLO | Users are waiting |
| Pods `CrashLoopBackOff` | Something is fundamentally broken |
| Deployment has fewer ready replicas than desired, for > 10 min | Rollout stuck or capacity gone |
| Pods `Pending` > 10 min | Cluster is out of room or a scheduling rule is impossible |
| Node `NotReady` | Lost capacity |
| PersistentVolume > 85% full | Silent killer; a full disk breaks everything at once |
| Certificate expiring in < 14 days | The classic 2 a.m. outage |
| **Kubernetes version approaching end of support** | Yes, really — put it on a calendar |

**Anti-pattern:** alerting on high CPU. High CPU is usually *fine* — that's what you're paying for. Alert on the consequence, not the number.

## 11.4 The four golden signals (from Google SRE)

1. **Latency** — how long requests take (track failed requests separately; a fast 500 is still a failure)
2. **Traffic** — how much demand
3. **Errors** — rate of failures
4. **Saturation** — how full the system is (the one metrics-server helps with)

## 11.5 Monitoring best practices

- **Label everything consistently** (`app`, `version`, `team`, `env`) — dashboards and alerts are only as good as your labels
- **Set an SLO** ("99.9% of requests succeed under 300ms") and alert on burning through the error budget, not on raw thresholds
- **Retain enough history** to see week-over-week patterns (metrics-server gives you none — this is Prometheus's job)
- **Monitor the monitoring** — a dead Prometheus is a silent outage
- **Structured logs (JSON)** with a request ID that also appears in traces
- **Don't log secrets.** Ever.
- Use **CloudWatch Container Insights** or **AKS Container Insights** for a zero-effort baseline, then add Prometheus for depth

---

# PART 12 — Amazon EKS (Elastic Kubernetes Service)

## 12.1 Background

AWS launched EKS in **2018**, after initially betting on its own ECS. EKS runs **upstream-conformant Kubernetes** — no forks, no proprietary API — so your YAML is portable. AWS runs the control plane; you run (or delegate) the data plane.

## 12.2 Architecture

**Control plane (AWS-managed, you never see the pods):**
- Runs in an AWS-owned VPC, dedicated per cluster
- **etcd spans 3 availability zones**; at least 2 API server instances in separate AZs
- Reached through an EKS-provided endpoint backed by a Network Load Balancer
- AWS patches, scales, and heals it. **SLA: 99.95%** for the control plane endpoint
- Flat cost: **$0.10/hour per cluster** (~$73/month), regardless of size

**Data plane (your account, your bill):** four options.

| Option | What it is | Pros | Cons |
|---|---|---|---|
| **EKS Auto Mode** *(recommended default since late 2024)* | AWS manages compute, storage, and networking end to end using Karpenter under the hood | No node groups to design, no Karpenter/CNI/EBS-CSI/LB-controller to install, automatic OS patching, ephemeral nodes replaced on a schedule for security, ~80% less ops work | ~40% premium per vCPU on top of EC2; no custom AMIs or Bottlerocket; limited GPU flexibility; **no Windows nodes** |
| **Managed node groups** | AWS creates and lifecycle-manages EC2 Auto Scaling Groups for you | Handles graceful drains during upgrades, integrates with Cluster Autoscaler, supports custom launch templates | You still choose instance types and sizes; you own capacity planning |
| **Karpenter (self-managed)** | Groupless, just-in-time node provisioning | Best-in-class cost optimization and speed; picks the ideal instance from hundreds | You install, configure, and upgrade Karpenter yourself |
| **Fargate** | Serverless: one micro-VM per pod | No nodes at all, strong isolation, per-second billing | No DaemonSets, no privileged pods, limited sizes, higher unit cost, port 10250 reserved |
| **Self-managed / Hybrid Nodes / Outposts** | Your own EC2, or on-prem hardware joined to the EKS control plane | Maximum control; on-prem and edge | You own everything: AMIs, bootstrapping, patching, upgrades |

## 12.3 EKS add-ons

Rather than `kubectl apply`-ing YAML you found on a blog, EKS **add-ons** are versioned, AWS-validated components you manage through the EKS API:

- **AWS-owned:** VPC CNI, kube-proxy, CoreDNS, EBS CSI driver, EFS CSI driver, Pod Identity Agent, Node Monitoring Agent, Mountpoint for S3 CSI
- **Community add-ons:** metrics-server, kube-state-metrics, cert-manager, prometheus-node-exporter, fluent-bit, external-dns (AWS packages and lifecycle-manages them; the software itself is community-supported)
- **Marketplace add-ons** from third-party vendors

```bash
aws eks describe-addon-versions --addon-name metrics-server
aws eks create-addon --cluster-name my-cluster --addon-name metrics-server
```

## 12.4 EKS-specific things you must understand

**Identity: IRSA vs EKS Pod Identity**
Your pods often need AWS permissions (read S3, write DynamoDB). Never use static access keys.
- **IRSA** (IAM Roles for Service Accounts, 2019) — uses an OIDC provider; the ServiceAccount is annotated with a role ARN. Works everywhere, including outside EKS. More setup, trust-policy editing per cluster.
- **EKS Pod Identity** (2023, now the recommended default) — a simple association between a ServiceAccount and an IAM role via the EKS API, plus the Pod Identity Agent. No OIDC provider per cluster, roles are reusable across clusters, far less YAML.

**Networking: the VPC CNI and the IP problem**
The **Amazon VPC CNI** gives every pod a **real VPC IP address**. That's beautiful (security groups work on pods, no overlay overhead) and dangerous: each instance type supports a limited number of ENIs and IPs, so **you can run out of subnet IPs before you run out of CPU.** Mitigations: prefix delegation (`ENABLE_PREFIX_DELEGATION=true`), large `/16`-ish subnets, or custom networking with secondary CIDRs. Alternatives: Cilium or Calico in overlay mode.

**Load balancing**
- Auto Mode: `Service type: LoadBalancer` → NLB automatically (`loadBalancerClass: eks.amazonaws.com/nlb` is the default); `Ingress` with `ingressClassName` pointing at controller `eks.amazonaws.com/alb` → ALB. No controller install needed.
- Classic mode: install the **AWS Load Balancer Controller** yourself for the same result.

**Version support**
- **Standard support:** the 3 newest versions (right now **1.34, 1.35, 1.36**), ~14 months each
- **Extended support:** an extra ~12 months at a **higher per-cluster hourly price** — a safety valve, not a plan
- **Auto upgrade:** clusters left on an unsupported version get force-upgraded
- **NEW (July 2026): version rollback** — revert the control plane to the prior minor version within 7 days, with automated readiness checks (API compatibility, version skew, add-on compatibility). For Auto Mode clusters, EKS rolls back worker nodes first, honoring your disruption controls.

**Resilience extras**
- **ARC zonal shift / autoshift**: as of July 2026, EKS Auto Mode clusters get Application Recovery Controller zonal shift support at no extra cost — traffic is automatically moved away from an impaired availability zone without you setting flags or managing Karpenter versions.

## 12.5 EKS pros and cons

**Pros**
- Deepest integration with the rest of AWS (IAM, VPC, ELB, CloudWatch, KMS, Secrets Manager)
- Upstream-conformant — genuinely portable workloads
- Auto Mode removes most day-2 operations
- Karpenter is the best node autoscaler in the industry
- Huge ecosystem, EKS Blueprints, extensive documentation

**Cons**
- You pay **$0.10/hr per cluster** even for a tiny dev cluster (AKS's free tier does not)
- The VPC CNI IP-exhaustion problem catches almost every team once
- More assembly required in classic mode: CNI, CSI, LB controller, autoscaler, metrics-server are all separate decisions
- IAM + Kubernetes RBAC is a genuinely steep learning curve
- Extended support costs meaningfully more

## 12.6 EKS best practices

1. **Default to EKS Auto Mode** unless you need Windows, custom AMIs, or exotic GPU setups.
2. Use **EKS Pod Identity** over IRSA for new clusters.
3. Managed node groups (not self-managed EC2) if you're not using Auto Mode.
4. **Private API endpoint** + bastion/SSM, or at minimum a CIDR allow-list.
5. Turn on **control plane logging** (api, audit, authenticator, controllerManager, scheduler) → CloudWatch.
6. Encrypt secrets at rest with **KMS**.
7. Plan for IPs: **prefix delegation on** and roomy subnets, from day one.
8. Spread node groups across **3 AZs**; use `topologySpreadConstraints`.
9. Use **Spot with capacity-optimized allocation** for interruptible work, on-demand for baseline.
10. Upgrade **at least twice a year**; use **EKS upgrade insights** to find deprecated APIs before you start.
11. Install **metrics-server as a community add-on** — it's not there by default.
12. Migrate off **Ingress NGINX** (retired March 2026) toward Gateway API or the AWS LB Controller / Auto Mode ALB path.

---

# PART 13 — Azure AKS (Azure Kubernetes Service)

## 13.1 Background

Microsoft launched **ACS** in 2015 (which could run Kubernetes, DC/OS, or Swarm), then **AKS** in **2018** as a dedicated managed Kubernetes service. Azure's strategic bet was "make the control plane free and make it easy" — and AKS has consistently been the fastest of the big three to ship new Kubernetes minor versions.

## 13.2 Architecture

**Control plane (Microsoft-managed):**
- Runs in a Microsoft-managed subscription; you never see or pay for the VMs
- **Free tier**: control plane is free, no financial SLA (99.9% uptime *target* with AZs)
- **Standard tier**: ~$0.10/hour, adds a financial **99.95% SLA** (with AZs) and supports far more nodes — use this for production
- **Premium tier**: Standard plus **Long Term Support (LTS)** — two years of support on a version instead of one

**Data plane — node pools:**

| Node pool type | Purpose |
|---|---|
| **System node pool** | Required. Runs CoreDNS, metrics-server, tunnelfront, etc. Must be Linux, minimum sizes apply. Taint it (`CriticalAddonsOnly`) so app pods stay out. |
| **User node pool** | Your applications. Can scale to zero. Linux or Windows. |
| **Spot node pool** | Deeply discounted, evictable capacity for batch/interruptible work. |

## 13.3 The three AKS "flavors" (this is the key 2026 decision)

| Flavor | What it is | Best for |
|---|---|---|
| **AKS Automatic** *(Microsoft's recommended production default)* | An opinionated, production-ready cluster: Node Auto Provisioning, auto-upgrades, managed Prometheus + Grafana + Container Insights, Azure RBAC, workload identity, deployment safeguards, and **SLA-backed pod readiness**, all preconfigured | Most production teams; the "just give me a good cluster" button |
| **AKS Standard** | You choose node pools, add-ons, networking, upgrade channels | Teams that need specific control |
| **Node Auto Provisioning (NAP)** | Karpenter-for-Azure (the `karpenter-provider-azure` project). Provisions right-sized VMs on demand instead of pre-defined pools. Included in Automatic; available on Standard | Variable workloads, cost optimization |

Recent NAP improvements (2026): the **Balanced consolidation policy** to reduce node churn, in-VM spot rebalancing signals for better spot eviction handling, and LocalDNS `Preferred` mode by default on Kubernetes 1.36+ for faster, more resilient DNS.

## 13.4 AKS-specific things you must understand

**Networking options**

| Mode | How it works | Notes |
|---|---|---|
| **Azure CNI Overlay** *(recommended default)* | Pods get IPs from a private overlay CIDR, not the VNet | Solves IP exhaustion; scales to very large clusters |
| **Azure CNI (node subnet)** | Every pod gets a real VNet IP | Direct VNet routing, but IP-hungry |
| **Azure CNI Powered by Cilium** | Overlay/VNet plus eBPF dataplane | Best performance, network policy, and observability (Hubble/Retina) |
| **kubenet** | Legacy basic networking | Being phased out; don't start here |

**Identity**
- **Microsoft Entra ID integration** for human access + **Azure RBAC for Kubernetes** so cluster permissions live in Azure RBAC, not just Kubernetes RBAC
- **Workload Identity** (the successor to the deprecated pod-managed identity) for pods that need Azure permissions — the equivalent of EKS Pod Identity
- **Managed identity** for the cluster itself to talk to Azure APIs

**Add-ons and extensions (managed by Microsoft)**
metrics-server (always on), CoreDNS, Azure Monitor **managed Prometheus** + Container Insights, **KEDA** (event-driven autoscaling), **Istio-based service mesh add-on**, **App Routing** (managed ingress — now with Gateway API, ExternalDNS, and Key Vault TLS support), Azure Policy/Gatekeeper, Key Vault Secrets Provider, GitOps (Flux), AI Toolchain Operator (KAITO) for running models, Image Cleaner, Backup for AKS.

**Upgrades — AKS's strongest feature**
- **Auto-upgrade channels:** `none`, `patch`, `stable` (N-1 minor), `rapid` (latest), `node-image`
- **Planned maintenance windows** so upgrades only happen when you say (`aksManagedAutoUpgradeSchedule`)
- **Node image auto-upgrade** separate from Kubernetes version upgrade
- **Node surge** (`--max-surge`) to add capacity before draining
- **Node Disruption Policy** (public preview, 2026) — control exactly when reimage-triggering operations may run
- **Fleet Manager** for orchestrating upgrades across many clusters in a safe, staged order

**Version support (as of August 2026)**

| Version | AKS GA | End of life | LTS end |
|---|---|---|---|
| 1.34 | Nov 2025 | Nov 2026 | Nov 2027 |
| 1.35 | Mar 2026 | Mar 2027 | Mar 2028 |
| **1.36** | **Jun 2026** | Jun 2027 | Jun 2028 |
| 1.37 | Oct 2026 (planned) | Oct 2027 | Oct 2028 |

AKS supports **N, N-1, N-2** (12 months), plus **platform support** at N-3 (Azure-level help only, no Kubernetes-level support), plus **LTS** on the Premium tier for a second year. You may skip minor versions when jumping LTS→LTS, but on standard supported versions you must go **one minor at a time**. Portal/CLI defaults to **N-1**.

## 13.5 AKS pros and cons

**Pros**
- **Free control plane tier** — a real advantage for dev/test and small teams
- Fastest to GA new Kubernetes versions among the big clouds
- **AKS Automatic** is the easiest good-production-cluster path in the industry right now
- Best-in-class upgrade tooling: channels, maintenance windows, Fleet Manager, LTS
- Deep managed add-on catalog (Prometheus, Grafana, Istio, KEDA, GitOps) that you'd otherwise assemble yourself
- Strong Windows container support (Windows Server 2025 GA in 2026)

**Cons**
- Free tier has **no SLA** — production means paying for Standard anyway
- More Azure-specific abstractions to learn (resource groups, the auto-created `MC_*` node resource group, VNet integration)
- Fewer node/instance shapes than EC2 in some regions
- Managed add-ons update on Microsoft's schedule; you get less version control
- Some newer capabilities (NAP, Node Disruption Policy) reach GA later than their AWS equivalents

## 13.6 AKS best practices

1. **Use AKS Automatic** for new production clusters unless you have a specific reason not to.
2. **Standard or Premium tier** for anything production — the free tier has no SLA.
3. **Enable availability zones at cluster creation.** You cannot add them later.
4. **System node pool tainted** with `CriticalAddonsOnly=true:NoSchedule`; apps in user pools.
5. **Azure CNI Overlay** (or Powered by Cilium) — avoid IP exhaustion and kubenet.
6. **Auto-upgrade channel `stable` + a maintenance window.** This is the single highest-value setting in AKS.
7. **Workload Identity** for pod→Azure auth; **Entra ID + Azure RBAC** for humans.
8. Turn on **Azure Monitor managed Prometheus + Container Insights** and **Defender for Containers**.
9. Use **KEDA** for event-driven scaling (queue depth, Kafka lag) instead of CPU-only HPA.
10. Enable **Deployment Safeguards** (Azure Policy) to enforce probes, limits, and non-root automatically.
11. Consider **LTS on Premium** if you genuinely cannot upgrade yearly — but treat it as a bridge, not a strategy.
12. Migrate off **Ingress NGINX** to App Routing with Gateway API / Istio.

---

# PART 14 — EKS vs AKS side by side

| Topic | Amazon EKS | Azure AKS |
|---|---|---|
| Launched | 2018 | 2018 (ACS 2015) |
| Control plane cost | $0.10/hr per cluster | **Free tier**, or $0.10/hr Standard (with SLA), Premium for LTS |
| Control plane SLA | 99.95% | 99.95% on Standard w/ AZs; none on Free |
| Versions supported | 3 (1.34–1.36) + paid extended support | 3 (1.34–1.36) + platform support N-3 + LTS (2 yrs, Premium) |
| Speed to new versions | Fast | Usually fastest |
| "Easy mode" | **EKS Auto Mode** | **AKS Automatic** |
| Node autoscaling | Cluster Autoscaler, **Karpenter** (native in Auto Mode) | Cluster Autoscaler, **Node Auto Provisioning** (Karpenter for Azure) |
| Default CNI | Amazon VPC CNI (real VPC IPs) | Azure CNI Overlay / Powered by Cilium |
| Pod→cloud identity | IRSA, **EKS Pod Identity** | **Workload Identity** |
| metrics-server | **Not installed** — add as a community add-on | **Installed and managed** |
| Managed Prometheus | Amazon Managed Prometheus + Managed Grafana | Azure Monitor managed Prometheus + Azure Managed Grafana |
| Serverless pods | Fargate | Virtual Nodes (ACI) |
| Upgrade safety net | **Version rollback within 7 days** (new, July 2026) | Auto-upgrade channels, maintenance windows, Fleet Manager, LTS |
| Windows nodes | Yes (not on Auto Mode) | Yes (Windows Server 2025 GA) |
| Best fit | Teams already deep in AWS; maximum instance choice and cost tuning | Teams wanting the lowest-effort, well-integrated production cluster; Microsoft shops |

**The honest summary:** both run the same upstream Kubernetes. Your workloads are portable. Pick the cloud your organization already uses, and pick the "easy mode" (Auto Mode / Automatic) unless you can name a specific reason not to.

---

# PART 15 — TUTORIAL A: Hello World on Amazon EKS

**Time:** ~30 minutes (cluster creation is 10–15 of them)
**Cost:** roughly $0.10/hr for the control plane + EC2 + one NLB. **Delete it when done.**

## A.0 Prerequisites

```bash
aws --version        # need AWS CLI v2
eksctl version       # need a recent version that supports --enable-auto-mode
kubectl version --client
aws sts get-caller-identity     # confirms you're logged in
```

Install links: AWS CLI v2 (`aws configure`), `eksctl` (https://eksctl.io), `kubectl`.
You need IAM permissions to create EKS clusters, VPCs, IAM roles, and EC2 instances.

## A.1 Create the cluster (Auto Mode — recommended)

```bash
export CLUSTER=hello-eks
export REGION=us-east-1

eksctl create cluster \
  --name $CLUSTER \
  --region $REGION \
  --enable-auto-mode
```

This creates a VPC across 3 availability zones, the EKS control plane, IAM roles, and enables Auto Mode. **It takes 10–15 minutes.** Go get a snack.

<details>
<summary><b>Alternative: classic managed node group (click to expand)</b></summary>

```bash
eksctl create cluster \
  --name $CLUSTER \
  --region $REGION \
  --version 1.36 \
  --nodegroup-name ng-general \
  --node-type t3.medium \
  --nodes 3 --nodes-min 3 --nodes-max 6 \
  --managed \
  --node-volume-size 30 \
  --with-oidc
```
With this path you must also install the AWS Load Balancer Controller yourself before `Service type: LoadBalancer` produces an NLB with modern features.
</details>

<details>
<summary><b>Alternative: declarative ClusterConfig file (better for real life)</b></summary>

`cluster.yaml`:
```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: hello-eks
  region: us-east-1
  version: "1.36"
autoModeConfig:
  enabled: true
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```
```bash
eksctl create cluster -f cluster.yaml
```
Keeping cluster config in Git is a best practice — it's reviewable, repeatable, and diff-able.
</details>

## A.2 Confirm you're connected

```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes
kubectl get pods -A
```

**Don't panic if `kubectl get nodes` shows nothing on Auto Mode.** Auto Mode is groupless — it creates nodes only when there are pods that need them. Deploy something and nodes appear within ~60 seconds.

## A.3 Deploy Hello World

`hello-eks.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hello
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  namespace: hello
spec:
  replicas: 3
  selector:
    matchLabels: { app: hello }
  template:
    metadata:
      labels: { app: hello }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: hello }
      containers:
        - name: web
          image: nginxdemos/hello:plain-text
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 3
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: hello
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
spec:
  type: LoadBalancer
  # On Auto Mode this is the default and may be omitted:
  loadBalancerClass: eks.amazonaws.com/nlb
  selector: { app: hello }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: hello-pdb
  namespace: hello
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: hello }
```

```bash
kubectl apply -f hello-eks.yaml
kubectl -n hello get pods -w      # nodes appear, then pods start
```

## A.4 Reach it from the internet

```bash
kubectl -n hello get svc hello
```

Wait 2–4 minutes for `EXTERNAL-IP` to become a hostname ending in `elb.amazonaws.com`, then:

```bash
export URL=$(kubectl -n hello get svc hello -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$URL
```

You'll see the serving pod's name. Open it in a browser and refresh — the name rotates. **You have a live website on Kubernetes.**

<details>
<summary><b>Optional: use an ALB + Ingress instead (better for HTTP)</b></summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: alb
spec:
  controller: eks.amazonaws.com/alb
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
  namespace: hello
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port: { number: 80 }
```
Change the Service back to `type: ClusterIP` first. Requires correctly tagged public/private subnets — `eksctl`-created VPCs already have them.
</details>

## A.5 Add the metrics server and autoscale

EKS does **not** ship metrics-server. Install it as a community add-on:

```bash
aws eks create-addon --cluster-name $CLUSTER --addon-name metrics-server --region $REGION
aws eks describe-addon --cluster-name $CLUSTER --addon-name metrics-server --region $REGION \
  --query 'addon.status'
```

Then:
```bash
kubectl top nodes
kubectl top pods -n hello

kubectl -n hello autoscale deployment hello --cpu-percent=50 --min=3 --max=15
kubectl -n hello get hpa -w
```

Generate load and watch both pods **and nodes** scale (Auto Mode/Karpenter will add capacity):
```bash
kubectl -n hello run load --rm -it --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://hello; done"
```

## A.6 Do a rolling update

```bash
kubectl -n hello set image deployment/hello web=nginxdemos/hello:plain-text
kubectl -n hello rollout status deployment/hello
kubectl -n hello rollout undo deployment/hello
```

Run `curl http://$URL` in a loop during the rollout — you should see **zero failures**.

## A.7 Clean up (do not skip this)

```bash
kubectl delete -f hello-eks.yaml       # deletes the Service FIRST so the NLB is removed
sleep 60
eksctl delete cluster --name $CLUSTER --region $REGION
```

Then check the AWS console for orphaned load balancers, EBS volumes, and Elastic IPs. **Deleting the cluster before deleting LoadBalancer Services is the #1 way people leave money on fire.**

---

# PART 16 — TUTORIAL B: Hello World on Azure AKS

**Time:** ~25 minutes
**Cost:** free-tier control plane + 2 VMs + one public load balancer. **Delete the resource group when done.**

## B.0 Prerequisites

```bash
az version
az login
az account set --subscription "<your-subscription-name-or-id>"
az aks install-cli        # installs kubectl and kubelogin if you need them
```

## B.1 Create a resource group

```bash
export RG=rg-hello-aks
export CLUSTER=hello-aks
export LOCATION=eastus

az group create --name $RG --location $LOCATION
```

*A resource group is a folder in Azure. Deleting it deletes everything inside — which makes cleanup trivial.*

## B.2 Create the cluster

**Option 1 — AKS Automatic (recommended for production-shaped clusters):**
```bash
az aks create \
  --resource-group $RG \
  --name $CLUSTER \
  --sku automatic \
  --generate-ssh-keys
```
Automatic gives you Node Auto Provisioning, auto-upgrades, managed Prometheus/Grafana, Azure RBAC, and deployment safeguards out of the box. Note: Automatic enforces stricter defaults (Azure RBAC, deployment safeguards), so some casual YAML may be rejected until you add probes/limits — which is the point.

**Option 2 — AKS Standard (more explicit, easier for a first tutorial):**
```bash
az aks create \
  --resource-group $RG \
  --name $CLUSTER \
  --tier standard \
  --node-count 3 \
  --node-vm-size Standard_D2s_v5 \
  --zones 1 2 3 \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --enable-managed-identity \
  --enable-cluster-autoscaler --min-count 3 --max-count 6 \
  --auto-upgrade-channel stable \
  --node-os-upgrade-channel NodeImage \
  --generate-ssh-keys
```

Line by line, why each flag matters:
- `--tier standard` → the 99.95% financial SLA (the free tier has none)
- `--zones 1 2 3` → spread across availability zones. **You cannot add this later.**
- `--network-plugin-mode overlay` → Azure CNI Overlay, so you don't burn VNet IPs
- `--enable-cluster-autoscaler` → nodes grow with demand
- `--auto-upgrade-channel stable` → stay in support automatically (pair with a maintenance window)

Takes ~5–10 minutes.

## B.3 Connect

```bash
az aks get-credentials --resource-group $RG --name $CLUSTER
kubectl get nodes
kubectl get pods -A
```

Notice `metrics-server` is already running in `kube-system` — AKS manages it for you.

```bash
kubectl top nodes     # works immediately, no install needed
```

## B.4 Deploy Hello World

`hello-aks.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: hello
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
  namespace: hello
spec:
  replicas: 3
  selector:
    matchLabels: { app: hello }
  template:
    metadata:
      labels: { app: hello }
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: hello }
      containers:
        - name: web
          image: nginxdemos/hello:plain-text
          ports: [{ containerPort: 80 }]
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 256Mi }
          readinessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /, port: 80 }
            initialDelaySeconds: 15
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: false
            capabilities: { drop: ["ALL"] }
---
apiVersion: v1
kind: Service
metadata:
  name: hello
  namespace: hello
spec:
  type: LoadBalancer
  selector: { app: hello }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: hello-pdb
  namespace: hello
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: hello }
```

```bash
kubectl apply -f hello-aks.yaml
kubectl -n hello get pods -o wide
kubectl -n hello get svc hello -w        # wait for EXTERNAL-IP
```

Then:
```bash
export IP=$(kubectl -n hello get svc hello -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$IP
```

Azure gives you a real public **IP address** (AWS gives a hostname). Open it in a browser.

## B.5 Autoscale

```bash
kubectl -n hello autoscale deployment hello --cpu-percent=50 --min=3 --max=15
kubectl -n hello get hpa

kubectl -n hello run load --rm -it --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://hello; done"
```

Watch in another terminal:
```bash
kubectl -n hello get hpa -w
kubectl get nodes -w        # cluster autoscaler / NAP adds nodes if pods go Pending
```

## B.6 Managed ingress (optional but recommended over per-app load balancers)

```bash
az aks approuting enable --resource-group $RG --name $CLUSTER
```

Then change the Service to `ClusterIP` and add:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
  namespace: hello
spec:
  ingressClassName: webapprouting.kubernetes.azure.com
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port: { number: 80 }
```
App Routing now also supports the **Gateway API** with Key Vault TLS certificates and ExternalDNS — the recommended direction now that Ingress NGINX is retired upstream.

## B.7 Try an upgrade (optional)

```bash
az aks get-upgrades --resource-group $RG --name $CLUSTER --output table
az aks upgrade --resource-group $RG --name $CLUSTER --kubernetes-version 1.36.x --control-plane-only
az aks nodepool upgrade --resource-group $RG --cluster-name $CLUSTER --name nodepool1 --kubernetes-version 1.36.x --max-surge 33%
```
Control plane first, then node pools — exactly the order from Part 9.

## B.8 Clean up

```bash
az group delete --name $RG --yes --no-wait
```

One command deletes the cluster, the node VMs, the load balancer, the public IP, and the auto-created `MC_*` resource group. This is genuinely nicer than AWS cleanup.

---

# PART 17 — TUTORIAL C: A Kafka message cluster on Kubernetes (EKS or AKS)

## C.0 What Kafka is, in middle-school terms

Imagine the grocery store's departments need to tell each other things: "we just sold the last gallon of milk," "a customer returned a broken egg carton," "the freezer hit 40°F."

**The bad way:** every department calls every other department directly. Ten departments = 45 phone lines. Add one department and everything breaks.

**The Kafka way:** there's a wall of labeled mailboxes in the back room. Dairy drops a note in the `sales` mailbox. Anyone who cares — inventory, accounting, the reorder robot — reads from that mailbox at their own pace. Nobody has to know who else is listening. Notes stay in the box for a set number of days, so a department that was on break can catch up.

**The vocabulary:**

| Kafka word | Mailbox meaning |
|---|---|
| **Topic** | One labeled mailbox (`sales`, `temperature-alerts`) |
| **Partition** | The mailbox is split into several slots so many people can read at once — this is how Kafka scales |
| **Producer** | Anyone dropping notes in |
| **Consumer** | Anyone reading notes out |
| **Consumer group** | A team splitting the reading work; each note goes to exactly one teammate |
| **Offset** | Your bookmark: "I've read up to note #4,201" |
| **Broker** | One Kafka server holding some mailboxes |
| **Replication factor** | How many copies of each note exist on different brokers (3 = survives 2 broker failures) |
| **Controller (KRaft)** | The brokers that keep the master list of who owns what |
| **min.insync.replicas** | How many copies must confirm before a write counts as safe |

## C.1 Background: why this got much simpler

Kafka used to require **Apache ZooKeeper** — a whole separate cluster just to track metadata. That meant two distributed systems to operate, two failure modes, and painful upgrades.

**KRaft** (Kafka Raft) moved metadata management *inside* Kafka itself. ZooKeeper was deprecated in Kafka 3.5 and **removed entirely in Kafka 4.0 (2025)**. Today there is no ZooKeeper — just Kafka nodes with a `controller` role, a `broker` role, or both.

**Strimzi** is the CNCF operator that runs Kafka on Kubernetes. You describe the cluster you want in YAML; Strimzi's controllers build and maintain it. Current Strimzi (1.x, 2026) is **KRaft-only**, requires **KafkaNodePool** resources, and serves the stable **`kafka.strimzi.io/v1`** API. A great deal of published material still shows `v1beta2` and a `zookeeper:` section — **that material is out of date.**

## C.2 Prerequisites

A working EKS or AKS cluster from Tutorial A or B, with at least 3 nodes and ~6 vCPU / 12 GiB total free.

Check your StorageClasses:
```bash
kubectl get storageclass
```
- **AKS** gives you `managed-csi` (standard SSD) and `managed-csi-premium`.
- **EKS classic** usually has `gp2`; add `gp3` if you want it.
- **EKS Auto Mode** ships no default StorageClass — create one:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.eks.amazonaws.com
volumeBindingMode: WaitForFirstConsumer     # critical: creates the disk in the pod's zone
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```
```bash
kubectl apply -f gp3-storageclass.yaml
```

## C.3 Install the Strimzi operator

```bash
kubectl create namespace kafka
kubectl create -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
kubectl -n kafka get pod -l name=strimzi-cluster-operator -w
```

Verify which API version your operator serves:
```bash
kubectl api-resources | grep kafka.strimzi.io
```
If you see `kafka.strimzi.io/v1`, use the manifests below as written. If you see only `v1beta2`, your operator is older — change `apiVersion` accordingly.

<details>
<summary><b>Helm alternative</b></summary>

```bash
helm repo add strimzi https://strimzi.io/charts/
helm repo update
helm install strimzi strimzi/strimzi-kafka-operator -n kafka --create-namespace
```
</details>

## C.4 Create the Kafka cluster

`kafka-cluster.yaml` — a production-shaped 3-node cluster with dual-role nodes:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 3
  roles:
    - controller          # manages cluster metadata (KRaft)
    - broker              # stores and serves messages
  resources:
    requests: { cpu: "500m", memory: 2Gi }
    limits:   { cpu: "2",    memory: 2Gi }
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 20Gi
        deleteClaim: false          # keep data if the cluster is deleted
        class: gp3                  # AKS: managed-csi
  template:
    pod:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              strimzi.io/cluster: my-cluster
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka
spec:
  kafka:
    listeners:
      - name: plain            # inside the cluster, no TLS — fine for a tutorial
        port: 9092
        type: internal
        tls: false
      - name: tls              # inside the cluster, encrypted
        port: 9093
        type: internal
        tls: true
    config:
      # These four settings ARE your durability guarantee. Read them carefully.
      default.replication.factor: 3       # 3 copies of every message
      min.insync.replicas: 2              # at least 2 must confirm a write
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
  entityOperator:
    topicOperator: {}          # lets you manage topics as Kubernetes objects
    userOperator: {}           # lets you manage users/ACLs as Kubernetes objects
```

```bash
kubectl apply -f kafka-cluster.yaml
kubectl -n kafka get pods -w
```

Wait for `my-cluster-dual-role-0/1/2` and `my-cluster-entity-operator` to be `Running` (3–5 minutes; the volumes have to be provisioned).

```bash
kubectl -n kafka get kafka my-cluster -o jsonpath='{.status.conditions}' | jq
kubectl -n kafka get pvc
kubectl -n kafka get svc
```

Note the **bootstrap service**: `my-cluster-kafka-bootstrap:9092`. That's the address every client uses. (Strimzi also creates a **headless** service so clients can reach individual brokers directly — exactly the StatefulSet pattern from Part 6.)

## C.5 Create a topic

`my-topic.yaml`:
```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: my-topic
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3          # 3 slots → up to 3 consumers in a group can read in parallel
  replicas: 3            # 3 copies → survives 2 broker failures
  config:
    retention.ms: 604800000      # keep messages 7 days
    segment.bytes: 1073741824
```
```bash
kubectl apply -f my-topic.yaml
kubectl -n kafka get kafkatopic
```

**This is the beautiful part:** a Kafka topic is now a Kubernetes object. It lives in Git, gets code-reviewed, and is created by the same `kubectl apply` as everything else.

## C.6 Send and receive messages

First, grab the exact Kafka image your cluster is running, so versions match:

```bash
export KAFKA_IMAGE=$(kubectl -n kafka get pod my-cluster-dual-role-0 \
  -o jsonpath='{.spec.containers[0].image}')
echo $KAFKA_IMAGE
```

**Terminal 1 — the consumer (reads the mailbox):**
```bash
kubectl -n kafka run kafka-consumer -ti --image=$KAFKA_IMAGE --rm=true --restart=Never -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic --from-beginning
```

**Terminal 2 — the producer (drops notes in):**
```bash
kubectl -n kafka run kafka-producer -ti --image=$KAFKA_IMAGE --rm=true --restart=Never -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --topic my-topic
```

Type messages in Terminal 2 and press Enter. They appear in Terminal 1. **You just built a message bus.**

Try this to feel the durability: while the consumer is stopped, send 5 messages. Restart the consumer with `--from-beginning`. All 5 are still there. That's the whole point of Kafka versus a plain queue — messages persist and multiple independent readers each keep their own bookmark.

## C.7 Prove it's fault tolerant

Check where the partitions live:
```bash
kubectl -n kafka run kafka-admin -ti --image=$KAFKA_IMAGE --rm=true --restart=Never -- \
  bin/kafka-topics.sh --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --describe --topic my-topic
```
You'll see `Leader`, `Replicas`, and `Isr` (in-sync replicas) for each partition.

Now kill a broker:
```bash
kubectl -n kafka delete pod my-cluster-dual-role-1
```
Immediately re-run the describe command. Leadership has moved to a surviving broker; the topic still works. Your producer and consumer never stopped. Then watch the StatefulSet bring `dual-role-1` back with **the same name and the same disk**.

## C.8 Expose Kafka outside the cluster (optional)

Add an external listener to the `Kafka` resource:

```yaml
      - name: external
        port: 9094
        type: loadbalancer      # AWS: NLB; Azure: Azure LB. Use 'ingress' or 'route' for TLS-SNI setups
        tls: true
        configuration:
          bootstrap:
            annotations:
              service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```
Strimzi creates one load balancer for bootstrap **plus one per broker** (Kafka clients must reach individual brokers directly). That's 4 load balancers for a 3-broker cluster — real money. Prefer keeping Kafka internal, or use a single-LB `ingress`/`nodeport` pattern with TLS SNI routing.

## C.9 Monitoring Kafka

```yaml
  kafka:
    metricsConfig:
      type: strimziMetricsReporter
      values:
        allowList: [".*"]
```
Then scrape with Prometheus and import the Strimzi Grafana dashboards. **The metric that matters most is consumer group lag** — how far behind readers are. Lag climbing steadily means consumers can't keep up, and that's your cue to scale them (KEDA does this natively with a Kafka scaler).

## C.10 Kafka-on-Kubernetes: pros, cons, best practices

**Pros**
- Declarative: brokers, topics, users, ACLs, mirroring all in Git
- The operator handles rolling upgrades, certificate rotation, and broker replacement safely
- Same tooling, same RBAC, same monitoring as the rest of your platform
- Cheaper than fully managed Kafka at scale, and portable across clouds

**Cons**
- Kafka is **stateful and disk-latency sensitive** — this is the hardest class of workload to run on Kubernetes
- **You cannot shrink a PersistentVolume.** Over-provision thoughtfully; that decision is nearly irreversible
- Partition rebalancing doesn't fix itself; you'll want **Cruise Control** (Strimzi ships a `KafkaRebalance` resource)
- Cross-AZ replication traffic costs real money on both clouds
- Genuinely ask whether **Amazon MSK** or **Azure Event Hubs (Kafka-compatible)** is the better answer for your team

**Best practices**
- **Separate controller and broker node pools** in production (dedicated controllers = safer metadata). Dual-role is fine for dev and small clusters.
- 3 or 5 controllers (odd number — quorum, same as etcd).
- `replication.factor: 3` and `min.insync.replicas: 2`. With `acks=all` on the producer, that's the durable configuration.
- **Local NVMe or high-IOPS SSD** (gp3 with provisioned IOPS, Azure Premium SSD v2). Never network file storage.
- Spread brokers across AZs with topology spread constraints, and use `rack` awareness so replicas of a partition land in different zones.
- Set a **PodDisruptionBudget** with `maxUnavailable: 1`.
- Never run Kafka brokers on **spot** instances.
- Set `deleteClaim: false` so an accidental `kubectl delete kafka` doesn't destroy your data.
- Monitor: consumer lag, under-replicated partitions, disk usage, request latency.
- Upgrade Kafka one minor version at a time, and let Strimzi manage the metadata version bump *after* the brokers are all on the new version.

## C.11 Clean up

```bash
kubectl -n kafka delete kafkatopic my-topic
kubectl -n kafka delete kafka my-cluster
kubectl -n kafka delete kafkanodepool dual-role
kubectl delete -f 'https://strimzi.io/install/latest?namespace=kafka' -n kafka
kubectl delete pvc --all -n kafka        # PVCs survive on purpose — delete explicitly
kubectl delete namespace kafka
```

---

# PART 18 — Security: locking the store

Kubernetes is secure *by configuration*, not by default. Out of the box, every pod can talk to every other pod, containers can run as root, and any service account token can be read by anything on the node. Here is the checklist that closes those doors, in the order that gives you the most protection per hour of work.

## 18.1 The five layers (the "4C" model, plus supply chain)

| Layer | What you control | Biggest risk if ignored |
|---|---|---|
| **Cloud** | VPC/VNet, private endpoints, IAM, KMS | Public API server; over-privileged node roles |
| **Cluster** | RBAC, admission control, network policy, audit logs | Anyone with a token becomes cluster-admin |
| **Container** | Non-root, read-only filesystem, dropped capabilities | Container escape → node takeover |
| **Code** | Your app's own bugs | SQL injection is still SQL injection |
| **Supply chain** | Image provenance, scanning, signing | You deploy someone else's malware on purpose |

## 18.2 Pod Security Admission (replaces PodSecurityPolicy)

PodSecurityPolicy was removed in Kubernetes 1.25. The replacement is built in and applied **per namespace with labels**. Three profiles:

| Profile | Meaning |
|---|---|
| `privileged` | No restrictions (only for system namespaces) |
| `baseline` | Blocks the obviously dangerous: host networking, privileged containers, hostPath |
| `restricted` | Hardened: non-root, no privilege escalation, seccomp, all capabilities dropped |

```bash
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

Start with `warn` and `audit` only. Look at what would break. Then turn on `enforce`. Flipping straight to enforce on a live namespace stops every non-compliant deploy at 2 a.m.

## 18.3 The securityContext every production pod should have

```yaml
spec:
  securityContext:                      # pod level
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  automountServiceAccountToken: false   # unless the pod actually calls the K8s API
  containers:
    - name: web
      securityContext:                  # container level
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        privileged: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:                     # read-only root needs writable scratch space
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

**User namespaces went stable in Kubernetes 1.36.** They map the container's root user to an unprivileged user on the host, so even a container breakout gains no administrative power over the node. Enable with `hostUsers: false` in the pod spec. This is the single biggest container-isolation improvement in years.

## 18.4 RBAC that doesn't leak

Rules of thumb:
- Nobody gets `cluster-admin` as a daily driver. Use a break-glass role that triggers an alert when assumed.
- Prefer **Roles** (namespace-scoped) over **ClusterRoles**.
- Never grant `secrets: list` broadly — listing secrets in a namespace means reading all of them.
- Avoid wildcards: `verbs: ["*"]` and `resources: ["*"]` are how privilege escalation happens.
- `escalate`, `bind`, and `impersonate` verbs are effectively admin. Treat them that way.

Check what you actually have:
```bash
kubectl auth can-i --list --as=system:serviceaccount:prod:api-sa
kubectl auth can-i delete pods --namespace production
kubectl get clusterrolebindings -o wide | grep cluster-admin
```

## 18.5 Supply chain

1. **Scan images** in CI and in the registry: Trivy, Grype, Amazon Inspector, Microsoft Defender for Containers.
2. **Pin by digest**, not tag: `myrepo/app@sha256:abc123...`. Tags are mutable; digests are not.
3. **Sign images** (Sigstore/cosign) and verify at admission (Kyverno, Ratify, or the OPA Gatekeeper policy).
4. **Use minimal base images**: distroless, Chainguard, Alpine. Fewer packages = fewer CVEs.
5. **Private registries only** for production: Amazon ECR or Azure Container Registry, with `imagePullSecrets` or workload identity.
6. **Generate an SBOM** (`syft`) for every build so you can answer "are we affected?" in minutes, not days.

## 18.6 Secrets

Kubernetes Secrets are **base64-encoded, not encrypted**, inside etcd by default. Fix that three ways:

1. **Encryption at rest** with a real KMS key — EKS with AWS KMS, AKS with Azure Key Vault KMS.
2. **External secret stores**: the **Secrets Store CSI driver** mounts values directly from AWS Secrets Manager or Azure Key Vault, so the secret never becomes a Kubernetes object at all. Or use **External Secrets Operator** to sync them.
3. **Never in Git.** If you must store encrypted secrets in Git, use Sealed Secrets or SOPS.

Also: `automountServiceAccountToken: false` on pods that don't call the API server, and use short-lived **bound service account tokens** (the default since 1.22) rather than legacy forever-tokens.

## 18.7 Network policy: default deny

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}          # every pod in this namespace
  policyTypes: [Ingress, Egress]
```
Then allow explicitly, one relationship at a time. Remember to allow DNS to `kube-system` or everything breaks in confusing ways:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

## 18.8 Audit and runtime

- Turn on **API audit logging** (EKS: control plane logging → CloudWatch; AKS: diagnostic settings → Log Analytics). You cannot investigate what you didn't record.
- **Runtime threat detection**: Falco (open source), Amazon GuardDuty EKS Runtime Monitoring, Microsoft Defender for Containers. These catch "a shell was spawned inside a running container" — the thing that means you've already been breached.
- **Policy as code**: Kyverno or OPA Gatekeeper to enforce "every image must come from our registry", "every pod must have limits", "no `:latest` tags". AKS ships Azure Policy/Gatekeeper as a managed add-on; EKS teams usually install Kyverno.

## 18.9 Security checklist

- ☐ API server endpoint private or IP-restricted
- ☐ Audit logging on and shipped somewhere durable
- ☐ Secrets encrypted at rest with a customer-managed key
- ☐ `restricted` Pod Security Admission on all app namespaces
- ☐ Default-deny NetworkPolicy per namespace
- ☐ No `cluster-admin` in day-to-day use; RBAC reviewed quarterly
- ☐ Workload identity (IRSA / EKS Pod Identity / Azure Workload Identity) — zero static cloud keys
- ☐ Images scanned, signed, pinned by digest, from a private registry
- ☐ Nodes on the latest OS image; patched at least monthly
- ☐ Runtime threat detection enabled
- ☐ Cluster within the supported version window

---

# PART 19 — Cost: why the bill is what it is, and how to cut it

## 19.1 Where the money actually goes

For a typical cluster the split looks roughly like this:

| Line item | Share | Notes |
|---|---|---|
| **Worker nodes (EC2 / Azure VMs)** | 60–80% | This is the whole game |
| **Storage (EBS / Managed Disks)** | 5–15% | Orphaned volumes are pure waste |
| **Load balancers** | 5–10% | One per LoadBalancer Service adds up fast |
| **Data transfer (esp. cross-AZ)** | 5–15% | The invisible one that surprises everyone |
| **Control plane** | 1–3% | $0.10/hr on EKS; free tier on AKS |
| **Observability** | 2–10% | Log volume is the usual culprit |

## 19.2 The biggest lever: your resource requests

Most clusters run at **10–25% actual CPU utilization** while being "full" from the scheduler's point of view. That's because requests are set from fear, not measurement.

```bash
# What you asked for vs what you use
kubectl describe node <node> | grep -A8 "Allocated resources"
kubectl top pods -A --sort-by=cpu
```

Fix it with **VPA in recommendation mode** — it watches real usage and tells you the right numbers without changing anything:

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: hello-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: hello
  updatePolicy:
    updateMode: "Off"        # recommend only — read it with kubectl describe vpa
```

Right-sizing requests is usually a **30–50% cost reduction** with zero performance change. Nothing else comes close.

## 19.3 The other nine levers

1. **Spot / Azure Spot** — 60–90% off for interruptible work. Use a diversified instance pool, a PodDisruptionBudget, and always keep an on-demand floor for baseline traffic.
2. **Savings Plans / Reserved Instances / Azure Reservations** — 30–60% off for committed baseline capacity. Commit to the floor, burst on-demand.
3. **Karpenter / Node Auto Provisioning** — picks the cheapest instance that fits, then **consolidates** underused nodes automatically. Frequently 20–40% versus static node groups.
4. **Graviton (arm64) on AWS / Ampere on Azure** — commonly 20–40% better price/performance. Requires multi-arch images (`docker buildx build --platform linux/amd64,linux/arm64`).
5. **Scale dev/test to zero at night.** A CronJob or KEDA cron scaler that sets replicas to 0 at 7 p.m. cuts non-prod spend by ~65%.
6. **One Ingress instead of ten LoadBalancer Services.** Each cloud LB is ~$16–25/month plus data processing.
7. **Kill cross-AZ chatter** with `trafficDistribution: PreferClose` (or `PreferSameZone`/`PreferSameNode`, stable since 1.35) on Services, and topology-aware routing.
8. **Clean up orphans**: released PersistentVolumes, unattached disks, old snapshots, unused load balancers, stale ECR/ACR images with a lifecycle policy.
9. **Cut log volume.** Debug-level logging in production is often the single largest observability bill line. Sample it.

## 19.4 Seeing the cost

- **OpenCost** (CNCF) or **Kubecost** — cost per namespace, per deployment, per team, on any cluster
- **AKS Cost Analysis** — a built-in add-on that breaks down cluster spend in the Azure portal
- **AWS Cost Explorer + split cost allocation data for EKS** — attributes EC2 cost down to pods
- **Tag/label everything** (`team`, `env`, `cost-center`) — showback is the only thing that reliably changes behavior

**Rule of thumb:** if you don't know your cost per namespace, you are overspending by at least 30%.

---

# PART 20 — Helm, GitOps, and CI/CD

## 20.1 Why you stop using `kubectl apply` by hand

Typing `kubectl apply` into a production cluster is like editing the store's ledger in pencil while customers watch. It works, it's fast, and nobody can tell you six months later *what* changed, *when*, or *why*.

The progression every team goes through:

```
kubectl apply  →  Helm charts  →  GitOps (Git is the only source of truth)
```

## 20.2 Helm: templating and packaging

A Helm **chart** is a parameterized bundle of manifests. Same chart, different `values.yaml` per environment.

```
hello-chart/
├── Chart.yaml            # name, version, appVersion
├── values.yaml           # defaults
├── values-prod.yaml      # production overrides
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    ├── ingress.yaml
    └── _helpers.tpl      # reusable name/label snippets
```

**Chart.yaml**
```yaml
apiVersion: v2
name: hello
description: Hello World web app
type: application
version: 0.1.0          # chart version
appVersion: "1.0.0"     # your app's version
```

**values.yaml**
```yaml
replicaCount: 3
image:
  repository: nginxdemos/hello
  tag: plain-text
  pullPolicy: IfNotPresent
resources:
  requests: { cpu: 100m, memory: 64Mi }
  limits:   { cpu: 500m, memory: 256Mi }
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 15
  targetCPUUtilizationPercentage: 50
ingress:
  enabled: false
  className: ""
  host: ""
```

**templates/deployment.yaml**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "hello.fullname" . }}
  labels: {{- include "hello.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels: {{- include "hello.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "hello.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 80
          resources: {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet: { path: /, port: 80 }
```

**The commands:**
```bash
helm lint ./hello-chart
helm template hello ./hello-chart -f values-prod.yaml   # render, don't install — read the output!
helm install hello ./hello-chart -n hello --create-namespace
helm upgrade hello ./hello-chart -f values-prod.yaml -n hello --atomic --timeout 5m
helm history hello -n hello
helm rollback hello 1 -n hello
helm uninstall hello -n hello
```

`--atomic` is the flag that matters: if the upgrade fails, Helm rolls the whole release back automatically.

**Helm pros:** real packaging, versioning, dependencies, one-command rollback, a huge public chart ecosystem.
**Helm cons:** Go templating inside YAML gets ugly fast; whitespace bugs; `helm template` output can drift from what's actually in the cluster. Alternatives: **Kustomize** (overlays, no templating — built into `kubectl -k`), **jsonnet**, **cdk8s**, or **Timoni**.

## 20.3 GitOps: Git is the desired state

**The idea:** an agent runs *inside* the cluster, watches a Git repository, and continuously makes the cluster match it. Nobody deploys — they merge a pull request.

**Why it's better:**
- Every change is reviewed, attributed, and reversible (`git revert` = rollback)
- Drift is detected and corrected automatically
- No CI system needs credentials to your cluster (huge security win — the pull model)
- Disaster recovery is "point a new cluster at the repo"

**The two tools:** **Argo CD** (UI-first, very popular) and **Flux** (CLI/CRD-first, and the engine behind the AKS GitOps add-on).

**Argo CD Application example:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/k8s-manifests.git
    targetRevision: main
    path: apps/hello/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: hello
  syncPolicy:
    automated:
      prune: true          # delete things removed from Git
      selfHeal: true       # revert manual kubectl changes
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff: { duration: 5s, factor: 2, maxDuration: 3m }
```

**Repository layout that scales:**
```
k8s-manifests/
├── apps/
│   └── hello/
│       ├── base/                 # shared manifests
│       └── overlays/
│           ├── dev/
│           ├── staging/
│           └── production/
└── infrastructure/
    ├── ingress/
    ├── monitoring/
    └── cert-manager/
```

## 20.4 A complete CI/CD pipeline (GitHub Actions → ECR/ACR → GitOps)

**Dockerfile** (multi-stage, non-root, small):
```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .

FROM gcr.io/distroless/nodejs22-debian12
WORKDIR /app
COPY --from=build /app /app
USER 10001
EXPOSE 8080
CMD ["server.js"]
```

**.github/workflows/deploy.yml** — build, scan, push, then bump the tag in the GitOps repo:
```yaml
name: build-and-deploy
on:
  push:
    branches: [main]

permissions:
  id-token: write        # for OIDC to AWS/Azure — no long-lived keys
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions
          aws-region: us-east-1

      - name: Log in to Amazon ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        env:
          REGISTRY: ${{ steps.ecr.outputs.registry }}
          IMAGE: hello
          TAG: ${{ github.sha }}
        run: |
          docker buildx build --platform linux/amd64,linux/arm64 \
            -t $REGISTRY/$IMAGE:$TAG --push .

      - name: Scan the image
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ steps.ecr.outputs.registry }}/hello:${{ github.sha }}
          severity: CRITICAL,HIGH
          exit-code: '1'          # fail the build on critical CVEs

      - name: Update the GitOps repo
        run: |
          git clone https://x-access-token:${{ secrets.GITOPS_TOKEN }}@github.com/yourorg/k8s-manifests.git
          cd k8s-manifests/apps/hello/overlays/production
          sed -i "s|newTag:.*|newTag: ${{ github.sha }}|" kustomization.yaml
          git config user.name  "ci-bot"
          git config user.email "ci@yourorg.com"
          git commit -am "hello: ${{ github.sha }}"
          git push
```

Argo CD sees the commit and rolls it out. **The CI system never touches the cluster.**

**Azure equivalent** for the login/push steps:
```yaml
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az acr login --name myregistry
      - run: docker build -t myregistry.azurecr.io/hello:${{ github.sha }} . && docker push myregistry.azurecr.io/hello:${{ github.sha }}
```

## 20.5 CI/CD best practices

- **Immutable tags** — the Git SHA, never `latest`
- **Build once, promote the same artifact** through dev → staging → prod
- **Fail the build on critical CVEs** and on failing policy checks (`kubeconform`, `kyverno test`, `conftest`)
- **Automate dev, gate production** with a manual approval or a PR review
- **Smoke test after deploy** and roll back automatically on failure (`--atomic`, Argo Rollouts analysis)
- **OIDC federation instead of stored cloud credentials** in the CI system
- **Keep the deploy under 10 minutes** or people start batching changes, which makes every deploy riskier

---

# PART 21 — Infrastructure as Code: Terraform for EKS and AKS

Clicking in a console is fine for learning and terrible for operating. IaC gives you review, repeatability, and a way to rebuild everything after a bad day.

## 21.1 Amazon EKS with Terraform (Auto Mode)

`main.tf`:
```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "my-tf-state"
    key            = "eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks"      # state locking — do not skip
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
}

locals {
  name = "hello-eks"
  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.0.0/19",  "10.0.32.0/19",  "10.0.64.0/19"]   # roomy: ~8k IPs each
  public_subnets  = ["10.0.96.0/24", "10.0.97.0/24",  "10.0.98.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = false     # one per AZ = resilient (and pricier)
  enable_dns_hostnames = true

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
  public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["203.0.113.0/24"]   # your office/VPN only

  # EKS Auto Mode: no node groups to define
  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_encryption_config = {
    resources = ["secrets"]
  }

  enable_cluster_creator_admin_permissions = true
  tags = local.tags
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = module.eks.cluster_name
  addon_name   = "metrics-server"
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
```

```bash
terraform init
terraform plan -out=tfplan       # ALWAYS read the plan
terraform apply tfplan
terraform destroy                # when you're done experimenting
```

<b>Classic managed node group variant</b> (instead of `cluster_compute_config`):
```hcl
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.large"]
      min_size = 3, max_size = 6, desired_size = 3
      taints = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    general = {
      instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"]   # diversify for capacity
      capacity_type  = "ON_DEMAND"
      min_size = 3, max_size = 20, desired_size = 3
    }
    spot = {
      instance_types = ["m6i.xlarge", "m5.xlarge", "m5a.xlarge", "m6a.xlarge"]
      capacity_type  = "SPOT"
      min_size = 0, max_size = 30, desired_size = 0
      taints = [{ key = "spot", value = "true", effect = "NO_SCHEDULE" }]
    }
  }
```

## 21.2 Azure AKS with Terraform

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-hello-aks"
  location = "eastus"
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "law-hello-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "hello-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "hello-aks"
  kubernetes_version  = "1.36"
  sku_tier            = "Standard"          # 99.95% SLA. "Premium" adds LTS.

  automatic_upgrade_channel      = "stable"
  node_os_upgrade_channel        = "NodeImage"

  default_node_pool {
    name                 = "system"
    vm_size              = "Standard_D4s_v5"
    node_count           = 3
    zones                = ["1", "2", "3"]
    only_critical_addons_enabled = true     # taints it CriticalAddonsOnly
    auto_scaling_enabled = true
    min_count            = 3
    max_count            = 6
    os_sku               = "AzureLinux"
  }

  identity { type = "SystemAssigned" }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"          # no VNet IP exhaustion
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "03:00"
    utc_offset  = "+00:00"
  }

  tags = { environment = "production", managed_by = "terraform" }
}

resource "azurerm_kubernetes_cluster_node_pool" "apps" {
  name                  = "apps"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = "Standard_D8s_v5"
  zones                 = ["1", "2", "3"]
  auto_scaling_enabled  = true
  min_count             = 3
  max_count             = 20
  os_sku                = "AzureLinux"
  node_labels           = { workload = "general" }
}

output "get_credentials" {
  value = "az aks get-credentials -g ${azurerm_resource_group.rg.name} -n ${azurerm_kubernetes_cluster.aks.name}"
}
```

## 21.3 IaC best practices

- **Remote state with locking** (S3 + DynamoDB, or an Azure Storage Account). Never commit `terraform.tfstate`.
- **Separate state per environment.** A `terraform destroy` typo should not be able to reach production.
- **Pin provider and module versions.** `~> 5.0`, never unpinned.
- **Split the stack**: network → cluster → platform add-ons → applications. Each with its own state and blast radius.
- **Don't manage app manifests in Terraform.** Terraform builds the cluster; GitOps deploys into it. Mixing them causes painful dependency ordering and drift.
- **Run `terraform plan` in CI on every PR** and post the diff as a comment.
- **`prevent_destroy = true`** on the cluster and on stateful resources.
- Alternatives worth knowing: **Pulumi** (real languages), **AWS CDK / CDK for Terraform**, **Bicep** (Azure-native), **Crossplane** (manage cloud infra *from inside* Kubernetes).

---

# PART 22 — Appendix: ready-to-use example files

Everything below is a complete, working file. Copy them into a folder, adjust names, and you have a realistic starting point. (These are also provided as separate downloadable files alongside this document.)

## 22.1 `01-namespace-and-guardrails.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "100"
    requests.memory: 200Gi
    limits.cpu: "200"
    limits.memory: 400Gi
    persistentvolumeclaims: "50"
    services.loadbalancers: "3"
    count/deployments.apps: "50"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: production-defaults
  namespace: production
spec:
  limits:
    - type: Container
      default:                     # applied if the pod omits limits
        cpu: 500m
        memory: 512Mi
      defaultRequest:              # applied if the pod omits requests
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "8"
        memory: 16Gi
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

## 22.2 `02-deployment-production.yaml` — the full-featured Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: production
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/version: "1.4.2"
    app.kubernetes.io/component: backend
    app.kubernetes.io/part-of: shop
spec:
  replicas: 3
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0        # never drop below full capacity
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/version: "1.4.2"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
        prometheus.io/path: /metrics
    spec:
      serviceAccountName: api-sa
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 60
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app.kubernetes.io/name: api }
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app.kubernetes.io/name: api }
      initContainers:
        - name: wait-for-db
          image: busybox:1.36
          command: ['sh','-c','until nc -z postgres 5432; do echo waiting; sleep 2; done']
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
      containers:
        - name: api
          image: myregistry.example.com/api@sha256:aaaabbbbccccdddd    # pinned by digest
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
            - name: metrics
              containerPort: 9090
          env:
            - name: POD_NAME
              valueFrom: { fieldRef: { fieldPath: metadata.name } }
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef: { name: api-config, key: log_level }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: api-secrets, key: db_password }
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits:   { cpu: "1",  memory: 256Mi }     # memory limit == request
          startupProbe:                                 # slow starters get 60s
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh","-c","sleep 10"]    # let the LB drain first
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: tmp,    mountPath: /tmp }
            - { name: config, mountPath: /etc/api, readOnly: true }
      volumes:
        - name: tmp
          emptyDir: {}
        - name: config
          configMap: { name: api-config }
```

## 22.3 `03-service-hpa-pdb.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: production
spec:
  type: ClusterIP
  trafficDistribution: PreferClose     # keep traffic in-zone; cuts cross-AZ cost
  selector:
    app.kubernetes.io/name: api
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: production
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 30
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 60 }
    - type: Resource
      resource:
        name: memory
        target: { type: Utilization, averageUtilization: 75 }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0      # react to spikes immediately
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }
    scaleDown:
      stabilizationWindowSeconds: 300    # scale down slowly, avoid flapping
      policies:
        - { type: Percent, value: 25, periodSeconds: 60 }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
  namespace: production
spec:
  maxUnavailable: 1        # safer than minAvailable — scales with replica count
  selector:
    matchLabels:
      app.kubernetes.io/name: api
```

## 22.4 `04-config-secret-rbac.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: production
data:
  log_level: "info"
  feature_new_checkout: "true"
  application.yaml: |
    server:
      port: 8080
      shutdownTimeout: 30s
    cache:
      ttlSeconds: 300
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-sa
  namespace: production
  annotations:
    # AWS (IRSA):
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/api-role
    # Azure Workload Identity uses a label + annotation instead:
    # azure.workload.identity/client-id: "00000000-0000-0000-0000-000000000000"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-reader
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]     # least privilege: no secrets, no write
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-reader
  namespace: production
subjects:
  - kind: ServiceAccount
    name: api-sa
    namespace: production
roleRef:
  kind: Role
  name: api-reader
  apiGroup: rbac.authorization.k8s.io
```

## 22.5 `05-statefulset-postgres.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: production
spec:
  clusterIP: None            # headless: DNS returns each pod's own IP
  selector: { app: postgres }
  ports:
    - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: production
spec:
  serviceName: postgres
  replicas: 3
  podManagementPolicy: OrderedReady
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1      # beta in 1.35+ for StatefulSets; speeds up maintenance
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      terminationGracePeriodSeconds: 120
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: postgres }
              topologyKey: kubernetes.io/hostname
      containers:
        - name: postgres
          image: postgres:17-alpine
          ports: [{ containerPort: 5432, name: pg }]
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: postgres-secret, key: password }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          resources:
            requests: { cpu: "1", memory: 4Gi }
            limits:   { cpu: "2", memory: 4Gi }
          readinessProbe:
            exec: { command: ["pg_isready","-U","postgres"] }
            periodSeconds: 5
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:            # each pod gets its OWN disk, kept across restarts
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3      # AKS: managed-csi-premium
        resources:
          requests: { storage: 100Gi }
```

## 22.6 `06-daemonset-cronjob.yaml`

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
  namespace: kube-system
spec:
  selector:
    matchLabels: { app: log-agent }
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 10% }
  template:
    metadata:
      labels: { app: log-agent }
    spec:
      tolerations:                       # run on EVERY node, even tainted ones
        - operator: Exists
      containers:
        - name: agent
          image: fluent/fluent-bit:3.1
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 200Mi }
          volumeMounts:
            - { name: varlog, mountPath: /var/log, readOnly: true }
      volumes:
        - name: varlog
          hostPath: { path: /var/log }
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-report
  namespace: production
spec:
  schedule: "0 3 * * *"              # 03:00 every day
  timeZone: "America/New_York"       # stable since Kubernetes 1.27
  concurrencyPolicy: Forbid          # never overlap runs
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  startingDeadlineSeconds: 300
  jobTemplate:
    spec:
      backoffLimit: 3
      activeDeadlineSeconds: 3600    # kill it after an hour
      ttlSecondsAfterFinished: 86400 # auto-clean finished jobs
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: report
              image: myregistry.example.com/reporter:1.2.0
              command: ["/app/generate-report","--date=yesterday"]
              resources:
                requests: { cpu: 500m, memory: 1Gi }
                limits:   { cpu: "2",  memory: 2Gi }
```

## 22.7 `07-gateway-api.yaml` — the modern replacement for Ingress

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: infrastructure
spec:
  gatewayClassName: eks-alb          # AKS: azure-application-gateway / istio
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: example-com-tls
      allowedRoutes:
        namespaces: { from: Selector, selector: { matchLabels: { gateway-access: "true" } } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: production
spec:
  parentRefs:
    - name: public-gateway
      namespace: infrastructure
  hostnames: ["shop.example.com"]
  rules:
    - matches:
        - path: { type: PathPrefix, value: /api }
      backendRefs:
        - name: api
          port: 80
          weight: 90               # canary: 90% to stable
        - name: api-canary
          port: 80
          weight: 10               # 10% to the new version
      timeouts:
        request: 10s
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - name: frontend
          port: 80
```

## 22.8 `08-keda-scaledobject.yaml` — scale on things that aren't CPU

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: order-processor
  namespace: production
spec:
  scaleTargetRef:
    name: order-processor
  minReplicaCount: 0          # KEDA can scale to ZERO — the HPA cannot
  maxReplicaCount: 50
  pollingInterval: 15
  cooldownPeriod: 300
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: my-cluster-kafka-bootstrap.kafka:9092
        consumerGroup: order-processors
        topic: orders
        lagThreshold: "100"     # one pod per 100 messages of lag
    - type: prometheus
      metadata:
        serverAddress: http://prometheus.monitoring:9090
        metricName: http_requests_per_second
        query: sum(rate(http_requests_total{app="order-processor"}[2m]))
        threshold: "50"
```

## 22.9 `09-karpenter-nodepool.yaml` (EKS Auto Mode / Karpenter)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general-purpose
spec:
  template:
    metadata:
      labels: { workload: general }
    spec:
      nodeClassRef:
        group: eks.amazonaws.com          # Auto Mode uses eks.amazonaws.com/v1 NodeClass
        kind: NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64", "arm64"]      # let Karpenter pick Graviton when it's cheaper
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: eks.amazonaws.com/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: eks.amazonaws.com/instance-generation
          operator: Gt
          values: ["5"]                   # modern instances only
      expireAfter: 336h                   # replace every 14 days for patching
      terminationGracePeriod: 24h
  limits:
    cpu: "1000"
    memory: 4000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets:
      - nodes: "10%"                      # never churn more than 10% at once
      - nodes: "0"                        # freeze during business hours
        schedule: "0 13 * * mon-fri"
        duration: 8h
```

## 22.10 `10-kafka-python-client.py` — a real producer and consumer

```python
#!/usr/bin/env python3
"""Minimal Kafka producer/consumer for the Strimzi cluster from Part 17.
   pip install confluent-kafka
   Run inside the cluster, or port-forward the bootstrap service first."""

import json, os, sys, time
from confluent_kafka import Producer, Consumer, KafkaError

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "my-cluster-kafka-bootstrap.kafka:9092")
TOPIC     = os.getenv("KAFKA_TOPIC", "my-topic")


def delivery_report(err, msg):
    if err:
        print(f"DELIVERY FAILED: {err}", file=sys.stderr)
    else:
        print(f"delivered to {msg.topic()}[{msg.partition()}] offset {msg.offset()}")


def produce(n=10):
    p = Producer({
        "bootstrap.servers": BOOTSTRAP,
        "acks": "all",              # wait for min.insync.replicas — durability
        "enable.idempotence": True, # no duplicates on retry
        "retries": 10,
        "compression.type": "snappy",
        "linger.ms": 20,            # small batching = big throughput win
    })
    for i in range(n):
        event = {"order_id": i, "item": "milk", "qty": 2, "ts": time.time()}
        p.produce(TOPIC,
                  key=str(i).encode(),          # same key -> same partition -> ordered
                  value=json.dumps(event).encode(),
                  callback=delivery_report)
        p.poll(0)
    p.flush(10)


def consume():
    c = Consumer({
        "bootstrap.servers": BOOTSTRAP,
        "group.id": "order-processors",
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,   # commit only AFTER successful processing
        "max.poll.interval.ms": 300000,
    })
    c.subscribe([TOPIC])
    try:
        while True:
            msg = c.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                if msg.error().code() != KafkaError._PARTITION_EOF:
                    print(f"consumer error: {msg.error()}", file=sys.stderr)
                continue
            event = json.loads(msg.value())
            print(f"processing {event}")
            # ... do the real work here ...
            c.commit(msg)              # at-least-once delivery
    except KeyboardInterrupt:
        pass
    finally:
        c.close()                      # triggers a clean group rebalance


if __name__ == "__main__":
    produce() if len(sys.argv) > 1 and sys.argv[1] == "produce" else consume()
```

## 22.11 `11-prometheus-rules.yaml` — alerts worth having

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: platform-alerts
  namespace: monitoring
spec:
  groups:
    - name: workloads
      rules:
        - alert: PodCrashLooping
          expr: rate(kube_pod_container_status_restarts_total[10m]) * 600 > 3
          for: 10m
          labels: { severity: critical }
          annotations:
            summary: "{{ $labels.namespace }}/{{ $labels.pod }} is crash looping"

        - alert: DeploymentReplicasMismatch
          expr: |
            kube_deployment_spec_replicas != kube_deployment_status_replicas_available
          for: 15m
          labels: { severity: warning }

        - alert: PodPendingTooLong
          expr: kube_pod_status_phase{phase="Pending"} == 1
          for: 15m
          labels: { severity: warning }

        - alert: HighErrorRate
          expr: |
            sum(rate(http_requests_total{code=~"5.."}[5m])) by (service)
              / sum(rate(http_requests_total[5m])) by (service) > 0.02
          for: 5m
          labels: { severity: critical }

        - alert: PVCAlmostFull
          expr: |
            kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85
          for: 10m
          labels: { severity: warning }

    - name: cluster
      rules:
        - alert: NodeNotReady
          expr: kube_node_status_condition{condition="Ready",status="true"} == 0
          for: 10m
          labels: { severity: critical }

        - alert: NodeMemoryPressure
          expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
          for: 5m
          labels: { severity: warning }
```

## 22.12 `12-cluster-bootstrap.sh` — one script to set up a new cluster

```bash
#!/usr/bin/env bash
# Installs the baseline platform components on a fresh EKS or AKS cluster.
set -euo pipefail

CLOUD="${1:-eks}"          # eks | aks
echo "==> Bootstrapping platform components for $CLOUD"

# --- 1. metrics-server (EKS only; AKS ships it) ---------------------------
if [[ "$CLOUD" == "eks" ]]; then
  echo "==> metrics-server"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/high-availability-1.21+.yaml
fi

# --- 2. Monitoring: Prometheus + Grafana ---------------------------------
echo "==> kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=true \
  --set prometheus.prometheusSpec.retention=15d \
  --set prometheus.prometheusSpec.resources.requests.memory=2Gi \
  --wait

# --- 3. Policy engine ----------------------------------------------------
echo "==> Kyverno"
helm repo add kyverno https://kyverno.github.io/kyverno
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait

# --- 4. Certificates -----------------------------------------------------
echo "==> cert-manager"
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true --wait

# --- 5. Event-driven autoscaling ----------------------------------------
echo "==> KEDA"
helm repo add kedacore https://kedacore.github.io/charts
helm upgrade --install keda kedacore/keda -n keda --create-namespace --wait

# --- 6. GitOps -----------------------------------------------------------
echo "==> Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo
echo "==> Done. Argo CD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
echo "==> Port-forward the UI:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
```

## 22.13 `13-health-check.sh` — a 60-second cluster triage script

```bash
#!/usr/bin/env bash
# Fast read on cluster health. Run it before you panic.
set -uo pipefail

echo "===== NODES ====="
kubectl get nodes -o wide
echo
echo "===== NOT-READY NODES ====="
kubectl get nodes --no-headers | grep -v " Ready" || echo "  all nodes Ready"
echo
echo "===== UNHEALTHY PODS ====="
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
echo
echo "===== RESTART LEADERBOARD (top 10) ====="
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount' \
  2>/dev/null | tail -10
echo
echo "===== RECENT WARNING EVENTS ====="
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20
echo
echo "===== RESOURCE USAGE ====="
kubectl top nodes 2>/dev/null || echo "  metrics-server not available"
echo
echo "===== PENDING PVCs ====="
kubectl get pvc -A 2>/dev/null | grep -i pending || echo "  none"
echo
echo "===== EXPIRING CERTIFICATES (cert-manager) ====="
kubectl get certificates -A 2>/dev/null || echo "  cert-manager not installed"
echo
echo "===== CLUSTER VERSION ====="
kubectl version -o yaml 2>/dev/null | grep -E "gitVersion|major|minor" | head -6
```

---

# PART 23 — Extended troubleshooting runbook

## 23.1 "The deploy went out and the site is down"

```bash
# 1. What's the rollout doing?
kubectl -n prod rollout status deployment/api --timeout=30s

# 2. Roll back FIRST, investigate second. Always.
kubectl -n prod rollout undo deployment/api

# 3. Now find out why
kubectl -n prod describe deployment api | tail -30
kubectl -n prod get rs -o wide           # which ReplicaSet has the bad pods?
kubectl -n prod logs -l app=api --tail=100 --prefix
kubectl -n prod get events --sort-by=.lastTimestamp | tail -30
```

## 23.2 "Pods are Pending and nothing is happening"

```bash
kubectl -n prod describe pod <pod> | sed -n '/Events/,$p'
```
Read the message literally:

| Message | Meaning | Fix |
|---|---|---|
| `0/6 nodes are available: 6 Insufficient cpu` | The cluster is genuinely full | Add nodes, or lower requests |
| `... didn't match Pod's node affinity/selector` | Your rules exclude every node | Check labels: `kubectl get nodes --show-labels` |
| `... had untolerated taint {gpu: true}` | You need a toleration | Add it, or target a different pool |
| `... exceeds max volume count` | Node hit its attachable-disk limit | Bigger nodes, or fewer volumes per node |
| `pod has unbound immediate PersistentVolumeClaims` | Storage isn't provisioning | Check StorageClass, CSI driver pods, and zone matching |
| `Too many pods` | Hit the per-node pod cap (or CNI IP limit) | Prefix delegation, bigger nodes, or more nodes |

## 23.3 "It's slow and I don't know why"

```bash
# CPU throttling — the silent latency killer
kubectl -n prod exec <pod> -- cat /sys/fs/cgroup/cpu.stat | grep throttled
# nr_throttled climbing = your CPU limit is too low

# Memory near the limit = imminent OOMKill
kubectl top pod <pod> -n prod
kubectl -n prod get pod <pod> -o jsonpath='{.spec.containers[0].resources}'

# Was it OOMKilled?
kubectl -n prod describe pod <pod> | grep -A3 "Last State"

# DNS slowness (extremely common)
kubectl -n prod run dns-test --rm -it --image=nicolaka/netshoot -- \
  sh -c "time nslookup api.prod.svc.cluster.local"
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50
kubectl -n kube-system top pods -l k8s-app=kube-dns    # CoreDNS starved for CPU?

# Is the node itself unhealthy?
kubectl describe node <node> | grep -A10 Conditions
```

**The three usual culprits, in order:** CPU limits causing throttling, CoreDNS under-provisioned, and cross-AZ network hops.

## 23.4 "I can't reach my service"

Work outward, one layer at a time:

```bash
# 1. Does the Service have any endpoints? (Empty = selector/label mismatch or failing readiness)
kubectl -n prod get endpointslices -l kubernetes.io/service-name=api

# 2. Do the labels actually match?
kubectl -n prod get svc api -o jsonpath='{.spec.selector}'; echo
kubectl -n prod get pods --show-labels

# 3. Can you reach the pod directly?
kubectl -n prod port-forward pod/<pod> 8080:8080

# 4. Can you reach it from inside the cluster?
kubectl -n prod run curl --rm -it --image=curlimages/curl -- curl -v http://api

# 5. Is a NetworkPolicy blocking it?
kubectl -n prod get networkpolicies

# 6. Is the load balancer healthy? (check target group health in AWS / backend pool in Azure)
kubectl -n prod describe svc api | tail -20
```

## 23.5 "The cluster upgrade is stuck"

Almost always a PodDisruptionBudget that can never be satisfied, or a pod that won't terminate.

```bash
# Which PDBs are blocking evictions?
kubectl get pdb -A          # look for ALLOWED DISRUPTIONS = 0

# Which pods refuse to die?
kubectl get pods -A --field-selector=status.phase=Running -o json \
  | jq -r '.items[] | select(.metadata.deletionTimestamp) | "\(.metadata.namespace)/\(.metadata.name)"'

# Emergency (understand the consequences first)
kubectl delete pod <pod> -n <ns> --force --grace-period=0
```

**Prevention:** every PDB should allow at least one disruption at your normal replica count. A single-replica Deployment with `minAvailable: 1` is an upgrade deadlock waiting to happen.

## 23.6 Emergency commands (know these cold)

```bash
# Stop the bleeding: scale to zero
kubectl -n prod scale deployment/api --replicas=0

# Roll back everything to the previous revision
kubectl -n prod rollout undo deployment/api

# Restart all pods without changing anything else
kubectl -n prod rollout restart deployment/api

# Take a node out of service right now
kubectl cordon <node> && kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force

# Grab everything about a broken pod, for the incident ticket
kubectl -n prod describe pod <pod>       > incident.txt
kubectl -n prod logs <pod> --previous   >> incident.txt
kubectl -n prod get events --sort-by=.lastTimestamp >> incident.txt

# Copy a file out of a running container
kubectl -n prod cp <pod>:/app/heapdump.hprof ./heapdump.hprof

# Run a debug sidecar in a distroless pod that has no shell
kubectl -n prod debug -it <pod> --image=nicolaka/netshoot --target=api
```

---
# PART 24 — The master troubleshooting guide

Part 23 covered the five emergencies you'll hit most. This part is the complete reference: **every common failure, how to identify it, what causes it, and exactly what to do.** Read the tables like a lookup index — find your symptom in the left column.

## 24.1 The universal triage sequence

Whatever is broken, run these five steps in this order before forming a theory. It takes 90 seconds and prevents most wrong turns.

```bash
# 1. WHAT is broken? Find the unhealthy objects.
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
kubectl get nodes | grep -v " Ready"

# 2. WHAT does Kubernetes say about it? (Events are at the bottom.)
kubectl -n <ns> describe pod <pod>

# 3. WHAT does the application say?
kubectl -n <ns> logs <pod> --tail=200
kubectl -n <ns> logs <pod> --previous          # the container that just died

# 4. WHAT changed? 99% of incidents follow a change.
kubectl -n <ns> rollout history deployment/<name>
kubectl get events -A --sort-by=.lastTimestamp | tail -40

# 5. IS IT WIDER than this one thing?
kubectl get pods -n kube-system
kubectl top nodes
```

**The single most useful rule:** the `Events:` section at the bottom of `kubectl describe` almost always tells you the answer in plain English. Read it before you Google anything.

## 24.2 Pod status decoder — every state you'll see

| Status / Reason | What it means | First command | Most likely cause & fix |
|---|---|---|---|
| `Pending` | Not assigned to a node yet | `kubectl describe pod` → Events | No room, unsatisfiable scheduling rule, or unbound PVC → see 24.3 |
| `ContainerCreating` (stuck > 2 min) | Node accepted it, can't start it | `describe pod`, `kubectl -n <ns> get events` | Volume mount failing, CNI can't assign an IP, image still pulling, secret/configmap missing |
| `ImagePullBackOff` / `ErrImagePull` | Can't download the image | `describe pod` → Events | Wrong name/tag, private registry with no `imagePullSecrets`, registry rate limit, no network route to registry |
| `CrashLoopBackOff` | Container starts then exits, repeatedly | `logs --previous` | App error, missing env var/config, failed dependency, wrong command, or a too-aggressive liveness probe |
| `Running` but `0/1 READY` | Alive, failing readiness | `describe pod`, `logs` | Readiness probe path/port wrong, app genuinely not ready, dependency unreachable |
| `OOMKilled` (in Last State) | Exceeded its memory limit | `describe pod` → Last State | Limit too low, or a memory leak. Raise the limit **and** investigate |
| `Error` | Exited non-zero, `restartPolicy` won't retry | `logs --previous` | Job/init container failed; read the exit code |
| `Completed` | Exited 0 | — | Normal for Jobs; a bug for a Deployment (your process isn't staying in the foreground) |
| `Evicted` | Kubelet reclaimed resources | `describe pod` → Message | Node ran out of memory/disk. Set requests; check node `DiskPressure` |
| `Terminating` (stuck) | Deletion blocked | `kubectl get pod -o yaml` → `finalizers`, `deletionTimestamp` | A finalizer isn't completing (volume detach, mesh sidecar), or the node is gone. See 24.13 |
| `Init:0/2` / `Init:Error` | Stuck or failed init container | `logs <pod> -c <init-container>` | The dependency it waits for isn't up |
| `PodInitializing` | Init containers done, main starting | wait, then `describe` | Usually just image pull |
| `CreateContainerConfigError` | Config referenced doesn't exist | `describe pod` → Events | Missing ConfigMap or Secret, or a missing key inside it |
| `CreateContainerError` | Runtime refused to start it | `describe pod`, node kubelet logs | Bad command/entrypoint, missing binary, read-only FS conflict |
| `InvalidImageName` | Malformed image reference | `get pod -o yaml` | Typo, stray whitespace, or an unrendered template variable |
| `NodeAffinity` | Node no longer matches | `describe pod` | Node labels changed under a running pod |
| `Unknown` | Node lost contact | `kubectl get nodes` | Node down or network partitioned |

## 24.3 Container exit codes — what the number means

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Clean exit | Fine for Jobs; for a Deployment, your process is backgrounding itself |
| `1` | Generic application error | Read the logs — it's your app |
| `2` | Shell misuse / bad command syntax | Check `command:` and `args:` |
| `126` | Command found but not executable | `chmod +x` in the Dockerfile, or wrong entrypoint |
| `127` | Command not found | Binary isn't in the image or not on `PATH` (very common with distroless) |
| `128+n` | Killed by signal *n* | See below |
| `137` (128+9) | **SIGKILL** — usually OOMKilled | Raise memory limit; check for a leak; confirm in `Last State` |
| `139` (128+11) | **SIGSEGV** — segmentation fault | App/native library bug; check architecture (arm64 image on amd64 node?) |
| `143` (128+15) | **SIGTERM** — graceful shutdown | Normal during rollouts and drains |
| `255` | Exit status out of range | App returned an unexpected code; read the logs |

## 24.4 Scheduling failures: pods stuck Pending

```bash
kubectl -n <ns> describe pod <pod> | sed -n '/Events/,$p'
kubectl get nodes --show-labels
kubectl describe node <node> | grep -A12 "Allocated resources"
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

| Event message contains | Cause | Remedy | Prevention |
|---|---|---|---|
| `Insufficient cpu` / `Insufficient memory` | Cluster genuinely full at the **request** level | Add nodes, lower requests, or delete lower-priority work | Cluster Autoscaler/Karpenter; right-size requests |
| `didn't match Pod's node affinity/selector` | Your `nodeSelector`/affinity excludes every node | Fix the label, or label a node | Validate labels in CI |
| `had untolerated taint {key: value}` | Node is reserved | Add a matching `toleration`, or target another pool | Document which pools are tainted |
| `node(s) had volume node affinity conflict` | The PV is in zone A, the pod is being placed in zone B | Use `volumeBindingMode: WaitForFirstConsumer`; recreate the PVC | Always set that binding mode |
| `pod has unbound immediate PersistentVolumeClaims` | Storage isn't provisioning | Check StorageClass name and CSI driver pods | Set a default StorageClass |
| `Too many pods` | Hit the node's max-pods cap | Bigger nodes, more nodes, or (EKS) prefix delegation | Plan pods-per-node with IP limits |
| `node(s) exceed max volume count` | Node can't attach more disks | Spread the workload; use larger nodes | Know your instance's attachment limit |
| `0/N nodes are available: N node(s) didn't match pod topology spread constraints` | `DoNotSchedule` skew can't be satisfied | Add capacity in the missing zone, or relax to `ScheduleAnyway` | Ensure node groups exist in every zone you require |
| `Insufficient nvidia.com/gpu` | No free GPU | Wait, scale the GPU pool, or check the device plugin DaemonSet is healthy | Monitor GPU allocation |
| Nothing at all — no events | The scheduler isn't running, or the pod has `nodeName` set manually | Check `kube-system` scheduler pods | — |

**Karpenter/NAP-specific:** if pods stay Pending with no node coming, check the provisioner's own logs:
```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=100
kubectl get nodepool,nodeclaim -o wide          # NodeClaim stuck = capacity or IAM problem
```
Common causes: instance-type requirements that match nothing, hitting the NodePool `limits`, EC2 capacity errors in the AZ, subnet out of IPs, or missing IAM permissions.

## 24.5 Image and registry problems

```bash
kubectl -n <ns> describe pod <pod> | grep -A5 Events
kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.containers[*].image}'
kubectl -n <ns> get sa <sa> -o yaml | grep -A3 imagePullSecrets
```

| Symptom | Cause | Remedy |
|---|---|---|
| `manifest unknown` / `not found` | Tag doesn't exist | Verify with `crane ls` / `aws ecr describe-images` / `az acr repository show-tags` |
| `unauthorized` / `authentication required` | No or wrong registry credentials | Add `imagePullSecrets`; on EKS confirm the node role has `AmazonEC2ContainerRegistryReadOnly`; on AKS run `az aks update --attach-acr <registry>` |
| `toomanyrequests` | Docker Hub rate limit | Mirror to ECR/ACR, or authenticate to Docker Hub |
| `dial tcp ... i/o timeout` | No network path to the registry | Private cluster needs a VPC endpoint / Private Link, or a NAT gateway |
| `no match for platform in manifest` | arm64 vs amd64 mismatch | Build multi-arch: `docker buildx build --platform linux/amd64,linux/arm64` |
| Pull is extremely slow | Huge image, cold node | Slim the image; use image streaming (AKS Artifact Streaming) or SOCI (EKS) |
| Image changed but pods run old code | You reused a mutable tag | Pin by digest; `kubectl rollout restart` won't help if the tag didn't change |

## 24.6 Crash loops and restarts

```bash
kubectl -n <ns> logs <pod> --previous --tail=200
kubectl -n <ns> describe pod <pod> | grep -A8 "Last State"
kubectl -n <ns> get pods --sort-by='.status.containerStatuses[0].restartCount'
```

| Finding | Meaning | Action |
|---|---|---|
| `Reason: OOMKilled`, exit 137 | Memory limit hit | Raise `limits.memory` (and set `requests` equal to it). Then profile for a leak. Java: set `-XX:MaxRAMPercentage=75` so the JVM respects the container limit |
| Exit 1 with a stack trace | Application bug or bad config | Fix config/env; roll back |
| Exit 127 | Binary missing | Check the image and `command:` |
| Restarts climb every ~30–60s with healthy logs | **Liveness probe is killing a healthy app** | Increase `failureThreshold`/`periodSeconds`, add a `startupProbe`, or remove the liveness probe |
| Crashes only under load | Resource starvation or a race | Check throttling (24.10); load-test in staging |
| Only one replica crashes | Node-specific problem | `kubectl get pod -o wide` → cordon and investigate that node |
| Crashes right after a deploy | The new version is bad | `kubectl rollout undo` immediately |

## 24.7 Probe failures

| Symptom | Identify | Fix |
|---|---|---|
| `Readiness probe failed: HTTP probe failed with statuscode: 404` | `describe pod` Events | Wrong path — probes hit the **container port**, not the Service port |
| `connection refused` | App not listening yet, or on a different port/interface | Bind to `0.0.0.0`, not `127.0.0.1`; add a `startupProbe` |
| `context deadline exceeded` | Probe timed out | Raise `timeoutSeconds`; the app may be blocked on a slow dependency |
| Probe passes locally, fails in cluster | Probe checks a downstream dependency | **Readiness should test only this pod.** Don't cascade failures |
| Everything restarts during a traffic spike | Liveness probe times out under load | This is how a slowdown becomes an outage. Loosen or remove liveness |

## 24.8 Networking: services, DNS, ingress

### Service has no endpoints (the most common networking bug)
```bash
kubectl -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>
kubectl -n <ns> get svc <svc> -o jsonpath='{.spec.selector}'; echo
kubectl -n <ns> get pods --show-labels
```
Empty endpoints means one of exactly three things: **(a)** the selector doesn't match any pod labels, **(b)** the pods exist but are failing readiness, **(c)** `targetPort` doesn't match the container's port name/number.

### DNS problems
```bash
kubectl -n <ns> run dns --rm -it --image=nicolaka/netshoot --restart=Never -- \
  sh -c "nslookup kubernetes.default; nslookup <svc>.<ns>.svc.cluster.local; cat /etc/resolv.conf"
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100
kubectl -n kube-system top pods -l k8s-app=kube-dns
```

| Symptom | Cause | Remedy |
|---|---|---|
| Intermittent `NXDOMAIN` or slow lookups | CoreDNS CPU-starved or under-replicated | Scale CoreDNS; on EKS use the cluster-proportional autoscaler; enable NodeLocal DNSCache (AKS: LocalDNS mode) |
| Every external lookup is slow | `ndots:5` causes 4 failed searches first | Use FQDNs with a trailing dot, or tune `dnsConfig.options.ndots` |
| DNS works, then stops after a policy change | NetworkPolicy blocks UDP/TCP 53 | Add an explicit egress allow to `kube-system` |
| Only some pods can't resolve | Pod stuck with stale DNS config, or on a broken node | Restart the pod; check the node's CNI |

### Ingress / load balancer
| Symptom | Identify | Remedy |
|---|---|---|
| `EXTERNAL-IP` stuck `<pending>` | `kubectl describe svc` | No LB controller installed; missing subnet tags; hit a cloud LB quota; wrong `loadBalancerClass` |
| LB exists but returns 502/503 | Cloud console → target/backend health | Pods failing readiness; wrong `targetPort`; security group/NSG blocking the health-check port |
| 504 timeouts under load | LB idle/request timeout shorter than the app's response | Raise the LB timeout annotation; look for slow queries |
| Ingress created, nothing happens | `kubectl get ingress -o wide` shows no ADDRESS | `ingressClassName` doesn't match any controller; controller pod is down |
| TLS fails / wrong certificate | `kubectl describe certificate` | cert-manager can't complete the challenge; DNS record missing; secret in the wrong namespace |
| Client IP shows as the node IP | SNAT | Set `externalTrafficPolicy: Local`, or use IP-target mode |

### NetworkPolicy
```bash
kubectl -n <ns> get networkpolicies
kubectl -n <ns> describe networkpolicy <name>
```
- Policies are **additive allow-lists**: once *any* policy selects a pod, everything not explicitly allowed is denied.
- Forgetting **egress to DNS** breaks everything in a way that looks like an app bug.
- Your CNI must enforce policy — Calico, Cilium, or Azure CNI Powered by Cilium. Plain `kubenet` silently ignores policies.

## 24.9 Storage problems

```bash
kubectl -n <ns> get pvc,pv
kubectl -n <ns> describe pvc <pvc>
kubectl get storageclass
kubectl -n kube-system get pods | grep -i csi
```

| Symptom | Cause | Remedy |
|---|---|---|
| PVC stuck `Pending`, no events | No default StorageClass, or the named class doesn't exist | `kubectl get sc`; set a default; fix the name |
| PVC `Pending` with `waiting for a volume to be created` | CSI driver missing or crashing | Install/repair the EBS CSI / Azure Disk CSI driver; check its IAM/identity permissions |
| `FailedAttachVolume` / `Multi-Attach error` | A `ReadWriteOnce` disk is still attached to another node | Delete the old pod; if the node is gone, force-delete it. Use `ReadWriteMany` (EFS / Azure Files) if you truly need shared access |
| `FailedMount ... timeout expired` | Slow attach, or a filesystem problem | Check node events and the CSI node pod logs |
| Pod won't schedule after a node dies | Zonal disk pins the pod to one AZ | Expected. Use replicated storage or a StatefulSet per zone |
| Disk full inside the pod | Volume undersized, or logs written to disk | Expand the PVC (`spec.resources.requests.storage`); log to stdout instead |
| Can't shrink a volume | Kubernetes doesn't support shrinking | Create a new smaller PVC and copy the data |
| PV stuck `Released`, storage still billed | `Retain` reclaim policy | Delete the PV and the underlying cloud disk manually |
| `permission denied` writing to the volume | UID mismatch | Set `fsGroup` in the pod `securityContext` |

## 24.10 Node problems

```bash
kubectl get nodes -o wide
kubectl describe node <node> | grep -A15 Conditions
kubectl describe node <node> | grep -A10 "Allocated resources"
kubectl get events --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp
```

| Node condition / symptom | Meaning | Remedy |
|---|---|---|
| `NotReady` | Kubelet stopped reporting | Check the VM in the cloud console, kubelet service, and CNI pods. If it doesn't recover in ~10 min, terminate it and let the node group replace it |
| `MemoryPressure` | Node low on RAM; eviction imminent | Raise requests so the scheduler stops overpacking; add nodes |
| `DiskPressure` | Root/ephemeral disk filling | Usually image sprawl or container logs. Increase disk size; enable image GC; cap log size |
| `PIDPressure` | Too many processes | A runaway app forking; set `pids` limits |
| `NetworkUnavailable` | CNI not configured | Check the CNI DaemonSet on that node |
| Node flaps Ready/NotReady | Under-resourced node or network instability | Reserve system resources (`--kube-reserved`, `--system-reserved`); use larger nodes |
| Pods evicted repeatedly | Node is oversubscribed | Requests are too low or absent. Fix the requests |
| Node exists in cloud but not in `kubectl get nodes` | Bootstrap failure | Check user data/bootstrap logs, IAM/identity, security groups, and that the node can reach the API endpoint |
| CPU throttling despite low usage | CPU limits | `cat /sys/fs/cgroup/cpu.stat` inside the pod → rising `nr_throttled` means raise or remove the limit |

## 24.11 Control plane and API server

| Symptom | Identify | Remedy |
|---|---|---|
| `kubectl` hangs or times out | `kubectl get --raw='/readyz?verbose'` | Network/VPN/private-endpoint issue, or the API server is overloaded |
| `error: You must be logged in to the server (Unauthorized)` | Token expired | Refresh credentials: `aws eks update-kubeconfig` / `az aks get-credentials` |
| `The connection to the server ... was refused` | Wrong context or endpoint | `kubectl config current-context` |
| `Error from server (Timeout)` on apply | An **admission webhook** is down | `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` — a failing webhook with `failurePolicy: Fail` blocks all writes. Delete or fix it |
| Everything is slow cluster-wide | `apiserver_request_duration_seconds`, etcd latency | Too many watches/objects, a hot controller, or slow etcd disks. On EKS/AKS, open a support ticket |
| `429 Too Many Requests` | Client throttled by API Priority and Fairness | Add backoff to your tooling; stop tight `kubectl` loops in scripts |
| `etcdserver: request is too large` | An object over ~1.5 MB | Don't put large blobs in ConfigMaps/Secrets |
| Certificate expiry errors | `kubectl get csr`; node kubelet logs | Managed clouds rotate automatically; self-managed clusters need `kubeadm certs renew` |

## 24.12 RBAC, identity, and access

| Symptom | Identify | Remedy |
|---|---|---|
| `Error from server (Forbidden): ... cannot list resource "pods"` | `kubectl auth can-i --list` | Missing Role/RoleBinding. Grant the narrowest role that works |
| Works for you, not for CI | `kubectl auth can-i <verb> <res> --as=system:serviceaccount:<ns>:<sa>` | Bind the role to the service account |
| Pod can't call AWS APIs | `kubectl -n <ns> describe sa <sa>`; check for the projected token | IRSA: role ARN annotation + OIDC provider + trust policy must all match. Pod Identity: check the association and that the agent is running |
| Pod can't call Azure APIs | Check the `azure.workload.identity/use: "true"` label and client-id annotation | Federated credential subject must match `system:serviceaccount:<ns>:<sa>` exactly |
| `User ... is not authorized to perform: eks:DescribeCluster` | Your IAM identity isn't mapped | Add an **EKS access entry** (or the legacy `aws-auth` ConfigMap entry) |
| AKS: `Forbidden` after Entra integration | Azure RBAC roles missing | Assign "Azure Kubernetes Service RBAC Reader/Writer/Admin" at the cluster scope |
| Everything works but nothing is auditable | Audit logging off | Enable EKS control plane logging / AKS diagnostic settings |

## 24.13 Stuck deletions and finalizers

```bash
kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.finalizers}'; echo
kubectl -n <ns> get ns <ns> -o json | jq '.status.conditions'
```
- A resource stuck `Terminating` is waiting on a **finalizer** owned by some controller. Find out which controller and why it can't finish — that's the real bug.
- A namespace stuck `Terminating` usually means an **APIService is unavailable** (a dead metrics/webhook API). Fix or delete the broken APIService: `kubectl get apiservices | grep False`.
- Force-removing finalizers is a last resort and **can orphan cloud resources** (disks, load balancers). Clean those up manually afterward.
```bash
kubectl -n <ns> patch pod <pod> -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete pod <pod> -n <ns> --force --grace-period=0
```

## 24.14 Autoscaling and metrics

| Symptom | Identify | Remedy |
|---|---|---|
| `kubectl top` → `Metrics API not available` | `kubectl -n kube-system get deploy metrics-server` | Install metrics-server (EKS: community add-on). Wait 60s for the first sample |
| metrics-server `x509: certificate signed by unknown authority` | `kubectl -n kube-system logs deploy/metrics-server` | Enable kubelet serving-cert rotation, or `--kubelet-insecure-tls` for test clusters |
| HPA shows `<unknown>/50%` | `kubectl describe hpa` | The pods have **no CPU requests**. HPA computes a % of the request |
| HPA won't scale up | `kubectl describe hpa` → Conditions/Events | Already at `maxReplicas`; metric below target; or `ScalingLimited` |
| HPA flaps up and down | Events show rapid changes | Increase `behavior.scaleDown.stabilizationWindowSeconds` |
| Nodes never scale up | Autoscaler logs | Cluster Autoscaler: node group `maxSize` reached, or ASG limits. Karpenter: NodePool `limits`, instance requirements, or IAM |
| Nodes never scale **down** | Autoscaler logs list blockers | Pods with local storage, no PDB-safe eviction, `safe-to-evict: false`, kube-system pods without a PDB, or a pod that can't be moved |
| KEDA doesn't scale | `kubectl describe scaledobject` | TriggerAuthentication wrong, unreachable metric source, or a bad query |
| Scale-up is too slow | Time between Pending and Running | Pre-provision with "pause pod" overprovisioning; shrink images; use Karpenter/NAP |

## 24.15 Upgrade failures

| Symptom | Cause | Remedy |
|---|---|---|
| Node drain hangs forever | A PDB that can never be satisfied | `kubectl get pdb -A` → find `ALLOWED DISRUPTIONS: 0`. Temporarily relax it or scale up replicas |
| Drain blocked by a bare pod | Pods not owned by a controller aren't evicted by default | `--force` (they will be deleted, not rescheduled) |
| Upgrade fails on an add-on | Add-on version incompatible with the new Kubernetes version | Upgrade CNI/CSI/CoreDNS **before** the control plane; check the provider's compatibility matrix |
| Workloads break after upgrade | A removed API version | Pre-scan with `kubent`/`pluto` or EKS upgrade insights / Azure Advisor. On EKS you can now **roll back within 7 days** |
| Node pool won't upgrade | Quota, capacity, or a stuck node | Check cloud quotas; increase `maxSurge`; delete the stuck node |
| Version skew error | Nodes more than 3 minors behind the control plane | Upgrade nodes; never skip so far again |
| kubectl "unexpected server response" | kubectl too old/new | Keep kubectl within one minor of the API server |

## 24.16 Performance and latency

```bash
# CPU throttling — check this FIRST for unexplained latency
kubectl -n <ns> exec <pod> -- cat /sys/fs/cgroup/cpu.stat | grep -E "nr_throttled|throttled_usec"

# Memory headroom
kubectl top pods -n <ns> --sort-by=memory

# Is traffic crossing zones?
kubectl get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName' -n <ns>
kubectl get nodes -L topology.kubernetes.io/zone
```

| Symptom | Likely cause | Remedy |
|---|---|---|
| p99 latency spikes, low average CPU | CPU limit throttling | Raise or remove `limits.cpu`; keep requests accurate |
| Latency rises with replica count | Downstream (DB/cache) saturation, or connection-pool exhaustion | Scale the dependency; tune pool sizes |
| Slow first request after idle | Cold start / JIT warmup | Keep a warm floor of replicas; use a `startupProbe` |
| Random slow requests | Cross-AZ hops or a noisy neighbor node | `trafficDistribution: PreferClose`; use dedicated node pools |
| Everything got slower after a node event | Pods repacked onto fewer nodes | Check `kubectl top nodes`; add capacity |
| Slow DNS-heavy workloads | `ndots` search-domain expansion | Use FQDNs; enable node-local DNS cache |
| Disk-bound app is slow | Wrong storage class | gp3 with provisioned IOPS / Premium SSD v2; never network file storage for databases |

## 24.17 EKS-specific problems

| Symptom | Cause | Remedy |
|---|---|---|
| Pods `ContainerCreating`, CNI error `failed to assign an IP address` | Subnet or ENI IP exhaustion | Enable prefix delegation (`ENABLE_PREFIX_DELEGATION=true`), add secondary CIDRs, or use bigger subnets |
| Node joins but is `NotReady` | CNI/kube-proxy add-on failing, or missing IAM policy | Check `aws-node` and `kube-proxy` DaemonSets and the node role policies |
| `Service type: LoadBalancer` stays pending | No AWS Load Balancer Controller (classic mode), or missing subnet tags | Install the controller; tag subnets `kubernetes.io/role/elb` and `/internal-elb` |
| Ingress creates one ALB per rule | `IngressGroup` unsupported in Auto Mode | Combine rules into a single Ingress |
| Pod can't assume its IAM role | IRSA misconfiguration | Verify the OIDC provider exists, the trust policy `sub` matches, and the SA annotation is correct. Prefer **EKS Pod Identity** |
| Fargate pod won't start | Missing Fargate profile match, or a DaemonSet | Fargate ignores DaemonSets; check the profile's namespace/label selectors |
| metrics-server fails on Fargate | Port 10250 is reserved | Use the EKS add-on version (port 10251) |
| Nodes replaced unexpectedly | Auto Mode `expireAfter` ephemeral-node policy, or spot reclamation | Expected behavior; set PDBs and disruption budgets |
| `aws-auth` edits don't take effect | Cluster migrated to access entries | Use `aws eks create-access-entry` instead |
| Cluster stuck upgrading | Add-on incompatibility or a blocking PDB | Check upgrade insights; fix, then retry. Rollback available within 7 days |

## 24.18 AKS-specific problems

| Symptom | Cause | Remedy |
|---|---|---|
| `SubnetIsFull` / pods can't get IPs | Azure CNI node-subnet mode exhausted the VNet | Migrate to **Azure CNI Overlay** |
| Node pool scale-up fails: `QuotaExceeded` | Regional vCPU quota | Request a quota increase; or use a different VM size/region |
| `SpotVMEvictionError` | Spot capacity reclaimed | Expected. Keep an on-demand pool for baseline |
| Cluster stuck in `Upgrading`/`Failed` | Blocked drain or a stuck node | `az aks nodepool list -o table`; resolve PDBs, then `az resource update` to reconcile |
| `az aks get-credentials` works but `kubectl` says Forbidden | Azure RBAC enabled without a role assignment | Assign an AKS RBAC role at cluster scope |
| Can't pull from ACR | Managed identity not attached to the registry | `az aks update -n <cluster> -g <rg> --attach-acr <acr>` |
| Load balancer stuck creating | Outbound type / NSG / quota | Check the `MC_*` resource group's LB and public IP quota |
| App Routing ingress not reachable | DNS zone or IngressClass mismatch | `kubectl get ingressclass`; verify ExternalDNS records |
| Node image out of date, CVEs flagged | Node image upgrades are separate from version upgrades | Set `--node-os-upgrade-channel NodeImage` |
| Workload identity token errors | Federated credential subject mismatch | It must be exactly `system:serviceaccount:<ns>:<sa>` |
| Free tier cluster degraded, no SLA credit | Free tier has no financial SLA | Move to Standard tier for production |

## 24.19 Kafka / Strimzi-specific problems

| Symptom | Identify | Remedy |
|---|---|---|
| Operator logs `Unsupported Kafka.spec.kafka.version` | Version not supported by this operator | Upgrade the operator first, then Kafka, one step at a time |
| Broker pods `Pending` | Storage class or zone mismatch | Check PVCs; use `WaitForFirstConsumer` |
| `NotEnoughReplicasException` on produce | Fewer in-sync replicas than `min.insync.replicas` | A broker is down — restore it. Don't lower the setting to hide the problem |
| Consumer lag climbing | Consumers too slow or too few | Scale consumers up to the partition count; use KEDA on lag; profile the handler |
| Rebalancing storms | Slow processing exceeds `max.poll.interval.ms` | Raise it, or process fewer records per poll |
| `UNKNOWN_TOPIC_OR_PARTITION` | Topic doesn't exist or the client points at the wrong cluster | Check the bootstrap address and the KafkaTopic resource |
| Under-replicated partitions after a node event | Replication catching up, or a stuck broker | Watch the metric; use Cruise Control (`KafkaRebalance`) to rebalance |
| Disk filling fast | Retention too long, or a hot partition | Shorten `retention.ms`; expand the PVC (you can grow, never shrink) |
| Cluster won't roll during an upgrade | Quorum can't be maintained | Never have fewer than 3 controllers; check the PDB |
| CRDs rejected after upgrade | `v1beta2` → `v1` API migration | Use the Strimzi API conversion tool |

## 24.20 Cost anomalies

| Symptom | Identify | Remedy |
|---|---|---|
| Bill jumped, traffic didn't | Cost Explorer / Azure Cost Analysis by service | Usually an autoscaler runaway, a stuck Job loop, or forgotten load balancers |
| Nodes at 15% CPU but "full" | `kubectl describe node` allocated vs `kubectl top node` | Requests are inflated. Run VPA in recommend mode |
| Storage cost keeps rising | `kubectl get pv` + cloud disk list | Orphaned `Released` PVs and unattached disks |
| Data transfer is a top line item | VPC flow logs / Azure network metrics | Cross-AZ chatter. Use `PreferClose` and zone-aware routing |
| Log ingestion is huge | Log Analytics / CloudWatch usage by table | Drop debug logs; sample; shorten retention |
| Many small load balancers | `kubectl get svc -A --field-selector spec.type=LoadBalancer` | Consolidate behind one Ingress/Gateway |

## 24.21 What to collect before escalating

When you open a ticket with AWS or Microsoft — or hand off to another engineer — include all of this. It cuts resolution time in half.

```bash
CLUSTER=my-cluster; NS=production; POD=api-xxxx
{
  echo "=== VERSION ==="        ; kubectl version -o yaml
  echo "=== NODES ==="          ; kubectl get nodes -o wide
  echo "=== NODE DETAIL ==="    ; kubectl describe nodes
  echo "=== POD ==="            ; kubectl -n $NS describe pod $POD
  echo "=== POD LOGS ==="       ; kubectl -n $NS logs $POD --all-containers --tail=500
  echo "=== PREVIOUS LOGS ===" ; kubectl -n $NS logs $POD --all-containers --previous --tail=500
  echo "=== EVENTS ==="         ; kubectl get events -A --sort-by=.lastTimestamp | tail -100
  echo "=== SYSTEM PODS ==="    ; kubectl -n kube-system get pods -o wide
  echo "=== WEBHOOKS ==="       ; kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations
  echo "=== APISERVICES ==="    ; kubectl get apiservices | grep -v True
  echo "=== PDBs ==="           ; kubectl get pdb -A
  echo "=== STORAGE ==="        ; kubectl get pvc,pv,storageclass -A
} > cluster-diagnostics-$(date +%Y%m%d-%H%M).txt
```

**Also include:** the exact time the problem started (with time zone), what changed immediately before, whether it affects one pod / one node / one zone / everything, what you've already tried, and the cluster ARN or resource ID.

**Vendor collectors:** AWS — `eksctl utils describe-stacks` and the EKS Log Collector script on the affected node. Azure — `az aks kollect` / the AKS Periscope tool, plus `az aks show -o json`.

## 24.22 The prevention checklist

Most incidents in this part are prevented by nine things:

- ☐ **Resource requests and limits on everything** — prevents oversubscription, eviction, and unschedulable surprises
- ☐ **Readiness probes on everything; liveness probes used sparingly** — prevents 502s and restart storms
- ☐ **3+ replicas, spread across 3 zones, with a workable PDB** — prevents single-failure outages and drain deadlocks
- ☐ **Pinned image digests from a private registry** — prevents "it changed by itself" and rate limits
- ☐ **Overlay/prefix-delegation networking** — prevents IP exhaustion
- ☐ **`WaitForFirstConsumer` storage binding** — prevents zone-conflict scheduling failures
- ☐ **Alerting on the symptoms in Part 11**, plus version end-of-support dates
- ☐ **Staged upgrades**: non-prod first, add-ons before control plane, one minor at a time
- ☐ **GitOps** — so "what changed?" is always answerable in ten seconds

---

# PART 25 — EKS in depth, and the expanded EKS vs AKS differences

Part 12 introduced Amazon EKS and Part 14 compared it to AKS in a table. This part goes deeper on EKS and then lays out **every meaningful difference between the two services as detailed bullet points**, dimension by dimension.

## 25.1 EKS architecture, expanded

**The control plane**
- Runs entirely in an **AWS-owned VPC**, one dedicated control plane per cluster — not shared multi-tenant infrastructure.
- **etcd is spread across three availability zones**; at least two API server instances run in separate AZs behind a Network Load Balancer.
- AWS owns patching, scaling, certificate rotation, and etcd backups. You cannot SSH to it or see its pods.
- Backed by a **99.95% availability SLA** on the API endpoint.
- Billed at a **flat $0.10/hour per cluster** (~$73/month) whether the cluster is empty or runs 5,000 nodes — which makes many small clusters relatively expensive and argues for fewer, larger, namespace-partitioned clusters.
- Reachable via a **public endpoint, a private endpoint, or both**. Private-only is the security best practice, accessed through a bastion, SSM Session Manager, VPN, or Direct Connect.

**The data plane, in order of how much AWS manages**
- **EKS Auto Mode** — AWS provisions, patches, secures, and replaces nodes. Karpenter runs inside AWS-owned infrastructure, not as pods in your account. Nodes are **ephemeral by design** (replaced on a rolling schedule for security). ~40% premium per vCPU over raw EC2, usually offset by higher utilization and eliminated ops labor.
- **Managed node groups** — AWS creates and lifecycle-manages EC2 Auto Scaling Groups, handles cordon/drain during upgrades, and integrates with Cluster Autoscaler. You pick instance types and sizes.
- **Self-managed Karpenter** — groupless provisioning with total control over `NodePool` and `EC2NodeClass`, including custom AMIs and Bottlerocket. Best cost efficiency; you own Karpenter's own upgrades.
- **Fargate** — one micro-VM per pod, no nodes at all. No DaemonSets, no privileged pods, no GPUs, fixed size increments, port 10250 reserved.
- **Self-managed EC2, EKS Hybrid Nodes, and Outposts** — your own instances or on-prem hardware joined to the EKS control plane. Maximum control, maximum responsibility.

**Add-ons**
- AWS-owned add-ons (VPC CNI, kube-proxy, CoreDNS, EBS/EFS CSI, Pod Identity Agent, Node Monitoring Agent, Mountpoint for S3) are versioned and upgraded through the EKS API rather than raw YAML.
- **Community add-ons** (metrics-server, kube-state-metrics, cert-manager, prometheus-node-exporter, fluent-bit, external-dns) are packaged and lifecycle-managed by AWS, but functionally supported by the community.
- Add-on version compatibility is the most common cause of a failed EKS upgrade — always upgrade add-ons before the control plane.

**Networking**
- The **Amazon VPC CNI** assigns every pod a real, routable VPC IP. Security groups, VPC flow logs, and Transit Gateway all work at pod level.
- The cost: **ENI and IP-per-instance limits**. A small instance may support only 8–29 pod IPs. **Prefix delegation** (`/28` blocks per ENI) raises this dramatically and should be on by default.
- **Security Groups for Pods** allows per-pod security groups — genuinely unique to EKS and useful for regulated workloads talking to RDS.
- Alternatives: Cilium or Calico in overlay mode when IP conservation matters more than VPC-native addressing.

**Identity**
- **EKS Pod Identity** (recommended) — a simple API association between a ServiceAccount and an IAM role, no per-cluster OIDC provider, roles reusable across clusters.
- **IRSA** — the older OIDC-based mechanism; still required for some cross-account and non-EKS scenarios.
- **Access entries** have replaced the fragile `aws-auth` ConfigMap for mapping IAM principals to Kubernetes RBAC. Editing `aws-auth` on a migrated cluster silently does nothing.

**Operational features worth knowing**
- **Version rollback (July 2026)** — revert the control plane one minor version within 7 days, preserving etcd data, workloads, and volumes, with automated pre-checks.
- **Upgrade insights** — automated scans for deprecated API usage, version skew, and add-on incompatibility before you upgrade.
- **ARC zonal shift and autoshift** — automatically drains in-cluster traffic away from an impaired AZ; free and configuration-less on Auto Mode.
- **Node Monitoring Agent + node auto-repair** — detects unhealthy nodes (GPU faults, kernel issues) and replaces them.
- **Extended support** — an extra ~12 months per version at a higher per-cluster hourly rate. A safety valve, not a strategy.

## 25.2 EKS vs AKS: the expanded differences

### Cost model
- **EKS** charges $0.10/hour per cluster with no free option; **AKS** offers a genuinely **free control plane tier**, so dev/test and small clusters are cheaper on Azure.
- **AKS Standard tier** costs about the same as EKS ($0.10/hr) and is what you must use in production to get an SLA.
- **AKS Premium tier** adds Long Term Support at a higher price; **EKS extended support** is the equivalent concept but priced as a surcharge on the standard cluster rate.
- **EKS Auto Mode** adds a per-vCPU management premium (~40%) on top of EC2; **AKS Automatic** does not charge a separate compute premium — you pay the tier plus VM cost.
- **Practical effect:** many small clusters favor AKS; a few large clusters make the control plane fee irrelevant on either.

### Ease of getting to production
- **AKS Automatic** is the more opinionated "good cluster by default" — it ships monitoring (managed Prometheus + Grafana + Container Insights), Azure RBAC, workload identity, deployment safeguards, auto-upgrade, and NAP all pre-wired, with **SLA-backed pod readiness**.
- **EKS Auto Mode** automates compute, storage, networking, and load balancing, but **you still choose and install your own observability stack** — it's infrastructure automation more than platform automation.
- AKS **enforces** good practice (deployment safeguards will reject pods without probes or limits); EKS **enables** it but leaves policy to you (Kyverno, OPA).
- EKS gives more knobs; AKS gives more defaults. That's the core cultural difference.

### Compute and node management
- **EKS** has far more instance shapes (hundreds of EC2 types, Graviton across generations, Inferentia/Trainium accelerators) than AKS in most regions.
- **Karpenter on EKS** is more mature than **Node Auto Provisioning on AKS** (which is Karpenter-for-Azure) — NAP reached feature parity later and still trails on some consolidation and disruption controls, though 2026 added Balanced consolidation and in-VM spot rebalancing.
- **AKS requires a system node pool** (which you should taint `CriticalAddonsOnly`); EKS has no such structural requirement, though a dedicated system pool is still best practice.
- **AKS user node pools can scale to zero**; EKS managed node groups can too, but Auto Mode makes the question mostly moot.
- **Windows**: both support Windows Server 2025, but **EKS Auto Mode does not support Windows at all** — you must use classic node groups. AKS supports Windows in Automatic and Standard.
- **Serverless pods**: EKS uses **Fargate** (per-pod micro-VM, mature, but no DaemonSets); AKS uses **Virtual Nodes / ACI** (less commonly used in production).

### Networking
- **EKS default = VPC-native**: every pod gets a real VPC IP. Powerful (per-pod security groups, flow logs) but leads to **IP exhaustion**, the single most common EKS design mistake.
- **AKS default = Azure CNI Overlay**: pods get overlay IPs, so VNet address space is never the constraint. Simpler at scale, at the cost of not being directly VNet-routable.
- **AKS ships Cilium as a supported data plane** ("Azure CNI Powered by Cilium") with eBPF policy and Retina/Hubble observability as first-class managed options; on EKS, Cilium is a self-installed choice.
- **EKS's Security Groups for Pods** has no direct AKS equivalent.
- Ingress: EKS leans on the **AWS Load Balancer Controller** (ALB/NLB) or Auto Mode's built-in equivalent; AKS offers the managed **App Routing** add-on and the **Istio-based service mesh add-on**, both now supporting Gateway API.

### Identity and access
- **EKS**: two mechanisms to learn — IRSA (OIDC) and Pod Identity (newer, simpler) — plus access entries for mapping IAM users/roles to RBAC. IAM is enormously powerful and correspondingly complex.
- **AKS**: **Workload Identity** for pods, **Microsoft Entra ID** for humans, and **Azure RBAC for Kubernetes** so cluster permissions can be managed entirely in Azure RBAC rather than Kubernetes RBAC.
- AKS's model is generally simpler to reason about for organizations already standardized on Entra ID; EKS's is more granular and more portable across accounts.

### Observability
- **AKS** includes managed Prometheus, Azure Managed Grafana, and Container Insights as add-ons you toggle on — and **metrics-server is installed and managed for you**.
- **EKS does not install metrics-server**; you add it as a community add-on. Monitoring is Amazon Managed Prometheus + Managed Grafana + CloudWatch Container Insights, assembled by you.
- **Practical effect:** an AKS cluster is observable in one click; an EKS cluster needs a deliberate observability project.

### Upgrades and lifecycle
- **AKS is usually first to GA a new Kubernetes minor version**, and it offers **auto-upgrade channels** (`patch`, `stable`, `rapid`, `node-image`) plus **planned maintenance windows** — the strongest upgrade automation of the big three.
- **AKS Long Term Support** (Premium tier) gives two years on a version, including backported fixes. **EKS extended support** gives roughly one extra year, billed as a surcharge.
- **EKS's unique advantage is version rollback** — revert the control plane within 7 days if an upgrade goes badly. AKS has no equivalent; you roll forward.
- **AKS Fleet Manager** orchestrates staged upgrades across many clusters; the EKS equivalent usually means building it yourself or using a third-party platform.
- Both support **N, N-1, N-2**; AKS adds an N-3 "platform support" tier where Azure helps with infrastructure but not Kubernetes itself.

### Storage
- **EKS**: EBS CSI (zonal block), EFS CSI (shared NFS), FSx, and Mountpoint for S3. Zonal disks pin pods to an AZ.
- **AKS**: Azure Disk CSI (zonal block), Azure Files CSI (SMB/NFS shared), Azure Blob CSI, and Azure Container Storage for high-performance local NVMe pooling.
- AKS ships **default StorageClasses** (`managed-csi`, `managed-csi-premium`) out of the box; **EKS Auto Mode ships none** — you must create one, which surprises people on their first StatefulSet.

### Security and compliance
- Both support private API endpoints, encryption at rest with customer-managed keys, and audit logging (CloudWatch vs Log Analytics).
- **AKS bundles Azure Policy/Gatekeeper and Microsoft Defender for Containers as managed add-ons**; on EKS, policy usually means self-installing Kyverno or Gatekeeper, and runtime security means GuardDuty EKS Runtime Monitoring or a third party.
- **EKS's IAM integration is finer-grained** (per-pod security groups, per-pod IAM roles, resource-level IAM conditions); **AKS's Entra integration is smoother** for human identity and conditional access.

### Ecosystem and portability
- Both run **upstream-conformant Kubernetes** — your manifests move between them with changes only to storage classes, ingress classes, identity annotations, and load balancer annotations.
- **EKS has the larger third-party ecosystem** (EKS Blueprints, more Helm charts tested against it, more community documentation).
- **AKS has tighter first-party integration** (GitOps/Flux extension, AI Toolchain Operator/KAITO for model serving, Backup for AKS, Cost Analysis) — more of the platform is "included" rather than assembled.

### When to choose which
- **Choose EKS** if you're already deep in AWS, need maximum instance/accelerator choice, want per-pod security groups or per-pod IAM, run cost-sensitive workloads where Karpenter's bin-packing pays for itself, or need an upgrade rollback safety net.
- **Choose AKS** if you want the lowest-effort path to a well-configured production cluster, are standardized on Entra ID and Azure governance, run many small clusters where a free control plane matters, need Windows containers with modern autoscaling, or value auto-upgrade channels and LTS.
- **Choose neither by feature list alone** — the deciding factor is almost always which cloud your data, identity provider, and on-call team already live in.

---
# PART 26 — History of changes: what changed, and what's changing now

## 26.1 The timeline

| When | What happened | Why it mattered |
|---|---|---|
| 2003–2013 | Google runs **Borg** internally | Proved container orchestration works at planetary scale |
| Mar 2013 | **Docker** released | Made containers usable by ordinary developers |
| Jun 2014 | **Kubernetes** open-sourced by Google | The ideas of Borg, rebuilt in the open |
| Jul 2015 | **v1.0** + donated to the **CNCF** | No single vendor owns it |
| 2016 | **Helm** and **Operators** appear | Packaging and automated day-2 operations |
| 2017 | Docker, AWS, and Azure all adopt Kubernetes | The orchestrator wars end |
| 2018 | **EKS** and **AKS** go GA; Kubernetes is the first CNCF project to *graduate* | Managed Kubernetes becomes the norm |
| 2019 | **CRDs go GA** (v1.16); IRSA on EKS | Anyone can extend the Kubernetes API |
| 2020 | **Dockershim deprecation announced** (v1.20) | Enormous confusion; images were never affected |
| 2021 | **Ingress GA**; **CSI/CRI/CNI** interfaces mature | Standard plug points for storage, runtime, network |
| **2022** | **v1.24: dockershim removed**; **v1.25: PodSecurityPolicy removed**, replaced by **Pod Security Admission** | Two of the biggest breaking changes ever |
| 2023 | **Gateway API GA**; **Karpenter** matures; **KRaft** ready in Kafka; **EKS Pod Identity** | Groupless autoscaling; Ingress's successor arrives |
| 2024 | **v1.28+: version skew widened to N-3**; **EKS Auto Mode** and **AKS Automatic** launch | "Easy mode" managed Kubernetes |
| **2025** | **Kafka 4.0 removes ZooKeeper**; **sidecar containers stable (1.33)**; **DRA core GA (1.34)** for GPUs | Stateful and AI workloads become first-class |
| **2026** | **Ingress NGINX retired (March)**; **cgroup v1 support removed (1.35)**; **in-place pod resize stable (1.35)**; **user namespaces GA (1.36)**; **IPVS kube-proxy removed (1.36)**; **EKS version rollback (July)** | Security hardening, smoother vertical scaling, safer upgrades |
| Aug 26, 2026 | **Kubernetes 1.37** ships | The cycle continues |

## 26.2 Things that are dead or dying — check your manifests

| Removed / retiring | Replaced by | Status |
|---|---|---|
| **ZooKeeper for Kafka** | KRaft | Removed in Kafka 4.0 |
| **PodSecurityPolicy** | Pod Security Admission, or Kyverno/OPA Gatekeeper | Removed in 1.25 |
| **Dockershim** | containerd / CRI-O | Removed in 1.24 |
| **Ingress NGINX** | Gateway API, Envoy Gateway, cloud-native controllers | **Retired March 2026 — no more security patches** |
| **IPVS mode in kube-proxy** | iptables mode or eBPF (Cilium) | Removed in 1.36 |
| **cgroup v1** | cgroup v2 | Kubelet refuses to start on v1 as of 1.35 |
| **gitRepo volumes** | init containers or a git-sync sidecar | Permanently disabled in 1.36 |
| **`Service.spec.externalIPs`** | LoadBalancer, NodePort, Gateway API | Deprecated in 1.36, removal planned for 1.43 |
| **AppArmor annotations** | seccomp, Pod Security Standards | Deprecated in 1.34 |
| **Amazon Linux 2 EKS AMIs** | Amazon Linux 2023 or Bottlerocket | No AL2 AMI from EKS 1.34 |
| **Azure Linux 2.0 on AKS** | Azure Linux 3.0 | Support ended Nov 2025; images removed Mar 2026 |
| **kubenet on AKS** | Azure CNI Overlay | Being phased out |
| **Azure pod-managed identity** | Azure Workload Identity | Deprecated |
| **Heapster** | metrics-server + Prometheus | Removed in 1.13 |
| **`kubectl run` creating Deployments** | `kubectl create deployment` | Changed long ago; `kubectl run` now makes a bare pod |

**Practical habit:** before every cluster upgrade, run a deprecated-API scanner (`kubent`, `pluto`, or EKS upgrade insights / Azure Advisor) against your live cluster *and* your Git repo. Deprecations, not bugs, are what break upgrades.

---

# PART 27 — Cheat sheet, glossary, and where to go next

## 27.1 The 30 commands you'll actually use

```bash
# Looking around
kubectl get nodes -o wide
kubectl get pods -A                              # -A = all namespaces
kubectl get all -n <namespace>
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl api-resources                            # every object type your cluster knows
kubectl explain deployment.spec.strategy         # built-in docs for any field

# Debugging (in this order)
kubectl describe pod <pod> -n <ns>               # Events at the bottom = the answer
kubectl logs <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous            # the crashed container
kubectl logs -f -l app=hello -n <ns>             # follow all pods of an app
kubectl exec -it <pod> -n <ns> -- /bin/sh
kubectl debug -it <pod> --image=busybox --target=<container>   # for distroless images
kubectl top nodes; kubectl top pods -n <ns>      # needs metrics-server

# Changing things
kubectl apply -f file.yaml
kubectl diff -f file.yaml                        # preview before applying
kubectl apply -f file.yaml --dry-run=server      # validate without applying
kubectl scale deployment/hello --replicas=5
kubectl set image deployment/hello web=repo/img:v2
kubectl rollout status|history|undo|restart deployment/hello
kubectl edit deployment/hello                    # fine for emergencies, bad as a habit

# Networking
kubectl port-forward svc/hello 8080:80
kubectl get endpointslices -n <ns>               # is anything actually behind this Service?
kubectl run tmp --rm -it --image=nicolaka/netshoot -- bash   # network debug toolbox

# Nodes
kubectl cordon|uncordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl describe node <node>

# Context
kubectl config get-contexts
kubectl config use-context <name>
```

**Add these two aliases and save an hour a week:**
```bash
alias k=kubectl
source <(kubectl completion bash)   # or zsh
```
Also look at **k9s** (a terminal dashboard), **stern** (multi-pod log tailing), and **kubectx/kubens**.

## 27.2 Debugging flowchart

```
Pod not working?
├─ STATUS: Pending
│   ├─ kubectl describe pod → "Insufficient cpu/memory"  → cluster is full; add nodes or lower requests
│   ├─ "didn't match node selector/affinity/taint"       → your scheduling rules are impossible
│   └─ "waiting for volume"                              → PVC unbound; check StorageClass and zone
├─ STATUS: ImagePullBackOff / ErrImagePull
│   └─ wrong image name/tag, or missing registry credentials (imagePullSecrets)
├─ STATUS: CrashLoopBackOff
│   └─ kubectl logs --previous → it's almost always your app: bad config, missing env var, can't reach DB
├─ STATUS: Running but 0/1 READY
│   └─ readiness probe is failing → wrong path, wrong port, or app is genuinely not ready
├─ STATUS: OOMKilled
│   └─ memory limit too low, or a leak. Raise the limit AND investigate.
└─ STATUS: Running, READY, but unreachable
    ├─ kubectl get endpointslices → empty means your Service selector doesn't match your pod labels
    ├─ check targetPort vs containerPort
    └─ check NetworkPolicy isn't blocking it
```

## 27.3 Glossary

- **Cluster** — a control plane plus its nodes, managed as one system
- **Node** — a machine (VM or physical) that runs pods
- **Node group / node pool** — a set of identical, interchangeable nodes managed together
- **Pod** — one or more co-located containers; the smallest schedulable unit
- **Container** — your app plus its dependencies, packaged and isolated
- **Control plane** — API server, etcd, scheduler, controller managers
- **Controller** — a loop that drives actual state toward desired state
- **Operator** — a controller that encodes *human* expertise about a specific app (Strimzi for Kafka, for example)
- **CRD** — Custom Resource Definition; teaches the API server a new object type (like `Kafka`)
- **Label** — a key/value tag on an object (`app: hello`)
- **Selector** — a query over labels ("everything with `app: hello`")
- **Annotation** — key/value metadata *not* used for selection (often config for controllers)
- **Taint / toleration** — a node's "keep out" sign, and a pod's permission slip
- **Affinity / anti-affinity** — "put me near / away from" rules
- **Requests / limits** — the minimum you're guaranteed and the maximum you may use
- **QoS class** — Guaranteed / Burstable / BestEffort; decides eviction order
- **PDB** — PodDisruptionBudget; caps *voluntary* disruption
- **HPA / VPA** — horizontal (more pods) / vertical (bigger pods) autoscaling
- **Cluster Autoscaler / Karpenter / NAP** — node-level autoscaling
- **CNI / CSI / CRI** — the standard plugs for networking, storage, and container runtime
- **KRaft** — Kafka's built-in metadata consensus, replacing ZooKeeper
- **Quorum** — a majority; why etcd and Kafka controllers use odd numbers
- **Drain / cordon** — safely empty a node / stop scheduling to it
- **Version skew** — the allowed version gap between control plane and nodes (currently up to N-3)

## 27.4 A learning path that actually works

1. **Week 1** — redo Part 1 twice, from memory the second time. Break things on purpose.
2. **Week 2** — deploy a real app of yours: Deployment + Service + ConfigMap + Secret + probes + requests.
3. **Week 3** — add Ingress/Gateway, an HPA, and a PodDisruptionBudget. Kill nodes and watch what happens.
4. **Week 4** — do Tutorials A and B on real clouds. Delete everything the same day.
5. **Month 2** — Helm, then GitOps (Argo CD or Flux). Stop running `kubectl apply` by hand.
6. **Month 3** — Prometheus + Grafana, then a stateful workload (Tutorial C).
7. **Ongoing** — read the release notes for every new Kubernetes minor version. It's 20 minutes, four times a year, and it prevents most upgrade disasters.

**Certifications worth it:** KCNA (beginner), CKA (administrator — the industry standard), CKAD (developer), CKS (security). All hands-on-keyboard exams, not multiple choice.

## 27.5 Primary sources (always prefer these over blog posts)

- Kubernetes docs and release notes — kubernetes.io/docs, kubernetes.io/releases
- Amazon EKS User Guide, and the **EKS Best Practices Guides** (aws.github.io/aws-eks-best-practices)
- Amazon EKS Workshop — eksworkshop.com
- Azure AKS docs — learn.microsoft.com/azure/aks, plus the **AKS release notes on GitHub** (github.com/Azure/AKS/releases)
- AKS Baseline reference architecture (Azure Architecture Center)
- Strimzi docs — strimzi.io/docs
- CNCF Landscape — landscape.cncf.io

---

## The ten things to remember if you forget everything else

1. **Declare what you want; controllers make it true, forever.** That's the whole idea.
2. **Pods are cattle, not pets.** Never depend on a specific pod or its IP.
3. **Services give you a stable address; labels are the glue.**
4. **Always set resource requests.** The scheduler is blind without them, and so is the HPA.
5. **Readiness probes prevent 502s. Liveness probes, misused, cause outages.**
6. **Redundancy beats recovery.** Recovery takes minutes; replicas take zero.
7. **Spread across 3 availability zones**, and use PodDisruptionBudgets — but never one that blocks your own drains.
8. **metrics-server = the scale (robots). Prometheus = the history (humans).** You need both.
9. **Upgrade one minor version at a time, control plane first, and read the release notes.**
10. **Use the managed easy mode** (EKS Auto Mode / AKS Automatic) unless you can name a specific reason not to. Your job is your application, not YAML archaeology.

---

*Guide compiled August 13, 2026. Kubernetes moves fast — verify version numbers and cloud provider features against the primary sources above before making production decisions.*
