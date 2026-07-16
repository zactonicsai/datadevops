# AWS EKS Networking — The Complete Beginner-to-Pro Tutorial

*Covers: VPC, subnets, EKS pods, internal & external connectivity, ALB listener rules, target groups, Route 53, EC2 worker nodes, and managing nodes with Ansible.*

*Tested against: EKS Kubernetes 1.33, AWS Load Balancer Controller v2.13+, VPC CNI add-on (2026).*

---

## 0. Background — What Are We Even Building?

Before we type a single command, let's understand the pieces in plain language.

### What is a VPC?
A **VPC (Virtual Private Cloud)** is your own private slice of the AWS network. Think of it like your own **gated neighborhood** inside a giant city (AWS). Nothing gets in or out unless you build a gate (internet gateway) or a road (NAT gateway, VPN, peering).

### What are subnets?
**Subnets** are the **streets** inside your neighborhood. Each subnet lives in one Availability Zone (AZ = one physical data center area).
- **Public subnet** = a street with a gate to the outside world (has a route to an Internet Gateway). Load balancers usually live here.
- **Private subnet** = an inner street with no direct gate. Your EC2 worker nodes and pods live here for safety. They can still reach the internet *outbound* through a **NAT Gateway** (a one-way door: you can go out, strangers can't come in).

### What is EKS?
**EKS (Elastic Kubernetes Service)** is AWS running the Kubernetes "brain" (the control plane) for you. You only manage the **worker nodes** (EC2 machines) where your **pods** (your running containers/apps) actually live.

### The magic of the AWS VPC CNI
Here is the single most important fact about EKS networking:

> **On EKS, every pod gets a REAL IP address from your VPC subnet — the same kind of IP an EC2 machine gets.**

This is done by the **Amazon VPC CNI plugin** (a networking add-on that runs on every node). It grabs extra IP addresses from the node's network cards (ENIs) and hands one to each pod. Consequences:

| Consequence | Why it matters |
|---|---|
| Pods are directly reachable inside the VPC | An EC2 instance or RDS database in the same VPC can talk to a pod IP directly |
| Subnets can run out of IPs | Each pod eats one subnet IP — plan big CIDR ranges (e.g., /16 VPC, /19–/20 subnets) |
| Load balancers can target pods directly | This is what "IP mode" target groups do (explained later) |

### The traffic path we will build (the big picture)

```
Internet user
   │
   ▼
Route 53 (DNS: app.example.com → ALB address)
   │
   ▼
Application Load Balancer (public subnets)
   │  ← Listener (port 443) + Listener RULES decide where traffic goes
   ▼
Target Group (contains pod IPs, health-checked)
   │
   ▼
Pods on EC2 worker nodes (private subnets)
   │
   ▼ (pod-to-pod, pod-to-database = internal VPC traffic)
Other pods / RDS / EC2 inside the VPC
```

Keep this picture in your head. Every section below fills in one box.

---

# PART 1 — Step-by-Step: One Complete Working Example

We will build, from zero: a VPC → an EKS cluster with EC2 nodes → a demo app → an ALB with listener rules → a Route 53 DNS name. Every step is explained.

### Prerequisites (install these first)

```bash
# AWS CLI v2 (talks to AWS)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# eksctl (creates EKS clusters easily)
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# kubectl (talks to Kubernetes)
curl -LO "https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# helm (installs Kubernetes packages)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

aws configure   # enter your access key, secret, region (e.g. us-east-1)
```

---

## Step 1 — Create the VPC and the EKS cluster (one command)

`eksctl` can create the whole neighborhood (VPC, public + private subnets in 3 AZs, NAT gateway, route tables) *and* the cluster together. Save this as `cluster.yaml`:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: demo-cluster
  region: us-east-1
  version: "1.33"            # latest EKS Kubernetes version

vpc:
  cidr: 10.0.0.0/16          # BIG range = plenty of IPs for pods
  nat:
    gateway: Single           # one NAT gateway (cheap); use HighlyAvailable in prod

iam:
  withOIDC: true              # REQUIRED for IRSA (pods getting IAM roles) — used later

managedNodeGroups:
  - name: workers
    instanceType: t3.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    privateNetworking: true   # nodes go into PRIVATE subnets (best practice!)
    ssh:
      allow: false            # we'll use SSM instead of SSH (safer, used by Ansible later)
    iam:
      withAddonPolicies:
        ssm: true             # lets AWS Systems Manager (and Ansible via SSM) reach nodes

addons:
  - name: vpc-cni             # the plugin that gives pods real VPC IPs
  - name: coredns             # internal DNS for service discovery
  - name: kube-proxy          # routes Service traffic to pods
```

Create it (takes ~15 minutes):

```bash
eksctl create cluster -f cluster.yaml
kubectl get nodes    # you should see 2 nodes in "Ready" state
```

**What just happened, explained:**
- A VPC `10.0.0.0/16` with 3 **public** subnets (for load balancers) and 3 **private** subnets (for nodes/pods) was created.
- eksctl automatically **tagged** the subnets — this matters! The Load Balancer Controller finds subnets by these tags:
  - Public subnets: `kubernetes.io/role/elb = 1`
  - Private subnets: `kubernetes.io/role/internal-elb = 1`
- Two EC2 `t3.large` machines joined the cluster as worker nodes in the private subnets.
- The **VPC CNI** is ready to hand out pod IPs from `10.0.x.x`.

## Step 2 — Install the AWS Load Balancer Controller

This controller is the robot that watches your Kubernetes `Ingress` objects and automatically builds real ALBs, target groups, and listener rules in AWS.

```bash
CLUSTER=demo-cluster
REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# 2a. Create the IAM policy the controller needs (lets it create ALBs)
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json

# 2b. Give that policy to the controller's pod via IRSA
#     (IRSA = IAM Roles for Service Accounts: a pod gets its OWN AWS permissions,
#      instead of borrowing the whole node's permissions. Much safer.)
eksctl create iamserviceaccount \
  --cluster=$CLUSTER --region=$REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name=AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::$ACCOUNT:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# 2c. Install the controller with Helm
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

kubectl get deployment -n kube-system aws-load-balancer-controller  # wait for 2/2 READY
```

## Step 3 — Deploy two demo apps (so listener rules have something to route between)

Save as `apps.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 2
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
        - name: web
          image: public.ecr.aws/nginx/nginx:latest
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service                      # a Service = stable "phone number" for a group of pods
metadata:
  name: web-svc
spec:
  type: ClusterIP                  # internal-only address (ALB will target pods directly)
  selector: { app: web }
  ports: [{ port: 80, targetPort: 80 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 2
  selector: { matchLabels: { app: api } }
  template:
    metadata: { labels: { app: api } }
    spec:
      containers:
        - name: api
          image: public.ecr.aws/docker/library/httpd:latest
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
spec:
  type: ClusterIP
  selector: { app: api }
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
kubectl apply -f apps.yaml
kubectl get pods -o wide   # NOTICE: each pod has a 10.0.x.x IP — a REAL VPC IP!
```

## Step 4 — Create the ALB with listener rules (via Ingress)

This is where **listeners, listener rules, and target groups** come alive. Save as `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing        # public ALB (use "internal" for private)
    alb.ingress.kubernetes.io/target-type: ip                # target group contains POD IPs directly
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111122223333:certificate/YOUR-CERT-ID
    alb.ingress.kubernetes.io/ssl-redirect: '443'            # rule: HTTP 80 → redirect to HTTPS 443
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
spec:
  ingressClassName: alb
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /api                 # listener RULE #1: path starts with /api → api target group
            pathType: Prefix
            backend:
              service: { name: api-svc, port: { number: 80 } }
          - path: /                    # listener RULE #2: everything else → web target group
            pathType: Prefix
            backend:
              service: { name: web-svc, port: { number: 80 } }
```

```bash
kubectl apply -f ingress.yaml
kubectl get ingress demo-ingress
# ADDRESS column shows something like:
# k8s-default-demoingr-abcd1234-1234567890.us-east-1.elb.amazonaws.com
```

**What the controller just built in AWS (check the EC2 console → Load Balancers):**

1. **An ALB** in your *public* subnets (found via the `kubernetes.io/role/elb` tags).
2. **Two listeners:**
   - Listener on port **80** → one rule: *redirect everything to 443* (from `ssl-redirect`).
   - Listener on port **443** (with your ACM certificate) → the real rules.
3. **Listener rules on :443** (evaluated top-down by priority number):
   - Priority 1: IF host = `app.example.com` AND path = `/api*` → **forward** to target group `api`
   - Priority 2: IF host = `app.example.com` AND path = `/*` → **forward** to target group `web`
   - Default rule: return 404 (nothing matched)
4. **Two target groups**, each containing the **pod IPs** (target-type: ip), with health checks hitting `/` every 15 s. Unhealthy pods get no traffic.

> **Tip:** if you don't have an ACM certificate yet, delete the `certificate-arn`, `ssl-redirect`, and `HTTPS` lines and test with plain HTTP first. Request a free certificate in **AWS Certificate Manager** for the real setup.

## Step 5 — Point Route 53 DNS at the ALB

Route 53 is AWS's DNS service — the phone book that turns `app.example.com` into your ALB's address.

```bash
# Find your hosted zone ID (your domain must be a hosted zone in Route 53)
aws route53 list-hosted-zones-by-name --dns-name example.com

# Get the ALB's DNS name and its hosted zone ID
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'demoingr')].[DNSName,CanonicalHostedZoneId]"
```

Create an **Alias A record** (save as `record.json`, then apply):

```json
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "app.example.com",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "Z35SXDOTRQ7X7K",
        "DNSName": "k8s-default-demoingr-abcd1234-1234567890.us-east-1.elb.amazonaws.com",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
```

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_ZONE_ID --change-batch file://record.json
```

**Why an Alias record and not a CNAME?**
- Alias works at the zone root (`example.com` itself) — CNAME can't.
- Alias queries are **free**; CNAME lookups are billed.
- Alias can health-check the ALB (`EvaluateTargetHealth`).

## Step 6 — Test everything

```bash
curl https://app.example.com/        # → nginx welcome page (web pods)
curl https://app.example.com/api     # → "It works!" (httpd/api pods)
curl -I http://app.example.com/      # → 301 redirect to https (listener rule!)
```

🎉 **You now have the full path working:** Route 53 → ALB → listener rules → target groups → pod IPs.

---

# PART 2 — Deep Dive: How Each Piece Really Works

## 2.1 Internal VPC connectivity (pod ↔ pod, pod ↔ EC2, pod ↔ RDS)

Because the VPC CNI gives pods real VPC IPs, **internal traffic is just normal VPC routing** — no tunnels, no overlays.

**Pod → Pod (same cluster):** never use pod IPs directly (they change when pods restart). Use a **Service**:

```
ClusterIP Service "web-svc" gets a stable virtual IP (e.g. 172.20.45.10)
        │  kube-proxy on every node rewrites this to a real pod IP
        ▼
one of the web pods (round-robin)
```

And you don't even need the IP — **CoreDNS** gives every Service a name:

```
web-svc                          → from inside the same namespace
web-svc.default                  → from another namespace
web-svc.default.svc.cluster.local → full name (always works)
```

**Pod → EC2 / RDS in the same VPC:** just connect to its private IP or endpoint. Two things must allow it:
1. **Security groups** — the RDS/EC2 security group must allow inbound traffic from the **node security group** (or the pod's security group, if you use "Security Groups for Pods").
2. **NACLs / route tables** — default VPC settings already allow this.

**EC2 → Pod:** works directly to the pod IP, but again — better to expose an **internal load balancer**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: internal-api
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal   # ← private NLB, VPC-only
spec:
  type: LoadBalancer
  selector: { app: api }
  ports: [{ port: 80, targetPort: 80 }]
```

This creates a **private NLB** in your private subnets (found via `kubernetes.io/role/internal-elb` tags) — reachable only inside the VPC (or over VPN/peering/Transit Gateway).

**Pod → Internet (outbound):** pod (private subnet) → route table → **NAT Gateway** (public subnet) → Internet Gateway. The pod's traffic appears to come from the NAT's public IP. Nobody can initiate a connection *in* through NAT — one-way door.

**Pod → AWS services (S3, ECR, etc.) without the internet:** add **VPC Endpoints** (best practice — cheaper than NAT traffic and more secure):

```bash
# Gateway endpoint for S3 (free!)
aws ec2 create-vpc-endpoint --vpc-id vpc-xxx --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids rtb-xxx
# Interface endpoints commonly needed by EKS: ecr.api, ecr.dkr, sts, ec2, logs
```

## 2.2 External connectivity — all your options, with pros & cons

| Option | What it is | Pros | Cons | Use when |
|---|---|---|---|---|
| **Ingress → ALB** | Layer 7 (HTTP) load balancer | Path/host routing, HTTPS termination, WAF, OIDC auth, redirects | HTTP(S) only, slightly higher latency | Web apps & APIs (most common) |
| **Service LoadBalancer → NLB** | Layer 4 (TCP/UDP) load balancer | Very fast, static IPs possible, TLS passthrough, any protocol | No path routing, no WAF | Databases, gRPC, game servers, TCP |
| **NodePort** | Opens a high port (30000–32767) on every node | No AWS cost, simple | Ugly ports, no health-aware LB, exposes nodes | Testing only |
| **ClusterIP + private NLB** | Internal-only LB | Not reachable from internet | Needs VPN/peering to reach from outside VPC | Internal microservices, partner links |
| **Classic Load Balancer** | Legacy in-tree LB | — | Deprecated; no ALB/NLB features | Never for new builds |

**Best practice:** ALB (via Ingress) for HTTP/HTTPS, NLB (via Service) for raw TCP/UDP. Always run the **AWS Load Balancer Controller**, never the legacy in-tree provider.

## 2.3 Target groups — instance mode vs IP mode (important!)

A **target group** is the ALB/NLB's list of "who can I send traffic to?", plus health checks.

| | `target-type: instance` | `target-type: ip` ✅ recommended |
|---|---|---|
| Targets registered | EC2 nodes on a NodePort | **Pod IPs directly** |
| Traffic path | ALB → node → kube-proxy → maybe *another* node → pod (extra hop!) | ALB → pod (direct) |
| Latency | Higher | Lower |
| Health checks | Check the node port | Check the actual pod |
| Fargate support | ❌ No | ✅ Yes |
| Requirement | Service must be NodePort/LoadBalancer | VPC CNI (pods have VPC IPs) — you already have this on EKS |

Because EKS pods have real VPC IPs, **IP mode is the natural and best choice**: fewer hops, truer health checks, works with Fargate.

## 2.4 Listener rules — the complete picture

A **listener** = "the ALB is listening on this port/protocol" (e.g., HTTPS :443).
**Listener rules** = an ordered IF/THEN list evaluated by **priority** (lowest number first; first match wins; the **default rule** catches everything else).

**Conditions you can match on:** host header (`api.example.com`), path (`/api/*`), HTTP headers, HTTP method (GET/POST), query string, source IP.

**Actions:** `forward` (to one or more target groups — including **weighted** splits for canary releases), `redirect` (e.g., HTTP→HTTPS), `fixed-response` (return a static 404/maintenance page), `authenticate-oidc` / `authenticate-cognito` (force login *before* traffic reaches your pods!).

With the Load Balancer Controller, you express rules through Ingress paths/hosts + annotations. Useful advanced annotations:

```yaml
# Canary: send 10% of traffic to v2, 90% to v1
alb.ingress.kubernetes.io/actions.weighted-routing: >
  {"type":"forward","forwardConfig":{"targetGroups":[
    {"serviceName":"web-v1","servicePort":80,"weight":90},
    {"serviceName":"web-v2","servicePort":80,"weight":10}]}}

# Share ONE ALB across many Ingresses/teams (saves money):
alb.ingress.kubernetes.io/group.name: shared-alb
alb.ingress.kubernetes.io/group.order: '10'     # rule priority within the group

# Attach a WAF:
alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:...
```

**Best practices for listener rules:**
- Put the **most specific** rules at the lowest priority numbers (`/api/v2/*` before `/api/*` before `/*`).
- Always terminate TLS at the ALB with an **ACM certificate** (free, auto-renews) and redirect 80→443.
- Use `fixed-response` on the default rule instead of exposing a random service by accident.
- Use `group.name` to share one ALB — each ALB costs ~$16+/month before traffic.

## 2.5 Route 53 — beyond the basics

Route 53 **routing policies** (pros/cons):

| Policy | What it does | Great for | Watch out |
|---|---|---|---|
| Simple | One name → one target | Single-region apps | No health checks/failover |
| Weighted | 70/30 split between targets | Canary / gradual migration | DNS caching delays shifts |
| Latency | Sends users to the nearest region | Multi-region performance | Needs deployments in ≥2 regions |
| Failover | Primary + standby with health checks | Disaster recovery | Standby costs money while idle |
| Geolocation | Route by user's country | Legal/data-residency rules | Gaps need a default record |

**Automate DNS with ExternalDNS (best practice):** instead of hand-editing records, install the **ExternalDNS** controller — it watches your Ingresses and creates/updates Route 53 records automatically:

```bash
# Give it Route 53 permissions via IRSA (same pattern as Step 2), then:
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm install external-dns external-dns/external-dns \
  --set provider=aws \
  --set policy=upsert-only \
  --set txtOwnerId=demo-cluster
# Now the host "app.example.com" in your Ingress creates its own Route 53 record. Zero manual steps.
```

## 2.6 EC2 worker nodes — what's happening on them

Each node runs: **kubelet** (talks to the EKS control plane), **kube-proxy** (Service routing), and the **aws-node** DaemonSet (the VPC CNI).

Networking facts about nodes:
- The number of pods a node can host is limited by its ENI/IP capacity (e.g., a `t3.large` ≈ 35 pods by default). **Prefix delegation** (`ENABLE_PREFIX_DELEGATION=true` on the CNI) assigns /28 blocks instead of single IPs and raises this to 110.
- Node security group must allow: node↔node (all), node↔control plane (443, 10250), and **9443 from the control plane** if you run the Load Balancer Controller webhooks. eksctl sets these up for you.
- **Managed node groups** (what we used) handle draining and rolling updates for you — prefer them over self-managed nodes.

---

# PART 3 — Using Ansible on EKS Nodes

## 3.1 First, an honest warning (best practice!)

Kubernetes philosophy treats nodes as **cattle, not pets**: instead of logging into nodes and changing them, you bake changes into a new machine image (AMI) or launch template and **replace** the nodes. Configuration drift (nodes that were hand-modified) is the #1 cause of "works on node A, breaks on node B."

**So when IS Ansible on nodes appropriate?**
- ✅ Installing security/monitoring agents required by your company on existing nodes
- ✅ One-time audits ("which kernel version is every node running?")
- ✅ Emergency patching before a proper AMI rollout
- ✅ Managing *self-managed* node fleets or hybrid EC2s alongside the cluster
- ❌ NOT for deploying apps (use `kubectl`/Helm/ArgoCD)
- ❌ NOT for permanent node configuration (use custom AMIs, launch template `user-data`, or EKS node bootstrap config)

## 3.2 Setup: Ansible over SSM (no SSH keys — best practice)

Remember we created nodes with `ssh.allow: false` and the SSM addon policy. **AWS Systems Manager (SSM)** lets you run commands on EC2 without opening port 22 or managing keys — and Ansible supports it natively.

```bash
pip install ansible boto3 botocore
ansible-galaxy collection install amazon.aws community.aws
# The SSM connection also needs an S3 bucket for file transfers:
aws s3 mb s3://my-ansible-ssm-bucket-12345
```

## 3.3 Dynamic inventory — find your nodes automatically

Never hand-write node IPs (they change constantly). Use the AWS EC2 inventory plugin. Save as `inventory_aws_ec2.yml`:

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  # eksctl tags every node with the cluster name — we select by that tag:
  tag:eks:cluster-name: demo-cluster
  instance-state-name: running
keyed_groups:
  - key: tags['eks:nodegroup-name']    # auto-create groups per nodegroup
    prefix: nodegroup
hostnames:
  - instance-id                        # SSM addresses machines by instance ID
compose:
  ansible_host: instance_id
```

```bash
ansible-inventory -i inventory_aws_ec2.yml --graph
# @all:
#   @nodegroup_workers:
#     i-0abc123...
#     i-0def456...
```

## 3.4 A real playbook (audit + install an agent)

Save as `node-maintenance.yml`:

```yaml
- name: EKS node maintenance
  hosts: nodegroup_workers
  gather_facts: true
  become: true
  serial: 1                      # ← one node at a time = zero downtime (best practice)
  vars:
    ansible_connection: aws_ssm  # ← the magic: connect via SSM, not SSH
    ansible_aws_ssm_region: us-east-1
    ansible_aws_ssm_bucket_name: my-ansible-ssm-bucket-12345

  tasks:
    - name: Report kernel and kubelet versions (audit)
      shell: "uname -r && kubelet --version"
      register: versions
      changed_when: false

    - name: Show results
      debug: { var: versions.stdout_lines }

    - name: Install the SSM-managed CloudWatch agent (idempotent)
      package:
        name: amazon-cloudwatch-agent
        state: present

    - name: Ensure agent is running
      service:
        name: amazon-cloudwatch-agent
        state: started
        enabled: true
```

```bash
ansible-playbook -i inventory_aws_ec2.yml node-maintenance.yml
```

## 3.5 Draining nodes safely before disruptive changes

If your playbook will reboot or heavily modify a node, tell Kubernetes to move the pods off first (**cordon + drain**), work on it, then bring it back (**uncordon**):

```yaml
- name: Safely patch and reboot nodes one at a time
  hosts: nodegroup_workers
  serial: 1
  become: true
  vars:
    ansible_connection: aws_ssm
    ansible_aws_ssm_region: us-east-1
    ansible_aws_ssm_bucket_name: my-ansible-ssm-bucket-12345

  tasks:
    - name: Get this node's Kubernetes name
      shell: curl -s http://169.254.169.254/latest/meta-data/local-hostname
      register: nodename
      changed_when: false

    - name: Drain the node (run from your machine, not the node)
      delegate_to: localhost
      become: false
      vars: { ansible_connection: local }
      shell: >
        kubectl drain {{ nodename.stdout }}
        --ignore-daemonsets --delete-emptydir-data --timeout=120s

    - name: Apply all OS security updates
      yum: { name: '*', security: true, state: latest }

    - name: Reboot and wait
      reboot: { reboot_timeout: 600 }

    - name: Uncordon (allow pods back)
      delegate_to: localhost
      become: false
      vars: { ansible_connection: local }
      shell: kubectl uncordon {{ nodename.stdout }}
```

## 3.6 Ansible-on-EKS best practices summary

- **SSM over SSH** — no open ports, no key management, everything logged in CloudTrail.
- **Dynamic inventory by tags** — nodes come and go; tags are stable.
- **`serial: 1` + drain/uncordon** for anything disruptive.
- **Idempotent tasks only** (`state: present`, not `shell: yum install`), so re-runs are safe.
- **Prefer replacement over mutation**: for permanent changes, put them in the node group's launch template / custom AMI (you can even use Ansible + Packer to *build* that AMI — the best of both worlds).
- Keep playbooks in Git; run them from CI, not laptops.

---

# PART 4 — Master Best-Practices Checklist

**VPC & subnets**
- /16 VPC; big private subnets across ≥3 AZs; pods eat IPs fast.
- Nodes and pods in **private** subnets; only load balancers and NAT in public.
- Tag subnets: `kubernetes.io/role/elb=1` (public), `kubernetes.io/role/internal-elb=1` (private).
- Enable **prefix delegation** on the VPC CNI for higher pod density.
- Add **VPC endpoints** (S3, ECR, STS, CloudWatch Logs) to cut NAT costs and exposure.

**Load balancing**
- ALB for HTTP(S), NLB for TCP/UDP; always via the AWS Load Balancer Controller.
- `target-type: ip` everywhere.
- TLS at the ALB with **ACM**, force 80→443 redirect.
- Share ALBs with `group.name`; protect with **WAF**; specific listener rules first.
- Health check a real endpoint (e.g. `/healthz`), not just `/`.

**DNS**
- Alias records to ALBs (free + root-domain capable).
- Automate with **ExternalDNS**.
- Multi-region? Latency or failover routing + Route 53 health checks.

**Security**
- **IRSA** for every pod that needs AWS APIs — never node-wide credentials.
- Restrict pod↔pod with **NetworkPolicies** (VPC CNI now enforces them natively) or Security Groups for Pods.
- No SSH to nodes — SSM only.

**Nodes & operations**
- Managed node groups; replace nodes, don't mutate them.
- Ansible via SSM + dynamic inventory for the exceptions; drain first, `serial: 1`.
- Keep EKS within supported versions (standard support = 14 months per minor version).

---

# PART 5 — Troubleshooting Quick Table

| Symptom | Most likely cause | Fix |
|---|---|---|
| Ingress has no ADDRESS | Controller can't find subnets | Check subnet tags (`kubernetes.io/role/elb`) and controller pod logs |
| Targets "unhealthy" in target group | Health check path wrong, or SG blocks ALB→pod | Fix `healthcheck-path`; ensure node/pod SG allows the ALB security group |
| Pods stuck `Pending`, "no available IP" | Subnet out of IPs | Bigger subnets, prefix delegation, or secondary CIDR on the VPC |
| Pod can't reach the internet | No NAT route from private subnet | Check private route table has `0.0.0.0/0 → nat-...` |
| Pod can't reach RDS | Security group | Allow node SG (or pod SG) inbound on the DB port |
| DNS name doesn't resolve | Record in the wrong zone / not propagated | `dig app.example.com`; verify hosted zone NS records at your registrar |
| 404 from ALB on every path | Hit the default rule | Host header in the request must match the Ingress `host:` |
| Ansible SSM connection fails | Node role lacks SSM policy / no S3 bucket | Attach `AmazonSSMManagedInstanceCore`; set `ansible_aws_ssm_bucket_name` |

---

## Cleanup (avoid charges!)

```bash
kubectl delete -f ingress.yaml     # deletes the ALB + target groups (wait ~60s)
kubectl delete -f apps.yaml
eksctl delete cluster -f cluster.yaml   # deletes nodes, VPC, NAT gateway
# Manually remove: Route 53 records, ACM cert (if unused), the SSM S3 bucket
```

> Delete the **Ingress before uninstalling the controller/cluster** — otherwise the ALB, listeners, and target groups are orphaned and keep billing you.

---

*You now understand the full chain — Route 53 → ALB listeners & rules → target groups → pod IPs via the VPC CNI — plus internal VPC connectivity and safe node management with Ansible. Happy shipping!* 🚀
