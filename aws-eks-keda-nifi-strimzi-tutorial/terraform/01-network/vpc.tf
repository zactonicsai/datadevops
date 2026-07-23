resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # EKS and Kubernetes service discovery need VPC DNS support.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.cluster_name}-vpc"
  }
}
