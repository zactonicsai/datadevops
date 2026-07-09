# EKS: Add a Node Group + Pods with Terraform (plus GitLab CI)

A minimal, working setup that adds a **managed node group** (plain EC2, vanilla EKS-optimized AMI, nothing extra installed) to an **existing EKS cluster**, then deploys a simple pod. Includes variables for subnets and other inputs, a GitLab pipeline, and a directory structure.

Use data sources to reference them instead of creating new ones. Replace the IAM section in `main.tf` with:

```hcl
# Look up existing role
data "aws_iam_role" "node" {
  name = "noderolettt"
}

# Look up existing customer-managed policy
data "aws_iam_policy" "my_policy" {
  name = "my policy"
}

# Attach your policy to the role
# (skip this if it's already attached)
resource "aws_iam_role_policy_attachment" "custom" {
  role       = data.aws_iam_role.node.name
  policy_arn = data.aws_iam_policy.my_policy.arn
}
```

Then point the node group at it:

```hcl
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = data.aws_iam_role.node.arn  # <-- changed
  subnet_ids      = var.subnet_ids
  # ...rest stays the same

  # Remove the old depends_on IAM attachments,
  # or point it at the new attachment if you kept it
}
```

Delete the `aws_iam_role` resource and the three `aws_iam_role_policy_attachment` blocks from the original example — otherwise Terraform will try to create duplicates.

Two things to verify on `noderolettt`:

1. **Trust policy** must allow `ec2.amazonaws.com` to assume it, or nodes can't launch.
2. **Required policies** — it still needs `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, and `AmazonEC2ContainerRegistryReadOnly` attached (either already on the role, or add attachment blocks like the one above). Your custom policy is in addition to those, not a replacement.

If you'd rather have Terraform fully manage the existing role instead of just referencing it, you'd use `terraform import` — but the data-source approach above is simpler and safer for shared roles.

## 1. Directory Structure

```
eks-nodegroup/
├── .gitlab-ci.yml          # GitLab pipeline
├── terraform/
│   ├── main.tf             # Node group + pod resources
│   ├── variables.tf        # All input variables
│   ├── outputs.tf          # Useful outputs
│   ├── providers.tf        # AWS + Kubernetes providers
│   ├── backend.tf          # Remote state (S3)
│   └── terraform.tfvars    # Your actual values (or use CI vars)
└── README.md
```

Keep everything Terraform in one folder — simple and easy for the pipeline to target with `-chdir`.

---

## 2. `providers.tf`

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

provider "aws" {
  region = var.region
}

# Look up the existing cluster so the k8s provider can authenticate
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
```

**What this does:**
- `data.aws_eks_cluster` pulls the endpoint and CA cert of your **existing** cluster — you don't recreate anything.
- `data.aws_eks_cluster_auth` generates a short-lived token so the `kubernetes` provider can deploy pods without a kubeconfig file.

---

## 3. `variables.tf`

```hcl
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs where worker nodes will run"
  type        = list(string)
}

variable "node_group_name" {
  description = "Name for the managed node group"
  type        = string
  default     = "simple-ec2-nodes"
}

variable "instance_types" {
  description = "EC2 instance types for the nodes"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "desired_size" {
  description = "Desired number of nodes"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 3
}

variable "disk_size" {
  description = "Root EBS volume size (GiB)"
  type        = number
  default     = 20
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
```

**What this does:** Everything environment-specific (subnets, cluster name, sizing) is a variable, so the same code works for dev/stage/prod by swapping tfvars.

---

## 4. `main.tf` — IAM Role + Node Group + Pod

```hcl
############################################
# IAM role the EC2 worker nodes will assume
############################################
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-${var.node_group_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

# The 3 policies every EKS worker node needs
resource "aws_iam_role_policy_attachment" "worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

############################################
# Managed node group (plain EC2, stock AMI)
############################################
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.instance_types
  capacity_type  = var.capacity_type
  disk_size      = var.disk_size
  ami_type       = "AL2023_x86_64_STANDARD"  # stock EKS-optimized AMI, nothing custom

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "nodegroup" = var.node_group_name
  }

  tags = var.tags

  # Make sure IAM is ready before nodes try to join
  depends_on = [
    aws_iam_role_policy_attachment.worker,
    aws_iam_role_policy_attachment.cni,
    aws_iam_role_policy_attachment.ecr,
  ]
}

############################################
# A simple pod (via Deployment) on the nodes
############################################
resource "kubernetes_deployment_v1" "hello" {
  metadata {
    name = "hello-nginx"
    labels = {
      app = "hello-nginx"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "hello-nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "hello-nginx"
        }
      }

      spec {
        # Pin pods to the new node group using its label
        node_selector = {
          "nodegroup" = var.node_group_name
        }

        container {
          name  = "nginx"
          image = "nginx:1.27"

          port {
            container_port = 80
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [aws_eks_node_group.this]
}
```

**What this does, step by step:**

1. **IAM role** — EC2 nodes must assume a role trusted by `ec2.amazonaws.com`.
2. **Three policy attachments** — the required trio:
   - `AmazonEKSWorkerNodePolicy`: lets the node register with the cluster.
   - `AmazonEKS_CNI_Policy`: lets the VPC CNI assign pod IPs.
   - `AmazonEC2ContainerRegistryReadOnly`: lets nodes pull container images.
3. **`aws_eks_node_group`** — a *managed* node group. AWS handles the launch template, ASG, and bootstrap. `ami_type = AL2023_x86_64_STANDARD` = a stock Amazon Linux 2023 EKS AMI — "simple EC2 with nothing in it."
4. **`labels`** — a Kubernetes node label so you can target these exact nodes.
5. **Deployment** — 2 nginx pods, pinned to the new nodes with `node_selector`. `depends_on` ensures nodes exist before pods are scheduled.

> **Prerequisite:** the subnets you pass must be the ones your cluster was configured with (or tagged for it), typically private subnets tagged `kubernetes.io/cluster/<cluster_name> = shared`.

---

## 5. `outputs.tf`

```hcl
output "node_group_arn" {
  value = aws_eks_node_group.this.arn
}

output "node_group_status" {
  value = aws_eks_node_group.this.status
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}
```

---

## 6. `backend.tf` — Remote State

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "eks/nodegroup/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

**Why:** the GitLab runner is ephemeral. State must live in S3 (with DynamoDB locking) or every pipeline run would start from scratch.

---

## 7. `terraform.tfvars` (example)

```hcl
region       = "us-east-1"
cluster_name = "my-existing-cluster"

subnet_ids = [
  "subnet-0abc1234def567890",
  "subnet-0fed9876cba543210",
]

node_group_name = "simple-ec2-nodes"
instance_types  = ["t3.medium"]
desired_size    = 2
min_size        = 1
max_size        = 3

tags = {
  Environment = "dev"
  ManagedBy   = "terraform"
}
```

---

## 8. GitLab Pipeline — `.gitlab-ci.yml`

```yaml
image:
  name: hashicorp/terraform:1.9
  entrypoint: [""]          # override so GitLab can run shell commands

variables:
  TF_DIR: terraform
  TF_IN_AUTOMATION: "true"

# AWS creds come from GitLab CI/CD variables:
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
# (Settings > CI/CD > Variables, masked + protected)

stages:
  - validate
  - plan
  - apply

before_script:
  - terraform -chdir=$TF_DIR init -input=false

validate:
  stage: validate
  script:
    - terraform -chdir=$TF_DIR fmt -check
    - terraform -chdir=$TF_DIR validate

plan:
  stage: plan
  script:
    - terraform -chdir=$TF_DIR plan -input=false -out=tfplan
  artifacts:
    paths:
      - $TF_DIR/tfplan
    expire_in: 1 day

apply:
  stage: apply
  script:
    - terraform -chdir=$TF_DIR apply -input=false tfplan
  dependencies:
    - plan
  when: manual              # human clicks "apply" after reviewing the plan
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

**Pipeline explained, stage by stage:**

| Stage | What happens | Why |
|---|---|---|
| `before_script` | `terraform init` pulls providers and connects to the S3 backend | Every job runs in a fresh container, so init runs each time |
| `validate` | `fmt -check` + `validate` | Fast fail on bad formatting or syntax before anything touches AWS |
| `plan` | Produces `tfplan` and saves it as an **artifact** | The apply stage runs *exactly* what was planned — no drift between plan and apply |
| `apply` | Applies the saved plan — **manual** and only on `main` | Safety gate: a person reviews the plan output in the UI, then clicks the play button |

**Flow in practice:**
1. Push a branch → `validate` + `plan` run automatically; review the plan in the job log via a merge request.
2. Merge to `main` → pipeline runs again; `apply` waits as a manual job.
3. Click **▶ apply** → node group is created (~2–3 min), then the nginx pods deploy onto it.

---

## 9. Verify After Apply

```bash
aws eks update-kubeconfig --name my-existing-cluster --region us-east-1

kubectl get nodes -l nodegroup=simple-ec2-nodes   # your new EC2 nodes
kubectl get pods -l app=hello-nginx -o wide       # pods running on those nodes
```

---

## Quick Recap

- **Node group** = IAM role (3 policies) + `aws_eks_node_group` with your `subnet_ids` variable and a stock AMI.
- **Pods** = `kubernetes_deployment_v1` pinned to the node group via label + `node_selector`.
- **Pipeline** = init → validate → plan (artifact) → manual apply on `main`.
- **State** = S3 backend so CI runs are stateless and safe.
