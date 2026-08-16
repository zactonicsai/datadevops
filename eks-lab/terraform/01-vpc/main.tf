# =============================================================================
# LAYER 1 — VPC and networking
#
# This layer has its OWN state file. Nothing here knows about the cluster,
# and the cluster layer cannot modify anything here. That separation means a
# mistake in the app layer can never delete your network.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # For a real team, uncomment and use a shared S3 backend so everyone sees
  # the same state and only one apply can run at a time:
  #
  # backend "s3" {
  #   bucket       = "your-tfstate-bucket"
  #   key          = "lab/01-vpc/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
  # default_tags puts these on EVERY resource automatically — no more
  # forgetting to tag something and losing track of what it costs.
  default_tags { tags = var.tags }
}

locals {
  name = var.lab_name
}

# ---------------------------------------------------------------------------
# The VPC. enable_dns_* are MANDATORY for EKS — without them nodes cannot
# find the control plane and you get "NotReady" with no useful error.
# ---------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

# ---------------------------------------------------------------------------
# Subnets. The kubernetes.io/role tags let AWS load balancer controllers
# discover which subnets to use. Miss them and Ingress never gets an address.
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                     = "${local.name}-public-${var.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name                              = "${local.name}-private-${var.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ---------------------------------------------------------------------------
# Public routing
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-rtb-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# NAT gateway — optional because it is the most expensive item in the lab.
# `count` on a bool is the standard Terraform way to make a resource optional.
# ---------------------------------------------------------------------------
resource "aws_eip" "nat" {
  count  = var.use_nat ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.use_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count  = var.use_nat ? 1 : 0
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }
  tags = { Name = "${local.name}-rtb-private" }
}

resource "aws_route_table_association" "private" {
  count          = var.use_nat ? length(aws_subnet.private) : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# ---------------------------------------------------------------------------
# S3 gateway endpoint. FREE, and keeps NiFi's writes to S3 off the NAT
# gateway (where you would pay per gigabyte). Always add this.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = compact(concat([aws_route_table.public.id], var.use_nat ? [aws_route_table.private[0].id] : []))
  tags              = { Name = "${local.name}-vpce-s3" }
}
