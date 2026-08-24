###############################################################################
# Development - single instance, single NAT, disposable database.
#   ENV=dev ./scripts/tf-plan.sh
###############################################################################

aws_region  = "us-east-1"
environment = "dev"
owner       = "platform-team"
cost_center = "CC-DEV-001"

instance_profile_name = "keycloak-instance-profile"

# Networking
vpc_cidr           = "10.30.0.0/16"
az_count           = 2
single_nat_gateway = true

# Load balancer - HTTP only until a certificate exists
acm_certificate_arn     = null
alb_ingress_cidr_blocks = ["0.0.0.0/0"]
alb_deletion_protection = false

# Keycloak hosts - one small instance is enough to develop against
keycloak_image        = "quay.io/keycloak/keycloak:26.0"
instance_type         = "t3.small"
asg_desired_capacity  = 1
asg_min_size          = 1
asg_max_size          = 2
log_retention_in_days = 7

# Reach the box through SSM Session Manager rather than SSH
ssh_ingress_cidr_blocks = []

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

enable_alarms = false

additional_tags = {
  AutoShutdown = "true"
}
