locals {
  rf = min(3, var.brokers.replicas)
}

resource "helm_release" "strimzi" {
  name      = "strimzi-kafka-operator"
  namespace = var.namespace
  chart     = "${path.module}/../../vendor/charts/strimzi-kafka-operator" # local, no network
  wait      = true
  timeout   = 600
}

resource "kubectl_manifest" "pool_controller" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "controller", namespace = var.namespace, labels = { "strimzi.io/cluster" = var.cluster_name } }
    spec = {
      replicas = var.controllers.replicas
      roles    = ["controller"]
      storage  = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = var.controllers.storage_size, class = var.storage_class, deleteClaim = false }] }
      template = { pod = { nodeSelector = var.brokers.node_selector, tolerations = var.brokers.tolerations } }
    }
  })
  depends_on = [helm_release.strimzi]
}

resource "kubectl_manifest" "pool_broker" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "broker", namespace = var.namespace, labels = { "strimzi.io/cluster" = var.cluster_name } }
    spec = {
      replicas  = var.brokers.replicas
      roles     = ["broker"]
      storage   = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = var.brokers.storage_size, class = var.storage_class, deleteClaim = false }] }
      resources = { requests = { cpu = var.brokers.cpu_request, memory = var.brokers.memory }, limits = { memory = var.brokers.memory } }
      template = {
        pod = {
          nodeSelector = var.brokers.node_selector
          tolerations  = var.brokers.tolerations
          affinity = { podAntiAffinity = { requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = { matchLabels = { "strimzi.io/cluster" = var.cluster_name, "strimzi.io/pool-name" = "broker" } }
            topologyKey   = "topology.kubernetes.io/zone"
          }] } }
        }
      }
    }
  })
  depends_on = [helm_release.strimzi]
}

resource "kubectl_manifest" "kafka" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name        = var.cluster_name
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
      entityOperator = { topicOperator = {}, userOperator = {} }
    }
  })
  wait_for {
    field {
      key   = "status.conditions.[0].type"
      value = "Ready"
    }
  }
  timeouts { create = "25m" }
  depends_on = [kubectl_manifest.pool_controller, kubectl_manifest.pool_broker]
}

resource "kubectl_manifest" "topics" {
  for_each = var.topics
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaTopic"
    metadata   = { name = each.key, namespace = var.namespace, labels = { "strimzi.io/cluster" = var.cluster_name } }
    spec       = { partitions = each.value.partitions, replicas = min(each.value.replicas, var.brokers.replicas), config = each.value.config }
  })
  depends_on = [kubectl_manifest.kafka]
}
