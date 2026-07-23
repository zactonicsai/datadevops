resource "kubernetes_manifest" "kafka_node_pool" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"

    metadata = {
      name      = "combined"
      namespace = "kafka"
      labels = {
        "strimzi.io/cluster" = "tutorial-kafka"
      }
    }

    spec = {
      replicas = 3
      roles    = ["controller", "broker"]

      resources = {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          cpu    = "1500m"
          memory = "2Gi"
        }
      }

      storage = {
        type = "jbod"
        volumes = [
          {
            id            = 0
            type          = "persistent-claim"
            size          = var.kafka_storage_size
            class         = kubernetes_storage_class_v1.gp3.metadata[0].name
            deleteClaim   = !var.retain_application_volumes
            kraftMetadata = "shared"
          }
        ]
      }

      template = {
        pod = {
          affinity = {
            podAntiAffinity = {
              preferredDuringSchedulingIgnoredDuringExecution = [
                {
                  weight = 100
                  podAffinityTerm = {
                    topologyKey = "kubernetes.io/hostname"
                    labelSelector = {
                      matchExpressions = [
                        {
                          key      = "strimzi.io/name"
                          operator = "In"
                          values   = ["tutorial-kafka-kafka"]
                        }
                      ]
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
  }
}
