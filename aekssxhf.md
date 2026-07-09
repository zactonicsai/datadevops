# How to Turn EKS Pods Off and On at Certain Times — The Simple Setup Guide

This guide shows the same idea in plain language: **your apps go to sleep at night and wake up in the morning**, so you stop paying for computers nobody is using.

There are two things you can turn off:

1. **Pods** — the apps themselves (like Kafka and NiFi)
2. **Nodes** — the computers (EC2 servers) the apps run on

The trick that saves money: **scale the pods to zero, and let the cluster remove the empty computers by itself.**

Below are 4 ways to set it up: **AWS CLI**, **Terraform**, **AWS Console**, and **other tools (Helm/KEDA, eksctl)**.

---

## The Big Picture (read this first)

Think of it like a school building:

- **Pods** = the students and teachers
- **Nodes** = the classrooms
- At 7 PM, everyone goes home (pods scale to 0)
- Empty classrooms get "closed" (nodes shut down) — that's where the money savings come from
- At 7 AM, classrooms open and everyone comes back — **in the right order**: Kafka first (the messenger), then NiFi (the worker that needs the messenger)

---

## Method 1: AWS CLI (typing commands)

The AWS CLI is a program you type commands into. Good for testing or quick scripts.

### Step 1 — Connect to your cluster

```bash
aws eks update-kubeconfig --name my-cluster --region us-east-1
```

This tells your computer how to talk to your EKS cluster.

### Step 2 — Turn pods off and on by hand (to test)

```bash
# Turn NiFi OFF (first, because it depends on Kafka)
kubectl scale statefulset nifi --replicas=0 -n data-platform

# Turn Kafka OFF (second)
kubectl scale statefulset kafka --replicas=0 -n data-platform

# --- Next morning ---

# Turn Kafka ON first
kubectl scale statefulset kafka --replicas=3 -n data-platform

# Wait until Kafka is fully ready
kubectl rollout status statefulset kafka -n data-platform

# Then turn NiFi ON
kubectl scale statefulset nifi --replicas=3 -n data-platform
```

> **Remember the order:** Off = NiFi first, Kafka second. On = Kafka first, NiFi second. (Turn off the worker before the messenger; turn on the messenger before the worker.)

### Step 3 — Turn the computers (nodes) off and on

If you use **managed node groups**, this shrinks the group to zero servers:

```bash
# Night: zero servers
aws eks update-nodegroup-config \
  --cluster-name my-cluster \
  --nodegroup-name data-nodes \
  --scaling-config minSize=0,maxSize=6,desiredSize=0

# Morning: bring servers back
aws eks update-nodegroup-config \
  --cluster-name my-cluster \
  --nodegroup-name data-nodes \
  --scaling-config minSize=3,maxSize=6,desiredSize=3
```

> ⚠️ Always scale the **pods down first**, then the nodes. If you take away the classrooms while students are still inside, alarms go off (pods get stuck "Pending").

> 💡 If you use **Karpenter**, skip this step. Karpenter removes empty servers automatically once the pods are gone.

### Step 4 — Make it happen automatically with EventBridge Scheduler

EventBridge Scheduler is AWS's alarm clock. Here it shrinks the node group every weeknight at 7 PM:

```bash
aws scheduler create-schedule \
  --name eks-nodes-sleep \
  --schedule-expression "cron(0 19 ? * MON-FRI *)" \
  --schedule-expression-timezone "America/New_York" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target '{
    "Arn": "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig",
    "RoleArn": "arn:aws:iam::123456789012:role/eks-scheduler-role",
    "Input": "{\"ClusterName\":\"my-cluster\",\"NodegroupName\":\"data-nodes\",\"ScalingConfig\":{\"MinSize\":0,\"MaxSize\":6,\"DesiredSize\":0}}"
  }'
```

Make a second schedule called `eks-nodes-wake` with `cron(0 7 ? * MON-FRI *)` and `DesiredSize: 3` for the morning.

> **For the pods** (the ordered Kafka → NiFi part), the alarm clock lives *inside* the cluster instead: a Kubernetes **CronJob** or **KEDA** (see Method 4). AWS's alarm clock is best for the node/computer level.

---

## Method 2: Terraform (writing it as code)

Terraform lets you write your setup in files. You run `terraform apply` and AWS builds it. The big win: everything is saved, reviewed, and repeatable.

### 2a. Schedule the nodes with an Auto Scaling schedule

Every managed node group secretly has an **Auto Scaling Group (ASG)** behind it, and ASGs support schedules natively:

```hcl
# Find the ASG behind the node group
data "aws_eks_node_group" "data_nodes" {
  cluster_name    = "my-cluster"
  node_group_name = "data-nodes"
}

locals {
  asg_name = data.aws_eks_node_group.data_nodes.resources[0].autoscaling_groups[0].name
}

# Night: shrink to zero at 7 PM, Mon–Fri
resource "aws_autoscaling_schedule" "sleep" {
  scheduled_action_name  = "eks-sleep"
  autoscaling_group_name = local.asg_name
  recurrence             = "0 19 * * MON-FRI"
  time_zone              = "America/New_York"
  min_size               = 0
  max_size               = 6
  desired_capacity       = 0
}

# Morning: wake up at 7 AM, Mon–Fri
resource "aws_autoscaling_schedule" "wake" {
  scheduled_action_name  = "eks-wake"
  autoscaling_group_name = local.asg_name
  recurrence             = "0 7 * * MON-FRI"
  time_zone              = "America/New_York"
  min_size               = 3
  max_size               = 6
  desired_capacity       = 3
}
```

> ⚠️ Heads-up: the EKS console may show "drift" because the node group size changed outside EKS. That's normal for this pattern. If it bothers you, use the EventBridge Scheduler approach (2b) instead.

### 2b. Or schedule with EventBridge Scheduler in Terraform

```hcl
resource "aws_scheduler_schedule" "eks_sleep" {
  name                         = "eks-nodes-sleep"
  schedule_expression          = "cron(0 19 ? * MON-FRI *)"
  schedule_expression_timezone = "America/New_York"

  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig"
    role_arn = aws_iam_role.scheduler.arn
    input = jsonencode({
      ClusterName   = "my-cluster"
      NodegroupName = "data-nodes"
      ScalingConfig = { MinSize = 0, MaxSize = 6, DesiredSize = 0 }
    })
  }
}
```

(Create a matching `eks_wake` schedule for 7 AM with `DesiredSize = 3`.)

The IAM role the scheduler uses:

```hcl
resource "aws_iam_role" "scheduler" {
  name = "eks-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:UpdateNodegroupConfig", "eks:DescribeNodegroup"]
      Resource = "arn:aws:eks:us-east-1:123456789012:nodegroup/my-cluster/data-nodes/*"
    }]
  })
}
```

### 2c. Schedule the pods (with ordering) using Terraform + KEDA

Terraform can also install KEDA and create the pod schedules:

```hcl
# Install KEDA into the cluster
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
}

# Kafka wakes at 7:00, sleeps at 7:20 PM (last to sleep)
resource "kubernetes_manifest" "kafka_schedule" {
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata   = { name = "kafka-hours", namespace = "data-platform" }
    spec = {
      scaleTargetRef  = { kind = "StatefulSet", name = "kafka" }
      minReplicaCount = 0
      triggers = [{
        type = "cron"
        metadata = {
          timezone        = "America/New_York"
          start           = "0 7 * * 1-5"    # wakes FIRST
          end             = "20 19 * * 1-5"  # sleeps LAST
          desiredReplicas = "3"
        }
      }]
    }
  }
}

# NiFi wakes at 7:20 (after Kafka), sleeps at 7:00 PM (before Kafka)
resource "kubernetes_manifest" "nifi_schedule" {
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata   = { name = "nifi-hours", namespace = "data-platform" }
    spec = {
      scaleTargetRef  = { kind = "StatefulSet", name = "nifi" }
      minReplicaCount = 0
      triggers = [{
        type = "cron"
        metadata = {
          timezone        = "America/New_York"
          start           = "20 7 * * 1-5"   # wakes SECOND
          end             = "0 19 * * 1-5"   # sleeps FIRST
          desiredReplicas = "3"
        }
      }]
    }
  }
}
```

> Add the **init container** from the main guide to NiFi too. The time gap is a good guess; the init container makes it a guarantee.

---

## Method 3: AWS Console (point and click)

No coding needed. Here's how to make the "alarm clock" that shrinks your node group at night.

### Create the nightly "sleep" schedule

1. Sign in to the **AWS Console**.
2. In the search bar at the top, type **EventBridge** and open it.
3. In the left menu, click **Scheduler → Schedules**.
4. Click the orange **Create schedule** button.
5. **Name it** something clear, like `eks-nodes-sleep`.
6. Under **Schedule pattern**, pick **Recurring schedule**.
7. Choose **Cron-based schedule** and type: `cron(0 19 ? * MON-FRI *)` — that means "7:00 PM, Monday through Friday."
8. Set the **timezone** to yours (example: America/New_York). Don't skip this!
9. Under **Flexible time window**, choose **Off**. Click **Next**.
10. On the target page, choose **All APIs** → search for **EKS** → pick **UpdateNodegroupConfig**.
11. In the input box, paste (change the names to yours):
    ```json
    {
      "ClusterName": "my-cluster",
      "NodegroupName": "data-nodes",
      "ScalingConfig": { "MinSize": 0, "MaxSize": 6, "DesiredSize": 0 }
    }
    ```
12. Click **Next**. Let it **create a new role** for you (or pick one that's allowed to update node groups).
13. Click **Next**, review, then **Create schedule**. Done — that's the bedtime alarm. ✅

### Create the morning "wake" schedule

Repeat the same steps with these changes:

- Name: `eks-nodes-wake`
- Cron: `cron(0 7 ? * MON-FRI *)` (7:00 AM)
- Input: `"ScalingConfig": { "MinSize": 3, "MaxSize": 6, "DesiredSize": 3 }`

### Check that it worked

1. Search **EKS** in the console → open your cluster → **Compute** tab.
2. Look at your node group's **Desired size**. After 7 PM it should say **0**; after 7 AM it should say **3**.
3. You can also check the schedule's run history: EventBridge → Scheduler → your schedule → **Monitoring**.

### One more Console option: AWS Instance Scheduler

If you want to sleep **whole environments** (many EC2 servers, RDS databases, etc.), AWS has a ready-made solution called **Instance Scheduler on AWS**. You launch it from the AWS Solutions Library page with a few clicks, then control everything by putting a **tag** on each resource, like `Schedule = office-hours`. Tag it, and it sleeps and wakes on that schedule.

> Note: the Console approach controls the **computers**. For the pods and the Kafka-before-NiFi ordering, use KEDA or a CronJob inside the cluster (Methods 1, 2, and 4).

---

## Method 4: Other Tools

### Helm + KEDA (the easiest pod scheduler)

```bash
# Install KEDA with two commands
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace

# Then apply your ScaledObject files
kubectl apply -f kafka-schedule.yaml
kubectl apply -f nifi-schedule.yaml
```

### kube-downscaler (one line per app)

Install it once, then teams just add one annotation to their apps:

```yaml
metadata:
  annotations:
    downscaler/uptime: "Mon-Fri 07:00-19:00 America/New_York"
```

That app now sleeps outside those hours. Super simple, but no built-in ordering — pair it with init containers.

### eksctl (quick node group changes)

```bash
# Night
eksctl scale nodegroup --cluster my-cluster --name data-nodes --nodes 0 --nodes-min 0

# Morning
eksctl scale nodegroup --cluster my-cluster --name data-nodes --nodes 3 --nodes-min 3
```

Put these two lines in any scheduler you already have (Jenkins, GitHub Actions on a cron, etc.).

### GitHub Actions (if your code lives on GitHub)

```yaml
name: eks-sleep
on:
  schedule:
    - cron: "0 23 * * 1-5"   # GitHub cron is UTC! 23:00 UTC = 7 PM Eastern (in summer)
jobs:
  sleep:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/gha-eks-scheduler
          aws-region: us-east-1
      - run: |
          aws eks update-kubeconfig --name my-cluster
          kubectl scale statefulset nifi --replicas=0 -n data-platform
          kubectl wait --for=delete pod -l app=nifi -n data-platform --timeout=600s
          kubectl scale statefulset kafka --replicas=0 -n data-platform
```

> ⚠️ GitHub's clock is always **UTC** and doesn't know about daylight saving time — double-check your math twice a year.

---

## Which Method Should I Pick?

| You are... | Use |
|---|---|
| Just testing the idea today | **AWS CLI** commands by hand |
| A team that stores everything in code | **Terraform** (node schedules + KEDA) |
| Not a coder, want it working this afternoon | **AWS Console** + EventBridge Scheduler |
| Running many apps with different hours | **KEDA** via Helm, or **kube-downscaler** |
| Sleeping whole environments with tags | **Instance Scheduler on AWS** |
| Already using Karpenter | Schedule only the **pods** — Karpenter cleans up the nodes for free |

## The 3 Rules That Never Change

1. **Pods first, nodes second** when going to sleep.
2. **Kafka before NiFi** when waking up; **NiFi before Kafka** when sleeping. (Messenger up first, worker down first.)
3. **Always set your timezone** on every schedule — cron defaults to UTC and will happily wake your cluster at 3 AM.
