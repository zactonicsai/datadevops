locals {
  net        = data.terraform_remote_state.network.outputs
  subnet_ids = var.cluster.subnet_ids != null ? var.cluster.subnet_ids : concat(local.net.private_subnet_ids, local.net.public_subnet_ids)
}

# ---- control-plane IAM role (core module) ----
module "cluster_role" {
  source             = "../../modules/aws/iam-role"
  create             = var.cluster_role.create
  existing_role_name = var.cluster_role.existing_role_name
  name               = "${var.cluster.name}-eks-cluster"
  trusted_services   = ["eks.amazonaws.com"]
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
  ]
  tags = local.tags
}

# ---- cluster (core module) — addons applied in a second module call below so IRSA exists first ----
module "eks" {
  source                 = "../../modules/aws/eks-cluster"
  create                 = var.cluster.create
  existing_cluster_name  = var.cluster.existing_cluster_name
  name                   = var.cluster.name
  kubernetes_version     = var.cluster.kubernetes_version
  cluster_role_arn       = module.cluster_role.role_arn
  subnet_ids             = local.subnet_ids
  endpoint_public_access = var.cluster.endpoint_public_access
  public_access_cidrs    = var.cluster.public_access_cidrs
  enabled_log_types      = var.cluster.enabled_log_types
  enable_irsa            = true
  addons = {
    for name, ver in var.addons : name => {
      version                  = ver
      service_account_role_arn = name == "aws-ebs-csi-driver" ? module.ebs_csi_role.role_arn : null
    }
  }
  tags = local.tags
}

# ---- IRSA role for the EBS CSI add-on (core module) ----
module "ebs_csi_role" {
  source = "../../modules/aws/iam-role"
  name   = "${var.cluster.name}-ebs-csi"
  oidc = {
    provider_arn     = module.eks.oidc_provider_arn
    issuer_host      = module.eks.oidc_issuer_host
    service_accounts = ["kube-system:ebs-csi-controller-sa"]
  }
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  tags                = local.tags
}
