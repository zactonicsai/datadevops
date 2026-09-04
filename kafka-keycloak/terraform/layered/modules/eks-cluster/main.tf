resource "aws_eks_cluster" "this" {
  count    = var.create ? 1 : 0
  name     = var.name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = var.additional_security_group_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = var.enabled_log_types
  tags                      = var.tags
}

data "aws_eks_cluster" "existing" {
  count = var.create ? 0 : 1
  name  = var.existing_cluster_name
}

locals {
  name        = var.create ? aws_eks_cluster.this[0].name : data.aws_eks_cluster.existing[0].name
  endpoint    = var.create ? aws_eks_cluster.this[0].endpoint : data.aws_eks_cluster.existing[0].endpoint
  ca          = var.create ? aws_eks_cluster.this[0].certificate_authority[0].data : data.aws_eks_cluster.existing[0].certificate_authority[0].data
  oidc_issuer = var.create ? aws_eks_cluster.this[0].identity[0].oidc[0].issuer : data.aws_eks_cluster.existing[0].identity[0].oidc[0].issuer
  cluster_sg  = var.create ? aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id : data.aws_eks_cluster.existing[0].vpc_config[0].cluster_security_group_id
}

data "tls_certificate" "oidc" {
  count = var.create ? 1 : 0
  url   = local.oidc_issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  count           = var.create ? 1 : 0
  url             = local.oidc_issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]
  tags            = var.tags
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create ? 0 : 1
  url   = local.oidc_issuer
}
