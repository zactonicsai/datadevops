# Deploying Keycloak on AWS with Terraform

## Using Your Existing VPC, Subnets, and Security Groups

*A complete beginner-to-intermediate guide, including EC2 Launch Templates with user data*

---

> ### 🔧 READ THIS FIRST — Values You Must Replace
>
> This guide is written for a **brownfield** deployment: your networking already exists and Terraform will *reference* it, not create it. Everywhere you see a `REPLACE_ME` stub, substitute your real value.
>
> | Stub | What it is | Example |
> |------|-----------|---------|
> | `REPLACE_ME_AWS_REGION` | Your region | `us-east-1` |
> | `REPLACE_ME_VPC_ID` | Existing VPC ID | `vpc-0a1b2c3d4e5f67890` |
> | `REPLACE_ME_APP_SUBNET_1` | Private subnet for Keycloak, AZ 1 | `subnet-0aaa111bbb222ccc3` |
> | `REPLACE_ME_APP_SUBNET_2` | Private subnet for Keycloak, AZ 2 | `subnet-0ddd444eee555fff6` |
> | `REPLACE_ME_ALB_SUBNET_1` | Public subnet for ALB, AZ 1 | `subnet-0111aaa222bbb333c` |
> | `REPLACE_ME_ALB_SUBNET_2` | Public subnet for ALB, AZ 2 | `subnet-0444ddd555eee666f` |
> | `REPLACE_ME_DB_SUBNET_1` | Subnet for RDS, AZ 1 | `subnet-0777ggg888hhh999i` |
> | `REPLACE_ME_DB_SUBNET_2` | Subnet for RDS, AZ 2 | `subnet-0jjj000kkk111lll2` |
> | `REPLACE_ME_ALB_SG_ID` | Existing SG for the load balancer | `sg-0abc123def456789a` |
> | `REPLACE_ME_APP_SG_ID` | Existing SG for Keycloak instances | `sg-0bcd234efg567890b` |
> | `REPLACE_ME_DB_SG_ID` | Existing SG for RDS | `sg-0cde345fgh678901c` |
> | `REPLACE_ME_DB_SUBNET_GROUP` | Existing RDS subnet group name | `shared-db-subnet-group` |
> | `REPLACE_ME_KMS_KEY_ARN` | Existing KMS key for encryption | `arn:aws:kms:us-east-1:111122223333:key/…` |
> | `REPLACE_ME_ACM_CERT_ARN` | Existing ACM certificate | `arn:aws:acm:us-east-1:111122223333:certificate/…` |
> | `REPLACE_ME_ROUTE53_ZONE_ID` | Existing hosted zone | `Z1D633PJN98FT9` |
> | `REPLACE_ME_HOSTNAME` | Public DNS name for Keycloak | `auth.example.com` |
> | `REPLACE_ME_PERMISSIONS_BOUNDARY_ARN` | IAM boundary, if your org requires one | `arn:aws:iam::111122223333:policy/OrgBoundary` |
>
> [Part 1, Step 1](#step-1-discover-your-existing-network) shows how to find every one of these with AWS CLI commands.

---

## Table of Contents

1. [Background: What Are We Building?](#part-0-background)
2. [Part 1: Quick Start — Deploy Into Your Existing Network](#part-1-quick-start)
3. [Part 2: The EC2 Launch Template Deep Dive](#part-2-launch-templates)
4. [Part 3: Working With Existing Infrastructure](#part-3-existing-infra)
5. [Part 4: Deployment Options Compared (Pros & Cons)](#part-4-options-compared)
6. [Part 5: Production Hardening](#part-5-production)
7. [Part 6: Troubleshooting & Reference](#part-6-troubleshooting)

---

## Part 0: Background

### What is Keycloak?

Imagine you run a school. Every classroom door has its own lock, and every student carries 40 different keys. That's chaos.

Now imagine instead there's one **front desk**. Students show their ID once at the front desk, get a badge, and that badge opens every door they're allowed through.

**Keycloak is the front desk.** It's an open-source *Identity and Access Management* (IAM) server. Applications hand off the job of "who is this person and what are they allowed to do?" to Keycloak.

Keycloak is maintained by the **Cloud Native Computing Foundation (CNCF)** — it became an incubating project in 2023 after Red Hat donated it. It is free and open source.

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

Terraform is **Infrastructure as Code (IaC)**. Instead of clicking around the AWS web console (and forgetting what you clicked), you write a text file describing what you want, and Terraform makes it real.

Benefits:
- **Repeatable** — build identical dev/staging/prod environments
- **Reviewable** — infrastructure changes go through code review
- **Reversible** — `terraform destroy` cleans up what Terraform created
- **Documented** — the code *is* the documentation

> **Version note:** Terraform is developed by HashiCorp (now part of IBM). In August 2023 HashiCorp changed Terraform's license from open-source MPL to the Business Source License (BUSL). This led to a community fork called **OpenTofu**, a drop-in replacement under the Linux Foundation. Everything here works identically with OpenTofu — replace `terraform` with `tofu` in commands.

### Greenfield vs. Brownfield — and Why This Guide Is Different

Most tutorials are **greenfield**: they create a brand-new VPC, subnets, and security groups just for the app. That's fine for a sandbox but wrong for most real companies, where:

- A network team owns the VPC and you're not allowed to create one
- Subnets are pre-allocated with routing, NAT, and Direct Connect already wired up
- Security groups are managed centrally for compliance
- Creating a duplicate VPC would waste IP space and break connectivity to other systems

This guide is **brownfield**. Terraform will:

| Terraform **reads** (does not manage) | Terraform **creates** (manages) |
|---|---|
| VPC | Launch Template |
| Subnets | Auto Scaling Group |
| Security groups | Load Balancer + Target Group + Listeners |
| Route tables, NAT, IGW | RDS instance |
| KMS keys | IAM role + instance profile |
| ACM certificates | Secrets Manager secrets |
| Route 53 hosted zone | CloudWatch alarms |
| RDS subnet group *(optional)* | Route 53 record |

**The critical safety property:** `terraform destroy` will never delete your VPC, subnets, or security groups, because Terraform doesn't own them. It only removes what it created.

### What is an EC2 Launch Template?

An **EC2 instance** is a virtual server in AWS. A **Launch Template** is a reusable recipe card that says: "when you make a server, use *this* image, *this* size, *this* network, and run *this* startup script."

**User data** is that startup script — a chunk of text (usually bash) that runs the very first time an instance boots. It's how a blank Linux box turns itself into a Keycloak server without you touching it.

### The Architecture

```
   ┌─────────────────────────────────────────────────────────┐
   │  EXISTING VPC (REPLACE_ME_VPC_ID) — managed by others   │
   │                                                          │
   │  ┌───────────── Existing PUBLIC subnets ──────────────┐ │
   │  │  REPLACE_ME_ALB_SUBNET_1 / _2                       │ │
   │  │                                                      │ │
   │  │   ╔══════════════════════════════════════╗          │ │
   │  │   ║  ALB  ◄── created by Terraform       ║          │ │
   │  │   ║  SG: REPLACE_ME_ALB_SG_ID (existing) ║          │ │
   │  │   ╚══════════════════════════════════════╝          │ │
   │  └──────────────────────┬───────────────────────────────┘ │
   │                         │ HTTP :8080 / health :9000       │
   │  ┌──────────────────────▼─── Existing PRIVATE subnets ──┐ │
   │  │  REPLACE_ME_APP_SUBNET_1 / _2                        │ │
   │  │                                                       │ │
   │  │   ╔═══════════════════════════════════════╗          │ │
   │  │   ║  Auto Scaling Group ◄── Terraform     ║          │ │
   │  │   ║  ┌────────┐  ┌────────┐               ║          │ │
   │  │   ║  │Keycloak│  │Keycloak│               ║          │ │
   │  │   ║  └────────┘  └────────┘               ║          │ │
   │  │   ║  SG: REPLACE_ME_APP_SG_ID (existing)  ║          │ │
   │  │   ╚═══════════════════════════════════════╝          │ │
   │  └──────────────────────┬────────────────────────────────┘ │
   │                         │ PostgreSQL :5432                │
   │  ┌──────────────────────▼─── Existing DB subnets ────────┐ │
   │  │  REPLACE_ME_DB_SUBNET_1 / _2                          │ │
   │  │   ╔═══════════════════════════════════════╗           │ │
   │  │   ║  RDS PostgreSQL ◄── Terraform         ║           │ │
   │  │   ║  SG: REPLACE_ME_DB_SG_ID (existing)   ║           │ │
   │  │   ╚═══════════════════════════════════════╝           │ │
   │  └────────────────────────────────────────────────────────┘ │
   │                                                              │
   │  Existing NAT Gateway ── provides outbound internet          │
   └──────────────────────────────────────────────────────────────┘

   ═══ = Terraform-managed        ─── = pre-existing
```

**Why this shape?**
- Keycloak stores everything in a database. Without an external DB, your users vanish on reboot.
- The ALB handles HTTPS so you don't manage certificates on each server.
- Private subnets mean the servers aren't directly reachable from the internet.

---

## Part 1: Quick Start

**Goal:** A working Keycloak deployment inside your existing network, in about 30 minutes.

### Prerequisites

```bash
terraform version              # need 1.5+, ideally 1.9+
aws --version                  # need v2
aws sts get-caller-identity    # verify credentials work
```

You also need:
- Permission to create EC2, ELB, RDS, IAM, and Secrets Manager resources
- **Read** permission on the existing VPC, subnets, and security groups
- The stub values from the table at the top of this document

### Network Requirements Checklist

Before writing any Terraform, confirm your existing network provides these. If any is missing, deployment will fail in confusing ways.

- [ ] **Two subnets in different AZs** for Keycloak instances
- [ ] **Two subnets in different AZs** for the ALB — public subnets for an internet-facing ALB, private for an internal one
- [ ] **Two subnets in different AZs** for RDS
- [ ] **Outbound internet access** from the app subnets — via NAT Gateway, or VPC endpoints (see below). Required to download Keycloak, OS packages, and reach Secrets Manager and SSM.
- [ ] **DNS resolution enabled** on the VPC (`enableDnsSupport` and `enableDnsHostnames` both true) — RDS endpoints won't resolve otherwise
- [ ] **Security group rules** as described in [Step 3](#step-3-verify-security-group-rules)
- [ ] **Available IP addresses** in each subnet — at least 4 free per app subnet for scaling headroom

#### If you have no NAT Gateway

Some locked-down VPCs have no outbound internet. In that case you need **VPC interface endpoints** for:

| Service | Endpoint | Why |
|---------|----------|-----|
| SSM | `com.amazonaws.<region>.ssm` | Session Manager shell access |
| SSM Messages | `com.amazonaws.<region>.ssmmessages` | Session Manager data channel |
| EC2 Messages | `com.amazonaws.<region>.ec2messages` | SSM agent |
| Secrets Manager | `com.amazonaws.<region>.secretsmanager` | Fetching DB credentials |
| CloudWatch Logs | `com.amazonaws.<region>.logs` | Log shipping |
| S3 (gateway) | `com.amazonaws.<region>.s3` | Package repos on AL2023 |

You'll also need to host the Keycloak tarball internally — see [Part 3, Air-Gapped Environments](#air-gapped-environments).

### Step 1: Discover Your Existing Network

Run these to fill in the stub table. Save the output somewhere.

```bash
export AWS_REGION=REPLACE_ME_AWS_REGION

# --- Find your VPC ---
aws ec2 describe-vpcs \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value,Default:IsDefault}' \
  --output table

# --- Confirm DNS is enabled (both must be true) ---
VPC_ID=REPLACE_ME_VPC_ID
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id $VPC_ID --attribute enableDnsHostnames

# --- List subnets with AZ and free IP count ---
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,FreeIPs:AvailableIpAddressCount,PublicIP:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# --- Determine which subnets are public vs private ---
# A subnet is PUBLIC if its route table has a 0.0.0.0/0 route to an igw-*
for SUBNET in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].SubnetId' --output text); do
  RT=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
    --output text 2>/dev/null)
  # Fall back to the VPC main route table if no explicit association
  if [ -z "$RT" ]; then
    RT=$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
      --output text)
  fi
  case "$RT" in
    igw-*) TYPE="PUBLIC  (via $RT)" ;;
    nat-*) TYPE="PRIVATE (via NAT $RT)" ;;
    "")    TYPE="ISOLATED (no default route)" ;;
    *)     TYPE="OTHER   ($RT)" ;;
  esac
  echo "$SUBNET  $TYPE"
done

# --- List security groups ---
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,Desc:Description}' \
  --output table

# --- Inspect a specific SG's rules ---
aws ec2 describe-security-groups --group-ids REPLACE_ME_APP_SG_ID \
  --query 'SecurityGroups[0].{Ingress:IpPermissions,Egress:IpPermissionsEgress}'

# --- Existing RDS subnet groups (reuse if one exists) ---
aws rds describe-db-subnet-groups \
  --query 'DBSubnetGroups[].{Name:DBSubnetGroupName,VPC:VpcId,Subnets:Subnets[].SubnetIdentifier}' \
  --output table

# --- Existing ACM certificates ---
aws acm list-certificates \
  --query 'CertificateSummaryList[].{ARN:CertificateArn,Domain:DomainName,Status:Status}' \
  --output table

# --- Existing Route 53 hosted zones ---
aws route53 list-hosted-zones \
  --query 'HostedZones[].{ID:Id,Name:Name,Private:Config.PrivateZone}' \
  --output table

# --- Existing customer-managed KMS keys ---
aws kms list-aliases \
  --query 'Aliases[?starts_with(AliasName,`alias/`) && !starts_with(AliasName,`alias/aws/`)].{Alias:AliasName,KeyId:TargetKeyId}' \
  --output table

# --- Check for VPC endpoints (matters if there is no NAT) ---
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].{Service:ServiceName,Type:VpcEndpointType,State:State}' \
  --output table
```

**Tip:** If your organization tags subnets by tier (very common), you can let Terraform discover them by tag instead of hardcoding IDs. That's covered in [Part 3](#discovering-subnets-by-tag).

### Step 2: Create Your Project Folder

```bash
mkdir keycloak-aws && cd keycloak-aws
```

Files we'll create:

```
keycloak-aws/
├── versions.tf          # Terraform + provider versions
├── variables.tf         # Configurable inputs (all the stubs live here)
├── data.tf              # Look up EXISTING network resources
├── security-rules.tf    # OPTIONAL rules on existing SGs
├── database.tf          # RDS PostgreSQL (created)
├── iam.tf               # Instance role for SSM (created)
├── compute.tf           # Launch Template + ASG (created)
├── loadbalancer.tf      # ALB (created)
├── dns.tf               # Route 53 record (created)
├── outputs.tf           # What to print when done
├── terraform.tfvars     # YOUR real values — git-ignored!
├── example.tfvars       # Stub template — safe to commit
└── user-data.sh.tftpl   # The boot script template
```

### Step 3: Verify Security Group Rules

Your existing security groups must permit these flows. Ask your network team to add anything missing, **or** let Terraform manage just the rules (see [Step 7](#step-7-optional--manage-rules-on-existing-security-groups)).

| From | To | Port | Protocol | Purpose |
|------|----|------|----------|---------|
| Your users / corporate CIDR | `REPLACE_ME_ALB_SG_ID` | 443 | TCP | HTTPS to Keycloak |
| Your users / corporate CIDR | `REPLACE_ME_ALB_SG_ID` | 80 | TCP | HTTP → HTTPS redirect |
| `REPLACE_ME_ALB_SG_ID` | `REPLACE_ME_APP_SG_ID` | 8080 | TCP | ALB → Keycloak app traffic |
| `REPLACE_ME_ALB_SG_ID` | `REPLACE_ME_APP_SG_ID` | 9000 | TCP | ALB → Keycloak health checks |
| `REPLACE_ME_APP_SG_ID` | `REPLACE_ME_APP_SG_ID` | 7800 | TCP | JGroups cluster (self-referencing) |
| `REPLACE_ME_APP_SG_ID` | `REPLACE_ME_DB_SG_ID` | 5432 | TCP | Keycloak → PostgreSQL |
| `REPLACE_ME_APP_SG_ID` | `0.0.0.0/0` | 443 | TCP | Egress: downloads, Secrets Manager, SSM |
| `REPLACE_ME_ALB_SG_ID` | `REPLACE_ME_APP_SG_ID` | all | — | Egress from ALB to targets |

**Note the pattern:** No SSH (port 22) anywhere. We use **AWS Systems Manager Session Manager** for shell access — no inbound ports, no key pairs, full audit logging. This is current AWS best practice.

**Verify with a script:**

```bash
#!/bin/bash
# save as check-sg-rules.sh
ALB_SG=REPLACE_ME_ALB_SG_ID
APP_SG=REPLACE_ME_APP_SG_ID
DB_SG=REPLACE_ME_DB_SG_ID

check() {
  local sg=$1 port=$2 src=$3 label=$4
  local found
  found=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query "SecurityGroups[0].IpPermissions[?FromPort<=\`$port\` && ToPort>=\`$port\`].[UserIdGroupPairs[].GroupId,IpRanges[].CidrIp]" \
    --output text 2>/dev/null | grep -c "$src")
  if [ "$found" -gt 0 ]; then
    echo "  OK      $label"
  else
    echo "  MISSING $label  (sg=$sg port=$port source=$src)"
  fi
}

echo "Checking required security group rules..."
check "$APP_SG" 8080 "$ALB_SG" "ALB -> App on 8080"
check "$APP_SG" 9000 "$ALB_SG" "ALB -> App on 9000 (health)"
check "$APP_SG" 7800 "$APP_SG" "App -> App on 7800 (JGroups)"
check "$DB_SG"  5432 "$APP_SG" "App -> DB on 5432"
```

### Step 4: Pin Your Versions

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

  # Uncomment and fill in for team use — see Part 5
  # backend "s3" {
  #   bucket       = "REPLACE_ME_STATE_BUCKET"
  #   key          = "keycloak/dev/terraform.tfstate"
  #   region       = "REPLACE_ME_AWS_REGION"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
      Owner       = var.owner_tag
      CostCenter  = var.cost_center_tag
    }
  }
}
```

**Why pin versions?** `~> 6.0` means "any 6.x, but not 7.0". Major version bumps contain breaking changes. Pinning means your build today works the same next month.

**Why `default_tags`?** Every resource Terraform creates automatically gets these tags. Essential for cost allocation and for proving to your platform team which resources are yours.

### Step 5: Define Variables (All Stubs Live Here)

Create `variables.tf`:

```hcl
# ============================================================
#  GENERAL
# ============================================================

variable "aws_region" {
  description = "AWS region — must match the region of your existing VPC"
  type        = string
  default     = "REPLACE_ME_AWS_REGION"
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
  description = "Prefix for names of resources Terraform creates"
  type        = string
  default     = "keycloak"
}

variable "owner_tag" {
  description = "Team or person responsible — often required by org tagging policy"
  type        = string
  default     = "REPLACE_ME_OWNER"
}

variable "cost_center_tag" {
  description = "Cost center for chargeback — often required by org tagging policy"
  type        = string
  default     = "REPLACE_ME_COST_CENTER"
}

# ============================================================
#  EXISTING NETWORK — Terraform READS these, never creates them
# ============================================================

variable "vpc_id" {
  description = "ID of the EXISTING VPC. Terraform will not create or modify it."
  type        = string
  default     = "REPLACE_ME_VPC_ID"

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must look like vpc-0a1b2c3d4e5f67890. Did you replace the stub?"
  }
}

variable "app_subnet_ids" {
  description = <<-EOT
    EXISTING private subnet IDs for Keycloak instances.
    Must be at least 2 subnets in DIFFERENT availability zones.
    These subnets need outbound internet access (NAT Gateway or VPC endpoints).
  EOT
  type        = list(string)
  default = [
    "REPLACE_ME_APP_SUBNET_1",
    "REPLACE_ME_APP_SUBNET_2",
  ]

  validation {
    condition     = length(var.app_subnet_ids) >= 2
    error_message = "Provide at least 2 app subnets in different AZs for high availability."
  }

  validation {
    condition = alltrue([
      for s in var.app_subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", s))
    ])
    error_message = "Each app subnet must look like subnet-0aaa111bbb222ccc3. Did you replace the stubs?"
  }
}

variable "alb_subnet_ids" {
  description = <<-EOT
    EXISTING subnet IDs for the Application Load Balancer.
    Must be at least 2 subnets in DIFFERENT availability zones.
    Use PUBLIC subnets for an internet-facing ALB, PRIVATE for an internal ALB.
  EOT
  type        = list(string)
  default = [
    "REPLACE_ME_ALB_SUBNET_1",
    "REPLACE_ME_ALB_SUBNET_2",
  ]

  validation {
    condition     = length(var.alb_subnet_ids) >= 2
    error_message = "An ALB requires at least 2 subnets in different AZs."
  }
}

variable "db_subnet_ids" {
  description = <<-EOT
    EXISTING subnet IDs for RDS. At least 2 in different AZs.
    Ignored if db_subnet_group_name is set.
  EOT
  type        = list(string)
  default = [
    "REPLACE_ME_DB_SUBNET_1",
    "REPLACE_ME_DB_SUBNET_2",
  ]
}

variable "db_subnet_group_name" {
  description = <<-EOT
    Name of an EXISTING RDS DB subnet group to reuse.
    Leave empty ("") to have Terraform create one from db_subnet_ids.
    Set to e.g. "REPLACE_ME_DB_SUBNET_GROUP" to reuse a shared one.
  EOT
  type        = string
  default     = ""
}

# ============================================================
#  EXISTING SECURITY GROUPS
# ============================================================

variable "alb_security_group_ids" {
  description = "EXISTING security group IDs to attach to the ALB"
  type        = list(string)
  default     = ["REPLACE_ME_ALB_SG_ID"]

  validation {
    condition = alltrue([
      for s in var.alb_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", s))
    ])
    error_message = "Each SG must look like sg-0abc123def456789a. Did you replace the stubs?"
  }
}

variable "app_security_group_ids" {
  description = "EXISTING security group IDs to attach to Keycloak instances"
  type        = list(string)
  default     = ["REPLACE_ME_APP_SG_ID"]
}

variable "db_security_group_ids" {
  description = "EXISTING security group IDs to attach to the RDS instance"
  type        = list(string)
  default     = ["REPLACE_ME_DB_SG_ID"]
}

variable "manage_security_group_rules" {
  description = <<-EOT
    If true, Terraform ADDS the required rules to your existing security groups.
    If false (default), it assumes your network team already added them.
    Set true only if you have permission to modify these SGs.
  EOT
  type        = bool
  default     = false
}

# ============================================================
#  EXISTING DNS / TLS / ENCRYPTION
# ============================================================

variable "acm_certificate_arn" {
  description = <<-EOT
    ARN of an EXISTING ACM certificate for the HTTPS listener.
    Must be in the SAME region as the ALB.
    Leave empty ("") to create an HTTP-only listener (dev only!).
  EOT
  type        = string
  default     = "REPLACE_ME_ACM_CERT_ARN"
}

variable "route53_zone_id" {
  description = "EXISTING Route 53 hosted zone ID. Leave empty to skip DNS record creation."
  type        = string
  default     = "REPLACE_ME_ROUTE53_ZONE_ID"
}

variable "keycloak_hostname" {
  description = "Public DNS name for Keycloak, e.g. auth.example.com"
  type        = string
  default     = "REPLACE_ME_HOSTNAME"
}

variable "kms_key_arn" {
  description = <<-EOT
    ARN of an EXISTING KMS key for EBS/RDS/Secrets encryption.
    Leave empty ("") to use AWS-managed keys.
  EOT
  type        = string
  default     = ""
}

variable "iam_permissions_boundary_arn" {
  description = <<-EOT
    ARN of an EXISTING IAM permissions boundary policy.
    Many enterprises require this on every role. Leave empty ("") if not required.
  EOT
  type        = string
  default     = ""
}

# ============================================================
#  APPLICATION SETTINGS
# ============================================================

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

variable "asg_min_size" {
  description = "Minimum instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum instances in the Auto Scaling Group"
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired instances in the Auto Scaling Group"
  type        = number
  default     = 1
}

variable "internal_alb" {
  description = "If true, create an INTERNAL ALB (no public IP). Requires private alb_subnet_ids."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.4"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB"
  type        = number
  default     = 20
}
```

**Why validation blocks?** They catch the most common mistake with this guide — forgetting to replace a stub. If `vpc_id` is still `REPLACE_ME_VPC_ID`, `terraform plan` fails immediately with a clear message instead of a cryptic AWS API error twenty resources later.

### Step 6: Look Up Existing Resources

Create `data.tf`. **This file contains only `data` blocks — nothing here creates anything.**

```hcl
# ============================================================
#  READ-ONLY LOOKUPS OF EXISTING INFRASTRUCTURE
#  Terraform never modifies or deletes anything referenced here.
# ============================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# --- The existing VPC ---
data "aws_vpc" "existing" {
  id = var.vpc_id
}

# --- The existing app subnets (one lookup per subnet) ---
data "aws_subnet" "app" {
  for_each = toset(var.app_subnet_ids)
  id       = each.value
}

# --- The existing ALB subnets ---
data "aws_subnet" "alb" {
  for_each = toset(var.alb_subnet_ids)
  id       = each.value
}

# --- The existing DB subnets ---
data "aws_subnet" "db" {
  for_each = toset(var.db_subnet_ids)
  id       = each.value
}

# --- The existing security groups ---
data "aws_security_group" "alb" {
  for_each = toset(var.alb_security_group_ids)
  id       = each.value
}

data "aws_security_group" "app" {
  for_each = toset(var.app_security_group_ids)
  id       = each.value
}

data "aws_security_group" "db" {
  for_each = toset(var.db_security_group_ids)
  id       = each.value
}

# --- Latest Amazon Linux 2023 AMI ---
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ============================================================
#  DERIVED VALUES
# ============================================================

locals {
  name = "${var.project_name}-${var.environment}"

  # Unique AZs covered by each subnet set
  app_azs = distinct([for s in data.aws_subnet.app : s.availability_zone])
  alb_azs = distinct([for s in data.aws_subnet.alb : s.availability_zone])
  db_azs  = distinct([for s in data.aws_subnet.db : s.availability_zone])

  # Whether the ALB subnets auto-assign public IPs (a proxy for "public subnet")
  alb_subnets_are_public = alltrue([for s in data.aws_subnet.alb : s.map_public_ip_on_launch])

  # Should we create a DB subnet group, or reuse an existing one?
  create_db_subnet_group = var.db_subnet_group_name == ""

  # Are we doing real HTTPS?
  enable_https = var.acm_certificate_arn != "" && var.acm_certificate_arn != "REPLACE_ME_ACM_CERT_ARN"

  # Effective hostname used by Keycloak
  effective_hostname = (
    var.keycloak_hostname != "" && var.keycloak_hostname != "REPLACE_ME_HOSTNAME"
    ? var.keycloak_hostname
    : aws_lb.keycloak.dns_name
  )
}

# ============================================================
#  SAFETY ASSERTIONS — fail fast if the network is wrong
# ============================================================

check "subnets_belong_to_vpc" {
  assert {
    condition     = alltrue([for s in data.aws_subnet.app : s.vpc_id == var.vpc_id])
    error_message = "One or more app_subnet_ids are not in vpc_id ${var.vpc_id}."
  }

  assert {
    condition     = alltrue([for s in data.aws_subnet.alb : s.vpc_id == var.vpc_id])
    error_message = "One or more alb_subnet_ids are not in vpc_id ${var.vpc_id}."
  }

  assert {
    condition     = alltrue([for s in data.aws_subnet.db : s.vpc_id == var.vpc_id])
    error_message = "One or more db_subnet_ids are not in vpc_id ${var.vpc_id}."
  }
}

check "multi_az_coverage" {
  assert {
    condition     = length(local.app_azs) >= 2
    error_message = "app_subnet_ids must span at least 2 AZs. Found: ${join(", ", local.app_azs)}"
  }

  assert {
    condition     = length(local.alb_azs) >= 2
    error_message = "alb_subnet_ids must span at least 2 AZs (ALB requirement). Found: ${join(", ", local.alb_azs)}"
  }

  assert {
    condition     = length(local.db_azs) >= 2
    error_message = "db_subnet_ids must span at least 2 AZs (RDS requirement). Found: ${join(", ", local.db_azs)}"
  }
}

check "security_groups_belong_to_vpc" {
  assert {
    condition     = alltrue([for sg in data.aws_security_group.app : sg.vpc_id == var.vpc_id])
    error_message = "One or more app_security_group_ids are not in vpc_id ${var.vpc_id}."
  }

  assert {
    condition     = alltrue([for sg in data.aws_security_group.alb : sg.vpc_id == var.vpc_id])
    error_message = "One or more alb_security_group_ids are not in vpc_id ${var.vpc_id}."
  }
}

check "sufficient_free_ips" {
  assert {
    condition     = alltrue([for s in data.aws_subnet.app : s.available_ip_address_count >= 4])
    error_message = "Each app subnet needs at least 4 free IPs for scaling headroom."
  }
}

check "alb_scheme_matches_subnets" {
  assert {
    condition     = var.internal_alb || local.alb_subnets_are_public
    error_message = "An internet-facing ALB needs PUBLIC subnets. Either set internal_alb = true, or supply public subnets in alb_subnet_ids."
  }
}
```

**What is a `check` block?** Introduced in Terraform 1.5, `check` blocks validate assumptions during `plan` and `apply`. Unlike `validation` inside a variable (which only sees that variable), a `check` can compare *looked-up* data. Failed assertions produce warnings rather than hard errors — but they surface exactly what's wrong, immediately.

**Why `for_each` on data blocks instead of `count`?** With `for_each` keyed by subnet ID, reordering the list doesn't shuffle Terraform's internal addresses. With `count`, swapping two subnets in your list would make Terraform think both changed.

### Step 7: Optional — Manage Rules on Existing Security Groups

If your team owns the security groups, skip this. If you're allowed to add rules, create `security-rules.tf`:

```hcl
# ============================================================
#  OPTIONAL: add required rules to EXISTING security groups.
#  Terraform manages ONLY these rules — not the groups themselves.
#  Enable with manage_security_group_rules = true
# ============================================================

locals {
  primary_alb_sg = var.alb_security_group_ids[0]
  primary_app_sg = var.app_security_group_ids[0]
  primary_db_sg  = var.db_security_group_ids[0]
}

# ALB -> Keycloak application port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb_8080" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id            = local.primary_app_sg
  description                  = "[terraform:${local.name}] Keycloak HTTP from ALB"
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.primary_alb_sg

  tags = { Name = "${local.name}-app-from-alb-8080" }
}

# ALB -> Keycloak management/health port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb_9000" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id            = local.primary_app_sg
  description                  = "[terraform:${local.name}] Health checks from ALB"
  from_port                    = 9000
  to_port                      = 9000
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.primary_alb_sg

  tags = { Name = "${local.name}-app-from-alb-9000" }
}

# Keycloak <-> Keycloak cluster discovery (JGroups)
resource "aws_vpc_security_group_ingress_rule" "app_cluster_7800" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id            = local.primary_app_sg
  description                  = "[terraform:${local.name}] JGroups cluster traffic"
  from_port                    = 7800
  to_port                      = 7800
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.primary_app_sg

  tags = { Name = "${local.name}-app-cluster-7800" }
}

# Keycloak -> RDS
resource "aws_vpc_security_group_ingress_rule" "db_from_app_5432" {
  count = var.manage_security_group_rules ? 1 : 0

  security_group_id            = local.primary_db_sg
  description                  = "[terraform:${local.name}] PostgreSQL from Keycloak"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = local.primary_app_sg

  tags = { Name = "${local.name}-db-from-app-5432" }
}
```

**Why prefix descriptions with `[terraform:...]`?** When your network team audits the security group, they can instantly see which rules are Terraform-managed and which are hand-made. Without this, someone will eventually delete a rule Terraform depends on.

**Why `aws_vpc_security_group_ingress_rule` and not an inline `ingress` block?** Inline blocks make Terraform take ownership of *every* rule in the group — it would delete your team's existing rules on the next apply. Standalone rule resources manage exactly one rule each and leave the rest alone. **This distinction is critical when working with shared security groups.**

### Step 8: The Database

Create `database.tf`:

```hcl
# --- Generate a strong random password ---
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"  # avoid chars that break JDBC URLs
}

# --- Store credentials in Secrets Manager ---
resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "${local.name}-db-credentials-"
  description             = "Keycloak database credentials (${local.name})"
  kms_key_id              = var.kms_key_arn != "" ? var.kms_key_arn : null
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
    engine   = "postgres"
  })
}

# --- DB subnet group: create one, OR reuse an existing one ---
resource "aws_db_subnet_group" "keycloak" {
  count = local.create_db_subnet_group ? 1 : 0

  name_prefix = "${local.name}-"
  description = "Keycloak DB subnet group (${local.name})"
  subnet_ids  = var.db_subnet_ids   # EXISTING subnets

  tags = { Name = "${local.name}-db-subnet-group" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- The RDS instance ---
resource "aws_db_instance" "keycloak" {
  identifier_prefix = "${local.name}-"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null

  db_name  = "keycloak"
  username = "keycloak"
  password = random_password.db.result

  # ---- EXISTING NETWORK REFERENCES ----
  db_subnet_group_name = (
    local.create_db_subnet_group
    ? aws_db_subnet_group.keycloak[0].name
    : var.db_subnet_group_name
  )
  vpc_security_group_ids = var.db_security_group_ids   # EXISTING SGs
  publicly_accessible    = false
  # -------------------------------------

  multi_az                  = var.environment == "prod"
  backup_retention_period   = var.environment == "prod" ? 30 : 1
  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"

  auto_minor_version_upgrade   = true
  performance_insights_enabled = true
  copy_tags_to_snapshot        = true

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "${local.name}-db" }
}
```

**Why PostgreSQL?** Keycloak officially supports PostgreSQL, MySQL, MariaDB, Oracle, and MS SQL Server. PostgreSQL is the most commonly used and best-tested option, and it's what Keycloak's own documentation uses in examples.

**Why `random_password` + Secrets Manager?** Hardcoding passwords in `.tf` files means they end up in Git. Terraform generates one, stores it encrypted, and the instance fetches it at boot using its IAM role. No human ever types it.

**Caveat:** The generated password *does* appear in `terraform.tfstate`. Always use an encrypted S3 backend with restricted access — never commit state to Git.

**Reusing an existing DB subnet group:** If your org maintains a shared one, set `db_subnet_group_name = "REPLACE_ME_DB_SUBNET_GROUP"` and Terraform will reference it instead of creating one. It must contain subnets in at least 2 AZs within your VPC.

### Step 9: IAM Role

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
  description        = "Instance role for Keycloak (${local.name})"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  # Many enterprises REQUIRE a permissions boundary on every role
  permissions_boundary = var.iam_permissions_boundary_arn != "" ? var.iam_permissions_boundary_arn : null
}

# Session Manager shell access — replaces SSH entirely
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch agent for logs and metrics
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Least privilege: read ONLY this deployment's DB secret
data "aws_iam_policy_document" "secrets" {
  statement {
    sid       = "ReadKeycloakDatabaseSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }

  # Only needed if you use a customer-managed KMS key
  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid       = "DecryptWithProvidedKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]
    }
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

  lifecycle {
    create_before_destroy = true
  }
}
```

**Least privilege:** The secrets policy names one specific ARN, not `"*"`. If this instance is ever compromised, the attacker reads one secret — not every secret in your account.

**Permissions boundary:** If your organization requires one, set `iam_permissions_boundary_arn`. Without it, role creation will be denied by an SCP or IAM policy, often with an unhelpful error.

**Using `data.aws_partition`:** This makes the ARNs work in GovCloud (`aws-us-gov`) and China (`aws-cn`) partitions, not just commercial AWS.

### Step 10: The User Data Script

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

# --- 2. Dedicated non-root service account ---
useradd -r -m -U -d /opt/keycloak -s /sbin/nologin keycloak || true

# --- 3. Download and install Keycloak ---
KC_VERSION="${keycloak_version}"
cd /tmp
curl -fsSL --retry 5 --retry-delay 5 -o keycloak.tar.gz \
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
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

hostname=${keycloak_hostname}
hostname-strict=${hostname_strict}
proxy-headers=xforwarded

http-enabled=true
http-port=8080

health-enabled=true
metrics-enabled=true

cache=ispn
cache-stack=jdbc-ping

log=console
log-console-output=json
log-level=INFO
EOF

chmod 600 /opt/keycloak/conf/keycloak.conf
chown keycloak:keycloak /opt/keycloak/conf/keycloak.conf

# --- 6. Build the optimized image (pre-compiles config for fast startup) ---
sudo -u keycloak /opt/keycloak/bin/kc.sh build

# --- 7. systemd service ---
cat > /etc/systemd/system/keycloak.service <<'UNIT'
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

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/keycloak/data /opt/keycloak/conf

[Install]
WantedBy=multi-user.target
UNIT

# --- 8. Bootstrap admin (first boot only) ---
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

# --- 9. Start ---
systemctl daemon-reload
systemctl enable --now keycloak

# --- 10. Wait for readiness ---
for i in {1..60}; do
  if curl -sf http://localhost:9000/health/ready > /dev/null 2>&1; then
    echo "=== Keycloak is READY at $(date) ==="
    exit 0
  fi
  echo "Waiting for Keycloak... attempt $i/60"
  sleep 10
done

echo "=== ERROR: Keycloak failed to become ready ==="
journalctl -u keycloak --no-pager -n 200
exit 1
```

**Critical syntax note:** This is a Terraform *template* file. Terraform substitutes `${keycloak_version}` with your variable. But bash *also* uses `${...}`. To write a literal bash variable, escape it as `$${VAR}`. **This is the number one cause of user data failures.**

**Why `set -euxo pipefail`?**
- `-e` — stop on any error
- `-u` — error on undefined variables
- `-x` — print each command (great for the log)
- `-o pipefail` — catch errors inside pipelines

**Why `exec > >(tee ...)`?** It captures all output to `/var/log/user-data.log`. When something goes wrong, that file is your first stop.

**Version note:** Keycloak 26+ renamed the bootstrap admin variables. The old `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` are deprecated in favor of `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`. Keycloak 26 also requires **Java 21**.

### Step 11: Launch Template and Auto Scaling Group

Create `compute.tf`:

```hcl
resource "random_password" "admin" {
  length  = 24
  special = false  # avoids shell-escaping headaches in systemd
}

resource "aws_secretsmanager_secret" "admin" {
  name_prefix             = "${local.name}-admin-credentials-"
  description             = "Keycloak bootstrap admin (${local.name}) - DELETE THIS ACCOUNT AFTER SETUP"
  kms_key_id              = var.kms_key_arn != "" ? var.kms_key_arn : null
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    username = "kcadmin"
    password = random_password.admin.result
  })
}

# ============================================================
#  THE LAUNCH TEMPLATE
# ============================================================
resource "aws_launch_template" "keycloak" {
  name_prefix            = "${local.name}-"
  description            = "Keycloak ${var.keycloak_version} on Amazon Linux 2023"
  image_id               = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.keycloak.arn
  }

  # ---- EXISTING SECURITY GROUPS ----
  # Note: use vpc_security_group_ids OR network_interfaces, never both.
  vpc_security_group_ids = var.app_security_group_ids
  # ----------------------------------

  # The boot script, base64 encoded
  user_data = base64encode(templatefile("${path.module}/user-data.sh.tftpl", {
    keycloak_version  = var.keycloak_version
    db_secret_arn     = aws_secretsmanager_secret.db.arn
    aws_region        = var.aws_region
    keycloak_hostname = local.effective_hostname
    hostname_strict   = local.enable_https ? "true" : "false"
    admin_username    = "kcadmin"
    admin_password    = random_password.admin.result
  }))

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      throughput            = 125
      iops                  = 3000
      encrypted             = true
      kms_key_id            = var.kms_key_arn != "" ? var.kms_key_arn : null
      delete_on_termination = true
    }
  }

  # IMDSv2 required — blocks SSRF-based credential theft
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

  tag_specifications {
    resource_type = "network-interface"
    tags = { Name = "${local.name}-eni" }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_db_instance.keycloak]
}

# ============================================================
#  AUTO SCALING GROUP — placed in EXISTING subnets
# ============================================================
resource "aws_autoscaling_group" "keycloak" {
  name_prefix = "${local.name}-asg-"

  # ---- EXISTING SUBNETS ----
  vpc_zone_identifier = var.app_subnet_ids
  # --------------------------

  target_group_arns = [aws_lb_target_group.keycloak.arn]

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

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
    # Uncomment if an external autoscaler adjusts capacity
    # ignore_changes = [desired_capacity]
  }
}
```

**What is `instance_refresh`?** When you change the launch template (new Keycloak version, new AMI), the ASG replaces running instances in batches, keeping at least 50% healthy. No downtime, no manual work.

**What is IMDSv2?** The Instance Metadata Service lets an instance ask "what IAM role do I have?" Version 1 answered any HTTP request — so a server-side request forgery bug in your app could leak credentials. **IMDSv2 requires a session token first**, blocking that attack. `http_tokens = "required"` is now the AWS-recommended default.

### Step 12: Load Balancer

Create `loadbalancer.tf`:

```hcl
resource "aws_lb" "keycloak" {
  name_prefix        = "kc-"
  load_balancer_type = "application"
  internal           = var.internal_alb

  # ---- EXISTING SUBNETS AND SECURITY GROUPS ----
  subnets         = var.alb_subnet_ids
  security_groups = var.alb_security_group_ids
  # ----------------------------------------------

  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true
  idle_timeout               = 300

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "keycloak" {
  name_prefix = "kc-"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"

  # ---- EXISTING VPC ----
  vpc_id = var.vpc_id
  # ----------------------

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

  # Sticky sessions smooth out multi-step login flows
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

# --- HTTPS listener (when an ACM cert is supplied) ---
resource "aws_lb_listener" "https" {
  count = local.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.keycloak.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn   # EXISTING certificate

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}

# --- HTTP listener: redirect to HTTPS if we have a cert, else forward ---
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.keycloak.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.enable_https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.enable_https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.keycloak.arn
    }
  }
}
```

**Health check on port 9000?** Keycloak 25+ moved health and metrics endpoints to a separate management port so you don't expose them publicly. The target group checks 9000 for health but forwards real traffic to 8080. Your app security group must allow both from the ALB.

**`internal = var.internal_alb`:** Many enterprise deployments put Keycloak behind an internal ALB reached via VPN or Direct Connect. Set `internal_alb = true` and supply private subnets.

### Step 13: DNS Record

Create `dns.tf`:

```hcl
resource "aws_route53_record" "keycloak" {
  count = (var.route53_zone_id != "" && var.route53_zone_id != "REPLACE_ME_ROUTE53_ZONE_ID") ? 1 : 0

  # ---- EXISTING HOSTED ZONE ----
  zone_id = var.route53_zone_id
  # ------------------------------

  name = var.keycloak_hostname
  type = "A"

  alias {
    name                   = aws_lb.keycloak.dns_name
    zone_id                = aws_lb.keycloak.zone_id
    evaluate_target_health = true
  }
}
```

If DNS is managed outside AWS, leave `route53_zone_id = ""` and create a CNAME manually pointing at the ALB DNS name from the outputs.

### Step 14: Outputs

Create `outputs.tf`:

```hcl
output "keycloak_url" {
  description = "URL to reach Keycloak"
  value       = local.enable_https ? "https://${local.effective_hostname}" : "http://${aws_lb.keycloak.dns_name}"
}

output "admin_console_url" {
  description = "Keycloak admin console"
  value       = "${local.enable_https ? "https://${local.effective_hostname}" : "http://${aws_lb.keycloak.dns_name}"}/admin"
}

output "alb_dns_name" {
  description = "Raw ALB DNS name — point your external CNAME here"
  value       = aws_lb.keycloak.dns_name
}

output "get_admin_password_command" {
  description = "Run this to retrieve the bootstrap admin credentials"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.admin.id} --region ${var.aws_region} --query SecretString --output text | jq ."
}

output "database_endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.keycloak.address
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.keycloak.id
}

output "autoscaling_group_name" {
  description = "ASG name"
  value       = aws_autoscaling_group.keycloak.name
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.keycloak.arn
}

# --- Confirmation that we referenced, not created, the network ---
output "existing_network_referenced" {
  description = "Existing resources this deployment consumes (NOT managed by Terraform)"
  value = {
    vpc_id      = data.aws_vpc.existing.id
    vpc_cidr    = data.aws_vpc.existing.cidr_block
    app_subnets = { for id, s in data.aws_subnet.app : id => s.availability_zone }
    alb_subnets = { for id, s in data.aws_subnet.alb : id => s.availability_zone }
    db_subnets  = { for id, s in data.aws_subnet.db : id => s.availability_zone }
    app_sgs     = var.app_security_group_ids
    alb_sgs     = var.alb_security_group_ids
    db_sgs      = var.db_security_group_ids
  }
}
```

### Step 15: Fill In Your Values

Create `example.tfvars` (safe to commit — it's all stubs):

```hcl
# ============================================================
#  COPY THIS TO terraform.tfvars AND REPLACE EVERY VALUE
# ============================================================

aws_region      = "REPLACE_ME_AWS_REGION"       # e.g. "us-east-1"
environment     = "dev"
project_name    = "keycloak"
owner_tag       = "REPLACE_ME_OWNER"            # e.g. "platform-team"
cost_center_tag = "REPLACE_ME_COST_CENTER"      # e.g. "CC-1234"

# ---------- EXISTING NETWORK (Terraform reads only) ----------
vpc_id = "REPLACE_ME_VPC_ID"                    # e.g. "vpc-0a1b2c3d4e5f67890"

app_subnet_ids = [
  "REPLACE_ME_APP_SUBNET_1",                    # private, AZ-a
  "REPLACE_ME_APP_SUBNET_2",                    # private, AZ-b
]

alb_subnet_ids = [
  "REPLACE_ME_ALB_SUBNET_1",                    # public (or private if internal_alb)
  "REPLACE_ME_ALB_SUBNET_2",
]

db_subnet_ids = [
  "REPLACE_ME_DB_SUBNET_1",
  "REPLACE_ME_DB_SUBNET_2",
]

# Reuse a shared RDS subnet group instead of creating one.
# Leave "" to have Terraform create one from db_subnet_ids.
db_subnet_group_name = ""                       # or "REPLACE_ME_DB_SUBNET_GROUP"

# ---------- EXISTING SECURITY GROUPS ----------
alb_security_group_ids = ["REPLACE_ME_ALB_SG_ID"]
app_security_group_ids = ["REPLACE_ME_APP_SG_ID"]
db_security_group_ids  = ["REPLACE_ME_DB_SG_ID"]

# Set true ONLY if you're allowed to add rules to those SGs
manage_security_group_rules = false

# ---------- EXISTING DNS / TLS / KMS ----------
acm_certificate_arn = "REPLACE_ME_ACM_CERT_ARN"     # "" for HTTP-only dev
route53_zone_id     = "REPLACE_ME_ROUTE53_ZONE_ID"  # "" to skip DNS
keycloak_hostname   = "REPLACE_ME_HOSTNAME"         # e.g. "auth.example.com"
kms_key_arn         = ""                            # "" = AWS-managed keys

# Required by some orgs on every IAM role
iam_permissions_boundary_arn = ""               # or "REPLACE_ME_PERMISSIONS_BOUNDARY_ARN"

# ---------- APPLICATION ----------
keycloak_version     = "26.4.0"
instance_type        = "t3.medium"
asg_min_size         = 1
asg_max_size         = 2
asg_desired_capacity = 1
internal_alb         = false

db_instance_class    = "db.t4g.micro"
db_engine_version    = "16.4"
db_allocated_storage = 20
```

Copy and edit:

```bash
cp example.tfvars terraform.tfvars
# now edit terraform.tfvars with your real values
```

Create `.gitignore`:

```gitignore
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
*.tfvars
!example.tfvars
crash.log
tfplan
plan.json
```

### Step 16: Deploy

```bash
terraform init
terraform validate
terraform fmt -recursive

# Preview. Read this carefully.
terraform plan -out=tfplan
```

**Before applying, verify the plan creates no networking.** Every network resource should be a *data source read*, never a create:

```bash
terraform show -json tfplan | jq -r '
  .resource_changes[]
  | select(.change.actions | index("create"))
  | .type' | sort -u
```

If that output contains `aws_vpc`, `aws_subnet`, `aws_security_group`, `aws_internet_gateway`, or `aws_nat_gateway`, **stop** — something is wrong and you're about to create duplicate networking.

Expected creates: `aws_launch_template`, `aws_autoscaling_group`, `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`, `aws_db_instance`, `aws_iam_role`, `aws_iam_instance_profile`, `aws_secretsmanager_secret`, `random_password`, `aws_route53_record`, and optionally `aws_db_subnet_group` and `aws_vpc_security_group_ingress_rule`.

```bash
terraform apply tfplan
```

RDS takes 10–15 minutes; instance boot takes another 5.

### Step 17: Verify

```bash
terraform output keycloak_url

# Retrieve bootstrap admin credentials
eval "$(terraform output -raw get_admin_password_command)"

# Confirm targets are healthy
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw target_group_arn)" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

Open the URL. You should see the Keycloak welcome page. Click **Administration Console** and log in.

**If it doesn't work:**

```bash
# Find the instance
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=keycloak" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Connect — no SSH key, no open port
aws ssm start-session --target $INSTANCE

# Once connected:
sudo cat /var/log/user-data.log
sudo journalctl -u keycloak -n 200 --no-pager
sudo systemctl status keycloak
curl -s localhost:9000/health/ready | jq .
```

### Step 18: Clean Up

```bash
terraform destroy
```

**This is safe.** Terraform removes only what it created — the launch template, ASG, ALB, RDS instance, IAM role, and secrets. Your **VPC, subnets, security groups, NAT gateway, KMS keys, ACM certificate, and hosted zone are untouched**, because they're `data` sources, not `resource`s.

If `manage_security_group_rules = true`, destroy also removes the four rules Terraform added — but not the security groups themselves.

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

AWS no longer adds features to Launch Configurations and has restricted creating new ones. **Always use Launch Templates.** If you find a tutorial using `aws_launch_configuration`, it's outdated.

### Every Useful Launch Template Block

```hcl
resource "aws_launch_template" "example" {
  # --- Identity ---
  name_prefix = "my-app-"        # Terraform appends a random suffix
  description = "v2.1 with new agent"

  # --- Base image ---
  image_id = data.aws_ssm_parameter.al2023.value

  # --- Size ---
  instance_type = "t3.medium"

  # --- SSH key (optional; prefer SSM Session Manager instead) ---
  # key_name = "REPLACE_ME_KEYPAIR_NAME"

  # --- Permissions ---
  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  # --- Networking, SIMPLE form: existing SGs, subnet chosen by the ASG ---
  vpc_security_group_ids = ["REPLACE_ME_APP_SG_ID"]

  # --- Networking, ADVANCED form: full ENI control ---
  # Use this OR vpc_security_group_ids — never both, it's an API error.
  # network_interfaces {
  #   device_index                = 0
  #   associate_public_ip_address = false
  #   security_groups             = ["REPLACE_ME_APP_SG_ID"]
  #   delete_on_termination       = true
  #   # Pinning a subnet here OVERRIDES the ASG's vpc_zone_identifier
  #   # and defeats multi-AZ. Usually leave it out.
  #   # subnet_id                 = "REPLACE_ME_APP_SUBNET_1"
  # }

  # --- Boot script ---
  user_data = base64encode(templatefile("init.sh.tftpl", {
    app_version = var.app_version
  }))

  # --- Storage ---
  block_device_mappings {
    device_name = "/dev/xvda"        # root volume on AL2023
    ebs {
      volume_size           = 50
      volume_type           = "gp3"   # cheaper and faster than gp2
      iops                  = 3000    # gp3 baseline, included free
      throughput            = 125     # MB/s, gp3 baseline, included free
      encrypted             = true
      kms_key_id            = "REPLACE_ME_KMS_KEY_ARN"
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
    http_put_response_hop_limit = 2            # 2 if containers need access
    instance_metadata_tags      = "enabled"
  }

  # --- Detailed CloudWatch metrics (1-min instead of 5-min) ---
  monitoring {
    enabled = true
  }

  # --- Spot configuration ---
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
    cpu_credits = "unlimited"    # for T-series burstable instances
  }

  cpu_options {
    core_count       = 2
    threads_per_core = 1         # disable hyperthreading for licensing
  }

  # --- Placement ---
  placement {
    availability_zone = "REPLACE_ME_AZ"
    tenancy           = "default"       # or "dedicated"
    group_name        = "REPLACE_ME_PLACEMENT_GROUP"
  }

  # --- Termination behavior ---
  disable_api_termination              = false
  disable_api_stop                     = false
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

> ### ⚠️ The `network_interfaces` Trap
>
> This is the single most common brownfield mistake. Two rules:
>
> 1. **Never set both `vpc_security_group_ids` and `network_interfaces`.** The AWS API rejects it with `InvalidParameterCombination`. Pick one.
> 2. **Don't put `subnet_id` inside `network_interfaces` when using an ASG.** It pins every instance to one subnet, silently defeating the ASG's `vpc_zone_identifier` and breaking multi-AZ. Let the ASG choose.
>
> Use `network_interfaces` only when you need `associate_public_ip_address`, multiple ENIs, or an Elastic Fabric Adapter.

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

**Pros:** Everything in one file, easy to see at a glance.
**Cons:** No syntax highlighting, no shellcheck, gets unwieldy fast, HCL/bash escaping is error-prone.
**Use when:** Under ~10 lines.

#### Option B: `templatefile()` — recommended

```hcl
user_data = base64encode(templatefile("${path.module}/init.sh.tftpl", {
  app_version = var.app_version
  db_host     = aws_db_instance.main.address
}))
```

**Pros:** Real bash file with editor support and shellcheck; variables injected cleanly; reviewable in isolation.
**Cons:** Must remember `$$` escaping for bash variables.
**Use when:** Almost always. This is the standard approach and what this guide uses.

#### Option C: `cloudinit_config` data source — multi-part

```hcl
data "cloudinit_config" "app" {
  gzip          = true    # beats the 16 KB limit
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

# In the launch template:
user_data = data.cloudinit_config.app.rendered
```

**Pros:** `gzip = true` compresses, letting you exceed practical size limits. Declarative package/file management. Multiple scripts combined cleanly.
**Cons:** Extra provider dependency, more concepts.
**Use when:** Your script is long, or you want declarative config alongside a shell script.

#### Option D: Bake an AMI (Packer) + minimal user data

```hcl
# AMI already contains Keycloak
user_data = base64encode(<<-EOF
  #!/bin/bash
  aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db.arn} \
    --query SecretString --output text > /opt/app/db.json
  systemctl start keycloak
EOF
)
```

**Pros:** Boot time drops from 5+ minutes to under 60 seconds. Immutable, pre-tested images. Much faster autoscaling. Works in air-gapped VPCs with no internet.
**Cons:** Requires a separate build pipeline. Extra step for every change.
**Use when:** Production, restricted networks, or anywhere boot speed matters.

### User Data Rules and Gotchas

| Rule | Detail |
|------|--------|
| **Size limit** | 16 KB *after* base64 encoding. Gzip (Option C) helps a lot. |
| **Runs as root** | No `sudo` needed. Use `sudo -u appuser` to drop privileges. |
| **Runs once by default** | Only on the *first* boot, not on reboot. |
| **Working directory** | `/` (root), not a home directory. Always use absolute paths. |
| **Minimal PATH** | Don't assume tools are on PATH; use full paths or set PATH explicitly. |
| **Log locations** | `/var/log/cloud-init-output.log`, `/var/log/cloud-init.log` |
| **Not encrypted at rest** | Anyone with `DescribeLaunchTemplateVersions` can read it. **Never put secrets in user data.** |
| **`$` escaping** | In `.tftpl` files, write `$${BASH_VAR}` for literal bash variables. |
| **Needs network** | If your subnet has no NAT and no VPC endpoints, downloads hang until timeout. |

### Making User Data Run on Every Boot

```bash
#!/bin/bash
cloud-init-per always my-task /path/to/script.sh
```

Or with cloud-config:

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
# Amazon Linux 2023, x86_64
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Amazon Linux 2023, ARM (Graviton — roughly 20% cheaper)
data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Ubuntu 24.04 LTS
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
```

**Using an approved internal AMI (very common in enterprises):**

```hcl
variable "custom_ami_id" {
  description = "Approved hardened AMI. Leave empty to use latest AL2023."
  type        = string
  default     = ""   # or "REPLACE_ME_GOLDEN_AMI_ID"
}

# Or find the newest one your platform team published, by tag
data "aws_ami" "golden" {
  count       = var.custom_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["REPLACE_ME_AMI_OWNER_ACCOUNT_ID"]

  filter {
    name   = "tag:Approved"
    values = ["true"]
  }
  filter {
    name   = "name"
    values = ["REPLACE_ME_AMI_NAME_PREFIX-*"]
  }
}

locals {
  ami_id = var.custom_ami_id != "" ? var.custom_ami_id : (
    length(data.aws_ami.golden) > 0
      ? data.aws_ami.golden[0].id
      : data.aws_ssm_parameter.al2023.value
  )
}
```

**Trade-off:** `most_recent = true` means a new AMI release triggers instance replacement on your next apply. Great for staying patched, occasionally surprising. For production, consider pinning a specific AMI ID and bumping it deliberately.

### Launch Template Versioning

```hcl
resource "aws_launch_template" "app" {
  # ...
  update_default_version = true   # new version becomes the default
}

resource "aws_autoscaling_group" "app" {
  launch_template {
    id = aws_launch_template.app.id

    # Pick ONE:
    version = aws_launch_template.app.latest_version  # always newest
    # version = "$Latest"    # AWS resolves at launch time
    # version = "$Default"   # uses whatever is marked default
    # version = "3"          # pinned to an exact version
  }
}
```

| Setting | Behavior | Best for |
|---------|----------|----------|
| `latest_version` (Terraform attribute) | Terraform sees the change and can trigger instance refresh | Most cases |
| `"$Latest"` | AWS picks newest at launch; Terraform doesn't detect changes | Manual control |
| `"$Default"` | Uses the marked-default version | Blue/green style rollouts |
| `"3"` | Frozen | Compliance, rollback |

**Rolling back:**

```bash
# List versions
aws ec2 describe-launch-template-versions \
  --launch-template-id REPLACE_ME_LAUNCH_TEMPLATE_ID \
  --query 'LaunchTemplateVersions[].[VersionNumber,DefaultVersion,VersionDescription]' \
  --output table

# Make version 3 the default again
aws ec2 modify-launch-template \
  --launch-template-id REPLACE_ME_LAUNCH_TEMPLATE_ID \
  --default-version 3

# Force the ASG to replace instances with it
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name REPLACE_ME_ASG_NAME \
  --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":600}'
```

### Mixed Instances with Spot (Cost Saving)

```hcl
resource "aws_autoscaling_group" "app" {
  name_prefix         = "app-"
  vpc_zone_identifier = var.app_subnet_ids   # EXISTING subnets
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

**Spot instances cost up to 90% less** but AWS can reclaim them with two minutes' notice. `price-capacity-optimized` is the current recommended strategy — it balances price against interruption risk.

**For Keycloak specifically:** Spot is risky for the primary tier, because losing a node mid-login disrupts users. Use on-demand for base capacity and spot only for burst above it.

### Attribute-Based Instance Selection

Instead of listing instance types, describe requirements:

```hcl
mixed_instances_policy {
  launch_template {
    launch_template_specification {
      launch_template_id = aws_launch_template.app.id
    }

    override {
      instance_requirements {
        vcpu_count            { min = 2, max = 8 }
        memory_mib            { min = 4096 }
        cpu_manufacturers     = ["intel", "amd"]
        burstable_performance = "included"
      }
    }
  }
}
```

AWS picks whatever matches, automatically including instance types released after you wrote the code.

---

## Part 3: Working With Existing Infrastructure

### The Golden Rule

> **`data` = read, never touch. `resource` = Terraform owns it and will delete it on destroy.**

If you accidentally write `resource "aws_vpc"` instead of `data "aws_vpc"`, Terraform will create a *second* VPC. Worse, if you *import* an existing VPC into a `resource` block, `terraform destroy` will delete your company's network. Keep every pre-existing network object in a `data` block.

### Discovering Subnets by Tag

Hardcoding subnet IDs is explicit and safe, but tedious across environments. If your org tags subnets consistently, discover them instead:

```hcl
variable "subnet_tier_tag_key" {
  description = "Tag key used to classify subnets, e.g. 'Tier'"
  type        = string
  default     = "REPLACE_ME_TIER_TAG_KEY"     # e.g. "Tier"
}

variable "app_subnet_tier_value" {
  description = "Tag value marking application subnets"
  type        = string
  default     = "REPLACE_ME_APP_TIER_VALUE"   # e.g. "private-app"
}

data "aws_subnets" "app" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = {
    (var.subnet_tier_tag_key) = var.app_subnet_tier_value
  }
}

# Then use: data.aws_subnets.app.ids
```

| Approach | Pros | Cons |
|----------|------|------|
| **Explicit IDs** | Deterministic, obvious in code review, no surprises | Different value per environment; tedious |
| **Tag discovery** | Same code across all environments; auto-picks up new subnets | Silently changes if someone retags; a new subnet can trigger unexpected changes |
| **Remote state lookup** | Single source of truth, type-safe | Couples your state to the network team's state file |

**Recommendation:** Explicit IDs for production. Tag discovery for dev and ephemeral environments.

### Reading From the Network Team's Remote State

If the network team also uses Terraform and publishes outputs:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "REPLACE_ME_NETWORK_STATE_BUCKET"
    key    = "REPLACE_ME_NETWORK_STATE_KEY"    # e.g. "network/prod/terraform.tfstate"
    region = "REPLACE_ME_AWS_REGION"
  }
}

locals {
  vpc_id         = data.terraform_remote_state.network.outputs.vpc_id
  app_subnet_ids = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  app_sg_ids     = [data.terraform_remote_state.network.outputs.app_security_group_id]
}
```

**Pros:** Authoritative, no copy-paste drift, self-documenting.
**Cons:** Needs read access to their state bucket; their output renames break you; tight coupling between teams.

### Security Group Strategies Compared

#### Option A: Existing SGs, rules managed externally (default in this guide)

```hcl
vpc_security_group_ids = var.app_security_group_ids
```

**Pros:** Zero risk of Terraform touching shared rules; matches most enterprise separation of duties.
**Cons:** You depend on another team to make changes; deployment fails opaquely if a rule is missing.

#### Option B: Existing SGs, Terraform-managed rules

```hcl
resource "aws_vpc_security_group_ingress_rule" "app_from_alb_8080" {
  security_group_id            = var.app_security_group_ids[0]
  referenced_security_group_id = var.alb_security_group_ids[0]
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "[terraform] Keycloak from ALB"
}
```

**Pros:** Self-service; rules live next to the app code that needs them.
**Cons:** Requires permission to modify shared SGs; conflicts if someone edits the same rule by hand.

> **Never do this with an existing shared SG:**
> ```hcl
> resource "aws_security_group" "existing" {   # <-- WRONG
>   ingress { ... }
> }
> ```
> An inline `ingress` block makes Terraform believe it owns *every* rule in the group. On the next apply it will delete every rule it doesn't know about.

#### Option C: New dedicated SG inside the existing VPC

```hcl
resource "aws_security_group" "keycloak" {
  name_prefix = "${local.name}-"
  description = "Keycloak instances (${local.name})"
  vpc_id      = var.vpc_id   # EXISTING VPC

  lifecycle { create_before_destroy = true }
}
```

**Pros:** Full self-service, clean lifecycle, `destroy` cleans it up.
**Cons:** Needs `ec2:CreateSecurityGroup`; adds to the per-VPC SG quota; some orgs forbid it outright.

**Recommendation:** Option C when allowed — it gives clean ownership boundaries. Option A when the platform team requires central control.

### Adopting Resources You Already Created by Hand

If a Keycloak launch template or ALB already exists from manual work, import it rather than duplicating:

```bash
# Terraform 1.5+ — declarative import blocks (preferred)
cat >> imports.tf <<'EOF'
import {
  to = aws_launch_template.keycloak
  id = "REPLACE_ME_LAUNCH_TEMPLATE_ID"
}

import {
  to = aws_lb.keycloak
  id = "REPLACE_ME_ALB_ARN"
}
EOF

# Generate matching HCL automatically
terraform plan -generate-config-out=generated.tf

# Review generated.tf carefully, merge into your real files, then:
terraform apply
```

**Never import the VPC, subnets, or security groups** unless your team genuinely owns them. Once imported, they're deletable by `terraform destroy`.

### Air-Gapped Environments

If the app subnets have no internet route at all:

1. **Mirror the Keycloak tarball** to an internal S3 bucket or artifact repo. Change the user data:
   ```bash
   aws s3 cp s3://REPLACE_ME_ARTIFACT_BUCKET/keycloak-$${KC_VERSION}.tar.gz /tmp/
   ```
   Add an S3 gateway VPC endpoint and grant the instance role `s3:GetObject` on that prefix.

2. **Point `dnf` at an internal mirror** by templating `/etc/yum.repos.d/`.

3. **Add interface VPC endpoints** for `ssm`, `ssmmessages`, `ec2messages`, `secretsmanager`, and `logs`.

4. **Better: bake an AMI** (Option D above) so nothing is downloaded at boot at all.

### Multi-Account Deployments

If the VPC lives in a shared networking account (common with AWS RAM shared subnets):

```hcl
provider "aws" {
  alias  = "workload"
  region = var.aws_region
  assume_role {
    role_arn = "REPLACE_ME_WORKLOAD_ROLE_ARN"
  }
}

provider "aws" {
  alias  = "network"
  region = var.aws_region
  assume_role {
    role_arn = "REPLACE_ME_NETWORK_READONLY_ROLE_ARN"
  }
}

# Read the shared subnet from the networking account
data "aws_subnet" "app" {
  provider = aws.network
  for_each = toset(var.app_subnet_ids)
  id       = each.value
}

# But create resources in the workload account
resource "aws_launch_template" "keycloak" {
  provider = aws.workload
  # ...
}
```

**Note on RAM-shared subnets:** With VPC sharing, the participant account can launch instances into shared subnets but **cannot** create or modify security groups there. You must reference SGs shared from the owner account. This makes Option A the only choice.

### Brownfield Pre-Flight Checklist

- [ ] Every `REPLACE_ME_*` stub replaced with a real value
- [ ] `terraform plan` shows zero `aws_vpc` / `aws_subnet` / `aws_security_group` creates
- [ ] All subnets confirmed to be in the stated VPC (the `check` blocks verify this)
- [ ] App, ALB, and DB subnets each span at least 2 AZs
- [ ] App subnets have outbound internet (NAT) or the required VPC endpoints
- [ ] VPC has `enableDnsSupport` and `enableDnsHostnames` both true
- [ ] Enough free IPs in each app subnet for max ASG size plus headroom
- [ ] Required security group rules exist (run `check-sg-rules.sh`)
- [ ] ACM certificate is in the **same region** as the ALB and is `ISSUED`
- [ ] IAM permissions boundary supplied if your org mandates one
- [ ] Required org tags (`Owner`, `CostCenter`) populated
- [ ] Confirmed you may create IAM roles in this account
- [ ] Confirmed whether an RDS subnet group should be reused or created
- [ ] Internal vs internet-facing ALB decision matches the subnets you supplied

---

## Part 4: Options Compared

### Where to Run Keycloak on AWS

#### Option 1: EC2 + Auto Scaling Group (this guide)

**Pros**
- Full control over the OS and JVM tuning
- Straightforward to debug — it's just a Linux box
- Easy to attach EBS volumes for custom providers and themes
- No container or Kubernetes knowledge required
- Reserved Instances and Savings Plans give predictable discounts
- Works with hardened corporate AMIs

**Cons**
- You patch the OS
- Slower scaling (minutes, not seconds)
- More Terraform to maintain
- You manage the Java runtime

**Best for:** Teams without Kubernetes, moderate scale, need for OS-level customization or compliance-mandated base images.

#### Option 2: ECS Fargate

**Pros**
- No servers to patch — AWS runs the infrastructure
- Fast scaling
- Official Keycloak container image
- Simpler Terraform than EKS
- Pay per second of vCPU and memory
- Slots neatly into existing VPCs (tasks use your subnets and SGs)

**Cons**
- Less control over the runtime
- Cold starts on scale-out
- Debugging requires ECS Exec setup
- Can cost more than EC2 at steady high utilization

**Best for:** Teams wanting managed infrastructure without Kubernetes complexity.

#### Option 3: EKS (Kubernetes)

**Pros**
- The **Keycloak Operator** handles upgrades, scaling, and config declaratively
- Best clustering support via KUBE_PING
- Fits existing Kubernetes platforms
- Rich ecosystem (cert-manager, external-secrets, etc.)

**Cons**
- Steepest learning curve
- EKS control plane costs roughly $73/month before any workloads
- Significant operational overhead
- Overkill for one application

**Best for:** Organizations already running Kubernetes.

#### Option 4: Amazon Cognito (not Keycloak)

**Pros**
- Fully managed, near-zero ops
- Deep AWS integration (API Gateway, ALB, AppSync)
- Generous free tier
- Scales automatically

**Cons**
- Far less flexible than Keycloak
- Limited theming and custom authentication flows
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
| Fits existing VPC | Easy | Easy | Moderate | N/A |

### Database Choices

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **RDS PostgreSQL** | Well-tested, cheap, simple, Multi-AZ | Manual instance sizing | **Recommended default** |
| **Aurora PostgreSQL** | Failover in seconds, storage auto-scales, up to 15 read replicas | Roughly 20% more expensive, more complex | Best for production HA |
| **Aurora Serverless v2** | Scales down to 0.5 ACU, pay for use | Scale-up latency, can cost more under steady load | Good for dev or spiky load |
| **Existing shared RDS cluster** | No new database cost; DBA team already operates it | Noisy-neighbor risk; schema migrations need coordination | Viable if the DBA team agrees |
| **RDS MySQL** | Supported | Less common with Keycloak, fewer community examples | Only if mandated |
| **Self-managed on EC2** | Cheapest raw cost | You own backups, patching, failover | Not recommended |

**Reusing an existing database server:** Keycloak needs its own schema, not necessarily its own instance. Point `db-url` at the shared endpoint with a dedicated database and user. Skip the `aws_db_instance` resource entirely and pass connection details in as variables.

### Handling HTTPS

| Option | Pros | Cons |
|--------|------|------|
| **ALB + existing ACM certificate** | Free certs, auto-renewal, offloads TLS | Cert must be in the same region as the ALB |
| **Existing shared ALB, new listener rule** | No new ALB cost; one entry point | Coupled to another team's ALB; host-header routing needed |
| **TLS terminated on Keycloak** | End-to-end encryption | Manual cert management, more instance CPU |
| **CloudFront + ALB** | Global edge, AWS Shield DDoS protection | Extra cost; caching needs care with auth flows |

**Recommended:** ALB with an existing ACM certificate. Add instance-level TLS only if compliance demands end-to-end encryption.

**Attaching to a shared ALB instead of creating one:**

```hcl
data "aws_lb_listener" "shared_https" {
  arn = "REPLACE_ME_SHARED_HTTPS_LISTENER_ARN"
}

resource "aws_lb_listener_rule" "keycloak" {
  listener_arn = data.aws_lb_listener.shared_https.arn
  priority     = 100   # must be unique on that listener

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }

  condition {
    host_header {
      values = [var.keycloak_hostname]
    }
  }
}
```

This saves roughly $18/month and one more thing to operate, at the cost of coupling to another team's load balancer.

### Clustering / Cache Stack

Keycloak uses Infinispan for its distributed cache. The discovery mechanism matters:

| Stack | How it works | Pros | Cons |
|-------|-------------|------|------|
| `jdbc-ping` | Nodes register themselves in a DB table | No extra infrastructure, works in any VPC, **recommended for EC2** | Slight DB load |
| `kubernetes` (KUBE_PING) | Uses the Kubernetes API | Native on EKS | Kubernetes only |
| `tcpping` | Static list of IPs | Simple | Breaks with autoscaling |
| `dns-ping` | DNS SRV records | Works with service discovery | Requires DNS setup |

For EC2 + ASG, **`jdbc-ping` is the right choice** — it's what the user data above configures. Keycloak 26 made it the default cache stack for exactly this reason. It also avoids needing multicast or complex SG rules, which matters in restricted networks.

---

## Part 5: Production Hardening

Everything in Part 1 works, but don't ship it as-is.

### 1. Remote State with Locking

Never keep `terraform.tfstate` on your laptop.

```hcl
terraform {
  backend "s3" {
    bucket       = "REPLACE_ME_STATE_BUCKET"
    key          = "keycloak/prod/terraform.tfstate"
    region       = "REPLACE_ME_AWS_REGION"
    encrypt      = true
    kms_key_id   = "REPLACE_ME_KMS_KEY_ARN"
    use_lockfile = true   # S3-native locking, Terraform 1.10+
  }
}
```

**Note:** As of Terraform 1.10+, S3-native state locking (`use_lockfile = true`) replaces the older DynamoDB table approach. DynamoDB locking still works but is being phased out.

If the bucket doesn't exist yet:

```bash
BUCKET=REPLACE_ME_STATE_BUCKET
REGION=REPLACE_ME_AWS_REGION

aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. Production Database Settings

```hcl
resource "aws_db_instance" "keycloak" {
  instance_class = "db.r6g.large"     # memory-optimized Graviton

  multi_az                = true      # automatic failover
  backup_retention_period = 30
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection = true
  skip_final_snapshot = false

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  performance_insights_enabled          = true
  performance_insights_retention_period = 731   # 2 years

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  monitoring_interval = 60
  monitoring_role_arn = "REPLACE_ME_RDS_MONITORING_ROLE_ARN"

  copy_tags_to_snapshot = true
  apply_immediately     = false   # wait for the maintenance window
}
```

**Sizing rule of thumb:** Keycloak's database load is mostly reads. Start with `db.r6g.large` (2 vCPU, 16 GB) for up to roughly 100 requests/second, then watch Performance Insights.

### 3. Auto Scaling Policies

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
      resource_label         = "${aws_lb.keycloak.arn_suffix}/${aws_lb_target_group.keycloak.arn_suffix}"
    }
    target_value = 500.0
  }
}
```

**Keycloak scaling caveat:** Nodes must join the Infinispan cluster to share sessions. Scaling *out* is fine. Scaling *in* drops sessions held by the terminating node unless persistent sessions are configured. Set a conservative `min_size` (2 or 3 in production) and prefer scaling out.

**Subnet capacity caveat:** In a brownfield VPC, `max_size` is bounded by free IPs in your existing subnets. Check `available_ip_address_count` before raising it — the `check` block in `data.tf` warns about this.

### 4. WAF Protection

```hcl
resource "aws_wafv2_web_acl" "keycloak" {
  name  = "${local.name}-waf"
  scope = "REGIONAL"

  default_action { allow {} }

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

If your org already has a central Web ACL, associate that instead:

```hcl
resource "aws_wafv2_web_acl_association" "keycloak" {
  resource_arn = aws_lb.keycloak.arn
  web_acl_arn  = "REPLACE_ME_EXISTING_WEB_ACL_ARN"
}
```

### 5. Monitoring and Alarms

```hcl
variable "alarm_sns_topic_arn" {
  description = "EXISTING SNS topic for alarms. Leave empty to disable alarm actions."
  type        = string
  default     = "REPLACE_ME_SNS_TOPIC_ARN"
}

locals {
  alarm_actions = (
    var.alarm_sns_topic_arn != "" && var.alarm_sns_topic_arn != "REPLACE_ME_SNS_TOPIC_ARN"
    ? [var.alarm_sns_topic_arn]
    : []
  )
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
  alarm_actions       = local.alarm_actions

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
  alarm_actions       = local.alarm_actions

  dimensions = { LoadBalancer = aws_lb.keycloak.arn_suffix }
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
  alarm_actions       = local.alarm_actions

  dimensions = { DBInstanceIdentifier = aws_db_instance.keycloak.id }
}
```

### 6. Rotate the Admin Account

The `KC_BOOTSTRAP_ADMIN_*` account is **temporary by design**. After first login:

1. Create a permanent admin user in the master realm
2. Assign it the `admin` role
3. Delete the bootstrap `kcadmin` account
4. Remove `/etc/systemd/system/keycloak.service.d/bootstrap.conf`
5. Delete the `${local.name}-admin-credentials-*` secret

Better still, federate admin login to your corporate IdP so no local admin password exists at all.

### 7. Production Checklist

**Brownfield-specific:**
- [ ] All `REPLACE_ME_*` stubs replaced
- [ ] `terraform plan` creates zero network resources
- [ ] `terraform destroy` tested in dev; VPC/subnets/SGs survived
- [ ] Terraform-managed SG rules tagged/described so the network team recognizes them
- [ ] Documented which existing resources this stack depends on
- [ ] Coordinated with the network team on subnet IP headroom for max ASG size

**General:**
- [ ] Remote S3 state with versioning, encryption, and locking
- [ ] `terraform.tfvars` and `*.tfstate` in `.gitignore`
- [ ] HTTPS with a valid ACM certificate; HTTP redirects to HTTPS
- [ ] `hostname-strict=true` with the correct `hostname` set
- [ ] Security groups reference other SGs, not `0.0.0.0/0`
- [ ] No SSH ports open; SSM Session Manager only
- [ ] IMDSv2 required (`http_tokens = "required"`)
- [ ] EBS volumes and RDS storage encrypted
- [ ] RDS Multi-AZ enabled
- [ ] RDS deletion protection on; final snapshot enabled
- [ ] Backup retention at least 7 days (30 for compliance)
- [ ] Instances in private subnets
- [ ] ALB access logs enabled to S3
- [ ] CloudWatch alarms wired to a real SNS topic
- [ ] WAF attached with rate limiting
- [ ] Bootstrap admin account deleted after setup
- [ ] Brute-force detection enabled in Keycloak realm settings
- [ ] MFA required for admin accounts
- [ ] Token lifespans reviewed (default access token: 5 minutes)
- [ ] Keycloak `--optimized` build in use
- [ ] Instance refresh configured on the ASG
- [ ] `terraform plan` shows no unexpected drift
- [ ] Runbook documented for restore-from-backup

### 8. Terraform Workflow Best Practices

```bash
terraform fmt -recursive          # consistent formatting
terraform validate                # syntax check

terraform plan -out=tfplan        # save the plan
terraform show -json tfplan | jq . > plan.json
terraform apply tfplan            # apply exactly what you reviewed

# Security scanning
tfsec .
checkov -d .

# Linting
tflint --init && tflint

# Drift detection
terraform plan -detailed-exitcode
# exit 0 = no changes, 1 = error, 2 = changes pending
```

**Guardrail: fail CI if the plan touches networking.**

```bash
#!/bin/bash
# ci-check-no-network-changes.sh
terraform show -json tfplan > plan.json

FORBIDDEN=$(jq -r '
  .resource_changes[]
  | select(.change.actions | (index("create") or index("delete") or index("update")))
  | select(.type | test("^aws_(vpc|subnet|security_group|internet_gateway|nat_gateway|route_table|route)$"))
  | "\(.type).\(.name) -> \(.change.actions | join(","))"
' plan.json)

if [ -n "$FORBIDDEN" ]; then
  echo "FAIL: plan modifies network resources that should be externally managed:"
  echo "$FORBIDDEN"
  exit 1
fi
echo "PASS: no network resource changes detected."
```

**Module structure for multiple environments:**

```
infra/
├── modules/
│   └── keycloak/
│       ├── main.tf
│       ├── data.tf
│       ├── variables.tf      # all network inputs required, no defaults
│       ├── outputs.tf
│       └── user-data.sh.tftpl
└── environments/
    ├── dev/
    │   ├── main.tf           # module "keycloak" { source = "../../modules/keycloak" ... }
    │   ├── backend.tf
    │   └── terraform.tfvars  # dev VPC/subnet/SG IDs
    ├── staging/
    │   └── terraform.tfvars  # staging VPC/subnet/SG IDs
    └── prod/
        └── terraform.tfvars  # prod VPC/subnet/SG IDs
```

**Inside a reusable module, make network inputs required — no defaults.** A stub default that silently applies to production is worse than a hard failure:

```hcl
variable "vpc_id" {
  description = "EXISTING VPC ID (required — no default on purpose)"
  type        = string
  # no default: force each environment to be explicit
}
```

**Avoid Terraform workspaces for environment separation.** They share one backend key and it's easy to apply to the wrong environment. Separate directories with separate state files are safer.

---

## Part 6: Troubleshooting

### Diagnostic Commands

```bash
# --- Connect without SSH ---
aws ssm start-session --target REPLACE_ME_INSTANCE_ID

# --- On the instance ---
sudo cat /var/log/user-data.log              # our script's output
sudo cat /var/log/cloud-init-output.log      # cloud-init's view
sudo journalctl -u keycloak -f               # live Keycloak logs
sudo systemctl status keycloak
curl -s localhost:9000/health/ready | jq .

# --- Read back the rendered user data ---
TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/user-data

# --- Test DB connectivity from the instance ---
sudo dnf install -y postgresql16
psql -h REPLACE_ME_RDS_ENDPOINT -U keycloak -d keycloak

# --- Verify outbound internet works ---
curl -sI https://github.com | head -1
curl -sI https://secretsmanager.REPLACE_ME_AWS_REGION.amazonaws.com | head -1

# --- From your laptop: ASG health ---
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names REPLACE_ME_ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,HealthStatus,LifecycleState,AvailabilityZone]' \
  --output table

# --- Scaling activity (shows WHY launches failed) ---
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name REPLACE_ME_ASG_NAME \
  --max-items 10 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:StatusMessage}' \
  --output table

# --- Target group health ---
aws elbv2 describe-target-health --target-group-arn REPLACE_ME_TARGET_GROUP_ARN

# --- Launch template versions ---
aws ec2 describe-launch-template-versions \
  --launch-template-id REPLACE_ME_LAUNCH_TEMPLATE_ID \
  --query 'LaunchTemplateVersions[].[VersionNumber,DefaultVersion,VersionDescription]' \
  --output table

# --- Free IPs remaining in your subnets ---
aws ec2 describe-subnets --subnet-ids REPLACE_ME_APP_SUBNET_1 REPLACE_ME_APP_SUBNET_2 \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Free:AvailableIpAddressCount}' \
  --output table
```

### Brownfield-Specific Problems

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `InvalidSubnetID.NotFound` | Stub not replaced, or subnet in another region/account | Verify the ID and that `aws_region` matches |
| `InvalidGroup.NotFound` | SG ID belongs to a different VPC | SGs are VPC-scoped; confirm with `describe-security-groups` |
| `ValidationError: subnets in at least two AZs` | All supplied subnets share one AZ | Supply subnets from different AZs (the `check` block warns) |
| ASG launches then immediately terminates | Subnet out of free IPs | Check `AvailableIpAddressCount`; ask for a larger subnet |
| Instance boots but user data hangs forever | No NAT Gateway and no VPC endpoints | Add NAT or interface endpoints, or bake an AMI |
| Can't reach Secrets Manager | Missing endpoint, or IAM policy ARN mismatch | Check egress on 443 and the exact secret ARN in the policy |
| RDS endpoint won't resolve | VPC DNS attributes disabled | Enable `enableDnsSupport` and `enableDnsHostnames` |
| `terraform plan` wants to create a VPC | You wrote `resource` where you meant `data` | Change to `data "aws_vpc"` and reference `var.vpc_id` |
| `terraform destroy` proposes deleting subnets | Network resources were imported into `resource` blocks | `terraform state rm` them, then re-reference as `data` |
| Existing SG rules disappeared after apply | Inline `ingress` block on a shared SG | Use standalone `aws_vpc_security_group_ingress_rule` resources |
| `InvalidParameterCombination` on launch template | Both `vpc_security_group_ids` and `network_interfaces` set | Use one or the other |
| All instances land in one AZ | `subnet_id` set inside `network_interfaces` | Remove it; let the ASG's `vpc_zone_identifier` decide |
| `CertificateNotFound` on the HTTPS listener | ACM cert is in a different region | ACM certs for an ALB must be in the ALB's region |
| IAM role creation denied | Missing permissions boundary required by an SCP | Set `iam_permissions_boundary_arn` |
| ALB created but unreachable from the internet | ALB placed in private subnets | Use public subnets, or set `internal_alb = true` |
| DB subnet group error: "does not cover enough AZs" | Reused group spans only one AZ | Use a different group, or let Terraform create one |

### General Problems

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Target group shows "unhealthy" | Health check path/port wrong, or grace period too short | Verify `/health/ready` on port 9000; raise `health_check_grace_period` |
| Keycloak won't start, DB error | SG blocks 5432, or wrong credentials | Check SG rules; test with `psql` from the instance |
| Blank page or broken CSS | `hostname` misconfigured behind the proxy | Set `hostname` and `proxy-headers=xforwarded` correctly |
| Infinite redirect loop | ALB terminates TLS but Keycloak thinks it's HTTP | Set `proxy-headers=xforwarded` |
| `Invalid parameter: redirect_uri` | Client's redirect URI doesn't match | Fix redirect URIs in the Keycloak client config |
| User data didn't run at all | Missing `#!/bin/bash` shebang, or not base64 encoded | First line must be the shebang; wrap in `base64encode()` |
| User data ran but variables are empty | `${VAR}` consumed by Terraform | Escape bash variables as `$${VAR}` in `.tftpl` |
| "User data is too large" | Over 16 KB after encoding | Use `cloudinit_config` with `gzip = true`, or bake an AMI |
| Instances loop terminate/launch | Health check fails before startup completes | Increase `health_check_grace_period`; read logs before the instance dies |
| Cluster nodes don't see each other | JGroups port 7800 blocked | Allow 7800 within the app security group |
| Sessions lost on scale-in | Terminating node held those sessions | Use `jdbc-ping` and sticky sessions; scale in conservatively |
| `terraform apply` hangs on RDS | Normal — RDS takes 10–15 minutes | Wait |

### Keycloak Version Notes

| Version | Key changes |
|---------|-------------|
| 26.x | `KC_BOOTSTRAP_ADMIN_*` replaces `KEYCLOAK_ADMIN_*`; requires Java 21; `jdbc-ping` default cache stack; persistent sessions by default |
| 25.x | Management port 9000 introduced for health/metrics; `proxy-headers` replaces the `proxy` option |
| 24.x | `hostname-strict-backchannel` changes |
| 17–23 | Quarkus distribution (replaced WildFly) |
| 16 and earlier | WildFly-based, **end of life** |

Always read the official upgrade guide before jumping versions. Keycloak releases frequently, with a support window of roughly one year per release.

---

## Quick Reference

### Complete Stub Replacement Table

| Stub | Where used | How to find it |
|------|-----------|----------------|
| `REPLACE_ME_AWS_REGION` | `aws_region` | `aws configure get region` |
| `REPLACE_ME_VPC_ID` | `vpc_id` | `aws ec2 describe-vpcs` |
| `REPLACE_ME_APP_SUBNET_1/2` | `app_subnet_ids` | `aws ec2 describe-subnets` (private) |
| `REPLACE_ME_ALB_SUBNET_1/2` | `alb_subnet_ids` | `aws ec2 describe-subnets` (public) |
| `REPLACE_ME_DB_SUBNET_1/2` | `db_subnet_ids` | `aws ec2 describe-subnets` |
| `REPLACE_ME_ALB_SG_ID` | `alb_security_group_ids` | `aws ec2 describe-security-groups` |
| `REPLACE_ME_APP_SG_ID` | `app_security_group_ids` | `aws ec2 describe-security-groups` |
| `REPLACE_ME_DB_SG_ID` | `db_security_group_ids` | `aws ec2 describe-security-groups` |
| `REPLACE_ME_DB_SUBNET_GROUP` | `db_subnet_group_name` | `aws rds describe-db-subnet-groups` |
| `REPLACE_ME_ACM_CERT_ARN` | `acm_certificate_arn` | `aws acm list-certificates` |
| `REPLACE_ME_ROUTE53_ZONE_ID` | `route53_zone_id` | `aws route53 list-hosted-zones` |
| `REPLACE_ME_HOSTNAME` | `keycloak_hostname` | Your DNS plan |
| `REPLACE_ME_KMS_KEY_ARN` | `kms_key_arn` | `aws kms list-aliases` |
| `REPLACE_ME_PERMISSIONS_BOUNDARY_ARN` | `iam_permissions_boundary_arn` | Ask your security team |
| `REPLACE_ME_SNS_TOPIC_ARN` | `alarm_sns_topic_arn` | `aws sns list-topics` |
| `REPLACE_ME_STATE_BUCKET` | backend config | Ask your platform team |
| `REPLACE_ME_OWNER` / `REPLACE_ME_COST_CENTER` | tags | Your org's tagging standard |

**One-liner to find leftover stubs before applying:**

```bash
grep -rn "REPLACE_ME" --include="*.tf" --include="*.tfvars" . \
  | grep -v example.tfvars \
  && echo "FAIL: unreplaced stubs found above" \
  || echo "PASS: no stubs remaining"
```

### Essential Terraform Commands

```bash
terraform init                          # download providers
terraform init -upgrade                 # update providers
terraform init -reconfigure             # change backend
terraform fmt -recursive                # format code
terraform validate                      # check syntax
terraform plan                          # preview changes
terraform plan -out=tfplan              # save a plan
terraform apply tfplan                  # apply a saved plan
terraform apply -target=aws_lb.keycloak # apply one resource (use sparingly)
terraform destroy                       # remove Terraform-managed resources only
terraform state list                    # list managed resources
terraform state show aws_lb.keycloak    # inspect one resource
terraform state rm aws_vpc.oops         # stop managing without deleting
terraform output                        # show outputs
terraform output -raw keycloak_url      # one output, unquoted
terraform refresh                       # sync state with reality
terraform console                       # interactive expression evaluation
```

`terraform state rm` is the escape hatch if you ever accidentally imported network resources. It removes them from state without deleting them from AWS.

### Key Keycloak Configuration Options

```properties
# Database
db=postgres
db-url=jdbc:postgresql://REPLACE_ME_RDS_ENDPOINT:5432/keycloak
db-username=keycloak
db-password=<from Secrets Manager>
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

# Hostname / proxy
hostname=https://REPLACE_ME_HOSTNAME
hostname-strict=true
hostname-backchannel-dynamic=false
proxy-headers=xforwarded

# HTTP
http-enabled=true
http-port=8080
https-port=8443

# Health and metrics (served on management port 9000)
health-enabled=true
metrics-enabled=true

# Clustering
cache=ispn
cache-stack=jdbc-ping

# Logging
log=console
log-console-output=json
log-level=INFO
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

### Estimated Monthly Costs (approximate, us-east-1)

Since you're reusing existing networking, you avoid NAT Gateway and VPC costs entirely — often the largest line item in a greenfield build.

| Component | Dev | Production |
|-----------|-----|-----------|
| EC2 instances | 1 × t3.medium ≈ $30 | 2 × m6i.large ≈ $140 |
| RDS | db.t4g.micro ≈ $13 | db.r6g.large Multi-AZ ≈ $360 |
| ALB | ≈ $18 + traffic | ≈ $18 + traffic |
| Secrets Manager | ≈ $1 | ≈ $1 |
| CloudWatch | ≈ $5 | ≈ $20 |
| WAF | — | ≈ $10 |
| **NAT Gateway** | **$0 (existing)** | **$0 (existing)** |
| **VPC / subnets** | **$0 (existing)** | **$0 (existing)** |
| **Rough total** | **≈ $67/mo** | **≈ $550/mo** |

Prices change — verify with the AWS Pricing Calculator for your region.

**Cost-saving tips:**
- Use Graviton instance types (`t4g`, `m7g`, `db.r7g`) — roughly 20% cheaper
- Scheduled ASG actions to scale to 0 outside work hours in dev
- Stop dev RDS when unused (auto-restarts after 7 days)
- Attach to a shared ALB with a listener rule instead of creating one (~$18/mo saved)

### Official Documentation

- Keycloak docs: `https://www.keycloak.org/documentation`
- Keycloak server configuration reference: `https://www.keycloak.org/server/all-config`
- Terraform AWS provider: `https://registry.terraform.io/providers/hashicorp/aws/latest/docs`
- AWS Launch Templates: `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-templates.html`
- EC2 user data: `https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html`
- cloud-init: `https://cloudinit.readthedocs.io/`
- Terraform import blocks: `https://developer.hashicorp.com/terraform/language/import`
- Terraform check blocks: `https://developer.hashicorp.com/terraform/language/checks`

---

*Versions referenced: Keycloak 26.4.0, Terraform 1.9+, AWS Provider 6.x, Amazon Linux 2023, PostgreSQL 16. Verify current versions before deploying — release cadences are fast.*
