# Kubernetes Explained — And When Other Options Beat It

**Application profile:** ~100,000 total registered users, **not** concurrent. Realistic peak is a few hundred to low thousands of requests per second.

**How this document is organized:**

1. The nine goals (the yardstick we measure everything against)
1. **Kubernetes in depth** — what it actually is, its parts, and how it scores
1. Why each alternative may be **better or worse** than Kubernetes
1. **Broader architecture approaches** — the wider landscape of alternatives and their benefits
1. Feature-by-feature difference tables
1. The full scorecard and a decision guide
1. Cross-cutting best practices and a leadership summary

-----

## 1. The Nine Goals, in Plain Language

Before judging Kubernetes or anything else, the team should agree on what “good” means. Think of these like qualities you’d want in a car before comparing engines.

|Goal                 |Middle-school explanation                                               |What “done well” looks like                                       |
|---------------------|------------------------------------------------------------------------|------------------------------------------------------------------|
|**Simplicity**       |How easy to set up and understand? Can one person hold it in their head?|A new teammate deploys on day one without a 3-week course.        |
|**Extensibility**    |How easily can you add features, services, or scale later?              |A new microservice or region doesn’t force a rebuild.             |
|**Maintainability**  |How easy to keep running, patch, and fix over years?                    |Routine updates are boring and safe, not scary.                   |
|**Reliability**      |Does it keep working day to day without surprises?                      |Few incidents; predictable behavior.                              |
|**Security**         |How well does it keep attackers and mistakes out?                       |Secrets protected, fast patching, small blast radius.             |
|**Repeatability**    |Can you rebuild the exact same setup automatically?                     |“Infrastructure as code” — destroy it and recreate it identically.|
|**Fault tolerance**  |If one piece breaks, does the whole thing stay up?                      |One server dies, users never notice.                              |
|**Five 9s (99.999%)**|Under ~5 minutes of downtime **per year**.                              |Near-zero outages, even during deploys and failures.              |
|**Performance**      |How fast and responsive under load?                                     |Pages load quickly even at peak traffic.                          |


> **Reality check on “Five 9s”:** 99.999% uptime is genuinely hard and expensive. It usually requires multi-zone or multi-region redundancy, automated failover, zero-downtime deploys, and mature on-call. Most apps actually need **three 9s (99.9%, ~8.8 hrs/yr)** or **four 9s (99.99%, ~53 min/yr)**. Be honest about whether five 9s is a real business requirement — it changes the cost by an order of magnitude, and it’s the single goal that most justifies Kubernetes.

-----

## 2. Kubernetes in Depth

### 2.1 What Kubernetes actually is (plain language)

Imagine a busy airport. Planes (your app’s containers) are constantly landing, taking off, and being refueled. Something has to direct all that traffic, replace a plane that breaks down, and add more flights when demand spikes. **Kubernetes is that control tower.** It runs many containers across many machines and constantly keeps them healthy: if a container dies, it restarts it; if a whole machine dies, it moves the work elsewhere; if traffic rises, it launches more copies.

It is extraordinarily powerful. But a control tower is overkill for a single small runway — and that’s the core tension for your use case.

### 2.2 A container, first

A **container** is a sealed box holding your code plus everything it needs to run (libraries, settings), so it behaves identically on any machine. Kubernetes doesn’t replace containers — it **orchestrates** them: it decides where they run, how many there are, and how they find each other.

### 2.3 The main parts of Kubernetes (so the team isn’t lost)

|Part                  |Airport analogy          |What it does                                                                    |
|----------------------|-------------------------|--------------------------------------------------------------------------------|
|**Cluster**           |The whole airport        |All the machines Kubernetes manages, working as one system.                     |
|**Node**              |A runway/gate            |A single machine (VM or physical) that runs your containers.                    |
|**Pod**               |A single parked plane    |The smallest unit Kubernetes runs — one or a few tightly-coupled containers.    |
|**Deployment**        |The flight schedule      |Declares “I want N copies of this app running” and keeps it true.               |
|**Service**           |The airport signage      |A stable address so other parts can find your pods even as they come and go.    |
|**Ingress**           |The arrivals gate        |Routes outside web traffic to the right Service inside the cluster.             |
|**ConfigMap / Secret**|The ops manual / the safe|Stores configuration and sensitive credentials separately from code.            |
|**Control plane**     |The control tower itself |The brain that schedules pods, watches health, and enforces your declared state.|
|**kubectl**           |The radio you talk on    |The command-line tool you use to inspect and change the cluster.                |

The key idea is **declarative state**: you write down what you want (in YAML manifests), and Kubernetes continuously works to make reality match. That’s why it self-heals — it’s always comparing “what is” to “what should be.”

### 2.4 Where you can run it

|Flavor          |Examples                      |Trade-off                                                                                               |
|----------------|------------------------------|--------------------------------------------------------------------------------------------------------|
|**Managed**     |AWS EKS, Google GKE, Azure AKS|Cloud runs the control plane for you. **Strongly recommended** — removes the hardest operational burden.|
|**Self-managed**|kubeadm, kOps, bare metal     |You run everything, including the control plane. Maximum control, maximum pain. Only for special needs. |

### 2.5 How Kubernetes scores against the nine goals

|Goal           |Score|Why                                                                                                       |
|---------------|-----|----------------------------------------------------------------------------------------------------------|
|Simplicity     |●○○  |Many moving parts (ingress, services, secrets, networking, autoscaling, monitoring). Steep learning curve.|
|Extensibility  |●●●  |Best in class. Run hundreds of services, custom operators, any deployment pattern you want.               |
|Maintainability|●●○  |Powerful but heavy; needs ongoing upgrades and expertise. Managed control planes ease this.               |
|Reliability    |●●●  |Self-healing and battle-tested at the world’s largest scales.                                             |
|Security       |●●○  |Very capable (RBAC, network policies, secrets) but **easy to misconfigure** without expertise.            |
|Repeatability  |●●●  |Declarative manifests + GitOps = exact, version-controlled rebuilds.                                      |
|Fault tolerance|●●●  |Reschedules across nodes and availability zones automatically; designed around failure.                   |
|Five 9s        |●●●  |The standard choice when five 9s is a *genuine* requirement — *with* the team to run it.                  |
|Performance    |●●●  |Scales horizontally extremely well, with fine-grained CPU/memory control.                                 |

Scoring key: ●●● strong, ●●○ moderate, ●○○ weak.

### 2.6 Kubernetes — pros and cons

**Pros**

- Unmatched scalability and flexibility for complex systems.
- Self-healing, automated rollouts/rollbacks, horizontal autoscaling.
- Cloud-portable — reduces lock-in across AWS/GCP/Azure/on-prem.
- Enormous ecosystem (Helm, operators, service mesh, observability tooling).
- The right tool when you genuinely need five 9s *and* many services.

**Cons**

- Steep learning curve and high operational complexity.
- Needs dedicated DevOps/SRE expertise to run safely.
- Higher baseline cost: control plane + nodes + tooling + **people**.
- Security and networking are easy to misconfigure.
- Slows early shipping — overkill for a single small app.

### 2.7 Kubernetes — troubleshooting

Work top-down: `kubectl get pods` → `kubectl describe pod <name>` → `kubectl logs <name>`.

|Symptom            |Likely cause                                                       |Fix                                                                                |
|-------------------|-------------------------------------------------------------------|-----------------------------------------------------------------------------------|
|Pod stuck `Pending`|Not enough CPU/memory on nodes, or an unschedulable constraint     |Scale the node group or relax the constraint.                                      |
|`CrashLoopBackOff` |App keeps crashing on start                                        |Check `kubectl logs`; usually bad config, missing env var, or a failing dependency.|
|`ImagePullBackOff` |Wrong image name/tag or missing registry credentials               |Fix the image reference or add a pull secret.                                      |
|Service unreachable|Service selectors don’t match pod labels; Ingress/DNS misconfigured|Align labels; verify Ingress + DNS wiring.                                         |
|`OOMKilled`        |Container exceeded its memory limit                                |Raise limits or fix a memory leak.                                                 |

### 2.8 Kubernetes — best practices

- Prefer a **managed** control plane (EKS/GKE/AKS); don’t self-run the control plane unless truly required.
- Use **GitOps** (Argo CD / Flux) so cluster state is fully version-controlled and repeatable.
- Set resource **requests and limits** on every workload.
- Enforce **RBAC**, **network policies**, and a real secrets manager from day one.
- Spread across **multiple availability zones**; use Pod Disruption Budgets for safe maintenance.
- Invest in observability (metrics, logs, traces) and alerting early.
- Adopt Kubernetes only when complexity (many services, large team, portability/compliance, true five-9s) genuinely justifies it.

-----

## 3. Why the Alternatives May Be Better or Worse Than Kubernetes

Each alternative is framed directly against Kubernetes: where it wins, where it loses, and the bottom line.

### 3.1 Single VM / VPS

**What it is:** One rented Linux server (EC2 instance, DigitalOcean Droplet, Linode). You SSH in, install your app, and run it. You are the admin, deployer, and firefighter.

**Better than Kubernetes when:**

- You need something live *today* for a prototype.
- Budget is tiny and the team is one person.
- The mental model must be dead simple (one box, logs right there).

**Worse than Kubernetes when:**

- You need fault tolerance — a single VM is a single point of failure with no auto-recovery.
- You need to scale smoothly — growth means manual server-adding and load-balancer wiring.
- You need repeatability — without scripting, rebuilds are manual and drift-prone.
- Five 9s is required — effectively impossible on one box.

**Bottom line vs K8s:** Far simpler and cheaper to start, but loses badly on fault tolerance, repeatability, and five 9s. A stepping stone, not a destination for a serious app.

### 3.2 Platform-as-a-Service (PaaS)

**Examples:** Render, Railway, Fly.io, Heroku, AWS App Runner.

**What it is:** You hand the platform your code (or a container). It builds, runs, gives it a URL, handles HTTPS, restarts on crash, and adds copies under load. You focus on the app; the platform handles the plumbing — essentially “Kubernetes-like benefits without touching Kubernetes.”

**Better than Kubernetes when:**

- You want production quality with almost no operational overhead.
- The team is small and has no dedicated DevOps/SRE.
- You value fast shipping and a gentle learning curve over fine-grained control.
- **This is the strongest fit for your scale.**

**Worse than Kubernetes when:**

- You need deep low-level control or unusual deployment patterns.
- You need true multi-region active-active for strict five 9s (often limited or pricey).
- Cost-per-unit at very large scale matters (PaaS is pricier per unit than raw infra).
- You want to avoid vendor lock-in.

**Bottom line vs K8s:** Wins decisively on simplicity, maintainability, and reliability for a single app; loses on extensibility ceiling, ultimate five-9s capability, and lock-in.

### 3.3 Managed Container Services

**Examples:** AWS ECS on Fargate, Google Cloud Run, Azure Container Apps.

**What it is:** You package your app as a container and hand it to the cloud, which runs and scales it — but **without you managing any servers or a cluster**. It’s the middle ground: containers and elasticity without Kubernetes’ orchestration burden.

**Better than Kubernetes when:**

- You want container benefits (portability, consistency, strong isolation) without cluster ops.
- You want excellent repeatability and fault tolerance defined as code, but with less surface area.
- Scale-to-zero economics (Cloud Run) are attractive.
- **This is the strongest fit if you want containers and room to grow.**

**Worse than Kubernetes when:**

- You’ll genuinely run *many* interconnected services needing advanced orchestration (service mesh, custom operators).
- You need maximum portability across clouds/on-prem.
- You need the very richest ecosystem of orchestration tooling.

**Bottom line vs K8s:** Matches Kubernetes on reliability, fault tolerance, and repeatability for a single app, while beating it on simplicity. Kubernetes only pulls ahead at high service count and complexity.

### 3.4 Serverless Functions

**Examples:** AWS Lambda, Cloudflare Workers, Vercel/Netlify Functions, Google Cloud Functions.

**What it is:** Your code sits idle and runs **only when called** (a request, an upload, a timer). 10,000 requests → 10,000 copies; nobody using it → you pay nothing. No servers to manage at all.

**Better than Kubernetes when:**

- Traffic is spiky, unpredictable, or event-driven.
- You want to pay nothing when idle and burst infinitely on demand.
- Workloads are short, stateless tasks.

**Worse than Kubernetes when:**

- Latency must be consistent — **cold starts** add delay when functions haven’t run recently.
- Work is long-running or stateful — execution time, memory, and payload **limits** get in the way.
- Traffic is sustained and heavy — cost can become **unpredictable and high**.
- You’re stitching many functions together — debugging the distributed sprawl is hard.

**Bottom line vs K8s:** Wins on idle cost and burst for spiky workloads; loses on consistent latency, long/stateful jobs, and predictable cost under steady heavy load.

-----

## 4. Broader Architecture Approaches and Their Benefits

The five options above (VM, PaaS, managed containers, serverless, Kubernetes) are *where* you run software. This section zooms out to the architectural **approaches** that cut across them — the patterns that shape how the app itself is built and deployed. Each is explained in plain language, with its core benefits and how it relates to Kubernetes.

### 4.1 Monolith vs. Microservices

This is the single biggest architectural fork, and it largely determines whether Kubernetes is worth it.

**Monolith (plain language):** The whole app is one program. All the features live together and deploy as a single unit. Think of one big house where every room is under one roof.

**Microservices (plain language):** The app is split into many small, independent programs that each do one job and talk to each other over the network. Think of a neighborhood of small houses, each with its own front door.

|                          |Monolith                                                                                                                               |Microservices                                                                                                                                        |
|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------|
|**Benefits**              |Simple to build, test, deploy, and reason about; one codebase; fast for small teams; cheap to run.                                     |Independent scaling and deployment per service; teams work in parallel; a fault in one service needn’t sink the rest; technology freedom per service.|
|**Costs**                 |Scales as one block (you scale everything even if one part is hot); a big change is riskier; harder for many teams to work in parallel.|Network complexity, distributed debugging, more infrastructure, operational overhead.                                                                |
|**Relation to Kubernetes**|A monolith rarely needs Kubernetes — a PaaS or managed container service runs it beautifully.                                          |Microservices are the classic *reason* to adopt Kubernetes: it orchestrates many services elegantly.                                                 |


> **For your use case:** A single app for 100k non-concurrent users is almost certainly best as a **monolith** (or a “modular monolith” — one deployable unit with clean internal boundaries). That alone removes most of the case for Kubernetes. Split into microservices later only when team size or clear scaling pressure demands it.

### 4.2 Serverless / Functions-as-a-Service (FaaS)

**Plain language:** Already covered as an option in Section 3.4 — code that runs only when called and scales to zero. As an *approach*, the benefit is **event-driven design**: you wire small functions to events (a file upload, a queue message, a scheduled timer) instead of keeping servers running.

**Benefits:** No idle cost, infinite burst, no servers to patch, naturally fault-tolerant, very fast to ship small pieces.

**Relation to Kubernetes:** The philosophical opposite. Kubernetes keeps containers running and you manage capacity; serverless hides all of that. For spiky or glue-logic workloads, serverless beats Kubernetes on simplicity and cost. For sustained heavy traffic or long jobs, Kubernetes (or containers) wins.

### 4.3 Serverless Containers

**Plain language:** A blend of two worlds — you give the cloud a *container* (like Kubernetes uses), but it runs and scales that container for you with no cluster (like serverless). Examples are **AWS Fargate** and **Google Cloud Run**.

**Benefits:** You get container portability and consistency **plus** scale-to-zero economics and zero cluster management. It’s often described as “the 80% of Kubernetes’ value for 20% of the effort.”

**Relation to Kubernetes:** This is the most direct “lighter alternative” to Kubernetes. For a single app — and even many small-to-medium systems — serverless containers deliver the reliability, fault tolerance, and repeatability of Kubernetes without the operational tax. **This is a top recommendation for your scale.**

### 4.4 Edge Computing

**Plain language:** Instead of running your app in one data center, the cloud runs copies of it in many locations physically close to your users around the world. When someone in Tokyo and someone in London both visit, each is served from a nearby city, so responses arrive faster. Examples are **Cloudflare Workers**, **Vercel Edge**, **AWS Lambda@Edge**, and **Fastly Compute**.

**Benefits:** Very low latency (the app is near the user), strong global fault tolerance (many locations, no single point), automatic scaling, and built-in protection against traffic spikes and some attacks.

**Costs / limits:** Edge runtimes are constrained — limited execution time, smaller code size, restricted libraries, and harder access to a central database. Best for lightweight, latency-sensitive logic (auth checks, redirects, personalization, caching), not heavy backends.

**Relation to Kubernetes:** Complementary rather than competing. Many teams run a Kubernetes or container backend **and** push a thin edge layer in front for speed. For a global, latency-sensitive front end, edge beats a single-region Kubernetes cluster outright.

### 4.5 Backend-as-a-Service (BaaS)

**Plain language:** A ready-made backend you don’t build yourself. The provider gives you a database, user login/authentication, file storage, and APIs out of the box, so you mostly write the front end. Examples are **Firebase**, **Supabase**, and **AWS Amplify**.

**Benefits:** Dramatically faster to launch (common backend pieces are pre-built), very low ops burden, generous free tiers, real-time data sync built in. Excellent for MVPs, mobile apps, and small teams.

**Costs / limits:** Less control, potential lock-in, costs that can climb at scale, and limits when your logic gets complex or unusual.

**Relation to Kubernetes:** Polar opposite philosophies — BaaS removes the backend you’d otherwise orchestrate. For a small team that wants to ship features rather than run infrastructure, BaaS can eliminate the need for Kubernetes entirely.

### 4.6 Static Site + APIs (Jamstack)

**Plain language:** The website’s pages are pre-built ahead of time and served as plain files from a global CDN (extremely fast and cheap), while anything dynamic is handled by separate API calls (often serverless). The name reflects “JavaScript, APIs, and Markup.” Examples pair **Netlify**, **Vercel**, or **Cloudflare Pages** with serverless functions.

**Benefits:** Blazing performance, excellent reliability (static files rarely fail), strong security (little server surface to attack), low cost, and effortless scaling.

**Costs / limits:** Best when much of the content is presentational; highly dynamic, per-user-heavy apps fit less cleanly.

**Relation to Kubernetes:** For content-heavy or marketing-style front ends, Jamstack vastly out-simplifies Kubernetes. Dynamic apps still need a backend somewhere — which could be serverless, containers, or, at scale, Kubernetes.

### 4.7 Hybrid and Multi-Cloud Approaches

**Plain language:** Running across more than one environment — e.g., part in your own data center and part in the public cloud (**hybrid**), or spread across two cloud providers (**multi-cloud**).

**Benefits:** Avoids dependence on a single vendor, can satisfy data-residency or compliance rules, and adds resilience if one provider has an outage.

**Costs / limits:** Significant complexity, harder networking and security, and higher operational cost — usually only justified by regulatory or strategic needs.

**Relation to Kubernetes:** This is one of Kubernetes’ strongest arguments — because Kubernetes is portable, it’s the common foundation for hybrid/multi-cloud. But unless you have a genuine compliance or vendor-risk mandate, this complexity is rarely worth it for a single app.

### 4.8 Quick reference — approaches mapped to benefits and fit

|Approach                 |Standout benefit              |Best for                    |Vs. Kubernetes for your case                        |
|-------------------------|------------------------------|----------------------------|----------------------------------------------------|
|**Monolith**             |Simplicity, low cost          |Single app, small team      |Removes most of the reason for K8s                  |
|**Microservices**        |Independent scaling/teams     |Large, complex systems      |The main reason to adopt K8s — not yet needed       |
|**Serverless / FaaS**    |No idle cost, infinite burst  |Spiky, event-driven work    |Simpler & cheaper than K8s for glue logic           |
|**Serverless containers**|K8s benefits, no cluster      |Most small–medium apps      |**Top lighter alternative to K8s**                  |
|**Edge computing**       |Ultra-low global latency      |Latency-sensitive front ends|Complements, can front a K8s/container backend      |
|**BaaS**                 |Pre-built backend, fast launch|MVPs, mobile, small teams   |Can remove the need for K8s entirely                |
|**Jamstack**             |Performance + reliability     |Content-heavy front ends    |Far simpler than K8s for presentational sites       |
|**Hybrid/Multi-cloud**   |No vendor lock-in, compliance |Regulated/strategic needs   |K8s’ strongest use case — overkill without a mandate|


> **Takeaway for your profile:** The approaches that fit a single app at 100k non-concurrent users best are a **monolith** (or modular monolith) deployed on **serverless containers** or **PaaS**, optionally fronted by an **edge/CDN layer** for speed. These deliver most of the nine goals with a fraction of Kubernetes’ complexity. Microservices + Kubernetes is the right destination only if the system later grows in service count, team size, or a genuine five-9s/portability mandate.

-----

## 5. Feature-by-Feature Differences

### 5.1 How each option handles core capabilities

|Capability             |Single VM    |PaaS                   |Managed Containers      |Serverless         |Kubernetes                                       |
|-----------------------|-------------|-----------------------|------------------------|-------------------|-------------------------------------------------|
|**Who manages servers**|You          |Provider               |Provider                |Provider           |You (nodes) + provider (control plane if managed)|
|**Scaling**            |Manual       |Auto (within limits)   |Auto, sometimes to zero |Auto, to zero      |Auto, highly configurable                        |
|**Self-healing**       |None         |Built-in restart       |Built-in restart        |Built-in retry     |Full self-healing & rescheduling                 |
|**Deploys**            |Manual       |Push-to-deploy, rolling|Defined as code, rolling|Deploy per function|Rolling/blue-green/canary                        |
|**Multi-AZ redundancy**|DIY/none     |Often built-in         |Built-in                |Built-in           |Built-in (you configure)                         |
|**Multi-region**       |DIY          |Limited/extra cost     |Achievable, more work   |Provider-dependent |Fully supported (complex)                        |
|**Containers required**|No           |Optional               |Yes                     |No (functions)     |Yes                                              |
|**Cold starts**        |No           |On small tiers         |On scale-to-zero        |Yes                |No (with warm pods)                              |
|**Best traffic shape** |Steady, small|Steady, small–medium   |Steady, medium–large    |Spiky/event-driven |Sustained, large/complex                         |

### 5.2 Operational reality

|Dimension                    |Single VM   |PaaS        |Managed Containers|Serverless  |Kubernetes                   |
|-----------------------------|------------|------------|------------------|------------|-----------------------------|
|**Learning curve**           |Low–medium  |Lowest      |Medium            |Medium      |Highest                      |
|**DevOps staff needed**      |1 generalist|None        |Light             |Light       |Dedicated SRE/DevOps         |
|**Time to first deploy**     |Hours       |Minutes     |Hours–days        |Hours       |Days–weeks                   |
|**Lock-in risk**             |Low         |High        |Medium            |High        |Low (portable)               |
|**Config-as-code maturity**  |DIY scripts |Config files|Terraform/CFN     |SAM/CDK/SF  |Manifests + GitOps           |
|**Blast radius of a mistake**|Whole box   |App-scoped  |Per container     |Per function|Cluster-wide if misconfigured|

-----

## 6. Full Scorecard and Decision Guide

### 6.1 Scorecard — all options vs. all goals

Assumes a **single typical web/API app at your scale**, run by a small-to-medium team.

|Goal           |Single VM|PaaS|Managed Containers|Serverless|Kubernetes|
|---------------|---------|----|------------------|----------|----------|
|Simplicity     |●●○      |●●● |●●○               |●●○       |●○○       |
|Extensibility  |●○○      |●●○ |●●○               |●●○       |●●●       |
|Maintainability|●○○      |●●● |●●○               |●●○       |●●○       |
|Reliability    |●○○      |●●● |●●●               |●●●       |●●●       |
|Security       |●○○      |●●○ |●●●               |●●●       |●●○       |
|Repeatability  |●○○      |●●○ |●●●               |●●●       |●●●       |
|Fault tolerance|●○○      |●●○ |●●●               |●●●       |●●●       |
|Five 9s capable|●○○      |●●○ |●●○               |●●○       |●●●       |
|Performance    |●●○      |●●○ |●●●               |●●○*      |●●●       |

*Serverless performance is excellent at steady scale but suffers from **cold starts**.

> **Headline:** For your scale, **PaaS** or **Managed Containers** offer the best balance. **Kubernetes** only wins when you have many services *and* a dedicated platform team. A **single VM** fails most reliability/fault-tolerance goals beyond an MVP.

### 6.2 Decision guide — match situation to option

|If your situation is…                                                      |Best fit              |Why                                                                        |
|---------------------------------------------------------------------------|----------------------|---------------------------------------------------------------------------|
|Quick MVP, one developer, predictable load                                 |**Single VM**         |Cheapest and fastest to ship; accept the reliability risk temporarily.     |
|Small team, want production quality without DevOps overhead                |**PaaS**              |Best balance of simplicity, reliability, maintainability for your scale.   |
|Want containers, room to grow, strong security/repeatability               |**Managed Containers**|The sweet spot for a serious app that may expand.                          |
|Spiky/unpredictable or event-driven traffic                                |**Serverless**        |Scales to zero, infinite burst, pay-per-use.                               |
|Many microservices, dedicated platform team, real five-9s/portability needs|**Kubernetes**        |The only option that fully delivers extensibility + five 9s at large scale.|

**For your profile (100k non-concurrent users, one app):** start with **PaaS** or **Managed Containers**. Both comfortably exceed your scale, deliver most of the nine goals well, and leave a clean path to Kubernetes later *if* — and only if — complexity genuinely demands it. Don’t pay the Kubernetes tax for a problem you don’t yet have.

-----

## 7. Cross-Cutting Best Practices (Any Option)

These apply regardless of platform — and they’re how you actually approach five 9s.

- **Infrastructure as code:** Terraform/CloudFormation/CDK so any environment is reproducible (*repeatability*).
- **Automated CI/CD:** test and deploy through a pipeline, not by hand (*maintainability* + *reliability*).
- **Multi-AZ, then multi-region:** zone redundancy is the baseline for *fault tolerance*; multi-region is the price of *five 9s*.
- **Observability first:** metrics, logs, traces, dashboards, alerts — before you need them.
- **Zero-downtime deploys:** rolling or blue-green so releases don’t cause outages.
- **Secrets management:** a real secret store + least-privilege access everywhere (*security*).
- **Backups + tested restores:** untested backups don’t count.
- **Define your real SLA:** choose honestly between three, four, or five 9s — each tier roughly multiplies cost and complexity.

-----

## 8. One-Paragraph Summary for Leadership

Kubernetes is the most powerful option here — self-healing, infinitely extensible, cloud-portable, and the standard when genuine five-9s reliability across many services is required. But that power comes with a steep learning curve, real operational complexity, and the need for dedicated DevOps/SRE staff. For a single application serving 100,000 total (non-concurrent) users, it is overkill: a **Platform-as-a-Service** or **managed container service** delivers strong reliability, security, maintainability, and repeatability at this scale with far less effort, and both leave a clean upgrade path to Kubernetes if the system later grows into many services or a true five-9s mandate. A single VM is acceptable only for an early prototype. Pick the simplest option that meets the real uptime requirement — and decide that uptime number deliberately, because five 9s costs far more than three or four.