locals {
  tags = { Project = var.project, Environment = var.environment, Stack = "40-kafka", ManagedBy = "terraform" }
}

data "terraform_remote_state" "cluster" {
  count   = var.cluster_name == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/10-eks-cluster.tfstate", region = local.state_region }
}

locals {
  cluster_name = coalesce(var.cluster_name, try(data.terraform_remote_state.cluster[0].outputs.cluster_name, null))
  rf           = min(3, var.brokers)
  pod_template = {
    pod = {
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = { matchLabels = { "strimzi.io/cluster" = var.kafka_cluster_name } }
              topologyKey   = "topology.kubernetes.io/zone"
            }
          }]
        }
      }
    }
  }
}

# ---------- Strimzi operator from the vendored chart ----------
module "strimzi" {
  source     = "../../modules/helm-app"
  name       = "strimzi-kafka-operator"
  namespace  = var.namespace
  chart_path = "${path.module}/../../shared/charts/strimzi-kafka-operator"
  values     = [yamlencode({ watchNamespaces = [var.namespace] })]
}

# ---------- node pools ----------
resource "kubectl_manifest" "controllers" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "controller", namespace = var.namespace, labels = { "strimzi.io/cluster" = var.kafka_cluster_name } }
    spec = {
      replicas = var.controllers
      roles    = ["controller"]
      storage  = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = "20Gi", class = var.storage_class, deleteClaim = false }] }
      template = local.pod_template
    }
  })
  depends_on = [module.strimzi]
}

resource "kubectl_manifest" "brokers" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "broker", namespace = var.namespace, labels = { "strimzi.io/cluster" = var.kafka_cluster_name } }
    spec = {
      replicas  = var.brokers
      roles     = ["broker"]
      storage   = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = "${var.broker_storage_gi}Gi", class = var.storage_class, deleteClaim = false }] }
      resources = { requests = { cpu = "1", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" } }
      template  = local.pod_template
    }
  })
  depends_on = [module.strimzi]
}

# ---------- Kafka cluster ----------
resource "kubectl_manifest" "kafka" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name        = var.kafka_cluster_name
      namespace   = var.namespace
      annotations = { "strimzi.io/node-pools" = "enabled", "strimzi.io/kraft" = "enabled" }
    }
    spec = {
      kafka = {
        version = var.kafka_version
        listeners = [
          { name = "plain", port = 9092, type = "internal", tls = false },
          { name = "tls", port = 9093, type = "internal", tls = true },
        ]
        config = {
          "offsets.topic.replication.factor"         = local.rf
          "transaction.state.log.replication.factor" = local.rf
          "transaction.state.log.min.isr"            = max(1, local.rf - 1)
          "default.replication.factor"               = local.rf
          "min.insync.replicas"                      = max(1, local.rf - 1)
          "auto.create.topics.enable"                = "false"
        }
      }
      entityOperator = { topicOperator = {}, userOperator = {}, template = { pod = { nodeSelector = var.node_selector, tolerations = var.tolerations } } }
    }
  })
  wait_for {
    field {
      key   = "status.conditions.[0].type"
      value = "Ready"
    }
  }
  timeouts { create = "25m" }
  depends_on = [kubectl_manifest.controllers, kubectl_manifest.brokers]
}

# ---------- topics ----------
resource "kubectl_manifest" "topic" {
  for_each = var.topics
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaTopic"
    metadata   = { name = each.key, namespace = var.namespace, labels = { "strimzi.io/cluster" = var.kafka_cluster_name } }
    spec       = { partitions = each.value.partitions, replicas = min(each.value.replicas, var.brokers), config = each.value.config }
  })
  depends_on = [kubectl_manifest.kafka]
}
