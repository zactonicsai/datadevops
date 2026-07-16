# Tutorial: Auto Start/Stop EKS Node Groups with AWS EventBridge to Save Money

**Level:** Beginner-friendly (explained simply, step by step)
**What you'll build:** A system that automatically shuts down your EKS worker nodes at night and starts them back up in the morning — in the right order — using **tags** to control schedules and dependencies.
**Last reviewed:** July 2026

---

## Part 1: Background — What Are All These Things?

Before we build anything, let's understand the pieces. Think of it like learning the parts of a car before driving.

### What is EKS?
**Amazon EKS (Elastic Kubernetes Service)** is AWS's managed Kubernetes service. Kubernetes is software that runs your applications inside "pods" (small packages of your app) on "nodes" (the actual computer servers, usually EC2 instances).

- **Control plane:** The "brain" of the cluster. AWS manages it. It costs **$0.10/hour (~$73/month)** no matter what. **You cannot turn this off.**
- **Node groups:** Groups of EC2 worker servers where your pods actually run. **This is where the big money goes**, and this is what we CAN turn off.
- **Pods:** Your applications. Pods live on nodes. **No nodes = no pods running = no EC2 bill.**

### Important fact: You can't "pause" an EKS cluster
There is no "stop" button for EKS like there is for a single EC2 instance. Instead, the trick everyone uses is:

> **Scale the node groups down to 0 nodes at night, and scale them back up in the morning.**

When a node group has 0 nodes, you pay $0 for EC2 compute in that group. When Kubernetes has no nodes, the pods simply wait in "Pending" state (or are recreated) until nodes come back — then they start running again automatically.

### What is EventBridge?
**Amazon EventBridge** is AWS's event and scheduling service. The part we'll use is **EventBridge Scheduler** — think of it as a super-reliable alarm clock in the cloud. You tell it: *"At 7:00 PM every weekday, run this function."* It never forgets.

> **Note:** There are two ways to schedule in EventBridge: the older **"scheduled rules"** and the newer **EventBridge Scheduler**. AWS recommends **EventBridge Scheduler** for new projects because it supports time zones, one-time schedules, flexible time windows, and retries. We'll use Scheduler.

### What is Lambda?
**AWS Lambda** runs a small piece of code (ours will be Python) without you needing a server. EventBridge Scheduler will "ring the alarm," and Lambda will do the actual work of resizing the node groups.

### What are tags?
**Tags** are labels (key = value) you can stick on almost any AWS resource. Example: `Environment = dev`. We'll use tags on node groups to store:
1. **Whether** a node group participates in auto start/stop
2. **What size** it should return to in the morning
3. **What order** it must start/stop in (the dependency tier)

### The big picture (architecture)

```
EventBridge Scheduler (cron: 7 PM weekdays)
        │ triggers with input {"action": "shutdown"}
        ▼
   Lambda function (Python)
        │ 1. Lists all node groups in the cluster
        │ 2. Reads their tags (enabled? which tier? what size?)
        │ 3. Sorts by dependency tier
        ▼
   EKS API: update_nodegroup_config (desiredSize = 0)
        ▼
   EC2 instances terminate → your bill drops

EventBridge Scheduler (cron: 7 AM weekdays)
        │ triggers with input {"action": "startup"}
        ▼
   Same Lambda → restores sizes from tags, tier by tier
```

### How much money can this save?
Rough math for a dev cluster running three `m5.xlarge` nodes (~$0.192/hr each in us-east-1):

| Scenario | Node hours/week | Weekly EC2 cost |
|---|---|---|
| Always on (24×7) | 3 × 168 = 504 | ~$96.77 |
| On 7 AM–7 PM weekdays only (12×5 = 60 hrs) | 3 × 60 = 180 | ~$34.56 |

**Savings: ~64%** on those nodes. Multiply across several node groups and clusters, and this adds up to thousands of dollars per year. (The $73/month control plane fee remains either way.)

---

## Part 2: Step-by-Step Setup — One Complete Working Example

We'll build one full example first, then go deeper afterward. Assume:
- Cluster name: `dev-cluster` in region `us-east-1`
- Three managed node groups: `ng-database`, `ng-backend`, `ng-frontend`
- Dependency rule: **database must start before backend, backend before frontend** (and shut down in reverse).

### Step 0: Prerequisites
- An EKS cluster with **managed node groups** (this tutorial targets managed node groups).
- AWS Console access with permission to create IAM roles, Lambda functions, and EventBridge schedules.
- (Optional but recommended) AWS CLI installed for the tagging step.

### Step 1: Tag your node groups
Tags carry all the "brains" of the system. We'll define this tag scheme:

| Tag key | Example value | Meaning |
|---|---|---|
| `scheduler:enabled` | `true` | This node group participates in auto start/stop |
| `scheduler:tier` | `1` | Dependency order. Tier 1 starts FIRST and stops LAST |
| `scheduler:desired` | `3` | How many nodes to restore at startup |
| `scheduler:min` | `1` | minSize to restore at startup |
| `scheduler:max` | `5` | maxSize to restore at startup |

Tag each node group (Console: EKS → Clusters → dev-cluster → Compute → node group → Tags, or CLI):

```bash
# Tier 1: database layer — starts first, stops last
aws eks tag-resource \
  --resource-arn arn:aws:eks:us-east-1:111122223333:nodegroup/dev-cluster/ng-database/abc123 \
  --tags "scheduler:enabled=true,scheduler:tier=1,scheduler:desired=2,scheduler:min=1,scheduler:max=3"

# Tier 2: backend services — needs the database first
aws eks tag-resource \
  --resource-arn arn:aws:eks:us-east-1:111122223333:nodegroup/dev-cluster/ng-backend/def456 \
  --tags "scheduler:enabled=true,scheduler:tier=2,scheduler:desired=3,scheduler:min=1,scheduler:max=5"

# Tier 3: frontend — needs the backend first
aws eks tag-resource \
  --resource-arn arn:aws:eks:us-east-1:111122223333:nodegroup/dev-cluster/ng-frontend/ghi789 \
  --tags "scheduler:enabled=true,scheduler:tier=3,scheduler:desired=2,scheduler:min=1,scheduler:max=4"
```

> Get each node group's ARN with:
> `aws eks describe-nodegroup --cluster-name dev-cluster --nodegroup-name ng-database --query nodegroup.nodegroupArn`

**Dependency tree this creates:**

```
Tier 1  ng-database        (databases, stateful sets)
   └── Tier 2  ng-backend  (APIs that need the DB)
          └── Tier 3  ng-frontend  (web UI that needs the APIs)

STARTUP order:   1 → 2 → 3   (foundation first)
SHUTDOWN order:  3 → 2 → 1   (reverse: top of the tree first)
```

### Step 2: Create the IAM policy for Lambda
IAM (Identity and Access Management) controls what the Lambda is allowed to do. **Least privilege** = only the exact permissions needed.

IAM Console → Policies → Create policy → JSON tab → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EksNodeGroupScheduler",
      "Effect": "Allow",
      "Action": [
        "eks:ListNodegroups",
        "eks:DescribeNodegroup",
        "eks:UpdateNodegroupConfig",
        "eks:TagResource"
      ],
      "Resource": [
        "arn:aws:eks:us-east-1:111122223333:cluster/dev-cluster",
        "arn:aws:eks:us-east-1:111122223333:nodegroup/dev-cluster/*/*"
      ]
    },
    {
      "Sid": "Logs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

Replace the account ID (`111122223333`), region, and cluster name with yours. Name it `eks-scheduler-policy`.

### Step 3: Create the IAM role
IAM Console → Roles → Create role:
1. Trusted entity type: **AWS service**
2. Use case: **Lambda**
3. Attach the `eks-scheduler-policy` you just created
4. Name it `eks-scheduler-lambda-role`

### Step 4: Create the Lambda function
Lambda Console → Create function:
- Name: `eks-nodegroup-scheduler`
- Runtime: **Python 3.13** (or latest available)
- Execution role: **Use existing role** → `eks-scheduler-lambda-role`
- Under Configuration → General: set **Timeout to 15 minutes** (startup waits for tiers to become healthy, which takes several minutes)

Paste this code:

```python
"""
EKS Node Group Scheduler
- Reads scheduler:* tags on managed node groups
- Startup:  scales tiers up in ASCENDING tier order (1, 2, 3...)
            waiting for each tier's node group(s) to be ACTIVE first
- Shutdown: scales tiers to 0 in DESCENDING tier order (3, 2, 1...)
Triggered by EventBridge Scheduler with input:
  {"action": "startup"}  or  {"action": "shutdown"}
"""

import boto3
import time
import os

CLUSTER = os.environ.get("CLUSTER_NAME", "dev-cluster")
TAG_ENABLED = "scheduler:enabled"
TAG_TIER = "scheduler:tier"
TAG_DESIRED = "scheduler:desired"
TAG_MIN = "scheduler:min"
TAG_MAX = "scheduler:max"
TAG_SAVED = "scheduler:saved-desired"   # snapshot taken at shutdown

WAIT_SECONDS = 20          # poll interval while waiting for a tier
MAX_WAIT_PER_TIER = 600    # give up waiting on a tier after 10 minutes

eks = boto3.client("eks")


def get_scheduled_nodegroups():
    """Return {tier_number: [nodegroup_info, ...]} for tagged node groups."""
    tiers = {}
    paginator = eks.get_paginator("list_nodegroups")
    for page in paginator.paginate(clusterName=CLUSTER):
        for ng_name in page["nodegroups"]:
            ng = eks.describe_nodegroup(
                clusterName=CLUSTER, nodegroupName=ng_name
            )["nodegroup"]
            tags = ng.get("tags", {})
            if tags.get(TAG_ENABLED, "").lower() != "true":
                continue  # not opted in — skip it
            tier = int(tags.get(TAG_TIER, "99"))  # untiered = last on startup
            tiers.setdefault(tier, []).append({
                "name": ng_name,
                "arn": ng["nodegroupArn"],
                "tags": tags,
                "current_desired": ng["scalingConfig"]["desiredSize"],
            })
    return tiers


def wait_until_active(ng_names):
    """Wait until node groups finish updating (status ACTIVE)."""
    deadline = time.time() + MAX_WAIT_PER_TIER
    pending = set(ng_names)
    while pending and time.time() < deadline:
        for name in list(pending):
            status = eks.describe_nodegroup(
                clusterName=CLUSTER, nodegroupName=name
            )["nodegroup"]["status"]
            if status == "ACTIVE":
                pending.discard(name)
            elif status in ("CREATE_FAILED", "DEGRADED"):
                raise RuntimeError(f"Node group {name} is {status}")
        if pending:
            time.sleep(WAIT_SECONDS)
    if pending:
        raise TimeoutError(f"Timed out waiting for: {pending}")


def scale(ng, desired, minimum, maximum):
    print(f"Scaling {ng['name']} -> desired={desired} min={minimum} max={maximum}")
    eks.update_nodegroup_config(
        clusterName=CLUSTER,
        nodegroupName=ng["name"],
        scalingConfig={
            "desiredSize": desired,
            "minSize": minimum,
            "maxSize": maximum,
        },
    )


def shutdown(tiers):
    # Highest tier first (frontend before backend before database)
    for tier in sorted(tiers.keys(), reverse=True):
        print(f"--- Shutting down tier {tier} ---")
        for ng in tiers[tier]:
            # Snapshot the current size into a tag so startup can restore it
            eks.tag_resource(
                resourceArn=ng["arn"],
                tags={TAG_SAVED: str(ng["current_desired"])},
            )
            # maxSize can never be 0 per the EKS API, so keep it at 1
            scale(ng, desired=0, minimum=0, maximum=1)
        wait_until_active([ng["name"] for ng in tiers[tier]])


def startup(tiers):
    # Lowest tier first (database before backend before frontend)
    for tier in sorted(tiers.keys()):
        print(f"--- Starting tier {tier} ---")
        for ng in tiers[tier]:
            t = ng["tags"]
            desired = int(t.get(TAG_SAVED) or t.get(TAG_DESIRED, "1"))
            minimum = int(t.get(TAG_MIN, "0"))
            maximum = int(t.get(TAG_MAX, str(max(desired, 1))))
            scale(ng, desired=desired, minimum=minimum, maximum=maximum)
        # WAIT so the next tier's services find this tier ready
        wait_until_active([ng["name"] for ng in tiers[tier]])


def lambda_handler(event, context):
    action = event.get("action", "").lower()
    tiers = get_scheduled_nodegroups()
    if not tiers:
        print("No node groups tagged scheduler:enabled=true. Nothing to do.")
        return {"status": "noop"}
    if action == "shutdown":
        shutdown(tiers)
    elif action == "startup":
        startup(tiers)
    else:
        raise ValueError("event must include action: startup | shutdown")
    return {"status": "ok", "action": action, "tiers": sorted(tiers.keys())}
```

Under Configuration → Environment variables, add: `CLUSTER_NAME = dev-cluster`. Click **Deploy**.

**Test it now** (before scheduling): Lambda Console → Test → create a test event with `{"action": "shutdown"}`, run it, watch the node groups scale to 0 in the EKS console. Then test `{"action": "startup"}` and confirm tier 1 finishes before tier 2 begins (check the CloudWatch logs).

### Step 5: Create the shutdown schedule in EventBridge Scheduler
EventBridge Console → **Scheduler** → Schedules → Create schedule:
1. **Name:** `eks-dev-shutdown`
2. **Schedule pattern:** Recurring → Cron-based:
   `cron(0 19 ? * MON-FRI *)` = 7:00 PM Monday–Friday
3. **Time zone:** pick YOUR local time zone (e.g., `America/New_York`). This is a big advantage of Scheduler — it handles daylight saving time for you.
4. **Flexible time window:** Off
5. **Target:** AWS Lambda → Invoke → choose `eks-nodegroup-scheduler`
6. **Payload (Input):**
   ```json
   {"action": "shutdown"}
   ```
7. Let Scheduler create its execution role automatically (it needs permission to invoke your Lambda). Create the schedule.

### Step 6: Create the startup schedule
Repeat Step 5 with:
- **Name:** `eks-dev-startup`
- **Cron:** `cron(0 7 ? * MON-FRI *)` = 7:00 AM Monday–Friday
- **Payload:** `{"action": "startup"}`

> **Tip:** Schedule startup ~30–45 minutes before people actually need the cluster. Nodes take a few minutes to boot and join, and pods need time to pull images and pass health checks — multiplied across your tiers.

### Step 7: Verify
- After 7 PM: EKS Console → node groups show desired size 0; EC2 console shows instances terminating; `kubectl get nodes` returns none; pods show `Pending`.
- After 7 AM: tiers come up 1 → 2 → 3; `kubectl get nodes` shows nodes `Ready`; pods schedule and run.
- CloudWatch → Log groups → `/aws/lambda/eks-nodegroup-scheduler` shows the tier-by-tier progress.

**That's the complete working example.** Everything below adds depth, options, and best practices.

---

## Part 3: The Dependency Tree, Explained Deeper

### Why order matters
Imagine a restaurant: if the waiters (frontend) show up before the kitchen (backend) is running, customers get errors. If the kitchen opens before the pantry (database) is stocked, the kitchen crashes. So:

- **Startup = bottom-up:** foundation services first (databases, message queues, service discovery), then the services that depend on them, then user-facing layers.
- **Shutdown = top-down (reverse):** stop the user-facing layer first so nothing is still writing to a database you're about to kill. This prevents connection errors, lost writes, and crash-loop restarts.

### Tiers vs. a full graph
Our tag design uses **numbered tiers**, which is a simple, robust way to encode a dependency tree:

```
scheduler:tier=1   ─ things that depend on nothing
scheduler:tier=2   ─ things that depend only on tier 1
scheduler:tier=3   ─ things that depend on tiers 1–2
```

If two node groups don't depend on each other, **give them the same tier** — they'll start in parallel, which is faster.

An alternative is a **`scheduler:depends-on=ng-database`** tag (a true graph), where the Lambda performs a topological sort. This is more expressive but easier to break (typos in names, accidental circular dependencies like A→B→A). **Best practice: start with tiers.** Tag values are just strings, so tiers are hard to get wrong and trivially easy to reason about.

### Two levels of dependencies (important!)
Node-group tiers control **infrastructure order**. Inside Kubernetes, also make your **pods** resilient about ordering:
- Use **readiness probes** so a backend pod isn't marked "ready" until it can reach the database.
- Use **initContainers** or retry logic so apps wait for their dependencies instead of crashing.
- Pin workloads to the right node group with **nodeSelector/labels** (e.g., database pods only on `ng-database`) — otherwise the tiering of node groups doesn't map to your services.

Well-built Kubernetes apps self-heal even if started out of order — the tiering just makes startup faster and cleaner.

---

## Part 4: Tag Reference (the full scheme)

You can go further than one fixed schedule by putting the **schedule itself in tags** and running the Lambda every hour (or every 15 minutes) with EventBridge to evaluate them:

| Tag | Example | Purpose |
|---|---|---|
| `scheduler:enabled` | `true` | Opt-in switch. Anything untagged is never touched (safe default) |
| `scheduler:tier` | `1`, `2`, `3` | Dependency order (low starts first, stops last) |
| `scheduler:desired` / `min` / `max` | `3` / `1` / `5` | Sizes to restore on startup |
| `scheduler:saved-desired` | `3` | Auto-written at shutdown; snapshot of the real size |
| `scheduler:schedule` | `office-hours` | Named schedule (Lambda maps names → up/down times) |
| `scheduler:uptime` | `Mon-Fri 07:00-19:00 America/New_York` | Fully self-describing window (Lambda parses it) |
| `scheduler:override` | `on-until-2026-07-20` | Temporary "keep it running" for late work/deadlines |

**Two design patterns — pick one:**
1. **Schedule-per-EventBridge-rule (what we built):** one startup + one shutdown schedule per time window; tags say *who* participates and *in what order*. Simple, few moving parts. Best when most node groups share the same hours.
2. **Schedule-in-tags:** one EventBridge schedule fires the Lambda every 15–60 minutes; the Lambda reads `scheduler:uptime` on each node group and decides what should be up right now. More flexible (every team sets its own hours by editing a tag — no console access needed), but the Lambda logic is more complex. This is exactly how AWS's own **Instance Scheduler on AWS** solution works.

---

## Part 5: Best Practices

1. **Opt-in, never opt-out.** Only touch node groups explicitly tagged `scheduler:enabled=true`. A bug should result in "forgot to stop something" (costs a little money), never "stopped production" (costs your job).
2. **Snapshot sizes at shutdown** (the `scheduler:saved-desired` tag in our code). Hard-coding sizes in the Lambda goes stale; tags stay with the resource.
3. **Never hard-code node group names in code.** Discover them by tag. New node groups then join the system just by being tagged — including ones created by Terraform/CloudFormation.
4. **Set Lambda timeout to 15 minutes** and, for many tiers or big clusters, consider **Step Functions** (see Part 6) so no single Lambda has to wait for everything.
5. **Watch out for autoscaler fights.** If you run **Cluster Autoscaler** or **Karpenter**, they may scale nodes right back up because pods are Pending. Fixes: also scale deployments to 0 replicas at night (a small in-cluster job or the Lambda via the Kubernetes API), set the node group `minSize=0` and let the autoscaler manage from there, or use Karpenter NodePool limits/disruption budgets on a schedule. If you use Karpenter, prefer scheduling *workloads* (replicas) down and let Karpenter remove empty nodes itself.
6. **Use PodDisruptionBudgets carefully.** Note that scaling a managed node group to 0 respects graceful termination but is blunt; drain-sensitive workloads (databases with local state) belong in tier 1 and should tolerate node shutdown, or shouldn't be in scope at all.
7. **Use EventBridge Scheduler's time zone support** instead of doing UTC math — it handles daylight saving time automatically.
8. **Announce shutdowns.** Add an SNS/Slack notification 15–30 minutes before shutdown so anyone working late can trigger the override tag.
9. **Least-privilege IAM.** Scope the policy to your specific cluster/node group ARNs (as we did) — not `Resource: "*"`.
10. **Alarm on failures.** Create a CloudWatch alarm on the Lambda's `Errors` metric → SNS email. A silent startup failure means the team arrives to a dead cluster.
11. **Mind stateful storage.** EBS volumes (PersistentVolumes) keep billing while nodes are off — that's usually fine and desirable (data survives), just know it's not $0.
12. **Skip weekends entirely** (`MON-FRI` cron) for dev/test — that alone is ~30% of the week.
13. **Test the startup path more than the shutdown path.** Shutdown failing = you lose some savings. Startup failing = the team loses a morning.

---

## Part 6: Options Compared — Pros and Cons

### Option A: EventBridge Scheduler + Lambda + tags (this tutorial)
**Pros:** Nearly free to run (pennies/month); no software in the cluster; tags make it self-service; works while the cluster has zero nodes; full control of dependency order.
**Cons:** You own the code; long multi-tier startups strain a single 15-minute Lambda; only controls node groups, not replicas (autoscalers can fight it).

### Option B: EventBridge Scheduler + Step Functions (+ small Lambdas)
Step Functions is AWS's workflow service: each tier is a state, with built-in Wait/Retry states between tiers.
**Pros:** Best for complex dependency trees; visual execution graph; retries and error branches without code; no 15-minute limit (Standard workflows run up to a year).
**Cons:** More AWS pieces to set up; slight learning curve for the state language.
**Best practice:** Move to this when you have 4+ tiers, multiple clusters, or need approval steps/notifications between tiers.

### Option C: Instance Scheduler on AWS (official AWS solution)
A prebuilt CloudFormation stack that starts/stops resources based on schedule tags.
**Pros:** Officially maintained, cross-account/cross-region, mature tag-based schedules (it added Auto Scaling Group support, which covers self-managed node groups).
**Cons:** Historically centered on EC2/RDS/ASGs rather than EKS *managed* node group APIs — verify current EKS coverage before adopting; heavier stack; less control over custom dependency logic.

### Option D: In-cluster tools (kube-downscaler / CronJobs / KEDA)
Software running inside Kubernetes scales **Deployments/StatefulSets** to 0 replicas on a schedule; Cluster Autoscaler or Karpenter then removes the empty nodes.
**Pros:** Kubernetes-native; per-namespace/per-deployment granularity via annotations; plays perfectly with autoscalers; KEDA can also wake things on events.
**Cons:** Chicken-and-egg problem — if all nodes are gone, nothing in the cluster can run the "scale up" job, so you still need something outside (EventBridge!) for wake-up; another component to maintain and patch.
**Best practice:** Combine — in-cluster downscaler handles replicas, EventBridge + Lambda handles the node groups. This is the cleanest setup for clusters that also run Karpenter.

### Option E: eksctl / CLI scripts on a schedule (Jenkins/GitHub Actions cron)
`eksctl scale nodegroup --cluster=dev-cluster --name=ng-backend --nodes=0`
**Pros:** Dead simple; great for one-off/manual pauses.
**Cons:** Depends on an always-on CI runner (which itself costs money); credentials management; no tag-driven discovery or dependency handling unless you script it all yourself.

**Bottom line:**
- 1 cluster, simple tiers → **Option A** (this tutorial)
- Many tiers/clusters, complex flows → **Option B** (Step Functions)
- Fleet-wide, many accounts, mostly EC2/ASG → **Option C**
- You run Karpenter/Cluster Autoscaler → **Option D + A combined**

---

## Part 7: Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Nodes come back at night by themselves | Cluster Autoscaler/Karpenter reacting to Pending pods | Scale replicas to 0 too, or cap the autoscaler (see Best Practice 5) |
| Lambda error `maxSize must be ≥ 1` | EKS API forbids maxSize 0 | Use `desired=0, min=0, max=1` (as our code does) |
| Morning startup "worked" but apps are broken | Tiers up, but pods started before dependencies were ready | Add readiness probes/initContainers; verify nodeSelectors pin workloads to the right node groups |
| Lambda timed out | Too many tiers to wait for in 15 min | Raise timeout to max, reduce waiting, or move to Step Functions |
| `AccessDeniedException` on UpdateNodegroupConfig | IAM policy ARNs don't match | Check account ID, region, cluster name in the policy resources |
| Schedule fired at the wrong hour | Cron written in UTC or wrong time zone | Set the schedule's Time zone field in EventBridge Scheduler |
| Node group stuck in `UPDATING` | Previous update still in progress | The API rejects concurrent updates; our `wait_until_active` prevents this — don't run startup and shutdown overlapping |

---

## Part 8: Quick Recap

1. **You can't stop EKS — you scale node groups to 0** (control plane fee remains).
2. **Tags carry everything:** opt-in flag, restore sizes, and dependency **tier**.
3. **EventBridge Scheduler** is the alarm clock (time-zone aware); **Lambda** is the worker.
4. **Startup = lowest tier first; shutdown = highest tier first**, waiting for each tier to be ACTIVE.
5. **Opt-in only, snapshot sizes, alarm on failures, and watch for autoscaler conflicts.**
6. Typical dev/test savings from nights + weekends: **60–70% of node compute cost.**
