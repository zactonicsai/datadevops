locals {
  is_alb   = var.type == "application"
  protocol = local.is_alb ? (var.certificate_arn != null ? "HTTPS" : "HTTP") : (var.certificate_arn != null ? "TLS" : "TCP")
}

resource "aws_lb" "this" {
  count              = var.create ? 1 : 0
  name               = var.name
  load_balancer_type = var.type
  internal           = var.internal
  subnets            = var.subnet_ids
  security_groups    = local.is_alb ? var.security_group_ids : null
  idle_timeout       = local.is_alb ? var.idle_timeout : null
  tags               = merge(var.tags, { Name = var.name })
}

resource "aws_lb_listener" "main" {
  count             = var.create ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = var.listener_port
  protocol          = local.protocol
  certificate_arn   = var.certificate_arn
  ssl_policy        = var.certificate_arn != null ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null

  dynamic "default_action" {
    for_each = var.default_target_group_arn != null ? [1] : []
    content {
      type             = "forward"
      target_group_arn = var.default_target_group_arn
    }
  }
  dynamic "default_action" {
    for_each = var.default_target_group_arn == null ? [1] : []
    content {
      type = local.is_alb ? "fixed-response" : "forward"
      dynamic "fixed_response" {
        for_each = local.is_alb ? [1] : []
        content {
          content_type = "text/plain"
          message_body = "not found"
          status_code  = "404"
        }
      }
    }
  }
  tags = var.tags
}

resource "aws_lb_listener" "http_redirect" {
  count             = var.create && local.is_alb && var.http_redirect && var.certificate_arn != null ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = tostring(var.listener_port)
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

locals {
  listener_arn = var.create ? aws_lb_listener.main[0].arn : var.existing_https_listener_arn
}

# Host rules work on both created and existing listeners (so an app can add itself to a shared ALB)
resource "aws_lb_listener_rule" "host" {
  for_each     = { for i, r in var.host_rules : "${i}" => r }
  listener_arn = local.listener_arn
  priority     = each.value.priority
  action {
    type             = "forward"
    target_group_arn = each.value.target_group_arn
  }
  condition {
    host_header { values = each.value.hosts }
  }
}

data "aws_lb" "existing" {
  count = var.create ? 0 : 1
  arn   = var.existing_arn
}
