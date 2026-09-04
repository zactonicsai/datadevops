locals {
  cluster_tags = { for n in var.eks_cluster_names : "kubernetes.io/cluster/${n}" => "shared" }
}

module "vpc" {
  source                      = "../../modules/aws/vpc"
  create                      = var.vpc.create
  existing_vpc_id             = var.vpc.existing_vpc_id
  existing_public_subnet_ids  = var.vpc.existing_public_subnet_ids
  existing_private_subnet_ids = var.vpc.existing_private_subnet_ids
  name                        = "${var.project}-${var.vpc.name}"
  cidr                        = var.vpc.cidr
  az_count                    = var.vpc.az_count
  single_nat_gateway          = var.vpc.single_nat_gateway
  public_subnet_tags          = merge({ "kubernetes.io/role/elb" = "1" }, local.cluster_tags)
  private_subnet_tags         = merge({ "kubernetes.io/role/internal-elb" = "1" }, local.cluster_tags)
  tags                        = local.tags
}
