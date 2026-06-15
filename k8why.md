# Kubernetes on AWS — For a Private, Internal-Only Business Network

**Application profile:** ~100,000 total registered users (employees / internal users), **not** concurrent. Realistic peak is a few hundred to low thousands of requests per second. **The app is internal-only — it lives entirely inside the company’s AWS private network boundary and is never exposed to the public internet.**

**Why “internal-only” changes everything below:** When an app is private, the whole question shifts from public-facing concerns (CDNs, edge, public load balancers, DDoS, marketing front ends) to **network isolation, controlled access, and east-west traffic inside a VPC**. So this version:

- Maps every option to its **specific AWS service**.
- Adds an AWS **private-network architecture** section (VPC, subnets, endpoints, access paths).
- Drops approaches that only make sense for public/global apps (public edge, Jamstack/CDN front ends).
- Reframes **security** around the network boundary, not the public internet.

**How this document is organized:**

1. The nine goals (the yardstick)
1. The AWS private-network boundary (the foundation everything sits inside)
1. **Kubernetes on AWS (EKS) in depth** — what it is, its parts, private-cluster specifics, and how it scores
1. Why each **AWS alternative** may be better or worse than EKS
1. AWS-specific architecture approaches and their benefits
1. Feature-by-feature difference tables (AWS services)
1. The full scorecard and a decision guide
1. Cross-cutting AWS best practices and a leadership summary

-----

## 1. The Nine Goals, in Plain Language

Before judging Kubernetes or anything else, the team should agree on what “good” means. Think of these like qualities you’d want in a car before comparing engines.

|Goal                 |Middle-school explanation                                               |What “done well” looks like (internal AWS context)                                               |
|---------------------|------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
|**Simplicity**       |How easy to set up and understand? Can one person hold it in their head?|A new teammate deploys on day one without a 3-week course.                                       |
|**Extensibility**    |How easily can you add features, services, or scale later?              |A new internal service doesn’t force a rebuild.                                                  |
|**Maintainability**  |How easy to keep running, patch, and fix over years?                    |Routine updates are boring and safe, not scary.                                                  |
|**Reliability**      |Does it keep working day to day without surprises?                      |Few incidents; predictable behavior for internal users.                                          |
|**Security**         |How well does it keep attackers and mistakes out?                       |App is unreachable from the internet; least-privilege IAM; secrets protected; small blast radius.|
|**Repeatability**    |Can you rebuild the exact same setup automatically?                     |“Infrastructure as code” — destroy the VPC stack and recreate it identically.                    |
|**Fault tolerance**  |If one piece breaks, does the whole thing stay up?                      |One Availability Zone fails, internal users never notice.                                        |
|**Five 9s (99.999%)**|Under ~5 minutes of downtime **per year**.                              |Near-zero outages, even during deploys and AZ failures.                                          |
|**Performance**      |How fast and responsive under load?                                     |Internal pages load quickly even at peak.                                                        |


> **Reality check on “Five 9s”:** 99.999% uptime is genuinely hard and expensive. On AWS it usually requires multi-AZ (and sometimes multi-region) redundancy, automated failover, zero-downtime deploys, and mature on-call. Most internal business apps actually need **three 9s (99.9%, ~8.8 hrs/yr)** or **four 9s (99.99%, ~53 min/yr)**. Be honest about whether five 9s is a real requirement — it changes cost by an order of magnitude, and it’s the single goal that most justifies Kubernetes. For an internal tool, planned maintenance windows are often acceptable, which relaxes this further.

-----

## 2. The AWS Private-Network Boundary (The Foundation)

Everything in this document runs **inside** this boundary. Understanding it first makes the rest obvious. Plain-language analogy: think of a **secure office building**. The VPC is the building, subnets are floors, security groups are door badges for each room, and there is **no public entrance** — staff get in only through the company’s own private corridors (VPN/Direct Connect).

### 2.1 Core building blocks

|AWS piece                       |Office analogy                        |What it does in a private setup                                                             |
|--------------------------------|--------------------------------------|--------------------------------------------------------------------------------------------|
|**VPC** (Virtual Private Cloud) |The whole building                    |Your isolated private network in AWS. Nothing enters unless you allow it.                   |
|**Private subnets**             |Floors with no street exit            |Where the app and database live. **No route to an internet gateway.**                       |
|**Security groups**             |Per-room badge readers                |Stateful firewalls on each resource — allow only the exact ports/sources needed.            |
|**Network ACLs**                |Floor-level guards                    |Optional subnet-wide allow/deny rules for defense in depth.                                 |
|**Internal ALB/NLB**            |The building’s internal reception desk|A load balancer marked **internal** (private IP only) — never public.                       |
|**VPC endpoints (PrivateLink)** |Private internal mail chutes          |Let the app reach AWS services (S3, ECR, Secrets Manager) **without** touching the internet.|
|**VPN / Direct Connect**        |The staff-only corridor from HQ       |How employees and on-prem systems reach the private app securely.                           |
|**Route 53 Private Hosted Zone**|The internal phone directory          |Internal-only DNS names that resolve just inside the VPC.                                   |

### 2.2 The golden rule for internal apps

**No public IPs, no public load balancers, no internet gateway on the app/data subnets.** Outbound access (for patches or AWS APIs) goes through **VPC endpoints** or a tightly controlled **NAT gateway**, and inbound access comes **only** from the corporate network via VPN/Direct Connect. This single discipline delivers most of the *security* goal before you write a line of app code.

### 2.3 Why this matters for the platform choice

Every option below — EKS, ECS/Fargate, Lambda, EC2 — can be deployed **fully privately** on AWS. The differences are in *how much networking you must wire yourself* and *how cleanly each integrates with private endpoints and IAM*. That becomes a major scoring factor that wouldn’t exist for a public app.

-----

## 3. Kubernetes on AWS (Amazon EKS) in Depth

### 3.1 What Kubernetes is (plain language)

Imagine a busy airport. Planes (your app’s containers) are constantly landing, taking off, and being refueled. Something has to direct all that traffic, replace a plane that breaks down, and add more flights when demand spikes. **Kubernetes is that control tower.** It runs many containers across many machines and constantly keeps them healthy: if a container dies, it restarts it; if a whole machine dies, it moves the work elsewhere; if traffic rises, it launches more copies.

On AWS, the managed version is **Amazon EKS** (Elastic Kubernetes Service): AWS runs the control plane (the “control tower” brain), and you run the worker nodes (or let Fargate run them serverlessly). It is extraordinarily powerful — but a control tower is overkill for a single small internal runway, which is the core tension for your use case.

### 3.2 A container, first

A **container** is a sealed box holding your code plus everything it needs to run (libraries, settings), so it behaves identically anywhere. On AWS you store container images privately in **Amazon ECR** (Elastic Container Registry) and pull them through a **VPC endpoint** so the image never travels over the public internet. Kubernetes doesn’t replace containers — it **orchestrates** them.

### 3.3 The main parts of Kubernetes (so the team isn’t lost)

|Part                  |Airport analogy          |What it does                                                                                  |
|----------------------|-------------------------|----------------------------------------------------------------------------------------------|
|**Cluster**           |The whole airport        |All the machines Kubernetes manages, working as one system.                                   |
|**Node**              |A runway/gate            |A single machine (an EC2 instance, or Fargate) that runs your containers.                     |
|**Pod**               |A single parked plane    |The smallest unit Kubernetes runs — one or a few tightly-coupled containers.                  |
|**Deployment**        |The flight schedule      |Declares “I want N copies of this app running” and keeps it true.                             |
|**Service**           |The airport signage      |A stable address so other parts can find your pods even as they come and go.                  |
|**Ingress**           |The arrivals gate        |Routes traffic to the right Service — on EKS, backed by an **internal** ALB for a private app.|
|**ConfigMap / Secret**|The ops manual / the safe|Stores configuration and credentials separately from code.                                    |
|**Control plane**     |The control tower itself |The brain that schedules pods and enforces your declared state — **managed by AWS in EKS**.   |
|**kubectl**           |The radio you talk on    |The command-line tool you use to inspect and change the cluster.                              |

The key idea is **declarative state**: you write what you want (YAML manifests), and Kubernetes continuously makes reality match. That’s why it self-heals.

### 3.4 What “private EKS” specifically means

For an internal-only app, you configure EKS as a **private cluster**:

- **Private API endpoint:** the cluster’s control API is reachable only from inside the VPC (not the public internet).
- **Worker nodes in private subnets:** no public IPs.
- **Internal ALB/NLB via the AWS Load Balancer Controller:** traffic enters only from the corporate network.
- **VPC endpoints for ECR, S3, STS, CloudWatch, Secrets Manager:** image pulls, logging, and secrets all stay on the private network.
- **IAM Roles for Service Accounts (IRSA):** each pod gets least-privilege AWS permissions without shared keys.

This is fully supported — but notice it’s **several extra moving parts** you must wire and maintain. That effort is the heart of the “is EKS worth it?” question.

### 3.5 How EKS scores against the nine goals (internal context)

|Goal           |Score|Why (private AWS context)                                                                                    |
|---------------|-----|-------------------------------------------------------------------------------------------------------------|
|Simplicity     |●○○  |Many moving parts (cluster, nodes, ingress, IRSA, VPC endpoints, add-ons). Steepest learning curve.          |
|Extensibility  |●●●  |Best in class. Run many internal services, operators, any pattern.                                           |
|Maintainability|●●○  |AWS manages the control plane, but you patch nodes/add-ons and own Kubernetes upgrades.                      |
|Reliability    |●●●  |Control plane spans multiple AZs by default; self-healing workloads.                                         |
|Security       |●●○  |Extremely capable (IRSA, network policies, private endpoints) but **easy to misconfigure** without expertise.|
|Repeatability  |●●●  |Manifests + GitOps + Terraform = exact, version-controlled private rebuilds.                                 |
|Fault tolerance|●●●  |Reschedules pods across AZs automatically; designed around failure.                                          |
|Five 9s        |●●●  |The standard choice when five 9s is a *genuine* requirement — *with* the team to run it.                     |
|Performance    |●●●  |Scales horizontally extremely well, with fine-grained CPU/memory control.                                    |

Scoring key: ●●● strong, ●●○ moderate, ●○○ weak.

### 3.6 EKS — pros and cons

**Pros**

- Unmatched scalability and flexibility for complex internal systems.
- Self-healing, automated rollouts/rollbacks, horizontal autoscaling.
- Portable — the same manifests run on other clouds or on-prem (useful if the company is hybrid).
- Enormous ecosystem (Helm, operators, service mesh, observability).
- The right tool when you genuinely need five 9s *and* many services.

**Cons**

- Steepest learning curve and highest operational complexity of any AWS option.
- Needs dedicated DevOps/SRE expertise to run safely.
- Higher baseline cost: control plane hourly fee + nodes + tooling + **people**.
- Private networking, IRSA, and add-ons are all extra surfaces to misconfigure.
- Overkill for a single small internal app.

### 3.7 EKS — troubleshooting

Work top-down: `kubectl get pods` → `kubectl describe pod <name>` → `kubectl logs <name>`.

|Symptom                         |Likely cause (private AWS)                                    |Fix                                                                                   |
|--------------------------------|--------------------------------------------------------------|--------------------------------------------------------------------------------------|
|Pod stuck `Pending`             |Not enough node capacity, or no free IPs in the private subnet|Scale the node group; size subnets with enough IP space (a common private-VPC gotcha).|
|`CrashLoopBackOff`              |App keeps crashing on start                                   |Check `kubectl logs`; usually bad config, missing env var, or a failing dependency.   |
|`ImagePullBackOff`              |Missing **ECR VPC endpoint** or wrong IAM permissions         |Add the ECR + S3 endpoints; confirm the node/pod role can pull.                       |
|Service unreachable             |Internal ALB misconfigured, or security group blocks the port |Check the Load Balancer Controller, target group health, and SG rules.                |
|Can’t reach Secrets Manager / S3|No VPC endpoint for that service                              |Create the PrivateLink endpoint; verify the route and SG.                             |
|`OOMKilled`                     |Container exceeded its memory limit                           |Raise limits or fix a memory leak.                                                    |

### 3.8 EKS — best practices (private)

- Use **private API endpoint** and put all nodes in **private subnets**.
- Use **IRSA** for least-privilege pod permissions — never bake AWS keys into images.
- Create **VPC endpoints** for ECR, S3, STS, CloudWatch Logs, and Secrets Manager so nothing leaves the private network.
- Use **GitOps** (Argo CD / Flux) so cluster state is version-controlled and repeatable.
- Set resource **requests and limits** on every workload; enforce **network policies**.
- Spread across **multiple AZs**; use Pod Disruption Budgets for safe maintenance.
- Right-size subnet CIDRs generously — IP exhaustion is a classic private-EKS failure.
- Adopt EKS only when complexity (many internal services, large team, true five-9s) genuinely justifies it.

-----

## 4. Why Each AWS Alternative May Be Better or Worse Than EKS

Each alternative is framed directly against EKS, all assumed deployed **privately** inside the VPC.

### 4.1 Amazon EC2 (single or few instances)

**What it is:** One or a few virtual servers in a private subnet. You SSH in (via a bastion or **SSM Session Manager**, no public IP), install the app, and run it. You are the admin, deployer, and firefighter.

**Better than EKS when:**

- You need something running fast for an internal pilot.
- The team is tiny and wants a dead-simple mental model.
- Budget is minimal.

**Worse than EKS when:**

- You need fault tolerance — a single instance is a single point of failure with no auto-recovery.
- You need smooth scaling — growth means manually adding instances behind an internal load balancer.
- You need repeatability — without scripting (or an Auto Scaling Group + launch template), rebuilds drift.
- Five 9s is required — effectively impossible on one box.

**Bottom line vs EKS:** Simpler and cheaper to start; loses badly on fault tolerance, repeatability, and five 9s. A stepping stone. (Use **SSM Session Manager** instead of a public bastion to keep it truly private.)

### 4.2 AWS App Runner (with VPC connector) — the AWS “PaaS”

**What it is:** AWS’s platform-as-a-service. You hand it a container image (from private ECR) or source, and it builds, runs, load-balances, and auto-scales it. With a **VPC connector**, it reaches private resources (databases, internal services) inside your network.

**Better than EKS when:**

- You want production quality with almost no operational overhead.
- The team is small with no dedicated DevOps/SRE.
- You value fast shipping and a gentle learning curve.

**Worse than EKS when:**

- You need deep low-level control or unusual deployment patterns.
- You require strictly *no* AWS-managed ingress in front (App Runner’s own endpoint can be made private but is less flexible than a hand-built internal ALB).
- You’ll run many tightly-coupled internal services needing orchestration.

**Bottom line vs EKS:** Wins decisively on simplicity and maintainability for a single internal app; loses on fine-grained control and extensibility ceiling. **A strong fit for your scale**, provided its private-networking model meets your boundary rules.

### 4.3 Amazon ECS on AWS Fargate — managed containers, no cluster

**What it is:** You package the app as a container and run it on **ECS with Fargate**, which runs and scales containers in your **private subnets** with **no servers or cluster to manage**. Containers and elasticity without Kubernetes’ orchestration burden — and it’s all native AWS.

**Better than EKS when:**

- You want container benefits (portability, consistency, isolation) without cluster ops.
- You want excellent repeatability and fault tolerance defined as code, with far less surface area.
- You want native, simple integration with internal ALBs, IAM task roles, and VPC endpoints.
- **This is the strongest fit if you want containers and room to grow.**

**Worse than EKS when:**

- You’ll genuinely run *many* interconnected services needing advanced orchestration (service mesh, custom operators).
- You need maximum portability across clouds/on-prem (ECS is AWS-only).
- You want the richest open-source orchestration ecosystem.

**Bottom line vs EKS:** Matches EKS on reliability, fault tolerance, and repeatability for a single internal app, while beating it on simplicity — and it lives privately in your VPC just as cleanly. EKS only pulls ahead at high service count and complexity. **Top recommendation alongside App Runner.**

### 4.4 AWS Lambda (private, in-VPC) — serverless functions

**What it is:** Your code runs **only when called** (an internal API call via private API Gateway, an S3 event, an EventBridge schedule). VPC-attached Lambdas run inside your private subnets and reach internal resources directly. No servers to manage.

**Better than EKS when:**

- Internal workloads are spiky, event-driven, or scheduled (report generation, data jobs, internal webhooks).
- You want to pay nothing when idle.
- Tasks are short and stateless.

**Worse than EKS when:**

- Latency must be consistent — **cold starts** add delay (in-VPC Lambdas have improved here but it’s still a factor).
- Work is long-running or stateful — execution-time, memory, and payload **limits** get in the way.
- Traffic is sustained and heavy — cost can become unpredictable.
- You’re stitching many functions together — distributed debugging is hard.

**Bottom line vs EKS:** Wins on idle cost and burst for internal event-driven work; loses on consistent latency, long/stateful jobs, and predictable cost under steady load. Often used *alongside* a container backend for glue logic.

-----

## 5. AWS-Specific Architecture Approaches and Their Benefits

The options above are *where* you run software. These are the architectural **approaches** that shape *how* the internal app is built — each mapped to AWS and to the private boundary. (Public-only patterns like global edge and CDN-fronted Jamstack are intentionally omitted, since the app is internal.)

### 5.1 Monolith vs. Microservices

This is the single biggest architectural fork, and it largely determines whether EKS is worth it.

**Monolith (plain language):** The whole app is one program; all features deploy as one unit. One big house, every room under one roof.

**Microservices (plain language):** Many small, independent programs that each do one job and talk over the private network. A neighborhood of small houses, each with its own door.

|                   |Monolith                                                                                      |Microservices                                                                                                                           |
|-------------------|----------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
|**Benefits**       |Simple to build, test, deploy, reason about; one codebase; fast for small teams; cheap to run.|Independent scaling/deployment per service; teams work in parallel; one service’s fault needn’t sink the rest; tech freedom per service.|
|**Costs**          |Scales as one block; a big change is riskier; harder for many teams in parallel.              |Private-network complexity, distributed debugging, more infrastructure, operational overhead.                                           |
|**Relation to EKS**|A monolith rarely needs EKS — App Runner or ECS/Fargate runs it beautifully inside the VPC.   |Microservices are the classic *reason* to adopt EKS: it orchestrates many internal services elegantly.                                  |


> **For your use case:** A single internal app for 100k non-concurrent users is almost certainly best as a **monolith** (or “modular monolith” — one deployable unit with clean internal boundaries). That alone removes most of the case for EKS. Split into microservices later only when team size or clear scaling pressure demands it.

### 5.2 Event-Driven Design (Serverless on AWS)

**Plain language:** Instead of servers running all the time, internal events trigger work — a file lands in **S3**, a message hits **SQS/SNS**, a schedule fires in **EventBridge**, and a **Lambda** runs.

**Benefits:** No idle cost, natural fault tolerance (AWS retries), no servers to patch, very fast to ship small internal automations.

**Relation to EKS:** The philosophical opposite — EKS keeps containers running and you manage capacity; event-driven hides that. For internal batch jobs, integrations, and automations, this beats EKS on simplicity and cost.

### 5.3 Serverless Containers (ECS/Fargate) — the lighter “EKS”

**Plain language:** You give AWS a *container* (like EKS uses), but **Fargate** runs and scales it with no cluster (like serverless). Native to AWS, fully private in your subnets.

**Benefits:** Container portability and consistency **plus** no cluster management — often “80% of Kubernetes’ value for 20% of the effort,” with clean private-VPC, IAM, and endpoint integration.

**Relation to EKS:** The most direct lighter alternative. For a single internal app — and many small-to-medium systems — Fargate delivers EKS-level reliability, fault tolerance, and repeatability without the operational tax. **Top recommendation for your scale.**

### 5.4 Internal API Layer (Private API Gateway / Internal ALB)

**Plain language:** A controlled front door *inside* the network that routes internal callers to the app. **API Gateway (private)** or an **internal ALB** sits in front; nothing is exposed publicly.

**Benefits:** Centralized auth, throttling, and routing for internal consumers; clean separation between callers and the backend; works identically whether the backend is Lambda, Fargate, or EKS.

**Relation to EKS:** Complementary. You’d use a private API layer in front of *any* of these backends; it isn’t a reason to pick or avoid EKS.

### 5.5 Managed Data Services (so you don’t run databases yourself)

**Plain language:** Let AWS run the stateful pieces privately — **RDS/Aurora** (relational), **DynamoDB** (key-value, reached via VPC endpoint), **ElastiCache** (in-memory), **S3** (object storage, via endpoint). All can be locked to private subnets.

**Benefits:** Removes the hardest reliability/backup/patching work; multi-AZ options give strong fault tolerance; reduces what you must orchestrate yourself.

**Relation to EKS:** Strongly reduces the case for EKS — if AWS runs your data tier, the compute tier for one app is light enough for Fargate or App Runner.

### 5.6 Hybrid / On-Prem Connectivity

**Plain language:** Connect the AWS private network to the company’s existing data center via **Direct Connect** or **Site-to-Site VPN**, so internal users and on-prem systems reach the app as if it were local.

**Benefits:** Meets data-residency and compliance needs; integrates with existing corporate identity and networks; resilience across environments.

**Relation to EKS:** This is one of Kubernetes’ stronger arguments — its portability suits hybrid estates. But unless there’s a genuine hybrid mandate, the complexity isn’t worth it for a single internal app.

### 5.7 Quick reference — AWS approaches mapped to benefits and fit

|Approach                 |AWS services                         |Standout benefit         |Best for                       |Vs. EKS for your case                              |
|-------------------------|-------------------------------------|-------------------------|-------------------------------|---------------------------------------------------|
|**Monolith**             |App Runner, ECS/Fargate, EC2         |Simplicity, low cost     |Single internal app, small team|Removes most of the reason for EKS                 |
|**Microservices**        |EKS, ECS                             |Independent scaling/teams|Large, complex internal systems|The main reason to adopt EKS — not yet needed      |
|**Event-driven**         |Lambda, SQS, SNS, EventBridge, S3    |No idle cost, auto-retry |Internal jobs/automations      |Simpler & cheaper than EKS for glue logic          |
|**Serverless containers**|ECS on Fargate                       |EKS value, no cluster    |Most small–medium internal apps|**Top lighter alternative to EKS**                 |
|**Internal API layer**   |Private API Gateway, internal ALB    |Central auth/routing     |Any internal backend           |Complements any choice; neutral to EKS             |
|**Managed data services**|RDS/Aurora, DynamoDB, ElastiCache, S3|No DB ops                |Almost every app               |Reduces the case for EKS                           |
|**Hybrid/on-prem**       |Direct Connect, VPN                  |Compliance, integration  |Regulated/hybrid estates       |EKS’ stronger use case — overkill without a mandate|


> **Takeaway for your profile:** A **monolith** (or modular monolith) on **ECS/Fargate** or **App Runner**, using **managed AWS data services**, behind an **internal ALB**, all inside private subnets with **VPC endpoints**, delivers most of the nine goals with a fraction of EKS’ complexity. Microservices + EKS is the right destination only if the system later grows in service count, team size, or a genuine five-9s/hybrid mandate.

-----

## 6. Feature-by-Feature Differences (AWS Services)

### 6.1 How each AWS option handles core capabilities (all deployed privately)

|Capability             |EC2                 |App Runner             |ECS/Fargate             |Lambda (in-VPC)      |EKS                              |
|-----------------------|--------------------|-----------------------|------------------------|---------------------|---------------------------------|
|**Who manages servers**|You                 |AWS                    |AWS                     |AWS                  |You (nodes) + AWS (control plane)|
|**Scaling**            |Manual / ASG        |Auto (within limits)   |Auto, configurable      |Auto, to zero        |Auto, highly configurable        |
|**Self-healing**       |ASG only            |Built-in restart       |Built-in restart        |Built-in retry       |Full self-healing & rescheduling |
|**Deploys**            |Manual / scripted   |Push-to-deploy, rolling|Defined as code, rolling|Per-function         |Rolling/blue-green/canary        |
|**Multi-AZ redundancy**|DIY (ASG across AZs)|Built-in               |Built-in                |Built-in             |Built-in (you configure)         |
|**Private-VPC fit**    |Native              |Via VPC connector      |Native, clean           |Native (VPC-attached)|Native (private cluster)         |
|**Containers required**|No                  |Optional               |Yes                     |No (functions)       |Yes                              |
|**Cold starts**        |No                  |On low tiers           |No (tasks stay warm)    |Yes                  |No (with warm pods)              |
|**Best traffic shape** |Steady, small       |Steady, small–medium   |Steady, medium–large    |Spiky/event-driven   |Sustained, large/complex         |

### 6.2 Operational reality (internal AWS)

|Dimension                    |EC2                   |App Runner     |ECS/Fargate              |Lambda         |EKS                                    |
|-----------------------------|----------------------|---------------|-------------------------|---------------|---------------------------------------|
|**Learning curve**           |Low–medium            |Lowest         |Medium                   |Medium         |Highest                                |
|**DevOps staff needed**      |1 generalist          |None           |Light                    |Light          |Dedicated SRE/DevOps                   |
|**Time to first deploy**     |Hours                 |Minutes        |Hours–days               |Hours          |Days–weeks                             |
|**Lock-in risk**             |Low                   |High (AWS-only)|High (AWS-only)          |High (AWS-only)|Low (portable)                         |
|**Config-as-code maturity**  |ASG + launch templates|App config     |Task defs + Terraform/CFN|SAM/CDK        |Manifests + GitOps                     |
|**Blast radius of a mistake**|Whole instance        |App-scoped     |Per task                 |Per function   |Cluster-wide if misconfigured          |
|**Private-networking effort**|Low                   |Low–medium     |Low                      |Low            |**High** (endpoints, IRSA, private API)|

-----

## 7. Full Scorecard and Decision Guide

### 7.1 Scorecard — AWS options vs. all goals

Assumes a **single internal web/API app at your scale**, run by a small-to-medium team, deployed privately in the VPC.

|Goal              |EC2|App Runner|ECS/Fargate|Lambda|EKS|
|------------------|---|----------|-----------|------|---|
|Simplicity        |●●○|●●●       |●●○        |●●○   |●○○|
|Extensibility     |●○○|●●○       |●●○        |●●○   |●●●|
|Maintainability   |●○○|●●●       |●●○        |●●○   |●●○|
|Reliability       |●○○|●●●       |●●●        |●●●   |●●●|
|Security (private)|●●○|●●○       |●●●        |●●●   |●●○|
|Repeatability     |●○○|●●○       |●●●        |●●●   |●●●|
|Fault tolerance   |●○○|●●○       |●●●        |●●●   |●●●|
|Five 9s capable   |●○○|●●○       |●●○        |●●○   |●●●|
|Performance       |●●○|●●○       |●●●        |●●○*  |●●●|

*Lambda performance is excellent at steady scale but suffers from **cold starts**, slightly more pronounced for VPC-attached functions.

> **Headline:** For your internal scale, **App Runner** or **ECS/Fargate** offer the best balance. **EKS** only wins when you have many internal services *and* a dedicated platform team. **EC2 alone** fails most reliability/fault-tolerance goals beyond a pilot. Security scores are close because *everything here is private* — the boundary does the heavy lifting.

### 7.2 Decision guide — match situation to AWS option

|If your situation is…                                                          |Best fit                        |Why                                                                    |
|-------------------------------------------------------------------------------|--------------------------------|-----------------------------------------------------------------------|
|Quick internal pilot, one developer, predictable load                          |**EC2** (via SSM, no public IP) |Cheapest, fastest to ship; accept the reliability risk temporarily.    |
|Small team, want production quality without DevOps overhead                    |**App Runner** (+ VPC connector)|Best balance of simplicity, reliability, maintainability at this scale.|
|Want containers, room to grow, strong security/repeatability                   |**ECS on Fargate**              |The sweet spot for a serious internal app that may expand.             |
|Spiky/scheduled internal jobs and automations                                  |**Lambda** (in-VPC)             |Scales to zero, event-driven, pay-per-use.                             |
|Many internal microservices, dedicated platform team, real five-9s/hybrid needs|**EKS**                         |The only option that fully delivers extensibility + five 9s at scale.  |

**For your profile (100k non-concurrent internal users, one app):** start with **App Runner** or **ECS/Fargate**, backed by **managed AWS data services**, behind an **internal ALB**, inside private subnets with **VPC endpoints**. Both comfortably exceed your scale, deliver most of the nine goals well, and leave a clean path to EKS later *if* — and only if — complexity genuinely demands it. Don’t pay the EKS tax for a problem you don’t yet have.

-----

## 8. Cross-Cutting AWS Best Practices (Any Option)

These apply regardless of the compute choice — and they’re how you actually approach five 9s on a private AWS estate.

- **Infrastructure as code:** Terraform or CloudFormation/CDK for the whole VPC + app stack, so any environment is reproducible (*repeatability*).
- **Private by default:** no public IPs on app/data subnets; inbound only via VPN/Direct Connect; outbound via VPC endpoints or controlled NAT (*security*).
- **Least-privilege IAM everywhere:** task roles / IRSA / function roles, never long-lived keys (*security*).
- **VPC endpoints (PrivateLink):** for S3, ECR, Secrets Manager, CloudWatch, STS — keep traffic off the internet entirely.
- **Multi-AZ first:** spread compute and databases across AZs for *fault tolerance*; consider multi-region only if five 9s truly demands it.
- **Automated CI/CD:** CodePipeline/CodeBuild or your tool of choice — deploy through a pipeline, not by hand (*maintainability* + *reliability*).
- **Observability first:** CloudWatch metrics/logs, X-Ray traces, dashboards, and alarms — before you need them.
- **Zero-downtime deploys:** rolling or blue-green so releases don’t cause outages.
- **Secrets in AWS Secrets Manager / Parameter Store:** accessed privately via endpoints, never in code.
- **Backups + tested restores:** automated RDS/Aurora snapshots; *untested backups don’t count*.
- **Define your real SLA:** choose honestly between three, four, or five 9s — each tier roughly multiplies cost and complexity. Internal tools can often use maintenance windows, relaxing the target.

-----

## 9. One-Paragraph Summary for Leadership

For an internal-only application living entirely inside the company’s AWS private network and serving 100,000 total (non-concurrent) users, **Amazon EKS (Kubernetes) is overkill**. EKS is the most powerful option — self-healing, infinitely extensible, portable across clouds and on-prem, and the right choice when genuine five-9s reliability across many services is required — but it carries the steepest learning curve, real operational complexity, extra private-networking surfaces (private endpoints, IRSA, internal ingress), and the need for dedicated DevOps/SRE staff. **AWS App Runner or Amazon ECS on Fargate** delivers strong reliability, security, maintainability, and repeatability at this scale with far less effort, integrates cleanly with private subnets and managed AWS data services, and leaves a clean upgrade path to EKS if the system later grows into many services or a true five-9s/hybrid mandate. A single EC2 instance is acceptable only for an internal pilot. Because the entire estate is private, the **network boundary itself delivers most of the security goal** — so the team should pick the simplest compute option that meets the real uptime requirement, and decide that uptime number deliberately, since five 9s costs far more than three or four.