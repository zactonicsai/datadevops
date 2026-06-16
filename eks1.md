# Adding Compute to Your EKS Cluster 🚀

## What We’re Doing (The Big Picture)

Imagine you built an empty restaurant building (that’s your **EKS cluster**). It has a manager’s office, electricity, and a front door — but **no kitchen staff** yet. Without workers, no food gets made!

In Kubernetes (the system EKS runs), the “workers” are called **nodes**. A node is just a computer (an AWS EC2 server) that actually *runs* your apps. Your cluster’s control plane is the manager; nodes are the staff.

> **Key idea:** When you create a cluster, you get the *brain* (control plane). Now you need to add the *muscle* (compute/nodes) so your apps have somewhere to live.

### Three ways to do everything 🛠️

For each step below, you’ll see **three tools** that all do the same job. Pick whichever you like:

- 🟢 **eksctl** — the simplest, fewest words to type.
- 🔵 **AWS CLI** — the official `aws` command tool. More steps, but you see exactly what’s happening.
- 🟣 **AWS Web Console** — clicking buttons in your web browser. Great if you like seeing things on screen.

> **Why is the AWS CLI longer than eksctl?** Because `eksctl` quietly does many small jobs for you (like creating security permissions). With the plain AWS CLI you have to do those small jobs yourself. That’s normal!

-----

## Two Ways to Add Compute

|Option                |What it is                                            |Best for beginners?        |
|----------------------|------------------------------------------------------|---------------------------|
|**Managed Node Group**|AWS rents you real EC2 computers and helps manage them|✅ **Yes — start here**     |
|**Fargate**           |AWS runs your app with *no* servers for you to manage |Good later, but more limits|

We’ll focus on **Managed Node Groups** because they’re the easiest to understand and the most common.

-----

## Before You Start ✅

Make sure you have these ready:

- Your cluster is already created.
- `eksctl`, `kubectl`, and the `aws` CLI are installed.
- You know your **cluster name** and **region**.
- You are logged in to the [AWS Web Console](https://console.aws.amazon.com/) if you want to use the clicking method.

### Quick check — does your cluster exist?

🟢 **eksctl**

```bash
eksctl get cluster
```

🔵 **AWS CLI**

```bash
aws eks list-clusters --region us-east-1
```

🟣 **Web Console**

1. Go to **console.aws.amazon.com** and sign in.
1. In the top search bar, type **EKS** and click **Elastic Kubernetes Service**.
1. Make sure the **region** (top-right corner, e.g. “N. Virginia”) matches where you built your cluster.
1. Click **Clusters** on the left. You should see your cluster’s name in the list. Click it to open it.

-----

## Step 1: Confirm You Have No Nodes Yet

Let’s look at the current workers.

🟢🔵 **eksctl / AWS CLI (kubectl works for both)**

```bash
kubectl get nodes
```

If you see `No resources found`, that’s expected — we haven’t added compute yet.

🟣 **Web Console**

1. Open your cluster (from the step above).
1. Click the **Compute** tab.
1. Look at the **Node groups** section. It should be **empty** right now. We’re about to fill it.

-----

## Step 2: Create a Managed Node Group

This is the main event. We’ll add a group of EC2 computers to the cluster.

### 🟢 Option A — eksctl (easiest)

```bash
eksctl create nodegroup \
  --cluster my-cluster \
  --region us-east-1 \
  --name my-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

**What each line means (in plain English):**

- `--cluster my-cluster` → the name of *your* cluster. Change this!
- `--region us-east-1` → where in the world your servers live. Change to your region.
- `--name my-nodes` → a nickname for this group of computers.
- `--node-type t3.medium` → the *size* of each computer. `t3.medium` is a small, cheap starter size.
- `--nodes 2` → start with 2 computers.
- `--nodes-min 1` → never go below 1 computer.
- `--nodes-max 3` → never go above 3 computers (this protects your wallet 💰).
- `--managed` → let AWS handle the boring maintenance for you.

> `eksctl` automatically creates the IAM role (the permission badge) for you. That’s why this is the easy option!

-----

### 🔵 Option B — AWS CLI (more steps)

The plain AWS CLI needs **two parts**. First we make a “permission badge” (called an **IAM role**) so the nodes are allowed to join. Then we create the node group.

**Part 1 — Create the node IAM role (only do this once).**

Nodes need permission to talk to the cluster. We create a role and attach 3 standard policies.

```bash
# Create the role with a trust policy (lets EC2 use this role)
aws iam create-role \
  --role-name eksNodeRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }'

# Attach the 3 permissions the nodes need
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

> Think of these 3 policies as 3 keys: one to join the cluster, one to handle networking, and one to download app images.

**Part 2 — Find your subnets, then create the node group.**

Subnets are the “rooms” in your network where servers can live. We ask EKS which subnets your cluster already uses.

```bash
# Get your account ID (needed for the role name below)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get the subnet IDs your cluster uses
aws eks describe-cluster \
  --name my-cluster \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.subnetIds" \
  --output text
```

Copy the subnet IDs that printed out (they look like `subnet-0abc123`). Now create the node group, pasting those subnet IDs in:

```bash
aws eks create-nodegroup \
  --cluster-name my-cluster \
  --region us-east-1 \
  --nodegroup-name my-nodes \
  --node-role arn:aws:iam::${ACCOUNT_ID}:role/eksNodeRole \
  --subnets subnet-0abc123 subnet-0def456 \
  --instance-types t3.medium \
  --scaling-config minSize=1,maxSize=3,desiredSize=2
```

**What the new lines mean:**

- `--node-role` → the permission badge you made in Part 1.
- `--subnets` → the network rooms (paste your real subnet IDs here).
- `--instance-types t3.medium` → the size of each computer.
- `--scaling-config minSize=1,maxSize=3,desiredSize=2` → same as min/max/start counts from eksctl.

-----

### 🟣 Option C — Web Console (clicking)

1. Open your cluster in the EKS console.
1. Click the **Compute** tab.
1. Click the **Add node group** button.
1. **Configure node group** page:
- **Name:** type `my-nodes`.
- **Node IAM role:** pick a role from the dropdown. *If the list is empty,* you must create one first (see the box below), then come back and pick it.
- Click **Next**.
1. **Set compute and scaling configuration** page:
- **AMI type:** leave the default (Amazon Linux).
- **Instance types:** choose `t3.medium`.
- **Disk size:** leave the default (20 GiB is fine).
- **Desired size:** `2`, **Minimum size:** `1`, **Maximum size:** `3`.
- Click **Next**.
1. **Specify networking** page:
- The **subnets** should already be filled in. Leave them as-is.
- Click **Next**.
1. **Review and create** page:
- Read the summary, then click **Create**.

> **No IAM role in the dropdown?** Open a new tab → search **IAM** → **Roles** → **Create role** → choose **AWS service** → **EC2** → click **Next** → attach these 3 policies: `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly` → name it `eksNodeRole` → **Create role**. Then return to the EKS tab and pick it.

> **Heads up (all methods):** Creating nodes takes a few minutes (usually 3–5). AWS is building real machines behind the scenes, so be patient. Grab a snack! 🍿

-----

## Step 3: Watch It Work

🟢 **eksctl** — prints progress messages and finishes with “created 1 nodegroup”.

🔵 **AWS CLI** — check the status with this command (run it a few times until it says `ACTIVE`):

```bash
aws eks describe-nodegroup \
  --cluster-name my-cluster \
  --nodegroup-name my-nodes \
  --region us-east-1 \
  --query "nodegroup.status" \
  --output text
```

It goes `CREATING` → `ACTIVE`. `ACTIVE` means it’s done!

🟣 **Web Console** — on the **Compute** tab, your node group shows a status. It changes from **Creating** to **Active**. You can click the refresh icon to update it.

-----

## Step 4: Check That Your Nodes Joined

🟢🔵 **eksctl / AWS CLI**

```bash
kubectl get nodes
```

Now you should see something like:

```
NAME                          STATUS   ROLES    AGE   VERSION
ip-192-168-1-23.ec2.internal  Ready    <none>   2m    v1.30.0
ip-192-168-5-87.ec2.internal  Ready    <none>   2m    v1.30.0
```

🎉 **The magic word is `Ready`.** It means the computer is healthy and waiting to run your apps.

> If a node says `NotReady`, wait another minute. They sometimes need a moment to fully wake up.

🟣 **Web Console**

1. On the **Compute** tab, click your node group name (`my-nodes`).
1. Scroll to the **Nodes** section.
1. You should see your computers listed with a **Ready** status. ✅

-----

## Step 5: Test It With a Real App (Optional but Fun)

Let’s prove the nodes actually work by running a tiny web app. *(This uses `kubectl` no matter how you added the nodes.)*

```bash
kubectl create deployment hello-web --image=nginx
```

This tells Kubernetes: “Please run a copy of the `nginx` web server.” Kubernetes will place it on one of your new nodes.

Check that it’s running:

```bash
kubectl get pods
```

A **pod** is the smallest unit that runs your app. When the pod shows `Running`, your compute is officially doing its job. ✅

Clean up the test app afterward:

```bash
kubectl delete deployment hello-web
```

> **See it in the console too:** On your cluster’s **Resources** tab → **Workloads** → **Deployments**, you’ll find `hello-web` listed while it’s running.

-----

## Quick Reference: The Whole Flow

🟢 **eksctl**

```bash
eksctl get cluster
kubectl get nodes
eksctl create nodegroup \
  --cluster my-cluster --region us-east-1 \
  --name my-nodes --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 3 --managed
kubectl get nodes
```

🔵 **AWS CLI**

```bash
aws eks list-clusters --region us-east-1
# (one-time) create eksNodeRole + attach 3 policies
aws eks describe-cluster --name my-cluster --region us-east-1 \
  --query "cluster.resourcesVpcConfig.subnetIds" --output text
aws eks create-nodegroup \
  --cluster-name my-cluster --region us-east-1 \
  --nodegroup-name my-nodes \
  --node-role arn:aws:iam::<ACCOUNT_ID>:role/eksNodeRole \
  --subnets subnet-0abc123 subnet-0def456 \
  --instance-types t3.medium \
  --scaling-config minSize=1,maxSize=3,desiredSize=2
aws eks describe-nodegroup --cluster-name my-cluster \
  --nodegroup-name my-nodes --region us-east-1 \
  --query "nodegroup.status" --output text
kubectl get nodes
```

🟣 **Web Console**

```
EKS → Clusters → (your cluster) → Compute tab → Add node group
→ Name + IAM role → Next
→ t3.medium + sizes 2/1/3 → Next
→ subnets (auto) → Next → Create
→ wait for Active → check Nodes are Ready
```

-----

## Common Beginner Mistakes 🐛

- **Wrong cluster name or region.** The command will fail or do nothing. Double-check spelling — computers are picky!
- **Forgetting `--managed`** (eksctl). Without it, you get a “self-managed” group, which is harder. Keep the flag.
- **No IAM role** (AWS CLI / console). The plain methods need you to make the `eksNodeRole` first. eksctl does this for you.
- **Pasting the wrong subnets** (AWS CLI). Use the subnet IDs that `describe-cluster` gives you, not random ones.
- **Picking a huge node type.** Big servers cost more money. Start small with `t3.medium`.
- **Impatience.** If nodes don’t appear instantly, wait a couple minutes before worrying.

-----

## How to Remove Compute (Save Money!) 💸

Real servers cost money every hour they run. When you’re done practicing, delete the node group.

🟢 **eksctl**

```bash
eksctl delete nodegroup \
  --cluster my-cluster \
  --name my-nodes \
  --region us-east-1
```

🔵 **AWS CLI**

```bash
aws eks delete-nodegroup \
  --cluster-name my-cluster \
  --nodegroup-name my-nodes \
  --region us-east-1
```

🟣 **Web Console**

1. Open your cluster → **Compute** tab.
1. Select your node group (`my-nodes`).
1. Click **Delete**, type the name to confirm, and click **Delete** again.

> ⚠️ This shuts down your worker computers. Your cluster’s “brain” stays, but apps can’t run until you add nodes again. Always delete things you’re not using so you don’t get a surprise bill.

-----

## What You Learned 🧠

- A **cluster** is the brain; **nodes** are the muscle that runs apps.
- You can add muscle **three ways**: eksctl (easy), AWS CLI (more steps), or the web console (clicking).
- The plain AWS CLI and console need an **IAM role** (`eksNodeRole`) first — eksctl makes it automatically.
- `kubectl get nodes` shows your workers; **`Ready`** means success. In the console, look for **Active** node groups and **Ready** nodes.
- Always clean up to avoid paying for idle servers.

You now know how to give your EKS cluster the power to actually run things — using whichever tool you prefer. Nice work! 🎓