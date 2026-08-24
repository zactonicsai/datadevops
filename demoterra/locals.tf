###############################################################################
# Locals - naming convention, tagging and derived values
###############################################################################

locals {
  # Every resource is prefixed consistently: <project>-<environment>
  name_prefix = "${var.project_name}-${var.environment}"

  tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      Component   = "keycloak"
      ManagedBy   = "terraform"
      Owner       = var.owner
      CostCenter  = var.cost_center
    },
    var.additional_tags
  )

  # Use the requested AZ count, but never more AZs than the region offers.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.az_count, length(data.aws_availability_zones.available.names))
  )

  # Deterministic /24-style subnet carving from the VPC CIDR.
  #   public   -> newbits offset 0
  #   private  -> newbits offset az_count
  #   database -> newbits offset az_count * 2
  public_subnet_cidrs = [
    for i in range(length(local.azs)) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
  ]

  private_subnet_cidrs = [
    for i in range(length(local.azs)) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + length(local.azs))
  ]

  database_subnet_cidrs = [
    for i in range(length(local.azs)) :
    cidrsubnet(var.vpc_cidr, var.subnet_newbits, i + (length(local.azs) * 2))
  ]

  # Keycloak is reached over this hostname; falls back to the ALB DNS name.
  keycloak_hostname = coalesce(var.keycloak_hostname, aws_lb.keycloak.dns_name)

  enable_https = var.acm_certificate_arn != null && var.acm_certificate_arn != ""
}
