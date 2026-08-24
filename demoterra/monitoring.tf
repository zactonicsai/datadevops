###############################################################################
# Alarms - the few that matter, wired to one SNS topic
###############################################################################

resource "aws_sns_topic" "alerts" {
  count = var.enable_alarms && var.alarm_sns_topic_arn == null ? 1 : 0

  name = "${local.name_prefix}-alerts"

  tags = { Name = "${local.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "alert_email" {
  for_each = var.enable_alarms && var.alarm_sns_topic_arn == null ? toset(var.alarm_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  alarm_actions = var.enable_alarms ? [
    coalesce(var.alarm_sns_topic_arn, try(aws_sns_topic.alerts[0].arn, null))
  ] : []
}

# No healthy targets means Keycloak is down. Missing data is treated as
# breaching, because silence here is also bad news.
resource "aws_cloudwatch_metric_alarm" "no_healthy_hosts" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-alb-no-healthy-targets"
  alarm_description = "CRITICAL: no healthy Keycloak targets behind the ALB."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = { Name = "${local.name_prefix}-alb-no-healthy-targets" }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-alb-5xx"
  alarm_description = "The load balancer is generating 5xx responses."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-alb-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-rds-free-storage-low"
  alarm_description = "The Keycloak database is running out of storage."

  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = var.alarm_rds_free_storage_bytes
  period              = 300
  evaluation_periods  = 1
  treat_missing_data  = "breaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.keycloak.identifier
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = { Name = "${local.name_prefix}-rds-free-storage-low" }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-rds-cpu-high"
  alarm_description = "The Keycloak database is CPU saturated."

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.keycloak.identifier
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-rds-cpu-high" }
}
