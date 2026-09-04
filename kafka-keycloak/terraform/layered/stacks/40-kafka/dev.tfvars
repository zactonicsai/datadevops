region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

state_bucket     = "my-tf-state-bucket"
state_key_prefix = "kafka-keycloak/dev"

# cluster_name = "kafka-keycloak-dev"     # else from 10-eks-cluster state
namespace          = "kafka"               # created by 20-eks-nodegroups
kafka_cluster_name = "my-cluster"
kafka_version      = "3.9.0"
controllers        = 3
brokers            = 3
broker_storage_gi  = 100
storage_class      = "gp3"

# pin Kafka to the dedicated node group from 20-eks-nodegroups
node_selector = { workload = "kafka" }
tolerations   = [{ key = "workload", value = "kafka", effect = "NoSchedule" }]

topics = {
  orders      = { partitions = 6 }
  payments    = { partitions = 6 }
  user-events = { partitions = 12 }
  audit-log   = { partitions = 3, config = { "retention.ms" = "604800000", "cleanup.policy" = "delete" } }
}
