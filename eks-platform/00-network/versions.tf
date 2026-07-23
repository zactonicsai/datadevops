# =============================================================================
# 00-network/versions.tf
# =============================================================================
# Every layer starts with a file like this. It answers two questions:
#   1. Which version of Terraform itself is allowed to run this code?
#   2. Which "providers" (plugins that talk to an API) do we need, and at
#      which versions?
#
# WHY PIN VERSIONS AT ALL?
# Providers are released constantly. If you do not pin, `terraform init` grabs
# whatever is newest that day. Code that worked last Tuesday can break today
# through no change of your own. Pinning makes builds REPRODUCIBLE, which is
# one of the most important best practices in infrastructure as code.
# =============================================================================

terraform {
  # The minimum Terraform CLI version. Features like optional object attributes
  # and improved validation need a modern release; 1.9 is a safe floor.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      # "source" is the address in the public Terraform Registry.
      source = "hashicorp/aws"

      # "~> 6.0" is the pessimistic constraint operator. It means:
      #   allow 6.1, 6.2, 6.54 ...  (minor and patch upgrades are fine)
      #   forbid 7.0               (a new major version may break things)
      # This is the sweet spot: you get bug fixes automatically but never a
      # surprise breaking change. AWS provider 6.x is current as of July 2026.
      version = "~> 6.0"
    }
  }

  # ---------------------------------------------------------------------------
  # BACKEND: where Terraform stores its state file
  # ---------------------------------------------------------------------------
  # "State" is Terraform's memory. It is a JSON file mapping the resources in
  # your code to the real IDs of things in AWS. Without it, Terraform would not
  # know that aws_vpc.main is the VPC with ID vpc-0abc123.
  #
  # We use the LOCAL backend, as requested: state lives in a file on this
  # machine, next to the code.
  #
  # PROS of local state:
  #   + Zero setup. Nothing to create before you can run terraform.
  #   + Fast. No network round trip on every operation.
  #   + Perfect for learning and for solo experiments.
  #
  # CONS of local state (know these before using this pattern at work):
  #   - Only one person can use it. There is no locking, so two people running
  #     apply at the same time can corrupt the file and orphan real resources.
  #   - It lives on one laptop. Lose the laptop, lose the ability to manage or
  #     destroy the infrastructure, which then bills you forever.
  #   - It contains SECRETS in plain text (certificate data, tokens). Never
  #     commit a .tfstate file to git. Our .gitignore blocks it.
  #
  # THE PRODUCTION ALTERNATIVE: an S3 backend with native state locking.
  #   backend "s3" {
  #     bucket       = "my-company-tfstate"
  #     key          = "eks-platform/00-network/terraform.tfstate"
  #     region       = "us-east-1"
  #     encrypt      = true
  #     use_lockfile = true   # S3-native locking; replaced DynamoDB in AWS
  #                           # provider v6 / Terraform 1.11+
  #   }
  # ---------------------------------------------------------------------------
  backend "local" {
    # Relative to this directory, so state is 00-network/terraform.tfstate.
    path = "terraform.tfstate"
  }
}

# -----------------------------------------------------------------------------
# The AWS provider block: configures HOW we talk to AWS.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  # NOTE ON CREDENTIALS: there are deliberately no access keys here.
  # Hard-coding credentials in Terraform code is one of the most common and
  # most damaging security mistakes, because the code usually ends up in git.
  #
  # Instead the provider walks a standard search order until it finds
  # credentials:
  #   1. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY environment variables
  #   2. The shared file ~/.aws/credentials (what `aws configure` writes)
  #   3. An IAM role attached to the EC2 instance / ECS task / CodeBuild job
  #   4. IAM Roles Anywhere or OIDC federation in CI systems
  # Options 3 and 4 are best: nothing long-lived is ever written to disk.

  # default_tags automatically stamps these tags onto EVERY resource this
  # provider creates. Without it you must remember `tags = var.tags` on all
  # ~80 resources, and you will eventually forget one.
  default_tags {
    tags = var.tags
  }
}
