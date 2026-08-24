###############################################################################
# Security groups
#
# Rules are declared as standalone aws_vpc_security_group_*_rule resources
# rather than inline blocks - inline rules cause perpetual diffs and cannot be
# referenced or changed individually.
#
# Traffic path:
#   internet -> ALB (80/443) -> Keycloak (8080, 9000) -> RDS (5432)
###############################################################################

# ----------------------------------------------------------------------------
# ALB
# ----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Ingress to the Keycloak application load balancer"
  vpc_id      = aws_vpc.keycloak.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.enable_https ? toset(var.alb_ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = var.alb_ingress_http_enabled ? toset(var.alb_ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_keycloak_http" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward traffic to Keycloak tasks"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = var.keycloak_http_port
  to_port                      = var.keycloak_http_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_keycloak_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks against the Keycloak management port"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = var.keycloak_management_port
  to_port                      = var.keycloak_management_port
  ip_protocol                  = "tcp"
}

# ----------------------------------------------------------------------------
# Keycloak (ECS tasks)
# ----------------------------------------------------------------------------
resource "aws_security_group" "keycloak" {
  name        = "${local.name_prefix}-keycloak-sg"
  description = "Keycloak Fargate tasks"
  vpc_id      = aws_vpc.keycloak.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-keycloak-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb_http" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Application traffic from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.keycloak_http_port
  to_port                      = var.keycloak_http_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb_health" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Health checks from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.keycloak_management_port
  to_port                      = var.keycloak_management_port
  ip_protocol                  = "tcp"
}

# Infinispan cluster discovery between Keycloak tasks.
resource "aws_vpc_security_group_ingress_rule" "keycloak_cluster" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Infinispan/JGroups traffic between Keycloak nodes"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 7800
  to_port                      = 7801
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_to_database" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "PostgreSQL to RDS"
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_https_out" {
  security_group_id = aws_security_group.keycloak.id
  description       = "HTTPS out for image pulls, Secrets Manager and logs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "keycloak_cluster_out" {
  security_group_id            = aws_security_group.keycloak.id
  description                  = "Infinispan/JGroups traffic to peer nodes"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 7800
  to_port                      = 7801
  ip_protocol                  = "tcp"
}

# ----------------------------------------------------------------------------
# RDS
# ----------------------------------------------------------------------------
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-database-sg"
  description = "Keycloak PostgreSQL database"
  vpc_id      = aws_vpc.keycloak.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-database-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "database_from_keycloak" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL from Keycloak tasks"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_extra_cidrs" {
  for_each = toset(var.extra_database_ingress_cidr_blocks)

  security_group_id = aws_security_group.database.id
  description       = "PostgreSQL from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = var.db_port
  to_port           = var.db_port
  ip_protocol       = "tcp"
}

# ----------------------------------------------------------------------------
# Interface VPC endpoints
# ----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "Interface VPC endpoints"
  vpc_id      = aws_vpc.keycloak.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_keycloak" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from Keycloak tasks"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
