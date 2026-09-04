region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

state_bucket     = "my-tf-state-bucket"
state_key_prefix = "kafka-keycloak/dev"

cluster_name       = "kafka-keycloak-dev"
kubernetes_version = "1.31"
create_cluster     = true
# subnet_ids               = ["subnet-..."]      # else read from 00-network state
# existing_cluster_role_arn = "arn:aws:iam::123456789012:role/eks-cluster-role"
endpoint_public_access_cidrs = ["0.0.0.0/0"]
