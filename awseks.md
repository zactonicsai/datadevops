# EKS node group + hello-world — line-by-line command reference

This is the **command-by-command** companion to `eks-nodegroup-helloworld.sh`.
Every shell command in the workflow is shown inline and then dissected: **what**
it does, **why** you need it, and **how** it works with AWS under the hood.

---

## 0. AWS CLI fundamentals (read this once)

Almost every command below has the same shape:

```bash
aws <service> <operation> [--flags]
```

- **`aws`** — the AWS command-line tool (v2). It takes your request, **signs**
  it with your credentials using AWS Signature v4, and sends it over HTTPS to
  the right **regional API endpoint**. You never see the signing; the CLI does it.
- **`<service>`** — which AWS API you're calling: `eks`, `iam`, `ec2`, `sts`, `ssm`.
- **`<operation>`** — the action, e.g. `describe-cluster`, `create-nodegroup`.
- **`--region`** — which regional endpoint to hit. EKS, EC2, and SSM are
  *regional*; IAM and STS are *global* (so they don't need `--region`).
- **`--query '...'`** — a **JMESPath** expression applied to the JSON response
  **on your machine** to pull out just the field(s) you want. It filters output;
  it does not change what AWS does.
- **`--output text|json|table`** — the print format. `text` is best for
  scripting because you can capture a bare value into a shell variable.
- **`file://path`** — tells the CLI "the value for this flag lives in this local
  file," instead of treating the text literally. Used for JSON policy documents.
- **ARN** — *Amazon Resource Name*, a globally-unique ID shaped like
  `arn:aws:service:region:account-id:resource`. IAM ARNs leave the region blank
  because IAM is global.
- **Where credentials come from** — `aws configure` (saved in `~/.aws/`),
  environment variables, or an attached instance role (this is automatic inside
  AWS CloudShell).

With that, here is the whole journey.

---

## Step 0 — Pre-flight checks

### Are the tools installed?

```bash
command -v aws     >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v curl    >/dev/null || { echo "curl not found"; exit 1; }
```

**What:** confirms each program is on your `PATH`.
**Line by line:**
- `command -v aws` — a shell built-in that prints the program's path if it
  exists and returns a non-zero exit code if it doesn't. (Not AWS-specific.)
- `>/dev/null` — throw away the printed path; we only care about success/failure.
- `|| { ... }` — run the block **only if** the check failed.
**Why:** fail early with a clear message instead of a confusing error halfway in.

### Are my AWS credentials valid, and who am I?

```bash
aws sts get-caller-identity
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
```

**What:** asks AWS "whose credentials are these?" and saves your account number.
**Line by line:**
- `sts` — **Security Token Service**, the AWS identity service.
- `get-caller-identity` — returns the **Account**, **UserId**, and **ARN** of the
  caller. It's the cheapest possible "are my credentials working?" probe.
- `--query Account` — JMESPath that keeps only the 12-digit account number.
- `--output text` — print it as a bare string so it can go into a variable.
**Why/how:** if credentials are missing or expired this command fails, so it's a
perfect gate. AWS authenticates the request from your signed credentials; no
special permission is required to ask who you are.

### Does the cluster exist, and what version is it?

```bash
aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION"
CLUSTER_VERSION="$(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --region "$REGION" --query 'cluster.version' --output text)"
```

**What:** reads the cluster's full configuration, then extracts its Kubernetes version.
**Line by line:**
- `eks describe-cluster` — the EKS API that returns everything about a cluster:
  API endpoint, status, networking (VPC/subnets), and version.
- `--name "$CLUSTER_NAME"` — which cluster to look up.
- `--query 'cluster.version'` — dive into the returned JSON object `cluster` and
  pull its `version` field (e.g. `1.31`).
**Why:** the call failing means the name/region is wrong. We also grab the
version because **worker nodes must be created at the same version as the
cluster** — you can't mix versions at creation time.

---

## Step 1 — Node IAM role (the workers' "permission badge")

A worker node runs an agent (the kubelet) that must call AWS APIs for you. It
gets permission through an **IAM role** attached to the EC2 instance.

### Does the role already exist?

```bash
aws iam get-role --role-name "$NODE_ROLE_NAME"
```

**What:** looks up the role; used as a yes/no existence check via its exit code.
**Line by line:**
- `iam` — **Identity and Access Management**, AWS's permissions service (global,
  so no `--region`).
- `get-role --role-name N` — returns the role's JSON, or errors if it's absent.
**Why:** lets the script reuse an existing role instead of failing on a duplicate.

### The trust policy (who is allowed to *wear* the badge)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

**What:** a JSON document that says "EC2 instances may assume this role."
**Line by line:**
- `"Version": "2012-10-17"` — the IAM policy-language version. Always this exact
  date string; it is not your choice.
- `"Statement"` — the list of rules in this policy.
- `"Effect": "Allow"` — permit the action that follows.
- `"Principal": { "Service": "ec2.amazonaws.com" }` — **who** may assume the
  role: the EC2 service itself, which is what lets your worker instances use it.
- `"Action": "sts:AssumeRole"` — the act of taking on the role's permissions.
**Why/how:** this is a **trust policy** (who can assume the role), which is
different from a **permissions policy** (what the role can do). A role needs both.

### Create the role

```bash
aws iam create-role --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json
```

**What:** creates the IAM role with the trust policy above.
**Line by line:**
- `create-role --role-name N` — make a new role with this name.
- `--assume-role-policy-document file://trust-policy.json` — attach the trust
  document; the `file://` prefix tells the CLI to **read it from disk** rather
  than treat the path as a literal string.
**Why/how:** the role is born with **zero permissions** — only the trust rule.
You grant abilities in the next step by attaching policies.

### Attach the three core permissions policies

```bash
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```

**What:** grants the role the three abilities every EKS worker needs.
**Line by line:**
- `attach-role-policy --role-name N` — bolt a permissions policy onto the role.
- `--policy-arn arn:aws:iam::aws:policy/...` — the policy's ARN. The **empty
  account field** (`iam::aws:` with nothing between the colons after `iam:`)
  means it is an **AWS-managed** policy owned by AWS, not a custom one in your
  account.
- The three policies, in order, let the worker: **talk to the EKS control
  plane**, **pull container images from ECR**, and **set up pod networking (CNI)**.
**Why/how:** attaching the same policy twice is harmless (idempotent), so the
script can safely re-attach on every run. If a worker stays `NotReady`, a
missing policy here is one of the two usual causes.

### (Optional) Allow shell access via Session Manager

```bash
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

**What:** lets you open a shell on a node later **without SSH keys or open ports**.
**Why/how:** the SSM agent on the node uses this policy to register with Systems
Manager, which then brokers an interactive session through IAM.

### Read back the role's ARN

```bash
NODE_ROLE_ARN="$(aws iam get-role --role-name "$NODE_ROLE_NAME" \
  --query 'Role.Arn' --output text)"
```

**What:** fetches the role's ARN and stores it for the node-group command.
**Line by line:**
- `--query 'Role.Arn'` — pull the `Arn` field out of the `Role` object.
**Why/how:** `create-nodegroup` wants the role's **ARN**, not its name. Behind
the scenes EKS wraps this role in an **instance profile**, attaches it to each
worker EC2 instance, and the kubelet then receives **temporary credentials**
from the instance metadata service (IMDS).

---

## Step 2 — Discover the subnets

```bash
SUBNETS="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)"
```

**What:** gets the list of subnets the cluster already uses, to place workers in.
**Line by line:**
- `--query 'cluster.resourcesVpcConfig.subnetIds'` — drill into
  `cluster` → `resourcesVpcConfig` → `subnetIds`, which is the array of subnet IDs.
- `--output text` — prints them **space/tab-separated on one line**, which is
  exactly the format the `--subnets` flag wants next.
**Why/how:** the worker Auto Scaling group spreads instances across these subnets
(and their Availability Zones). **Private** subnets need a NAT gateway or ECR
PrivateLink endpoints to pull images; **public** subnets must have
`MapPublicIpOnLaunch=true` or the nodes won't get an IP and won't join.

---

## Step 3 — Create the managed node group

### Existence check (for safe re-runs)

```bash
aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --region "$REGION"
```

**What:** errors if the node group doesn't exist; the script uses that to decide
whether to create it.
**Why:** makes the script **idempotent** — re-running won't try to create a
duplicate.

### The create command

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets subnet-aaa subnet-bbb subnet-ccc \
  --scaling-config minSize=2,maxSize=5,desiredSize=2 \
  --instance-types m6i.large \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --disk-size 50 \
  --update-config maxUnavailablePercentage=33 \
  --node-repair-config enabled=true \
  --region "$REGION"
```

**What:** tells EKS to provision a managed Auto Scaling group of workers and
register them with the cluster.
**Line by line (the flags that matter):**
- `--cluster-name` — which cluster these workers join.
- `--nodegroup-name` — a unique name for this group within the cluster.
- `--node-role` — the **IAM role ARN** from Step 1 (the workers' badge).
- `--subnets a b c` — **space-separated** subnet IDs; the group spreads across
  these and their AZs for resilience.
- `--scaling-config minSize=,maxSize=,desiredSize=` — the Auto Scaling bounds.
  `desiredSize` is how many launch **now**; `min`/`max` bound future scaling.
- `--instance-types m6i.large` — the EC2 machine type(s). You may list several
  (space-separated); doing so is recommended for Spot.
- `--ami-type AL2023_x86_64_STANDARD` — the **operating-system image family**.
  AL2 is retired; use AL2023 or Bottlerocket. Match the architecture to the
  instance (ARM AMI ↔ Graviton instances).
- `--capacity-type ON_DEMAND` — pricing model. `SPOT` is cheaper but reclaimable.
- `--disk-size 50` — root **EBS** volume size in GiB.
- `--update-config maxUnavailablePercentage=33` — during a version upgrade, at
  most 33% of the nodes are taken down at once.
- `--node-repair-config enabled=true` — EKS watches node health and **auto-
  replaces** unhealthy nodes. (Needs a recent CLI; drop this flag on old ones.)
**Why/how:** this one call makes AWS build a **launch template**, an **EC2 Auto
Scaling group**, and the instances; tag them for this cluster; and join them.
The command **returns immediately** with status `CREATING` — it does not wait.

> Tip: `aws eks create-nodegroup --generate-cli-skeleton > ng.json` prints a
> blank template of every possible field; fill it in and run with
> `--cli-input-json file://ng.json` to avoid long command lines.

### Wait until the workers are ready

```bash
aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --region "$REGION"
```

**What:** blocks until the node group reaches `ACTIVE`.
**Line by line:**
- `eks wait nodegroup-active` — a built-in **waiter**: the CLI repeatedly calls
  `describe-nodegroup` on a fixed interval until the status is `ACTIVE` (or it
  times out after the waiter's maximum attempts).
**Why/how:** keeps the script from racing ahead before the instances exist. The
polling happens on **your** machine; there's no extra AWS charge for waiting.

---

## Step 4 — Point kubectl at the cluster and check the nodes

```bash
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
kubectl get nodes -o wide
```

**What:** configures `kubectl` for this cluster, then lists the worker nodes.
**Line by line:**
- `eks update-kubeconfig --name C` — writes a context into your local
  `~/.kube/config` containing the cluster's API endpoint **and** an `exec`
  credential plugin. When kubectl needs to authenticate, that plugin runs
  `aws eks get-token` behind the scenes, so your **IAM identity** logs you in.
- `kubectl get nodes` — asks the cluster's API for the list of nodes.
- `-o wide` — adds extra columns: internal/external IPs, OS image, kernel, and
  instance type.
**Why/how:** this is the moment of truth — the nodes from your new group should
appear in `Ready` state. `kubectl` talks to the EKS API server (not the AWS API
directly), authenticating with the token the plugin fetched via IAM.

---

## Step 5 — Deploy the hello-world app

### The manifest

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: hashicorp/http-echo
          args:
            - "-text=hello world"
            - "-listen=:5678"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  type: NodePort
  selector:
    app: hello
  ports:
    - port: 80
      targetPort: 5678
      nodePort: 30080
```

**What:** declares two things — a program to run, and a way to reach it.
**Line by line (Deployment):**
- `kind: Deployment` — "keep N copies of this program running, replace any that die."
- `replicas: 2` — run two copies (Pods).
- `selector.matchLabels.app: hello` — the Deployment manages Pods carrying the
  label `app: hello`.
- `template` — the blueprint for each Pod.
- `image: hashicorp/http-echo` — a tiny program that replies with fixed text.
- `args: -text=hello world` — **the exact words curl will get back**.
- `args: -listen=:5678` — the port the program listens on **inside** the container.
- `containerPort: 5678` — documents that port to Kubernetes.
**Line by line (Service — the stable "front desk"):**
- `type: NodePort` — open the **same numbered door on every node** so external
  traffic can get in.
- `selector.app: hello` — forward traffic to Pods with that label.
- `port: 80` — the port the Service itself answers on (inside the cluster).
- `targetPort: 5678` — forward to the container's port.
- `nodePort: 30080` — the external door on each node (must be 30000–32767).

### Apply and verify

```bash
kubectl apply -f hello.yaml
kubectl rollout status deployment/hello --timeout=120s
kubectl get pods -l app=hello -o wide
```

**Line by line:**
- `kubectl apply -f hello.yaml` — send the manifest to the cluster API; it
  **creates or updates** the objects to match the file (declarative).
- `kubectl rollout status deployment/hello --timeout=120s` — wait until all
  desired replicas are up and available, or give up after 120 seconds.
- `kubectl get pods -l app=hello -o wide` — list the app's Pods; `-l app=hello`
  filters by label, and `-o wide` shows the **NODE** column — proof the Pods
  landed on your new node group.

---

## Step 6a — curl via port-forward (always works)

```bash
kubectl port-forward svc/hello 18080:80 &
PF_PID=$!
sleep 5
curl -s http://localhost:18080
kill "$PF_PID"
```

**What:** tunnels into the cluster and curls the app — no public networking needed.
**Line by line:**
- `kubectl port-forward svc/hello 18080:80` — open a tunnel: **local** port
  `18080` → the Service's port `80`, routed **through the Kubernetes API server**.
- `&` — run the tunnel in the background so the script can keep going.
- `PF_PID=$!` — capture the background process's PID so we can stop it later.
- `sleep 5` — give the tunnel a moment to establish.
- `curl -s http://localhost:18080` — hit the local end of the tunnel; `-s` means
  "silent" (no progress bar). The response body is `hello world`.
- `kill "$PF_PID"` — close the tunnel.
**Why/how:** because traffic rides the API server, this works even when the nodes
are in **private** subnets and have no public IP — ideal from CloudShell.

---

## Step 6b — curl a public LoadBalancer (optional)

```bash
kubectl apply -f -  <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: hello-lb
spec:
  type: LoadBalancer
  selector:
    app: hello
  ports:
    - port: 80
      targetPort: 5678
YAML

LB_HOST="$(kubectl get svc hello-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
curl -s --retry 10 --retry-delay 15 --retry-all-errors "http://${LB_HOST}"
```

**What:** asks AWS for a public load balancer in front of the app, then curls it.
**Line by line:**
- `type: LoadBalancer` — this single change makes the EKS **cloud controller**
  provision an actual AWS Elastic Load Balancer pointing at your nodes.
- `kubectl get svc hello-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
  — `jsonpath` is kubectl's own templating; this pulls the **ELB DNS name** out
  of the Service status once AWS assigns it.
- `curl --retry 10 --retry-delay 15 --retry-all-errors` — retry up to 10 times,
  15 seconds apart, **even on HTTP errors**, because a fresh ELB takes a couple
  of minutes to pass health checks and start serving.
**Why/how:** the ELB has its own public address and forwards to your (possibly
private) workers, so you can curl from anywhere without touching node IPs. Note
an ELB costs a small amount while it exists.

---

## Step 6c — curl the node's own IP (literal "connect to the node")

```bash
NODE_IP="$(kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')"

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP_NAME" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$REGION")"

NODE_SG="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
  --output text --region "$REGION")"

MY_IP="$(curl -s https://checkip.amazonaws.com)"

aws ec2 authorize-security-group-ingress --group-id "$NODE_SG" \
  --protocol tcp --port 30080 --cidr "${MY_IP}/32" --region "$REGION"

curl -s "http://${NODE_IP}:30080"

aws ec2 revoke-security-group-ingress --group-id "$NODE_SG" \
  --protocol tcp --port 30080 --cidr "${MY_IP}/32" --region "$REGION"
```

**What:** finds a node's public IP and its firewall, opens the firewall **just
for you**, curls the node, then closes the firewall again.
**Line by line:**
- `kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}'`
  — JSONPath with a **filter** `[?(@.type=="ExternalIP")]`: from the first node,
  return the address whose type is `ExternalIP`. If this is empty, your nodes are
  **private** — use 6a or 6b instead.
- `aws ec2 describe-instances --filters "Name=tag:eks:nodegroup-name,Values=..."`
  — find EC2 instances **tagged** as belonging to this node group (EKS adds the
  `eks:nodegroup-name` tag automatically).
- `"Name=instance-state-name,Values=running"` — only running instances.
- `--query 'Reservations[0].Instances[0].InstanceId'` — EC2 groups instances
  inside **Reservations**, so you index `Reservations` → `Instances` → first
  instance → its `InstanceId`.
- second `describe-instances ... 'SecurityGroups[0].GroupId'` — read that
  instance's first **security group** ID (its virtual firewall).
- `curl -s https://checkip.amazonaws.com` — an AWS-hosted endpoint that simply
  echoes **your** public IP, so we can scope the rule to you alone.
- `authorize-security-group-ingress --protocol tcp --port 30080 --cidr MY_IP/32`
  — add **one inbound rule**: allow TCP on the NodePort **from your IP only**.
  `/32` means a single address. Security groups are **stateful** firewalls that
  **deny inbound by default**, which is why this rule is required.
- `curl http://NODE_IP:30080` — hit the node's public IP on the NodePort door.
- `revoke-security-group-ingress ...` — remove that rule so nothing stays exposed.
**Why/how:** this is the most literal "connect to the node instance via curl," and
it only works when the node has a **public IP** and you open the firewall for it.

---

## Bonus — get a SHELL on a node (then curl from on the box)

```bash
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
# then, on the node itself:
curl http://localhost:30080
```

**Line by line:**
- `ssm start-session --target INSTANCE_ID` — open an **interactive shell** on the
  instance through **Systems Manager**. No SSH key, no open port, no bastion —
  it tunnels through the SSM agent and is authorized by IAM (this is why the node
  role needed `AmazonSSMManagedInstanceCore`).
- `curl http://localhost:30080` — from **on** the node, the NodePort is listening
  on the node's own network interface, so `localhost` reaches the app.
**Note:** **Bottlerocket** AMIs have no normal shell — you'll land in the special
admin/control container. **AL2023** gives you a regular Linux prompt.

---

## Cleanup — remove everything

```bash
kubectl delete deployment hello
kubectl delete service hello hello-lb --ignore-not-found
aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --region "$REGION"
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name "$NODEGROUP_NAME" --region "$REGION"
```

**Line by line:**
- `kubectl delete deployment hello` — remove the app and its Pods.
- `kubectl delete service hello hello-lb --ignore-not-found` — remove both
  Services; deleting the `LoadBalancer` Service also **tears down the AWS ELB**.
  `--ignore-not-found` avoids an error if a Service isn't there.
- `aws eks delete-nodegroup` — delete the managed group; EKS **drains** the Pods,
  **terminates** the EC2 instances, and removes the Auto Scaling group.
- `aws eks wait nodegroup-deleted` — poll until it's fully gone, so you know the
  instances (and their cost) have stopped.

---

## One-screen summary of the journey

```text
describe-cluster        → confirm cluster + version
create-role + attach×3  → build the workers' permission badge
describe-cluster query  → get subnets
create-nodegroup        → provision the workers
wait nodegroup-active   → block until they're ready
update-kubeconfig       → point kubectl at the cluster
kubectl get nodes       → confirm workers are Ready
kubectl apply           → deploy hello-world
port-forward + curl     → get "hello world" back
```
