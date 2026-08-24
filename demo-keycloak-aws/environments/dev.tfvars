###############################################################################
# Development - optimised for cost, not resilience.
#   terraform apply -var-file=environments/dev.tfvars
###############################################################################

aws_region  = "us-east-1"
environment = "dev"
owner       = "platform-team"
cost_center = "CC-DEV-001"

ecs_task_execution_role_name = "ecsTaskExecutionRole"
ecs_task_role_name           = "keycloakTaskRole"

# Networking - one NAT Gateway shared by both AZs
vpc_cidr           = "10.30.0.0/16"
az_count           = 2
enable_nat_gateway = true
single_nat_gateway = true

# Load balancer - HTTP only until a certificate exists
acm_certificate_arn     = null
alb_ingress_cidr_blocks = ["0.0.0.0/0"]
alb_deletion_protection = false

# Keycloak - single small task
keycloak_image         = "quay.io/keycloak/keycloak:26.0"
keycloak_cpu           = 512
keycloak_memory        = 1024
keycloak_desired_count = 1
enable_execute_command = true
enable_autoscaling     = false
log_retention_in_days  = 7

# RDS - smallest sensible footprint, disposable
db_instance_class               = "db.t4g.micro"
db_allocated_storage            = 20
db_max_allocated_storage        = 50
db_multi_az                     = false
db_backup_retention_period      = 1
db_deletion_protection          = false
db_skip_final_snapshot          = true
db_performance_insights_enabled = false
db_apply_immediately            = true

secret_recovery_window_days = 0

additional_tags = {
  AutoShutdown = "true"
}

# --- Resilience (relaxed for dev) -------------------------------------------
deployment_minimum_healthy_percent = 50
enable_deployment_circuit_breaker  = true
enable_container_health_check      = true
enable_az_rebalancing              = true
target_group_slow_start            = 30

enable_alarms            = true
alarm_email_endpoints    = []
alarm_evaluation_periods = 3

secret_replica_regions                 = []
enable_cross_region_backup_replication = false
