terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.33" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
  }
  backend "s3" {} # configured via: terraform init -backend-config=backend.hcl
}
