# Tutorial: Using the Pipeline Template — Step by Step

This guide takes you from an empty GitLab project to a working pipeline that
configures **infrastructure** (AWS via Terraform) and **applications**
(Kubernetes, Helm, Ansible, Kafka). Every section uses a tiny **hello-world**
example with **2–3 nodes/replicas** so you can see results fast without large
bills or complexity.

If you only read one thing: **you configure everything by editing one file,
`ci/includes/00-variables.yml`, and you turn tools on/off with the `ENABLE_*`
switches.** The rest of this tutorial just shows what to put where.

> **Ready-made copies:** every hello-world file below is also saved under
> `examples/` in this repo (`examples/terraform/hello.tf`,
> `examples/kubernetes/hello.yaml`, etc.). You can copy them into place instead
> of typing them out — each section tells you the destination path.

---

## Table of contents

1. [Mental model — how the pipeline thinks](#1-mental-model)
2. [Prerequisites — what you need before starting](#2-prerequisites)
3. [Step 0: Get the template into your project](#3-step-0-get-the-template-into-your-project)
4. [Step 1: One-time AWS state bootstrap](#4-step-1-one-time-aws-state-bootstrap)
5. [Step 2: Set your secrets in GitLab](#5-step-2-set-your-secrets-in-gitlab)
6. [Step 3: Your first pipeline run (validation only)](#6-step-3-your-first-pipeline-run)
7. [Example A — Terraform "hello world" (an S3 bucket)](#7-example-a--terraform-hello-world)
8. [Example B — Kubernetes "hello world" (3 nginx pods)](#8-example-b--kubernetes-hello-world)
9. [Example C — Helm "hello world" (2-replica release)](#9-example-c--helm-hello-world)
10. [Example D — Ansible "hello world" (3-node ping + message)](#10-example-d--ansible-hello-world)
11. [Example E — Kafka "hello world" (3 topics)](#11-example-e--kafka-hello-world)
12. [Putting it together: full infra + app pipeline](#12-putting-it-together)
13. [Debugging when something breaks](#13-debugging)
14. [Cleaning up everything safely](#14-cleaning-up)
15. [Cheat sheet](#15-cheat-sheet)

---

## 1. Mental model

The pipeline runs in ordered **stages**. Each stage contains **jobs**. Jobs in
the same stage run in parallel; stages run one after another.

```
prerequisites → validate → plan → build → deploy → test → debug → cleanup
```

- **prerequisites** — Is the runner healthy? Are the right tool versions
  installed? Can we log into AWS and the cluster? Fails fast if not.
- **validate** — Read-only checks: format, lint, security scan, dry-run. Nothing
  touches live systems. Safe to run on every change.
- **plan** — Shows *what would change* (`terraform plan`, `kubectl diff`,
  `helm template`, ansible `--check`). Still no changes made.
- **deploy** — Actually applies changes. **Manual by default** — you click a
  button. (You can flip `AUTO_APPLY: "true"` for dev.)
- **test** — After deploy, checks the result is healthy.
- **debug** — Manual-only diagnostics. Never runs on its own, never blocks.
- **cleanup** — Tears things down. **Double-locked**: needs `ALLOW_DESTROY:
  "true"` *and* a manual click.

The big idea: **plan is automatic and safe; deploy and destroy require a human.**

A quick map of where things live:

| You want to change…        | Edit this                                  |
|----------------------------|--------------------------------------------|
| Any setting / toggle       | `ci/includes/00-variables.yml`             |
| Infrastructure (AWS)       | `terraform/environments/<env>/`            |
| Raw Kubernetes YAML        | `kubernetes/manifests/` or `kustomize/`    |
| Helm app config            | `helm/charts/…` and `helm/values/<env>.yaml` |
| Server configuration       | `ansible/playbooks/`, `ansible/inventory/` |
| Kafka topics               | `kafka/topics/topics.yml`                  |

---

## 2. Prerequisites

Before you start you need:

- A **GitLab project** (gitlab.com or self-managed) with the **CI/CD feature**
  enabled and at least one **runner** available (shared runners on gitlab.com
  are fine).
- An **AWS account** and an IAM identity you can use for setup. (We'll switch
  the pipeline to a safer OIDC role below.)
- For the Kubernetes/Helm examples: an **EKS cluster** you can reach. If you
  don't have one, you can still do Examples A (Terraform) and D (Ansible).
- `git` on your machine.

You do **not** need Terraform/kubectl/helm installed locally — the pipeline
installs pinned versions itself. (You only need Terraform locally for the
one-time state bootstrap in Step 1, or you can do that step from any machine
that has it.)

---

## 3. Step 0: Get the template into your project

**Option A — copy the files in (simplest to start):**

```bash
# from the template directory
git init my-pipeline && cd my-pipeline
# copy all template files here, then:
git add .
git commit -m "Add pipeline template"
git remote add origin git@gitlab.com:your-group/my-pipeline.git
git push -u origin main
```

**Option B — reference a central template repo (best once you have many
projects).** Your project's `.gitlab-ci.yml` becomes just a few lines — see
`ci/templates/example-consumer.gitlab-ci.yml`. We use Option A for the rest of
this tutorial because it's easier to follow.

After pushing, open **GitLab → Build → Pipelines**. You'll likely see a pipeline
already running. That's expected. We'll make it meaningful over the next steps.

---

## 4. Step 1: One-time AWS state bootstrap

Terraform needs a place to store its "state" (its record of what it created).
We use an S3 bucket + a DynamoDB table for locking. You create these **once per
AWS account**, by hand, because Terraform can't store its own state before the
storage exists (chicken-and-egg).

```bash
cd terraform/backend
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — pick **globally unique** names:

```hcl
region            = "us-east-1"
state_bucket_name = "helloworld-tfstate-123456"   # must be globally unique
lock_table_name   = "helloworld-tf-locks"
```

Then run it locally (this is the only step that uses local Terraform):

```bash
terraform init
terraform apply        # type "yes" when prompted
```

You now have an encrypted, versioned state bucket and a lock table. Note the two
output names — you'll put them in `00-variables.yml` next.

> **Why this matters:** remote state lets the pipeline (and teammates) share one
> source of truth, and the lock prevents two pipelines from corrupting state by
> applying at the same time.

---

## 5. Step 2: Set your secrets in GitLab

**Never put secrets in the repo.** Put them in **GitLab → Settings → CI/CD →
Variables**. For each one, tick **Protected** and **Masked** where possible.

The recommended path is **OIDC** (no long-lived keys). Set up an IAM OIDC
provider for GitLab and a role the pipeline can assume, then add:

| Variable        | Example value                                  | Notes                |
|-----------------|------------------------------------------------|----------------------|
| `AWS_ROLE_ARN`  | `arn:aws:iam::123456789012:role/gitlab-deploy` | OIDC role to assume  |

(See `config/aws/README.md` and `config/eks/aws-auth-example.yaml` for the IAM
and cluster-access setup.)

If you're just kicking the tires and don't have OIDC yet, you can temporarily
use static keys instead (less secure — rotate/remove them after):

| Variable                | Notes                          |
|-------------------------|--------------------------------|
| `AWS_ACCESS_KEY_ID`     | masked                         |
| `AWS_SECRET_ACCESS_KEY` | masked                         |

---

## 6. Step 3: Your first pipeline run

Now point the template at *your* AWS settings. Open
`ci/includes/00-variables.yml` and change just these lines:

```yaml
  AWS_DEFAULT_REGION: "us-east-1"
  AWS_ROLE_ARN: ""                 # leave blank if using static keys for now

  TF_STATE_BUCKET: "helloworld-tfstate-123456"   # from Step 1
  TF_STATE_REGION: "us-east-1"
  TF_STATE_DYNAMODB_TABLE: "helloworld-tf-locks" # from Step 1
```

For this very first run, turn **off** everything except validation so we can
confirm the basics work:

```yaml
  ENABLE_TERRAFORM: "true"
  ENABLE_KUBERNETES: "false"
  ENABLE_HELM: "false"
  ENABLE_ANSIBLE: "false"
  ENABLE_KAFKA: "false"
```

Commit and push:

```bash
git add ci/includes/00-variables.yml
git commit -m "Point template at my AWS account"
git push
```

Open the pipeline. You should see the **prerequisites** and **validate** stages
run and go green:

- `prereq:runner-check` — confirms the runner and network.
- `prereq:tool-versions` — installs pinned Terraform/kubectl/helm and verifies them.
- `prereq:auth-smoke-test` — runs `aws sts get-caller-identity` and checks your
  state bucket is reachable.
- `validate:terraform-fmt` / `validate:terraform-validate` — checks the Terraform.

If `prereq:auth-smoke-test` fails, your AWS variables or OIDC trust aren't right
yet — fix those before moving on. **Getting this green is the foundation for
everything else.**

---

## 7. Example A — Terraform "hello world"

**Goal:** have the pipeline create one tiny piece of infrastructure — an S3
bucket — so you can watch the full plan → approve → apply flow.

### A.1 Add the resource

The dev environment lives in `terraform/environments/dev/`. Add a hello-world
bucket. Create `terraform/environments/dev/hello.tf`:

```hcl
# A tiny "hello world" resource so we can see Terraform work end-to-end.
resource "aws_s3_bucket" "hello" {
  bucket = "helloworld-${var.environment}-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
}

output "hello_bucket_name" {
  value = aws_s3_bucket.hello.bucket
}
```

`random_id` needs the random provider. Add it to the `required_providers` block
in `terraform/environments/dev/main.tf`:

```hcl
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }   # add this line
  }
```

### A.2 Run plan (automatic, safe)

Commit and push. On your merge request / default branch, `terraform:plan` runs
automatically. Open its log — you'll see Terraform intends to **add 2 resources**
(the bucket and the random id). It saves this as a plan artifact. **Nothing has
been created yet.**

```
Plan: 2 to add, 0 to change, 0 to destroy.
```

### A.3 Apply (manual click)

Go to the pipeline. The `terraform:apply` job sits in the **deploy** stage with a
▶ (play) button because deploys are manual. Click it. It applies **exactly the
plan you reviewed** (it reuses the saved plan artifact, so there are no
surprises). When it finishes, the log prints your new bucket name.

You just provisioned infrastructure through the pipeline. 🎉

> **Tip:** for a pure dev sandbox you can set `AUTO_APPLY: "true"` so apply runs
> automatically after a green plan — but keep deploys manual for anything shared.

---

## 8. Example B — Kubernetes "hello world"

**Goal:** deploy **3 nginx pods** to your EKS cluster using raw manifests, and
watch the dry-run diff before applying.

### B.1 Turn Kubernetes on and point at your cluster

In `ci/includes/00-variables.yml`:

```yaml
  ENABLE_KUBERNETES: "true"
  EKS_CLUSTER_NAME: "my-eks-cluster"     # your cluster name
  EKS_CLUSTER_REGION: "us-east-1"
  KUBE_NAMESPACE: "hello"
```

> Make sure the pipeline's IAM role is mapped in the cluster's `aws-auth`
> ConfigMap (see `config/eks/aws-auth-example.yaml`), or kubectl can't talk to
> the cluster.

### B.2 Write the hello-world manifest

Replace the contents of `kubernetes/manifests/` with a single Deployment of 3
replicas. Create `kubernetes/manifests/hello.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  replicas: 3                 # <-- 3 nodes/pods
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
        - name: hello
          image: nginxdemos/hello:plain-text   # prints which pod served you
          ports:
            - containerPort: 80
```

(Optional — delete the old `kubernetes/manifests/namespace.yaml` so only your
hello Deployment is applied. The pipeline creates the `hello` namespace for you.)

### B.3 See the diff, then apply

Push. In the **plan** stage, `kubectl:diff` shows a server-side dry-run of what
would change — you'll see the Deployment being created. In the **deploy** stage,
click ▶ on `kubectl:apply`. It creates the namespace, applies the Deployment,
and waits for the rollout. Then `kubectl:smoke-test` confirms all 3 pods are
`Running`:

```
deployment "hello-world" successfully rolled out
All pods healthy.
```

Check it yourself locally if you have kubectl access:

```bash
kubectl get pods -n hello
# hello-world-xxxx-1   1/1   Running
# hello-world-xxxx-2   1/1   Running
# hello-world-xxxx-3   1/1   Running
```

---

## 9. Example C — Helm "hello world"

**Goal:** deploy the same idea but managed by **Helm**, with **2 replicas**, so
you get upgrades, history, and one-command rollback.

The template already ships a chart at `helm/charts/my-app/`. We'll just point a
hello-world release at it with 2 replicas.

### C.1 Turn Helm on

In `ci/includes/00-variables.yml`:

```yaml
  ENABLE_HELM: "true"
  HELM_CHART_PATH: "helm/charts/my-app"
  HELM_RELEASE_NAME: "hello"
  HELM_VALUES_FILE: "helm/values/dev.yaml"
  KUBE_NAMESPACE: "hello"
```

### C.2 Set the hello-world values (2 replicas)

Edit `helm/values/dev.yaml`:

```yaml
replicaCount: 2                 # <-- 2 nodes/replicas
image:
  repository: nginxdemos/hello
  tag: "plain-text"
service:
  type: ClusterIP
  port: 80
```

### C.3 Render, deploy, and (optionally) roll back

Push. In **plan**, `helm:template` renders the chart so you can eyeball the YAML.
In **deploy**, click ▶ on `helm:deploy`. Because `HELM_ATOMIC: "true"`, a failed
upgrade rolls itself back automatically. Success looks like:

```
Release "hello" has been upgraded. STATUS: deployed
```

Want to see rollback? Change `tag:` to something broken (e.g. `tag: "does-not-exist"`),
push, run `helm:deploy` and watch it auto-roll-back. Or run the manual
`helm:rollback` job to go to the previous revision. Inspect history anytime with
the `debug:helm` job.

> **Manifests vs Helm — which to use?** Raw manifests (Example B) are simplest
> for a couple of static files. Helm (this example) is better when you want
> templating, environment-specific values, release versioning, and easy
> rollback. You normally wouldn't deploy the *same* app both ways.

---

## 10. Example D — Ansible "hello world"

**Goal:** have Ansible reach **3 nodes**, ping them, and print a hello message —
the classic first Ansible run. This shows the `--check` (dry-run) → real-run flow
for **server configuration**.

### D.1 Turn Ansible on

In `ci/includes/00-variables.yml`:

```yaml
  ENABLE_ANSIBLE: "true"
  ANSIBLE_PLAYBOOK: "ansible/playbooks/hello.yml"
  ANSIBLE_INVENTORY: "ansible/inventory/dev.ini"
```

### D.2 Define 3 nodes

Edit `ansible/inventory/dev.ini` with three hosts (replace IPs/users with real
reachable hosts, e.g. small EC2 instances):

```ini
[web]
node1 ansible_host=10.0.1.11
node2 ansible_host=10.0.1.12
node3 ansible_host=10.0.1.13

[web:vars]
ansible_user=ec2-user
ansible_python_interpreter=/usr/bin/python3
```

The pipeline injects the SSH key from the `ANSIBLE_SSH_PRIVATE_KEY` CI/CD
variable (set it as a **File**-type variable containing your private key).

### D.3 Write the hello playbook

Create `ansible/playbooks/hello.yml`:

```yaml
---
- name: Hello world across 3 nodes
  hosts: web                      # the 3 nodes from inventory
  gather_facts: true
  tasks:
    - name: Ping every node
      ansible.builtin.ping:

    - name: Say hello from each node
      ansible.builtin.debug:
        msg: "Hello world from {{ inventory_hostname }} ({{ ansible_default_ipv4.address | default('no-ip') }})"
```

### D.4 Dry-run, then run for real

Push. In **plan**, `ansible:check` runs `ansible-playbook --check --diff` — it
connects and reports what *would* happen without changing anything. In
**deploy**, click ▶ on `ansible:run`. You'll see a green `ok=` for each of the 3
nodes and the hello message printed per host:

```
ok: [node1] => msg: Hello world from node1 (10.0.1.11)
ok: [node2] => msg: Hello world from node2 (10.0.1.12)
ok: [node3] => msg: Hello world from node3 (10.0.1.13)
```

> **No servers handy?** Skip this example — it's the one part that needs real
> reachable hosts. Everything else works with just AWS + EKS.

---

## 11. Example E — Kafka "hello world"

**Goal:** declare **3 topics** and have the pipeline create them. Kafka is off by
default, so this is opt-in.

### E.1 Turn Kafka on and point at your broker

In `ci/includes/00-variables.yml`:

```yaml
  ENABLE_KAFKA: "true"
  KAFKA_BOOTSTRAP_SERVERS: "my-broker:9092"   # your broker(s)
  KAFKA_SECURITY_PROTOCOL: "PLAINTEXT"        # or SASL_SSL with creds in CI vars
  KAFKA_TOPICS_CONFIG: "kafka/topics/topics.yml"
  KAFKA_REPLICATION_FACTOR: "3"
```

### E.2 Declare 3 hello-world topics

Replace `kafka/topics/topics.yml` with three simple topics:

```yaml
topics:
  - name: hello.greetings
    partitions: 3
    replication_factor: 3

  - name: hello.events
    partitions: 3
    replication_factor: 3

  - name: hello.logs
    partitions: 1
    replication_factor: 3
    config:
      retention.ms: "86400000"   # 1 day
```

### E.3 Validate, list, apply

Push. In **validate**, `kafka:validate` checks the file is well-formed and has no
duplicate names. In **plan**, `kafka:list` shows existing topics (read-only). In
**deploy**, click ▶ on `kafka:apply` — it creates any missing topics and prints:

```
[create] hello.greetings partitions=3 rf=3
[create] hello.events partitions=3 rf=3
[create] hello.logs partitions=1 rf=3
```

Re-running is safe: topics that already exist are detected and skipped (it only
adds partitions if your file asks for more).

---

## 11b. Example F — Strimzi: Kafka *on* Kubernetes

**Goal:** instead of pointing at an existing broker (Example E), **run a real
3-node Kafka cluster inside your EKS cluster**, managed declaratively by the
**Strimzi operator**. You'll install the operator, deploy a `Kafka` custom
resource, declare topics as `KafkaTopic` resources, and produce/consume a
hello-world message end to end.

### When to use this vs Example E

These are two different answers to "how do I do Kafka":

| | Example E (`70-kafka.yml`) | Example F — Strimzi (`75-strimzi.yml`) |
|---|---|---|
| Where Kafka runs | An **existing** broker you already have | **Created for you inside Kubernetes** |
| How you manage it | `kafka-topics.sh` CLI from a job | Kubernetes **custom resources** (`Kafka`, `KafkaTopic`, `KafkaUser`) |
| You need | A reachable bootstrap server | An EKS cluster + the Strimzi operator |
| Best for | Managed Kafka (MSK, Confluent Cloud), existing clusters | Running and versioning Kafka yourself, GitOps |

Use **one or the other**, not both, for the same Kafka. This example assumes you
finished Example B (so EKS auth already works).

### F.1 Turn Strimzi on

In `ci/includes/00-variables.yml`:

```yaml
  ENABLE_STRIMZI: "true"
  STRIMZI_OPERATOR_VERSION: "0.42.0"
  STRIMZI_NAMESPACE: "kafka"
  STRIMZI_CLUSTER_NAME: "hello-kafka"     # must match the Kafka CR name
  STRIMZI_DIR: "examples/strimzi"         # or move these to kubernetes/strimzi/
  EKS_CLUSTER_NAME: "my-eks-cluster"
  EKS_CLUSTER_REGION: "us-east-1"
```

Leave `ENABLE_KAFKA: "false"` — you don't want the CLI path running too.

### F.2 The manifests (already provided)

The hello-world Strimzi resources ship under `examples/strimzi/`:

- `cluster/kafka-cluster.yaml` — a `KafkaNodePool` of **3 nodes** (combined
  broker+controller) plus a `Kafka` CR in **KRaft mode** (no ZooKeeper), sized
  for replication-factor 3.
- `topics/hello-topics.yaml` — three `KafkaTopic` resources
  (`hello.greetings`, `hello.events`, `hello.logs`).
- `users/hello-user.yaml` — an optional `KafkaUser` with ACLs (only used if you
  enable authentication on a listener).

The cluster CR is the heart of it:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: hello-kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 3.7.1
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
  entityOperator:
    topicOperator: {}        # reconciles KafkaTopic resources
    userOperator: {}         # reconciles KafkaUser resources
```

For real use, move `examples/strimzi/` to `kubernetes/strimzi/` and update
`STRIMZI_DIR` so it lives with the rest of your infrastructure code.

### F.3 Validate and plan

Push. In **validate**, `strimzi:validate` does a client-side dry-run of all the
CRs. In **plan**, `strimzi:plan` adds the Strimzi Helm repo, renders the operator
chart, and runs `kubectl diff` for the cluster and topics. (On the very first
run the diff for the cluster is limited because the Strimzi CRDs aren't installed
yet — that's expected and noted in the job output.)

### F.4 Deploy — operator, then cluster, then topics

Deploys are manual, and they're ordered with `needs:` so they run in the right
sequence. Click ▶ on them in this order (or just click the first — the others
become available as each succeeds):

1. **`strimzi:deploy-operator`** — installs the Strimzi operator via Helm into
   the `kafka` namespace and waits for it to be ready. The operator is the thing
   that watches for `Kafka`/`KafkaTopic` resources and turns them into running
   pods.
2. **`strimzi:deploy-cluster`** — applies the node pool + `Kafka` CR, then
   **blocks until Strimzi reports the cluster `Ready`** (`kubectl wait
   kafka/hello-kafka --for=condition=Ready`). This is the step that actually
   spins up the 3 broker pods and their storage. It can take a few minutes.
3. **`strimzi:deploy-topics`** — applies the `KafkaTopic` (and optional
   `KafkaUser`) resources; the operators reconcile them into the cluster.

After step 2 you can watch it come up locally:

```bash
kubectl get kafka,kafkanodepool,pods -n kafka
# NAME                              ...   READY
# kafka.kafka.strimzi.io/hello-kafka      True
# pod/hello-kafka-dual-role-0       1/1   Running
# pod/hello-kafka-dual-role-1       1/1   Running
# pod/hello-kafka-dual-role-2       1/1   Running
```

### F.5 End-to-end smoke test

In the **test** stage, `strimzi:smoke-test` spins up a throwaway client pod,
**produces** a `hello world` message to `hello.greetings`, then **consumes** it
back — proving the cluster works for real, not just that the pods are up:

```
hello world from the pipeline
Strimzi end-to-end smoke test passed.
```

### F.6 Debug and cleanup

`strimzi:debug` (manual) dumps all the custom resources, the `Kafka` status
conditions, pods, and the operator logs — your first stop if the cluster won't
go Ready.

`strimzi:cleanup` (manual, needs `ALLOW_DESTROY: "true"`) tears down in the
**correct order** — topics/users CRs, then the `Kafka` CR (so the operator
removes the brokers cleanly), then the operator itself. Note that the
PersistentVolumeClaims are kept by default (`deleteClaim: false`) so your data
survives; the job prints the exact command to delete them if you truly want them
gone.

> **Why the ordering matters:** if you uninstalled the operator first, nothing
> would be left to clean up the broker StatefulSets and you'd get orphaned
> resources. Always delete the CRs while the operator is still running.

---

## 12. Putting it together

A realistic project configures **infrastructure first, then the application on
top of it**, in a single pipeline. With the `ENABLE_*` flags you choose which
tools participate. A common combination:

```yaml
  ENABLE_TERRAFORM: "true"     # provision AWS infra (VPC, EKS, buckets…)
  ENABLE_KUBERNETES: "false"   # using Helm for the app instead of raw manifests
  ENABLE_HELM: "true"          # deploy the app
  ENABLE_ANSIBLE: "false"      # not configuring VMs in this project
  ENABLE_KAFKA: "true"         # create the app's topics
```

The pipeline then naturally orders the work by stage:

1. **prerequisites** — verify tools + AWS/cluster auth.
2. **validate** — fmt/lint/scan Terraform, Helm, and Kafka config in parallel.
3. **plan** — `terraform:plan`, `helm:template`, `kafka:list` all show intended
   changes.
4. **deploy** (manual) — you click to apply in this order of intent:
   - `terraform:apply` builds/updates the infrastructure and exports outputs,
   - `kafka:apply` ensures the topics exist,
   - `helm:deploy` rolls out the application.
5. **test** — `kubectl:smoke-test` confirms pods are healthy.

Because each tool reads the **same** `00-variables.yml` and the **same**
per-environment folders, promoting from dev → staging → prod is mostly a matter
of changing `ENVIRONMENT`, `TF_ROOT`, and `HELM_VALUES_FILE` (or running the
pipeline with those overridden). State is isolated per environment automatically.

> **Ordering note:** within the manual deploy stage, run the jobs in the order
> above. If you want strict automatic ordering instead of manual clicks, add
> `needs:` between the jobs (e.g. make `helm:deploy` need `terraform:apply`) and
> set `AUTO_APPLY: "true"`.

---

## 13. Debugging

When a job fails, use the **manual debug jobs** — they never run on their own and
never block the pipeline. Trigger them from the pipeline view (▶):

- `debug:environment` — prints all non-secret CI variables and your toggles/versions.
- `debug:aws` — `get-caller-identity`, lists EKS clusters, shows your state objects.
- `debug:kubernetes` — nodes, all resources in the namespace, recent events, and
  describes/logs of any non-running pods.
- `debug:helm` — release list, history, the deployed manifest, and computed values.
- `debug:terraform` — `state list`, providers, and outputs.

You can also set `PIPELINE_DEBUG: "true"` (in `00-variables.yml` or as a manual
run variable) to turn on verbose shell tracing across **every** job.

Common first checks:

| Symptom                                   | Look at                                   |
|-------------------------------------------|-------------------------------------------|
| Auth/identity errors                      | `debug:aws`; check `AWS_ROLE_ARN`/keys    |
| kubectl "Unauthorized" / can't connect    | cluster `aws-auth` mapping; `debug:kubernetes` |
| Terraform "state locked"                  | a stuck run; see cleanup below            |
| Helm upgrade failed but app gone          | `HELM_ATOMIC` rolled it back; `debug:helm`|

---

## 14. Cleaning up

Teardown is deliberately hard to do by accident. **Two locks** must both be
satisfied: set `ALLOW_DESTROY: "true"` **and** click the manual job.

To tear down the examples, set in `00-variables.yml` (or as run variables):

```yaml
  ALLOW_DESTROY: "true"
```

Then run the cleanup-stage jobs in this order, clicking each ▶:

1. `helm:uninstall` — removes the Helm release.
2. `kubectl:delete` — removes raw-manifest workloads.
3. `terraform:destroy` — destroys the AWS infrastructure (your hello bucket, etc.).

Optional and dangerous: `cleanup:tf-state` removes the env's state object — only
runs if you also set `CLEANUP_RETAIN_STATE: "false"`. Leave state alone unless
you're decommissioning the whole environment.

`cleanup:artifacts` is the safe one — it just prunes scratch files and can run on
a schedule.

> **Don't forget to set `ALLOW_DESTROY` back to `"false"`** after you're done, so
> nobody can trigger a destroy by clicking a stray button.

---

## 15. Cheat sheet

**Turn a tool on/off:** flip its `ENABLE_*` in `ci/includes/00-variables.yml`.

**Where the hello-world examples put files:**

| Example   | Files you create/edit                                  | Deploy job        |
|-----------|--------------------------------------------------------|-------------------|
| Terraform | `terraform/environments/dev/hello.tf`                  | `terraform:apply` |
| Kubernetes| `kubernetes/manifests/hello.yaml`                      | `kubectl:apply`   |
| Helm      | `helm/values/dev.yaml` (+ chart in `helm/charts/`)     | `helm:deploy`     |
| Ansible   | `ansible/playbooks/hello.yml`, `ansible/inventory/dev.ini` | `ansible:run` |
| Kafka     | `kafka/topics/topics.yml`                              | `kafka:apply`     |
| Strimzi   | `examples/strimzi/{cluster,topics,users}/`             | `strimzi:deploy-cluster` |

**The golden rules:**

- Plan is automatic and safe; **deploy and destroy need a human**.
- **No secrets in the repo** — use protected CI/CD variables.
- State is **isolated per environment** and **locked** during apply.
- Tool versions are **pinned** and verified before any real work.
- Stuck? Run a **`debug:*`** job or set `PIPELINE_DEBUG: "true"`.

You now have a repeatable way to configure both infrastructure and applications
from one pipeline. Start with Example A, get it green, then layer on the others
one `ENABLE_*` flag at a time.
