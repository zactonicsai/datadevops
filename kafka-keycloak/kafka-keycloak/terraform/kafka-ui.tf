resource "kubernetes_secret_v1" "kafka_ui_oidc" {
  metadata {
    name      = "kafka-ui-keycloak"
    namespace = kubernetes_namespace_v1.kafka.metadata[0].name
  }
  data = {
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET = var.kafka_ui_client_secret
  }
}

resource "helm_release" "kafka_ui" {
  name       = "kafka-ui"
  namespace  = kubernetes_namespace_v1.kafka.metadata[0].name
  repository = "https://ui.charts.kafbat.io"
  chart      = "kafka-ui"
  version    = var.versions["kafka_ui_chart"]
  wait       = true
  timeout    = 600

  values = [yamlencode({
    existingSecret = kubernetes_secret_v1.kafka_ui_oidc.metadata[0].name

    yamlApplicationConfig = {
      kafka = {
        clusters = [{
          name             = "kind"
          bootstrapServers = "my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092"
        }]
      }
      auth = {
        type = "OAUTH2"
        oauth2 = {
          client = {
            keycloak = {
              clientId              = "kafka-ui"
              scope                 = "openid"
              "issuer-uri"          = local.issuer_uri
              "user-name-attribute" = "preferred_username"
              "client-name"         = "Keycloak"
              provider              = "keycloak"
              "custom-params"       = { type = "oauth", "roles-field" = "roles" }
            }
          }
        }
      }
      rbac = {
        roles = [
          {
            name     = "admins"
            clusters = ["kind"]
            subjects = [{ provider = "oauth", type = "role", value = "kafka-admin" }]
            permissions = [
              { resource = "applicationconfig", actions = "all" },
              { resource = "clusterconfig", actions = "all" },
              { resource = "topic", value = ".*", actions = "all" },
              { resource = "consumer", value = ".*", actions = "all" },
              { resource = "schema", value = ".*", actions = "all" },
              { resource = "connect", value = ".*", actions = "all" },
              { resource = "acl", actions = "all" },
              { resource = "audit", actions = "all" },
            ]
          },
          {
            name     = "viewers"
            clusters = ["kind"]
            subjects = [{ provider = "oauth", type = "role", value = "kafka-viewer" }]
            permissions = [
              { resource = "clusterconfig", actions = ["view"] },
              { resource = "topic", value = ".*", actions = ["view", "messages_read"] },
              { resource = "consumer", value = ".*", actions = ["view"] },
            ]
          },
        ]
      }
      server = { "forward-headers-strategy" = "framework" } # behind ingress
    }

    ingress = {
      enabled          = true
      ingressClassName = "nginx"
      host             = local.kafka_ui_host
      path             = "/"
      pathType         = "Prefix"
    }
  })]

  # Kafka UI validates the OIDC issuer at startup, so Keycloak + DNS rewrite must be ready first
  depends_on = [
    kubernetes_deployment_v1.keycloak,
    kubernetes_ingress_v1.keycloak,
    kubernetes_config_map_v1_data.coredns,
    kubectl_manifest.kafka,
  ]
}
