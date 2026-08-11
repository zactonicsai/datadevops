# Deploying Karpenter on EKS with Terraform — Including On/Off-Hours Pod & Node Scheduling

**Companion to:** *Safely Turning EKS Nodes and Pods Off and On with Karpenter*
**Last verified:** July 2026 · Terraform ≥ 1.7 · AWS provider ~> 6.0 · `terraform-aws-modules/eks` **~> 21.0** · Karpenter **v1.13.x** · EKS Pod Identity

---

## Table of Contents

1. [Background: what Terraform changes (and one big gotcha)](#1-background)
2. [Step 0 — Project layout, versions, providers](#step-0)
3. [Step 1 — VPC and EKS cluster (with the always-on baseline)](#step-1)
4. [Step 2 — Karpenter's AWS resources (IAM, Pod Identity, SQS) via the submodule](#step-2)
5. [Step 3 — The Karpenter controller pod (Helm release)](#step-3)
6. [Step 4 — EC2NodeClass + NodePool with schedule-aware disruption budgets](#step-4)
7. [Step 5 — The on/off-hours scheduler (RBAC, scripts, CronJobs) in Terraform](#step-5)
8. [Step 6 — Apply order, verification, and day-2 commands](#step-6)
9. [Gotchas, destroy order, and best practices](#gotchas)
10. [Pros and cons: Terraform-managed vs GitOps-managed Kubernetes objects](#pros-cons)

---

<a name="1-background"></a>
## 1. Background: what Terraform changes (and one big gotcha)

In the previous tutorial we built everything imperatively (`eksctl`, `helm`, `kubectl apply`). Terraform replaces all of that with **declarative infrastructure-as-code**: one repository describes the VPC, the cluster, Karpenter's IAM plumbing, the controller pod, the NodePools, *and* the on/off-hours CronJobs. `terraform apply` converges reality to the code; `terraform plan` shows any drift.

The stack has **four layers**, and Terraform touches all of them:

```
Layer 4  Kubernetes objects: NodePool, EC2NodeClass, CronJobs, RBAC   (kubectl/kubernetes providers)
Layer 3  Karpenter controller pod                                     (helm provider)
Layer 2  Karpenter's AWS dependencies: IAM roles, Pod Identity, SQS   (eks//modules/karpenter)
Layer 1  VPC + EKS cluster + always-on baseline node group            (vpc + eks modules)
```

**The one big gotcha before we start:** Layers 3–4 talk to the Kubernetes API of a cluster that Layer 1 *creates in the same configuration*. Terraform providers are configured before resources exist, so the Kubernetes/Helm providers must authenticate **lazily** via an `exec` block (calling `aws eks get-token` at apply time, never a cached token). This works well, but it means:

- The very first apply must happen in order — we wire `depends_on` so a plain `terraform apply` works end-to-end, and note where a targeted apply helps if your organization's policies interfere.
- `terraform destroy` needs care (Kubernetes finalizers vs. a disappearing cluster) — covered in the [gotchas](#gotchas) section.

We use the community-standard modules (`terraform-aws-modules/*`) because in v21 the **Karpenter submodule creates everything Karpenter needs on the AWS side in ~10 lines**: controller IAM role, **Pod Identity association** (the current default — IRSA support was removed from the submodule in v21), node IAM role, EKS **access entry** so nodes can join, and the **SQS queue + EventBridge rules** for Spot-interruption handling.

---

<a name="step-0"></a>
## Step 0 — Project layout, versions, providers

```
karpenter-onoff/
├── versions.tf        # terraform + provider version pins
├── providers.tf       # aws, helm, kubernetes, kubectl provider config
├── variables.tf       # region, cluster name, schedules, timezone
├── vpc.tf             # Layer 1a
├── eks.tf             # Layer 1b
├── karpenter.tf       # Layers 2 + 3
├── karpenter-crds.tf  # Layer 4a: EC2NodeClass, NodePool
├── scheduler.tf       # Layer 4b: on/off-hours RBAC + CronJobs
└── outputs.tf
```

**`versions.tf`** — pin everything; unpinned provider majors are how Friday deploys break:

```hcl
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    kubectl = {
      source  = "alekc/kubectl"      # maintained fork; applies raw YAML manifests (for CRD-based objects)
      version = "~> 2.1"
    }
  }
}
```

> **Why two Kubernetes-ish providers?** The `kubernetes` provider has typed resources for core objects (ServiceAccount, CronJob, ConfigMap…) with great plan diffs. But Karpenter's `NodePool`/`EC2NodeClass` are **CRDs**, and the typed provider can't plan resources whose CRDs don't exist yet at plan time. The `kubectl` provider applies raw YAML server-side and handles that ordering gracefully. Using both is the widely adopted pattern. (Alternative: `kubernetes_manifest` works but fails planning on not-yet-installed CRDs; `helm_release` with a wrapper chart also works.)

**`variables.tf`** — the on/off schedule is data, not code:

```hcl
variable "region"        { default = "us-east-1" }
variable "cluster_name"  { default = "demo-cluster" }
variable "k8s_version"   { default = "1.33" }
variable "karpenter_chart_version" { default = "1.13.0" }

# ---- On/off-hours policy (cron format, 5 fields) ----
variable "scale_down_schedule" {
  description = "When to begin the ordered shutdown (Mon-Fri 20:00)"
  default     = "0 20 * * 1-5"
}
variable "scale_up_schedule" {
  description = "When to begin the ordered startup (Mon-Fri 07:00)"
  default     = "0 7 * * 1-5"
}
variable "schedule_timezone" {
  description = "IANA timezone for both CronJobs and NodePool budgets"
  default     = "America/New_York"
}
variable "offhours_duration" {
  description = "Length of the off-hours window, for the NodePool 100% budget"
  default     = "11h"
}
```

**`providers.tf`** — the lazy-auth pattern:

```hcl
provider "aws" {
  region = var.region
}

# Lazily authenticate to the cluster this same config creates.
# exec > token data source: a token fetched at plan time can expire mid-apply.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
```

---

<a name="step-1"></a>
## Step 1 — VPC and EKS cluster (with the always-on baseline)

**`vpc.tf`** — three AZs, private subnets for nodes. The **`karpenter.sh/discovery` tag on the private subnets** is how our EC2NodeClass will find them later:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]
  public_subnets  = ["10.0.96.0/22", "10.0.100.0/22", "10.0.104.0/22"]

  enable_nat_gateway = true
  single_nat_gateway = true          # cheap for demo; one per AZ in production

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name   # <-- Karpenter subnet discovery
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
```

**`eks.tf`** — the cluster plus the small **always-on baseline node group**. Everything from the previous tutorial's design carries over: the baseline hosts the Karpenter controller, CoreDNS, and — critically for on/off hours — **the CronJobs that must be alive at 07:00 to wake everything else up.** Karpenter must never manage its own nodes.

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.k8s_version

  # Let the identity running Terraform administer the cluster (needed for Layers 3-4)
  enable_cluster_creator_admin_permissions = true
  endpoint_public_access                   = true   # set false + use a bastion/VPN for private clusters

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }   # required for Pod Identity auth
    aws-ebs-csi-driver     = {}                          # PVs must outlive nodes (stateful tiers!)
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system_baseline = {
      instance_types = ["m6i.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels = {
        role = "system-baseline"       # CronJobs nodeSelector targets this
      }
      # Optional hardening: taint the baseline so ONLY tolerating system pods land here.
      # Add matching tolerations to Karpenter (Step 3) and the scheduler CronJobs (Step 5)
      # if you enable it:
      # taints = { critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" } }
    }
  }

  # Karpenter discovers the node security group by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = { Environment = "demo", Terraform = "true" }
}
```

Notes worth internalizing:

- **`eks-pod-identity-agent` with `before_compute = true`** — the agent DaemonSet must exist before Karpenter's pod starts, or the controller boots with no AWS credentials and crash-loops.
- **`enable_cluster_creator_admin_permissions = true`** creates an EKS **access entry** mapping your Terraform identity to cluster-admin. Without it, Layers 3–4 fail with `Unauthorized`. In v21, access entries fully replace the old `aws-auth` ConfigMap workflow.
- **The baseline node group is Terraform-managed and Karpenter-invisible** (it's a plain managed node group, not a NodePool). During off-hours it keeps running — that's your ~2 × m6i.large floor cost, and it's what makes the whole scheme self-hosting.

---

<a name="step-2"></a>
## Step 2 — Karpenter's AWS resources via the submodule

**`karpenter.tf` (part 1).** In module v21, this one block replaces the entire CloudFormation stack from the imperative tutorial:

```hcl
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # v21 defaults to EKS Pod Identity (IRSA support was removed from this submodule).
  # It creates: controller IAM role + scoped policy, the Pod Identity association
  # for kube-system/karpenter, the node IAM role, an ACCESS ENTRY so those nodes
  # can join the cluster, and the SQS interruption queue + EventBridge rules.
  namespace = "kube-system"

  # Nodes need SSM for AL2023 bootstrap/session access
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = { Environment = "demo", Terraform = "true" }
}
```

What you get (visible in `terraform plan`, ~15 resources):

| Created resource | Role in the system |
|---|---|
| `aws_iam_role` (controller) + scoped policy | Lets the Karpenter pod call EC2 `RunInstances`/`TerminateInstances`/`Describe*`, pass the node role, read SQS |
| `aws_eks_pod_identity_association` | Binds that role to ServiceAccount `kube-system/karpenter` — no OIDC, no annotations |
| `aws_iam_role` (node) + instance-profile permissions | The role every Karpenter-launched EC2 instance assumes |
| `aws_eks_access_entry` | Authorizes those nodes to join the cluster (replaces aws-auth edits) |
| `aws_sqs_queue` + `aws_cloudwatch_event_rule`s | Spot interruptions / rebalance / health events → queue → Karpenter drains **gracefully**. (EventBridge in its *correct* role: informing Kubernetes-native draining, never terminating nodes itself.) |

---

<a name="step-3"></a>
## Step 3 — The Karpenter controller pod (Helm release)

**`karpenter.tf` (part 2).** The controller itself, wired to the submodule's outputs:

```hcl
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  wait       = true

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      name = module.karpenter.service_account   # must match the Pod Identity association
    }
    replicas = 2
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
    # Pin the controller to the always-on baseline — never to Karpenter's own nodes
    nodeSelector = { role = "system-baseline" }
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "DoNotSchedule"
      labelSelector     = { matchLabels = { "app.kubernetes.io/name" = "karpenter" } }
    }]
  })]

  # Ensure cluster, node group, Pod Identity assoc., and queue all exist first
  depends_on = [
    module.eks,
    module.karpenter,
  ]
}
```

Design choices explained:

- **`replicas = 2` + a hostname topology spread** — the two controller pods land on *different* baseline nodes, so one node failing at 06:59 doesn't take down the component responsible for the 07:00 wake-up.
- **`nodeSelector` on the baseline label** — the belt to go with the "min 2 baseline nodes" suspenders. If you enabled the baseline taint in Step 1, also add the matching `tolerations` here.
- **`wait = true`** — the apply blocks until the controller is Ready, which makes the `depends_on` chain into Step 4's CRDs actually meaningful (the chart installs the NodePool/EC2NodeClass CRDs).

---

<a name="step-4"></a>
## Step 4 — EC2NodeClass + NodePool with schedule-aware disruption budgets

**`karpenter-crds.tf`.** Same objects as the imperative tutorial, now templated by Terraform — note how the **NodePool's off-hours budget reuses the same `var.scale_down_schedule`** as the CronJobs, so the node policy and the pod schedule can never drift apart. That single-source-of-truth trick is one of the best reasons to do this in Terraform.

```hcl
resource "kubectl_manifest" "ec2nodeclass_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      role = module.karpenter.node_iam_role_name
      amiSelectorTerms = [{ alias = "al2023@latest" }]   # pin al2023@vYYYYMMDD in prod
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = { volumeSize = "50Gi", volumeType = "gp3", encrypted = true }
      }]
    }
  })
  depends_on = [helm_release.karpenter]   # CRDs must exist
}

resource "kubectl_manifest" "nodepool_apps" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "apps" }
    spec = {
      template = {
        metadata = { labels = { pool = "apps" } }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            { key = "kubernetes.io/arch",                      operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type",              operator = "In", values = ["on-demand"] },
            { key = "karpenter.k8s.aws/instance-category",     operator = "In", values = ["c", "m", "r"] },
            { key = "karpenter.k8s.aws/instance-generation",   operator = "Gt", values = ["4"] },
          ]
          expireAfter            = "720h"
          terminationGracePeriod = "30m"
        }
      }
      limits = { cpu = "200", memory = "800Gi" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "2m"
        budgets = [
          # Daytime default: gentle
          { nodes = "10%" },
          # Business hours: block repacking-driven disruption entirely
          {
            nodes    = "0"
            reasons  = ["Underutilized"]
            schedule = var.scale_up_schedule       # 07:00 Mon-Fri — same var as the CronJob!
            duration = "13h"
          },
          # Off-hours: tear down as fast as PDBs allow
          {
            nodes    = "100%"
            schedule = var.scale_down_schedule     # 20:00 Mon-Fri — same var as the CronJob!
            duration = var.offhours_duration
          },
        ]
      }
    }
  })
  depends_on = [kubectl_manifest.ec2nodeclass_default]
}
```

> **Timezone caveat (worth 5 minutes of reading now vs. a 3 AM page later):** NodePool budget `schedule` fields are evaluated in **UTC** by the Karpenter controller, while our CronJobs use the `timeZone` field. If your `schedule_timezone` isn't UTC, convert the budget crons to UTC equivalents (e.g., 20:00 America/New_York = `0 0/1 * * *`-style UTC offsets that shift with DST). Pragmatic options: run everything in UTC, or accept ±1h skew on the *budget* windows (harmless — the budgets only need to roughly bracket the CronJobs), or generate the UTC cron with a `locals` block. The CronJobs — the things that must be exact — handle timezones natively.

---

<a name="step-5"></a>
## Step 5 — The on/off-hours scheduler in Terraform

**`scheduler.tf`.** The dependency-ordered shutdown/startup machinery from the companion tutorial — namespace, least-privilege RBAC, the ordered scripts, and the two CronJobs — all as typed Terraform resources. Workloads opt in exactly as before: label the namespace `scale-schedule=office-hours` and label each Deployment/StatefulSet with `tier: "1|2|3"` (1 = database/base, highest = frontend).

```hcl
# ---------- Namespace + ServiceAccount ----------
resource "kubernetes_namespace_v1" "scale_scheduler" {
  metadata { name = "scale-scheduler" }
}

resource "kubernetes_service_account_v1" "scale_scheduler" {
  metadata {
    name      = "scale-scheduler"
    namespace = kubernetes_namespace_v1.scale_scheduler.metadata[0].name
  }
}

# ---------- Least-privilege RBAC: scale + read, nothing else ----------
resource "kubernetes_cluster_role_v1" "scale_scheduler" {
  metadata { name = "scale-scheduler" }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
    verbs      = ["get", "list", "watch", "patch", "update"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments/scale", "statefulsets/scale"]
    verbs      = ["get", "patch", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "scale_scheduler" {
  metadata { name = "scale-scheduler" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.scale_scheduler.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.scale_scheduler.metadata[0].name
    namespace = kubernetes_namespace_v1.scale_scheduler.metadata[0].name
  }
}

# ---------- The ordered scripts, from files, into a ConfigMap ----------
# Keep the shell in real .sh files next to the Terraform (syntax highlighting,
# shellcheck in CI, reviewable diffs) instead of heredocs inside HCL.
resource "kubernetes_config_map_v1" "scale_scripts" {
  metadata {
    name      = "scale-scripts"
    namespace = kubernetes_namespace_v1.scale_scheduler.metadata[0].name
  }
  data = {
    "scale-down.sh" = file("${path.module}/scripts/scale-down.sh")
    "scale-up.sh"   = file("${path.module}/scripts/scale-up.sh")
  }
}

# ---------- The two CronJobs ----------
locals {
  cron_jobs = {
    nightly-scale-down = {
      schedule = var.scale_down_schedule
      script   = "scale-down.sh"
      backoff  = 2
      deadline = 3600
    }
    morning-scale-up = {
      schedule = var.scale_up_schedule
      script   = "scale-up.sh"
      backoff  = 3      # startup failures retry harder
      deadline = 5400
    }
  }
}

resource "kubernetes_cron_job_v1" "scheduler" {
  for_each = local.cron_jobs

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.scale_scheduler.metadata[0].name
  }

  spec {
    schedule                      = each.value.schedule
    timezone                      = var.schedule_timezone
    concurrency_policy            = "Forbid"      # never two runs at once
    starting_deadline_seconds     = 3600          # missed trigger? run within 1h or skip
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5             # keep evidence for postmortems

    job_template {
      metadata {}
      spec {
        backoff_limit              = each.value.backoff
        active_deadline_seconds    = each.value.deadline

        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.scale_scheduler.metadata[0].name
            restart_policy       = "Never"
            node_selector        = { role = "system-baseline" }   # always-on nodes only

            container {
              name    = "runner"
              image   = "bitnami/kubectl:1.33"
              command = ["/bin/sh", "/scripts/${each.value.script}"]

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
              }
              resources {
                requests = { cpu = "100m", memory = "128Mi" }
                limits   = { cpu = "500m", memory = "256Mi" }
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.scale_scripts.metadata[0].name
                default_mode = "0755"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_cluster_role_binding_v1.scale_scheduler]
}
```

Create `scripts/scale-down.sh` and `scripts/scale-up.sh` with the exact ordered scripts from the companion tutorial (Section 4, Step 6c): shutdown walks tier labels **high → low**, gating until each tier's pods are fully gone; startup walks **low → high**, gating on `kubectl rollout status` (i.e., real readiness probes) before advancing; replica counts are saved to / restored from the `scale-scheduler/restore-replicas` annotation.

**How the pieces now interlock, end to end:**

```
Terraform var.scale_down_schedule ─┬─► CronJob "nightly-scale-down" (pods → 0, in tier order)
                                   └─► NodePool budget "100%" window (nodes may all drain)
                                              │
             pods gone → nodes empty → Karpenter consolidates → EC2 terminated
                                              │
Terraform var.scale_up_schedule  ──┬─► CronJob "morning-scale-up" (pods → N, tier order, health-gated)
                                   └─► (day budgets resume: 10%, no Underutilized disruption)
                                              │
             pods Pending → Karpenter launches right-sized nodes → tiers verified healthy
```

One `terraform.tfvars` edit changes the whole company's office hours:

```hcl
scale_down_schedule = "0 19 * * 1-5"   # close an hour earlier
scale_up_schedule   = "30 6 * * 1-5"   # open half an hour earlier
schedule_timezone   = "Europe/Berlin"
```

---

<a name="step-6"></a>
## Step 6 — Apply order, verification, day-2 commands

**First apply.** The `depends_on` chain (eks → karpenter module → helm → CRDs → scheduler) lets a single apply work:

```bash
terraform init
terraform plan -out=tfplan     # expect ~90-110 resources
terraform apply tfplan         # ~20-25 minutes, mostly EKS control plane
```

If your pipeline separates infra and Kubernetes stages (or a policy engine blocks mixed applies), the clean two-stage variant is:

```bash
terraform apply -target=module.vpc -target=module.eks -target=module.karpenter
terraform apply                # everything else
```

**Verify each layer:**

```bash
aws eks update-kubeconfig --name demo-cluster --region us-east-1

kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter   # 2/2 Running
kubectl get nodepools,ec2nodeclasses                                  # apps / default, Ready=True
kubectl get cronjobs -n scale-scheduler                               # both, with your schedules

# Full-cycle rehearsal, exactly like the imperative tutorial:
kubectl create job --from=cronjob/nightly-scale-down rehearsal-down -n scale-scheduler
kubectl logs -f job/rehearsal-down -n scale-scheduler
kubectl get nodeclaims -w                     # nodes drain & vanish ~2m after pods stop
kubectl create job --from=cronjob/morning-scale-up rehearsal-up -n scale-scheduler
kubectl logs -f job/rehearsal-up -n scale-scheduler
```

**Day-2 in Terraform terms:**

| Task | How |
|---|---|
| Change office hours | Edit the two schedule vars → `terraform apply` (updates CronJobs *and* NodePool budgets together) |
| Upgrade Karpenter | Bump `karpenter_chart_version` → apply (check the Karpenter upgrade guide for minor-version notes) |
| Roll a new AMI | Change `amiSelectorTerms` pin → apply → Karpenter *drift* replaces nodes gracefully, honoring budgets/PDBs |
| Pause the whole scheme | `suspend = true` on the CronJob specs (add it as a variable) → apply |
| Force everything up NOW | `kubectl create job --from=cronjob/morning-scale-up force-up -n scale-scheduler` (deliberately imperative — it's an emergency lever) |

---

<a name="gotchas"></a>
## Gotchas, destroy order, and best practices

**1. Never let Terraform own what Karpenter creates.** Karpenter launches EC2 instances outside Terraform state — that's correct and by design. Don't write `aws_instance` data sources/resources against them, don't run tag-based cleanup tools that sweep them, and don't be alarmed that `terraform plan` doesn't see them. State boundary: *Terraform owns the machine that owns the machines.*

**2. The IAM deadlock.** Applying IAM changes to the Karpenter controller role **while the controller is actively provisioning** can wedge things (in-flight EC2 calls with a role mid-modification have caused stuck NodeClaims). Prefer applying IAM-touching changes during a quiet window — you conveniently have one every night at 20:05.

**3. Destroy order matters.** A naive `terraform destroy` can hang: deleting the cluster while NodePools still have finalizers (and live nodes) leaves orphaned EC2 instances, or the kubectl provider can't reach a half-deleted cluster. Safe teardown:

```bash
# 1. Empty the cluster first (pods → 0 → Karpenter deletes its own nodes)
kubectl create job --from=cronjob/nightly-scale-down teardown -n scale-scheduler && sleep 300
# 2. Delete Karpenter CRs so finalizers run while the API server still exists
terraform destroy -target=kubectl_manifest.nodepool_apps -target=kubectl_manifest.ec2nodeclass_default
# 3. Now everything else
terraform destroy
```

**4. `kubernetes` provider + brand-new cluster in one apply** is officially "works, with caveats." The exec-auth pattern above is the reliable version of it. If you hit `connection refused` during plan on a fresh workspace, it's because a K8s data source ran before the cluster existed — avoid K8s *data sources* in this root module, or split state (see below).

**5. State layout for real teams.** This tutorial uses one root module for readability. At scale, split into two states: `infra` (VPC, EKS, Karpenter module + Helm) and `platform` (CRDs, scheduler), with the second reading the first's outputs via `terraform_remote_state`. Blast-radius isolation and faster plans.

**6. Everything from the companion tutorial still applies at the workload layer.** Terraform provisions the machinery; PDBs, preStop hooks, dependency-verifying readiness probes, resource requests, and EBS-backed state are still what make the on/off cycle *safe*. And the EventBridge lesson is unchanged — notice that the only EventBridge rules in this entire configuration are the ones the Karpenter submodule created to feed the interruption queue. Nothing anywhere calls `ec2:StopInstances`/`TerminateInstances` on a schedule, and nothing should.

---

<a name="pros-cons"></a>
## Pros and cons: Terraform-managed vs GitOps-managed Kubernetes objects

Layers 1–3 (AWS + controller) belong in Terraform, full stop. Layer 4 (NodePools, CronJobs) has two legitimate homes:

### Terraform-managed (this tutorial)

**Pros:** One tool, one state, one apply; cross-layer references are native (`module.karpenter.node_iam_role_name` flows straight into the EC2NodeClass; one variable drives CronJobs *and* budgets); drift detection via `plan`; no extra controllers to run.
**Cons:** Kubernetes changes require a Terraform pipeline run (slower loop than `git push` → sync); `kubectl` provider diffs on raw YAML are noisier than typed resources; app teams may not have Terraform access.

### GitOps-managed (Argo CD / Flux applying Layer 4 from a manifests repo)

**Pros:** Continuous reconciliation (a manually deleted CronJob comes back in seconds, not at the next apply); Kubernetes-native review flow for platform/app teams; clean separation — Terraform never touches the K8s API at all (kills gotchas 3 and 4 entirely).
**Cons:** Second tool + controllers to operate; the "one variable drives both CronJob and NodePool budget" trick needs re-plumbing (Helm values or Kustomize vars); bootstrap ordering (Terraform must still install Argo/Flux).

**Common production pattern:** Terraform for Layers 1–3 plus the Karpenter CRDs it's tightly coupled to; GitOps for the scheduler and everything app-shaped. Start with all-Terraform (this tutorial) — it's the smallest system that works — and split when team boundaries demand it.

---

### The one-paragraph summary

Four layers, one repository: the VPC/EKS modules build the cluster with a small always-on baseline node group; the `eks//modules/karpenter` submodule (v21) creates Karpenter's IAM roles, Pod Identity association, access entry, and Spot-interruption SQS queue in one block; a `helm_release` runs the two controller replicas pinned to the baseline; and `kubectl_manifest`/`kubernetes_*` resources declare the EC2NodeClass, a NodePool whose disruption budgets open to 100% during off-hours, and the two dependency-ordered CronJobs — with a single pair of Terraform variables (`scale_down_schedule`, `scale_up_schedule`) driving both the pod schedule and the node-disruption windows so they can never drift apart. Pods scale in tier order, Karpenter turns empty nodes into a $0 bill, and in the morning pending pods summon right-sized nodes back. Terraform owns the machine that owns the machines — and still, nothing ever terminates an EC2 instance behind Kubernetes' back.
