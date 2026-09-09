# Terraform Modules Template: EC2, Launch Templates, and Platform Apps

A reusable module layout for deploying **EC2 instances**, **Launch Templates / Auto Scaling Groups**, and self-hosted apps — **Grafana, Prometheus, Keycloak, Kafka, and NiFi** — on AWS, with pros, cons, and best practices.

---

## 1. Background: What is a Terraform module?

A **module** is just a folder of `.tf` files that describes one reusable piece of infrastructure (for example "one EC2 server with its security group"). Instead of copy-pasting 100 lines every time you need a server, you write the module once and *call* it with different inputs:

```hcl
module "grafana" {
  source        = "./modules/ec2-app"
  name          = "grafana"
  instance_type = "t3.small"
}
```

Think of a module like a recipe: the recipe (module) is written once; each time you cook (call it) you change the ingredients (variables).

**Key building blocks**

| Term | Plain-language meaning |
|---|---|
| Launch Template | A saved "blueprint" for a server: AMI, size, disk, startup script, IAM role. |
| Auto Scaling Group (ASG) | Keeps N copies of a blueprint running and replaces broken ones. |
| EC2 instance | A single server you manage directly. |
| user_data | A script that runs the first time the server boots (installs the app). |
| Security Group | A firewall for the server. |
| Remote state | Where Terraform stores what it built (S3 + locking) so a team can share it. |

---

## 2. Step-by-step setup: deploy Grafana with a module

### Step 1 – Repository layout

```
infra/
├── modules/
│   ├── launch-template-asg/     # blueprint + auto scaling
│   ├── ec2-instance/            # single server
│   ├── security-group/
│   └── apps/
│       ├── grafana/
│       ├── prometheus/
│       ├── keycloak/
│       ├── kafka/
│       └── nifi/
├── envs/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── backend.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   └── prod/
└── versions.tf
```

### Step 2 – Pin versions (`versions.tf`)

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

### Step 3 – Remote state (`envs/dev/backend.tf`)

```hcl
terraform {
  backend "s3" {
    bucket       = "mycompany-tf-state"
    key          = "dev/platform/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # S3 native locking (no DynamoDB table needed)
  }
}
```

### Step 4 – The generic `ec2-instance` module

`modules/ec2-instance/variables.tf`
```hcl
variable "name"           { type = string }
variable "vpc_id"         { type = string }
variable "subnet_id"      { type = string }
variable "instance_type"  { type = string  default = "t3.small" }
variable "ami_id"         { type = string  default = null }   # null = latest AL2023
variable "root_volume_gb" { type = number  default = 20 }
variable "user_data"      { type = string  default = "" }
variable "ingress_rules" {
  type = list(object({
    port        = number
    cidr_blocks = list(string)
    description = string
  }))
  default = []
}
variable "iam_policy_arns" { type = list(string) default = [] }
variable "tags"            { type = map(string)  default = {} }
```

`modules/ec2-instance/main.tf`
```hcl
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id = coalesce(var.ami_id, data.aws_ssm_parameter.al2023.value)
  tags   = merge({ Name = var.name, ManagedBy = "terraform" }, var.tags)
}

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Security group for ${var.name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.port
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = ingress.value.cidr_blocks
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_iam_role" "this" {
  name = "${var.name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

# Always attach SSM so you never need SSH keys
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.iam_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = var.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"   # IMDSv2 only
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = local.tags
}
```

`modules/ec2-instance/outputs.tf`
```hcl
output "instance_id"       { value = aws_instance.this.id }
output "private_ip"        { value = aws_instance.this.private_ip }
output "security_group_id" { value = aws_security_group.this.id }
output "iam_role_name"     { value = aws_iam_role.this.name }
```

### Step 5 – The Grafana app module (wraps the generic module)

`modules/apps/grafana/main.tf`
```hcl
variable "name"       { type = string  default = "grafana" }
variable "vpc_id"     { type = string }
variable "subnet_id"  { type = string }
variable "allowed_cidrs" { type = list(string) }
variable "admin_password_ssm_param" { type = string }  # store secrets in SSM, not tfvars
variable "prometheus_url" { type = string }

module "server" {
  source        = "../../ec2-instance"
  name          = var.name
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  instance_type = "t3.small"

  ingress_rules = [
    { port = 3000, cidr_blocks = var.allowed_cidrs, description = "Grafana UI" }
  ]

  iam_policy_arns = ["arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess"]

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    admin_password_param = var.admin_password_ssm_param
    prometheus_url       = var.prometheus_url
  })
}

output "private_ip" { value = module.server.private_ip }
```

`modules/apps/grafana/user_data.sh.tftpl`
```bash
#!/bin/bash
set -euxo pipefail
dnf install -y docker
systemctl enable --now docker

ADMIN_PW=$(aws ssm get-parameter --name "${admin_password_param}" --with-decryption --query Parameter.Value --output text)

mkdir -p /opt/grafana/provisioning/datasources
cat > /opt/grafana/provisioning/datasources/prom.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    url: ${prometheus_url}
    isDefault: true
EOF

docker run -d --name grafana --restart unless-stopped \
  -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD="$ADMIN_PW" \
  -v /opt/grafana/provisioning:/etc/grafana/provisioning \
  -v grafana-data:/var/lib/grafana \
  grafana/grafana:latest
```

### Step 6 – Call it from an environment (`envs/dev/main.tf`)

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = { Environment = "dev", Project = "platform" }
  }
}

module "grafana" {
  source                   = "../../modules/apps/grafana"
  vpc_id                   = var.vpc_id
  subnet_id                = var.private_subnet_ids[0]
  allowed_cidrs            = ["10.0.0.0/8"]
  admin_password_ssm_param = "/dev/grafana/admin_password"
  prometheus_url           = "http://${module.prometheus.private_ip}:9090"
}
```

### Step 7 – Run it

```bash
cd envs/dev
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

---

## 3. Launch Template + Auto Scaling module

Use this instead of `ec2-instance` for anything that should self-heal or scale (Kafka brokers, NiFi nodes, stateless services).

`modules/launch-template-asg/main.tf`
```hcl
variable "name"            { type = string }
variable "vpc_id"          { type = string }
variable "subnet_ids"      { type = list(string) }
variable "instance_type"   { type = string  default = "t3.medium" }
variable "ami_id"          { type = string  default = null }
variable "min_size"        { type = number  default = 1 }
variable "max_size"        { type = number  default = 3 }
variable "desired_capacity"{ type = number  default = 1 }
variable "user_data"       { type = string  default = "" }
variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }
variable "target_group_arns" { type = list(string) default = [] }
variable "tags"            { type = map(string) default = {} }

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = coalesce(var.ami_id, data.aws_ssm_parameter.al2023.value)
  instance_type = var.instance_type
  user_data     = base64encode(var.user_data)
  update_default_version = true

  iam_instance_profile { name = var.instance_profile_name }

  network_interfaces {
    security_groups             = var.security_group_ids
    associate_public_ip_address = false
  }

  metadata_options {
    http_tokens = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 30
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge({ Name = var.name }, var.tags)
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-asg"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity
  target_group_arns   = var.target_group_arns
  health_check_type   = length(var.target_group_arns) > 0 ? "ELB" : "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # Replace instances automatically when the launch template changes
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180
    }
  }

  dynamic "tag" {
    for_each = merge({ Name = var.name }, var.tags)
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle { ignore_changes = [desired_capacity] }  # let autoscaling policies own this
}

output "asg_name"           { value = aws_autoscaling_group.this.name }
output "launch_template_id" { value = aws_launch_template.this.id }
```

**Single EC2 vs Launch Template + ASG**

| | `ec2-instance` | `launch-template-asg` |
|---|---|---|
| Pros | Simple, stable IP, easy to attach one EBS volume, good for stateful singletons | Self-healing, rolling updates via instance refresh, scale out/in, multi-AZ |
| Cons | No auto-recovery beyond EC2 auto-recovery, manual replacement, single AZ | Stateful apps need extra work (EBS attach scripts, stable hostnames), harder to debug one node |
| Use for | Grafana, Keycloak (small), NiFi single node, bastions | Prometheus behind LB, Kafka brokers (with care), NiFi cluster, Keycloak cluster |

---

## 4. App module templates

Each app module follows the same pattern: **wrap the base module + add app-specific ports, IAM, storage, and user_data**. Only the differences are shown below.

### 4.1 Prometheus

```hcl
module "server" {
  source        = "../../ec2-instance"
  name          = "prometheus"
  instance_type = "t3.medium"
  root_volume_gb = 100          # TSDB grows fast; size for retention
  ingress_rules = [
    { port = 9090, cidr_blocks = var.allowed_cidrs, description = "Prometheus UI/API" }
  ]
  # ec2:DescribeInstances lets Prometheus auto-discover targets by tag
  iam_policy_arns = [aws_iam_policy.ec2_discovery.arn]
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    retention = "15d"
    region    = var.region
  })
  # ...
}
```

Prometheus config snippet in user_data (EC2 service discovery by tag):
```yaml
scrape_configs:
  - job_name: node
    ec2_sd_configs:
      - region: ${region}
        port: 9100
        filters:
          - name: tag:Monitoring
            values: ["true"]
```

| Pros | Cons |
|---|---|
| Pull model auto-discovers EC2 targets via tags — no manual target lists | Single node = single point of failure; needs Thanos/Mimir for HA and long retention |
| Cheap, simple, huge ecosystem | Disk sizing and retention need monitoring; not horizontally scalable alone |

**Managed alternative:** Amazon Managed Service for Prometheus (AMP) + Amazon Managed Grafana (AMG). Pros: no servers, HA built in. Cons: per-sample pricing, less control, some features differ.

### 4.2 Keycloak

```hcl
resource "aws_db_instance" "keycloak" {
  identifier        = "keycloak-db"
  engine            = "postgres"
  instance_class    = "db.t4g.small"
  allocated_storage = 20
  db_name           = "keycloak"
  username          = "keycloak"
  manage_master_user_password = true   # secret stored in Secrets Manager
  storage_encrypted = true
  skip_final_snapshot = var.environment != "prod"
  # ...
}

module "server" {
  source = "../../ec2-instance"
  name   = "keycloak"
  instance_type = "t3.medium"
  ingress_rules = [
    { port = 8443, cidr_blocks = var.allowed_cidrs, description = "Keycloak HTTPS" }
  ]
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    db_host   = aws_db_instance.keycloak.address
    db_secret = aws_db_instance.keycloak.master_user_secret[0].secret_arn
    hostname  = var.public_hostname
  })
}
```

user_data core:
```bash
docker run -d --name keycloak --restart unless-stopped -p 8443:8443 \
  -e KC_DB=postgres -e KC_DB_URL="jdbc:postgresql://${db_host}:5432/keycloak" \
  -e KC_DB_USERNAME="$DB_USER" -e KC_DB_PASSWORD="$DB_PASS" \
  -e KC_HOSTNAME="${hostname}" -e KC_HTTPS_CERTIFICATE_FILE=/certs/tls.crt \
  -e KC_HTTPS_CERTIFICATE_KEY_FILE=/certs/tls.key \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PW" \
  -v /opt/keycloak/certs:/certs quay.io/keycloak/keycloak:latest start
```

| Pros | Cons |
|---|---|
| Full OIDC/SAML identity provider, realms, federation to LDAP/AD | Needs an external DB (RDS) — never use the dev H2 store |
| Clusters via ASG + JDBC-ping or DNS discovery | TLS termination, hostname config, and cache clustering are fiddly; memory hungry |

**Managed alternative:** Amazon Cognito. Cheaper to run, but less flexible than Keycloak for complex federation.

### 4.3 Kafka (self-managed on EC2, KRaft mode)

```hcl
# One launch template + ASG per broker so each keeps a stable ID and EBS volume
module "broker" {
  for_each = { for i in range(var.broker_count) : i => i }
  source   = "../../launch-template-asg"
  name     = "kafka-broker-${each.key}"
  subnet_ids    = [var.subnet_ids[each.key % length(var.subnet_ids)]]
  instance_type = "m6i.large"
  min_size = 1
  max_size = 1
  desired_capacity = 1
  security_group_ids    = [aws_security_group.kafka.id]
  instance_profile_name = aws_iam_instance_profile.kafka.name
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    node_id      = each.key
    volume_id    = aws_ebs_volume.data[each.key].id     # attached at boot
    controller_quorum = join(",", [for i in range(var.broker_count) : "${i}@kafka-${i}.internal:9093"])
  })
}

resource "aws_ebs_volume" "data" {
  count             = var.broker_count
  availability_zone = var.azs[count.index % length(var.azs)]
  size              = 500
  type              = "gp3"
  iops              = 6000
  throughput        = 500
  encrypted         = true
}
```

Security group ports: `9092` (client), `9093` (controller), plus `9100` for node exporter.

| Pros | Cons |
|---|---|
| Full control over version, configs, disk performance, cost at scale | Stateful: you own EBS attach logic, broker IDs, DNS records, rolling upgrades |
| KRaft removes ZooKeeper | Hard to run well in an ASG; replacing a broker triggers partition reassignment |

**Managed alternative:** Amazon MSK (or MSK Serverless). Strongly recommended unless you have a dedicated Kafka team. Pros: patching, multi-AZ, monitoring done for you. Cons: higher fixed cost, version lag, less tuning.

### 4.4 NiFi

```hcl
module "nifi" {
  source        = "../../launch-template-asg"
  name          = "nifi"
  instance_type = "m6i.xlarge"      # NiFi is JVM + disk heavy
  min_size = var.cluster_size
  max_size = var.cluster_size
  desired_capacity = var.cluster_size
  security_group_ids    = [aws_security_group.nifi.id]
  instance_profile_name = aws_iam_instance_profile.nifi.name
  target_group_arns     = [aws_lb_target_group.nifi.arn]   # UI behind ALB with sticky sessions
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    zk_connect  = var.zookeeper_connect   # NiFi clustering still needs ZooKeeper
    keystore_ssm = var.keystore_ssm_param
  })
}
```

Ports: `8443` (UI/API), `11443` (cluster protocol), `6342` (load balancing), `2181` ZooKeeper.

| Pros | Cons |
|---|---|
| Visual dataflow, back-pressure, provenance built in | Needs ZooKeeper for clustering; heavy JVM; secured setup requires certs on every node |
| Scales with ASG when repositories are on fast EBS | Flow definitions live on nodes — version them with NiFi Registry, not by hand |

### 4.5 Grafana (see Section 2)

| Pros | Cons |
|---|---|
| Lightweight, dashboards-as-code via provisioning | Default SQLite DB — use RDS or AMG for HA; single node is fine for most teams |

---

## 5. Deployment options compared

| Option | Pros | Cons | Best when |
|---|---|---|---|
| **EC2 + Docker via user_data** (this template) | Simple, cheap, no cluster to run, Terraform owns everything | Rebuilds on every change, limited orchestration, slow boots | Small teams, few services, dev/test, edge cases where EKS is overkill |
| **EKS + Helm charts** (kube-prometheus-stack, Strimzi for Kafka, Keycloak operator, NiFi operator) | Declarative upgrades, HA, rolling updates, huge chart ecosystem | Cluster cost and complexity, Kubernetes skills needed | Many services, prod, teams already on Kubernetes |
| **Managed services** (AMP, AMG, MSK, Cognito) | Least ops, HA by default, security patching handled | Cost, less control, vendor lock-in, feature lag | Prod workloads without a platform team |
| **Packer-built "golden AMIs" + Terraform** | Fast boots, immutable, reproducible, user_data becomes tiny | Extra pipeline to maintain AMIs | Any prod EC2-based deployment |

---

## 6. Best practices checklist

### Module design
- [ ] One responsibility per module; compose small modules (sg, iam, ec2) into app modules.
- [ ] Always ship `variables.tf`, `outputs.tf`, `README.md`, and `examples/` per module.
- [ ] Add `validation` blocks to variables (e.g., instance type prefix, CIDR format).
- [ ] Pin module sources by tag: `source = "git::https://…//modules/ec2-instance?ref=v1.4.0"`.
- [ ] Use `for_each` over `count` so removing one item doesn't reshuffle the rest.
- [ ] Never hard-code AMI IDs; look them up via SSM public parameters or a `data "aws_ami"` filter.

### State and workflow
- [ ] Remote S3 backend with encryption and locking; one state file per environment/stack.
- [ ] Separate stacks for network, data (RDS/EBS), and apps so a bad app change can't destroy a database.
- [ ] Run `terraform fmt`, `validate`, `tflint`, and `trivy`/`checkov` in CI; require a reviewed plan before apply.
- [ ] Protect stateful resources with `lifecycle { prevent_destroy = true }`.

### Security
- [ ] No SSH: use SSM Session Manager (`AmazonSSMManagedInstanceCore`).
- [ ] IMDSv2 required (`http_tokens = "required"`).
- [ ] Encrypt every EBS/RDS volume; use KMS CMKs in prod.
- [ ] Secrets in SSM Parameter Store / Secrets Manager, fetched at boot — never in `.tfvars` or state.
- [ ] Least-privilege security groups: reference other SGs instead of wide CIDRs where possible.
- [ ] Private subnets for everything; expose UIs only through an ALB with TLS and auth (Keycloak/OIDC).

### Operations
- [ ] Tag everything (`default_tags` on the provider) for cost allocation and discovery.
- [ ] Install `node_exporter` on every instance and tag `Monitoring = "true"` so Prometheus auto-discovers it.
- [ ] Use `instance_refresh` on ASGs for zero-touch rolling updates.
- [ ] Bake AMIs with Packer for prod; keep `user_data` for config only.
- [ ] Back up stateful volumes with AWS Backup or DLM snapshot policies.
- [ ] Prefer managed services (MSK, AMP, AMG) for prod unless you have a clear reason not to.

---

## 7. Quick reference: ports per app

| App | Port(s) | Notes |
|---|---|---|
| Grafana | 3000 | Put behind ALB + TLS |
| Prometheus | 9090 | Internal only |
| Node exporter | 9100 | Internal only |
| Keycloak | 8443 (8080 http) | HTTPS required in prod |
| Kafka | 9092 client, 9093 controller | KRaft mode |
| NiFi | 8443 UI, 11443 cluster, 6342 LB | ZooKeeper 2181 for clustering |
