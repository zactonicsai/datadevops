resource "kubernetes_manifest" "tutorial_topic" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaTopic"

    metadata = {
      name      = "tutorial-topic"
      namespace = "kafka"
      labels = {
        "strimzi.io/cluster" = "tutorial-kafka"
      }
    }

    spec = {
      partitions = 3
      replicas   = 3
      config = {
        "retention.ms"  = "3600000"
        "segment.bytes" = "1073741824"
      }
    }
  }

  depends_on = [kubernetes_manifest.kafka]
}
