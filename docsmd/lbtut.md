# AWS Elastic Load Balancing — A Complete, Plain-English Field Guide

**Networking, Target Groups, CIDR, Security, and Metrics**
*with worked examples for APIs, Kafka, Databases, Apache NiFi, and Amazon EKS*

> Written for Cloud Support & Application Development Support teams.
> Explained at a middle-school reading level — no prior cloud experience required.

---

## Table of Contents

1. [How to Use This Guide](#1-how-to-use-this-guide)
2. [What Is a Load Balancer?](#2-what-is-a-load-balancer)
3. [AWS Networking Vocabulary (Read This First)](#3-aws-networking-vocabulary-read-this-first)
4. [The Three Types of AWS Load Balancer](#4-the-three-types-of-aws-load-balancer)
5. [Target Groups Explained Fully](#5-target-groups-explained-fully)
6. [CIDR and IP Addressing Made Simple](#6-cidr-and-ip-addressing-made-simple)
7. [Security Concerns and How to Address Them](#7-security-concerns-and-how-to-address-them)
8. [Metrics and Monitoring](#8-metrics-and-monitoring)
9. [Playbook: Load Balancing APIs](#9-playbook-load-balancing-apis)
10. [Playbook: Load Balancing Apache Kafka](#10-playbook-load-balancing-apache-kafka)
11. [Playbook: Load Balancing Database Clusters](#11-playbook-load-balancing-database-clusters)
12. [Playbook: Load Balancing Apache NiFi](#12-playbook-load-balancing-apache-nifi)
13. [Playbook: Load Balancing Amazon EKS (Nodes & Node Groups)](#13-playbook-load-balancing-amazon-eks-nodes--node-groups)
14. [Networking Best-Practices Checklist](#14-networking-best-practices-checklist)
15. [Troubleshooting Guide](#15-troubleshooting-guide)
16. [Quick Reference and Glossary](#16-quick-reference-and-glossary)

---

## 1. How to Use This Guide

This guide teaches AWS load balancing from the ground up. You do not need to know anything about cloud computing before reading it. Every technical word is explained the first time it appears, usually with a real-world comparison you already understand.

The guide is built for two audiences who work side by side:

- **Cloud Support teams** — the people who build, watch, and fix the network plumbing. You will care most about CIDR, security groups, target groups, health checks, and metrics.
- **Application Development Support teams** — the people who connect applications (APIs, Kafka, databases, NiFi, and Kubernetes workloads) to that plumbing. You will care most about which load balancer to pick and how to wire your app to it correctly.

**How the guide is organized:**

1. Chapters 2–4 teach the core ideas everyone must know: what a load balancer is, the AWS networking words, and the three types of AWS load balancer.
2. Chapters 5–7 go deep on target groups, CIDR/IP addressing, and security.
3. Chapter 8 covers metrics and monitoring — how you know things are healthy or broken.
4. Chapters 9–13 are hands-on playbooks, one each for APIs, Kafka, Database clusters, Apache NiFi, and Amazon EKS.
5. Chapters 14–16 give best-practice checklists, a troubleshooting guide, and a glossary.

> **📘 NOTE — Icons you will see**
> Throughout the guide, blockquotes flag important information: **✅ BEST PRACTICE** boxes are recommended habits, **⚠️ WARNING** boxes are mistakes to avoid, **🔒 SECURITY** boxes are security notes, and **📘 NOTE** boxes are extra explanations.

---

## 2. What Is a Load Balancer?

### 2.1 The simple idea

Imagine a popular ice cream shop with one cashier. On a hot day the line stretches out the door. People get frustrated and leave. The fix is obvious: open more cashier lanes. But now customers walking in need someone to tell them, "Lane 3 is open, go there." That greeter at the door is a load balancer.

A load balancer is a piece of software that sits in front of your servers and spreads incoming requests across all of them, so no single server gets overwhelmed. It also notices when a cashier (server) goes home sick and stops sending people to that empty lane.

In cloud terms: a **load balancer** receives network traffic from users and distributes it across multiple **backend servers** (in AWS these are often EC2 virtual machines, containers, or IP addresses). It improves three things at once: speed, reliability, and the ability to grow.

### 2.2 Why every serious system uses one

- **Scalability** — when traffic grows, you add more servers behind the load balancer instead of buying one giant server. This is called scaling out.
- **High availability** — if one server crashes, the load balancer routes around it. Users never notice. Spreading servers across multiple data centers means even a whole-building outage doesn't take you down.
- **Health checking** — the load balancer constantly pings each server with a small test request. Healthy servers get traffic; unhealthy ones are quietly removed until they recover.
- **A single front door** — users connect to one stable address (like `api.mycompany.com`). Behind that door, servers can come and go, be replaced, or be upgraded, and nobody outside has to change anything.
- **Security choke point** — because all traffic flows through one place, the load balancer is a natural spot to terminate encryption (HTTPS), inspect traffic, and block bad actors.

### 2.3 Two directions of load balancing

It helps to know there are two flavors, because AWS gives you tools for both:

- **External (internet-facing)** — handles traffic coming from the public internet, e.g., customers using your website or mobile app.
- **Internal (private)** — handles traffic between your own systems inside AWS, e.g., your web tier talking to your order-processing tier. Internal load balancers have no public address and can only be reached from inside your private network.

> **📘 NOTE — A load balancer is not a firewall**
> A load balancer's main job is distributing traffic, not blocking attacks. AWS provides separate tools for protection — Security Groups, Network ACLs, AWS WAF (Web Application Firewall), and AWS Shield. We cover how they work together in Chapter 7. Think of the load balancer as the greeter, and these tools as the security guards.

---

## 3. AWS Networking Vocabulary (Read This First)

Load balancers live inside a network. Before we go further, here are the networking words you will see on every screen and in every error message. Learn these ten terms and the rest of the guide becomes easy.

### 3.1 The ten core terms

| Term | Plain-English meaning |
|------|----------------------|
| **Region** | A geographic area where AWS has data centers, e.g., `us-east-1` (Northern Virginia). Think of it as a city. |
| **Availability Zone (AZ)** | One or more separate data centers inside a Region, with independent power and networking. Think of it as a building in that city. Spreading servers across AZs survives a building failure. |
| **VPC** (Virtual Private Cloud) | Your own private, walled-off network inside AWS. Nothing gets in or out unless you allow it. Think of it as your company's private campus. |
| **Subnet** | A smaller slice of your VPC that lives in one AZ. Public subnets can reach the internet; private subnets cannot. Think of it as a fenced section of the campus. |
| **CIDR block** | The range of IP addresses a VPC or subnet owns, written like `10.0.0.0/16`. Covered in detail in Chapter 6. |
| **IP address** | The numeric "phone number" of a server, e.g., `10.0.1.25`. Private IPs work only inside the VPC; public IPs are reachable from the internet. |
| **Route table** | A list of rules that decides where network traffic goes next — like road signs at an intersection. |
| **Internet Gateway (IGW)** | The doorway that connects a VPC to the public internet. Without it, a subnet cannot reach the internet. |
| **NAT Gateway** | Lets servers in a private subnet reach OUT to the internet (for updates) without letting the internet reach IN to them. |
| **Security Group (SG)** | A virtual firewall attached to a server or load balancer that says which traffic is allowed in and out. Covered in Chapter 7. |

### 3.2 How they fit together

Picture the layers from the outside in. A user on the internet sends a request. It enters your VPC through an Internet Gateway. A route table directs it to a public subnet where your load balancer lives. The load balancer's security group checks whether the traffic is allowed. If yes, the load balancer forwards the request to a healthy application server sitting in a private subnet, possibly in a different Availability Zone for safety. The server's own security group checks the traffic again before accepting it.

> **✅ BEST PRACTICE — Layered defense**
> Notice the traffic is checked at least twice — once at the load balancer and once at the server. Layering security checks like this is called defense in depth, and it is a core AWS best practice. If one layer is misconfigured, the next layer still protects you.

### 3.3 A reference VPC layout we will reuse

To keep examples consistent, the whole guide uses one example network. Memorize this small table; we refer back to it often.

| Piece | Value in our examples | Purpose |
|-------|----------------------|---------|
| VPC CIDR | `10.0.0.0/16` | 65,536 total addresses for the whole campus |
| Public subnet A | `10.0.0.0/24` (AZ `us-east-1a`) | Internet-facing load balancers |
| Public subnet B | `10.0.1.0/24` (AZ `us-east-1b`) | Internet-facing load balancers (2nd AZ) |
| Private subnet A | `10.0.10.0/24` (AZ `us-east-1a`) | App servers, internal load balancers |
| Private subnet B | `10.0.11.0/24` (AZ `us-east-1b`) | App servers, internal load balancers (2nd AZ) |
| Data subnet A | `10.0.20.0/24` (AZ `us-east-1a`) | Databases, Kafka, NiFi |
| Data subnet B | `10.0.21.0/24` (AZ `us-east-1b`) | Databases, Kafka, NiFi (2nd AZ) |

> **✅ BEST PRACTICE — Always use at least two AZs**
> Every load balancer in this guide is placed in two Availability Zones. AWS requires at least two subnets in two different AZs for a load balancer, and it is the single most important availability decision you will make. One AZ = one building = one outage away from downtime.

---

## 4. The Three Types of AWS Load Balancer

AWS Elastic Load Balancing (ELB) is the umbrella service. Under it are three different load balancers. Picking the right one is the most important early decision, because it affects performance, cost, and which features you get. There is also a fourth, older option you should know about but rarely choose for new work.

### 4.1 The OSI layers (just enough to choose correctly)

Networking people describe communication in seven "layers." You only need two of them to choose a load balancer:

- **Layer 4 (Transport layer)** — deals with raw connections: TCP and UDP, IP addresses, and port numbers. It does not understand what is inside the message. Fast and simple. Think of a mail sorter who reads the address on the envelope but never opens it.
- **Layer 7 (Application layer)** — understands the actual content: HTTP requests, web addresses (URLs), headers, and cookies. It can make smart decisions based on what's inside. Think of a receptionist who opens the letter, reads it, and routes it to the right department.

### 4.2 The three load balancers at a glance

| Load Balancer | Layer | Best for | Key superpower |
|---------------|-------|----------|----------------|
| **Application LB (ALB)** | Layer 7 | Websites, REST APIs, microservices, containers, NiFi UIs | Smart routing by URL path, hostname, or header; native HTTPS; WebSockets |
| **Network LB (NLB)** | Layer 4 | Kafka, databases, gaming, anything needing extreme speed or static IPs | Millions of requests/sec, ultra-low latency, static IP per AZ, preserves client IP |
| **Gateway LB (GWLB)** | Layer 3/4 | Inserting firewalls and security appliances into traffic flow | Transparently sends all traffic through third-party security tools |

> **⚠️ WARNING — The old one: Classic Load Balancer (CLB)**
> The Classic Load Balancer is the original from 2009. It mixes Layer 4 and Layer 7 but does both less well and lacks modern features. AWS recommends migrating off it. Do not choose CLB for new systems — it appears here only so you recognize it in older accounts.

### 4.3 Application Load Balancer (ALB) in depth

The ALB is the workhorse for anything that speaks HTTP or HTTPS. It reads the request and can route based on content. This is called content-based routing and it is the ALB's defining feature.

**Things only an ALB can do:**

- **Path-based routing** — send `/api/*` to one group of servers and `/images/*` to another.
- **Host-based routing** — send `shop.example.com` and `blog.example.com` to different servers using a single load balancer.
- **Header and query routing** — route based on HTTP headers, cookies, HTTP method, or query strings (e.g., send `version=beta` users to canary servers).
- **Native HTTPS termination** — decrypt HTTPS at the load balancer using a free certificate from AWS Certificate Manager (ACM).
- **Built-in authentication** — require login via Amazon Cognito or any OpenID Connect provider before traffic reaches your app.
- **WebSockets and HTTP/2** — for real-time, two-way connections such as chat and live dashboards.
- **Redirects and fixed responses** — e.g., automatically send all `http://` traffic to `https://`, or return a maintenance page.

### 4.4 Network Load Balancer (NLB) in depth

The NLB operates at Layer 4. It does not read your messages, which makes it extraordinarily fast and able to handle sudden traffic spikes with no "warm-up." It is the right tool whenever raw performance, non-HTTP protocols, or fixed IP addresses matter.

**Things that make the NLB special:**

- **Extreme performance** — handles tens of millions of requests per second at microsecond-level latency.
- **Static IP addresses** — you get one fixed IP per Availability Zone (and can assign your own Elastic IPs). Firewalls and partners can allow-list these addresses. ALBs cannot give you static IPs.
- **Any TCP or UDP protocol** — perfect for Kafka, databases, MQTT, DNS, and custom protocols that are not HTTP.
- **Preserves the client's real IP address** — by default the backend server sees the original client IP, which databases and Kafka often need for security and logging.
- **TLS termination** — an NLB can still decrypt TLS if you want, while keeping Layer 4 speed.
- **Connection-based** — it balances whole connections, not individual requests, which is exactly what long-lived Kafka and database connections want.

### 4.5 Gateway Load Balancer (GWLB) in depth

The GWLB is specialized. Its job is to transparently insert third-party network security appliances — firewalls, intrusion-detection systems, deep-packet-inspection tools — into your traffic path. Traffic flows to the GWLB, through the security appliances, and back, without applications knowing. Most teams only need it when a security mandate requires routing all traffic through a specific vendor appliance. We mention it for completeness and focus the rest of the guide on ALB and NLB.

### 4.6 A decision flowchart in words

1. Is the traffic HTTP or HTTPS, and do you want routing by URL, hostname, or header, or features like authentication and WebSockets? → **Choose an ALB.**
2. Is it a non-HTTP protocol (Kafka, database, UDP), or do you need static IPs, the client's real IP, or the absolute highest performance? → **Choose an NLB.**
3. Do you need to force all traffic through a third-party firewall/security appliance? → **Choose a GWLB.**
4. Are you on a Classic Load Balancer today? → **Plan a migration to ALB or NLB.**

> **📘 NOTE — You can combine them**
> A common advanced pattern is to put an NLB in front of an ALB. The NLB gives you static IPs and extreme scale at the edge; the ALB behind it gives you smart HTTP routing. You can also expose an ALB through AWS PrivateLink using an NLB. Mixing load balancers is normal and powerful.

---

## 5. Target Groups Explained Fully

If the load balancer is the greeter at the ice cream shop, a target group is the list of which cashier lanes are open right now and whether each one is working. Understanding target groups is essential because most load-balancer problems are really target-group problems.

### 5.1 The three building blocks

Every AWS load balancer is assembled from three connected parts. Picture them as a chain:

- **Listener** — a door on the load balancer that watches a specific port (e.g., port 443 for HTTPS). It says "I am listening for traffic here."
- **Rule** — (ALB only) the logic on a listener that decides where to send a request, e.g., "if the path starts with `/api`, send it to the API target group."
- **Target group** — the list of backend targets (servers) that actually receive the traffic, plus the health-check settings that decide which of them are allowed to receive it.

The flow is: **Listener → Rule → Target Group → Targets**. Traffic enters a listener, a rule decides the destination, and the target group delivers it to a healthy target.

### 5.2 What can be a target?

A target group has a target type, chosen when you create it. You cannot mix types in one group.

| Target type | What it points to | Typical use |
|-------------|-------------------|-------------|
| **instance** | EC2 virtual machines, identified by instance ID | Classic server-based apps; preserves nothing special |
| **ip** | Specific private IP addresses | Containers, on-premises servers reached over VPN/Direct Connect, databases, Kafka brokers, NiFi nodes |
| **lambda** | An AWS Lambda function (ALB only) | Serverless APIs with no servers to manage |
| **alb** | An Application Load Balancer (NLB only) | NLB-in-front-of-ALB pattern for static IPs + smart routing |

> **📘 NOTE — Target type drives everything downstream**
> For EKS, Kafka, and databases you will almost always use the `ip` target type, because the things you are balancing are not plain EC2 instances. Choosing `instance` when you needed `ip` is one of the most common setup mistakes.

### 5.3 Health checks — the heartbeat of a target group

A health check is a small, repeated test the load balancer sends to each target. If the target answers correctly, it is marked healthy and receives traffic. If it fails, it is marked unhealthy and is removed until it recovers. This is what lets the system route around broken servers automatically.

**The settings you tune:**

| Setting | What it means | Sensible starting value |
|---------|---------------|-------------------------|
| Protocol & Port | How and where to probe (e.g., HTTP on port 8080, or TCP on 9092) | Match the app's real port |
| Path | (HTTP/HTTPS only) the URL to request, e.g., `/healthz` | A lightweight endpoint that checks dependencies |
| Healthy threshold | How many passes in a row before a target is declared healthy | 2–3 |
| Unhealthy threshold | How many failures in a row before a target is declared unhealthy | 2–3 |
| Interval | Seconds between checks | 10–30 seconds |
| Timeout | Seconds to wait for a reply before counting it as a failure | 5 seconds |
| Success codes | (HTTP) which response codes count as healthy, e.g., `200` | `200`, or `200-299` |

> **✅ BEST PRACTICE — Design a real `/health` endpoint**
> Do not point health checks at your home page. Build a dedicated lightweight endpoint (commonly `/health` or `/healthz`) that quickly confirms the app and its critical dependencies (like the database connection) are working, then returns HTTP 200. Keep it fast and cheap — it runs constantly. A health check that is too heavy can itself overload your servers.

> **⚠️ WARNING — Shallow vs deep health checks**
> A shallow check confirms the process is up. A deep check also confirms downstream dependencies. Deep checks catch more problems but can cause cascading failures — if a shared database hiccups, every target fails its check at once and the whole pool is pulled out. A common balance: shallow checks for the load balancer, and separate deeper monitoring/alerting for dependencies.

### 5.4 Important target-group features

- **Stickiness (session affinity)** — keeps one user pinned to the same target using a cookie (ALB) or source-IP (NLB). Useful when a server stores per-user state in memory. Better long-term design: store session state externally (e.g., in a cache) so any server can serve any user.
- **Deregistration delay (connection draining)** — when a target is removed, the load balancer stops sending NEW connections but lets existing ones finish for a set time (default 300s). This prevents cutting users off mid-request during deployments or scale-in.
- **Slow start** — gradually ramps traffic to a newly healthy target instead of hitting it at full load instantly, giving caches and connection pools time to warm up.
- **Load-balancing algorithm** — round robin (take turns) or least outstanding requests (favor the least-busy target). Least-outstanding-requests is often better when request durations vary a lot.
- **Cross-zone load balancing** — decides whether a load balancer node can send traffic to healthy targets in OTHER Availability Zones. On the ALB it is always on and free; on the NLB it is off by default and may add inter-AZ data charges when on. See the warning below.

> **⚠️ WARNING — The cross-zone trap on NLBs**
> If your targets are spread unevenly across AZs and cross-zone balancing is OFF (the NLB default), some targets can be overloaded while others sit idle, because each load balancer node only talks to targets in its own AZ. Either keep targets balanced across AZs or turn cross-zone on (accepting possible inter-AZ data transfer cost). This surprises many teams.

### 5.5 One target can serve many ports

A single target group maps to one port per target, but you can register the same server in multiple target groups on different ports, or use multiple listeners. This matters for systems like Kafka and NiFi that expose several ports (data, control, UI, metrics). We use this technique in those chapters.

---

## 6. CIDR and IP Addressing Made Simple

CIDR (pronounced "cider") stands for Classless Inter-Domain Routing. Behind the scary name is a simple idea: a short way to describe a range of IP addresses. You must understand CIDR to size your network, place load balancers, and write security rules.

### 6.1 What an IP address really is

An IPv4 address looks like `10.0.1.25`. It is four numbers (0–255) separated by dots. Each number is 8 bits, so the whole address is 32 bits. That is just a 32-digit binary number written in a friendly way. Every device on a network needs a unique one, like a unique street address for mail.

### 6.2 Reading the slash: /16, /24, /32

A CIDR block adds a slash and a number, like `10.0.0.0/16`. The number after the slash tells you how many bits are FIXED (the network part). The remaining bits are free to number individual hosts. Fewer fixed bits = bigger range.

| CIDR | Fixed bits | Free bits | Total addresses | Plain meaning |
|------|-----------|-----------|-----------------|---------------|
| `10.0.0.0/16` | 16 | 16 | 65,536 | A whole campus (our example VPC) |
| `10.0.1.0/24` | 24 | 8 | 256 | One building/subnet |
| `10.0.1.0/28` | 28 | 4 | 16 | A tiny block, e.g., for an NLB |
| `10.0.1.25/32` | 32 | 0 | 1 | Exactly one address (one specific host) |
| `0.0.0.0/0` | 0 | 32 | All of them | "Anywhere on the internet" |

> **📘 NOTE — Two CIDR values you will type constantly**
> `0.0.0.0/0` means "any IPv4 address in the world." You use it for a public website's inbound rule, but **never** for sensitive ports like databases. `x.x.x.x/32` means "this exact single address," used to allow-list one specific server.

### 6.3 The math: how many usable addresses?

The number of addresses in a block is 2 raised to the number of free bits. A /24 has 8 free bits, so 2^8 = 256 addresses.

> **⚠️ WARNING — AWS reserves 5 addresses in every subnet**
> In each subnet, AWS takes the first four addresses and the last one for its own networking. So a /24 subnet gives you 256 minus 5 = 251 usable addresses, not 256. Always plan with the 5-address tax in mind, especially for small subnets. A /28 (16 addresses) leaves only 11 usable.

### 6.4 Private vs public address ranges

Certain ranges are reserved for private networks and are never used directly on the public internet. Your VPC should use these. The three private IPv4 ranges are:

- `10.0.0.0/8` — `10.0.0.0` to `10.255.255.255` (huge; what we use in this guide)
- `172.16.0.0/12` — `172.16.0.0` to `172.31.255.255`
- `192.168.0.0/16` — `192.168.0.0` to `192.168.255.255` (common in home routers)

### 6.5 Practical CIDR rules for load balancing

- **Size the VPC generously** — a /16 gives 65,536 addresses and room to grow. You cannot easily shrink later, and a too-small VPC is painful to fix.
- **Give each subnet enough room** — a /24 (251 usable) is a comfortable default per AZ. Container platforms like EKS can consume IPs very fast (one IP per pod), so size data and pod subnets larger.
- **Never overlap CIDRs** — two networks you want to connect (e.g., via VPC peering or VPN) cannot have overlapping ranges, or routing breaks. Plan address space across all your VPCs up front.
- **Leave space for load balancers** — ALBs need free IPs in each subnet they use and will grow into them under load. AWS recommends at least a /27 (or 8+ free IPs) per ALB subnet.
- **Match security rules to real ranges** — when writing a security-group rule, prefer the tightest CIDR that works (a /32 for one host) over broad ranges.

> **📘 NOTE — A word on IPv6**
> IPv6 addresses are much longer (e.g., `2600:1f18:...`) and exist because the world is running out of IPv4. AWS load balancers can support IPv6 in "dualstack" mode (both IPv4 and IPv6). The CIDR idea is identical — only the address length changes (IPv6 blocks are commonly /56 or /64). For most internal systems, IPv4 is still the default.

---

## 7. Security Concerns and How to Address Them

A load balancer sits at the front of your system, so it is both your best security choke point and a target if misconfigured. This chapter covers the controls you must understand and the mistakes that cause real incidents.

### 7.1 The AWS network security toolkit

| Control | Layer it works at | What it does | Key trait |
|---------|-------------------|--------------|-----------|
| **Security Group (SG)** | Instance / LB | Virtual firewall on each resource; allow rules only | Stateful: a reply to an allowed request is automatically allowed back |
| **Network ACL (NACL)** | Subnet | Allow AND deny rules at the subnet edge | Stateless: you must allow both directions explicitly |
| **AWS WAF** | Layer 7 (ALB) | Blocks malicious web requests (SQL injection, XSS, bad bots) | Rule-based; attaches to ALB, not NLB |
| **AWS Shield** | Network/transport | Protects against DDoS (traffic flood) attacks | Standard is free & automatic; Advanced is paid |

> **📘 NOTE — Security Groups vs NACLs — the difference that trips everyone up**
> Security Groups are stateful: if you allow traffic IN, the response is automatically allowed OUT. Network ACLs are stateless: they have no memory, so you must write rules for both directions. Most teams do nearly all their work with Security Groups and leave NACLs at their permissive defaults unless they need an explicit subnet-wide deny.

### 7.2 The security-group pattern for load balancers

The gold-standard pattern uses security groups that reference each other, instead of hard-coded IP ranges. This is more secure and self-maintaining.

1. Create a security group for the load balancer (call it `sg-lb`). Allow inbound from users on the listener port (e.g., 443 from `0.0.0.0/0` for a public site).
2. Create a security group for the application servers (call it `sg-app`). For its inbound rule, do NOT use an IP range — instead allow traffic only from `sg-lb` on the app's port.
3. The result: the servers accept traffic only from the load balancer, and nothing else can reach them, even from inside the VPC. If the load balancer's IPs change, nothing breaks because you referenced the group, not the addresses.

**Example rules in plain language:**

```text
sg-lb (Load Balancer)
  Inbound : allow TCP 443 from 0.0.0.0/0        # public HTTPS
  Inbound : allow TCP 80  from 0.0.0.0/0         # http, to redirect to https
  Outbound: allow TCP 8080 to sg-app             # forward to app

sg-app (Application servers)
  Inbound : allow TCP 8080 from sg-lb            # only from the load balancer
  Outbound: allow TCP 5432 to sg-db              # talk to the database
```

### 7.3 Encryption in transit (TLS/HTTPS)

TLS (Transport Layer Security, the modern name for SSL) scrambles data as it travels so eavesdroppers cannot read it. HTTPS is simply HTTP wrapped in TLS. You should encrypt traffic both from users to the load balancer and, for sensitive systems, from the load balancer to the servers.

- **TLS termination** — the load balancer decrypts incoming TLS and forwards plain traffic to servers. Simple and fast; fine when the internal network is trusted.
- **TLS passthrough / re-encryption** — the load balancer keeps traffic encrypted all the way to the servers (end-to-end encryption). Use this for regulated data (health, finance) or zero-trust networks.
- **Free certificates** — AWS Certificate Manager (ACM) issues and auto-renews TLS certificates at no cost for use on ALBs and NLBs. Use ACM so certificates never silently expire — an expired certificate is a very common, very visible outage.
- **Security policies** — choose a modern TLS security policy on the listener so weak, outdated protocols (like TLS 1.0) are refused. Prefer policies that require TLS 1.2 or higher.

### 7.4 Public vs private placement

- **Put internet-facing load balancers in public subnets** and keep the application servers in private subnets. Users reach the load balancer; nobody reaches the servers directly.
- **Use internal load balancers for service-to-service traffic** that never needs to touch the internet (e.g., internal APIs, databases, Kafka). They have no public IP at all.

### 7.5 The most common security mistakes

> **⚠️ WARNING — Do not do these**
> - Opening `0.0.0.0/0` on database, Kafka, or admin ports.
> - Putting databases or brokers in a public subnet "just to make it work."
> - Using self-signed or manually managed certificates that expire without warning.
> - Allowing the load balancer to talk to servers on every port (use one specific port).
> - Forgetting that NLBs preserve the client IP — your server's security group must allow the real client range, not the load balancer's.

> **🔒 SECURITY — Defense in depth, restated**
> Combine the layers: WAF filters bad web requests, Shield absorbs floods, security groups restrict who can connect, private subnets hide your servers, and TLS protects the data in motion. No single control is enough; together they are strong.

> **🔒 SECURITY — Log everything**
> Enable access logs (ALB/NLB) to Amazon S3 and VPC Flow Logs for the subnets. When something goes wrong at 3 a.m., these logs are how you find out who connected, from where, and what happened. Turn them on before you need them.

---

## 8. Metrics and Monitoring

You cannot fix what you cannot see. AWS publishes load-balancer metrics to Amazon CloudWatch automatically. This chapter explains the metrics that matter, what they tell you, and the alarms a support team should set.

### 8.1 How metrics reach you

CloudWatch is the AWS monitoring service. Load balancers send it numbers every minute. You can view graphs, set alarms that notify you (e.g., via email or a pager) when a number crosses a threshold, and build dashboards. Access logs (every request) go to S3, and CloudWatch can also collect application logs and traces.

### 8.2 Key ALB metrics

| Metric | What it tells you | Watch for |
|--------|-------------------|-----------|
| `RequestCount` | How many requests the ALB handled | Sudden spikes or drops |
| `TargetResponseTime` | How long targets take to respond (latency) | Rising values = slow app |
| `HTTPCode_Target_5XX_Count` | Server errors coming from your app | Any sustained increase |
| `HTTPCode_ELB_5XX_Count` | Errors generated by the ALB itself (e.g., no healthy targets) | Almost always a real problem |
| `HealthyHostCount` / `UnHealthyHostCount` | How many targets are passing health checks | Healthy dropping toward zero |
| `RejectedConnectionCount` | Connections refused because a limit was hit | Any non-zero value |
| `TargetConnectionErrorCount` | ALB could not open a connection to a target | Network/SG problems |

### 8.3 Key NLB metrics

| Metric | What it tells you | Watch for |
|--------|-------------------|-----------|
| `ActiveFlowCount` | Number of active connections (flows) | Unexpected growth or collapse |
| `NewFlowCount` | Rate of new connections | Spikes = traffic surge |
| `ProcessedBytes` | Total data moved through the NLB | Capacity planning |
| `HealthyHostCount` / `UnHealthyHostCount` | Targets passing the health check | Healthy dropping |
| `TCP_Target_Reset_Count` | Resets sent by targets (abrupt connection drops) | App or broker instability |
| `TCP_ELB_Reset_Count` | Resets sent by the NLB itself | Idle-timeout or config issues |

### 8.4 Alarms a support team should configure

1. `HealthyHostCount` < (minimum needed) — your safety margin is gone; page someone.
2. ELB 5XX errors > 0 sustained — the load balancer cannot serve traffic.
3. Target 5XX error rate above your baseline — the application is failing.
4. `TargetResponseTime` above your latency budget — users are feeling slowness.
5. `UnHealthyHostCount` > 0 for several minutes — investigate the failing target.
6. `RejectedConnectionCount` > 0 — you are hitting a capacity limit.

### 8.5 The four golden signals

A simple framework borrowed from site-reliability engineering. Watch these four and you catch most problems:

- **Latency** — how long requests take (`TargetResponseTime`).
- **Traffic** — how much demand there is (`RequestCount`, `NewFlowCount`).
- **Errors** — how many requests fail (5XX counts, reset counts).
- **Saturation** — how full the system is (healthy host count, connection counts, CPU on targets).

> **✅ BEST PRACTICE — Alert on symptoms, not noise**
> Set alarms on things users actually feel — errors and latency — rather than on every minor fluctuation. Too many false alarms train people to ignore the pager, which is how real incidents get missed. Tune thresholds against a week or two of normal traffic before going live.

---

## 9. Playbook: Load Balancing APIs

APIs (Application Programming Interfaces) are how applications talk to each other over the web, almost always using HTTP/HTTPS and often returning JSON. Because APIs speak HTTP and benefit from smart routing, the Application Load Balancer (ALB) is the natural choice.

### 9.1 Why an ALB for APIs

- Path-based routing lets one load balancer serve many microservices: `/users` → user service, `/orders` → order service, `/payments` → payment service.
- Host-based routing serves multiple API domains (`v1.api.com`, `v2.api.com`) from one ALB.
- Native HTTPS termination with a free ACM certificate, plus automatic http→https redirect.
- Built-in authentication (Cognito/OIDC) can protect APIs before traffic reaches your code.
- Works with EC2, containers (ECS/EKS), and Lambda targets — so the same front door fits any backend.

### 9.2 Reference architecture

Internet → ALB (public subnets, two AZs) → target group of API servers (private subnets, two AZs) → database (data subnets). The ALB terminates HTTPS, routes by path, and health-checks each API server at `/health`.

### 9.3 Step-by-step setup

1. Request a TLS certificate for `api.example.com` in AWS Certificate Manager (free, auto-renewing).
2. Create the ALB as internet-facing, attached to the two public subnets (`10.0.0.0/24` and `10.0.1.0/24`).
3. Create a target group of type `ip` or `instance` for your API servers, protocol HTTP on the app port (e.g., 8080).
4. Configure the health check: HTTP, path `/health`, healthy threshold 3, interval 15s, success code 200.
5. Add an HTTPS listener on port 443 using the ACM certificate and a TLS 1.2+ security policy; set the default action to forward to the API target group.
6. Add an HTTP listener on port 80 whose only action is a permanent redirect to HTTPS.
7. Add path-based rules if you run microservices, e.g., `/orders/*` → orders target group.
8. Lock down security groups: ALB allows 443 from users; API servers allow their app port only from the ALB's security group.

**Example listener rules:**

```text
Listener :443 (HTTPS, cert from ACM, policy TLS1.2+)
  Rule 1 : IF path = /orders/*    FORWARD -> tg-orders
  Rule 2 : IF path = /users/*     FORWARD -> tg-users
  Default:                        FORWARD -> tg-api-main

Listener :80 (HTTP)
  Default: REDIRECT -> https://#{host}:443/#{path}?#{query}  (301)
```

### 9.4 API-specific best practices

> **✅ BEST PRACTICE — Make health checks meaningful**
> Your `/health` endpoint should confirm the API can reach its critical dependencies (database, cache) and return 200 only when it can truly serve requests. But keep it lightweight so it does not add load or cause mass failures during a brief dependency blip.

- **Tune the idle timeout** — the ALB closes idle connections after 60 seconds by default. For slow or long-polling APIs, raise it; for fast APIs, the default is fine.
- **Enable HTTP/2** — it is on by default on the ALB and improves performance for modern clients.
- **Put AWS WAF on the ALB** — block SQL injection, cross-site scripting, and abusive bots before they reach your code, and add rate-based rules to throttle floods.
- **Use stickiness only if you must** — well-designed APIs are stateless, so any server can handle any request. Avoid stickiness unless a specific feature needs it.
- **Consider Amazon API Gateway too** — for heavy API management (API keys, usage plans, throttling per customer, request transformation), API Gateway complements or replaces an ALB. For straightforward routing to your own servers, an ALB is simpler and cheaper.

> **📘 NOTE — Watch these metrics for APIs**
> `TargetResponseTime` (latency), `HTTPCode_Target_5XX_Count` (your app failing), `HTTPCode_ELB_5XX_Count` (no healthy targets), and `RequestCount` (demand). Alarm on rising latency and any sustained 5XX.

---

## 10. Playbook: Load Balancing Apache Kafka

Apache Kafka is a system for streaming large volumes of messages between applications in real time. A Kafka cluster is made of brokers (the servers that store and serve messages). Kafka does not speak HTTP — it uses its own fast TCP protocol — and clients need to reach specific brokers. This makes Kafka one of the trickiest things to load balance, and the Network Load Balancer (NLB) is the right tool.

### 10.1 Why Kafka is special

> **⚠️ WARNING — Kafka clients must reach EACH broker directly**
> Kafka has a built-in awareness of its own brokers. A client first contacts any broker to discover the cluster, then is told the address (the advertised listener) of the exact broker that holds the data it wants — and it must be able to connect to that specific broker. This means you cannot simply hide all brokers behind one address and randomly spread connections. The load-balancing design must let clients reach each broker individually.

### 10.2 Why an NLB (not an ALB)

- Kafka uses raw TCP on port 9092 (or 9094 for TLS), not HTTP — so an ALB cannot route it.
- NLBs preserve the client's real IP, which Kafka security and quotas often rely on.
- NLBs provide static IPs and handle the high throughput and long-lived connections Kafka demands.
- Low latency matters for streaming, and the NLB adds almost none.

### 10.3 The per-broker pattern

Because each broker must be individually reachable, the standard solution gives every broker its own dedicated listener and target group on the NLB, each on a unique port. Clients are then told (via Kafka's advertised listeners) to use those unique ports.

```text
NLB (one static IP set, two+ AZs)
  Listener :9092 -> tg-broker-0 (target: broker-0 IP, port 9092)
  Listener :9093 -> tg-broker-1 (target: broker-1 IP, port 9092)
  Listener :9094 -> tg-broker-2 (target: broker-2 IP, port 9092)

Each broker's advertised.listeners is set so clients connect
back through the matching NLB port:
  broker-0 -> nlb-dns:9092
  broker-1 -> nlb-dns:9093
  broker-2 -> nlb-dns:9094
```

> **⚠️ WARNING — The advertised-listener rule**
> This is the single most important Kafka-behind-a-load-balancer concept: each broker must advertise the address and port that routes back to itself through the NLB. If a broker advertises its private VPC address instead, external clients will discover an address they cannot reach, and connections will mysteriously fail after the initial handshake. Set `advertised.listeners` to the NLB DNS name and that broker's unique port.

### 10.4 Step-by-step setup

1. Place brokers in private data subnets across two or three AZs (`10.0.20.0/24`, `10.0.21.0/24`).
2. Create an NLB (internal for in-VPC clients, or internet-facing only if you truly must expose Kafka publicly).
3. For each broker, create an `ip` target group on port 9092 containing only that broker's IP.
4. Add one NLB listener per broker on a unique port, each forwarding to the matching target group.
5. Health-check each target group with a TCP check on 9092 (or a deeper check if available).
6. Configure each broker's `advertised.listeners` to the NLB DNS name and its unique port.
7. Lock down security groups: brokers allow 9092 only from the NLB and from each other (brokers replicate among themselves).
8. Use TLS (port 9094) end-to-end for any sensitive data; the NLB can pass TLS through to brokers.

### 10.5 Kafka best practices and metrics

- **Strongly prefer Amazon MSK** — Amazon Managed Streaming for Apache Kafka (MSK) runs Kafka for you and handles much of this networking, including private connectivity. Self-managing Kafka load balancing is hard; use MSK unless you have a strong reason not to.
- **Enable cross-zone balancing thoughtfully** — since each broker has its own target group with a single target, this is less of an issue, but be aware of inter-AZ data-transfer costs for cross-AZ client traffic.
- **Mind the idle timeout** — Kafka connections are long-lived; the NLB's 350-second idle timeout can drop quiet connections. Enable TCP keep-alive on clients/brokers so connections are not considered idle.
- **Keep client IP visible** — rely on the NLB's default client-IP preservation for broker-side authorization and logging.

> **📘 NOTE — Kafka metrics to watch**
> On the NLB: `HealthyHostCount` per broker target group (each should stay at its expected count), `TCP_Target_Reset_Count` (broker dropping connections), `ActiveFlowCount` and `NewFlowCount` (connection load), and `ProcessedBytes` (throughput). On the brokers themselves, watch under-replicated partitions and consumer lag via Kafka/MSK metrics.

---

## 11. Playbook: Load Balancing Database Clusters

A database cluster is a group of database servers working together, usually with one primary (writer) that accepts changes and one or more replicas (readers) that serve copies of the data for reading. Databases speak TCP (e.g., PostgreSQL on 5432, MySQL on 3306), not HTTP, so when load balancing is needed it is again an NLB job — but databases come with an important twist.

### 11.1 The most important rule: prefer the database's own endpoints

> **⚠️ WARNING — Often you should NOT put a load balancer in front of a database**
> Managed databases like Amazon RDS and Amazon Aurora already give you smart endpoints: a writer endpoint that always points to the current primary, and a reader endpoint that automatically spreads read traffic across replicas and updates instantly during a failover. These are smarter than a generic load balancer because they understand database roles. For RDS/Aurora, use these built-in endpoints instead of building your own NLB.

So when do you use an NLB for databases? Mainly for self-managed databases on EC2, for exposing a database through AWS PrivateLink to other accounts, or to provide a single stable IP/endpoint in front of a self-managed cluster. The rest of this chapter covers those cases.

### 11.2 The writer/reader split

The biggest danger with databases is sending a write to a read-only replica, which fails, or spreading writes across multiple servers, which corrupts data. Never blindly round-robin database connections across all nodes. Instead, separate the roles:

- **Writer path** — a target group containing only the current primary. All inserts/updates/deletes go here.
- **Reader path** — a target group containing the read replicas, which CAN be balanced because reads are safe to spread.

```text
NLB (internal, two+ AZs)
  Listener :5432 (writer)  -> tg-db-writer (primary only)
  Listener :5433 (readers) -> tg-db-readers (all replicas)

Applications:
  - send writes to nlb-dns:5432
  - send reads  to nlb-dns:5433
```

### 11.3 The failover challenge

> **⚠️ WARNING — A plain NLB does not know which node is the primary**
> If the primary fails and a replica is promoted, your writer target group is now pointing at the wrong (old) node. A generic NLB cannot detect a database role change on its own. You must either (a) use RDS/Aurora endpoints which handle this automatically, or (b) build automation (e.g., a Lambda triggered by failover events, or a health check that only passes on the true primary) that updates the target group membership. Do not assume the NLB will follow a failover — it will not, unless you make it.

A common trick: write a health-check endpoint or use a TCP/script check that returns healthy only on the node currently acting as primary. When the primary changes, the old node fails the check and the new one passes, and the writer target group self-corrects.

### 11.4 Step-by-step setup (self-managed cluster)

1. Place all database nodes in private data subnets across two AZs (`10.0.20.0/24`, `10.0.21.0/24`). Never in a public subnet.
2. Create an internal NLB (databases should never be internet-facing).
3. Create a writer target group (`ip` type) and register the primary; create a reader target group with the replicas.
4. Configure health checks that distinguish primary from replica where possible (role-aware checks).
5. Add a listener on the writer port and another on the reader port.
6. Security groups: database nodes allow their port only from the application security group (and from each other for replication) — never from `0.0.0.0/0`.
7. Require TLS for all database connections (pass TLS through the NLB to the database).
8. Set up failover automation to keep target-group membership correct.

### 11.5 Database best practices and metrics

- **Default to managed endpoints** — for RDS/Aurora, the writer and reader endpoints replace almost everything above and handle failover for you.
- **Use connection pooling** — databases handle a limited number of connections. A pooler (e.g., RDS Proxy or PgBouncer) reuses connections and protects the database during traffic spikes and failovers. This often matters more than the load balancer itself.
- **Long-lived connections need keep-alive** — like Kafka, database connections are long-lived; enable TCP keep-alive so the NLB does not drop idle ones.
- **Keep client IP** — the NLB preserves client IP, useful for database-side access rules and auditing.
- **Never expose databases publicly** — internal NLB only, private subnets only, tight security groups always.

> **📘 NOTE — Database metrics to watch**
> On the NLB: `HealthyHostCount` for the writer group (should be exactly 1) and reader group, plus TCP reset counts and active flows. On the database (CloudWatch RDS metrics or your own): connection count, CPU, replica lag, and free storage/memory. Replica lag is critical — readers serving stale data can cause subtle bugs.

---

## 12. Playbook: Load Balancing Apache NiFi

Apache NiFi is a tool for moving and transforming data between systems using visual "flows." A NiFi cluster has multiple nodes that share the work, plus a web user interface (UI) that operators use to design and monitor flows. NiFi is interesting because it needs load balancing for two different things at once: the HTTPS web UI (an ALB job) and, sometimes, incoming data over various protocols (often an NLB job).

### 12.1 What NiFi exposes

| Port / interface | Protocol | Purpose | Best load balancer |
|------------------|----------|---------|--------------------|
| Web UI / REST API | HTTPS | Operators design and monitor flows; APIs control NiFi | ALB |
| Site-to-Site (S2S) | Raw/secure TCP | NiFi-to-NiFi data transfer between clusters | NLB |
| Listen processors (e.g., ListenTCP, ListenSyslog) | TCP/UDP | External systems push data into NiFi | NLB |
| Cluster protocol | TCP (internal) | Nodes coordinate with each other | No LB — node-to-node only |

> **⚠️ WARNING — Do not load balance NiFi's internal cluster protocol**
> NiFi nodes talk among themselves to coordinate the cluster and elect a coordinator. This internal traffic must go node-to-node directly and should never be routed through a load balancer. Only the UI and data-ingest interfaces sit behind load balancers.

### 12.2 Load balancing the NiFi web UI (ALB)

Operators reach the NiFi UI through an ALB over HTTPS. Any node can render the UI, so this part is a fairly standard ALB setup — with two NiFi-specific cautions.

1. Create an internal ALB (or internet-facing only if operators are remote and you also add WAF + authentication) in two AZs.
2. Create a target group (`ip` or `instance`) containing all NiFi nodes on the UI port (e.g., 8443), protocol HTTPS.
3. Health-check the UI path over HTTPS; expect the node to return a success code.
4. Add an HTTPS listener with an ACM certificate; forward to the NiFi node target group.

> **✅ BEST PRACTICE — NiFi UI needs sticky sessions**
> The NiFi UI keeps some per-user session state, so you should enable stickiness on the target group so each operator stays on the same node for the duration of their session. Without stickiness, the UI can behave erratically as requests bounce between nodes. Also enable HTTPS end-to-end — NiFi typically expects secure connections, and the ALB should talk HTTPS to the nodes, not plain HTTP.

### 12.3 Load balancing NiFi data ingest (NLB)

When external systems push data into NiFi (for example via a ListenTCP or ListenSyslog processor, or Site-to-Site), that traffic is usually raw TCP/UDP and high-volume — an NLB job. Every node typically runs the same listener, so the data can be spread across all nodes.

```text
ALB (internal, HTTPS)         NLB (data ingest, TCP)
  :8443 -> tg-nifi-ui           :6543 -> tg-nifi-s2s   (site-to-site)
  (sticky, HTTPS to nodes)      :7777 -> tg-nifi-tcp   (ListenTCP)
                                :514  -> tg-nifi-syslog (UDP/TCP)
  All target groups contain every NiFi node.
```

For Site-to-Site specifically, NiFi clients can be told the load-balanced endpoint; NiFi's S2S protocol then distributes data across the available nodes, complementing the NLB.

### 12.4 Step-by-step setup

1. Place NiFi nodes in private subnets across two AZs (`10.0.20.0/24`, `10.0.21.0/24`).
2. Stand up an internal ALB for the UI (sticky, HTTPS, ACM cert) targeting all nodes on 8443.
3. Stand up an NLB for data ingest with one listener per ingest protocol/port, each targeting all nodes.
4. Health-check each target group on its respective port.
5. Security groups: ALB allows 8443 from operators; NLB allows ingest ports from approved source ranges; nodes allow UI/ingest ports only from the matching load balancer, and allow the NiFi cluster ports only from each other.
6. Use TLS everywhere — NiFi is security-sensitive and usually configured for secure connections by default.

### 12.5 NiFi best practices and metrics

- **Separate UI and data load balancers** — do not try to force both through one load balancer; their needs (Layer 7 + sticky vs Layer 4 + high throughput) are different.
- **Enable stickiness for the UI only** — ingest traffic should spread freely; only the UI needs affinity.
- **Mind long-lived data connections** — set generous idle timeouts and TCP keep-alive for S2S and streaming ingest, as with Kafka.
- **Right-size for data volume** — NiFi ingest can be very high throughput; the NLB handles this well, but ensure nodes and subnets have capacity and IP space.

> **📘 NOTE — NiFi metrics to watch**
> On the ALB (UI): `TargetResponseTime` and `HealthyHostCount`. On the NLB (ingest): `ProcessedBytes` and `NewFlowCount` (data volume and connection rate), plus `HealthyHostCount`. On NiFi itself: back-pressure, queue sizes, and per-node CPU/heap — NiFi back-pressure is the clearest sign a node or flow is overloaded.

---

## 13. Playbook: Load Balancing Amazon EKS (Nodes & Node Groups)

Amazon EKS (Elastic Kubernetes Service) is AWS's managed Kubernetes. Kubernetes runs your applications inside containers and automatically places, scales, and restarts them. Load balancing for EKS is its own topic because Kubernetes constantly moves workloads around, so the load balancer must keep up automatically. This chapter explains the EKS building blocks first, then exactly how load balancing works.

### 13.1 EKS vocabulary you must know

| Term | Plain-English meaning |
|------|----------------------|
| **Cluster** | The whole Kubernetes system: a managed control plane (the brain, run by AWS) plus your worker nodes (the muscle). |
| **Node** | A single worker machine (usually an EC2 instance) that runs your containers. Like one server in the pool. |
| **Node group** | A set of identical nodes managed together and scaled as a unit. EKS "managed node groups" handle creating, updating, and scaling these EC2 instances for you. |
| **Pod** | The smallest unit Kubernetes runs — one or more containers that share an IP address. Pods are created and destroyed constantly as the app scales or heals. |
| **Deployment** | A recipe telling Kubernetes how many copies (replicas) of a pod to keep running. |
| **Service** | A stable internal address for a set of pods, so other things can reach them even as individual pods come and go. |
| **Ingress** | A Kubernetes object describing HTTP routing rules (which URL goes to which Service). On AWS this becomes an ALB. |
| **Fargate** | A serverless option where AWS runs pods for you with no EC2 nodes to manage. Pods become `ip` targets directly. |

### 13.2 Nodes vs node groups (and why load balancing cares)

A node is one machine; a node group is a managed fleet of identical machines that scales up and down automatically. As traffic grows, the node group adds nodes and Kubernetes schedules more pods onto them; as traffic falls, nodes are removed. The challenge: the actual workloads (pods) and even the nodes themselves are constantly changing, so a load balancer that points at a fixed list of servers would be wrong within minutes.

> **⚠️ WARNING — The core EKS load-balancing problem**
> Pods get new IP addresses every time they restart, and nodes join and leave as node groups scale. A static target list cannot work. The solution is a controller that watches Kubernetes and automatically updates the load balancer's target group in real time. On EKS this controller is the AWS Load Balancer Controller.

### 13.3 The AWS Load Balancer Controller

The AWS Load Balancer Controller is a small program you install into your cluster. It watches for Kubernetes Ingress and Service objects and, in response, creates and continuously manages real AWS load balancers and target groups. You describe what you want in Kubernetes; the controller makes AWS match it, including registering and deregistering targets as pods come and go.

- Create a Kubernetes Ingress → the controller provisions an ALB and routes HTTP/HTTPS by path/host to your pods.
- Create a Kubernetes Service of type LoadBalancer → the controller provisions an NLB for TCP/UDP traffic.
- As pods scale or move, the controller updates the target group automatically — no human action needed.

### 13.4 Two traffic modes: instance vs ip

This is the most important EKS target-group decision, and it maps directly to the target types from Chapter 5.

| Mode | How it works | When to use |
|------|--------------|-------------|
| **instance mode** | Target group points at the NODES (EC2 instances) on a NodePort; traffic lands on a node and Kubernetes forwards it to a pod, possibly on another node. | Simple setups; works without VPC CNI IP exposure. Extra hop and less even distribution. |
| **ip mode** (recommended) | Target group points DIRECTLY at pod IP addresses, using the Amazon VPC CNI that gives every pod a real VPC IP. | Most modern clusters, and required for Fargate. Lower latency, even load, no extra hop. |

> **✅ BEST PRACTICE — Prefer ip mode — and plan your IP space for it**
> `ip` mode is the modern default: the load balancer talks straight to pods, removing an extra network hop and balancing more evenly. But because every pod gets its own VPC IP address, a busy cluster can consume thousands of IPs. Size your pod subnets large (e.g., /20 or bigger) and remember the 5-address-per-subnet AWS reservation. Running out of pod IPs is a classic EKS outage — plan CIDR generously up front.

### 13.5 Reference architecture

Internet → ALB (public subnets, two AZs, created by the controller from an Ingress) → pod IP targets spread across nodes in private subnets in multiple AZs. The node groups live in the private subnets; the control plane is managed by AWS. For non-HTTP workloads, a Service of type LoadBalancer creates an NLB instead.

### 13.6 Step-by-step setup

1. Create the EKS cluster with subnets in at least two AZs. Tag public subnets for external load balancers and private subnets for internal ones, so the controller knows where to place each.
2. Create one or more managed node groups in the private subnets, with autoscaling limits (min/max nodes).
3. Install the AWS Load Balancer Controller and grant it permission (via IAM) to manage load balancers.
4. Use the Amazon VPC CNI so pods receive VPC IPs (enables `ip` mode).
5. For web apps: create an Ingress annotated for internet-facing, `ip` target mode, HTTPS with an ACM certificate, and a `/health` check path. The controller builds the ALB.
6. For non-HTTP apps: create a Service of type LoadBalancer annotated for an NLB and `ip` mode.
7. Set security groups so the load balancer can reach the pod/node ports and the cluster stays private.

**Example Ingress (what you declare; the controller does the rest):**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: <ACM-cert-arn>
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  rules:
    - http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
```

### 13.7 Scaling: how the pieces grow together

- **Horizontal Pod Autoscaler (HPA)** — adds more pod replicas when pods get busy (e.g., high CPU). The controller registers the new pods as targets automatically.
- **Cluster Autoscaler / Karpenter** — adds more NODES to a node group when there is no room to place new pods, and removes nodes when they are idle.
- **Result** — pods scale to handle load, nodes scale to hold the pods, and the load balancer target group is kept in sync the whole time without manual work.

> **✅ BEST PRACTICE — Pod readiness gates keep deployments safe**
> Enable readiness gates with the AWS Load Balancer Controller so Kubernetes waits until a new pod is actually registered and healthy in the target group before sending it traffic or removing the old pod. This prevents dropped requests during rolling updates — the Kubernetes equivalent of connection draining.

### 13.8 EKS best practices and metrics

- **Use `ip` target mode** for lower latency and even load (and it is required for Fargate).
- **Spread node groups across multiple AZs** so an AZ failure cannot take out the whole cluster.
- **Size pod subnets generously** — `ip` mode is IP-hungry; plan CIDR before you launch.
- **One ALB for many services** — use IngressGroups to share a single ALB across multiple Ingresses and save cost.
- **Keep the controller updated** and watch its logs — most "my load balancer didn't update" issues are controller permission or version problems.
- **Define readiness and liveness probes** on pods so Kubernetes and the load balancer agree on what "healthy" means.

> **📘 NOTE — EKS metrics to watch**
> Load-balancer side: `HealthyHostCount` (should track your replica count), `TargetResponseTime`, and 5XX counts as in Chapter 8. Kubernetes side: pod readiness, HPA replica counts, node-group size, and — critically — available IP addresses in your pod subnets. Also watch the AWS Load Balancer Controller's own logs and metrics; if it stops reconciling, your target groups silently drift from reality.

---

## 14. Networking Best-Practices Checklist

A consolidated checklist your team can use as a pre-launch review. Group it by theme and confirm each item before sending real traffic.

### 14.1 Availability and resilience

- [ ] Every load balancer spans at least two Availability Zones.
- [ ] Targets are spread evenly across those AZs.
- [ ] Cross-zone load balancing is configured intentionally (default on for ALB; decide consciously for NLB, weighing inter-AZ cost).
- [ ] Health checks point at a real, lightweight endpoint and use sensible thresholds.
- [ ] Deregistration delay (connection draining) is enabled so deployments don't cut users off.

### 14.2 Security

- [ ] Internet-facing load balancers are in public subnets; servers are in private subnets.
- [ ] Databases, Kafka, and NiFi cluster ports are never open to `0.0.0.0/0`.
- [ ] Security groups reference other security groups instead of broad IP ranges.
- [ ] TLS is enabled (certificates from ACM, auto-renewing), with a TLS 1.2+ security policy.
- [ ] Sensitive systems use end-to-end encryption, not just termination at the edge.
- [ ] AWS WAF is attached to public ALBs; AWS Shield protects against DDoS.
- [ ] Access logs and VPC Flow Logs are turned on and stored.

### 14.3 Addressing (CIDR)

- [ ] VPC is sized generously (e.g., /16) with no overlap with peered networks.
- [ ] Subnets have room for growth; load-balancer subnets have spare IPs (8+ per ALB subnet).
- [ ] EKS pod subnets are sized large for `ip`-mode IP consumption.
- [ ] The 5-reserved-addresses-per-subnet rule is accounted for in capacity plans.

### 14.4 Performance and correctness

- [ ] The right load balancer type is chosen per workload (ALB for HTTP, NLB for TCP/UDP).
- [ ] Long-lived connections (Kafka, databases, NiFi) use TCP keep-alive and suitable idle timeouts.
- [ ] Stateless apps avoid stickiness; stateful ones (e.g., NiFi UI) enable it deliberately.
- [ ] Kafka brokers advertise the correct load-balanced endpoint per broker.
- [ ] Database writes target only the primary; reads are split to replicas; failover is automated.
- [ ] EKS uses the AWS Load Balancer Controller with `ip` mode and readiness gates.

### 14.5 Observability

- [ ] CloudWatch alarms exist for healthy-host count, 5XX errors, latency, and rejected connections.
- [ ] Alarms target user-visible symptoms (errors, latency), not noise.
- [ ] Dashboards show the four golden signals: latency, traffic, errors, saturation.
- [ ] Thresholds were tuned against real baseline traffic before launch.

---

## 15. Troubleshooting Guide

A symptom-to-cause reference for the support team. Most load-balancer incidents fall into a handful of patterns; check these first.

### 15.1 Common symptoms and likely causes

| Symptom | Most likely causes | First things to check |
|---------|--------------------|-----------------------|
| All targets show unhealthy | Wrong health-check port/path; security group blocks the health check; app not actually listening | Confirm the app answers on the health-check port from within the VPC; check SG allows the LB to reach the target port |
| 502 Bad Gateway (ALB) | Target returned an invalid response; target crashed mid-request; protocol mismatch (HTTP vs HTTPS) | Check target logs; verify listener-to-target protocol; confirm the app speaks the expected protocol |
| 503 Service Unavailable (ALB) | No healthy targets in the group; capacity exhausted | Look at `HealthyHostCount`; check target health and scaling |
| 504 Gateway Timeout (ALB) | Target too slow; idle timeout shorter than the request | Check `TargetResponseTime`; raise idle timeout if requests are legitimately long |
| Connection works, then drops after idle | NLB/ALB idle timeout closed a quiet connection | Enable TCP keep-alive; raise idle timeout for long-lived connections (Kafka, DB, NiFi S2S) |
| Kafka connects then fails on produce/consume | Broker advertising its private IP instead of the LB endpoint | Fix `advertised.listeners` to the NLB DNS + that broker's unique port |
| Uneven load across targets (NLB) | Cross-zone off with uneven AZ distribution | Balance targets across AZs or enable cross-zone |
| EKS target group not updating | Controller lacks IAM permissions; controller crashed; wrong subnet tags | Check AWS Load Balancer Controller logs; verify IAM and subnet tags |
| Certificate errors for clients | Expired or mismatched certificate; wrong security policy | Use ACM auto-renewal; confirm the cert matches the hostname; check TLS policy |
| Server sees LB IP instead of client IP | Expected on ALB; on NLB, target-group setting changed | For real client IP use NLB (preserves by default) or read `X-Forwarded-For` on ALB |

### 15.2 A simple triage order

1. Check `HealthyHostCount` first — if it is zero, nothing else matters; fix health.
2. Read the error code (502/503/504) — it points straight at the layer at fault.
3. Verify security groups — can the load balancer actually reach the target port?
4. Check the listener/target protocol match — HTTP vs HTTPS mismatches are extremely common.
5. Look at target logs — the application often logs the real reason.
6. Check recent changes — deployments, scaling events, and config edits cause most new incidents.

> **✅ BEST PRACTICE — When in doubt, follow the path**
> Trace a single request from the outside in: DNS → listener → rule → target group → target → app → dependency. Find the first hop that fails and you have found the problem. The access logs and VPC Flow Logs you enabled earlier make this trace fast.

---

## 16. Quick Reference and Glossary

### 16.1 Which load balancer for which workload

| Workload | Load balancer | Target type | Key reason |
|----------|---------------|-------------|------------|
| Web app / REST API | ALB | `ip` / `instance` / `lambda` | HTTP routing, HTTPS, WAF |
| Microservices | ALB | `ip` | Path/host routing to many services |
| Apache Kafka | NLB | `ip` | TCP, per-broker listeners, static IPs |
| Database (self-managed) | NLB (internal) | `ip` | TCP, writer/reader split |
| Database (RDS/Aurora) | Built-in endpoints | n/a | Role-aware, auto-failover |
| NiFi web UI | ALB (sticky, HTTPS) | `ip` / `instance` | HTTPS UI with session affinity |
| NiFi data ingest / S2S | NLB | `ip` | High-throughput TCP/UDP |
| EKS HTTP workloads | ALB (via Ingress) | `ip` | Controller-managed, `ip` mode |
| EKS TCP/UDP workloads | NLB (via Service) | `ip` | Controller-managed, `ip` mode |
| Insert security appliances | GWLB | `ip` | Transparent traffic inspection |

### 16.2 Common ports cheat sheet

| Port | Used by | Notes |
|------|---------|-------|
| 80 | HTTP | Redirect to 443 in practice |
| 443 | HTTPS | TLS-encrypted web/API |
| 9092 / 9094 | Kafka (plain / TLS) | Per-broker listeners on NLB |
| 5432 | PostgreSQL | Writer + reader split |
| 3306 | MySQL / MariaDB | Writer + reader split |
| 8443 | NiFi UI (example) | HTTPS, sticky on ALB |
| 514 | Syslog | Common NiFi ingest (UDP/TCP) |

### 16.3 Glossary

| Term | Meaning |
|------|---------|
| **ACM** | AWS Certificate Manager — issues and auto-renews free TLS certificates. |
| **ALB** | Application Load Balancer — Layer 7, routes HTTP/HTTPS by content. |
| **Availability Zone (AZ)** | An isolated data center (or set) within a Region. |
| **CIDR** | A compact way to write a range of IP addresses, e.g., `10.0.0.0/16`. |
| **CloudWatch** | AWS monitoring service for metrics, alarms, and logs. |
| **Cross-zone load balancing** | Letting a load-balancer node send traffic to targets in other AZs. |
| **Deregistration delay** | Time the LB lets existing connections finish before fully removing a target. |
| **EKS** | Elastic Kubernetes Service — managed Kubernetes on AWS. |
| **GWLB** | Gateway Load Balancer — inserts security appliances into traffic flow. |
| **Health check** | A repeated test that decides whether a target receives traffic. |
| **Ingress** | A Kubernetes object describing HTTP routing; becomes an ALB on AWS. |
| **Listener** | A load-balancer port that accepts incoming traffic. |
| **MSK** | Amazon Managed Streaming for Apache Kafka — Kafka run by AWS. |
| **NACL** | Network ACL — stateless subnet-level firewall with allow and deny rules. |
| **NAT Gateway** | Lets private servers reach out to the internet without being reachable from it. |
| **NLB** | Network Load Balancer — Layer 4, ultra-fast TCP/UDP balancing. |
| **Node** | A worker machine in a Kubernetes cluster. |
| **Node group** | A managed, autoscaling set of identical Kubernetes nodes. |
| **Pod** | The smallest deployable unit in Kubernetes; one or more containers sharing an IP. |
| **Rule** | ALB logic on a listener that decides where to route a request. |
| **Security Group (SG)** | Stateful virtual firewall attached to a resource; allow rules only. |
| **Stickiness** | Pinning a client to the same target for the session. |
| **Subnet** | A slice of a VPC living in one AZ; public or private. |
| **Target group** | The list of backends a load balancer sends traffic to, plus health-check settings. |
| **TLS / SSL** | Encryption that protects data in transit; HTTPS is HTTP over TLS. |
| **VPC** | Virtual Private Cloud — your isolated private network in AWS. |
| **WAF** | Web Application Firewall — blocks malicious HTTP requests on an ALB. |

---

*End of guide.*
