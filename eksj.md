# The Friendly Guide: EKS + NiFi + Kafka on AWS
### A training manual for the new cloud support team

**Who this is for:** New team members who will build, migrate, and support our data platform on AWS.

**How this guide works:** Every topic answers three questions — **WHAT** is it (in plain language), **WHY** do we use it, and **HOW** do we do it (real commands and code you can copy). Analogies are written so a middle schooler could follow them, but the commands are the real deal.

**Companion file:** `eks-cheat-sheet.md` — a quick-reference card. Keep it open while you work.

---

## Table of Contents

1. [Part 1 — The Big Ideas (Background)](#part-1--the-big-ideas-background)
2. [Part 2 — The Big Picture Architecture](#part-2--the-big-picture-architecture)
3. [Part 3 — Designing the EKS Clusters (dev / stage / prod)](#part-3--designing-the-eks-clusters-dev--stage--prod)
4. [Part 4 — Networking: VPC, Subnets, Load Balancers, Security Groups](#part-4--networking)
5. [Part 5 — Multi-Tenant Setup: Namespaces, Roles, Quotas](#part-5--multi-tenant-setup)
6. [Part 6 — Running Kafka on EKS](#part-6--running-kafka-on-eks)
7. [Part 7 — Running NiFi on EKS](#part-7--running-nifi-on-eks)
8. [Part 8 — GitLab CI/CD: dev → stage → prod](#part-8--gitlab-cicd)
9. [Part 9 — Migrating from EC2](#part-9--migrating-from-ec2)
10. [Part 10 — Auditing What Already Exists](#part-10--auditing-what-already-exists)
11. [Part 11 — Logging and Monitoring](#part-11--logging-and-monitoring)
12. [Glossary](#glossary)

---

# Part 1 — The Big Ideas (Background)

Before touching any buttons, let's understand the characters in this story.

## 1.1 What is AWS?

**WHAT:** Amazon Web Services. Think of it as renting rooms in a giant, super-secure building instead of building your own house. You rent computers, storage, and networks by the hour.

**WHY:** Building your own data center is expensive and slow. Renting means you can grow or shrink in minutes and only pay for what you use.

## 1.2 What is a container?

**WHAT:** A container is like a **lunchbox**. It holds an app *plus everything the app needs to run* (code, libraries, settings) in one sealed package. Docker is the most famous lunchbox maker.

**WHY:** Before containers, apps were like meals cooked directly in someone's kitchen — they worked on *that* kitchen (server) but broke everywhere else ("it works on my machine!"). A lunchbox works the same anywhere you carry it: your laptop, dev, stage, or prod.

## 1.3 What is Kubernetes (K8s)?

**WHAT:** Kubernetes is the **cafeteria manager** for thousands of lunchboxes. You tell it "I always want 3 copies of the Kafka lunchbox running," and it makes it happen. If one falls on the floor (crashes), Kubernetes throws it away and opens a fresh one automatically.

**WHY:** Managing hundreds of containers by hand is impossible. Kubernetes handles restarting, scaling, networking, and placing containers on machines for you.

**Key words you'll hear:**

| Word | Middle-school meaning |
|---|---|
| **Pod** | The smallest unit — one or more containers glued together (usually one). Like a single lunch tray. |
| **Node** | A real (virtual) computer that pods run on. A cafeteria table. |
| **Deployment** | "Keep N copies of this pod running." Great for stateless apps. |
| **StatefulSet** | Like a Deployment, but each pod gets a permanent name and its own disk. Used for Kafka and NiFi, which must remember things. |
| **Service** | A stable phone number for a group of pods. Pods come and go; the Service number never changes. |
| **Ingress** | The front door for web traffic coming from outside the cluster. |
| **Namespace** | A labeled section of the cafeteria — walls between teams. |
| **ConfigMap / Secret** | Sticky notes with settings (ConfigMap) or locked notes with passwords (Secret). |

## 1.4 What is EKS?

**WHAT:** **Elastic Kubernetes Service.** Kubernetes has a "brain" (the control plane) and "muscles" (worker nodes). With EKS, **AWS runs the brain for you** — patched, backed up, and highly available. You mostly manage the muscles (nodes) and the apps.

**WHY:** Running the Kubernetes brain yourself is hard and risky. Letting AWS do it means fewer 3 a.m. pages and easier upgrades.

## 1.5 What is Apache Kafka?

**WHAT:** Kafka is a **super-fast post office for computer messages**. Apps drop letters (events/messages) into named mail slots called **topics**. Other apps subscribe to those slots and read the letters, in order, as fast or slow as they like. Kafka keeps copies of every letter for days, so a reader that was asleep can catch up.

**WHY:** It lets many systems talk without knowing about each other. The website drops "user clicked buy" into a topic; billing, analytics, and inventory each read it independently. If analytics is down for an hour, no data is lost.

**Key words:**

| Word | Meaning |
|---|---|
| **Topic** | A named mail slot / category of messages. |
| **Partition** | A topic split into lanes so multiple readers can work in parallel. |
| **Broker** | One Kafka server. A cluster has several (usually 3+). |
| **Producer / Consumer** | App that writes / app that reads. |
| **Consumer group** | A team of readers that split the work of one topic. |
| **Offset** | A bookmark showing how far a reader has read. |
| **Replication factor** | How many brokers keep a copy of each message (3 is standard). |
| **KRaft** | Kafka's modern built-in coordination mode. Old Kafka needed a helper called ZooKeeper; new Kafka (3.x+ and all of 4.x) doesn't. |

## 1.6 What is Apache NiFi?

**WHAT:** NiFi is **visual plumbing for data**. You drag-and-drop boxes (processors) on a canvas and connect them with pipes (queues). Data flows through: "Pull files from SFTP → clean them → convert to JSON → send to Kafka." No pipe-code to write; you configure boxes.

**WHY:** It's fast to build data flows, easy to see where data is stuck (the pipes fill up visually), and it records the history of every piece of data (**provenance** — like a package tracking number).

**Key words:**

| Word | Meaning |
|---|---|
| **Processor** | One box that does one job (fetch, transform, route, send). |
| **FlowFile** | One piece of data moving through the pipes (content + attributes/sticky notes). |
| **Connection / Queue** | The pipe between boxes; also a buffer when downstream is slow. |
| **Process Group** | A folder of boxes — how you organize flows per team/project. |
| **Controller Service** | Shared settings, like "how to connect to Kafka" or a database pool. |
| **NiFi Registry** | Version control (like Git) for your flows. Critical for dev→stage→prod promotion. |
| **Provenance** | The tracking history of every FlowFile. |

## 1.7 What is GitLab (and CI/CD)?

**WHAT:** GitLab is a **shared recipe book (Git) plus a robot chef (CI/CD pipelines)**. Everyone writes and reviews recipes (code, configs) in one place. When a recipe is approved, the robot automatically cooks it — builds, tests, and deploys to dev, then stage, then prod.

**WHY:** No more "Bob deployed something from his laptop and nobody knows what." Every change is reviewed, recorded, and repeatable. Rollback = re-run an old recipe.

## 1.8 What are Terraform and CloudFormation?

**WHAT:** Both are **LEGO instruction booklets for the cloud** (called *Infrastructure as Code*, IaC). Instead of clicking 200 buttons in the AWS console, you write a file describing what you want ("1 VPC, 6 subnets, 1 EKS cluster") and the tool builds it exactly the same way every time.

- **Terraform** — made by HashiCorp, works with any cloud, files end in `.tf`. Keeps a memory file called **state** that records what it built.
- **CloudFormation (CFN)** — AWS's own version, files are YAML/JSON **templates**, deployed as **stacks**.

**WHY:** Clicking is not repeatable and not reviewable. Code is both. When something breaks at 2 a.m., the `.tf` files tell you exactly what *should* exist.

---

# Part 2 — The Big Picture Architecture

Here is what we're building. Three copies of the same layout — one for **dev**, one for **stage**, one for **prod** — ideally in **separate AWS accounts** so a mistake in dev can never hurt prod.

```
                            THE INTERNET
                                 │
              ┌──────────────────┼──────────────────┐
              │        AWS ACCOUNT (one per env)     │
              │  ┌────────────── VPC 10.0.0.0/16 ──┐ │
              │  │                                  │ │
   Users ────►│  │  PUBLIC SUBNETS (the front yard) │ │
   (HTTPS)    │  │  ┌─────────┐  ┌──────────────┐  │ │
              │  │  │   ALB   │  │ NAT Gateways │  │ │
              │  │  │(web door)│ │(outbound door)│  │ │
              │  │  └────┬────┘  └──────┬───────┘  │ │
              │  │       │              │           │ │
              │  │  PRIVATE SUBNETS (the backyard)  │ │
              │  │  ┌────▼──────────────▼────────┐  │ │
              │  │  │        EKS CLUSTER          │  │ │
              │  │  │  ┌───────┐   ┌───────────┐ │  │ │
              │  │  │  │ NiFi  │──►│   Kafka   │ │  │ │
              │  │  │  │ pods  │   │  brokers  │ │  │ │
              │  │  │  └───┬───┘   └─────┬─────┘ │  │ │
              │  │  │      │   internal  │       │  │ │
              │  │  │      │     NLB ◄───┘       │  │ │
              │  │  │  (private apps use this)   │  │ │
              │  │  └────────────────────────────┘  │ │
              │  │   EBS volumes (disks for Kafka   │ │
              │  │   & NiFi live here too)          │ │
              │  └──────────────────────────────────┘ │
              │   CloudWatch Logs ◄── Fluent Bit      │
              │   IAM roles, Secrets Manager, ECR     │
              └───────────────────────────────────────┘

   GitLab (outside AWS) ──► runs Terraform & Helm ──► builds all of the above
```

**Read it top to bottom:**

1. Users on the internet hit an **ALB** (Application Load Balancer) sitting in **public subnets** — the only part of the front yard visible from the street.
2. The ALB forwards traffic to **NiFi pods** running on EKS nodes hidden in **private subnets** (the backyard — no direct street access).
3. NiFi pushes data into **Kafka brokers**, also in private subnets, reached through an **internal NLB** or in-cluster Services.
4. When pods need to reach *out* to the internet (download a package, call an API), they exit through the **NAT Gateway** — an outbound-only door.
5. Every log line ships to **CloudWatch**; every change to the setup is made by **GitLab pipelines**, never by hand.

**The golden rules of this design:**

1. **Nothing important lives in a public subnet.** Only doors (load balancers, NAT gateways) do.
2. **Three environments, three clusters, ideally three accounts.** Blast radius stays small.
3. **Humans don't click; pipelines do.** The console is for *looking*, GitLab is for *changing*.
4. **Everything is code** — network, cluster, apps, and even NiFi flows (via NiFi Registry).

---

# Part 3 — Designing the EKS Clusters (dev / stage / prod)

## 3.1 One cluster per environment — the simplest safe design

**WHAT:** We build **three separate EKS clusters**: `dp-dev`, `dp-stage`, `dp-prod` (dp = data platform). Same design, different sizes.

**WHY:** You *could* cram dev, stage, and prod into one cluster using namespaces, but then a dev experiment can eat prod's CPU, a bad upgrade breaks everything at once, and security boundaries get fuzzy. Separate clusters (in separate AWS accounts) mean:

- **Blast radius:** breaking dev breaks *only* dev.
- **Safe upgrades:** upgrade dev's Kubernetes version first, watch it for a week, then stage, then prod.
- **Clean billing:** each account's bill = that environment's cost.
- **Simple security:** prod credentials never exist in dev.

**HOW (account layout):**

| AWS Account | Cluster | Who can touch it | Size |
|---|---|---|---|
| `company-dev` | `dp-dev` | All engineers | Small (spot instances OK) |
| `company-stage` | `dp-stage` | Engineers via pipeline; read-only console | Medium (mirrors prod shape) |
| `company-prod` | `dp-prod` | **Pipeline only** + break-glass role | Full size, on-demand instances |

## 3.2 Cluster building blocks

**Managed Node Groups** — AWS-managed groups of EC2 worker machines. AWS handles the boring parts (joining the cluster, rolling updates).

**Karpenter (recommended) or Cluster Autoscaler** — robots that add/remove nodes automatically when pods need room. Karpenter is the modern choice: it picks the cheapest right-sized instance on the fly.

**EKS Add-ons** — AWS-packaged versions of the core plumbing. Always install these as *managed add-ons* so upgrades are one command:

| Add-on | What it does |
|---|---|
| `vpc-cni` | Gives every pod a real VPC IP address |
| `coredns` | Phone book (DNS) inside the cluster |
| `kube-proxy` | Routes Service traffic to pods |
| `aws-ebs-csi-driver` | Lets pods create/attach EBS disks (Kafka & NiFi need this!) |
| `eks-pod-identity-agent` | Lets pods assume IAM roles the modern way |
| `amazon-cloudwatch-observability` | Ships logs + metrics to CloudWatch (see Part 11) |

**Separate node groups for the heavy hitters.** Kafka and NiFi are memory- and disk-hungry. Give them their own node group with taints so random small apps don't land on (and fight with) them:

| Node group | Instance type (example) | For | Notes |
|---|---|---|---|
| `system` | m6i.large ×2–3 | CoreDNS, controllers, operators | Small and steady |
| `apps` | m6i.xlarge, autoscaled | General workloads | Spot OK in dev |
| `kafka` | r6i.2xlarge ×3 | Kafka brokers only | Tainted `dedicated=kafka:NoSchedule`, one per AZ |
| `nifi` | r6i.2xlarge ×3 | NiFi nodes only | Tainted `dedicated=nifi:NoSchedule` |

## 3.3 How pods get AWS permissions (very important!)

**WHAT:** Pods often need AWS powers — NiFi writing to S3, External Secrets reading Secrets Manager. **Never** put AWS access keys in the pod. Instead, attach an **IAM role to the pod's service account**.

Two mechanisms:

- **EKS Pod Identity** (newer, simpler — use this): install the `eks-pod-identity-agent` add-on, then map *cluster + namespace + service account → IAM role* with one API call.
- **IRSA** (IAM Roles for Service Accounts — older, still everywhere): uses an OIDC provider and an annotation on the service account. You'll see it in existing Terraform, so recognize it.

**WHY:** Keys in pods leak. Roles are temporary, automatic, and auditable in CloudTrail.

**HOW (Pod Identity example):**

```bash
# Map: in cluster dp-prod, namespace nifi, service account nifi-sa → this IAM role
aws eks create-pod-identity-association \
  --cluster-name dp-prod \
  --namespace nifi \
  --service-account nifi-sa \
  --role-arn arn:aws:iam::111122223333:role/nifi-s3-writer
```

## 3.4 Versions and upgrades

- EKS supports each Kubernetes version for a limited window; check the current calendar with `aws eks describe-cluster-versions` or the EKS docs.
- **Upgrade path:** dev → soak 1–2 weeks → stage → soak → prod. One minor version at a time.
- Upgrade order inside a cluster: **control plane → add-ons → node groups**.
- Never let clusters fall into "extended support" — it costs extra and means you're way behind.

## 3.5 Terraform layout for the clusters

Keep one repo, one folder per environment, shared modules. This is the "simplest to manage with GitLab" shape:

```
infra/                          # GitLab repo: data-platform-infra
├── modules/
│   ├── vpc/                    # our reusable VPC recipe
│   ├── eks/                    # our reusable cluster recipe
│   └── observability/
├── envs/
│   ├── dev/
│   │   ├── main.tf             # calls modules with small sizes
│   │   ├── backend.tf          # where state lives (unique per env!)
│   │   └── terraform.tfvars
│   ├── stage/                  # same files, medium sizes
│   └── prod/                   # same files, full sizes
└── .gitlab-ci.yml
```

**WHY this shape:** the *recipe* (modules) is written once; each env only says "how big." Diffing dev vs prod is trivial. Each env has its **own state file**, so a mistake in dev's state can't corrupt prod.

Popular building blocks: the community modules `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws` — battle-tested, don't reinvent them.

---

# Part 4 — Networking
### VPC, Subnets, Public vs Private Access, Load Balancers, Security Groups

Networking is where most real-world outages and security holes live, so slow down here.

## 4.1 The VPC — your gated neighborhood

**WHAT:** A **VPC (Virtual Private Cloud)** is your own private, fenced neighborhood inside AWS. Nothing gets in or out unless *you* build a gate. Every VPC has an address range (**CIDR block**), like `10.0.0.0/16` — that's 65,536 house numbers (IP addresses).

**WHY size matters for EKS:** With the AWS VPC CNI, **every single pod gets its own IP address** from your subnets. Kafka + NiFi + system pods + autoscaling = IPs disappear fast. Undersized subnets are the #1 rookie EKS mistake. Go big: `/16` VPC, and if you're worried, add a **secondary CIDR** (like `100.64.0.0/16`) just for pods later.

## 4.2 Subnets — front yard vs backyard

**WHAT:** A **subnet** is one street in the neighborhood, tied to one **Availability Zone (AZ)** — a physical data-center building. We use two kinds:

- **Public subnet (front yard):** has a route to the **Internet Gateway**. Things here can be reached from the internet *if* you allow it. Only doors live here: internet-facing load balancers and NAT gateways.
- **Private subnet (backyard):** **no** route from the internet. Things here can reach *out* through the NAT gateway but can never be reached directly from outside. **All EKS nodes, all pods, Kafka, and NiFi live here.**

**HOW — our standard subnet plan (per environment):**

| Subnet | AZ | CIDR | Type | What lives here |
|---|---|---|---|---|
| public-a | us-east-1a | 10.0.0.0/24 | Public | ALB, NAT-a |
| public-b | us-east-1b | 10.0.1.0/24 | Public | ALB, NAT-b |
| public-c | us-east-1c | 10.0.2.0/24 | Public | ALB, NAT-c |
| private-a | us-east-1a | 10.0.32.0/19 | Private | EKS nodes + pods |
| private-b | us-east-1b | 10.0.64.0/19 | Private | EKS nodes + pods |
| private-c | us-east-1c | 10.0.96.0/19 | Private | EKS nodes + pods |

Notice: public subnets are tiny (`/24` = 256 addresses — doors don't need many), private subnets are huge (`/19` = 8,192 addresses each — pods need lots). **Three AZs** so losing one building doesn't take you down.

**The gates:**

- **Internet Gateway (IGW):** the neighborhood's front gate. Two-way, but only public subnets route to it.
- **NAT Gateway:** an *exit-only* revolving door in each public subnet. Private things go out (pull images, call APIs); nothing comes in through it. One per AZ in prod (HA); one total in dev (cheaper).

**Magic tags EKS requires on subnets** (load balancer auto-discovery breaks without these):

| Tag | Value | Put on |
|---|---|---|
| `kubernetes.io/role/elb` | `1` | **Public** subnets (for internet-facing LBs) |
| `kubernetes.io/role/internal-elb` | `1` | **Private** subnets (for internal LBs) |
| `kubernetes.io/cluster/dp-prod` | `shared` | All subnets the cluster uses |

## 4.3 The EKS API endpoint — who can talk to the cluster's brain

The Kubernetes API endpoint (what `kubectl` talks to) has its own public/private setting:

| Mode | Meaning | Use for |
|---|---|---|
| Public + Private | Reachable from internet (lock down with allowed CIDRs!) and from inside VPC | dev, sometimes stage |
| **Private only** | Only reachable from inside the VPC / VPN / GitLab runners in the VPC | **prod** ✅ |

```bash
# Lock a cluster down to private-only API access
aws eks update-cluster-config --name dp-prod \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true
```

## 4.4 Load balancing — the restaurant hosts

**WHAT:** A load balancer is the **host at a restaurant door**: greets every guest (request) and seats them at a table (pod) that has room. AWS gives us two hosts, and we use both:

| | **ALB** (Application LB) | **NLB** (Network LB) |
|---|---|---|
| Understands | HTTP/HTTPS (Layer 7) — paths, headers, cookies | Raw TCP/TLS (Layer 4) — just connections |
| Best for | **NiFi UI**, web apps, APIs | **Kafka** (Kafka speaks its own TCP protocol, not HTTP) |
| Created by | Kubernetes `Ingress` | Kubernetes `Service type: LoadBalancer` |
| Extras | TLS termination, WAF, cognito/OIDC auth, sticky sessions | Millions of connections, static IPs, ultra-low latency |

**HOW:** Install the **AWS Load Balancer Controller** (a robot in the cluster that watches for Ingress/Service objects and builds real ALBs/NLBs). Then load balancers are just YAML:

**Public access example — NiFi UI for VPN users, via internet-facing ALB:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nifi-ui
  namespace: nifi
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing        # front yard
    alb.ingress.kubernetes.io/target-type: ip                # route straight to pods
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111122223333:certificate/abc-123
    alb.ingress.kubernetes.io/inbound-cidrs: 203.0.113.0/24  # ONLY the company VPN!
    alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.type=lb_cookie
spec:
  ingressClassName: alb
  rules:
  - host: nifi.dp-prod.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: { service: { name: nifi, port: { number: 8443 } } }
```

> Sticky sessions matter for NiFi: its UI wants you to keep talking to the same node.

**Private access example — Kafka for in-VPC apps, via internal NLB:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka-internal
  namespace: kafka
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal   # backyard only!
spec:
  type: LoadBalancer
  selector: { strimzi.io/cluster: dp-kafka, strimzi.io/kind: Kafka }
  ports:
  - { name: tls-clients, port: 9094, targetPort: 9094 }
```

**Decision rule:** *Anything a human browser touches* → ALB. *Anything speaking a binary protocol (Kafka, JDBC, NiFi site-to-site)* → NLB. *Public vs private* → the `scheme` annotation, plus which subnets it lands in (the magic tags from 4.2).

## 4.5 Security groups — bouncers with guest lists

**WHAT:** A security group (SG) is a **bouncer standing at each resource's door with a guest list**. Rules say who (source) may enter on which door number (port). Default answer is always **NO**. SGs are *stateful*: if a guest was let in, their reply can go back out automatically.

**WHY least privilege:** every open port is a possible break-in. The guest list should name specific friends (other SGs, VPN CIDR) — **never `0.0.0.0/0`** (the whole internet) on anything except an internet-facing load balancer's 443.

**HOW — the SG map for our platform:**

| Security Group | Inbound rule | Port | Source | Why |
|---|---|---|---|---|
| `sg-alb-public` | HTTPS | 443 | Company VPN CIDR (or 0.0.0.0/0 for truly public apps) | Users reach the ALB |
| `sg-eks-nodes` | All traffic | all | `sg-eks-nodes` (itself) | Pods/nodes talk to each other |
| `sg-eks-nodes` | HTTPS targets | 8443 | `sg-alb-public` | ALB forwards to NiFi pods |
| `sg-eks-nodes` | Kafka TLS | 9094 | `sg-internal-clients` | In-VPC apps reach Kafka via NLB |
| `sg-eks-cluster` | HTTPS | 443 | `sg-eks-nodes` | Nodes call the K8s API |
| `sg-internal-clients` | (outbound only) | — | — | Attached to app EC2s/lambdas that consume Kafka |

**Pro move:** notice sources are *other security groups*, not IP lists. If the ALB gets a new IP tomorrow, the rule still works. Bouncers recognize club membership cards, not faces.

**Inside the cluster**, security groups don't see pod-to-pod traffic. For that, use **Kubernetes NetworkPolicies** (Part 5.5) — bouncers *inside* the building, between apartments.

## 4.6 Quick recap picture

```
Internet ──443──► ALB (public subnet, sg-alb-public)
                    │ 8443
                    ▼
              NiFi pods ──9092/9094──► Kafka pods        (private subnets, sg-eks-nodes)
                    │                        ▲
                    └── outbound via NAT     │ 9094
                                     Internal NLB ◄──── other VPC apps (sg-internal-clients)
```

---

# Part 5 — Multi-Tenant Setup
### Namespaces, RBAC roles, IAM mapping, quotas, network walls

**WHAT is multi-tenancy:** several teams ("tenants") share one cluster like families share an **apartment building**. Each family gets its own apartment (namespace), its own keys (roles), a utilities cap (quotas), and locked doors between apartments (network policies).

**WHY:** clusters are expensive; sharing dev/stage clusters across teams saves money — *as long as* teams can't see or break each other's stuff.

## 5.1 Namespaces — the apartments

```bash
kubectl create namespace team-orders
kubectl create namespace team-analytics
kubectl label namespace team-orders tenant=orders cost-center=1234
```

Rule of thumb: one namespace per team per app family (`team-orders`, `team-orders-batch`). Platform stuff gets its own (`kafka`, `nifi`, `kube-system`, `observability`).

## 5.2 Two permission systems working together

This confuses everyone at first, so read twice:

1. **IAM (AWS)** answers: *"Is this person/pipeline allowed to talk to the cluster at all, and as who?"*
2. **RBAC (Kubernetes)** answers: *"Now that they're inside, which apartments and which actions are allowed?"*

The bridge between them is **EKS Access Entries** — a mapping table that says "this IAM role = these Kubernetes groups." (Old clusters used a ConfigMap named `aws-auth` for this; you'll still see it during audits — same idea, clunkier.)

**HOW — give Team Orders' devs access to only their namespace:**

**Step 1 — IAM side.** Their SSO role is `arn:aws:iam::111122223333:role/TeamOrdersDev`.

```bash
aws eks create-access-entry \
  --cluster-name dp-dev \
  --principal-arn arn:aws:iam::111122223333:role/TeamOrdersDev \
  --kubernetes-groups team-orders-devs
```

**Step 2 — Kubernetes side.** A Role (list of allowed actions *inside one namespace*) + a RoleBinding (glue group → role):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-full
  namespace: team-orders
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "pods/log", "deployments", "statefulsets",
              "services", "configmaps", "jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]            # can read, not edit, secrets
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: team-orders-devs-binding
  namespace: team-orders
subjects:
- kind: Group
  name: team-orders-devs            # matches the access entry above
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: dev-full
  apiGroup: rbac.authorization.k8s.io
```

**The standard role ladder (define once as ClusterRoles, bind per namespace):**

| Role | Who gets it | Can do |
|---|---|---|
| `viewer` | Support L1, auditors | `get/list/watch` everything, no secrets |
| `developer` | Team engineers (dev/stage) | Full control **in their namespace only** |
| `deployer` | GitLab pipeline service role | Apply manifests in target namespaces |
| `platform-admin` | Platform team | Cluster-wide, node/CRD management |
| `break-glass` | On-call, prod, logged & alarmed | cluster-admin, time-boxed |

**Golden rule for prod:** humans get `viewer`; only the **pipeline's** IAM role gets `deployer`. Changes go through Git, period.

## 5.3 Resource quotas — the utilities cap

**WHY:** without caps, one tenant's runaway job eats all CPU and starves Kafka. Quotas are the breaker box per apartment.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-orders-quota
  namespace: team-orders
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 64Gi
    limits.cpu: "40"
    limits.memory: 128Gi
    persistentvolumeclaims: "10"
    services.loadbalancers: "1"     # LBs cost money — cap them!
---
apiVersion: v1
kind: LimitRange                     # defaults so pods without limits get sane ones
metadata:
  name: defaults
  namespace: team-orders
spec:
  limits:
  - type: Container
    default:        { cpu: "1",   memory: 1Gi }
    defaultRequest: { cpu: "250m", memory: 256Mi }
```

## 5.4 IAM per tenant (pods)

Each tenant's pods get **their own** IAM role via Pod Identity (Part 3.3). Team Orders' role can touch `s3://orders-*` only; Team Analytics' role can touch `s3://analytics-*` only. Never one shared fat role.

## 5.5 Network policies — locked doors between apartments

**WHAT:** NetworkPolicies are firewall rules **between pods**. Default Kubernetes is "everyone can knock on everyone's door" — bad for multi-tenant.

**HOW — the standard pair per tenant namespace:**

```yaml
# 1) Slam every door shut by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: team-orders }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
# 2) Re-open only what's needed: same namespace + platform ingress + Kafka
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: allow-needed, namespace: team-orders }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {}                                   # neighbors in own namespace
    - namespaceSelector:
        matchLabels: { kubernetes.io/metadata.name: nifi }   # NiFi may deliver data
```

(Enforcement needs a network policy engine — enable it in the VPC CNI settings or run Cilium/Calico. Verify with a quick `kubectl exec ... curl` test between namespaces.)

---

# Part 6 — Running Kafka on EKS

## 6.1 First decision: MSK or self-managed?

Be honest with yourselves here:

| | **Amazon MSK** (managed Kafka) | **Strimzi on EKS** (self-managed) |
|---|---|---|
| Who patches brokers | AWS | You |
| Cost | Higher sticker price | Lower sticker, higher people-time |
| Control/custom configs | Limited | Total |
| Where it runs | AWS's infra in your VPC | Your EKS nodes |
| Pick when | Small team, Kafka is a utility | Kafka expertise in-house, special needs, portability |

Many teams run **MSK for prod** and **Strimzi in dev** for cheap experiments. Both are legitimate; the rest of this part covers the Strimzi path since that's the EKS skill set.

## 6.2 Strimzi — the Kafka robot operator

**WHAT:** Strimzi is a Kubernetes **operator**: a robot that knows how to run Kafka. You write a short YAML wish ("3 brokers, 3 controllers, 1 TB disks, TLS on"), and the robot builds and babysits it — rolling restarts, cert rotation, config changes.

**HOW:**

```bash
helm repo add strimzi https://strimzi.io/charts/
helm install strimzi-operator strimzi/strimzi-kafka-operator \
  -n kafka --create-namespace
```

Then the wish (modern **KRaft** mode — no ZooKeeper):

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: brokers
  namespace: kafka
  labels: { strimzi.io/cluster: dp-kafka }
spec:
  replicas: 3
  roles: [broker]
  storage:
    type: jbod
    volumes:
    - id: 0
      type: persistent-claim
      size: 1000Gi
      class: gp3-kafka          # a gp3 StorageClass you define
      deleteClaim: false        # NEVER auto-delete Kafka's disks!
  resources:
    requests: { cpu: "2", memory: 16Gi }
    limits:   { cpu: "4", memory: 16Gi }
  template:
    pod:
      tolerations:
      - { key: dedicated, value: kafka, effect: NoSchedule }   # the tainted nodes
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: controllers
  namespace: kafka
  labels: { strimzi.io/cluster: dp-kafka }
spec:
  replicas: 3
  roles: [controller]
  storage:
    type: persistent-claim
    size: 20Gi
    class: gp3-kafka
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: dp-kafka
  namespace: kafka
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    listeners:
    - { name: tls,      port: 9093, type: internal,     tls: true }   # in-cluster apps
    - { name: external, port: 9094, type: loadbalancer, tls: true,    # in-VPC apps
        configuration: { bootstrap: { annotations:
          { service.beta.kubernetes.io/aws-load-balancer-scheme: internal } } } }
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      auto.create.topics.enable: false      # topics are code, not accidents
    rack:
      topologyKey: topology.kubernetes.io/zone   # spread copies across AZs!
  entityOperator: { topicOperator: {}, userOperator: {} }
```

**The non-negotiables baked in above, and WHY:**

1. **3 brokers, replication 3, min-ISR 2** → any single broker or AZ can die with zero data loss.
2. **Rack awareness on zones** → the 3 copies live in 3 different buildings.
3. **`deleteClaim: false`** → deleting the Kafka object never deletes the data disks.
4. **gp3 EBS volumes** → cheap, and you can dial IOPS/throughput without resizing.
5. **`auto.create.topics.enable: false`** → topics come from `KafkaTopic` YAML in Git, with review.
6. **TLS everywhere; internal-scheme NLB only** → Kafka is never on the public internet. Ever.

**Topics and users as code:**

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders.events
  namespace: kafka
  labels: { strimzi.io/cluster: dp-kafka }
spec:
  partitions: 12
  replicas: 3
  config: { retention.ms: "604800000" }   # keep letters 7 days
```

---

# Part 7 — Running NiFi on EKS

## 7.1 What makes NiFi tricky on Kubernetes

NiFi is **stateful three times over**: it stores (1) the flow design, (2) the data currently in the pipes, and (3) the provenance history — all on disk. So NiFi runs as a **StatefulSet** where every pod keeps its own EBS volumes, on the dedicated tainted nodes from Part 3.2.

**Version note:** **NiFi 2.x is the one to deploy on EKS.** NiFi 1.x needed a ZooKeeper cluster for coordination; NiFi 2.x can use Kubernetes itself for leader election and cluster state — fewer moving parts. If you inherit a 1.x + ZooKeeper setup on EC2, that's normal; you'll modernize during migration.

## 7.2 The deployment shape

Use a maintained Helm chart (or your own chart) with these essentials in `values.yaml`:

```yaml
replicaCount: 3

persistence:                    # separate disks per repository = performance + safety
  flowfileRepo:    { size: 50Gi,  storageClass: gp3 }
  contentRepo:     { size: 500Gi, storageClass: gp3 }
  provenanceRepo:  { size: 200Gi, storageClass: gp3 }

resources:
  requests: { cpu: "2", memory: 8Gi }
  limits:   { cpu: "4", memory: 12Gi }   # also set NiFi JVM heap ~= 8g, below the limit

tolerations:
- { key: dedicated, value: nifi, effect: NoSchedule }

auth:
  oidc:                          # humans log in with SSO, not nifi-generated certs
    discoveryUrl: https://sso.example.com/.well-known/openid-configuration
    clientId: nifi-prod

service: { httpsPort: 8443 }
```

Expose the UI with the **sticky-session ALB Ingress from Part 4.4**. NiFi's UI + API is port **8443**; nodes also chat cluster-protocol with each other (chart handles those ports internally).

## 7.3 NiFi Registry — flows are code too

**WHAT:** NiFi Registry is Git-style version control for flows. You *commit* a process group in dev, then *import that exact version* in stage and prod.

**WHY this is the whole ballgame for dev→stage→prod:** without Registry, "promotion" means a human re-dragging boxes in prod and hoping. With it:

1. Developer builds/edits flow in **dev** NiFi → right-click process group → *Commit version* to Registry (which stores to a Git repo).
2. **Stage** NiFi imports version N; pipeline runs test data through; checks pass.
3. **Prod** NiFi upgrades to version N — a two-click (or scripted, via NiFi Toolkit/API) operation.
4. Environment differences (bucket names, Kafka endpoints, passwords) live in **Parameter Contexts** per environment — the flow is identical, only parameters change. Secrets come from AWS Secrets Manager via the **External Secrets Operator**, never typed into the canvas.

```
dev canvas ──commit──► NiFi Registry (backed by Git) ──import──► stage ──promote──► prod
                          ▲ the single source of truth ▲
```

## 7.4 NiFi ↔ Kafka wiring

In-cluster, NiFi's Kafka processors point at the internal bootstrap Service — no load balancer needed:

```
Kafka Brokers (bootstrap): dp-kafka-kafka-bootstrap.kafka.svc:9093
Security Protocol: SSL   (certs via Strimzi's KafkaUser + mounted secret)
```

Sizing tip: one `ConsumeKafka` processor with **concurrent tasks = partitions ÷ NiFi nodes** is the usual starting point.

---

# Part 8 — GitLab CI/CD
### dev → stage → prod, the simple and safe way

## 8.1 The philosophy

**WHAT:** GitLab pipelines are the *only* hands that change infrastructure and apps. A change is a **merge request (MR)** → reviewed → merged → robot deploys.

**WHY:** repeatable, reviewable, revertible, and auditable. "Who changed the security group?" is answered by `git log`, not by shrugging.

**The promotion river (memorize this):**

```
feature branch ──MR──► main branch
      │                   │
   plan only          auto-deploy DEV
  (see changes)           │
                     ✅ smoke tests
                          │
                  ▶ button: deploy STAGE   (protected environment)
                          │
                     ✅ full tests
                          │
                  ▶ button: deploy PROD    (protected env + 2nd approver)
```

Same artifact/commit flows through all three. **Nothing reaches prod that didn't live in stage first.**

## 8.2 Repos — keep it to three

| Repo | Contains | Deploys via |
|---|---|---|
| `data-platform-infra` | Terraform: VPC, EKS, IAM, node groups (layout from Part 3.5) | `terraform plan/apply` |
| `data-platform-apps` | Helm values / manifests: Strimzi, Kafka CRs, NiFi, ingress, quotas, RBAC | `helm upgrade` / `kubectl apply` |
| `nifi-flows` | NiFi Registry's Git backing store (flow versions) | NiFi Registry promotion |

## 8.3 GitLab → AWS without passwords (OIDC)

**Never store long-lived AWS keys in GitLab variables.** Use **OIDC federation**: GitLab hands the job a signed ID token; AWS trades it for short-lived credentials for a role like `gitlab-deployer-dev`. Setup is one IAM Identity Provider + one role trust policy per account; each job then does:

```yaml
# snippet used by every deploy job
.aws_auth:
  id_tokens:
    GITLAB_OIDC_TOKEN: { aud: https://gitlab.example.com }
  before_script:
    - >
      export $(aws sts assume-role-with-web-identity
      --role-arn "$AWS_ROLE_ARN"
      --role-session-name "gl-$CI_PIPELINE_ID"
      --web-identity-token "$GITLAB_OIDC_TOKEN"
      --duration-seconds 3600
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
      --output text | awk '{print "AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')
```

`AWS_ROLE_ARN` is a GitLab **environment-scoped CI/CD variable** — the dev environment gets the dev account's role, prod gets prod's. That's how one pipeline file safely targets three accounts.

## 8.4 The infra pipeline (`data-platform-infra/.gitlab-ci.yml`)

```yaml
stages: [validate, plan, apply]

default:
  image: hashicorp/terraform:1.9        # or opentofu/opentofu

variables:
  TF_IN_AUTOMATION: "true"

# ---- reusable job templates ----
.tf:
  extends: .aws_auth
  before_script:
    - !reference [.aws_auth, before_script]
    - cd envs/$ENV && terraform init -input=false

.plan:
  extends: .tf
  stage: plan
  script:
    - terraform plan -input=false -out=tf.plan
    - terraform show -no-color tf.plan     # reviewers read this in the MR
  artifacts: { paths: ["envs/$ENV/tf.plan"], expire_in: 1 week }

.apply:
  extends: .tf
  stage: apply
  script: [ "terraform apply -input=false tf.plan" ]
  rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }]

# ---- lint every MR ----
validate:
  stage: validate
  script: [ "terraform fmt -check -recursive", "cd envs/dev && terraform init -backend=false && terraform validate" ]

# ---- per environment ----
plan:dev:    { extends: .plan,  variables: { ENV: dev },   environment: { name: dev } }
apply:dev:   { extends: .apply, variables: { ENV: dev },   environment: { name: dev },
               needs: [plan:dev] }                                   # auto on merge

plan:stage:  { extends: .plan,  variables: { ENV: stage }, environment: { name: stage },
               rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }] }
apply:stage: { extends: .apply, variables: { ENV: stage }, environment: { name: stage },
               needs: [plan:stage], when: manual }                    # ▶ button

plan:prod:   { extends: .plan,  variables: { ENV: prod },  environment: { name: prod },
               rules: [{ if: '$CI_COMMIT_BRANCH == "main"' }] }
apply:prod:  { extends: .apply, variables: { ENV: prod },  environment: { name: prod },
               needs: [apply:stage, plan:prod], when: manual }        # ▶ + approvals
```

**State storage:** each env's `backend.tf` points to either **GitLab-managed Terraform state** (zero setup: `http` backend at your project's API URL) or an **S3 bucket + DynamoDB lock table per account**. Either is fine; pick one and never mix. One state file per environment — remember, that isolation is the safety net.

**Guardrails to switch on in GitLab (Settings):**

1. **Protected branch** `main` — merge only via approved MR.
2. **Protected environments** `stage`, `prod` — only Maintainers (or a deploy group) can press ▶; add *approval rules* on prod so a second human confirms.
3. **Merge checks** — pipeline must pass; `plan` output attached for reviewers.

## 8.5 The apps pipeline (Helm)

Same skeleton, different verbs:

```yaml
.deploy:
  extends: .aws_auth
  image: alpine/k8s:1.31.4                 # kubectl + helm in one image
  script:
    - !reference [.aws_auth, before_script]
    - aws eks update-kubeconfig --name dp-$ENV --region us-east-1
    - helm upgrade --install nifi  ./charts/nifi  -n nifi  -f values/$ENV/nifi.yaml  --wait
    - helm upgrade --install kafka ./charts/kafka -n kafka -f values/$ENV/kafka.yaml --wait
    - kubectl apply -f tenants/$ENV/        # quotas, RBAC, network policies

deploy:dev:   { extends: .deploy, variables: { ENV: dev },   environment: { name: dev } }
test:dev:     { stage: test, needs: [deploy:dev], script: ["./tests/smoke.sh dev"] }
deploy:stage: { extends: .deploy, variables: { ENV: stage }, environment: { name: stage },
                needs: [test:dev], when: manual }
deploy:prod:  { extends: .deploy, variables: { ENV: prod },  environment: { name: prod },
                needs: [deploy:stage], when: manual }
```

The per-env `values/` folders are the *only* place environments differ (replica counts, hostnames, sizes). The charts are identical — that's what makes stage a truthful rehearsal of prod.

**Secrets:** application secrets live in **AWS Secrets Manager**, pulled into the cluster by the **External Secrets Operator** (whose pod has an IAM role via Pod Identity). GitLab CI/CD variables hold only pipeline-level settings (role ARNs, cluster names) — masked and protected.

---

# Part 9 — Migrating from EC2

You inherit NiFi and Kafka running on plain EC2 boxes. Here's the flight plan. The strategy for both is the same shape: **build new next to old → copy/replicate → move readers, then writers → watch → retire old.** Never a big-bang switch.

## 9.1 The phases

| Phase | What happens | Output |
|---|---|---|
| **1. Discover** | Inventory everything (Part 10 tells you where to look) | Spreadsheet of hosts, versions, configs, data sizes, who-talks-to-whom |
| **2. Assess** | Version gaps? (Kafka w/ ZooKeeper? NiFi 1.x?) Custom hacks? Data volume? | Risk list + target versions |
| **3. Build** | Stand up EKS platform (Parts 3–8) in dev, prove it with test data | Working empty platform |
| **4. Replicate** | Mirror Kafka data; import NiFi flows; run **in parallel** | Old & new both alive, new is a shadow |
| **5. Cut over** | Move consumers → producers (Kafka); drain & switch senders (NiFi) | Traffic on new |
| **6. Watch** | 1–2 weeks of soak; old cluster idle but intact = instant rollback | Confidence |
| **7. Retire** | Snapshot old disks, stop instances, wait 30 days, terminate | 💰 savings |

## 9.2 Discovery checklist (fill this in before anything else)

```
□ EC2 instances: IDs, types, AZs, AMIs, attached EBS volumes & sizes
□ Kafka: version, ZooKeeper or KRaft?, broker count, topic list w/ partitions,
  retention settings, total data on disk, TLS/SASL config, ACLs
□ Kafka clients: every producer & consumer group (ask Kafka itself:
  kafka-consumer-groups.sh --bootstrap-server old:9092 --list)
□ NiFi: version, node count, flow inventory (screenshot canvas + export flow
  definitions), controller services, parameter/variable values, custom NARs
  (custom processors!), state (e.g., "last file pulled" markers)
□ Network: DNS names clients use TODAY (these become your cutover levers),
  security groups, who connects from where
□ Secrets: where do current passwords/certs live?
□ Terraform/CFN: is any of this already codified? (Part 10)
```

## 9.3 Kafka migration with MirrorMaker 2

**WHAT:** MirrorMaker 2 (MM2) is Kafka's built-in **photocopier between clusters**: it continuously copies topics *and consumer-group bookmarks (offsets)* from old to new. Strimzi runs it as a simple YAML (`KafkaMirrorMaker2` resource).

**HOW — the ordered moves:**

```
Step 1  Deploy MM2 on EKS: source = old EC2 cluster, target = new cluster.
        Copy topics, configs, and checkpoints. Let it catch up (lag → ~0).

Step 2  VERIFY: message counts match, spot-check payloads, checkpoint
        topic is flowing.

Step 3  Move CONSUMERS first, one group at a time:
        stop group → point bootstrap at new cluster → start.
        MM2's offset translation means they resume where they left off.
        (Consumers first = they can already see all old data on the new side.)

Step 4  Move PRODUCERS, one app at a time:
        point at new cluster → new messages now land on new only.
        Consumers there see them instantly.

Step 5  Old cluster goes quiet. Keep MM2 off, old cluster idle for the
        rollback window. Then retire.
```

**Rollback at any step:** point the moved app back at the old bootstrap address. This is why you migrate *one client at a time* and why DNS CNAMEs (e.g., `kafka.internal.example.com`) beat hardcoded IPs — cutover becomes a DNS flip.

**Gotchas:** MM2 can prefix topic names with the source cluster alias (`old.orders.events`) — set `replication.policy.class` to the IdentityReplicationPolicy if you need identical names. Recreate ACLs/users on the new side *before* moving clients.

## 9.4 NiFi migration

NiFi's data-in-the-pipes makes this different: you don't copy queues, you **drain** them.

```
Step 1  Stand up NiFi 2.x on EKS (Part 7), connected to NiFi Registry.

Step 2  On OLD NiFi: version-control each process group into Registry
        (or export flow definitions as JSON files → commit to Git).

Step 3  On NEW NiFi: import flows from Registry. Recreate controller
        services & parameter contexts pointing at NEW endpoints
        (new Kafka bootstrap, same S3 buckets, etc.). Install any
        custom NARs into the new image. Fix 1.x→2.x deprecated
        processors now, in dev.

Step 4  Parallel run: enable the new flow against test/duplicate input.
        Compare outputs old vs new. Migrate processor STATE carefully
        (e.g., ListFile/ListS3 "what have I already pulled" markers) —
        otherwise the new cluster re-ingests everything or skips data.

Step 5  Cut over per flow:
          a. STOP the source processors on OLD (intake valves off)
          b. Let OLD queues drain to zero (watch the canvas)
          c. START source processors on NEW
          d. Flip any push-senders' DNS to the new NLB/ALB
        Order matters: b before c prevents double-processing.

Step 6  Old NiFi sits stopped-but-intact for the rollback window.
```

**The classic traps:** custom NARs nobody remembered building; passwords that only exist inside the old `nifi.properties`/flow (extract them into Secrets Manager first!); and forgetting processor state (Step 4) — the silent duplicate-data machine.

## 9.5 What about the EC2 boxes themselves?

Don't "lift and shift" the VMs into containers. The *apps* (Kafka, NiFi) move as fresh, clean, versioned installs on EKS; only their **data and flows** migrate. The EC2 instances' last job is to be the rollback parachute, then a snapshot, then a memory.

---

# Part 10 — Auditing What Already Exists
### Reading Terraform, reading CloudFormation, and where to click in the console

Support work is 80% detective work. The question is always: *"What exists, why, and does reality match the blueprints?"* You have three evidence sources.

## 10.1 Reading a Terraform repo (the blueprints, HashiCorp flavor)

**Tour of the files:**

| File | What it tells you |
|---|---|
| `main.tf` | The resources being built (or `module` blocks calling recipes) |
| `variables.tf` | The knobs — every input the recipe accepts |
| `terraform.tfvars` / `*.auto.tfvars` | The knob *settings* for this environment (sizes, CIDRs, names) |
| `outputs.tf` | What this stack exports (cluster name, VPC ID) for humans/other stacks |
| `backend.tf` / `backend "s3"` block | **Where the state file lives** — find this first |
| `versions.tf` | Terraform + provider versions pinned |
| `modules/` | Local reusable recipes |
| `.terraform.lock.hcl` | Exact provider versions (like a package lock file) |

**The commands that answer audit questions (read-only, safe):**

```bash
terraform init                 # connect to the state backend (needed first)
terraform state list           # EVERY resource Terraform believes it owns
terraform state show aws_eks_cluster.this     # full detail on one resource
terraform output               # the exported values
terraform plan                 # ★ DRIFT DETECTOR ★ — "No changes" = reality
                               #   matches code. Anything else = someone
                               #   clicked in the console, or code changed
terraform providers            # which clouds/plugins are in play
grep -r "module " --include="*.tf" .          # map the recipe structure fast
```

**Reading a resource block, decoded:**

```hcl
resource "aws_security_group_rule" "kafka_in" {   # TYPE . local NICKNAME
  security_group_id = aws_security_group.nodes.id # ref to another resource here
  type        = "ingress"
  from_port   = 9094
  to_port     = 9094
  protocol    = "tcp"
  source_security_group_id = var.client_sg_id     # var.* → look in variables.tf,
}                                                 # value in terraform.tfvars
```

Follow the breadcrumbs: `var.x` → `variables.tf`/`tfvars`; `module.vpc.private_subnets` → that module's `outputs.tf`; `data "aws_..."` → Terraform *reading* something it doesn't own.

## 10.2 Reading CloudFormation (the blueprints, AWS flavor)

**Console path:** **CloudFormation → Stacks** → click a stack, then walk the tabs:

| Tab | Audit gold |
|---|---|
| **Resources** | Every AWS object this stack owns, with clickable physical IDs |
| **Template** | The YAML/JSON blueprint itself |
| **Parameters** | The knob settings used at deploy time |
| **Outputs** | Exported values (often consumed by *other* stacks — dependency clue!) |
| **Events** | Deploy history — great for "when did this change/break" |
| **Change sets** | Pending, not-yet-applied changes |

**Drift detection (CFN's version of `terraform plan`):** Stack → **Stack actions → Detect drift** → then *View drift results* shows exactly which properties were hand-edited away from the template.

**Template skeleton, decoded:**

```yaml
Parameters:            # the knobs
  Env: { Type: String }
Resources:             # ★ the actual stuff — read this section first ★
  KafkaSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      VpcId: !Ref VpcId              # !Ref = "the value of that parameter/resource"
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 9092, ToPort: 9092,
            SourceSecurityGroupId: !GetAtt ClientSG.GroupId }   # !GetAtt = an attribute
Outputs:               # what it exports
  KafkaSGId: { Value: !Ref KafkaSG, Export: { Name: !Sub "${Env}-kafka-sg" } }
```

`Fn::ImportValue` / `!ImportValue` in one stack ← matches an `Export` in another = cross-stack dependency. Map these before touching anything.

## 10.3 AWS Console — the "where do I click" audit map

The console shows **reality** (vs. the blueprints above). Bookmark this table:

| Question | Console location | Look at |
|---|---|---|
| What servers exist? | **EC2 → Instances** | State, type, AZ, **Tags** (esp. `aws:cloudformation:stack-name` — instant "which stack owns me") |
| What disks / are any orphaned? | **EC2 → Volumes** | State "available" = unattached = paying for nothing |
| Network layout? | **VPC** → Subnets / Route tables / NAT / IGW | Route table with `0.0.0.0/0 → igw-…` = that subnet is **public** |
| Who can reach what? | **EC2 → Security Groups** | Any `0.0.0.0/0` inbound that isn't a public LB:443 = 🚨 |
| Load balancers? | **EC2 → Load Balancers** + Target groups | Scheme internet-facing vs internal; unhealthy targets |
| Kubernetes clusters? | **EKS → Clusters** | Version (behind?), endpoint access, add-on versions, **Access entries**, logging on/off |
| Who has AWS power? | **IAM** → Roles / Users / **IAM → Access Analyzer** | Users with keys >90 days, `AdministratorAccess` sprawl, unused roles |
| Managed Kafka? | **MSK → Clusters** | Might already exist! Version, broker sizes |
| What changed & who did it? | **CloudTrail → Event history** | Filter by resource name or username; 90 days searchable free |
| Is config compliant / history of a resource? | **Config → Resources** | Timeline of every change to e.g. a security group |
| What's this all costing? | **Cost Explorer** (Billing) | Group by **Service**, then by **Tag: environment** — untagged spend = mystery meat |
| Quick wins / risks? | **Trusted Advisor** | Idle LBs, open ports, low utilization |
| Every resource with tag X? | **Resource Groups → Tag Editor** | Search all regions for `env=prod`, or find the **untagged** |
| Logs? | **CloudWatch → Log groups** | What exists, retention (Never expire = 💸), last event time |

**The 60-second "who owns this mystery EC2 box" ritual:** Instance → **Tags** tab → look for `aws:cloudformation:stack-name` (CFN-owned) or team tags → no tags? → **CloudTrail**: search event `RunInstances` + the instance ID → find the IAM identity that launched it → if it's Terraform's role, `grep` the repos for the instance's Name tag.

**CLI one-liners for the audit spreadsheet:**

```bash
# All instances: id, type, state, Name tag
aws ec2 describe-instances --query \
 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`]|[0].Value]' \
 --output table

# Everything tagged env=prod, all services
aws resourcegroupstaggingapi get-resources --tag-filters Key=env,Values=prod \
  --query 'ResourceTagMappingList[].ResourceARN'

# Security groups open to the world
aws ec2 describe-security-groups --filters Name=ip-permission.cidr,Values='0.0.0.0/0' \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output table
```

## 10.4 Putting it together — the audit workflow

```
1. Blueprints:  read Terraform repos (state list) + CFN stacks (Resources tabs)
2. Reality:     console + CLI inventory (tables above)
3. Diff:        terraform plan (per env) + CFN drift detection
4. Orphans:     reality minus blueprints = hand-made resources → adopt into
                code (terraform import) or schedule for deletion
5. Risks:       open SGs, untagged spend, old keys, EKS versions, unencrypted volumes
6. Report:      one page per environment: owns/costs/risks/actions
```

---

# Part 11 — Logging and Monitoring

**WHY first:** when Kafka hiccups at 2 a.m., logs are your time machine. And auditors *will* ask "who accessed prod and what did they change?" No logs = no answers = failed audit.

## 11.1 The four layers of logging

| Layer | What it captures | Where it goes | How to enable |
|---|---|---|---|
| **1. AWS API** | Every AWS action by anyone (human/pipeline/pod role) | **CloudTrail** → S3 + CW Logs | Org-level trail, all regions, on day one |
| **2. EKS control plane** | K8s API calls, **audit** (who did what in-cluster), authenticator (which IAM role mapped in), scheduler | CloudWatch: `/aws/eks/dp-prod/cluster` | Cluster setting — turn **all five** on in prod |
| **3. Container stdout/stderr** | Every pod's console output (Kafka broker logs, NiFi app logs) | CloudWatch via Fluent Bit | `amazon-cloudwatch-observability` add-on |
| **4. App-specific** | NiFi provenance & `nifi-user.log`, Kafka client metrics | NiFi repos / Prometheus | Chart config |

**Enable layers 2+3 (Terraform snippet for the EKS module):**

```hcl
cluster_enabled_log_types = ["api", "audit", "authenticator",
                             "controllerManager", "scheduler"]

cluster_addons = {
  amazon-cloudwatch-observability = {}   # installs Fluent Bit + Container Insights agent
}
```

Result: log groups `/aws/containerinsights/dp-prod/application` (pod logs), `/performance` (metrics), and `/aws/eks/dp-prod/cluster` (control plane). **Set retention** on every group (e.g., 30 days dev, 90+ prod) — "Never expire" quietly becomes a giant bill.

## 11.2 Reading logs like a support engineer

```bash
# Live tail one pod (first stop, always)
kubectl logs -n kafka dp-kafka-brokers-0 -f --tail=200

# Previous crashed container (the "why did it restart" question)
kubectl logs -n nifi nifi-1 --previous

# Search ALL pods' logs across the cluster (CloudWatch Logs Insights):
# Console → CloudWatch → Logs Insights → group /aws/containerinsights/dp-prod/application
fields @timestamp, kubernetes.pod_name, log
| filter kubernetes.namespace_name = "kafka" and log like /ERROR/
| sort @timestamp desc | limit 100

# Kubernetes audit: WHO deleted that deployment?
# group /aws/eks/dp-prod/cluster, stream kube-apiserver-audit-*
fields @timestamp, user.username, verb, objectRef.namespace, objectRef.name
| filter verb = "delete" and objectRef.resource = "deployments"
```

## 11.3 Metrics & dashboards

- **Container Insights** (comes with the add-on): CPU/memory/disk per pod, node, namespace — Console → CloudWatch → Container Insights.
- **Prometheus + Grafana** (or Amazon Managed Prometheus/Grafana) for the deep stuff: Strimzi and NiFi both export rich Prometheus metrics.
- **The alarms you must have from day one:**

| Alarm | Why it's the canary |
|---|---|
| Kafka **under-replicated partitions > 0** | A broker/AZ is sick; data safety margin shrinking |
| Kafka **consumer lag** growing | Readers can't keep up — downstream is falling behind |
| **Broker/NiFi disk > 75%** | Full disk = hard outage for stateful apps |
| NiFi **back-pressured connections** | Pipes are full; flow is stuck |
| Pod **restart loops** (CrashLoopBackOff) | Something is dying repeatedly |
| Node **NotReady** | Capacity loss |
| **Cert expiry < 30 days** | TLS everywhere means expiry = outage |

## 11.4 Multi-tenant logging etiquette

Tag every log with its namespace (Fluent Bit does automatically via `kubernetes.*` fields). Tenants get CloudWatch access scoped to *their* log streams via IAM conditions; the audit log group is platform-team-only. Nobody gets to edit or delete log groups except a break-glass role — logs you can tamper with prove nothing.

---

# Glossary

| Term | Plain meaning |
|---|---|
| **ALB / NLB** | Web-smart / raw-TCP load balancer (restaurant host) |
| **AZ** | Availability Zone — one physical data-center building |
| **CIDR** | An IP address range, e.g. `10.0.0.0/16` (smaller /number = bigger range) |
| **CloudFormation** | AWS's own infrastructure-as-code (stacks + templates) |
| **CloudTrail** | The security camera recording every AWS API call |
| **CloudWatch** | AWS's logs + metrics + alarms service |
| **Container** | Sealed lunchbox: app + everything it needs |
| **Drift** | Reality no longer matching the code (someone clicked) |
| **EBS / gp3** | Virtual hard drives / the cheap-fast standard type |
| **EKS** | AWS-managed Kubernetes (AWS runs the brain) |
| **Helm** | Package manager for Kubernetes apps ("charts") |
| **IAM** | AWS's who-may-do-what system (users, roles, policies) |
| **Ingress** | Kubernetes object describing the HTTP front door |
| **IRSA / Pod Identity** | Ways to give a pod an IAM role instead of keys |
| **KRaft** | Modern Kafka coordination — no ZooKeeper needed |
| **MirrorMaker 2** | Kafka's cluster-to-cluster photocopier (migrations) |
| **MSK** | Amazon's managed Kafka service |
| **NAT Gateway** | Exit-only door for private subnets |
| **NetworkPolicy** | Firewall rules between pods |
| **NiFi Registry** | Version control (Git-like) for NiFi flows |
| **OIDC** | Token-based identity handshake (GitLab→AWS, SSO→NiFi) |
| **Operator (Strimzi)** | In-cluster robot that runs an app for you |
| **Provenance** | NiFi's package-tracking history per piece of data |
| **RBAC** | Kubernetes' who-may-do-what system (roles + bindings) |
| **Security Group** | Stateful bouncer with a guest list per resource |
| **State (Terraform)** | Terraform's memory file of what it built |
| **StatefulSet** | Pods with permanent names + their own disks (Kafka, NiFi) |
| **Subnet (public/private)** | Front yard (internet-routable) / backyard (hidden) |
| **Taint / Toleration** | "Reserved table" sign / permission slip to sit there |
| **Terraform** | Cloud LEGO instructions; `.tf` files + state |
| **VPC** | Your private, fenced network neighborhood in AWS |

---

*End of guide. Now open `eks-cheat-sheet.md` and keep it within arm's reach.* 🛠️
