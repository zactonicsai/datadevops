resource "kubernetes_manifest" "kafka" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"

    metadata = {
      name      = "tutorial-kafka"
      namespace = "kafka"
    }

    spec = {
      kafka = {
        version         = var.kafka_version
        metadataVersion = "4.3-IV0"

        listeners = [
          {
            name = "plain"
            port = 9092
            type = "internal"
            tls  = false
          },
          {
            name = "tls"
            port = 9093
            type = "internal"
            tls  = true
          }
        ]

        config = {
          "offsets.topic.replication.factor"         = 3
          "transaction.state.log.replication.factor" = 3
          "transaction.state.log.min.isr"             = 2
          "default.replication.factor"                 = 3
          "min.insync.replicas"                        = 2
          "auto.create.topics.enable"                  = false
        }
      }

      entityOperator = {
        topicOperator = {}
        userOperator  = {}
      }
    }
  }

  depends_on = [kubernetes_manifest.kafka_node_pool]
}
