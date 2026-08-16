# =============================================================================
# LAYER 4 — the launch template and the managed node group (the workers).
#
# Separate from the cluster layer on purpose: you can destroy the nodes every
# evening to save money and rebuild them in the morning, without touching the
# control plane or the network.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}

provider "aws" {
  region = var.region
  default_tags { tags = var.tags }
}

# Read-only views of the earlier layers. This layer can SEE their outputs
# but can never modify their resources — that is the isolation we want.
data "terraform_remote_state" "vpc" {
  backend = "local"
  config = {
    path = "../01-vpc/terraform.tfstate"
  }
}

data "terraform_remote_state" "iam" {
  backend = "local"
  config = {
    path = "../02-iam-sg/terraform.tfstate"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../03-cluster/terraform.tfstate"
  }
}

locals { name = var.lab_name }

# ---------------------------------------------------------------------------
# Launch template — the recipe for each worker machine.
#
# We deliberately leave out image_id and instance_type so the EKS managed node
# group picks the correct, AWS-patched, EKS-optimised AMI for our Kubernetes
# version. Only pin an AMI when you need your own hardened image.
# ---------------------------------------------------------------------------
resource "aws_launch_template" "node" {
  name_prefix = "${local.name}-node-"

  vpc_security_group_ids = [
    data.terraform_remote_state.iam.outputs.node_sg_id,
    data.terraform_remote_state.cluster.outputs.cluster_sg_id,
  ]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 hardening.
  #   http_tokens = "required"       -> blocks a whole class of SSRF attacks
  #   hop_limit   = 1                -> the reply cannot reach into a pod, so
  #                                     pods cannot steal the NODE's AWS
  #                                     credentials and bypass IRSA
  # Two lines, no cost, real protection.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${local.name}-node" })
  }

  lifecycle { create_before_destroy = true }
}

# ---------------------------------------------------------------------------
# The node group
# ---------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = data.terraform_remote_state.cluster.outputs.cluster_name
  node_group_name = "${local.name}-ng"
  node_role_arn   = data.terraform_remote_state.iam.outputs.node_role_arn
  subnet_ids      = data.terraform_remote_state.vpc.outputs.node_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type   # SPOT is ~70% cheaper than ON_DEMAND

  scaling_config {
    min_size     = var.node_min
    desired_size = var.node_desired
    max_size     = var.node_max
  }

  update_config { max_unavailable = 1 }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = { workload = "lab" }

  lifecycle {
    # If you later add an autoscaler, IT owns desired_size at runtime.
    # Without this, Terraform and the autoscaler fight each other forever.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
