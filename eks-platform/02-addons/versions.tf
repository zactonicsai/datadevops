# =============================================================================
# 02-addons/versions.tf
# =============================================================================
# This is the FIRST layer that installs things INSIDE Kubernetes rather than in
# AWS, so it is the first to need the kubernetes and helm providers. The same
# provider block pattern repeats in layers 03 through 08.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # The kubernetes provider manages individual Kubernetes objects
    # (Namespaces, ServiceAccounts, ConfigMaps) the way kubectl would.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }

    # The helm provider installs Helm charts.
    #
    # WHAT IS HELM? A package manager for Kubernetes. A "chart" is a bundle of
    # templated YAML plus a values file that fills in the blanks. Instead of
    # writing 400 lines of YAML for the load balancer controller, you install
    # a chart and set a handful of values.
    #
    # WHY INSTALL CHARTS FROM TERRAFORM instead of running `helm install`?
    #   + One tool, one state file, one `destroy` that cleans up everything.
    #   + Values can reference Terraform outputs (IAM role ARNs, VPC IDs)
    #     directly, with no copy-paste step.
    #   - You lose some Helm niceties like `helm rollback`.
    #   - Terraform's error messages for a failed chart are worse than Helm's.
    # The README shows the equivalent raw `helm` commands for every chart, so
    # you can see both approaches and debug with native tools when needed.
    #
    # NOTE: helm provider v3 changed configuration from nested `kubernetes {}`
    # blocks to a single `kubernetes = {}` attribute. We pin v3 and use the
    # new syntax below.
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

# -----------------------------------------------------------------------------
# Read the cluster layer's outputs so we know how to connect.
# -----------------------------------------------------------------------------
data "terraform_remote_state" "cluster" {
  backend = "local"
  config = {
    path = "../01-cluster/terraform.tfstate"
  }
}

data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "../00-network/terraform.tfstate"
  }
}

# -----------------------------------------------------------------------------
# CONNECTING TO THE CLUSTER
# -----------------------------------------------------------------------------
# Both providers below authenticate identically: they call out to the AWS CLI
# for a fresh token every run. Tokens are only valid ~15 minutes, so this
# "exec" plugin approach is the only correct one -- never store a token.
locals {
  cluster_name     = data.terraform_remote_state.cluster.outputs.cluster_name
  cluster_endpoint = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca       = data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data
}

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
  # Helm provider v3 syntax: an attribute, not a block.
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
