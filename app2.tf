# Kafka UI (provectuslabs/kafka-ui) - configured purely via env vars
resource "kubernetes_deployment_v1" "kafka_ui" {
  metadata {
    name   = "kafka-ui"
    labels = { app = "kafka-ui" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "kafka-ui" }
    }

    template {
      metadata {
        labels = { app = "kafka-ui" }
      }

      spec {
        container {
          name  = "kafka-ui"
          image = "provectuslabs/kafka-ui:latest"

          port {
            container_port = 8080
          }

          # Lets you add/edit clusters from the web UI too
          env {
            name  = "DYNAMIC_CONFIG_ENABLED"
            value = "true"
          }

          env {
            name  = "KAFKA_CLUSTERS_0_NAME"
            value = var.kafka_cluster_name
          }

          env {
            name  = "KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS"
            value = var.kafka_bootstrap_servers
          }

          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          readiness_probe {
            http_get {
              path = "/actuator/health"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_v1" "kafka_ui" {
  metadata {
    name = "kafka-ui"
  }

  spec {
    selector = { app = "kafka-ui" }
    type     = "LoadBalancer"

    port {
      port        = 80
      target_port = 8080
    }
  }
}
