###############################################################################
# IAM - lookups only.
#
# Roles and policies are managed OUTSIDE this project (by the security team).
# We reference them by name so this stack never needs iam:Create* permissions.
#
# Required permissions on those roles:
#
#   ecs_task_execution_role_name
#     - AmazonECSTaskExecutionRolePolicy (ECR pull + CloudWatch Logs)
#     - secretsmanager:GetSecretValue on the secrets created here
#     - kms:Decrypt if a customer-managed KMS key is used
#     - Trust policy: ecs-tasks.amazonaws.com
#
#   ecs_task_role_name
#     - Whatever Keycloak itself needs at runtime (often nothing)
#     - ssmmessages:* if enable_execute_command is true
#     - Trust policy: ecs-tasks.amazonaws.com
#
#   rds_monitoring_role_name  (only when db_monitoring_interval > 0)
#     - AmazonRDSEnhancedMonitoringRole, trusted by monitoring.rds.amazonaws.com
#
#   vpc_flow_logs_role_name   (only when enable_vpc_flow_logs is true)
#     - logs:CreateLogStream / PutLogEvents, trusted by vpc-flow-logs.amazonaws.com
###############################################################################

data "aws_iam_role" "ecs_task_execution" {
  name = var.ecs_task_execution_role_name
}

data "aws_iam_role" "ecs_task" {
  name = var.ecs_task_role_name
}

data "aws_iam_role" "rds_monitoring" {
  count = var.db_monitoring_interval > 0 ? 1 : 0

  name = var.rds_monitoring_role_name
}

data "aws_iam_role" "vpc_flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = var.vpc_flow_logs_role_name
}
