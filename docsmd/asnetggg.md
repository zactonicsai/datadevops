# AWS Networking from Zero to Load Balancer — A Learning-Loop Tutorial (AWS CLI Only)

**Who this is for:** Anyone new to AWS networking. Everything is explained simply, like you've never seen a VPC before. Every step uses only the AWS CLI — no console clicking — so what you learn is repeatable and scriptable.

---

## Part 1 — The Learning Loop (and how to use an LLM as your tutor)

A "learning loop" is a simple cycle you repeat until a skill sticks. Instead of reading everything once and forgetting it, you **build small, verify, break it on purpose, and rebuild**. Each pass through the loop makes the mental model stronger.

**The loop:**

1. **LEARN** — Read a short concept (e.g., "what is a subnet?").
2. **BUILD** — Run the CLI commands to create it yourself.
3. **VERIFY** — Prove it works (`curl`, `ping`, `aws ... describe-*`).
4. **BREAK** — Remove one piece (delete a route, close a security group port) and observe the failure.
5. **REBUILD & EXPLAIN** — Fix it, then explain out loud (or to an LLM) *why* it broke.
6. **REPEAT** at the next level of complexity.

**How to use an LLM (like Claude) inside the loop:**

- After each BUILD step, paste your command output and ask: *"Does this look correct? What would break if I deleted X?"*
- In the BREAK step, ask the LLM to quiz you: *"Give me 3 failure scenarios for a private subnet and ask me to diagnose them."*
- In EXPLAIN, teach the LLM: *"I'm going to explain route tables to you — correct anything I get wrong."* Teaching is the strongest memory glue there is.
- Ask for variations: *"Rewrite scenario 2 for two Availability Zones."*

**Pros of the loop method:** deep retention, real debugging skill, confidence.
**Cons:** slower than skimming docs, and you'll pay a few cents in AWS charges while resources exist (always clean up — cleanup section at the end!).

---

## Part 2 — Background: The Pieces, in Plain English

Think of AWS networking like a **gated neighborhood**:

| AWS Term | Neighborhood Analogy | What it really is |
|---|---|---|
| **VPC** | The whole gated neighborhood | Your private network in AWS with an IP range you choose (e.g., `10.0.0.0/16`) |
| **Subnet** | A street inside the neighborhood | A slice of the VPC's IP range, living in ONE Availability Zone |
| **Internet Gateway (IGW)** | The neighborhood's main gate | Lets traffic flow between your VPC and the internet |
| **Route Table** | Street signs | Rules that say "traffic going to X goes through door Y" |
| **NAT Gateway** | An outgoing-mail-only mailbox | Lets *private* machines reach out to the internet, but nobody outside can reach in |
| **Security Group (SG)** | A guard at each house's door | A firewall attached to an instance/load balancer; **stateful** (replies are auto-allowed) |
| **Network ACL (NACL)** | A guard at each street entrance | A firewall on the subnet; **stateless** (you must allow replies too). Default = allow all; most teams leave it alone |
| **EC2 instance** | A house | A virtual server |
| **Target Group** | A guest list | The set of instances a load balancer sends traffic to, plus health checks |
| **ALB (Application Load Balancer)** | A receptionist | Receives HTTP/HTTPS traffic and spreads it across healthy targets |

### Public vs. private subnet — the ONE rule to memorize

> A subnet is **public** if (and only if) its route table has a route `0.0.0.0/0 → Internet Gateway`.
> A subnet is **private** if it doesn't. That's it. Nothing else makes it public.

`0.0.0.0/0` means "everywhere on the internet."

### CIDR in 60 seconds

`10.0.0.0/16` = IPs from `10.0.0.0` to `10.0.255.255` (~65k addresses). The `/16` means "the first 16 bits are locked." A `/24` subnet like `10.0.1.0/24` gives 256 addresses (AWS reserves 5 in each subnet, so 251 usable).

### Best-practice mental model (memorize this picture)

```
Internet
   │
[Internet Gateway]
   │
┌──▼──────────────── VPC 10.0.0.0/16 ────────────────┐
│  PUBLIC subnets (10.0.0.0/24, 10.0.1.0/24)          │
│     → ALB lives here, NAT Gateway lives here        │
│  PRIVATE subnets (10.0.10.0/24, 10.0.11.0/24)       │
│     → your app EC2 instances live here              │
│     → outbound internet via NAT Gateway             │
└──────────────────────────────────────────────────────┘
```

**Golden best practices (2025/2026 era):**
1. **Apps in private subnets; only the ALB is public.** Users should never reach an instance directly.
2. **Two Availability Zones minimum** for anything real (ALBs require ≥2 subnets in different AZs).
3. **Security groups reference other security groups**, not IP ranges, for app-to-app rules ("allow traffic *from the ALB's SG*"). This survives IP changes.
4. **Least privilege:** open only the exact ports needed.
5. **Don't SSH — use SSM Session Manager** (no port 22 open at all). If you must SSH, restrict to your own IP `/32`.
6. **NAT Gateway over the old NAT instances** (managed, scales, no patching) — con: ~$0.045/hr + data charges, so delete it when practicing.
7. **Tag everything** so you can find and clean up resources.

---
## Part 3 — LOOP 1 (BUILD FIRST): One Public EC2 Web Server, Step by Step

We start with the simplest working thing: a VPC, one public subnet, one EC2 instance serving a web page. Every later scenario builds on these exact commands.

> **Setup:** You need the AWS CLI v2 installed and configured (`aws configure`) with a user/role that can manage EC2/VPC/ELB. Pick one region and stick to it (examples use `us-east-1`). All commands are Linux/macOS shell; on Windows use WSL or adjust line continuations.

### Step 0 — Helper: save IDs as variables

The CLI returns IDs like `vpc-0abc123...`. We capture them into shell variables so later commands can use them.

### Step 1 — Create the VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=learn-vpc}]' \
  --query 'Vpc.VpcId' --output text)
echo "VPC: $VPC_ID"

# Best practice: enable DNS hostnames so instances get names like ec2-x-x-x-x...
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
```

**Why:** The VPC is your empty neighborhood. `10.0.0.0/16` is a private range with room for many subnets.

### Step 2 — Create a public subnet

```bash
PUB_SUBNET=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.0.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-a}]' \
  --query 'Subnet.SubnetId' --output text)

# Best practice for public subnets: auto-assign public IPs to instances launched here
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET --map-public-ip-on-launch
```

### Step 3 — Internet Gateway (the neighborhood gate)

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=learn-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
```

### Step 4 — Route table: make the subnet actually public

```bash
PUB_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)

# THE rule that makes a subnet public:
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Attach the route table to our subnet
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET
```

**Background:** Every VPC comes with a "main" route table that only routes traffic *inside* the VPC (`10.0.0.0/16 → local`). That local route always exists in every route table and can't be deleted — it's why subnets can always talk to each other by default.

### Step 5 — Security group (the door guard)

```bash
WEB_SG=$(aws ec2 create-security-group \
  --group-name web-sg --description "Allow HTTP from anywhere" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow HTTP (port 80) from the whole internet — fine for this demo web page
aws ec2 authorize-security-group-ingress --group-id $WEB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
```

**Note:** Security groups allow all *outbound* traffic by default, and they're **stateful** — the reply to an allowed request is automatically allowed back. We deliberately did **not** open port 22 (SSH); best practice is SSM Session Manager for shell access.

### Step 6 — Launch the EC2 instance with a tiny web server

```bash
# Get the latest Amazon Linux 2023 AMI (always fetch fresh — AMI IDs change)
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --subnet-id $PUB_SUBNET \
  --security-group-ids $WEB_SG \
  --user-data '#!/bin/bash
dnf install -y httpd
echo "<h1>Hello from $(hostname -f)</h1>" > /var/www/html/index.html
systemctl enable --now httpd' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=web-1}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID
```

**What's user-data?** A script that runs once at first boot. Ours installs Apache and writes a hello page.

### Step 7 — VERIFY

```bash
PUB_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Try: http://$PUB_IP"
curl -s http://$PUB_IP
```

You should see the `<h1>Hello...` page. 🎉 You built: VPC → subnet → IGW → route → SG → instance.

### Step 8 — BREAK it (the most important step!)

```bash
# Break #1: remove the internet route
aws ec2 delete-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0
curl -m 5 http://$PUB_IP   # times out — subnet is now effectively private!

# Fix:
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Break #2: revoke the SG rule
aws ec2 revoke-security-group-ingress --group-id $WEB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
curl -m 5 http://$PUB_IP   # times out — the guard turns everyone away
# Fix:
aws ec2 authorize-security-group-ingress --group-id $WEB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
```

**EXPLAIN step:** Tell your LLM tutor why each break behaved identically from the outside (timeout) but for different reasons (routing vs. filtering). Notice: a missing route kills traffic at the street level; a missing SG rule kills it at the door.

---
## Part 4 — LOOP 2: Private Subnet + NAT Gateway (instance with outbound-only internet)

**Concept:** Real app servers should NOT have public IPs. But they still need *outbound* internet (to download packages, call APIs). A **NAT Gateway** does exactly that: outbound yes, inbound no.

### Build

```bash
# 1) Private subnet in the same AZ
PRIV_SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.10.0/24 --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-a}]' \
  --query 'Subnet.SubnetId' --output text)

# 2) NAT Gateway needs a static public IP (Elastic IP) and must sit in a PUBLIC subnet
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)

NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET \
  --allocation-id $EIP_ALLOC \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=learn-nat}]' \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID   # takes ~2 min

# 3) Private route table: default route goes to the NAT (not the IGW!)
PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=private-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET

# 4) SG for the private app: only allow HTTP from INSIDE the VPC for now
APP_SG=$(aws ec2 create-security-group --group-name app-sg \
  --description "App tier" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 80 --cidr 10.0.0.0/16

# 5) Launch a private instance (note: NO public IP)
APP1_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro \
  --subnet-id $PRIV_SUBNET --security-group-ids $APP_SG \
  --no-associate-public-ip-address \
  --user-data '#!/bin/bash
dnf install -y httpd
echo "<h1>app-1 (private)</h1>" > /var/www/html/index.html
systemctl enable --now httpd' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=app-1}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $APP1_ID
```

### Verify

The instance downloaded and installed Apache — that alone proves outbound internet works through the NAT (the `dnf install` would have failed otherwise). To check from inside without SSH, use SSM Session Manager (requires an instance IAM role with `AmazonSSMManagedInstanceCore` — ask your LLM tutor to walk you through adding it as a side quest).

From the *public* web-1 instance you could `curl http://<app-1-private-ip>` — allowed because the SG permits `10.0.0.0/16`.

From the internet? There is no public IP and no inbound path. Perfect.

### Break & explain

Delete the NAT route (`aws ec2 delete-route --route-table-id $PRIV_RT --destination-cidr-block 0.0.0.0/0`) and reason through: the instance can still talk to everything inside `10.0.0.0/16` (local route), but any internet call now dies. Recreate the route to fix.

**Pros/cons of NAT Gateway:** managed, highly available within its AZ, scales automatically — but it costs money per hour and per GB. Alternatives: *NAT instance* (cheap, but you patch/scale it yourself — mostly legacy) and *VPC endpoints* (free/cheap private tunnels to AWS services like S3 — best practice when your only "internet" need is AWS APIs).

---

## Part 5 — LOOP 3: The Real-World Pattern — Only the Load Balancer Exposed

**Goal architecture (this is what you'll build at almost every job):**

```
Internet → ALB (public subnets, 2 AZs) → Target Group → app instances (private subnets)
```

Nothing but the ALB has any public exposure. App SG accepts traffic **only from the ALB's SG**.

### Step 1 — Second AZ (ALBs require two AZs — availability best practice)

```bash
PUB_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-b}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET_B

PRIV_SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.11.0/24 --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-b}]' \
  --query 'Subnet.SubnetId' --output text)
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET_B
```

*(Production note: you'd normally put a second NAT Gateway in `public-b` and a separate private route table per AZ, so one AZ outage can't kill the other AZ's outbound traffic. We skip it here to save cost.)*

```bash
# A second app instance in AZ b, same user-data pattern
APP2_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro \
  --subnet-id $PRIV_SUBNET_B --security-group-ids $APP_SG \
  --no-associate-public-ip-address \
  --user-data '#!/bin/bash
dnf install -y httpd
echo "<h1>app-2 (private)</h1>" > /var/www/html/index.html
systemctl enable --now httpd' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=app-2}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $APP2_ID
```

### Step 2 — Security groups the RIGHT way (SG-to-SG references)

```bash
# ALB's own SG: internet may reach it on 80
ALB_SG=$(aws ec2 create-security-group --group-name alb-sg \
  --description "Public ALB" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# Tighten the app SG: remove the broad VPC-wide rule...
aws ec2 revoke-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 80 --cidr 10.0.0.0/16

# ...and allow port 80 ONLY from the ALB's security group
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 80 --source-group $ALB_SG
```

**Why this matters:** `--source-group` means "anything wearing the ALB badge may enter." IPs can change; badges don't. This is the single most important SG best practice.

### Step 3 — Target group + register instances

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name app-tg --protocol HTTP --port 80 \
  --vpc-id $VPC_ID --target-type instance \
  --health-check-path / --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn $TG_ARN \
  --targets Id=$APP1_ID Id=$APP2_ID
```

**Background — target types:** `instance` (by EC2 ID, most common), `ip` (for containers/on-prem IPs), `lambda`. Health checks are the ALB's heartbeat: fail them and the target stops receiving traffic — this is how zero-downtime deploys work.

### Step 4 — Create the ALB + listener

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name learn-alb --type application --scheme internet-facing \
  --subnets $PUB_SUBNET $PUB_SUBNET_B \
  --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

aws elbv2 wait load-balancer-available --load-balancer-arns $ALB_ARN
```

**Listener = "on port 80, forward to this target group."** In production you'd add an HTTPS (443) listener with an ACM certificate and make the port-80 listener a redirect to HTTPS — best practice.

### Step 5 — VERIFY

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

# Wait for targets to pass health checks, then:
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealth.State}'

for i in 1 2 3 4; do curl -s http://$ALB_DNS; done
# You should see responses alternate between app-1 and app-2 — that's load balancing!
```

### Break & explain (great LLM quiz material)

- Stop httpd on app-1 (via SSM) → watch `describe-target-health` flip it to `unhealthy` → all traffic flows to app-2 only. That's self-healing routing.
- Revoke the SG-to-SG rule → targets go unhealthy even though the servers are fine. Lesson: "unhealthy" often means *the health check can't reach you*, not "the app crashed."

---

## Part 6 — LOOP 4: App-to-App with Only an INTERNAL Load Balancer Exposed

**Scenario:** Service A (e.g., a web tier) must call Service B (e.g., an API tier). Nobody outside the VPC should ever reach Service B — not even through the public ALB. The pattern: an **internal ALB** in the *private* subnets.

```bash
# Service B: its own SG + instance in a private subnet
SVCB_SG=$(aws ec2 create-security-group --group-name svcb-sg \
  --description "Service B API tier" --vpc-id $VPC_ID --query 'GroupId' --output text)

SVCB_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro \
  --subnet-id $PRIV_SUBNET --security-group-ids $SVCB_SG \
  --no-associate-public-ip-address \
  --user-data '#!/bin/bash
dnf install -y httpd
echo "{\"service\":\"B\",\"status\":\"ok\"}" > /var/www/html/index.html
systemctl enable --now httpd' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=svc-b-1}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids $SVCB_ID

# Internal ALB gets its own SG, allowing traffic ONLY from Service A's SG (our APP_SG)
IALB_SG=$(aws ec2 create-security-group --group-name internal-alb-sg \
  --description "Internal ALB for Service B" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $IALB_SG \
  --protocol tcp --port 80 --source-group $APP_SG

# Service B accepts traffic ONLY from the internal ALB
aws ec2 authorize-security-group-ingress --group-id $SVCB_SG \
  --protocol tcp --port 80 --source-group $IALB_SG

# Target group + INTERNAL load balancer (note --scheme internal, PRIVATE subnets)
TGB_ARN=$(aws elbv2 create-target-group --name svcb-tg \
  --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 register-targets --target-group-arn $TGB_ARN --targets Id=$SVCB_ID

IALB_ARN=$(aws elbv2 create-load-balancer --name svcb-internal-alb \
  --type application --scheme internal \
  --subnets $PRIV_SUBNET $PRIV_SUBNET_B \
  --security-groups $IALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws elbv2 create-listener --load-balancer-arn $IALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TGB_ARN
```

**Verify:** From an app-tier instance (SSM session): `curl http://<internal-alb-dns>` returns Service B's JSON. From your laptop: the internal ALB's DNS resolves to *private* IPs — unreachable. Exactly what we wanted.

**The full chain you've now built — read it out loud:**

```
Internet → public ALB (ALB_SG) → app tier (APP_SG, allows only ALB_SG)
        → internal ALB (IALB_SG, allows only APP_SG) → Service B (SVCB_SG, allows only IALB_SG)
```

Every arrow is enforced by an SG-to-SG rule. This chain-of-badges design is the heart of AWS network security.

**Pros/cons vs. alternatives for app-to-app:**

| Option | Pros | Cons |
|---|---|---|
| Internal ALB (this loop) | Health checks, scaling, path routing, one stable DNS name | Hourly + per-request cost |
| Direct SG-to-SG calls (no LB) | Free, simple | No load spreading/health checks; callers must track instance IPs |
| Cloud Map / service discovery | DNS-based, great for ECS | More moving parts |
| PrivateLink (VPC endpoints) | Cross-VPC/cross-account, very locked down | Setup complexity; NLB required in provider VPC |

---

## Part 7 — More Scenarios to Repeat the Loop On (simple → complex)

1. **Solo public instance** (Loop 1) — the "hello world."
2. **Private instance + NAT** (Loop 2) — outbound-only.
3. **Public ALB → private fleet** (Loop 3) — the standard web app.
4. **App→app via internal ALB** (Loop 4) — microservice style.
5. **Add HTTPS:** request a free cert with ACM, add a 443 listener, redirect 80→443. Ask your LLM: *"Give me the `aws acm request-certificate` and `create-listener` commands with a redirect action."*
6. **Path-based routing:** one ALB, `create-rule` sending `/api/*` to one target group and `/*` to another.
7. **Auto Scaling Group** as the target instead of hand-registered instances — instances join/leave the target group automatically.
8. **Three-tier:** add a database subnet pair (e.g., `10.0.20.0/24`, `10.0.21.0/24`) with NO internet route at all; DB SG allows 3306/5432 only from the app SG.
9. **VPC endpoints:** add an S3 gateway endpoint so private instances reach S3 without the NAT — cheaper and more secure.
10. **Two VPCs:** peering vs. Transit Gateway vs. PrivateLink — the multi-VPC graduation exam.

For each: BUILD → VERIFY → BREAK → EXPLAIN to your LLM.

---

## Part 8 — Quick Reference: "Why can't I reach my instance?" Debug Checklist

Work top-down; this ordering resolves ~95% of cases:

1. Instance running & passed both status checks? `aws ec2 describe-instance-status`
2. Does it have the IP you think (public vs private)? `describe-instances`
3. **Subnet's route table** — is there a `0.0.0.0/0` route to the right thing (IGW for public, NAT for private-outbound)? `describe-route-tables`
4. **Security group** — inbound rule for that port *from that source*? Remember SGs are stateful.
5. **NACL** — if someone customized it, check BOTH inbound and outbound (stateless!). `describe-network-acls`
6. Is the app actually listening? (`ss -tlnp` via SSM)
7. Behind an ALB: `describe-target-health` — health checks come *from the ALB's SG/IPs*, so the target SG must allow the ALB SG.

---

## Part 8.5 — Troubleshooting: Service A Can't Reach Service B

This is the #1 real-world networking ticket. Use this exact order — each step rules out one layer, from "is it even running" up to "is AWS silently dropping packets."

### Step 1 — Confirm Service B is actually listening

Before blaming the network, check the app. On the Service B instance (SSM session):

```bash
ss -tlnp | grep :80        # is anything listening on the port?
curl -s http://localhost/  # does the app answer ITSELF?
```

If localhost fails, it's an app problem, not networking. Stop here and fix the service.

### Step 2 — Test from Service A and read the failure type

The *kind* of failure tells you *where* it broke:

```bash
curl -v -m 5 http://<target-dns-or-ip>/
```

| Symptom | Most likely layer |
|---|---|
| **Timeout** (hangs, then dies) | Security group, NACL, or routing — packets silently dropped |
| **Connection refused** (instant) | Packets ARRIVED, but nothing listening on that port — wrong port, app down, or wrong target |
| **Could not resolve host** | DNS problem — wrong name, or internal ALB DNS used from outside the VPC |
| **503 from an ALB** | ALB reached, but it has **no healthy targets** — check target health |
| **502 from an ALB** | Target answered but broke the connection — app crash/misbehavior, or wrong protocol (HTTPS vs HTTP) on the target |

Memorize the first two: **timeout = firewall/route, refused = port/app.** That one distinction solves half of all tickets.

### Step 3 — Check the security group chain (the usual culprit)

For every hop, the *receiver's* SG must allow the *sender's* SG. In our Loop 4 chain that means three rules:

```bash
# Does the internal ALB's SG allow Service A's SG on port 80?
aws ec2 describe-security-groups --group-ids $IALB_SG \
  --query 'SecurityGroups[0].IpPermissions'

# Does Service B's SG allow the internal ALB's SG?
aws ec2 describe-security-groups --group-ids $SVCB_SG \
  --query 'SecurityGroups[0].IpPermissions'
```

Classic mistakes to look for:
- Rule allows a **CIDR** that used to match, but the caller's IP changed (this is why SG-to-SG references are best practice).
- Rule references the **wrong SG** — e.g., Service B allows Service A's SG directly, but traffic actually arrives *from the internal ALB*, so it must allow the **ALB's** SG.
- **Wrong port** — the app moved to 8080 but the rule still says 80.
- Someone added a custom **outbound** rule on the sender's SG (default allows all outbound; if restricted, the sender needs an egress rule to the target too).

### Step 4 — Behind a load balancer? Check target health first

```bash
aws elbv2 describe-target-health --target-group-arn $TGB_ARN \
  --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason,desc:TargetHealth.Description}'
```

The `Reason` field is gold: `Target.Timeout` = SG blocking the health check; `Target.ResponseCodeMismatch` = app returns 404/500 on the health-check path; `Target.NotRegistered` = you forgot `register-targets`. Also verify the health-check path exists (`curl localhost/<health-path>` on the target).

### Step 5 — Same VPC? Different VPC? Check routing accordingly

- **Same VPC:** the `local` route always exists — routing is almost never the issue *inside* one VPC. Skip to NACLs.
- **Different VPCs (peering/Transit Gateway):** BOTH sides need routes to each other's CIDR, and BOTH SGs/NACLs must allow the *other VPC's* CIDR (SG-to-SG references only work across peering in the same region). Check with `aws ec2 describe-route-tables` on both sides. Also confirm the VPC CIDRs don't overlap — overlapping CIDRs silently break peering.

### Step 6 — DNS gotchas

```bash
nslookup <name-you-are-calling>
```

- An **internal ALB's DNS** resolves to private IPs — it only works from inside the VPC (or connected networks). Calling it from your laptop will always fail; that's by design.
- If resolution fails inside the VPC, confirm `enableDnsSupport` and `enableDnsHostnames` are on: `aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport`
- Hard-coded instance IPs go stale after stop/start — another reason to always call through an ALB or DNS name.

### Step 7 — NACLs (only if someone touched them)

Default NACLs allow everything. But if customized, remember they're **stateless**: you need the request allowed inbound on B's subnet AND the *reply* allowed outbound — including the ephemeral port range `1024-65535` for return traffic.

```bash
aws ec2 describe-network-acls \
  --filters Name=association.subnet-id,Values=$PRIV_SUBNET \
  --query 'NetworkAcls[].Entries'
```

### Step 8 — Let AWS diagnose it for you: Reachability Analyzer

When you're stuck, this tool traces the path hop-by-hop and names the exact blocking component (a specific SG, NACL, or route table):

```bash
PATH_ID=$(aws ec2 create-network-insights-path \
  --source $APP1_ID --destination $SVCB_ID \
  --protocol tcp --destination-port 80 \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)

ANALYSIS_ID=$(aws ec2 start-network-insights-analysis \
  --network-insights-path-id $PATH_ID \
  --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)

sleep 30
aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids $ANALYSIS_ID \
  --query 'NetworkInsightsAnalyses[0].{reachable:NetworkPathFound,blocker:Explanations[0]}'
```

`NetworkPathFound: false` plus the `Explanations` block = your answer, straight from AWS. (Small per-analysis fee; worth every cent when stuck.)

### Step 9 — See the actual packets: VPC Flow Logs

Flow logs record every accepted/rejected connection attempt — proof of whether traffic arrives and what happens to it:

```bash
aws ec2 create-flow-logs --resource-type VPC --resource-ids $VPC_ID \
  --traffic-type ALL --log-destination-type cloud-watch-logs \
  --log-group-name vpc-flow-debug \
  --deliver-logs-permission-arn <role-arn-with-cloudwatch-perms>
```

Then look for lines ending in `REJECT` with Service B's IP and port. **REJECT in flow logs = SG or NACL said no. No log line at all = traffic never arrived (routing/DNS problem on the sender's side).** That single distinction tells you which half of the path to investigate.

### The 60-second cheat sheet

```
localhost works?  no → fix the app
timeout?          → SG / NACL / route  (start with receiver's SG)
refused?          → wrong port or app not listening
can't resolve?    → DNS / calling internal name from outside
503 via ALB?      → no healthy targets → describe-target-health, read Reason
502 via ALB?      → target broke the connection (crash / HTTP vs HTTPS mismatch)
cross-VPC?        → routes BOTH ways + CIDR rules + no overlap
still stuck?      → Reachability Analyzer, then Flow Logs
```

**BREAK-step practice for this section:** ask your LLM tutor to secretly pick one of these failure causes, describe only the symptom (e.g., "curl times out"), and make you diagnose it question-by-question, twenty-questions style.

---

## Part 9 — CLEAN UP (avoid charges!)

Order matters — dependencies must go first. NAT Gateways and ALBs are the money burners.

```bash
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 delete-load-balancer --load-balancer-arn $IALB_ARN
sleep 60   # let ALBs finish deleting
aws elbv2 delete-target-group --target-group-arn $TG_ARN
aws elbv2 delete-target-group --target-group-arn $TGB_ARN

aws ec2 terminate-instances --instance-ids $INSTANCE_ID $APP1_ID $APP2_ID $SVCB_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID $APP1_ID $APP2_ID $SVCB_ID

aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_ID
aws ec2 release-address --allocation-id $EIP_ALLOC

aws ec2 delete-security-group --group-id $SVCB_SG
aws ec2 delete-security-group --group-id $IALB_SG
aws ec2 delete-security-group --group-id $APP_SG
aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 delete-security-group --group-id $WEB_SG

aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID

aws ec2 delete-subnet --subnet-id $PUB_SUBNET
aws ec2 delete-subnet --subnet-id $PUB_SUBNET_B
aws ec2 delete-subnet --subnet-id $PRIV_SUBNET
aws ec2 delete-subnet --subnet-id $PRIV_SUBNET_B
aws ec2 delete-route-table --route-table-id $PUB_RT
aws ec2 delete-route-table --route-table-id $PRIV_RT
aws ec2 delete-vpc --vpc-id $VPC_ID
```

Double-check nothing is left: `aws ec2 describe-vpcs --filters Name=tag:Name,Values=learn-vpc`

---

## Part 10 — Your Next Learning-Loop Prompt (copy-paste to your LLM)

> "I just completed Loop N of my AWS networking tutorial. Quiz me with 5 scenario questions about [topic], let me answer each one, and correct me. Then give me one 'break it' exercise using AWS CLI commands and ask me to predict the outcome before I run it."

Keep looping. The person who has broken and fixed a VPC ten times understands it better than the person who read about it a hundred times.
