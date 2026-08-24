###############################################################################
# Monitoring and alarming
#
# Resilience is only real if you find out when a layer degrades. Every alarm
# here treats missing data as breaching where absence itself is the signal.
###############################################################################

resource "aws_sns_topic" "alerts" {
  count = var.enable_alarms && var.alarm_sns_topic_arn == null ? 1 : 0

  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = var.secrets_kms_key_arn != null ? var.secrets_kms_key_arn : "alias/aws/sns"

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

# ----------------------------------------------------------------------------
# Load balancer
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-alb-unhealthy-targets"
  alarm_description = "One or more Keycloak targets are failing ALB health checks."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = { Name = "${local.name_prefix}-alb-unhealthy-targets" }
}

resource "aws_cloudwatch_metric_alarm" "alb_no_healthy_hosts" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-alb-no-healthy-targets"
  alarm_description = "CRITICAL: Keycloak has no healthy targets - the service is down."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  period              = var.alarm_period_seconds
  evaluation_periods  = 1
  # Absent data here means the ALB is not reporting - treat that as an outage.
  treat_missing_data = "breaching"

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
  threshold           = var.alarm_alb_5xx_threshold
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-alb-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-alb-target-latency"
  alarm_description = "Keycloak response times are elevated."

  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_target_response_time
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.keycloak.arn_suffix
    TargetGroup  = aws_lb_target_group.keycloak.arn_suffix
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-alb-target-latency" }
}

# ----------------------------------------------------------------------------
# ECS service
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-ecs-task-count-low"
  alarm_description = "Fewer Keycloak tasks are running than the configured minimum."

  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = var.enable_autoscaling ? var.autoscaling_min_capacity : var.keycloak_desired_count
  period              = var.alarm_period_seconds
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.keycloak.name
    ServiceName = aws_ecs_service.keycloak.name
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = { Name = "${local.name_prefix}-ecs-task-count-low" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-ecs-cpu-high"
  alarm_description = "Keycloak tasks are CPU saturated."

  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  period              = 300
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.keycloak.name
    ServiceName = aws_ecs_service.keycloak.name
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-ecs-cpu-high" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_high" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-ecs-memory-high"
  alarm_description = "Keycloak tasks are approaching their memory limit - OOM kills are likely."

  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  period              = 300
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.keycloak.name
    ServiceName = aws_ecs_service.keycloak.name
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-ecs-memory-high" }
}

# ----------------------------------------------------------------------------
# RDS
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-rds-cpu-high"
  alarm_description = "The Keycloak database is CPU saturated."

  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.alarm_rds_cpu_threshold
  period              = 300
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.keycloak.identifier
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-rds-cpu-high" }
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

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  count = var.enable_alarms ? 1 : 0

  alarm_name        = "${local.name_prefix}-rds-connections-high"
  alarm_description = "Database connection count is unusually high - check the Keycloak pool settings."

  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.autoscaling_max_capacity * 20
  period              = 300
  evaluation_periods  = var.alarm_evaluation_periods
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.keycloak.identifier
  }

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name_prefix}-rds-connections-high" }
}
