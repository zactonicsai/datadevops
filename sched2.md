Yes — a cron Lambda is absolutely an option, and it's the right choice in specific situations.

## Cron Lambda (EventBridge rule → Lambda → EKS API)

It works like this: an EventBridge rule with a cron expression triggers a Lambda function, which calls `eks:UpdateNodegroupConfig` using the AWS SDK (boto3, etc.).

**When it makes sense** — when you need *logic*, not just a fixed API call:

- **Many node groups/clusters:** loop over everything tagged `Schedule=office-hours` instead of maintaining dozens of schedules
- **Remember daytime sizes:** before scaling down, save current desired/min to a tag or DynamoDB, then restore exactly those values in the morning (a fixed schedule hardcodes the numbers)
- **Notifications & approvals:** post to Slack "scaling down in 30 min, react 🛑 to skip"
- **Safety checks:** skip scale-down if a CI job is running or business-hours pods exist

**When it's overkill:** one or two node groups with fixed sizes. Then plain EventBridge Scheduler (the tutorial's Option A) does the same thing with zero code to write, patch, or debug. The Lambda itself costs pennies — the real cost is maintaining Python/Node code, IAM for Lambda, and runtime upgrades.

Rule of thumb: **static schedule → EventBridge Scheduler; dynamic behavior → Lambda.**

## EKS cost breakdown (us-east-1 examples)

| Component | Price | Scales to 0 at night? |
|---|---|---|
| Control plane | $0.10/hr (~$73/mo) per cluster | ❌ Never (extended-support versions: $0.60/hr) |
| EC2 nodes | Per instance-hr (m5.large ≈ $0.096/hr) | ✅ **This is what you save** |
| EKS Auto Mode fee | ~10–12% on top of EC2 for managed nodes | ✅ Follows nodes |
| EBS volumes | gp3 ≈ $0.08/GB-mo | ⚠️ Node root volumes go; PVCs persist |
| Load balancers | ALB ≈ $0.0225/hr + usage | ❌ Stays unless deleted |
| NAT Gateway | $0.045/hr + $0.045/GB | ❌ Stays unless deleted |
| Fargate pods | Per vCPU-hr + GB-hr | ✅ Stops when pods stop |
| Data transfer | Cross-AZ $0.01/GB each way, egress ~$0.09/GB | ✅ Stops with traffic |

## How the savings math works

Savings apply **only to the hourly components you actually turn off** — mainly EC2.

Example dev cluster, 3 × m5.large:

- **Always on:** 3 × $0.096 × 730 hrs = **$210/mo** nodes + $73 control plane + ~$33 NAT = ~$316/mo
- **12 hrs weekdays only** (~260 hrs/mo): 3 × $0.096 × 260 = **$75/mo** nodes → total ~$181/mo
- **Node savings: 65%. Total bill savings: ~43%** — the fixed costs (control plane, NAT, LBs) dilute the percentage

Key takeaways: the fraction of hours off drives savings (168-hr week − 60 business hrs = 64% off), bigger/more nodes = bigger absolute savings, and if a cluster is *mostly* fixed costs, consider deleting NAT/LBs off-hours too or consolidating clusters. Also note Spot instances stack with scheduling — Spot nodes at ~70% off, running only 36% of hours, can cut node cost ~90% vs on-demand 24/7.

Here's the per-hour savings view (us-east-1, on-demand Linux pricing):

## Savings per hour when scaled to 0

| Instance type | $/hr per node | 2 nodes | 3 nodes | 5 nodes |
|---|---|---|---|---|
| t3.medium | $0.0416 | $0.083 | $0.125 | $0.208 |
| t3.large | $0.0832 | $0.166 | $0.250 | $0.416 |
| m5.large | $0.096 | $0.192 | $0.288 | $0.480 |
| m5.xlarge | $0.192 | $0.384 | $0.576 | $0.960 |
| m5.2xlarge | $0.384 | $0.768 | $1.152 | $1.920 |
| c5.2xlarge | $0.340 | $0.680 | $1.020 | $1.700 |
| r5.xlarge | $0.252 | $0.504 | $0.756 | $1.260 |

## What those hours add up to

Typical off-hours schedule (nights 7 PM–7 AM + full weekends) = **~470 hours off per month**:

| Setup | Saved per hour | Saved per month |
|---|---|---|
| 3 × t3.medium | $0.125 | ~$59 |
| 3 × m5.large | $0.288 | ~$135 |
| 3 × m5.xlarge | $0.576 | ~$271 |
| 5 × m5.2xlarge | $1.920 | ~$902 |
| 10 × m5.xlarge | $1.920 | ~$902 |

## What keeps costing you per hour (even at 0 nodes)

| Component | $/hr while "off" |
|---|---|
| EKS control plane | $0.100 |
| NAT Gateway (1) | $0.045 |
| ALB (1) | $0.0225 |
| **Fixed floor** | **~$0.17/hr** |

So the break-even intuition: scheduling only pays off meaningfully once your node cost exceeds that ~$0.17/hr floor — which is true for almost any cluster bigger than a couple of t3.mediums. Prices vary a bit by region; check yours in the AWS pricing calculator.

Want this added as a section in the tutorial file?