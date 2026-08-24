###############################################################################
# ECS Fargate service running the Keycloak Docker image
#
# Resilience posture:
#   - tasks spread across every AZ, with automatic AZ rebalancing
#   - rolling deployments never drop below 100% healthy capacity
#   - circuit breaker rolls back a bad deployment automatically
#   - container-level readiness probe plus ALB health checks
#   - autoscaling on CPU, memory and (optionally) request count
###############################################################################

resource "aws_ecs_cluster" "keycloak" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = { Name = "${local.name_prefix}-cluster" }
}

resource "aws_ecs_cluster_capacity_providers" "keycloak" {
  cluster_name       = aws_ecs_cluster.keycloak.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  # On-demand only by default - Spot interruptions are not worth it for an
  # identity provider that everything else depends on.
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_cloudwatch_log_group" "keycloak" {
  name              = "/aws/ecs/${local.name_prefix}/keycloak"
  retention_in_days = var.log_retention_in_days

  tags = { Name = "${local.name_prefix}-logs" }
}

locals {
  # Base Keycloak configuration. Anything here can be overridden or extended
  # through var.keycloak_extra_environment.
  keycloak_environment = merge(
    {
      KC_DB              = "postgres"
      KC_DB_URL_HOST     = aws_db_instance.keycloak.address
      KC_DB_URL_PORT     = tostring(var.db_port)
      KC_DB_URL_DATABASE = var.db_name
      KC_DB_USERNAME     = var.db_username
      KC_DB_SCHEMA       = "public"

      # Connection pool sized so all tasks together stay within RDS limits,
      # and so a database blip does not wedge every request thread.
      KC_DB_POOL_INITIAL_SIZE = "5"
      KC_DB_POOL_MIN_SIZE     = "5"
      KC_DB_POOL_MAX_SIZE     = "20"

      # Terminating TLS at the ALB - trust the X-Forwarded-* headers.
      KC_HTTP_ENABLED    = "true"
      KC_HTTP_PORT       = tostring(var.keycloak_http_port)
      KC_PROXY_HEADERS   = "xforwarded"
      KC_HOSTNAME        = local.keycloak_hostname
      KC_HOSTNAME_STRICT = "false"

      # Health and metrics on the dedicated management port used by the ALB.
      KC_HEALTH_ENABLED  = "true"
      KC_METRICS_ENABLED = "true"

      # Cluster discovery via the shared database - no multicast on Fargate.
      # Sessions survive the loss of a single node because caches are replicated.
      KC_CACHE       = "ispn"
      KC_CACHE_STACK = "jdbc-ping"

      KC_LOG                      = "console"
      KC_LOG_CONSOLE_OUTPUT       = "json"
      KC_BOOTSTRAP_ADMIN_USERNAME = var.keycloak_admin_username
    },
    var.keycloak_extra_environment
  )

  # Readiness probe without curl: the Keycloak image ships bash, so use /dev/tcp.
  container_health_check = var.enable_container_health_check ? {
    command = [
      "CMD-SHELL",
      "exec 3<>/dev/tcp/127.0.0.1/${var.keycloak_management_port} && echo -e 'GET ${var.health_check_path} HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && cat <&3 | grep -q '\"status\": \"UP\"'"
    ]
    interval    = 30
    timeout     = 10
    retries     = 3
    startPeriod = 180
  } : null
}

resource "aws_ecs_task_definition" "keycloak" {
  family                   = "${local.name_prefix}-keycloak"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.keycloak_cpu
  memory                   = var.keycloak_memory
  execution_role_arn       = data.aws_iam_role.ecs_task_execution.arn
  task_role_arn            = data.aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name        = "keycloak"
      image       = var.keycloak_image
      essential   = true
      command     = ["start"]
      stopTimeout = var.container_stop_timeout

      portMappings = [
        {
          name          = "http"
          containerPort = var.keycloak_http_port
          protocol      = "tcp"
        },
        {
          name          = "management"
          containerPort = var.keycloak_management_port
          protocol      = "tcp"
        }
      ]

      environment = [
        for k, v in local.keycloak_environment : {
          name  = k
          value = v
        }
      ]

      # Injected at runtime by the execution role - never baked into the image
      # and never visible in the task definition.
      secrets = [
        {
          name      = "KC_DB_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
        },
        {
          name      = "KC_BOOTSTRAP_ADMIN_PASSWORD"
          valueFrom = "${aws_secretsmanager_secret.keycloak_admin.arn}:password::"
        }
      ]

      healthCheck = local.container_health_check

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.keycloak.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "keycloak"
        }
      }

      ulimits = [
        {
          name      = "nofile"
          softLimit = 65536
          hardLimit = 65536
        }
      ]
    }
  ])

  tags = { Name = "${local.name_prefix}-keycloak-task" }

  depends_on = [
    aws_secretsmanager_secret_version.db,
    aws_secretsmanager_secret_version.keycloak_admin,
  ]
}

resource "aws_ecs_service" "keycloak" {
  name            = "${local.name_prefix}-keycloak"
  cluster         = aws_ecs_cluster.keycloak.id
  task_definition = aws_ecs_task_definition.keycloak.arn
  desired_count   = var.keycloak_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  health_check_grace_period_seconds = var.health_check_grace_period

  deployment_maximum_percent         = var.deployment_maximum_percent
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  wait_for_steady_state              = false

  # Keeps tasks evenly spread when an AZ recovers from an impairment.
  availability_zone_rebalancing = var.enable_az_rebalancing ? "ENABLED" : "DISABLED"

  deployment_circuit_breaker {
    enable   = var.enable_deployment_circuit_breaker
    rollback = var.enable_deployment_circuit_breaker
  }

  network_configuration {
    subnets          = values(aws_subnet.private)[*].id
    security_groups  = [aws_security_group.keycloak.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.keycloak.arn
    container_name   = "keycloak"
    container_port   = var.keycloak_http_port
  }

  lifecycle {
    # Let autoscaling own the task count once it is enabled.
    ignore_changes = [desired_count]
  }

  tags = { Name = "${local.name_prefix}-keycloak-service" }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener.https,
    aws_db_instance.keycloak,
  ]
}

# ----------------------------------------------------------------------------
# Autoscaling
# ----------------------------------------------------------------------------
resource "aws_appautoscaling_target" "keycloak" {
  count = var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.keycloak.name}/${aws_ecs_service.keycloak.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "keycloak_cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${local.name_prefix}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.keycloak[0].service_namespace
  resource_id        = aws_appautoscaling_target.keycloak[0].resource_id
  scalable_dimension = aws_appautoscaling_target.keycloak[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = var.autoscaling_cpu_target
    # Scale out fast, scale in slowly - shedding capacity too eagerly is how
    # you end up under-provisioned during a traffic spike.
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "keycloak_memory" {
  count = var.enable_autoscaling && var.autoscaling_memory_target > 0 ? 1 : 0

  name               = "${local.name_prefix}-memory-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.keycloak[0].service_namespace
  resource_id        = aws_appautoscaling_target.keycloak[0].resource_id
  scalable_dimension = aws_appautoscaling_target.keycloak[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_memory_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "keycloak_requests" {
  count = var.enable_autoscaling && var.autoscaling_requests_per_target > 0 ? 1 : 0

  name               = "${local.name_prefix}-request-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.keycloak[0].service_namespace
  resource_id        = aws_appautoscaling_target.keycloak[0].resource_id
  scalable_dimension = aws_appautoscaling_target.keycloak[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_requests_per_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.keycloak.arn_suffix}/${aws_lb_target_group.keycloak.arn_suffix}"
    }
  }
}
