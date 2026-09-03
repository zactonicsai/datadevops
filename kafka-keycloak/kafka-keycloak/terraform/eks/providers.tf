provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# ---- platform cluster (Keycloak) ----
provider "kubernetes" {
  alias                  = "platform"
  host                   = module.platform.endpoint
  cluster_ca_certificate = base64decode(module.platform.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.name, "--region", var.region]
  }
}

provider "helm" {
  alias = "platform"
  kubernetes {
    host                   = module.platform.endpoint
    cluster_ca_certificate = base64decode(module.platform.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.platform.name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  alias                  = "platform"
  host                   = module.platform.endpoint
  cluster_ca_certificate = base64decode(module.platform.ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.platform.name, "--region", var.region]
  }
}

# ---- data cluster (Kafka + Kafka UI) ----
provider "kubernetes" {
  alias                  = "data"
  host                   = module.data.endpoint
  cluster_ca_certificate = base64decode(module.data.ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.data.name, "--region", var.region]
  }
}

provider "helm" {
  alias = "data"
  kubernetes {
    host                   = module.data.endpoint
    cluster_ca_certificate = base64decode(module.data.ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.data.name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  alias                  = "data"
  host                   = module.data.endpoint
  cluster_ca_certificate = base64decode(module.data.ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.data.name, "--region", var.region]
  }
}
