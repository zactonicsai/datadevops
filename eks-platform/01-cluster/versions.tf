# =============================================================================
# 01-cluster/versions.tf
# =============================================================================
# Same structure as 00-network/versions.tf. See that file for the full
# explanation of why we pin versions and why the backend is local.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # The TLS provider is used by the EKS module to fetch and fingerprint the
    # cluster's OIDC certificate. We do not call it directly, but declaring it
    # keeps the version pinned and the lock file complete.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
# READING THE PREVIOUS LAYER'S OUTPUTS
# -----------------------------------------------------------------------------
# This is the mechanism that lets separate layers cooperate. It opens
# 00-network's state file and exposes its outputs to us.
#
# After this block, ../00-network's `vpc_id` output is available as:
#     data.terraform_remote_state.network.outputs.vpc_id
#
# WHY SPLIT INTO LAYERS AT ALL? Pros and cons:
#
#   PROS
#     + Blast radius. A mistake in the web-app layer cannot accidentally
#       destroy your VPC, because that VPC is not in this state file.
#     + Speed. `terraform plan` on one small layer takes seconds; on a single
#       giant monolith it can take many minutes.
#     + Lifecycle separation. The network changes once a year; the web app
#       changes daily. They should not be coupled.
#     + Permissions. Different teams can be granted access to different layers.
#
#   CONS
#     + More moving parts. You must apply them in the right order.
#     + Cross-layer references are read-only snapshots. If you change layer 00
#       you must re-apply it before layer 01 sees the new value.
#     + `terraform destroy` must be run in REVERSE order, or you will try to
#       delete a VPC that still has a cluster inside it (AWS will refuse).
#
# The wrapper scripts in scripts/ handle the ordering for you.
# -----------------------------------------------------------------------------
data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    # Relative path from THIS directory to the network layer's state file.
    path = "../00-network/terraform.tfstate"
  }
}
