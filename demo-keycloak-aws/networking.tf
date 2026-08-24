###############################################################################
# Networking - VPC, three subnet tiers, routing and NAT
#
# Tier layout (per AZ):
#   public   -> ALB + NAT Gateway
#   private  -> Keycloak ECS tasks (no inbound from internet)
#   database -> RDS only, no route to the internet at all
###############################################################################

resource "aws_vpc" "keycloak" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = { Name = "${local.name_prefix}-vpc" }
}

# ----------------------------------------------------------------------------
# Internet Gateway
# ----------------------------------------------------------------------------
resource "aws_internet_gateway" "keycloak" {
  vpc_id = aws_vpc.keycloak.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# ----------------------------------------------------------------------------
# Subnets
# ----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id                  = aws_vpc.keycloak.id
  availability_zone       = each.key
  cidr_block              = local.public_subnet_cidrs[each.value]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id            = aws_vpc.keycloak.id
  availability_zone = each.key
  cidr_block        = local.private_subnet_cidrs[each.value]

  tags = {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_subnet" "database" {
  for_each = { for idx, az in local.azs : az => idx }

  vpc_id            = aws_vpc.keycloak.id
  availability_zone = each.key
  cidr_block        = local.database_subnet_cidrs[each.value]

  tags = {
    Name = "${local.name_prefix}-database-${each.key}"
    Tier = "database"
  }
}

# ----------------------------------------------------------------------------
# NAT Gateways - one per AZ, or a single shared one for non-prod
# ----------------------------------------------------------------------------
locals {
  nat_gateway_azs = var.enable_nat_gateway ? (
    var.single_nat_gateway ? [local.azs[0]] : local.azs
  ) : []
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_gateway_azs)

  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip-${each.key}" }

  depends_on = [aws_internet_gateway.keycloak]
}

resource "aws_nat_gateway" "keycloak" {
  for_each = toset(local.nat_gateway_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = { Name = "${local.name_prefix}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.keycloak]
}

# ----------------------------------------------------------------------------
# Route tables
# ----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.keycloak.id

  tags = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.keycloak.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each can target its own NAT Gateway.
resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.keycloak.id

  tags = { Name = "${local.name_prefix}-rt-private-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each = var.enable_nat_gateway ? aws_subnet.private : {}

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = var.single_nat_gateway ? aws_nat_gateway.keycloak[local.azs[0]].id : aws_nat_gateway.keycloak[each.key].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# Database tier is fully isolated - local VPC routing only.
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.keycloak.id

  tags = { Name = "${local.name_prefix}-rt-database" }
}

resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

# ----------------------------------------------------------------------------
# VPC endpoints - keep Secrets Manager / ECR / Logs traffic off the NAT
# ----------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.keycloak.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = values(aws_route_table.private)[*].id

  tags = { Name = "${local.name_prefix}-vpce-s3" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["secretsmanager", "ecr.api", "ecr.dkr", "logs"])

  vpc_id              = aws_vpc.keycloak.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(aws_subnet.private)[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-vpce-${replace(each.key, ".", "-")}" }
}

# ----------------------------------------------------------------------------
# Flow logs (optional) - uses a pre-existing IAM role
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.log_retention_in_days
}

resource "aws_flow_log" "keycloak_vpc" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.keycloak.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = data.aws_iam_role.vpc_flow_logs[0].arn

  tags = { Name = "${local.name_prefix}-flow-logs" }
}
