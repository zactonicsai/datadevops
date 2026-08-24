###############################################################################
# Production - two AZs, two instances, Multi-AZ database.
#   ENV=prod ./scripts/tf-plan.sh
###############################################################################

aws_region  = "us-east-1"
environment = "prod"
owner       = "platform-team"
cost_center = "CC-PROD-001"

instance_profile_name   = "keycloak-instance-profile-prod"
vpc_flow_logs_role_name = "vpc-flow-logs-role"
enable_vpc_flow_logs    = true

# Networking - a NAT Gateway per AZ so one AZ failure cannot strand the other
vpc_cidr           = "10.40.0.0/16"
az_count           = 2
single_nat_gateway = false

# Load balancer - TLS required
acm_certificate_arn     = "arn:aws:acm:us-east-1:111122223333:certificate/REPLACE-ME"
keycloak_hostname       = "auth.example.com"
alb_ingress_cidr_blocks = ["0.0.0.0/0"]
alb_deletion_protection = true

# Keycloak hosts - two instances, one per AZ, rolling replacement on change
keycloak_image                       = "quay.io/keycloak/keycloak:26.0"
instance_type                        = "t3.large"
asg_desired_capacity                 = 2
asg_min_size                         = 2
asg_max_size                         = 6
enable_autoscaling                   = true
autoscaling_cpu_target               = 60
instance_refresh_min_healthy_percent = 50
health_check_grace_period            = 300
log_retention_in_days                = 90

keycloak_extra_environment = {
  KC_HOSTNAME_STRICT = "true"
}

# RDS - Multi-AZ, protected
db_instance_class               = "db.t4g.large"
db_allocated_storage            = 100
db_max_allocated_storage        = 500
db_multi_az                     = true
db_backup_retention_period      = 30
db_deletion_protection          = true
db_skip_final_snapshot          = false
db_performance_insights_enabled = true
db_apply_immediately            = false

db_parameters = [
  {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }
]

secret_recovery_window_days = 30

enable_alarms         = true
alarm_email_endpoints = ["platform-oncall@example.com"]
