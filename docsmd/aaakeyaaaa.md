# Running Keycloak on AWS: A Complete Beginner-to-Working-System Guide

**What you will build:** A login system (Keycloak) that runs in Docker containers on AWS EC2 servers, pulls its container image from your company's Artifactory, stores all its data in an Amazon RDS PostgreSQL database, sits behind a Load Balancer, and automatically grows and heals itself with an Auto Scaling Group.

**Who this is for:** Someone who has never done this before. Every term is explained. Nothing is assumed.

**How to read this:** Sections 1–2 explain the idea. Section 3 is the checklist before you start. Section 4 is the full click-by-click build with the AWS CLI. Section 5 is the same thing with Terraform. Sections 6–10 are the deep background, the pros and cons, and the best practices. Section 11 is how to safely tear it all down without leaving anything behind that costs money.

---

## Table of Contents

1. [The Big Picture (read this first)](#1-the-big-picture)
2. [What Every Piece Is and Why It's There](#2-what-every-piece-is-and-why-its-there)
3. [Before You Start: Prerequisites](#3-before-you-start-prerequisites)
4. [Part A — Build It With the AWS CLI (step by step)](#4-part-a--build-it-with-the-aws-cli)
5. [Part B — Build It With Terraform (step by step)](#5-part-b--build-it-with-terraform)
6. [Keycloak Configuration Deep Dive](#6-keycloak-configuration-deep-dive)
7. [Testing That Fault Tolerance Actually Works](#7-testing-that-fault-tolerance-actually-works)
8. [Pros and Cons of Every Major Choice](#8-pros-and-cons-of-every-major-choice)
9. [Best Practices Checklist](#9-best-practices-checklist)
10. [Troubleshooting Common Problems](#10-troubleshooting-common-problems)
11. [How to Destroy Everything Safely](#11-how-to-destroy-everything-safely)
12. [Glossary](#12-glossary)

---

## 1. The Big Picture

### 1.1 The problem we're solving

Imagine your school has 30 different websites: the grade portal, the library system, the cafeteria account, the sports sign-up, and so on. Without a shared login system, every one of those sites needs its own username and password list. That is 30 places where passwords can leak, 30 places to add a new student, and 30 places to delete an account when someone leaves.

**Keycloak** solves this. It is one central "bouncer at the door." All 30 websites say to the user: "Go see the bouncer, and come back with a wristband." The bouncer (Keycloak) checks who you are once, hands you a digital wristband (called a **token**), and every website trusts that wristband. This idea is called **Single Sign-On (SSO)**.

### 1.2 The problem *that* creates

If everything depends on the bouncer, and the bouncer goes home sick, **nobody can log into anything**. Keycloak becomes what engineers call a **single point of failure** — one broken thing that breaks everything.

So the entire rest of this guide is really about one question: **how do we make sure the bouncer is never sick, never overwhelmed, and never forgets who you are?**

The answer has three parts:

1. **Run several bouncers, not one.** (Auto Scaling Group)
2. **Put a receptionist in front of them who sends visitors to whichever bouncer is healthy.** (Application Load Balancer)
3. **Keep the guest list in a separate, backed-up, duplicated filing cabinet that no single bouncer owns.** (Amazon RDS PostgreSQL, Multi-AZ)

### 1.3 The architecture diagram

```
                            THE INTERNET
                                 |
                                 | (users' browsers, HTTPS port 443)
                                 v
                    +------------------------------+
                    |   Route 53 (DNS)             |   "auth.example.com"
                    |   points the name at the ALB |
                    +------------------------------+
                                 |
                                 v
        +===========================================================+
        |  AWS REGION  (e.g. us-east-1)                             |
        |  VPC  10.0.0.0/16   <- your own private network           |
        |                                                           |
        |   +--- Availability Zone A ----+  +-- Availability Zone B -+
        |   |                            |  |                        |
        |   | PUBLIC SUBNET 10.0.1.0/24  |  | PUBLIC SUBNET 10.0.2.0/24
        |   |   [ ALB node ]  <----------+--+--> [ ALB node ]        |
        |   |   [ NAT Gateway ]          |  |                        |
        |   |                            |  |                        |
        |   | PRIVATE SUBNET 10.0.11.0/24|  | PRIVATE SUBNET 10.0.12.0/24
        |   |   [ EC2 + Docker ]         |  |   [ EC2 + Docker ]     |
        |   |    Keycloak container      |  |    Keycloak container  |
        |   |         |                  |  |         |              |
        |   | DB SUBNET 10.0.21.0/24     |  | DB SUBNET 10.0.22.0/24 |
        |   |   [ RDS PRIMARY ] =========+==+=> [ RDS STANDBY ]      |
        |   |         (synchronous replication) |                    |
        |   +----------------------------+  +------------------------+
        |                                                           |
        |   Auto Scaling Group spans BOTH zones, min 2 / max 6      |
        +===========================================================+
                                 |
                                 | (EC2 pulls image on boot, via NAT)
                                 v
                    +------------------------------+
                    |  JFrog Artifactory           |
                    |  your-company.jfrog.io       |
                    |  docker-local/keycloak:26.x  |
                    +------------------------------+
```

### 1.4 The story of one request, start to finish

This is the single most useful thing to understand. Follow it slowly.

1. A student types `https://auth.example.com` into their browser.
2. **Route 53** (AWS's phone book) translates that name into the IP address of the load balancer.
3. The **Application Load Balancer (ALB)** answers. It holds the TLS certificate, so it does the encryption/decryption (this is called **TLS termination**). Everything from here inward travels on the private network.
4. The ALB looks at its list of healthy Keycloak servers and picks one. It forwards the request over plain HTTP on port 8080, but it adds special headers (`X-Forwarded-For`, `X-Forwarded-Proto: https`) that say "hey, the original user came in over HTTPS from this IP."
5. The **EC2 instance** receives it. On that instance, a **Docker container** running the Keycloak image is listening on port 8080.
6. **Keycloak** needs to check the username and password. It doesn't store them locally — it opens a connection to **RDS PostgreSQL** and asks the database.
7. RDS answers. Keycloak creates a signed token, and the answer travels back out: Keycloak → ALB → browser.
8. If, at step 5, that EC2 instance had been on fire, the ALB's **health check** would already have marked it "unhealthy" and step 4 would have picked a different one. The student would never notice.

**That last sentence is the whole point of this guide.**

### 1.5 Why the pieces are split up this way

A very common beginner instinct is: "Why not just put Keycloak and Postgres on one EC2 server? It's simpler!"

Here is why we don't:

| If you combine... | What breaks |
|---|---|
| App + database on one server | The server dies → your **data** dies with it, not just the app. You cannot add a second app server, because the second one wouldn't see the first one's database. |
| One server, no load balancer | Any reboot, patch, or crash = total outage. No way to deploy a new version without downtime. |
| Everything in one Availability Zone | AWS data centers do occasionally have problems. One zone failing takes you down entirely. |
| Servers in public subnets with public IPs | Every server is directly reachable from the internet. Much bigger attack surface. |

The rule to remember: **separate the things that hold state (the database) from the things that don't (the app servers), and make the stateless things disposable.**

An EC2 instance in this design is **cattle, not a pet**. If one behaves badly, you don't nurse it back to health — you destroy it and let the Auto Scaling Group build a fresh one from the same recipe. That is only possible because *nothing important lives on the instance*.

---

## 2. What Every Piece Is and Why It's There

### 2.1 VPC — Virtual Private Cloud

**What it is:** Your own private, walled-off network inside AWS. You choose the IP address range (we'll use `10.0.0.0/16`, which gives you about 65,000 addresses).

**Middle-school version:** AWS is a giant apartment building. A VPC is *your* apartment. Other tenants can't walk into it.

**Why we need it:** Everything else lives inside it. It's the container for the whole design.

### 2.2 Subnets — and the critical public/private split

A **subnet** is a slice of your VPC that lives in exactly one Availability Zone.

- A **public subnet** has a route to an **Internet Gateway**. Things in it can be reached from the internet.
- A **private subnet** has no such route. Things in it *cannot* be reached from the internet directly.

We create **six** subnets — three tiers × two zones:

| Tier | Zone A | Zone B | What lives here | Reachable from internet? |
|---|---|---|---|---|
| Public | 10.0.1.0/24 | 10.0.2.0/24 | Load balancer, NAT Gateway | Yes |
| Private (app) | 10.0.11.0/24 | 10.0.12.0/24 | EC2 running Keycloak | No (inbound) |
| Private (data) | 10.0.21.0/24 | 10.0.22.0/24 | RDS PostgreSQL | No |

**Why three tiers?** Defense in depth. Even if an attacker somehow got into the load balancer, they'd still have to get through a second wall to reach the app servers, and a third to reach the database.

### 2.3 Availability Zones (AZs)

An **Availability Zone** is a physically separate data center (or cluster of them) within one AWS region. Separate power, separate cooling, separate network. They're close enough together that talking between them is fast (a couple of milliseconds), but far enough apart that a flood, fire, or power failure won't hit both.

**Why it matters:** Putting all your servers in one AZ is like keeping your only copy of your homework and your only backup on the same laptop. We spread across **at least two** AZs. Three is better if your budget allows.

### 2.4 Internet Gateway and NAT Gateway

- **Internet Gateway (IGW):** the front door. Lets traffic flow *in and out* of the VPC. Attached to the VPC, used by public subnets.
- **NAT Gateway:** a one-way door. Lets things in private subnets reach *out* to the internet (to download the Docker image from Artifactory, to get OS security patches) while blocking anything from reaching *in*.

**Middle-school version:** A NAT Gateway is like a window you can shout out of but nobody can climb in through.

⚠️ **Cost warning:** NAT Gateways are one of the most common surprise bills in AWS. Roughly **$32–$45/month each**, plus about **$0.045 per GB** of data processed. Two of them (one per AZ, for high availability) is ~$70–90/month before any traffic. Section 8 covers cheaper alternatives.

### 2.5 Security Groups

A **security group** is a firewall attached to a resource. It is **stateful**, meaning if you allow traffic in, the reply is automatically allowed back out. You only write "allow" rules — everything not allowed is denied.

The best practice, which we follow throughout, is **security group chaining**: instead of saying "allow port 5432 from IP range 10.0.11.0/24", you say "allow port 5432 **from the app servers' security group**." This way, if you ever change your IP layout, the rules still work, and no one can accidentally get database access by launching a server in the right subnet.

Our three groups:

```
sg-alb   : IN  443 from 0.0.0.0/0        (the whole internet)
           IN  80  from 0.0.0.0/0        (only to redirect to 443)
           OUT everything

sg-app   : IN  8080 from sg-alb ONLY     <-- chained
           IN  9000 from sg-alb ONLY     (health check port)
           IN  7800 from sg-app ONLY     (Keycloak cluster chatter)
           OUT everything (needs to reach Artifactory + RDS)

sg-rds   : IN  5432 from sg-app ONLY     <-- chained
           OUT nothing needed
```

Notice that `sg-rds` allows connections from **nothing on the internet**. The database is unreachable from outside. That is exactly right.

### 2.6 EC2 — Elastic Compute Cloud

**What it is:** A virtual computer you rent by the second.

**Why we use it here:** It's the simplest place to run a Docker container if your team already knows Linux. (Section 8 compares this against ECS, EKS, and Fargate — for many teams those are actually better, and it's worth reading before you commit.)

Key EC2 concepts you'll meet:

- **AMI (Amazon Machine Image):** the disk template the instance boots from. We'll use Amazon Linux 2023.
- **Instance type:** the size. `t3.medium` (2 vCPU, 4 GB RAM) is a reasonable starting point for Keycloak. Anything smaller than 2 GB RAM will struggle because Keycloak runs on a Java Virtual Machine.
- **User data:** a shell script that runs automatically the first time the instance boots. This is where we install Docker and start Keycloak.
- **Instance profile / IAM role:** how the instance proves its identity to other AWS services *without* you hard-coding any passwords on it.

### 2.7 Docker

**What it is:** A way to package an application together with everything it needs — the right Java version, the right libraries, the right config — into one sealed box called an **image**. A running copy of that image is a **container**.

**Middle-school version:** A shipping container. It doesn't matter whether it's on a truck, a train, or a boat — the contents and how you load it are identical. Docker does that for software.

**Why it matters here:** Every one of your EC2 instances runs the *exact same bytes*. There is no "well, it works on server 3 but not server 4." That predictability is what makes autoscaling safe.

### 2.8 JFrog Artifactory

**What it is:** A private warehouse for software packages, including Docker images. Your company runs one (or pays JFrog to run it) at an address like `mycompany.jfrog.io`.

**Why not just use the public image from Quay.io or Docker Hub?**

| Reason | Explanation |
|---|---|
| **Scanning** | Artifactory (with Xray) scans images for known vulnerabilities before you're allowed to use them. |
| **Availability** | If Docker Hub has an outage or rate-limits you, your deployments still work. |
| **Immutability** | You control the tags. Nobody can silently re-push a different image under the same name. |
| **Auditability** | You can prove exactly which image version was running on which day — often a compliance requirement. |
| **Customization** | Your image may include your company's TLS certificates, custom themes, or provider JARs baked in. |

The image path will look like:
```
mycompany.jfrog.io/docker-local/keycloak:26.4.0
```

To pull it, EC2 must first run `docker login` with credentials. **Those credentials must never be typed into the user-data script**, because user data is readable by anything running on the instance. We store them in **AWS Secrets Manager** and let the instance fetch them using its IAM role.

### 2.9 Amazon RDS for PostgreSQL

**What it is:** A managed PostgreSQL database. AWS handles the server, the operating system, the backups, the patching, and the failover. You get a connection endpoint.

**What Keycloak stores in it:** users, groups, roles, realms, clients, credentials (hashed), sessions (in newer versions, persistent sessions live here too), and configuration. Essentially **everything that matters**.

**Multi-AZ:** This is the setting that makes it fault tolerant. AWS keeps a hot standby copy in a different Availability Zone, kept in sync **synchronously** (every write must land on both before it's confirmed). If the primary dies, AWS flips the DNS name to the standby, usually in **60–120 seconds**, with no data loss.

**Important:** In a standard Multi-AZ deployment, the standby is *not* readable. You don't get extra performance from it — you get **survivability**. That's what you're paying for.

### 2.10 Application Load Balancer (ALB)

**What it is:** A managed traffic cop that sits in front of your servers.

What it does for us:

| Job | Detail |
|---|---|
| **Spreads load** | Sends each request to a different healthy instance (round-robin by default). |
| **Health checks** | Every 30 seconds it calls a URL on each instance. Fails → that instance stops receiving traffic. |
| **TLS termination** | Holds your HTTPS certificate (from AWS Certificate Manager, which is free). |
| **HTTP → HTTPS redirect** | Anyone who types `http://` gets bounced to `https://`. |
| **Sticky sessions** | Optional: keeps one user on one server using a cookie. |
| **Cross-zone** | It has nodes in both AZs and can send traffic to either. |

The ALB itself is **highly available by design** — AWS runs it redundantly across your chosen subnets. You don't have to make the load balancer fault tolerant; that's AWS's job.

### 2.11 Auto Scaling Group (ASG)

**What it is:** A rule that says "always keep between N and M copies of this server running, and if one dies, replace it."

Three numbers define it:
- **Minimum:** never go below this. **Set this to 2**, never 1. With 1, a failure means an outage while a replacement boots (2–4 minutes).
- **Desired:** how many right now. The ASG adjusts this automatically.
- **Maximum:** never go above this. Protects you from a runaway bill.

Two behaviors it gives us:

1. **Self-healing.** If we set the ASG's health check type to `ELB`, the ASG trusts the load balancer's opinion. If the ALB says an instance is unhealthy, the ASG terminates it and launches a fresh one from the launch template. **Nobody has to be paged at 3am.**
2. **Scaling.** A **target tracking policy** says "keep average CPU at 60%." Traffic doubles → CPU climbs → ASG adds instances. Traffic drops at night → ASG removes them and you stop paying.

### 2.12 The supporting cast

- **AWS Secrets Manager:** encrypted storage for the database password and the Artifactory credentials. Supports automatic rotation. Costs about $0.40/secret/month.
- **IAM role + instance profile:** lets the EC2 instance read those secrets without any password being stored on disk.
- **AWS Certificate Manager (ACM):** free public TLS certificates that auto-renew, usable on the ALB.
- **CloudWatch:** where logs and metrics go, and where alarms are defined.
- **Route 53:** DNS. Turns `auth.example.com` into the ALB.

---

## 3. Before You Start: Prerequisites

### 3.1 Things you need to have

| # | Requirement | How to check / get it |
|---|---|---|
| 1 | An AWS account you can create resources in | Log into the AWS console |
| 2 | AWS CLI v2 installed | `aws --version` → should say `aws-cli/2.x` |
| 3 | CLI credentials configured | `aws sts get-caller-identity` → should print your account ID |
| 4 | Terraform ≥ 1.6 (for Part B) | `terraform version` |
| 5 | A domain name you control | Needed for a real TLS certificate |
| 6 | An ACM certificate for that domain | Request it in the **same region** as your ALB |
| 7 | Artifactory URL, username, and access token | Ask your platform team. Use a **token**, never your personal password. |
| 8 | The exact Keycloak image path and tag | e.g. `mycompany.jfrog.io/docker-local/keycloak:26.4.0` |
| 9 | An EC2 key pair *or* SSM Session Manager enabled | SSM is strongly preferred — see below |

### 3.2 Verify your access before spending an hour

```bash
# Who am I?
aws sts get-caller-identity

# Which region am I defaulting to?
aws configure get region

# Can I see EC2? (should return an empty list or your instances, not an error)
aws ec2 describe-instances --max-items 1

# Can I see RDS?
aws rds describe-db-instances --max-items 1
```

If any of those return `AccessDenied`, stop and fix permissions first. You need roughly: `AmazonEC2FullAccess`, `AmazonRDSFullAccess`, `ElasticLoadBalancingFullAccess`, `AutoScalingFullAccess`, `SecretsManagerReadWrite`, and IAM permissions to create roles.

### 3.3 A note on SSH keys vs. Session Manager

The old way to get a shell on an EC2 instance is SSH on port 22 with a `.pem` key file. The problems: you have to open port 22 somewhere, you have to manage and rotate key files, and there's no audit trail of who logged in.

The modern way is **AWS Systems Manager Session Manager**. It requires:
- The SSM agent on the instance (pre-installed on Amazon Linux 2023)
- The `AmazonSSMManagedInstanceCore` policy on the instance's IAM role
- Outbound HTTPS from the instance (which we have, via NAT)

Then you connect with:
```bash
aws ssm start-session --target i-0123456789abcdef0
```

**No open port 22. No key files. Every session logged in CloudTrail.** This guide uses SSM. We will not open port 22 at all.

### 3.4 Set up your shell variables

Everything in Part A uses these. Set them once, in one terminal session, and keep that terminal open.

```bash
# ---- EDIT THESE ----
export AWS_REGION="us-east-1"
export PROJECT="keycloak-demo"
export DOMAIN_NAME="auth.example.com"
export ACM_CERT_ARN="arn:aws:acm:us-east-1:111122223333:certificate/aaaa-bbbb-cccc"
export ARTIFACTORY_HOST="mycompany.jfrog.io"
export KC_IMAGE="mycompany.jfrog.io/docker-local/keycloak:26.4.0"
export ARTIFACTORY_USER="svc-keycloak-deploy"
export ARTIFACTORY_TOKEN="paste-your-artifactory-access-token-here"
export DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
export KC_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
# ---- END EDIT ----

export AWS_DEFAULT_REGION="$AWS_REGION"
export AZ_A="${AWS_REGION}a"
export AZ_B="${AWS_REGION}b"

echo "DB password generated: $DB_PASSWORD"
echo "Admin password generated: $KC_ADMIN_PASSWORD"
echo "SAVE THESE SOMEWHERE SAFE NOW — they will also be stored in Secrets Manager."
```

> **Why generate passwords with `openssl` instead of typing one?** Humans pick predictable passwords. Also, a typed password ends up in your shell history file. Note that even this approach leaves the password in the environment; in a real production pipeline you would have Secrets Manager generate it and never see it at all.

---

## 4. Part A — Build It With the AWS CLI

> **Read this before you start.** We build from the outside in: network first, then security, then secrets, then the database, then the load balancer, then finally the servers. This order matters because each piece needs the ID of the piece before it.
>
> Every command below saves its output into a shell variable. **Keep the same terminal open the whole way through.** If you close it, you lose the variables. Step 4.0 shows you how to write them to a file so you can recover.

### 4.0 Save your IDs to a file as you go

```bash
mkdir -p ~/keycloak-build && cd ~/keycloak-build
touch ids.env

# Helper: record a variable to the file AND export it
save() { echo "export $1=\"$2\"" >> ids.env; export "$1=$2"; echo "  $1 = $2"; }

# If you ever lose your terminal, get everything back with:
#   source ~/keycloak-build/ids.env
```

---

### 4.1 Create the VPC

**What this does:** Carves out your private network inside AWS.

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PROJECT}-vpc},{Key=Project,Value=${PROJECT}}]" \
  --query 'Vpc.VpcId' --output text)

save VPC_ID "$VPC_ID"

# Turn on DNS hostnames — REQUIRED for RDS endpoints to resolve
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
```

**Line-by-line:**
- `--cidr-block 10.0.0.0/16` — the address range. The `/16` means the first 16 bits are fixed, so every address from `10.0.0.0` to `10.0.255.255` is yours. That's 65,536 addresses.
- `--tag-specifications` — labels. **Tag everything.** Tags are how you find things later, how you split the bill by team, and how you safely delete only your own resources.
- `--query 'Vpc.VpcId' --output text` — the CLI returns a big JSON blob; this pulls out just the ID so we can put it in a variable.
- `--enable-dns-hostnames` — **do not skip this.** Without it, the RDS endpoint name will not resolve from inside your VPC and Keycloak will fail to connect with a confusing error.

**Why 10.0.0.0/16?** It's in the private address space (RFC 1918) that is not routable on the public internet. The `/16` is generous — pick a range that doesn't collide with your office network or other VPCs you may want to peer with later.

---

### 4.2 Create the six subnets

**What this does:** Divides the VPC into three tiers across two Availability Zones.

```bash
# --- Public tier (load balancer + NAT lives here) ---
PUB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone "$AZ_A" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-a},{Key=Tier,Value=public}]" \
  --query 'Subnet.SubnetId' --output text)
save PUB_A "$PUB_A"

PUB_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-public-b},{Key=Tier,Value=public}]" \
  --query 'Subnet.SubnetId' --output text)
save PUB_B "$PUB_B"

# --- Private app tier (EC2 + Docker + Keycloak lives here) ---
APP_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.11.0/24 \
  --availability-zone "$AZ_A" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-app-a},{Key=Tier,Value=app}]" \
  --query 'Subnet.SubnetId' --output text)
save APP_A "$APP_A"

APP_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.12.0/24 \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-app-b},{Key=Tier,Value=app}]" \
  --query 'Subnet.SubnetId' --output text)
save APP_B "$APP_B"

# --- Private data tier (RDS lives here) ---
DB_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.21.0/24 \
  --availability-zone "$AZ_A" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-db-a},{Key=Tier,Value=data}]" \
  --query 'Subnet.SubnetId' --output text)
save DB_A "$DB_A"

DB_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.22.0/24 \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${PROJECT}-db-b},{Key=Tier,Value=data}]" \
  --query 'Subnet.SubnetId' --output text)
save DB_B "$DB_B"
```

**Why `/24` for each?** A `/24` gives 256 addresses (AWS reserves 5, so 251 usable). That is plenty for a handful of EC2 instances and leaves room to grow. It also keeps the math easy to read: the third number in the address tells you which subnet you're in.

**Why exactly two AZs for the database subnets?** RDS Multi-AZ *requires* a subnet group covering at least two AZs. Even if you only ever run a single-AZ database, AWS makes you declare two so that failover is possible later.

---

### 4.3 Internet Gateway and the public route table

**What this does:** Gives the public subnets a path to the internet.

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PROJECT}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
save IGW_ID "$IGW_ID"

aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID"

# Route table for public subnets
RTB_PUB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rtb-public}]" \
  --query 'RouteTable.RouteTableId' --output text)
save RTB_PUB "$RTB_PUB"

# "Anything not local goes to the internet gateway"
aws ec2 create-route --route-table-id "$RTB_PUB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"

aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_A"
aws ec2 associate-route-table --route-table-id "$RTB_PUB" --subnet-id "$PUB_B"
```

**What is a route table?** A list of instructions: "traffic going to address range X should be sent to destination Y." Every subnet has one. The rule `0.0.0.0/0 → IGW` means "for anything I don't recognise, send it to the internet." `0.0.0.0/0` is shorthand for "every possible address" and is called the **default route**.

**The definition of a public subnet is literally this:** a subnet whose route table has a route to an Internet Gateway. There's no checkbox called "public."

---

### 4.4 NAT Gateways and the private route tables

**What this does:** Lets your private servers download things (the Keycloak image, OS patches) without being reachable from outside.

```bash
# A NAT Gateway needs a static public IP, called an Elastic IP
EIP_A=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-a}]" \
  --query 'AllocationId' --output text)
save EIP_A "$EIP_A"

EIP_B=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip-b}]" \
  --query 'AllocationId' --output text)
save EIP_B "$EIP_B"

# NAT Gateway A — note it goes in the PUBLIC subnet
NAT_A=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_A" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-a}]" \
  --query 'NatGateway.NatGatewayId' --output text)
save NAT_A "$NAT_A"

NAT_B=$(aws ec2 create-nat-gateway --subnet-id "$PUB_B" --allocation-id "$EIP_B" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PROJECT}-nat-b}]" \
  --query 'NatGateway.NatGatewayId' --output text)
save NAT_B "$NAT_B"

# NAT Gateways take 2-3 minutes to become available. Wait for them.
echo "Waiting for NAT gateways (this takes a few minutes)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_A" "$NAT_B"
echo "NAT gateways ready."
```

**Wait — the NAT Gateway goes in the *public* subnet?** Yes, and this confuses everyone the first time. Think of it as a translator standing in the doorway. It needs one foot in the public world (so it can reach the internet) and it serves the private world (via route table entries pointing at it). The *thing being protected* is private; the *translator* is public.

Now the private route tables. **We make one per AZ** so that if NAT Gateway A dies, only zone A loses outbound access, not both zones:

```bash
# Private route table for AZ A
RTB_A=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rtb-private-a}]" \
  --query 'RouteTable.RouteTableId' --output text)
save RTB_A "$RTB_A"
aws ec2 create-route --route-table-id "$RTB_A" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_A"
aws ec2 associate-route-table --route-table-id "$RTB_A" --subnet-id "$APP_A"
aws ec2 associate-route-table --route-table-id "$RTB_A" --subnet-id "$DB_A"

# Private route table for AZ B
RTB_B=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PROJECT}-rtb-private-b}]" \
  --query 'RouteTable.RouteTableId' --output text)
save RTB_B "$RTB_B"
aws ec2 create-route --route-table-id "$RTB_B" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_B"
aws ec2 associate-route-table --route-table-id "$RTB_B" --subnet-id "$APP_B"
aws ec2 associate-route-table --route-table-id "$RTB_B" --subnet-id "$DB_B"
```

💰 **Cost checkpoint:** You have now started the meter on two NAT Gateways (~$70/month combined) and two Elastic IPs. If this is a learning exercise, consider using **one** NAT Gateway shared by both private route tables. You lose zone-independence for outbound traffic, but you halve the cost. For production, keep two.

---

### 4.5 Create the three security groups

**What this does:** Builds the firewall rules. This is the most security-critical step in the whole guide.

```bash
# --- ALB security group ---
SG_ALB=$(aws ec2 create-security-group --group-name "${PROJECT}-alb-sg" \
  --description "Allow HTTPS from internet to ALB" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-alb-sg}]" \
  --query 'GroupId' --output text)
save SG_ALB "$SG_ALB"

aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# --- App (EC2) security group ---
SG_APP=$(aws ec2 create-security-group --group-name "${PROJECT}-app-sg" \
  --description "Keycloak EC2 instances" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-app-sg}]" \
  --query 'GroupId' --output text)
save SG_APP "$SG_APP"

# HTTP traffic from the ALB only  -- note --source-group, NOT --cidr
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 8080 --source-group "$SG_ALB"

# Health-check traffic from the ALB to Keycloak's management port
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 9000 --source-group "$SG_ALB"

# Keycloak cluster gossip between the instances themselves
aws ec2 authorize-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 7800 --source-group "$SG_APP"

# --- RDS security group ---
SG_RDS=$(aws ec2 create-security-group --group-name "${PROJECT}-rds-sg" \
  --description "PostgreSQL, reachable only from app tier" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-rds-sg}]" \
  --query 'GroupId' --output text)
save SG_RDS "$SG_RDS"

aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 5432 --source-group "$SG_APP"
```

**The single most important idea here:** notice `--source-group "$SG_APP"` instead of `--cidr 10.0.11.0/24`. This is **security group chaining**. It means "allow connections from anything wearing the app-tier badge." If you later add a third subnet or change your IP plan, nothing breaks. And critically, launching a random EC2 instance in the app subnet does **not** grant database access unless you also attach the app security group.

**Notice what's missing:** there is no rule allowing port 22 (SSH) from anywhere. We use Session Manager instead.

**Why port 7800?** That's the default port Keycloak's clustering layer (Infinispan/JGroups) uses to talk between nodes. Instances need to gossip with each other about who's in the cluster.

**Note on outbound rules:** AWS gives every new security group a default "allow all outbound" rule. We keep it, because the instances must reach Artifactory, RDS, and the AWS APIs. Locking outbound down further is a valid hardening step but adds a lot of complexity (you'd need VPC endpoints for the AWS services).

---

### 4.6 Store secrets in Secrets Manager

**What this does:** Puts the database password and Artifactory credentials somewhere encrypted, so they never appear in a script, a launch template, or your git history.

```bash
# Database credentials
DB_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "${PROJECT}/db-credentials" \
  --description "Keycloak RDS master credentials" \
  --secret-string "{\"username\":\"kcadmin\",\"password\":\"${DB_PASSWORD}\"}" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'ARN' --output text)
save DB_SECRET_ARN "$DB_SECRET_ARN"

# Artifactory credentials
ART_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "${PROJECT}/artifactory-credentials" \
  --description "JFrog Artifactory pull credentials" \
  --secret-string "{\"username\":\"${ARTIFACTORY_USER}\",\"token\":\"${ARTIFACTORY_TOKEN}\"}" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'ARN' --output text)
save ART_SECRET_ARN "$ART_SECRET_ARN"

# Keycloak bootstrap admin credentials
KC_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "${PROJECT}/keycloak-admin" \
  --description "Keycloak temporary bootstrap admin" \
  --secret-string "{\"username\":\"tmpadmin\",\"password\":\"${KC_ADMIN_PASSWORD}\"}" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'ARN' --output text)
save KC_SECRET_ARN "$KC_SECRET_ARN"
```

**Why not just put the password in the user-data script?** Because user data is retrievable by *anything running on the instance*, including a compromised application, via `http://169.254.169.254/latest/user-data`. It's also visible in the AWS console to anyone with `ec2:DescribeLaunchTemplateVersions`. Treat user data as public text.

> ⚠️ **About the bootstrap admin:** `KC_BOOTSTRAP_ADMIN_*` creates a temporary master-realm admin the first time Keycloak starts against an empty database. It is meant to be used once, to log in and create a real named admin account, and then **deleted**. Do not leave `tmpadmin` alive in production.

---

### 4.7 Create the IAM role and instance profile

**What this does:** Gives the EC2 instances permission to read those secrets and to be managed by Session Manager — without any credentials on disk.

```bash
# The trust policy: "EC2 instances are allowed to assume this role"
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

ROLE_NAME="${PROJECT}-ec2-role"
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json \
  --tags "Key=Project,Value=${PROJECT}"
save ROLE_NAME "$ROLE_NAME"

# Attach the AWS-managed policy for Session Manager
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Attach the AWS-managed policy for sending logs to CloudWatch
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

# A custom, LEAST-PRIVILEGE policy: read exactly these three secrets, nothing else
cat > secrets-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": [
      "${DB_SECRET_ARN}",
      "${ART_SECRET_ARN}",
      "${KC_SECRET_ARN}"
    ]
  }]
}
EOF

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${PROJECT}-read-secrets" \
  --policy-document file://secrets-policy.json

# An instance profile is the wrapper that lets EC2 actually use a role
aws iam create-instance-profile --instance-profile-name "$ROLE_NAME"
aws iam add-role-to-instance-profile \
  --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"

# IAM changes take a few seconds to propagate globally
sleep 15
```

**What is "least privilege"?** Give each thing the *smallest* set of permissions that lets it do its job. Notice the `Resource` list names the three specific secret ARNs. A lazier version would say `"Resource": "*"`, which would let a compromised Keycloak instance read *every secret in your account* — database passwords for other teams, API keys, everything. **Never write `"Resource": "*"` for secrets.**

**Why does an "instance profile" exist separately from a "role"?** Historical AWS plumbing. A role is the set of permissions; an instance profile is the container that attaches a role to an EC2 instance. In the console they look like one thing; in the CLI you must create both. Give them the same name to save yourself confusion.

---

### 4.8 Create the RDS PostgreSQL database

**What this does:** Creates the durable, replicated home for all of Keycloak's data. **This is the most important resource in the whole stack** — everything else can be rebuilt from a script; this cannot.

```bash
# A DB subnet group tells RDS which subnets it may live in
aws rds create-db-subnet-group \
  --db-subnet-group-name "${PROJECT}-db-subnets" \
  --db-subnet-group-description "Private data subnets for Keycloak" \
  --subnet-ids "$DB_A" "$DB_B" \
  --tags "Key=Project,Value=${PROJECT}"
save DB_SUBNET_GROUP "${PROJECT}-db-subnets"

# Find a current PostgreSQL version rather than hard-coding one that may be retired
PG_VERSION=$(aws rds describe-db-engine-versions --engine postgres \
  --query 'sort_by(DBEngineVersions,&EngineVersion)[-1].EngineVersion' --output text)
echo "Using PostgreSQL version: $PG_VERSION"
save PG_VERSION "$PG_VERSION"

aws rds create-db-instance \
  --db-instance-identifier "${PROJECT}-db" \
  --db-instance-class db.t3.medium \
  --engine postgres \
  --engine-version "$PG_VERSION" \
  --master-username kcadmin \
  --master-user-password "$DB_PASSWORD" \
  --db-name keycloak \
  --allocated-storage 20 \
  --max-allocated-storage 100 \
  --storage-type gp3 \
  --storage-encrypted \
  --multi-az \
  --db-subnet-group-name "${PROJECT}-db-subnets" \
  --vpc-security-group-ids "$SG_RDS" \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --preferred-backup-window "03:00-04:00" \
  --preferred-maintenance-window "sun:04:30-sun:05:30" \
  --auto-minor-version-upgrade \
  --deletion-protection \
  --enable-performance-insights \
  --copy-tags-to-snapshot \
  --tags "Key=Project,Value=${PROJECT}"

echo "Creating the database. This takes 10-20 minutes for Multi-AZ. Go get a snack."
aws rds wait db-instance-available --db-instance-identifier "${PROJECT}-db"

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${PROJECT}-db" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
save DB_ENDPOINT "$DB_ENDPOINT"
echo "Database is ready at: $DB_ENDPOINT"
```

**Every flag explained:**

| Flag | What it means and why |
|---|---|
| `--db-instance-class db.t3.medium` | The size: 2 vCPU, 4 GB RAM. Fine for testing and small production. Burstable — good for spiky login traffic, but watch CPU credits. For heavy production use `db.m6g.large` or bigger. |
| `--db-name keycloak` | Creates an empty database called `keycloak` inside the server. Without this, no database is created and Keycloak's first connection fails. |
| `--allocated-storage 20` | Start with 20 GB. |
| `--max-allocated-storage 100` | **Storage autoscaling.** If it fills up, AWS grows it automatically to 100 GB. This has saved countless outages. |
| `--storage-type gp3` | Modern SSD. Cheaper and more predictable than the older gp2. |
| `--storage-encrypted` | Encrypts the disk at rest. **You cannot turn this on later** without a snapshot-and-restore. Always turn it on now. |
| `--multi-az` | **The fault-tolerance switch.** Creates a synchronous standby in the other AZ. Roughly doubles the cost. Automatic failover in 60–120 seconds. |
| `--no-publicly-accessible` | The database gets no public IP. Combined with the security group, it's unreachable from the internet. |
| `--backup-retention-period 7` | Keeps 7 days of automated backups, enabling **point-in-time recovery** — you can restore to any second in the last week. Setting this to `0` disables backups entirely; never do that in production. |
| `--preferred-backup-window` | Times are **UTC**. Pick your quietest hour. |
| `--preferred-maintenance-window` | When AWS may apply patches. With Multi-AZ, AWS patches the standby first, fails over, then patches the old primary — so you get a ~60 second blip instead of an outage. |
| `--deletion-protection` | **You cannot delete this database until you explicitly turn this off.** This is a seatbelt against a mistyped command. Section 11 shows how to remove it deliberately. |
| `--enable-performance-insights` | A free (7-day retention) dashboard showing which queries are slow. |
| `--copy-tags-to-snapshot` | Snapshots inherit your tags, so you can find and clean them up later. |

**Why Multi-AZ and not read replicas?** They solve different problems:
- **Multi-AZ** = survivability. Standby is invisible and unreadable; it exists purely to take over.
- **Read replica** = performance. Readable, but asynchronous (can lag), and failover is manual.

Keycloak's workload is write-heavy relative to typical apps (every login writes session data), so read replicas help less than you'd expect. **Multi-AZ is the right choice here.**

---

### 4.9 Create the Application Load Balancer

**What this does:** Puts a highly available front door in place, with HTTPS.

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT}-alb" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$PUB_A" "$PUB_B" \
  --security-groups "$SG_ALB" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
save ALB_ARN "$ALB_ARN"

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)
save ALB_DNS "$ALB_DNS"
echo "Your load balancer's address is: $ALB_DNS"

# Recommended hardening
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=deletion_protection.enabled,Value=false \
    Key=idle_timeout.timeout_seconds,Value=120
```

Now the **target group** — the list of servers the ALB sends traffic to, plus the health-check rules:

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg" \
  --protocol HTTP --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port 9000 \
  --health-check-path /health/ready \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
save TG_ARN "$TG_ARN"

# Sticky sessions + a graceful shutdown window
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
  --attributes \
    Key=stickiness.enabled,Value=true \
    Key=stickiness.type,Value=lb_cookie \
    Key=stickiness.lb_cookie.duration_seconds,Value=3600 \
    Key=deregistration_delay.timeout_seconds,Value=60
```

**Health check settings, explained:**

- **`--health-check-port 9000`** — Keycloak 25 and later serve health endpoints on a *separate management port* (9000), not on the main HTTP port. This is deliberate: it lets you keep health and metrics off the public path. The ALB checks 9000 but sends real traffic to 8080.
- **`/health/ready`** — "ready" means *ready to serve traffic*, including having a working database connection. There is also `/health/live` ("the process is running") and `/health/started`. **Use `/health/ready` for the load balancer** — you don't want traffic sent to an instance that's alive but can't reach the database.
- **`--healthy-threshold-count 2`** — must pass twice before it gets traffic. Prevents flapping.
- **`--unhealthy-threshold-count 3`** — must fail three times (3 × 15s = 45 seconds) before it's pulled out. Prevents one slow response from evicting a healthy server.
- **`deregistration_delay 60`** — when an instance is being removed, the ALB stops sending it *new* requests but waits 60 seconds for in-flight ones to finish. This is what makes deployments graceful instead of dropping users mid-login.

**On sticky sessions:** Keycloak can run without them, because it replicates sessions between nodes. But the replication has a cost, and if a user's requests keep landing on the node that owns their session, everything is faster. Enabling stickiness is a performance optimization, **not** a correctness requirement — the system must still work if a sticky node dies, and it does.

Now the **listeners** — the rules for what to do with incoming connections:

```bash
# HTTPS listener: decrypt and forward to the target group
HTTPS_LISTENER=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn="$ACM_CERT_ARN" \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --query 'Listeners[0].ListenerArn' --output text)
save HTTPS_LISTENER "$HTTPS_LISTENER"

# HTTP listener: do not serve anything, just redirect to HTTPS
HTTP_LISTENER=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions '[{
    "Type":"redirect",
    "RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}
  }]' \
  --query 'Listeners[0].ListenerArn' --output text)
save HTTP_LISTENER "$HTTP_LISTENER"
```

**Why redirect instead of just closing port 80?** Because users type `auth.example.com` without a scheme, and browsers try HTTP first. A redirect gives them a working experience. The `301` status means "moved permanently," which browsers cache.

**Why that SSL policy?** `ELBSecurityPolicy-TLS13-1-2-2021-06` allows TLS 1.2 and 1.3 only, and blocks the old broken ciphers. Never use a policy whose name includes `TLS-1-0` or `TLS-1-1`.

---

### 4.10 Write the user-data script

**What this does:** This is the recipe every new instance follows on first boot. Read it carefully — it's the heart of the deployment.

```bash
cat > user-data.sh << USERDATA
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/keycloak-bootstrap.log | logger -t keycloak-bootstrap) 2>&1

echo "=== Keycloak bootstrap starting at \$(date) ==="

# ---------- 1. Install Docker, jq, and the AWS CLI ----------
dnf update -y
dnf install -y docker jq awscli
systemctl enable --now docker

# ---------- 2. Fetch secrets using the instance's IAM role ----------
# No credentials are stored here. The AWS CLI picks up the role automatically.
DB_JSON=\$(aws secretsmanager get-secret-value \\
  --secret-id "${DB_SECRET_ARN}" --region "${AWS_REGION}" \\
  --query SecretString --output text)
DB_USER=\$(echo "\$DB_JSON" | jq -r .username)
DB_PASS=\$(echo "\$DB_JSON" | jq -r .password)

ART_JSON=\$(aws secretsmanager get-secret-value \\
  --secret-id "${ART_SECRET_ARN}" --region "${AWS_REGION}" \\
  --query SecretString --output text)
ART_USER=\$(echo "\$ART_JSON" | jq -r .username)
ART_TOKEN=\$(echo "\$ART_JSON" | jq -r .token)

KC_JSON=\$(aws secretsmanager get-secret-value \\
  --secret-id "${KC_SECRET_ARN}" --region "${AWS_REGION}" \\
  --query SecretString --output text)
KC_USER=\$(echo "\$KC_JSON" | jq -r .username)
KC_PASS=\$(echo "\$KC_JSON" | jq -r .password)

# ---------- 3. Log in to Artifactory and pull the image ----------
echo "\$ART_TOKEN" | docker login "${ARTIFACTORY_HOST}" \\
  --username "\$ART_USER" --password-stdin

# Retry, because transient network failures on boot are common
for attempt in 1 2 3 4 5; do
  if docker pull "${KC_IMAGE}"; then
    echo "Image pulled successfully on attempt \$attempt"
    break
  fi
  echo "Pull attempt \$attempt failed; retrying in 15s"
  sleep 15
done

# Immediately remove the stored registry credentials from disk
docker logout "${ARTIFACTORY_HOST}" || true
rm -f /root/.docker/config.json

# ---------- 4. Run Keycloak ----------
docker run -d \\
  --name keycloak \\
  --restart unless-stopped \\
  --network host \\
  --log-driver=awslogs \\
  --log-opt awslogs-region="${AWS_REGION}" \\
  --log-opt awslogs-group="/${PROJECT}/keycloak" \\
  --log-opt awslogs-create-group=true \\
  -e KC_DB=postgres \\
  -e KC_DB_URL="jdbc:postgresql://${DB_ENDPOINT}:5432/keycloak" \\
  -e KC_DB_USERNAME="\$DB_USER" \\
  -e KC_DB_PASSWORD="\$DB_PASS" \\
  -e KC_DB_POOL_INITIAL_SIZE=5 \\
  -e KC_DB_POOL_MIN_SIZE=5 \\
  -e KC_DB_POOL_MAX_SIZE=20 \\
  -e KC_HOSTNAME="https://${DOMAIN_NAME}" \\
  -e KC_HTTP_ENABLED=true \\
  -e KC_HTTP_PORT=8080 \\
  -e KC_PROXY_HEADERS=xforwarded \\
  -e KC_HEALTH_ENABLED=true \\
  -e KC_METRICS_ENABLED=true \\
  -e KC_HTTP_MANAGEMENT_PORT=9000 \\
  -e KC_CACHE=ispn \\
  -e KC_BOOTSTRAP_ADMIN_USERNAME="\$KC_USER" \\
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="\$KC_PASS" \\
  -e JAVA_OPTS_APPEND="-XX:MaxRAMPercentage=70" \\
  "${KC_IMAGE}" \\
  start --cache-stack=jdbc-ping

echo "=== Keycloak container started at \$(date) ==="

# ---------- 5. Wait until it is actually ready ----------
for i in \$(seq 1 60); do
  if curl -fsS http://localhost:9000/health/ready > /dev/null 2>&1; then
    echo "Keycloak reported READY after \$((i*5)) seconds"
    exit 0
  fi
  sleep 5
done

echo "ERROR: Keycloak did not become ready within 5 minutes"
docker logs keycloak --tail 200
exit 1
USERDATA
```

**Every important choice in that script:**

| Choice | Why |
|---|---|
| `set -euo pipefail` | Stop on the first error instead of continuing in a broken state. Without this, a failed image pull would be silently ignored and you'd have a running instance serving nothing. |
| `exec > >(tee /var/log/...)` | Captures all output to a log file *and* to syslog, so you can debug boot failures. |
| `--password-stdin` | Passing a token as a command-line argument makes it visible in `ps` output to every user on the box. `--password-stdin` avoids that. |
| Retry loop on `docker pull` | Instances sometimes boot before the NAT route is fully usable. Retrying converts a hard failure into a 15-second delay. |
| `docker logout` + `rm config.json` | The pull is done; leaving credentials on disk serves no purpose and creates risk. |
| `--restart unless-stopped` | If the container crashes, Docker restarts it. If the *instance* has a deeper problem, the ALB health check catches it and the ASG replaces the instance. Two layers of recovery. |
| `--network host` | Simplest networking: the container's ports 8080/9000 are the instance's ports. Also required for Keycloak's cluster discovery to advertise the right IP. |
| `--log-driver=awslogs` | Ships container logs straight to CloudWatch. **Critical** — when the ASG destroys a failing instance, its local logs die with it. Centralized logs are the only way to find out what happened. |
| `MaxRAMPercentage=70` | Tells the JVM it may use 70% of the machine's RAM, leaving headroom for the OS. Without this the JVM often under-uses available memory. |

**The Keycloak environment variables, explained:**

| Variable | Purpose |
|---|---|
| `KC_DB=postgres` | Which database driver to use. |
| `KC_DB_URL` | Standard JDBC connection string pointing at the **RDS endpoint DNS name**, never an IP. During a failover, AWS changes what that name resolves to; an IP would break. |
| `KC_DB_POOL_MAX_SIZE=20` | Each Keycloak node keeps up to 20 open database connections. **Do the math:** 6 instances × 20 = 120 connections. A `db.t3.medium` supports several hundred, so we're fine — but if you scale to 30 nodes you will exhaust the database's connection limit. This is a very common production outage. |
| `KC_HOSTNAME=https://auth.example.com` | Keycloak puts absolute URLs into the tokens and redirects it issues. If this is wrong, users get redirected to the wrong place and login silently breaks. **This must be the public URL your users type**, not the instance's address. |
| `KC_HTTP_ENABLED=true` | Allow plain HTTP. Safe here *only* because the ALB terminates TLS and nothing but the ALB can reach port 8080. |
| `KC_PROXY_HEADERS=xforwarded` | Tells Keycloak to trust `X-Forwarded-*` headers from the ALB, so it knows the original request was HTTPS and knows the real client IP. **Without this, Keycloak thinks every request is insecure HTTP and will refuse or misbehave.** (This setting replaced the older `KC_PROXY=edge`, which was removed in Keycloak 26.) |
| `KC_HEALTH_ENABLED=true` | Turns on `/health/*`. Without it the ALB health check gets a 404 and every instance is marked unhealthy forever. This is the #1 cause of "my ASG keeps replacing instances." |
| `KC_METRICS_ENABLED=true` | Exposes Prometheus metrics on port 9000. |
| `KC_CACHE=ispn` | Use the distributed Infinispan cache (clustered mode) rather than `local`. Required for multiple nodes to share session state. |
| `start --cache-stack=jdbc-ping` | **The clustering method.** Explained below. |

> 🔧 **Version note:** `KC_BOOTSTRAP_ADMIN_USERNAME`/`_PASSWORD` are the Keycloak 26 names; earlier versions used `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD`. Recent Keycloak versions also default the cache stack to `jdbc-ping`, so passing it explicitly is harmless but may be redundant. Always check the release notes for the exact tag you are deploying.

**Why `jdbc-ping` matters so much:**

Keycloak nodes need to find each other to form a cluster. The classic method is **UDP multicast** — shout on the network and see who answers. **AWS VPCs do not support multicast.** So the default discovery fails, every node thinks it is alone, and you get bizarre symptoms: users randomly logged out, "invalid state" errors on login.

`jdbc-ping` solves this elegantly: each node writes its own address into a table in the PostgreSQL database and reads the table to find everyone else. **The database becomes the meeting point.** No extra infrastructure, no multicast, and it works perfectly with autoscaling because nodes register and deregister themselves.

The alternative, `kubernetes` / `dns.DNS_PING`, requires a headless service — great on EKS, not applicable on plain EC2.

---

### 4.11 Create the launch template

**What this does:** Saves the "recipe" for building a Keycloak server, so the ASG can stamp out identical copies.

```bash
# Find the newest Amazon Linux 2023 AMI from the official SSM parameter
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)
save AMI_ID "$AMI_ID"
echo "Using AMI: $AMI_ID"

# The launch template needs user data base64-encoded
USER_DATA_B64=$(base64 -w0 user-data.sh 2>/dev/null || base64 -i user-data.sh)

cat > lt-data.json << EOF
{
  "ImageId": "${AMI_ID}",
  "InstanceType": "t3.medium",
  "IamInstanceProfile": { "Name": "${ROLE_NAME}" },
  "SecurityGroupIds": ["${SG_APP}"],
  "UserData": "${USER_DATA_B64}",
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpPutResponseHopLimit": 2,
    "HttpEndpoint": "enabled"
  },
  "Monitoring": { "Enabled": true },
  "BlockDeviceMappings": [{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 30,
      "VolumeType": "gp3",
      "Encrypted": true,
      "DeleteOnTermination": true
    }
  }],
  "TagSpecifications": [{
    "ResourceType": "instance",
    "Tags": [
      {"Key": "Name", "Value": "${PROJECT}-node"},
      {"Key": "Project", "Value": "${PROJECT}"}
    ]
  }]
}
EOF

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "${PROJECT}-lt" \
  --version-description "v1 initial" \
  --launch-template-data file://lt-data.json \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
save LT_ID "$LT_ID"
```

**Key settings:**

- **`"HttpTokens": "required"`** — This enforces **IMDSv2**. The instance metadata service (at `169.254.169.254`) is where an instance gets its IAM credentials. IMDSv1 could be tricked by a **Server-Side Request Forgery (SSRF)** attack — an attacker makes your app fetch that URL and leaks your credentials. IMDSv2 requires a token obtained by a `PUT` request, which SSRF generally cannot perform. **Always set this.** This exact vulnerability caused the 2019 Capital One breach.
- **`"HttpPutResponseHopLimit": 2`** — allows one extra network hop, needed when a Docker container (rather than the host directly) calls the metadata service.
- **`"Encrypted": true`** on the EBS volume — disk encryption at rest, free.
- **`"DeleteOnTermination": true`** — when the ASG kills an instance, its disk goes too. Otherwise you accumulate orphaned volumes that quietly cost money forever. (See Section 11.)
- **`"Monitoring": {"Enabled": true}`** — detailed CloudWatch metrics at 1-minute granularity instead of 5. Costs a little; worth it for autoscaling responsiveness.

**Launch templates are versioned.** When you need to deploy a new Keycloak image, you create a *new version* of the template rather than editing it. That gives you a rollback path.

---

### 4.12 Create the Auto Scaling Group

**What this does:** Brings it all to life. This is the step where servers actually start.

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
  --min-size 2 \
  --max-size 6 \
  --desired-capacity 2 \
  --vpc-zone-identifier "${APP_A},${APP_B}" \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --default-instance-warmup 300 \
  --termination-policies "OldestInstance" \
  --tags \
    "Key=Name,Value=${PROJECT}-node,PropagateAtLaunch=true" \
    "Key=Project,Value=${PROJECT},PropagateAtLaunch=true"
```

**Every flag, explained:**

| Flag | Why it's set this way |
|---|---|
| `--min-size 2` | **Never set this to 1.** With 1, any failure is a full outage until a replacement boots (2–4 minutes). With 2 in different AZs, a failure is invisible to users. |
| `--max-size 6` | A ceiling on the bill. If something goes wrong and scaling runs away, you lose 6 instances of money, not 600. |
| `--vpc-zone-identifier` with **both** app subnets | This is what makes the ASG span two Availability Zones. The ASG automatically keeps them balanced. **If you list only one subnet, you have thrown away your AZ redundancy** while thinking you're highly available. |
| `--target-group-arns` | Automatically registers each new instance with the load balancer and deregisters it on termination. No manual step. |
| `--health-check-type ELB` | **The self-healing switch.** The default is `EC2`, which only notices if the *virtual machine* has failed — a hung Keycloak on a perfectly healthy VM would be left in place forever. `ELB` means the ASG trusts the load balancer's HTTP health check and replaces instances whose application is broken. |
| `--health-check-grace-period 300` | Give a new instance 5 minutes to boot, pull the image, and start Keycloak before health checks count against it. **Too short and you get an infinite kill-and-relaunch loop** — instances get terminated for being unhealthy before they've had a chance to start. Very common mistake. |
| `--default-instance-warmup 300` | Tells scaling policies to ignore a new instance's metrics for 5 minutes, preventing over-scaling while it warms up. |
| `--termination-policies OldestInstance` | When scaling in, remove the oldest instance. Natural rotation, keeps the fleet fresh. |
| `PropagateAtLaunch=true` | Copies the tag onto every instance the ASG creates. Without it, only the ASG itself is tagged and your instances show up untagged in the bill. |

Now add the scaling rule:

```bash
cat > scaling-policy.json << 'EOF'
{
  "TargetValue": 60.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ASGAverageCPUUtilization"
  },
  "DisableScaleIn": false
}
EOF

aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "${PROJECT}-asg" \
  --policy-name "${PROJECT}-cpu-target-tracking" \
  --policy-type TargetTrackingScaling \
  --estimated-instance-warmup 300 \
  --target-tracking-configuration file://scaling-policy.json
```

**How target tracking works:** You state a goal ("average CPU across the group should be 60%"). AWS creates the CloudWatch alarms behind the scenes and continuously adds or removes instances to hold that number. It's like a thermostat — you set the temperature, not the furnace schedule.

**Why 60% and not 90%?** Because scaling takes time. A new instance needs ~3 minutes to boot, pull the image, start the JVM, and pass health checks. If you wait until 90% CPU to react, you'll be at 100% and dropping requests before help arrives. The 40% headroom is your buffer.

**Should you scale on CPU at all for Keycloak?** CPU is a reasonable proxy, because password hashing (Keycloak uses Argon2 or PBKDF2 with many iterations) is deliberately CPU-expensive. But `ALBRequestCountPerTarget` is often a better signal, because it responds to load *before* CPU climbs:

```bash
# Alternative: scale on requests per instance
TG_SUFFIX=$(echo "$TG_ARN" | awk -F: '{print $6}')
ALB_SUFFIX=$(echo "$ALB_ARN" | awk -F"loadbalancer/" '{print $2}')

cat > scaling-policy-req.json << EOF
{
  "TargetValue": 1000.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "${ALB_SUFFIX}/${TG_SUFFIX}"
  }
}
EOF
```

---

### 4.13 Watch it come up

```bash
# Are the instances launching?
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT}-asg" \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,Health:HealthStatus,State:LifecycleState}' \
  --output table

# Are they healthy in the load balancer's eyes? (this is the real test)
watch -n 15 "aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table"
```

You will see states in this order: `initial` → `unhealthy` → `healthy`. **Give it 4–6 minutes.** The first instance is slowest because it also has to create all of Keycloak's database tables.

**Read the boot log on an instance if something looks wrong:**

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT}-asg" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE_ID"
# then, inside the session:
#   sudo tail -100 /var/log/keycloak-bootstrap.log
#   sudo docker ps
#   sudo docker logs keycloak --tail 100
#   curl -s localhost:9000/health/ready
```

---

### 4.14 Point DNS at the load balancer

```bash
# Find your hosted zone
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "example.com" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')

ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

cat > dns-record.json << EOF
{
  "Comment": "Point Keycloak hostname at the ALB",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DOMAIN_NAME}",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE_ID}",
        "DNSName": "${ALB_DNS}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://dns-record.json
```

**Why an "Alias" record and not a CNAME?** An ALB's IP addresses change over time, so you can never point an `A` record at a fixed IP. A CNAME would work but can't be used at the zone apex (`example.com` itself), and adds a DNS lookup. An **Alias** is an AWS-specific record that resolves directly to the ALB's current IPs, is free to query, and works at the apex. Always use Alias for AWS resources.

---

### 4.15 Verify it works

```bash
# 1. HTTP should redirect to HTTPS
curl -I "http://${DOMAIN_NAME}"
# Expect: HTTP/1.1 301 Moved Permanently, Location: https://...

# 2. The main page should load
curl -sI "https://${DOMAIN_NAME}/realms/master" | head -1
# Expect: HTTP/2 200

# 3. The OpenID configuration document — proves Keycloak is truly working
curl -s "https://${DOMAIN_NAME}/realms/master/.well-known/openid-configuration" | jq -r '.issuer'
# Expect: https://auth.example.com/realms/master
# If the issuer shows an internal IP or the ALB DNS name, KC_HOSTNAME is wrong.
```

Then open `https://auth.example.com/admin` in a browser and log in with the bootstrap credentials.

**🔴 Do this immediately after your first login:**
1. Create a new admin user with a real name and a strong password.
2. Enable OTP / multi-factor authentication on it.
3. **Delete the `tmpadmin` bootstrap account.**
4. Delete the `${PROJECT}/keycloak-admin` secret, or rotate it to something unusable.

---

## 5. Part B — Build It With Terraform

### 5.1 Why Terraform instead of the CLI?

You just built the whole thing with 40-odd CLI commands. It works. So why do it again?

| Problem with the CLI approach | How Terraform fixes it |
|---|---|
| If your terminal closes, you lose all the IDs | State file tracks every resource |
| Rebuilding in a second region means running everything again by hand | `terraform apply -var region=eu-west-1` |
| No record of *why* something is configured a certain way | The code is the record, in git, with commit messages |
| You can't preview a change before making it | `terraform plan` shows exactly what will change |
| Deleting requires remembering 40 things in the right order | `terraform destroy` figures out the order for you |
| Someone changes a security group by hand and nobody knows | `terraform plan` detects the drift |

**The core idea is called "declarative infrastructure."** With the CLI you write *instructions* ("create this, then create that"). With Terraform you write a *description of the desired end state*, and Terraform works out what to create, change, or delete to get there. If you run it twice, nothing happens the second time — this property is called **idempotency**.

**Pros and cons, honestly:**

✅ **Pros:** Reviewable in a pull request. Reproducible. Self-documenting. Handles dependency ordering automatically. Huge ecosystem of modules. Works across AWS, Azure, GCP, Cloudflare, and hundreds more.

❌ **Cons:** You must learn HCL. The **state file is precious** — lose or corrupt it and Terraform no longer knows what it owns. State files contain secrets in plaintext, so they need encryption and access control. Some AWS features appear in the provider weeks after they appear in the console. And a bad `terraform destroy` deletes everything very efficiently.

**Alternatives worth knowing:** AWS CloudFormation (native, no state file to manage, AWS-only), AWS CDK (write infrastructure in TypeScript/Python, compiles to CloudFormation), Pulumi (like CDK but multi-cloud), OpenTofu (open-source fork of Terraform, drop-in compatible).

---

### 5.2 Set up the project

```bash
mkdir -p ~/keycloak-terraform && cd ~/keycloak-terraform
```

You will create these files:

```
keycloak-terraform/
├── versions.tf        # which Terraform + provider versions
├── variables.tf       # all the knobs you can turn
├── locals.tf          # computed values
├── network.tf         # VPC, subnets, gateways, routes
├── security.tf        # security groups
├── iam.tf             # roles and policies
├── secrets.tf         # Secrets Manager
├── rds.tf             # the database
├── alb.tf             # load balancer
├── compute.tf         # launch template + ASG + scaling
├── dns.tf             # Route 53
├── outputs.tf         # what to print at the end
├── user-data.sh.tftpl # the boot script template
└── terraform.tfvars   # YOUR values (never commit this!)
```

---

### 5.3 `versions.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # STRONGLY RECOMMENDED for any real use.
  # Keeps state off your laptop, encrypted, versioned, and locked
  # so two people can't apply at the same time.
  #
  # backend "s3" {
  #   bucket       = "mycompany-terraform-state"
  #   key          = "keycloak/prod/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true   # native S3 locking (Terraform >= 1.10)
  #   # For older versions use: dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

**Why pin versions with `~> 5.60`?** That means "5.60 or any later 5.x, but never 6.0." Providers introduce breaking changes at major versions. Without a pin, a colleague running `terraform init` next month could pull a different provider and get a wildly different plan. **Always pin.**

**What is `default_tags`?** Every single resource this provider creates gets these tags automatically. That's roughly 40 resources you don't have to tag by hand — and it makes Section 11's cleanup verification trivial.

**Why does the backend matter so much?** By default, state lives in a file called `terraform.tfstate` in your current directory. If you delete it, Terraform forgets it created anything and a subsequent `apply` will try to build a duplicate stack. If two engineers apply at once without locking, the state can corrupt. An S3 backend with locking and versioning fixes all of that.

---

### 5.4 `variables.tf`

```hcl
variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix on every resource"
  type        = string
  default     = "keycloak"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Lowercase letters, digits and hyphens; 3-21 characters."
  }
}

variable "environment" {
  description = "dev, staging, or prod"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "vpc_cidr" {
  description = "IP range for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_count" {
  description = "How many AZs to spread across. Minimum 2."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2
    error_message = "You need at least 2 AZs for fault tolerance."
  }
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (cheap, less resilient). false = one per AZ."
  type        = bool
  default     = false
}

# ---------- Keycloak / Artifactory ----------

variable "keycloak_image" {
  description = "Full Artifactory image path INCLUDING the version tag"
  type        = string
  # example: "mycompany.jfrog.io/docker-local/keycloak:26.4.0"

  validation {
    condition     = can(regex(":[^:/]+$", var.keycloak_image))
    error_message = "Pin an explicit tag. Never deploy ':latest'."
  }
}

variable "artifactory_host" {
  description = "Artifactory registry hostname, e.g. mycompany.jfrog.io"
  type        = string
}

variable "artifactory_username" {
  description = "Service account username for pulling images"
  type        = string
}

variable "artifactory_token" {
  description = "Artifactory access token"
  type        = string
  sensitive   = true
}

# ---------- Sizing ----------

variable "instance_type" {
  description = "EC2 size for Keycloak nodes"
  type        = string
  default     = "t3.medium"
}

variable "asg_min_size" {
  description = "Minimum instances. Never below 2 in production."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  type    = number
  default = 6
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  description = "Synchronous standby in a second AZ. Doubles DB cost."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Never disable backups."
  }
}

# ---------- DNS / TLS ----------

variable "domain_name" {
  description = "Public hostname users will visit, e.g. auth.example.com"
  type        = string
}

variable "route53_zone_name" {
  description = "Hosted zone, e.g. example.com. Leave empty to skip DNS."
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = "ACM cert ARN, in the SAME region as the ALB"
  type        = string
}

# ---------- Safety switches (see Section 11) ----------

variable "enable_deletion_protection" {
  description = "Blocks accidental deletion of the DB and ALB"
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "true = no backup taken on destroy. NEVER true in prod."
  type        = bool
  default     = false
}
```

**Why the `validation` blocks?** They catch mistakes at `plan` time, in one second, instead of at `apply` time, twenty minutes in. The `keycloak_image` one is especially valuable: deploying `:latest` means two instances launched an hour apart can be running **different versions of Keycloak against the same database**, which is a genuinely dangerous state.

**Why `sensitive = true`?** Terraform will print `(sensitive value)` instead of the token in plan output and logs. ⚠️ **It is still stored in plaintext in the state file.** Sensitivity marking is about shoulder-surfing and CI logs, not about state security. Encrypt your state bucket.

---

### 5.5 `locals.tf`

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project_name}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # Build the subnet map programmatically:
  # public  -> 10.0.1.0/24, 10.0.2.0/24
  # app     -> 10.0.11.0/24, 10.0.12.0/24
  # data    -> 10.0.21.0/24, 10.0.22.0/24
  subnets = merge(
    { for i, az in local.azs : "public-${i}" => {
        az    = az
        cidr  = cidrsubnet(var.vpc_cidr, 8, i + 1)
        tier  = "public"
    }},
    { for i, az in local.azs : "app-${i}" => {
        az    = az
        cidr  = cidrsubnet(var.vpc_cidr, 8, i + 11)
        tier  = "app"
    }},
    { for i, az in local.azs : "data-${i}" => {
        az    = az
        cidr  = cidrsubnet(var.vpc_cidr, 8, i + 21)
        tier  = "data"
    }},
  )

  public_subnet_keys = [for k, v in local.subnets : k if v.tier == "public"]
  app_subnet_keys    = [for k, v in local.subnets : k if v.tier == "app"]
  data_subnet_keys   = [for k, v in local.subnets : k if v.tier == "data"]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.availability_zone_count
}
```

**What is `cidrsubnet`?** A built-in function that does subnet math for you. `cidrsubnet("10.0.0.0/16", 8, 11)` means "take the /16, add 8 more bits (making it a /24), and give me subnet number 11" → `10.0.11.0/24`. Doing this by hand across three tiers and three AZs is where mistakes happen.

**What is `data "aws_availability_zones"`?** A **data source** — it *reads* existing information from AWS rather than creating something. Here it asks "which AZs exist in this region and are healthy?" so the code works in any region without you hard-coding zone names.

---

### 5.6 `network.tf`

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  # Only public subnets get auto-assigned public IPs
  map_public_ip_on_launch = each.value.tier == "public"

  tags = {
    Name = "${local.name}-${each.key}"
    Tier = each.value.tier
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ---------- NAT ----------

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${count.index}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.this[local.public_subnet_keys[count.index]].id

  tags = { Name = "${local.name}-nat-${count.index}" }

  depends_on = [aws_internet_gateway.main]
}

# ---------- Route tables ----------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rtb-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = toset(local.public_subnet_keys)

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ, so each AZ uses its own NAT
resource "aws_route_table" "private" {
  count  = var.availability_zone_count
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rtb-private-${count.index}" }
}

resource "aws_route" "private_nat" {
  count = var.availability_zone_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # If single_nat_gateway, everyone shares NAT 0
  nat_gateway_id = aws_nat_gateway.main[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "app" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.this["app-${count.index}"].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "data" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.this["data-${count.index}"].id
  route_table_id = aws_route_table.private[count.index].id
}

# ---------- VPC Flow Logs (recommended) ----------

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name}/flow-logs"
  retention_in_days = 30
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.flow_logs.arn
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  log_destination_type = "cloud-watch-logs"
}
```

**What are VPC Flow Logs?** A record of every network connection attempt in your VPC — who tried to talk to whom, on what port, and whether it was allowed or denied. When you're debugging "why can't Keycloak reach the database," flow logs answer it in thirty seconds. They also matter for security investigations. They cost a small amount in CloudWatch ingestion; worth it.

---

### 5.7 `security.tf`

```hcl
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Public HTTPS entry point"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, only to be redirected to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- App tier ----------

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-app-"
  description = "Keycloak EC2 instances"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_http_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Application traffic from ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_health_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Health checks on the management port"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "app_cluster" {
  security_group_id            = aws_security_group.app.id
  description                  = "Infinispan/JGroups cluster traffic between nodes"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 7800
  to_port                      = 7801
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Reach Artifactory, RDS, and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- Database tier ----------

resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "PostgreSQL, app tier only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from Keycloak nodes only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
```

**Why `name_prefix` instead of `name`?** Combined with `create_before_destroy`, it lets Terraform replace a security group without a downtime gap. With a fixed name, Terraform would have to delete the old one first — but it can't, because things are still attached to it. Deadlock. `name_prefix` avoids that entirely.

**Why the separate `aws_vpc_security_group_ingress_rule` resources instead of inline `ingress` blocks?** The modern, recommended pattern. Each rule is a distinct resource with its own ID, so Terraform can add or remove one rule without recreating the whole group, and the plan output tells you exactly which rule changed.

---

### 5.8 `secrets.tf`

```hcl
resource "random_password" "db" {
  length  = 32
  special = true
  # RDS rejects these characters in a master password
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "kc_bootstrap_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "${local.name}/db-credentials-"
  description             = "Keycloak RDS master credentials"
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "kcadmin"
    password = random_password.db.result
    engine   = "postgres"
    port     = 5432
    dbname   = "keycloak"
  })
}

resource "aws_secretsmanager_secret" "artifactory" {
  name_prefix             = "${local.name}/artifactory-"
  description             = "Artifactory pull credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "artifactory" {
  secret_id = aws_secretsmanager_secret.artifactory.id
  secret_string = jsonencode({
    username = var.artifactory_username
    token    = var.artifactory_token
  })
}

resource "aws_secretsmanager_secret" "kc_admin" {
  name_prefix             = "${local.name}/keycloak-bootstrap-admin-"
  description             = "TEMPORARY bootstrap admin. Delete after first login."
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "kc_admin" {
  secret_id = aws_secretsmanager_secret.kc_admin.id
  secret_string = jsonencode({
    username = "tmpadmin"
    password = random_password.kc_bootstrap_admin.result
  })
}
```

**Why `name_prefix` on secrets?** Secrets Manager does not immediately free a deleted name — it holds it for the recovery window (7–30 days). If you destroy and re-apply within that window with a fixed name, you get `InvalidRequestException: You can't create this secret because a secret with this name is already scheduled for deletion.` The random suffix from `name_prefix` sidesteps that. This is one of the most common Terraform-destroy-then-recreate failures.

**What is `recovery_window_in_days`?** When you delete a secret, AWS doesn't delete it immediately — it schedules deletion. During the window you can restore it. This is a safety net against accidental deletion of a production credential. You can force immediate deletion, but see Section 11 for why you should think first.

---

### 5.9 `iam.tf`

```hcl
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name_prefix        = "${local.name}-app-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    sid    = "ReadOnlyTheseThreeSecrets"
    effect = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.db.arn,
      aws_secretsmanager_secret.artifactory.arn,
      aws_secretsmanager_secret.kc_admin.arn,
    ]
  }
}

resource "aws_iam_role_policy" "read_secrets" {
  name_prefix = "${local.name}-secrets-"
  role        = aws_iam_role.app.id
  policy      = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "${local.name}-app-"
  role        = aws_iam_role.app.name
}
```

---

### 5.10 `rds.tf`

```hcl
resource "aws_db_subnet_group" "main" {
  name_prefix = "${local.name}-db-"
  subnet_ids  = [for k in local.data_subnet_keys : aws_subnet.this[k].id]

  tags = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-pg-"
  family      = "postgres16"

  # Log any query taking longer than 1 second
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Force TLS on all connections
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier_prefix = "${local.name}-"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  db_name  = "keycloak"
  username = "kcadmin"
  password = random_password.db.result
  port     = 5432

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  parameter_group_name   = aws_db_parameter_group.main.name

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"

  performance_insights_enabled = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # ---- Safety ----
  deletion_protection       = var.enable_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}"

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier, # the timestamp changes every plan
      engine_version,            # allow AWS auto minor upgrades without drift
    ]
  }

  tags = { Name = "${local.name}-db" }
}
```

**The `lifecycle.ignore_changes` block is important.** `timestamp()` produces a new value on every single plan, so without ignoring it, Terraform would show a change every time you run `plan`, which trains you to ignore plan output — a genuinely dangerous habit. Similarly, `auto_minor_version_upgrade` means AWS may bump 16.3 → 16.4 on its own; ignoring `engine_version` prevents Terraform from trying to downgrade it back.

**Optional but recommended: `prevent_destroy`.** Add this to the lifecycle block and Terraform will *refuse* to destroy the database, even with `terraform destroy`:

```hcl
lifecycle {
  prevent_destroy = true
}
```

You must then edit the code and remove the line to delete it. That deliberate friction has saved a lot of production data. The downside: it also blocks `terraform destroy` for the whole stack, which is annoying in dev. Use it in prod, leave it off in dev.

---

### 5.11 `alb.tf`

```hcl
resource "aws_lb" "main" {
  name_prefix        = substr(var.project_name, 0, 6)
  load_balancer_type = "application"
  internal           = false

  subnets         = [for k in local.public_subnet_keys : aws_subnet.this[k].id]
  security_groups = [aws_security_group.alb.id]

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true
  idle_timeout               = 120

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "keycloak" {
  name_prefix = "kc-"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 60

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "9000"
    path                = "/health/ready"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  stickiness {
    enabled         = true
    type            = "lb_cookie"
    cookie_duration = 3600
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}
```

---

### 5.12 `user-data.sh.tftpl`

This is the same boot script as Part A, but written as a Terraform **template** with `${placeholders}` that Terraform fills in.

```bash
#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/keycloak-bootstrap.log | logger -t keycloak-bootstrap) 2>&1

echo "=== Keycloak bootstrap starting at $(date) ==="

dnf update -y
dnf install -y docker jq awscli
systemctl enable --now docker

REGION="${aws_region}"

DB_JSON=$(aws secretsmanager get-secret-value --secret-id "${db_secret_arn}" \
  --region "$REGION" --query SecretString --output text)
DB_USER=$(echo "$DB_JSON" | jq -r .username)
DB_PASS=$(echo "$DB_JSON" | jq -r .password)

ART_JSON=$(aws secretsmanager get-secret-value --secret-id "${artifactory_secret_arn}" \
  --region "$REGION" --query SecretString --output text)
ART_USER=$(echo "$ART_JSON" | jq -r .username)
ART_TOKEN=$(echo "$ART_JSON" | jq -r .token)

KC_JSON=$(aws secretsmanager get-secret-value --secret-id "${kc_admin_secret_arn}" \
  --region "$REGION" --query SecretString --output text)
KC_USER=$(echo "$KC_JSON" | jq -r .username)
KC_PASS=$(echo "$KC_JSON" | jq -r .password)

echo "$ART_TOKEN" | docker login "${artifactory_host}" --username "$ART_USER" --password-stdin

for attempt in 1 2 3 4 5; do
  if docker pull "${keycloak_image}"; then
    echo "Pulled image on attempt $attempt"; break
  fi
  echo "Pull attempt $attempt failed; retrying"; sleep 15
done

docker logout "${artifactory_host}" || true
rm -f /root/.docker/config.json

docker run -d \
  --name keycloak \
  --restart unless-stopped \
  --network host \
  --log-driver=awslogs \
  --log-opt awslogs-region="$REGION" \
  --log-opt awslogs-group="${log_group_name}" \
  --log-opt awslogs-create-group=true \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${db_endpoint}/keycloak" \
  -e KC_DB_USERNAME="$DB_USER" \
  -e KC_DB_PASSWORD="$DB_PASS" \
  -e KC_DB_POOL_INITIAL_SIZE=5 \
  -e KC_DB_POOL_MIN_SIZE=5 \
  -e KC_DB_POOL_MAX_SIZE=20 \
  -e KC_HOSTNAME="https://${domain_name}" \
  -e KC_HTTP_ENABLED=true \
  -e KC_HTTP_PORT=8080 \
  -e KC_PROXY_HEADERS=xforwarded \
  -e KC_HEALTH_ENABLED=true \
  -e KC_METRICS_ENABLED=true \
  -e KC_HTTP_MANAGEMENT_PORT=9000 \
  -e KC_CACHE=ispn \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="$KC_USER" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="$KC_PASS" \
  -e JAVA_OPTS_APPEND="-XX:MaxRAMPercentage=70" \
  "${keycloak_image}" \
  start --cache-stack=jdbc-ping

for i in $(seq 1 60); do
  if curl -fsS http://localhost:9000/health/ready >/dev/null 2>&1; then
    echo "Keycloak READY after $((i*5))s"; exit 0
  fi
  sleep 5
done

echo "ERROR: not ready in 5 minutes"
docker logs keycloak --tail 200
exit 1
```

⚠️ **A gotcha that catches everyone:** Terraform's `templatefile()` uses `${...}` for its own substitutions, and so does bash. Any `${VAR}` you want bash to handle must be written as `$${VAR}` or as `$VAR` without braces. In the script above, the bash variables use the plain `$VAR` form for exactly this reason, while `${db_endpoint}`, `${keycloak_image}` etc. are Terraform placeholders.

---

### 5.13 `compute.tf`

```hcl
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/${local.name}/keycloak"
  retention_in_days = var.environment == "prod" ? 90 : 14
}

resource "aws_launch_template" "keycloak" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    aws_region             = var.aws_region
    db_secret_arn          = aws_secretsmanager_secret.db.arn
    artifactory_secret_arn = aws_secretsmanager_secret.artifactory.arn
    kc_admin_secret_arn    = aws_secretsmanager_secret.kc_admin.arn
    artifactory_host       = var.artifactory_host
    keycloak_image         = var.keycloak_image
    db_endpoint            = aws_db_instance.main.endpoint
    domain_name            = var.domain_name
    log_group_name         = aws_cloudwatch_log_group.keycloak.name
  }))

  # Force IMDSv2 — protects IAM credentials from SSRF attacks
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring { enabled = true }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-node" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name}-volume" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "keycloak" {
  name_prefix = "${local.name}-"

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_min_size

  vpc_zone_identifier = [for k in local.app_subnet_keys : aws_subnet.this[k].id]
  target_group_arns   = [aws_lb_target_group.keycloak.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300
  default_instance_warmup   = 300
  termination_policies      = ["OldestInstance"]

  launch_template {
    id      = aws_launch_template.keycloak.id
    version = aws_launch_template.keycloak.latest_version
  }

  # Rolling replacement whenever the template changes: zero-downtime deploys
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 300
      checkpoint_percentages = [50, 100]
      checkpoint_delay       = 120
    }
    triggers = ["launch_template", "desired_capacity"]
  }

  dynamic "tag" {
    for_each = {
      Name        = "${local.name}-node"
      Project     = var.project_name
      Environment = var.environment
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # let autoscaling own this number
  }

  depends_on = [aws_db_instance.main]
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

# ---------- Alarms ----------

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  alarm_name          = "${local.name}-NO-healthy-hosts-CRITICAL"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${local.name}-db-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }
}
```

**`instance_refresh` is the feature that makes deployments painless.** When you change `keycloak_image` and run `apply`, Terraform creates a new launch template version, and the ASG then *rolls* through the fleet: launch a new instance, wait for it to be healthy, terminate an old one, repeat. `min_healthy_percentage = 100` means it always adds before it removes, so capacity never dips. `checkpoint_percentages = [50, 100]` pauses halfway for two minutes, giving you a window to spot a problem and abort.

**Why `ignore_changes = [desired_capacity]`?** Because the scaling policy changes that number constantly. Without this, every `terraform apply` would yank the fleet back to the minimum, undoing autoscaling.

**Why `depends_on = [aws_db_instance.main]`?** Terraform usually figures out dependencies from references, and there is one here (`db_endpoint`). Being explicit is harmless and documents the intent: instances must not launch before the database exists, or they will crash-loop.

---

### 5.14 `dns.tf` and `outputs.tf`

```hcl
# dns.tf
data "aws_route53_zone" "main" {
  count = var.route53_zone_name != "" ? 1 : 0
  name  = var.route53_zone_name
}

resource "aws_route53_record" "keycloak" {
  count = var.route53_zone_name != "" ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
```

```hcl
# outputs.tf
output "keycloak_url" {
  description = "Where users log in"
  value       = "https://${var.domain_name}"
}

output "alb_dns_name" {
  description = "Direct ALB address (useful before DNS propagates)"
  value       = aws_lb.main.dns_name
}

output "db_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "db_secret_name" {
  description = "Read the DB password with: aws secretsmanager get-secret-value --secret-id <this>"
  value       = aws_secretsmanager_secret.db.name
}

output "bootstrap_admin_secret_name" {
  description = "First-login credentials. DELETE THE USER AND THIS SECRET after setup."
  value       = aws_secretsmanager_secret.kc_admin.name
}

output "asg_name" {
  value = aws_autoscaling_group.keycloak.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.keycloak.name
}
```

---

### 5.15 `terraform.tfvars` and running it

```hcl
# terraform.tfvars  --  ADD THIS TO .gitignore
aws_region  = "us-east-1"
project_name = "keycloak"
environment  = "dev"

domain_name         = "auth.example.com"
route53_zone_name   = "example.com"
acm_certificate_arn = "arn:aws:acm:us-east-1:111122223333:certificate/aaaa-bbbb"

keycloak_image       = "mycompany.jfrog.io/docker-local/keycloak:26.4.0"
artifactory_host     = "mycompany.jfrog.io"
artifactory_username = "svc-keycloak-deploy"
artifactory_token    = "REPLACE_ME"   # better: TF_VAR_artifactory_token env var

instance_type = "t3.medium"
asg_min_size  = 2
asg_max_size  = 6

db_instance_class = "db.t3.medium"
db_multi_az       = true
```

**Never commit this file.** Create `.gitignore`:

```gitignore
*.tfvars
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl.bak
crash.log
```

Better still, pass the token via environment variable so it never touches disk:

```bash
export TF_VAR_artifactory_token="your-token-here"
```

Now run it:

```bash
# 1. Download providers and set up the backend
terraform init

# 2. Check formatting and syntax
terraform fmt -recursive
terraform validate

# 3. THE MOST IMPORTANT STEP: preview
terraform plan -out=tfplan

# 4. Read the plan. Seriously read it.
#    Look for: "X to add, Y to change, Z to destroy"
#    In a fresh build, Z must be 0.

# 5. Apply the exact plan you reviewed
terraform apply tfplan

# 6. See the results
terraform output
```

**Why `-out=tfplan` and then apply the file?** Because `terraform apply` on its own re-plans, and the world may have changed since you looked. Applying a saved plan file guarantees you get *exactly* what you reviewed. In CI/CD this is mandatory practice.

Expect **15–25 minutes**, almost all of it waiting for the Multi-AZ RDS instance.

---

## 6. Keycloak Configuration Deep Dive

### 6.1 What Keycloak actually is

Keycloak is an open-source **Identity and Access Management (IAM)** server, originally from Red Hat, now a Cloud Native Computing Foundation project. It implements the industry-standard protocols:

- **OpenID Connect (OIDC)** — the modern standard for "log in with." Built on OAuth 2.0. Returns a **JWT** (JSON Web Token) that applications can verify without calling back to Keycloak.
- **OAuth 2.0** — the standard for delegated *authorization* ("let this app read my calendar").
- **SAML 2.0** — the older XML-based standard, still ubiquitous in enterprise and education software.

**The key vocabulary:**

| Term | Meaning |
|---|---|
| **Realm** | A completely isolated tenant. Users in realm A cannot see or log into realm B. The `master` realm is for administering Keycloak itself — **never put real application users in `master`**. |
| **Client** | An application that trusts Keycloak. Each of your 30 websites is a client. |
| **User** | A person. |
| **Role** | A permission label ("teacher", "student", "admin"). |
| **Group** | A bundle of users that can be granted roles collectively. |
| **Identity Provider** | An *external* login source Keycloak can delegate to — Google, Microsoft Entra ID, an LDAP directory, another SAML provider. |
| **Token** | The digital wristband. An **access token** proves who you are to an API; a **refresh token** gets you a new access token without logging in again. |

### 6.2 Why Keycloak is a stateful application pretending to be stateless

This is the subtlety that makes Keycloak harder to scale than an ordinary web app.

Keycloak keeps several **caches** in memory:
- **Session cache** — who is currently logged in
- **Authentication session cache** — people who are *mid-login* (they've submitted a username but not yet a password/OTP)
- **Realm and user caches** — configuration and user data, cached to avoid hammering the database
- **Login failure cache** — for brute-force protection

If node 1 holds your login session and you get sent to node 2, node 2 must know about it. Keycloak solves this with **Infinispan**, an in-memory distributed data grid that replicates cache entries across the cluster.

**What this means practically:**

1. **The nodes must be able to find each other.** Hence `jdbc-ping` (Section 4.10).
2. **They must be able to talk to each other.** Hence the security group rule on port 7800.
3. **A node dying loses some in-flight state.** Users mid-login may need to start over. Users already logged in are fine, because Keycloak 25+ stores user sessions persistently in the database by default.
4. **Sticky sessions reduce the pain** by keeping a user on one node, so cross-node lookups are rare.

### 6.3 The environment variables that break things when wrong

These four are responsible for the vast majority of "Keycloak deployed but login doesn't work" tickets:

**1. `KC_HOSTNAME`**

Keycloak bakes absolute URLs into tokens, redirect responses, and its OIDC discovery document. If it thinks its hostname is the EC2 instance's private IP, then:
- The discovery document advertises `http://10.0.11.47:8080/...`
- Applications try to redirect users there
- Users' browsers cannot reach a private IP
- Login hangs forever with no useful error

Set it to the **exact public URL including scheme**: `https://auth.example.com`.

**Verify it:**
```bash
curl -s https://auth.example.com/realms/master/.well-known/openid-configuration | jq -r '.issuer, .authorization_endpoint'
```
Every URL in that output must be `https://auth.example.com/...`.

**2. `KC_PROXY_HEADERS=xforwarded`**

The ALB terminates TLS, so the request that reaches Keycloak is plain HTTP. Without this setting Keycloak concludes "this connection is insecure" and either refuses cookie operations or generates `http://` URLs. With it, Keycloak reads `X-Forwarded-Proto: https` and behaves correctly.

⚠️ **Security caveat:** trusting forwarded headers is only safe because **nothing except the ALB can reach port 8080** (security group chaining). If you ever expose the instances directly, an attacker could forge those headers and spoof their source IP. This is exactly why the app tier is private.

**3. `KC_HEALTH_ENABLED=true`**

Without it, `/health/ready` returns 404, the ALB marks every instance unhealthy, the ASG (with `health_check_type = ELB`) terminates them, launches replacements, and those are also marked unhealthy. **You get an infinite instance-churn loop that burns money and never serves a request.** If you see instances cycling every ~8 minutes, check this first.

**4. `KC_DB_URL`**

Must point at the **RDS endpoint DNS name**, never an IP address. During a Multi-AZ failover, AWS changes what that DNS name resolves to. An IP address would keep pointing at the dead primary.

Also relevant: the JVM caches DNS lookups. Keycloak's container image sets a sane TTL, but if you're building a custom image, ensure `networkaddress.cache.ttl` is around 30–60 seconds so failover is picked up quickly.

### 6.4 Database connection pool math — the scaling trap

Each Keycloak node opens a pool of connections to PostgreSQL and keeps them open.

```
total connections = (number of instances) × KC_DB_POOL_MAX_SIZE
```

With our settings: 6 instances × 20 = **120 connections** at maximum scale.

PostgreSQL's `max_connections` on RDS is derived from instance memory. Roughly:

| Instance class | RAM | Approx. max_connections |
|---|---|---|
| db.t3.medium | 4 GB | ~410 |
| db.t3.large | 8 GB | ~830 |
| db.m6g.large | 8 GB | ~830 |

Check yours:
```sql
SHOW max_connections;
SELECT count(*) FROM pg_stat_activity;
```

**The trap:** an autoscaling event during a traffic spike adds instances, each of which opens 20 more connections, at exactly the moment the database is already busy. Exhausting `max_connections` causes *every* node to start failing — a scaling event turns into a total outage.

**Mitigations:**
- Keep `max_size × asg_max_size` well under `max_connections` (aim for under 50%).
- Consider **RDS Proxy**, which pools and multiplexes connections. It adds ~$15+/month and a small latency cost but removes this failure mode entirely, and it also speeds up failover.
- Size the pool for actual concurrency, not for comfort. 20 per node is generous.

### 6.5 Running Keycloak in "optimized" mode

Keycloak has a two-phase startup: a **build** phase (which compiles configuration into the image, resolving which database driver, which features, which providers) and a **run** phase.

When you run plain `start`, Keycloak checks whether a re-build is needed and may do one on every boot. That adds **20–60 seconds** to startup. Multiply by every autoscaling event.

The fix is to bake the build into your Artifactory image:

```dockerfile
FROM quay.io/keycloak/keycloak:26.4.0 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn
RUN /opt/keycloak/bin/kc.sh build --cache-stack=jdbc-ping

FROM quay.io/keycloak/keycloak:26.4.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

Then run with `start --optimized`, and Keycloak skips the build entirely. **This is the single biggest startup-time win** and directly improves how fast your ASG can respond to load.

Build it, then push to Artifactory:
```bash
docker build -t mycompany.jfrog.io/docker-local/keycloak:26.4.0-optimized .
docker push mycompany.jfrog.io/docker-local/keycloak:26.4.0-optimized
```

Note that **build-time options** (like `KC_DB` and `KC_CACHE`) are fixed in the image; **run-time options** (like `KC_DB_URL`, passwords, hostname) still come from environment variables. If you change a build-time option you must rebuild the image.

### 6.6 Database schema migrations and the concurrent-start problem

When Keycloak starts against a database whose schema is older than the code, it runs **Liquibase** migrations to update it.

If ten instances start simultaneously against an empty database, all ten try to create the schema. Liquibase uses a database lock table to serialize this, so it *usually* works — but a node that waits too long for the lock can time out and fail, and interrupted migrations can leave a stale lock that blocks all future starts.

**Best practice for a version upgrade:**

1. **Snapshot the database first.** Always.
2. Scale the ASG to a **single instance** and let it do the migration alone.
3. Verify it's healthy.
4. Scale back up.

Or, more cleanly, run migrations as an explicit separate step in your pipeline:
```bash
kc.sh bootstrap-admin ... # (not a migration, but the pattern)
kc.sh start --optimized --spi-connections-jpa-quarkus-migration-strategy=manual
```

**Also critical:** Keycloak supports upgrading one minor version at a time. Do not jump from 22 to 26 in one step. Read the migration guide for every version in between.

### 6.7 A hardening checklist for the Keycloak application itself

Infrastructure security is only half the job. Inside Keycloak:

- [ ] Delete the bootstrap admin; create named admin accounts.
- [ ] Require **OTP/MFA** for every account in the `master` realm.
- [ ] Create a separate realm for your applications. Never use `master` for end users.
- [ ] Turn on **Brute Force Detection** (Realm Settings → Security Defenses).
- [ ] Set **strict redirect URIs** on every client. Never use `*` — an open redirect lets an attacker steal authorization codes.
- [ ] Use **Authorization Code flow with PKCE** for browser and mobile apps. The old Implicit flow is deprecated and insecure.
- [ ] Set short access-token lifespans (5 minutes is typical) and rely on refresh tokens.
- [ ] Configure a **password policy**: minimum length, no username in password, and a hashing algorithm of `argon2` where available.
- [ ] Restrict the `/admin` path at the ALB if your admin console doesn't need to be public — an ALB listener rule can allow it only from your office CIDR.
- [ ] Enable Keycloak's **admin events** and **login events**, and ship them to CloudWatch or a SIEM.

---

## 7. Testing That Fault Tolerance Actually Works

**Untested fault tolerance is not fault tolerance.** It is a hope. Run these tests in a non-production environment first, then in production during a maintenance window.

### Test 1: Kill an instance

```bash
# Pick a victim
VICTIM=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT}-asg" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# Generate continuous traffic in another terminal:
# while true; do curl -s -o /dev/null -w "%{http_code} " https://auth.example.com/realms/master; sleep 1; done

aws ec2 terminate-instances --instance-ids "$VICTIM"

# Watch the recovery
watch -n 10 "aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{T:Target.Id,H:TargetHealth.State}' --output table"
```

**Expected:** Your traffic loop shows `200` continuously, with no errors. The dead instance disappears from the target group within ~45 seconds. A replacement appears within 1 minute and becomes healthy in 3–5 minutes.

**If you see errors:** either `min_size` was 1, or both instances were in the same AZ, or `deregistration_delay` is too short.

### Test 2: Break the application without killing the instance

This tests whether `health_check_type = ELB` is really working.

```bash
aws ssm start-session --target "$INSTANCE_ID"
# inside:
sudo docker stop keycloak
exit
```

**Expected:** Within ~45 seconds (3 failed checks × 15s) the ALB marks it unhealthy and stops sending traffic. Within a couple more minutes the ASG terminates and replaces it.

**If nothing happens:** your ASG health check type is still `EC2`. The VM is perfectly healthy; only the app is broken, and `EC2` health checks cannot see that. Fix it:
```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg" --health-check-type ELB
```

### Test 3: Fail the database over

```bash
aws rds reboot-db-instance \
  --db-instance-identifier "${PROJECT}-db" \
  --force-failover

# Watch for the failover event
aws rds describe-events \
  --source-identifier "${PROJECT}-db" --source-type db-instance \
  --duration 20 --query 'Events[].[Date,Message]' --output table
```

**Expected:** 60–120 seconds of database errors, then full recovery with no data loss. Keycloak's connection pool will throw errors during the gap; the health check will likely mark instances unhealthy briefly and then recover.

**What to check afterwards:** Did the instances recover on their own, or did the ASG replace all of them? If your `unhealthy_threshold` is very aggressive, a 90-second database blip can cause the ASG to kill the entire fleet, turning a 90-second degradation into a 5-minute outage. This is a real failure mode called a **retry storm** or **cascading failure**. The `unhealthy_threshold_count = 3` with a 15-second interval gives 45 seconds of tolerance — consider raising it if failovers are causing fleet-wide replacement.

### Test 4: Lose an entire Availability Zone

You can simulate this by detaching one app subnet, or more realistically by using **AWS Fault Injection Service (FIS)**, which has a purpose-built "AZ availability: power interruption" experiment template.

**Expected:** Traffic continues via the other AZ. If RDS's primary was in the lost AZ, it fails over. Capacity is halved, so you should confirm that one AZ alone can handle your peak load — which means your `min_size` should really be **2 per AZ (4 total)** if you can't tolerate degraded performance during an AZ failure.

### Test 5: Scale under load

```bash
# Install a load generator somewhere outside the VPC
# k6, hey, or vegeta all work well
hey -z 5m -c 200 https://auth.example.com/realms/master/.well-known/openid-configuration

# Watch the ASG react
watch -n 30 "aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ${PROJECT}-asg \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,InService:length(Instances)}'"
```

**Expected:** CPU climbs past 60%, a scale-out is triggered, capacity increases within ~5 minutes. When load stops, capacity slowly returns to minimum (scale-in is deliberately slower than scale-out).

**Important:** load-test the **login flow**, not just a static endpoint. Password hashing is the expensive part, and a `.well-known` document is served from cache. A realistic test uses the OIDC password grant or a headless browser.

### Test 6: Restore from backup

The most-skipped and most-important test. **A backup you have never restored is not a backup.**

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "${PROJECT}-db" \
  --target-db-instance-identifier "${PROJECT}-db-restore-test" \
  --restore-time "2026-07-25T12:00:00Z" \
  --db-subnet-group-name "${PROJECT}-db-subnets" \
  --vpc-security-group-ids "$SG_RDS" \
  --no-publicly-accessible

# ... verify the data, then DELETE THE TEST INSTANCE (it costs money)
aws rds delete-db-instance \
  --db-instance-identifier "${PROJECT}-db-restore-test" \
  --skip-final-snapshot --delete-automated-backups
```

Do this quarterly. Write down how long it took — that number is your real **Recovery Time Objective (RTO)**.

---

## 8. Pros and Cons of Every Major Choice

### 8.1 Where to run the containers: EC2 vs. ECS vs. EKS vs. Fargate

| | **EC2 + Docker** (this guide) | **ECS on Fargate** | **EKS (Kubernetes)** |
|---|---|---|---|
| **Learning curve** | Low — it's just Linux | Medium | High |
| **You manage** | OS patching, Docker, AMIs | Nothing below the container | Cluster add-ons, upgrades, CNI |
| **Deploy a new version** | ASG instance refresh (~10 min) | Rolling task update (~2 min) | `kubectl set image` (~1 min) |
| **Startup time** | 2–4 min (boot + pull + JVM) | 60–90 sec | 60–90 sec |
| **Base cost** | Instance cost only | ~20–30% premium per vCPU-hour | **+$73/mo for the control plane** |
| **Bin packing** | Poor — one big container per box | Perfect — pay per task | Good |
| **Keycloak clustering** | `jdbc-ping` | `jdbc-ping` | `dns.DNS_PING` via headless service, or the official Keycloak Operator |
| **Best for** | Teams comfortable with Linux; existing EC2 estates; special agent/kernel requirements | Most teams, most workloads | Multi-app platforms already on k8s |

**Honest assessment:** for a new Keycloak deployment with no other constraints, **ECS on Fargate is usually the better choice** than what this guide builds. You get faster deploys, no AMI patching, and no OS-level attack surface. This guide uses EC2 because it was asked for, and because EC2 makes every mechanism visible — which is much better for *learning* what the managed services are doing for you.

**Reasons EC2 genuinely wins:** you need a specific kernel module, a security agent that requires host access, GPU or specialized hardware, extremely cost-sensitive workloads where Reserved Instances or Savings Plans beat Fargate pricing, or an organization that simply hasn't approved ECS.

**A fourth option worth knowing:** the **Keycloak Operator** on Kubernetes manages Keycloak via a Custom Resource, handling clustering, upgrades, and realm imports declaratively. If you're already on EKS, that's the path of least resistance.

### 8.2 Database: RDS PostgreSQL vs. Aurora vs. self-managed

| | **RDS PostgreSQL** (this guide) | **Aurora PostgreSQL** | **Postgres on EC2** |
|---|---|---|---|
| **Failover time** | 60–120 sec | ~30 sec | Whatever you build |
| **Storage** | Fixed volume, autoscaling to a limit | Auto-grows, 6 copies across 3 AZs | You manage |
| **Read replicas** | Up to 15, async | Up to 15, ~10ms lag, shared storage | Manual |
| **Cost** | Lower | ~20–30% more (or Serverless v2 for variable load) | Cheapest hardware, most expensive humans |
| **Backups** | Automated, PITR | Automated, PITR, faster restores | Your problem |
| **Complexity** | Low | Low | High |
| **Best for** | Steady, predictable workloads like Keycloak | Bursty load, need fast failover, heavy reads | Very unusual requirements |

**Recommendation for Keycloak:** **RDS PostgreSQL Multi-AZ** is the right default. Keycloak's database load is modest and mostly writes. Aurora's advantages (read scaling, fast storage growth) don't map well onto Keycloak's access pattern, and you'd pay extra for them. Consider Aurora if you need sub-minute failover or you're running multiple large realms with heavy user-federation queries.

⚠️ **Never run Keycloak against SQLite or the embedded H2 database in production.** The Keycloak dev-mode default (`start-dev`) uses H2, which is single-node and non-durable. It exists for laptops.

### 8.3 Image registry: Artifactory vs. ECR vs. Docker Hub

| | **Artifactory** (this guide) | **Amazon ECR** | **Docker Hub** |
|---|---|---|---|
| **Auth from EC2** | Manual `docker login` with a token | Native IAM — no secret to manage | Token |
| **Pull latency in AWS** | Depends on network path | Lowest (same region, VPC endpoint) | Highest |
| **Data transfer cost** | Egress from AWS + Artifactory bandwidth | Free within the same region | Egress |
| **Vulnerability scanning** | JFrog Xray (excellent, licensed) | ECR Enhanced Scanning via Inspector | Limited |
| **Multi-cloud / on-prem** | Yes | AWS-focused | Yes |
| **Cost** | License | ~$0.10/GB/month storage | Free tier with rate limits |
| **Rate limits** | Your own | None meaningful | **Yes — a real production risk** |

**The pragmatic pattern many teams use:** Artifactory is the **source of truth** (where builds are published, scanned, and promoted through dev → staging → prod), and a small pipeline step **mirrors approved images into ECR** in each deployment region. You get Artifactory's governance and ECR's IAM-native, low-latency, zero-egress pulls.

```bash
# Mirror step in your pipeline
docker pull mycompany.jfrog.io/docker-local/keycloak:26.4.0
docker tag  mycompany.jfrog.io/docker-local/keycloak:26.4.0 \
            111122223333.dkr.ecr.us-east-1.amazonaws.com/keycloak:26.4.0
aws ecr get-login-password | docker login --username AWS --password-stdin \
            111122223333.dkr.ecr.us-east-1.amazonaws.com
docker push 111122223333.dkr.ecr.us-east-1.amazonaws.com/keycloak:26.4.0
```

**Why this matters for autoscaling:** every scale-out event pulls the image. Pulling ~500 MB from an external registry across the internet, through a NAT Gateway you pay per-GB for, at the exact moment you're under load, is a bad combination. ECR with a VPC endpoint makes the pull fast and free.

### 8.4 NAT Gateway vs. the alternatives

| Option | Monthly cost (2 AZ) | Trade-off |
|---|---|---|
| **NAT Gateway ×2** | ~$70 + $0.045/GB | Best reliability, highest cost |
| **NAT Gateway ×1** | ~$35 + data | Cheaper; one AZ's outbound depends on the other AZ |
| **NAT instance** (t4g.nano) | ~$3 | You patch it, you monitor it, limited bandwidth. Fine for dev. |
| **VPC endpoints only** | ~$7/endpoint + data | No general internet, but AWS services work. Best security. |
| **Public subnets, no NAT** | $0 | ❌ Don't. Instances get public IPs and are exposed. |

**The best-practice combination:** use **VPC endpoints** for the AWS services you need (S3 and DynamoDB gateway endpoints are free; ECR, Secrets Manager, SSM, CloudWatch Logs are interface endpoints at ~$7/month each), plus **one NAT Gateway** for OS package updates and the Artifactory pull. If you mirror images to ECR and use an ECR endpoint, you may be able to eliminate NAT entirely — which is both cheaper and more secure.

### 8.5 Sticky sessions: on or off?

| | **On** | **Off** |
|---|---|---|
| **Performance** | Better — session lookups are local | Worse — more cross-node Infinispan traffic |
| **Load distribution** | Can become uneven | Perfectly even |
| **Node failure** | That user's requests move to a new node; usually seamless | No impact |
| **Debugging** | Harder — a user always hits the same node | Easier |

**Recommendation:** on, using `lb_cookie` with a duration of about an hour. But **design as if it were off** — never let correctness depend on it, and test that killing a node doesn't break logged-in users.

### 8.6 Multi-AZ vs. Multi-Region

Everything in this guide is **Multi-AZ**: it survives one data center failing. That covers the overwhelming majority of real incidents.

**Multi-Region** survives an entire AWS region failing. It is dramatically harder:
- Keycloak's Infinispan cluster does not stretch well across regions (latency breaks the consistency assumptions). Keycloak's supported answer is **cross-site replication** in active/passive mode.
- The database needs Aurora Global Database or cross-region read replicas, with a manual or orchestrated promotion.
- You need Route 53 health-check-based failover and a plan for split-brain.

**Recommendation:** do Multi-AZ properly first. Only pursue Multi-Region if you have a written requirement with a specific RTO/RPO that Multi-AZ cannot meet, and budget for roughly double the infrastructure and a great deal of engineering time.

---

## 9. Best Practices Checklist

### Security

- [ ] **No SSH.** Use SSM Session Manager. Never open port 22.
- [ ] **IMDSv2 required** (`http_tokens = "required"`) on every launch template.
- [ ] **Security group chaining** — reference other security groups, not CIDR blocks, for internal traffic.
- [ ] **Database in a private subnet**, `publicly_accessible = false`, and reachable only from the app security group.
- [ ] **Encryption at rest** on EBS, RDS, and Secrets Manager (all effectively free).
- [ ] **Encryption in transit** — TLS 1.2+ at the ALB; `rds.force_ssl = 1` on the database parameter group.
- [ ] **No secrets in user data, launch templates, AMIs, environment files, or git.** Secrets Manager only.
- [ ] **Least-privilege IAM.** Name exact resource ARNs. Never `"Resource": "*"` for secrets.
- [ ] **Rotate credentials.** Secrets Manager can rotate RDS passwords automatically with a Lambda.
- [ ] **VPC Flow Logs** and **CloudTrail** enabled.
- [ ] **Delete the Keycloak bootstrap admin** after first login.
- [ ] **MFA on all Keycloak admin accounts** and on your AWS root and IAM users.
- [ ] Consider **AWS WAF** on the ALB with rate-limiting rules on `/realms/*/protocol/openid-connect/token` to blunt credential-stuffing attacks.
- [ ] Consider restricting `/admin` to corporate IP ranges via an ALB listener rule.

### Reliability

- [ ] **`min_size >= 2`**, spread across **at least 2 AZs**.
- [ ] **`health_check_type = "ELB"`** on the ASG, not `EC2`.
- [ ] **Grace period ≥ 300 seconds**, longer if your image is large or startup is slow.
- [ ] **RDS Multi-AZ** enabled with `deletion_protection`.
- [ ] **`deregistration_delay`** set (60s) so deploys don't drop in-flight requests.
- [ ] **`instance_refresh`** with `min_healthy_percentage = 100` for zero-downtime deploys.
- [ ] **Pin the image tag.** Never `:latest`.
- [ ] **Alarm on `HealthyHostCount < 1`** and route it to a pager, not an email nobody reads.
- [ ] **Test your failure modes** (Section 7) on a schedule, not just once.
- [ ] Know your **connection pool math** (Section 6.4).

### Cost

- [ ] **Tag everything.** Enable cost allocation tags in Billing so you can see this stack's spend.
- [ ] **Set an AWS Budget with an alert** before you build anything.
- [ ] Watch NAT Gateway data-processing charges — often the biggest surprise.
- [ ] Use **Graviton** (`t4g`, `m7g`, `db.m6g`) instance types where possible: typically 20% cheaper for similar performance. Verify your Keycloak image is multi-arch or arm64.
- [ ] Buy **Savings Plans** or **Reserved Instances** for the steady-state baseline once you know it.
- [ ] Set **CloudWatch log retention** — logs default to "never expire" and quietly accumulate cost forever.
- [ ] Scale down or destroy dev environments outside working hours. A scheduled scaling action can take dev to zero at 7pm.

**Rough monthly cost of this exact stack (us-east-1, on-demand, mid-2026 order of magnitude):**

| Item | Approx. |
|---|---|
| 2 × t3.medium EC2 | ~$60 |
| RDS db.t3.medium Multi-AZ + 20 GB gp3 | ~$130 |
| Application Load Balancer | ~$20 + LCU charges |
| 2 × NAT Gateway | ~$70 + data |
| Secrets Manager (3 secrets) | ~$1.20 |
| CloudWatch logs/metrics/alarms | ~$5–20 |
| **Total** | **~$290–320/month** |

Cutting to one NAT Gateway and a single-AZ database for a dev environment brings this to roughly **$120/month**. Always check the AWS Pricing Calculator for current, region-specific numbers.

### Operations

- [ ] **Centralize logs** (the `awslogs` driver in this guide) — instance-local logs vanish when the ASG replaces a node.
- [ ] **Dashboard the key metrics:** `HealthyHostCount`, `TargetResponseTime`, `HTTPCode_ELB_5XX_Count`, RDS `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`.
- [ ] **Write a runbook** for the top 5 alerts before you need it at 3am.
- [ ] **Version-control everything.** No manual console changes — they get silently overwritten by the next `terraform apply`.
- [ ] **Use separate AWS accounts** for dev/staging/prod. It is the strongest blast-radius control AWS offers.
- [ ] **Practice upgrades in staging** with a copy of production data (anonymized).
- [ ] **Export realm configuration regularly** as a second layer of backup beyond the database:
      `kc.sh export --dir /tmp/export --users realm_file`

---

## 10. Troubleshooting Common Problems

### Instances launch and are immediately terminated, over and over

**Cause:** the ALB health check is failing and the ASG is doing its job.

```bash
# What reason does the load balancer give?
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].TargetHealth' --output json

# What does the ASG say?
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "${PROJECT}-asg" --max-records 10 \
  --query 'Activities[].{Cause:Cause,Status:StatusCode}' --output table
```

**Check, in this order:**
1. Is `KC_HEALTH_ENABLED=true` set? (Most common cause.)
2. Does the app security group allow port **9000** from the ALB security group?
3. Is `health-check-grace-period` at least 300 seconds?
4. Read `/var/log/keycloak-bootstrap.log` on a surviving instance.

To debug without the ASG killing your evidence, **suspend the process**:
```bash
aws autoscaling suspend-processes \
  --auto-scaling-group-name "${PROJECT}-asg" \
  --scaling-processes ReplaceUnhealthy Terminate
# ... investigate ...
aws autoscaling resume-processes --auto-scaling-group-name "${PROJECT}-asg"
```

### Keycloak can't connect to the database

```bash
# From inside an instance:
nc -zv <db-endpoint> 5432          # network reachability
nslookup <db-endpoint>             # does the name resolve?
sudo docker logs keycloak 2>&1 | grep -i -E "connection|refused|timeout"
```

**Checks:** Is `enable_dns_hostnames` on for the VPC? Does `sg-rds` allow 5432 from `sg-app`? Is the RDS instance actually `available`? Did the password in Secrets Manager get rotated without the instances being refreshed?

### Login redirects to a private IP or the ALB DNS name

**Cause:** `KC_HOSTNAME` is wrong or unset.

```bash
curl -s https://auth.example.com/realms/master/.well-known/openid-configuration | jq -r '.issuer'
```
Fix the value, create a new launch template version, and trigger an instance refresh.

### Users get randomly logged out, or "invalid state" errors during login

**Cause:** the cluster isn't forming, so each node is an island.

```bash
sudo docker logs keycloak 2>&1 | grep -i -E "ISPN|jgroups|cluster|view"
```
You want to see a log line reporting a cluster **view** containing more than one member. If each node reports a view of size 1, check: the `--cache-stack=jdbc-ping` flag, `KC_CACHE=ispn`, and the port 7800 self-referencing security group rule.

### Image pull fails on boot

```bash
sudo tail -50 /var/log/keycloak-bootstrap.log
```
**Checks:** Can the instance reach the internet? (`curl -I https://mycompany.jfrog.io`) Is the NAT route present? Is the Artifactory token expired? Does the instance role have `GetSecretValue` on that specific secret ARN? Does the image tag actually exist in the repository?

### `terraform apply` says a secret name already exists

**Cause:** you destroyed and re-applied within the secret's recovery window.

```bash
aws secretsmanager list-secrets --include-planned-deletion \
  --query 'SecretList[?DeletedDate!=null].[Name,DeletedDate]' --output table

# Either restore it, or force-delete it
aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery
```
Using `name_prefix` (as in Section 5.8) prevents this from happening in the first place.

### Everything works but is very slow

- Check RDS **Performance Insights** for slow queries.
- Check EC2 **CPU credit balance** if you're on a `t3` burstable instance — running out of credits throttles you to a fraction of a vCPU.
- Check whether Keycloak is doing a **build** on every start (Section 6.5).
- Check `DatabaseConnections` against `max_connections`.
- Check whether user federation (LDAP) queries are the bottleneck.

---

## 11. How to Destroy Everything Safely

This section matters as much as the build. Two things go wrong when people tear down AWS infrastructure:

1. **They delete something they needed** — usually the database, usually with no snapshot.
2. **They think they deleted everything but didn't**, and discover a $90 bill three months later from NAT Gateways, Elastic IPs, and orphaned EBS volumes still quietly running.

The order matters, because AWS refuses to delete a resource that other resources depend on. Work **inside out**: the things that use the network go first, the network goes last.

### 11.0 The pre-destroy checklist — do this before typing any delete command

- [ ] **Confirm you are in the right AWS account and region.**
      ```bash
      aws sts get-caller-identity
      aws configure get region
      ```
      More production data has been lost to "wrong terminal window" than to any technical failure.

- [ ] **Take a manual database snapshot** and confirm it completed. Automated backups are deleted with the instance; manual snapshots survive.
      ```bash
      aws rds create-db-snapshot \
        --db-instance-identifier "${PROJECT}-db" \
        --db-snapshot-identifier "${PROJECT}-manual-$(date +%Y%m%d-%H%M%S)" \
        --tags "Key=Project,Value=${PROJECT}" "Key=Reason,Value=pre-teardown"

      aws rds wait db-snapshot-available \
        --db-snapshot-identifier "${PROJECT}-manual-<the-timestamp-you-used>"
      ```

- [ ] **Export Keycloak realm configuration** as a human-readable second backup. A database snapshot is opaque; a realm export is a JSON file you can read, diff, and re-import into a completely different Keycloak.
      ```bash
      aws ssm start-session --target "$INSTANCE_ID"
      sudo docker exec keycloak /opt/keycloak/bin/kc.sh export \
        --dir /tmp/kc-export --users realm_file
      sudo docker cp keycloak:/tmp/kc-export /tmp/kc-export
      # then copy it off the instance to S3
      ```

- [ ] **Record what you're about to delete**, so you can verify it's gone afterwards.
      ```bash
      aws resourcegroupstaggingapi get-resources \
        --tag-filters "Key=Project,Values=${PROJECT}" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text | tee pre-destroy-inventory.txt
      wc -l pre-destroy-inventory.txt
      ```

- [ ] **Check nothing else depends on this Keycloak.** Every application configured to use it will break. Search your codebase for the hostname.

- [ ] **Lower the DNS TTL** 24 hours in advance if you plan to move traffic elsewhere.

- [ ] **Tell people.** Post in the channel. Get an acknowledgment.

- [ ] **Note the current bill** so you can confirm it drops.

---

### 11.1 Destroying with Terraform

Terraform makes this much safer, because it knows the dependency graph and deletes in the correct order automatically. But the safety switches you set in Section 5 will deliberately get in your way — that's the point.

#### Step 1: Preview the destruction

```bash
cd ~/keycloak-terraform

terraform plan -destroy -out=destroy.tfplan
```

**Read the output.** It ends with a line like `Plan: 0 to add, 0 to change, 47 to destroy.`

Check that number against your expectations. If it says 3, your state file is missing things. If it says 200, you may be pointed at the wrong workspace or a shared state file containing other people's infrastructure.

```bash
# List exactly what will go, in a readable form
terraform show -json destroy.tfplan | \
  jq -r '.resource_changes[] | select(.change.actions[0]=="delete") | .address' | sort
```

#### Step 2: Deliberately disable each safety switch

You set these on purpose. Now remove them on purpose, one at a time, thinking about each.

**a) Database deletion protection and final snapshot.** Edit `terraform.tfvars`:

```hcl
enable_deletion_protection = false

# Leave this FALSE so Terraform takes a final snapshot on the way out.
# Only set it to true if you have already taken a manual snapshot
# AND you are certain the data is worthless.
db_skip_final_snapshot = false
```

Apply just that change first, so the protection flag is actually removed in AWS before you try to destroy:

```bash
terraform apply -target=aws_db_instance.main -target=aws_lb.main
```

**b) `prevent_destroy`.** If you added `lifecycle { prevent_destroy = true }` to the database, Terraform will fail with `Instance cannot be destroyed`. There is no CLI flag to override this — you **must** edit the code and delete the line. That friction is intentional. Delete the line, save, and note in your commit message why.

#### Step 3: Destroy

```bash
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

Expect **10–20 minutes**. Most of it is RDS taking its final snapshot and the NAT Gateways releasing.

#### Step 4: Handle the things Terraform commonly can't finish

Terraform destroy is usually clean, but a few resources fight back:

| Symptom | Why | Fix |
|---|---|---|
| `DependencyViolation` on a security group | The ALB's network interfaces take a few minutes to release | Wait 5 minutes, run `terraform destroy` again |
| `Subnet has dependencies and cannot be deleted` | Same — leftover ENIs | Wait, retry; if stuck, find the ENI (below) |
| Secret deletion "pending" | Recovery window, by design | Expected. Force-delete only if you're sure. |
| CloudWatch log groups remain | They may be outside state if auto-created by the `awslogs` driver | Delete manually (below) |
| RDS takes 10+ minutes | It's taking the final snapshot | Be patient; do not interrupt |

Finding a stuck network interface:
```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}' \
  --output table
```

#### Step 5: Verify Terraform's state is empty

```bash
terraform state list
# Should print nothing.
```

If entries remain, they failed to delete. Investigate before walking away.

#### Step 6: Clean up Terraform's own artifacts

```bash
# The state file still exists (now empty of resources). Keep it if you use
# a versioned S3 backend — it's a useful audit record. Locally:
ls -la terraform.tfstate*
```

⚠️ **Never delete a state file that still contains resources.** That orphans real, billable AWS infrastructure that Terraform no longer knows about, and you'll have to hunt it down by hand.

---

### 11.2 Destroying with the AWS CLI, step by step

Use this if you built with Part A, or if Terraform has left things behind. **The order below is the correct dependency order — do not skip around.**

```bash
source ~/keycloak-build/ids.env   # restore all the IDs
```

#### Step 1: Scale the Auto Scaling Group to zero

Do this **before** deleting anything else. If you delete the target group while the ASG is running, the ASG will keep trying to register instances and you'll get confusing errors.

```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg" \
  --min-size 0 --max-size 0 --desired-capacity 0

echo "Waiting for instances to terminate..."
while true; do
  COUNT=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${PROJECT}-asg" \
    --query 'length(AutoScalingGroups[0].Instances)' --output text)
  echo "  instances remaining: $COUNT"
  [ "$COUNT" = "0" ] && break
  sleep 20
done
```

**Why scale to zero first rather than force-delete?** Graceful termination lets the ALB deregister instances cleanly and lets you watch the process. Force-delete works but can leave instances briefly orphaned.

#### Step 2: Delete the Auto Scaling Group

```bash
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg"

# Verify
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "${PROJECT}-asg" \
  --query 'AutoScalingGroups' --output text
# Should print nothing
```

#### Step 3: Delete the launch template

```bash
aws ec2 delete-launch-template --launch-template-id "$LT_ID"
```

#### Step 4: Delete the ALB listeners, then the ALB, then the target group

```bash
aws elbv2 delete-listener --listener-arn "$HTTPS_LISTENER"
aws elbv2 delete-listener --listener-arn "$HTTP_LISTENER"

# If deletion protection was enabled, turn it off first
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --attributes Key=deletion_protection.enabled,Value=false

aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"

echo "Waiting for the ALB to fully release its network interfaces..."
aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN"
sleep 60   # ENIs linger a little after the API says 'deleted'

aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
```

**Why wait 60 extra seconds?** The load balancer's elastic network interfaces are removed asynchronously. If you try to delete the security group or subnets immediately, you get `DependencyViolation` and have to start guessing. Waiting is faster than debugging.

#### Step 5: Delete the RDS database — the careful part

```bash
# 5a. Remove deletion protection (deliberate act)
aws rds modify-db-instance \
  --db-instance-identifier "${PROJECT}-db" \
  --no-deletion-protection --apply-immediately

aws rds wait db-instance-available --db-instance-identifier "${PROJECT}-db"

# 5b. Delete WITH a final snapshot -- the safe default
FINAL_SNAP="${PROJECT}-final-$(date +%Y%m%d-%H%M%S)"
aws rds delete-db-instance \
  --db-instance-identifier "${PROJECT}-db" \
  --final-db-snapshot-identifier "$FINAL_SNAP"

echo "Final snapshot will be: $FINAL_SNAP  -- WRITE THIS DOWN"

aws rds wait db-instance-deleted --db-instance-identifier "${PROJECT}-db"
```

> 🔴 **The dangerous alternative.** This deletes the data permanently, with no way back:
> ```bash
> aws rds delete-db-instance \
>   --db-instance-identifier "${PROJECT}-db" \
>   --skip-final-snapshot --delete-automated-backups
> ```
> Only use this if you have already verified a manual snapshot exists, or the data is genuinely disposable (a scratch dev environment). There is no undo. AWS support cannot recover it.

**Note on automated backups:** by default they are deleted along with the instance. Manual snapshots and the final snapshot are **not** — they persist and cost about $0.095/GB-month. That's usually a few dollars a month for a small Keycloak database, and it is excellent insurance. Decide deliberately whether to keep them.

```bash
# See what snapshots you now have
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[?contains(DBInstanceIdentifier,`'"${PROJECT}"'`)].[DBSnapshotIdentifier,SnapshotCreateTime,AllocatedStorage]' \
  --output table
```

Then remove the subnet group and parameter group:
```bash
aws rds delete-db-subnet-group --db-subnet-group-name "${PROJECT}-db-subnets"
```

#### Step 6: Delete the NAT Gateways and release the Elastic IPs

**This is the step people forget, and it's the expensive one.**

```bash
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_A"
aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_B"

echo "Waiting for NAT gateways to delete (2-5 minutes)..."
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$NAT_A" "$NAT_B"

# NOW release the Elastic IPs. An unassociated EIP still costs ~$3.60/month.
aws ec2 release-address --allocation-id "$EIP_A"
aws ec2 release-address --allocation-id "$EIP_B"
```

**Order matters:** you cannot release an EIP that is still attached to a NAT Gateway. Delete the gateway, wait for it to be gone, then release.

#### Step 7: Delete route tables, subnets, internet gateway, VPC

```bash
# Route tables (the main/default one is deleted with the VPC)
for RTB in "$RTB_PUB" "$RTB_A" "$RTB_B"; do
  # Disassociate first
  ASSOCS=$(aws ec2 describe-route-tables --route-table-ids "$RTB" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text)
  for A in $ASSOCS; do aws ec2 disassociate-route-table --association-id "$A"; done
  aws ec2 delete-route-table --route-table-id "$RTB"
done

# Subnets
for S in "$PUB_A" "$PUB_B" "$APP_A" "$APP_B" "$DB_A" "$DB_B"; do
  aws ec2 delete-subnet --subnet-id "$S" && echo "deleted $S"
done

# Internet gateway: detach, then delete
aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
```

#### Step 8: Delete the security groups

Delete them in reverse dependency order. Because they reference each other, you may need to remove the cross-references first.

```bash
# Remove the rules that reference other groups
aws ec2 revoke-security-group-ingress --group-id "$SG_RDS" \
  --protocol tcp --port 5432 --source-group "$SG_APP" || true
aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 8080 --source-group "$SG_ALB" || true
aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 9000 --source-group "$SG_ALB" || true
aws ec2 revoke-security-group-ingress --group-id "$SG_APP" \
  --protocol tcp --port 7800 --source-group "$SG_APP" || true

aws ec2 delete-security-group --group-id "$SG_RDS"
aws ec2 delete-security-group --group-id "$SG_APP"
aws ec2 delete-security-group --group-id "$SG_ALB"
```

**If you get `DependencyViolation`:** something is still using the group — usually a lingering ENI from the deleted ALB. Wait a few minutes and retry, or find it:
```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ALB" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status]' --output table
```

#### Step 9: Delete the VPC

```bash
aws ec2 delete-vpc --vpc-id "$VPC_ID"
```

**If this fails, something is still inside it.** The VPC is the last thing to go, and its refusal to delete is a useful signal that you missed a resource. Find the leftovers:
```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" --output table
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Reservations[].Instances[?State.Name!=`terminated`]' --output table
```

#### Step 10: Delete IAM roles and the instance profile

IAM is global, so this is independent of the VPC — but it must be done in order.

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME"
aws iam delete-instance-profile --instance-profile-name "$ROLE_NAME"

aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${PROJECT}-read-secrets"
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

aws iam delete-role --role-name "$ROLE_NAME"
```

**You must detach every policy and remove the role from every instance profile before the role can be deleted.** AWS will tell you which one is blocking.

#### Step 11: Delete the secrets — think first

```bash
# The SAFE way: schedule deletion with a recovery window
aws secretsmanager delete-secret --secret-id "$DB_SECRET_ARN" --recovery-window-in-days 30
aws secretsmanager delete-secret --secret-id "$ART_SECRET_ARN" --recovery-window-in-days 7
aws secretsmanager delete-secret --secret-id "$KC_SECRET_ARN" --recovery-window-in-days 7
```

**Why keep the database credentials for 30 days?** Because if you ever restore that final RDS snapshot, you will need the master password. Deleting the password and keeping the snapshot gives you an encrypted box you can't open. Keep the secret at least as long as you keep the snapshot.

The immediate version, for when you're certain:
```bash
aws secretsmanager delete-secret --secret-id "$KC_SECRET_ARN" --force-delete-without-recovery
```

⚠️ **Trade-off with `--force-delete-without-recovery`:** it frees the name immediately (helpful if you plan to rebuild right away) but there is absolutely no undo.

#### Step 12: Delete DNS records and CloudWatch resources

```bash
# Route 53 - change the Action to DELETE with the EXACT same record body
# (Route 53 requires the full record definition to delete it)
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{ ...same body as when created... }}]}'

# CloudWatch log groups (these persist forever and cost money)
aws logs delete-log-group --log-group-name "/${PROJECT}/keycloak"
aws logs delete-log-group --log-group-name "/aws/vpc/${PROJECT}/flow-logs"

# Alarms
aws cloudwatch delete-alarms --alarm-names \
  "${PROJECT}-unhealthy-hosts" "${PROJECT}-NO-healthy-hosts-CRITICAL" "${PROJECT}-db-cpu-high"
```

**Note:** log groups created automatically by the Docker `awslogs` driver (`awslogs-create-group=true`) are **not** managed by Terraform, so `terraform destroy` will not remove them. Always check manually.

---

### 11.3 The orphan hunt: verifying nothing is left

Run every one of these. This is the step that prevents surprise bills.

```bash
echo "=== Running EC2 instances ==="
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table

echo "=== Unattached EBS volumes (these cost money silently) ==="
aws ec2 describe-volumes --filters "Name=status,Values=available" \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

echo "=== EBS snapshots you own ==="
aws ec2 describe-snapshots --owner-ids self \
  --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime,Description]' --output table

echo "=== Unassociated Elastic IPs (~\$3.60/mo each) ==="
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table

echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query 'NatGateways[].[NatGatewayId,State,VpcId]' --output table

echo "=== Load balancers ==="
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].[LoadBalancerName,State.Code]' --output table

echo "=== Target groups ==="
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table

echo "=== RDS instances ==="
aws rds describe-db-instances \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,MultiAZ]' --output table

echo "=== RDS snapshots (manual ones persist and cost money) ==="
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,SnapshotCreateTime]' --output table

echo "=== Secrets, including scheduled-for-deletion ==="
aws secretsmanager list-secrets --include-planned-deletion \
  --query 'SecretList[].[Name,DeletedDate]' --output table

echo "=== CloudWatch log groups matching the project ==="
aws logs describe-log-groups --log-group-name-prefix "/${PROJECT}" \
  --query 'logGroups[].[logGroupName,storedBytes,retentionInDays]' --output table

echo "=== VPCs ==="
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock,IsDefault]' --output table

echo "=== ANYTHING still tagged with this project (the catch-all) ==="
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

**The `resourcegroupstaggingapi` call at the end is the single most useful one.** If you tagged everything consistently (which is why Section 5.3 used `default_tags`), it finds anything you missed in one shot.

### 11.4 The specific things that silently keep costing money

| Resource | Cost if forgotten | Why it's easy to miss |
|---|---|---|
| **NAT Gateway** | ~$32–45/month each | Not attached to anything obvious; invisible in the EC2 instance list |
| **Elastic IP, unassociated** | ~$3.60/month each | AWS charges *specifically* for idle EIPs |
| **EBS volume, unattached** | ~$0.08/GB/month | Left behind if `delete_on_termination` was false |
| **Manual RDS snapshots** | ~$0.095/GB/month | Deliberately survive instance deletion |
| **EBS snapshots / AMIs** | ~$0.05/GB/month | Custom AMIs keep their backing snapshots |
| **CloudWatch logs** | ~$0.03/GB/month, forever | Default retention is "never expire" |
| **Load balancer** | ~$16–20/month + LCUs | Runs happily with zero targets |
| **Secrets Manager** | ~$0.40/secret/month | Tiny, so nobody notices |
| **Route 53 hosted zone** | $0.50/month | Often shared, so leave it if other records use it |

### 11.5 Confirm the bill actually dropped

```bash
# Yesterday's spend, broken down by service
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '2 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output text
```

Check this **48 hours after** the teardown. AWS billing data lags by up to a day, so an immediate check won't tell you anything. If a service you thought you deleted still shows charges, go back to Section 11.3.

**Also set a budget alarm before you build the next thing:**
```bash
# In the Billing console: Budgets → Create budget → Cost budget → $50/month
# with alerts at 50%, 80%, and 100% of forecast.
```

### 11.6 A quick reference destroy order

```
 1. ASG → desired/min/max = 0, wait for instances to drain
 2. Delete ASG
 3. Delete launch template
 4. Delete ALB listeners
 5. Delete ALB (disable deletion protection first), WAIT for ENIs
 6. Delete target group
 7. RDS: disable deletion protection → delete WITH final snapshot → wait
 8. Delete DB subnet group + parameter group
 9. Delete NAT Gateways, WAIT
10. Release Elastic IPs
11. Delete route table associations, then route tables
12. Delete subnets
13. Detach + delete internet gateway
14. Revoke cross-referencing SG rules, then delete security groups
15. Delete VPC
16. IAM: remove role from instance profile → delete profile → detach policies → delete role
17. Schedule secret deletion (keep DB creds ≥ as long as the snapshot)
18. Delete Route 53 records, CloudWatch log groups, alarms
19. Run the orphan hunt (11.3)
20. Check the bill in 48 hours (11.5)
```

---

## 12. Glossary

| Term | Plain-English meaning |
|---|---|
| **ALB** | Application Load Balancer. Traffic cop that spreads requests across servers and hides broken ones. |
| **AMI** | Amazon Machine Image. The disk template an EC2 instance boots from. |
| **ARN** | Amazon Resource Name. The globally unique ID of any AWS thing. |
| **ASG** | Auto Scaling Group. Keeps N servers running and replaces broken ones. |
| **AZ** | Availability Zone. A physically separate data center inside a region. |
| **CIDR** | The `10.0.0.0/16` notation for describing a range of IP addresses. |
| **Container** | A running copy of a Docker image. |
| **Data source** (Terraform) | Reads existing information from AWS rather than creating something. |
| **Declarative** | You describe the end state; the tool figures out the steps. |
| **Deregistration delay** | How long the ALB waits for in-flight requests before removing a server. |
| **EBS** | Elastic Block Store. Virtual hard drives for EC2. |
| **EC2** | Elastic Compute Cloud. Rented virtual servers. |
| **EIP** | Elastic IP. A static public IP address you own. |
| **ENI** | Elastic Network Interface. A virtual network card. Often the thing blocking a deletion. |
| **Health check** | A URL the load balancer calls to ask "are you OK?" |
| **HCL** | HashiCorp Configuration Language. What Terraform files are written in. |
| **IAM** | Identity and Access Management. Who is allowed to do what in AWS. |
| **Idempotent** | Running it twice has the same effect as running it once. |
| **IGW** | Internet Gateway. The VPC's front door to the internet. |
| **IMDSv2** | The secure version of the EC2 metadata service. Always require it. |
| **Infinispan** | The distributed in-memory cache Keycloak uses to share sessions between nodes. |
| **Instance profile** | The wrapper that lets an EC2 instance use an IAM role. |
| **JDBC** | The standard Java way of connecting to a database. |
| **JDBC_PING** | Cluster discovery via a database table instead of network multicast. Essential on AWS. |
| **JWT** | JSON Web Token. The signed "wristband" Keycloak issues. |
| **Launch template** | The recipe an ASG uses to build each new server. |
| **Least privilege** | Grant only the permissions actually needed, nothing more. |
| **Liquibase** | The tool Keycloak uses to update its database schema. |
| **Multi-AZ** | Running a duplicate in a second data center for survivability. |
| **NAT Gateway** | Lets private servers reach out to the internet without being reachable from it. |
| **OIDC** | OpenID Connect. The modern "log in with" standard. |
| **PITR** | Point-in-time recovery. Restore a database to any second within the backup window. |
| **RDS** | Relational Database Service. AWS-managed databases. |
| **Realm** | An isolated tenant inside Keycloak. |
| **RPO** | Recovery Point Objective. How much data you can afford to lose. |
| **RTO** | Recovery Time Objective. How long you can afford to be down. |
| **Route table** | The list of "traffic for X goes to Y" rules for a subnet. |
| **SAML** | An older XML-based single-sign-on standard. |
| **Security group** | A stateful firewall attached to a resource. |
| **Sticky session** | Keeping one user pinned to one server via a cookie. |
| **SSM Session Manager** | Browser/CLI shell access to an instance without SSH or open ports. |
| **SSO** | Single Sign-On. Log in once, access many applications. |
| **SSRF** | Server-Side Request Forgery. An attack IMDSv2 defends against. |
| **State file** | Terraform's record of what it has created. Precious; protect it. |
| **Subnet** | A slice of a VPC that lives in exactly one Availability Zone. |
| **Target group** | The ALB's list of servers, plus the health-check rules for them. |
| **Target tracking** | Autoscaling that works like a thermostat: set a goal, AWS holds it. |
| **TLS termination** | The load balancer handles encryption so the servers don't have to. |
| **User data** | A script that runs on an EC2 instance's first boot. Treat as public. |
| **VPC** | Virtual Private Cloud. Your own isolated network inside AWS. |

---

## Where to Go Next

- **Official Keycloak docs**, especially the *Configuring Keycloak for production* and *Configuring distributed caches* guides — always check these against the exact version tag you deploy, since option names have changed meaningfully between versions 22 and 26.
- **AWS Well-Architected Framework**, particularly the Reliability and Security pillars.
- **Terraform AWS modules** — `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/rds/aws` are battle-tested and would replace several hundred lines of the code in Section 5. Writing it out by hand once, as you did here, is the best way to understand what those modules are doing for you.
- **AWS Fault Injection Service** for automating the chaos tests in Section 7.
- **RDS Proxy** if you expect to scale past a handful of Keycloak nodes.

---

*One final piece of advice: build this in a scratch AWS account first, destroy it completely, and confirm the bill returns to zero. Doing the full build-and-destroy cycle once, before it matters, is worth more than reading this document three times.*
