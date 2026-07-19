# AWS Networking, Explained Like You're New

**A step-by-step tutorial: from typing a web address to running pods in Kubernetes.**

---

## Table of Contents

1. [What This Tutorial Covers](#1-what-this-tutorial-covers)
2. [Background: What Even Is a Network?](#2-background-what-even-is-a-network)
3. [The Big Picture: What Happens When You Visit a Website](#3-the-big-picture-what-happens-when-you-visit-a-website)
4. [Part One: Build It Yourself (Step-by-Step)](#4-part-one-build-it-yourself-step-by-step)
5. [Part Two: The VPC, Explained Properly](#5-part-two-the-vpc-explained-properly)
6. [Part Three: Subnets — Public and Private](#6-part-three-subnets--public-and-private)
7. [Part Four: Route Tables — The Signposts](#7-part-four-route-tables--the-signposts)
8. [Part Five: Gateways — The Doors In and Out](#8-part-five-gateways--the-doors-in-and-out)
9. [Part Six: Security Groups and NACLs — The Guards](#9-part-six-security-groups-and-nacls--the-guards)
10. [Part Seven: EC2 Network Settings Up Close](#10-part-seven-ec2-network-settings-up-close)
11. [Part Eight: Load Balancers and Target Groups](#11-part-eight-load-balancers-and-target-groups)
12. [Part Nine: DNS — Public and Private](#12-part-nine-dns--public-and-private)
13. [Part Ten: VPC Endpoints — Private Doors to AWS](#13-part-ten-vpc-endpoints--private-doors-to-aws)
14. [Part Eleven: Connecting VPCs Together](#14-part-eleven-connecting-vpcs-together)
15. [Part Twelve: EKS and Kubernetes Pod Networking](#15-part-twelve-eks-and-kubernetes-pod-networking)
16. [Part Thirteen: Following One Request All The Way Through](#16-part-thirteen-following-one-request-all-the-way-through)
17. [Best Practices Cheat Sheet](#17-best-practices-cheat-sheet)
18. [Common Problems and How to Fix Them](#18-common-problems-and-how-to-fix-them)
19. [Glossary](#19-glossary)

---

## 1. What This Tutorial Covers

By the end of this you will understand:

- How a web browser on someone's phone reaches a server sitting inside Amazon's data center
- What a **VPC** is and why every AWS account needs one
- The difference between **public** and **private** networks, and why private is safer
- How **route tables**, **gateways**, **security groups**, and **NACLs** work together
- What **target groups** and **load balancers** actually do
- How **DNS** works, both the public internet kind and the private internal kind
- The **EC2 settings** that matter for networking
- How **EKS** (Kubernetes) gives every pod its own IP address, and why that's a big deal

**Who this is for:** Anyone who has never touched AWS, or who has clicked around the console and felt lost. No prior networking knowledge needed.

**A note on style:** I'm going to use a lot of comparisons to buildings, mail, and streets. Networks really do work like cities, and the comparison holds up better than you'd expect.

---

## 2. Background: What Even Is a Network?

### 2.1 Computers need addresses

Imagine you want to mail a letter to a friend. You need their address. Without it, the post office has no idea where to take your envelope.

Computers work the same way. Every computer on a network has an address called an **IP address**. It looks like this:

```
192.168.1.50
```

Four numbers, each between 0 and 255, separated by dots. That's **IPv4**, the most common kind. (There's a newer kind called IPv6 with longer addresses — we'll touch on it later.)

### 2.2 Two kinds of IP addresses

This is the single most important idea in this whole tutorial, so let's slow down.

**Public IP addresses** are unique across the entire internet. Like a street address in the real world — there is only one "1600 Pennsylvania Avenue, Washington DC." If you have a public IP, anyone in the world can (in theory) send you a message.

**Private IP addresses** are only unique *inside one building*. Like apartment numbers. There are millions of "Apartment 3B" in the world. That's fine, because you only use "3B" once you're already inside the right building.

Certain IP ranges are reserved forever as private. These are the ones you'll see constantly:

| Range | How many addresses | Where you'll see it |
|---|---|---|
| `10.0.0.0` – `10.255.255.255` | ~16.7 million | Most AWS VPCs. This is the big one. |
| `172.16.0.0` – `172.31.255.255` | ~1 million | AWS default VPCs use `172.31.x.x` |
| `192.168.0.0` – `192.168.255.255` | ~65,000 | Your home WiFi router |

Your laptop at home almost certainly has an address like `192.168.1.x` right now. That address means nothing to the rest of the internet. Your home router translates it when you go online.

### 2.3 CIDR notation — the slash number

You will see addresses written like this:

```
10.0.0.0/16
```

That `/16` on the end is **CIDR notation**. It tells you how big the block of addresses is.

Think of an IP address as four boxes: `[10].[0].[0].[0]`. Each box holds 8 "bits" of information, so all four together hold 32 bits.

The slash number says: **"this many bits from the left are locked and cannot change."** Everything after is free to vary.

```
10.0.0.0/16
        ↑
   First 16 bits locked = first two boxes locked
   
   Locked:    10  .  0  .  ?  .  ?
   Free:                  0-255  0-255
   
   So this covers 10.0.0.0 through 10.0.255.255
   That's 256 × 256 = 65,536 addresses
```

Quick reference table — memorize the first three rows and you'll be fine:

| CIDR | Addresses | Plain English |
|---|---|---|
| `/32` | 1 | Exactly one computer |
| `/24` | 256 | A small subnet, ~251 usable in AWS |
| `/16` | 65,536 | A whole VPC, typical size |
| `/8` | 16,777,216 | Enormous, rarely used |
| `0.0.0.0/0` | Everything | "The entire internet, all addresses" |

**Rule of thumb:** smaller slash number = bigger block. `/16` is much bigger than `/24`.

That last one, `0.0.0.0/0`, shows up everywhere in AWS. It's shorthand for "anywhere at all." When you see it in a route table it means "any destination." When you see it in a security group it means "from anyone in the world."

### 2.4 Ports — apartment doors

One computer can run many programs at once. A web server, a database, an email server. So how does an incoming message know which program it's for?

**Ports.** A port is a number from 1 to 65535 attached to the address.

```
10.0.1.50:443
└────────┘ └─┘
  which     which
 computer  program
```

Standard ports you should know:

| Port | Used for |
|---|---|
| 22 | SSH (remote login to a Linux server) |
| 80 | HTTP (unencrypted web) |
| 443 | HTTPS (encrypted web) — the important one |
| 3306 | MySQL database |
| 5432 | PostgreSQL database |
| 6379 | Redis |

So `10.0.1.50:443` means "the web server program, on the computer at 10.0.1.50."

### 2.5 A quick word on protocols

**TCP** is the delivery method that guarantees arrival. It's like certified mail — the recipient confirms each piece, and anything lost gets re-sent. Web traffic, databases, SSH all use TCP.

**UDP** is fire-and-forget. Faster, no confirmation. Used for video streaming, gaming, and DNS lookups.

**ICMP** is the protocol behind `ping`. It's for network diagnostics, not carrying real data. Worth knowing because if `ping` fails but the website works, that's usually just ICMP being blocked on purpose.

---

## 3. The Big Picture: What Happens When You Visit a Website

Before we build anything, let's see the whole journey. Someone opens their phone and types `shop.example.com`.

```
┌─────────────┐
│   Phone     │  1. "What's the IP for shop.example.com?"
│  (browser)  │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│    DNS      │  2. "It's 54.239.28.85"
│  (Route 53) │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────────────────┐
│              AWS REGION (us-east-1)                 │
│                                                     │
│  ┌────────────────┐                                 │
│  │Internet Gateway│  3. Traffic enters AWS          │
│  └───────┬────────┘                                 │
│          │                                          │
│  ┌───────▼──────────────────────────────────────┐   │
│  │        VPC  10.0.0.0/16                      │   │
│  │                                              │   │
│  │  ┌─────────────────────────────────────┐     │   │
│  │  │ PUBLIC SUBNET  10.0.1.0/24          │     │   │
│  │  │                                     │     │   │
│  │  │   ┌───────────────────────────┐     │     │   │
│  │  │   │  Application Load Balancer│  4. │     │   │
│  │  │   └────────────┬──────────────┘     │     │   │
│  │  └────────────────┼────────────────────┘     │   │
│  │                   │                          │   │
│  │                   │  5. Forward to healthy   │   │
│  │                   │     target               │   │
│  │  ┌────────────────▼────────────────────┐     │   │
│  │  │ PRIVATE SUBNET  10.0.10.0/24        │     │   │
│  │  │                                     │     │   │
│  │  │   ┌──────────┐    ┌──────────┐      │     │   │
│  │  │   │ Server 1 │    │ Server 2 │  6.  │     │   │
│  │  │   │10.0.10.5 │    │10.0.10.6 │      │     │   │
│  │  │   └────┬─────┘    └──────────┘      │     │   │
│  │  └────────┼────────────────────────────┘     │   │
│  │           │                                  │   │
│  │           │  7. Look up database address     │   │
│  │           │     via private DNS              │   │
│  │  ┌────────▼────────────────────────────┐     │   │
│  │  │ PRIVATE SUBNET  10.0.20.0/24        │     │   │
│  │  │                                     │     │   │
│  │  │   ┌──────────────────────────┐      │     │   │
│  │  │   │  Database  10.0.20.100   │  8.  │     │   │
│  │  │   └──────────────────────────┘      │     │   │
│  │  └─────────────────────────────────────┘     │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

The eight steps:

1. **Browser asks DNS** for the IP address behind the name
2. **DNS answers** with the load balancer's public IP
3. **Traffic enters AWS** through an Internet Gateway
4. **Load balancer receives** the request in a public subnet
5. **Load balancer picks a healthy server** from its target group
6. **Server processes** the request — it lives in a private subnet with no public IP at all
7. **Server needs data**, so it looks up the database name using private DNS
8. **Database answers** — it's in an even more locked-down subnet

Notice what's happening here: **the servers and database have no public IP addresses.** Nobody on the internet can reach them directly. The only thing exposed to the world is the load balancer. That's the core security pattern of AWS, and everything else in this tutorial supports it.

---

## 4. Part One: Build It Yourself (Step-by-Step)

Enough theory. Let's build the thing in the diagram above. I'll give you both console clicks and CLI commands.

**What we're building:** A web server that the world can reach, sitting safely in a private subnet behind a load balancer.

**What it costs:** The load balancer runs about $16/month, the NAT Gateway about $32/month, and a `t3.micro` EC2 instance is free-tier eligible for the first year. **Delete everything at the end of this section if you're just practicing** — see Step 12.

**Time needed:** About 45 minutes.

### Prerequisites

- An AWS account
- The AWS CLI installed, if you want to follow the command-line version:

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Check it worked
aws --version
# Should print something like: aws-cli/2.x.x

# Set up your credentials
aws configure
```

---

### Step 1: Create the VPC

The VPC is your private section of the AWS cloud. Nothing else can be built until this exists.

**Console:** VPC service → *Your VPCs* → *Create VPC* → choose **VPC only** (we're doing this manually to learn; the "VPC and more" wizard does it all at once, which we'll discuss at the end).

- Name: `tutorial-vpc`
- IPv4 CIDR: `10.0.0.0/16`
- Tenancy: Default

**CLI:**

```bash
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=tutorial-vpc}]'
```

Save the VPC ID it returns (looks like `vpc-0a1b2c3d4e5f`). We'll call it `$VPC_ID`.

```bash
# Handy trick — store it in a shell variable
export VPC_ID=vpc-0a1b2c3d4e5f
```

**Why `10.0.0.0/16`?** It gives you 65,536 addresses, which is plenty for almost any project, and leaves room to add subnets later without running out. Using a `/16` is the standard convention.

---

### Step 2: Turn on DNS features

This is easy to miss and causes confusing bugs later. Two settings control whether things inside your VPC can use hostnames.

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
```

**Console:** Select the VPC → *Actions* → *Edit VPC settings* → tick both DNS boxes.

- **enableDnsSupport** — lets instances ask the built-in AWS DNS server for answers. Default is on.
- **enableDnsHostnames** — gives instances actual DNS names. **Default is OFF for VPCs you create yourself.** Turn it on. Without it, VPC endpoints and RDS private names won't resolve properly.

---

### Step 3: Create four subnets

A subnet is a slice of your VPC that lives in one physical data center (called an **Availability Zone**, or AZ). We want two AZs for redundancy, and public + private in each.

```bash
# Public subnets — these will host the load balancer
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-1a}]'

aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-1b}]'

# Private subnets — these will host the actual servers
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.10.0/24 \
  --availability-zone us-east-1a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-1a}]'

aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 \
  --availability-zone us-east-1b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-1b}]'
```

Save all four subnet IDs.

**Why two AZs?** An Availability Zone is a real building. Buildings occasionally lose power, flood, or catch fire. If everything you own is in `us-east-1a` and `us-east-1a` goes down, you go down. Two AZs means you survive losing one. **Application Load Balancers actually require at least two AZs — AWS won't let you create one otherwise.**

**Why did I number them 1, 2, 10, 11?** Pure convention, but a useful one. Low numbers for public, higher numbers for private, so you can tell at a glance what a subnet is just from its address. Some teams use `10.0.0.x` for public and `10.0.100.x` for private. Pick a scheme and stick to it.

**AWS reserves 5 addresses in every subnet.** In `10.0.1.0/24` you get 256 addresses but only 251 usable:

| Address | Reserved for |
|---|---|
| `10.0.1.0` | Network address (always reserved, standard networking) |
| `10.0.1.1` | The VPC router |
| `10.0.1.2` | AWS DNS server (remember this one — it matters later) |
| `10.0.1.3` | Reserved for future use |
| `10.0.1.255` | Broadcast address (reserved, though VPCs don't use broadcast) |

---

### Step 4: Create an Internet Gateway

This is the door between your VPC and the internet. Without it, nothing gets in or out.

```bash
aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=tutorial-igw}]'

# Then attach it to the VPC
export IGW_ID=igw-0a1b2c3d4e5f
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
```

An Internet Gateway is a slightly odd thing — it isn't a server, it has no IP address, and it can't fail or get overloaded. AWS runs it as a redundant, horizontally-scaled service. Think of it as a permanent doorway rather than a machine.

**Creating and attaching it does NOT automatically give anything internet access.** You also need route table entries, which is the next step. This trips up beginners constantly.

---

### Step 5: Create route tables

A route table is a list of signposts. Every subnet gets one. When a packet leaves a machine, the route table decides where it goes.

**Public route table:**

```bash
aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]'

export PUB_RT=rtb-0aaa...

# The critical line: send everything not local to the internet gateway
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

# Attach it to both public subnets
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id subnet-public1a
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id subnet-public1b
```

That route table now says:

| Destination | Target | Meaning |
|---|---|---|
| `10.0.0.0/16` | `local` | Anything inside my VPC — deliver directly (this is added automatically and cannot be deleted) |
| `0.0.0.0/0` | `igw-xxx` | Anything else — send to the internet |

**This is the actual definition of a "public subnet."** There's no checkbox called "make public." A subnet is public if and only if its route table has a `0.0.0.0/0` route pointing at an Internet Gateway. That's it. That's the whole thing.

**Private route table:**

```bash
aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=private-rt}]'

export PRIV_RT=rtb-0bbb...

aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id subnet-private1a
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id subnet-private1b
```

Note we added **no** `0.0.0.0/0` route. Right now the private subnets can talk within the VPC and nowhere else. We'll fix outbound access in the next step.

---

### Step 6: Create a NAT Gateway

Our private servers still need to reach the internet *outbound* — to download security patches, call third-party APIs, pull container images. But we don't want the internet reaching *in*.

A **NAT Gateway** does exactly that: one-way outbound access.

```bash
# NAT Gateways need a public IP of their own
aws ec2 allocate-address --domain vpc
export EIP_ALLOC=eipalloc-0aaa...

# Create it IN A PUBLIC SUBNET (this is the part people get wrong)
aws ec2 create-nat-gateway \
  --subnet-id subnet-public1a \
  --allocation-id $EIP_ALLOC \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=tutorial-nat}]'

export NAT_ID=nat-0aaa...

# Now point the private route table at it
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_ID
```

**The NAT Gateway lives in a PUBLIC subnet but serves the PRIVATE subnets.** This confuses everybody at first. Think of it as a receptionist in the lobby: people in the back offices hand her their outgoing mail, she walks it out the front door. She sits at the front, but she works for the back.

**How NAT works, mechanically:**

```
Private server 10.0.10.5 wants to reach api.stripe.com
        │
        │  Source: 10.0.10.5    Destination: 54.x.x.x
        ▼
   NAT Gateway (public IP 3.88.1.20)
        │
        │  REWRITES the source address:
        │  Source: 3.88.1.20    Destination: 54.x.x.x
        ▼
     Internet ──► Stripe sees the request coming from 3.88.1.20
                  and replies to 3.88.1.20

   NAT Gateway remembers this conversation, so when the reply
   comes back it knows to forward it to 10.0.10.5.

   But Stripe CANNOT start a new conversation with 10.0.10.5.
   It has no idea that address exists. That's the security win.
```

⚠️ **Cost warning:** NAT Gateways cost roughly **$32/month** plus about **$0.045 per GB** of data processed. On a real production system the data charges often exceed the hourly charge. This is one of the most common surprise items on an AWS bill. See Part Ten for how VPC Endpoints cut this dramatically.

💡 **Money-saving option:** For dev environments, run **one** NAT Gateway and point both private subnets at it. You lose AZ redundancy (if that AZ dies, both private subnets lose outbound internet) but you halve the cost. For production, run one per AZ.

---

### Step 7: Create security groups

Security groups are firewalls attached to individual resources. We need two: one for the load balancer, one for the servers.

```bash
# --- Load balancer security group: open to the world on 443 and 80 ---
aws ec2 create-security-group \
  --group-name alb-sg \
  --description "Allow web traffic from internet" \
  --vpc-id $VPC_ID

export ALB_SG=sg-0aaa...

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0


# --- Server security group: ONLY accepts traffic from the load balancer ---
aws ec2 create-security-group \
  --group-name app-sg \
  --description "Allow traffic from ALB only" \
  --vpc-id $VPC_ID

export APP_SG=sg-0bbb...

# Notice: --source-group, not --cidr
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG
```

**That last command is the single best trick in AWS networking.** Instead of saying "allow traffic from IP range X," you say **"allow traffic from anything wearing this security group badge."**

Why that's better:

- You never have to update it when IPs change
- Load balancers change IPs regularly — this survives that automatically
- It reads like a sentence: "app servers accept traffic from load balancers"
- Auto-scaling adds and removes servers freely without any rule changes

**Security groups are stateful.** If you allow traffic in, the reply is automatically allowed back out. You do not need a matching outbound rule. This is different from NACLs, which we'll cover shortly.

**Default behavior to memorize:**

| Direction | Default |
|---|---|
| Inbound | Deny everything (you must explicitly allow) |
| Outbound | Allow everything (you may restrict if you want) |

---

### Step 8: Launch EC2 instances

Now the actual servers. These go in the **private** subnets with **no public IP**.

```bash
aws ec2 run-instances \
  --image-id ami-0abcdef1234567890 \
  --instance-type t3.micro \
  --subnet-id subnet-private1a \
  --security-group-ids $APP_SG \
  --no-associate-public-ip-address \
  --iam-instance-profile Name=SSMInstanceProfile \
  --user-data file://startup.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=app-server-1}]'
```

Here's a `startup.sh` that installs a tiny web server so we have something to test:

```bash
#!/bin/bash
dnf install -y python3
mkdir -p /var/www && cd /var/www
echo "Hello from $(hostname -f)" > index.html
python3 -m http.server 8080 --directory /var/www &
```

Key flags explained:

- `--no-associate-public-ip-address` — **the whole point.** No public IP means the internet cannot reach this machine directly, ever.
- `--iam-instance-profile` — lets you connect via **SSM Session Manager** instead of SSH. More on this next.
- `--user-data` — a script that runs once on first boot

Repeat for `subnet-private1b` so you have a server in each AZ.

---

### Step 9: How do you log in with no public IP?

Old way: put a "bastion host" (a small public server) in the public subnet, SSH into it, then SSH from there to your private servers. It works, but it's an extra machine to patch, an extra SSH key to lose, and an extra open port on the internet.

**Current best practice: AWS Systems Manager Session Manager.** No open ports at all, no SSH keys, no bastion.

```bash
aws ssm start-session --target i-0a1b2c3d4e5f
```

You get a shell. No inbound rules needed anywhere.

How it works: an agent on the instance (pre-installed on Amazon Linux, Ubuntu, and Windows AMIs) makes an **outbound** connection to the SSM service. You connect to the SSM service too, and it bridges you together. Since the connection is outbound-initiated from the instance, no firewall hole is needed.

Requirements:
1. Instance has an IAM role with the `AmazonSSMManagedInstanceCore` policy
2. Instance can reach the SSM service — either via NAT Gateway, or via VPC Endpoints (Part Ten)

**Pros vs. bastion host:**

| | SSM Session Manager | Bastion Host |
|---|---|---|
| Open ports | None | Port 22 exposed |
| SSH keys to manage | None | Yes |
| Extra servers to patch | None | Yes |
| Every command logged | Yes, automatically to CloudWatch/S3 | Only if you set it up |
| Cost | Free | ~$8/month + effort |
| Works with any tool | Needs SSM plugin for port forwarding | Standard SSH, works everywhere |

Use SSM unless you have a strong reason not to.

---

### Step 10: Create a target group

A **target group** is a named list of servers plus instructions for checking whether they're healthy.

```bash
aws elbv2 create-target-group \
  --name app-targets \
  --protocol HTTP \
  --port 8080 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2

export TG_ARN=arn:aws:elasticloadbalancing:...

# Register the servers
aws elbv2 register-targets --target-group-arn $TG_ARN \
  --targets Id=i-0aaa... Id=i-0bbb...
```

The health check is the important part. Every 15 seconds, the load balancer sends `GET /health` to each server. Two failures in a row and that server stops receiving traffic. Two successes and it comes back.

**Make sure your app actually has a `/health` endpoint that returns HTTP 200.** If it returns 404, every target will be marked unhealthy and your load balancer will return `503 Service Unavailable` to everyone. This is probably the #1 "my ALB doesn't work" cause.

---

### Step 11: Create the load balancer

```bash
aws elbv2 create-load-balancer \
  --name tutorial-alb \
  --type application \
  --scheme internet-facing \
  --subnets subnet-public1a subnet-public1b \
  --security-groups $ALB_SG

export ALB_ARN=arn:aws:elasticloadbalancing:...

# Add a listener — this is what actually accepts connections
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS \
  --port 443 \
  --certificates CertificateArn=arn:aws:acm:... \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN
```

Note: `--subnets` uses the **public** subnets. The load balancer is the public face; the servers behind it stay private.

The **listener** is the piece that says "listen on port 443, and when something arrives, forward it to this target group." A load balancer with no listener does nothing at all.

Get your load balancer's DNS name:

```bash
aws elbv2 describe-load-balancers --names tutorial-alb \
  --query 'LoadBalancers[0].DNSName' --output text
# tutorial-alb-1234567890.us-east-1.elb.amazonaws.com
```

Open that in a browser. You should see "Hello from ip-10-0-10-5.ec2.internal."

🎉 **You just built a production-shaped architecture.** Traffic from the internet, through a load balancer, to servers that have no public exposure whatsoever.

---

### Step 12: Clean up (do this if you're just practicing!)

Delete in this order — AWS won't let you delete things that others depend on:

```bash
# 1. Load balancer and target group
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# 2. EC2 instances
aws ec2 terminate-instances --instance-ids i-0aaa... i-0bbb...

# 3. NAT Gateway (takes a few minutes) and its Elastic IP
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_ID
# WAIT for it to finish deleting, then:
aws ec2 release-address --allocation-id $EIP_ALLOC

# 4. Internet Gateway
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID

# 5. Subnets, route tables, security groups
aws ec2 delete-subnet --subnet-id subnet-...   # ×4
aws ec2 delete-route-table --route-table-id $PUB_RT
aws ec2 delete-route-table --route-table-id $PRIV_RT
aws ec2 delete-security-group --group-id $APP_SG
aws ec2 delete-security-group --group-id $ALB_SG

# 6. Finally the VPC
aws ec2 delete-vpc --vpc-id $VPC_ID
```

**The most expensive thing to forget is the NAT Gateway.** It bills by the hour whether you use it or not. Check the AWS Cost Explorer a day later to make sure you're at zero.

---

### A note on doing this the easy way

You just did it manually to learn the pieces. In real life, you'd use:

**The VPC Wizard** (Console → Create VPC → "VPC and more"): builds subnets, route tables, IGW, and NAT Gateway in about 90 seconds. Great for getting started.

**Infrastructure as Code** — Terraform, CloudFormation, or AWS CDK. Your entire network becomes a text file you can version-control, review, and recreate identically. Here's the same VPC in Terraform, for a sense of it:

```hcl
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "tutorial-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24",  "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # false for production
  enable_dns_hostnames = true
}
```

That's the entire network. **Nobody builds production networks by clicking.** But you needed to click once to understand what the code is doing.


---

## 5. Part Two: The VPC, Explained Properly

### 5.1 What a VPC actually is

**VPC** stands for **Virtual Private Cloud**. It is your own isolated network inside AWS.

The physical reality: AWS has enormous data centers with hundreds of thousands of servers, all shared among millions of customers. Your servers and Netflix's servers might literally be in the same rack. The VPC is the software layer that makes it *feel* like you have your own private data center.

AWS implements this with something called **Mapping Service** — a giant distributed lookup table. When your instance sends a packet to `10.0.10.6`, the hypervisor intercepts it, checks the mapping service to find which physical host owns that VPC-address pair, wraps the packet in an outer packet addressed to that physical host, and sends it. The receiving host unwraps it and delivers it. Your `10.0.10.6` and another customer's `10.0.10.6` never collide because the VPC ID is part of the lookup.

You don't need to know that to use AWS. But it explains a few things:
- Why VPC traffic can't be sniffed by other customers (it's encapsulated and the physical network never sees your addresses)
- Why "broadcast" and "multicast" don't work normally in a VPC (there's no shared physical segment)
- Why you can't run your own DHCP server on a VPC subnet (AWS controls address assignment)

### 5.2 Regions and Availability Zones

```
┌───────────────────────────────────────────────────┐
│  REGION: us-east-1 (Northern Virginia)            │
│                                                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐   │
│  │ AZ us-east │  │ AZ us-east │  │ AZ us-east │   │
│  │    -1a     │  │    -1b     │  │    -1c     │   │
│  │            │  │            │  │            │   │
│  │ Physical   │  │ Physical   │  │ Physical   │   │
│  │ building   │  │ building   │  │ building   │   │
│  │ ~30km away │  │ ~30km away │  │ ~30km away │   │
│  └────────────┘  └────────────┘  └────────────┘   │
│         └───────────────┴───────────────┘         │
│         Connected by private fiber,                │
│         <2ms latency between them                  │
└───────────────────────────────────────────────────┘
```

- A **Region** is a geographic area. `us-east-1` is Virginia, `eu-west-1` is Ireland, `ap-southeast-2` is Sydney. There are 30+ regions worldwide.
- An **Availability Zone** is one or more physical data centers within a region, with independent power, cooling, and networking. Most regions have 3 to 6.

**A VPC spans a whole region.** It exists in every AZ of that region simultaneously.
**A subnet exists in exactly one AZ.** This is the key constraint that drives your whole design.

⚠️ **AZ names are shuffled per account.** Your `us-east-1a` and my `us-east-1a` are probably different physical buildings. AWS does this so everyone doesn't pile into "a". If you need the real, consistent identifier, use the **AZ ID** (`use1-az1`, `use1-az2`) which is the same across all accounts. This matters when sharing subnets between accounts.

### 5.3 Choosing your CIDR block

You pick this once, and changing it later is painful. Some guidance:

**Pick from the private ranges:**

| Range | Notes |
|---|---|
| `10.0.0.0/8` | Biggest space, most flexible. **Recommended.** |
| `172.16.0.0/12` | Fine, but AWS default VPCs use `172.31.x.x` — avoid that specific chunk |
| `192.168.0.0/16` | Small, and collides with home/office networks constantly. Avoid for AWS. |

**Size it as a `/16`.** AWS allows `/16` (65,536 addresses) down to `/28` (16 addresses). A `/16` is the standard choice — it costs nothing extra and saves you from running out.

**The overlap rule:** if two VPCs might ever need to talk to each other, or connect to your office network, **their CIDR blocks must not overlap.** Two VPCs both using `10.0.0.0/16` can never be peered. Ever. You'd have to rebuild one.

So plan a scheme up front:

```
10.0.0.0/16    →  production, us-east-1
10.1.0.0/16    →  production, eu-west-1
10.10.0.0/16   →  staging
10.20.0.0/16   →  development
10.100.0.0/16  →  shared services (logging, CI, monitoring)
172.16.0.0/16  →  on-premises office network
```

Write this down somewhere permanent before you create your first VPC. Companies have spent months untangling overlapping CIDRs after a merger.

**You can add secondary CIDR blocks later** if you run out — up to 5 total per VPC. But they still can't overlap with anything you connect to, so it's a patch, not a fix.

### 5.4 The default VPC

Every new AWS account comes with a default VPC in every region, using `172.31.0.0/16`. All its subnets are public, and instances launched there get public IPs automatically.

**Convenient for a five-minute experiment. Not appropriate for anything real.** Every instance is directly internet-exposed by default. Build your own VPC for anything that matters.

---

## 6. Part Three: Subnets — Public and Private

### 6.1 The definition, one more time

A subnet is **public** if its route table sends `0.0.0.0/0` to an **Internet Gateway**.
A subnet is **private** if it doesn't.

That's the entire distinction. There is no checkbox, no setting, no label. It's purely a consequence of routing.

### 6.2 The three-tier pattern

The standard layout for a real application:

```
┌──────────────────────────────────────────────────────┐
│                   VPC 10.0.0.0/16                    │
│                                                      │
│  TIER 1 — PUBLIC SUBNETS  (10.0.1.0/24, 10.0.2.0/24) │
│  ┌────────────────────────────────────────────────┐  │
│  │  • Load balancers                              │  │
│  │  • NAT Gateways                                │  │
│  │  • Bastion hosts (if you still use them)       │  │
│  │                                                │  │
│  │  Route: 0.0.0.0/0 → Internet Gateway           │  │
│  └────────────────────────────────────────────────┘  │
│                          │                           │
│  TIER 2 — PRIVATE APP  (10.0.10.0/24, 10.0.11.0/24)  │
│  ┌────────────────────────────────────────────────┐  │
│  │  • Web servers, API servers                    │  │
│  │  • Containers, EKS worker nodes                │  │
│  │  • Lambda functions with VPC access            │  │
│  │                                                │  │
│  │  Route: 0.0.0.0/0 → NAT Gateway                │  │
│  └────────────────────────────────────────────────┘  │
│                          │                           │
│  TIER 3 — PRIVATE DATA  (10.0.20.0/24, 10.0.21.0/24) │
│  ┌────────────────────────────────────────────────┐  │
│  │  • RDS databases                               │  │
│  │  • ElastiCache / Redis                         │  │
│  │  • OpenSearch                                  │  │
│  │                                                │  │
│  │  Route: local only. NO internet at all.        │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

Why separate tier 2 from tier 3? **Defense in depth.** If an attacker compromises a web server, they're in tier 2. Tier 3 has its own security groups that only accept database traffic from tier 2, and no route to the internet at all — so an attacker can't easily exfiltrate data or download tools.

### 6.3 Sizing subnets

Common mistake: making subnets too small. A `/24` gives you 251 usable addresses, which sounds like a lot until you run EKS, where **every pod gets its own IP address**. A node running 30 pods consumes 30+ addresses on its own.

Guidance:

| Use case | Suggested size | Usable IPs |
|---|---|---|
| Public subnet (just LBs and NAT) | `/24` | 251 |
| Private app subnet, EC2 only | `/24` | 251 |
| Private app subnet, **EKS** | `/20` or `/19` | 4,091 / 8,187 |
| Database subnet | `/24` | 251 |

**You cannot resize a subnet after creating it.** You'd have to create a new one and migrate. Err on the large side — unused private IP addresses cost nothing.

### 6.4 Auto-assign public IP

Each subnet has a setting: `mapPublicIpOnLaunch`. If on, instances launched there get a public IP automatically.

```bash
# Turn it on (only ever do this for public subnets)
aws ec2 modify-subnet-attribute --subnet-id subnet-xxx --map-public-ip-on-launch

# Turn it off
aws ec2 modify-subnet-attribute --subnet-id subnet-xxx --no-map-public-ip-on-launch
```

**Best practice:** leave it OFF everywhere, and explicitly request a public IP per-instance when you need one. Accidentally launching a database into a subnet with auto-assign on is a genuinely bad day.

⚠️ **Note on cost:** since February 2024, **all public IPv4 addresses cost money** — about $0.005/hour (~$3.60/month) each, whether attached to a running instance or not. That's another reason to keep instances private and share one load balancer.

---

## 7. Part Four: Route Tables — The Signposts

### 7.1 How routing decisions work

Every packet leaving a network interface hits the route table. The rule is simple:

> **The most specific matching route wins.**

"Most specific" means the longest prefix — the biggest slash number.

Example route table:

| # | Destination | Target |
|---|---|---|
| 1 | `10.0.0.0/16` | local |
| 2 | `10.0.5.0/24` | `vpce-xxx` (endpoint) |
| 3 | `172.16.0.0/16` | `pcx-xxx` (peering) |
| 4 | `0.0.0.0/0` | `nat-xxx` |

Where does a packet go?

- To `10.0.10.7` → matches rule 1 only → **stays local in the VPC**
- To `10.0.5.20` → matches rules 1 *and* 2. Rule 2 is `/24` vs rule 1's `/16`, so **rule 2 wins** → goes to the endpoint
- To `172.16.3.9` → matches rules 3 and 4. `/16` beats `/0` → **peering connection**
- To `142.250.72.14` (Google) → only matches rule 4 → **NAT Gateway**

### 7.2 The local route

Every route table automatically contains a route for the VPC's own CIDR pointing to `local`. You cannot delete it or change it.

This is why **every subnet in a VPC can talk to every other subnet by default**, regardless of public/private. Route tables don't isolate subnets from each other — only security groups and NACLs do that.

This surprises people. "I put the database in a private subnet, so it's isolated." No — it's isolated *from the internet*. Every other subnet in the VPC can still reach it at the routing level. Security groups do the actual isolation.

### 7.3 What can be a route target

| Target | What it does |
|---|---|
| `local` | Inside this VPC |
| Internet Gateway (`igw-`) | Out to the internet, two-way |
| NAT Gateway (`nat-`) | Out to the internet, outbound-only |
| VPC Peering (`pcx-`) | To a specific other VPC |
| Transit Gateway (`tgw-`) | To a network hub connecting many VPCs |
| VPC Endpoint (`vpce-`) | To an AWS service, privately |
| Virtual Private Gateway (`vgw-`) | To your office over VPN or Direct Connect |
| Network Interface (`eni-`) | To a specific machine — used for firewall appliances |
| Egress-only IGW (`eigw-`) | The IPv6 equivalent of a NAT Gateway |

### 7.4 The main route table

Every VPC has one **main route table**. Any subnet you create without explicitly associating a route table uses it.

⚠️ **Danger:** the main route table in a new VPC has no internet route, so subnets default to private. That's a safe default. But if someone adds an IGW route to the *main* table, **every unassociated subnet silently becomes public.** 

**Best practice:** leave the main route table empty except the local route, and explicitly associate every subnet with a named route table. Then nothing is public by accident.

### 7.5 Gateway route tables (edge routing)

An advanced feature: you can attach a route table to the **Internet Gateway itself**, forcing all inbound traffic through an inspection appliance before it reaches your subnets.

```
Internet → IGW → [Gateway Route Table] → Firewall appliance → Subnet
```

This is how AWS Network Firewall and third-party appliances (Palo Alto, Fortinet) get inserted into the path. Mostly relevant for regulated environments.

---

## 8. Part Five: Gateways — The Doors In and Out

### 8.1 Internet Gateway (IGW)

Two-way door. Traffic can flow both directions.

Properties:
- One per VPC, maximum
- Free (no hourly charge)
- No bandwidth limit, no availability concerns — it's not a device
- Performs 1:1 NAT between an instance's private IP and its public IP

**That last point matters.** Your EC2 instance never sees its own public IP. Run `ip addr` on an instance with public IP `54.1.2.3` and you'll see only `10.0.1.50`. The IGW does the translation invisibly. To find your public IP from inside an instance, ask the metadata service:

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 3600")
curl -sH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4
```

For an instance to actually use the internet, **four things must all be true**:
1. An IGW is attached to the VPC
2. The subnet's route table has `0.0.0.0/0 → igw-xxx`
3. The instance has a public IP or Elastic IP
4. Security group and NACL allow the traffic

Miss any one and it won't work. Check them in that order when debugging.

### 8.2 NAT Gateway

One-way door — outbound only.

| Property | Detail |
|---|---|
| Cost | ~$0.045/hour (~$32/mo) + ~$0.045/GB processed |
| Bandwidth | Scales automatically up to 100 Gbps |
| Pricing modes | **Standard** (hourly + per-GB) or **Provisioned** (per Gbps-hour, data processing free) |
| Connections | Up to 55,000 simultaneous per destination |
| Availability | Redundant *within* one AZ. Dies if that AZ dies. |
| Management | Fully managed — no patching |

**Design decision: how many NAT Gateways?**

| Approach | Cost/month | Resilience | Good for |
|---|---|---|---|
| One total | ~$32 | AZ failure kills outbound for all | Dev/test |
| One per AZ | ~$32 × AZs | Survives AZ failure | Production |
| None (endpoints only) | $0 | N/A | Workloads that only talk to AWS services |

That third option is worth serious consideration — see Part Ten.

⚠️ **The charges stack.** Sending 1 GB to the internet from a private subnet costs the NAT processing fee (~$0.045/GB) **plus** standard AWS internet egress (~$0.09/GB) — roughly **$0.135/GB** all-in. This is why NAT Gateway is routinely the single biggest surprise on a startup's AWS bill.

💡 **Provisioned NAT Gateway** is a newer pricing mode: you pay per Gbps-hour of reserved bandwidth and **data processing is free**. It becomes cheaper than Standard at roughly 16 TB/month of sustained throughput per gateway. Only worth it for genuinely high-volume egress.

⚠️ **Cross-AZ data transfer charge:** if your instance in `us-east-1b` uses a NAT Gateway in `us-east-1a`, you pay ~$0.01/GB *each way* on top of NAT processing charges. One NAT per AZ avoids this and can actually be cheaper at volume.

### 8.3 NAT Instance (legacy)

Before NAT Gateway existed, you ran a regular EC2 instance configured to forward traffic. You still can, and for very low-traffic dev environments a `t4g.nano` NAT instance costs ~$3/month instead of $32.

But you have to patch it, monitor it, handle its failure, and it's a single point of failure with limited bandwidth. **Use NAT Gateway unless cost is genuinely critical and you accept the operational burden.**

If you do run one, you must disable **source/destination checking** — by default EC2 drops packets not addressed to itself:

```bash
aws ec2 modify-instance-attribute --instance-id i-xxx --no-source-dest-check
```

### 8.4 Egress-Only Internet Gateway

The IPv6 version of a NAT Gateway. Because IPv6 addresses are all globally routable (there's no "private IPv6" in the AWS sense), you need a separate device to allow outbound-only IPv6.

It's **free**, unlike NAT Gateway. That's one of several reasons IPv6 is worth considering for large workloads.

---

## 9. Part Six: Security Groups and NACLs — The Guards

Two layers of firewall. People mix them up constantly, so let's be precise.

### 9.1 Side-by-side comparison

| | **Security Group** | **Network ACL** |
|---|---|---|
| Attaches to | A network interface (instance, LB, RDS) | A whole subnet |
| Rules | Allow only | Allow **and** Deny |
| State | **Stateful** — replies auto-allowed | **Stateless** — you need both directions |
| Evaluation | All rules checked together | In number order, first match wins |
| Default inbound | Deny all | Default NACL allows all |
| Default outbound | Allow all | Default NACL allows all |
| Can reference other SGs | **Yes** | No, CIDR only |
| Limit | 60 rules in + 60 out per SG; 5 SGs per interface | 20 rules per direction (40 max) |
| When you need it | Always | Rarely |

### 9.2 Stateful vs stateless — the key difference

**Security group (stateful):**

```
You write:  ALLOW inbound TCP 443 from 0.0.0.0/0

Request comes in on 443     ✓ allowed by your rule
Response goes back out      ✓ automatically allowed — SG remembers
```

**NACL (stateless):**

```
You write:  ALLOW inbound TCP 443 from 0.0.0.0/0

Request comes in on 443     ✓ allowed
Response goes back out      ✗ BLOCKED — no outbound rule!
```

The response doesn't leave on port 443. It leaves *from* port 443 *to* a random high port on the client — an **ephemeral port**, usually in the range 1024–65535.

So NACLs almost always need this outbound rule:

```
ALLOW outbound TCP 1024-65535 to 0.0.0.0/0
```

Forgetting it is the classic NACL mistake. Connections hang, nothing appears in logs, and it looks like a routing problem.

### 9.3 Security group referencing (do this)

```
┌────────────────┐
│  ALB           │  Security Group: alb-sg
│                │  IN: 443 from 0.0.0.0/0
└───────┬────────┘
        │
        ▼
┌────────────────┐
│  App servers   │  Security Group: app-sg
│                │  IN: 8080 from alb-sg          ← references SG, not IP
└───────┬────────┘
        │
        ▼
┌────────────────┐
│  Database      │  Security Group: db-sg
│                │  IN: 5432 from app-sg          ← references SG, not IP
└────────────────┘
```

Read it out loud: *"Load balancers accept from the internet. App servers accept from load balancers. Databases accept from app servers."* That's a security policy anyone can audit at a glance.

Compare to the IP-based version, which is a list of CIDR blocks that nobody remembers the meaning of six months later, and which breaks every time you scale.

### 9.4 The self-referencing rule

For clusters where members talk to each other (Redis, Elasticsearch, Kafka, EKS nodes), a security group can reference **itself**:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --protocol tcp --port 0-65535 \
  --source-group $CLUSTER_SG    # itself
```

Now any instance with that SG can talk to any other instance with that SG, and nothing else can. Add or remove nodes freely.

### 9.5 When do you actually need NACLs?

Honestly: **usually never.** Security groups handle almost everything, and they're easier to reason about.

Use NACLs when you need to **deny** something specific, since security groups can't deny:

- Block a specific malicious IP range at the subnet level
- Enforce a compliance rule like "the database subnet must never send traffic to the internet, and this must be enforced at two independent layers"
- Emergency response — instantly block an attacker's range across a whole subnet

Otherwise leave the default NACL (which allows everything) in place and let security groups do the work.

### 9.6 Reading NACL rule numbers

NACL rules are evaluated in ascending number order, and **the first match wins — the rest are never checked.**

```
Rule 100:  ALLOW  TCP 443   from 0.0.0.0/0
Rule 200:  DENY   TCP 443   from 1.2.3.4/32     ← NEVER APPLIES
Rule *:    DENY   all
```

Rule 100 matches first and allows the traffic. Rule 200 is dead code. To block that IP you must number it lower:

```
Rule 50:   DENY   TCP 443   from 1.2.3.4/32     ← now it works
Rule 100:  ALLOW  TCP 443   from 0.0.0.0/0
Rule *:    DENY   all
```

**Convention:** number rules in increments of 100 (100, 200, 300) so you have room to insert rules between them later.

The `*` rule at the end is implicit, always present, and always denies. You can't remove it.

---

## 10. Part Seven: EC2 Network Settings Up Close

### 10.1 The ENI — Elastic Network Interface

An EC2 instance doesn't have a network connection directly. It has one or more **ENIs**, which are virtual network cards.

Each ENI carries:
- One **primary private IP** (permanent for the ENI's life)
- Zero or more **secondary private IPs**
- Optionally a **public IP** or **Elastic IP**
- One to five **security groups**
- A **MAC address**
- A **source/destination check** flag

```
┌─────────────────────────────────────────────┐
│  EC2 Instance i-0abc123                     │
│                                             │
│  ┌────────────────────────────────────┐     │
│  │ eth0 — primary ENI                 │     │
│  │  Private IP:  10.0.10.5            │     │
│  │  Secondary:   10.0.10.6, 10.0.10.7 │     │
│  │  Public IP:   54.1.2.3             │     │
│  │  Security groups: app-sg           │     │
│  │  Subnet:      private-1a           │     │
│  └────────────────────────────────────┘     │
│                                             │
│  ┌────────────────────────────────────┐     │
│  │ eth1 — secondary ENI (optional)    │     │
│  │  Private IP:  10.0.99.10           │     │
│  │  Security groups: mgmt-sg          │     │
│  │  Subnet:      management-1a        │     │
│  └────────────────────────────────────┘     │
└─────────────────────────────────────────────┘
```

**An ENI is independent of the instance.** You can detach it from a dying instance and attach it to a replacement, and the new instance inherits the IP, MAC, and security groups. This is how some failover systems work — and how licensing tied to MAC addresses survives instance replacement.

**Both ENIs must be in the same AZ as the instance**, though they can be in different subnets.

### 10.2 How many IPs can an instance have?

Depends entirely on instance type. Rough guide:

| Instance type | Max ENIs | IPs per ENI | Total private IPs |
|---|---|---|---|
| `t3.micro` | 2 | 2 | 4 |
| `t3.medium` | 3 | 6 | 18 |
| `m5.large` | 3 | 10 | 30 |
| `m5.4xlarge` | 8 | 30 | 240 |
| `m5.24xlarge` | 15 | 50 | 750 |

**This table is critical for EKS.** Pods get IPs from this pool, so instance type directly caps how many pods fit on a node. Come back to this in Part Twelve.

Check the current numbers for any type:

```bash
aws ec2 describe-instance-types --instance-types m5.large \
  --query 'InstanceTypes[0].NetworkInfo.[MaximumNetworkInterfaces,Ipv4AddressesPerInterface]'
```

### 10.3 Public IP vs Elastic IP

| | Auto-assigned Public IP | Elastic IP |
|---|---|---|
| Survives stop/start | **No — you get a new one** | **Yes** |
| Survives termination | No | Yes (it's yours until released) |
| Can move between instances | No | Yes |
| Cost | ~$3.60/month while running | ~$3.60/month, always |

**Use Elastic IPs sparingly.** They're for cases where something external depends on a fixed IP — a partner's firewall allowlist, a DNS A record you can't change, a NAT Gateway. For normal web servers, put a load balancer in front and use DNS instead.

### 10.4 Instance metadata service (IMDS)

Every instance can query `169.254.169.254` for information about itself. That address is link-local — it never leaves the instance's host, needs no route, and isn't reachable from anywhere else.

```bash
# Always use IMDSv2 (token-based) — IMDSv1 is a security risk
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

CURL="curl -sH X-aws-ec2-metadata-token:$TOKEN"

$CURL http://169.254.169.254/latest/meta-data/instance-id
$CURL http://169.254.169.254/latest/meta-data/local-ipv4
$CURL http://169.254.169.254/latest/meta-data/public-ipv4
$CURL http://169.254.169.254/latest/meta-data/placement/availability-zone
$CURL http://169.254.169.254/latest/meta-data/mac
$CURL http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

⚠️ **Security: enforce IMDSv2.** The old IMDSv1 answered any HTTP GET with no authentication. If an attacker found a server-side request forgery (SSRF) bug in your app, they could make your app fetch `169.254.169.254/latest/meta-data/iam/security-credentials/` and steal your AWS credentials. This caused the 2019 Capital One breach.

IMDSv2 requires a `PUT` request first to get a token, which SSRF attacks generally can't perform. Enforce it:

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id i-xxx \
  --http-tokens required \
  --http-endpoint enabled \
  --http-put-response-hop-limit 1
```

`--http-put-response-hop-limit 1` prevents containers on the instance from reaching IMDS, which is another common escalation path.

### 10.5 Enhanced networking

Modern instance types support hardware-accelerated networking:

**ENA (Elastic Network Adapter)** — up to 100 Gbps on the largest instance types. Enabled by default on all current-generation instances and modern AMIs. Nothing to configure.

**EFA (Elastic Fabric Adapter)** — for HPC and large-scale ML training. Bypasses the OS kernel entirely for lower latency. Only needed for tightly-coupled parallel workloads.

### 10.6 Placement groups

Control where AWS physically puts your instances:

| Type | Behavior | Use for |
|---|---|---|
| **Cluster** | Packed onto the same rack | Lowest latency, highest throughput between nodes. HPC, big data. |
| **Spread** | Each on separate hardware | Maximum fault isolation. Small critical clusters. Max 7 per AZ. |
| **Partition** | Grouped into isolated partitions | Large distributed systems that understand racks — HDFS, Cassandra, Kafka. |

Cluster placement groups give you the best network performance but concentrate risk. Use them when the workload can tolerate losing the whole group.

---

## 11. Part Eight: Load Balancers and Target Groups

### 11.1 Why load balancers exist

Three problems, one solution:

1. **One server isn't enough.** Traffic grows past what a single machine handles.
2. **Servers die.** Hardware fails, deploys go wrong, processes crash. You need traffic to route around a dead server automatically.
3. **You don't want servers exposed.** A load balancer is the only public-facing thing; everything behind it stays private.

### 11.2 The three types

| | **Application LB (ALB)** | **Network LB (NLB)** | **Gateway LB (GWLB)** |
|---|---|---|---|
| OSI layer | 7 (application) | 4 (transport) | 3 (network) |
| Protocols | HTTP, HTTPS, gRPC, WebSocket | TCP, UDP, TLS | All IP traffic |
| Routing on | Path, host, header, method, query, source IP | IP and port only | N/A — transparent |
| Static IP | No (DNS name only) | **Yes**, one per AZ | No |
| Latency | ~5-10 ms added | **~100 µs** added | Minimal |
| Preserves source IP | No (adds `X-Forwarded-For`) | **Yes** | Yes |
| Security groups | Yes | Yes (added 2023) | No |
| TLS termination | Yes | Yes | No |
| Cost | ~$16/mo + LCU | ~$16/mo + LCU | ~$0.0125/hr + GB |
| Use for | Web apps, APIs, microservices | Extreme performance, non-HTTP, static IPs | Firewall appliances |

**Choosing:**
- Web application or API? → **ALB**. Almost always the right answer.
- Need a fixed IP for a partner's allowlist, or running a game server / MQTT / custom TCP protocol? → **NLB**
- Millions of requests/sec, microsecond latency matters? → **NLB**
- Inserting a third-party firewall into your traffic path? → **GWLB**

There's also the **Classic Load Balancer (CLB)** — deprecated. Don't use it for anything new.

### 11.3 Target groups in depth

A target group is a list of destinations plus health check rules.

```
┌─────────────────────────────────────────────────┐
│  TARGET GROUP: api-targets                      │
│                                                 │
│  Protocol: HTTP    Port: 8080                   │
│  Type: instance                                 │
│                                                 │
│  Health check:                                  │
│    Path:      /health                           │
│    Interval:  15 seconds                        │
│    Timeout:   5 seconds                         │
│    Healthy:   2 consecutive passes              │
│    Unhealthy: 2 consecutive fails               │
│    Success:   HTTP 200                          │
│                                                 │
│  ┌──────────────────────────────────────────┐   │
│  │ i-0aaa  10.0.10.5:8080   ✓ healthy       │   │
│  │ i-0bbb  10.0.11.6:8080   ✓ healthy       │   │
│  │ i-0ccc  10.0.10.9:8080   ✗ unhealthy     │   │  ← no traffic sent
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

**Four target types:**

| Type | Registers | Notes |
|---|---|---|
| `instance` | EC2 instance IDs | Simplest. LB sends to the instance's primary private IP. |
| `ip` | Raw IP addresses | Required for Fargate, EKS with the AWS LB Controller, and on-prem servers reachable over VPN |
| `lambda` | A Lambda function | ALB invokes the function directly. No servers at all. |
| `alb` | Another ALB | Lets an NLB front an ALB — gives you static IPs *and* HTTP routing |

### 11.4 Health checks — get these right

The single most common ALB problem is misconfigured health checks. Rules to follow:

**Make a real `/health` endpoint.** Don't health-check `/`, which might be slow, require auth, or hit the database.

**Decide: shallow or deep?**

```python
# SHALLOW — "is the process alive?"
@app.route('/health')
def health():
    return {'status': 'ok'}, 200

# DEEP — "can I actually serve requests?"
@app.route('/health/ready')
def ready():
    try:
        db.execute('SELECT 1')
        cache.ping()
        return {'status': 'ok'}, 200
    except Exception as e:
        return {'status': 'degraded', 'error': str(e)}, 503
```

**Use shallow checks for the load balancer.** Here's why: if your database has a hiccup, a deep check marks *every* server unhealthy at once, the ALB has no targets left, and it returns 503 to everyone — turning a slow database into a total outage. A shallow check keeps servers in rotation so they can at least return proper errors or serve cached content.

Use deep checks for your *own* monitoring and alerting, and for Kubernetes readiness probes on individual pods.

**Tune the timing:**

| Setting | Fast failover | Stable/default |
|---|---|---|
| Interval | 5s | 30s |
| Timeout | 2s | 5s |
| Unhealthy threshold | 2 | 3 |
| **Time to detect failure** | **10s** | **90s** |

Faster detection means more health check traffic and more risk of false positives from a brief hiccup. Start at the defaults and tighten only if you measure a real need.

### 11.5 Listener rules — routing by content

This is what makes ALBs powerful. One load balancer, many backends:

```
                    ┌──────────────────┐
   Internet ──────► │  ALB :443        │
                    └────────┬─────────┘
                             │
      ┌──────────────────────┼──────────────────────┐
      │                      │                      │
  Priority 10           Priority 20           Priority 30
  path = /api/*         path = /admin/*       host = img.site.com
      │                      │                      │
      ▼                      ▼                      ▼
 ┌──────────┐          ┌──────────┐           ┌──────────┐
 │ api-tg   │          │ admin-tg │           │ static-tg│
 └──────────┘          └──────────┘           └──────────┘
                             
                    default → web-tg
```

Rules are checked in priority order, lowest number first, and the first match wins.

You can match on:
- **Path** — `/api/*`, `/admin/*`
- **Host header** — `api.example.com` vs `www.example.com`
- **HTTP header** — any header, e.g. `X-Canary: true`
- **HTTP method** — `GET` vs `POST`
- **Query string** — `?version=beta`
- **Source IP** — restrict `/admin` to office IPs

Actions available: forward to a target group, redirect (e.g. HTTP→HTTPS), return a fixed response, or authenticate via Cognito/OIDC before forwarding.

**Weighted forwarding** enables blue/green and canary deploys:

```bash
aws elbv2 modify-listener --listener-arn $LISTENER \
  --default-actions '[{
    "Type": "forward",
    "ForwardConfig": {
      "TargetGroups": [
        {"TargetGroupArn": "'$BLUE_TG'",  "Weight": 90},
        {"TargetGroupArn": "'$GREEN_TG'", "Weight": 10}
      ]
    }
  }]'
```

10% of traffic to the new version. Watch your error rates. Shift to 50/50, then 100. If something breaks, shift back to 100/0 in seconds.

### 11.6 Always redirect HTTP to HTTPS

```bash
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions '[{
    "Type": "redirect",
    "RedirectConfig": {
      "Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"
    }
  }]'
```

Free TLS certificates come from **AWS Certificate Manager (ACM)**. They auto-renew. There is no reason to run unencrypted HTTP in 2026.

### 11.7 Connection draining

When you remove a target, the ALB doesn't cut existing connections immediately — it stops sending *new* requests and waits for in-flight ones to finish. Default is 300 seconds.

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn $TG_ARN \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30
```

For fast-responding APIs, 30 seconds is plenty and makes deploys much quicker. For long-running uploads or WebSockets, keep it high.

### 11.8 Cross-zone load balancing

```
Without cross-zone:              With cross-zone:
 AZ-a: 1 target → 50% traffic     AZ-a: 1 target → 25% traffic
 AZ-b: 3 targets → 50% split      AZ-b: 3 targets → 25% each
       (16.7% each)
```

**ALB: enabled by default, free, can't be disabled.** 
**NLB: disabled by default, and enabling it incurs cross-AZ data charges.**

If your NLB targets are unevenly distributed across AZs, you need it on. If they're even, leave it off and save money.

---

## 12. Part Nine: DNS — Public and Private

### 12.1 What DNS does

DNS translates names humans can remember into IP addresses computers need. `google.com` → `142.250.72.14`.

The hierarchy, reading a domain right to left:

```
        api.shop.example.com.
        │    │     │      │  │
        │    │     │      │  └── Root (the invisible final dot)
        │    │     │      └───── TLD: .com
        │    │     └──────────── Domain: example.com
        │    └────────────────── Subdomain: shop
        └─────────────────────── Subdomain: api
```

A full lookup, first time:

```
1. Browser checks its own cache                    → miss
2. OS checks its cache and /etc/hosts              → miss
3. Ask the resolver (in AWS: 169.254.169.253)      → miss
4. Resolver asks a ROOT server: "who handles .com?"
      → "these 13 .com nameservers"
5. Resolver asks a .COM server: "who handles example.com?"
      → "ns-1234.awsdns.org"
6. Resolver asks THAT server: "what is api.shop.example.com?"
      → "203.0.113.50"
7. Resolver caches the answer for the TTL, returns it
```

Steps 4-6 only happen on a cache miss. In practice almost everything is cached somewhere, and lookups take milliseconds.

### 12.2 Record types you need to know

| Type | Points to | Example |
|---|---|---|
| **A** | An IPv4 address | `example.com → 203.0.113.50` |
| **AAAA** | An IPv6 address | `example.com → 2001:db8::1` |
| **CNAME** | Another name | `www.example.com → example.com` |
| **MX** | Mail servers | `example.com → mail.example.com` |
| **TXT** | Arbitrary text | Domain verification, SPF, DKIM |
| **NS** | Nameservers for a zone | Delegation |
| **ALIAS** | AWS-only: an AWS resource | `example.com → my-alb-123.elb.amazonaws.com` |

### 12.3 ALIAS records — the AWS special

**You cannot put a CNAME at the root of a domain.** DNS forbids it — `example.com` must have an A record because it also needs NS and SOA records, and CNAME can't coexist with other records.

But your load balancer only gives you a DNS name, not an IP. Problem.

AWS solved this with **ALIAS records**, a Route 53 extension:

```
example.com  ALIAS → tutorial-alb-1234.us-east-1.elb.amazonaws.com
```

Route 53 resolves this internally and hands the browser an A record with the actual current IPs. Advantages over CNAME:

- **Works at the domain root** (this is the main reason)
- **Free** — AWS doesn't charge for ALIAS queries to AWS resources
- **One lookup** instead of two — faster
- **Auto-updates** when the target's IPs change

Use ALIAS for: ALB, NLB, CloudFront, S3 website endpoints, API Gateway, another Route 53 record.

### 12.4 TTL — how long answers are cached

```
example.com.  300  IN  A  203.0.113.50
              └─┘
              TTL in seconds — cache for 5 minutes
```

| TTL | Trade-off |
|---|---|
| 60s | Fast changes, more DNS queries (more cost), more resolver load |
| 300s (5 min) | Good general default |
| 3600s (1 hr) | Fewer queries, but changes take an hour to propagate |
| 86400s (1 day) | Only for records that truly never change |

**Migration trick:** before changing a record, drop its TTL to 60. Wait for the *old* TTL to expire everywhere (so if it was 3600, wait an hour). Then make the change — it propagates in a minute. Raise the TTL back afterward.

### 12.5 Route 53 routing policies

| Policy | Behavior | Use case |
|---|---|---|
| **Simple** | One answer | Basic sites |
| **Weighted** | Split by percentage | Canary deploys, A/B tests |
| **Latency** | Nearest region by measured latency | Global apps |
| **Geolocation** | By user's country/continent | Localized content, legal compliance |
| **Geoproximity** | By distance, with a bias dial | Fine-grained traffic shifting |
| **Failover** | Primary, then secondary if unhealthy | Disaster recovery |
| **Multivalue** | Up to 8 healthy IPs, client picks | Cheap poor-man's load balancing |

Failover example:

```
example.com  A  FAILOVER=PRIMARY    → us-east-1 ALB   (health-checked)
example.com  A  FAILOVER=SECONDARY  → eu-west-1 ALB
```

If the health check on the primary fails, Route 53 starts answering with the secondary automatically.

### 12.6 Private DNS inside your VPC

**This is what makes internal service communication work, and it's the part people understand least.**

Every VPC has a built-in DNS resolver at two addresses:
- **`VPC_CIDR_base + 2`** — for `10.0.0.0/16` that's `10.0.0.2`
- **`169.254.169.253`** — link-local, works from anywhere in the VPC

Your instances are configured to use it automatically via DHCP.

**Automatic internal names.** Every instance gets a private DNS name for free:

```
ip-10-0-10-5.ec2.internal            (in us-east-1)
ip-10-0-10-5.us-west-2.compute.internal   (everywhere else)
```

These resolve only inside the VPC. They're not very useful directly — the IP is embedded in the name, so it changes when the instance does.

### 12.7 Private hosted zones

Much more useful: create your own internal DNS zone.

```bash
aws route53 create-hosted-zone \
  --name internal.mycompany.com \
  --vpc VPCRegion=us-east-1,VPCId=$VPC_ID \
  --caller-reference $(date +%s) \
  --hosted-zone-config PrivateZone=true
```

Now add records:

```
db.internal.mycompany.com      → 10.0.20.100
cache.internal.mycompany.com   → 10.0.20.50
api.internal.mycompany.com     → internal ALB alias
```

Your app connects to `db.internal.mycompany.com` instead of a hardcoded IP. Move the database, update one DNS record, everything follows. No redeploys.

**Split-horizon DNS** — you can have a public zone and a private zone with the *same name*:

```
Public zone  "example.com":   api.example.com → 203.0.113.50 (public ALB)
Private zone "example.com":   api.example.com → 10.0.10.99   (internal ALB)
```

Requests from outside get the public IP. Requests from inside the VPC get the private IP — traffic stays internal, skips the internet, avoids NAT charges, and is faster. The private zone always wins for queries originating inside the associated VPC.

**Requirement:** the VPC must have both `enableDnsSupport` and `enableDnsHostnames` on. (Remember Step 2.)

### 12.8 Route 53 Resolver endpoints — hybrid DNS

If you have an office network connected by VPN or Direct Connect, you need DNS to work in both directions.

```
┌───────────────────────┐         ┌────────────────────────┐
│   Your office         │         │   AWS VPC              │
│                       │         │                        │
│  DNS server           │◄────────┤ OUTBOUND endpoint      │
│  corp.local           │  fwd    │ "queries for           │
│                       │  rules  │  corp.local go there"  │
│                       │         │                        │
│  Servers ─────────────┼────────►│ INBOUND endpoint       │
│  need to resolve      │         │ "office can query      │
│  internal.aws.com     │         │  our private zones"    │
└───────────────────────┘         └────────────────────────┘
```

- **Inbound endpoint** — office machines can query AWS private hosted zones
- **Outbound endpoint** + forwarding rules — AWS instances can query your office DNS

Each endpoint costs about $0.125/hour per IP address, and you need at least two IPs for redundancy — roughly $180/month for both directions.

### 12.9 DHCP option sets

Controls what DNS settings instances receive on boot:

```bash
aws ec2 create-dhcp-options --dhcp-configurations \
  'Key=domain-name-servers,Values=10.0.0.2' \
  'Key=domain-name,Values=internal.mycompany.com'
```

Setting `domain-name` means an instance can resolve `db` as shorthand for `db.internal.mycompany.com` via search domain.

**Best practice:** leave this alone and use `AmazonProvidedDNS` unless you have a specific reason. Custom DNS servers break VPC endpoints, EKS service discovery, and RDS private names in ways that are annoying to debug.

---

## 13. Part Ten: VPC Endpoints — Private Doors to AWS

### 13.1 The problem

Your private EC2 instance wants to read a file from S3. S3 lives on the public internet — `s3.us-east-1.amazonaws.com` resolves to a public IP.

So the request goes: instance → NAT Gateway → Internet Gateway → out to the internet → back into AWS → S3.

Two problems:
1. **Cost.** Every gigabyte pays NAT processing charges.
2. **Security.** Traffic leaves your VPC. And to permit it, your NAT and route tables must allow general internet access.

### 13.2 Gateway Endpoints (S3 and DynamoDB only)

The fix for these two services, and it's completely free.

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids $PRIV_RT \
  --vpc-endpoint-type Gateway
```

What this does: adds an entry to your route table pointing S3's IP ranges at the endpoint instead of the NAT Gateway.

```
Before:                        After:
 Destination      Target        Destination        Target
 10.0.0.0/16      local         10.0.0.0/16        local
 0.0.0.0/0        nat-xxx       pl-63a5400 (S3)    vpce-xxx    ← more specific!
                                0.0.0.0/0          nat-xxx
```

That `pl-63a5400` is a **prefix list** — an AWS-maintained list of S3's IP ranges that updates automatically. Because it's more specific than `0.0.0.0/0`, S3 traffic takes the endpoint.

| | Cost | Availability |
|---|---|---|
| Gateway endpoint | **Free** | Highly available, no bandwidth limit |

💰 **Create these on day one.** There is no downside. A company moving 10 TB/month through S3 saves roughly $450/month by adding one free endpoint.

### 13.3 Interface Endpoints (PrivateLink) — everything else

For the other ~100 AWS services, an **interface endpoint** puts an actual ENI with a private IP inside your subnet.

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.us-east-1.secretsmanager \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-private1a subnet-private1b \
  --security-group-ids $ENDPOINT_SG \
  --private-dns-enabled
```

That `--private-dns-enabled` flag is the magic. With it on, `secretsmanager.us-east-1.amazonaws.com` resolves to the endpoint's **private IP** inside your VPC. Your code needs zero changes — the SDK calls the normal endpoint name and traffic silently stays private.

| | Cost |
|---|---|
| Interface endpoint | ~$0.01/hr per AZ (~$7/mo per AZ) + ~$0.01/GB |

So two AZs ≈ $14/month per service. Compare against your NAT data charges to decide which services are worth it.

**Commonly worth creating:**
- `ecr.api` and `ecr.dkr` — pulling container images is high-volume
- `logs` — CloudWatch Logs, constant traffic
- `ssm`, `ssmmessages`, `ec2messages` — required for Session Manager without NAT
- `secretsmanager` — credentials should never touch the internet
- `sts` — IAM role assumption
- `kms` — encryption operations

**The fully-private pattern:** with S3 + ECR + logs + SSM endpoints, an EKS cluster or EC2 fleet can run with **no NAT Gateway at all**. Route table has no `0.0.0.0/0` route. Nothing can reach the internet, and nothing needs to. Maximum security and often lower cost.

### 13.4 Locking down endpoints with policies

Endpoints support their own IAM-style policies:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": ["s3:GetObject", "s3:PutObject"],
    "Resource": "arn:aws:s3:::my-company-bucket/*"
  }]
}
```

Now instances in this VPC can only reach *your* bucket through this endpoint — not any random public S3 bucket. That closes a real data-exfiltration path: an attacker on your server can't copy your data to their own S3 bucket.

### 13.5 PrivateLink for your own services

The same technology lets you expose *your* service privately to *another AWS account* — no peering, no VPN, no overlapping-CIDR problems.

```
┌─────────────────────┐         ┌──────────────────────┐
│  Provider VPC       │         │  Consumer VPC        │
│  (your SaaS)        │         │  (your customer)     │
│                     │         │                      │
│   NLB               │◄────────┤   Interface endpoint │
│    ↓                │ Private │   with private IP    │
│   Your servers      │  Link   │   in their subnet    │
│                     │         │                      │
│  10.0.0.0/16        │         │  10.0.0.0/16         │
│                     │         │  ← same CIDR, fine!  │
└─────────────────────┘         └──────────────────────┘
```

Traffic is one-directional (consumer → provider) and never touches the internet. CIDRs can overlap because there's no routing between the VPCs — just an endpoint. This is how Snowflake, Datadog, MongoDB Atlas, and most modern SaaS offer private connectivity.

---

## 14. Part Eleven: Connecting VPCs Together

### 14.1 VPC Peering

A direct, private link between two VPCs.

```bash
aws ec2 create-vpc-peering-connection \
  --vpc-id vpc-aaa --peer-vpc-id vpc-bbb

aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id pcx-xxx

# Add routes on BOTH sides — this is required
aws ec2 create-route --route-table-id $RT_A \
  --destination-cidr-block 10.1.0.0/16 --vpc-peering-connection-id pcx-xxx

aws ec2 create-route --route-table-id $RT_B \
  --destination-cidr-block 10.0.0.0/16 --vpc-peering-connection-id pcx-xxx
```

| Pros | Cons |
|---|---|
| No hourly charge (data transfer only) | **Not transitive** |
| Very low latency | CIDRs must not overlap |
| Works cross-region and cross-account | Doesn't scale — N VPCs need N(N-1)/2 connections |
| Simple to understand | Route tables get messy fast |

**Not transitive** means: if A peers with B, and B peers with C, **A cannot reach C.** You'd need a third peering connection. With 10 VPCs that's 45 connections and 45 sets of route table entries. Unmanageable.

### 14.2 Transit Gateway

A hub-and-spoke router. Every VPC connects once to the hub.

```
        ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
        │   VPC A      │  │   VPC B      │  │   VPC C      │
        │ 10.0.0.0/16  │  │ 10.1.0.0/16  │  │ 10.2.0.0/16  │
        └───────┬──────┘  └───────┬──────┘  └───────┬──────┘
                │                 │                 │
                └────────┬────────┴────────┬────────┘
                         │                 │
                  ┌──────▼─────────────────▼──────┐
                  │      TRANSIT GATEWAY          │
                  │   (route tables live here)    │
                  └──────┬─────────────────┬──────┘
                         │                 │
                ┌────────▼──────┐  ┌───────▼────────┐
                │ VPN to office │  │ Direct Connect │
                └───────────────┘  └────────────────┘
```

**Transit Gateway is transitive.** A can reach C through the hub automatically.

| Pros | Cons |
|---|---|
| Scales to thousands of VPCs | ~$36/month per attachment |
| Transitive routing | ~$0.02/GB processed |
| One place to manage all routes | More concepts to learn |
| Multiple route tables for segmentation | Slightly higher latency than peering |
| Connects VPN and Direct Connect too | |

**Segmentation with TGW route tables** — a genuinely useful feature. Give production and development separate TGW route tables so they can each reach shared services but not each other:

```
Prod route table:    prod-vpc ✓  shared-vpc ✓  dev-vpc ✗
Dev route table:     dev-vpc ✓   shared-vpc ✓  prod-vpc ✗
Shared route table:  everything ✓
```

**When to switch from peering to TGW:** roughly 4-5 VPCs, or the first time you need transitive routing, or when you connect an office network.

### 14.3 Connecting to your office

| Option | Speed | Latency | Cost | Setup time |
|---|---|---|---|---|
| **Site-to-Site VPN** | Up to 1.25 Gbps per tunnel | Variable (internet) | ~$36/mo + data | Hours |
| **Direct Connect** | 50 Mbps – 100 Gbps | Consistent, low | $$$ + port fees | Weeks to months |
| **Client VPN** | Per-user | Variable | ~$0.10/hr/endpoint + $0.05/hr/user | Hours |

**Site-to-Site VPN** is encrypted tunnels over the public internet. Cheap, fast to set up, but performance depends on the internet that day. AWS gives you two tunnels for redundancy — configure both.

**Direct Connect** is a physical fiber connection into an AWS facility. Consistent performance, lower data transfer costs at volume, but takes weeks to provision and costs thousands per month.

**Common production pattern:** Direct Connect as primary, Site-to-Site VPN as automatic backup. If the fiber gets cut, BGP fails over to the VPN within seconds.

**Client VPN** is for individual laptops — remote employees connecting to private resources. Uses OpenVPN, supports certificate or Active Directory auth.

---

## 15. Part Twelve: EKS and Kubernetes Pod Networking

### 15.1 What Kubernetes changes

With plain EC2, one server = one IP address. Simple.

With Kubernetes, one server (a **node**) runs many **pods**, and each pod is like a tiny separate computer. So how do pods get network addresses?

Most Kubernetes setups solve this with an **overlay network** — pods get fake IPs on a virtual network, and traffic gets wrapped in extra packet layers to travel between nodes. It works, but it adds overhead, and AWS security groups can't see pod addresses.

**AWS took a different approach.** The **VPC CNI plugin** gives every pod a **real IP address from your actual VPC subnet.**

```
┌────────────────────────────────────────────────────┐
│  VPC 10.0.0.0/16                                   │
│  ┌──────────────────────────────────────────────┐  │
│  │  Private subnet 10.0.10.0/24                 │  │
│  │                                              │  │
│  │  ┌────────────────────────────────────────┐  │  │
│  │  │  EKS Node (EC2 m5.large)               │  │  │
│  │  │  Node IP: 10.0.10.5                    │  │  │
│  │  │                                        │  │  │
│  │  │  ┌──────────┐ ┌──────────┐ ┌────────┐  │  │  │
│  │  │  │ Pod A    │ │ Pod B    │ │ Pod C  │  │  │  │
│  │  │  │10.0.10.20│ │10.0.10.21│ │10.0.10.│  │  │  │
│  │  │  │          │ │          │ │  22    │  │  │  │
│  │  │  └──────────┘ └──────────┘ └────────┘  │  │  │
│  │  │       ↑ REAL VPC IPs, not fake ones    │  │  │
│  │  └────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────┘
```

**Why this is great:**
- No encapsulation overhead — full network performance
- VPC Flow Logs show pod-level traffic
- Pods can be load balancer targets directly
- Security groups can apply to individual pods
- Anything in the VPC can reach a pod directly by IP

**The catch: you can run out of IP addresses.** This is the #1 EKS networking problem and it deserves its own section.

### 15.2 The IP exhaustion problem

Remember the ENI limits from Part Seven? Pod capacity per node is:

```
Max pods = (ENIs × (IPs per ENI − 1)) + 2
```

The `−1` is because each ENI's primary IP belongs to the node itself.

| Instance type | ENIs | IPs/ENI | Max pods |
|---|---|---|---|
| `t3.small` | 3 | 4 | 11 |
| `t3.medium` | 3 | 6 | 17 |
| `m5.large` | 3 | 10 | 29 |
| `m5.xlarge` | 4 | 15 | 58 |
| `m5.4xlarge` | 8 | 30 | 234 |

Now do the math on a `/24` subnet with 251 usable IPs:

```
10 nodes × 29 pods = 290 IPs needed
Subnet has 251
→ You run out. Pods stick in "ContainerCreating" forever.
```

The error you'll see:

```
Failed to create pod sandbox: ... failed to assign an IP address to container
```

**Fix #1 — size subnets generously from the start.** Use `/19` or `/20` for EKS subnets. Private IPs are free.

**Fix #2 — prefix delegation (recommended).** Instead of assigning individual IPs, assign `/28` blocks (16 addresses) at once:

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_PREFIX_DELEGATION=true
```

Now an `m5.large` jumps from 29 pods to **110 pods**. It also massively speeds up pod startup, since IPs are pre-allocated in blocks rather than fetched one at a time.

Note that **110 is a Kubernetes-recommended cap, not an IP limit** — the raw IP math on an `m5.large` with prefixes allows far more, but you'd exhaust CPU and memory long before that. On instances with more than 30 vCPUs, the cap rises to 250.

Requires Nitro-based instances (m5, c5, r5, t3 and newer — basically anything current).

⚠️ **Prefix delegation needs contiguous free `/28` blocks.** If a subnet is heavily fragmented from long use, prefix allocation fails with `InsufficientCidrBlocks`. Two mitigations: create fresh subnets for prefix-mode node groups rather than reusing old ones, and use **subnet CIDR reservations** to set aside contiguous space in advance. Migrating an existing node group in place often conflicts with already-assigned individual IPs — deploy new nodes instead.

**Fix #3 — custom networking.** Put nodes in your main subnets but pods in a secondary CIDR block:

```bash
# Add a big secondary CIDR just for pods
aws ec2 associate-vpc-cidr-block \
  --vpc-id $VPC_ID --cidr-block 100.64.0.0/16
```

`100.64.0.0/10` is **CGNAT space** — reserved, routable inside your VPC, and it won't collide with anything on-premises. That gives you 65,536 pod IPs without touching your main address plan. This is the standard fix for large clusters in CIDR-constrained environments.

**Fix #4 — use Fargate** for some workloads. Each Fargate pod gets its own ENI, managed entirely by AWS. You still consume subnet IPs, but there's no node capacity math.

**Fix #5 — use EKS Auto Mode**, which handles most of this for you. Auto Mode enables prefix delegation by default, maintains a warm pool of `/28` prefixes that scales with scheduled pods, falls back to individual IPs when it detects subnet fragmentation, and calculates `max-pods` per node automatically from the instance type. The trade-off: several manual knobs are unavailable — security groups for pods (use `podSecurityGroupSelectorTerms` in the NodeClass instead), ENIConfig-based custom networking (use `podSubnetSelectorTerms`), and the warm IP / warm prefix tuning settings. Good default for new clusters; less suitable if you need fine-grained control.

### 15.3 Kubernetes Services — internal load balancing

Pods are ephemeral. They die, get rescheduled, and get new IPs. You can't hardcode a pod IP.

A **Service** gives a stable name and address in front of a changing set of pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payments
spec:
  selector:
    app: payments        # find pods with this label
  ports:
    - port: 80           # the Service's port
      targetPort: 8080   # the pod's actual port
  type: ClusterIP        # internal only
```

Now any pod in the cluster can reach it at `payments` or `payments.default.svc.cluster.local`, and traffic is spread across all matching pods automatically.

**The three Service types:**

| Type | What it creates | Reachable from |
|---|---|---|
| **ClusterIP** | A virtual IP inside the cluster | Inside the cluster only |
| **NodePort** | Opens a port (30000-32767) on every node | Anything that can reach a node |
| **LoadBalancer** | Provisions an actual AWS NLB | The internet, or the VPC |

```yaml
# Creates a real AWS Network Load Balancer
apiVersion: v1
kind: Service
metadata:
  name: api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  selector:
    app: api
  ports:
    - port: 443
      targetPort: 8080
```

### 15.4 CoreDNS — DNS inside the cluster

EKS runs **CoreDNS** as pods inside your cluster. Every pod's `/etc/resolv.conf` points at it.

```
nameserver 172.20.0.10          ← CoreDNS Service IP
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

The naming pattern:

```
payments.default.svc.cluster.local
│        │       │   │
│        │       │   └── cluster domain
│        │       └────── "this is a service"
│        └────────────── namespace
└─────────────────────── service name
```

Because of the `search` line, a pod in the `default` namespace can just say `payments`. From another namespace it needs `payments.default`.

**Anything CoreDNS can't resolve gets forwarded to the VPC resolver at `10.0.0.2`**, so pods can also resolve `db.internal.mycompany.com` and public internet names.

⚠️ **The `ndots:5` gotcha.** That option means "if a name has fewer than 5 dots, try the search domains first." So looking up `api.stripe.com` (2 dots) generates:

```
api.stripe.com.default.svc.cluster.local   → NXDOMAIN
api.stripe.com.svc.cluster.local           → NXDOMAIN
api.stripe.com.cluster.local               → NXDOMAIN
api.stripe.com                             → ✓ finally
```

Four queries instead of one. At scale this overloads CoreDNS and shows up as mysterious latency spikes.

**Fixes:**
```yaml
# Use a fully-qualified name with a trailing dot
- name: STRIPE_URL
  value: "https://api.stripe.com./v1"   # ← note the dot after com

# Or lower ndots for that pod
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

Also consider **NodeLocal DNSCache**, which runs a small DNS cache on every node and dramatically reduces CoreDNS load.

### 15.5 The AWS Load Balancer Controller

This is the component that lets Kubernetes create real AWS load balancers. Install it first:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=my-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

Then an **Ingress** resource creates an ALB:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/group.name: shared    # share one ALB!
spec:
  ingressClassName: alb
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /users
            pathType: Prefix
            backend:
              service:
                name: users-service
                port: {number: 80}
          - path: /orders
            pathType: Prefix
            backend:
              service:
                name: orders-service
                port: {number: 80}
```

The controller watches this and builds the ALB, target groups, and listener rules for you.

**`target-type: ip` vs `instance`:**

| | `ip` mode | `instance` mode |
|---|---|---|
| ALB sends to | The pod's IP directly | A NodePort on the node |
| Network hops | 1 | 2 (node then kube-proxy then pod) |
| Works with Fargate | **Yes** | No |
| Health checks | Per pod, accurate | Per node |

**Use `ip` mode.** It's the modern default and strictly better.

💰 **`group.name` is a big cost saver.** Without it, every Ingress creates its own ALB at $16+/month. With a shared group name, 20 Ingresses share one ALB. On a large cluster this saves hundreds of dollars a month.

### 15.6 Security groups for pods

Normally all pods on a node share the node's security group. For workloads that need isolation (a pod that talks to a locked-down database, say), you can give specific pods their own security group:

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_POD_ENI=true
```

```yaml
apiVersion: vpcresources.k8s.aws/v1beta1
kind: SecurityGroupPolicy
metadata:
  name: db-access
spec:
  podSelector:
    matchLabels:
      role: db-client
  securityGroups:
    groupIds:
      - sg-0abc123      # this SG is allowed into the database
```

Now only pods labeled `role: db-client` can reach the database, even though they share nodes with everything else. Requires Nitro instances, and each such pod consumes a full ENI (reducing node pod capacity).

### 15.7 Network Policies — pod-level firewalls

Kubernetes-native traffic rules. By default **every pod can talk to every other pod**, which is usually too permissive.

Since 2023, the VPC CNI enforces network policies natively (no Calico needed):

```bash
kubectl set env daemonset aws-node -n kube-system \
  ENABLE_NETWORK_POLICY=true
```

Start with a default-deny, then allow explicitly:

```yaml
# Deny all ingress in this namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: production
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
# Allow only the frontend to reach the API on 8080
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-api
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
```

**Security groups vs network policies:** security groups control traffic at the VPC level (pod ↔ RDS, pod ↔ internet). Network policies control pod ↔ pod inside the cluster. Use both — they solve different problems.

### 15.8 EKS cluster endpoint access

The Kubernetes API server itself has network settings:

| Mode | API server reachable from | Notes |
|---|---|---|
| Public | Internet | Default. Restrict with CIDR allowlist. |
| Public + Private | Internet **and** VPC | Common. VPC traffic stays internal. |
| **Private only** | VPC only | Most secure. Needs VPN/bastion for `kubectl`. |

```bash
aws eks update-cluster-config --name my-cluster \
  --resources-vpc-config \
    endpointPublicAccess=true,\
    endpointPrivateAccess=true,\
    publicAccessCidrs=203.0.113.0/24
```

**Best practice:** enable private access always, and either disable public access or restrict it to your office/VPN CIDR. A fully public API endpoint with only IAM protecting it is a large attack surface.

### 15.9 Other AWS networking services worth knowing

**CloudFront (CDN)** — copies of your content in 400+ locations worldwide. A user in Tokyo gets served from Tokyo instead of Virginia. Also absorbs DDoS attacks and terminates TLS at the edge. Put it in front of any public site.

**AWS WAF** — inspects HTTP requests for SQL injection, XSS, bad bots. Attaches to ALB, CloudFront, or API Gateway. Managed rule sets cover the OWASP Top 10 out of the box.

**AWS Shield** — DDoS protection. Standard is free and automatic. Advanced ($3,000/month) adds a response team and cost protection.

**Global Accelerator** — gives you two static anycast IPs and routes users onto the AWS backbone at the nearest edge location. Unlike CloudFront it works for any TCP/UDP traffic, not just HTTP. Good for gaming, VoIP, and non-cacheable APIs.

**API Gateway** — managed HTTP/REST/WebSocket front end with auth, throttling, and request validation built in. Often replaces an ALB for serverless architectures.

**App Mesh / Service Connect** — service mesh for advanced traffic management between microservices. Consider only after you have real scale and complexity.

**VPC Lattice** — newer service that handles service-to-service connectivity, auth, and observability across VPCs and accounts without peering. Worth watching if you have many services across many accounts.

---

## 16. Part Thirteen: Following One Request All The Way Through

Let's put everything together. A user in London opens `shop.example.com` on their phone.

**1. DNS resolution**
```
Phone → local resolver → Route 53
"shop.example.com?"
Route 53 has an ALIAS record → returns the ALB's IPs, e.g. 3.33.x.x
TTL 60, so it's cached for a minute
```

**2. TCP connection and TLS**
```
Phone opens TCP to 3.33.x.x:443
TLS handshake — ALB presents the ACM certificate
Encrypted tunnel established
```

**3. Entering AWS**
```
Packet arrives at the AWS edge → Internet Gateway
IGW checks: is there a route table entry? Yes.
IGW translates the destination to the ALB's private IP
Enters the public subnet 10.0.1.0/24
```

**4. ALB security group check**
```
alb-sg: ALLOW tcp/443 from 0.0.0.0/0   ✓ passed
```

**5. ALB listener rules**
```
Request is GET /api/products
Rule priority 10: path = /api/*  → MATCH
Forward to target group: api-tg
```

**6. Target selection**
```
api-tg has 4 targets, 3 healthy
Round-robin picks 10.0.10.22:8080  (an EKS pod, ip target-type)
ALB opens a NEW connection to that pod
```

**7. Pod security group check**
```
Traffic from ALB → pod on port 8080
app-sg: ALLOW tcp/8080 from alb-sg   ✓ passed
(SG referencing means we never had to know the ALB's IP)
```

**8. Pod needs the database**
```
App code connects to "db.internal.mycompany.com"
→ CoreDNS: not a cluster.local name, forward upstream
→ VPC resolver 10.0.0.2
→ Private hosted zone lookup → 10.0.20.100
```

**9. Route to the database**
```
Route table: 10.0.20.100 matches 10.0.0.0/16 → local
Stays entirely inside the VPC, never touches a gateway
```

**10. Database security group check**
```
db-sg: ALLOW tcp/5432 from app-sg   ✓ passed
```

**11. Pod needs to read an image from S3**
```
Resolves s3.us-east-1.amazonaws.com
Route table has a more-specific prefix-list route → gateway endpoint
Traffic goes to S3 privately, bypassing the NAT Gateway
Cost: $0
```

**12. Response travels back**
```
Pod → ALB  (SG stateful: reply auto-allowed)
ALB → IGW  (SG stateful: reply auto-allowed)
IGW translates back to the public IP
Internet → phone
```

**Total: roughly 50-150 milliseconds.** Every hop was checked by at least one security control, and the servers and database were never reachable from the internet at any point.

---

## 17. Best Practices Cheat Sheet

### Design

✅ **Plan CIDR blocks before creating anything.** Write down the whole scheme. Never let two connected VPCs overlap.
✅ **Use `/16` for VPCs, `/24` for normal subnets, `/19` for EKS subnets.**
✅ **Always use at least two Availability Zones.** ALBs require it, and it's the cheapest resilience you can buy.
✅ **Three tiers: public → private app → private data.**
✅ **Nothing in a public subnet except load balancers and NAT Gateways.**
✅ **Build with Terraform or CDK, not console clicks.**

### Security

✅ **No public IPs on application servers.** Ever. Put a load balancer in front.
✅ **Reference security groups from other security groups**, not CIDR blocks.
✅ **Use SSM Session Manager, not bastion hosts and SSH keys.**
✅ **Enforce IMDSv2** with `--http-tokens required`.
✅ **HTTPS only.** Free certificates from ACM, redirect port 80 to 443.
✅ **Enable VPC Flow Logs** — you cannot investigate an incident without them.
✅ **Don't bother with NACLs** unless you specifically need a DENY rule.
✅ **Default-deny network policies in Kubernetes**, then allow explicitly.
✅ **Restrict the EKS public API endpoint** to known CIDRs, or disable it.

### Cost

💰 **Create S3 and DynamoDB gateway endpoints on day one.** Free, immediate savings.
💰 **One NAT Gateway for dev, one per AZ for production.** Understand the trade-off.
💰 **Add interface endpoints for ECR, logs, and SSM** if you move meaningful volume.
💰 **Share one ALB across many services** using ALB `group.name` or path-based routing.
💰 **Keep traffic within an AZ** where you can — cross-AZ transfer is ~$0.01/GB each way.
💰 **Release unused Elastic IPs.** They bill even when unattached.
💰 **Put CloudFront in front of public content** — its data transfer out is cheaper than direct.
💰 **Set up an AWS Budget alert.** Everyone should have one.

### Operations

🔧 **Tag everything** — Name, Environment, Owner, CostCenter.
🔧 **Shallow health checks on load balancers**, deep checks in your monitoring.
🔧 **Lower deregistration delay to 30s** for fast APIs.
🔧 **Enable prefix delegation on EKS** from the start.
🔧 **Watch for the `ndots:5` DNS problem** in Kubernetes.
🔧 **Use Reachability Analyzer** before you spend an hour guessing.

---

## 18. Common Problems and How to Fix Them

### "I can't SSH to my instance"

Check in this order:
1. Does the instance have a public IP? (`describe-instances`)
2. Does the subnet's route table have `0.0.0.0/0 → igw-xxx`?
3. Does the security group allow port 22 from **your** IP?
4. Is the NACL allowing both inbound 22 and outbound 1024-65535?
5. Is the instance actually running and finished booting?

**Better answer: stop using SSH.** Use `aws ssm start-session` and skip 1-4 entirely.

### "My ALB returns 503 Service Unavailable"

Almost always: **no healthy targets.**

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

Look at the `Reason` field:

| Reason | Meaning |
|---|---|
| `Target.NotRegistered` | Nothing registered in the target group |
| `Target.Timeout` | Security group is blocking the health check, or the app isn't listening |
| `Target.ResponseCodeMismatch` | App is up but `/health` returns a non-200 code |
| `Target.FailedHealthChecks` | The health check path doesn't exist |

Most common cause: **the target's security group doesn't allow traffic from the ALB's security group on the health check port.**

### "My private instance can't reach the internet"

1. Does the private route table have `0.0.0.0/0 → nat-xxx`?
2. Is the NAT Gateway in a **public** subnet? (Not the private one.)
3. Does the NAT Gateway's subnet route table have `0.0.0.0/0 → igw-xxx`?
4. Is the NAT Gateway state `available`?
5. Does the instance's security group allow **outbound** traffic?

### "DNS isn't resolving inside my VPC"

1. `enableDnsSupport` on the VPC — must be true
2. `enableDnsHostnames` on the VPC — **must be true, defaults to false**
3. For private hosted zones: is the zone associated with **this** VPC?
4. Is the DHCP option set using `AmazonProvidedDNS`?
5. Does the security group allow outbound UDP 53?

### "EKS pods stuck in ContainerCreating"

```bash
kubectl describe pod <name>
# "failed to assign an IP address to container" → IP exhaustion
```

1. Check free IPs in your subnets
2. Enable prefix delegation: `ENABLE_PREFIX_DELEGATION=true`
3. Or add a secondary CIDR (`100.64.0.0/16`) with custom networking
4. Check whether you've hit the node's max-pods limit

### "Traffic between two peered VPCs doesn't work"

1. Is the peering connection `active` (accepted, not just requested)?
2. Are there routes on **both** sides? Peering needs both.
3. Do the security groups allow the other VPC's CIDR?
4. Do the CIDRs overlap? If so, peering can't work — you need PrivateLink.
5. Are you trying to route *through* an intermediate VPC? Peering isn't transitive.

### Tools that save time

**VPC Reachability Analyzer** — tell it a source and destination; it tells you exactly which rule is blocking you.

```bash
aws ec2 create-network-insights-path \
  --source i-0aaa --destination i-0bbb \
  --protocol tcp --destination-port 443
aws ec2 start-network-insights-analysis --network-insights-path-id nip-xxx
```

This is dramatically faster than manually checking route tables and security groups. Use it first, not last.

**VPC Flow Logs** — records every connection attempt.

```bash
aws ec2 create-flow-logs \
  --resource-type VPC --resource-ids $VPC_ID \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /aws/vpc/flowlogs \
  --deliver-logs-permission-arn arn:aws:iam::...:role/flowlogsRole
```

A record ending in `REJECT` tells you a security group or NACL blocked something — and which addresses and ports were involved.

**Network Access Analyzer** — scans for unintended paths, e.g. "show me everything that can reach the internet." Good for audits.

---

## 19. Glossary

| Term | Meaning |
|---|---|
| **ALB** | Application Load Balancer. Routes HTTP/HTTPS by path, host, or header. |
| **ALIAS record** | Route 53 record type pointing at an AWS resource. Works at the domain root, unlike CNAME. |
| **AZ** | Availability Zone. One or more physical data centers within a region. |
| **CIDR** | The `/16` notation describing a block of IP addresses. |
| **CNI** | Container Network Interface. The plugin giving Kubernetes pods their networking. |
| **CoreDNS** | The DNS server running inside a Kubernetes cluster. |
| **ENI** | Elastic Network Interface. A virtual network card attached to an instance. |
| **Elastic IP** | A public IP you own permanently and can move between resources. |
| **Ephemeral port** | A temporary high-numbered port (1024-65535) a client uses for outgoing connections. |
| **IGW** | Internet Gateway. Two-way door between a VPC and the internet. |
| **IMDS** | Instance Metadata Service at `169.254.169.254`. Always enforce v2. |
| **Ingress** | Kubernetes resource that (with the AWS controller) creates an ALB. |
| **NACL** | Network ACL. Stateless subnet-level firewall supporting deny rules. |
| **NAT Gateway** | One-way outbound internet access for private subnets. |
| **NLB** | Network Load Balancer. Layer 4, very fast, supports static IPs. |
| **Pod** | The smallest deployable unit in Kubernetes. Gets its own VPC IP with the AWS CNI. |
| **Prefix delegation** | EKS setting assigning `/28` IP blocks per ENI, raising pod density. |
| **Prefix list** | An AWS-managed list of IP ranges for a service, usable in routes and SG rules. |
| **PrivateLink** | Technology behind interface endpoints; private access to services via ENIs. |
| **Route 53** | AWS's DNS service. |
| **Route table** | The list of rules deciding where packets from a subnet go. |
| **Security group** | Stateful firewall attached to a resource. Allow rules only. |
| **Service (k8s)** | Stable name and address in front of a changing set of pods. |
| **SSM Session Manager** | Shell access to instances with no open ports and no SSH keys. |
| **Subnet** | A slice of a VPC in one AZ. Public if routed to an IGW, private otherwise. |
| **Target group** | A list of destinations plus health check rules, used by a load balancer. |
| **Transit Gateway** | Hub-and-spoke router connecting many VPCs and on-prem networks transitively. |
| **VPC** | Virtual Private Cloud. Your isolated network inside AWS. |
| **VPC Endpoint** | Private connection to an AWS service without traversing the internet. |
| **VPC Peering** | Direct link between two VPCs. Not transitive. |

---

## Where to Go Next

**Practice:** Rebuild Part One from scratch without looking. Then rebuild it in Terraform. Then break something on purpose and fix it with Reachability Analyzer.

**Read:** The AWS Well-Architected Framework's Security and Reliability pillars. The VPC User Guide is genuinely well written.

**Certify:** *AWS Certified Solutions Architect – Associate* covers roughly 70% of this material. *AWS Certified Advanced Networking – Specialty* covers all of it and much more.

**Remember the one rule that matters most:**

> **Put nothing in a public subnet except load balancers and NAT gateways.**

Follow that and you've avoided most of the security problems people actually have.

---

*Tutorial written for AWS as of July 2026. AWS changes constantly — verify pricing and feature details against current AWS documentation before making production decisions.*
