# Deploying Keycloak on AWS with Terraform

*A complete beginner-to-intermediate guide, including EC2 Launch Templates with user data*

---

## Table of Contents

1. [Background: What Are We Building?](#part-0-background)
2. [Part 1: Quick Start — Your First Keycloak Deployment](#part-1-quick-start)
3. [Part 2: The EC2 Launch Template Deep Dive](#part-2-launch-templates)
4. [Part 3: Deployment Options Compared (Pros & Cons)](#part-3-options-compared)
5. [Part 4: Production Hardening](#part-4-production)
6. [Part 5: Troubleshooting & Reference](#part-5-troubleshooting)

---

## Part 0: Background

### What is Keycloak?

Imagine you run a school. Every classroom door has its own lock, and every student carries 40 different keys. That's chaos.

Now imagine instead there's one **front desk**. Students show their ID once at the front desk, get a badge, and that badge opens every door they're allowed through.

**Keycloak is the front desk.** It's an open-source *Identity and Access Management* (IAM) server. Applications hand off the job of "who is this person and what are they allowed to do?" to Keycloak.

Keycloak is maintained by the **Cloud Native Computing Foundation (CNCF)** — it graduated to an incubating project in 2023 after Red Hat donated it. It is free and open source.

### Key Vocabulary

| Term | Plain-English Meaning |
|------|----------------------|
| **Realm** | A separate, isolated "world" of users. Like separate schools sharing one building. Your apps live in a realm. |
| **Client** | An application that trusts Keycloak (your web app, mobile app, API). |
| **User** | A person with a login. |
| **Role** | A label like `admin` or `student` that grants permissions. |
| **OIDC** | *OpenID Connect* — the modern standard protocol Keycloak speaks to prove identity. |
| **SAML** | An older XML-based identity protocol, still common in enterprises. |
| **Token** | The digital "badge" Keycloak issues after login. Usually a JWT. |
| **JWT** | *JSON Web Token* — a signed blob of JSON containing who you are. |

### What is Terraform?

Terraform is **Infrastructure as Code (IaC)**. Instead of clicking around the AWS web console (and forgetting what you clicked), you write a text file describing what you want:

```hcl
# "I want a server."
resource "aws_instance" "my_server" {
  ami           = "ami-12345"
  instance_type = "t3.micro"
}
```

Then Terraform makes it real. Benefits:

- **Repeatable** — build identical dev/staging/prod environments
- **Reviewable** — infrastructure changes go through code review
- **Reversible** — `terraform destroy` cleans everything up
- **Documented** — the code *is* the documentation

> **Version note:** Terraform is developed by HashiCorp (now part of IBM). In August 2023 HashiCorp changed Terraform's license from open-source MPL to the Business Source License (BUSL). This led to a community fork called **OpenTofu**, which is a drop-in replacement under the Linux Foundation. Everything in this guide works identically with OpenTofu — just replace `terraform` with `tofu` in commands.

### What is an EC2 Launch Template?

An **EC2 instance** is a virtual server in AWS. A **Launch Template** is a reusable recipe card that says: "when you make a server, use *this* image, *this* size, *this* network, and run *this* startup script."

**User data** is that startup script — a chunk of text (usually bash) that runs the very first time an instance boots. It's how a blank Linux box turns itself into a Keycloak server without you touching it.

### The Architecture We're Building

```
                    Internet
                       │
                       ▼
          ┌────────────────────────┐
          │  Application Load       │  ← Terminates HTTPS (ACM cert)
          │  Balancer (ALB)         │
          └────────────────────────┘
                       │ HTTP :8080
                       ▼
          ┌────────────────────────┐
          │  Auto Scaling Group     │  ← Uses our Launch Template
          │  ┌──────┐  ┌──────┐    │
          │  │ EC2  │  │ EC2  │    │  ← Keycloak, private subnets
          │  └──────┘  └──────┘    │
          └────────────────────────┘
                       │ :5432
                       ▼
          ┌────────────────────────┐
          │  RDS PostgreSQL         │  ← Persistent storage
          │  (Multi-AZ in prod)     │
          └────────────────────────┘
```

**Why this shape?**

- Keycloak stores everything in a database. Without an external DB, your users vanish on reboot.
- The ALB handles HTTPS so you don't manage certificates on each server.
- Private subnets mean the servers aren't directly reachable from the internet.

---

## Part 1: Quick Start

**Goal:** A working Keycloak dev instance on AWS in about 20 minutes.

**Warning:** This Part 1 setup is for *learning and development only*. It uses a single instance and a small database. Part 4 covers production hardening.

### Prerequisites

Install these first:

```bash
# Check Terraform (need 1.5+, ideally 1.9+)
terraform version

# Check AWS CLI (need v2)
aws --version

# Verify your AWS credentials work
aws sts get-caller-identity
```

If `get-caller-identity` fails, run `aws configure` and enter your access key, secret key, and region.

You'll also need:
- An AWS account with permissions to create VPCs, EC2, RDS, and IAM resources
- Roughly **$40–70/month** if you leave the Part 1 setup running (mostly RDS and NAT Gateway)

### Step 1: Create Your Project Folder

```bash
mkdir keycloak-aws && cd keycloak-aws
```

We'll create these files:

```
keycloak-aws/
├── versions.tf       # Terraform + provider versions
├── variables.tf      # Configurable inputs
├── network.tf        # VPC, subnets, gateways
├── security.tf       # Security groups
├── database.tf       # RDS PostgreSQL
├── iam.tf            # Instance role for SSM
├── compute.tf        # Launch Template + ASG
├── loadbalancer.tf   # ALB
├── outputs.tf        # What to print when done
├── terraform.tfvars  # Your actual values (git-ignored!)
└── user-data.sh.tftpl # The boot script template
```

### Step 2: Pin Your Versions

Create `versions.tf`:

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "keycloak"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
```

**Why pin versions?** The `~> 6.0` means "any 6.x version, but not 7.0". Major version bumps contain breaking changes. Pinning means your build today works the same next month.

**Why `default_tags`?** Every resource automatically gets these tags. Essential for cost tracking and knowing what belongs to what.

### Step 3: Define Variables

Create `variables.tf`:

```hcl
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "keycloak"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "keycloak_version" {
  description = "Keycloak version to install"
  type        = string
  default     = "26.4.0"
}

variable "instance_type" {
  description = "EC2 instance type for Keycloak"
  type        = string
  default     = "t3.medium"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "admin_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the admin console"
  type        = list(string)
  # CHANGE THIS to your office/home IP, e.g. ["203.0.113.45/32"]
  default     = ["0.0.0.0/0"]
}

variable "keycloak_hostname" {
  description = "Public DNS name for Keycloak (leave empty to use ALB DNS)"
  type        = string
  default     = ""
}
```

> **Important:** `admin_ingress_cidrs` defaults to the whole internet for convenience. **Change this immediately.** Find your IP with `curl -s https://checkip.amazonaws.com`.

### Step 4: Build the Network

Create `network.tf`:

```hcl
# Look up which availability zones exist in this region
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

# The VPC — your own private slice of AWS's network
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name}-vpc" }
}

# Internet Gateway — the door to the public internet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# Public subnets — for the load balancer and NAT gateway
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

# Private subnets — for Keycloak servers (no direct internet access in)
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

# Database subnets — most isolated tier
resource "aws_subnet" "database" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-db-${local.azs[count.index]}" }
}

# Elastic IP for the NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

# NAT Gateway — lets private instances reach OUT to the internet
# (to download Keycloak, get OS updates) without being reachable FROM it
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags       = { Name = "${local.name}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# Route table: public subnets → Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Route table: private subnets → NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
```

**What's `cidrsubnet` doing?** It slices your big network into smaller pieces. `cidrsubnet("10.0.0.0/16", 8, 0)` gives `10.0.0.0/24`. The `8` adds 8 bits to the prefix (16 + 8 = 24), and the last number picks which slice.

**Cost warning:** NAT Gateways cost about **$32/month plus data transfer**. For a pure dev sandbox you could put instances in public subnets and skip NAT entirely — see Part 3 for that trade-off.

### Step 5: Security Groups

Create `security.tf`:

```hcl
# ALB security group — accepts traffic from the internet
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  description = "Security group for Keycloak ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from allowed CIDRs"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_ingress_cidrs[0]
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from allowed CIDRs"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_ingress_cidrs[0]
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Keycloak instance security group
resource "aws_security_group" "keycloak" {
  name_prefix = "${local.name}-app-"
  description = "Security group for Keycloak instances"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Keycloak HTTP from ALB only"
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

# Cluster discovery between Keycloak nodes (JGroups)
resource "aws_vpc_security_group_ingress_rule" "keycloak_cluster" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "JGroups cluster traffic"
  from_port                    = 7800
  to_port                      = 7800
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.keycloak.id
}

resource "aws_vpc_security_group_egress_rule" "keycloak_all" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Database security group
resource "aws_security_group" "database" {
  name_prefix = "${local.name}-db-"
  description = "Security group for Keycloak RDS"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from Keycloak instances only"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.keycloak.id
}
```

**Note the pattern:** Notice there is no SSH (port 22) rule anywhere. We use **AWS Systems Manager Session Manager** instead — it gives you a shell without opening any inbound ports. This is current AWS best practice.

**Note the resource type:** Modern AWS provider versions prefer `aws_vpc_security_group_ingress_rule` (one rule per resource) over inline `ingress` blocks. This makes changes cleaner — modifying one rule doesn't recreate the whole group.

### Step 6: The Database

Create `database.tf`:

```hcl
# Generate a strong random password
resource "random_password" "db" {
  length  = 32
  special = true
  # Exclude characters that break connection strings
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Store it in Secrets Manager — never in plain text
resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "${local.name}-db-credentials-"
  description             = "Keycloak database credentials"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = aws_db_instance.keycloak.username
    password = random_password.db.result
    host     = aws_db_instance.keycloak.address
    port     = aws_db_instance.keycloak.port
    dbname   = aws_db_instance.keycloak.db_name
  })
}

resource "aws_db_subnet_group" "keycloak" {
  name_prefix = "${local.name}-db-"
  subnet_ids  = aws_subnet.database[*].id

  tags = { Name = "${local.name}-db-subnet-group" }
}

resource "aws_db_instance" "keycloak" {
  identifier_prefix = "${local.name}-"

  engine         = "postgres"
  engine_version = "16.4"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "keycloak"
  username = "keycloak"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.keycloak.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  # Dev-friendly settings — see Part 4 for production values
  multi_az                = var.environment == "prod"
  backup_retention_period = var.environment == "prod" ? 30 : 1
  deletion_protection     = var.environment == "prod"
  skip_final_snapshot     = var.environment != "prod"

  auto_minor_version_upgrade = true
  performance_insights_enabled = true

  tags = { Name = "${local.name}-db" }
}
```

**Why PostgreSQL?** Keycloak officially supports PostgreSQL, MySQL, MariaDB, Oracle, and MS SQL Server. PostgreSQL is the most commonly used and best-tested option, and it's what Keycloak's own docs use in examples.

**Why `random_password` + Secrets Manager?** Hardcoding passwords in `.tf` files means they end up in Git. Terraform generates a random one, stores it encrypted in AWS Secrets Manager, and the instance fetches it at boot using its IAM role. No human ever sees or types it.

**Caveat:** The generated password *does* appear in `terraform.tfstate`. Always store state in an encrypted S3 backend with restricted access — never commit state to Git.

### Step 7: IAM Role for the Instances

Create `iam.tf`:

```hcl
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keycloak" {
  name_prefix        = "${local.name}-instance-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Allows Session Manager shell access without SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows sending logs and metrics to CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Narrowly scoped: read ONLY the database secret
data "aws_iam_policy_document" "secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "secrets" {
  name_prefix = "read-db-secret-"
  role        = aws_iam_role.keycloak.id
  policy      = data.aws_iam_policy_document.secrets.json
}

resource "aws_iam_instance_profile" "keycloak" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.keycloak.name
}
```

**Least privilege:** Notice the secrets policy names one specific ARN, not `"*"`. If this instance is ever compromised, the attacker can read one secret — not every secret in your account.

### Step 8: The User Data Script

Create `user-data.sh.tftpl`:

```bash
#!/bin/bash
set -euxo pipefail

# Log everything to a file AND the console for debugging
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Keycloak bootstrap starting at $(date) ==="

# --- 1. System packages ---
dnf update -y
dnf install -y java-21-amazon-corretto-headless jq awscli tar gzip

# --- 2. Create a dedicated non-root user ---
useradd -r -m -U -d /opt/keycloak -s /sbin/nologin keycloak || true

# --- 3. Download and install Keycloak ---
KC_VERSION="${keycloak_version}"
cd /tmp
curl -fsSL -o keycloak.tar.gz \
  "https://github.com/keycloak/keycloak/releases/download/$${KC_VERSION}/keycloak-$${KC_VERSION}.tar.gz"

tar -xzf keycloak.tar.gz
cp -r keycloak-$${KC_VERSION}/* /opt/keycloak/
rm -rf keycloak.tar.gz keycloak-$${KC_VERSION}
chown -R keycloak:keycloak /opt/keycloak

# --- 4. Fetch database credentials from Secrets Manager ---
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString --output text)

DB_HOST=$(echo "$SECRET" | jq -r .host)
DB_PORT=$(echo "$SECRET" | jq -r .port)
DB_NAME=$(echo "$SECRET" | jq -r .dbname)
DB_USER=$(echo "$SECRET" | jq -r .username)
DB_PASS=$(echo "$SECRET" | jq -r .password)

# --- 5. Write Keycloak configuration ---
cat > /opt/keycloak/conf/keycloak.conf <<EOF
db=postgres
db-url=jdbc:postgresql://$${DB_HOST}:$${DB_PORT}/$${DB_NAME}
db-username=$${DB_USER}
db-password=$${DB_PASS}

hostname=${keycloak_hostname}
hostname-strict=false
proxy-headers=xforwarded

http-enabled=true
http-port=8080

health-enabled=true
metrics-enabled=true

cache=ispn
cache-stack=jdbc-ping
EOF

chmod 600 /opt/keycloak/conf/keycloak.conf
chown keycloak:keycloak /opt/keycloak/conf/keycloak.conf

# --- 6. Build the optimized Keycloak image ---
# This pre-compiles config for much faster startup
sudo -u keycloak /opt/keycloak/bin/kc.sh build

# --- 7. Create the systemd service ---
cat > /etc/systemd/system/keycloak.service <<'EOF'
[Unit]
Description=Keycloak Identity Provider
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=keycloak
Group=keycloak
Environment="JAVA_OPTS_APPEND=-XX:MaxRAMPercentage=70"
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNOFILE=102642

[Service]
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/keycloak/data /opt/keycloak/conf

[Install]
WantedBy=multi-user.target
EOF

# --- 8. Bootstrap the temporary admin account (first boot only) ---
BOOTSTRAP_MARKER=/opt/keycloak/.admin-bootstrapped
if [ ! -f "$BOOTSTRAP_MARKER" ]; then
  mkdir -p /etc/systemd/system/keycloak.service.d
  cat > /etc/systemd/system/keycloak.service.d/bootstrap.conf <<EOF
[Service]
Environment="KC_BOOTSTRAP_ADMIN_USERNAME=${admin_username}"
Environment="KC_BOOTSTRAP_ADMIN_PASSWORD=${admin_password}"
EOF
  chmod 600 /etc/systemd/system/keycloak.service.d/bootstrap.conf
  touch "$BOOTSTRAP_MARKER"
fi

# --- 9. Start it up ---
systemctl daemon-reload
systemctl enable --now keycloak

# --- 10. Wait for health check to pass ---
for i in {1..60}; do
  if curl -sf http://localhost:9000/health/ready > /dev/null 2>&1; then
    echo "=== Keycloak is READY at $(date) ==="
    exit 0
  fi
  echo "Waiting for Keycloak... attempt $i/60"
  sleep 10
done

echo "=== ERROR: Keycloak failed to become ready ==="
journalctl -u keycloak --no-pager -n 100
exit 1
```

**Critical syntax note:** This is a Terraform *template* file. Terraform will substitute `${keycloak_version}` with your variable. But bash *also* uses `${...}` syntax. To write a literal `${VAR}` for bash, you must escape it as `$${VAR}`. Getting this wrong is the #1 cause of user data failures.

**Why `set -euxo pipefail`?**
- `-e` — stop on any error
- `-u` — error on undefined variables
- `-x` — print each command (great for the log)
- `-o pipefail` — catch errors in pipelines

**Why the `exec > >(tee ...)` line?** It captures all output to `/var/log/user-data.log`. When something goes wrong, this file is your first stop.

**Version note:** Keycloak 26+ renamed the bootstrap admin variables. The old `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` are deprecated in favor of `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`. Also, Keycloak 26 requires **Java 21**.

### Step 9: Launch Template and Auto Scaling Group

Create `compute.tf`:

```hcl
# Always get the newest Amazon Linux 2023 AMI
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "random_password" "admin" {
  length  = 24
  special = false  # avoids shell-escaping headaches
}

resource "aws_secretsmanager_secret" "admin" {
  name_prefix             = "${local.name}-admin-credentials-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    username = "kcadmin"
    password = random_password.admin.result
  })
}

# ===== THE LAUNCH TEMPLATE =====
resource "aws_launch_template" "keycloak" {
  name_prefix   = "${local.name}-"
  description   = "Keycloak ${var.keycloak_version} on Amazon Linux 2023"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.keycloak.arn
  }

  vpc_security_group_ids = [aws_security_group.keycloak.id]

  # --- The user data script, base64 encoded ---
  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    keycloak_version  = var.keycloak_version
    db_secret_arn     = aws_secretsmanager_secret.db.arn
    aws_region        = var.aws_region
    keycloak_hostname = var.keycloak_hostname != "" ? var.keycloak_hostname : aws_lb.keycloak.dns_name
    admin_username    = "kcadmin"
    admin_password    = random_password.admin.result
  }))

  # --- Encrypted root volume ---
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      throughput            = 125
      iops                  = 3000
      encrypted             = true
      delete_on_termination = true
    }
  }

  # --- IMDSv2 required (blocks SSRF credential theft) ---
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name}-instance"
      Role = "keycloak"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = { Name = "${local.name}-volume" }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_db_instance.keycloak]
}

# ===== AUTO SCALING GROUP =====
resource "aws_autoscaling_group" "keycloak" {
  name_prefix         = "${local.name}-asg-"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.keycloak.arn]

  min_size         = 1
  max_size         = var.environment == "prod" ? 4 : 2
  desired_capacity = var.environment == "prod" ? 2 : 1

  health_check_type         = "ELB"
  health_check_grace_period = 600  # Keycloak takes a while to boot

  launch_template {
    id      = aws_launch_template.keycloak.id
    version = aws_launch_template.keycloak.latest_version
  }

  # Zero-downtime rolling replacement when the template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 600
    }
    triggers = ["launch_template"]
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

**What is `instance_refresh`?** When you change the launch template (say, a new Keycloak version), the ASG automatically replaces running instances one batch at a time, keeping at least 50% healthy. No downtime, no manual work.

**What is IMDSv2?** The Instance Metadata Service lets an instance ask "what IAM role do I have?" Version 1 answered any HTTP request. If your app had a server-side request forgery bug, an attacker could steal credentials. **IMDSv2 requires a session token first**, which blocks that attack. Setting `http_tokens = "required"` is now the AWS-recommended default.

### Step 10: Load Balancer

Create `loadbalancer.tf`:

```hcl
resource "aws_lb" "keycloak" {
  name_prefix        = "kc-"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true
  idle_timeout               = 300

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "keycloak" {
  name_prefix = "kc-"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/health/ready"
    port                = "9000"      # Keycloak's management port
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # Sticky sessions help during login flows
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 3600
    enabled         = true
  }

  deregistration_delay = 60

  lifecycle {
    create_before_destroy = true
  }
}

# HTTP listener
# NOTE: For production, replace this with an HTTPS listener (port 443)
# using an ACM certificate, and make port 80 redirect to 443.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}
```

**Health check on port 9000?** Keycloak 25+ moved health and metrics endpoints to a separate management port (9000) so you don't expose them publicly. The target group checks 9000 for health but forwards real traffic to 8080.

You'll also need to allow port 9000 from the ALB. Add to `security.tf`:

```hcl
resource "aws_vpc_security_group_ingress_rule" "keycloak_health" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Health checks from ALB"
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}
```

### Step 11: Outputs

Create `outputs.tf`:

```hcl
output "keycloak_url" {
  description = "URL to reach Keycloak"
  value       = "http://${aws_lb.keycloak.dns_name}"
}

output "admin_console_url" {
  description = "Keycloak admin console"
  value       = "http://${aws_lb.keycloak.dns_name}/admin"
}

output "admin_credentials_command" {
  description = "Run this to retrieve the admin password"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.admin.id} --region ${var.aws_region} --query SecretString --output text | jq ."
}

output "database_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.keycloak.address
}

output "launch_template_id" {
  value = aws_launch_template.keycloak.id
}
```

### Step 12: Your Values

Create `terraform.tfvars`:

```hcl
aws_region   = "us-east-1"
environment  = "dev"
project_name = "keycloak"

instance_type     = "t3.medium"
db_instance_class = "db.t4g.micro"
keycloak_version  = "26.4.0"

# IMPORTANT: replace with your actual IP!
# Find it with: curl -s https://checkip.amazonaws.com
admin_ingress_cidrs = ["203.0.113.45/32"]
```

And create `.gitignore`:

```gitignore
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
*.tfvars
!example.tfvars
crash.log
```

### Step 13: Deploy

```bash
# Download providers
terraform init

# Check syntax
terraform validate

# Preview what will be created
terraform plan

# Build it (takes 10-15 min, mostly RDS)
terraform apply
```

Type `yes` when prompted.

### Step 14: Verify

```bash
# Get your URL
terraform output keycloak_url

# Get admin credentials
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw admin_secret_id 2>/dev/null || echo "keycloak-dev-admin-credentials") \
  --query SecretString --output text | jq .
```

Open the URL in a browser. You should see the Keycloak welcome page. Click **Administration Console** and log in.

**If it doesn't work,** connect to the instance and check the logs:

```bash
# Find the instance
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=keycloak" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text

# Connect (no SSH key needed!)
aws ssm start-session --target i-0123456789abcdef0

# Once connected:
sudo cat /var/log/user-data.log
sudo journalctl -u keycloak -n 100 --no-pager
sudo systemctl status keycloak
```

### Step 15: Clean Up

```bash
terraform destroy
```

**Do this when you're done experimenting.** The NAT Gateway and RDS instance cost money whether you use them or not.

---

## Part 2: Launch Templates Deep Dive

Now that you've seen one work, let's understand Launch Templates properly.

### Launch Templates vs. Launch Configurations

| | Launch Template | Launch Configuration |
|---|---|---|
| Status | Current, recommended | **Deprecated** |
| Versioning | Yes — multiple versions, rollback | No — immutable, must recreate |
| Mixed instance types | Yes | No |
| Spot + On-Demand mix | Yes | No |
| T2/T3 unlimited mode | Yes | No |
| Placement groups | Yes | Limited |
| Metadata options (IMDSv2) | Yes | Limited |

**AWS stopped allowing new Launch Configurations for accounts that hadn't used them, and no longer adds features to them.** Always use Launch Templates. If you find a tutorial using `aws_launch_configuration`, it's outdated.

### Every Useful Launch Template Block

```hcl
resource "aws_launch_template" "example" {
  # --- Identity ---
  name_prefix = "my-app-"     # Terraform appends random suffix
  description = "Version 2.1 with new agent"

  # --- The base image ---
  image_id = data.aws_ssm_parameter.al2023.value

  # --- Size ---
  instance_type = "t3.medium"

  # --- SSH key (optional; prefer SSM instead) ---
  # key_name = "my-keypair"

  # --- Permissions ---
  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # --- Networking ---
  vpc_security_group_ids = [aws_security_group.app.id]

  # OR, for more control (can't use both):
  # network_interfaces {
  #   associate_public_ip_address = false
  #   security_groups             = [aws_security_group.app.id]
  #   delete_on_termination       = true
  # }

  # --- The boot script ---
  user_data = base64encode(templatefile("init.sh.tftpl", {
    app_version = var.app_version
  }))

  # --- Storage ---
  block_device_mappings {
    device_name = "/dev/xvda"          # root volume on AL2023
    ebs {
      volume_size           = 50
      volume_type           = "gp3"     # cheaper + faster than gp2
      iops                  = 3000      # gp3 baseline, free
      throughput            = 125       # MB/s, gp3 baseline, free
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  # Additional data volume
  block_device_mappings {
    device_name = "/dev/xvdf"
    ebs {
      volume_size = 100
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # --- Metadata security (IMPORTANT) ---
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 only
    http_put_response_hop_limit = 2            # 2 if containers need it
    instance_metadata_tags      = "enabled"
  }

  # --- Detailed CloudWatch metrics (1-min instead of 5-min) ---
  monitoring {
    enabled = true
  }

  # --- Spot instance config ---
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
      max_price                      = "0.05"
    }
  }

  # --- CPU customization ---
  credit_specification {
    cpu_credits = "unlimited"   # for T-series burstable
  }

  cpu_options {
    core_count       = 2
    threads_per_core = 1   # disable hyperthreading for licensing
  }

  # --- Placement ---
  placement {
    availability_zone = "us-east-1a"
    tenancy           = "default"
  }

  # --- Termination protection ---
  disable_api_termination = false
  disable_api_stop        = false
  instance_initiated_shutdown_behavior = "terminate"

  # --- Tagging launched resources ---
  tag_specifications {
    resource_type = "instance"
    tags = { Name = "my-app", Tier = "web" }
  }
  tag_specifications {
    resource_type = "volume"
    tags = { Name = "my-app-volume" }
  }
  tag_specifications {
    resource_type = "network-interface"
    tags = { Name = "my-app-eni" }
  }

  # --- Version management ---
  update_default_version = true

  # --- Tags on the template itself ---
  tags = { Purpose = "web-tier" }

  lifecycle {
    create_before_destroy = true
  }
}
```

### The Four Ways to Write User Data

#### Option A: Heredoc (simple, inline)

```hcl
user_data = base64encode(<<-EOF
  #!/bin/bash
  dnf install -y nginx
  systemctl enable --now nginx
EOF
)
```

**Pros:** Everything in one file, easy to see.
**Cons:** No syntax highlighting, gets unwieldy fast, mixing HCL and bash escaping is error-prone.
**Use when:** Under ~10 lines.

#### Option B: `templatefile()` (recommended)

```hcl
user_data = base64encode(templatefile("${path.module}/init.sh.tftpl", {
  app_version = var.app_version
  db_host     = aws_db_instance.main.address
}))
```

**Pros:** Real bash file with editor support, shellcheck works, variables injected cleanly.
**Cons:** Must remember `$$` escaping for bash variables.
**Use when:** Almost always. This is the standard approach.

#### Option C: `cloudinit_config` data source (multi-part)

```hcl
data "cloudinit_config" "app" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = yamlencode({
      package_update  = true
      package_upgrade = true
      packages        = ["jq", "awscli"]
      write_files = [{
        path        = "/etc/app/config.yml"
        permissions = "0644"
        content     = yamlencode({ env = var.environment })
      }]
    })
  }

  part {
    content_type = "text/x-shellscript"
    content      = templatefile("${path.module}/init.sh.tftpl", {
      app_version = var.app_version
    })
  }
}

# Then in the launch template:
user_data = data.cloudinit_config.app.rendered
```

**Pros:** `gzip = true` compresses, letting you exceed practical limits. Declarative cloud-config for package installs. Multiple scripts combined cleanly.
**Cons:** Extra provider dependency, more concepts to learn.
**Use when:** Your script is long, or you want declarative package/file management.

#### Option D: Bake an AMI (Packer) + minimal user data

```hcl
# AMI already has Keycloak installed
user_data = base64encode(<<-EOF
  #!/bin/bash
  aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db.arn} \
    --query SecretString --output text > /opt/app/db.json
  systemctl start keycloak
EOF
)
```

**Pros:** Boot time drops from 5+ minutes to under 60 seconds. Tested, immutable images. Faster autoscaling.
**Cons:** Requires a separate build pipeline (Packer). Extra step for every change.
**Use when:** Production, or anywhere boot speed matters.

### User Data Rules and Gotchas

| Rule | Detail |
|------|--------|
| **Size limit** | 16 KB *after* base64 encoding. Gzip (Option C) helps a lot. |
| **Runs as root** | No `sudo` needed. Use `sudo -u appuser` to drop privileges. |
| **Runs once by default** | Only on the *first* boot. Won't re-run on reboot. |
| **Working directory** | `/` (root), not the home directory. Always use absolute paths. |
| **Minimal PATH** | Don't assume tools are in PATH; use full paths or set PATH explicitly. |
| **Log location** | `/var/log/cloud-init-output.log` and `/var/log/cloud-init.log` |
| **Not encrypted at rest** | Anyone who can call `DescribeLaunchTemplateVersions` sees it. **Never put secrets in user data.** |
| **`$` escaping** | In `.tftpl` files, write `$${BASH_VAR}` for literal bash variables. |

### Making User Data Run on Every Boot

```bash
#!/bin/bash
# Add this to the top of your script
cloud-init-per always my-task /path/to/script.sh
```

Or use cloud-config:

```yaml
#cloud-config
bootcmd:
  - echo "Runs on EVERY boot"
runcmd:
  - echo "Runs only on FIRST boot"
```

### Getting the Right AMI

**Best practice — SSM Parameter (auto-updating):**

```hcl
# Amazon Linux 2023
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Amazon Linux 2023 ARM (Graviton — ~20% cheaper)
data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Ubuntu 24.04 LTS
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
```

**Alternative — filtered lookup:**

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
```

**Trade-off:** `most_recent = true` means a new AMI release triggers instance replacement on your next apply. Great for staying patched, potentially surprising. For production, consider pinning a specific AMI ID and updating it deliberately.

### Launch Template Versioning

```hcl
resource "aws_launch_template" "app" {
  # ...
  update_default_version = true   # new version becomes default
}

resource "aws_autoscaling_group" "app" {
  launch_template {
    id = aws_launch_template.app.id

    # Pick ONE:
    version = aws_launch_template.app.latest_version  # always newest
    # version = "$Latest"    # AWS resolves at launch time
    # version = "$Default"   # uses whatever is marked default
    # version = "3"          # pinned to exact version
  }
}
```

| Setting | Behavior | Best for |
|---------|----------|----------|
| `latest_version` (Terraform attribute) | Terraform sees the change and can trigger instance refresh | Most cases |
| `"$Latest"` | AWS picks newest at launch; Terraform doesn't detect changes | Manual control |
| `"$Default"` | Uses the marked-default version | Blue/green style rollouts |
| `"3"` | Frozen | Compliance, rollback |

### Mixed Instances with Spot (Cost Saving)

```hcl
resource "aws_autoscaling_group" "app" {
  name_prefix         = "app-"
  vpc_zone_identifier = aws_subnet.private[*].id
  min_size            = 2
  max_size            = 10
  desired_capacity    = 4

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 2      # always 2 on-demand
      on_demand_percentage_above_base_capacity = 25     # then 25% on-demand
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = aws_launch_template.app.latest_version
      }

      # More types = better spot availability
      override { instance_type = "t3.medium" }
      override { instance_type = "t3a.medium" }
      override { instance_type = "t2.medium" }
      override { instance_type = "m5.large" }
    }
  }
}
```

**Spot instances cost up to 90% less** but AWS can reclaim them with 2 minutes' notice. `price-capacity-optimized` is the current recommended strategy — it balances low price against low interruption risk.

**For Keycloak specifically:** Spot is risky for the primary tier because losing a node mid-login flow disrupts users. Use on-demand for base capacity and spot only for burst.

### Attribute-Based Instance Selection

Instead of listing instance types, describe what you need:

```hcl
mixed_instances_policy {
  launch_template {
    launch_template_specification {
      launch_template_id = aws_launch_template.app.id
    }

    override {
      instance_requirements {
        vcpu_count   { min = 2, max = 8 }
        memory_mib   { min = 4096 }
        cpu_manufacturers = ["intel", "amd"]
        burstable_performance = "included"
      }
    }
  }
}
```

AWS picks whatever matches, automatically including new instance types as they launch.

---

## Part 3: Options Compared

### Where to Run Keycloak on AWS

#### Option 1: EC2 + Auto Scaling Group (this guide)

**Pros**
- Full control over the OS and JVM tuning
- Straightforward to debug — it's just a Linux box
- Easy to attach EBS volumes for custom providers/themes
- No container knowledge required
- Reserved Instances / Savings Plans give predictable discounts

**Cons**
- You patch the OS
- Slower scaling (minutes, not seconds)
- More Terraform code to maintain
- You manage the Java runtime

**Best for:** Teams without Kubernetes, moderate scale, need for OS-level customization.

#### Option 2: ECS Fargate

**Pros**
- No servers to patch — AWS runs the infrastructure
- Fast scaling
- Official Keycloak container image (`quay.io/keycloak/keycloak`)
- Simpler Terraform than EKS
- Pay per second of vCPU/memory

**Cons**
- Less control over the runtime
- Cold starts on scale-out
- Debugging requires ECS Exec setup
- Can cost more than EC2 at steady high usage

**Best for:** Teams wanting managed infrastructure without Kubernetes complexity.

#### Option 3: EKS (Kubernetes)

**Pros**
- The **Keycloak Operator** handles upgrades, scaling, and config declaratively
- Best clustering support via KUBE_PING
- Fits existing Kubernetes platforms
- Rich ecosystem (cert-manager, external-secrets, etc.)

**Cons**
- Steepest learning curve
- EKS control plane costs ~$73/month before any workloads
- Significant operational overhead
- Overkill for a single application

**Best for:** Organizations already running Kubernetes.

#### Option 4: Amazon Cognito (not Keycloak)

**Pros**
- Fully managed, near-zero ops
- Deep AWS integration (API Gateway, ALB, AppSync)
- Generous free tier
- Scales automatically

**Cons**
- Far less flexible than Keycloak
- Limited theming and custom flows
- Weaker enterprise federation features
- Vendor lock-in
- Some advanced features cost significantly

**Best for:** New AWS-native apps with straightforward auth needs.

#### Comparison Table

| Factor | EC2 + ASG | ECS Fargate | EKS | Cognito |
|--------|-----------|-------------|-----|---------|
| Setup difficulty | Medium | Medium | High | Low |
| Ops burden | High | Low | High | None |
| Cost (small) | $$ | $$ | $$$ | $ |
| Cost (large) | $$ | $$$ | $$$ | $$$ |
| Flexibility | High | High | Highest | Low |
| Scaling speed | Minutes | Seconds | Seconds | Instant |
| Portability | Good | Medium | Best | None |

### Database Choices

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **RDS PostgreSQL** | Well-tested, cheap, simple, Multi-AZ | Manual instance sizing | **Recommended default** |
| **Aurora PostgreSQL** | Auto-failover in seconds, storage auto-scales, up to 15 read replicas | ~20% more expensive, more complex | Best for production HA |
| **Aurora Serverless v2** | Scales to 0.5 ACU, pay for what you use | Cold start latency, can be pricier under steady load | Good for dev/variable load |
| **RDS MySQL** | Supported | Less common with Keycloak, fewer examples | Only if you must |
| **Self-managed on EC2** | Cheapest raw cost | You do backups, patching, failover | Not recommended |

### Handling HTTPS

| Option | Pros | Cons |
|--------|------|------|
| **ALB + ACM certificate** | Free certs, auto-renewal, offloads TLS from Keycloak | Requires Route 53 or DNS validation |
| **TLS on Keycloak directly** | End-to-end encryption | Manual cert management, more CPU on instances |
| **CloudFront + ALB** | Global edge caching, DDoS protection via Shield | Extra cost and complexity, caching needs care with auth |

**Recommended:** ALB with ACM. Add end-to-end TLS (ALB→instance also encrypted) only if compliance requires it.

### Clustering / Cache Stack

Keycloak uses Infinispan for its distributed cache. The discovery mechanism matters:

| Stack | How it works | Pros | Cons |
|-------|-------------|------|------|
| `jdbc-ping` | Nodes register in a DB table | No extra infra, works everywhere, **recommended for EC2** | Slight DB load |
| `kubernetes` (KUBE_PING) | Uses K8s API | Native on EKS | K8s only |
| `tcpping` | Static list of IPs | Simple | Breaks with autoscaling |
| `dns-ping` | DNS SRV records | Works with service discovery | Needs DNS setup |

For EC2 + ASG, **`jdbc-ping` is the right choice** — it's what's configured in the user data script above. Keycloak 26 made `jdbc-ping` the default cache stack for exactly this reason.

---

## Part 4: Production Hardening

Everything in Part 1 works, but don't ship it as-is. Here's what changes.

### 1. Remote State with Locking

Never keep `terraform.tfstate` on your laptop.

```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "mycompany-terraform-state"
    key          = "keycloak/prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # S3-native locking, Terraform 1.10+
  }
}
```

**Note:** As of Terraform 1.10+, S3-native state locking (`use_lockfile = true`) replaces the old DynamoDB table approach. DynamoDB locking still works but is being phased out.

Create the bucket first, with versioning:

```bash
aws s3api create-bucket --bucket mycompany-terraform-state --region us-east-1
aws s3api put-bucket-versioning --bucket mycompany-terraform-state \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket mycompany-terraform-state \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket mycompany-terraform-state \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. Real HTTPS

```hcl
# Request a certificate
resource "aws_acm_certificate" "keycloak" {
  domain_name       = "auth.example.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Validate it via Route 53
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.keycloak.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "keycloak" {
  certificate_arn         = aws_acm_certificate.keycloak.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# HTTPS listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.keycloak.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

# Redirect HTTP → HTTPS
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# DNS record pointing at the ALB
resource "aws_route53_record" "keycloak" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "auth.example.com"
  type    = "A"

  alias {
    name                   = aws_lb.keycloak.dns_name
    zone_id                = aws_lb.keycloak.zone_id
    evaluate_target_health = true
  }
}
```

Then set `keycloak_hostname = "auth.example.com"` in your tfvars and add to the Keycloak config:

```
hostname=https://auth.example.com
hostname-strict=true
proxy-headers=xforwarded
```

**Security note:** `proxy-headers=xforwarded` tells Keycloak to trust `X-Forwarded-*` headers. Only enable this when the ALB is the *only* path to your instances — which is why the security group restricts port 8080 to the ALB security group.

### 3. Production Database Settings

```hcl
resource "aws_db_instance" "keycloak" {
  instance_class = "db.r6g.large"    # memory-optimized, Graviton

  multi_az                = true      # automatic failover
  backup_retention_period = 30
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "keycloak-final-${formatdate("YYYYMMDD-hhmm", timestamp())}"

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  performance_insights_enabled          = true
  performance_insights_retention_period = 731   # 2 years

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  copy_tags_to_snapshot = true
  apply_immediately     = false   # wait for maintenance window
}
```

**Sizing rule of thumb:** Keycloak's database load is mostly reads. Start with `db.r6g.large` (2 vCPU, 16 GB) for up to ~100 requests/second, and monitor Performance Insights.

### 4. Auto Scaling Policies

```hcl
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

resource "aws_autoscaling_policy" "requests" {
  name                   = "${local.name}-request-target"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label = "${aws_lb.keycloak.arn_suffix}/${aws_lb_target_group.keycloak.arn_suffix}"
    }
    target_value = 500.0
  }
}
```

**Keycloak scaling caveat:** Keycloak nodes must join the Infinispan cluster to share sessions. Scaling *out* is fine. Scaling *in* drops sessions held by that node unless you've configured session persistence. Consider setting a conservative `min_size` (2 or 3) and scaling out only.

### 5. WAF Protection

```hcl
resource "aws_wafv2_web_acl" "keycloak" {
  name  = "${local.name}-waf"
  scope = "REGIONAL"

  default_action { allow {} }

  # Rate limit login attempts
  rule {
    name     = "rate-limit"
    priority = 1

    action { block {} }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # AWS managed common rules
  rule {
    name     = "common-rules"
    priority = 2

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "keycloak" {
  resource_arn = aws_lb.keycloak.arn
  web_acl_arn  = aws_wafv2_web_acl.keycloak.arn
}
```

### 6. Monitoring and Alarms

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
    LoadBalancer = aws_lb.keycloak.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "high_5xx" {
  alarm_name          = "${local.name}-high-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "${local.name}-db-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.keycloak.id
  }
}
```

### 7. Rotate the Admin Account

The `KC_BOOTSTRAP_ADMIN_*` account is meant to be **temporary**. After first login:

1. Create a permanent admin user in the master realm
2. Assign it the `admin` role
3. Delete the bootstrap `kcadmin` account
4. Remove the drop-in file: `/etc/systemd/system/keycloak.service.d/bootstrap.conf`

Better still, federate admin access to your corporate IdP so no local admin password exists at all.

### 8. Secrets Rotation

```hcl
resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = aws_secretsmanager_secret.db.id
  rotation_lambda_arn = aws_lambda_function.rotate_db.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

AWS provides ready-made rotation Lambda templates for RDS PostgreSQL. Note that Keycloak reads the password once at boot, so rotation requires an instance refresh or a config-reload mechanism.

### 9. Production Checklist

- [ ] Remote S3 state with versioning, encryption, and locking
- [ ] `terraform.tfvars` and `*.tfstate` in `.gitignore`
- [ ] HTTPS with valid ACM certificate; HTTP redirects to HTTPS
- [ ] `hostname-strict=true` and correct `hostname` set
- [ ] Security groups reference other security groups, not `0.0.0.0/0`
- [ ] No SSH ports open; SSM Session Manager only
- [ ] IMDSv2 required (`http_tokens = "required"`)
- [ ] All EBS volumes and RDS storage encrypted
- [ ] RDS Multi-AZ enabled
- [ ] RDS deletion protection on; final snapshot enabled
- [ ] Backup retention ≥ 7 days (30 for compliance)
- [ ] Instances in private subnets
- [ ] ALB access logs enabled to S3
- [ ] VPC Flow Logs enabled
- [ ] CloudWatch alarms with SNS notifications
- [ ] WAF attached to ALB with rate limiting
- [ ] Bootstrap admin account deleted after setup
- [ ] Brute force detection enabled in Keycloak realm settings
- [ ] MFA required for admin accounts
- [ ] Token lifespans reviewed (default access token: 5 min)
- [ ] Keycloak `--optimized` build used (faster startup)
- [ ] Instance refresh configured on the ASG
- [ ] Tested `terraform plan` shows no unexpected drift
- [ ] Documented runbook for restore-from-backup

### 10. Terraform Best Practices

```bash
# Format consistently
terraform fmt -recursive

# Validate syntax
terraform validate

# Save plans for review
terraform plan -out=tfplan
terraform show -json tfplan | jq . > plan.json
terraform apply tfplan

# Security scanning
brew install tfsec checkov     # or your package manager
tfsec .
checkov -d .

# Linting
tflint --init && tflint

# Detect drift
terraform plan -detailed-exitcode
# exit 0 = no changes, 1 = error, 2 = changes pending
```

**Module structure for multiple environments:**

```
infra/
├── modules/
│   └── keycloak/
│       ├── main.tf
│       ├── variables.tf
│       ├── outputs.tf
│       └── user-data.sh.tftpl
└── environments/
    ├── dev/
    │   ├── main.tf          # module "keycloak" { source = "../../modules/keycloak" ... }
    │   ├── backend.tf
    │   └── terraform.tfvars
    ├── staging/
    └── prod/
```

**Avoid Terraform workspaces for environment separation.** They share a single backend key and it's easy to apply to the wrong environment. Separate directories with separate state files are safer.

---

## Part 5: Troubleshooting

### Diagnostic Commands

```bash
# --- Connect without SSH ---
aws ssm start-session --target i-0123456789abcdef0

# --- On the instance ---
sudo cat /var/log/user-data.log              # our script's output
sudo cat /var/log/cloud-init-output.log      # cloud-init's view
sudo journalctl -u keycloak -f               # live Keycloak logs
sudo systemctl status keycloak
curl -s localhost:9000/health/ready | jq .

# --- Check the rendered user data ---
curl -H "X-aws-ec2-metadata-token: $(curl -X PUT \
  'http://169.254.169.254/latest/api/token' \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/user-data

# --- Test DB connectivity from the instance ---
sudo dnf install -y postgresql16
psql -h <rds-endpoint> -U keycloak -d keycloak

# --- From your laptop: check ASG health ---
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <asg-name> \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,HealthStatus,LifecycleState]' \
  --output table

# --- Check target group health ---
aws elbv2 describe-target-health --target-group-arn <arn>

# --- See launch template versions ---
aws ec2 describe-launch-template-versions \
  --launch-template-id lt-0123456789abcdef0 \
  --query 'LaunchTemplateVersions[].[VersionNumber,DefaultVersion,VersionDescription]' \
  --output table
```

### Common Problems

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Target group shows "unhealthy" | Health check path/port wrong, or grace period too short | Verify `/health/ready` on port 9000; raise `health_check_grace_period` to 600 |
| Keycloak won't start, DB error | Security group blocks 5432, or wrong credentials | Check SG references; test with `psql` from instance |
| Blank page or broken CSS | `hostname` misconfigured behind proxy | Set `hostname` and `proxy-headers=xforwarded` correctly |
| Infinite redirect loop | ALB terminates TLS but Keycloak thinks it's HTTP | Set `proxy-headers=xforwarded` |
| `Invalid parameter: redirect_uri` | Client's redirect URI doesn't match | Fix redirect URIs in the Keycloak client config |
| User data didn't run at all | Missing `#!/bin/bash` shebang, or wrong encoding | First line must be the shebang; wrap in `base64encode()` |
| User data ran but variables are empty | `${VAR}` consumed by Terraform | Escape bash variables as `$${VAR}` in `.tftpl` files |
| "User data is too large" | Over 16 KB after encoding | Use `cloudinit_config` with `gzip = true`, or bake an AMI |
| Instances loop terminate/launch | Health check failing before startup completes | Increase `health_check_grace_period`; check logs before instance dies |
| Can't reach Secrets Manager | No NAT Gateway, or IAM policy too narrow | Add NAT or a VPC endpoint; verify the secret ARN in the policy |
| `terraform apply` hangs on RDS | Normal — RDS takes 10–15 minutes | Wait |
| Cluster nodes don't see each other | JGroups port blocked | Allow 7800 within the instance security group |
| Sessions lost on scale-in | Node held sessions, no persistence | Use `jdbc-ping` cache stack; consider sticky sessions |

### Keycloak Version Notes

| Version | Key changes |
|---------|-------------|
| 26.x | `KC_BOOTSTRAP_ADMIN_*` replaces `KEYCLOAK_ADMIN_*`; requires Java 21; `jdbc-ping` default cache stack; persistent sessions by default |
| 25.x | Management port 9000 introduced for health/metrics; `proxy-headers` replaces `proxy` option |
| 24.x | `hostname-strict-backchannel` changes |
| 17–23 | Quarkus distribution (replaced WildFly) |
| ≤16 | WildFly-based, **end of life** |

Always check the official upgrade guide before jumping versions. Keycloak follows a rapid release cadence with a support window of roughly one year per release.

---

## Quick Reference

### Essential Commands

```bash
terraform init                        # download providers
terraform init -upgrade               # update providers
terraform fmt -recursive              # format code
terraform validate                    # check syntax
terraform plan                        # preview changes
terraform plan -out=tfplan            # save a plan
terraform apply tfplan                # apply saved plan
terraform apply -target=aws_instance.x  # apply one resource (use sparingly)
terraform destroy                     # tear everything down
terraform state list                  # list managed resources
terraform state show aws_vpc.main     # inspect one resource
terraform output                      # show outputs
terraform output -raw keycloak_url    # single output, no quotes
terraform refresh                     # sync state with reality
terraform import aws_vpc.main vpc-123 # adopt existing resource
```

### Key Keycloak Configuration Options

```properties
# Database
db=postgres
db-url=jdbc:postgresql://host:5432/keycloak
db-username=keycloak
db-password=secret
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

# Hostname / proxy
hostname=https://auth.example.com
hostname-strict=true
hostname-backchannel-dynamic=false
proxy-headers=xforwarded

# HTTP
http-enabled=true
http-port=8080
https-port=8443

# Health & metrics (on management port 9000)
health-enabled=true
metrics-enabled=true

# Clustering
cache=ispn
cache-stack=jdbc-ping

# Logging
log=console,file
log-level=INFO
log-console-output=json
```

### Useful Endpoints

| Endpoint | Purpose |
|----------|---------|
| `/admin` | Admin console |
| `/realms/{realm}/.well-known/openid-configuration` | OIDC discovery document |
| `/realms/{realm}/protocol/openid-connect/token` | Token endpoint |
| `/realms/{realm}/protocol/openid-connect/auth` | Authorization endpoint |
| `/realms/{realm}/protocol/openid-connect/userinfo` | User info |
| `/realms/{realm}/protocol/openid-connect/certs` | Public keys (JWKS) |
| `:9000/health/ready` | Readiness probe |
| `:9000/health/live` | Liveness probe |
| `:9000/metrics` | Prometheus metrics |

### Estimated Monthly Costs (us-east-1, approximate)

| Component | Dev | Production |
|-----------|-----|-----------|
| EC2 instances | 1 × t3.medium ≈ $30 | 2 × m6i.large ≈ $140 |
| RDS | db.t4g.micro ≈ $13 | db.r6g.large Multi-AZ ≈ $360 |
| ALB | ≈ $18 + traffic | ≈ $18 + traffic |
| NAT Gateway | ≈ $32 + data | 2 AZ ≈ $65 + data |
| Secrets Manager | ≈ $1 | ≈ $1 |
| CloudWatch | ≈ $5 | ≈ $20 |
| WAF | — | ≈ $10 |
| **Rough total** | **≈ $100/mo** | **≈ $615/mo** |

Prices change — verify with the AWS Pricing Calculator for your region.

**Dev cost-saving tips:**
- Skip the NAT Gateway; put instances in public subnets (dev only, restricted SG)
- Use a scheduled ASG action to scale to 0 outside work hours
- Stop RDS when not in use (auto-restarts after 7 days)
- Use Graviton (`t4g`, `m7g`) instance types — ~20% cheaper

### Official Documentation

- Keycloak docs: `https://www.keycloak.org/documentation`
- Keycloak server configuration guide: `https://www.keycloak.org/server/all-config`
- Terraform AWS provider: `https://registry.terraform.io/providers/hashicorp/aws/latest/docs`
- AWS Launch Templates: `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-templates.html`
- EC2 user data: `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html`
- cloud-init docs: `https://cloudinit.readthedocs.io/`
- Terraform AWS modules: `https://github.com/terraform-aws-modules`

---

*Versions referenced: Keycloak 26.4.0, Terraform 1.9+, AWS Provider 6.x, Amazon Linux 2023, PostgreSQL 16. Verify current versions before deploying, as release cadences are fast.*
