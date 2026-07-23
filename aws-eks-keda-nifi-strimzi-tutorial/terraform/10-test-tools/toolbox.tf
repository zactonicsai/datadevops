resource "kubernetes_deployment_v1" "toolbox" {
  metadata {
    name      = "toolbox"
    namespace = kubernetes_namespace_v1.test_tools.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "toolbox"
      }
    }

    template {
      metadata {
        labels = {
          app = "toolbox"
        }
      }

      spec {
        container {
          name    = "toolbox"
          image   = var.toolbox_image
          command = ["sleep", "infinity"]

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false

            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}
