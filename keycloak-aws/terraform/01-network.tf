###############################################################################
# 01-network.tf
# Builds the "land" everything else sits on:
#   VPC, subnets, internet gateway, route tables,
#   security groups (firewalls), and IAM roles (permission badges).
#
# Nothing here costs money except the optional VPC endpoints (disabled by
# default). Plain VPCs, subnets, security groups and IAM roles are FREE.
###############################################################################

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
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
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}

###############################################################################
# VARIABLES - the knobs you can turn without editing the rest of the code
###############################################################################

variable "aws_region" {
  description = "Which AWS datacenter region to build in."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name glued onto every resource so you can find them."
  type        = string
  default     = "keycloak-demo"
}

variable "environment" {
  description = "dev / test / prod - just a label."
  type        = string
  default     = "dev"
}

variable "my_ip_cidr" {
  description = "YOUR public IP with /32 on the end. Only this IP can reach Keycloak."
  type        = string
  default     = "68.32.112.68/32"

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must look like 1.2.3.4/32"
  }
}

variable "vpc_cidr" {
  description = "Private IP address range for the whole VPC."
  type        = string
  default     = "10.42.0.0/16"
}

###############################################################################
# DATA SOURCES - ask AWS questions instead of hard-coding answers
###############################################################################

# Which Availability Zones exist in this region right now?
data "aws_availability_zones" "available" {
  state = "available"
}

# Who am I? (account ID, used to lock IAM policies down tightly)
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

###############################################################################
# THE VPC - your own private slice of the AWS network
###############################################################################

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # These two must be ON or RDS hostnames won't resolve inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

###############################################################################
# INTERNET GATEWAY - the door to the public internet
###############################################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

###############################################################################
# SUBNETS
#
# PUBLIC subnet  -> Keycloak EC2 lives here, has a public IP, reachable by you.
# PRIVATE subnets -> RDS Postgres lives here. NO public IP, NO internet route.
#                    RDS requires at least 2 subnets in 2 different AZs.
###############################################################################

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # 10.42.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-a"
    Tier = "public"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11) # 10.42.11.0/24
  availability_zone = data.aws_availability_zones.available.names[0]

  # Belt and braces: never hand out a public IP here.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-a"
    Tier = "private"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 12) # 10.42.12.0/24
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-private-b"
    Tier = "private"
  }
}

###############################################################################
# ROUTE TABLES - the road signs
###############################################################################

# Public: "anything not local -> go out the internet gateway"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private: NO 0.0.0.0/0 route on purpose. The database cannot phone home,
# and the internet cannot phone it. This is free; a NAT Gateway would be
# roughly $32/month plus data charges, and we simply don't need one.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-rt-private"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# SECURITY GROUPS - stateful firewalls attached to each resource
#
# Design rule: the database SG allows traffic FROM THE KEYCLOAK SG, not from
# an IP range. If the EC2 instance is replaced and gets a new IP, the rule
# still works. This is the AWS best practice.
###############################################################################

# ---- Keycloak server firewall -------------------------------------------
resource "aws_security_group" "keycloak" {
  name        = "${var.project_name}-keycloak-sg"
  description = "Allow admin console and SSH from one IP only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-keycloak-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS (8443) from your IP only - Keycloak's own TLS listener
resource "aws_vpc_security_group_ingress_rule" "keycloak_https" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Keycloak HTTPS from my IP"
  cidr_ipv4         = var.my_ip_cidr
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}

# HTTP (8080) from your IP only - handy for first-boot troubleshooting.
# Comment this out once you are happy with HTTPS.
resource "aws_vpc_security_group_ingress_rule" "keycloak_http" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Keycloak HTTP from my IP (troubleshooting)"
  cidr_ipv4         = var.my_ip_cidr
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
}

# SSH from your IP only. Even so, prefer SSM Session Manager (see IAM below)
# so you never need to open port 22 at all.
resource "aws_vpc_security_group_ingress_rule" "keycloak_ssh" {
  security_group_id = aws_security_group.keycloak.id
  description       = "SSH from my IP only"
  cidr_ipv4         = var.my_ip_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Egress: the server needs to reach the internet to pull the Keycloak
# tarball, OS packages and to talk to SSM.
resource "aws_vpc_security_group_egress_rule" "keycloak_all_out" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- Database firewall ---------------------------------------------------
resource "aws_security_group" "database" {
  name        = "${var.project_name}-db-sg"
  description = "Postgres 5432 from the Keycloak SG only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-db-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# THE important rule: source is a security group, not a CIDR block.
resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
  security_group_id            = aws_security_group.database.id
  description                  = "Postgres from Keycloak instances only"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# The database never needs to start outbound connections, but AWS requires
# at least a placeholder. We give it nothing useful.
resource "aws_vpc_security_group_egress_rule" "db_none" {
  security_group_id = aws_security_group.database.id
  description       = "No meaningful egress needed"
  cidr_ipv4         = "127.0.0.1/32"
  ip_protocol       = "-1"
}

###############################################################################
# IAM - least privilege permission badges for the EC2 instance
#
# The instance needs exactly two things:
#   1. Read ONE specific secret from Secrets Manager (the DB password)
#   2. Talk to SSM Session Manager so you can get a shell without SSH
# Nothing else. No s3:*, no ec2:*, no wildcards on resources.
###############################################################################

# Random suffix so the secret name is unique and re-creatable after deletion
resource "random_id" "suffix" {
  byte_length = 3
}

# Trust policy: only the EC2 service may wear this role.
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2ToAssume"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keycloak" {
  name               = "${var.project_name}-keycloak-role-${random_id.suffix.hex}"
  description        = "Least privilege role for the Keycloak EC2 instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# AWS-managed policy that enables SSM Session Manager (browser shell).
# This is the one managed policy worth attaching: maintaining an equivalent
# inline policy by hand is error prone and AWS keeps this one current.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Custom policy: read exactly one secret ARN. Note the resource is pinned
# to a single ARN prefix, not "*".
data "aws_iam_policy_document" "read_db_secret" {
  statement {
    sid = "ReadOnlyTheKeycloakDbSecret"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/db-*"
    ]
  }
}

resource "aws_iam_policy" "read_db_secret" {
  name        = "${var.project_name}-read-db-secret-${random_id.suffix.hex}"
  description = "Read only the Keycloak database secret"
  policy      = data.aws_iam_policy_document.read_db_secret.json
}

resource "aws_iam_role_policy_attachment" "read_db_secret" {
  role       = aws_iam_role.keycloak.name
  policy_arn = aws_iam_policy.read_db_secret.arn
}

# An instance profile is the wrapper that lets an EC2 instance wear a role.
resource "aws_iam_instance_profile" "keycloak" {
  name = "${var.project_name}-keycloak-profile-${random_id.suffix.hex}"
  role = aws_iam_role.keycloak.name
}

###############################################################################
# RDS SUBNET GROUP - tells RDS which private subnets it may use
###############################################################################

resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnets"
  description = "Private subnets for the Keycloak database"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name = "${var.project_name}-db-subnets"
  }
}

###############################################################################
# OUTPUTS - values the other two Terraform files consume
###############################################################################

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Subnet where the Keycloak EC2 instance goes"
  value       = aws_subnet.public.id
}

output "private_subnet_ids" {
  description = "Subnets where RDS goes"
  value       = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

output "keycloak_sg_id" {
  description = "Security group for the Keycloak instance"
  value       = aws_security_group.keycloak.id
}

output "database_sg_id" {
  description = "Security group for the RDS instance"
  value       = aws_security_group.database.id
}

output "db_subnet_group_name" {
  description = "RDS subnet group name"
  value       = aws_db_subnet_group.main.name
}

output "instance_profile_name" {
  description = "IAM instance profile for the Keycloak EC2 instance"
  value       = aws_iam_instance_profile.keycloak.name
}

output "resource_suffix" {
  description = "Random suffix used for globally-unique names"
  value       = random_id.suffix.hex
}
