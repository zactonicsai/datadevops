# AWS Route 53 & DNS — The Complete Tutorial
### Understand, Configure, and Troubleshoot Public & Private Zones (with CNAME deep-dive and tracing)

---

## Part 1: Quick Step-by-Step Setup Example (Do This First!)

Before all the theory, let's actually build something. We'll set up **one real example**: a website called `example.com` hosted on AWS, with a **public zone** (so the whole internet can find it) and a **private zone** (so servers inside your AWS network can talk to each other with friendly names).

### Step 1 — Register or bring a domain
1. Open the **AWS Console** → search for **Route 53**.
2. In the left menu, click **Registered domains** → **Register domain**.
3. Type `example.com` (use your own name — must be available), pick it, pay the yearly fee (a `.com` is about $14/year).
4. AWS automatically creates a **public hosted zone** for you when registration finishes.

> Already own a domain at GoDaddy/Namecheap? Skip registration. Just create a hosted zone (Step 2) and then copy the 4 **NS (name server)** values Route 53 gives you into your registrar's "custom nameservers" setting.

### Step 2 — Create the Public Hosted Zone (if not auto-created)
1. Route 53 → **Hosted zones** → **Create hosted zone**.
2. Domain name: `example.com`
3. Type: **Public hosted zone** → Create.
4. Notice two records appear automatically:
   - **NS record** — the 4 Amazon name servers that answer for your domain.
   - **SOA record** — "Start of Authority," basic info about who manages the zone.

### Step 3 — Point your domain at your website
Say your website runs behind an **Application Load Balancer (ALB)**:
1. Click **Create record**.
2. Record name: leave blank (this means the "root" — `example.com` itself).
3. Record type: **A**.
4. Toggle **Alias** = ON.
5. Route traffic to: **Alias to Application and Classic Load Balancer** → pick your region → pick your ALB.
6. Routing policy: **Simple** → Create.

Now add `www`:
1. **Create record** → Record name: `www`.
2. Type: **CNAME** → Value: `example.com` (or use another Alias A record — more on this choice later).
3. TTL: `300` seconds → Create.

### Step 4 — Create the Private Hosted Zone
1. **Hosted zones** → **Create hosted zone**.
2. Domain name: `internal.example.com` (or even `example.com` again — private zones can overlap!).
3. Type: **Private hosted zone**.
4. **Associate a VPC**: pick your region + your VPC ID → Create.
5. Add a record: name `db`, type **A**, value `10.0.2.15` (your database server's private IP).

Now any EC2 instance **inside that VPC** can reach the database at `db.internal.example.com` — but nobody on the public internet can even see that this name exists.

### Step 5 — Make sure the VPC can actually use it
Private zones only work if the VPC has these two settings ON (VPC console → your VPC → **Edit VPC settings**):
- ✅ **enableDnsSupport** (DNS resolution)
- ✅ **enableDnsHostnames**

### Step 6 — Test it
From your laptop (public zone):
```bash
dig example.com
dig www.example.com
```
From an EC2 instance inside the VPC (private zone):
```bash
dig db.internal.example.com
```
You should get your IPs back. 🎉 That's a working setup. Now let's understand *everything* underneath it.

---

## Part 2: Background — What Is DNS, Really?

### The phone book analogy
Computers find each other using **IP addresses** (like `54.23.10.8`), which are like phone numbers. Humans prefer **names** (like `example.com`). **DNS (Domain Name System)** is the giant, worldwide phone book that translates names into numbers.

### How a DNS lookup actually works (the journey of one question)
When you type `www.example.com` into a browser:

1. **Your computer checks its own cache** — "Did I look this up recently?"
2. If not, it asks a **recursive resolver** (usually your ISP's, or `8.8.8.8` Google, or `1.1.1.1` Cloudflare, or inside AWS: the **VPC resolver** at your-VPC-base+2, e.g. `10.0.0.2`, also reachable at `169.254.169.253`).
3. The resolver asks a **root name server** (there are 13 logical ones, named `a.` through `m.root-servers.net`): "Who handles `.com`?"
4. Root replies: "Ask the **.com TLD servers**."
5. Resolver asks the .com TLD servers: "Who handles `example.com`?"
6. TLD replies: "Ask these 4 Amazon Route 53 name servers" (the NS records set at your registrar).
7. Resolver asks Route 53: "What's the A record for `www.example.com`?"
8. Route 53 answers with the IP. The resolver **caches** the answer for the **TTL** (time to live) and hands it back to your browser.

### Key vocabulary
| Term | Meaning |
|---|---|
| **Domain** | The name you own, e.g. `example.com` |
| **Subdomain** | A name under it, e.g. `www.example.com`, `api.example.com` |
| **Zone** | The container holding all DNS records for a domain |
| **Record (RRset)** | One entry: a name + type + value(s) + TTL |
| **TTL** | How many seconds resolvers may cache the answer |
| **Authoritative server** | The server that holds the *official* answer (Route 53 for your zone) |
| **Recursive resolver** | The middleman that does the lookup journey for you |
| **Apex / root / naked domain** | `example.com` itself, with no subdomain in front |
| **FQDN** | Fully Qualified Domain Name — the complete name ending in an (invisible) dot: `www.example.com.` |

### Why Route 53 is called that
DNS traffic uses **port 53** (UDP mostly, TCP for big answers and zone transfers). "Route" + "53" = Route 53. It's also a nod to Route 66. Route 53 is AWS's managed DNS service and offers a **100% availability SLA** — the only AWS service with one.

---

## Part 3: Public vs Private Hosted Zones

### Public hosted zone
- Answers queries from **anyone on the internet**.
- Requires your registrar's NS delegation to point at the 4 Route 53 name servers assigned to your zone.
- Used for: websites, public APIs, email routing (MX), domain verification (TXT).

### Private hosted zone
- Answers queries **only from VPCs you explicitly associate** (and from on-prem networks via Resolver endpoints — see Part 8).
- **Invisible to the internet.** No registrar delegation needed at all.
- Can use **any name you want**, even names you don't own (e.g. `corp.internal`) — though best practice is to use a subdomain of a domain you do own to avoid future collisions.
- Used for: microservice discovery, internal databases, hybrid-cloud naming.

### Split-horizon (split-view) DNS — a superpower
You can create a **public zone AND a private zone with the same name** (`example.com`). Then:
- Internet users asking for `app.example.com` get the **public answer** (say, your load balancer).
- EC2 instances in the associated VPC asking the same question get the **private answer** (say, an internal IP).

The VPC resolver always **prefers the private zone** when the VPC is associated with it.

⚠️ **Gotcha:** If a name exists only in your *public* zone but the VPC is associated with a *private* zone of the same domain, instances in the VPC **cannot resolve the public-only name** — the private zone "shadows" the whole domain. Duplicate needed records into the private zone.

### Comparison table
| Feature | Public zone | Private zone |
|---|---|---|
| Who can query | Everyone | Associated VPCs only |
| Registrar NS delegation | Required | Not used |
| Cost | $0.50/zone/month + queries | $0.50/zone/month; **queries free** from VPCs |
| Name ownership needed | Yes (practically) | No |
| Health-check routing | Full support | Supported (with some limits) |
| DNSSEC signing | Supported | Not supported |

---

## Part 4: Every Record Type Explained

| Type | What it does | Example value |
|---|---|---|
| **A** | Name → IPv4 address | `192.0.2.44` |
| **AAAA** | Name → IPv6 address | `2001:db8::1` |
| **CNAME** | Name → another name (an alias) | `example.com` |
| **Alias** (Route 53 special) | Name → AWS resource or another record in the zone | ALB, CloudFront, S3… |
| **MX** | Where email for the domain goes | `10 mail.example.com` |
| **TXT** | Free text; used for verification, SPF, DKIM, DMARC | `"v=spf1 include:amazonses.com ~all"` |
| **NS** | Which name servers are authoritative | `ns-123.awsdns-45.com` |
| **SOA** | Zone metadata (admin, refresh timers, negative-cache TTL) | auto-created |
| **SRV** | Service location: priority weight port target | `1 10 5269 xmpp.example.com` |
| **PTR** | Reverse: IP → name (lives in special `in-addr.arpa` zones) | `host.example.com` |
| **CAA** | Which Certificate Authorities may issue TLS certs for you | `0 issue "amazon.com"` |
| **DS** | DNSSEC delegation signer (chains trust to parent zone) | hash of your key |
| **NAPTR** | Rules for rewriting names (telephony/SIP) | rarely used |
| **HTTPS / SVCB** | Modern service binding hints for browsers | supported in Route 53 |

### CNAME — the full deep-dive (you asked!)

**What a CNAME is:** "Canonical Name." It says *"this name is just a nickname — the real (canonical) name is over there."* When a resolver hits a CNAME, it restarts the lookup with the new name.

```
www.example.com.   300   IN   CNAME   webserver.example.com.
webserver.example.com. 300 IN A       192.0.2.44
```
Query `www.example.com` → resolver sees the CNAME → looks up `webserver.example.com` → gets `192.0.2.44`.

**The iron rules of CNAME:**
1. 🚫 **You cannot put a CNAME at the zone apex.** `example.com` itself can never be a CNAME. Why? The apex *must* have SOA and NS records, and the DNS standard (RFC 1034) says a CNAME cannot coexist with *any* other record at the same name.
2. 🚫 A name that has a CNAME can have **no other record types** (no simultaneous MX, TXT, etc. at that exact name).
3. 🚫 Don't point MX or NS records **at** a CNAME target (violates standards; breaks some mail servers).
4. ✅ CNAMEs may point outside your zone, outside Route 53, anywhere: `shop.example.com → shops.myshopify.com` is fine.
5. ⚠️ CNAME chains (CNAME → CNAME → A) work but add latency; keep chains short.
6. 💰 In Route 53, a query that hits a CNAME **is billed**, and if it points to another Route 53 name, the follow-up query is billed too.

**Alias records — Amazon's answer to CNAME's limits:**
An **Alias** is a Route-53-only extension. It looks like an A/AAAA record to the outside world, but inside Route 53 it dynamically resolves to an AWS resource.

| | CNAME | Alias |
|---|---|---|
| Works at zone apex (`example.com`) | ❌ No | ✅ Yes |
| Can point to | Any DNS name anywhere | AWS resources + records *in the same zone* |
| Visible to resolvers as | CNAME record | Plain A/AAAA answer |
| Query cost | Charged | **Free** when target is an AWS resource |
| TTL control | You set it | Inherited from the target resource |
| Tracks target IP changes | Only by re-resolving | Automatic (ALB/CloudFront IPs change constantly!) |
| Health "evaluate target health" | ❌ | ✅ Optional checkbox |

**Alias targets include:** ALB/NLB/Classic ELB, CloudFront distributions, API Gateway, S3 static-website endpoints, Elastic Beanstalk, Global Accelerator, VPC interface endpoints, App Runner, AppSync, and **another record in the same hosted zone**.

**Best practice:** Inside AWS, use **Alias** whenever the target is an AWS resource. Use **CNAME** only when pointing at names *outside* AWS (SaaS vendors, verification targets like ACM certificate validation CNAMEs, etc.).

### TTL — small but mighty
- **Low TTL (30–60s):** changes take effect fast; more queries (more cost, more resolver load). Use before planned migrations.
- **High TTL (1–24h):** cheap and fast for users; slow to change. Use for stable records.
- **Pro tip:** Lower the TTL a day *before* a migration, migrate, verify, then raise it again.
- Negative answers (NXDOMAIN) are cached using the SOA's minimum TTL — Route 53 default 300s (SOA TTL is 900s).

---

## Part 5: Routing Policies — All the Options

Every record gets a **routing policy** deciding *how* Route 53 answers when multiple records share a name.

| Policy | What it does | Best for | Cons |
|---|---|---|---|
| **Simple** | One record, returns all values in random order | Single resource | No health checks |
| **Weighted** | Split traffic by weights (e.g. 90/10) | Blue-green & canary deploys, A/B tests | Resolver caching makes splits approximate |
| **Latency-based** | Answers with the region lowest-latency to the user | Multi-region apps | Based on measured network latency, not geography |
| **Failover** | Primary answer; switches to secondary when health check fails | Active-passive DR | Needs health checks; failover takes TTL + check time |
| **Geolocation** | Answer based on user's country/continent/US state | Legal compliance, localized content | Users on VPNs get "wrong" answers; set a **Default** record! |
| **Geoproximity** | Answer based on distance to resources, with a **bias** dial to shift traffic | Gradually shifting load between regions | Historically tied to Traffic Flow; more complex |
| **Multivalue answer** | Returns up to 8 healthy records; client picks one | Poor-man's load balancing with health checks | Not a real load balancer |
| **IP-based** | You map client CIDR blocks to answers | ISP-specific routing, known corporate ranges | You must know client IP ranges |

**Health checks** (used by failover/multivalue/weighted+):
- Types: endpoint (HTTP/HTTPS/TCP), **calculated** (combine other checks with AND/OR), **CloudWatch alarm** (great for private resources, since Route 53 checkers live on the public internet and can't see inside your VPC).
- Checkers probe from multiple global locations; default = healthy if ≥18% of checkers succeed, checked every 30s (10s fast option).
- ⚠️ Health checks **cannot directly probe private IPs** — use a CloudWatch-alarm-based check for private zone failover.

**Traffic Flow:** a visual editor that chains policies into a decision tree (geo → latency → weighted → failover) and versions it. Costs $50/policy record/month — powerful but pricey.

---

## Part 6: How DNS Works *Inside* a VPC (Private Resolution Details)

- Every VPC has a built-in resolver: the **Amazon Route 53 Resolver** (a.k.a. "AmazonProvidedDNS"), at **VPC CIDR base + 2** (e.g., `10.0.0.2` for `10.0.0.0/16`) and at `169.254.169.253`.
- Resolution order for a query from an EC2 instance:
  1. **Resolver rules** (forwarding rules — see Part 8)
  2. **Private hosted zones** associated with the VPC
  3. **VPC internal names** (e.g., `ip-10-0-2-15.ec2.internal`)
  4. **Public DNS** (the internet)
- DHCP option sets control which DNS server instances use; default is AmazonProvidedDNS.
- Limits worth knowing: 1,024 packets/second per network interface to the resolver (a real bottleneck for chatty apps — cache locally or raise via Resolver endpoints).

---

## Part 7: Troubleshooting & Tracing — The Practical Toolkit

### Tool 1: `dig` (the gold standard)
```bash
# Basic lookup
dig www.example.com

# Ask a specific server (bypass your cache)
dig www.example.com @8.8.8.8

# Ask Route 53's name server directly (authoritative answer)
dig www.example.com @ns-123.awsdns-45.com

# Query a specific record type
dig example.com MX
dig example.com TXT
dig example.com NS

# Short answer only
dig +short www.example.com

# 🔎 TRACE the full delegation path: root → .com → your NS → answer
dig +trace www.example.com
```
**Reading `dig +trace`:** you'll see the root servers' referral, then the `.com` TLD referral, then your zone's NS records, then the final answer. If the trace dies at the TLD step, your **registrar delegation (NS records) is wrong** — the #1 Route 53 setup mistake.

**Reading a normal `dig` answer:**
- `status: NOERROR` — name exists, answer returned.
- `status: NXDOMAIN` — name does not exist (typo? wrong zone? shadowed by a private zone?).
- `status: SERVFAIL` — the resolver failed (often DNSSEC breakage or unreachable NS).
- `ANSWER SECTION` — the records; the number after the name is the **remaining TTL** (watch it count down on repeated queries = you're hitting cache).
- `flags: aa` — authoritative answer (you asked the real source).

### Tool 2: `nslookup` (available everywhere, including Windows)
```bash
nslookup www.example.com
nslookup www.example.com 8.8.8.8
nslookup -type=MX example.com
```

### Tool 3: `traceroute` / `tracert` (the network path, not DNS — but you asked!)
DNS tells you *where* to go; traceroute shows the *road*:
```bash
# Linux/macOS
traceroute example.com          # UDP probes by default
traceroute -I example.com       # ICMP probes (often gets further)
traceroute -T -p 443 example.com# TCP to port 443 (best through firewalls)

# Windows
tracert example.com

# Modern combo tool (continuous trace + loss stats)
mtr example.com
```
**How it works:** it sends packets with TTL=1, 2, 3… Each router that decrements TTL to zero sends back "time exceeded," revealing itself hop by hop. `* * *` rows mean a router silently drops the probes (common, not necessarily a problem if later hops respond).

**DNS + traceroute workflow for "site is down":**
1. `dig site.example.com` — does DNS even resolve? To the IP you expect?
2. `dig site.example.com @ns-xxx.awsdns-yy.com` — does the authoritative answer differ from cached? (propagation issue)
3. `ping <ip>` / `traceroute <ip>` — is the network path alive? Where does it stop?
4. `curl -v https://site.example.com` — does the app answer? (TLS/app layer)

### Route 53–specific troubleshooting checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| Public domain doesn't resolve at all | Registrar NS ≠ hosted zone NS | Copy the zone's 4 NS values to the registrar; verify with `dig NS example.com +trace` |
| Resolves for some people, not others | TTL caching during a change | Wait out old TTL; check with `dig @authoritative-ns` |
| Works on internet, fails inside VPC | Private zone with same name shadows public records | Add the record to the private zone too |
| Private name won't resolve in VPC | VPC not associated / DNS attrs off / wrong DHCP options | Associate VPC to zone; enable enableDnsSupport + enableDnsHostnames |
| `SERVFAIL` after enabling DNSSEC | Broken DS record or KSK issue | Verify DS at registrar matches; use `dig +dnssec` |
| CNAME at apex rejected | DNS standard forbids it | Use an **Alias A** record instead |
| Failover never fails over | Health check misconfigured or checking private IP | Health checkers need public reachability; use CloudWatch-alarm checks for private |
| Intermittent resolution failures on busy instance | 1024 pps resolver limit per ENI | Add local caching (systemd-resolved/dnsmasq) |
| Changes not appearing | Editing wrong zone (duplicate zones!) | `dig NS` the domain, match server names to the zone you're editing |

**Extra tracing aids:**
- **Route 53 Resolver Query Logs** → send every DNS query from your VPCs to CloudWatch Logs/S3/Kinesis — see exactly what instances are asking and what answers they got.
- **Public DNS query logging** (per public hosted zone → CloudWatch Logs) — see what the world asks your zone.
- `whois example.com` — check registrar, expiry, and delegated NS.
- Online propagation checkers (e.g., dnschecker.org) — view answers from resolvers worldwide.

---

## Part 8: Hybrid DNS — Route 53 Resolver Endpoints

Connecting AWS DNS with an on-premises datacenter (VPN/Direct Connect):

- **Inbound endpoint:** gives your on-prem servers IP addresses *inside the VPC* they can query → on-prem can resolve your **private hosted zones**.
- **Outbound endpoint + forwarding rules:** lets VPC instances forward chosen domains (e.g., `corp.local`) to your **on-prem DNS servers**.
- **Rule types:** *Forward* (send `corp.local` to these IPs) and *System* (override: resolve normally). Rules can be **shared across accounts** via AWS RAM.
- Cost note: endpoints bill per ENI-hour (~$0.125/hr each, min 2 ENIs recommended per endpoint) — it adds up; centralize in a shared-services VPC.
- **Route 53 Profiles** (newer feature): bundle private zones + rules + DNS Firewall settings and attach the whole profile to many VPCs/accounts at once — the modern best practice for large orgs.

**Route 53 Resolver DNS Firewall:** block/allow domain lists applied to VPC resolver traffic (stops malware calling home via DNS). Managed AWS threat lists available.

---

## Part 9: Security & DNSSEC

- **DNSSEC** cryptographically signs your public zone so resolvers can verify answers weren't forged (stops cache-poisoning). Route 53 supports signing with a KMS key; you then add a **DS record** at your registrar. ⚠️ Get the DS wrong and your whole domain SERVFAILs — enable carefully, monitor, and know how to roll back.
- Not available for private zones (not needed — traffic never crosses the internet).
- **IAM**: lock down `route53:ChangeResourceRecordSets`; you can scope permissions per zone.
- **CAA records**: publish which CAs may issue certs (`0 issue "amazon.com"` if you only use ACM).

---

## Part 10: Best Practices Summary

1. **Alias over CNAME** for AWS targets (free, apex-capable, auto-tracking).
2. **Never leave registrar NS mismatched** — verify with `dig +trace` after any zone recreation (recreated zones get *new* NS values!).
3. **Use split-horizon deliberately**, and remember private zones shadow same-named public records.
4. **Lower TTLs before migrations**, raise after.
5. **Use a subdomain you own for private zones** (`internal.example.com`, not `.local` — mDNS conflicts).
6. **Enable Resolver query logging** in production VPCs — invaluable for debugging and security.
7. **Health checks for anything with failover**; CloudWatch-alarm checks for private resources.
8. **Tag and document zones**; delete unused ones (attackers exploit dangling records — see next).
9. **Beware dangling DNS:** if a record points at a deleted resource (old ELB name, released Elastic IP), someone else may claim it = **subdomain takeover**. Clean up records when tearing down infrastructure.
10. **Infrastructure as Code** (CloudFormation/Terraform/CDK) for zones and records — reviewable, repeatable, no console typos.
11. **Multi-account orgs:** central networking account owns zones; share via Resolver rules/Profiles + cross-account zone association (CLI/API only for association authorization).

---

## Part 11: Pricing Cheat Sheet (approximate, us-east-1)

| Item | Price |
|---|---|
| Hosted zone (public or private) | $0.50/month (first 25), then $0.10 |
| Standard queries | $0.40 per million (drops after 1B) |
| Latency/Geo/Geoproximity queries | $0.60–$0.70 per million |
| Alias to AWS resources | **Free** |
| Private zone queries from VPCs | **Free** |
| Health check (AWS endpoint) | $0.50/month (+$1 non-AWS; + optional features) |
| Resolver endpoint ENI | ~$0.125/hour each |
| Resolver queries via endpoints | $0.40 per million |
| Traffic Flow policy record | $50/month |
| DNSSEC | No extra Route 53 fee (KMS key ~$1/month + usage) |
| .com registration | ~$14/year |

---

## Part 12: Quick Reference Commands

```bash
# What are my zone's real name servers?
aws route53 get-hosted-zone --id Z123EXAMPLE

# List all records in a zone
aws route53 list-resource-record-sets --hosted-zone-id Z123EXAMPLE

# Create/update a record from CLI (UPSERT)
aws route53 change-resource-record-sets --hosted-zone-id Z123EXAMPLE \
  --change-batch '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
    "Name":"api.example.com","Type":"A","TTL":300,
    "ResourceRecords":[{"Value":"192.0.2.10"}]}}]}'

# Check change propagation to Route 53 servers (INSYNC = done)
aws route53 get-change --id /change/C123EXAMPLE

# Test what a VPC's resolver returns (run on an EC2 instance)
dig db.internal.example.com @169.254.169.253

# Full public delegation trace
dig +trace www.example.com

# Compare cached vs authoritative
dig www.example.com; dig www.example.com @ns-123.awsdns-45.com
```

---

## The One-Paragraph Recap
Route 53 is AWS's DNS phone book. **Public zones** answer the internet and need your registrar's NS records pointed at Amazon's name servers; **private zones** answer only associated VPCs and can shadow public names (split-horizon). Use **Alias records** for AWS targets (they beat CNAMEs at the apex, cost nothing, and track changing IPs) and **CNAMEs** for external names — never at the apex. Pick a **routing policy** (simple, weighted, latency, failover, geo…) per record, attach **health checks** for failover, and troubleshoot with `dig` (add `+trace` to walk the delegation), `nslookup`, `traceroute`/`mtr` for the network path, and **Resolver query logs** to see exactly what your VPCs are asking.
