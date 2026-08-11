# AWS Networking Explained Simply
### Domain Name → Load Balancer → Target Group → EC2 Server, with SSL
### Plus: everything that can go wrong, and exactly how to check it

---

## Table of Contents

1. [What this guide teaches you](#1-what-this-guide-teaches-you)
2. [Background: how the internet actually works (the mail analogy)](#2-background-how-the-internet-actually-works-the-mail-analogy)
3. [The big picture diagram](#3-the-big-picture-diagram)
4. [PART A — Step-by-step: build one working example](#4-part-a--step-by-step-build-one-working-example)
5. [The request flow, written out in words](#5-the-request-flow-written-out-in-words)
6. [PART B — Every piece explained in detail](#6-part-b--every-piece-explained-in-detail)
7. [PART C — Everything that can go wrong](#7-part-c--everything-that-can-go-wrong)
8. [PART D — The debugging flowchart](#8-part-d--the-debugging-flowchart)
9. [Command cheat sheet](#9-command-cheat-sheet)
10. [Best practices](#10-best-practices)
11. [Cost traps](#11-cost-traps)
12. [Glossary](#12-glossary)

---

## 1. What this guide teaches you

By the end of this you will be able to:

- Explain what a **hosted zone**, **load balancer**, **target group**, **security group**, and **SSL certificate** actually do
- Build a real website that answers at `https://shop.example.com`
- Look at an error like "503 Service Unavailable" or "connection timed out" and know *exactly* which of the 7 links in the chain broke
- Run the commands that prove where the break is, instead of guessing

**Who this is for:** anyone. If you know what a website is, you know enough to start.

---

## 2. Background: how the internet actually works (the mail analogy)

Before AWS, understand the plain internet. Everything in AWS is just these ideas wearing a costume.

### 2.1 IP address = a street address

Every computer on a network has a number called an **IP address**, like `54.23.11.9` or `10.0.1.42`. It is exactly like a house address. If you want to send data to a computer, you need its address.

Two kinds:

| Type | Example | Meaning |
|---|---|---|
| **Public IP** | `54.23.11.9` | Reachable from anywhere on the internet |
| **Private IP** | `10.0.1.42` | Only reachable inside your own private network |

Private IPs always start with `10.`, `172.16–172.31.`, or `192.168.`. Those ranges are reserved worldwide for private use. Your home WiFi uses them too.

### 2.2 Port = an apartment number

One computer can run many programs at once — a web server, a database, an SSH login service. So an address alone isn't enough. You also need a **port number**, a number from 1 to 65535.

Think of it as: IP address = the apartment building, port = the apartment number.

The famous ones:

| Port | Used for | Notes |
|---|---|---|
| **22** | SSH (remote login to a Linux server) | Admin only. Never open to the world. |
| **80** | HTTP (plain, unencrypted web) | Anyone in the middle can read it |
| **443** | HTTPS (encrypted web) | What real websites use |
| **3389** | RDP (remote desktop for Windows) | Admin only |
| **3306** | MySQL database | Never open to the world |
| **5432** | PostgreSQL database | Never open to the world |
| **8080 / 3000 / 5000** | Where app code often listens internally | Node.js, Java, Python apps love these |
| **1024–65535** | "Ephemeral" ports | Temporary ports your computer uses to *receive replies* |

That last row matters more than people expect — see the NACL section later.

### 2.3 DNS = the phone book

Nobody remembers `54.23.11.9`. So there is a giant worldwide phone book called **DNS** (Domain Name System). You say "shop.example.com" and DNS answers "that's `54.23.11.9`".

DNS is organized like a tree, from right to left:

```
                        . (the root)
                        |
        +---------------+---------------+
        |               |               |
       com             org             net          <- top-level domains
        |
    example.com                                     <- your domain (you rent this)
        |
  +-----+------+
  |            |
shop.        api.example.com                        <- records inside your zone
example.com
```

When your browser looks up `shop.example.com`, it asks the root, which says "ask `.com`", which says "ask example.com's name servers", which finally gives the answer. This is called **delegation**, and it is the #1 source of "why isn't my domain working" problems.

### 2.4 Protocol = the language spoken

Once connected to an address and port, both sides must speak the same language.

- **TCP** — the reliable one. Confirms every piece arrived. Used by web, SSH, databases.
- **UDP** — the fast, no-confirmation one. Used by video calls, DNS lookups, gaming.
- **HTTP** — the web language, spoken on top of TCP.
- **HTTPS** — HTTP wrapped inside encryption (TLS).

### 2.5 The TCP handshake = knocking on the door

Before any data flows, TCP does a 3-step greeting:

```
  YOU                                    SERVER
   |                                        |
   |------- 1. SYN     "Hi, you there?" --->|
   |                                        |
   |<------ 2. SYN-ACK "Yes, I'm here!" ----|
   |                                        |
   |------- 3. ACK     "Great, talking." -->|
   |                                        |
   |========== connection open =============|
```

**Why you care:** the *way* this fails tells you the problem.

| What happens | What it means |
|---|---|
| **Connection refused** (instant rejection) | You reached the machine, but nothing is listening on that port. The app is down or listening on a different port. |
| **Connection timed out** (hangs ~30s, then fails) | Your packet was silently dropped. A firewall (security group / NACL) ate it, or routing is wrong. |
| **Connection reset** | Something actively killed the connection mid-stream. |

Memorize this. "Refused" vs "timed out" cuts your debugging time in half every single time.

### 2.6 TLS / SSL = the sealed envelope

**SSL** is the old name, **TLS** is the current name. People say "SSL" out of habit; every modern system actually uses TLS (version 1.2 or 1.3).

TLS does three jobs:

1. **Encryption** — nobody in between can read the contents
2. **Identity** — proves the server really is `shop.example.com`, using a **certificate** signed by a trusted authority
3. **Integrity** — proves nobody changed the data in transit

The TLS handshake, right after the TCP handshake:

```
  BROWSER                                       SERVER
     |                                             |
     |-- "Hello. I want shop.example.com" -------->|   <-- this name is called SNI
     |   (+ list of encryption I support)          |
     |                                             |
     |<-- "Hello. Here is my certificate" ---------|
     |    (cert says: I am shop.example.com,       |
     |     signed by Amazon Trust Services)        |
     |                                             |
     | [browser checks: is the name right?         |
     |  is it expired? do I trust the signer?]     |
     |                                             |
     |<========= encrypted tunnel open ===========>|
```

**SNI** (Server Name Indication) is important: it's how one load balancer with one IP address can serve 50 different domains with 50 different certificates. The browser announces which site it wants *before* the certificate is chosen.

---

## 3. The big picture diagram

Here is the whole system you are going to build.

```
                              👤 USER'S BROWSER
                          types https://shop.example.com
                                       |
                                       | (1) DNS lookup
                                       v
        ┌──────────────────────────────────────────────────────────┐
        │  ROUTE 53 — PUBLIC HOSTED ZONE for "example.com"         │
        │                                                          │
        │   shop.example.com   A (Alias) --> my-alb-123.us-east-1  │
        │   www.example.com    A (Alias) --> my-alb-123.us-east-1  │
        │   _abc123.example.com CNAME --> ACM validation record    │
        └──────────────────────────────────────────────────────────┘
                                       |
                        answers: 54.23.11.9 , 54.23.11.10
                                       |
                                       | (2) HTTPS request to port 443
                                       v
    ╔══════════════════════════════════════════════════════════════════════╗
    ║  AWS REGION: us-east-1                                               ║
    ║  ┌────────────────────────────────────────────────────────────────┐  ║
    ║  │ VPC   10.0.0.0/16   (your own private network in the cloud)    │  ║
    ║  │                                                                │  ║
    ║  │        ┌───────────────────┐                                   │  ║
    ║  │        │  INTERNET GATEWAY │  <-- the only door to the internet│  ║
    ║  │        └─────────┬─────────┘                                   │  ║
    ║  │                  |                                             │  ║
    ║  │   ┌──────────────┴───────────────────────────────┐             │  ║
    ║  │   │  PUBLIC SUBNETS (route 0.0.0.0/0 -> IGW)     │             │  ║
    ║  │   │                                              │             │  ║
    ║  │   │  AZ us-east-1a          AZ us-east-1b        │             │  ║
    ║  │   │  10.0.1.0/24            10.0.2.0/24          │             │  ║
    ║  │   │  ┌───────────┐          ┌───────────┐        │             │  ║
    ║  │   │  │ ALB node  │          │ ALB node  │        │             │  ║
    ║  │   │  └─────┬─────┘          └─────┬─────┘        │             │  ║
    ║  │   └────────┼──────────────────────┼──────────────┘             │  ║
    ║  │            │   APPLICATION LOAD BALANCER (internet-facing)     │  ║
    ║  │            │   SG-ALB: allow IN 443 + 80 from 0.0.0.0/0        │  ║
    ║  │            │   Listener :443 -> TLS cert from ACM              │  ║
    ║  │            │   Listener :80  -> redirect to 443                │  ║
    ║  │            │                                                   │  ║
    ║  │            │  (3) TLS ends here. New plain HTTP conn to target │  ║
    ║  │            v                                                   │  ║
    ║  │   ┌────────────────────────────────────────────┐               │  ║
    ║  │   │  TARGET GROUP  "tg-shop-web"               │               │  ║
    ║  │   │  protocol HTTP, port 8080                  │               │  ║
    ║  │   │  health check: GET /health, expect 200     │               │  ║
    ║  │   │  ┌──────────────┬──────────────┐           │               │  ║
    ║  │   │  │ i-aaa healthy│ i-bbb healthy│           │               │  ║
    ║  │   │  └──────┬───────┴──────┬───────┘           │               │  ║
    ║  │   └─────────┼──────────────┼───────────────────┘               │  ║
    ║  │             │              │  (4) forward to a healthy target  │  ║
    ║  │   ┌─────────┼──────────────┼───────────────────────────────┐   │  ║
    ║  │   │  PRIVATE SUBNETS (no route to IGW)                     │   │  ║
    ║  │   │         v              v                               │   │  ║
    ║  │   │  10.0.11.0/24    10.0.12.0/24                          │   │  ║
    ║  │   │  ┌───────────┐   ┌───────────┐                         │   │  ║
    ║  │   │  │  EC2 #1   │   │  EC2 #2   │                         │   │  ║
    ║  │   │  │ 10.0.11.5 │   │ 10.0.12.7 │                         │   │  ║
    ║  │   │  │ app :8080 │   │ app :8080 │                         │   │  ║
    ║  │   │  └─────┬─────┘   └─────┬─────┘                         │   │  ║
    ║  │   │        │               │                               │   │  ║
    ║  │   │  SG-EC2: allow IN 8080 ONLY from SG-ALB                │   │  ║
    ║  │   │          allow IN 22 ONLY from SG-Bastion (or use SSM) │   │  ║
    ║  │   └────────┼───────────────┼────────────────────────────────┘  │  ║
    ║  │            │               │  (5) outbound for updates         │  ║
    ║  │            v               v                                   │  ║
    ║  │        ┌──────────────────────┐                                │  ║
    ║  │        │  NAT GATEWAY         │ (sits in a PUBLIC subnet)      │  ║
    ║  │        │  lets private boxes  │                                │  ║
    ║  │        │  call out, but no    │                                │  ║
    ║  │        │  one can call in     │                                │  ║
    ║  │        └──────────┬───────────┘                                │  ║
    ║  │                   └──────> INTERNET GATEWAY ──> internet       │  ║
    ║  └────────────────────────────────────────────────────────────────┘  ║
    ╚══════════════════════════════════════════════════════════════════════╝
```

**Read it as one sentence:** the browser asks Route 53 for an address, Route 53 points to the load balancer, the load balancer decrypts HTTPS and picks a healthy EC2 server from a target group, and firewalls at every layer decide whether each hop is allowed.

---

## 4. PART A — Step-by-step: build one working example

**Goal:** `https://shop.example.com` shows your web app, running on two EC2 servers, with a valid green-padlock certificate.

**Assumption:** you already own the domain `example.com` somewhere (Route 53, GoDaddy, Namecheap, anywhere).

---

### Step 1 — Create the VPC and subnets

The **VPC** (Virtual Private Cloud) is your own private network inside AWS. Nothing exists outside a VPC.

Console: **VPC → Create VPC → "VPC and more"**. This wizard builds everything correctly in one shot, and is what AWS recommends for beginners.

Settings:

| Setting | Value | Why |
|---|---|---|
| IPv4 CIDR | `10.0.0.0/16` | Gives you 65,536 private addresses. Room to grow. |
| Availability Zones | **2** | A load balancer legally requires 2. Also survives one data center failing. |
| Public subnets | **2** | The load balancer lives here |
| Private subnets | **2** | Your EC2 servers live here |
| NAT gateways | **1 per AZ** (or "In 1 AZ" to save money) | So private servers can download updates |
| DNS hostnames | **Enabled** | Required for lots of things to work |
| DNS resolution | **Enabled** | Required |

What the wizard silently creates for you:

```
VPC 10.0.0.0/16
├── Internet Gateway (attached)
├── Public subnet  10.0.1.0/24  (us-east-1a) ─┐
├── Public subnet  10.0.2.0/24  (us-east-1b) ─┤── route table: 0.0.0.0/0 -> IGW
├── Private subnet 10.0.11.0/24 (us-east-1a) ─┐
├── Private subnet 10.0.12.0/24 (us-east-1b) ─┤── route table: 0.0.0.0/0 -> NAT
└── NAT Gateway (sitting in a public subnet, with an Elastic IP)
```

> **The one-line definition of "public subnet":** a subnet whose route table has a route `0.0.0.0/0 → Internet Gateway`. That's literally the only difference. There is no checkbox called "make public."

⚠️ **Subnet size rule for load balancers:** each subnet you give the ALB must be at least a `/27` (32 addresses) and have **at least 8 free IP addresses**. The ALB needs room to scale itself up. A `/24` is a safe default.

---

### Step 2 — Create the security groups (do this BEFORE the servers)

A **security group** is a firewall that wraps around a resource. Create three, and make them reference each other rather than raw IP addresses.

**SG-ALB** (for the load balancer)

| Direction | Type | Port | Source/Destination |
|---|---|---|---|
| Inbound | HTTPS | 443 | `0.0.0.0/0` (anyone) |
| Inbound | HTTP | 80 | `0.0.0.0/0` (anyone — will just redirect) |
| Outbound | All | All | `0.0.0.0/0` |

**SG-EC2** (for the web servers)

| Direction | Type | Port | Source/Destination |
|---|---|---|---|
| Inbound | Custom TCP | 8080 | **SG-ALB** ← select the security group, not an IP |
| Inbound | SSH | 22 | **SG-Bastion** (or skip entirely and use SSM) |
| Outbound | All | All | `0.0.0.0/0` |

**SG-Bastion** (optional jump box)

| Direction | Type | Port | Source/Destination |
|---|---|---|---|
| Inbound | SSH | 22 | **your office IP only**, e.g. `203.0.113.45/32` |

> 🔑 **The single most important trick in AWS networking:** in the "Source" box of a security group rule, you can type another security group's ID. This means "allow anything wearing that badge." Your EC2 servers' IPs can change, autoscaling can add ten more — the rule keeps working forever. Never hardcode the ALB's IPs. They change without warning.

---

### Step 3 — Launch the EC2 servers

Console: **EC2 → Launch instance**. Do it twice, once per AZ, or use an Auto Scaling group.

| Setting | Value |
|---|---|
| AMI | Amazon Linux 2023 |
| Instance type | `t3.micro` to start |
| VPC | your new VPC |
| Subnet | private subnet in us-east-1a (then 1b for the second one) |
| Auto-assign public IP | **Disable** — private servers don't need one |
| Security group | **SG-EC2** |
| IAM instance profile | attach a role with `AmazonSSMManagedInstanceCore` |
| Metadata version | **IMDSv2 required** (this is now the default — leave it) |

That IAM role is worth the 30 seconds: it lets you log in through **SSM Session Manager** with zero open SSH ports and no key files. It is the modern, safer replacement for a bastion host.

User data script to install a test web server on port 8080:

```bash
#!/bin/bash
dnf install -y nginx
# make nginx listen on 8080 instead of 80
sed -i 's/listen       80;/listen       8080;/' /etc/nginx/nginx.conf
sed -i 's/listen       \[::\]:80;/listen       [::]:8080;/' /etc/nginx/nginx.conf
# a health check endpoint the load balancer can ping
mkdir -p /usr/share/nginx/html
echo "OK" > /usr/share/nginx/html/health
echo "<h1>Hello from $(hostname -f)</h1>" > /usr/share/nginx/html/index.html
systemctl enable --now nginx
```

**Verify before moving on.** Connect with SSM (**EC2 → select instance → Connect → Session Manager**) and run:

```bash
curl -i http://localhost:8080/health     # must print HTTP/1.1 200 OK  and  OK
sudo ss -tlnp | grep 8080                # must show nginx listening
```

If `ss` shows `127.0.0.1:8080` instead of `0.0.0.0:8080`, **stop here.** Your app is only listening to itself and the load balancer will never reach it. This is an extremely common mistake.

---

### Step 4 — Create the target group

A **target group** is a labeled list of servers plus the rules for checking whether they're alive.

Console: **EC2 → Target Groups → Create target group**

| Setting | Value | Why |
|---|---|---|
| Target type | **Instances** | Simplest. (Alternatives explained in Part B.) |
| Protocol : Port | **HTTP : 8080** | The port your app listens on, *not* 443 |
| VPC | your VPC | |
| Protocol version | HTTP1 | Use HTTP2 or gRPC only if your app speaks it |
| Health check protocol | HTTP | |
| Health check path | `/health` | A cheap page that doesn't touch the database |
| Healthy threshold | 2 | 2 passes in a row = alive |
| Unhealthy threshold | 2 | 2 fails in a row = dead |
| Timeout | 5 seconds | |
| Interval | 30 seconds | |
| Success codes | `200` | |
| Deregistration delay | 30 seconds | Lower than the default 300 for faster deploys |

Then **register** both EC2 instances.

**Verify:** watch the Targets tab. Within about a minute both should flip from `initial` to **`healthy`**. If they stay `unhealthy`, jump to section 7.4 — do not continue building on top of a broken foundation.

---

### Step 5 — Request the SSL certificate

Console: **Certificate Manager (ACM) → Request → Public certificate**

⚠️ **The certificate must be in the same AWS region as your load balancer.** An ACM certificate in `us-west-2` is invisible to an ALB in `us-east-1`. (The one exception: CloudFront always needs its cert in `us-east-1`.) This trips up almost everyone once.

| Setting | Value |
|---|---|
| Domain name | `shop.example.com` |
| Additional names | `www.example.com`, and `*.example.com` if you want a wildcard |
| Validation method | **DNS validation** (strongly preferred) |
| Key algorithm | RSA 2048 (universal) or ECDSA P-256 (faster, tiny) |

ACM then shows you a `CNAME` record to create. If your domain's hosted zone is in Route 53 in the same account, there's a **"Create records in Route 53"** button that does it for you in one click.

Status goes `Pending validation` → **`Issued`**, usually in 1–15 minutes.

**Why DNS validation and not email validation:**

| | DNS validation | Email validation |
|---|---|---|
| Renewal | **Automatic, forever**, as long as the record stays | Manual email click every 13 months |
| Speed | Minutes | Depends on someone reading email |
| Failure mode | Only if you delete the record | Someone leaves the company, cert expires, site dies |

> 🔒 **Never delete the ACM validation CNAME record.** It looks like junk (`_a79865eb4cd1a6ab.shop.example.com`). It is not junk. It is what silently renews your certificate every year. Deleting it is a classic self-inflicted outage that shows up 12 months later.

ACM certificates are **free** and **auto-renew**. Their only limitation: you can't export the private key, so they only work with AWS services (ALB, NLB, CloudFront, API Gateway) — not on an EC2 instance directly.

---

### Step 6 — Create the Application Load Balancer

Console: **EC2 → Load Balancers → Create → Application Load Balancer**

| Setting | Value | Why |
|---|---|---|
| Scheme | **Internet-facing** | Gets public IPs. Use "Internal" for private-only services. |
| IP address type | IPv4 (or Dualstack) | |
| VPC | your VPC | |
| Mappings | both **public** subnets | Must be public, or the internet can't reach it |
| Security group | **SG-ALB** | Remove the default SG |

**Listeners** — a listener is a door with a rule attached.

Listener 1:
```
Protocol HTTPS : Port 443
  Default SSL certificate: shop.example.com (from ACM)
  Security policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  Default action: Forward → tg-shop-web
```

Listener 2:
```
Protocol HTTP : Port 80
  Default action: Redirect to HTTPS
    → port 443, status code HTTP_301 (permanent)
```

That redirect is the correct way to handle port 80. Don't serve real content on it; just bounce everyone to the secure version.

**Security policy** is the list of encryption methods you'll accept. `ELBSecurityPolicy-TLS13-1-2-2021-06` allows TLS 1.2 and 1.3 and blocks the old broken stuff. Use it unless you have a documented reason not to.

After creating, wait for State = **Active** (2–4 minutes) and copy the **DNS name**, which looks like:

```
my-alb-1234567890.us-east-1.elb.amazonaws.com
```

**Verify before touching DNS:**

```bash
curl -kv https://my-alb-1234567890.us-east-1.elb.amazonaws.com
```

If that returns your page, the entire AWS half of the system works. Anything broken from here is a DNS problem. (`-k` skips certificate checking, which will fail on the raw ALB name — that's expected and fine.)

---

### Step 7 — Point the domain at the load balancer

Console: **Route 53 → Hosted zones → example.com → Create record**

| Setting | Value |
|---|---|
| Record name | `shop` |
| Record type | **A** |
| **Alias** | **ON** ← this is the key toggle |
| Route traffic to | Alias to Application and Classic Load Balancer |
| Region | us-east-1 |
| Load balancer | your ALB |
| Routing policy | Simple |

**Alias vs CNAME — why Alias wins:**

| | Alias record (AWS-only) | CNAME record (standard DNS) |
|---|---|---|
| Works at the root domain (`example.com`)? | ✅ **Yes** | ❌ No — DNS forbids it |
| Cost of lookups | **Free** | Charged per query |
| Health-aware | Yes, can track target health | No |
| Follows the ALB's changing IPs | Yes, automatically | Yes, but with an extra lookup hop |
| Works outside Route 53? | No | Yes |

Use **Alias** for anything pointing at an AWS resource. Always.

---

### Step 8 — Verify the whole chain

Run these in order. Each one proves a different link.

```bash
# 1. Does DNS answer, and with the right addresses?
dig +short shop.example.com
#    expect: two or more public IPs

# 2. Is the TCP door open on 443?
nc -zv shop.example.com 443
#    expect: succeeded!

# 3. Is the certificate valid and correctly named?
openssl s_client -connect shop.example.com:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
#    expect: subject=CN=shop.example.com, notAfter= a date ~13 months out

# 4. Does the full HTTPS request work end to end?
curl -v https://shop.example.com
#    expect: HTTP/2 200, and your page HTML

# 5. Does the port 80 redirect work?
curl -I http://shop.example.com
#    expect: HTTP/1.1 301 Moved Permanently
#            Location: https://shop.example.com:443/
```

If all five pass, you're done. 🎉

---

## 5. The request flow, written out in words

This is the same journey as the diagram, but as a numbered checklist. **Every debugging session is just finding which of these steps failed.**

```
════════════════════════════════════════════════════════════════════
 PHASE 1 — FINDING THE ADDRESS (DNS)
════════════════════════════════════════════════════════════════════
 1. User types  https://shop.example.com
 2. Browser checks its own cache. Miss.
 3. OS asks the local DNS resolver (your ISP, or 8.8.8.8).
 4. Resolver asks a root server:  "who handles .com?"
 5. Resolver asks .com:           "who handles example.com?"
    -> .com replies with the NAME SERVERS listed at your registrar
      !! FAILURE POINT: if the registrar's NS records don't match
         your Route 53 hosted zone's NS records, everything below
         never happens. Nothing else you do will fix it.
 6. Resolver asks those name servers: "what is shop.example.com?"
 7. Route 53 finds the Alias record and returns the ALB's live IPs.
      !! FAILURE POINT: record missing, typo'd, wrong type, or you
         edited a DUPLICATE hosted zone for the same domain.
 8. Answer is cached everywhere for TTL seconds.
      !! FAILURE POINT: an old TTL of 86400 means your change takes
         a full day to reach some users.

════════════════════════════════════════════════════════════════════
 PHASE 2 — REACHING THE LOAD BALANCER (TCP)
════════════════════════════════════════════════════════════════════
 9. Browser opens a TCP connection to  <ALB-IP>:443.
10. Packet crosses the internet to the AWS edge.
11. Packet enters your VPC through the INTERNET GATEWAY.
      !! FAILURE POINT: ALB placed in subnets with no route to the
         IGW = it isn't really public. Symptom: TIMEOUT.
12. NETWORK ACL on the public subnet checks inbound rules.
      !! FAILURE POINT: custom NACL missing the inbound 443 rule,
         or missing the OUTBOUND 1024-65535 rule for replies.
         Symptom: TIMEOUT (NACLs drop silently).
13. SECURITY GROUP SG-ALB checks: is 443 allowed from this IP?
      !! FAILURE POINT: only your office IP allowed; you're testing
         from home. Symptom: TIMEOUT.
14. TCP 3-way handshake completes. Door is open.

════════════════════════════════════════════════════════════════════
 PHASE 3 — PROVING IDENTITY (TLS)
════════════════════════════════════════════════════════════════════
15. Browser sends TLS ClientHello, announcing "shop.example.com"
    via SNI, plus the cipher suites it supports.
16. ALB picks a matching certificate from its listener.
      !! FAILURE POINT: no cert covers that exact name ->
         ERR_CERT_COMMON_NAME_INVALID.
      !! FAILURE POINT: no shared cipher (very old client vs
         TLS-1.3-only policy) -> HANDSHAKE FAILURE.
17. Browser validates: name matches? not expired? signed by a
    Certificate Authority I trust? Is the chain complete?
18. Encrypted tunnel established.

════════════════════════════════════════════════════════════════════
 PHASE 4 — CHOOSING A SERVER (Load balancing)
════════════════════════════════════════════════════════════════════
19. ALB decrypts the request and reads the HTTP Host header + path.
20. ALB walks its LISTENER RULES top to bottom, first match wins,
    and lands on a target group.
      !! FAILURE POINT: host/path rule doesn't match -> the default
         action fires instead (often a 404 fixed response).
21. ALB picks a HEALTHY target from that group (round robin).
      !! FAILURE POINT: zero healthy targets -> HTTP 503.

════════════════════════════════════════════════════════════════════
 PHASE 5 — REACHING THE SERVER
════════════════════════════════════════════════════════════════════
22. ALB opens a NEW, SEPARATE connection to 10.0.11.5:8080.
    (The client connection and the target connection are two
     different connections. This matters - see "X-Forwarded-For".)
      !! FAILURE POINT: SG-EC2 doesn't allow 8080 from SG-ALB ->
         TIMEOUT -> HTTP 504.
      !! FAILURE POINT: app not running / wrong port ->
         REFUSED -> HTTP 502.
      !! FAILURE POINT: app speaks HTTPS but target group says
         HTTP (or vice versa) -> HTTP 502.
23. App handles the request and replies.
      !! FAILURE POINT: app takes longer than the ALB idle timeout
         (default 60s) -> HTTP 504.
24. Reply travels back: EC2 -> ALB -> re-encrypted -> browser. Done.
```

**Keep this list handy.** When something breaks, you are always answering one question: *which number stopped?*

---

## 6. PART B — Every piece explained in detail

### 6.1 VPC, subnets, and route tables

**VPC** = your own private, isolated network inside an AWS region. Two VPCs cannot talk to each other unless you deliberately connect them.

**Subnet** = a slice of the VPC that lives in exactly **one Availability Zone**. An AZ is one or more physical data centers. Spreading across AZs is how you survive a data center outage.

**CIDR notation** — `10.0.1.0/24` means "the first 24 bits are fixed, the last 8 vary."

| CIDR | Total addresses | Usable in AWS |
|---|---|---|
| `/16` | 65,536 | 65,531 |
| `/24` | 256 | 251 |
| `/27` | 32 | 27 |
| `/28` | 16 | 11 (smallest AWS allows) |

**AWS reserves 5 addresses in every subnet.** In `10.0.1.0/24`:

| Address | Reserved for |
|---|---|
| `10.0.1.0` | Network address |
| `10.0.1.1` | The VPC router |
| `10.0.1.2` | AWS DNS server (also reachable at `169.254.169.253`) |
| `10.0.1.3` | Reserved for future use |
| `10.0.1.255` | Broadcast address |

**Route table** = the signpost. It says "traffic for THIS destination goes THAT way." The most specific match wins.

Public subnet route table:
```
Destination      Target          Meaning
10.0.0.0/16      local           inside my VPC, stay local (always present, cannot be removed)
0.0.0.0/0        igw-abc123      everything else, go to the internet
```

Private subnet route table:
```
Destination      Target          Meaning
10.0.0.0/16      local           inside my VPC, stay local
0.0.0.0/0        nat-xyz789      everything else, go out via NAT (one-way)
```

**Internet Gateway (IGW)** — the door between your VPC and the internet. Free, horizontally scaled, one per VPC. Traffic can go both directions.

**NAT Gateway** — a one-way valve. Servers in private subnets can reach out (to download patches, call APIs), but nothing on the internet can start a connection inward. It lives in a public subnet, costs roughly **$32/month plus per-GB data processing**, and is often the single largest surprise on a small AWS bill.

> **Cheaper alternative to NAT:** if your private servers only need to talk to AWS services (S3, ECR, Systems Manager, DynamoDB), use **VPC Endpoints** instead. Gateway endpoints for S3 and DynamoDB are completely free.

### 6.2 Security Groups vs Network ACLs

Both are firewalls. They behave very differently, and confusing them causes hours of pain.

| | **Security Group** | **Network ACL (NACL)** |
|---|---|---|
| Wraps around | An individual resource (EC2, ALB, RDS) | An entire subnet |
| **Stateful?** | **Yes** | **No** |
| What that means | If you allow traffic in, the reply is automatically allowed out | You must write inbound AND outbound rules separately |
| Rule types | **Allow only** | Allow **and** Deny |
| Evaluation | All rules considered together | Numbered, lowest number first, first match wins |
| Can reference another SG? | **Yes** — the killer feature | No, IP ranges only |
| Default behavior | Deny all inbound, allow all outbound | Default NACL allows everything |
| When it blocks you, you see | **Timeout** (silent drop) | **Timeout** (silent drop) |

**The stateless NACL trap.** You want web traffic in, so you write:

```
Inbound  Rule 100:  Allow TCP 443 from 0.0.0.0/0     <- correct
Outbound Rule 100:  Allow TCP 443 to   0.0.0.0/0     <- WRONG
```

This does not work. When your server replies, it sends *from* port 443 *to* the client's **ephemeral port** (a random number between 1024 and 65535). The correct outbound rule is:

```
Outbound Rule 100:  Allow TCP 1024-65535 to 0.0.0.0/0    <- CORRECT
```

Security groups never have this problem, because they remember ("keep state" on) the request you allowed in.

> **Practical advice:** leave NACLs at their permissive default and do all your filtering with security groups. Add NACL rules only when a compliance requirement forces you to, or to block a specific attacking IP range — something SGs cannot do, since they have no Deny rule.

### 6.3 Route 53 and hosted zones

A **hosted zone** is a container of DNS records for one domain. Creating one costs about **$0.50/month**.

**Public vs Private hosted zones:**

| | Public | Private |
|---|---|---|
| Who can query it | The whole internet | Only resources inside VPCs you associate |
| Use for | Your real website | Internal names like `db.internal.example.com` |
| Requires | You control the domain | Association with one or more VPCs, plus `enableDnsHostnames` and `enableDnsSupport` turned on |

**Split-horizon DNS:** you can have a public *and* a private zone for the same name. Inside the VPC, the private zone wins. This lets `api.example.com` resolve to a private IP internally and a public IP externally. Powerful — and a confusing debugging surprise if you forget you set it up.

**The delegation check — the #1 DNS problem.** When you create a hosted zone, Route 53 assigns it four name servers. Those must be entered at your **registrar** (wherever you bought the domain). If they don't match, nothing works no matter how perfect your records are.

```bash
# What the world thinks is authoritative for your domain:
dig NS example.com +short @8.8.8.8

# What your Route 53 hosted zone claims:
aws route53 get-hosted-zone --id /hostedzone/Z1234567890ABC \
  --query 'DelegationSet.NameServers'

# THESE TWO LISTS MUST MATCH.
```

**Record types you'll actually use:**

| Type | Points to | Example |
|---|---|---|
| **A** | An IPv4 address | `shop -> 54.23.11.9` |
| **AAAA** | An IPv6 address | `shop -> 2600:1f18::1` |
| **CNAME** | Another *name* | `www -> shop.example.com` |
| **A (Alias)** | An AWS resource | `shop -> my-alb.elb.amazonaws.com` |
| **MX** | Mail servers | `example.com -> 10 mail.example.com` |
| **TXT** | Free text (SPF, domain ownership proof) | `"v=spf1 include:..."` |
| **NS** | Delegates a subdomain elsewhere | |
| **CAA** | Which certificate authorities may issue for you | `0 issue "amazon.com"` |

**CNAME rules that bite people:** you cannot put a CNAME at the root of a domain (`example.com` itself), and a name holding a CNAME can have **no other records**. Adding a CNAME for `example.com` when MX records exist there will break your email.

**Routing policies:**

| Policy | What it does | Good for |
|---|---|---|
| **Simple** | One answer | Almost everything |
| **Weighted** | Split traffic by percentage | Canary releases, A/B tests |
| **Latency** | Nearest region by network speed | Global multi-region apps |
| **Failover** | Primary, plus a backup if a health check fails | Disaster recovery |
| **Geolocation** | By the user's country | Legal/compliance, localized content |
| **Multivalue answer** | Returns several healthy IPs | Poor-man's load balancing |

**TTL (Time To Live)** — how many seconds resolvers may cache the answer.

- Normal operation: **300 seconds** (5 minutes) is a good default
- **Before** a planned migration: drop the TTL to 60 a full day ahead, migrate, then raise it back
- Alias records have no TTL you control — Route 53 manages it

### 6.4 Load balancer types — which one to pick

| | **ALB** (Application) | **NLB** (Network) | **CLB** (Classic) |
|---|---|---|---|
| OSI Layer | 7 (HTTP) | 4 (TCP/UDP) | 4 and 7 |
| Understands URLs/headers | Yes | No | Barely |
| Protocols | HTTP, HTTPS, gRPC, WebSocket | TCP, UDP, TLS | HTTP, HTTPS, TCP |
| Static IP address | No (use the DNS name) | **Yes** (Elastic IP per AZ) | No |
| Speed | Fast | **Extremely fast**, ultra-low latency | Slow |
| Preserves client source IP | Via `X-Forwarded-For` header | **Natively** | Via header |
| AWS WAF integration | Yes | No | No |
| Path / host routing | Yes | No | No |
| Rough cost | ~$16/mo + LCU usage | ~$16/mo + NLCU usage | Legacy pricing |

**Pros and cons in plain terms:**

**ALB — pros:** routes by URL path, hostname, header, or query string, so you can run 20 microservices behind one load balancer; native HTTPS termination with free ACM certificates; built-in authentication via Cognito or any OIDC provider; works with AWS WAF; supports Lambda functions as targets.
**ALB — cons:** no static IP, which is a problem if a partner needs to allow-list your address; HTTP/HTTPS only; slightly higher latency than NLB; billing by "LCU" is hard to predict in advance.

**NLB — pros:** millions of requests per second at microsecond latency; static Elastic IPs; handles any TCP or UDP protocol (databases, game servers, MQTT); preserves the real client IP with no header tricks; can pass TLS through completely untouched.
**NLB — cons:** blind to HTTP, so no path routing, no header rules, no WAF; harder to debug because there is no access log of URLs; health checks are more basic.

**CLB — pros:** none for new work.
**CLB — cons:** deprecated. Migrate off it.

> **Rule of thumb:** websites and APIs go to an ALB. Databases, game servers, or "I need a static IP" go to an NLB. If you need caching and global edge locations, put **CloudFront** in front of your ALB.

### 6.5 Target groups in depth

**Target types — pick carefully, this cannot be changed later:**

| Type | You register | Best for | Watch out for |
|---|---|---|---|
| **Instance** | EC2 instance IDs | Classic EC2 setups | Needs a primary network interface in the VPC |
| **IP** | Raw IP addresses | Containers, on-prem servers over VPN/Direct Connect, several apps per host | Must be a private RFC1918 address, not a public one |
| **Lambda** | A Lambda function | Serverless behind a URL | ALB only, not NLB |
| **ALB** | Another load balancer | Putting an NLB in front of an ALB to gain a static IP | Niche use case |

**Health checks — how AWS decides a server is alive.**

The load balancer sends an HTTP request to each target on a schedule. Pass enough times in a row and it becomes `healthy`. Fail enough times and it becomes `unhealthy`, and traffic stops going there.

| Setting | Default | Advice |
|---|---|---|
| Path | `/` | Make a dedicated `/health` route |
| Port | traffic-port | Override only if health checks use a different port |
| Healthy threshold | 5 | 2 recovers faster |
| Unhealthy threshold | 2 | Keep it low so bad servers drain quickly |
| Timeout | 5s | Must be less than the interval |
| Interval | 30s | 10s detects faster, at higher load |
| Success codes | 200 | Can be a range such as `200-299` |

**How to design a good health check endpoint:**

**Do:** return 200 quickly; confirm the app can actually serve traffic; keep it a plain, unauthenticated route; log it at a low level so it doesn't flood your logs.
**Don't:** query the database on every check (30 servers checking every 30 seconds is a self-inflicted DDoS); require login; use `/` if `/` is a heavy homepage; return a 301 or 302 redirect — a redirect is not a 200 and the check will fail.

**Other target group settings worth knowing:**

- **Deregistration delay** (default 300s) — how long the load balancer waits for in-flight requests to finish before cutting off a removed target. Lower it to 30s for fast deploys; raise it if you have long-running uploads.
- **Stickiness** — pins a user to one server using a cookie. Useful for apps that keep session state in memory; avoid it when you can, because it defeats even load distribution.
- **Slow start** — ramps traffic up gradually on a newly healthy target, giving caches and JIT compilers time to warm up.
- **Cross-zone load balancing** — spreads requests evenly across all AZs. **On by default for ALB**, off by default for NLB.
- **Target Optimizer** (added late 2025) — caps how many concurrent requests each target will accept, using a small AWS-provided agent on the instance. Built for heavy workloads like ML inference where a single request can saturate a box.

### 6.6 Listeners and rules

A **listener** watches a port. **Rules** decide where matching traffic goes. Rules are evaluated by priority number, lowest first, **first match wins**, and there is always a catch-all default at the bottom.

```
HTTPS :443 listener
|
+- Priority 10 : IF path is /api/*        -> forward to tg-api
+- Priority 20 : IF host is admin.ex.com  -> forward to tg-admin
+- Priority 30 : IF path is /old/*        -> redirect 301 to /new/
+- Priority 40 : IF header X-Canary=true  -> forward to tg-canary
|
+- DEFAULT     : everything else          -> forward to tg-shop-web
```

Conditions you can match on: host header, path, HTTP method, query string, source IP, and any HTTP header.
Actions available: forward (optionally weighted across several target groups), redirect, return a fixed response, or authenticate via Cognito/OIDC.

> **Very common bug:** you add a rule for `/api/*` and requests to exactly `/api` (no trailing slash) fall through to the default and 404. Match both `/api` and `/api/*`.

### 6.7 Where SSL ends: the three patterns

```
PATTERN 1 - TLS TERMINATION (most common)
  Browser ==HTTPS==> ALB ---HTTP---> EC2
                      ^                ^
              cert lives here     plain text inside VPC
  Pros: simplest; the ALB can read headers and route by path; free ACM
        certs; low CPU on your servers.
  Cons: traffic is unencrypted inside the VPC. Fine for most people;
        fails strict rules like PCI-DSS or HIPAA.

PATTERN 2 - RE-ENCRYPTION / END-TO-END
  Browser ==HTTPS==> ALB ==HTTPS==> EC2
                      ^               ^
              public ACM cert   self-signed cert is OK here
  Pros: encrypted the whole way; ALB still reads and routes on headers.
  Cons: more CPU; you manage the backend certificate yourself.
  Note: the ALB does NOT validate the backend certificate, so a
        self-signed one on EC2 is acceptable and normal.

PATTERN 3 - TLS PASSTHROUGH (NLB only)
  Browser =====HTTPS all the way through the NLB=====> EC2
                                                        ^
                                            cert must live on EC2
  Pros: the load balancer never sees plaintext; maximum privacy.
  Cons: no path routing, no WAF, no header inspection; you install
        and renew the certificate yourself.
```

**How your app learns the real client IP.** Because the ALB opens a separate connection to your server, the server sees the ALB's IP as the source. The real one arrives in headers the ALB adds:

| Header | Contains |
|---|---|
| `X-Forwarded-For` | The original client IP |
| `X-Forwarded-Proto` | `http` or `https` — what the *client* used |
| `X-Forwarded-Port` | The port the client connected to |

If your app builds redirect URLs and keeps producing `http://` links on an HTTPS site, it is ignoring `X-Forwarded-Proto`. In nginx you fix that with `proxy_set_header`; in Express you set `app.set('trust proxy', true)`.

**mTLS (mutual TLS)** — an ALB can also require the *client* to present a certificate, for partner APIs and IoT devices. You configure it on the HTTPS listener with a trust store of the CAs you accept.

---

## 7. PART C — Everything that can go wrong

### 7.0 The master symptom table

Find your symptom, jump to the section.

| What you see | Most likely cause | Where it broke | Section |
|---|---|---|---|
| `NXDOMAIN` / "server not found" | DNS record missing, or NS delegation wrong | Route 53 | 7.1 |
| Domain resolves to an **old** IP | TTL cache, or a duplicate hosted zone | Route 53 | 7.1 |
| Connection **times out** (hangs) | Security group, NACL, or route table | VPC firewall | 7.2 |
| Connection **refused** (instant) | Nothing listening on that port | App / port config | 7.2 |
| `ERR_CERT_COMMON_NAME_INVALID` | Certificate doesn't cover that hostname | ACM / listener | 7.3 |
| `ERR_CERT_DATE_INVALID` | Certificate expired | ACM | 7.3 |
| `SSL_ERROR_NO_CYPHER_OVERLAP` | Client too old for your security policy | ALB policy | 7.3 |
| **HTTP 503** Service Unavailable | Zero healthy targets, or none registered | Target group | 7.4 |
| **HTTP 502** Bad Gateway | Target closed the connection, or protocol mismatch | EC2 app | 7.5 |
| **HTTP 504** Gateway Timeout | SG blocking the ALB, or the app is too slow | SG / app | 7.6 |
| **HTTP 460** | The client hung up before the ALB replied | Client-side | 7.6 |
| **HTTP 404** from the ALB itself | No listener rule matched | Listener rules | 7.7 |
| Works on the ALB DNS name, fails on your domain | DNS or certificate | Route 53 / ACM | 7.1 |
| Works from one machine, not another | Source-IP-restricted security group | SG | 7.2 |
| Half of requests fail | One unhealthy target still receiving traffic | Target group | 7.4 |
| SSH to EC2 hangs | SG, or no public route | VPC | 7.8 |
| App can't download updates | No NAT gateway, or a broken private route table | VPC | 7.9 |

---

### 7.1 DNS problems

**Symptom:** the browser says the site can't be found, or points to the wrong place.

**Check it in this order:**

```bash
# 1. Does the name resolve at all, from a public resolver?
dig +short shop.example.com @8.8.8.8

# 2. Follow the whole delegation chain from the root down.
#    This shows you EXACTLY where the trail goes cold.
dig +trace shop.example.com

# 3. Compare the world's view of your name servers...
dig NS example.com +short @8.8.8.8

#    ...with what your hosted zone says they should be.
aws route53 list-hosted-zones-by-name --dns-name example.com
aws route53 get-hosted-zone --id /hostedzone/ZXXXXXXXXXXXX \
  --query 'DelegationSet.NameServers'

# 4. Ask Route 53 directly, bypassing all caches.
#    If this works but step 1 doesn't, it is purely a caching or
#    delegation problem, not a record problem.
dig shop.example.com @ns-123.awsdns-45.com

# 5. List every record in the zone and eyeball it.
aws route53 list-resource-record-sets --hosted-zone-id ZXXXXXXXXXXXX \
  --query "ResourceRecordSets[?contains(Name, 'shop')]"
```

**The specific causes, and their fixes:**

| Cause | How to confirm | Fix |
|---|---|---|
| **NS mismatch** — registrar points elsewhere | Step 3 lists returns different servers | Update the name servers at your registrar to Route 53's four |
| **Duplicate hosted zone** — you have two zones for `example.com` and edited the wrong one | `list-hosted-zones-by-name` shows two entries | Delete the unused zone, or update the registrar to point at the one you're editing |
| **Trailing dot / typo** in the record name | You created `shop.example.com.example.com` | In the console, type only `shop` in the name box; the domain is appended for you |
| **Old TTL still cached** | Step 4 gives the new answer, step 1 gives the old one | Wait out the TTL. Verify with `dig` at multiple public resolvers |
| **CNAME at the zone apex** | Route 53 rejects it, or email breaks | Use an **Alias A record** instead |
| **Wrong record type** — you made a CNAME to an ALB at the apex | Console error | Alias A record |
| **Registrar lock / expired domain** | WHOIS lookup | Renew the domain |

**How to be sure DNS is not the problem:** hit the ALB's own DNS name directly. If `curl -kv https://my-alb-123.us-east-1.elb.amazonaws.com` works and your domain doesn't, the problem is 100% in DNS or the certificate, and nowhere else.

---

### 7.2 Connection timeouts and refusals

This is the most important distinction in all of network debugging.

```
     Run:  nc -zv <host> <port>
             |
     +-------+---------------------------------+
     |                                         |
  TIMED OUT (hangs ~30s)              CONNECTION REFUSED (instant)
     |                                         |
 A firewall silently ate               You reached the machine.
 your packet, or routing is            Nothing is listening on
 wrong. The machine never              that port.
 even saw it.                                  |
     |                                         |
 CHECK, in this order:                 CHECK, in this order:
  1. Security group inbound rule        1. Is the app running?
     - right port?                         systemctl status myapp
     - right source (SG or CIDR)?       2. Is it on the right port?
  2. Security group of the SOURCE          sudo ss -tlnp
     - outbound allowed?                3. Is it bound to 0.0.0.0
  3. NACL inbound AND outbound             and not 127.0.0.1?
     - remember 1024-65535 out!         4. Did it crash on boot?
  4. Route table                           journalctl -u myapp -n 50
     - is there a path back?
  5. Right subnet? Right AZ?
  6. Is the instance actually running?
```

**Concrete commands for each check:**

```bash
# See exactly what a security group allows
aws ec2 describe-security-groups --group-ids sg-0abc123 \
  --query 'SecurityGroups[0].IpPermissions'

# See what the EC2 instance is actually listening on (run ON the box)
sudo ss -tlnp
#  0.0.0.0:8080   -> good, listening on all interfaces
#  127.0.0.1:8080 -> BAD, only listening to itself. The ALB can never reach it.

# Test connectivity from one box to another (run ON the source box)
nc -zv 10.0.11.5 8080
curl -v --max-time 5 http://10.0.11.5:8080/health

# Check the NACL attached to a subnet
aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=subnet-0abc"

# Check the route table for a subnet
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=subnet-0abc" \
  --query 'RouteTables[0].Routes'
```

**Let AWS do the work — VPC Reachability Analyzer.** This is the single most underused debugging tool in AWS. It statically analyzes your entire configuration and tells you *which specific component* is blocking a path, without sending a single packet.

Console: **VPC → Reachability Analyzer → Create and analyze path**
- Source: your ALB (or an ENI, instance, or internet gateway)
- Destination: your EC2 instance
- Protocol: TCP, Destination port: 8080

The output is either a green "Reachable" with the full hop-by-hop path, or a red "Not reachable" naming the exact security group or route table rule at fault. It costs about $0.10 per analysis and routinely saves an hour.

**VPC Flow Logs** — the other heavy tool. Turn them on for your VPC (sending to CloudWatch Logs), then look for `REJECT` entries:

```
2 123456789 eni-abc123 10.0.1.50 10.0.11.5 41234 8080 6 1 40 1690000000 1690000060 REJECT OK
                       ^source    ^dest    ^sport ^dport                              ^^^^^^
```

A `REJECT` proves a security group or NACL blocked it. **No log line at all** means the packet never arrived — a routing problem, not a firewall problem. That distinction alone is worth enabling flow logs.

---

### 7.3 Certificate and SSL problems

**Diagnose with one command:**

```bash
openssl s_client -connect shop.example.com:443 -servername shop.example.com </dev/null
```

Then read the output:

| Output line | Meaning |
|---|---|
| `Verify return code: 0 (ok)` | Everything is fine |
| `subject=CN=...` | Which name the cert claims to be |
| `issuer=...Amazon...` | Who signed it |
| `notAfter=...` | Expiry date |
| `unable to get local issuer certificate` | Incomplete chain — an intermediate cert is missing |
| `certificate verify failed: Hostname mismatch` | Cert doesn't cover the name you asked for |
| `no peer certificate available` | Nothing is doing TLS on that port at all |

**Common causes and fixes:**

| Problem | Cause | Fix |
|---|---|---|
| Name mismatch | Cert is for `example.com`, you're visiting `www.example.com` | Add the extra name to the cert (a cert for `example.com` does **not** cover `www.example.com` — you need both, or a wildcard) |
| Wildcard doesn't work | `*.example.com` covers `shop.example.com` but **not** `a.b.example.com` and **not** bare `example.com` | Request both `example.com` and `*.example.com` |
| Cert not visible in the ALB dropdown | It's in the wrong **region** | Re-request it in the ALB's region |
| Cert stuck at "Pending validation" | The DNS validation CNAME isn't published, or has a typo | Re-check the record; confirm with `dig CNAME _abc123.example.com` |
| Cert expired despite auto-renew | Someone deleted the validation CNAME record | Re-create the record, then re-request |
| Old browsers/devices fail to connect | Your security policy is too modern | Switch to a policy that includes TLS 1.2, e.g. `ELBSecurityPolicy-TLS13-1-2-2021-06` |
| Padlock shows "mixed content" warning | Your HTML loads images/scripts over `http://` | Fix the page to use protocol-relative or `https://` URLs |
| Endless redirect loop | The app redirects HTTP→HTTPS, but the ALB already terminated TLS so the app sees HTTP | Honor `X-Forwarded-Proto` in the app, and let the ALB listener do the redirect |

```bash
# Check certificate status and which names it covers
aws acm describe-certificate --certificate-arn arn:aws:acm:us-east-1:123:certificate/abc \
  --query 'Certificate.[Status,DomainName,SubjectAlternativeNames,NotAfter]'

# Confirm the validation CNAME is actually published
dig CNAME _a79865eb4cd1a6ab.shop.example.com +short

# List every certificate attached to the listener
aws elbv2 describe-listener-certificates --listener-arn <listener-arn>
```

---

### 7.4 HTTP 503 — "Service Unavailable"

**What it means:** the ALB has **no healthy targets** to send your request to. The request never reached any EC2 instance.

```bash
# THE command. Run this first, always.
aws elbv2 describe-target-health --target-group-arn <tg-arn>
```

The `Reason` field tells you exactly what's wrong:

| Reason code | Plain English | Fix |
|---|---|---|
| `Target.NotRegistered` | Nothing is in the target group | Register your instances |
| `Target.Timeout` | Health check got no reply | Security group is blocking the ALB. Check SG-EC2 allows the health check port **from SG-ALB** |
| `Target.FailedHealthChecks` | It replied, but with the wrong status code | Check the path and the expected code. Curl it locally on the box |
| `Target.ResponseCodeMismatch` | Got e.g. 302 or 404, expected 200 | Fix the health check path, or widen the success codes |
| `Target.NotInUse` | Instance is stopped, or in an AZ the ALB isn't enabled for | Start the instance; enable that AZ on the load balancer |
| `Target.InvalidState` | Instance is stopping or terminated | Replace it |
| `Elb.InternalError` | AWS-side problem | Retry; open a support case if it persists |
| `Target.DeregistrationInProgress` | It's being drained on purpose | Normal during a deploy |

**The debugging ladder for an unhealthy target** — climb it in order and you will find the fault:

```
Rung 1: On the EC2 box itself
        curl -i http://localhost:8080/health
        Does it return 200?
        NO  -> the app is broken. Stop here and fix the app.
        YES -> go to rung 2.

Rung 2: On the EC2 box, using its own private IP (not localhost)
        curl -i http://10.0.11.5:8080/health
        NO  -> the app is bound to 127.0.0.1 only. Check `ss -tlnp`
               and change the bind address to 0.0.0.0.
        YES -> go to rung 3.

Rung 3: From another box in the same VPC
        curl -i http://10.0.11.5:8080/health
        NO  -> security group or NACL. Check SG-EC2 inbound.
        YES -> go to rung 4.

Rung 4: Does SG-EC2 allow the health check port FROM SG-ALB
        specifically? Not from your IP, not from 0.0.0.0/0 -
        from the load balancer's security group.
        NO  -> add that exact rule. This is the answer ~50% of the time.
        YES -> go to rung 5.

Rung 5: Does the target group's configured PORT match the port the
        app listens on? And does the health check PATH exist?
        Mismatch here is the other ~40%.
```

Also worth checking: if the ALB is enabled in `us-east-1a` and `us-east-1b`, but your instance is in `us-east-1c`, the ALB cannot reach it. Enable the AZ or move the instance.

---

### 7.5 HTTP 502 — "Bad Gateway"

**What it means:** the ALB reached your server, but got an answer it could not use.

| Cause | How to confirm | Fix |
|---|---|---|
| **Protocol mismatch** — target group says HTTP but the app speaks HTTPS (or the reverse) | `curl http://IP:port` returns garbage or fails while `curl -k https://IP:port` works | Change the target group protocol to match |
| App crashed mid-request | Application logs show a stack trace | Fix the crash |
| App's keep-alive timeout is **shorter** than the ALB's idle timeout (60s), so the app closes a connection the ALB is still trying to use | Intermittent 502s under light load, no pattern | Set the app's keep-alive to **longer** than the ALB idle timeout, e.g. app 75s vs ALB 60s. This is a classic and very sneaky one. |
| Response headers too large | Long cookies or many headers | ALB caps headers around 64KB total; trim them |
| Malformed HTTP response | `curl -v` shows an odd status line | Fix the app's response |
| Backend TLS handshake failed (Pattern 2) | ALB access log shows `-` for target status | Ensure the backend cert isn't malformed; check TLS versions match |

```bash
# Look at ALB access logs to separate ALB errors from target errors
# elb_status_code = what the client got
# target_status_code = what your server actually said ("-" means the ALB never got a valid reply)
```

**CloudWatch metric to watch:** `HTTPCode_ELB_502_Count` (the ALB generated it) vs `HTTPCode_Target_5XX_Count` (your app generated it). These two metrics immediately tell you whether to debug AWS config or your own code.

---

### 7.6 HTTP 504 — "Gateway Timeout"

**What it means:** the ALB waited and got no answer in time.

| Cause | Fix |
|---|---|
| **Security group blocks the ALB** (most common) | Add inbound rule on SG-EC2: allow the app port from SG-ALB |
| App is genuinely slow (heavy query, external API hanging) | Optimize it, or raise the ALB idle timeout (max 4000s) |
| App is overloaded, request queue is full | Scale out, add more targets |
| Wrong port in the target group | Match it to the listening port |
| NACL blocking the return traffic | Add outbound 1024-65535 |
| Database connection pool exhausted | Increase the pool, fix connection leaks |

```bash
# Adjust the idle timeout if requests are legitimately long-running
aws elbv2 modify-load-balancer-attributes --load-balancer-arn <arn> \
  --attributes Key=idle_timeout.timeout_seconds,Value=120
```

**Related: HTTP 460** means the *client* gave up and closed the connection before the ALB could respond. Usually a slow backend combined with an impatient mobile client. Fix the backend latency.

---

### 7.7 HTTP 404 coming from the ALB itself

If you get a 404 but your app's logs show nothing, the ALB never forwarded the request — no listener rule matched, so the default action fired.

```bash
# List the listener's rules in priority order
aws elbv2 describe-rules --listener-arn <listener-arn>

# Test a specific host header against the raw ALB, bypassing DNS entirely.
# This is a great trick for isolating routing rules from DNS problems.
curl -v -H "Host: shop.example.com" http://my-alb-123.us-east-1.elb.amazonaws.com/
```

Check for: a path pattern missing its `/*` wildcard, a host condition with a typo, or rule priorities in an order where a broad rule shadows a specific one.

---

### 7.8 Can't SSH into the EC2 instance

```
Can you connect?
   |
   +-- TIMEOUT
   |     - SG allows 22 from your current IP? (your home IP changed!)
   |     - Instance in a PRIVATE subnet with no public IP? (expected -
   |       you must go through a bastion, SSM, or EC2 Instance Connect
   |       Endpoint)
   |     - Route table has 0.0.0.0/0 -> IGW?
   |     - NACL allows 22 in and 1024-65535 out?
   |
   +-- REFUSED
   |     - sshd is not running, or listens on a nonstandard port
   |     - Instance is still booting
   |
   +-- "Permission denied (publickey)"
         - Wrong key file, or wrong username
           Amazon Linux -> ec2-user
           Ubuntu       -> ubuntu
           Debian       -> admin
           RHEL         -> ec2-user or root
         - Key file permissions too open: chmod 400 key.pem
```

> **The modern answer: stop using SSH.** Attach the `AmazonSSMManagedInstanceCore` IAM policy and use **Session Manager**. No port 22 open, no key files to lose, no bastion host to pay for, and every session is logged to CloudTrail. For teams that genuinely need SSH, **EC2 Instance Connect Endpoint** gives you SSH into private subnets without a bastion or a public IP.

```bash
aws ssm start-session --target i-0abc123def456
```

---

### 7.9 Private servers can't reach the internet

Symptom: `dnf update` or `apt update` hangs on an instance in a private subnet.

Check, in order:
1. Does the private subnet's route table have `0.0.0.0/0 → nat-xxxxx`?
2. Is the NAT gateway in a **public** subnet (not the private one)?
3. Does the NAT gateway's subnet route `0.0.0.0/0 → igw-xxxxx`?
4. Is the NAT gateway status `Available`?
5. Does SG-EC2 allow **outbound** traffic? (Default allows all — but people sometimes lock it down and forget.)
6. NACL outbound allows 443, and inbound allows 1024-65535 for the replies?

---

## 8. PART D — The debugging flowchart

Follow this top to bottom. **Never skip a step**, because each one rules out an entire category of problems.

```
                    ┌───────────────────────────────┐
                    │  "My site isn't working"      │
                    └───────────────┬───────────────┘
                                    v
              ╔═════════════════════════════════════════════╗
              ║  STEP 1:  dig +short shop.example.com       ║
              ╚═════════════════════════════════════════════╝
                                    │
            ┌───────────────────────┴───────────────────────┐
            │ NO ANSWER                                     │ GOT IPs
            v                                               v
  ┌──────────────────────┐              ╔═════════════════════════════════════╗
  │ >> DNS PROBLEM       │              ║  STEP 2: nc -zv shop.example.com 443║
  │ - dig +trace         │              ╚═════════════════════════════════════╝
  │ - compare NS records │                            │
  │   at registrar vs    │           ┌────────────────┴────────────────┐
  │   Route 53           │           │ TIMEOUT / REFUSED               │ OPEN
  │ - check for a        │           v                                 v
  │   duplicate zone     │ ┌───────────────────────┐   ╔═══════════════════════════════╗
  │ - check the record   │ │ >> NETWORK PROBLEM    │   ║ STEP 3: openssl s_client      ║
  │   name for typos     │ │ - SG-ALB allows 443   │   ║   -connect host:443           ║
  │ SECTION 7.1          │ │   from 0.0.0.0/0?     │   ╚═══════════════════════════════╝
  └──────────────────────┘ │ - ALB in PUBLIC       │                 │
                           │   subnets?            │      ┌──────────┴──────────┐
                           │ - route 0.0.0.0/0     │      │ CERT ERROR          │ VERIFY OK
                           │   -> IGW?             │      v                     v
                           │ - NACL inbound 443    │ ┌──────────────┐ ╔══════════════════════╗
                           │   AND outbound        │ │>> SSL PROBLEM│ ║ STEP 4:              ║
                           │   1024-65535?         │ │- name match? │ ║ curl -v https://...  ║
                           │ - ALB state Active?   │ │- expired?    │ ╚══════════════════════╝
                           │ SECTION 7.2           │ │- right region│           │
                           └───────────────────────┘ │- attached to │           │
                                                     │  listener?   │           │
                                                     │ SECTION 7.3  │           │
                                                     └──────────────┘           │
                     ┌──────────────────────────────────────────────────────────┤
                     │                                                          │
          ┌──────────┴──────────┬──────────────┬──────────────┬─────────────────┴─────┐
          v                     v              v              v                       v
     ┌─────────┐          ┌─────────┐    ┌─────────┐    ┌─────────┐             ┌─────────┐
     │  503    │          │  502    │    │  504    │    │  404    │             │200 OK 🎉│
     └────┬────┘          └────┬────┘    └────┬────┘    └────┬────┘             └─────────┘
          v                    v              v              v
  ╔═══════════════╗   ┌────────────────┐ ┌──────────────┐ ┌───────────────┐
  ║ NO HEALTHY    ║   │ BAD RESPONSE   │ │ TOO SLOW /   │ │ NO RULE       │
  ║ TARGETS       ║   │ FROM TARGET    │ │ BLOCKED      │ │ MATCHED       │
  ╠═══════════════╣   ├────────────────┤ ├──────────────┤ ├───────────────┤
  ║ aws elbv2     ║   │- protocol      │ │- SG-EC2 lets │ │- describe-    │
  ║ describe-     ║   │  mismatch      │ │  SG-ALB in?  │ │  rules        │
  ║ target-health ║   │  (HTTP vs      │ │- app slow?   │ │- missing /*   │
  ║               ║   │   HTTPS)?      │ │- raise idle  │ │  wildcard?    │
  ║ read the      ║   │- app keepalive │ │  timeout     │ │- host header  │
  ║ Reason field  ║   │  < ALB idle    │ │- NACL out    │ │  typo?        │
  ║               ║   │  timeout?      │ │  1024-65535? │ │               │
  ║ then climb    ║   │- app crashing? │ │              │ │ SECTION 7.7   │
  ║ the ladder in ║   │ SECTION 7.5    │ │ SECTION 7.6  │ └───────────────┘
  ║ SECTION 7.4   ║   └────────────────┘ └──────────────┘
  ╚═══════════════╝
```

**The one shortcut that saves the most time:**

```bash
# Skip DNS and the certificate entirely, and test the ALB directly:
curl -kv -H "Host: shop.example.com" https://my-alb-123.us-east-1.elb.amazonaws.com/

# WORKS  -> your problem is DNS or the certificate. Look at 7.1 and 7.3.
# FAILS  -> your problem is the ALB, target group, or EC2. Look at 7.4 - 7.7.
```

That single command splits the problem space in half in two seconds.

---

## 9. Command cheat sheet

### DNS
```bash
dig +short shop.example.com                    # just the answer
dig +trace shop.example.com                    # follow the full delegation chain
dig NS example.com @8.8.8.8                    # who the world thinks is authoritative
dig CNAME _abc123.example.com                  # verify an ACM validation record
dig shop.example.com @ns-1.awsdns-01.com       # ask Route 53 directly, skip caches
nslookup shop.example.com 1.1.1.1              # Windows-friendly alternative
```

### Connectivity
```bash
nc -zv host 443                                # is the TCP port open?
nc -zv host 22 80 443 8080                     # scan several ports
traceroute host                                # where does the path die?
mtr host                                       # continuous traceroute, great for flaky links
curl -v --max-time 5 http://10.0.11.5:8080/    # verbose HTTP test with a timeout
curl -I https://shop.example.com               # headers only
curl -w "@-" -o /dev/null -s https://shop.example.com <<'EOF'
  dns: %{time_namelookup}s  connect: %{time_connect}s  tls: %{time_appconnect}s  total: %{time_total}s
EOF
```

### On the EC2 instance
```bash
sudo ss -tlnp                                  # what is listening, and on which address
sudo ss -tn state established                  # current connections
systemctl status nginx                         # is the service up?
journalctl -u nginx -n 100 --no-pager          # recent service logs
curl -i http://localhost:8080/health           # test the app locally
curl -s http://169.254.169.254/latest/meta-data/instance-id \
  -H "X-aws-ec2-metadata-token: $(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"   # IMDSv2 metadata query
```

### TLS
```bash
openssl s_client -connect shop.example.com:443 -servername shop.example.com </dev/null
openssl s_client -connect shop.example.com:443 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
openssl s_client -connect shop.example.com:443 -tls1_2 </dev/null   # force a TLS version
curl -vI https://shop.example.com 2>&1 | grep -E "SSL|subject|issuer|expire"
```

### AWS CLI — the essentials
```bash
# Load balancer
aws elbv2 describe-load-balancers --names my-alb
aws elbv2 describe-listeners --load-balancer-arn <arn>
aws elbv2 describe-rules --listener-arn <arn>
aws elbv2 describe-listener-certificates --listener-arn <arn>
aws elbv2 describe-load-balancer-attributes --load-balancer-arn <arn>

# Target group  <- your most-used command
aws elbv2 describe-target-health --target-group-arn <arn>
aws elbv2 describe-target-groups --names tg-shop-web
aws elbv2 describe-target-group-attributes --target-group-arn <arn>

# Networking
aws ec2 describe-security-groups --group-ids sg-0abc
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-0abc"
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=vpc-0abc"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-0abc" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,AvailableIpAddressCount]' --output table

# DNS and certificates
aws route53 list-hosted-zones-by-name --dns-name example.com
aws route53 list-resource-record-sets --hosted-zone-id ZXXXX
aws acm list-certificates --certificate-statuses ISSUED
aws acm describe-certificate --certificate-arn <arn>

# Reachability Analyzer, from the command line
aws ec2 create-network-insights-path \
  --source <alb-or-eni-id> --destination <instance-id> \
  --protocol tcp --destination-port 8080
aws ec2 start-network-insights-analysis --network-insights-path-id <id>
aws ec2 describe-network-insights-analyses --network-insights-analysis-ids <id>
```

### CloudWatch metrics worth alarming on

| Metric | Meaning | Alarm when |
|---|---|---|
| `UnHealthyHostCount` | Dead targets | `>= 1` |
| `HealthyHostCount` | Live targets | `< 2` |
| `HTTPCode_ELB_5XX_Count` | The ALB itself errored | `> 0` |
| `HTTPCode_Target_5XX_Count` | Your app errored | above your baseline |
| `TargetResponseTime` | Latency | p99 above your SLA |
| `RejectedConnectionCount` | ALB hit a connection limit | `> 0` |
| `TargetConnectionErrorCount` | ALB couldn't reach targets | `> 0` |

As of mid-2026, ALB access, connection, and health check logs can also be sent **directly to CloudWatch Logs**, so you can query them with Logs Insights and watch them live with Live Tail instead of digging through S3.

---

## 10. Best practices

### Security
- ✅ Reference **security groups** in rules, never hardcoded IPs
- ✅ EC2 instances in **private** subnets; only the load balancer is public
- ✅ Close port 22 entirely and use **SSM Session Manager**
- ✅ Keep **IMDSv2 required** (the default on new instances) — this blocks a whole class of SSRF credential-theft attacks
- ✅ Put **AWS WAF** in front of a public ALB for SQL injection, XSS, and rate limiting
- ✅ Enable **VPC Flow Logs** before you need them
- ❌ Never open a database port to `0.0.0.0/0`
- ❌ Never use `0.0.0.0/0` on port 22 or 3389

### Reliability
- ✅ Always at least **2 AZs**, always at least **2 targets**
- ✅ Health checks that test something meaningful but stay cheap
- ✅ Deregistration delay tuned to your longest normal request
- ✅ Auto Scaling group with ELB health checks, so bad instances get replaced automatically
- ✅ Lower DNS TTLs a day before any migration
- ✅ Set CloudWatch alarms on `UnHealthyHostCount` before launch, not after the first outage

### Operations
- ✅ Build it with **Terraform, CDK, or CloudFormation**, not console clicks — you will need to rebuild it, and clicking is not repeatable
- ✅ Tag everything (`Environment`, `Owner`, `Application`)
- ✅ Turn on ALB access logs from day one
- ✅ Write down the ALB DNS name, target group ARN, and hosted zone ID in your runbook
- ✅ Use one ALB with path/host rules for many services rather than one ALB per service — it is cheaper and simpler

---

## 11. Cost traps

| Item | Cost | How to avoid the surprise |
|---|---|---|
| **NAT Gateway** | ~$32/mo each + ~$0.045/GB processed | Use VPC Endpoints for AWS services; consider one shared NAT for dev |
| **Public IPv4 addresses** | ~$0.005/hr each (~$3.60/mo), charged on *all* public IPv4 since Feb 2024 | Don't assign public IPs to private instances; consider IPv6-only dual-stack ALBs |
| **ALB** | ~$16/mo + LCU charges | Consolidate services behind one ALB with listener rules |
| **Cross-AZ data transfer** | ~$0.01/GB each way | Keep chatty services in the same AZ where availability allows |
| **Route 53 hosted zone** | $0.50/mo + query charges | Use Alias records — their lookups are free |
| **Idle load balancers** | Full price even with zero traffic | Delete abandoned dev environments |

---

## 12. Glossary

| Term | Plain English |
|---|---|
| **ACM** | AWS Certificate Manager — free, auto-renewing SSL certificates |
| **ALB** | Application Load Balancer — the smart, HTTP-aware one |
| **AZ** | Availability Zone — one physical data center location in a region |
| **Bastion** | A jump server used to reach private machines. Mostly obsolete; use SSM |
| **CIDR** | The `10.0.0.0/16` notation for describing a range of IP addresses |
| **CNAME** | A DNS record pointing one name at another name |
| **ENI** | Elastic Network Interface — a virtual network card |
| **Ephemeral port** | The temporary high-numbered port a client uses to receive a reply |
| **Health check** | A repeated request the load balancer uses to decide if a server is alive |
| **Hosted zone** | A container in Route 53 holding all DNS records for one domain |
| **IGW** | Internet Gateway — the door between your VPC and the internet |
| **LCU** | Load Balancer Capacity Unit — the metering unit ALBs are billed on |
| **Listener** | The port an ALB watches for incoming connections |
| **NACL** | Network ACL — a stateless subnet-level firewall |
| **NAT Gateway** | A one-way valve letting private servers reach out but not be reached |
| **SG** | Security Group — a stateful firewall around a single resource |
| **SNI** | Server Name Indication — how a client says which site it wants before TLS picks a certificate |
| **SSM** | AWS Systems Manager — includes Session Manager for keyless, portless logins |
| **Target group** | A named list of servers plus their health check rules |
| **TLS/SSL** | The encryption that turns HTTP into HTTPS |
| **TTL** | Time To Live — how long a DNS answer may be cached |
| **VPC** | Virtual Private Cloud — your isolated network inside AWS |
| **WAF** | Web Application Firewall — blocks malicious HTTP requests |

---

*Verify current pricing, limits, and features against the official AWS documentation before making production decisions — AWS ships changes constantly.*
