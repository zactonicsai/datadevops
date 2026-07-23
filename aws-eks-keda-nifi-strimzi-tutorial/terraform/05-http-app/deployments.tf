resource "kubernetes_deployment_v1" "server" {
  for_each = local.servers

  metadata {
    name      = each.value.name
    namespace = kubernetes_namespace_v1.web.metadata[0].name

    labels = {
      app    = "hello-web"
      server = each.key
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app    = "hello-web"
        server = each.key
      }
    }

    template {
      metadata {
        labels = {
          app    = "hello-web"
          server = each.key
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          run_as_group    = 101
          fs_group        = 101
        }

        container {
          name  = "nginx"
          image = var.http_image

          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "128Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "content"
            mount_path = "/usr/share/nginx/html/index.html"
            sub_path   = "index.html"
            read_only  = true
          }

          volume_mount {
            name       = "content"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/nginx"
          }

          volume_mount {
            name       = "run"
            mount_path = "/var/run"
          }
        }

        volume {
          name = "content"
          config_map {
            name = kubernetes_config_map_v1.web_content[each.key].metadata[0].name
          }
        }

        volume {
          name = "cache"
          empty_dir {}
        }

        volume {
          name = "run"
          empty_dir {}
        }

        # Prefer different worker nodes when spare capacity exists.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100

              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"

                label_selector {
                  match_expressions {
                    key      = "app"
                    operator = "In"
                    values   = ["hello-web"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
