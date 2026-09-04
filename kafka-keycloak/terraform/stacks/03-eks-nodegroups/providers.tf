provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster.endpoint
    cluster_ca_certificate = base64decode(local.cluster.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
    }
  }
}
