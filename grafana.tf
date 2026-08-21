terraform {
  required_version = ">= 1.5"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "cluster_name" {
  type        = string
  description = "Name of the existing EKS cluster"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "namespace" {
  type    = string
  default = "monitoring"
}

# Pin this. Check available versions with:
#   helm search repo grafana/grafana --versions
variable "chart_version" {
  type    = string
  default = "8.5.1"
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "kubernetes_namespace" "grafana" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "grafana_admin" {
  length  = 20
  special = true
}

resource "helm_release" "grafana" {
  name       = "grafana"
  namespace  = kubernetes_namespace.grafana.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = var.chart_version

  # Chart creates its own admin secret from this value.
  set_sensitive {
    name  = "adminPassword"
    value = random_password.grafana_admin.result
  }

  values = [yamlencode({
    persistence = {
      enabled = true
      size    = "10Gi"
      # Requires the EBS CSI driver on the cluster. Set enabled=false if absent.
      storageClassName = "gp2"
    }
    service = {
      type = "ClusterIP"
      port = 80
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "port_forward_command" {
  value = "kubectl -n ${var.namespace} port-forward svc/grafana 3000:80"
}
