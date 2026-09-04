resource "aws_lb" "this" {
  count              = var.create ? 1 : 0
  name               = substr(var.name, 0, 32)
  internal           = var.internal
  load_balancer_type = "application"
  subnets            = var.subnet_ids
  security_groups    = var.security_group_ids
  idle_timeout       = var.idle_timeout
  tags               = merge(var.tags, { Name = var.name })
}

locals {
  https = var.create && var.certificate_arn != null
}

resource "aws_lb_listener" "https" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = var.default_target_group_arn == null ? "fixed-response" : "forward"
    target_group_arn = var.default_target_group_arn
    dynamic "fixed_response" {
      for_each = var.default_target_group_arn == null ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "no route"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "http" {
  count             = var.create ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = local.https ? "redirect" : (var.default_target_group_arn == null ? "fixed-response" : "forward")
    target_group_arn = local.https ? null : var.default_target_group_arn
    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    dynamic "fixed_response" {
      for_each = !local.https && var.default_target_group_arn == null ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "no route"
        status_code  = "404"
      }
    }
  }
}

locals {
  main_listener_arn = local.https ? aws_lb_listener.https[0].arn : (var.create ? aws_lb_listener.http[0].arn : var.existing_https_listener_arn)
}

resource "aws_lb_listener_rule" "host" {
  for_each     = var.host_rules
  listener_arn = local.main_listener_arn
  action {
    type             = "forward"
    target_group_arn = each.value
  }
  condition {
    host_header { values = [each.key] }
  }
}
