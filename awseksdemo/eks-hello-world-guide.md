# Deploying a Hello-World App on Amazon EKS

A complete, self-contained walkthrough for provisioning an EKS cluster, deploying a 3-pod hello-world app behind a load balancer, verifying it, troubleshooting, and tearing everything down cleanly. Every `aws`, `eksctl`, and `kubectl` command used in both standup and teardown is included, along with the full YAML files.

> **Version note:** As of mid-2026, EKS standard support runs through Kubernetes 1.36, with 1.33 widely available. This guide targets **1.33** as a safe, well-supported default. If you're building a cluster meant to last, consider `--version 1.35` or `1.36` for a longer support runway — 1.33's standard support window ends in late July 2026 before moving to extended support.

## Naming conventions used throughout

| Resource | Value |
|----------|-------|
| Cluster name | `hello-world-cluster` |
| Region | `us-east-1` |
| Node group | `standard-workers` |
| EKS CloudFormation stack | `eksctl-hello-world-cluster-cluster` |
| Node group CloudFormation stack | `eksctl-hello-world-cluster-nodegroup-standard-workers` |
| Manifest file | `hello-world.yaml` |

> **Note on stack names:** When you create a cluster with `eksctl`, it generates CloudFormation stacks named `eksctl-<cluster>-cluster` and `eksctl-<cluster>-nodegroup-<group>`. If instead you used a custom build with separate VPC/EKS stacks (e.g. `hello-world-cluster-vpc` / `hello-world-cluster-eks`), substitute those names where noted. List your actual stack names anytime with `aws cloudformation list-stacks`.

---

# PART 1 — STANDUP

## Prerequisites

Install and configure these three tools first.

### AWS CLI

```bash
# macOS (Homebrew)
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Windows
msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
```

Configure credentials:

```bash
aws configure   # enter access key, secret, region (e.g. us-east-1), output format

# Confirm who you are — note this identity; it must match the one running kubectl later
aws sts get-caller-identity
```

### eksctl (official EKS provisioning CLI)

**Linux / macOS:**

```bash
# Download and extract eksctl to /tmp
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp

# Move the binary to your local bin directory
sudo mv /tmp/eksctl /usr/local/bin
```

**Windows** — the Unix command above won't run natively. Use a package manager in a terminal opened **as Administrator**:

```powershell
winget install eksctl          # Option 1 (recommended)
```

```powershell
choco install eksctl           # Option 2: Chocolatey
```

```powershell
scoop bucket add aws           # Option 3: Scoop
scoop install eksctl
```

### kubectl

```bash
# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# macOS (Homebrew)
brew install kubectl

# Windows
winget install -e --id Kubernetes.kubectl
```

### Verify all three

```bash
eksctl version
kubectl version --client
aws sts get-caller-identity
```

Your IAM principal needs permissions for **EKS, EC2, CloudFormation, IAM, and VPC**. An admin-level policy is simplest for a test cluster.

---

## Step 1 — Create the Cluster

`eksctl` provisions the control plane, a VPC, and a managed node group via CloudFormation. This takes roughly **15–20 minutes**.

### Option A — Flags (quickest)

**Linux / macOS** (backslash line continuation):

```bash
eksctl create cluster \
  --name hello-world-cluster \
  --region us-east-1 \
  --version 1.33 \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 3 \
  --managed
```

**Windows PowerShell** (backtick `` ` `` line continuation):

```powershell
eksctl create cluster `
  --name hello-world-cluster `
  --region us-east-1 `
  --version 1.33 `
  --nodegroup-name standard-workers `
  --node-type t3.medium `
  --nodes 2 `
  --nodes-min 2 `
  --nodes-max 3 `
  --managed
```

**Windows Command Prompt (CMD)** (caret `^` line continuation):

```cmd
eksctl create cluster ^
  --name hello-world-cluster ^
  --region us-east-1 ^
  --version 1.33 ^
  --nodegroup-name standard-workers ^
  --node-type t3.medium ^
  --nodes 2 ^
  --nodes-min 2 ^
  --nodes-max 3 ^
  --managed
```

### Option B — Cluster config file (reproducible)

Save as `cluster.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: hello-world-cluster
  region: us-east-1
  version: "1.33"

managedNodeGroups:
  - name: standard-workers
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 3
    volumeSize: 20
    # Uncomment to allow SSH into nodes:
    # ssh:
    #   allow: true
    #   publicKeyName: your-ec2-keypair

# Default managed addons installed by eksctl
addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: metrics-server

# Send control-plane logs to CloudWatch (optional)
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator"]
```

Create from the file:

```bash
eksctl create cluster -f cluster.yaml
```

A successful run ends with messages confirming the kubeconfig was saved, the node group has 2 nodes, and both nodes are `ready`.

---

## Step 2 — Connect kubectl & Inspect

`eksctl` updates your kubeconfig automatically. If you used a separate process, or kubectl points elsewhere, wire it up manually:

```bash
aws eks update-kubeconfig --name hello-world-cluster --region us-east-1
```

Verify the connection and context:

```bash
kubectl config current-context     # shows the EKS cluster ARN
kubectl get nodes                  # should list 2 Ready nodes
```

### How the authentication works

The kubeconfig entry doesn't store a password. It stores a command that calls the AWS CLI to generate a short-lived token on each request, using your current AWS credentials. Three things must be true:

1. The AWS CLI is configured (`aws configure` done, or env vars set).
2. Your IAM identity has access to the cluster — automatic here, since the CloudFormation template sets `BootstrapClusterCreatorAdminPermissions`, making the stack creator a cluster admin.
3. **The same IAM identity that created the cluster is the one running kubectl.** This is the usual gotcha — a different user/role gives an "Unauthorized" error even when the config looks right. Confirm with `aws sts get-caller-identity`.

### AWS-side inspection commands

```bash
# List clusters in the region
aws eks list-clusters --region us-east-1

# Full cluster details — status, endpoint, version, networking
aws eks describe-cluster --name hello-world-cluster --region us-east-1

# Just the status (you want ACTIVE)
aws eks describe-cluster --name hello-world-cluster --region us-east-1 \
  --query "cluster.status" --output text

# List node groups
aws eks list-nodegroups --cluster-name hello-world-cluster --region us-east-1

# Node group health (you want ACTIVE)
aws eks describe-nodegroup \
  --cluster-name hello-world-cluster \
  --nodegroup-name standard-workers \
  --region us-east-1 \
  --query "nodegroup.status" --output text

# Installed addons
aws eks list-addons --cluster-name hello-world-cluster --region us-east-1
```

### Watch the CloudFormation stacks build (optional)

```bash
# List the stacks eksctl created
aws cloudformation list-stacks --region us-east-1 \
  --query "StackSummaries[?contains(StackName, 'hello-world-cluster')].[StackName,StackStatus]" \
  --output table

# Tail events for the cluster stack
aws cloudformation describe-stack-events \
  --stack-name eksctl-hello-world-cluster-cluster \
  --region us-east-1 \
  --max-items 20
```

> **Sequencing note:** `update-kubeconfig` succeeds the moment the cluster is `ACTIVE`, but `kubectl get nodes` shows nothing until the node group finishes and nodes register. If the cluster is active but `get nodes` is empty, the node group is still coming up — check it with `describe-nodegroup` above.

---

## Step 3 — The YAML Manifest

Save the following as `hello-world.yaml`. It creates a **3-replica deployment** (your three pods) fronted by a **LoadBalancer** service.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
  labels:
    app: hello-world
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
      - name: hello-world
        image: nginxdemos/hello:plain-text
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
spec:
  type: LoadBalancer
  selector:
    app: hello-world
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

The `nginxdemos/hello` image returns a small page showing the serving pod's name and IP, so you can watch the three pods load-balancing.

### Alternative: ClusterIP (no public load balancer)

If you'd rather avoid a public ELB entirely, change the Service block's `type` to `ClusterIP` and reach the pods with port-forwarding (see Step 6). Everything else stays the same.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-world
spec:
  type: ClusterIP      # changed from LoadBalancer
  selector:
    app: hello-world
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

---

## Step 4 — Apply the Manifest

```bash
kubectl apply -f hello-world.yaml
kubectl rollout status deployment/hello-world
```

> **Path matters.** `kubectl apply -f k8s/hello-world.yaml` fails with `the path does not exist` if you're not in the right directory. Use the actual path to your file — either `cd` into its folder or give the full/correct relative path.

---

## Step 5 — Verify the Three Pods

```bash
kubectl get pods -l app=hello-world      # expect 3 pods, all Running
kubectl get deployment hello-world       # READY 3/3
kubectl describe deployment hello-world  # full detail if anything looks off
```

---

## Step 6 — Get the Public URL

The LoadBalancer service provisions an AWS ELB. The hostname takes **2–3 minutes** to populate.

### See it in context

```bash
kubectl get service hello-world
```

```
NAME          TYPE           CLUSTER-IP      EXTERNAL-IP                       PORT(S)        AGE
hello-world   LoadBalancer   10.100.42.118   a1b2c3d4...elb.amazonaws.com      80:31234/TCP   3m
```

### Extract just the hostname

```bash
kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

### Build a ready-to-paste URL

```bash
echo "http://$(kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

### Wait for it to populate, then print it

```bash
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' \
  service/hello-world --timeout=180s \
  && echo "http://$(kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

### From the AWS side

```bash
# Lists every NLB/ALB in the region (not cluster-specific)
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].DNSName" --output text
```

### Then hit it

```bash
curl http://<EXTERNAL-IP>     # refresh a few times to watch the pod name change
```

### ClusterIP fallback — reach the app with no load balancer

```bash
kubectl port-forward service/hello-world 8080:80
# then visit http://localhost:8080
```

**Reminders:** The URL is `http`, not `https` (only port 80 is exposed). If jsonpath returns nothing, the load balancer is still provisioning — wait 2–3 minutes. On AWS the field is almost always `.hostname`; if you get an IP-style field instead, swap `.hostname` for `.ip`.

---

## Troubleshooting

### App not showing up — `services "hello-world" not found`

The cluster and EC2 instances existing only means the **infrastructure** is up. The pods and service are a **separate layer** you deploy on top with kubectl. If the workload was never applied:

```bash
# Confirm kubectl is connected
kubectl get nodes

# Check what's actually deployed across ALL namespaces
kubectl get services --all-namespaces
kubectl get deployments --all-namespaces
kubectl get pods --all-namespaces

# Cluster-wide events, newest last
kubectl get events -A --sort-by='.lastTimestamp'
```

The `--all-namespaces` flag matters — if the manifest landed in a different namespace than your context default, a plain `kubectl get services` would miss it.

If `hello-world` isn't in any list, it was never applied. Apply it (using the correct path):

```bash
kubectl apply -f hello-world.yaml
kubectl rollout status deployment/hello-world
```

### No EXTERNAL-IP / no LoadBalancer ingress

You don't manually "add" the ingress — AWS fills it in automatically once the load balancer provisions. Its absence means provisioning hasn't finished or has failed.

**First, confirm the service type:**

```bash
kubectl get service hello-world
```

Check the `TYPE` column. It must say `LoadBalancer`. If it says `ClusterIP`, there will never be an ingress — see the fix below.

**Then find what's blocking provisioning:**

```bash
kubectl describe service hello-world
```

Look at the **Events:** section at the bottom:

| Event | Meaning | Action |
|-------|---------|--------|
| `EnsuringLoadBalancer` then nothing | Still working | An AWS NLB takes 2–5 min. Watch with `kubectl get service hello-world -w` |
| `SyncLoadBalancerFailed` with a reason | That reason is the answer | Common: no subnets tagged for ELB, no available IPs, node-role permissions |
| No events, several minutes in | Cloud controller isn't acting | Usually nodes aren't ready or networking is incomplete |

**Also check the nodes** — a LoadBalancer service with no healthy nodes behind it can stall:

```bash
kubectl get nodes      # all must be Ready
```

**If the TYPE is wrong (`ClusterIP`)**, either re-apply the manifest or patch the existing service:

```bash
kubectl patch service hello-world -p '{"spec":{"type":"LoadBalancer"}}'
```

**Fallback that needs no load balancer** — reach the app immediately while the ELB sorts out:

```bash
kubectl port-forward service/hello-world 8080:80
# then visit http://localhost:8080
```

### Common kubectl connection errors

| Error | Cause & Fix |
|-------|-------------|
| `You must be logged in to the server (Unauthorized)` | IAM identity running kubectl isn't the one that created the cluster, or credentials aren't loading. Confirm with `aws sts get-caller-identity` |
| `Unable to connect to the server: dial tcp ... i/o timeout` | Cluster isn't `ACTIVE` yet, or wrong region. Check cluster status |
| `The connection to the server localhost:8080 was refused` | kubectl has no cluster configured. Re-run `aws eks update-kubeconfig` and check `kubectl config current-context` |

---

# PART 2 — TEARDOWN

This cluster costs roughly **$0.10/hr** for the control plane, plus the two EC2 instances and the ELB.

> **Order matters.** Deleting in the wrong sequence leaves orphaned resources that keep billing and block the VPC from deleting. The single most important rule: **delete the Kubernetes LoadBalancer service first.** If you delete the cluster while the service still exists, the load balancer is orphaned and its network interfaces (ENIs) stay attached to your subnets, blocking the VPC from ever deleting.

## The simple path (eksctl-managed cluster)

For a cluster created with `eksctl`, this is the whole teardown. `eksctl delete cluster` removes the node group, control plane, addons, IAM roles, and the VPC it created — all in dependency order.

```bash
# 1. Delete the app first so AWS tears down the ELB cleanly
kubectl delete -f hello-world.yaml

# 2. Wait ~60s, then confirm the load balancer is gone (see Step 1 below)

# 3. Delete the entire cluster and all eksctl-created infrastructure
eksctl delete cluster --name hello-world-cluster --region us-east-1
```

Use `eksctl delete cluster -f cluster.yaml` instead if you created from the config file.

The steps below break this down explicitly and cover the manual CloudFormation path if you need it.

---

## Step 1 — Delete the Kubernetes service (releases the load balancer)

```bash
kubectl delete -f hello-world.yaml
# or by name:
kubectl delete service hello-world
kubectl delete deployment hello-world
```

Wait ~60 seconds, then **confirm the load balancer is gone** before continuing:

```bash
# Network/Application LB
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].LoadBalancerName" --output text

# Classic LB
aws elb describe-load-balancers --region us-east-1 \
  --query "LoadBalancerDescriptions[].LoadBalancerName" --output text
```

(Two commands because a classic LB shows under `elb`, a network/application LB under `elbv2`.) Both should come back empty. **Don't skip this confirmation — it's the whole point of the ordering.**

---

## Step 2 — Delete the cluster

### Option A — eksctl (recommended for eksctl-created clusters)

```bash
eksctl delete cluster --name hello-world-cluster --region us-east-1
```

This deletes the node group, control plane, addons, IAM roles, and the VPC/networking together. It internally deletes the CloudFormation stacks in the correct order and waits for completion.

### Option B — CloudFormation directly

Use this only if you built the cluster with separate stacks or need manual control. Delete the **EKS/cluster stack first**, then the **VPC stack** — never the reverse.

```bash
# EKS / cluster stack (control plane + node group + IAM roles)
aws cloudformation delete-stack \
  --stack-name eksctl-hello-world-cluster-cluster \
  --region us-east-1
aws cloudformation wait stack-delete-complete \
  --stack-name eksctl-hello-world-cluster-cluster \
  --region us-east-1
```

If your build used a separate VPC stack (custom setups named like `hello-world-cluster-vpc`), delete it **only after** the EKS stack is fully gone:

```bash
aws cloudformation delete-stack \
  --stack-name hello-world-cluster-vpc \
  --region us-east-1
aws cloudformation wait stack-delete-complete \
  --stack-name hello-world-cluster-vpc \
  --region us-east-1
```

The `wait` commands block until each stack is fully deleted (a few minutes each). This removes the VPC, both subnet pairs, the NAT gateway, internet gateway, route tables, and Elastic IP.

---

## Step 3 — Verify nothing's left

```bash
# Stacks should not list any hello-world-cluster stacks still active
aws cloudformation list-stacks --region us-east-1 \
  --query "StackSummaries[?StackStatus!='DELETE_COMPLETE' && contains(StackName, 'hello-world-cluster')].[StackName,StackStatus]" \
  --output table

# Cluster should be gone
aws eks list-clusters --region us-east-1

# No leftover load balancers
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].LoadBalancerName" --output text
```

---

## If the VPC stack gets stuck in `DELETE_FAILED`

This almost always traces back to Step 1 being skipped — an orphaned load balancer's ENIs holding the subnets.

**Manually delete any leftover load balancer:**

```bash
# find it
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[].[LoadBalancerName,LoadBalancerArn]" --output table
# delete it
aws elbv2 delete-load-balancer \
  --load-balancer-arn <arn-from-above> --region us-east-1
```

**Then find the VPC ID and check for stuck network interfaces:**

```bash
# Get the VPC ID (filter by the eksctl tag if you have many VPCs)
aws ec2 describe-vpcs --region us-east-1 \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=hello-world-cluster" \
  --query "Vpcs[].VpcId" --output text

# Check for ENIs still attached to that VPC
aws ec2 describe-network-interfaces --region us-east-1 \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
  --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" --output table
```

**Detach/delete any available ENIs that remain:**

```bash
aws ec2 delete-network-interface \
  --network-interface-id <eni-id-from-above> --region us-east-1
```

Once those ENIs are released (deleting the load balancer usually clears them within a minute or two), retry the stack deletion:

```bash
aws cloudformation delete-stack \
  --stack-name hello-world-cluster-vpc --region us-east-1
aws cloudformation wait stack-delete-complete \
  --stack-name hello-world-cluster-vpc --region us-east-1
```

---

# Quick Reference — All Commands

## Standup

```bash
# Configure & verify identity
aws configure
aws sts get-caller-identity

# Create cluster (15–20 min)
eksctl create cluster \
  --name hello-world-cluster --region us-east-1 --version 1.33 \
  --nodegroup-name standard-workers --node-type t3.medium \
  --nodes 2 --nodes-min 2 --nodes-max 3 --managed

# Connect kubectl & verify
aws eks update-kubeconfig --name hello-world-cluster --region us-east-1
kubectl config current-context
kubectl get nodes

# Deploy app
kubectl apply -f hello-world.yaml
kubectl rollout status deployment/hello-world
kubectl get pods -l app=hello-world

# Get the URL
echo "http://$(kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
```

## Teardown

```bash
# 1. Delete the app FIRST (releases the load balancer)
kubectl delete -f hello-world.yaml

# 2. Confirm the LB is gone
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].LoadBalancerName" --output text
aws elb describe-load-balancers --region us-east-1 --query "LoadBalancerDescriptions[].LoadBalancerName" --output text

# 3. Delete the cluster (and all eksctl-created infra)
eksctl delete cluster --name hello-world-cluster --region us-east-1

# 4. Verify
aws eks list-clusters --region us-east-1
aws cloudformation list-stacks --region us-east-1 \
  --query "StackSummaries[?StackStatus!='DELETE_COMPLETE' && contains(StackName, 'hello-world-cluster')].StackName" --output table
```
