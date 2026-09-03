module "platform" {
  source              = "./modules/eks-cluster"
  name                = "${var.project}-platform"
  kubernetes_version  = var.kubernetes_version
  vpc_id              = aws_vpc.this.id
  private_subnet_ids  = aws_subnet.private[*].id
  public_subnet_ids   = aws_subnet.public[*].id
  node_instance_types = var.platform_nodes.instance_types
  node_desired        = var.platform_nodes.desired
  node_min            = var.platform_nodes.min
  node_max            = var.platform_nodes.max
  tags                = local.tags
}

module "data" {
  source              = "./modules/eks-cluster"
  name                = "${var.project}-data"
  kubernetes_version  = var.kubernetes_version
  vpc_id              = aws_vpc.this.id
  private_subnet_ids  = aws_subnet.private[*].id
  public_subnet_ids   = aws_subnet.public[*].id
  node_instance_types = var.data_nodes.instance_types
  node_desired        = var.data_nodes.desired
  node_min            = var.data_nodes.min
  node_max            = var.data_nodes.max
  tags                = local.tags
}
