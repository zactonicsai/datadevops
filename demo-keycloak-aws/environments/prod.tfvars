###############################################################################
# Production - resilience and protection first.
#   terraform apply -var-file=environments/prod.tfvars
###############################################################################

aws_region  = "us-east-1"
environment = "prod"
owner       = "platform-team"
cost_center = "CC-PROD-001"

ecs_task_execution_role_name = "ecsTaskExecutionRole-prod"
ecs_task_role_name           = "keycloakTaskRole-prod"
rds_monitoring_role_name     = "rds-enhanced-monitoring-role"
vpc_flow_logs_role_name      = "vpc-flow-logs-role"

# Networking - NAT Gateway per AZ, flow logs on
vpc_cidr             = "10.40.0.0/16"
az_count             = 3
enable_nat_gateway   = true
single_nat_gateway   = false
enable_vpc_flow_logs = true

# Load balancer - TLS required, restrict the source ranges to your edge/CDN
acm_certificate_arn     = "arn:aws:acm:us-east-1:111122223333:certificate/REPLACE-ME"
keycloak_hostname       = "auth.example.com"
alb_ingress_cidr_blocks = ["0.0.0.0/0"]
alb_deletion_protection = true
alb_ssl_policy          = "ELBSecurityPolicy-TLS13-1-2-2021-06"
# alb_access_logs_bucket = "my-alb-access-logs"

# Keycloak - clustered with autoscaling
keycloak_image           = "111122223333.dkr.ecr.us-east-1.amazonaws.com/keycloak:26.0-optimized"
keycloak_cpu             = 2048
keycloak_memory          = 4096
keycloak_desired_count   = 3
enable_execute_command   = false
enable_autoscaling       = true
autoscaling_min_capacity = 3
autoscaling_max_capacity = 12
autoscaling_cpu_target   = 60
log_retention_in_days    = 90

# RDS - Multi-AZ, protected, monitored
db_instance_class               = "db.r6g.large"
db_allocated_storage            = 100
db_max_allocated_storage        = 500
db_multi_az                     = true
db_backup_retention_period      = 30
db_deletion_protection          = true
db_skip_final_snapshot          = false
db_performance_insights_enabled = true
db_monitoring_interval          = 60
db_apply_immediately            = false

db_parameters = [
  {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }
]

# Customer-managed keys
# secrets_kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/REPLACE-ME"
# rds_kms_key_arn     = "arn:aws:kms:us-east-1:111122223333:key/REPLACE-ME"

secret_recovery_window_days = 30

# --- Resilience -------------------------------------------------------------
# No capacity dip during deployments, automatic rollback, AZ rebalancing on.
deployment_minimum_healthy_percent = 100
deployment_maximum_percent         = 200
enable_deployment_circuit_breaker  = true
enable_az_rebalancing              = true
enable_container_health_check      = true
container_stop_timeout             = 90
target_group_slow_start            = 60
enable_alb_http2                   = true

# Scale on CPU and memory; add request-count tracking once you know your
# per-task throughput.
autoscaling_memory_target       = 75
autoscaling_requests_per_target = 0

# Alarms wired to a topic the on-call rotation actually watches.
enable_alarms                = true
alarm_email_endpoints        = ["platform-oncall@example.com"]
alarm_evaluation_periods     = 2
alarm_period_seconds         = 60
alarm_rds_free_storage_bytes = 21474836480 # 20 GiB
alarm_rds_cpu_threshold      = 75
alarm_target_response_time   = 2

# Credentials and backups survive the loss of the primary region.
secret_replica_regions                 = ["us-west-2"]
enable_cross_region_backup_replication = true
backup_replication_region              = "us-west-2"
backup_replication_kms_key_arn         = "arn:aws:kms:us-west-2:111122223333:key/REPLACE-ME"

db_performance_insights_retention = 93
db_storage_iops                   = 12000
db_storage_throughput             = 500
