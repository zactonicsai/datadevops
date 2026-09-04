locals {
  tags         = { Project = var.project, Environment = var.environment, Stack = "00-network", ManagedBy = "terraform" }
  cluster_tags = { for n in var.eks_cluster_names : "kubernetes.io/cluster/${n}" => "shared" }
}

module "vpc" {
  source                      = "../../modules/vpc"
  create                      = var.create_vpc
  name                        = "${var.project}-${var.environment}"
  cidr                        = var.vpc_cidr
  az_count                    = var.az_count
  single_nat_gateway          = var.single_nat_gateway
  public_subnet_tags          = merge(local.cluster_tags, { "kubernetes.io/role/elb" = "1" })
  private_subnet_tags         = merge(local.cluster_tags, { "kubernetes.io/role/internal-elb" = "1" })
  existing_vpc_id             = var.existing_vpc_id
  existing_public_subnet_ids  = var.existing_public_subnet_ids
  existing_private_subnet_ids = var.existing_private_subnet_ids
  tags                        = local.tags
}
