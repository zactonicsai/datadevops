terraform {
  required_version = ">= 1.6"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.70" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.33" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    time       = { source = "hashicorp/time", version = "~> 0.12" }
  }
  # Optional: keep state in S3 (uncomment and fill in)
  # backend "s3" { bucket = "my-tf-state"  key = "kafka-keycloak/eks.tfstate"  region = "us-east-1" }
}
