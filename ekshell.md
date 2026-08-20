# Adding a Node Group + a Scaling "Hello World" App to an Existing EKS Cluster

A complete, plain-English walkthrough. Start at Part 1 and follow along; the background and deeper explanations come after.

---

## The 60-second background

Imagine a restaurant.

- **The EKS cluster** is the restaurant's manager. It decides who cooks what. AWS runs the manager for you and charges roughly $0.10/hour for it. **You already have this.**
- **A node group** is a batch of identical kitchen staff (EC2 virtual machines). The manager has no hands — without staff, nothing gets cooked. **This is what we're adding.**
- **A pod** is one cook working on one dish. Your Docker image is the recipe.
- **A Deployment** is the standing order: "always keep 3 cooks making this dish; if one quits, hire a replacement."
- **A Service** is the front counter — one stable address customers use, no matter which cook is actually working.
- **An HPA (Horizontal Pod Autoscaler)** is the shift supervisor: "dinner rush started, put more cooks on the line."

**Terraform** is the written plan for the whole restaurant. You describe what you want to exist, and Terraform figures out what to create, change, or delete to match.

**Two separate kinds of scaling** — this trips people up constantly:

| Layer | What it adds | Controlled by |
|---|---|---|
| Pod scaling | More copies of your app | HPA (`hpa_min_replicas` / `hpa_max_replicas`) |
| Node scaling | More EC2 machines to run pods on | Node group (`node_min_size` / `node_max_size`) |

More cooks are useless without enough kitchen space. If your HPA can reach 20 pods but your node group caps at 2 small machines, pods will sit stuck in `Pending`. Size them together.

---

## Part 1: Step-by-step setup

### Step 0 — Prerequisites checklist

You need all of these before starting:

- [ ] An **existing EKS cluster** (you're not creating one here)
- [ ] `terraform` v1.5 or newer — `terraform -version`
- [ ] `aws` CLI v2 — `aws --version`
- [ ] `kubectl` — `kubectl version --client`
- [ ] AWS credentials with permission to create IAM roles and EKS node groups
- [ ] The **subnet IDs** your cluster uses
- [ ] **metrics-server** installed in the cluster (Step 2 — the HPA is blind without it)

### Step 1 — Point kubectl at your cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name my-dev-eks
kubectl get nodes
```

If `get nodes` returns something (even "No resources found"), you're connected. If it errors, fix that before going further — Terraform authenticates the same way.

### Step 2 — Install metrics-server

The HPA works by asking, "how much CPU are my pods using?" Nothing in a stock EKS cluster answers that question. metrics-server is the component that does.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Wait ~60 seconds, then verify:
kubectl top nodes
```

If `kubectl top nodes` prints CPU and memory numbers, you're good. If it says `error: Metrics API not available`, wait a bit longer or check `kubectl -n kube-system get pods | grep metrics`.

> **Skip this and everything still applies cleanly** — but your HPA will show `<unknown>/70%` forever and never scale. It's the single most common "my autoscaling doesn't work" cause.

### Step 3 — Find your subnet IDs

```bash
aws eks describe-cluster --name my-dev-eks --region us-east-1 \
  --query "cluster.resourcesVpcConfig.subnetIds"
```

Copy the output into `subnet_ids` in your tfvars file.

### Step 4 — Fill in your tfvars

Open `dev.tfvars` and change the three things marked `<-- your ...`:

```hcl
region       = "us-east-1"
cluster_name = "my-dev-eks"
subnet_ids   = ["subnet-0aaa...", "subnet-0bbb..."]
```

Everything else has a sensible default.

### Step 5 — Initialise Terraform

```bash
cd eks-hello
terraform init
```

This downloads the AWS and Kubernetes provider plugins into `.terraform/`. Run it once per project (and again whenever you change provider versions).

### Step 6 — Preview before you build

```bash
terraform plan -var-file=dev.tfvars
```

Read the output. It should end with something like `Plan: 8 to add, 0 to change, 0 to destroy.` **Nothing has been created yet.** `plan` is read-only and free. Always run it first.

Confirm you see **`0 to destroy`**. If Terraform wants to destroy something, stop and investigate.

### Step 7 — Build it

```bash
terraform apply -var-file=dev.tfvars
```

Type `yes` when prompted. Expect **5–10 minutes** — most of it is EC2 instances booting and registering with the cluster.

### Step 8 — Verify

```bash
# Are the new nodes there?
kubectl get nodes -L eks.amazonaws.com/nodegroup

# Are the pods running?
kubectl get pods -l app=hello-web

# Is the autoscaler awake? (Targets column must NOT say <unknown>)
kubectl get hpa hello-web
```

Healthy output looks like:

```
NAME        REFERENCE              TARGETS   MINPODS  MAXPODS  REPLICAS
hello-web   Deployment/hello-web   1%/70%    1        4        1
```

### Step 9 — See the hello page

**Dev (ClusterIP):**
```bash
kubectl port-forward svc/hello-web 8080:80
```
Open `http://localhost:8080`. The page shows the pod's name and IP — refresh a few times and watch it change as the Service round-robins between pods.

**Prod (LoadBalancer):**
```bash
terraform output app_url
```
Give the load balancer 2–3 minutes to come online.

### Step 10 — Watch it actually scale

Open **three terminals**.

Terminal 1 — watch the autoscaler:
```bash
kubectl get hpa hello-web -w
```

Terminal 2 — watch pods appear:
```bash
kubectl get pods -l app=hello-web -w
```

Terminal 3 — generate load:
```bash
kubectl run loadgen --rm -it --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://hello-web; done"
```

Within about 60 seconds you'll see `TARGETS` climb past 70% and `REPLICAS` start rising. Press `Ctrl+C` in Terminal 3 to stop the load. Scale-down takes ~5 minutes by design (see `stabilization_window_seconds` in `k8s.tf`).

### Step 11 — Clean up when done

```bash
terraform destroy -var-file=dev.tfvars
```

This removes **only what this code created** — the node group, the IAM role, and the app. Your cluster is untouched, because we read it with a `data` block rather than a `resource` block.

---

## Part 2: What each file does

| File | Purpose |
|---|---|
| `versions.tf` | Pins Terraform + provider versions, configures AWS and Kubernetes authentication |
| `variables.tf` | Declares every knob, its type, default, and description |
| `main.tf` | AWS side: IAM role, policy attachments, the node group |
| `k8s.tf` | Kubernetes side: Deployment, Service, HPA |
| `outputs.tf` | Values printed after apply (URL, status, handy commands) |
| `dev.tfvars` | Dev values — small, cheap, Spot |
| `prod.tfvars` | Prod values — redundant, On-Demand, load-balanced |

Every line inside those files is commented. Read them alongside this document.

### The three IAM policies (why all three are mandatory)

| Policy | Without it |
|---|---|
| `AmazonEKSWorkerNodePolicy` | Node boots but never joins the cluster |
| `AmazonEKS_CNI_Policy` | Node joins, but pods get no IP addresses and stay `ContainerCreating` |
| `AmazonEC2ContainerRegistryReadOnly` | Node can't pull images from your private ECR registry |

### Two `lifecycle` blocks worth understanding

```hcl
ignore_changes = [scaling_config[0].desired_size]   # main.tf
ignore_changes = [spec[0].replicas]                 # k8s.tf
```

Autoscalers change these numbers at runtime. Without these blocks, your next `terraform apply` would see "current: 8 pods, my code says 2" and scale you back down — possibly mid-traffic-spike. These blocks say: *I set the starting value; the autoscaler owns it after that.*

---

## Part 3: Key variables for dev vs prod

These are the settings that genuinely should differ between environments.

| Variable | Dev | Prod | Why |
|---|---|---|---|
| `cluster_name` | dev cluster | prod cluster | Different clusters, always |
| `subnet_ids` | 2 AZs | **3 private** AZs | Survive an AZ failure; private = not internet-reachable |
| `capacity_type` | `SPOT` | `ON_DEMAND` | Spot saves ~70% but AWS can reclaim with 2 min notice |
| `instance_types` | `["t3.small","t3a.small"]` | `["m6i.large"]` | Multiple types improve Spot fill rate; prod wants predictable perf |
| `node_min_size` | 1 | 3 | Prod must tolerate losing a node |
| `node_max_size` | 2 | 10 | Dev ceiling is a cost guardrail |
| `disk_size` | 20 | 50 | Prod holds more image layers and logs |
| `replicas` / `hpa_min_replicas` | 1 | 3 | One pod = one outage away from downtime |
| `hpa_max_replicas` | 4 | 20 | Prod needs real burst headroom |
| `hpa_cpu_target` | 70 | 60 | Lower = scales earlier = more safety margin |
| `cpu_request` | `50m` | `200m` | Prod reserves real capacity |
| `service_type` | `ClusterIP` | `LoadBalancer` | No LB bill in dev; port-forward is enough |
| `image` | mutable tag OK | **pin by digest** | Guarantees the exact same bits ship every time |
| `tags` | sandbox cost centre | prod cost centre + compliance | Cost attribution and audits |

**Variables that should NOT differ:** `app_name`, `container_port`, `ami_type`. Keeping these identical is the whole point — you want dev to be a faithful rehearsal of prod.

**Never put in tfvars:** passwords, API keys, or tokens. `.tfvars` files get committed to git. Use AWS Secrets Manager or Kubernetes Secrets via IRSA instead.

---

## Part 4: Choices and trade-offs

### Spot vs On-Demand

| | Spot | On-Demand |
|---|---|---|
| **Pro** | ~70% cheaper | Never reclaimed; predictable |
| **Con** | 2-minute eviction notice; capacity can be unavailable | 3–4× the price |
| **Use for** | Dev, CI, batch, stateless workloads with 3+ replicas | Prod, databases, anything stateful |

*Middle ground:* run a small On-Demand group for baseline plus a Spot group for burst.

### ClusterIP vs LoadBalancer vs Ingress

| | Pro | Con |
|---|---|---|
| **ClusterIP** | Free; nothing exposed | Needs `port-forward` to reach |
| **LoadBalancer** | Simple public URL | One AWS load balancer (~$16+/mo) **per service** |
| **Ingress (ALB)** | One load balancer for many apps; path routing, TLS | Requires installing AWS Load Balancer Controller |

Rule of thumb: 1 app → LoadBalancer. 3+ apps → Ingress.

### x86 vs ARM (Graviton)

ARM (`AL2023_ARM_64_STANDARD` + `m7g.large`) is roughly 20% cheaper for the same performance. The catch: your Docker image **must** be built for `arm64`. `nginxdemos/hello` is multi-arch so it works either way, but check your own images with `docker manifest inspect`.

### Managed node groups vs Karpenter

This code uses **managed node groups** — the simple, well-understood option. **Karpenter** provisions right-sized nodes on demand and is usually cheaper at scale, but it's a whole extra system to install and learn. Start here; graduate to Karpenter when node costs become a real line item.

---

## Part 5: Best practices applied in this code

1. **Remote state.** Local `terraform.tfstate` is the #1 cause of team disasters. Add a backend before anyone else touches this:
   ```hcl
   terraform {
     backend "s3" {
       bucket       = "my-tf-state"
       key          = "eks-hello/dev.tfstate"
       region       = "us-east-1"
       use_lockfile = true   # native S3 locking, no DynamoDB table needed
     }
   }
   ```
   Use a **different `key` per environment** so dev can never overwrite prod.

2. **Separate state per environment.** Different tfvars alone is not enough — one state file per env, or use workspaces.

3. **Always `plan` before `apply`.** In CI, run `plan` on pull requests and require a human to approve.

4. **Set resource requests on every container.** No request = no CPU-based autoscaling, and the scheduler can't place pods intelligently.

5. **Pin versions.** Terraform (`>= 1.5`), providers (`~> 6.0`), and container images. `:latest` means "whatever happened to be pushed today."

6. **Use `data` for things you don't own.** Reading the cluster with `data "aws_eks_cluster"` makes it structurally impossible for `terraform destroy` to delete it.

7. **Validate inputs.** The `validation` blocks in `variables.tf` catch typos at plan time instead of 8 minutes into an apply.

8. **Tag everything.** `Environment`, `Owner`, `CostCenter` — these become your AWS Cost Explorer filters.

---

## Part 6: Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Node group stuck in `CREATING`, then fails | Subnets can't reach the EKS API | Private subnets need a NAT gateway or VPC endpoints |
| Pods stuck `Pending` | No node has room | Raise `node_max_size`, or lower `cpu_request` |
| Pods stuck `ContainerCreating` | CNI can't assign IPs | Check the `AmazonEKS_CNI_Policy` attachment; check subnet free IPs |
| HPA shows `<unknown>/70%` | metrics-server missing | Redo Step 2 |
| HPA shows `<unknown>` even with metrics-server | No `cpu` request on the container | Set `cpu_request` |
| `ImagePullBackOff` | Bad image name, or private registry | Verify the tag; check the ECR policy attachment |
| `Unauthorized` from the Kubernetes provider | kubeconfig/EKS access entry missing | Re-run Step 1; confirm your IAM principal has cluster access |
| `terraform apply` reverts pod count | Missing `ignore_changes` | Already handled in this code — don't remove it |
| LoadBalancer `EXTERNAL-IP` stuck `<pending>` | Subnets not tagged for ELB discovery | Public subnets need `kubernetes.io/role/elb = 1` |

---

## Quick command reference

```bash
terraform init                              # once per project
terraform plan  -var-file=dev.tfvars        # preview (safe, free)
terraform apply -var-file=dev.tfvars        # build
terraform apply -var-file=prod.tfvars       # build prod
terraform output                            # show URLs and names
terraform destroy -var-file=dev.tfvars      # tear down

kubectl get nodes -L eks.amazonaws.com/nodegroup
kubectl get pods -l app=hello-web -w
kubectl get hpa hello-web -w
kubectl describe hpa hello-web              # why isn't it scaling?
kubectl logs -l app=hello-web --tail=50
kubectl top pods                            # needs metrics-server
```
