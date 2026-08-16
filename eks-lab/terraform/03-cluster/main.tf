# =============================================================================
# LAYER 3 — the EKS control plane, the S3 bucket, and the IRSA roles.
#
# Takes 10-15 minutes. This is where the $0.10/hour starts.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags { tags = var.tags }
}

data "terraform_remote_state" "vpc" {
  backend = "local"
  config  = { path = "../01-vpc/terraform.tfstate" }
}

data "terraform_remote_state" "iam" {
  backend = "local"
  config  = { path = "../02-iam-sg/terraform.tfstate" }
}

data "aws_caller_identity" "current" {}

locals {
  name         = var.lab_name
  cluster_name = "${var.lab_name}-eks"
  all_subnets  = concat(
    data.terraform_remote_state.vpc.outputs.public_subnet_ids,
    data.terraform_remote_state.vpc.outputs.private_subnet_ids,
  )
}

# ---------------------------------------------------------------------------
# The cluster
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = data.terraform_remote_state.iam.outputs.cluster_role_arn

  vpc_config {
    subnet_ids              = local.all_subnets
    security_group_ids      = [data.terraform_remote_state.iam.outputs.node_sg_id]
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # "API" = modern access entries. The old aws-auth ConfigMap could lock you
  # out of your own cluster permanently with a single typo; access entries
  # are ordinary AWS objects you can always repair.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # A lab safety rail. Uncomment for anything you would be sad to lose:
  # lifecycle { prevent_destroy = true }
}

# Keep the cluster's log group under Terraform's control so it has a
# retention period. Log groups created implicitly never expire and quietly
# accumulate charges forever.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# OIDC provider — the thing that makes IRSA possible
# ---------------------------------------------------------------------------
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

locals {
  oidc_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# ---------------------------------------------------------------------------
# The destination S3 bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "messages" {
  bucket        = "${local.name}-messages-${data.aws_caller_identity.current.account_id}"
  force_destroy = true   # lab convenience: lets `terraform destroy` empty it.
                         # NEVER set this on a bucket with real data.
}

resource "aws_s3_bucket_public_access_block" "messages" {
  bucket                  = aws_s3_bucket.messages.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "messages" {
  bucket = aws_s3_bucket.messages.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "messages" {
  bucket = aws_s3_bucket.messages.id
  versioning_configuration { status = "Enabled" }
}

# Auto-delete lab data after 7 days so forgotten objects stop costing money.
resource "aws_s3_bucket_lifecycle_configuration" "messages" {
  bucket = aws_s3_bucket.messages.id
  rule {
    id     = "lab-cleanup"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# ---------------------------------------------------------------------------
# IRSA role for NiFi — ONE service account may write to ONE bucket
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "nifi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    # This condition is the whole security boundary. Get the namespace or
    # service-account name wrong and the pod silently falls back to the
    # node's permissions instead — with no error message.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.namespace}:nifi"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "nifi_s3" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.messages.arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.messages.arn]
  }
}

resource "aws_iam_role" "nifi" {
  name               = "${local.name}-nifi-irsa"
  assume_role_policy = data.aws_iam_policy_document.nifi_assume.json
}

resource "aws_iam_role_policy" "nifi" {
  name   = "${local.name}-nifi-s3"
  role   = aws_iam_role.nifi.id
  policy = data.aws_iam_policy_document.nifi_s3.json
}

# ---------------------------------------------------------------------------
# IRSA role for the EBS CSI driver, so pods can get persistent disks
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ebs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# Managed add-ons
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
}
