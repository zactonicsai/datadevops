resource "aws_lb_target_group" "this" {
  count                = var.create ? 1 : 0
  name                 = substr(var.name, 0, 32)
  vpc_id               = var.vpc_id
  port                 = var.port
  protocol             = var.protocol
  target_type          = var.target_type
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check.path
    port                = var.health_check.port
    matcher             = var.health_check.matcher
    interval            = var.health_check.interval
    healthy_threshold   = var.health_check.healthy_threshold
    unhealthy_threshold = var.health_check.unhealthy_threshold
    timeout             = var.health_check.timeout
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = var.stickiness_enabled
    cookie_duration = 86400
  }

  tags = merge(var.tags, { Name = var.name })
  lifecycle { create_before_destroy = true }
}
