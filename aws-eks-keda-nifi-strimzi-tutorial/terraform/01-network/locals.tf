data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two Availability Zones satisfy the EKS multi-AZ networking requirement.
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  # Split the selected VPC CIDR into four equal ranges. The default /16 becomes /20 subnets.
  # Using cidrsubnet keeps the subnet plan tied to vpc_cidr instead of fixed addresses.
  public_subnet_cidrs = [
    cidrsubnet(var.vpc_cidr, 4, 0),
    cidrsubnet(var.vpc_cidr, 4, 1),
  ]

  private_subnet_cidrs = [
    cidrsubnet(var.vpc_cidr, 4, 2),
    cidrsubnet(var.vpc_cidr, 4, 3),
  ]

  cluster_name = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Tutorial    = "EKS-KEDA-NiFi-Strimzi"
  }
}
