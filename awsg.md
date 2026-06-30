# AWS Network Security — A Complete, Plain-English Field Guide

**Security Groups, Network ACLs, AWS WAF, and AWS Shield**
*how the four layers fit together, with rules, examples, and troubleshooting*

> Written for Cloud Support & Application Development Support teams.
> Explained at a middle-school reading level — no prior cloud experience required.

---

## Table of Contents

1. [How to Use This Guide](#1-how-to-use-this-guide)
2. [Networking Vocabulary (Read This First)](#2-networking-vocabulary-read-this-first)
3. [The Big Picture: Four Layers of Defense](#3-the-big-picture-four-layers-of-defense)
4. [Security Groups (Your Door Locks)](#4-security-groups-your-door-locks)
5. [Network ACLs (Your Neighborhood Gate)](#5-network-acls-your-neighborhood-gate)
6. [AWS WAF (Your Content Inspector)](#6-aws-waf-your-content-inspector)
7. [AWS Shield (Your Flood Barrier)](#7-aws-shield-your-flood-barrier)
8. [Putting It All Together](#8-putting-it-all-together)
9. [Monitoring and Logging](#9-monitoring-and-logging)
10. [Best-Practices Checklist](#10-best-practices-checklist)
11. [Troubleshooting Guide](#11-troubleshooting-guide)
12. [Quick Reference and Glossary](#12-quick-reference-and-glossary)

---

## 1. How to Use This Guide

This guide teaches the four main building blocks of AWS network security from the ground up: Security Groups, Network ACLs (NACLs), AWS WAF, and AWS Shield. You do not need to know anything about cloud computing before reading it. Every technical word is explained the first time it appears, usually with a real-world comparison you already understand.

The guide is built for two audiences who work side by side:

- **Cloud Support teams** — the people who build, watch, and fix the network plumbing. You will care most about how Security Groups and NACLs are written, how WAF rules are tuned, and how to read the logs when something is blocked or breached.
- **Application Development Support teams** — the people who connect applications to that plumbing. You will care most about which control protects which part of your app, and why a request is being allowed or denied.

**How the guide is organized:**

1. Chapters 2–3 teach the core ideas everyone must know: the networking words, and the big picture of how the four controls layer together.
2. Chapters 4–7 go deep on each control in turn: Security Groups, NACLs, WAF, and Shield.
3. Chapter 8 shows how the four work together on one realistic system, request by request.
4. Chapters 9–11 cover monitoring and logging, a best-practice checklist, and a troubleshooting guide.
5. Chapter 12 is a quick reference and glossary.

> **📘 NOTE — Icons you will see**
> Throughout the guide, blockquotes flag important information: **✅ BEST PRACTICE** boxes are recommended habits, **⚠️ WARNING** boxes are mistakes to avoid, **🔒 SECURITY** boxes are security notes, and **📘 NOTE** boxes are extra explanations.

---

## 2. Networking Vocabulary (Read This First)

Network security controls decide what traffic is allowed where. Before we go further, here are the words you will see on every screen and in every rule. Learn these and the rest of the guide becomes easy.

### 2.1 The core terms

| Term | Plain-English meaning |
|------|----------------------|
| **VPC** (Virtual Private Cloud) | Your own private, walled-off network inside AWS. Think of it as your company's private campus. |
| **Subnet** | A smaller slice of your VPC that lives in one Availability Zone. Public subnets can reach the internet; private subnets cannot. Think of it as a fenced section of the campus. |
| **IP address** | The numeric "phone number" of a device, e.g., `10.0.1.25`. Private IPs work only inside the VPC; public IPs are reachable from the internet. |
| **CIDR block** | A short way to write a range of IP addresses, e.g., `10.0.0.0/16` (a big range) or `203.0.113.5/32` (exactly one address). The `/number` tells you how many addresses are included. |
| **Port** | A numbered "door" on a server for a specific kind of traffic, e.g., 443 for HTTPS, 22 for SSH, 3306 for MySQL. One IP address has 65,536 ports. |
| **Protocol** | The language of the traffic. The three you'll see most: TCP (reliable connections, used by web/database), UDP (fast, connectionless, used by DNS/streaming), and ICMP (used by ping). |
| **Inbound vs Outbound** | Inbound (or ingress) is traffic coming INTO a resource. Outbound (or egress) is traffic leaving it. Every rule applies to one direction. |
| **Stateful vs Stateless** | A stateful control remembers a connection, so a reply to allowed traffic is automatically allowed back. A stateless control has no memory and must be told about both directions. This single distinction explains most of the difference between Security Groups and NACLs. |
| **ENI** (Elastic Network Interface) | A virtual network card attached to a resource (like an EC2 server). Security Groups actually attach to the ENI, which is why one server can have several. |

### 2.2 The one idea to hold onto: stateful vs stateless

Almost every confusing moment in AWS network security comes back to this. Picture a security guard at a door:

- **A stateful guard** remembers who they let in. When that person turns to leave, the guard waves them out without checking again. Security Groups work this way.
- **A stateless guard** has no memory at all. They check every single person in BOTH directions — coming in and going out — every time. If you only wrote a rule for people coming in, those same people get stopped on the way out. Network ACLs work this way.

> **📘 NOTE — Why this matters constantly**
> When a connection mysteriously works one way but fails the other, the cause is almost always a stateless NACL that's missing a return-traffic rule. Keep the guard analogy in your head and you'll diagnose these in seconds.

### 2.3 A reference system we will reuse

To keep examples consistent, the whole guide protects one example system: a simple public web application. Memorize this small layout; we refer back to it often.

| Piece | Where it lives | What it does |
|-------|----------------|--------------|
| Internet users | Anywhere (`0.0.0.0/0`) | Send web requests to our app |
| Web/App servers | Private subnet `10.0.10.0/24` | Run the application on port 8080 |
| Load balancer (ALB) | Public subnet `10.0.0.0/24` | Public front door on port 443 (HTTPS) |
| Database | Data subnet `10.0.20.0/24` | MySQL on port 3306, private only |
| Admin laptop | Office IP `203.0.113.10/32` | Occasional SSH (port 22) to servers |

---

## 3. The Big Picture: Four Layers of Defense

AWS gives you four main network-security controls. They are not competing choices — they are layers that stack on top of each other, each catching what the others miss. This idea is called defense in depth: if one layer is misconfigured, the next still protects you. This chapter gives you the map before we explore each layer in detail.

### 3.1 The four controls at a glance

| Control | Where it sits | Layer | What it protects against | Stateful? |
|---------|---------------|-------|--------------------------|-----------|
| **AWS Shield** | The edge of AWS, in front of everything | Network/transport (3/4) | DDoS — floods of traffic meant to knock you offline | n/a |
| **AWS WAF** | On the load balancer / CDN / API | Application (7) | Malicious web requests — SQL injection, XSS, bad bots | n/a (inspects requests) |
| **Network ACL (NACL)** | The edge of each subnet | Network/transport (3/4) | Broad, subnet-wide allow/deny by IP, port, protocol | No (stateless) |
| **Security Group (SG)** | On each resource (server, LB, database) | Network/transport (3/4) | Precise, per-resource allow rules | Yes (stateful) |

### 3.2 The journey of a request

Imagine a single web request arriving from a user on the internet. It passes through the layers from the outside in, and each layer can stop it:

1. **AWS Shield** is always on at the AWS edge. If the request is part of a massive flood (a DDoS attack), Shield helps absorb and filter it before it ever reaches you.
2. **AWS WAF** (if attached to your load balancer) reads the actual request. If it looks like an attack — say, a login form field stuffed with database commands — WAF blocks it.
3. The **Network ACL** on the subnet checks the request against broad rules. For example, "block this entire abusive IP range" or "only allow web ports into this subnet."
4. The **Security Group** on the resource makes the final, precise check: "does this specific server accept traffic on this specific port from this source?"
5. Only if all applicable layers allow it does the request reach your application.

On the way back out, the response retraces its steps — and here the stateful/stateless difference appears. The Security Group automatically allows the reply (it remembers the connection). The NACL does not remember, so it must have its own rule permitting the return traffic. We'll see exactly how this plays out in Chapter 8.

### 3.3 How to think about each layer

- **Shield is your flood barrier** — it deals with volume and brute force, not the content of any single request.
- **WAF is your content inspector** — it reads inside web requests to catch clever attacks that look like normal traffic at the network level.
- **NACLs are your neighborhood gate** — broad rules at the subnet edge; good for blanket blocks and a coarse safety net.
- **Security Groups are your door locks** — precise, per-resource rules; this is where you do most of your day-to-day work.

> **✅ BEST PRACTICE — The golden rule of layering**
> Do most of your precise work with Security Groups (door locks). Use NACLs (the gate) for a few broad, blanket rules. Add WAF (the inspector) in front of public web apps. Let Shield (the flood barrier) run automatically, and upgrade it only if you face serious DDoS risk. You rarely need to fight all four at once — each has a clear job.

### 3.4 A note on cost

Three of these four are free or mostly free, which surprises people:

- Security Groups and NACLs are completely free.
- AWS Shield Standard is free and automatic for every AWS customer.
- **AWS WAF and AWS Shield Advanced cost money** — WAF charges per rule and per million requests; Shield Advanced is a paid subscription with extra DDoS protection and support. We cover when each is worth it in their chapters.

---

## 4. Security Groups (Your Door Locks)

A Security Group is a virtual firewall that attaches directly to a resource — an EC2 server, a load balancer, a database, a container. It is the control you will use most. Think of it as the lock on a specific door: it decides exactly who may connect to that one resource, on which ports, using which protocol.

### 4.1 The defining traits

- **Allow-only** — Security Groups contain only "allow" rules. There is no "deny" rule. Anything you don't explicitly allow is denied automatically. This makes them simple and safe: the default is to block.
- **Stateful** — if you allow traffic in, the reply is automatically allowed back out (and vice-versa). You almost never need to think about return traffic.
- **Attached to resources, not subnets** — a Security Group protects whatever it is attached to, wherever that resource sits. Two servers in the same subnet can have completely different Security Groups.
- **Evaluated together** — a resource can have several Security Groups at once; their allow rules are combined (added together). If any group allows the traffic, it's allowed.

### 4.2 What a rule looks like

Every Security Group rule has the same shape. An inbound rule answers: "What traffic may come IN to this resource?" An outbound rule answers: "What traffic may leave?" Each rule specifies:

- **Type/Protocol** — e.g., HTTPS (TCP 443), SSH (TCP 22), or a custom port.
- **Port range** — the door number(s), e.g., 443, or 8000-8100.
- **Source (inbound) or Destination (outbound)** — WHO the traffic may come from or go to. This is the powerful part: it can be a CIDR range (like `0.0.0.0/0` for anyone) OR another Security Group.

### 4.3 The superpower: referencing other Security Groups

Instead of listing IP addresses, a Security Group rule can name ANOTHER Security Group as its source. This means "allow traffic from any resource that belongs to that group." It is the single most important Security Group technique, because it keeps your rules correct even as servers come and go and change IPs.

> **✅ BEST PRACTICE — Why reference groups instead of IPs**
> In the cloud, server IP addresses change constantly — every time something scales, restarts, or is replaced. If you write rules using IP addresses, they break. If you write "allow from the load balancer's Security Group," the rule keeps working no matter how many load balancer nodes appear or what IPs they get. Always prefer group references over IP addresses for traffic between your own resources.

Here is the gold-standard three-tier pattern for our reference web app, written in plain language:

```text
sg-alb  (Load balancer)
  Inbound : allow TCP 443 from 0.0.0.0/0      # public HTTPS from anyone
  Inbound : allow TCP 80  from 0.0.0.0/0       # http (to redirect to https)

sg-app  (Application servers)
  Inbound : allow TCP 8080 from sg-alb         # ONLY from the load balancer
  Inbound : allow TCP 22   from sg-bastion      # admin access via bastion only

sg-db   (Database)
  Inbound : allow TCP 3306 from sg-app          # ONLY from the app servers

Result: the internet can reach only the load balancer.
The app servers accept traffic only from the load balancer.
The database accepts traffic only from the app servers.
Nothing else can connect, even from inside the VPC.
```

Notice how each tier only trusts the tier directly in front of it. This is exactly the layered, least-privilege design you want.

### 4.4 Default outbound and the default group

- **Default outbound is wide open** — a new Security Group allows ALL outbound traffic by default. For most apps this is fine, but high-security environments tighten it so a compromised server can't "phone home" to an attacker. Restricting outbound is called egress filtering.
- **The default Security Group** — every VPC comes with one. It allows all traffic between resources that share it, and is a common source of accidental over-permission. Prefer creating purpose-built groups over relying on the default.

### 4.5 Limits and good habits

- **Name and describe everything** — give each group and each rule a clear description (e.g., "HTTPS from public"). Six months later, nobody remembers why a rule exists unless it's labeled.
- **One purpose per group** — create `sg-alb`, `sg-app`, `sg-db` rather than one giant group. Small, single-purpose groups are easier to reason about and reuse.
- **Mind the quotas** — there are limits on rules per group and groups per network interface (the defaults are generous but not infinite). If you're hitting them, your design is probably too broad.
- **Never use `0.0.0.0/0` on sensitive ports** — SSH (22), RDP (3389), and database ports (3306, 5432) should never be open to the whole internet. Scope them to a specific admin IP or a bastion's Security Group.

> **⚠️ WARNING — The most common Security Group mistake**
> Opening SSH (port 22) or RDP (port 3389) to `0.0.0.0/0` "just to test." Automated bots scan the entire internet for these open ports within minutes. If you need admin access, allow only your office IP as a `/32`, or better, go through a bastion host or AWS Systems Manager Session Manager (which needs no open inbound port at all).

### 4.6 When Security Groups are not enough

Security Groups are precise and stateful, but they have two gaps that the other layers fill: they cannot write explicit DENY rules (so you can't blanket-block a known-bad IP range — that's a job for a NACL), and they don't read the content of web requests (so they can't catch SQL injection — that's a job for WAF). Knowing these gaps is exactly why the other three layers exist.

---

## 5. Network ACLs (Your Neighborhood Gate)

A Network ACL (NACL, pronounced "nackle") is a firewall that sits at the edge of a subnet, checking every packet that enters or leaves the whole subnet. If a Security Group is the lock on one door, a NACL is the gate at the entrance to a whole neighborhood. It is broader, blunter, and — crucially — stateless.

### 5.1 The defining traits

- **Operates at the subnet edge** — a NACL protects every resource in the subnets it's associated with, all at once. You don't attach it to individual servers.
- **Allow AND deny rules** — unlike Security Groups, NACLs can explicitly DENY. This is their unique value: you can blanket-block a known-bad IP range so it can't reach anything in the subnet.
- **Stateless** — the big one. NACLs have no memory of connections. If you allow traffic IN, you must also write a rule allowing the reply to go OUT, or the connection breaks. (Remember the forgetful guard from Chapter 2.)
- **Numbered, ordered rules** — rules are evaluated in number order, lowest first, and the FIRST match wins. Once a rule matches, AWS stops looking. Rule order is everything.

### 5.2 How rule evaluation works

This is where NACLs differ most from Security Groups, so go slowly. Each NACL has a numbered list of inbound rules and a separate numbered list of outbound rules. For each packet, AWS reads the rules from the lowest number upward and applies the first one that matches. There is always a final, un-removable rule numbered "*" that denies everything not matched before it.

```text
Inbound rules (evaluated low number first, first match wins)
  100  ALLOW  TCP 443   from 0.0.0.0/0      # let HTTPS in
  110  ALLOW  TCP 1024-65535 from 0.0.0.0/0 # let return traffic in (see 5.3)
  120  DENY   ALL        from 198.51.100.0/24 # block a bad range
  *    DENY   ALL        from 0.0.0.0/0       # default: block everything else
```

> **⚠️ WARNING — First match wins — order carefully**
> Because the first matching rule wins, a broad ALLOW placed before a specific DENY will let the bad traffic through — the DENY never gets read. Put specific DENY rules at LOW numbers (so they're checked first) and broad ALLOW rules at higher numbers. Leave gaps between numbers (100, 110, 120…) so you can insert rules later without renumbering.

### 5.3 Ephemeral ports: the stateless gotcha

Here is the single most common NACL mistake, and it follows directly from being stateless. When a client connects to your server on port 443, the server's reply does NOT come back on port 443. It comes back on a high-numbered, temporary port the client picked — called an ephemeral port. These are typically in the range 1024–65535.

With a stateful Security Group, this is invisible — the reply is auto-allowed. But a stateless NACL must have an explicit rule allowing outbound (and the return inbound) traffic on the ephemeral port range, or every connection will hang.

> **⚠️ WARNING — Always allow ephemeral ports on NACLs**
> If you use a custom NACL, you must add rules permitting the ephemeral port range (commonly 1024–65535) for return traffic — outbound for responses to inbound connections, and inbound for responses to outbound connections your servers initiate. Forgetting this causes connections that "start but never complete," and it's the number-one NACL support ticket.

### 5.4 The default NACL vs custom NACLs

| | Default NACL | Custom NACL |
|---|--------------|-------------|
| Starting behavior | Allows ALL inbound and outbound traffic | Denies ALL inbound and outbound until you add rules |
| Good for | Most workloads — leave it open and rely on Security Groups | Adding specific subnet-wide DENY rules or strict isolation |
| Risk | Low (Security Groups do the real work) | High — easy to lock yourself out by forgetting ephemeral ports |

### 5.5 When to actually use NACLs

Most teams leave NACLs at their default (allow-all) and do all real filtering with Security Groups. Reach for a custom NACL only when you need something Security Groups can't do:

- **Blanket-blocking a malicious IP range** — a DENY rule stops that range from reaching anything in the subnet, no matter what the Security Groups say.
- **A coarse safety net** — e.g., ensuring a "database" subnet never accepts traffic from the internet, as a backstop in case a Security Group is misconfigured.
- **Compliance requirements** — some standards mandate subnet-level controls in addition to per-resource ones.

### 5.6 Security Groups vs NACLs side by side

| Question | Security Group | Network ACL |
|----------|----------------|-------------|
| Where does it apply? | To a resource (via its ENI) | To a whole subnet |
| Allow rules? | Yes | Yes |
| Deny rules? | No (implicit deny only) | Yes (explicit deny) |
| Stateful? | Yes — returns auto-allowed | No — must allow returns yourself |
| Rule order matter? | No — all rules combined | Yes — lowest number, first match wins |
| Can reference another group? | Yes (its superpower) | No — IP ranges only |
| Typical role | Your main, precise control | Broad backstop and blanket blocks |

> **✅ BEST PRACTICE — Use both, for different jobs**
> Security Groups and NACLs are not either/or. The recommended design uses Security Groups for nearly all real, precise control (because they're stateful and can reference each other), and reserves NACLs for the occasional broad DENY or as a subnet-level safety net. They form two of your four layers.

---

## 6. AWS WAF (Your Content Inspector)

AWS WAF (Web Application Firewall) is different from the first two controls. Security Groups and NACLs work at the network level — they only see IP addresses and ports, like an envelope. WAF works at the application level (Layer 7): it opens the envelope and reads the actual web request. This lets it catch attacks that look completely normal to a network firewall.

### 6.1 Why a network firewall isn't enough

Imagine an attacker types database commands into your website's login box, trying to trick your app into dumping its data. This is called SQL injection. To a Security Group or NACL, this request looks perfectly fine — it's just normal HTTPS traffic on port 443 from a normal IP. Only something that reads the contents of the request can spot the malicious payload. That something is WAF.

> **📘 NOTE — WAF reads what the network controls cannot see**
> Security Groups and NACLs ask "is this traffic allowed on this port from this IP?" WAF asks "does the content of this web request look like an attack?" They're complementary: the network controls guard the doors and ports; WAF inspects the letters that come through them.

### 6.2 What WAF can do

- **Block common web attacks** — SQL injection (database-command attacks) and cross-site scripting or XSS (injecting malicious scripts into pages).
- **Filter by content** — inspect headers, the request body, URL paths, query strings, cookies, and more, and block based on what it finds.
- **Rate limiting** — automatically block an IP that sends too many requests in a short time (e.g., more than 2,000 in 5 minutes) — great against brute-force and scraping.
- **Geo-blocking** — allow or block traffic by country.
- **IP allow/deny lists** — permit known-good partners or block known-bad sources at the application layer.
- **Bot control** — identify and manage automated bot traffic, separating good bots (search engines) from bad ones.

### 6.3 Where WAF attaches

WAF does not run on its own — you attach it to a public-facing AWS service that handles web traffic. The common attachment points are:

- **Application Load Balancer (ALB)** — the most common; protects apps behind the load balancer.
- **Amazon CloudFront** — AWS's content delivery network (CDN); protects at the global edge, closest to users.
- **Amazon API Gateway** — protects APIs.
- **AppSync and a few others** — for GraphQL and similar services.

> **⚠️ WARNING — WAF works only with HTTP/HTTPS services**
> Because WAF reads web requests, it attaches only to services that handle HTTP/HTTPS (ALB, CloudFront, API Gateway). It cannot protect a Network Load Balancer or a raw TCP service like a database or Kafka — those have no web requests to inspect. For non-web traffic, you rely on Security Groups, NACLs, and Shield.

### 6.4 How WAF is organized: ACLs, rules, and rule groups

| Piece | What it is |
|-------|-----------|
| **Web ACL** | The top-level container you attach to a resource. It holds an ordered list of rules and a default action (allow or block) for anything no rule matches. |
| **Rule** | A single condition plus an action, e.g., "if the request body contains a SQL-injection pattern, BLOCK." Rules are evaluated in priority order. |
| **Rule group** | A reusable bundle of rules. You can write your own, or use ready-made ones. |
| **Managed rule groups** | Pre-built, automatically updated rule bundles from AWS and security vendors — covering the OWASP Top 10 common threats, known bad inputs, bot patterns, and more. The fastest way to get strong protection. |

### 6.5 Rule actions and a safe rollout

Each WAF rule can take one of a few actions when it matches: Allow, Block, Count (just record a match without blocking), or CAPTCHA/Challenge (make the client prove it's human). The Count action is your best friend for safe rollouts.

> **✅ BEST PRACTICE — Start in Count mode to avoid blocking real users**
> Before you set a rule to BLOCK, run it in COUNT mode for a while and watch the metrics. Count records what WOULD have been blocked without actually blocking it, so you can confirm the rule isn't catching legitimate customers (a false positive). Only switch to BLOCK once the counts look clean. Turning on aggressive blocking rules cold is a classic way to accidentally take down your own site.

### 6.6 A sensible starting configuration

1. Attach a Web ACL to your public ALB or CloudFront distribution.
2. Add the AWS Managed Rules "common" and "known bad inputs" rule groups — broad protection with almost no tuning.
3. Add the SQL-injection and (if you render user input) cross-site-scripting managed rules.
4. Add a rate-based rule to throttle any single IP that floods you.
5. Run new rules in Count mode first, review the metrics, then switch to Block.
6. Send WAF logs to storage (see Chapter 9) so you can investigate what's being blocked and why.

### 6.7 Cost awareness

Unlike Security Groups and NACLs, WAF costs money: roughly a monthly charge per Web ACL, a charge per rule, and a charge per million requests inspected. Managed rule groups may add a small fee. For a public, internet-facing web application the protection is usually well worth it; for a purely internal service with no public exposure, you may not need WAF at all.

---

## 7. AWS Shield (Your Flood Barrier)

AWS Shield protects against DDoS attacks. DDoS stands for Distributed Denial of Service: an attacker uses thousands of machines to flood your system with so much traffic that real users can't get through — like a mob jamming every entrance to a store so genuine customers can't get in. Shield is your barrier against that flood.

### 7.1 What a DDoS attack actually is

There are a few flavors, and Shield addresses them all:

- **Volumetric attacks** — sheer volume — gigabits of junk traffic meant to saturate your network pipe.
- **Protocol attacks** — abuse weaknesses in network protocols (like a flood of half-open connections) to exhaust your servers' resources.
- **Application-layer attacks** — a flood of seemingly valid web requests (like hammering an expensive search page) to overwhelm the app itself. These overlap with what WAF rate-limiting handles.

### 7.2 Two tiers: Standard and Advanced

| | Shield Standard | Shield Advanced |
|---|-----------------|-----------------|
| Cost | Free, automatic for all AWS customers | Paid monthly subscription (plus data fees) |
| Protection | Defends against common, most frequent network/transport-layer DDoS attacks | Adds protection against large and sophisticated attacks, including application-layer |
| You do anything? | No — it's always on in the background | You enroll resources and configure protections |
| DDoS cost protection | No | Yes — credits back scaling charges caused by a DDoS attack |
| Expert help | No | Yes — access to the AWS Shield Response Team (SRT) during attacks |
| Best for | Everyone (it's already included) | High-profile, high-availability, or frequently targeted apps |

### 7.3 Shield Standard: already protecting you

Every AWS customer gets Shield Standard automatically, at no cost, with nothing to turn on. It continuously defends services like CloudFront, Route 53, and Elastic Load Balancing against the common volumetric and protocol DDoS attacks that make up the vast majority of attempts. For many workloads, this baseline is genuinely enough.

### 7.4 Shield Advanced: when the stakes are higher

Shield Advanced is a paid upgrade for organizations that face serious DDoS risk — well-known brands, financial services, gaming, or anyone who has been targeted before. Beyond stronger detection, its standout benefits are:

- **DDoS cost protection** — if an attack forces your resources to scale up (costing money), AWS credits those charges back. This removes the fear of a surprise bill from an attack.
- **The Shield Response Team (SRT)** — during a serious attack you can get direct help from AWS DDoS experts who help build mitigations.
- **Tighter WAF integration** — Shield Advanced works hand-in-hand with WAF for application-layer defense, and includes WAF usage for protected resources.
- **Detailed attack visibility** — richer diagnostics and near-real-time attack notifications.

### 7.5 How Shield works with the other layers

> **✅ BEST PRACTICE — Shield and WAF are a team**
> Shield handles the flood (volume and protocol abuse); WAF handles malicious or excessive individual requests at the application layer. For application-layer DDoS — a storm of valid-looking requests — the standard defense is WAF rate-based rules backed by Shield. If you adopt Shield Advanced, plan to use WAF alongside it; they're designed to work together.

Architectural choices also strengthen Shield's effectiveness: serving traffic through CloudFront and Route 53 puts AWS's globally distributed edge network in front of your origin, which absorbs and disperses attack traffic far better than a single regional endpoint. Designing to scale (auto scaling, load balancing across AZs) means you can soak up bursts while mitigations engage.

### 7.6 Do you need Shield Advanced?

A simple way to decide:

- **Most internal or low-profile apps** — Shield Standard (free) is fine. Focus your effort on Security Groups, NACLs, and WAF.
- **Public, revenue-critical, or high-visibility apps** — consider Shield Advanced for the cost protection, expert support, and stronger application-layer defense, especially if downtime is expensive or you've been targeted before.

---

## 8. Putting It All Together

Now we connect the four layers on our reference web application and follow real traffic through them. This is the chapter to reread whenever the pieces feel abstract — it shows each control doing its specific job in sequence.

### 8.1 The complete protected architecture

Our public web app, fully defended, looks like this from the outside in:

```text
Internet users (0.0.0.0/0)
      |
      v
[ AWS Shield ]  always-on DDoS flood protection at the AWS edge
      |
      v
[ Amazon CloudFront / ALB ]  <-- [ AWS WAF Web ACL ] inspects each request
      |                              (SQLi, XSS, rate limiting, geo, bots)
      v
[ Public subnet ]  NACL: broad allow of web ports, deny known-bad ranges
   ALB  (Security Group sg-alb: allow 443 from the internet)
      |
      v
[ Private subnet ]  NACL: backstop, no direct internet
   App servers (sg-app: allow 8080 only from sg-alb; 22 only from bastion)
      |
      v
[ Data subnet ]  NACL: deny all internet, allow only from private subnet
   Database (sg-db: allow 3306 only from sg-app)
```

### 8.2 Following an allowed request, step by step

1. A customer's browser sends an HTTPS request to your site.
2. Shield checks it as part of overall traffic patterns; it's not part of a flood, so it passes.
3. WAF reads the request: no SQL-injection or XSS patterns, the IP isn't over the rate limit, the country is allowed — ALLOW.
4. The public subnet's NACL allows HTTPS (443) inbound — pass.
5. The load balancer's Security Group (`sg-alb`) allows 443 from `0.0.0.0/0` — the request reaches the ALB.
6. The ALB forwards to an app server on 8080. The app server's Security Group (`sg-app`) allows 8080 from `sg-alb` — accepted.
7. The app needs data, so it connects to the database on 3306. The database's Security Group (`sg-db`) allows 3306 from `sg-app` — accepted.
8. Because Security Groups are stateful, every reply flows back automatically. The response returns to the customer.

### 8.3 Following a blocked attack

Now watch the same architecture stop different attacks, each at the right layer:

- **A traffic flood (DDoS)** — stopped by Shield at the edge before it ever reaches your app.
- **A SQL-injection attempt in a form field** — looks like normal HTTPS to the network, but WAF reads the body, matches the SQL-injection rule, and BLOCKS it.
- **Repeated probing from one abusive IP range** — a NACL DENY rule blocks that entire range at the subnet edge, so it can't touch anything inside.
- **An attempt to connect directly to the database from the internet** — the data subnet's NACL denies internet traffic, and even if that failed, `sg-db` only allows 3306 from `sg-app`. Two layers say no.
- **An attempt to SSH into an app server from a random IP** — `sg-app` only allows port 22 from the bastion's Security Group, so the connection is refused.

### 8.4 The layered-defense summary

| Threat | Caught by | Why that layer |
|--------|-----------|----------------|
| Traffic flood (DDoS) | AWS Shield | Built to absorb volume at the edge |
| SQL injection / XSS | AWS WAF | Only it reads request content |
| Known-bad IP range | NACL (deny rule) | Only it can explicitly DENY, subnet-wide |
| Wrong port / wrong source to a resource | Security Group | Precise, per-resource allow rules |
| Direct database access from internet | NACL + Security Group | Two independent layers both refuse |
| Brute-force login flood | WAF rate limit + Shield | Throttle requests, absorb volume |

> **🔒 SECURITY — The whole philosophy in one sentence**
> No single control catches everything, so you layer four of them — Shield for floods, WAF for malicious requests, NACLs for broad subnet rules, and Security Groups for precise per-resource locks — and each compensates for the others' blind spots.

---

## 9. Monitoring and Logging

Security controls are only useful if you can see what they're doing. When a request is blocked at 3 a.m., or a customer says "I can't connect," logs are how you find out who, from where, and why. This chapter covers what each layer logs and the alarms a support team should set.

### 9.1 What each layer gives you

| Layer | What to enable | What it tells you |
|-------|----------------|-------------------|
| **Security Groups / NACLs** | VPC Flow Logs (per VPC, subnet, or interface) | A record of accepted and rejected connections — source, destination, port, and whether it was ALLOWed or REJECTed. Essential for "why is this blocked?" |
| **AWS WAF** | WAF logging to S3, CloudWatch Logs, or Kinesis | Every inspected request, which rule matched, and the action taken. Shows exactly what WAF blocked and why. |
| **AWS Shield** | Shield metrics in CloudWatch; Advanced adds detailed diagnostics | Whether an attack is in progress, its size, and how mitigation is performing. |
| **All of AWS** | AWS CloudTrail | WHO changed a rule and WHEN — the audit trail for every security-group or WAF edit. |

### 9.2 VPC Flow Logs: your network black box

VPC Flow Logs are the most important tool for diagnosing Security Group and NACL behavior. Each log entry records a connection attempt and ends in either ACCEPT or REJECT. When something can't connect, a REJECT entry points you straight at the layer that blocked it; the absence of any entry tells you the traffic never arrived at all. Enable them before you have a problem — they only capture traffic from the moment they're turned on.

### 9.3 Reading WAF metrics

WAF publishes counts to CloudWatch for allowed requests, blocked requests, and counted (would-have-blocked) requests, broken down per rule. The key habits:

- **Watch the Count metrics** — when testing a new rule in Count mode, these show what it WOULD block, so you can catch false positives before going live.
- **Watch the Blocked metrics** — a sudden spike can mean an attack in progress — or a new rule mistakenly blocking real users.
- **Sample the blocked requests** — WAF lets you view a sample of blocked requests so you can confirm they really are malicious.

### 9.4 Alarms a support team should configure

1. A spike in WAF Blocked requests — possible attack or a misfiring rule; investigate.
2. A spike in VPC Flow Log REJECTs to a resource — possible scanning, or a broken rule blocking legitimate traffic.
3. Shield DDoS-detected notifications (especially with Shield Advanced) — an attack is underway.
4. Any change to a Security Group or NACL via CloudTrail — know immediately when rules are edited, intentionally or not.
5. Unusual outbound traffic in Flow Logs — a server "phoning home" can indicate a compromise.

> **✅ BEST PRACTICE — Turn on logging before you need it**
> Flow Logs, WAF logs, and CloudTrail only record events that happen AFTER you enable them. The time to switch them on is now — during calm operations — not during an incident, when the evidence you need has already passed. Treat enabling logs as part of building the system, not a later add-on.

---

## 10. Best-Practices Checklist

A consolidated checklist your team can use as a pre-launch review. Confirm each item before exposing a system to real traffic.

### 10.1 Security Groups

- [ ] Every group and rule has a clear description explaining its purpose.
- [ ] Rules reference other Security Groups instead of IP addresses wherever traffic is between your own resources.
- [ ] No sensitive port (22, 3389, 3306, 5432) is open to `0.0.0.0/0`.
- [ ] Admin access goes through a bastion or Session Manager, not a wide-open SSH/RDP port.
- [ ] Groups are small and single-purpose (`sg-alb`, `sg-app`, `sg-db`), not one catch-all group.
- [ ] Outbound rules are tightened for high-security workloads (egress filtering).
- [ ] The default Security Group is not relied upon for real access control.

### 10.2 Network ACLs

- [ ] Custom NACLs include explicit rules for ephemeral ports (1024–65535) for return traffic.
- [ ] Specific DENY rules use low numbers; broad ALLOW rules use higher numbers.
- [ ] Rule numbers are spaced (100, 110, 120…) to allow easy insertion later.
- [ ] NACLs are used for broad backstops and blanket blocks — not as a replacement for Security Groups.
- [ ] Sensitive subnets (e.g., database) have a NACL that denies internet traffic as a safety net.

### 10.3 AWS WAF

- [ ] A Web ACL is attached to every public ALB, CloudFront distribution, or API Gateway.
- [ ] AWS Managed Rules (common threats, known bad inputs) are enabled.
- [ ] SQL-injection and cross-site-scripting rules are active for apps that take user input.
- [ ] A rate-based rule throttles flooding from any single IP.
- [ ] New rules are tested in Count mode before being set to Block.
- [ ] WAF logging is enabled and reviewed.

### 10.4 AWS Shield

- [ ] You understand that Shield Standard is already protecting you for free.
- [ ] High-profile or revenue-critical apps have evaluated Shield Advanced for cost protection and expert support.
- [ ] Public traffic is served through CloudFront/Route 53 where possible to leverage the AWS edge.
- [ ] The architecture can scale to absorb bursts (auto scaling, multi-AZ load balancing).

### 10.5 Across all layers

- [ ] VPC Flow Logs, WAF logs, and CloudTrail are all enabled and stored.
- [ ] Alarms exist for blocked-request spikes, REJECT spikes, DDoS detection, and rule changes.
- [ ] Every layer follows least privilege: allow only what's needed, deny everything else.
- [ ] Rules are reviewed periodically and stale ones removed.

---

## 11. Troubleshooting Guide

A symptom-to-cause reference for the support team. Most network-security incidents fall into a handful of patterns; check these first.

### 11.1 Common symptoms and likely causes

| Symptom | Most likely causes | First things to check |
|---------|--------------------|-----------------------|
| Connection refused / times out immediately | Security Group doesn't allow that port/source; resource not listening | Check the resource's inbound SG rule for the right port and source; confirm the app is running |
| Connection starts but never completes (hangs) | Stateless NACL missing ephemeral-port return rule | Add inbound/outbound NACL rules for 1024–65535 return traffic |
| Works from inside the VPC but not the internet | NACL or SG blocking the public source; resource in a private subnet | Verify public subnet, internet gateway, and an SG rule allowing `0.0.0.0/0` on the listener port |
| Traffic blocked despite an allow rule (NACL) | A lower-numbered DENY rule matches first | Remember first-match-wins; check rule numbers — specific DENYs should not sit above needed ALLOWs by accident |
| Legitimate users suddenly blocked | A new WAF rule causing false positives | Check WAF blocked-request samples; switch the rule to Count mode and retune |
| Site slow or down under heavy traffic | DDoS attack, or no rate limiting | Check Shield metrics; add/verify WAF rate-based rules; ensure scaling is working |
| Can't SSH/RDP to a server | Port 22/3389 not allowed from your IP; using wide-open is unsafe anyway | Allow your specific `/32` or use a bastion/Session Manager; never open to `0.0.0.0/0` |
| Two servers in same subnet behave differently | They have different Security Groups | Compare each resource's attached SGs — SGs are per-resource, not per-subnet |
| Rule change didn't take effect | Edited the wrong group, or change not saved/propagated | Confirm via CloudTrail which group changed; verify the resource's attached groups |

### 11.2 A simple triage order

1. Reproduce and note the exact source IP, destination, and port — precise details narrow the cause fast.
2. Check VPC Flow Logs for an ACCEPT or REJECT — a REJECT names the blocking layer; no entry means traffic never arrived.
3. Check the resource's Security Groups first — they do most of the work and cause most blocks.
4. If the connection hangs rather than refuses, suspect a stateless NACL missing ephemeral-port rules.
5. For web-layer blocks (403s on specific requests), check WAF — view the blocked-request sample.
6. For slowness or outages under load, check Shield and WAF rate-limiting metrics.
7. Use CloudTrail to see if a recent rule change caused the problem.

> **✅ BEST PRACTICE — Layer-by-layer, outside in**
> When stuck, walk the four layers in order: Is Shield seeing an attack? Is WAF blocking the request? Is a NACL denying it at the subnet edge? Is a Security Group refusing it at the resource? Identify the first layer that says "no" and you've found your answer. The logs from Chapter 9 make this walk quick.

---

## 12. Quick Reference and Glossary

### 12.1 Which control for which job

| I want to… | Use this control | How |
|-----------|------------------|-----|
| Allow my load balancer to reach my app servers | Security Group | `sg-app` inbound: allow app port from `sg-alb` |
| Stop the whole internet from reaching my database | Security Group (+ NACL backstop) | `sg-db` inbound: allow DB port only from `sg-app` |
| Blanket-block a known malicious IP range | Network ACL | Low-numbered DENY rule for that CIDR |
| Block SQL injection in a login form | AWS WAF | Enable the SQL-injection managed rule |
| Throttle an IP sending too many requests | AWS WAF | Rate-based rule |
| Block traffic from a specific country | AWS WAF | Geo-match rule |
| Survive a traffic flood (DDoS) | AWS Shield | Standard is automatic; Advanced for high risk |
| Give admins safe server access | Security Group | Allow 22/3389 from a bastion SG or office `/32` only |
| See why a connection was blocked | VPC Flow Logs | Look for the REJECT entry |
| See who changed a rule | AWS CloudTrail | Review the audit event |

### 12.2 Stateful vs stateless at a glance

| | Security Group | Network ACL |
|---|----------------|-------------|
| Memory of connections | Yes (stateful) | No (stateless) |
| Return traffic | Auto-allowed | Needs its own rule (ephemeral ports!) |
| Rules | Allow only | Allow and deny |
| Scope | Per resource | Per subnet |
| Order matters | No | Yes (lowest number first) |

### 12.3 Common ports to recognize

| Port | Service | Note |
|------|---------|------|
| 22 | SSH | Admin access — never open to `0.0.0.0/0` |
| 3389 | RDP | Windows admin — never open to `0.0.0.0/0` |
| 80 | HTTP | Usually redirected to 443 |
| 443 | HTTPS | Encrypted web traffic |
| 3306 | MySQL / MariaDB | Database — private only |
| 5432 | PostgreSQL | Database — private only |
| 1024–65535 | Ephemeral ports | Return-traffic range — allow on custom NACLs |

### 12.4 Glossary

| Term | Meaning |
|------|---------|
| **Bastion host** | A hardened jump server you connect to first, then hop to private servers — avoids exposing admin ports to the internet. |
| **CIDR** | A compact way to write a range of IP addresses, e.g., `10.0.0.0/16`; `/32` means a single address. |
| **CloudFront** | AWS's content delivery network (CDN); a common place to attach WAF and benefit from Shield at the edge. |
| **CloudTrail** | AWS's audit log of who did what and when — including security-rule changes. |
| **DDoS** | Distributed Denial of Service — a flood of traffic from many sources meant to knock you offline. Defended by Shield. |
| **Egress filtering** | Restricting OUTBOUND traffic so a compromised resource can't send data out freely. |
| **Ephemeral ports** | Temporary high-numbered ports (commonly 1024–65535) used for return traffic; must be allowed on stateless NACLs. |
| **ENI** | Elastic Network Interface — the virtual network card a Security Group attaches to. |
| **Ingress / Egress** | Inbound traffic / outbound traffic. |
| **Least privilege** | Grant only the access truly needed, and deny everything else — the core security principle. |
| **NACL** | Network ACL — a stateless, subnet-level firewall with allow and deny rules. |
| **Rate-based rule** | A WAF rule that blocks an IP exceeding a request threshold in a time window. |
| **Rule group (WAF)** | A reusable bundle of WAF rules; managed ones are maintained by AWS or vendors. |
| **Security Group** | A stateful, allow-only virtual firewall attached to a resource. |
| **Shield (Standard/Advanced)** | AWS's DDoS protection; Standard is free and automatic, Advanced is a paid upgrade. |
| **SQL injection** | An attack that sends database commands through input fields; blocked by WAF. |
| **Stateful** | Remembers connections, so replies are auto-allowed (Security Groups). |
| **Stateless** | No memory of connections; both directions must be allowed explicitly (NACLs). |
| **VPC Flow Logs** | Records of accepted/rejected connections — the key tool for diagnosing SG/NACL blocks. |
| **WAF** | Web Application Firewall — inspects HTTP/HTTPS request content to block web attacks. |
| **Web ACL** | The top-level WAF container you attach to a resource; holds rules and a default action. |
| **XSS** | Cross-site scripting — injecting malicious scripts into web pages; blocked by WAF. |

---

*End of guide.*
