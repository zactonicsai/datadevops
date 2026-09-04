resource "aws_lb_target_group" "this" {
  count                = var.create ? 1 : 0
  name                 = var.name
  vpc_id               = var.vpc_id
  port                 = var.port
  protocol             = var.protocol
  target_type          = var.target_type
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.protocol == "TCP" ? null : var.health_check.path
    port                = var.health_check.port
    protocol            = var.health_check.protocol
    matcher             = var.protocol == "TCP" ? null : var.health_check.matcher
    interval            = var.health_check.interval
    timeout             = var.protocol == "TCP" ? null : var.health_check.timeout
    healthy_threshold   = var.health_check.healthy_threshold
    unhealthy_threshold = var.health_check.unhealthy_threshold
  }

  dynamic "stickiness" {
    for_each = var.stickiness.enabled ? [1] : []
    content {
      enabled         = true
      type            = var.stickiness.type
      cookie_duration = var.stickiness.duration
    }
  }

  tags = merge(var.tags, { Name = var.name })
  lifecycle { create_before_destroy = true }
}
