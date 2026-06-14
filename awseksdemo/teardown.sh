#!/usr/bin/env bash
#


# Deploying a Hello-World App on Amazon EKS

A complete walkthrough for provisioning an EKS cluster, deploying a 3-pod hello-world app behind a load balancer, verifying it, troubleshooting common issues, and tearing everything down cleanly.

> **Version note:** As of mid-2026, EKS standard support runs through Kubernetes 1.36, with 1.33 widely available. This guide targets **1.33** as a safe, well-supported default. If you're building a cluster meant to last, consider `--version 1.35` or `1.36` for a longer support runway — 1.33's standard support window ends in late July 2026 before moving to extended support.

---

## Prerequisites

Install and configure these three tools first.

### AWS CLI

```bash
aws configure   # enter access key, secret, region (e.g. us-east-1), output format
```

### eksctl (official EKS provisioning CLI)

Choose the commands for your operating system.

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
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

### Verify all three

```bash
eksctl version && kubectl version --client && aws sts get-caller-identity
```

Your IAM principal needs permissions for **EKS, EC2, CloudFormation, IAM, and VPC**. An admin-level policy is simplest for a test cluster.

---

## Step 1 — Create the Cluster

`eksctl` provisions the control plane, a VPC, and a managed node group via CloudFormation. This takes roughly **15–20 minutes**.

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

A successful run ends with messages confirming the kubeconfig was saved, the node group has 2 nodes, and both nodes are `ready`.

---

## Step 2 — Confirm kubectl Is Connected

`eksctl` updates your kubeconfig automatically. Verify the connection:

```bash
kubectl get nodes        # should list 2 Ready nodes
```

If kubectl isn't connected (or you create/run as different IAM identities), wire it up manually:

```bash
aws eks update-kubeconfig --name hello-world-cluster --region us-east-1
```

### How the authentication works

The kubeconfig entry doesn't store a password. It stores a command that calls the AWS CLI to generate a short-lived token on each request, using your current AWS credentials. Three things must be true:

1. The AWS CLI is configured (`aws configure` done, or env vars set).
2. Your IAM identity has access to the cluster — automatic here, since the CloudFormation template sets `BootstrapClusterCreatorAdminPermissions`, making the stack creator a cluster admin.
3. **The same IAM identity that created the cluster is the one running kubectl.** This is the usual gotcha — a different user/role gives an "Unauthorized" error even when the config looks right.

### Useful `aws eks` inspection commands

```bash
# List clusters in the region
aws eks list-clusters --region us-east-1

# Full cluster details — status, endpoint, version, networking
aws eks describe-cluster --name hello-world-cluster --region us-east-1

# Just the status (you want ACTIVE)
aws eks describe-cluster --name hello-world-cluster --region us-east-1 \
  --query "cluster.status" --output text

# Node group health
aws eks list-nodegroups --cluster-name hello-world-cluster --region us-east-1
aws eks describe-nodegroup \
  --cluster-name hello-world-cluster \
  --nodegroup-name standard-workers \
  --region us-east-1 \
  --query "nodegroup.status" --output text
```

> **Sequencing note:** `update-kubeconfig` succeeds the moment the cluster is `ACTIVE`, but `kubectl get nodes` shows nothing until the node group finishes and nodes register. If the cluster is active but `get nodes` is empty, the node group is still coming up.

---

## Step 3 — Define the Deployment + Service

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

---

## Step 4 — Apply the Manifest

```bash
kubectl apply -f hello-world.yaml
```

> **Path matters.** `kubectl apply -f k8s/hello-world.yaml` fails with `the path does not exist` if you're not in the right directory. Use the actual path to your file — either `cd` into its folder or give the full/correct relative path.

---

## Step 5 — Verify the Three Pods

```bash
kubectl get pods -l app=hello-world      # expect 3 pods, all Running
kubectl get deployment hello-world       # READY 3/3
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

### Then hit it

```bash
curl http://<EXTERNAL-IP>     # refresh a few times to watch the pod name change
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
```

The `--all-namespaces` flag matters — if the manifest landed in a different namespace than your context default, a plain `kubectl get services` would miss it.

If `hello-world` isn't in any list, it was never applied. Apply it (using the correct path to your file):

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

## Step 7 — Tear Down (Avoid Ongoing Charges)

This cluster costs roughly **$0.10/hr** for the control plane, plus the two EC2 instances and the ELB.

> **Order matters.** Deleting in the wrong sequence leaves orphaned resources that keep billing and block the VPC from deleting. The single most important rule: **delete the Kubernetes LoadBalancer service first.** If you delete the cluster while the service still exists, the load balancer is orphaned and its network interfaces (ENIs) stay attached to your subnets, blocking the VPC from ever deleting.

### The simple path (eksctl-managed cluster)

```bash
kubectl delete -f hello-world.yaml       # removes the ELB first
eksctl delete cluster --name hello-world-cluster --region us-east-1
```

### Step 1 — Delete the Kubernetes service (releases the load balancer)

```bash
kubectl delete -f hello-world.yaml
# or by name:
kubectl delete service hello-world
kubectl delete deployment hello-world
```

Wait ~60 seconds, then **confirm the load balancer is gone** before continuing:

```bash
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].LoadBalancerName" --output text
aws elb describe-load-balancers --region us-east-1 --query "LoadBalancerDescriptions[].LoadBalancerName" --output text
```

(Two commands because a classic LB shows under `elb`, a network/application LB under `elbv2`.) Both should come back empty. Don't skip this confirmation.

### Step 2 — Delete the EKS stack (control plane + node group)

```bash
aws cloudformation delete-stack --stack-name hello-world-cluster-eks --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name hello-world-cluster-eks --region us-east-1
```

The `wait` blocks until it's fully gone. This deletes the pods, nodes, cluster, and IAM roles in one shot.

### Step 3 — Delete the VPC stack (all networking)

Only after the EKS stack is fully deleted:

```bash
aws cloudformation delete-stack --stack-name hello-world-cluster-vpc --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name hello-world-cluster-vpc --region us-east-1
```

This removes the VPC, both subnet pairs, the NAT gateway, internet gateway, route tables, and Elastic IP.

### Verify nothing's left

```bash
# Stacks should not list either of yours
aws cloudformation list-stacks --region us-east-1 \
  --query "StackSummaries[?StackStatus!='DELETE_COMPLETE'].StackName" --output table

# Cluster should be gone
aws eks list-clusters --region us-east-1

# No leftover load balancers
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].LoadBalancerName" --output text
```

### If the VPC stack gets stuck in `DELETE_FAILED`

This almost always traces back to Step 1 being skipped — an orphaned load balancer's ENIs holding the subnets.

**Manually delete any leftover load balancer:**

```bash
# find it
aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[].[LoadBalancerName,LoadBalancerArn]" --output table
# delete it
aws elbv2 delete-load-balancer --load-balancer-arn <arn-from-above> --region us-east-1
```

**Then find the VPC ID and check for stuck network interfaces:**

```bash
aws ec2 describe-network-interfaces --region us-east-1 \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
  --query "NetworkInterfaces[].[NetworkInterfaceId,Status,Description]" --output table
```

Once those ENIs are released (deleting the load balancer usually clears them within a minute or two), retry the VPC stack deletion.


# Tear everything down in the correct order so nothing is orphaned.
# Deleting the Service first releases the AWS load balancer BEFORE the VPC
# stack tries to delete subnets (an orphaned LB blocks VPC deletion and keeps billing).
#
# Usage:
#   ./teardown.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-hello-world-cluster}"
REGION="${2:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VPC_STACK="${CLUSTER_NAME}-vpc"
EKS_STACK="${CLUSTER_NAME}-eks"

echo "==> [1/4] Deleting Kubernetes Service (releases the load balancer)..."
kubectl delete -f "${SCRIPT_DIR}/03-hello-world.yaml" --ignore-not-found=true || true
echo "    Pausing 60s for the load balancer to deprovision..."
sleep 60

echo "==> [2/4] Deleting EKS stack (${EKS_STACK})..."
aws cloudformation delete-stack --region "${REGION}" --stack-name "${EKS_STACK}"
aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${EKS_STACK}"

echo "==> [3/4] Deleting VPC stack (${VPC_STACK})..."
aws cloudformation delete-stack --region "${REGION}" --stack-name "${VPC_STACK}"
aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${VPC_STACK}"

echo "==> [4/4] Done. All stacks removed."
