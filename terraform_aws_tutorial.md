# Terraform & AWS Infrastructure Tutorial

**Build Real Cloud Stuff with Code — Middle School Level**

Focus: Kafka, NiFi, Postgres (EC2 + RDS), Load Balancers, EKS Clusters, Multi-Tenant EKS.  
Learn every keyword, how to read `.tf` files, tags superpowers, and why multi-tenant saves money.

---

## 1. Terraform Basics

### The LEGO Instruction Sheet Idea

Think of AWS as a giant box of LEGO bricks (servers, networks, databases, load balancers).  
Terraform is the instruction sheet. You write what the finished model should look like.  
TF reads the sheet and snaps the bricks together exactly the same way every time.  
No clicking around the AWS console. Everything is code you can save in git and share.

### The Three-Step Dance: init → plan → apply

- **init**: First time only. Downloads the AWS rulebook (provider plugin) and connects to your state notebook.
- **plan**: TF compares your instruction sheet to what already exists. Shows exactly what it will create, change, or destroy. No surprises.
- **apply**: You type `yes`. TF builds or fixes everything on AWS and updates the notebook.

Bonus: `terraform destroy` safely removes everything when you are done testing.

### The State File (`terraform.tfstate`)

This is TF's private notebook. It stores the real IDs of every VPC, EC2, EKS cluster, and tag it created.  
Next time you run plan, TF uses this notebook to know what is already built and what needs fixing.  
**Never edit it by hand.** Never commit it to git (it can have secrets). Use a remote backend (S3 + DynamoDB) so your whole team shares one notebook.

### What "Declarative" Means

You declare the end result you want:  
"I want one VPC, six subnets, three Kafka brokers, one EKS cluster with two node groups."

You do **not** write step-by-step commands ("first make VPC, then add internet gateway...").  
TF figures out the correct order and the smallest changes needed. This is why it is safe and repeatable.

---

## 2. How to Read a `.tf` File

All Terraform files use one universal shape. Once you see the pattern, every file looks familiar.

```hcl
provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "main-vpc"
    Environment = "dev"
    Project     = "kafka-nifi"
  }
}
```

### Block Shape

`TYPE "LABEL" { arguments... }`

- **TYPE**: `provider`, `resource`, `data`, `variable`, `output`, `terraform`, `locals`, `module`
- **LABEL**: your own name for this block (must be unique inside the same TYPE)
- **arguments**: the settings inside the curly braces. Most are `key = value`

### The Secret Handshake: Referencing

To connect blocks, write `LABEL.ATTRIBUTE`.  
Example: `vpc_id = aws_vpc.main.id`

This says "use the ID that the main VPC block created". TF automatically knows the order.

### Comments

```hcl
# Single line comment — TF ignores everything after the #
/* Multi-line comment works too. Use it to explain tricky parts. */
```

### CIDR Network Numbers — Plain English

CIDR is just a short way to say "this group of IP addresses".

- `10.0.0.0/16` → Network starts at 10.0.0.0, first 16 bits fixed → 65,536 addresses (giant apartment building)
- `10.0.1.0/24` → Smaller group, 256 addresses (one floor)

You choose CIDR blocks when creating VPCs and subnets so they do not overlap and you have enough room.

---

## 3. Every Keyword, Argument & Tags Deep Dive

### The Five Main Block Types

1. **provider** — tells TF which cloud (AWS) and where (region). Also sets `default_tags`.
2. **resource** — the star. Creates or manages real AWS or Kubernetes things (EC2, VPC, EKS, ALB, `kubernetes_namespace`, etc.).
3. **data** — read-only lookup. Example: `data "aws_ami" "latest"` finds the newest Amazon Linux image ID.
4. **variable** — input you can change without editing main code. Good for environment (`dev`/`prod`) or secrets.
5. **output** — values TF prints after apply (cluster endpoint, VPC ID, load balancer DNS).

### Most Useful Arguments Inside Resources

- **ami** — Amazon Machine Image ID. The "disk image" that becomes your EC2 server's OS.
- **instance_type** — size of server (`t3.micro`, `m5.large`, etc.).
- **count** — integer. Make that many identical copies. Resources become `name[0]`, `name[1]`, `name[2]`. Use `count.index` inside the block.
- **for_each** — better than count when you want named copies. Give it a map or set.
- **lifecycle** — special nested block:
  - `create_before_destroy = true` → zero-downtime updates
  - `prevent_destroy = true` → block accidental delete
  - `ignore_changes = [tags]` → don't redeploy if only tags change
- **depends_on** — rare. Force TF to wait for another resource.
- **tags** — map of `key = value` labels (see deep dive below).
- **user_data** — script that runs on first boot of EC2.

### Tags — The Four Superpowers + Name + default_tags + locals + merge()

Tags are tiny labels you stick on every AWS resource. They cost nothing but give huge power.

1. **Organize & Find** — Filter resources in AWS console by tag.
2. **Cost Tracking** — AWS billing groups costs by tag.
3. **Automation** — Scripts can act only on resources with certain tags.
4. **Access Control** — IAM policies can target resources by tag.

**The special `Name` tag**: AWS console shows this as the friendly name in lists. Always set it.

**`default_tags` in provider**: Put it once in the `aws` provider block. TF adds those tags to **every** resource automatically.

**Best practice: `locals` + `merge()`**

```hcl
locals {
  common_tags = {
    Project     = "kafka-nifi-eks"
    Environment = var.environment
    Owner       = "zachary"
    ManagedBy   = "terraform"
  }
}

resource "aws_instance" "kafka" {
  count = 3
  # ... other args ...
  tags = merge(
    local.common_tags,
    {
      Name = "kafka-broker-${count.index + 1}"
      Role = "broker"
    }
  )
}
```

`merge()` combines the common map with extra tags. Clean and no repetition.

---

## 4. Real Infrastructure Examples

### VPC + Subnets + Security Groups (Foundation)

Every real setup starts with a VPC and subnets.  
Public subnets have internet. Private subnets use NAT.  
Security groups = firewalls.

```hcl
# VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = merge(local.common_tags, { Name = "main-vpc" })
}

# Two public subnets (one per AZ)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.common_tags, { Name = "public-${count.index}" })
}

# Security group for Kafka
resource "aws_security_group" "kafka" {
  name   = "kafka-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "kafka-sg" })
}
```

### Kafka — 3 Brokers Using `count`

Self-managed Kafka on EC2. Spread across AZs.

```hcl
resource "aws_instance" "kafka" {
  count         = 3
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.medium"
  subnet_id     = aws_subnet.private[count.index % 2].id
  vpc_security_group_ids = [aws_security_group.kafka.id]
  key_name      = var.key_name

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    # install java, kafka, set broker.id=${count.index}
    # start kafka
  EOF

  tags = merge(local.common_tags, {
    Name = "kafka-broker-${count.index + 1}"
    Role = "broker"
  })
}
```

### NiFi on EC2

Same pattern as Kafka but usually `count = 1` or `2` with larger instance type.

### Postgres — EC2 vs RDS Trade-off

**EC2 self-managed**: Full control. You handle backups, patches, replication. Cheaper for simple dev. You do all the work.

**RDS managed**: AWS handles backups, patching, multi-AZ HA, read replicas, storage auto-grow. Costs more but saves time and reduces errors. Use RDS for anything important.

```hcl
resource "aws_db_instance" "postgres" {
  identifier           = "main-postgres"
  engine               = "postgres"
  engine_version       = "15.4"
  instance_class       = "db.t3.medium"
  allocated_storage    = 100
  storage_encrypted    = true
  db_name              = "appdb"
  username             = var.db_user
  password             = var.db_password
  vpc_security_group_ids = [aws_security_group.postgres.id]
  db_subnet_group_name = aws_db_subnet_group.main.name
  multi_az             = true
  backup_retention_period = 7
  tags = merge(local.common_tags, { Name = "main-postgres" })
}
```

### Load Balancers (ALB)

ALB = Application Load Balancer. Routes traffic by path/host. Health checks keep only healthy targets in rotation.

```hcl
resource "aws_lb" "main" {
  name               = "main-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags = merge(local.common_tags, { Name = "main-alb" })
}

resource "aws_lb_target_group" "app" {
  name     = "app-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

### EKS Cluster with IAM Roles & Auto-Scaling Node Groups

EKS = Elastic Kubernetes Service. AWS runs the control plane. You manage node groups.

```hcl
# Cluster IAM Role
resource "aws_iam_role" "cluster" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The EKS cluster
resource "aws_eks_cluster" "main" {
  name     = "multi-tenant-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = merge(local.common_tags, { Name = "multi-tenant-cluster" })
}

# Node group with auto-scaling
resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "general-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 3
    max_size     = 8
    min_size     = 2
  }

  tags = merge(local.common_tags, { Name = "general-nodes" })
}
```

---

## 5. Multi-Tenant EKS — Deep Dive

### The Apartment Building Analogy

One big apartment building = **one EKS cluster**.  
Shared foundation, roof, elevators, utilities = control plane + node machines.  
Each family in their own apartment = **a namespace**.  
They have privacy inside their walls but share the building services.

You do **not** build 15 separate houses (15 clusters). You build one strong building and divide it safely.

### The Real-World Problem It Solves

Before multi-tenancy: 15 teams each wanted their own EKS cluster.  
Cost: ~$150–300/month per control plane × 15 = thousands extra.  
Plus 15 upgrades, 15 node groups, 15 VPCs, painful cross-cluster networking, and most clusters half empty.

One shared cluster = 1 control plane cost, easier patching, better packing, single monitoring place.  
The hard part is **isolation** — making sure Team A cannot see or break Team B's stuff. The four tools below solve it.

### Tool 1: Namespaces (the apartment number)

```hcl
resource "kubernetes_namespace" "team_a" {
  metadata {
    name = "team-a"
    labels = { team = "a", environment = "dev" }
  }
}
```

Pods in different namespaces cannot talk to each other by default.

### Tool 2: Resource Quotas + LimitRanges (no one hogs the building)

Quota limits total CPU/memory/pods a namespace can use.  
LimitRange sets defaults per container.

```hcl
resource "kubernetes_resource_quota" "team_a_quota" {
  metadata {
    name      = "team-a-quota"
    namespace = kubernetes_namespace.team_a.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "20"
      "requests.memory" = "40Gi"
      "limits.cpu"      = "40"
      "limits.memory"   = "80Gi"
      pods              = "100"
    }
  }
}

resource "kubernetes_limit_range" "team_a_limits" {
  metadata {
    name      = "team-a-limits"
    namespace = kubernetes_namespace.team_a.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
    }
  }
}
```

### Tool 3: RBAC — Who Can Do What Inside Their Apartment

Role + RoleBinding = permissions inside a namespace.

```hcl
resource "kubernetes_role" "team_a_dev" {
  metadata {
    name      = "team-a-dev"
    namespace = kubernetes_namespace.team_a.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "team_a_dev_bind" {
  metadata {
    name      = "team-a-dev-bind"
    namespace = kubernetes_namespace.team_a.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.team_a_dev.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "team-a-developers"
    api_group = "rbac.authorization.k8s.io"
  }
}
```

### Tool 4: Network Policies (locks on the doors)

Explicit firewall rules for pods between namespaces.

```hcl
resource "kubernetes_network_policy" "team_a_deny_all" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.team_a.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    # empty = deny all
  }
}
```

### Dedicated Worker Pools with Taints & Tolerations

Sometimes a team needs dedicated machines (no noisy neighbors).

```hcl
resource "aws_eks_node_group" "team_a" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "team-a-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = ["m5.large"]

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 1
  }

  taint {
    key    = "dedicated"
    value  = "team-a"
    effect = "NO_SCHEDULE"
  }

  tags = merge(local.common_tags, { Name = "team-a-nodes" })
}
```

In the pod/deployment, add:

```yaml
tolerations:
- key: "dedicated"
  operator: "Equal"
  value: "team-a"
  effect: "NoSchedule"
nodeSelector:
  dedicated: team-a
```

---

## 6. Putting It All Together

### Professional File Structure

```
my-infra/
├── main.tf          # providers, VPC, EKS, Kafka, NiFi, ALB
├── variables.tf     # all var "..." blocks
├── outputs.tf       # all output "..." blocks
├── terraform.tfvars # actual values (git-ignored)
├── backend.tf       # terraform { backend "s3" {...} }
├── versions.tf      # required_providers
└── modules/
    ├── vpc/
    ├── eks/
    └── kafka/
```

### The Backend Block (remote state)

```hcl
terraform {
  backend "s3" {
    bucket         = "my-company-tf-state"
    key            = "prod/kafka-nifi-eks/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

### Outputs Example

```hcl
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "kafka_broker_ips" {
  value = aws_instance.kafka[*].private_ip
}

output "alb_dns" {
  value = aws_lb.main.dns_name
}
```

### Full Command Workflow

1. `terraform init` — download providers, connect backend
2. `terraform plan` — preview every create/change/destroy
3. `terraform apply` — build it (type `yes`)
4. Edit a `.tf` file — change desired state
5. `terraform plan` — see the diff
6. `terraform apply` — make it match again
7. `terraform destroy` — tear everything down when done

### Recap

Write what you want in simple blocks. TF handles the how, remembers everything in state, and keeps AWS exactly in sync with your code.  
Use `count`/`for_each` for multiples, `locals` + `merge()` for clean tags, and the four multi-tenant tools (namespaces, quotas, RBAC, network policies) plus taints when you need isolation inside one EKS cluster.  
Version control your `.tf` files. Review plans before apply. You now have repeatable, auditable, team-friendly infrastructure.

---

## One-Page Glossary

| Term                  | Simple Meaning |
|-----------------------|----------------|
| **Block**             | A section in `.tf` like `resource "aws_vpc" "main" { ... }` |
| **Argument**          | A setting inside a block: `cidr_block = "10.0.0.0/16"` |
| **Attribute**         | A value you can read after creation: `aws_vpc.main.id` |
| **State file**        | TF's notebook (`terraform.tfstate`) that remembers every real resource |
| **Provider**          | Plugin that talks to AWS (or Kubernetes) |
| **Resource**          | Thing TF creates and manages (EC2, VPC, EKS, ALB, `kubernetes_namespace`...) |
| **Data source**       | Read-only lookup from AWS (latest AMI, existing VPC) |
| **Variable**          | Input you pass in (environment, passwords) |
| **Output**            | Value TF prints or returns after apply |
| **count / for_each**  | Make many copies of one resource block |
| **lifecycle**         | Special block: `create_before_destroy`, `prevent_destroy`, `ignore_changes` |
| **Taint / Toleration**| Node taint = "no pods unless they tolerate it". Pod toleration = "I can run on tainted nodes" |
| **Namespace**         | Virtual wall inside one Kubernetes cluster |
| **ResourceQuota**     | Hard limit on total CPU/memory/pods a namespace can use |
| **LimitRange**        | Default request/limit per container |
| **RBAC**              | Role-Based Access Control — who can do what inside a namespace |
| **NetworkPolicy**     | Firewall rules for pods between namespaces/ports |
| **ALB**               | Application Load Balancer — smart HTTP router with health checks |
| **CIDR**              | Short way to write IP ranges (`/16` = big, `/24` = small) |
| **Declarative**       | You say the end result. TF figures out the steps |
| **default_tags**      | Tags the provider adds to every resource automatically |
| **merge()**           | Function that combines two tag maps into one clean map |

---

**Tutorial complete.** Copy the examples, run `terraform init` / `plan` / `apply`, and you will have real AWS infrastructure you can understand and change safely.