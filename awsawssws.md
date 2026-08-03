# The Corner Shop Data Pipeline
### Build a real ETL system on AWS EKS Auto Mode — step by step, twice (AWS CLI *and* Terraform)

---

## What you are about to build (the 30-second version)

Imagine a chain of corner shops. Every time a cashier rings up a sale, we want that sale to:

1. Show up on a **web page** (a cashier types it in — that's our pretend till),
2. Get dropped onto a **conveyor belt** (Kafka) so the till never has to wait,
3. Get picked up by **workers** (pods that KEDA turns on and off automatically),
4. Get **cleaned and enriched** (fix the spelling, add the tax, add the region — the "T" in ETL),
5. Get **stored forever** in a data lake (S3),
6. Get **indexed for instant search** (OpenSearch — "show me refunds in the last 15 minutes"),
7. Optionally flow through **NiFi**, a drag-and-drop ETL tool, doing the same moves visually.

```
 Browser ──HTTP──▶ ALB (load balancer)
                    │  /            ▶ web  (static HTML page)
                    │  /api/sales   ▶ producer ──▶ KAFKA topic: retail.sales.raw
                                                     │
                                    KEDA watches the backlog and starts workers
                                                     ▼
                                                  worker pods
                                     ┌───────────────┼──────────────────┐
                                     ▼               ▼                  ▼
                               S3  raw/        enrich API         S3 curated/
                                              (tax + region)           │
                                                                       ▼
                                                                  OpenSearch
                               NiFi (optional) does the same Kafka ▶ S3 flow
                               with drag-and-drop boxes instead of code.
```

This is **ETL**: **E**xtract (read from Kafka), **T**ransform (clean + enrich), **L**oad (into S3 and OpenSearch). Every big company runs pipelines shaped exactly like this — Netflix for viewing events, banks for card transactions, airlines for bookings. Ours just sells apples.

---

## Background: the words you need, explained like you're new (because everyone was)

| Word | What it actually is | Corner-shop version |
|---|---|---|
| **VPC** | Your own private slice of AWS's network | The shop building. You decide where the doors are. |
| **Subnet** | A slice of the VPC, tied to one data center (AZ) | A room in the building. Public rooms have a street door; private rooms don't. |
| **Internet Gateway** | The VPC's connection to the internet | The front door |
| **NAT Gateway** | Lets private things call *out* without letting anyone call *in* | A mail slot: letters go out, burglars don't come in |
| **Security Group** | A firewall around one thing | A bouncer with a guest list |
| **IAM Role** | A job badge with permissions, that a service *borrows* | The "manager" badge — whoever wears it can open the safe |
| **EKS** | AWS-managed Kubernetes: a system that runs your apps in containers and keeps them alive | The shift manager who makes sure there's always someone at every till |
| **EKS Auto Mode** | EKS where AWS also manages the machines, load balancers, and disks | The shift manager *also* hires and fires staff as the queue grows and shrinks |
| **Node / Node Pool** | An EC2 machine running your pods / the rules for what machines to create | A staff member / the hiring policy ("hire part-timers first, they're cheaper") |
| **Kafka** | A durable message queue, split into topics and partitions | The conveyor belt between the tills and the back office |
| **KEDA** | An autoscaler that watches *queues* instead of CPU | A supervisor who counts the boxes piling up on the belt and calls in help |
| **S3** | Infinite, cheap object storage | The warehouse. Everything is kept, forever, in labelled boxes |
| **OpenSearch** | A fast search engine with dashboards | The index card box at the front desk — instant answers about recent stuff |
| **NiFi** | A visual, drag-and-drop data-flow tool | A whiteboard where each box is a step and arrows are the data moving |
| **ALB / Ingress** | An AWS load balancer / the Kubernetes object that asks for one | The greeter who sends customers to whichever till is free |

**Why both S3 *and* OpenSearch?** They answer different questions. S3 is the warehouse: complete, cheap, a bit slow ("every sale in 2024" — fine, take a minute). OpenSearch is the index cards: fast, recent, more expensive per GB ("card payments over $50 in the last hour" — answered before you blink). Nearly every real data platform keeps both. This is called the **hot/cold storage** pattern.

**Why Kafka in the middle instead of writing straight to S3?** Because the till must *never* wait for the warehouse. The producer writes to Kafka in ~5 milliseconds and moves on. If OpenSearch is down or the workers are being upgraded, sales keep flowing onto the belt and get processed later. That decoupling is the single most important idea in this whole tutorial.

---

## What "template" means here (read this before running anything)

You asked for something reusable, and both stacks are built that way:

- **CLI side:** every value lives in **`env/config.sh`** as `: "${VAR:=default}"` — meaning "use the default *unless* someone already set it." You override values three ways, strongest first:
  1. `export CLUSTER_NAME=my-thing` in your shell,
  2. an env file: `cp env/lab.env.example env/my.env`, then `ENV_FILE=env/my.env ./run-all.sh`,
  3. edit the defaults in `env/config.sh`.
  Scripts never hard-code anything, and they write the IDs they create into `.state/<prefix>/` so later scripts can read them — like a shared notebook.
- **Terraform side:** every value is a `variable` in **`terraform/variables.tf`**. You set them in a `terraform.tfvars` file. Two examples ship with the repo: `terraform.tfvars.example` (cheap lab) and `prod.tfvars.example` (3 AZs, MSK, private endpoint). **Same code, different numbers** — that's the whole discipline of infrastructure as code.
- Change `PROJECT`/`ENVIRONMENT` (or `project`/`environment`) and *every* resource gets a new name — so `shopetl-lab` and `shopetl-prod` can coexist in one account without collisions.

**Cost warning (be honest with yourself):** this lab runs roughly **$8–12/day** — EKS control plane (~$0.10/hr), NAT gateway (~$0.045/hr), OpenSearch `t3.small` (~$0.04/hr), plus a couple of small nodes. Tear it down when you're done (`cli/99-destroy.sh` or `terraform destroy`). Nothing hurts like a forgotten NAT gateway on the monthly bill.

---

## Part 1 — Step-by-step setup (the AWS CLI path)

**Prerequisites:** AWS CLI v2, `jq`, `kubectl`, `helm`, `docker`, `envsubst` (from `gettext`), and credentials with admin-ish rights (`aws configure`).

Each script builds **one resource**, explains itself in comments, is **idempotent** (safe to run twice — it skips what exists), and supports `DRY_RUN=true` to preview. Run them in numeric order, or just:

```bash
./run-all.sh                 # everything, in order
./run-all.sh 12              # resume from step 12 after a failure
DRY_RUN=true ./run-all.sh    # look before you leap
```

### The ordered plan, and *why* the order is what it is

| # | Script | Creates | Why it must come *here* |
|---|--------|---------|--------------------------|
| 00 | `00-preflight.sh` | nothing | Checks tools + credentials. Failing here costs 5 seconds; failing at step 09 costs 15 minutes. |
| 01 | `01-vpc.sh` | VPC | Everything else lives inside it. The building before the rooms. |
| 02 | `02-subnets.sh` | public + private subnets | Rooms need a building. Also applies the `kubernetes.io/role/elb` tags the load balancer controller *reads* — they're functional, not decoration. |
| 03 | `03-internet-gateway.sh` | IGW | The door needs a wall to be in. |
| 04 | `04-nat-gateway.sh` | NAT + Elastic IP | NAT must sit in a **public** subnet (02) and needs the IGW (03) to reach the internet. |
| 05 | `05-route-tables.sh` | route tables | Signposts can only point at doors that exist (03, 04). |
| 06 | `06-security-groups.sh` | 3 security groups | Bouncers hired before the guests arrive. Note the best practice: rules reference *other security groups*, not IP ranges. |
| 07 | `07-iam-cluster-role.sh` | control-plane role | EKS refuses to start without its badge. Auto Mode adds 4 extra policies (Compute, BlockStorage, LoadBalancing, Networking) so AWS may manage nodes for you. |
| 08 | `08-iam-node-role.sh` | node role | Must exist *before* the cluster, because Auto Mode's `computeConfig` names it at creation time. Notice it's tiny — `WorkerNodeMinimal` + `ECRPullOnly`. |
| 09 | `09-eks-cluster.sh` | **the cluster** | Needs subnets (02), SG (06) and both roles (07, 08). Flips the three Auto Mode switches: `computeConfig`, `elasticLoadBalancing`, `blockStorage`. ~12 minutes. |
| 10 | `10-access-entry.sh` | access entry | Grants *you* kubectl rights via the modern Access Entries API (never edit the old `aws-auth` ConfigMap). |
| 11 | `11-kubeconfig.sh` | kubeconfig | `kubectl get nodes` will show **zero nodes** — that's correct! Auto Mode creates nodes only when a pod needs one. |
| 12 | `12-s3-bucket.sh` | data lake bucket | Public access blocked, encrypted, versioned, lifecycle to Glacier. Independent of the cluster, but the app role (16) references its ARN. |
| 13 | `13-kafka.sh` | MSK *or* nothing | With `KAFKA_BACKEND=in-cluster` (default) it just records the future in-cluster address. With `msk` it builds MSK Serverless in the private subnets. |
| 14 | `14-opensearch.sh` | OpenSearch domain | Generates the master password and stores it in **Secrets Manager** — passwords never live in files. ~15 minutes. |
| 15 | `15-ecr.sh` | 4 image repos | Shelves before you can put images on them (23 pushes there). |
| 16 | `16-iam-app-role.sh` | app IAM role | Least privilege: *this one bucket*, *this one Kafka cluster*, *this one domain*. Needs the ARNs from 12–14, which is why it's after them. |
| 17 | `17-pod-identity.sh` | Pod Identity association | Glues namespace + ServiceAccount → role. Result: pods get AWS permissions with **zero access keys anywhere**. |
| 18 | `18-nodepool.sh` | NodeClass + NodePool | A custom **Spot-first** pool, tainted `workload=etl`, so only ETL workers land on the cheap interruptible machines. |
| 19 | `19-ingressclass.sh` | IngressClass(+Params) | Tells Auto Mode's *built-in* ALB controller how to build load balancers. **Auto Mode gotcha:** the old `alb.ingress.kubernetes.io/*` annotations are ignored — settings go in `IngressClassParams`. |
| 20 | `20-keda.sh` | KEDA (Helm) | The queue-watching autoscaler, installed before anything asks it to scale. |
| 21 | `21-kafka-deploy.sh` | Kafka pod + topics | Creates `retail.sales.raw` (6 partitions) and the dead-letter topic. |
| 22 | `22-nifi.sh` | NiFi | Single-node visual ETL. Flow recipe in `docs/04-nifi-flow.md`. |
| 23 | `23-apps.sh` | build + deploy 4 apps | Builds/pushes images, applies web, producer, enrich, worker, ScaledObject, **Ingress** — and creating that Ingress is what makes AWS build the real ALB. |
| 24 | `24-verify.sh` | nothing | Sends a test sale end-to-end and checks S3. Proof, not hope. |
| 99 | `99-destroy.sh` | −everything | Deletes in exact **reverse** order (K8s Ingress first so the ALB goes away, VPC last). Wrong order = `DependencyViolation` errors. |

### Watch the magic moment

Open two terminals:

```bash
# terminal 1 — watch pods and nodes appear
kubectl get pods -n shop-etl -w

# terminal 2 — hammer the API
ADDR=$(cat .state/shopetl-lab/alb_hostname)
for i in $(seq 1 300); do
  curl -s -X POST http://$ADDR/api/sales -H 'content-type: application/json' \
    -d '{"store_id":"STORE-001","sku":"CHOC-DARK-100G","qty":1,"unit_price":3.20,"payment":"card"}' >/dev/null
done
```

Within ~30 seconds KEDA sees the Kafka backlog grow, scales `worker` from **0** to several pods; Auto Mode notices there's nowhere to put them and **buys Spot machines**; the batch drains; workers scale back to 0; the machines get consolidated away. You just watched the entire cloud-economics argument happen live.

---

## Part 2 — The same thing in Terraform

The CLI path teaches you *what each resource is*. Terraform is how you'd run it *for real*: it records what it built (state), shows you a diff before changing anything (plan), and deletes in the right order automatically.

One `.tf` file per resource, numbered to match the CLI scripts (`01-vpc.tf`, `02-subnets.tf`, … `24-ingress.tf`), so you can read them side by side:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit your values
terraform init
terraform plan                                  # READ THIS. Every time. Forever.
terraform apply

# Practical tip for first-time applies: infra first, workloads second
terraform apply -var deploy_k8s_workloads=false   # VPC → cluster → S3 → OpenSearch
# build & push images (cli/23-apps.sh with BUILD_IMAGES=true does this)
terraform apply                                    # now the K8s workloads

terraform output kubeconfig_command             # copy-paste to get kubectl access
terraform destroy                               # cleanup, correct order, automatic
```

For production: `terraform apply -var-file=prod.tfvars` — same code, prod numbers.

### CLI vs Terraform — honest pros and cons

| | AWS CLI scripts | Terraform |
|---|---|---|
| **Learning** | ★★★ You see every API call | ★ Declarative; the "how" is hidden |
| **Repeatability** | OK (we hand-built idempotency) | ★★★ Built in |
| **Drift detection** | None — someone clicks in the console, you'll never know | `terraform plan` shows exactly what changed |
| **Deletion** | You must script reverse order yourself (see `99-destroy.sh`) | Automatic, dependency-ordered |
| **Team use** | Hard — state lives in files on *your* laptop | Remote state in S3 = shared truth |
| **Verdict** | Perfect for learning and one-off ops | The right answer for anything that must exist next month |

---

## Best practices baked in (and where to look at them)

1. **Never put credentials in code.** Pod Identity gives pods AWS permissions with no keys (`17-pod-identity`); the OpenSearch password goes to Secrets Manager (`14-opensearch`).
2. **Least privilege.** The app role can touch *one* bucket, *one* Kafka cluster, *one* domain (`16-iam-app-role`). If the worker is ever compromised, the blast radius is small.
3. **Validate at the front door.** The producer rejects bad sales with HTTP 400 *before* they enter the pipeline (`app/producer/app.py`). Cleaning data downstream costs 100× more.
4. **Batch.** The worker writes 200 rows per S3 object (`app/worker/worker.py`). Millions of tiny files are the #1 killer of data-lake query speed.
5. **Partition your lake.** `raw/dt=2026-08-03/hour=14/…` lets query engines skip whole folders. One habit, 10–100× faster queries.
6. **At-least-once + idempotent.** Offsets commit *after* data is safe; `event_id` is the OpenSearch document `_id`, so replays overwrite instead of duplicating.
7. **Dead-letter queue.** One unparseable "poison" message must never stop the belt — it goes to `retail.sales.dlq` and the pipeline moves on.
8. **Handle SIGTERM.** Spot nodes give 2 minutes' warning; the worker finishes its batch and exits cleanly.
9. **Tag everything.** `Project`, `Environment`, `Owner`, `CostCenter` on every resource (automatic via `default_tags` in Terraform, shared strings in the CLI). Your future finance team says thanks.
10. **Scale on the queue, not the CPU.** By the time CPU is high, the backlog is hours deep. KEDA watches lag (`k8s/44-keda.yaml`) and can scale to zero.

### Design options and their trade-offs

| Choice | Cheap/simple (lab default) | Robust (prod) | The trade |
|---|---|---|---|
| NAT gateways | 1 shared (`SINGLE_NAT_GATEWAY=true`) | 1 per AZ | ~$32/mo per extra NAT vs. surviving an AZ outage |
| Kafka | 1 pod in-cluster | MSK Serverless / Strimzi, RF=3 | ~$0 vs. ~$550/mo minimum; pod restarts lose data, MSK doesn't |
| Nodes | Spot-first custom pool | On-demand for latency-critical | ~70% cheaper vs. 2-minute interruption notices |
| Worker floor | scale-to-zero | `min=2` warm | $0 idle vs. ~60s cold-start on the first message |
| Cluster endpoint | public API (CIDR-limited) | private-only + VPN | Convenience vs. attack surface |
| Auto Mode | on | on (or self-managed Karpenter for exotic needs) | ~12% management fee on node cost vs. running your own controllers, upgrades, patching |

---

## More real-world ETL examples with this exact shape

- **Rideshare app:** every GPS ping → Kafka → workers compute surge pricing → S3 for the data scientists, OpenSearch for the live ops map.
- **Hospital lab:** test results → queue → validation (units! ranges!) → enrichment against the patient registry → archive + fast lookup for doctors.
- **Online game:** player events → Kafka → cheat-detection workers scale with player count (KEDA shines here — Friday 8 pm vs. Tuesday 4 am) → S3 for analytics, OpenSearch for the moderation team.
- **Bank cards:** transactions → queue → fraud scoring calls an API (our `enrich` stand-in) → immutable S3 archive for regulators (note `prod.tfvars`'s 7-year retention), OpenSearch for the fraud desk.

Same skeleton every time: **fast front door → durable queue → elastic workers → cheap forever-store + fast recent-store.** Learn it once, recognize it everywhere.

## Where everything lives

```
eks-etl-lab/
├── README.md              ← you are here
├── run-all.sh             ← run the whole CLI path in order
├── env/                   ← config.sh (all CLI variables) + lab/prod .env examples
├── cli/                   ← 00–24 + 99, one script per resource, lib.sh helpers
├── terraform/             ← one .tf per resource + tfvars examples
├── k8s/                   ← YAML templates the CLI scripts render (envsubst)
├── app/                   ← web (HTML), producer, worker, enrich (+Dockerfiles)
└── docs/                  ← run-order deep dive, NiFi flow recipe, troubleshooting
```

Start with `./cli/00-preflight.sh`. Read each script before you run it — they're short on purpose, and the comments are the other half of this tutorial.
