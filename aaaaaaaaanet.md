# AWS EC2-to-EC2 Networking Lab: Make It Work, Then Break It On Purpose

**A hands-on tutorial using only the AWS Console and Session Manager (SSM) — no SSH keys, no bastion hosts, no public IPs.**

---# Cost Breakdown — AWS EC2-to-EC2 Networking Lab

**Region:** us-east-1 (N. Virginia) — the cheapest AWS region for everything in this lab
**Prices verified:** July 2026 list pricing
**Currency:** USD

> ⚠️ Always cross-check against the [AWS Pricing Calculator](https://calculator.aws) before committing to an architecture. AWS adjusts rates without much announcement.

---

## 1. The Short Answer

| Scenario | Cost |
|----------|------|
| **2-hour lab, cleaned up properly** | **≈ $0.13** |
| 2-hour lab + 5 Reachability Analyzer runs | ≈ $0.63 |
| Left running 24 hours (oops) | ≈ $1.53 |
| **Left running 30 days (the real danger)** | **≈ $37.87** |
| Same lab with NAT gateway instead of endpoints | ≈ $33 for 30 days (but less secure) |
| Same lab, brand-new AWS account on Free Tier | **≈ $22 for 30 days** (EC2 is free, endpoints are not) |

**The one number to remember:** three VPC interface endpoints across two AZs cost **$0.06/hour** whether you use them or not. That's **$43.80/month** for something sitting completely idle. This is the dominant cost in the lab and the thing that bites people.

---

## 2. Per-Component Rates

### 2.1 Free components (no charge, ever)

These make up most of what you build:

| Component | Cost | Notes |
|-----------|------|-------|
| VPC | **$0.00** | The VPC itself is always free |
| Subnets | **$0.00** | Any number, any size |
| Route tables | **$0.00** | |
| Internet Gateway | **$0.00** | Free to have (data transfer still applies) |
| Security groups | **$0.00** | Unlimited rules within quota |
| Network ACLs | **$0.00** | |
| IAM roles & policies | **$0.00** | |
| SSM Session Manager | **$0.00** | The *service* is free — endpoints are not |
| VPC Peering connection | **$0.00** | Hourly is free; you pay for data transfer |
| Gateway VPC endpoints (S3/DynamoDB) | **$0.00** | <cite index="19-1">Gateway Endpoints for S3 and DynamoDB are free</cite> |

> **Why this matters:** the entire "networking" part of your lab — VPC, subnets, routing, both firewalls — is genuinely free. Everything you pay for is either compute or PrivateLink.

### 2.2 Paid components

| Component | Rate | Monthly (730 hrs) | Used in this lab? |
|-----------|------|-------------------|-------------------|
| **VPC Interface Endpoint** | <cite index="2-1">$0.01 per hour per Availability Zone</cite> | $7.30 per AZ | ✅ 3 endpoints × 2 AZs |
| **Interface Endpoint data processing** | <cite index="4-1">$0.01/GB for the first 1 PB</cite> | usage-based | ✅ negligible |
| **EC2 t3.micro (Linux)** | <cite index="12-1">$0.0104/hr in us-east-1</cite> | <cite index="8-1">$7.59/month</cite> | ✅ 2 instances |
| **EBS gp3 root volume** | $0.08/GB-month | $0.64 for 8 GB | ✅ 2 volumes |
| **Cross-AZ data transfer** | <cite index="6-1">Same-AZ is free; cross-AZ adds $0.01/GB each way</cite> | usage-based | ✅ negligible |
| **Reachability Analyzer** | $0.10 per analysis | per-run | ⚠️ optional |
| **VPC Flow Logs → CloudWatch** | $0.50/GB ingest + $0.03/GB storage | usage-based | ⚠️ optional |
| **Public IPv4 address** | <cite index="4-1">$0.005 per hour, whether in-use or idle — about $3.65/month per IP</cite> | $3.65 | ❌ we use none |
| **NAT Gateway** | <cite index="19-1">$0.045 per hour + $0.045 per GB</cite> | <cite index="19-1">$32.85/month</cite> | ❌ we avoid this |
| **EC2 Instance Connect Endpoint** | ~$0.005/hr | ~$3.60 | ⚠️ Lab 11 optional |

---

## 3. The Actual Lab Bill, Line by Line

### 3.1 A focused 2-hour session (build + Part B + a few labs)

| Line item | Qty | Rate | Hours | Cost |
|-----------|-----|------|-------|------|
| Interface endpoint: `ssm` | 2 AZs | $0.01/hr | 2 | $0.04 |
| Interface endpoint: `ssmmessages` | 2 AZs | $0.01/hr | 2 | $0.04 |
| Interface endpoint: `ec2messages` | 2 AZs | $0.01/hr | 2 | $0.04 |
| EC2 `instance-a` (t3.micro) | 1 | $0.0104/hr | 2 | $0.02 |
| EC2 `instance-b` (t3.micro) | 1 | $0.0104/hr | 2 | $0.02 |
| EBS gp3 8 GB × 2 | 16 GB | $0.08/GB-mo | 2 | $0.004 |
| Endpoint data processing | <0.1 GB | $0.01/GB | — | ~$0.00 |
| Cross-AZ transfer (ping/nc) | <0.01 GB | $0.01/GB | — | ~$0.00 |
| **TOTAL** | | | | **$0.16** |

### 3.2 The full tutorial, all 11 labs (≈ 4 hours)

| Line item | Cost |
|-----------|------|
| 3 endpoints × 2 AZs × 4 hrs | $0.24 |
| 2 × t3.micro × 4 hrs | $0.08 |
| `instance-c` (Lab 6) × 1 hr | $0.01 |
| EBS (3 volumes × 4 hrs) | $0.01 |
| Reachability Analyzer × 6 runs | $0.60 |
| VPC Flow Logs (Lab 5, ~50 MB) | $0.03 |
| EC2 Instance Connect Endpoint (Lab 11, 1 hr) | $0.01 |
| Data transfer | ~$0.00 |
| **TOTAL** | **$0.98** |

**Under a dollar for the entire tutorial.** That's the good news.

### 3.3 The bad news: what "forgetting to clean up" costs

| Line item | Rate | 30 days (730 hrs) |
|-----------|------|-------------------|
| 3 endpoints × 2 AZs | $0.06/hr | **$43.80** |
| 2 × t3.micro | $0.0208/hr | $15.18 |
| EBS 16 GB gp3 | — | $1.28 |
| **TOTAL** | | **$60.26/month** |

**And if you only deployed endpoints in one AZ** (which the tutorial doesn't, but many people do to save money):

| Line item | 30 days |
|-----------|---------|
| 3 endpoints × 1 AZ | $21.90 |
| 2 × t3.micro | $15.18 |
| EBS | $1.28 |
| **TOTAL** | **$38.36/month** |

> 💡 **The single-AZ tradeoff:** deploying endpoints in one AZ halves the endpoint cost but creates a hard dependency — if that AZ has problems, SSM stops working for *every* instance in the VPC, including ones in the healthy AZ. For a lab, single-AZ is a reasonable money saver. For production, two AZs is correct.

---

## 4. Cost per Failure Lab

Most labs are free — you're editing config, not provisioning resources.

| Lab | What it provisions | Extra cost |
|-----|-------------------|------------|
| 1 — Missing IAM profile | Nothing | **$0.00** |
| 2 — Missing SG rule | Nothing | **$0.00** |
| 3 — Wrong port | Nothing | **$0.00** |
| 4 — Wrong SG source | Nothing | **$0.00** |
| 5 — NACL stateless trap | Optional: Flow Logs | $0.00–0.05 |
| 6 — Wrong VPC | `instance-c` + optional peering | ~$0.01/hr |
| 7 — Broken route table | Nothing | **$0.00** |
| 8 — Deleted endpoint | Nothing (saves money briefly!) | **$0.00** |
| 9 — Endpoint SG blocks 443 | Nothing | **$0.00** |
| 10 — Localhost binding | Nothing | **$0.00** |
| 11 — Agent stopped | Optional: EICE | $0.00–0.01/hr |
| *Any lab* | Reachability Analyzer | $0.10 per run |

**8 of 11 labs are completely free.** The tutorial is deliberately built this way — breaking security group rules, route tables, and NACLs costs nothing because those components cost nothing.

---

## 5. Free Tier Considerations

If your AWS account is under 12 months old:

| Resource | Free Tier allowance | Covers this lab? |
|----------|--------------------|--------------------|
| EC2 t3.micro | <cite index="14-1">750 hours/month of t2.micro or t3.micro (enough to run one instance 24/7) plus 30GB of EBS storage</cite> | ✅ Yes — 2 instances × 4 hrs = 8 hrs, well under 750 |
| EBS | 30 GB | ✅ Yes — we use 16 GB |
| VPC endpoints | **None** | ❌ **No — full price** |
| Data transfer out | 100 GB/month | ✅ Yes |

**Bottom line on Free Tier:** your compute is free, but the $0.06/hour endpoint charge applies from minute one. Free Tier does **not** protect you from the main cost in this lab.

> ⚠️ **Note:** <cite index="14-1">There is no permanent free tier for EC2 — production workloads always cost money.</cite> The 12-month clock starts at account creation, not at first use.

---

## 6. Architecture Cost Comparison

The tutorial deliberately picks the cheaper-and-more-secure option. Here's the math behind that choice.

### 6.1 Private SSM access: Endpoints vs NAT Gateway

Both give private instances a path to the SSM service. Here's what each costs at rest:

| | 3 Interface Endpoints (2 AZ) | 1 NAT Gateway |
|---|---|---|
| Hourly | $0.06 | <cite index="19-1">$0.045</cite> |
| Monthly base | $43.80 | <cite index="19-1">$32.85</cite> |
| Per GB | $0.01 | <cite index="19-1">$0.045</cite> |
| Also needs | — | Elastic IP ($3.65/mo) |
| Realistic monthly total | **$43.80** | **$36.50+** |

**So NAT is cheaper for this specific lab?** Yes — for three endpoints at rest, marginally. But the picture flips fast:

| Monthly data volume | 3 Endpoints (2 AZ) | NAT Gateway + EIP |
|---------------------|--------------------|--------------------|
| 0 GB | $43.80 | $36.50 |
| 100 GB | $44.80 | $41.00 |
| 500 GB | $48.80 | $59.00 |
| 1 TB | $53.80 | $82.55 |
| 5 TB | $93.80 | $266.00 |

**Crossover point: roughly 250 GB/month.** Beyond that, endpoints win and keep winning.

**And cost isn't the only axis:**

| | Endpoints | NAT Gateway |
|---|---|---|
| Traffic leaves AWS network | **No** | Yes (to public AWS endpoints) |
| Per-service firewall control | **Yes** (SG per endpoint) | No |
| Instance can reach arbitrary internet | No — **this is a feature** | Yes — this is a risk |
| Compliance story | Strong | Weaker |

<cite index="5-1">Traffic to AWS services that exits the VPC and re-enters via public endpoints is harder to constrain, harder to audit, and harder to defend in a compliance review than traffic that never leaves the AWS network at all.</cite>

<cite index="6-1">Interface endpoints can reduce costs by 78%+ compared to routing AWS service traffic through NAT Gateways</cite> for high-traffic AWS-service workloads.

**Real-world answer:** production VPCs often run both — endpoints for chatty AWS services (S3, ECR, SSM, CloudWatch), NAT for genuine general internet access like OS package updates.

### 6.2 Single-AZ vs Multi-AZ endpoints

| Setup | Monthly | Failure mode |
|-------|---------|--------------|
| 3 endpoints, 1 AZ | $21.90 | AZ outage kills SSM VPC-wide |
| 3 endpoints, 2 AZ | $43.80 | Survives one AZ failure |
| 3 endpoints, 3 AZ | $65.70 | Survives two AZ failures |

### 6.3 Access method cost comparison

| Method | Monthly cost | Notes |
|--------|--------------|-------|
| SSH with public IP | $3.65 | Cheapest, worst security — port 22 exposed |
| SSH via bastion host (t3.micro + EIP) | $11.24 | Extra box to patch and secure |
| **SSM via VPC endpoints** | **$43.80** | Most secure, fully audited, no open ports |
| SSM via NAT Gateway | $36.50 | Cheaper but instances get general internet |
| EC2 Instance Connect Endpoint | $3.65 | Real SSH into private subnets, no public IP |

> 💡 **The cheapest secure option people miss:** if you only need occasional shell access and don't need SSM's Run Command / patch management / session logging, an **EC2 Instance Connect Endpoint at ~$3.65/month** gives you keyless SSH into private subnets for 1/12th the cost of the three SSM endpoints. It's a genuinely good option for dev environments.

---

## 7. Where Costs Hide

The things that surprise people on the bill:

| Hidden cost | Rate | How it sneaks up |
|-------------|------|------------------|
| **Unattached Elastic IPs** | <cite index="4-1">$0.005/hour, whether in-use or idle</cite> ≈ $3.65/mo | Terminate an instance, forget the EIP |
| **Orphaned EBS volumes** | $0.08/GB-mo | Volume set to *not* delete on termination |
| **Endpoints in extra AZs** | $7.30/AZ/mo | Wizard defaults to selecting all AZs |
| **Cross-AZ chatter** | <cite index="6-1">$0.01/GB each way</cite> | Our lab is cross-AZ by design; at scale this adds up |
| **Flow Logs to CloudWatch** | $0.50/GB ingest | A busy VPC generates GBs of logs daily |
| **Reachability Analyzer** | $0.10/run | Easy to run 20 times while debugging = $2 |
| **NAT data processing** | $0.045/GB | <cite index="20-1">The data processing charge applies even when the destination is another AWS service in the same region</cite> |
| **EBS snapshots** | $0.05/GB-mo | Auto-created by backup policies you forgot about |

> **The cross-AZ note is worth internalizing.** <cite index="6-1">Same-AZ data transfer is free; cross-AZ adds $0.01/GB each way. Keep chatty services in the same AZ.</cite> Our lab puts instances in different AZs *specifically to teach that they can still talk* — but a production database replicating 500 GB/day across AZs would cost ~$300/month in transfer alone.

---

## 8. Cost Guardrails — Set These Up Now

### 8.1 A billing alert (5 minutes, prevents most horror stories)

1. **Billing and Cost Management → Budgets → Create budget**
2. Choose **Zero spend budget** (alerts at any charge) or **Monthly cost budget**
3. Set threshold: **$5**
4. Add your email → **Create budget**

You'll get an email the moment anything unexpected accrues. This has saved more people from four-figure surprise bills than any other single AWS feature.

### 8.2 Verify you're clean after the lab

| Check | Where | Looking for |
|-------|-------|-------------|
| Endpoints deleted | VPC → Endpoints | Empty list |
| Instances terminated | EC2 → Instances | State = Terminated |
| No stray EIPs | EC2 → Elastic IPs | Nothing unassociated |
| No orphan volumes | EC2 → Volumes | Nothing in `available` state |
| No orphan ENIs | EC2 → Network Interfaces | Nothing in `available` state |
| Nothing accruing | Cost Explorer → filter to today | $0.00 trending |

> **Cost Explorer lags 24 hours.** Check it the day *after* cleanup, not immediately. Immediately after cleanup it'll still show yesterday's charges and you'll think something is wrong.

### 8.3 Set a phone alarm

Genuinely. Set a timer for 3 hours when you start. The #1 cause of surprise AWS bills isn't misconfiguration — it's getting distracted mid-lab and never coming back.

---

## 9. Cheapest Possible Version of This Lab

If you want to run the tutorial for the absolute minimum:

| Change | Saves | Tradeoff |
|--------|-------|----------|
| Endpoints in 1 AZ instead of 2 | $0.03/hr | Both instances still work; less resilient |
| Use `t4g.nano` instead of `t3.micro` | $0.012/hr | ARM Graviton; <cite index="14-1">~$3/month, 2 vCPU / 0.5 GiB RAM</cite>; AL2023 ARM AMI has SSM agent |
| Skip Reachability Analyzer | $0.10/run | Manual diagnosis (arguably better learning) |
| Skip Flow Logs | ~$0.05 | Lab 5 is less vivid without the ACCEPT/REJECT proof |
| Skip Lab 6 (`instance-c` + peering) | ~$0.01/hr | Miss the cross-VPC lesson |
| Do it all in one AZ | ~$0 | Miss the cross-AZ latency observation |

**Minimum viable lab (1 AZ endpoints, 2× t4g.nano, 2 hrs):**

| Item | Cost |
|------|------|
| 3 endpoints × 1 AZ × 2 hrs | $0.06 |
| 2 × t4g.nano × 2 hrs | $0.017 |
| EBS | $0.004 |
| **TOTAL** | **$0.08** |

**Free Tier account, minimum config:** ≈ **$0.06** (endpoints only).

---

## 10. Quick Reference

```
FREE:      VPC, subnets, route tables, security groups, NACLs,
           IAM roles, IGW, peering (hourly), S3/DynamoDB gateway endpoints,
           SSM service itself

$0.01/hr:  each interface endpoint, PER AZ         ← the lab's main cost
$0.0104/hr: t3.micro Linux
$0.005/hr: public IPv4 address (even unused)
$0.045/hr: NAT gateway (+ $0.045/GB)
$0.10:     each Reachability Analyzer run
$0.01/GB:  cross-AZ data transfer, each way
$0.01/GB:  interface endpoint data processing
```

**The three numbers that matter for this lab:**

1. **$0.06/hour** — three endpoints, two AZs, running idle
2. **$43.80/month** — the same thing if you forget to delete it
3. **$0.16** — what the lab actually costs if you clean up

**Delete the VPC endpoints first during cleanup.** They're the expensive part, they bill by the hour regardless of use, and <cite index="7-1">hourly billing for your VPC endpoint will stop when you delete it. Each partial VPC endpoint-hour consumed is billed as a full hour.</cite>


## Table of Contents

1. [What You're Going to Build](#1-what-youre-going-to-build)
2. [Background: The Words You Need to Know](#2-background-the-words-you-need-to-know)
3. [Before You Start](#3-before-you-start)
4. [Part A — Step-by-Step Build (The Working Example)](#part-a--step-by-step-build-the-working-example)
5. [Part B — Prove It Works](#part-b--prove-it-works)
6. [Part C — Break It On Purpose (11 Failure Labs)](#part-c--break-it-on-purpose-11-failure-labs)
7. [The Master Troubleshooting Flowchart](#the-master-troubleshooting-flowchart)
8. [Deep Background: How Packets Actually Move](#deep-background-how-packets-actually-move)
9. [Best Practices](#best-practices)
10. [Pros and Cons of Your Options](#pros-and-cons-of-your-options)
11. [Cleanup (Do Not Skip This)](#cleanup-do-not-skip-this)
12. [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet)

---

## 1. What You're Going to Build

Imagine two computers in two different rooms of the same building. You want them to talk to each other. That's the whole project.

In AWS language:

- The **building** is a VPC (Virtual Private Cloud) — your own private slice of Amazon's data center.
- The **rooms** are subnets — smaller sections of the building.
- The **computers** are EC2 instances — virtual servers you rent by the hour.
- The **door locks** are security groups and network ACLs.
- The **hallways** are route tables.

Here's the picture:

```
┌───────────────────────────────────────────────────────────────────┐
│  VPC: lab-vpc          10.0.0.0/16                                │
│                                                                    │
│  ┌──────────────────────────┐    ┌──────────────────────────┐    │
│  │ Subnet A (private)       │    │ Subnet B (private)       │    │
│  │ 10.0.1.0/24              │    │ 10.0.2.0/24              │    │
│  │ AZ: us-east-1a           │    │ AZ: us-east-1b           │    │
│  │                          │    │                          │    │
│  │  ┌────────────────────┐  │    │  ┌────────────────────┐  │    │
│  │  │ EC2: instance-a    │  │    │  │ EC2: instance-b    │  │    │
│  │  │ 10.0.1.10          │◄─┼────┼─►│ 10.0.2.10          │  │    │
│  │  │ SG: sg-app         │  │    │  │ SG: sg-db          │  │    │
│  │  └────────────────────┘  │    │  └────────────────────┘  │    │
│  └──────────────────────────┘    └──────────────────────────┘    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ VPC Endpoints (so SSM works without internet)            │    │
│  │  • com.amazonaws.us-east-1.ssm                           │    │
│  │  • com.amazonaws.us-east-1.ssmmessages                   │    │
│  │  • com.amazonaws.us-east-1.ec2messages                   │    │
│  │  SG: sg-endpoints (allows 443 from VPC)                  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Route Table: rtb-private → local (10.0.0.0/16) only              │
└───────────────────────────────────────────────────────────────────┘
```

**No internet gateway. No NAT gateway. No public IPs. No SSH keys.** Everything happens through private networking and SSM Session Manager.

**Estimated cost:** VPC endpoints cost about $0.01/hour each. Three endpoints running for a 2-hour lab ≈ $0.06, plus two t3.micro instances ≈ $0.04. Total well under a dollar — *if you do the cleanup in Section 11.* If you leave the endpoints running for a month, that's about $22. Set a phone alarm.

---

## 2. Background: The Words You Need to Know

Read this section even if you're in a hurry. Every failure lab later on depends on you knowing these five ideas.

### 2.1 VPC — Your Private Building

A **VPC** is a private network inside AWS that only you can use. When you create one, you pick a range of IP addresses using something called **CIDR notation**.

`10.0.0.0/16` means: "All addresses that start with `10.0.`" — that's 65,536 addresses from `10.0.0.0` to `10.0.255.255`.

The number after the slash tells you how many bits are locked down:

| CIDR | Locked bits | Usable IPs (AWS) | Plain English |
|------|-------------|------------------|---------------|
| `/16` | First 16 | 65,531 | `10.0.anything.anything` |
| `/24` | First 24 | 251 | `10.0.1.anything` |
| `/28` | First 28 | 11 | 16 addresses, tiny |

> **Why AWS gives you 5 fewer than you'd expect:** In a `/24` you'd think you get 256 addresses. AWS reserves 5 in every subnet: the network address (`.0`), the VPC router (`.1`), DNS (`.2`), a reserved-for-future slot (`.3`), and the broadcast address (`.255`). So a `/24` gives you 251 usable IPs.

### 2.2 Subnet — A Room in the Building

A **subnet** is a smaller chunk of your VPC's address range. Every subnet lives in exactly one **Availability Zone** (AZ) — a physically separate data center building.

Two subnets in different AZs can still talk to each other for free within the same VPC. That's built in and you don't configure it. Remember this — it kills a very common misconception.

### 2.3 Security Group — A Bouncer With a Guest List

A **security group** (SG) is a firewall that wraps around each instance's network card. Three things make SGs weird compared to normal firewalls:

1. **Allow-only.** You cannot write a "deny" rule. If no rule matches, traffic is dropped. Silence means no.
2. **Stateful.** If you allow traffic *in*, the reply is automatically allowed *out*. You never write return rules.
3. **They can reference each other.** Instead of writing an IP address as the source, you can write another security group's ID. That means "anything wearing this badge is allowed in." This is the single most useful AWS networking trick and we'll use it.

**Default behavior when you create a new SG:**
- Inbound: **empty** (nothing gets in)
- Outbound: **allow all** (everything gets out)

### 2.4 Network ACL — A Guard at the Room Door

A **Network ACL** (NACL) is a second firewall, but it sits at the *subnet* boundary instead of the instance. It's the opposite of a security group in almost every way:

| | Security Group | Network ACL |
|---|---|---|
| Attaches to | Instance (ENI) | Subnet |
| Deny rules? | No | Yes |
| Stateful? | Yes — replies auto-allowed | **No** — you must write return rules |
| Rule order | All rules evaluated | Numbered, lowest first, first match wins |
| Default (new custom) | In: deny all, Out: allow all | **In: deny all, Out: deny all** |
| Default (VPC's default NACL) | n/a | Allow all both ways |

The **stateless** part is what bites everyone. If you allow port 22 inbound on a NACL, the reply comes *back* from a random high port (1024–65535, called an **ephemeral port**). If you didn't allow those outbound, the connection hangs.

### 2.5 Route Table — The Building's Hallway Map

A **route table** tells packets where to go. Every VPC gets one automatic rule you cannot delete:

```
Destination: 10.0.0.0/16   Target: local
```

This is why any subnet can reach any other subnet in the same VPC by default. That "local" route is permanent and always wins for in-VPC traffic.

### 2.6 SSM Session Manager — Getting In Without Keys

Traditionally you'd SSH into an EC2 instance using a `.pem` key file and an open port 22. **Session Manager** replaces that entirely.

Here's the flow, and it's backwards from what you'd expect:

```
Your Browser  →  AWS SSM Service  ←  [outbound HTTPS 443]  ←  EC2 Instance
                                       (agent dials OUT)
```

The SSM Agent running *on the instance* makes an **outbound** connection to AWS. AWS never connects *in* to your instance. That means:

- ❌ No inbound port 22 needed
- ❌ No public IP needed
- ❌ No SSH key needed
- ✅ Every session is logged in CloudTrail
- ✅ Access controlled by IAM, not by who has a key file

**The three things SSM requires:**
1. SSM Agent installed and running (pre-installed on Amazon Linux 2023)
2. An IAM instance profile with the `AmazonSSMManagedInstanceCore` policy
3. A network path to three SSM endpoints on port 443 — either via internet/NAT, or via **VPC endpoints** (what we'll use)

---

## 3. Before You Start

**You need:**
- An AWS account with permissions to create VPCs, EC2 instances, IAM roles, and VPC endpoints
- A web browser
- About 45 minutes for the build, plus 60+ minutes if you do all 11 failure labs

**Pick a region and stay in it.** This guide uses **us-east-1 (N. Virginia)**. If you use a different region, substitute it everywhere you see `us-east-1`. Mixing regions is a classic way to waste an hour wondering why nothing appears in a dropdown.

**Check your region:** top-right corner of the AWS Console. Confirm it before every single step.

---

# Part A — Step-by-Step Build (The Working Example)

We'll build the whole thing first, get it working, and *then* break it.

---

## Step 1 — Create the VPC and Subnets

AWS has a wizard that builds several things at once. We'll use it but then strip out the parts we don't want.

1. Open the console and search for **VPC** in the top search bar. Click **VPC**.
2. In the left sidebar, click **Your VPCs**, then the orange **Create VPC** button.
3. At the top, select **VPC and more** (not "VPC only" — the wizard saves time).
4. Fill in:

| Field | Value |
|-------|-------|
| Name tag auto-generation | ✅ checked, enter `lab` |
| IPv4 CIDR block | `10.0.0.0/16` |
| IPv6 CIDR block | No IPv6 CIDR block |
| Tenancy | Default |
| Number of Availability Zones (AZs) | **2** |
| Number of public subnets | **0** |
| Number of private subnets | **2** |
| NAT gateways | **None** |
| VPC endpoints | **None** |
| DNS options | ✅ Enable DNS hostnames, ✅ Enable DNS resolution |

> **Why 0 public subnets and no NAT gateway?** We want to prove SSM works with zero internet access. A NAT gateway also costs about $32/month, which is real money for a lab. VPC endpoints are cheaper and more secure.

5. Look at the **Preview** panel on the right. You should see one VPC, two subnets, one route table, and zero gateways.
6. Click **Create VPC**. Wait for all green checkmarks, then click **View VPC**.

**Expected result:**

| Resource | Name | Value |
|----------|------|-------|
| VPC | `lab-vpc` | `10.0.0.0/16` |
| Subnet | `lab-subnet-private1-us-east-1a` | `10.0.1.0/24` |
| Subnet | `lab-subnet-private2-us-east-1b` | `10.0.2.0/24` |
| Route table | `lab-rtb-private1-us-east-1a` | 1 route: `10.0.0.0/16 → local` |

> **Note:** The wizard sometimes assigns `10.0.128.0/20` style CIDRs instead of `10.0.1.0/24`. Either is fine. **Write down whatever CIDRs you actually got** — you'll need them later.

7. Click **Subnets** in the sidebar and confirm both subnets exist and are in **different AZs**. Copy both **Subnet IDs** into a notepad.

---

## Step 2 — Create the IAM Role for SSM

Without this role, your instances are invisible to Session Manager. This is the #1 reason people can't connect.

1. Search for **IAM** in the top bar. Click **IAM**.
2. Sidebar → **Roles** → **Create role**.
3. **Trusted entity type:** AWS service
4. **Use case:** select **EC2**. Click **Next**.
5. In the permissions search box, type `AmazonSSMManagedInstanceCore`. Check its box.
6. Click **Next**.
7. **Role name:** `EC2-SSM-Lab-Role`
8. **Description:** `Allows EC2 instances to be managed by SSM Session Manager`
9. Click **Create role**.

**What this policy actually grants:** permission to call `ssm:UpdateInstanceInformation` (register itself), `ssmmessages:*` (the Session Manager data channel), and `ec2messages:*` (legacy command channel). It grants **zero** access to your other AWS resources.

> **Best practice note:** `AmazonSSMManagedInstanceCore` is an AWS-managed policy, which means AWS keeps it updated. For production, many teams still write a custom policy scoped to specific instance IDs. For a lab, the managed policy is correct.

---

## Step 3 — Create the Security Groups

We need three. Create them in this order, because two of them reference each other.

Go to **VPC → Security groups → Create security group**. Do this three times.

### 3a. `sg-endpoints` — for the VPC endpoints

| Field | Value |
|-------|-------|
| Name | `sg-endpoints` |
| Description | `Allows HTTPS from VPC to interface endpoints` |
| VPC | `lab-vpc` |

**Inbound rules** — click **Add rule**:

| Type | Protocol | Port range | Source | Description |
|------|----------|------------|--------|-------------|
| HTTPS | TCP | 443 | Custom → `10.0.0.0/16` | `HTTPS from anywhere in VPC` |

**Outbound rules:** leave the default `All traffic → 0.0.0.0/0`.

Click **Create security group**.

### 3b. `sg-app` — for instance-a

| Field | Value |
|-------|-------|
| Name | `sg-app` |
| Description | `App tier instance` |
| VPC | `lab-vpc` |

**Inbound rules:** **leave completely empty for now.** We'll add one in Step 3d.

**Outbound rules:** leave the default `All traffic → 0.0.0.0/0`.

Click **Create security group**. Copy the resulting **sg-xxxxx ID** into your notepad.

### 3c. `sg-db` — for instance-b

| Field | Value |
|-------|-------|
| Name | `sg-db` |
| Description | `DB tier instance` |
| VPC | `lab-vpc` |

**Inbound rules** — click **Add rule** twice:

| Type | Protocol | Port range | Source | Description |
|------|----------|------------|--------|-------------|
| Custom TCP | TCP | 3306 | Custom → **`sg-app`** (start typing `sg-` and pick sg-app from the dropdown) | `MySQL from app tier` |
| All ICMP - IPv4 | ICMP | All | Custom → **`sg-app`** | `Ping from app tier` |

**Outbound rules:** leave the default.

Click **Create security group**.

> **This is the important part.** The source isn't an IP address — it's *another security group*. This means "allow anything wearing the sg-app badge." If you add ten more app servers later, they're automatically allowed. No IP list to maintain. This is called a **security group reference** and it's the AWS-native pattern.

### 3d. Go back and add a rule to `sg-app`

Now that `sg-db` exists, we can add the reverse rule for testing.

1. Select `sg-app` → **Inbound rules** tab → **Edit inbound rules** → **Add rule**:

| Type | Protocol | Port range | Source | Description |
|------|----------|------------|--------|-------------|
| All ICMP - IPv4 | ICMP | All | Custom → **`sg-db`** | `Ping from db tier` |

2. **Save rules.**

**Why:** ICMP (ping) is technically stateless in how AWS handles echo request vs. echo reply. Security groups handle ICMP echo/reply pairs correctly as stateful, but having both directions explicit makes your bidirectional tests cleaner and removes ambiguity when we start breaking things.

---

## Step 4 — Create the VPC Endpoints

Three endpoints. Without all three, Session Manager will not work in a no-internet VPC.

Go to **VPC → Endpoints → Create endpoint**. Repeat three times.

### Endpoint 1 of 3: SSM

| Field | Value |
|-------|-------|
| Name tag | `vpce-ssm` |
| Type | **AWS services** |
| Service Name | search `ssm`, select **`com.amazonaws.us-east-1.ssm`** (type: Interface) |
| VPC | `lab-vpc` |
| Subnets | ✅ **both** AZs — pick `lab-subnet-private1` for us-east-1a and `lab-subnet-private2` for us-east-1b |
| IP address type | IPv4 |
| Security groups | ✅ `sg-endpoints` — **uncheck the default SG** |
| Policy | Full access |

Click **Create endpoint**.

> ⚠️ **Careful in the service list.** You'll see `com.amazonaws.us-east-1.ssm` and also `com.amazonaws.us-east-1.ssm-incidents`, `ssm-contacts`, and `ssm-quicksetup`. You want the plain one with nothing after `ssm`.

### Endpoint 2 of 3: SSM Messages

Same steps, but:
- **Name tag:** `vpce-ssmmessages`
- **Service Name:** `com.amazonaws.us-east-1.ssmmessages`

### Endpoint 3 of 3: EC2 Messages

Same steps, but:
- **Name tag:** `vpce-ec2messages`
- **Service Name:** `com.amazonaws.us-east-1.ec2messages`

**What each one does:**

| Endpoint | Job | Symptom if missing |
|----------|-----|--------------------|
| `ssm` | Agent registers itself, reports health, gets patch info | Instance never appears in Fleet Manager |
| `ssmmessages` | Carries the actual interactive terminal session data | Instance appears "Online" but Connect button fails or session dies instantly |
| `ec2messages` | Legacy channel for Run Command | Run Command fails; sessions may be unstable |

**Wait for all three to show Status: `Available`.** This takes 2–5 minutes. Refresh the page. Do not proceed until all three are green.

---

## Step 5 — Launch the Two EC2 Instances

### 5a. Launch `instance-a`

1. Go to **EC2 → Instances → Launch instances**.
2. Fill in:

| Field | Value |
|-------|-------|
| Name | `instance-a` |
| AMI | **Amazon Linux 2023 AMI** (SSM Agent is pre-installed) |
| Architecture | 64-bit (x86) |
| Instance type | `t3.micro` |
| Key pair | **Proceed without a key pair (Not recommended)** ← yes, really |

3. Expand **Network settings** → click **Edit**:

| Field | Value |
|-------|-------|
| VPC | `lab-vpc` |
| Subnet | `lab-subnet-private1-us-east-1a` |
| Auto-assign public IP | **Disable** |
| Firewall (security groups) | **Select existing security group** → `sg-app` |

4. Expand **Advanced details**. Scroll to **IAM instance profile** and select **`EC2-SSM-Lab-Role`**.

> This is the step everyone forgets. It's buried in "Advanced details" and there's no warning if you skip it. If you skip it, the instance launches fine, runs fine, and is completely unreachable.

5. Click **Launch instance**.

### 5b. Launch `instance-b`

Repeat with these changes:

| Field | Value |
|-------|-------|
| Name | `instance-b` |
| Subnet | `lab-subnet-private2-us-east-1b` |
| Security group | `sg-db` |
| IAM instance profile | `EC2-SSM-Lab-Role` |

Everything else identical.

### 5c. Record the private IPs

Go to **EC2 → Instances**. Wait until both show **Running** and **2/2 checks passed** (about 2 minutes).

Click each instance and copy its **Private IPv4 address** from the Details tab.

**Write these down:**

```
instance-a  →  10.0.1.___
instance-b  →  10.0.2.___
```

You'll use these constantly. In this guide I'll write `<IP-A>` and `<IP-B>`.

---

## Step 6 — Verify SSM Registration

**Wait 3–5 minutes after launch.** The agent needs time to find the endpoints and register.

1. Go to **Systems Manager** (search "Systems Manager" in the top bar).
2. Sidebar → **Node Management** → **Fleet Manager**.
3. You should see both instances with **Ping status: Online**.

**If they're not there after 5 minutes:** don't panic and don't rebuild. Jump to **Failure Lab 1** in Part C — it walks through exactly how to diagnose this, and this is the single most common problem in the whole tutorial.

---

# Part B — Prove It Works

## Step 7 — Connect to instance-a

1. **EC2 → Instances** → select `instance-a` → click **Connect** (top right).
2. Choose the **Session Manager** tab.
3. Click **Connect**.

A black terminal opens in your browser. You'll see something like:

```
sh-5.2$
```

Make it friendlier:

```bash
sudo su - ec2-user
```

Now your prompt is `[ec2-user@ip-10-0-1-10 ~]$`. The hostname contains the private IP with dashes — a handy way to confirm which box you're on.

## Step 8 — Run the Baseline Tests

Run each of these from `instance-a`. Replace `<IP-B>` with instance-b's actual private IP.

### Test 1: Ping (ICMP)

```bash
ping -c 4 <IP-B>
```

**Expected — working:**
```
PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.
64 bytes from 10.0.2.10: icmp_seq=1 ttl=127 time=0.842 ms
64 bytes from 10.0.2.10: icmp_seq=2 ttl=127 time=0.771 ms
64 bytes from 10.0.2.10: icmp_seq=3 ttl=127 time=0.798 ms
64 bytes from 10.0.2.10: icmp_seq=4 ttl=127 time=0.765 ms

--- 10.0.2.10 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3057ms
rtt min/avg/max/mdev = 0.765/0.794/0.842/0.029 ms
```

**Key numbers to notice:**
- `0% packet loss` = perfect
- `~0.8 ms` = cross-AZ latency. Same-AZ would be ~0.2 ms. Both are fast; this difference is normal and is the price of high availability.

### Test 2: TCP port check

Install a proper port-testing tool:

```bash
sudo dnf install -y nmap-ncat
```

Now test port 3306:

```bash
nc -zv <IP-B> 3306
```

**Expected right now — connection refused:**
```
Ncat: Connection refused.
```

**This is a PASS, not a failure.** Read the next section carefully — this distinction is the heart of network troubleshooting.

### 🔑 The Single Most Important Concept in This Tutorial

| What you see | What it means | Where the problem is |
|--------------|---------------|----------------------|
| `Connection refused` | Packet **arrived**. The OS said "nothing is listening on that port." | **Network is fine.** Problem is the application (not running / wrong port / bound to 127.0.0.1) |
| Hangs, then `Connection timed out` | Packet **vanished**. Nothing replied at all. | **Network is blocked.** Check SG, NACL, route table, wrong IP |
| `No route to host` | Local OS or NACL rejected it before it left | Routing or NACL deny |

Memorize this. **Refused = fast and loud = network OK. Timeout = slow and silent = network broken.**

Why? A security group that blocks traffic simply *drops* the packet. It doesn't send back a rejection. Your instance waits, and waits, and eventually gives up. But if the packet arrives and no program is listening, the target OS politely sends back a TCP RST packet meaning "nobody's home" — and that's instant.

### Test 3: Start a real listener and get a real success

Open a **second browser tab**, connect to `instance-b` via Session Manager, and run:

```bash
sudo su - ec2-user
nc -l 3306
```

The cursor sits there blinking. That's correct — it's listening.

Back on **instance-a**:

```bash
nc -zv <IP-B> 3306
```

**Expected — full success:**
```
Ncat: Connected to 10.0.2.10:3306.
```

🎉 **You now have proof of a complete working path:** route table → security group → subnet → NACL → instance → listening application.

Now make them actually chat. On **instance-a**:

```bash
nc <IP-B> 3306
```

Type `hello from A` and press Enter. Watch it appear on instance-b's screen. Type back. Press `Ctrl+C` on both when done.

### Test 4: Save your baseline

Run this on instance-a and screenshot the output. When things break later, this is your "known good."

```bash
echo "=== BASELINE $(date) ===" && \
echo "--- My identity ---" && \
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300") && \
curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id && echo && \
curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 && echo && \
echo "--- Ping to B ---" && ping -c 3 <IP-B> && \
echo "--- Route table ---" && ip route && \
echo "--- SSM agent ---" && sudo systemctl is-active amazon-ssm-agent
```

> **Note on that TOKEN business:** that's IMDSv2, the secure version of instance metadata. You request a short-lived token first, then use it. AMIs from 2023 onward require it. If you ever see a tutorial doing `curl http://169.254.169.254/latest/meta-data/` with no token, that's IMDSv1 and it's deprecated for security reasons.

---

# Part C — Break It On Purpose (11 Failure Labs)

Now the real learning. Each lab follows the same shape:

**Break it → See the symptom → Diagnose it properly → Fix it → Understand why**

**Golden rule: fix each lab completely before starting the next one.** Two overlapping problems are ten times harder to diagnose than one, which is also true in real life and is exactly why change management exists.

---

## Failure Lab 1 — Missing IAM Instance Profile

*Difficulty: ⭐ | Frequency in real life: 🔥🔥🔥🔥🔥 (the #1 SSM problem)*

### Break it

1. **EC2 → Instances** → select `instance-a`.
2. **Actions → Security → Modify IAM role**.
3. Set the dropdown to **No IAM role**. Type `disassociate` to confirm. Click **Remove IAM role**.
4. Wait 5 minutes. (SSM caches credentials, so it won't fail instantly.)

### Symptom

- **Systems Manager → Fleet Manager:** instance-a disappears, or shows **Connection lost**
- **EC2 → Connect → Session Manager tab:** the **Connect** button is greyed out
- Hovering over it shows a vague message about the instance not being configured

### Diagnose

Because you can't get into instance-a anymore, diagnose it **from the console**:

1. **EC2 → Instances →** `instance-a` **→ Details** tab → look for **IAM Role**. It says `–`.
2. **Systems Manager → Fleet Manager**: instance not listed.

Here's the real-world diagnostic order for "SSM won't connect":

```
1. Does the instance have an IAM role?           ← 60% of cases
2. Does that role have AmazonSSMManagedInstanceCore?  ← 15%
3. Are all three VPC endpoints Available?        ← 10%
4. Does the endpoint SG allow 443 from VPC?      ← 5%
5. Is the SSM agent running on the box?          ← 5%
6. Does the instance SG allow outbound 443?      ← 5%
```

### Fix

1. **Actions → Security → Modify IAM role**
2. Select **`EC2-SSM-Lab-Role`** → **Update IAM role**
3. Wait 3–5 minutes. Refresh Fleet Manager.

> **Speed it up:** if you're impatient, reboot the instance (**Instance state → Reboot**). The agent re-reads credentials on startup.

### Why this happens

The SSM Agent needs AWS credentials to say "hi, I'm here, I'm instance i-abc123." It gets those credentials from the **instance metadata service** at `169.254.169.254`, which only serves them if an IAM role is attached.

Without a role, the agent literally cannot authenticate to AWS. It's not a firewall problem, not a routing problem, not a networking problem at all — it's an identity problem. The instance is running perfectly, has full network access, and is completely unreachable.

**Confusing detail:** the agent caches credentials for a few minutes, so removing the role doesn't break things instantly. Conversely, adding a role doesn't fix things instantly. This lag makes people think their fix didn't work when it did. **Always wait 5 minutes before concluding anything about SSM.**

---

## Failure Lab 2 — Missing Security Group Rule (Timeout)

*Difficulty: ⭐ | Frequency: 🔥🔥🔥🔥🔥*

### Break it

1. **VPC → Security groups →** `sg-db` → **Inbound rules** → **Edit inbound rules**
2. **Delete** the ICMP rule (click the ✕ on that row). Keep the 3306 rule.
3. **Save rules.**

### Symptom

From instance-a:

```bash
ping -c 4 <IP-B>
```

```
PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.

--- 10.0.2.10 ping statistics ---
4 packets transmitted, 0 received, 100% packet loss, time 3080ms
```

Notice: **no error message at all.** Just silence, then a summary saying nothing came back. It takes about 4 seconds to fail.

Meanwhile:
```bash
nc -zv <IP-B> 3306
Ncat: Connection refused.
```

Port 3306 still responds instantly. **One protocol works, another doesn't.** That's a screaming clue.

### Diagnose

**Step 1 — Use the pattern.** 100% loss + no error message + slow = **silent drop** = firewall.

**Step 2 — Narrow it down with the differential.** TCP/3306 gets a *response* (refused). ICMP gets *nothing*. So packets from A definitely reach B's network interface. Something is filtering by protocol.

**Step 3 — Use VPC Reachability Analyzer.** This is AWS's purpose-built tool and it beats guessing every time.

1. **VPC → Reachability Analyzer → Create and analyze path**
2. Fill in:

| Field | Value |
|-------|-------|
| Name | `a-to-b-icmp` |
| Source type | Instances |
| Source | `instance-a` |
| Destination type | Instances |
| Destination | `instance-b` |
| Protocol | **ICMP** |

3. Click **Create and analyze path**. Wait ~1 minute. Refresh.

**Result:** `Not reachable`

Expand **Explanations**. It will say something very close to:

> *The security group `sg-db` (sg-0abc...) attached to the destination network interface does not have an inbound rule that allows ICMP traffic from the source.*

It names the exact security group and the exact missing rule. This tool costs $0.10 per analysis and is worth every penny.

**Step 4 — Confirm manually.** Go to `sg-db` → Inbound rules. Only 3306 is listed. Confirmed.

### Fix

Re-add the rule:

| Type | Protocol | Port | Source |
|------|----------|------|--------|
| All ICMP - IPv4 | ICMP | All | `sg-app` |

Save. Test again — ping works **instantly**. No reboot, no waiting. Security group changes take effect in under a second.

### Why this happens

Security groups are **allow-list only**. There is no rule that says "block ICMP" — there's just an *absence* of a rule that says "allow ICMP." No match = silent drop.

**Why silent?** AWS deliberately drops rather than rejects. A rejection tells an attacker "something is here but it's filtered," which is useful reconnaissance. Silence tells them nothing. It's a security decision that makes your life harder, on purpose.

**The direction that matters:** you edited the *destination's inbound* rules. Traffic from A to B is *inbound* at B. Instance-a's outbound rules were never involved because the default outbound rule allows everything. When debugging, always ask: **"which direction is this traffic, at which instance?"**

---

## Failure Lab 3 — Wrong Port in the Security Group

*Difficulty: ⭐ | Frequency: 🔥🔥🔥🔥*

### Break it

1. `sg-db` → **Edit inbound rules**
2. Change the port on the MySQL rule from `3306` to `3307`. Save.
3. On **instance-b**, start a listener: `nc -l 3306`

### Symptom

From instance-a:
```bash
nc -zv <IP-B> 3306
```
```
Ncat: Connection timed out.
```

**Compare this to earlier.** Before, with no listener, you got `Connection refused` in under a second. Now, with a listener actually running, you get a **timeout after ~2 minutes**. The app is *more* ready than before and the result is *worse*.

### Diagnose

**The trap:** many people see a timeout, assume the application crashed, and go debug the app. They'll spend an hour on instance-b checking logs while the actual problem is a typo in a firewall rule.

**Use the pattern instead:** timeout = network drop. The app is irrelevant. Go to the network.

**Prove the app is fine.** On instance-b:
```bash
sudo ss -tlnp | grep 3306
```
```
LISTEN 0  10  0.0.0.0:3306  0.0.0.0:*  users:(("nc",pid=3421,fd=3))
```

`ss` is the modern replacement for `netstat`. The flags mean: `-t` TCP, `-l` listening only, `-n` numeric ports (don't translate to names), `-p` show which process.

`0.0.0.0:3306` means it's listening on **all network interfaces** — good. If it said `127.0.0.1:3306` that would be a genuine app problem (Failure Lab 10).

App confirmed healthy. **Therefore the problem is the network.**

**Now check the SG.** `sg-db` → Inbound → you see `3307`, not `3306`. Found it.

**Faster route:** Reachability Analyzer with Protocol = TCP, Destination port = 3306. It'll report:

> *The security group does not have an inbound rule allowing TCP traffic on port 3306 from the source.*

### Fix

Change `3307` back to `3306`. Save. Retry:
```
Ncat: Connected to 10.0.2.10:3306.
```

### Why this happens

Ports are exact-match integers. There is no "close enough." 3306 and 3307 are as different as 3306 and 80.

**Real-world versions of this bug:**
- 8080 vs 8000 (both are "the dev port" in different frameworks)
- 443 vs 8443 (HTTPS vs alternate HTTPS)
- 5432 vs 5433 (PostgreSQL default vs second instance)
- 6379 vs 6380 (Redis vs Redis-with-TLS)

**The lesson worth carrying:** *timeout with a confirmed-running app = firewall, essentially always.* Don't debug the app. Debug the path.

---

## Failure Lab 4 — Wrong Security Group Source (The Two-Way Mirror)

*Difficulty: ⭐⭐ | Frequency: 🔥🔥🔥🔥*

### Break it

1. `sg-db` → **Edit inbound rules**
2. Change the source of the 3306 rule from `sg-app` to **`sg-db`** (itself).
3. Save.
4. On instance-b: `nc -l 3306`

### Symptom

From instance-a:
```bash
nc -zv <IP-B> 3306
Ncat: Connection timed out.
```

But the rule is *right there* on screen. Port 3306. Allowed. It looks completely correct at a glance.

### Diagnose

**Read the rule out loud in plain English.** Seriously — this technique catches more bugs than any tool.

> "Allow inbound TCP 3306 **from anything wearing the sg-db badge**."

Now ask: **what badge is instance-a wearing?**

Check: **EC2 → instance-a → Security tab → Security groups**. It says `sg-app`.

`sg-app` ≠ `sg-db`. Instance-a isn't on the guest list. Denied.

**Confirm the theory with a control test.** Launch a temporary third instance in subnet-b with `sg-db` attached, and try from there — it works. Same port, same target, different badge, different outcome. That isolates the variable perfectly.

(If you don't want to launch a third instance, Reachability Analyzer will tell you the same thing without the cost.)

### Fix

Change source back to `sg-app`. Save. Works immediately.

### Why this happens

A security group referencing **itself** is a real and useful pattern — it means "members of this group can talk to each other." You'd use it for a database cluster where nodes need to replicate to each other.

But it's *not* what you want for tier-to-tier traffic. Here's the mental model:

```
sg-app        = the badge worn by app servers
sg-db         = the badge worn by database servers

Rule on sg-db: "allow 3306 from sg-app"
              = "database doors open for anyone with an app badge"  ✅

Rule on sg-db: "allow 3306 from sg-db"
              = "database doors open for anyone with a db badge"
              = databases can talk to each other, apps cannot        ❌
```

**Why security group references beat IP addresses (a genuinely important idea):**

| Approach | What happens when you add 5 more app servers |
|----------|----------------------------------------------|
| Source = `10.0.1.10/32` | Rule breaks. Manually add 5 more rules. Hit the 60-rule limit eventually. |
| Source = `10.0.1.0/24` | Works, but now *any* instance in that subnet can reach the DB, including ones that shouldn't. |
| Source = `sg-app` | Works automatically. New servers get the badge on launch. Nothing to update. Zero over-permission. |

This is why AWS architects use SG references almost exclusively for internal traffic. It's self-maintaining and least-privilege at the same time.

---

## Failure Lab 5 — Network ACL Blocking (The Stateless Trap)

*Difficulty: ⭐⭐⭐ | Frequency: 🔥🔥🔥 (rare, but brutal when it happens)*

This is the hardest lab. Take your time.

### Break it

1. **VPC → Network ACLs → Create network ACL**
   - Name: `nacl-broken`
   - VPC: `lab-vpc`
   - Click **Create**

2. Select `nacl-broken` → **Inbound rules** tab → **Edit inbound rules** → **Add new rule**:

| Rule # | Type | Protocol | Port range | Source | Allow/Deny |
|--------|------|----------|------------|--------|------------|
| 100 | All traffic | All | All | `0.0.0.0/0` | **ALLOW** |

Save.

3. **Outbound rules** tab → **Edit outbound rules** → **Add new rule**:

| Rule # | Type | Protocol | Port range | Destination | Allow/Deny |
|--------|------|----------|------------|-------------|------------|
| 100 | HTTPS | TCP | 443 | `0.0.0.0/0` | ALLOW |

Save. **Note we allowed only 443 outbound. Nothing else.**

4. **Subnet associations** tab → **Edit subnet associations** → check **`lab-subnet-private2`** (instance-b's subnet) → Save.

### Symptom

From instance-a:
```bash
ping -c 4 <IP-B>
100% packet loss

nc -zv <IP-B> 3306
Ncat: Connection timed out.
```

Now check the security groups. **They're perfect.** Port 3306 allowed from sg-app. ICMP allowed from sg-app. Everything you'd normally check is correct.

**And here's the part that breaks brains:** on instance-b, run `nc -l 3306` and then from instance-b try to reach instance-a:

```bash
# On instance-b:
ping -c 2 <IP-A>
```
Also fails. **Traffic is broken in both directions**, even though your inbound NACL rule says ALLOW ALL.

### Diagnose

**Step 1 — Rule out the usual suspects.** SGs are correct (you just checked). Routes are default. So it's something else in the path.

**Step 2 — Know the checklist.** When SGs look fine, the path has exactly these remaining components:

```
Route table  →  NACL (out)  →  [VPC fabric]  →  NACL (in)  →  SG  →  ENI  →  App
```

**Step 3 — Check the NACL.** **VPC → Subnets →** `lab-subnet-private2` → **Network ACL** tab. It shows `nacl-broken` instead of the default. That's the anomaly.

**Step 4 — Read the rules.** Inbound: allow all. Outbound: allow 443 only, then the implicit `*` DENY.

**Step 5 — Understand why "allow all inbound" isn't enough.** This is the whole lesson:

```
STEP 1: A sends SYN to B:3306
        Source port 51234 (random ephemeral)  →  Dest port 3306
        NACL inbound rule 100: ALLOW ALL  ✅  Packet arrives at B.

STEP 2: B replies SYN-ACK back to A
        Source port 3306  →  Dest port 51234
        This is now OUTBOUND from B's subnet.
        NACL outbound: only 443 allowed. Port 51234 is not 443.
        Falls through to rule *: DENY  ❌  Reply is destroyed.

RESULT: A sent a packet successfully, B received it successfully,
        B answered correctly, and A never hears anything.
        Timeout.
```

The request worked. The response died. Because NACLs are **stateless**, they have no memory that a conversation is in progress. Each packet is judged alone, on its own merits, with no context.

**Step 6 — Confirm with Reachability Analyzer.** It reports:

> *The network ACL `nacl-broken` associated with the destination subnet does not have an outbound rule that allows the return traffic on the ephemeral port range.*

**Step 7 — Confirm with VPC Flow Logs (optional but very instructive).**

Enable them: **VPC → Your VPCs →** `lab-vpc` → **Flow logs** tab → **Create flow log** → Filter: **All** → Destination: **CloudWatch Logs** → create a log group named `vpc-flow-logs`. (Requires an IAM role for flow logs; the console will offer to create one.)

Generate traffic, wait ~5 minutes, then look in CloudWatch Logs. You'll see:

```
2 123456789012 eni-aaa 10.0.1.10 10.0.2.10 51234 3306 6 1 40 ... ACCEPT OK
2 123456789012 eni-bbb 10.0.2.10 10.0.1.10 3306 51234 6 1 40 ... REJECT OK
```

Line 1: the request was **ACCEPT**ed. Line 2: the reply was **REJECT**ed. The evidence is right there in black and white — and it's exactly the pattern that means "stateless firewall ate my return traffic."

> **Flow Logs pro tip:** `ACCEPT` on the way out and `REJECT` on the way back is the *signature* of a NACL problem. If it were a security group, you'd only ever see the one direction.

### Fix

**Option A (correct for a real environment):** add an ephemeral port range rule.

**Outbound rules** → **Add new rule**:

| Rule # | Type | Protocol | Port range | Destination | Allow/Deny |
|--------|------|----------|------------|-------------|------------|
| 110 | Custom TCP | TCP | **1024 - 65535** | `0.0.0.0/0` | ALLOW |

Also add ICMP outbound so ping replies work:

| Rule # | Type | Protocol | Port range | Destination | Allow/Deny |
|--------|------|----------|------------|-------------|------------|
| 120 | All ICMP - IPv4 | ICMP | All | `0.0.0.0/0` | ALLOW |

**Option B (correct for this lab):** put the subnet back on the default NACL.

1. **VPC → Subnets →** `lab-subnet-private2` → **Network ACL** tab → **Edit network ACL association**
2. Select the **default** NACL (the one named `lab-...` with no custom name)
3. Save
4. Delete `nacl-broken` so it can't cause confusion in later labs

Test again. Everything works.

### Why this happens

**The ephemeral port explanation, in full:**

When any computer opens an outbound TCP connection, it picks a random unused port number for its own end. That's the **ephemeral port** (also called a source port). The server replies *to that port*.

Linux uses **32768–60999** by default. Windows uses 49152–65535. AWS load balancers use 1024–65535. Because you rarely know what's on the other end, the standard advice is to allow **1024–65535** outbound on NACLs.

You can see your own range:
```bash
cat /proc/sys/net/ipv4/ip_local_port_range
32768   60999
```

**The comparison that makes it click:**

| | Security Group | Network ACL |
|---|---|---|
| Remembers connections? | **Yes** | **No** |
| You write return rules? | Never | Always |
| Allow 3306 in → reply works? | ✅ automatically | ❌ need ephemeral outbound too |

**When should you actually use NACLs?**

Honestly: rarely. They're a blunt instrument. The legitimate uses are:

- ✅ Blocking a specific malicious IP range across an entire subnet at once (SGs can't do deny)
- ✅ Compliance requirements demanding "defense in depth" with two firewall layers
- ✅ A guardrail so a junior engineer's overly-permissive SG can't expose a truly sensitive subnet

Otherwise, **use security groups and leave NACLs at their default allow-all.** Most AWS outages caused by NACLs are caused by someone editing a NACL. The default is fine.

---

## Failure Lab 6 — Wrong Subnet / Different VPC

*Difficulty: ⭐⭐ | Frequency: 🔥🔥🔥*

### Break it

We'll build a second, separate VPC and put an instance in it.

1. **VPC → Create VPC → VPC only:**

| Field | Value |
|-------|-------|
| Name | `other-vpc` |
| IPv4 CIDR | `172.16.0.0/16` |

2. **Subnets → Create subnet:**

| Field | Value |
|-------|-------|
| VPC | `other-vpc` |
| Name | `other-subnet` |
| AZ | us-east-1a |
| CIDR | `172.16.1.0/24` |

3. **Security groups → Create:**

| Field | Value |
|-------|-------|
| Name | `sg-other` |
| VPC | `other-vpc` |
| Inbound | All traffic from `0.0.0.0/0` ← wide open on purpose |

4. **Launch `instance-c`:** AL2023, t3.micro, no key pair, VPC = `other-vpc`, subnet = `other-subnet`, SG = `sg-other`, IAM role = `EC2-SSM-Lab-Role`.

5. Note its private IP: `172.16.1.___`

### Symptom

From instance-a:
```bash
ping -c 4 172.16.1.x
```
```
--- 172.16.1.x ping statistics ---
4 packets transmitted, 0 received, 100% packet loss
```

Sometimes you'll instead see:
```
connect: Network is unreachable
```

**And instance-c's security group allows literally everything from everywhere.** Wide open. Still fails.

### Diagnose

**Step 1 — Notice the CIDR mismatch.** Instance-a is `10.0.x.x`. Instance-c is `172.16.x.x`. Different first octets → almost certainly different VPCs.

**Step 2 — Look at the route table.** On instance-a:

```bash
ip route
```
```
default via 10.0.1.1 dev enX0
10.0.1.0/24 dev enX0 proto kernel scope link src 10.0.1.10
```

Instance-a knows about its own subnet, and has a default gateway. Now look at the *AWS* route table: **VPC → Route tables →** `lab-rtb-private1`:

```
Destination      Target
10.0.0.0/16      local
```

**One route.** There is no entry for `172.16.0.0/16`. AWS has no idea where to send that packet, so it drops it.

**Step 3 — Reachability Analyzer.** Source `instance-a`, destination `instance-c`. It reports:

> *No route to the destination. The source and destination are in different VPCs and no peering connection, transit gateway, or other connectivity exists between them.*

**Step 4 — Note that no firewall was ever consulted.** The packet died at the routing stage, before any security group or NACL was evaluated. This is why "but the security group is wide open!" is irrelevant here.

### Fix — Option 1: VPC Peering

A direct private link between two VPCs.

1. **VPC → Peering connections → Create peering connection:**

| Field | Value |
|-------|-------|
| Name | `lab-to-other` |
| VPC (Requester) | `lab-vpc` |
| VPC (Accepter) | `other-vpc` |

2. Create it. Then **Actions → Accept request**.

3. **Add routes on both sides.** Peering does *not* create routes automatically — this is the step everyone forgets.

   **lab-vpc's route table** → Edit routes → Add route:

| Destination | Target |
|-------------|--------|
| `172.16.0.0/16` | Peering Connection → `lab-to-other` |

   **other-vpc's route table** → Edit routes → Add route:

| Destination | Target |
|-------------|--------|
| `10.0.0.0/16` | Peering Connection → `lab-to-other` |

4. Make sure security groups allow the traffic **by CIDR** — SG references do *not* work across peering connections unless both VPCs are in the same AWS account and region (and even then you must explicitly enable it).

5. Test:
```bash
ping -c 4 172.16.1.x
64 bytes from 172.16.1.5: icmp_seq=1 ttl=127 time=1.21 ms
```

### Fix — Option 2: Put it in the right VPC

Terminate `instance-c` and relaunch it in `lab-vpc`. In real life this is often the right answer — if two things need to talk constantly, they probably belong in the same VPC.

### Why this happens

**VPCs are isolated by design, completely and by default.** That's the entire point of a VPC. Two VPCs are as separate as two different companies' networks, even if they're owned by you, in the same region, in the same account.

To connect them you must *explicitly* build a bridge:

| Method | Best for | Cost | Complexity |
|--------|----------|------|------------|
| **VPC Peering** | 2–5 VPCs, simple mesh | Free (pay data transfer only) | Low |
| **Transit Gateway** | 5+ VPCs, hub-and-spoke | ~$36/mo + $0.02/GB | Medium |
| **PrivateLink** | Exposing one service, not whole networks | ~$7/mo per endpoint | Medium |
| **VPN / Direct Connect** | Connecting to on-premises | Varies | High |

**The peering gotcha that catches everyone:** peering is **not transitive**. If A peers with B, and B peers with C, then **A cannot reach C**. You'd need a third peering connection A↔C. With 10 VPCs, full mesh needs 45 connections. That's precisely when you switch to Transit Gateway.

**Also:** peered VPCs cannot have overlapping CIDRs. If both are `10.0.0.0/16`, peering will refuse to be created. Plan your IP ranges before you build, not after.

---

## Failure Lab 7 — Broken Route Table

*Difficulty: ⭐⭐ | Frequency: 🔥🔥*

### Break it

The `local` route can't be deleted, so we'll break routing a different way: by pointing traffic somewhere useless.

1. **VPC → Route tables →** select `lab-rtb-private2` (instance-b's route table)
2. **Routes** tab → **Edit routes** → **Add route**:

| Destination | Target |
|-------------|--------|
| `10.0.1.0/24` | Instance → **`instance-b`** (itself) |

3. Save.

*(If the console won't let you pick an instance as a target, use a Network Interface target and select instance-b's ENI.)*

### Symptom

From instance-a:
```bash
ping -c 4 <IP-B>
100% packet loss
```

SGs are correct. NACLs are default. Same VPC. Everything you'd normally check is fine.

### Diagnose

**Step 1 — Check both route tables, not just the source's.** Traffic needs a valid path in *both* directions.

**VPC → Subnets →** `lab-subnet-private2` → **Route table** tab:

```
Destination      Target                Status
10.0.0.0/16      local                 Active
10.0.1.0/24      eni-xxx / i-instanceb Active   ← the problem
```

**Step 2 — Understand longest-prefix match.** When multiple routes could apply, AWS picks the **most specific** one (the largest prefix number).

Packet going to `10.0.1.10`:
- Matches `10.0.0.0/16` → local (16 bits specific)
- Matches `10.0.1.0/24` → instance-b (24 bits specific) ← **this wins**

So instance-b's replies to instance-a get sent *to instance-b*, which has no idea what to do with them and drops them.

**Step 3 — Reachability Analyzer** will report a routing failure and name the offending route.

### Fix

Delete the `10.0.1.0/24` route. Save. Ping works immediately.

### Why this happens

**Longest-prefix match** is a fundamental internet routing rule, not an AWS quirk. Every router on earth works this way. The more specific route always wins, regardless of the order rules appear in the table.

```
10.0.0.0/16   → 65,536 addresses → less specific → lower priority
10.0.1.0/24   →    256 addresses → more specific → higher priority
10.0.1.10/32  →      1 address   → most specific → highest priority
```

**Real-world versions of this bug:**
- A `0.0.0.0/0` route pointing at a deleted NAT gateway → the route shows **Blackhole** status and all internet traffic silently dies
- A firewall appliance route that survives after you terminate the appliance
- Overlapping routes from a Transit Gateway attachment fighting with a peering route

**Always check for `Blackhole` status** in route tables. It means the target no longer exists. AWS shows it clearly and people still miss it.

---

## Failure Lab 8 — Missing or Broken VPC Endpoint (SSM Dies)

*Difficulty: ⭐⭐⭐ | Frequency: 🔥🔥🔥🔥*

### Break it

1. **VPC → Endpoints →** select **`vpce-ssmmessages`**
2. **Actions → Delete VPC endpoints** → type `delete` → confirm

### Symptom

- Existing sessions may keep running for a while (already-established connections survive)
- **New** connection attempts fail with:
  > *We weren't able to connect to your instance. Common reasons include: the SSM Agent isn't running, the instance doesn't have the required IAM permissions, or there's no network path to the Systems Manager endpoints.*
- After ~10–30 minutes, Fleet Manager shows **Connection lost**
- Confusingly, the instance may *still show Online* for a while, because the `ssm` endpoint (which handles health check-ins) still exists

### Diagnose

**Step 1 — Get in while you still can.** If you have a session open, don't close it. Run:

```bash
sudo systemctl status amazon-ssm-agent
sudo tail -50 /var/log/amazon/ssm/amazon-ssm-agent.log
```

You'll see repeated errors like:

```
ERROR Failed to create channel: dial tcp: lookup ssmmessages.us-east-1.amazonaws.com: no such host
ERROR Message gateway connection failed
INFO  Retrying in 30 seconds
```

**`no such host`** is the giveaway. DNS can't resolve the endpoint hostname because the private hosted zone that the VPC endpoint created was deleted along with it.

**Step 2 — Test DNS directly:**

```bash
nslookup ssm.us-east-1.amazonaws.com
nslookup ssmmessages.us-east-1.amazonaws.com
nslookup ec2messages.us-east-1.amazonaws.com
```

**Working endpoint** resolves to a private IP inside your VPC:
```
Name:   ssm.us-east-1.amazonaws.com
Address: 10.0.1.47          ← private! this is your endpoint's ENI
```

**Missing endpoint** either fails entirely or resolves to a *public* AWS IP:
```
Address: 52.46.140.15       ← public! and you have no route to the internet
```

That's the diagnosis in one command. Private IP = endpoint working. Public IP or NXDOMAIN = endpoint missing.

**Step 3 — Test connectivity:**
```bash
nc -zv ssmmessages.us-east-1.amazonaws.com 443
Ncat: Connection timed out.
```

**Step 4 — Check the console.** **VPC → Endpoints** — only two are listed. Confirmed.

**If you're locked out entirely,** use EC2 **Instance Console Screenshot** (Actions → Monitor and troubleshoot → Get instance screenshot) or attach the root volume to a working instance to read the logs. But mostly: just recreate the endpoint.

### Fix

Recreate `com.amazonaws.us-east-1.ssmmessages` exactly as in Step 4 of Part A — both subnets, `sg-endpoints`, **Enable DNS name** checked.

Wait for **Available** (2–5 min), then wait another 2–3 minutes for the agent to reconnect. Or reboot the instance to force it.

### Why this happens

**The three endpoints have genuinely different jobs:**

| Endpoint | Job | Symptom if this one is missing |
|----------|-----|-------------------------------|
| `ssm` | Health check-ins, inventory, patch data | Instance never appears in Fleet Manager at all |
| `ssmmessages` | The actual interactive terminal data channel | Shows Online, but Connect fails or dies instantly |
| `ec2messages` | Legacy Run Command channel | Run Command fails; sessions may be flaky |

**How VPC endpoints work under the hood:**

An **Interface Endpoint** creates an **elastic network interface (ENI)** with a private IP inside your subnet. Then it creates a **Route 53 private hosted zone** that overrides DNS for that service's hostname *inside your VPC only*.

```
Without endpoint:  ssm.us-east-1.amazonaws.com → 52.46.140.15 (public)
                   → needs internet gateway or NAT to reach

With endpoint:     ssm.us-east-1.amazonaws.com → 10.0.1.47 (private)
                   → reached via the local route, no internet at all
```

That DNS override is why **"Enable DNS name" must be checked**. If you uncheck it, the endpoint exists, has an ENI, is fully functional — and nothing uses it, because DNS still points at the public IP. Silent, total failure with everything looking green in the console. **This is a top-five AWS gotcha.**

**Interface vs Gateway endpoints (worth knowing):**

| | Interface Endpoint | Gateway Endpoint |
|---|---|---|
| Services | ~100+ (SSM, KMS, ECR, Secrets Manager…) | **S3 and DynamoDB only** |
| How it works | ENI with private IP | Route table entry |
| Cost | ~$7.20/mo per AZ + $0.01/GB | **Free** |
| Security group | Yes, attaches one | No |
| DNS override | Yes | No (uses prefix list) |

Rule of thumb: S3 and DynamoDB → always use the free Gateway endpoint. Everything else → Interface endpoint.

---

## Failure Lab 9 — Endpoint Security Group Blocks 443

*Difficulty: ⭐⭐⭐ | Frequency: 🔥🔥🔥*

This is Lab 8's evil twin. The endpoint exists, is `Available`, DNS resolves perfectly — and nothing works.

### Break it

1. **VPC → Security groups →** `sg-endpoints` → **Edit inbound rules**
2. **Delete** the HTTPS 443 rule. Save.

### Symptom

- Fleet Manager: instances go to **Connection lost** after ~10 minutes
- **VPC → Endpoints:** all three show **Status: Available** ✅
- `nslookup ssm.us-east-1.amazonaws.com` returns the correct **private** IP ✅
- Everything in the console looks perfect
- Nothing works

### Diagnose

**Step 1 — DNS is fine, so it's not Lab 8.**

```bash
nslookup ssmmessages.us-east-1.amazonaws.com
Address: 10.0.1.62      ← private IP, correct
```

**Step 2 — But TCP fails:**

```bash
nc -zv 10.0.1.62 443
Ncat: Connection timed out.
```

**Step 3 — Apply the pattern.** DNS resolves (so the endpoint exists) + TCP times out (so packets are dropped) = **a firewall is eating traffic between the instance and the endpoint ENI.**

**Step 4 — There are exactly two firewalls in that path:**
1. Instance's SG **outbound** — check `sg-app` outbound. It's `All traffic → 0.0.0.0/0`. Fine.
2. Endpoint's SG **inbound** — check `sg-endpoints` inbound. **Empty.** ← found it

**Step 5 — Agent log confirms it:**
```bash
sudo tail -20 /var/log/amazon/ssm/amazon-ssm-agent.log
```
```
ERROR Failed to connect to message gateway: dial tcp 10.0.1.62:443: i/o timeout
```

Note the difference from Lab 8. Lab 8 said `no such host` (DNS failure). Lab 9 says `i/o timeout` to a **specific private IP** (network failure). The log tells you which lab you're in.

### Fix

Re-add to `sg-endpoints` inbound:

| Type | Protocol | Port | Source |
|------|----------|------|--------|
| HTTPS | TCP | 443 | `10.0.0.0/16` |

Save. Agent reconnects within a few minutes.

### Why this happens

**Interface VPC endpoints have their own security group.** People forget this constantly, because an endpoint doesn't *feel* like a server. But it is one — it's an ENI, it has an IP, it has a firewall.

The traffic path is:

```
EC2 instance                        VPC Endpoint ENI
10.0.1.10                           10.0.1.62
    │                                    │
    │  SG: sg-app                        │  SG: sg-endpoints
    │  outbound must allow 443 ─────────►│  inbound must allow 443
    │                                    │
    └──────────── TCP 443 ───────────────┘
```

**Both** sides must permit it. Most people only check the instance side.

**Best practice for the source of that rule:**

| Source | Security | Verdict |
|--------|----------|---------|
| `0.0.0.0/0` | Bad — though limited by the ENI being VPC-internal | ❌ sloppy |
| `10.0.0.0/16` (VPC CIDR) | Good — anything in your VPC | ✅ recommended default |
| `sg-app`, `sg-db` (SG refs) | Best — only specific tiers | ✅✅ tightest |

For production, use SG references. For a lab, the VPC CIDR is fine and simpler.

---

## Failure Lab 10 — Application Listening on Localhost Only

*Difficulty: ⭐⭐ | Frequency: 🔥🔥🔥🔥 (extremely common with real software)*

This one has **nothing to do with AWS networking** — and that's precisely the lesson.

### Break it

On **instance-b**:
```bash
nc -l 127.0.0.1 3306
```

Make sure `sg-db` correctly allows 3306 from `sg-app`.

### Symptom

From instance-a:
```bash
nc -zv <IP-B> 3306
Ncat: Connection refused.
```

**Refused**, not timeout. And on instance-b, the listener is *definitely running* — you can see it.

Prove it's running, from instance-b itself:
```bash
nc -zv 127.0.0.1 3306
Ncat: Connected to 127.0.0.1:3306.
```

Works locally. Fails remotely. Security group is correct.

### Diagnose

**Step 1 — "Refused" means the network is fine.** Remember the golden rule from Part B. The packet arrived. The OS answered. **Stop looking at AWS entirely.**

**Step 2 — Check what the app is actually bound to.** On instance-b:

```bash
sudo ss -tlnp
```

```
State   Recv-Q  Send-Q   Local Address:Port    Process
LISTEN  0       1        127.0.0.1:3306        users:(("nc",pid=4102,fd=3))
```

**`127.0.0.1:3306`** — there's your answer.

Compare to a correctly-bound service:
```
LISTEN  0       1        0.0.0.0:3306          ← accepts from anywhere
LISTEN  0       128      *:22                  ← also accepts from anywhere
```

**Step 3 — Understand the three binding addresses:**

| Bind address | Accepts connections from | Use case |
|--------------|-------------------------|----------|
| `127.0.0.1` (localhost) | **Only this same machine** | Dev servers, local-only DBs |
| `0.0.0.0` | Any network interface | Normal server config |
| `10.0.2.10` (specific) | Only via that one interface | Multi-homed hosts |

**Step 4 — Confirm with tcpdump** (optional, but this is the definitive proof):

On instance-b:
```bash
sudo dnf install -y tcpdump
sudo tcpdump -i any port 3306 -n
```

From instance-a: `nc -zv <IP-B> 3306`

On instance-b you'll see:
```
10:15:32.123 IP 10.0.1.10.51234 > 10.0.2.10.3306: Flags [S], seq 12345
10:15:32.123 IP 10.0.2.10.3306 > 10.0.1.10.51234: Flags [R.], seq 0, ack 12346
```

`[S]` = SYN (the request arrived!). `[R.]` = RST (the OS actively rejected it).

**This is 100% proof the network delivered the packet.** If a security group were blocking, tcpdump would show *nothing at all* — the packet would never reach the instance.

> **`tcpdump` is the ultimate arbiter.** Packet visible = network fine, app problem. Packet invisible = network problem, don't touch the app.

### Fix

On instance-b, `Ctrl+C` and restart bound to all interfaces:
```bash
nc -l 0.0.0.0 3306
```

From instance-a:
```bash
nc -zv <IP-B> 3306
Ncat: Connected to 10.0.2.10:3306.
```

### Why this happens

Enormous numbers of real applications default to localhost-only binding, on purpose, for safety:

| Software | Config setting | Default |
|----------|---------------|---------|
| MySQL / MariaDB | `bind-address` in `my.cnf` | `127.0.0.1` |
| PostgreSQL | `listen_addresses` in `postgresql.conf` | `localhost` |
| Redis | `bind` in `redis.conf` | `127.0.0.1` |
| Flask (dev) | `app.run(host=...)` | `127.0.0.1` |
| Node/Express | `app.listen(port, host)` | often all, sometimes localhost |
| Jupyter | `--ip` | `localhost` |

**This is a good default.** It means installing a database doesn't accidentally expose it to your whole network on day one. You have to consciously opt in to network exposure — at which point you also (hopefully) think about authentication.

**The lesson that matters most:** don't assume every connection problem is an AWS problem. Roughly half of "AWS networking issues" reported by developers are actually application configuration issues. `Connection refused` tells you which half you're in, instantly, for free.

---

## Failure Lab 11 — SSM Agent Stopped

*Difficulty: ⭐⭐ | Frequency: 🔥🔥*

### Break it

While connected to instance-a via Session Manager:

```bash
sudo systemctl stop amazon-ssm-agent
```

Your session dies within seconds. You have just locked yourself out of a machine with no SSH, no key pair, and no public IP.

### Symptom

- Session terminates immediately
- Fleet Manager: **Connection lost** within a few minutes
- Connect button greyed out
- Everything else about the instance is perfectly healthy: it's Running, 2/2 checks passed, network is fine

### Diagnose

You can't get in to look at the agent. So diagnose from outside:

**Step 1 — Rule out the other causes.** IAM role attached? ✅ Endpoints Available? ✅ Endpoint SG allows 443? ✅ Instance Running with 2/2 checks? ✅

By elimination: it's the agent itself.

**Step 2 — Check EC2 status checks.** Both pass. That confirms the *instance* is healthy and it's a software-level problem, not hardware or OS boot failure.

**Step 3 — Verify from another instance** that the network path is fine, so you know the endpoints aren't the issue:
```bash
# From instance-b:
nc -zv ssmmessages.us-east-1.amazonaws.com 443
Ncat: Connected to 10.0.2.55:443.
```
Network is fine. Definitively the agent.

### Fix — Option 1: Reboot (simplest)

**EC2 → Instance state → Reboot instance.** The agent is enabled at boot, so it restarts. Wait 3–4 minutes.

### Fix — Option 2: EC2 Instance Connect Endpoint (no reboot)

If you can't afford a reboot, create an **EC2 Instance Connect Endpoint** — it provides SSH access to private instances without a public IP or internet gateway.

1. **VPC → Endpoints → Create endpoint → EC2 Instance Connect Endpoint**
2. VPC: `lab-vpc`, Subnet: `lab-subnet-private1`, Security group: one allowing outbound 22 to `sg-app`
3. Add an inbound rule to `sg-app` allowing TCP 22 from the EICE security group
4. Connect via **EC2 → Connect → EC2 Instance Connect** tab
5. Then:
```bash
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
```

### Fix — Option 3: Prevention via User Data

For future instances, add this to **Advanced details → User data** at launch:

```bash
#!/bin/bash
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
```

### Useful agent commands (for when you *can* get in)

```bash
sudo systemctl status amazon-ssm-agent        # is it running?
sudo systemctl restart amazon-ssm-agent       # restart it
sudo systemctl enable amazon-ssm-agent        # start at boot
sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log   # live logs
sudo dnf update -y amazon-ssm-agent           # update it (AL2023)
rpm -qa | grep ssm                            # what version?
```

### Why this happens

The SSM Agent is just a normal Linux service. It can crash, be stopped, run out of memory, or fail after a bad update. And because it *is* your access method, breaking it removes your ability to fix it. That circularity is the whole danger.

**Real-world causes:**
- Someone runs `systemctl stop amazon-ssm-agent` while "cleaning up services"
- The instance runs out of memory and the OOM killer picks the agent
- A hardened AMI ships with the agent disabled
- A configuration-management tool (Ansible/Puppet) has a rule that stops "unnecessary" services
- Disk fills to 100%, agent can't write logs, crashes

**Defense in depth for production:**
1. Enable EC2 detailed monitoring and alarm on status check failures
2. Create an EC2 Instance Connect Endpoint as a backup access path
3. Use SSM State Manager to enforce "agent must be running" on a schedule
4. Keep the agent updated automatically via State Manager
5. Never make a single access method your only access method

---

# The Master Troubleshooting Flowchart

Print this. It handles the vast majority of EC2-to-EC2 connectivity problems.

```
START: instance-a can't reach instance-b
│
├─► Can you even connect to instance-a via SSM?
│   │
│   NO ──► SSM TROUBLESHOOTING (in this exact order):
│   │      1. IAM instance profile attached?          → Lab 1
│   │      2. Role has AmazonSSMManagedInstanceCore?  → Lab 1
│   │      3. All 3 VPC endpoints "Available"?        → Lab 8
│   │      4. Endpoints have "Enable DNS name" ✅?     → Lab 8
│   │      5. Endpoint SG allows 443 from VPC?        → Lab 9
│   │      6. Instance SG allows outbound 443?        → Lab 9
│   │      7. Agent running? (reboot to test)         → Lab 11
│   │      8. Waited a full 5 minutes?                → always do this
│   │
│   YES ─┤
│        │
│        ▼
├─► Run: nc -zv <IP-B> <PORT>. What happened?
│   │
│   ├─► "Connection refused" (instant)
│   │      ✅ NETWORK IS FINE. It's the application.
│   │      • On B: sudo ss -tlnp | grep <PORT>
│   │      • Nothing listed?      → app isn't running
│   │      • Shows 127.0.0.1?     → Lab 10, bind to 0.0.0.0
│   │      • Shows a diff port?   → you're testing the wrong port
│   │
│   ├─► "Connection timed out" (slow, ~2 min)
│   │      ❌ SOMETHING IS DROPPING PACKETS. Check in this order:
│   │      │
│   │      ├─ 1. Same VPC? (compare CIDRs)             → Lab 6
│   │      │
│   │      ├─ 2. Route tables (BOTH subnets):
│   │      │     • Is there a "local" route?
│   │      │     • Any more-specific route stealing it? → Lab 7
│   │      │     • Any route showing "Blackhole"?       → Lab 7
│   │      │
│   │      ├─ 3. Destination SG inbound:
│   │      │     • Rule for the right PORT?             → Lab 3
│   │      │     • Right SOURCE (SG ref or CIDR)?       → Lab 4
│   │      │     • Rule exists at all?                  → Lab 2
│   │      │
│   │      ├─ 4. Source SG outbound:
│   │      │     • Default allow-all still there?
│   │      │     • If customized, does it allow this?
│   │      │
│   │      ├─ 5. NACLs on BOTH subnets:
│   │      │     • Inbound allows the port?
│   │      │     • Outbound allows 1024-65535?          → Lab 5 ⚠️
│   │      │     • Any DENY rule with a lower number?
│   │      │
│   │      └─ 6. Still stuck? Run tcpdump on B:
│   │            sudo tcpdump -i any port <PORT> -n
│   │            • Packets visible?  → network OK, app problem
│   │            • Nothing at all?   → network blocked, keep looking
│   │
│   └─► "No route to host" / "Network is unreachable"
│          ❌ ROUTING or NACL DENY
│          • Check ip route on the instance
│          • Check the AWS route table                  → Lab 7
│          • Check NACL for an explicit DENY            → Lab 5
│
└─► SHORTCUT: run VPC Reachability Analyzer first.
    VPC → Reachability Analyzer → Create and analyze path
    Costs $0.10. Names the exact component that's blocking.
    Often faster than everything above combined.
```

---

# Deep Background: How Packets Actually Move

## The full evaluation order, A → B

```
┌─ ON INSTANCE-A ────────────────────────────────────────────┐
│ 1. App calls connect(10.0.2.10:3306)                       │
│ 2. Kernel picks an ephemeral source port, e.g. 51234       │
│ 3. Kernel route table: which interface?  → enX0            │
│ 4. ARP: MAC address for the gateway 10.0.1.1               │
│ 5. Packet leaves the ENI                                   │
└────────────────────────────────────────────────────────────┘
                        ▼
┌─ AWS NETWORK FABRIC (leaving) ─────────────────────────────┐
│ 6. sg-app OUTBOUND rules evaluated                         │
│    (default: allow all → passes)                           │
│ 7. Route table for subnet-a:                               │
│    longest-prefix match on 10.0.2.10                       │
│    → 10.0.0.0/16 = local  ✅                                │
│ 8. NACL for subnet-a, OUTBOUND, rules in number order      │
│    first match wins; if none, implicit * DENY              │
└────────────────────────────────────────────────────────────┘
                        ▼
        [ AWS internal network — cross-AZ ~0.8ms ]
                        ▼
┌─ AWS NETWORK FABRIC (arriving) ────────────────────────────┐
│ 9. NACL for subnet-b, INBOUND, numbered order              │
│ 10. sg-db INBOUND rules evaluated                          │
│     Is TCP/3306 allowed from sg-app? ✅                     │
└────────────────────────────────────────────────────────────┘
                        ▼
┌─ ON INSTANCE-B ────────────────────────────────────────────┐
│ 11. Packet arrives at the ENI                              │
│ 12. Kernel: is anything LISTENing on 3306?                 │
│     ├─ YES, on 0.0.0.0 → deliver ✅                         │
│     ├─ YES, on 127.0.0.1 only → send RST ❌ (Lab 10)        │
│     └─ NO → send RST ❌ ("connection refused")              │
└────────────────────────────────────────────────────────────┘
                        ▼
              THE REPLY GOES BACK
                        ▼
   sg-db: stateful, reply auto-allowed        ✅ nothing to do
   NACL subnet-b OUTBOUND: STATELESS          ⚠️ must allow 1024-65535
   Route table subnet-b: needs a path to A    ⚠️ Lab 7
   NACL subnet-a INBOUND: STATELESS           ⚠️ must allow 1024-65535
   sg-app: stateful, reply auto-allowed       ✅ nothing to do
```

**Where each lab breaks this chain:**

| Step | Component | Lab |
|------|-----------|-----|
| 6 | Source SG outbound | (rarely broken — default allows all) |
| 7 | Route table out | Lab 7 |
| 8 | NACL out | Lab 5 |
| 9 | NACL in | Lab 5 |
| 10 | Destination SG inbound | Labs 2, 3, 4 |
| 12 | App binding | Lab 10 |
| all | Different VPC | Lab 6 |
| n/a | SSM access | Labs 1, 8, 9, 11 |

## Why "Refused" is fast and "Timeout" is slow

**Refused:** the target sends back a TCP RST packet immediately. Round trip is under a millisecond in-VPC. You get an answer instantly.

**Timeout:** nobody sends anything. Your kernel retransmits the SYN at 1s, 2s, 4s, 8s, 16s, 32s… with exponential backoff, until `tcp_syn_retries` is exhausted. Linux default is 6 retries ≈ **127 seconds**.

You can literally measure the difference:
```bash
time nc -zv <IP-B> 3306
```
- Refused: `real 0m0.012s`
- Timeout: `real 2m7.043s`

**That timing difference alone diagnoses the problem class.** Before you open a single console page, `time` tells you whether you're looking at a firewall or an app.

## Essential command reference

```bash
# --- Reachability ---
ping -c 4 <IP>                    # ICMP; needs an ICMP SG rule
nc -zv <IP> <PORT>                # TCP port test (best single tool)
nc -zvu <IP> <PORT>               # UDP (unreliable — no handshake)
time nc -zv <IP> <PORT>           # measure fast-vs-slow failure
traceroute <IP>                   # often useless in VPC (AWS hides hops)
mtr <IP>                          # continuous traceroute

# --- What's listening locally ---
sudo ss -tlnp                     # TCP listeners + process
sudo ss -ulnp                     # UDP listeners
sudo ss -tnp                      # active connections
sudo lsof -i :3306                # what owns this port

# --- Packet capture (the ultimate truth) ---
sudo tcpdump -i any port 3306 -n
sudo tcpdump -i any host 10.0.1.10 -n -vv
sudo tcpdump -i any icmp -n

# --- DNS ---
nslookup ssm.us-east-1.amazonaws.com
dig +short ssm.us-east-1.amazonaws.com
resolvectl status                 # what resolver am I using?

# --- Local routing ---
ip route
ip addr show
cat /proc/sys/net/ipv4/ip_local_port_range

# --- Instance identity (IMDSv2) ---
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id
curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/security-groups
curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/network/interfaces/macs/

# --- SSM agent ---
sudo systemctl status amazon-ssm-agent
sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log
```

---

# Best Practices

## Security groups

✅ **Do:**
- Reference other security groups instead of IP ranges for internal traffic
- Give every rule a description (the field exists; use it)
- Name groups by function: `sg-web-tier`, `sg-app-tier`, `sg-db-tier`
- Keep rules minimal — one port per rule, specific sources
- Rely on the default allow-all outbound unless you have a compliance requirement

❌ **Don't:**
- Use `0.0.0.0/0` as a source for anything except public HTTP/HTTPS
- Open port 22 to the world (use SSM instead — that's this whole tutorial)
- Use the `default` security group for anything real
- Create one giant SG shared by every instance
- Assume the rule limit is infinite (60 inbound + 60 outbound per SG; 5 SGs per ENI by default)

## Network ACLs

✅ **Do:**
- Leave them at default allow-all unless you have a specific reason
- Number rules in increments of 100 so you can insert later
- **Always** allow ephemeral ports 1024–65535 outbound if you customize
- Document why every custom NACL exists

❌ **Don't:**
- Use NACLs as your primary firewall (that's what SGs are for)
- Forget they're stateless — this is the #1 NACL bug, by a mile
- Create rules with tiny gaps (`100, 101, 102`) — you'll regret it

## SSM

✅ **Do:**
- Use Session Manager instead of SSH, always, in new builds
- Create all three VPC endpoints for private subnets
- Enable session logging to S3 or CloudWatch for audit trails
- Use IAM policies to control who can connect to which instances (tag-based)
- Keep the agent updated via SSM State Manager
- Set up an EC2 Instance Connect Endpoint as a break-glass backup

❌ **Don't:**
- Rely on a NAT gateway for SSM in private subnets (endpoints are cheaper and more secure)
- Forget the IAM instance profile — it's the #1 failure
- Uncheck "Enable DNS name" on endpoints
- Stop the agent while you're connected through it

## Subnets and VPC design

✅ **Do:**
- Use `/24` subnets as a default — 251 usable IPs is enough for most tiers
- Spread across at least 2 AZs for availability
- Leave room to grow: `10.0.0.0/16` gives you 256 `/24` subnets
- Plan CIDRs before you build, especially if peering is in your future
- Tag everything with Environment, Owner, and Project

❌ **Don't:**
- Overlap CIDRs between VPCs you may want to peer someday
- Use `10.0.0.0/8` for a VPC (it's the max size and blocks all future peering with anything using 10.x)
- Put everything in one AZ
- Put databases in public subnets

## Troubleshooting method

✅ **Do:**
- Change **one thing at a time**, then retest
- Use Reachability Analyzer first — $0.10 beats 30 minutes of clicking
- Learn the refused-vs-timeout distinction cold
- Enable VPC Flow Logs before you need them
- Capture a known-good baseline while things are working

❌ **Don't:**
- Change five things and then test
- Assume it's AWS's fault (it's usually a config you own)
- Skip the 5-minute wait for SSM propagation
- Debug the application when you're seeing a timeout

---

# Pros and Cons of Your Options

## Access method: SSM vs SSH vs EC2 Instance Connect

| | Session Manager | Traditional SSH | EC2 Instance Connect Endpoint |
|---|---|---|---|
| **Pros** | No open ports, no keys, IAM-controlled, fully audited in CloudTrail, works in private subnets, session recording | Universal, works anywhere, supports SCP/tunneling, no AWS dependency, familiar | No public IP needed, uses real SSH (so SCP/tunnels work), no keys to distribute |
| **Cons** | AWS-only, needs agent + IAM + endpoints, browser terminal is clunky, file transfer is awkward | Key management is a nightmare, port 22 is the most-attacked port on the internet, no built-in audit, keys get shared | Extra cost, still needs SSH keys, newer/less documented |
| **Cost** | Free (endpoints ~$22/mo if private) | Free | ~$3.60/mo |
| **Use when** | Default for all new builds | Legacy systems, non-AWS, need SCP | You need real SSH into private subnets |

## Private connectivity: VPC endpoints vs NAT gateway

| | VPC Interface Endpoints | NAT Gateway |
|---|---|---|
| **Pros** | Traffic never leaves the AWS network, per-service SG control, no internet exposure at all, cheaper for a few services | One resource covers all internet traffic, simple, works for `dnf update` and any external API |
| **Cons** | ~$7.20/mo **each, per AZ** — adds up fast, one per service, DNS gotchas | ~$32/mo + $0.045/GB, traffic traverses the internet edge, no per-service control |
| **Cost (3 services, 2 AZ)** | ~$43/mo | ~$32/mo + data |
| **Use when** | Security-sensitive, few AWS services needed, compliance requires no internet path | Instances genuinely need general internet access (package updates, third-party APIs) |

> **Real-world answer:** many production VPCs use both. Endpoints for AWS services (S3, DynamoDB gateway endpoints are free — always use them), NAT for general internet.

## VPC-to-VPC: Peering vs Transit Gateway vs PrivateLink

| | VPC Peering | Transit Gateway | PrivateLink |
|---|---|---|---|
| **Pros** | Free (data transfer only), simple, low latency, cross-account and cross-region | Central hub, transitive routing, scales to thousands of VPCs, supports VPN/DX | Exposes one service not a whole network, no CIDR overlap issues, one-way by design |
| **Cons** | **Not transitive**, mesh explodes at scale (n×(n−1)/2), CIDRs must not overlap, 125 peer limit | ~$36/mo per attachment + $0.02/GB, more complex, another thing to learn | ~$7.20/mo per endpoint + data, service-level only, requires an NLB on the provider side |
| **Use when** | 2–5 VPCs, simple needs | 5+ VPCs, hybrid networking, central control | SaaS-style service exposure, third-party access, overlapping CIDRs |

## Subnet sizing

| Size | Usable IPs | Pros | Cons |
|------|-----------|------|------|
| `/28` | 11 | Tiny footprint, great for endpoints/NAT | Runs out fast; ENIs, containers, and load balancers eat IPs |
| `/24` | 251 | **Sweet spot for most tiers**, easy math | Might be tight for large EKS clusters |
| `/20` | 4,091 | Room for containers and autoscaling | Wastes address space if you need many subnets |
| `/16` | 65,531 | Massive | Uses your entire VPC in one subnet — almost always wrong |

> **EKS warning:** with the VPC CNI, every pod gets a real VPC IP. A `/24` subnet with 251 IPs can be exhausted by a few dozen pods. For Kubernetes, size up to `/20` or use secondary CIDRs.

## ICMP: allow or not?

| | Allow ICMP | Block ICMP |
|---|---|---|
| **Pros** | `ping` works, troubleshooting is dramatically easier, **Path MTU Discovery works** | Slightly smaller attack surface, hides hosts from casual scans |
| **Cons** | Enables host discovery by an attacker already inside your VPC | Breaks ping, and **breaks PMTUD which can cause bizarre hanging connections for large packets** |

> **Recommendation:** allow ICMP *within* your VPC (source = your VPC CIDR or an SG reference). Block it from the internet. The troubleshooting value inside your own network far outweighs the risk, and blocking ICMP Type 3 Code 4 specifically causes genuinely awful, hard-to-diagnose MTU black holes.

---

# Cleanup (Do Not Skip This)

VPC endpoints bill hourly whether you use them or not. Three endpoints left running for a month is roughly **$22**. Do this now.

**Delete in this order** (dependencies matter):

1. **EC2 → Instances** → select `instance-a`, `instance-b`, `instance-c` → **Instance state → Terminate instance**. Wait for `Terminated`.
2. **VPC → Endpoints** → select all → **Actions → Delete VPC endpoints**
3. **VPC → Peering connections** → delete `lab-to-other` (if created)
4. **VPC → Network ACLs** → delete `nacl-broken` (if it still exists)
5. **CloudWatch → Log groups** → delete `vpc-flow-logs` (if created)
6. **VPC → Your VPCs** → select `lab-vpc` → **Actions → Delete VPC**. This cascades and removes the subnets, route tables, default NACL, and default SG.
7. Repeat for `other-vpc`.
8. **IAM → Roles** → delete `EC2-SSM-Lab-Role` (optional — IAM roles are free)

**Verify you're clean:**
- **Billing → Cost Explorer** → filter to today → confirm nothing is still accruing
- **EC2 → Elastic IPs** → make sure none are unassociated (unattached EIPs bill $3.60/mo)
- **EC2 → Volumes** → confirm no orphaned EBS volumes

> **Common leftover:** if VPC deletion fails, something is still attached. The usual culprits are a lingering ENI from a deleted endpoint or load balancer. Go to **EC2 → Network Interfaces**, filter by your VPC, and delete any that are `available`.

---

# Quick Reference Cheat Sheet

## Symptom → Cause

| Symptom | Most likely cause | Lab |
|---------|------------------|-----|
| `Connection refused` (instant) | App not running / bound to 127.0.0.1 | 10 |
| `Connection timed out` (~2 min) | Security group or NACL dropping packets | 2, 3, 4, 5 |
| `No route to host` | Route table or NACL deny | 6, 7 |
| `Network is unreachable` | Different VPC, no route | 6 |
| Ping fails, TCP works | Missing ICMP rule specifically | 2 |
| TCP works one way only | NACL stateless / missing ephemeral ports | 5 |
| SSM Connect button greyed out | No IAM instance profile | 1 |
| SSM shows Online, Connect fails | `ssmmessages` endpoint missing | 8 |
| SSM never appears at all | `ssm` endpoint or IAM role missing | 1, 8 |
| Endpoints Available but SSM dead | Endpoint SG blocks 443 | 9 |
| SSM worked, then stopped | Agent crashed/stopped | 11 |
| `no such host` in agent log | DNS / endpoint missing | 8 |
| `i/o timeout` to a private IP in agent log | Endpoint SG blocking | 9 |

## Component behavior at a glance

| | Security Group | Network ACL |
|---|---|---|
| Level | Instance (ENI) | Subnet |
| Rules | Allow only | Allow + Deny |
| State | Stateful | **Stateless** |
| Evaluation | All rules, any match = allow | Numbered, first match wins |
| Default new | In: deny all / Out: allow all | In: deny all / Out: deny all |
| Return traffic | Automatic | **You must write it** |
| Can reference SGs | Yes | No |
| Limit | 60 in + 60 out per SG | 20 rules (soft) per direction |

## The three SSM endpoints

```
com.amazonaws.<region>.ssm            → registration, health, inventory
com.amazonaws.<region>.ssmmessages    → the interactive session channel
com.amazonaws.<region>.ec2messages    → Run Command (legacy channel)
```

All three. Both AZs. `sg-endpoints` allowing 443 from your VPC CIDR. **Enable DNS name checked.**

## The one rule to remember

> **`Connection refused` = the network works, fix the app.**
> **`Connection timed out` = the network is blocked, don't touch the app.**

Everything else follows from that.
