# Building a Real Kubernetes Platform on AWS

**A step-by-step tutorial.** By the end you will have a working cluster running
a web app that scales itself, a Kafka message system, a NiFi data tool, and a
Linux pod you can use to test that everything talks to everything else.

Everything is built with Terraform, one piece at a time, and every line of code
is commented.

---

## Table of contents

1. [What you are building](#1-what-you-are-building)
2. [Background: the ideas you need first](#2-background-the-ideas-you-need-first)
3. [Before you start](#3-before-you-start)
4. [The quick version: build it in four commands](#4-the-quick-version)
5. [The slow version: what each layer does](#5-the-slow-version-layer-by-layer)
6. [How to test that it worked](#6-how-to-test-that-it-worked)
7. [How to tear it down](#7-how-to-tear-it-down)
8. [When things go wrong](#8-when-things-go-wrong)
9. [Design decisions and why](#9-design-decisions-and-why)
10. [What this is missing](#10-what-this-is-missing)
11. [Cost](#11-cost)

---

## 1. What you are building

Think of it like a building with floors. You cannot build the third floor
before the second. Each numbered folder is one floor:

```
00-network            The land and the roads.  (VPC, subnets)
01-cluster            The building itself.     (EKS + worker machines)
02-addons             The utilities.           (metrics-server)
03-keda               The thermostat.          (autoscaling brain)
04-webapp             Two web servers.         (nginx + load balancer)
05-strimzi-operator   The Kafka expert.        (an operator)
06-kafka-cluster      The message system.      (3 controllers + 2 brokers)
07-nifi               The data tool.           (2 NiFi pods)
08-toolbox            The test bench.          (a Linux pod with tools)
```

**Why split it up instead of one big file?**

| | Split into layers | One giant file |
|---|---|---|
| A mistake in the web app | Cannot touch your network | Could delete your whole VPC |
| `terraform plan` speed | Seconds | Many minutes |
| Rebuilding one piece | Easy | Rebuild everything |
| Learning curve | You must apply in order | Simpler at first |

The layered approach wins for anything real. It also happens to be *required*
here for a technical reason explained in [section 9](#9-design-decisions-and-why).

---

## 2. Background: the ideas you need first

Skip this if you already know Kubernetes. Otherwise these five ideas explain
almost everything else.

### A container is a boxed-up program

A container packages a program with everything it needs to run — the code, the
libraries, the settings. It runs the same on your laptop as on a server, which
solves the oldest complaint in software: *"it works on my machine."*

### Kubernetes runs containers for you

You tell Kubernetes **what you want**, not how to get it:

> "Keep two copies of this web server running at all times."

Kubernetes makes it true and *keeps* it true. A copy crashes? It starts
another. A whole machine dies? It moves the work elsewhere. You describe the
destination; it figures out the route.

### A pod is the smallest unit

A **pod** is one or more containers that always run together and share a
network address. Usually it is just one container. When people say "my app is
running in Kubernetes," they mean it is running in a pod.

Pods are **disposable**. They get deleted and replaced constantly. That is
normal, not a failure.

### A Service is a stable name for shifting pods

Since pods come and go and change IP addresses, nothing can point at a pod
directly. A **Service** is a permanent name and address in front of a moving
set of pods. Kubernetes keeps the list of healthy pods behind it up to date
automatically.

This one idea causes more confusion than any other, so: *pods move, Services
do not.*

### An operator is expert knowledge as software

Some programs are genuinely hard to run — Kafka is the classic example.
Certificates between servers, restarts that must never take down two at once,
storage that must follow a server if it moves.

An **operator** is a program running inside your cluster that already knows all
of that. You write a short description of what you want:

```yaml
kind: Kafka
spec:
  kafka:
    version: 4.2.0
```

...and the operator builds and maintains roughly forty Kubernetes objects to
make it real. That is why layer 06 is short and still produces a working Kafka
cluster.

---

## 3. Before you start

### Install these

| Tool | Version | Check with |
|---|---|---|
| Terraform | 1.9+ | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| kubectl | any recent | `kubectl version --client` |
| jq | any | `jq --version` |

### Set up AWS access

```bash
aws configure
aws sts get-caller-identity     # must print your account ID
```

If that second command fails, stop and fix it. Nothing else will work.

Your IAM user or role needs permission to create VPCs, EKS clusters, EC2
instances, IAM roles, EBS volumes and load balancers. For a personal learning
account, `AdministratorAccess` is simplest. For a shared account, ask whoever
runs it.

### Two things you should genuinely worry about

**1. Cost.** This platform runs about **$250–350 per month** if you leave it
up. That is real money. See [section 11](#11-cost) and *always* tear it down
when you are done.

**2. State files.** Terraform remembers what it built in a file called
`terraform.tfstate`. This project keeps those files **on your computer**.

> **If you delete these folders, you lose the ability to destroy the
> infrastructure — and it keeps billing you forever.**

Back them up, or read [section 9](#9-design-decisions-and-why) on switching to
S3 storage.

State files also contain **passwords and certificates in plain text**. Never
put them in Git. The included `.gitignore` blocks them.

---

## 4. The quick version

Four commands. Roughly 30–40 minutes, most of it waiting.

```bash
# 1. Create your settings file
cp common.auto.tfvars.example common.auto.tfvars

# 2. Edit it — at minimum, restrict who can reach your cluster
#    Find your IP: curl -s https://checkip.amazonaws.com
#    Then set:     allowed_admin_cidrs = ["YOUR.IP.HERE/32"]
nano common.auto.tfvars

# 3. Build everything, in order, with logs
./scripts/apply-all.sh

# 4. Check it works
./tests/run-tests.sh
```

**When you are finished:**

```bash
./scripts/destroy-all.sh
```

### What you should see while it runs

```
[2026-07-23 14:02:11] INFO   Checking prerequisites...
[2026-07-23 14:02:13] OK     AWS account: 123456789012
================================================================
  00-network :: terraform apply
================================================================
...
```

Every layer writes its own log to `logs/`. If something fails, the script tells
you exactly which log to read and how to resume:

```bash
./scripts/apply-all.sh --from 05-strimzi-operator
```

### Useful variations

```bash
./scripts/apply-all.sh --plan        # preview everything, change nothing
./scripts/apply-all.sh 04-webapp     # rebuild one layer
./scripts/apply-all.sh --from 06     # resume after a failure
```

---

## 5. The slow version, layer by layer

This section walks through one layer in full detail so you can see the pattern,
then summarises the rest.

### Worked example: layer 00, the network

```bash
cd 00-network
terraform init      # download the AWS plugin
terraform plan      # show what WOULD be created
terraform apply     # actually create it
```

`terraform plan` prints something like:

```
Plan: 18 to add, 0 to change, 0 to destroy.
```

**Always read the plan.** In particular watch for `destroy` on anything you
care about. A plan that says "1 to add, 1 to destroy" when you expected a
simple change usually means you edited something immutable and Terraform is
about to replace it.

**What gets built and why:**

| Thing | What it is |
|---|---|
| VPC | Your own private network, isolated from everyone else |
| Public subnets | The front porch — load balancers live here |
| Private subnets | The bedrooms — worker machines live here, unreachable from the internet |
| Internet Gateway | The front door |
| NAT Gateway | A one-way exit so private machines can download software but nobody can call in |
| S3 endpoint | A free shortcut that avoids NAT charges when pulling container images |

**Why put worker machines in private subnets?** Defence in depth. If someone
finds a bug in your web server, they still cannot open a connection to the
machine from their laptop, because there is no network path to it.

Check what it produced:

```bash
terraform output
terraform output vpc_id
```

Those outputs are how layer 01 finds the network. Each layer reads the previous
one's state file — that is the glue holding the layers together.

### The remaining layers, in brief

**01-cluster** — The EKS control plane plus three worker machines. This is the
slowest step (10–15 minutes) and nothing can hurry it. Also sets up `gp3` disks
as the default, because EKS's built-in default (`gp2`) is slower and more
expensive.

**02-addons** — Installs metrics-server, which measures CPU and memory. Small
but **essential**: without it, autoscaling silently never happens. You get an
HPA showing `<unknown>/50%` forever and no error message anywhere.

**03-keda** — The autoscaling brain. Plain Kubernetes can only scale on CPU and
memory. KEDA can scale on anything — queue length, database rows, an HTTP
endpoint — and can scale all the way to zero.

**04-webapp** — Two nginx pods serving a page that shows which pod answered
you. Refresh it and the name changes: that is proof load balancing works. A
KEDA rule adds pods when CPU passes 50%.

**05-strimzi-operator** — Installs the Kafka expert. Creates nothing yet.

**06-kafka-cluster** — 3 controllers + 2 brokers. The sizing reasoning is in
[section 9](#9-design-decisions-and-why) and is worth reading; it is the most
interesting decision in the project.

**07-nifi** — Two NiFi pods, each with its own disk. Uses a **StatefulSet**
rather than a Deployment, because NiFi keeps data on disk and each pod must get
*its own* disk back after a restart.

**08-toolbox** — A Linux pod with `curl`, `dig`, `nc`, `tcpdump` and friends.
This is the "Linux node that can talk to everything" — and it matters because
from your laptop you are *outside* the cluster, where internal names do not
resolve.

---

## 6. How to test that it worked

### Run the full suite

```bash
./tests/run-tests.sh
```

It checks about 30 things and prints a summary:

```
  PASS  All nodes are Ready
  PASS  HTTP 200 and page content served
  PASS  All 5 Kafka pods running (3 controllers + 2 brokers)
  PASS  Toolbox -> Kafka (TCP 9092)
================================================================
  RESULTS: 31 / 31 passed
================================================================
```

Exit code 0 means everything passed, so this works in CI too.

### Watch autoscaling actually happen

This is the most satisfying part:

```bash
./tests/load-test.sh 180
```

It generates load from inside the cluster and shows the replica count moving:

```
ELAPSED    PODS     HPA TARGETS    REPLICAS
0m0s       2        8%/50%         2
0m45s      2        94%/50%        2
1m15s      4        71%/50%        4
2m00s      6        48%/50%        6
```

Then load stops and pods scale back down — **slowly**, over about five minutes.
That is deliberate, not a bug. Scaling *down* fast is how a brief traffic dip
turns into an outage when traffic returns.

### Test things by hand

```bash
# Open a shell inside the cluster
kubectl exec -it -n toolbox deploy/toolbox -- /bin/bash

# Then:
curl http://hello-web.hello-web.svc.cluster.local/
nc -zv demo-kafka-kafka-bootstrap.kafka.svc.cluster.local 9092
dig +short nifi.nifi.svc.cluster.local
```

### See the web page in a browser

```bash
cd 04-webapp && terraform output -raw web_url
```

DNS takes 2–3 minutes after creation. If it does not resolve yet, wait.

### Open NiFi

```bash
kubectl port-forward -n nifi svc/nifi 8443:8443
cd 07-nifi && terraform output -raw nifi_password
# Open https://localhost:8443/nifi  (accept the certificate warning)
```

---

## 7. How to tear it down

```bash
./scripts/destroy-all.sh
```

It asks you to type `destroy` to confirm, then works **backwards** from layer
08 to layer 00.

**Why backwards?** You cannot delete a network that still has a cluster inside
it. AWS refuses, with the famously unhelpful message:

```
DependencyViolation: The vpc has dependencies and cannot be deleted
```

The script also checks for **orphans** afterwards — leftover disks that survive
deletion and quietly keep billing you:

```
[WARN] Unattached EBS volumes found (these still cost money):
vol-0abc123    10    2026-07-23T14:22:01
```

Review the list carefully before deleting anything, since other projects in the
same account may own some of those volumes.

---

## 8. When things go wrong

### The debugging order that actually works

Follow this sequence. Each step rules out a whole category of problem:

```bash
# 1. What is not running?
kubectl get pods -A | grep -v Running

# 2. Why not? The Events at the bottom are the answer.
kubectl describe pod <pod-name> -n <namespace>

# 3. What did the application itself say?
kubectl logs <pod-name> -n <namespace>

# 4. What happened recently, cluster-wide?
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

Most people jump straight to logs. **Start with `describe` instead** — for
scheduling, storage and image problems, the app never started, so its logs are
empty and the real answer is in Events.

### Common problems

**Pod stuck `Pending`**

```bash
kubectl describe pod <name> -n <ns> | grep -A10 Events
```

Almost always "Insufficient cpu" or "Insufficient memory" — the cluster is
full. Raise `node_group_desired_size` in your tfvars and re-apply layer 01.

**Pod in `CrashLoopBackOff`**

The container starts and immediately dies, over and over.

```bash
kubectl logs <name> -n <ns> --previous    # --previous shows the crashed run
```

**HPA shows `<unknown>/50%`**

metrics-server is not working. Check `kubectl top nodes`. If that fails, go
back to layer 02.

**"no matches for kind Kafka"**

The Strimzi CRDs are not registered yet. Wait 30 seconds and retry. This is a
timing race the layer ordering is designed to avoid.

**NiFi says "Invalid host header"**

The hostname you used is not in `NIFI_WEB_PROXY_HOST`. Edit `07-nifi/main.tf`.

**`terraform destroy` fails on the VPC**

Something is still using it — usually a load balancer whose network interfaces
have not been released yet. Wait 5 minutes and retry. If it persists:

```bash
aws ec2 describe-network-interfaces \
  --filters Name=vpc-id,Values=<vpc-id> \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]' --output table
```

---

## 9. Design decisions and why

This section is the "pros and cons" of the choices that mattered most.

### Why 3 Kafka controllers but 2 brokers?

Kafka controllers vote to agree on cluster state. Voting needs a **majority**:

| Controllers | Failures survived |
|---|---|
| 1 | 0 |
| **2** | **0** ← no better than 1, but costs double |
| 3 | 1 |
| 5 | 2 |

A majority of 2 is still 2, so an even number buys nothing. **This is why
controller counts are always odd.** The code enforces it:

```
Error: controller_replicas must be ODD (1, 3, 5). An even count buys cost
without buying fault tolerance -- a majority of 2 is still 2.
```

Brokers are different — they store data, not votes. You asked for two, and two
demonstrates replication.

**But be honest about the limitation.** With 2 brokers you must choose:

| Setting | Effect |
|---|---|
| `min.insync.replicas: 2` | Writes are safe, but *any* broker restart stops writes |
| `min.insync.replicas: 1` | Writes keep flowing, but a failure at the wrong moment can lose acknowledged data |

There is no good answer with 2 brokers. **This is exactly why the production
standard is 3 brokers, `replication.factor=3`, `min.insync.replicas=2`** —
which survives one broker failing with zero data loss *and* no interruption.

If you take one thing from this project into real work, take **3/3/2**.

### Why JVM heap is much smaller than the memory limit

Kafka brokers: 3 GiB container limit, 1.5 GiB heap.
NiFi: 3 GiB container limit, 1 GiB heap.

Two reasons:

1. **The JVM needs memory outside the heap** — thread stacks, metaspace, direct
   buffers. Setting the heap equal to the container limit is the classic way to
   get killed by the kernel while the JVM still thinks it has room.
2. **Kafka depends on the OS page cache** for read speed. A heap that fills the
   container leaves no cache, and throughput collapses.

**Rule of thumb: heap ≈ 30–50% of the container limit.**

### Why a Network Load Balancer instead of an Ingress

Most EKS tutorials install the AWS Load Balancer Controller so you can use
Ingress resources. We deliberately do not.

| | Our approach (Service type LoadBalancer → NLB) | Ingress + AWS LB Controller |
|---|---|---|
| Extra components | None | Controller, CRDs, webhooks, large IAM policy |
| Gets you | A real NLB | An ALB with path routing, TLS, WAF |
| Failure modes | Few | Many |

At the time of writing, the controller's chart 3.x has open issues with missing
CRDs causing crash loops. For a tutorial, fewer moving parts wins. **Install
the controller when you actually need** path-based routing, TLS termination at
the load balancer, or one ALB shared by many services.

### Why `ignore_changes` on the web app's replica count

Terraform believes the code is the truth. KEDA believes the metrics are the
truth. Both want to control the replica count.

Without `ignore_changes`, you get a fight:

1. Traffic arrives, KEDA scales to 6.
2. You run `terraform apply` for something unrelated.
3. Terraform sees 6, its code says 2, and scales you **down mid-incident**.
4. KEDA notices and scales back up.

`ignore_changes` tells Terraform: set this once at creation, then never look
again. Use this pattern **any time a controller inside the cluster owns a field
Terraform also declares.**

### Why local state — and why you should not keep it

You asked for local state, and it is genuinely right for learning: zero setup,
fast, nothing to create first.

**But know what you are giving up:**

| | Local state | S3 backend |
|---|---|---|
| Team use | Impossible — no locking, concurrent applies corrupt it | Safe |
| Losing your laptop | You can never destroy the infrastructure | Fine |
| Secrets | Plain text on disk | Encrypted at rest |

To switch, replace the `backend "local"` block in each layer:

```hcl
backend "s3" {
  bucket       = "my-company-tfstate"
  key          = "eks-platform/00-network/terraform.tfstate"
  region       = "us-east-1"
  encrypt      = true
  use_lockfile = true   # S3-native locking; replaced DynamoDB
}
```

### Why layers are *required*, not just tidy

Terraform's `kubernetes_manifest` resource validates custom resources against
the cluster's schema **during `plan`**. That means the CRD must already exist
*before you plan*.

So you **cannot** install KEDA and create a ScaledObject in the same apply. The
layer split is not merely good organisation here — it is the mechanism that
makes this work at all.

### Security choices, stated honestly

| Choice | Reasoning |
|---|---|
| Worker nodes in private subnets | No inbound path from the internet |
| IMDSv2 required, hop limit 1 | Blocks pods from stealing the node's IAM credentials |
| Pod Identity, not access keys | Short-lived, auto-rotating, scoped to one ServiceAccount |
| Read-only root filesystems | An attacker cannot write a payload to disk |
| Drop ALL capabilities | Then add back only what is needed (toolbox gets `NET_RAW` for `ping`) |
| KMS-encrypted secrets | You control the key and can audit its use |

**Where we knowingly relaxed things, and why:**

- **Kafka and NiFi namespaces use `baseline`, not `restricted`.** Both need
  filesystem ownership changes at startup that the strictest profile blocks.
  Use the strictest profile that *works*, not the strictest that exists.
- **The toolbox has a writable filesystem.** Its whole value is being able to
  install a tool or save a capture mid-investigation.
- **Kafka's internal listener is unencrypted.** So that testing needs no
  certificate wrangling. A TLS listener is also configured on port 9093 —
  switch to it for anything real.

---

## 10. What this is missing

An honest list. Do not mistake this for production-ready.

**Not built here:**

- **Monitoring.** No Prometheus, no Grafana, no alerts. You cannot see a
  problem coming.
- **Backups.** Nothing backs up Kafka or NiFi data. `velero` is the usual tool.
- **NetworkPolicy.** Any pod can reach any other pod. Real clusters restrict
  this.
- **A cluster autoscaler.** KEDA adds *pods*; nothing adds *nodes*. If pods
  cannot fit, they stay Pending. Look at Karpenter.
- **TLS on Kafka's data path.** Configured but not used.
- **Real secret management.** Passwords sit in state files. Use AWS Secrets
  Manager or External Secrets Operator.
- **CI/CD.** No pipeline, no policy checks (`tflint`, `checkov`, `tfsec` are
  the usual tools).

**A real limitation worth naming:** the two NiFi pods are **independent
instances, not a NiFi cluster**. Each has its own canvas and its own data. A
flow you build on `nifi-0` does not appear on `nifi-1`. Real NiFi clustering
needs ZooKeeper or Kubernetes-native leader election, mutual TLS between nodes,
and a shared flow definition — a substantial amount of extra work. The details
are in the comments at the bottom of `07-nifi/main.tf`.

---

## 11. Cost

Approximate US East pricing, running 24/7:

| Item | Per month |
|---|---|
| EKS control plane | $73 |
| 3 × m6i.large workers | $210 |
| NAT gateway (single) | $32 |
| Network Load Balancer | $16 |
| EBS volumes (~120 GiB) | $10 |
| KMS key | $1 |
| CloudWatch logs | $5–20 |
| **Total** | **~$350** |

### Cutting the cost

```hcl
# In common.auto.tfvars:

node_instance_types     = ["t3.large"]   # cheaper, burstable CPU
node_group_desired_size = 2              # fewer machines
availability_zone_count = 2              # minimum EKS allows
single_nat_gateway      = true           # already the default
```

```hcl
# In 04-webapp — skip the $16/month load balancer, test from the toolbox instead
create_public_loadbalancer = false
```

**Spot instances** cut worker cost 60–90%, but AWS can reclaim a machine with
two minutes' notice. Excellent for the web app, genuinely bad for Kafka brokers
holding data. Since one node group hosts both here, we chose reliability.

> **The single biggest cost mistake is forgetting to run
> `./scripts/destroy-all.sh`.** A cluster left running over a forgotten weekend
> costs more than a month of deliberate use.

---

## Where to go next

- **Add monitoring:** install `kube-prometheus-stack` and point Grafana at the
  metrics KEDA and Strimzi already expose.
- **Scale Kafka properly:** change `broker_replicas` to 3 and
  `min.insync.replicas` to 2, then re-apply layer 06. Watch Strimzi perform a
  rolling change with no downtime.
- **Try scale-to-zero:** set `min_replicas = 0` in layer 04 and add a Kafka lag
  trigger instead of CPU. That is KEDA's real superpower.
- **Build a NiFi flow:** drag a `ConsumeKafka` processor onto the canvas and
  point it at the bootstrap address in `terraform output kafka_bootstrap_for_nifi`.

### Reference

- `docs/cli-equivalents.md` — every Terraform action as raw `aws`/`kubectl`/`helm`
- `docs/keda-scaledobject.yaml` — the ScaledObject as plain YAML
- `docs/kafka-cluster.yaml` — the Kafka cluster as plain YAML
- Every `.tf` file is commented line by line; read them in numbered order.
