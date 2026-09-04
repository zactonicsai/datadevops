# ======================= Kafka on the DATA cluster (Strimzi, local chart) =======================
resource "kubernetes_namespace_v1" "kafka" {
  provider = kubernetes.data
  metadata { name = "kafka" }
  depends_on = [module.data]
}

resource "helm_release" "strimzi" {
  provider  = helm.data
  name      = "strimzi-kafka-operator"
  namespace = kubernetes_namespace_v1.kafka.metadata[0].name
  chart     = local.charts.strimzi # local directory
  wait      = true
  timeout   = 600
}

resource "kubectl_manifest" "nodepool_controller" {
  provider  = kubectl.data
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "controller", namespace = "kafka", labels = { "strimzi.io/cluster" = "my-cluster" } }
    spec = {
      replicas = 3
      roles    = ["controller"]
      storage  = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = "20Gi", class = "gp3", deleteClaim = false }] }
    }
  })
  depends_on = [helm_release.strimzi, kubernetes_storage_class_v1.gp3]
}

resource "kubectl_manifest" "nodepool_broker" {
  provider  = kubectl.data
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata   = { name = "broker", namespace = "kafka", labels = { "strimzi.io/cluster" = "my-cluster" } }
    spec = {
      replicas  = 3
      roles     = ["broker"]
      storage   = { type = "jbod", volumes = [{ id = 0, type = "persistent-claim", size = "100Gi", class = "gp3", deleteClaim = false }] }
      resources = { requests = { cpu = "1", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" } }
      template = {
        pod = {
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [{
                labelSelector = { matchLabels = { "strimzi.io/cluster" = "my-cluster", "strimzi.io/pool-name" = "broker" } }
                topologyKey   = "topology.kubernetes.io/zone"
              }]
            }
          }
        }
      }
    }
  })
  depends_on = [helm_release.strimzi, kubernetes_storage_class_v1.gp3]
}

resource "kubectl_manifest" "kafka" {
  provider  = kubectl.data
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "Kafka"
    metadata = {
      name        = "my-cluster"
      namespace   = "kafka"
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
          "offsets.topic.replication.factor"         = 3
          "transaction.state.log.replication.factor" = 3
          "transaction.state.log.min.isr"            = 2
          "default.replication.factor"               = 3
          "min.insync.replicas"                      = 2
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
  depends_on = [kubectl_manifest.nodepool_controller, kubectl_manifest.nodepool_broker]
}

resource "kubectl_manifest" "topics" {
  provider = kubectl.data
  for_each = var.topics
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaTopic"
    metadata   = { name = each.key, namespace = "kafka", labels = { "strimzi.io/cluster" = "my-cluster" } }
    spec       = { partitions = each.value.partitions, replicas = each.value.replicas, config = each.value.config }
  })
  depends_on = [kubectl_manifest.kafka]
}
