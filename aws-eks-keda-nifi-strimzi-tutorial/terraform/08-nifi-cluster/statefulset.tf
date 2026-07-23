resource "kubernetes_stateful_set_v1" "nifi" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  spec {
    service_name = kubernetes_service_v1.headless.metadata[0].name
    replicas     = 2

    pod_management_policy = "Parallel"

    selector {
      match_labels = {
        app = "nifi"
      }
    }

    template {
      metadata {
        labels = {
          app = "nifi"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.nifi.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
        }

        init_container {
          name  = "configure"
          image = var.nifi_image

          command = ["/bin/bash", "/scripts/configure-nifi.sh"]

          env {
            name = "NIFI_SENSITIVE_PROPS_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.nifi.metadata[0].name
                key  = "sensitive_properties_key"
              }
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          volume_mount {
            name       = "generated-conf"
            mount_path = "/work/conf"
          }

          volume_mount {
            name       = "configure-script"
            mount_path = "/scripts"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/nifi/data"
          }
        }

        container {
          name  = "nifi"
          image = var.nifi_image

          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8080
          }

          port {
            name           = "cluster"
            container_port = 11443
          }

          port {
            name           = "load-balance"
            container_port = 6342
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1500Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "3Gi"
            }
          }

          startup_probe {
            http_get {
              path = "/nifi/"
              port = "http"
            }
            failure_threshold     = 60
            period_seconds        = 10
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/nifi/"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            tcp_socket {
              port = "http"
            }
            initial_delay_seconds = 180
            period_seconds        = 20
            timeout_seconds       = 5
          }

          security_context {
            allow_privilege_escalation = false

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "generated-conf"
            mount_path = "/opt/nifi/nifi-current/conf"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/nifi/data"
          }
        }

        volume {
          name = "generated-conf"
          empty_dir {}
        }

        volume {
          name = "configure-script"
          config_map {
            name         = kubernetes_config_map_v1.configure.metadata[0].name
            default_mode = "0755"
          }
        }

        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"

              label_selector {
                match_expressions {
                  key      = "app"
                  operator = "In"
                  values   = ["nifi"]
                }
              }
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name

        resources {
          requests = {
            storage = var.nifi_storage_size
          }
        }
      }
    }
  }

  depends_on = [kubernetes_role_binding_v1.nifi_leader_election]
}
