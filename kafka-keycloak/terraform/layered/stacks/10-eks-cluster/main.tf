locals {
  tags = { Project = var.project, Environment = var.environment, Stack = "10-eks-cluster", ManagedBy = "terraform" }
}

data "terraform_remote_state" "network" {
  count   = var.subnet_ids == null ? 1 : 0
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_key_prefix}/00-network.tfstate"
    region = local.state_region
  }
}

locals {
  subnet_ids = coalesce(var.subnet_ids, try(concat(
    data.terraform_remote_state.network[0].outputs.private_subnet_ids,
    data.terraform_remote_state.network[0].outputs.public_subnet_ids
  ), null))
}

module "cluster_role" {
  source              = "../../modules/iam-role"
  create              = var.existing_cluster_role_arn == null
  existing_role_arn   = var.existing_cluster_role_arn
  name                = "${var.cluster_name}-cluster"
  trusted_services    = ["eks.amazonaws.com"]
  managed_policy_arns = ["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
  tags                = local.tags
}

module "cluster" {
  source                       = "../../modules/eks-cluster"
  create                       = var.create_cluster
  existing_cluster_name        = var.cluster_name
  name                         = var.cluster_name
  kubernetes_version           = var.kubernetes_version
  subnet_ids                   = local.subnet_ids
  cluster_role_arn             = module.cluster_role.arn
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  tags                         = local.tags
}
