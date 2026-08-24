###############################################################################
# Application Load Balancer
# Public subnets, HTTP -> HTTPS redirect, instance target group fed by the ASG.
###############################################################################

resource "aws_lb" "keycloak" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = var.alb_internal
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_internal ? values(aws_subnet.private)[*].id : values(aws_subnet.public)[*].id

  idle_timeout                     = var.alb_idle_timeout
  enable_deletion_protection       = var.alb_deletion_protection
  enable_cross_zone_load_balancing = true
  drop_invalid_header_fields       = true
  enable_http2                     = true

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket == null ? [] : [1]

    content {
      bucket  = var.alb_access_logs_bucket
      prefix  = local.name_prefix
      enabled = true
    }
  }

  tags = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "keycloak" {
  name        = "${local.name_prefix}-tg"
  port        = var.keycloak_http_port
  protocol    = "HTTP"
  target_type = "instance" # the Auto Scaling Group registers its instances here
  vpc_id      = aws_vpc.keycloak.id

  deregistration_delay = var.deregistration_delay
  # Ramp traffic into a freshly started task instead of hitting a cold JVM
  # with full production load the moment it passes its first health check.
  slow_start = var.target_group_slow_start

  health_check {
    enabled = true
    path    = var.health_check_path
    # Keycloak 25+ serves /health/* on the separate management port.
    port                = tostring(var.keycloak_management_port)
    protocol            = "HTTP"
    matcher             = "200"
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    interval            = var.health_check_interval
    timeout             = var.health_check_timeout
  }

  dynamic "stickiness" {
    for_each = var.enable_stickiness ? [1] : []

    content {
      type            = "lb_cookie"
      cookie_duration = var.stickiness_duration
      enabled         = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-tg" }
}

# ----------------------------------------------------------------------------
# Listeners
# ----------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  count = var.alb_ingress_http_enabled ? 1 : 0

  load_balancer_arn = aws_lb.keycloak.arn
  port              = 80
  protocol          = "HTTP"

  # Redirect to HTTPS when a certificate exists, otherwise serve directly.
  dynamic "default_action" {
    for_each = local.enable_https ? [1] : []

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.enable_https ? [] : [1]

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.keycloak.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.keycloak.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.keycloak.arn
  }
}
