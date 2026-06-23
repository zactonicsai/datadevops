There are a few ways to pull SSM Parameter Store values into Terraform variables, depending on whether the parameter already exists or you're creating it.

**Reading existing parameters** (most common use case):

```hcl
data "aws_ssm_parameter" "db_password" {
  name = "/myapp/prod/db_password"
}

resource "aws_db_instance" "example" {
  password = data.aws_ssm_parameter.db_password.value
}
```

The `.value` attribute is automatically decrypted for `SecureString` parameters (no extra config needed). It's marked sensitive, so it won't print in plan/apply output.

**Creating parameters:**

```hcl
resource "aws_ssm_parameter" "db_password" {
  name  = "/myapp/prod/db_password"
  type  = "SecureString"
  value = var.db_password
}
```

**Fetching multiple parameters by path** (useful for loading a whole config tree):

```hcl
data "aws_ssm_parameters_by_path" "config" {
  path            = "/myapp/prod"
  recursive       = true
  with_decryption = true
}

# Build a map of name => value
locals {
  config = zipmap(
    data.aws_ssm_parameters_by_path.config.names,
    data.aws_ssm_parameters_by_path.config.values
  )
}

# Access: local.config["/myapp/prod/db_password"]
```

A few practical notes: avoid storing the parameter value back into a `.tfvars` file or output without `sensitive = true`, since it defeats the purpose. Also, data sources read at plan time, so the parameter must already exist in AWS before you reference it — if Terraform is creating it in the same apply, reference the resource (`aws_ssm_parameter.x.value`) rather than a data source to avoid a chicken-and-egg dependency.

Use the `aws_ami` data source with `most_recent = true` and a filter. For Amazon Linux 2023:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "example" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.micro"
}
```

For **Amazon Linux 2** instead, swap the name filter:

```hcl
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
```

For **ARM/Graviton**, change the architecture suffix (`arm64`) and add an architecture filter:

```hcl
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
```

A cleaner alternative for Amazon Linux specifically is to read the AMI ID straight from the public SSM parameter AWS publishes, which avoids filter-string fragility:

```hcl
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "example" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = "t3.micro"
}


variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a prefix for resource names and the SSM parameter path."
  type        = string
  default     = "myapp"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ami_architecture" {
  description = "CPU architecture for the AMI: x86_64 or arm64. arm64 selects Graviton."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.ami_architecture)
    error_message = "ami_architecture must be either x86_64 or arm64."
  }
}

variable "db_host" {
  description = "Database host (non-secret config)."
  type        = string
  default     = "db.internal"
}

variable "db_port" {
  description = "Database port (non-secret config)."
  type        = string
  default     = "5432"
}

variable "db_password" {
  description = "Database password (stored as a SecureString). Pass via TF_VAR_db_password or a tfvars file kept out of version control."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ─── VPC ────────────────────────────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = var.tags
}

# ─── EKS CLUSTER ────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Managed node groups
  eks_managed_node_groups = {
    # General-purpose nodes for Java servers
    java_servers = {
      name           = "java-server-ng"
      instance_types = [var.java_node_instance_type]

      min_size     = 3
      max_size     = 6
      desired_size = 3

      disk_size = 50

      labels = {
        role = "java-server"
      }

      taints = []

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      })
    }

    # Kafka broker nodes (memory + storage optimised)
    kafka_nodes = {
      name           = "kafka-ng"
      instance_types = [var.kafka_node_instance_type]

      min_size     = 3
      max_size     = 6
      desired_size = 3

      disk_size = 100

      labels = {
        role = "kafka"
      }

      taints = [
        {
          key    = "dedicated"
          value  = "kafka"
          effect = "NO_SCHEDULE"
        }
      ]

      tags = merge(var.tags, {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      })
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Cluster add-ons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  tags = var.tags
}

# ─── SECURITY GROUP: Java servers ↔ Kafka ───────────────────────────────────

resource "aws_security_group" "kafka_access" {
  name        = "${var.cluster_name}-kafka-access"
  description = "Allow Java server pods to reach Kafka brokers"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Kafka broker plaintext"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Kafka broker TLS"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "ZooKeeper (if used)"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-kafka-access" })
}

# ─── IAM: IRSA role for Java server pods ────────────────────────────────────

module "java_server_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name = "${var.cluster_name}-java-server-role"

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kafka-system:java-server-sa"]
    }
  }

  role_policy_arns = {
    msk_policy = aws_iam_policy.java_server_msk.arn
  }

  tags = var.tags
}

resource "aws_iam_policy" "java_server_msk" {
  name        = "${var.cluster_name}-java-server-msk"
  description = "Allow Java server pods to connect to MSK / self-managed Kafka"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers",
          "kafka:ListClusters",
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
        ]
        Resource = "*"
      }
    ]
  })

  tags = var.tags
}

# ─── Kubernetes + Helm providers (post-cluster) ──────────────────────────────

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# ─── Namespace ───────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "kafka_system" {
  metadata {
    name = "kafka-system"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

# ─── Strimzi Kafka Operator (Helm) ───────────────────────────────────────────

resource "helm_release" "strimzi" {
  name             = "strimzi"
  repository       = "https://strimzi.io/charts/"
  chart            = "strimzi-kafka-operator"
  version          = "0.40.0"
  namespace        = kubernetes_namespace.kafka_system.metadata[0].name
  create_namespace = false

  set {
    name  = "watchNamespaces"
    value = "{kafka-system}"
  }

  depends_on = [kubernetes_namespace.kafka_system]
}

```

Two things worth keeping in mind: pin `owners` to `["amazon"]` so a malicious public AMI can't match your filter, and be aware that `most_recent = true` means a new AMI release will show as a diff and trigger instance replacement on the next apply — if you don't want that churn, capture the ID once and hardcode it, or use `ignore_changes = [ami]` in a lifecycle block.

Here's a complete, working Terraform configuration that ties the pieces together: latest Amazon Linux AMI via SSM, Parameter Store for config and secrets, an EC2 instance that reads parameters at boot through its IAM role (no secrets in user_data or state), and the matching IAM setup.

I'll split it across the conventional files. You can also drop it all into a single `main.tf` if you prefer.

Done. Five files plus an example tfvars:

- **`versions.tf`** — Terraform ≥ 1.5 and AWS provider ~> 5.0.
- **`variables.tf`** — inputs with validation on architecture and `sensitive = true` on the password.
- **`main.tf`** — the core: AMI via public SSM parameter (switchable x86_64/arm64), three SSM parameters, an IAM role scoped to just this project's parameter path, instance profile, and the EC2 instance.
- **`outputs.tf`** — AMI ID, instance ID/IP, role ARN, parameter names.
- **`terraform.tfvars.example`** — sample values.

Key design choices worth noting:

The password never touches user_data or the launch config. The instance fetches it at boot via its IAM role, so it's not exposed in the EC2 console or instance metadata. It does still live in your Terraform state (any `aws_ssm_parameter` value does), so keep state in an encrypted backend with restricted access.

`ignore_changes = [ami]` prevents instance replacement when AWS publishes a new Amazon Linux release. Remove it if you'd rather roll forward automatically.

To run it: drop a real password in via `export TF_VAR_db_password="..."`, then `terraform init && terraform apply`.


