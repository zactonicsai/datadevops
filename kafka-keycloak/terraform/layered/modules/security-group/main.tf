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
  rules = { for i, r in var.ingress : tostring(i) => r if var.create }
}

resource "aws_security_group_rule" "ingress" {
  for_each                 = local.rules
  type                     = "ingress"
  security_group_id        = local.sg_id
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  cidr_blocks              = length(each.value.cidr_blocks) > 0 ? each.value.cidr_blocks : null
  source_security_group_id = each.value.source_security_group_id
  self                     = each.value.self ? true : null
  description              = each.value.description
}

resource "aws_security_group_rule" "egress" {
  count             = var.create && var.egress_all ? 1 : 0
  type              = "egress"
  security_group_id = local.sg_id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
