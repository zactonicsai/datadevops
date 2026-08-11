# Amazon EKS: Automatic Node Groups + a "Hello World" Web Server
### A step-by-step guide written so a middle schooler can follow it

**Last checked: August 2026** · Uses EKS Auto Mode (the current AWS-recommended way to get nodes that add and remove themselves).

---

## 1. The big idea, in plain words

Imagine you run a pizza shop.

| Pizza shop | Kubernetes / AWS |
|---|---|
| An **order** for one pizza | A **Pod** (one running copy of your app) |
| An **oven** that bakes pizzas | A **Node** (one computer / EC2 server) |
| The **manager** who decides which oven bakes which pizza | The **Control Plane** (the brain of the cluster) |
| The whole shop | The **Cluster** |
| A **group of identical ovens** you rent | A **Node Group** |
| A manager who **rents more ovens when orders pile up** and **returns them when it's quiet** | **Auto scaling / EKS Auto Mode** |

The old, manual way: *you* guess how many ovens to rent. Rent too few and orders burn up in the queue. Rent too many and you pay for cold, empty ovens.

The automatic way (what this guide teaches): you just say *"here are my orders"*, and AWS rents exactly the right ovens, in the right sizes, and gets rid of them when they're not needed.

**EKS** = Elastic Kubernetes Service. It's AWS running the manager (control plane) for you.
**EKS Auto Mode** = AWS also runs the ovens (nodes) for you — buying, patching, replacing, and shutting them down.

---

## 2. What you will build today

```
   Internet
      |
      v
[ Network Load Balancer ]   <-- AWS creates this for you
      |
      v
[ hello-world Pods ]        <-- tiny web servers that say "Hello World"
      |
      v
[ Nodes ]                   <-- EC2 servers that appear AUTOMATICALLY
```

You will:
1. Create an EKS cluster with Auto Mode turned on.
2. Deploy a tiny "Hello World" HTTP server.
3. Open it in your browser.
4. Create your **own custom node pool** (this is the "auto node group" part).
5. Scale the app up and **watch new servers appear by themselves**.
6. Delete everything so you stop paying.

---

## 3. ⚠️ Money warning (read this, seriously)

This is not free. Rough costs in `us-east-1` at the time of writing:

| Thing | Cost |
|---|---|
| EKS cluster (the manager) | **$0.10 per hour** (~$73/month) — charged even if zero apps run |
| EC2 nodes | Normal EC2 prices (a small `m` instance ≈ $0.10/hr) |
| Auto Mode management fee | **~12% extra** on top of the EC2 price |
| Network Load Balancer | ~$0.025/hr + data (~$18–20/month) |

**Doing this whole tutorial and deleting it within 2 hours costs roughly $0.50–$1.00.**
If you forget to delete it, you'll pay ~$100+/month. **Set a phone alarm right now** to remind you to run the cleanup in Step 10.

---

# PART 1 — The step-by-step example

## Step 0: Install your tools

You need three command-line programs.

```bash
# 1) AWS CLI - lets your computer talk to AWS
aws --version          # want v2.x

# 2) kubectl - lets your computer talk to Kubernetes
kubectl version --client

# 3) eksctl - a helper that builds EKS clusters for you
eksctl version         # MUST be 0.195.0 or newer for Auto Mode
```

Install links:
- AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- kubectl: https://kubernetes.io/docs/tasks/tools/
- eksctl: https://github.com/eksctl-io/eksctl/releases

Now log in to AWS:

```bash
aws configure
# Paste your Access Key ID, Secret Access Key
# Default region: us-east-1
# Default output format: json

# Check it worked - this prints your account number
aws sts get-caller-identity
```

**Permissions you need:** your AWS user must be allowed to create EKS clusters, EC2 instances, VPC networking, and IAM roles. If you're learning on a personal account with `AdministratorAccess`, you're fine. On a work account, ask your admin.

---

## Step 1: Create the cluster (takes ~15 minutes)

Make a file called `cluster.yaml`:

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: hello-auto
  region: us-east-1
  version: "1.35"          # See "Which version?" in Part 2

autoModeConfig:
  enabled: true            # <-- THE MAGIC LINE. Turns on Auto Mode.
  # nodePools: []          # uncomment to skip the 2 built-in pools
```

Create it:

```bash
eksctl create cluster -f cluster.yaml
```

**What's happening while you wait ~15 minutes:** AWS is building a private network (VPC), subnets in 3 different data centers, IAM roles (permission badges), and the Kubernetes control plane itself. Go get a snack.

> **One-liner alternative** (fewer options, same result):
> ```bash
> eksctl create cluster --name hello-auto --region us-east-1 --enable-auto-mode
> ```

---

## Step 2: Check that it worked

```bash
# Point kubectl at your new cluster
aws eks update-kubeconfig --name hello-auto --region us-east-1

# Ask the cluster who's there
kubectl get nodes
```

Expected output:

```
No resources found
```

**This is correct and is the whole point!** You have a cluster with **zero** servers running, because you have zero apps. You're not paying for any nodes yet. Nodes only appear when work shows up.

Check that Auto Mode's compute is switched on:

```bash
aws eks describe-cluster --name hello-auto --region us-east-1 \
  --query 'cluster.computeConfig'
```

You should see `"enabled": true` and two built-in node pools: `general-purpose` and `system`.

---

## Step 3: Write the Hello World web server

Create `hello-world.yaml`:

```yaml
# hello-world.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world
spec:
  replicas: 2                      # start with 2 copies
  selector:
    matchLabels:
      app: hello-world
  template:
    metadata:
      labels:
        app: hello-world
    spec:
      containers:
      - name: web
        image: public.ecr.aws/nginx/nginx:alpine
        ports:
        - containerPort: 80
        # Write a Hello World page, then start the web server.
        # $(hostname) = the pod's name, so we can see WHICH copy answered.
        command: ["/bin/sh", "-c"]
        args:
          - echo "Hello World from $(hostname)" > /usr/share/nginx/html/index.html
            && nginx -g 'daemon off;'
        resources:
          requests:                # "I need at least this much"
            cpu: 250m              # 250m = 0.25 of one CPU core
            memory: 128Mi
          limits:                  # "never let me use more than this"
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: hello-world
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer     # Auto Mode turns this into a real AWS load balancer
  selector:
    app: hello-world     # send traffic to pods with this label
  ports:
  - port: 80             # the door the internet knocks on
    targetPort: 80       # the door on the pod
```

**Reading that in plain English:**
- `Deployment` = "AWS, always keep 2 copies of this web server alive. If one dies, replace it."
- `resources.requests` = "each copy needs a quarter of a CPU." **This is the most important line for autoscaling** — it's how the system does the math on how many servers to rent.
- `Service` with `type: LoadBalancer` = "give me one public address that spreads visitors across all the copies."

---

## Step 4: Deploy it and watch nodes appear

```bash
kubectl apply -f hello-world.yaml
```

Now watch, in real time:

```bash
kubectl get pods -w
```

You'll see something like:

```
NAME                          READY   STATUS    AGE
hello-world-7d4b8c9f5-abcde   0/1     Pending   5s     <-- no server yet!
hello-world-7d4b8c9f5-fghij   0/1     Pending   5s
hello-world-7d4b8c9f5-abcde   0/1     ContainerCreating   45s
hello-world-7d4b8c9f5-abcde   1/1     Running             60s
```

Press `Ctrl+C` to stop watching, then:

```bash
kubectl get nodes
```

```
NAME                  STATUS   ROLES    AGE   VERSION
i-0a1b2c3d4e5f6g7h8   Ready    <none>   1m    v1.35.x-eks-xxxxx
```

🎉 **A server appeared out of nowhere.** Nobody told AWS "rent a c5.large." The pods said "I'm homeless and I need 0.25 CPU," and Auto Mode found the cheapest instance that fits, booted it, joined it to the cluster, and scheduled the pods — in about 60 seconds.

---

## Step 5: Visit your website

```bash
kubectl get service hello-world
```

```
NAME          TYPE           EXTERNAL-IP                                    PORT(S)
hello-world   LoadBalancer   k8s-default-hellowo-abc123-xyz.elb.amazonaws.com  80:31234/TCP
```

Copy that `EXTERNAL-IP` address into your browser (or use curl):

```bash
curl http://k8s-default-hellowo-abc123-xyz.elb.amazonaws.com
```

```
Hello World from hello-world-7d4b8c9f5-abcde
```

Refresh a few times — the pod name changes, proving the load balancer is spreading traffic. 

> **If `EXTERNAL-IP` says `<pending>` for more than 5 minutes**, jump to Troubleshooting in Part 2.

---

## Step 6: Create your OWN node pool (the "auto node group")

The built-in pools are fine, but real teams define their own so they control instance types, cost strategy, and which apps land where. This is the part people mean when they say *"configure auto node groups."*

Two objects work together:

- **NodeClass** = the *hardware and networking* recipe (disk size, subnets, security groups).
- **NodePool** = the *rules* (allowed instance types, spot vs on-demand, size limits, when to shut nodes down).

Create `nodepool.yaml`:

```yaml
# nodepool.yaml
# ---------- 1. The hardware recipe ----------
apiVersion: eks.amazonaws.com/v1
kind: NodeClass
metadata:
  name: web-nodeclass
spec:
  role: <PASTE-YOUR-NODE-ROLE-NAME-HERE>   # see command below
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/hello-auto: "*"     # use this cluster's subnets
  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/hello-auto: "owned"
  ephemeralStorage:
    size: "40Gi"        # disk on each node
    iops: 3000
    throughput: 125
---
# ---------- 2. The rules ----------
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: web-pool
spec:
  template:
    metadata:
      labels:
        workload-type: web      # a name tag so apps can ask for this pool
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: web-nodeclass

      requirements:
        # Only rent servers matching ALL of these rules:
        - key: "eks.amazonaws.com/instance-category"
          operator: In
          values: ["c", "m", "r"]          # compute / general / memory families
        - key: "eks.amazonaws.com/instance-cpu"
          operator: In
          values: ["2", "4", "8"]          # 2, 4, or 8 cores only
        - key: "eks.amazonaws.com/instance-generation"
          operator: Gt
          values: ["4"]                    # modern generations only (newer = cheaper/faster)
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64"]                # normal Intel/AMD chips
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["on-demand"]            # add "spot" to save up to 90% (see Part 2)

      # Replace nodes before they get old and crusty
      expireAfter: 336h                    # 14 days

  # When to shrink
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s                  # wait 30s of quiet before shutting down

  # Hard ceiling so a runaway app can't rent $50,000 of servers
  limits:
    cpu: "100"
    memory: 200Gi
```

Get your node role name and paste it in:

```bash
aws eks describe-cluster --name hello-auto --region us-east-1 \
  --query 'cluster.computeConfig.nodeRoleArn' --output text
# Output looks like: arn:aws:iam::123456789012:role/eksctl-hello-auto-nodeRole-ABC123
# Use ONLY the part after "role/"  -->  eksctl-hello-auto-nodeRole-ABC123
```

Apply it:

```bash
kubectl apply -f nodepool.yaml
kubectl get nodepools
```

Now tell your app to use it. Add this under `spec:` in the pod template of `hello-world.yaml` (same indent level as `containers:`):

```yaml
      nodeSelector:
        workload-type: web     # "only put me on nodes from web-pool"
```

```bash
kubectl apply -f hello-world.yaml
kubectl get nodes -L workload-type    # -L shows the label as a column
```

Within a minute or two, new nodes labeled `web` appear, pods move onto them, and the old node — now empty — gets deleted automatically.

---

## Step 7: Watch autoscaling actually happen

Open **two terminal windows**.

Terminal 1 (the scoreboard):
```bash
watch -n 5 'kubectl get nodes -L workload-type; echo; kubectl get pods -o wide | head -20'
```
*(No `watch` on your machine? Just run `kubectl get nodes` repeatedly.)*

Terminal 2 (turn up the volume):
```bash
kubectl scale deployment hello-world --replicas=20
```

**What you'll see over the next ~2 minutes:**
1. All 20 pods appear as `Pending` (nowhere to live).
2. Auto Mode does the math: 20 pods × 0.25 CPU = 5 CPUs needed, plus overhead.
3. It picks instance sizes and launches them. New node names show up.
4. Nodes go `NotReady` → `Ready`.
5. Pods flip to `Running`.

Now scale back down:

```bash
kubectl scale deployment hello-world --replicas=2
kubectl get nodes -w
```

After ~30 seconds of quiet (`consolidateAfter: 30s`), the extra nodes drain and disappear. **You stop paying for them within seconds.** That's consolidation.

**Bonus: make it scale by itself based on traffic.** The Horizontal Pod Autoscaler adds *pods* when CPU gets busy; Auto Mode then adds *nodes* to hold them. Two layers working together:

```bash
kubectl autoscale deployment hello-world --cpu-percent=50 --min=2 --max=30
kubectl get hpa
```
*(Requires the Metrics Server add-on; on Auto Mode clusters, install it with
`kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`)*

---

## Step 8: Useful commands while you poke around

```bash
kubectl get nodeclaims                        # nodes Auto Mode is currently requesting
kubectl describe nodeclaim <name>             # why this node was chosen, which type
kubectl describe pod <pod-name>               # bottom "Events" section explains Pending
kubectl get events --sort-by=.lastTimestamp   # everything that just happened
kubectl top nodes                             # actual CPU/memory use (needs metrics-server)
kubectl logs -l app=hello-world --tail=20     # app logs
```

The single most useful debugging habit: **`kubectl describe pod` and read the Events at the bottom.** It literally tells you in English why a pod isn't running.

---

## Step 9: Clean up (DO NOT SKIP)

Delete the app first so the load balancer goes away, *then* the cluster.

```bash
kubectl delete -f hello-world.yaml
kubectl delete -f nodepool.yaml

# wait ~2 minutes for the load balancer to fully delete, then:
eksctl delete cluster --name hello-auto --region us-east-1
```

Verify nothing is left:

```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName'
```

> **Common trap:** deleting the cluster *before* deleting the Service leaves an orphaned load balancer quietly billing you ~$18/month forever. Always delete apps first.

---

# PART 2 — Background, details, and everything else

## 2.1 The vocabulary, properly explained

| Word | What it really is |
|---|---|
| **Container** | Your app plus everything it needs to run, zipped into one box. Runs the same anywhere. |
| **Pod** | The smallest thing Kubernetes runs. Usually one container. Pods are disposable — they get killed and recreated constantly. |
| **Node** | One EC2 virtual machine that runs pods. |
| **Deployment** | "Keep N copies of this pod alive forever." Handles restarts and rolling updates. |
| **Service** | A stable address for a set of pods, since pods keep changing. |
| **Control plane** | The brain: decides what runs where. AWS manages it for you in EKS. That's the $0.10/hr. |
| **Node group** | Traditionally: a set of identical EC2s managed together. In Auto Mode: replaced by **NodePools**. |
| **NodePool** | Rules describing what kind of nodes may be created, and when to delete them. |
| **NodeClass** | The AWS-specific hardware/network settings the NodePool uses. |
| **NodeClaim** | A single "I need one node like this, please" request. Watch these to debug scaling. |
| **Karpenter** | The open-source engine that does just-in-time node provisioning. Auto Mode runs a managed version of it. |

## 2.2 Why "requests" matter more than anything else

Autoscaling math is based on `resources.requests`, **not** on how much CPU your app actually uses.

- **Requests too high** → you rent giant servers that sit 5% busy. You burn money.
- **Requests too low** → too many pods jam onto one node, everything gets slow, pods get killed for using too much memory (`OOMKilled`).
- **No requests at all** → the scheduler thinks your pods need nothing, packs them infinitely, and your app falls over.

**Best practice:** always set `requests`. Set `limits` on memory (memory can't be shared politely). Be cautious with CPU limits — they can throttle your app for no good reason. A common pro pattern is `requests.cpu` set realistically, no `limits.cpu`, and `limits.memory == requests.memory`.

## 2.3 The three ways to get compute on EKS — pros and cons

### Option A: EKS Auto Mode (used in this guide)

| ✅ Pros | ❌ Cons |
|---|---|
| Almost nothing to configure; nodes appear in ~60s | ~12% management fee on top of EC2 prices |
| AWS patches, upgrades, and replaces nodes for you | Savings Plans / Reserved Instances **do not** discount that fee |
| Picks the cheapest instance that fits, automatically | Less control: no SSH into nodes, limited AMI customization |
| Built-in load balancer controller, EBS driver, DNS, metrics wiring | Nodes are force-replaced every 21 days max (great for security, bad for long-running stateful jobs) |
| Scales to zero nodes when idle | Newer, so fewer Stack Overflow answers when things break |
| Great for small teams with no platform engineer | Some DaemonSets/security agents need testing before migrating |

### Option B: Managed node groups (the classic way)

You define groups yourself: instance type, min/max/desired count. Add **Cluster Autoscaler** or **self-managed Karpenter** for scaling.

```bash
eksctl create nodegroup \
  --cluster hello-auto \
  --name workers \
  --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 6 \
  --managed --asg-access
```

| ✅ Pros | ❌ Cons |
|---|---|
| No management fee — pure EC2 pricing | You own patching, AMI updates, draining, upgrades |
| Full control: custom AMIs, GPU drivers, SSH, kernel tuning | Scaling is slower and dumber (fixed instance types) |
| Predictable capacity, easy to reason about on the bill | You must install and maintain the autoscaler yourself |
| Massive amount of community documentation | Empty nodes still cost money if you set `min` too high |

**Choose this if:** you have a platform team, a big fleet with heavy Savings Plan coverage, or unusual hardware needs.

### Option C: AWS Fargate

No nodes at all. Each pod gets its own micro-VM, billed per vCPU-second.

| ✅ Pros | ❌ Cons |
|---|---|
| Zero node management whatsoever | No DaemonSets (breaks many logging/security tools) |
| Perfect isolation between pods | No Fargate Spot on EKS (ECS-only feature) |
| Great for short batch jobs and spiky, rare workloads | Usually more expensive for steady 24/7 workloads |
| | No GPUs, no privileged pods, limited storage |

**Rule of thumb in 2026:** new project, small team → **Auto Mode**. Large existing fleet with a working Karpenter setup → **managed node groups**. Occasional isolated jobs → **Fargate**.

## 2.4 The two built-in node pools

Auto Mode ships with two pools you can enable/disable but **cannot edit**:

| Pool | Purpose |
|---|---|
| `general-purpose` | Runs your normal apps. On-demand, amd64, C/M/R families. |
| `system` | Runs cluster infrastructure pods. Tainted so your app pods stay off it. |

Disable them (`nodePools: []` in eksctl, or in the console) when you want *every* node governed by your own NodePools — for example to force private subnets, spot instances, or ARM chips. Keeping them on is fine for learning.

## 2.5 NodePool fields you'll actually use

| Field | What it does | Typical value |
|---|---|---|
| `requirements` | Which instance types are allowed | families `c`,`m`,`r`; generation `> 4` |
| `karpenter.sh/capacity-type` | On-demand vs Spot | `["spot","on-demand"]` for cheap workloads |
| `kubernetes.io/arch` | Chip type | `arm64` (Graviton) is ~20% cheaper if your image supports it |
| `limits.cpu` / `limits.memory` | Hard ceiling on the whole pool | Always set one. Your future self will thank you. |
| `disruption.consolidationPolicy` | When to shrink | `WhenEmptyOrUnderutilized` (aggressive savings) or `WhenEmpty` (safer) |
| `disruption.consolidateAfter` | Quiet period before shrinking | `30s` for dev, `5m`–`15m` for production |
| `expireAfter` | Max node age before forced replacement | `336h` (14 days) |
| `template.spec.taints` | Keep normal pods off | Used for GPU or special pools |
| `template.metadata.labels` | Name tags for `nodeSelector` | `workload-type: web` |
| `weight` | Priority when several pools match | Higher number wins |

### Spot instances: the 90%-off button

```yaml
- key: "karpenter.sh/capacity-type"
  operator: In
  values: ["spot", "on-demand"]     # prefers spot, falls back to on-demand
```

Spot = leftover AWS capacity, up to ~90% cheaper, but AWS can take it back with **2 minutes' notice**. Safe for: stateless web apps with several replicas, batch jobs, CI runners, dev environments. Risky for: databases, single-replica anything, long jobs that can't checkpoint.

If you use spot, also add **PodDisruptionBudgets** so Kubernetes never lets too many replicas vanish at once:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: hello-world-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: hello-world
```

## 2.6 Which Kubernetes version?

As of August 2026, EKS supports roughly **1.33 through 1.36** on standard support. Each version gets 14 months of standard support, then 12 months of *extended support* — during which the cluster fee jumps from **$0.10/hr to $0.60/hr**. That 6× surprise bill is one of the most common EKS cost complaints.

**Best practice:** pick a version one behind the newest (stability + long runway), and calendar an upgrade every ~9 months. Also note: from 1.33 onward, Amazon Linux 2 is gone — nodes use Amazon Linux 2023.

## 2.7 Best practices checklist

**Cost**
- [ ] Set `limits` on every NodePool.
- [ ] Use spot for anything stateless and replicated.
- [ ] Consider `arm64` (Graviton) — cheaper per unit of work.
- [ ] Delete dev clusters at night, or scale deployments to zero.
- [ ] Set an AWS Budget alert *before* you build anything.
- [ ] Remember: Savings Plans don't cover the Auto Mode fee or the cluster fee.

**Reliability**
- [ ] Always ≥ 2 replicas for anything user-facing.
- [ ] Add PodDisruptionBudgets.
- [ ] Add `topologySpreadConstraints` to spread pods across availability zones.
- [ ] Add readiness + liveness probes so traffic never hits a booting pod.
- [ ] Never rely on a specific node existing — nodes are cattle, not pets.

**Security**
- [ ] Put nodes in **private** subnets in production (public subnets are fine for this tutorial only).
- [ ] Use IAM Roles for Service Accounts / EKS Pod Identity — never bake AWS keys into images.
- [ ] Let `expireAfter` recycle nodes regularly; Auto Mode caps node life at 21 days anyway.
- [ ] Scan images; pin image tags to digests rather than `:latest`.

**Operations**
- [ ] Keep NodePool YAML in Git (with Terraform or GitOps), not typed by hand.
- [ ] Start with 2–3 boring NodePools. Don't build twelve on day one.
- [ ] Test a "chaos" run: delete pods, kill nodes, and confirm recovery.

## 2.8 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Pod stuck `Pending` forever | No NodePool matches its requirements | `kubectl describe pod` → read Events; loosen `requirements`; check `nodeSelector` spelling |
| Pod `Pending`, NodePool at limit | Hit `limits.cpu`/`limits.memory` | Raise the limits (deliberately) |
| No nodes launching at all | NodeClass role/subnet/security-group selectors wrong | `kubectl describe nodeclass web-nodeclass` and `kubectl get nodeclaims` |
| `EXTERNAL-IP` stuck `<pending>` | Subnets missing ELB tags, or no public subnet | Public subnets need `kubernetes.io/role/elb=1`; private need `kubernetes.io/role/internal-elb=1` |
| `ImagePullBackOff` | Image name wrong, or node role can't pull from ECR | Check the image name; verify node IAM role permissions |
| `CrashLoopBackOff` | App itself is failing | `kubectl logs <pod> --previous` |
| Nodes never shrink | `consolidateAfter` too long, or pods block eviction | Shorten it; check PDBs and pods without controllers |
| Bill way higher than expected | Extended support ($0.60/hr), orphaned load balancers, NAT Gateway, cross-AZ traffic | Check Cost Explorer grouped by usage type |

## 2.9 Where to go next

1. **Ingress + ALB** — one load balancer serving many apps at different URLs (cheaper than one NLB per service).
2. **Horizontal Pod Autoscaler on custom metrics** — scale on requests-per-second, not just CPU.
3. **Terraform** — rebuild all of this as code so it's repeatable and reviewable.
4. **Observability** — CloudWatch Container Insights, or Prometheus + Grafana.
5. **GitOps (Argo CD / Flux)** — deploy by merging a pull request instead of running `kubectl apply`.
6. **Self-managed Karpenter** — the same engine, fully under your control, no Auto Mode fee.

---

# PART 3 — The Terraform version (with separate state per layer)

Everything in Part 1 was typed by hand. That's great for learning and terrible for real life: nobody remembers what they typed six months ago. Terraform lets you write your infrastructure down as files, keep them in Git, and rebuild the whole thing with one command.

## 3.0 What "state" is, and why we split it

**Terraform state** is a save file. It's a JSON file that records "I created VPC `vpc-abc123`, and it belongs to this line of code." Without it, Terraform has no memory and would try to create everything twice.

Think of it like save files in a video game:

- **One giant save file** = every time you want to change your character's hat, the game reloads the entire world. Slow. And if the file corrupts, you lose everything.
- **Separate save files per level** = change the hat, only the hat level reloads. If one file breaks, the others are fine.

Reasons real teams split state:

| Reason | Plain English |
|---|---|
| **Blast radius** | A typo in the app layer can't accidentally delete your VPC. Terraform can only destroy what's in the state file it's holding. |
| **Speed** | `terraform plan` on 8 resources takes 5 seconds. On 400 resources it takes 4 minutes. |
| **Permissions** | Network engineers get write access to the network state; app developers only get the app state. |
| **Change rate** | The VPC changes twice a year. The app changes twice a day. Don't couple them. |
| **Fewer lock fights** | Two people running `apply` on different layers don't block each other. |

## 3.1 The dependency tree

```
                    ┌──────────────────────────┐
                    │  00-bootstrap            │  state: LOCAL (then migrated to itself)
                    │  S3 bucket for all state │  changes: ~never
                    └────────────┬─────────────┘
                                 │ (provides the bucket everything else writes into)
                    ┌────────────▼─────────────┐
                    │  01-network              │  state: s3://.../01-network/terraform.tfstate
                    │  VPC, subnets, NAT, tags │  changes: ~yearly
                    └────────────┬─────────────┘
                                 │ outputs: vpc_id, private_subnet_ids, public_subnet_ids
                    ┌────────────▼─────────────┐
                    │  02-cluster              │  state: s3://.../02-cluster/terraform.tfstate
                    │  EKS control plane,      │  changes: ~quarterly (version upgrades)
                    │  Auto Mode, IAM roles    │
                    └──────┬──────────────┬────┘
       outputs: cluster_name,│             │ outputs: cluster_endpoint, ca_data
       node_iam_role_name    │             │
              ┌──────────────▼───┐   ┌─────▼──────────────┐
              │  03-nodepools    │   │  (03b-addons)      │  optional: metrics-server,
              │  NodeClass +     │   │                    │  observability, etc.
              │  NodePool CRDs   │   └────────────────────┘
              │  changes: monthly│
              └──────────┬───────┘
                         │ (nodes must be schedulable before pods land)
              ┌──────────▼───────┐
              │  04-app          │  state: s3://.../04-app/terraform.tfstate
              │  hello-world     │  changes: daily
              │  Deployment + Svc│
              └──────────────────┘
```

**Rule of the tree:** arrows point *downward only*. A lower layer may read a higher layer's outputs; a higher layer must never know a lower layer exists. That one rule is what keeps the whole thing untangleable.

| Layer | Owns | Reads from | Blast radius if you break it |
|---|---|---|---|
| `00-bootstrap` | State bucket | nothing | Catastrophic — protect it |
| `01-network` | VPC, subnets, NAT, route tables | nothing | Whole environment down |
| `02-cluster` | EKS cluster, Auto Mode config, IAM | 01 | Cluster down, VPC safe |
| `03-nodepools` | NodeClass, NodePool | 02 | Nodes stop scaling; cluster safe |
| `04-app` | Deployment, Service, HPA, PDB | 02 (+03 labels) | One app down; nothing else |

## 3.2 Folder layout

```
eks-hello-auto/
├── backend.hcl                 # shared backend settings (bucket, region)
├── 00-bootstrap/
│   ├── main.tf
│   └── outputs.tf
├── 01-network/
│   ├── backend.tf  main.tf  variables.tf  outputs.tf
├── 02-cluster/
│   ├── backend.tf  main.tf  variables.tf  outputs.tf
├── 03-nodepools/
│   ├── backend.tf  providers.tf  main.tf  variables.tf  outputs.tf
└── 04-app/
    ├── backend.tf  providers.tf  main.tf  variables.tf  outputs.tf
```

Shared `backend.hcl` (backends can't use variables, so we pass a file instead):

```hcl
# backend.hcl  — pass with: terraform init -backend-config=../backend.hcl
bucket       = "tfstate-hello-auto-123456789012"   # must be globally unique
region       = "us-east-1"
encrypt      = true
use_lockfile = true    # native S3 locking - no DynamoDB table needed (Terraform 1.11+)
```

> **Version note:** `use_lockfile` went GA in Terraform 1.11 and the old `dynamodb_table` argument is deprecated. If you see a guide telling you to create a DynamoDB lock table, it's out of date.

---

## 3.3 Layer 00 — bootstrap (the chicken-and-egg layer)

You need an S3 bucket to store state... but that bucket is itself infrastructure. Solution: create it with **local state**, then migrate its own state into itself.

```hcl
# 00-bootstrap/main.tf
terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # NO backend block yet — starts as a local terraform.tfstate file
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "tfstate-hello-auto-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true    # seatbelt: refuses to be deleted by accident
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }   # REQUIRED for safe locking + undo
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

```hcl
# 00-bootstrap/outputs.tf
output "state_bucket" { value = aws_s3_bucket.tfstate.id }
```

Run it:

```bash
cd 00-bootstrap
terraform init
terraform apply
terraform output state_bucket        # copy this into backend.hcl
```

*(Optional, once the bucket exists: add a `backend "s3"` block with key `00-bootstrap/terraform.tfstate`, re-run `terraform init -migrate-state`, and answer `yes`. Now even the bootstrap layer lives remotely. Commit the local state file to Git **never** — add `*.tfstate*` to `.gitignore`.)*

---

## 3.4 Layer 01 — network

```hcl
# 01-network/backend.tf
terraform {
  required_version = ">= 1.11.0"
  backend "s3" {
    key = "01-network/terraform.tfstate"     # bucket/region come from backend.hcl
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = var.region }
```

```hcl
# 01-network/main.tf
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24",   "10.0.2.0/24",   "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true      # cheap: 1 NAT (~$32/mo). Production: false = 1 per AZ.
  enable_dns_hostnames = true

  # These tags are how load balancers find the right subnets. Miss them and your
  # Service sits at EXTERNAL-IP <pending> forever.
  public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

```hcl
# 01-network/outputs.tf   <-- this is the CONTRACT with the layer below
output "vpc_id"             { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnets }
output "public_subnet_ids"  { value = module.vpc.public_subnets }
```

```bash
cd 01-network
terraform init -backend-config=../backend.hcl
terraform apply
```

---

## 3.5 Layer 02 — the EKS cluster with Auto Mode

```hcl
# 02-cluster/backend.tf
terraform {
  required_version = ">= 1.11.0"
  backend "s3" { key = "02-cluster/terraform.tfstate" }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" { region = var.region }
```

```hcl
# 02-cluster/main.tf

# ---- Reach UP the tree and read layer 01's outputs ----
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "01-network/terraform.tfstate"
    region = var.region
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"          # PIN EXACTLY. This module changes fast.

  name               = var.cluster_name
  kubernetes_version = "1.35"

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  # ===== THE AUTO MODE SWITCH =====
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]   # use [] to run ONLY your own pools
  }
  # =================================

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  tags = { Environment = "learning", ManagedBy = "terraform" }
}
```

```hcl
# 02-cluster/outputs.tf
output "cluster_name"              { value = module.eks.cluster_name }
output "cluster_endpoint"          { value = module.eks.cluster_endpoint }
output "cluster_ca_data"           { value = module.eks.cluster_certificate_authority_data }
output "node_iam_role_name"        { value = module.eks.node_iam_role_name }   # needed by NodeClass
output "cluster_security_group_id" { value = module.eks.cluster_security_group_id }
```

```bash
cd 02-cluster
terraform init -backend-config=../backend.hcl
terraform apply                      # ~15 minutes
aws eks update-kubeconfig --name hello-auto --region us-east-1
```

> **Known trap:** the `compute_config` block is what turns Auto Mode on and off, and some module upgrades have generated a spurious "disable Auto Mode" diff. This is exactly why you pin the version and **always read the plan before typing yes**.

---

## 3.6 Layer 03 — the node pools

This layer applies Kubernetes CRDs (`NodeClass`, `NodePool`), so it needs a Kubernetes provider, not just AWS.

```hcl
# 03-nodepools/providers.tf
terraform {
  required_version = ">= 1.11.0"
  backend "s3" { key = "03-nodepools/terraform.tfstate" }
  required_providers {
    aws     = { source = "hashicorp/aws",  version = "~> 6.0" }
    kubectl = { source = "alekc/kubectl",  version = "~> 2.1" }
  }
}

provider "aws" { region = var.region }

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "02-cluster/terraform.tfstate"
    region = var.region
  }
}

# Log in to the cluster using a short-lived token, generated at run time.
provider "kubectl" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name",
            data.terraform_remote_state.cluster.outputs.cluster_name]
  }
}
```

> **Why `kubectl` instead of the official `kubernetes` provider here?** The official provider's `kubernetes_manifest` resource contacts the cluster during `plan` to learn the CRD's shape. If the CRD doesn't exist yet, the plan explodes. The `kubectl_manifest` resource just sends YAML, so it works fine on a brand-new cluster. For plain Deployments and Services (Part 3.7) the official provider is great.

```hcl
# 03-nodepools/main.tf
locals {
  cluster_name = data.terraform_remote_state.cluster.outputs.cluster_name
  node_role    = data.terraform_remote_state.cluster.outputs.node_iam_role_name
}

resource "kubectl_manifest" "web_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"
    metadata   = { name = "web-nodeclass" }
    spec = {
      role = local.node_role
      subnetSelectorTerms        = [{ tags = { "kubernetes.io/cluster/${local.cluster_name}" = "*" } }]
      securityGroupSelectorTerms = [{ tags = { "kubernetes.io/cluster/${local.cluster_name}" = "owned" } }]
      ephemeralStorage = { size = "40Gi", iops = 3000, throughput = 125 }
    }
  })
}

resource "kubectl_manifest" "web_nodepool" {
  depends_on = [kubectl_manifest.web_nodeclass]   # explicit ordering inside the layer

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "web-pool" }
    spec = {
      template = {
        metadata = { labels = { "workload-type" = "web" } }
        spec = {
          nodeClassRef = { group = "eks.amazonaws.com", kind = "NodeClass", name = "web-nodeclass" }
          requirements = [
            { key = "eks.amazonaws.com/instance-category",   operator = "In", values = ["c", "m", "r"] },
            { key = "eks.amazonaws.com/instance-cpu",        operator = "In", values = ["2", "4", "8"] },
            { key = "eks.amazonaws.com/instance-generation", operator = "Gt", values = ["4"] },
            { key = "kubernetes.io/arch",                    operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type",            operator = "In", values = var.capacity_types },
          ]
          expireAfter = "336h"
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = var.consolidate_after
      }
      limits = { cpu = var.pool_cpu_limit, memory = var.pool_memory_limit }
    }
  })
}
```

```hcl
# 03-nodepools/variables.tf   — the knobs you actually turn per environment
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type = string          # no default: set it in terraform.tfvars
}

variable "capacity_types" {
  type    = list(string)
  default = ["on-demand"]   # dev/staging: ["spot", "on-demand"]
}

variable "consolidate_after" {
  type    = string
  default = "30s"           # production: "5m" or longer
}

variable "pool_cpu_limit" {
  type    = string
  default = "100"
}

variable "pool_memory_limit" {
  type    = string
  default = "200Gi"
}
```

```hcl
# 03-nodepools/outputs.tf
output "nodepool_label" { value = "workload-type=web" }   # contract for layer 04
```

---

## 3.7 Layer 04 — the Hello World app

```hcl
# 04-app/providers.tf
terraform {
  required_version = ">= 1.11.0"
  backend "s3" { key = "04-app/terraform.tfstate" }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = { bucket = var.state_bucket, key = "02-cluster/terraform.tfstate", region = var.region }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name",
            data.terraform_remote_state.cluster.outputs.cluster_name]
  }
}
```

```hcl
# 04-app/main.tf
resource "kubernetes_deployment" "hello" {
  metadata {
    name   = "hello-world"
    labels = { app = "hello-world" }
  }

  spec {
    replicas = var.replicas
    selector { match_labels = { app = "hello-world" } }

    template {
      metadata { labels = { app = "hello-world" } }
      spec {
        node_selector = { "workload-type" = "web" }   # land on OUR node pool

        container {
          name    = "web"
          image   = "public.ecr.aws/nginx/nginx:alpine"
          command = ["/bin/sh", "-c"]
          args    = ["echo \"Hello World from $(hostname)\" > /usr/share/nginx/html/index.html && nginx -g 'daemon off;'"]

          port { container_port = 80 }

          resources {
            requests = { cpu = "250m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "hello" {
  metadata {
    name = "hello-world"
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
    }
  }
  spec {
    type     = "LoadBalancer"
    selector = { app = "hello-world" }
    port {
      port        = 80
      target_port = 80
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "hello" {
  metadata { name = "hello-world-pdb" }
  spec {
    min_available = 1
    selector { match_labels = { app = "hello-world" } }
  }
}
```

```hcl
# 04-app/outputs.tf
output "url" {
  value = "http://${kubernetes_service.hello.status[0].load_balancer[0].ingress[0].hostname}"
}
```

```bash
cd 04-app
terraform init -backend-config=../backend.hcl
terraform apply
terraform output url          # paste into your browser
```

Scaling now means editing one number:

```bash
terraform apply -var="replicas=20"    # nodes appear
terraform apply -var="replicas=2"     # nodes disappear
```

---

## 3.8 Running the whole thing

**Build order — follow the tree downward:**

```bash
export TF_BACKEND=../backend.hcl

(cd 00-bootstrap && terraform init && terraform apply)
(cd 01-network   && terraform init -backend-config=$TF_BACKEND && terraform apply)
(cd 02-cluster   && terraform init -backend-config=$TF_BACKEND && terraform apply)
aws eks update-kubeconfig --name hello-auto --region us-east-1
(cd 03-nodepools && terraform init -backend-config=$TF_BACKEND && terraform apply)
(cd 04-app       && terraform init -backend-config=$TF_BACKEND && terraform apply)
```

**Destroy order — exactly backwards. This is not optional.**

```bash
(cd 04-app       && terraform destroy)    # deletes the load balancer FIRST
(cd 03-nodepools && terraform destroy)
(cd 02-cluster   && terraform destroy)
(cd 01-network   && terraform destroy)
# 00-bootstrap has prevent_destroy = true; remove that line if you really mean it
```

If you destroy the network before the app, the load balancer still exists, holds network interfaces in the subnets, and the VPC destroy hangs for 20 minutes and then fails. Same trap as Part 1, Step 9 — Terraform doesn't save you from it, because separate states means Terraform *can't see* the dependency across layers.

A tiny `Makefile` makes this safe:

```makefile
LAYERS_UP   = 01-network 02-cluster 03-nodepools 04-app
LAYERS_DOWN = 04-app 03-nodepools 02-cluster 01-network

up:
	@for d in $(LAYERS_UP); do \
	  (cd $$d && terraform init -input=false -backend-config=../backend.hcl && terraform apply -auto-approve) || exit 1; \
	done

down:
	@for d in $(LAYERS_DOWN); do \
	  (cd $$d && terraform destroy -auto-approve) || exit 1; \
	done

plan:
	@for d in $(LAYERS_UP); do echo "== $$d =="; (cd $$d && terraform plan); done
```

## 3.9 How layers talk to each other

Three ways to pass information down the tree:

| Method | How | Pros | Cons |
|---|---|---|---|
| **`terraform_remote_state`** (used above) | Read the layer above's state file directly | Simple, typed, no extra resources | Reader needs S3 read on the *whole* state file — which contains secrets |
| **AWS data sources** | Look resources up by tag: `data "aws_vpc" { filter { tag:Name } }` | Zero coupling; works even if the VPC wasn't made by Terraform | Silent breakage if someone renames a tag |
| **SSM Parameter Store** | Upper layer writes params; lower layer reads them | Explicit published contract, fine-grained IAM | One more moving part |

**Best practice for teams:** publish outputs to SSM Parameter Store, and treat those parameter names as a versioned API between teams. For a solo project, `terraform_remote_state` is perfectly fine — just remember that **state files contain secrets in plaintext**, so encrypt the bucket and lock down who can read it.

## 3.10 Split state vs. one big state — pros and cons

| | ✅ Pros | ❌ Cons |
|---|---|---|
| **Split state (this guide)** | Small blast radius; fast plans; per-layer permissions; parallel work; easy to destroy just the app | You must remember apply/destroy order yourself; cross-layer changes need multiple applies; more boilerplate |
| **One giant state** | One `apply` does everything; Terraform figures out all ordering for you | Slow; one bad plan can delete production; everyone fights over the lock; can't give partial access |

**Alternatives worth knowing about:**

- **Terraform workspaces** — same code, different state per environment (`dev`/`prod`). Good for *environments*, bad for *layers*. Easy to run in the wrong workspace by accident.
- **Terragrunt** — a wrapper that generates the backend blocks and works out layer ordering (`terragrunt run-all apply`) from `dependency` blocks. It exists precisely because of the manual ordering pain in 3.8.
- **Terraform Stacks / CDKTF / Pulumi** — newer approaches that model cross-layer dependencies natively.
- **Separate AWS accounts per environment** — the strongest blast-radius boundary of all. Standard in production.

**Rule of thumb:** one state per *thing that changes at a different speed or is owned by a different person.* If two things always change together and are owned by the same person, don't split them.

## 3.11 Terraform-specific gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `Error: Kubernetes cluster unreachable` in layer 03/04 | kubeconfig/token not available, or cluster endpoint private | Run `aws eks update-kubeconfig` first; check the `exec` block region and profile |
| Plan fails on `kubernetes_manifest` for a CRD | Official provider queries the API at plan time | Use `kubectl_manifest`, or apply the CRD in an earlier layer |
| `terraform destroy` on network hangs | Load balancer/ENIs still exist | Destroy layer 04 first; check for orphaned ELBs |
| Plan wants to disable Auto Mode after a module bump | Module version drift in `compute_config` | Pin the exact module version; read every plan |
| `Error acquiring the state lock` | Someone else is applying, or a run crashed | Wait; if truly stale, `terraform force-unlock <ID>` (carefully) |
| Backend config changed | You edited `backend.hcl` | `terraform init -reconfigure` (or `-migrate-state` if moving state) |
| Secrets visible in state | Normal Terraform behaviour | Encrypt the bucket, restrict IAM, never commit `*.tfstate` |

**Terraform best practices checklist**

- [ ] `.gitignore` contains `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.tfvars` with secrets.
- [ ] Commit `.terraform.lock.hcl` (provider version lock) — yes, this one goes in Git.
- [ ] Pin module versions exactly (`= 21.24.0`), pin providers with `~>`.
- [ ] Enable S3 bucket versioning — it's your undo button and required for safe locking.
- [ ] `prevent_destroy` on the state bucket and anything else irreplaceable.
- [ ] Always run `terraform plan` and actually read it. `-auto-approve` belongs in CI, not your terminal.
- [ ] Run `terraform fmt` and `terraform validate` before committing; add `tflint`/`checkov` in CI.
- [ ] Tag everything (`Environment`, `Owner`, `ManagedBy`) so the bill is readable.

## 3.12 Sources & official docs

- EKS Auto Mode overview: https://docs.aws.amazon.com/eks/latest/userguide/automode.html
- Create an Auto Mode cluster with eksctl: https://docs.aws.amazon.com/eks/latest/userguide/automode-get-started-eksctl.html
- Create a NodePool: https://docs.aws.amazon.com/eks/latest/userguide/create-node-pool.html
- NodeClass reference: https://docs.aws.amazon.com/eks/latest/userguide/create-node-class.html
- NLB service annotations in Auto Mode: https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-nlb.html
- Kubernetes version support: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html
- EKS pricing: https://aws.amazon.com/eks/pricing/
- eksctl Auto Mode docs: https://docs.aws.amazon.com/eks/latest/eksctl/auto-mode.html
- Karpenter (the engine behind it): https://karpenter.sh/

**Terraform**
- EKS Terraform module: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
- EKS Auto Mode example: https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest/examples/eks-auto-mode
- VPC Terraform module: https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest
- S3 backend + native locking: https://developer.hashicorp.com/terraform/language/backend/s3
- `terraform_remote_state`: https://developer.hashicorp.com/terraform/language/state/remote-state-data
- Terragrunt (if manual layer ordering annoys you): https://terragrunt.gruntwork.io/

---

*AWS ships changes constantly. If a command errors, check the official doc linked above for that exact step — it will be newer than this guide.*
