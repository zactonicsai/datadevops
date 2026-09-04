region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

state_bucket     = "my-tf-state-bucket"
state_key_prefix = "kafka-keycloak/dev"

# cluster_name / vpc_id / private_subnet_ids / oidc_provider_arn: omit to read upstream state, or set explicitly
# existing_node_role_arn      = "arn:aws:iam::123456789012:role/my-node-role"
# existing_launch_template_id = "lt-0123456789abcdef0"
node_key_name         = null
node_root_volume_size = 80

node_groups = {
  general = { instance_types = ["m6i.large"], desired = 2, min = 2, max = 4, labels = { workload = "general" } }
  kafka   = { instance_types = ["m6i.xlarge"], desired = 3, min = 3, max = 5, labels = { workload = "kafka" }
              taints = [{ key = "workload", value = "kafka", effect = "NO_SCHEDULE" }] }
}

namespaces = {
  kafka    = { labels = { team = "data" }, resource_quota = {} }
  kafka-ui = { labels = { team = "data" } }
}

install_lb_controller = true
install_ebs_csi       = true
