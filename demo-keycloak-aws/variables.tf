###############################################################################
# Input variables
# Every configurable value lives here. Nothing environment-specific is
# hardcoded anywhere else in the project - override via *.tfvars.
###############################################################################

# ----------------------------------------------------------------------------
# General / naming
# ----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name used as the prefix for all resource names."
  type        = string
  default     = "keycloak"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 2-20 chars, lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (dev, stg, prod, ...)."
  type        = string

  validation {
    condition     = contains(["dev", "test", "stg", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, stg, prod."
  }
}

variable "owner" {
  description = "Team or individual responsible for this stack (tagging)."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost center used for chargeback tagging."
  type        = string
  default     = "unassigned"
}

variable "additional_tags" {
  description = "Extra tags merged into the default tag set."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "subnet_newbits" {
  description = "Additional bits added to the VPC prefix when carving subnets (8 turns a /16 into /24s)."
  type        = number
  default     = 8
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across (minimum 2 for ALB and RDS Multi-AZ)."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "enable_nat_gateway" {
  description = "Create NAT Gateway(s) so private subnets can pull the Keycloak image from the internet."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT Gateway instead of one per AZ (cheaper, less resilient - fine for dev)."
  type        = bool
  default     = false
}

variable "enable_vpc_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in the VPC."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# Security groups
# ----------------------------------------------------------------------------
variable "alb_ingress_cidr_blocks" {
  description = "CIDR blocks permitted to reach the ALB. Lock this down in production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alb_ingress_http_enabled" {
  description = "Open port 80 on the ALB (used to redirect to HTTPS)."
  type        = bool
  default     = true
}

variable "extra_database_ingress_cidr_blocks" {
  description = "Optional extra CIDRs allowed to reach RDS (e.g. a bastion or VPN range)."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------------
# Load balancer
# ----------------------------------------------------------------------------
variable "alb_internal" {
  description = "Create an internal (private) ALB instead of internet-facing."
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener. If null/empty only an HTTP listener is created."
  type        = string
  default     = null
}

variable "alb_ssl_policy" {
  description = "SSL security policy for the HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "alb_deletion_protection" {
  description = "Protect the ALB from accidental deletion."
  type        = bool
  default     = true
}

variable "alb_idle_timeout" {
  description = "ALB idle timeout in seconds."
  type        = number
  default     = 60
}

variable "alb_access_logs_bucket" {
  description = "Existing S3 bucket for ALB access logs. Leave null to disable."
  type        = string
  default     = null
}

variable "health_check_path" {
  description = "Keycloak readiness endpoint used by the target group."
  type        = string
  default     = "/health/ready"
}

variable "health_check_healthy_threshold" {
  description = "Consecutive successful checks before a target is healthy."
  type        = number
  default     = 2
}

variable "health_check_unhealthy_threshold" {
  description = "Consecutive failed checks before a target is unhealthy."
  type        = number
  default     = 3
}

variable "health_check_interval" {
  description = "Seconds between health checks."
  type        = number
  default     = 15
}

variable "health_check_timeout" {
  description = "Health check timeout in seconds."
  type        = number
  default     = 5
}

variable "deregistration_delay" {
  description = "Connection draining time in seconds."
  type        = number
  default     = 60
}

variable "enable_stickiness" {
  description = "Enable load balancer cookie stickiness (helps browser-based auth flows)."
  type        = bool
  default     = true
}

variable "stickiness_duration" {
  description = "Stickiness cookie duration in seconds."
  type        = number
  default     = 3600
}

# ----------------------------------------------------------------------------
# Keycloak / ECS
# ----------------------------------------------------------------------------
variable "keycloak_image" {
  description = "Keycloak Docker image (public registry, ECR, or a custom optimized build)."
  type        = string
  default     = "quay.io/keycloak/keycloak:26.0"
}

variable "keycloak_hostname" {
  description = "Public hostname for Keycloak (e.g. auth.example.com). Falls back to the ALB DNS name if null."
  type        = string
  default     = null
}

variable "keycloak_http_port" {
  description = "Container port serving HTTP traffic."
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Container port serving health/metrics endpoints (Keycloak 25+ management interface)."
  type        = number
  default     = 9000
}

variable "keycloak_admin_username" {
  description = "Bootstrap admin username created on first start."
  type        = string
  default     = "admin"
}

variable "keycloak_cpu" {
  description = "Fargate task CPU units (256, 512, 1024, 2048, 4096)."
  type        = number
  default     = 1024
}

variable "keycloak_memory" {
  description = "Fargate task memory in MiB - must be a valid pairing with keycloak_cpu."
  type        = number
  default     = 2048
}

variable "keycloak_desired_count" {
  description = "Number of Keycloak tasks to run."
  type        = number
  default     = 3
}

variable "keycloak_extra_environment" {
  description = "Additional KC_* environment variables passed to the container."
  type        = map(string)
  default     = {}
}

variable "cpu_architecture" {
  description = "Fargate CPU architecture: X86_64 or ARM64."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "enable_execute_command" {
  description = "Allow ECS Exec (aws ecs execute-command) into running tasks. Requires task role permissions."
  type        = bool
  default     = false
}

variable "enable_container_insights" {
  description = "Enable CloudWatch Container Insights on the ECS cluster."
  type        = bool
  default     = true
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs retention for Keycloak container logs."
  type        = number
  default     = 90
}

variable "health_check_grace_period" {
  description = "Seconds the ECS service ignores ALB health checks after a task starts (Keycloak boots slowly)."
  type        = number
  default     = 300
}

variable "enable_autoscaling" {
  description = "Enable Application Auto Scaling for the ECS service."
  type        = bool
  default     = true
}

variable "autoscaling_min_capacity" {
  description = "Minimum task count when autoscaling is enabled."
  type        = number
  default     = 3
}

variable "autoscaling_max_capacity" {
  description = "Maximum task count when autoscaling is enabled."
  type        = number
  default     = 6
}

variable "autoscaling_cpu_target" {
  description = "Target average CPU utilisation percentage for autoscaling."
  type        = number
  default     = 65
}

# ----------------------------------------------------------------------------
# RDS
# ----------------------------------------------------------------------------
variable "db_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.large"
}

variable "db_name" {
  description = "Initial database name created for Keycloak."
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username for the Keycloak database."
  type        = string
  default     = "keycloak_admin"
}

variable "db_port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for storage autoscaling in GiB. Set equal to db_allocated_storage to disable."
  type        = number
  default     = 100
}

variable "db_storage_type" {
  description = "RDS storage type (gp3 recommended)."
  type        = string
  default     = "gp3"
}

variable "db_multi_az" {
  description = "Deploy RDS across two AZs with a standby."
  type        = bool
  default     = true
}

variable "db_backup_retention_period" {
  description = "Days of automated backups to retain."
  type        = number
  default     = 30
}

variable "db_backup_window" {
  description = "Preferred daily backup window (UTC)."
  type        = string
  default     = "03:00-04:00"
}

variable "db_maintenance_window" {
  description = "Preferred weekly maintenance window (UTC)."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "db_deletion_protection" {
  description = "Prevent accidental deletion of the RDS instance."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy (only ever true in dev)."
  type        = bool
  default     = false
}

variable "db_performance_insights_enabled" {
  description = "Enable RDS Performance Insights."
  type        = bool
  default     = true
}

variable "db_monitoring_interval" {
  description = "Enhanced monitoring interval in seconds (0 disables it). Requires rds_monitoring_role_name when > 0."
  type        = number
  default     = 0
}

variable "db_apply_immediately" {
  description = "Apply RDS modifications immediately instead of during the maintenance window."
  type        = bool
  default     = false
}

variable "db_auto_minor_version_upgrade" {
  description = "Allow automatic minor engine version upgrades."
  type        = bool
  default     = true
}

variable "db_parameters" {
  description = "Custom PostgreSQL parameters applied via a dedicated parameter group."
  type        = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

# ----------------------------------------------------------------------------
# Secrets Manager / KMS
# ----------------------------------------------------------------------------
variable "secrets_kms_key_arn" {
  description = "Customer-managed KMS key ARN for Secrets Manager. Null uses the AWS-managed key."
  type        = string
  default     = null
}

variable "rds_kms_key_arn" {
  description = "Customer-managed KMS key ARN for RDS storage encryption. Null uses the AWS-managed key."
  type        = string
  default     = null
}

variable "secret_recovery_window_days" {
  description = "Days before a deleted secret is permanently removed (0 = delete immediately)."
  type        = number
  default     = 7
}

variable "generated_password_length" {
  description = "Length of the auto-generated database and admin passwords."
  type        = number
  default     = 32
}

# ----------------------------------------------------------------------------
# Pre-existing IAM (managed outside this project)
# ----------------------------------------------------------------------------
variable "ecs_task_execution_role_name" {
  description = "Name of the EXISTING IAM role ECS uses to pull images, write logs and read secrets."
  type        = string
}

variable "ecs_task_role_name" {
  description = "Name of the EXISTING IAM role assumed by the Keycloak container itself."
  type        = string
}

variable "rds_monitoring_role_name" {
  description = "Name of the EXISTING IAM role for RDS Enhanced Monitoring. Required only when db_monitoring_interval > 0."
  type        = string
  default     = null
}

variable "vpc_flow_logs_role_name" {
  description = "Name of the EXISTING IAM role used to publish VPC flow logs. Required only when enable_vpc_flow_logs is true."
  type        = string
  default     = null
}

# ----------------------------------------------------------------------------
# Resilience - deployment safety
# ----------------------------------------------------------------------------
variable "deployment_minimum_healthy_percent" {
  description = "Percentage of tasks that must stay healthy during a deployment. 100 means no capacity loss while rolling."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "Upper bound on running tasks during a deployment. 200 allows a full parallel replacement set."
  type        = number
  default     = 200
}

variable "enable_deployment_circuit_breaker" {
  description = "Abort and roll back an ECS deployment automatically when tasks fail to stabilise."
  type        = bool
  default     = true
}

variable "enable_az_rebalancing" {
  description = "Let ECS automatically redistribute tasks when an Availability Zone becomes unbalanced."
  type        = bool
  default     = true
}

variable "enable_container_health_check" {
  description = "Run an in-container readiness probe against the management port (uses bash /dev/tcp, no curl required)."
  type        = bool
  default     = true
}

variable "container_stop_timeout" {
  description = "Seconds ECS waits for Keycloak to shut down gracefully before killing the container."
  type        = number
  default     = 60
}

variable "autoscaling_memory_target" {
  description = "Target average memory utilisation percentage. Set to 0 to disable the memory policy."
  type        = number
  default     = 75
}

variable "autoscaling_requests_per_target" {
  description = "Target ALB requests per task. Set to 0 to disable the request-count policy."
  type        = number
  default     = 0
}

variable "enable_alb_http2" {
  description = "Enable HTTP/2 on the load balancer."
  type        = bool
  default     = true
}

variable "target_group_slow_start" {
  description = "Seconds the ALB ramps traffic to a newly healthy target (0 disables). Helps a cold Keycloak JVM."
  type        = number
  default     = 60
}

# ----------------------------------------------------------------------------
# Resilience - backup and multi-region
# ----------------------------------------------------------------------------
variable "secret_replica_regions" {
  description = "Regions to replicate Secrets Manager secrets into, so credentials survive a regional outage."
  type        = list(string)
  default     = []
}

variable "enable_cross_region_backup_replication" {
  description = "Replicate RDS automated backups into another region."
  type        = bool
  default     = false
}

variable "backup_replication_region" {
  description = "Destination region for replicated RDS automated backups."
  type        = string
  default     = null
}

variable "backup_replication_kms_key_arn" {
  description = "KMS key ARN in the destination region used to encrypt replicated backups. Required when replication is enabled."
  type        = string
  default     = null
}

variable "db_performance_insights_retention" {
  description = "Performance Insights retention in days (7 is free tier, or 93/731)."
  type        = number
  default     = 7
}

variable "db_storage_iops" {
  description = "Provisioned IOPS for gp3/io1 storage. Null uses the gp3 baseline."
  type        = number
  default     = null
}

variable "db_storage_throughput" {
  description = "Storage throughput in MiB/s for gp3. Null uses the baseline."
  type        = number
  default     = null
}

# ----------------------------------------------------------------------------
# Resilience - observability and alarming
# ----------------------------------------------------------------------------
variable "enable_alarms" {
  description = "Create CloudWatch alarms for the ALB, ECS service and RDS instance."
  type        = bool
  default     = true
}

variable "alarm_sns_topic_arn" {
  description = "Existing SNS topic to notify. When null a topic is created for this stack."
  type        = string
  default     = null
}

variable "alarm_email_endpoints" {
  description = "Email addresses subscribed to the created SNS topic. Each address must confirm the subscription."
  type        = list(string)
  default     = []
}

variable "alarm_evaluation_periods" {
  description = "Evaluation periods before an alarm fires."
  type        = number
  default     = 2
}

variable "alarm_period_seconds" {
  description = "Metric period in seconds for the alarms."
  type        = number
  default     = 60
}

variable "alarm_rds_free_storage_bytes" {
  description = "Alarm threshold for RDS free storage space, in bytes."
  type        = number
  default     = 5368709120 # 5 GiB
}

variable "alarm_rds_cpu_threshold" {
  description = "Alarm threshold for RDS CPU utilisation percentage."
  type        = number
  default     = 80
}

variable "alarm_alb_5xx_threshold" {
  description = "Alarm threshold for ALB-generated 5xx responses per period."
  type        = number
  default     = 10
}

variable "alarm_target_response_time" {
  description = "Alarm threshold for target response time, in seconds."
  type        = number
  default     = 3
}
