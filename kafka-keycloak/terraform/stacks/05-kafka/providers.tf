provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs
  k8s_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", var.region]
  }
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.ca_certificate)
  exec {
    api_version = local.k8s_exec.api_version
    command     = local.k8s_exec.command
    args        = local.k8s_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster.endpoint
    cluster_ca_certificate = base64decode(local.cluster.ca_certificate)
    exec {
      api_version = local.k8s_exec.api_version
      command     = local.k8s_exec.command
      args        = local.k8s_exec.args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.ca_certificate)
  load_config_file       = false
  exec {
    api_version = local.k8s_exec.api_version
    command     = local.k8s_exec.command
    args        = local.k8s_exec.args
  }
}
