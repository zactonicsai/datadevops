resource "kubernetes_namespace_v1" "keycloak" {
  metadata { name = "keycloak" }
  depends_on = [kind_cluster.this]
}

resource "kubernetes_config_map_v1" "realm" {
  metadata {
    name      = "keycloak-realm"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = {
    "realm-kafka.json" = templatefile("${path.module}/files/realm-kafka.json.tftpl", {
      client_secret = var.kafka_ui_client_secret
      kafka_ui_url  = local.kafka_ui_url
    })
  }
}

resource "kubernetes_secret_v1" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = {
    username = "admin"
    password = var.keycloak_admin_password
  }
}

# Dev-mode Keycloak (in-memory DB) — fine for kind, not for production.
resource "kubernetes_deployment_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    labels    = { app = "keycloak" }
  }
  wait_for_rollout = true
  timeouts { create = "10m" }

  spec {
    replicas = 1
    selector { match_labels = { app = "keycloak" } }
    template {
      metadata { labels = { app = "keycloak" } }
      spec {
        container {
          name  = "keycloak"
          image = var.versions["keycloak_image"]
          args  = ["start-dev", "--import-realm"]

          env {
            name = "KC_BOOTSTRAP_ADMIN_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.keycloak_admin.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "KC_BOOTSTRAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.keycloak_admin.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name  = "KC_HOSTNAME" # token issuer = this URL
            value = local.keycloak_url
          }
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_PROXY_HEADERS" # behind ingress-nginx
            value = "xforwarded"
          }
          env {
            name  = "KC_HEALTH_ENABLED"
            value = "true"
          }

          port {
            name           = "http"
            container_port = 8080
          }
          port {
            name           = "mgmt"
            container_port = 9000
          }

          readiness_probe {
            http_get {
              path = "/health/ready"
              port = 9000
            }
            initial_delay_seconds = 20
            period_seconds        = 5
            failure_threshold     = 30
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { memory = "1Gi" }
          }
          volume_mount {
            name       = "realm"
            mount_path = "/opt/keycloak/data/import"
            read_only  = true
          }
        }
        volume {
          name = "realm"
          config_map { name = kubernetes_config_map_v1.realm.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  spec {
    selector = { app = "keycloak" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_ingress_v1" "keycloak" {
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/proxy-buffer-size" = "128k" # Keycloak sends large headers
    }
  }
  spec {
    ingress_class_name = "nginx"
    rule {
      host = local.keycloak_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.keycloak.metadata[0].name
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.ingress_nginx]
}
