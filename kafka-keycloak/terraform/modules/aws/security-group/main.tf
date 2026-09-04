resource "aws_security_group" "this" {
  count       = var.create ? 1 : 0
  name        = var.name
  description = var.description
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = var.name })
  lifecycle { create_before_destroy = true }
}

locals {
  sg_id = var.create ? aws_security_group.this[0].id : var.existing_id
}

# Rules are applied even to an EXISTING group (so an app can add its ports to a shared SG).
resource "aws_security_group_rule" "ingress" {
  for_each                 = { for i, r in var.ingress_rules : "${i}" => r }
  type                     = "ingress"
  security_group_id        = local.sg_id
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  cidr_blocks              = each.value.cidr_blocks
  source_security_group_id = each.value.source_security_group_id
  self                     = each.value.self
  description              = each.value.description
}

resource "aws_security_group_rule" "egress" {
  for_each                 = { for i, r in var.egress_rules : "${i}" => r }
  type                     = "egress"
  security_group_id        = local.sg_id
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  cidr_blocks              = each.value.cidr_blocks
  source_security_group_id = each.value.source_security_group_id
  self                     = each.value.self
  description              = each.value.description
}
