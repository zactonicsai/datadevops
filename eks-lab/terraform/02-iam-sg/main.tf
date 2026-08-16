# =============================================================================
# LAYER 2 — IAM roles and security groups
#
# Reads layer 1's outputs read-only. It can SEE the VPC id; it can never
# change the VPC. That is the isolation we want between layers.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}

provider "aws" {
  region = var.region
  default_tags { tags = var.tags }
}

# Read the previous layer's state. With a local backend this is a file path;
# with an S3 backend it would be backend="s3" and the same key you used there.
data "terraform_remote_state" "vpc" {
  backend = "local"
  config  = { path = "../01-vpc/terraform.tfstate" }
}

locals {
  name   = var.lab_name
  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id
}

# ---------------------------------------------------------------------------
# EKS cluster role — worn by the EKS service itself
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]   # ONLY EKS may wear this hat
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------------------------
# Node role — worn by each worker EC2 instance
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # join the cluster
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # give pods IPs
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull images
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",       # shell without SSH
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# BEST PRACTICE: the node role gets NOTHING beyond what Kubernetes needs.
# Applications get their own roles (layer 3, using IRSA). If the node role
# could reach S3, every pod could too, and per-app permissions would be a lie.

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "node" {
  name        = "${local.name}-node-sg"
  description = "EKS worker nodes"
  vpc_id      = local.vpc_id
  tags        = { Name = "${local.name}-node-sg" }
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public load balancer"
  vpc_id      = local.vpc_id
  tags        = { Name = "${local.name}-alb-sg" }
}

# Rules are separate resources so you can change a rule without destroying
# and recreating the whole security group.
resource "aws_vpc_security_group_ingress_rule" "node_to_node" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
  description                  = "All traffic between nodes (pods, DNS, etc.)"
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_node" {
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"
  description                  = "Load balancer to NodePort range"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.public_access_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS to the load balancer"
}

resource "aws_vpc_security_group_egress_rule" "node_out" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Nodes may call out (pull images, reach AWS APIs)"
}

# NOTE: no port 22 anywhere. Use SSM Session Manager for a shell:
#   aws ssm start-session --target i-xxxxx
