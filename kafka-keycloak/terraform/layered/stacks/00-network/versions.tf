terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
  # Configured per environment: terraform init -backend-config=backend.hcl
  backend "s3" {}
}
