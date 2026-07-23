# =============================================================================
# 03-keda/versions.tf
# =============================================================================
# Providers for the KEDA autoscaling layer.
#
# The structure here is identical to 02-addons/versions.tf, which carries the
# full explanations of version pinning, local state, and the exec-based
# authentication pattern. Read that file first if anything below is unclear.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# Read the cluster layer's outputs to learn how to reach the API server.
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../01-cluster/terraform.tfstate"
  }
}

locals {
  cluster_name     = data.terraform_remote_state.cluster.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data
}

# Both providers fetch a short-lived token from the AWS CLI on every run,
# rather than storing one. Requires AWS CLI v2 on PATH.
provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_ca)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", var.aws_region]
    }
  }
}
