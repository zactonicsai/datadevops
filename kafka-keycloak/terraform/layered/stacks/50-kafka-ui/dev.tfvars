region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

state_bucket     = "my-tf-state-bucket"
state_key_prefix = "kafka-keycloak/dev"

route53_zone_name = "example.com"
hostname          = "kafka-ui"          # -> https://kafka-ui.example.com (must match 30-keycloak-ec2 kafka_ui_url)
namespace         = "kafka-ui"          # created by 20-eks-nodegroups
replicas          = 2
alb_internal      = false
alb_allowed_cidrs = ["0.0.0.0/0"]

kafka_ui_client_secret = "a-long-random-secret"   # same value as in 30-keycloak-ec2
rbac_roles = { kafka-admin = "admin", kafka-viewer = "viewer" }

# Override upstream state lookups if needed:
# cluster_name              = "kafka-keycloak-dev"
# cluster_security_group_id = "sg-..."
# keycloak_issuer_uri       = "https://auth.example.com/realms/kafka"
# kafka_bootstrap_servers   = "my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
# existing_certificate_arn / existing_alb_security_group_id / existing_target_group_arn / existing_alb = {...}
