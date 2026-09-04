region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

state_bucket     = "my-tf-state-bucket"
state_key_prefix = "kafka-keycloak/dev"

route53_zone_name = "example.com"
hostname          = "auth"
kafka_ui_url      = "https://kafka-ui.example.com"

instance_type     = "t3.medium"
desired_capacity  = 1
alb_internal      = false
alb_allowed_cidrs = ["0.0.0.0/0"]
db_instance_class = "db.t4g.small"

# Secrets: prefer TF_VAR_* env vars or a git-ignored secrets.auto.tfvars
keycloak_admin_password = "change-me"
db_password             = "change-me-too"
kafka_ui_client_secret  = "a-long-random-secret"
test_users = {
  alice = { password = "alice123", roles = ["kafka-admin"] }
  bob   = { password = "bob123", roles = ["kafka-viewer"] }
}

# ---- reuse pre-existing infrastructure (leave unset to create) ----
# vpc_id                         = "vpc-..."
# public_subnet_ids              = ["subnet-..."]
# private_subnet_ids             = ["subnet-..."]
# existing_certificate_arn       = "arn:aws:acm:..."
# existing_alb_security_group_id = "sg-..."
# existing_app_security_group_id = "sg-..."
# existing_db_security_group_id  = "sg-..."
# existing_instance_role_arn     = "arn:aws:iam::123456789012:role/keycloak-ec2"
# existing_instance_profile_name = "keycloak-ec2"
# existing_launch_template_id    = "lt-..."
# existing_target_group_arn      = "arn:aws:elasticloadbalancing:...:targetgroup/..."
# existing_alb = { arn = "...", dns_name = "...", zone_id = "...", https_listener_arn = "..." }
# existing_db_endpoint           = "keycloak.abc.us-east-1.rds.amazonaws.com"
