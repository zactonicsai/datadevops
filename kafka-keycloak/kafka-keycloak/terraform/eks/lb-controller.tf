# AWS Load Balancer Controller on BOTH clusters, from the vendored local chart.
locals {
  lbc_values = {
    region                 = var.region
    vpcId                  = aws_vpc.this.id
    enableServiceMutatorWebhook = false
  }
}

# ---- platform ----
resource "kubernetes_service_account_v1" "lbc_platform" {
  provider = kubernetes.platform
  metadata {
    name        = "aws-load-balancer-controller"
    namespace   = "kube-system"
    annotations = { "eks.amazonaws.com/role-arn" = module.platform.lbc_role_arn }
  }
  depends_on = [module.platform]
}

resource "helm_release" "lbc_platform" {
  provider  = helm.platform
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"
  chart     = local.charts.lbc # local directory, no repository
  wait      = true
  timeout   = 600
  values = [yamlencode(merge(local.lbc_values, {
    clusterName    = module.platform.name
    serviceAccount = { create = false, name = kubernetes_service_account_v1.lbc_platform.metadata[0].name }
  }))]
}

# ---- data ----
resource "kubernetes_service_account_v1" "lbc_data" {
  provider = kubernetes.data
  metadata {
    name        = "aws-load-balancer-controller"
    namespace   = "kube-system"
    annotations = { "eks.amazonaws.com/role-arn" = module.data.lbc_role_arn }
  }
  depends_on = [module.data]
}

resource "helm_release" "lbc_data" {
  provider  = helm.data
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"
  chart     = local.charts.lbc
  wait      = true
  timeout   = 600
  values = [yamlencode(merge(local.lbc_values, {
    clusterName    = module.data.name
    serviceAccount = { create = false, name = kubernetes_service_account_v1.lbc_data.metadata[0].name }
  }))]
}

# gp3 default StorageClass on the data cluster (Kafka volumes)
resource "kubernetes_storage_class_v1" "gp3" {
  provider = kubernetes.data
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [module.data]
}
