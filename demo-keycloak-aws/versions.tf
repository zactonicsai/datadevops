###############################################################################
# Terraform & provider version pinning
# Best practice: pin the Terraform core version and use pessimistic (~>)
# constraints on providers so upgrades are deliberate, not accidental.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.83"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
