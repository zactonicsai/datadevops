resource "kubernetes_namespace_v1" "kafka" {
  metadata { name = "kafka" }
  depends_on = [kind_cluster.this]
}

resource "helm_release" "strimzi" {
  name       = "strimzi-kafka-operator"
  namespace  = kubernetes_namespace_v1.kafka.metadata[0].name
  repository = "oci://quay.io/strimzi-helm"
  chart      = "strimzi-kafka-operator"
  version    = var.versions["strimzi_chart"]
  wait       = true
  timeout    = 600
}

# Single node acting as both KRaft controller and broker (dev sizing).
resource "kubectl_manifest" "kafka_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaNodePool"
    metadata = {
      name      = "dual-role"
      namespace = kubernetes_namespace_v1.kafka.metadata[0].name
      labels    = { "strimzi.io/cluster" = "my-cluster" }
    }
    spec = {
      replicas = 1
      roles    = ["controller", "broker"]
      storage = {
        type = "jbod"
        volumes = [{ id = 0, type = "persistent-claim", size = "5Gi", deleteClaim = true }]
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
      name      = "my-cluster"
      namespace = kubernetes_namespace_v1.kafka.metadata[0].name
      annotations = {
        "strimzi.io/node-pools" = "enabled"
        "strimzi.io/kraft"      = "enabled"
      }
    }
    spec = {
      kafka = {
        version = var.versions["kafka"]
        listeners = [
          { name = "plain", port = 9092, type = "internal", tls = false },
          {
            # Reachable from the host via kind port mappings -> localhost:${kafka_host_port}
            name = "external", port = 9094, type = "nodeport", tls = false
            configuration = {
              bootstrap = { nodePort = 30092 }
              brokers = [{
                broker         = 0
                nodePort       = 30093
                advertisedHost = "localhost"
                advertisedPort = var.kafka_host_port + 1
              }]
            }
          }
        ]
        config = {
          "offsets.topic.replication.factor"         = 1
          "transaction.state.log.replication.factor" = 1
          "transaction.state.log.min.isr"            = 1
          "default.replication.factor"               = 1
          "min.insync.replicas"                      = 1
          "auto.create.topics.enable"                = "false"
        }
      }
      entityOperator = { topicOperator = {}, userOperator = {} }
    }
  })
  depends_on = [kubectl_manifest.kafka_nodepool]
}

resource "kubectl_manifest" "topics" {
  for_each = var.topics
  yaml_body = yamlencode({
    apiVersion = "kafka.strimzi.io/v1beta2"
    kind       = "KafkaTopic"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace_v1.kafka.metadata[0].name
      labels    = { "strimzi.io/cluster" = "my-cluster" }
    }
    spec = {
      partitions = each.value.partitions
      replicas   = 1
      config     = each.value.config
    }
  })
  depends_on = [kubectl_manifest.kafka]
}
