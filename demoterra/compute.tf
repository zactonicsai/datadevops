###############################################################################
# Keycloak on EC2 with Docker
#
# A launch template bootstraps each instance (install Docker, read credentials
# from Secrets Manager, run the container) and an Auto Scaling Group keeps the
# desired number of them registered with the ALB target group.
###############################################################################

# Latest Amazon Linux 2023 AMI, unless one is pinned explicitly.
data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/aws/ec2/${local.name_prefix}/keycloak"
  retention_in_days = var.log_retention_in_days

  tags = { Name = "${local.name_prefix}-logs" }
}

resource "aws_launch_template" "keycloak" {
  name_prefix   = "${local.name_prefix}-"
  image_id      = coalesce(var.ami_id, try(data.aws_ssm_parameter.al2023[0].value, null))
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = data.aws_iam_instance_profile.keycloak.name
  }

  vpc_security_group_ids = [aws_security_group.keycloak.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 only.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    region            = data.aws_region.current.name
    keycloak_image    = var.keycloak_image
    keycloak_hostname = local.keycloak_hostname
    http_port         = var.keycloak_http_port
    management_port   = var.keycloak_management_port
    health_path       = var.health_check_path
    log_group         = aws_cloudwatch_log_group.keycloak.name
    db_host           = aws_db_instance.keycloak.address
    db_port           = var.db_port
    db_name           = var.db_name
    db_username       = var.db_username
    db_secret_arn     = aws_secretsmanager_secret.db.arn
    admin_secret_arn  = aws_secretsmanager_secret.keycloak_admin.arn
    extra_environment = var.keycloak_extra_environment
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name_prefix}-keycloak" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "${local.name_prefix}-keycloak-root" })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-lt" }

  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_secretsmanager_secret_version.keycloak_admin,
  ]
}

resource "aws_autoscaling_group" "keycloak" {
  name                = "${local.name_prefix}-asg"
  vpc_zone_identifier = values(aws_subnet.private)[*].id

  desired_capacity = var.asg_desired_capacity
  min_size         = var.asg_min_size
  max_size         = var.asg_max_size

  # Replace an instance when the ALB says it is unhealthy, not just when EC2
  # says the hardware is fine.
  health_check_type         = "ELB"
  health_check_grace_period = var.health_check_grace_period
  target_group_arns         = [aws_lb_target_group.keycloak.arn]

  launch_template {
    id      = aws_launch_template.keycloak.id
    version = "$Latest"
  }

  # Rolling replacement when the launch template changes.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = var.instance_refresh_min_healthy_percent
      instance_warmup        = var.health_check_grace_period
    }
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = "${local.name_prefix}-keycloak" })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_db_instance.keycloak,
  ]
}

resource "aws_autoscaling_policy" "keycloak_cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name                   = "${local.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.keycloak.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    target_value = var.autoscaling_cpu_target

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
