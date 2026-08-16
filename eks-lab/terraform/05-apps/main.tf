# =============================================================================
# LAYER 5 — the applications: Keycloak, Kafka, NiFi, the web app, monitoring.
#
# This layer uses the KUBERNETES and HELM providers instead of the AWS
# provider. Same tool, different target: instead of calling the AWS API it
# calls the Kubernetes API.
#
# The manifests here are the same ones the shell scripts apply — read them
# side by side to see how "kubectl apply" and "terraform apply" express the
# identical idea.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
    random     = { source = "hashicorp/random",     version = "~> 3.6" }
  }
}

provider "aws" { region = var.region }

data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "../03-cluster/terraform.tfstate" }
}

# Get a fresh authentication token for the cluster on every run.
data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.cluster.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

locals {
  ns        = var.namespace
  bucket    = data.terraform_remote_state.cluster.outputs.s3_bucket
  nifi_role = data.terraform_remote_state.cluster.outputs.nifi_role_arn
  kafka_bootstrap = "kafka-0.kafka.${var.namespace}.svc.cluster.local:9092"
}

resource "kubernetes_namespace" "lab" {
  metadata { name = local.ns }
}

# ---------------------------------------------------------------------------
# StorageClass — WaitForFirstConsumer stops Kubernetes creating a disk in one
# availability zone and then scheduling the pod in another, where it can
# never attach.
# ---------------------------------------------------------------------------
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters             = { type = "gp3", encrypted = "true" }
}

# ---------------------------------------------------------------------------
# Passwords: generated, never typed into a file
# ---------------------------------------------------------------------------
resource "random_password" "keycloak" {
  length  = 24
  special = false
}
resource "random_password" "nifi" {
  length  = 20
  special = false
}

resource "kubernetes_secret" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = local.ns
  }
  data = {
    username = "admin"
    password = random_password.keycloak.result
  }
  depends_on = [kubernetes_namespace.lab]
}

resource "kubernetes_secret" "nifi_user" {
  metadata {
    name      = "nifi-single-user"
    namespace = local.ns
  }
  data = {
    username = "labadmin"
    password = random_password.nifi.result
  }
  depends_on = [kubernetes_namespace.lab]
}

# ---------------------------------------------------------------------------
# The service account that carries NiFi's AWS identity (IRSA).
# The annotation is the entire link between Kubernetes and IAM.
# ---------------------------------------------------------------------------
resource "kubernetes_service_account" "nifi" {
  metadata {
    name        = "nifi"
    namespace   = local.ns
    annotations = { "eks.amazonaws.com/role-arn" = local.nifi_role }
  }
  depends_on = [kubernetes_namespace.lab]
}

# ---------------------------------------------------------------------------
# The applications.
#
# The manifests live as plain YAML in manifests/ — the SAME YAML the shell
# scripts apply. Read the two side by side to see how "kubectl apply" and
# "terraform apply" express the identical idea.
#
# GOTCHA worth knowing: kubernetes_manifest needs the cluster to be reachable
# at PLAN time, not just apply time. So layers 3 and 4 must already exist
# before you run `terraform plan` here. That is why this is a separate layer.
# ---------------------------------------------------------------------------
locals {
  tpl_vars = {
    namespace       = local.ns
    image_keycloak  = var.image_keycloak
    image_kafka     = var.image_kafka
    image_nifi      = var.image_nifi
    image_python    = var.image_python
    kafka_bootstrap = local.kafka_bootstrap
    kafka_topic     = var.kafka_topic
  }
}

# The web app's source code, mounted into a stock python image.
resource "kubernetes_config_map" "webapp_code" {
  metadata {
    name      = "webapp-code"
    namespace = local.ns
  }
  data = {
    "app.py" = file("${path.module}/app/app.py")
  }
  depends_on = [kubernetes_namespace.lab]
}

resource "kubernetes_manifest" "apps" {
  for_each = fileset("${path.module}/manifests", "*.yaml")

  manifest = yamldecode(templatefile("${path.module}/manifests/${each.value}", local.tpl_vars))

  depends_on = [
    kubernetes_storage_class.gp3,
    kubernetes_service_account.nifi,
    kubernetes_secret.keycloak_admin,
    kubernetes_secret.nifi_user,
    kubernetes_config_map.webapp_code,
  ]
}

# ---------------------------------------------------------------------------
# Monitoring (optional — it is the heaviest thing in the lab)
# ---------------------------------------------------------------------------
resource "helm_release" "monitoring" {
  count            = var.enable_monitoring ? 1 : 0
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900

  # Trimmed down to fit a small lab cluster
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "2d"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = "gp3"
  }
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "5Gi"
  }
  set {
    name  = "grafana.persistence.enabled"
    value = "false"
  }
  set {
    name  = "grafana.resources.limits.memory"
    value = "256Mi"
  }

  depends_on = [kubernetes_storage_class.gp3]
}
