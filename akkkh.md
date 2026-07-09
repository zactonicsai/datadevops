# The Complete Beginner's Guide to EKS: A Web Server That Sleeps at Night

**What you'll build:** a real Kubernetes cluster on AWS (EKS) running a tiny "Hello" web server. It works during business hours (7 AM – 7 PM, Monday–Friday) and **automatically goes to sleep at night and on weekends** so you don't pay for computers nobody is using.

You'll learn to do every step **three ways**: typing commands (CLI), clicking in the AWS website (Console), and writing it as code (Terraform). Pick one way, or read all three to see how they compare.

**No experience needed.** Every word is explained, every step is shown.

---

## Table of Contents

1. [The Big Picture — what are we building?](#part-0)
2. [Words to Know (mini dictionary)](#dictionary)
3. [Get Your Tools Ready](#part-1)
4. [Part A — Create the Cluster and Node Group](#part-a)
5. [Part B — Deploy the Hello Web Server](#part-b)
6. [Part C — Make the Pods Sleep at Night](#part-c)
7. [Part D — Make the Computers Sleep at Night](#part-d)
8. [Part E — Check That It All Works](#part-e)
9. [Best Practices Checklist](#best-practices)
10. [Clean Up (so you stop paying)](#cleanup)
11. [What to Learn Next](#next)

---

<a name="part-0"></a>
## 1. The Big Picture — What Are We Building?

Imagine a school:

| School thing | Kubernetes thing | In our project |
|---|---|---|
| The whole school | **Cluster** | Our EKS cluster, named `hello-cluster` |
| Classrooms | **Nodes** (EC2 computers) | 2 small computers in a **node group** |
| Students | **Pods** (running apps) | 2 copies of our Hello web server |
| The front office | **Control plane** | AWS runs this for us (that's what EKS means!) |
| The principal's rulebook | **Deployment** | "Always keep 2 Hello pods running" |
| The school's front door | **Service / Load Balancer** | The web address people visit |

**The daily schedule we want:**

```
7:00 AM  Mon–Fri   →  Computers turn on, pods start, website works ✅
7:00 PM  Mon–Fri   →  Pods stop, computers turn off, website sleeps 😴
Weekends            →  Everything stays asleep 😴😴
```

**Why?** Money. A cluster that runs 24/7 but is only used 12 hours a day, 5 days a week, wastes about **65% of its cost**. Sleeping at night fixes that.

**The golden rule of sleeping (memorize this):**

> **Going to sleep: pods first, computers second.**
> **Waking up: computers first, pods second.**
> (Students leave before you lock the classrooms. Unlock the classrooms before students arrive.)

---

<a name="dictionary"></a>
## 2. Words to Know (Mini Dictionary)

- **EKS** — Amazon's managed Kubernetes. AWS runs the "brain" of the cluster for you.
- **Cluster** — the whole system: brain + computers + apps.
- **Node** — one computer (an EC2 server) that runs your apps.
- **Node group** — a set of matching nodes that AWS manages together as a team.
- **Pod** — the smallest running unit; usually one app in a box (container).
- **Deployment** — a rule that says "keep N copies of this pod running." If a pod dies, the Deployment makes a new one.
- **Replicas** — the number of copies. `replicas: 2` = 2 pods. `replicas: 0` = **asleep**.
- **Service** — a stable "front door" address for your pods.
- **kubectl** — (say "cube-control") the command you type to talk to Kubernetes.
- **eksctl** — a helper command that builds EKS clusters easily.
- **Terraform** — a tool where you *write* your setup as code files, then run one command to build it all.
- **CronJob** — an alarm clock inside Kubernetes that runs a task on a schedule.
- **EventBridge Scheduler** — AWS's alarm clock, outside the cluster.
- **Cron expression** — alarm-clock language. `0 19 * * 1-5` means "7:00 PM, Monday through Friday." (minute, hour, day-of-month, month, day-of-week)

---

<a name="part-1"></a>
## 3. Get Your Tools Ready

You need an **AWS account** (a grown-up credit card is required — but this guide's cluster costs only a few dollars if you clean up at the end, and the sleeping trick keeps it cheap).

### Install these 4 tools

**1. AWS CLI** — talks to AWS

```bash
# macOS
brew install awscli

# Windows: download the installer from aws.amazon.com/cli
# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

**2. kubectl** — talks to Kubernetes

```bash
# macOS
brew install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**3. eksctl** — builds EKS clusters (for the CLI path)

```bash
# macOS
brew install eksctl

# Linux
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz && sudo mv eksctl /usr/local/bin
```

**4. Terraform** — only if you choose the Terraform path

```bash
# macOS
brew install terraform
# Others: download from developer.hashicorp.com/terraform
```

### Connect the AWS CLI to your account

```bash
aws configure
# It asks 4 questions:
# AWS Access Key ID:      (from AWS Console → your name → Security credentials)
# AWS Secret Access Key:  (shown once when you create the key — save it!)
# Default region name:    us-east-1     (or your closest region)
# Default output format:  json
```

Test it:

```bash
aws sts get-caller-identity
# If you see your account number, you're connected! ✅
```

---

<a name="part-a"></a>
## 4. Part A — Create the Cluster and Node Group

Pick **one** of the three ways below. They all end in the same place: a cluster called `hello-cluster` with a node group of 2 small computers.

> ⏱️ Creating a cluster takes **10–15 minutes** no matter which way you choose. AWS is building a lot behind the scenes. Get a snack.

### Way 1: CLI (eksctl) — the fastest

One command builds everything (cluster, network, node group):

```bash
eksctl create cluster \
  --name hello-cluster \
  --region us-east-1 \
  --nodegroup-name work-nodes \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 0 \
  --nodes-max 3 \
  --managed
```

What each line means:

- `--name hello-cluster` — the cluster's name
- `--node-type t3.small` — small, cheap computers (about 2 cents/hour each)
- `--nodes 2` — start with 2 computers
- `--nodes-min 0` — **important!** allows the group to shrink all the way to ZERO at night
- `--nodes-max 3` — never more than 3
- `--managed` — AWS manages the node group for us

When it finishes, eksctl automatically connects `kubectl` to your new cluster. Test it:

```bash
kubectl get nodes
# You should see 2 nodes with STATUS "Ready" ✅
```

### Way 2: AWS Console — point and click

**Create the cluster:**

1. Sign in to the **AWS Console**. In the top search bar, type **EKS** and open **Elastic Kubernetes Service**.
2. Click **Create cluster** (choose **Custom configuration** if asked, and turn **off** "EKS Auto Mode" for this guide — we want to manage our own node group).
3. **Name:** `hello-cluster`. Leave the Kubernetes version as the default.
4. **Cluster IAM role:** click **Create recommended role** if you don't have one (it opens IAM with everything pre-filled — click through and create it), come back, hit refresh, and select it.
5. Click **Next** through Networking (defaults are fine for learning: your default VPC and subnets), Observability, and Add-ons pages.
6. Click **Create**. Wait ~10 minutes until the status says **Active**. ☕

**Create the node group:**

1. Open your cluster → **Compute** tab → **Add node group**.
2. **Name:** `work-nodes`.
3. **Node IAM role:** click **Create recommended role** if needed (same trick as before), then select it.
4. Click **Next**. Set:
   - **Instance type:** `t3.small`
   - **Desired size:** `2`
   - **Minimum size:** `0`  ← the magic number that lets it sleep!
   - **Maximum size:** `3`
5. Click **Next** through subnets (defaults fine), then **Create**. Wait ~3 minutes until **Active**.

**Connect kubectl** (one command in your terminal):

```bash
aws eks update-kubeconfig --name hello-cluster --region us-east-1
kubectl get nodes   # 2 Ready nodes ✅
```

### Way 3: Terraform — write it as code

Make a folder, create a file called `main.tf`, and paste this:

```hcl
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- Network (a simple VPC for the cluster) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "hello-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true   # cheaper for learning
}

# --- The EKS cluster + node group ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "hello-cluster"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    work-nodes = {
      instance_types = ["t3.small"]
      desired_size   = 2
      min_size       = 0        # ← lets it sleep!
      max_size       = 3
    }
  }

  tags = {
    team        = "learning"
    environment = "dev"
  }
}
```

Then run:

```bash
terraform init      # downloads what Terraform needs (once)
terraform plan      # shows what it WILL build — read it!
terraform apply     # type "yes" — builds everything (~15 min)

# Connect kubectl
aws eks update-kubeconfig --name hello-cluster --region us-east-1
kubectl get nodes   # ✅
```

> 💡 Why Terraform is cool: your whole cluster is now described in one file. Delete everything with `terraform destroy`, rebuild it identically with `terraform apply`. Teams review changes to the file like they review code.

---

<a name="part-b"></a>
## 5. Part B — Deploy the Hello Web Server

Now let's put an app on our cluster: a tiny web server that just says hello.

### Step 1 — Write the app files

Create a file called `hello-app.yaml`:

```yaml
# The Deployment: "keep 2 copies of the hello server running"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-web
  labels:
    app: hello-web
    team: learning                          # who owns this (for tracking!)
  annotations:
    scheduling.acme.io/schedule: "business-hours"   # opts into our sleep schedule
    scheduling.acme.io/restore-replicas: "2"        # how many to wake up
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-web
  template:
    metadata:
      labels:
        app: hello-web
    spec:
      containers:
        - name: hello
          image: hashicorp/http-echo:1.0
          args:
            - "-text=Hello from EKS! I sleep at night to save money. 😴💰"
            - "-listen=:8080"
          ports:
            - containerPort: 8080
          resources:              # tell K8s how much the pod needs
            requests:
              cpu: 50m            # 5% of one CPU
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
          readinessProbe:         # "raise your hand when you're ready"
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
---
# The Service: the front door with a public address
apiVersion: v1
kind: Service
metadata:
  name: hello-web
spec:
  type: LoadBalancer      # AWS creates a public load balancer for us
  selector:
    app: hello-web
  ports:
    - port: 80            # the world visits port 80...
      targetPort: 8080    # ...and it goes to our pods' port 8080
```

### Step 2 — Apply it

```bash
kubectl apply -f hello-app.yaml
```

### Step 3 — Visit your website!

```bash
# Watch until both pods say "Running"
kubectl get pods -l app=hello-web

# Get your public web address (takes ~2 min for AWS to create it)
kubectl get service hello-web
# Look at the EXTERNAL-IP column — something like:
# a1b2c3...us-east-1.elb.amazonaws.com

# Test it
curl http://<that-address>
# → Hello from EKS! I sleep at night to save money. 😴💰
```

🎉 **You have a website running on Kubernetes.** Now let's teach it to sleep.

---

<a name="part-c"></a>
## 6. Part C — Make the Pods Sleep at Night

We'll use a **CronJob** — an alarm clock inside the cluster. At 7 PM it sets replicas to 0 (sleep). At 7 AM it sets replicas back to 2 (wake).

> Simple app = simple ordering. Our hello server has no dependencies, so we just scale it. (If you had Kafka + NiFi, the wake-up script would start Kafka first and NiFi second — see the companion data-platform guides.)

### Step 1 — Give the alarm clock permission

The alarm clock needs a badge (ServiceAccount) with permission to change replica counts — and **only** that. Create `scaler-rbac.yaml`:

```yaml
# A "badge" for our alarm clock
apiVersion: v1
kind: ServiceAccount
metadata:
  name: scheduler-sa
  namespace: default
---
# What the badge is allowed to do (as little as possible!)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-hello
  namespace: default
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale"]
    verbs: ["get", "list", "update", "patch"]
---
# Attach the permission to the badge
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: scale-hello-binding
  namespace: default
subjects:
  - kind: ServiceAccount
    name: scheduler-sa
    namespace: default
roleRef:
  kind: Role
  name: scale-hello
  apiGroup: rbac.authorization.k8s.io
```

### Step 2 — Create the two alarm clocks

Create `sleep-wake-cronjobs.yaml`:

```yaml
# 😴 BEDTIME: 7:00 PM Mon–Fri → replicas to 0
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello-sleep
  namespace: default
spec:
  schedule: "0 19 * * 1-5"
  timeZone: "America/New_York"      # ← ALWAYS set your timezone!
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scheduler-sa
          restartPolicy: Never
          containers:
            - name: scaler
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  echo "Bedtime! Scaling hello-web to 0..."
                  kubectl scale deployment/hello-web --replicas=0 -n default
                  echo "Good night. 😴"
---
# ☀️ WAKE UP: 7:00 AM Mon–Fri → replicas back to 2
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hello-wake
  namespace: default
spec:
  schedule: "0 7 * * 1-5"
  timeZone: "America/New_York"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scheduler-sa
          restartPolicy: Never
          containers:
            - name: scaler
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  echo "Good morning! Scaling hello-web to 2..."
                  kubectl scale deployment/hello-web --replicas=2 -n default
                  kubectl rollout status deployment/hello-web -n default --timeout=5m
                  echo "Website is awake. ☀️"
```

### Step 3 — Apply and test without waiting until 7 PM

```bash
kubectl apply -f scaler-rbac.yaml
kubectl apply -f sleep-wake-cronjobs.yaml

# Force the bedtime alarm to ring RIGHT NOW:
kubectl create job test-sleep --from=cronjob/hello-sleep

# Watch the pods disappear
kubectl get pods -l app=hello-web
# No resources found  ← they're asleep! 😴

# Now ring the morning alarm:
kubectl create job test-wake --from=cronjob/hello-wake

# Watch them come back
kubectl get pods -l app=hello-web -w
# 2 pods Running ← awake! ☀️

# Clean up the test jobs
kubectl delete job test-sleep test-wake
```

> 🎓 **Fancier option for later:** instead of CronJobs, install **KEDA** (2 Helm commands) and use a `ScaledObject` with a cron trigger, or install **kube-downscaler** and just annotate apps with `downscaler/uptime: "Mon-Fri 07:00-19:00 America/New_York"`. Same result, less script to maintain. The CronJob way is best for learning because you can see exactly what happens.

---

<a name="part-d"></a>
## 7. Part D — Make the Computers Sleep at Night

The pods are asleep, but the 2 computers are still on and still costing money — empty classrooms with the lights on. Let's schedule the node group too.

**The timing rule:** computers sleep 15 minutes **after** pods (7:15 PM) and wake 15 minutes **before** pods (6:45 AM). Pods first down, computers first up.

```
6:45 AM  computers on   ☀️🏫
7:00 AM  pods on        ☀️🧑‍🎓
7:00 PM  pods off       😴🧑‍🎓
7:15 PM  computers off  😴🏫
```

Pick your way:

### Way 1: CLI — EventBridge Scheduler

First, create a small IAM role that AWS's alarm clock can use. Save this as `trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "scheduler.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

```bash
# Create the role
aws iam create-role --role-name eks-night-scheduler \
  --assume-role-policy-document file://trust.json

# Let it resize node groups (and nothing else)
aws iam put-role-policy --role-name eks-night-scheduler \
  --policy-name resize-nodegroup \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["eks:UpdateNodegroupConfig", "eks:DescribeNodegroup"],
      "Resource": "*"
    }]
  }'

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 😴 BEDTIME for computers: 7:15 PM Mon–Fri
aws scheduler create-schedule \
  --name eks-nodes-sleep \
  --schedule-expression "cron(15 19 ? * MON-FRI *)" \
  --schedule-expression-timezone "America/New_York" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig\",
    \"RoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/eks-night-scheduler\",
    \"Input\": \"{\\\"ClusterName\\\":\\\"hello-cluster\\\",\\\"NodegroupName\\\":\\\"work-nodes\\\",\\\"ScalingConfig\\\":{\\\"MinSize\\\":0,\\\"MaxSize\\\":3,\\\"DesiredSize\\\":0}}\"
  }"

# ☀️ WAKE UP for computers: 6:45 AM Mon–Fri
aws scheduler create-schedule \
  --name eks-nodes-wake \
  --schedule-expression "cron(45 6 ? * MON-FRI *)" \
  --schedule-expression-timezone "America/New_York" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig\",
    \"RoleArn\": \"arn:aws:iam::${ACCOUNT_ID}:role/eks-night-scheduler\",
    \"Input\": \"{\\\"ClusterName\\\":\\\"hello-cluster\\\",\\\"NodegroupName\\\":\\\"work-nodes\\\",\\\"ScalingConfig\\\":{\\\"MinSize\\\":2,\\\"MaxSize\\\":3,\\\"DesiredSize\\\":2}}\"
  }"
```

Test right now without waiting for 7:15 PM:

```bash
# Manually put the computers to sleep
aws eks update-nodegroup-config --cluster-name hello-cluster \
  --nodegroup-name work-nodes \
  --scaling-config minSize=0,maxSize=3,desiredSize=0

kubectl get nodes    # after ~2 min: "No resources found" 😴

# Wake them back up
aws eks update-nodegroup-config --cluster-name hello-cluster \
  --nodegroup-name work-nodes \
  --scaling-config minSize=2,maxSize=3,desiredSize=2

kubectl get nodes    # after ~3 min: 2 Ready nodes ☀️
```

### Way 2: AWS Console — point and click

1. Search **EventBridge** in the Console → left menu → **Scheduler → Schedules** → **Create schedule**.
2. **Name:** `eks-nodes-sleep`.
3. **Schedule pattern:** Recurring → Cron-based → type `cron(15 19 ? * MON-FRI *)`.
4. **Timezone:** pick yours (e.g., America/New_York). Never skip this!
5. **Flexible time window:** Off → **Next**.
6. Target: choose **All APIs** → search **EKS** → pick **UpdateNodegroupConfig**.
7. Paste into the input box:
   ```json
   {
     "ClusterName": "hello-cluster",
     "NodegroupName": "work-nodes",
     "ScalingConfig": { "MinSize": 0, "MaxSize": 3, "DesiredSize": 0 }
   }
   ```
8. **Next** → let it **create a new execution role** → **Next** → **Create schedule**. ✅
9. Repeat everything for the morning: name `eks-nodes-wake`, cron `cron(45 6 ? * MON-FRI *)`, and input `"ScalingConfig": { "MinSize": 2, "MaxSize": 3, "DesiredSize": 2 }`.

**Check it worked:** EKS Console → hello-cluster → Compute tab → your node group's **Desired size** shows 0 after 7:15 PM, 2 after 6:45 AM.

### Way 3: Terraform

Add this to your `main.tf` (works with the module from Part A):

```hcl
# --- IAM role for the AWS alarm clock ---
resource "aws_iam_role" "night_scheduler" {
  name = "eks-night-scheduler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "night_scheduler" {
  role = aws_iam_role.night_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:UpdateNodegroupConfig", "eks:DescribeNodegroup"]
      Resource = "*"
    }]
  })
}

# --- 😴 Computers sleep at 7:15 PM Mon–Fri ---
resource "aws_scheduler_schedule" "nodes_sleep" {
  name                         = "eks-nodes-sleep"
  schedule_expression          = "cron(15 19 ? * MON-FRI *)"
  schedule_expression_timezone = "America/New_York"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig"
    role_arn = aws_iam_role.night_scheduler.arn
    input = jsonencode({
      ClusterName   = "hello-cluster"
      NodegroupName = "work-nodes"
      ScalingConfig = { MinSize = 0, MaxSize = 3, DesiredSize = 0 }
    })
  }
}

# --- ☀️ Computers wake at 6:45 AM Mon–Fri ---
resource "aws_scheduler_schedule" "nodes_wake" {
  name                         = "eks-nodes-wake"
  schedule_expression          = "cron(45 6 ? * MON-FRI *)"
  schedule_expression_timezone = "America/New_York"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig"
    role_arn = aws_iam_role.night_scheduler.arn
    input = jsonencode({
      ClusterName   = "hello-cluster"
      NodegroupName = "work-nodes"
      ScalingConfig = { MinSize = 2, MaxSize = 3, DesiredSize = 2 }
    })
  }
}
```

Run `terraform apply` again — it only adds the new pieces.

> 🧠 **Note about names:** the node group name in these schedules must match exactly. eksctl and the Console use the name you typed (`work-nodes`). The Terraform EKS module adds a random suffix — run `aws eks list-nodegroups --cluster-name hello-cluster` to see the real name and use that.

> 🚀 **Grown-up shortcut for later:** big teams often skip node schedules entirely by using **Karpenter** — it deletes empty nodes automatically the moment pods scale to zero, and launches new ones in ~60 seconds when pods come back. Then you only ever schedule pods. See the Karpenter deep-dive guide.

---

<a name="part-e"></a>
## 8. Part E — Check That It All Works

### The full test (do this once, manually)

Run the bedtime routine in the correct order and watch:

```bash
# 1. Pods to sleep (students leave)
kubectl create job manual-sleep --from=cronjob/hello-sleep
kubectl get pods -l app=hello-web          # → No resources found 😴

# 2. Computers to sleep (lock the classrooms)
aws eks update-nodegroup-config --cluster-name hello-cluster \
  --nodegroup-name work-nodes --scaling-config minSize=0,maxSize=3,desiredSize=0
kubectl get nodes                           # after ~2 min → No resources found 😴

# --- Now the morning routine ---

# 3. Computers wake (unlock classrooms FIRST)
aws eks update-nodegroup-config --cluster-name hello-cluster \
  --nodegroup-name work-nodes --scaling-config minSize=2,maxSize=3,desiredSize=2
kubectl get nodes -w                        # wait for 2 "Ready" ☀️

# 4. Pods wake (students arrive)
kubectl create job manual-wake --from=cronjob/hello-wake
kubectl get pods -l app=hello-web           # 2 Running ☀️

# 5. Website works again?
curl http://<your-load-balancer-address>    # Hello from EKS! ✅

kubectl delete job manual-sleep manual-wake
```

### Things to watch over the first week

```bash
# Did the alarm clocks ring? (see recent job runs)
kubectl get jobs

# Any errors in an alarm's run?
kubectl logs job/<job-name>

# AWS side: EventBridge → Scheduler → your schedule → Monitoring tab
# Cost side: AWS Console → Cost Explorer → filter by service "EC2" → watch the daily bill drop!
```

### What happens if someone visits the website at night?

The load balancer address still exists, but there are no pods behind it — visitors get an error. That's expected for a dev/test setup. For anything users depend on, keep it awake or add a friendly "we're closed" static page.

---

<a name="best-practices"></a>
## 9. Best Practices Checklist

Everything the pros do, in plain language:

**Ordering**
- [ ] **Sleep: pods → computers. Wake: computers → pods.** Always.
- [ ] Apps with dependencies wake in dependency order (database/Kafka first, apps second) and sleep in reverse. Use **init containers** that wait for the dependency to be truly ready — don't just guess with timing.

**Time**
- [ ] **Set the timezone on every schedule** (`timeZone:` in CronJobs, `--schedule-expression-timezone` in EventBridge). Plain cron is UTC and will wake your cluster at weird hours — and daylight saving time will betray you twice a year.
- [ ] Leave a **15-minute gap** between computer and pod alarms so there's room for slow starts.

**Tracking (labels & tags)**
- [ ] Put `team`, `environment`, and a schedule opt-in label/annotation on every app — so automation can find them and bills can be split by team.
- [ ] Tag AWS resources (node groups) with the same `team` / `cost-center` keys; turn on **split cost allocation for EKS** to see per-team costs.
- [ ] Store the wake-up replica count in an annotation (like our `restore-replicas: "2"`) instead of hardcoding numbers in scripts.
- [ ] Give teams an escape hatch: an `exclude: "true"` annotation with a required reason, reviewed monthly.

**Safety**
- [ ] The alarm-clock badge (ServiceAccount/IAM role) gets the **smallest possible permission** — only "resize these things," nothing more.
- [ ] Every app has a **readinessProbe** so "awake" means "actually ready," not just "turned on."
- [ ] `minSize=0` on the node group, or the sleep command will be rejected.
- [ ] **Silence your alerts during the sleep window** — otherwise "everything is down!" pages ring every night and people learn to ignore them (dangerous).
- [ ] Add a **morning check**: a tiny script (or synthetic monitor) that curls the website at 7:05 AM and yells if it's broken — so problems are found before humans arrive.

**Money**
- [ ] `desiredSize=0` at night is the win: you stop paying for EC2. (Disks/EBS still cost pennies overnight — that's normal; the computers are the big cost.)
- [ ] Check Cost Explorer after the first week — seeing the savings graph is the best part.

**Growing up later**
- [ ] Many apps? Install **kube-downscaler** (teams opt in with one annotation) or **KEDA** (per-app cron ScaledObjects).
- [ ] Want nodes handled automatically? **Karpenter** deletes empty nodes and launches new ones on demand — then you only schedule pods, ever.
- [ ] Stateful data services (Kafka, NiFi, OpenSearch)? Read the companion data-platform guide — they need ordered wake-ups, drain-before-sleep, and disruption protection.

---

<a name="cleanup"></a>
## 10. Clean Up (So You Stop Paying)

When you're done learning, delete everything:

```bash
# Delete the app (this also deletes the AWS load balancer — important!)
kubectl delete -f hello-app.yaml
kubectl delete -f sleep-wake-cronjobs.yaml
kubectl delete -f scaler-rbac.yaml

# Delete the AWS alarm clocks
aws scheduler delete-schedule --name eks-nodes-sleep
aws scheduler delete-schedule --name eks-nodes-wake
aws iam delete-role-policy --role-name eks-night-scheduler --policy-name resize-nodegroup
aws iam delete-role --role-name eks-night-scheduler

# Delete the cluster
# CLI way:
eksctl delete cluster --name hello-cluster --region us-east-1

# Terraform way:
terraform destroy    # type "yes"

# Console way: EKS → hello-cluster → Compute → delete node group first,
# wait, then Delete cluster.
```

> ⚠️ Delete the **Service** (load balancer) *before* the cluster, or the load balancer can get orphaned and keep billing you. The commands above do it in the right order.

---

<a name="next"></a>
## 11. What to Learn Next

You just did real cloud engineering: cluster, node group, deployment, service, RBAC, scheduling, IAM, and cost optimization — three different ways. Next steps, in order:

1. **kube-downscaler or KEDA** — replace your CronJobs with a one-line annotation or a ScaledObject.
2. **Karpenter** — nodes that manage themselves (see the deep-dive guide).
3. **Dependencies** — add a second app that must start *after* the first, using an init container (see the data-platform guide's Kafka → NiFi pattern).
4. **GitOps (Argo CD or Flux)** — your YAML files live in Git, and the cluster keeps itself matching them.

**The one-sentence summary of everything:**

> *Scale the pods to zero on a schedule, scale the computers to zero right after, wake the computers first and the pods second in the morning — always with a timezone, always in that order, always with the smallest permissions possible.*
