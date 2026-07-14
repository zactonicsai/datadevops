# Tutorial: Save Money on AWS EKS by Turning Off Nodes During Off-Hours

*A beginner-friendly, step-by-step guide (written so anyone can follow it)*

---

## 1. Background: Why This Saves Money

Imagine you rent a fleet of taxis (your **EC2 instances / EKS nodes**) that drive around 24 hours a day, but your passengers (your **applications**) only ride between 7 AM and 7 PM on weekdays. You are paying for taxis to drive around empty all night and all weekend!

That is exactly what happens with many **development, test, QA, and staging** EKS clusters:

- You pay for EC2 nodes **every hour they run**, whether they are busy or idle.
- Nights + weekends = roughly **65–70% of the hours in a week**. If a dev cluster only needs to run during business hours, you can cut its compute bill by well over half.
- **Important:** You cannot "pause" the EKS control plane itself. AWS runs it for you and charges a small flat fee (about $0.10/hour) per cluster no matter what. The savings come from the **worker nodes** (EC2 instances), which are usually the biggest cost.

### Key idea

You never "stop" EKS nodes the way you stop a laptop. If you stop an EC2 instance that belongs to a node group, the Auto Scaling Group (ASG) behind it will notice it's "unhealthy" and **launch a replacement** — you save nothing! Instead, the correct move is:

> **Scale the node group down to 0 nodes at night, and scale it back up in the morning.**

Every EKS **managed node group** is backed by an **EC2 Auto Scaling Group** with three numbers:

| Setting | Meaning |
|---|---|
| **Minimum size** | The fewest nodes allowed |
| **Desired size** | How many nodes should be running right now |
| **Maximum size** | The most nodes allowed |

To "turn off" a node group, set **min = 0 and desired = 0**. To "turn it on," set desired (and min, if you want) back to your daytime numbers.

---

## 2. Step-by-Step Example: Schedule Scale-Down with Amazon EventBridge Scheduler (Recommended, No Servers Needed)

This is the most modern approach. **EventBridge Scheduler** is an AWS service that runs actions on a cron schedule and can call the EKS API **directly** — no Lambda function or extra servers required.

**What we will build:** Every weekday at 7:00 PM, scale the node group `dev-nodes` in cluster `dev-cluster` down to 0. Every weekday at 7:00 AM, scale it back up to 2 nodes.

### Prerequisites

- An EKS cluster with a **managed node group** (this example uses cluster `dev-cluster` and node group `dev-nodes`).
- AWS CLI installed and configured (`aws configure`).
- Permission to create IAM roles and EventBridge schedules.

### Step 1 — Create an IAM role that EventBridge Scheduler can use

EventBridge Scheduler needs permission to change your node group size.

Create a trust policy file `scheduler-trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "scheduler.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Create a permissions policy file `scheduler-eks-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["eks:UpdateNodegroupConfig", "eks:DescribeNodegroup"],
      "Resource": "arn:aws:eks:us-east-1:123456789012:nodegroup/dev-cluster/dev-nodes/*"
    }
  ]
}
```

> Replace `us-east-1` and `123456789012` with your region and AWS account ID.

Create the role and attach the policy:

```bash
aws iam create-role \
  --role-name eks-offhours-scheduler-role \
  --assume-role-policy-document file://scheduler-trust.json

aws iam put-role-policy \
  --role-name eks-offhours-scheduler-role \
  --policy-name eks-scale-nodegroup \
  --policy-document file://scheduler-eks-policy.json
```

### Step 2 — Create the "scale DOWN at night" schedule

```bash
aws scheduler create-schedule \
  --name eks-dev-scale-down \
  --schedule-expression "cron(0 19 ? * MON-FRI *)" \
  --schedule-expression-timezone "America/New_York" \
  --flexible-time-window '{"Mode": "OFF"}' \
  --target '{
    "Arn": "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig",
    "RoleArn": "arn:aws:iam::123456789012:role/eks-offhours-scheduler-role",
    "Input": "{\"ClusterName\": \"dev-cluster\", \"NodegroupName\": \"dev-nodes\", \"ScalingConfig\": {\"MinSize\": 0, \"MaxSize\": 3, \"DesiredSize\": 0}}"
  }'
```

**What this means, piece by piece:**

- `cron(0 19 ? * MON-FRI *)` → run at **19:00 (7 PM)**, Monday through Friday.
- `schedule-expression-timezone` → EventBridge Scheduler handles time zones and daylight saving time for you. (Set this to your own zone, e.g. `Europe/London` or `Asia/Kolkata`.)
- The target ARN `aws-sdk:eks:updateNodegroupConfig` is a "universal target" — it calls the EKS API directly.
- `MinSize: 0, DesiredSize: 0` → all nodes in the group terminate. Pods on them are evicted.

### Step 3 — Create the "scale UP in the morning" schedule

```bash
aws scheduler create-schedule \
  --name eks-dev-scale-up \
  --schedule-expression "cron(0 7 ? * MON-FRI *)" \
  --schedule-expression-timezone "America/New_York" \
  --flexible-time-window '{"Mode": "OFF"}' \
  --target '{
    "Arn": "arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig",
    "RoleArn": "arn:aws:iam::123456789012:role/eks-offhours-scheduler-role",
    "Input": "{\"ClusterName\": \"dev-cluster\", \"NodegroupName\": \"dev-nodes\", \"ScalingConfig\": {\"MinSize\": 1, \"MaxSize\": 3, \"DesiredSize\": 2}}"
  }'
```

This brings back 2 nodes at 7 AM on weekdays. Notice it never runs on Saturday/Sunday, so the cluster stays off all weekend — a huge chunk of the savings.

### Step 4 — Test it before trusting it

Don't wait until 7 PM. Test the exact same action by hand:

```bash
# Scale down manually to prove permissions and settings work
aws eks update-nodegroup-config \
  --cluster-name dev-cluster \
  --nodegroup-name dev-nodes \
  --scaling-config minSize=0,maxSize=3,desiredSize=0

# Watch the nodes disappear (takes a few minutes)
kubectl get nodes -w

# Scale back up
aws eks update-nodegroup-config \
  --cluster-name dev-cluster \
  --nodegroup-name dev-nodes \
  --scaling-config minSize=1,maxSize=3,desiredSize=2
```

When nodes come back, confirm your apps recover:

```bash
kubectl get pods -A   # everything should return to Running
```

### Step 5 — Verify the schedules exist

```bash
aws scheduler list-schedules
```

That's it. From now on, your node group turns itself off every weeknight and weekend, and turns itself on every weekday morning.

### Roughly how much will you save?

If your node group is 2 × `m5.large` (~$0.096/hr each in us-east-1):

- Always on: 2 × $0.096 × 730 hrs ≈ **$140/month**
- On only 12 hrs × 5 days/week (~260 hrs/month): ≈ **$50/month**
- **Savings: ~65%** of node cost, per node group, per cluster. Multiply this across many dev/test clusters and it adds up fast.

---

## 3. All the Options Compared (Details, Pros & Cons)

There are several ways to do this. Pick based on how your team works.

### Option A — EventBridge Scheduler → EKS API (the example above)

**How it works:** Native AWS cron schedules call `UpdateNodegroupConfig` directly.

**Pros**
- No servers, no Lambda, no in-cluster components to maintain.
- Time-zone and daylight-saving aware.
- Updates the node group through the official EKS API, so the EKS console always shows the true scaling config (no drift between EKS and the ASG).
- Nearly free (EventBridge Scheduler costs fractions of a cent per invocation).

**Cons**
- One pair of schedules per node group (can get repetitive for many groups — use Terraform/CloudFormation loops).
- All pods are evicted at once at shutdown time (fine for dev, not for anything that must stay up).

**Best for:** Dev/test/staging clusters with managed node groups. This is the recommended default today.

### Option B — EC2 Auto Scaling Group Scheduled Actions

Every managed node group has an ASG behind it. ASGs have a built-in feature called **scheduled actions**.

```bash
# Find the ASG name for your node group
aws eks describe-nodegroup --cluster-name dev-cluster --nodegroup-name dev-nodes \
  --query "nodegroup.resources.autoScalingGroups[0].name" --output text

# Scale down at 7 PM Mon–Fri
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name <ASG_NAME> \
  --scheduled-action-name scale-down-night \
  --recurrence "0 23 * * MON-FRI" \
  --minimum-size 0 --desired-capacity 0

# Scale up at 7 AM Mon–Fri
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name <ASG_NAME> \
  --scheduled-action-name scale-up-morning \
  --recurrence "0 11 * * MON-FRI" \
  --minimum-size 1 --desired-capacity 2
```

> Note: ASG recurrence cron is in **UTC** by default (23:00 UTC = 7 PM Eastern in summer), though ASG scheduled actions also support a time-zone parameter.

**Pros**
- Built into EC2 Auto Scaling; nothing extra to deploy.
- Very simple and battle-tested.

**Cons**
- You are editing the ASG **underneath** EKS. The EKS console's scaling config can drift out of sync with reality, which can confuse teammates and tools.
- Node group ASG names change if the node group is recreated, breaking your scheduled actions silently.
- AWS generally recommends managing managed node group scaling through the EKS API instead.

**Best for:** Teams already comfortable with ASGs, or self-managed node groups (where there is no EKS scaling API in the middle).

### Option C — Kube-downscaler / KEDA + an Autoscaler (Cluster Autoscaler or Karpenter)

Instead of shutting off nodes directly, shut off the **workloads**, and let the node autoscaler remove the now-empty nodes automatically.

**How it works:**
1. Install **kube-downscaler** (or use **KEDA cron scaling**) in the cluster. It scales Deployments/StatefulSets to 0 replicas on a schedule, e.g. with an annotation like `downscaler/uptime: "Mon-Fri 07:00-19:00 America/New_York"`.
2. Run **Karpenter** (AWS's recommended autoscaler for new clusters) or the classic **Cluster Autoscaler**. When pods disappear, the autoscaler sees empty nodes and terminates them (Karpenter's "consolidation" does this quickly).
3. In the morning, kube-downscaler restores replicas; pods go "Pending"; the autoscaler launches nodes to fit them.

**Pros**
- Kubernetes-native: schedules live as annotations right on each app, so app teams control their own hours.
- Different apps can have different schedules in the same cluster.
- Nodes scale to exactly what's needed — you also save during the day if apps are idle.
- Graceful: pods are scaled down properly (respecting termination), not yanked off dying nodes.

**Cons**
- More moving parts: you must install and operate kube-downscaler **and** Karpenter/Cluster Autoscaler.
- DaemonSets and system pods (kube-system) can keep a node or two alive unless you plan for it.
- Slightly slower "wake up" in the morning (pods pend → nodes launch → pods start).

**Best for:** Shared clusters where many teams need different schedules, or clusters that already run Karpenter.

### Option D — EKS Auto Mode (newest managed option)

**EKS Auto Mode** (launched by AWS in late 2024) has AWS manage the nodes for you, including automatic scale-up/scale-down based on pods. Combine it with scheduled workload scaling (Option C style: scale Deployments to 0 at night with kube-downscaler/KEDA/CronJobs) and Auto Mode removes the empty nodes itself.

**Pros**
- No node groups, no ASGs, no autoscaler to manage at all — AWS handles node lifecycle.
- Scale-to-zero of compute happens naturally when no pods need nodes.

**Cons**
- Adds a management fee on top of EC2 pricing.
- Less low-level control; newer, so fewer community examples.

**Best for:** New clusters where minimizing operations matters more than squeezing every cent.

### Option E — AWS Instance Scheduler / third-party tools (Blink, Cast.ai, Sedai, etc.)

Pre-built solutions and SaaS products can schedule and even approve scale-downs via Slack.

**Pros:** Central dashboard across many clusters/accounts; approval workflows.
**Cons:** Extra cost and another vendor/tool; often overkill for a handful of clusters.

### Quick comparison table

| Option | Complexity | Extra components | Granularity | Best for |
|---|---|---|---|---|
| A. EventBridge Scheduler → EKS API | Low | None | Per node group | Dev/test (recommended default) |
| B. ASG scheduled actions | Low | None | Per node group | Self-managed node groups |
| C. kube-downscaler + Karpenter/CA | Medium | 2 in-cluster tools | Per app | Shared multi-team clusters |
| D. EKS Auto Mode + workload schedules | Low–Medium | Auto Mode fee | Per app | New clusters |
| E. Instance Scheduler / SaaS | Medium | External tool | Fleet-wide | Many clusters/accounts |

---

## 4. Best Practices Checklist

1. **Never stop EC2 instances directly.** The ASG will just replace them. Always change **min/desired size** instead.
2. **Only do this to non-production clusters** (dev, test, QA, staging, sandboxes) unless production genuinely has zero-traffic windows and everyone agrees.
3. **Set min = 0, not just desired = 0** when scaling down. If min stays at 1, the group can't reach 0.
4. **Use time zones on your schedules** (EventBridge Scheduler supports them natively) so daylight saving time doesn't shift your shutdown by an hour twice a year.
5. **Warn humans before shutdown.** Send a Slack/SNS notification 15–30 minutes before scale-down so anyone working late can postpone it. A common pattern: EventBridge Scheduler → SNS topic at 6:30 PM, scale-down at 7 PM.
6. **Watch out for stateful workloads.** Databases, message queues, and anything with attached EBS volumes need graceful shutdown. Prefer Option C (scale the workload first) for these, or exclude their node group from the schedule.
7. **Mind PodDisruptionBudgets (PDBs).** Setting desired=0 on a node group force-terminates nodes; strict PDBs can slow or complicate drains when autoscalers do the removal (Option C). Review PDBs on scheduled clusters.
8. **Exclude critical add-ons or keep one small "always-on" node group** if something must survive the night (e.g., a bastion pod, CI runner controller, monitoring agent). Schedule the big node groups; leave one tiny group (1 × small instance) running.
9. **Expect a warm-up delay in the morning.** Nodes take 2–5 minutes to join, then images pull, then pods start. Schedule scale-up 15–30 minutes before people actually start work.
10. **Tag everything and use Infrastructure as Code.** Define schedules in Terraform/CloudFormation so they survive cluster rebuilds and are visible in code review.
11. **Verify with the bill.** After a week, check AWS Cost Explorer (filter by the cluster's tags) to confirm EC2 spend dropped as expected.
12. **Remember what you still pay for even at 0 nodes:** the EKS control plane fee (~$0.10/hr), EBS volumes that still exist, load balancers, NAT gateways, and Elastic IPs. Scaling nodes to 0 does not remove those — clean them up separately if the environment is truly idle.
13. **Test failure modes:** What happens if scale-up fails (IAM change, quota limit)? Add a CloudWatch alarm on "node count = 0 during business hours" so mornings never start with a surprise.
14. **Don't fight your autoscaler.** If Cluster Autoscaler or Karpenter manages the same node group, a scheduled desired=0 can be undone if pending pods exist. Either scale the workloads down too (Option C), or make sure nothing schedulable remains overnight.

---

## 5. Extra Background: How Scale-Down Actually Happens

When you set desired size to 0 on a managed node group:

1. EKS updates the underlying Auto Scaling Group.
2. The ASG picks instances to terminate. For **managed** node groups, EKS attempts a graceful drain: nodes are cordoned (no new pods) and pods are evicted before the instance terminates.
3. Evicted pods with controllers (Deployments, StatefulSets) go **Pending** — they'll sit there until nodes return in the morning, then get scheduled again automatically. This is why stateless apps recover on their own.
4. In the morning, the reverse happens: new EC2 instances launch, run the EKS bootstrap, join the cluster as nodes, and the scheduler places the pending pods.

This is also why the approach works so well: **Kubernetes is self-healing by design.** You don't have to "restart your apps" — you just give the cluster its muscles back and it puts everything where it belongs.

---

## 6. Summary

- EKS worker nodes bill by the hour; dev/test clusters idle most of the week — scheduling them off saves **~60–70%** of node cost.
- "Turning off" = **scaling node groups to min 0 / desired 0**, never stopping instances.
- The recommended modern setup: **EventBridge Scheduler calling the EKS API directly** — two small schedules per node group, no servers, time-zone aware.
- For shared or sophisticated clusters, scale **workloads** on a schedule (kube-downscaler/KEDA) and let **Karpenter** remove the empty nodes.
- Follow the best-practices checklist: warn users, handle stateful apps carefully, keep schedules in IaC, alarm on failed morning scale-ups, and confirm savings in Cost Explorer.
