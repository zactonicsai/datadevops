# Deploying Kafka UI on an Existing AWS EKS Cluster with Terraform (Modules)

A step‑by‑step tutorial, explained simply.

---

## Part 1: The 30‑Second Picture

Imagine Kafka is a giant post office that moves millions of letters (messages) around. **Kafka UI** is the window you look through to see what's happening inside — the mailboxes (topics), the mail carriers (consumers), and the letters themselves.

**EKS** is Amazon's service that runs Kubernetes for you. Kubernetes is like an apartment building manager that decides where your apps live and keeps them running.

**Terraform** is a recipe book. Instead of clicking around the AWS console, you write down what you want, and Terraform builds it — the same way every time.

**Modules** are like sub‑recipes. Instead of one giant recipe for "dinner," you have separate cards for "salad," "main course," and "dessert." Each card does one job and can be reused.

In this tutorial you already have:
- An EKS cluster ✅
- A node group (the worker machines) ✅
- A Kafka cluster somewhere (Amazon MSK, or Kafka running in the cluster) ✅

We will **only** add Kafka UI on top, using Terraform modules.

---

## Part 2: Step‑by‑Step Setup (Do This First)

### Step 0: What you need installed

| Tool | Why | Check it works |
|------|-----|----------------|
| Terraform ≥ 1.9 | Builds everything | `terraform version` |
| AWS CLI v2 | Talks to AWS | `aws sts get-caller-identity` |
| kubectl | Talks to Kubernetes | `kubectl version --client` |

Your AWS user/role must be allowed to read the EKS cluster **and** be mapped inside the cluster (via EKS Access Entries or the `aws-auth` ConfigMap). If `kubectl get nodes` already works for you, you're good.

### Step 1: Create the folder structure

```
kafka-ui-terraform/
├── main.tf            # The "menu" — calls each module
├── providers.tf       # How Terraform logs into AWS and Kubernetes
├── variables.tf       # Inputs you can change
├── outputs.tf         # Useful info printed at the end
├── terraform.tfvars   # Your actual values
└── modules/
    ├── eks-lookup/    # Finds your existing cluster
    ├── namespace/     # Makes a "room" for Kafka UI
    └── kafka-ui/      # Installs Kafka UI with Helm
```

Think of it like this:
- **eks-lookup** = "Where is the building?"
- **namespace** = "Which room do we get?"
- **kafka-ui** = "Move the furniture in."

### Step 2: Root files

**`providers.tf`**

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  # Best practice: store state remotely so teammates share it.
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "kafka-ui/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region
}

# Kubernetes and Helm providers log in using a short-lived token
# from AWS, so no passwords are stored on disk.
provider "kubernetes" {
  host                   = module.eks_lookup.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_lookup.cluster_ca)
  token                  = module.eks_lookup.cluster_token
}

provider "helm" {
  kubernetes = {
    host                   = module.eks_lookup.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_lookup.cluster_ca)
    token                  = module.eks_lookup.cluster_token
  }
}
```

**`variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region where the EKS cluster lives"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EXISTING EKS cluster"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Kafka UI"
  type        = string
  default     = "kafka-ui"
}

variable "kafka_bootstrap_servers" {
  description = "Kafka broker address(es), e.g. b-1.mycluster.abc.kafka.us-east-1.amazonaws.com:9092"
  type        = string
}

variable "kafka_cluster_display_name" {
  description = "Friendly name shown in the Kafka UI screen"
  type        = string
  default     = "my-kafka"
}

variable "kafka_ui_chart_version" {
  description = "Helm chart version for Kafka UI (check releases for latest)"
  type        = string
  default     = "1.5.0"
}

variable "node_group_label" {
  description = "Node label to pin Kafka UI to a node group (empty = any node)"
  type        = map(string)
  default     = {}
}
```

**`main.tf`**

```hcl
module "eks_lookup" {
  source       = "./modules/eks-lookup"
  cluster_name = var.cluster_name
}

module "namespace" {
  source = "./modules/namespace"
  name   = var.namespace
}

module "kafka_ui" {
  source = "./modules/kafka-ui"

  namespace                  = module.namespace.name
  chart_version              = var.kafka_ui_chart_version
  kafka_bootstrap_servers    = var.kafka_bootstrap_servers
  kafka_cluster_display_name = var.kafka_cluster_display_name
  node_selector              = var.node_group_label
}
```

**`outputs.tf`**

```hcl
output "cluster_endpoint" {
  value = module.eks_lookup.cluster_endpoint
}

output "kafka_ui_namespace" {
  value = module.namespace.name
}

output "port_forward_command" {
  description = "Run this, then open http://localhost:8080"
  value       = "kubectl -n ${module.namespace.name} port-forward svc/${module.kafka_ui.service_name} 8080:80"
}
```

**`terraform.tfvars`** (your values)

```hcl
aws_region              = "us-east-1"
cluster_name            = "my-existing-eks"
kafka_bootstrap_servers = "b-1.mycluster.abc.kafka.us-east-1.amazonaws.com:9092"
kafka_cluster_display_name = "prod-msk"

# Optional: pin to your node group.
# node_group_label = { "eks.amazonaws.com/nodegroup" = "my-node-group" }
```

### Step 3: Module `modules/eks-lookup`

This module doesn't create anything. It just **asks AWS** about your existing cluster and hands back the address, certificate, and a login token.

**`modules/eks-lookup/variables.tf`**

```hcl
variable "cluster_name" {
  type = string
}
```

**`modules/eks-lookup/main.tf`**

```hcl
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}
```

**`modules/eks-lookup/outputs.tf`**

```hcl
output "cluster_endpoint" {
  value = data.aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  value = data.aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_token" {
  value     = data.aws_eks_cluster_auth.this.token
  sensitive = true
}

output "cluster_version" {
  value = data.aws_eks_cluster.this.version
}
```

### Step 4: Module `modules/namespace`

A namespace is a labeled room. Everything for Kafka UI lives here so it doesn't mix with other apps.

**`modules/namespace/variables.tf`**

```hcl
variable "name" {
  type = string
}
```

**`modules/namespace/main.tf`**

```hcl
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}
```

**`modules/namespace/outputs.tf`**

```hcl
output "name" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}
```

### Step 5: Module `modules/kafka-ui`

This is the main course. It uses **Helm** — a package manager for Kubernetes (like an app store) — to install the official Kafka UI chart.

**`modules/kafka-ui/variables.tf`**

```hcl
variable "namespace" {
  type = string
}

variable "chart_version" {
  type = string
}

variable "kafka_bootstrap_servers" {
  type = string
}

variable "kafka_cluster_display_name" {
  type = string
}

variable "node_selector" {
  type    = map(string)
  default = {}
}

variable "replicas" {
  type    = number
  default = 1
}
```

**`modules/kafka-ui/main.tf`**

```hcl
resource "helm_release" "kafka_ui" {
  name       = "kafka-ui"
  namespace  = var.namespace
  chart      = "oci://ghcr.io/kafbat/helm-charts/kafka-ui"
  version    = var.chart_version

  wait    = true
  timeout = 300

  values = [
    yamlencode({
      replicaCount = var.replicas

      # Tell Kafka UI where Kafka lives
      yamlApplicationConfig = {
        kafka = {
          clusters = [
            {
              name             = var.kafka_cluster_display_name
              bootstrapServers = var.kafka_bootstrap_servers
            }
          ]
        }
        auth = {
          type = "disabled"   # See Part 4 for enabling login
        }
        management = {
          health = { ldap = { enabled = false } }
        }
      }

      # Keep it inside the cluster; we'll reach it with port-forward.
      service = {
        type = "ClusterIP"
        port = 80
      }

      # Pin to a node group if a label was given
      nodeSelector = var.node_selector

      # Best practice: always set resource requests/limits
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { cpu = "500m", memory = "1Gi" }
      }

      # Best practice: don't run as root
      podSecurityContext = {
        runAsNonRoot = true
        runAsUser    = 1000
      }
    })
  ]
}
```

**`modules/kafka-ui/outputs.tf`**

```hcl
output "service_name" {
  value = helm_release.kafka_ui.name
}

output "release_status" {
  value = helm_release.kafka_ui.status
}
```

### Step 6: Run it

```bash
cd kafka-ui-terraform

terraform init          # Downloads providers and the chart
terraform validate      # Checks for typos
terraform plan          # Shows what WILL happen (nothing changes yet)
terraform apply         # Actually builds it (type "yes")
```

### Step 7: Open Kafka UI

```bash
# Point kubectl at your cluster (if not already)
aws eks update-kubeconfig --region us-east-1 --name my-existing-eks

# Check the pod is running
kubectl -n kafka-ui get pods

# Open a tunnel from your laptop to the pod
kubectl -n kafka-ui port-forward svc/kafka-ui 8080:80
```

Open **http://localhost:8080** in your browser. You should see your topics. 🎉

### Step 8: Tear it down (when done)

```bash
terraform destroy
```

Only Kafka UI and its namespace are removed. Your EKS cluster and Kafka are untouched, because Terraform never created them.

---

## Part 3: Background — What Just Happened?

### Why modules?

| Without modules | With modules |
|-----------------|--------------|
| One 200‑line file | Three small folders, each with one job |
| Hard to reuse | `module "kafka_ui"` can be copied to another cluster in seconds |
| Change one thing, risk breaking all | Change the `kafka-ui` module, nothing else moves |

**Rule of thumb:** a module should do one thing you could describe in one sentence.

### How Terraform talked to Kubernetes without a password

1. `aws_eks_cluster_auth` asks AWS for a **temporary token** (lasts ~15 min).
2. The Kubernetes and Helm providers use that token.
3. Nothing sensitive sits in your files.

### Why Helm instead of writing raw Kubernetes YAML?

The Kafka UI project publishes a Helm chart that already knows the right Deployment, Service, ConfigMap, and health checks. You just fill in the blanks. Writing it by hand = more code, more mistakes.

### The `yamlApplicationConfig` block

Kafka UI reads its settings from a YAML file. The Helm chart turns whatever you put in `yamlApplicationConfig` into that file. `bootstrapServers` is the "front door" address of your Kafka cluster.

---

## Part 4: Options, Pros & Cons

### Option A: How do people reach Kafka UI?

| Method | How | Pros | Cons |
|--------|-----|------|------|
| **Port‑forward** (what we did) | `kubectl port-forward` | Zero AWS cost, nothing exposed to the internet | Only works for people with kubectl access; one person at a time per tunnel |
| **LoadBalancer Service** | `service.type = "LoadBalancer"` | Simple, gets an AWS NLB with a public/private DNS name | Costs ~$16+/month; you must add auth or restrict security groups |
| **Ingress + AWS Load Balancer Controller** | `ingress.enabled = true` with ALB annotations | HTTPS with ACM certs, one ALB for many apps, can plug into Cognito/OIDC | Requires the AWS Load Balancer Controller to be installed first — more moving parts |

To switch to LoadBalancer, change one line in the module:

```hcl
service = {
  type = "LoadBalancer"
  port = 80
  annotations = {
    "service.beta.kubernetes.io/aws-load-balancer-type"     = "nlb"
    "service.beta.kubernetes.io/aws-load-balancer-internal" = "true"  # keep private
  }
}
```

### Option B: Login / authentication

| Type | When to use |
|------|-------------|
| `disabled` | Local testing only |
| `LOGIN_FORM` | Small teams; username/password set via env vars |
| `OAUTH2` (Cognito, Okta, Google) | Production; single sign‑on |

Example of a basic login form:

```hcl
auth = {
  type = "LOGIN_FORM"
}
spring = {
  security = {
    user = {
      name     = "admin"
      password = var.admin_password   # mark as sensitive = true
    }
  }
}
```

### Option C: Connecting to Amazon MSK with IAM (no passwords)

If your Kafka is MSK with IAM auth, add to the cluster config:

```hcl
{
  name             = var.kafka_cluster_display_name
  bootstrapServers = var.kafka_bootstrap_servers   # port 9098 for IAM
  properties = {
    "security.protocol"  = "SASL_SSL"
    "sasl.mechanism"     = "AWS_MSK_IAM"
    "sasl.jaas.config"   = "software.amazon.msk.auth.iam.IAMLoginModule required;"
    "sasl.client.callback.handler.class" = "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
  }
}
```

Then give the pod an IAM role with **EKS Pod Identity** (the modern replacement for IRSA) that allows `kafka-cluster:Connect`, `kafka-cluster:DescribeTopic`, etc. That would be a great fourth module: `modules/pod-identity`.

### Option D: Where to keep Terraform state

| Backend | Pros | Cons |
|---------|------|------|
| Local file (default) | Zero setup | Lost if laptop dies; teammates can't share |
| S3 with `use_lockfile = true` | Shared, versioned, locked | Need to create the bucket once |

---

## Part 5: Best Practices Checklist

- ✅ **Pin versions** — provider versions and `chart_version`. "Latest" today may break tomorrow.
- ✅ **Never hard‑code secrets** — use `sensitive = true` variables, AWS Secrets Manager, or environment variables.
- ✅ **Set resource requests/limits** — stops one app from hogging a node.
- ✅ **Use a dedicated namespace** — easy cleanup, easy permissions.
- ✅ **Run `terraform plan` before `apply`** — read the plan like a receipt before paying.
- ✅ **Use remote state** for anything beyond a personal experiment.
- ✅ **Keep the service private** (ClusterIP or internal LB) unless you have auth in front of it.
- ✅ **One module = one responsibility.**
- ✅ **Check the Kafka UI GitHub releases** for the current chart version before deploying.

---

## Part 6: Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `error: You must be logged in to the server (Unauthorized)` | Your IAM identity isn't mapped into the cluster | Add an EKS Access Entry for your role, or update `aws-auth` |
| Pod stuck in `Pending` | `nodeSelector` doesn't match any node, or not enough CPU/memory | `kubectl describe pod` → check Events |
| Kafka UI shows cluster "Offline" | Wrong `bootstrap_servers`, or security group blocks EKS → Kafka | Allow port 9092/9094/9098 from the node group's security group to MSK's security group |
| `helm_release` times out | Image pull slow or pod crash‑looping | `kubectl -n kafka-ui logs deploy/kafka-ui` |
| `chart not found` | Wrong `chart_version` | Check the kafbat/helm-charts releases page |

---

## Part 7: Quick Glossary

- **Broker** — one Kafka server. Several brokers = a cluster.
- **Topic** — a named mailbox that messages go into.
- **Consumer group** — a team of readers sharing the work of reading a topic.
- **Pod** — the smallest thing Kubernetes runs; usually one container.
- **Service** — a stable address inside the cluster that points at pods.
- **Helm chart** — a bundle of Kubernetes YAML with fill‑in‑the‑blank values.
- **Provider** — the Terraform plugin that knows how to talk to AWS, Kubernetes, or Helm.
- **Data source** — Terraform *reading* something that already exists (vs. a *resource*, which it creates).
