# ======================= Kafka UI on the DATA cluster (local chart) =======================
resource "kubernetes_secret_v1" "kafka_ui_oidc" {
  provider = kubernetes.data
  metadata {
    name      = "kafka-ui-keycloak"
    namespace = kubernetes_namespace_v1.kafka.metadata[0].name
  }
  data = { AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET = var.kafka_ui_client_secret }
}

resource "helm_release" "kafka_ui" {
  provider  = helm.data
  name      = "kafka-ui"
  namespace = kubernetes_namespace_v1.kafka.metadata[0].name
  chart     = local.charts.kafka_ui # local directory
  wait      = true
  timeout   = 900

  values = [yamlencode({
    replicaCount   = 2
    image          = { registry = split("/", var.images["kafka_ui"])[0], repository = join("/", slice(split("/", split(":", var.images["kafka_ui"])[0]), 1, 3)), tag = split(":", var.images["kafka_ui"])[1] }
    existingSecret = kubernetes_secret_v1.kafka_ui_oidc.metadata[0].name

    yamlApplicationConfig = {
      kafka = { clusters = [{ name = "eks-prod", bootstrapServers = "my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092" }] }
      auth = {
        type = "OAUTH2"
        oauth2 = { client = { keycloak = {
          clientId              = "kafka-ui"
          scope                 = "openid"
          "issuer-uri"          = local.issuer_uri
          "user-name-attribute" = "preferred_username"
          "client-name"         = "Keycloak"
          provider              = "keycloak"
          "custom-params"       = { type = "oauth", "roles-field" = "roles" }
        } } }
      }
      rbac = { roles = [
        {
          name = "admins", clusters = ["eks-prod"]
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
          name = "viewers", clusters = ["eks-prod"]
          subjects = [{ provider = "oauth", type = "role", value = "kafka-viewer" }]
          permissions = [
            { resource = "clusterconfig", actions = ["view"] },
            { resource = "topic", value = ".*", actions = ["view", "messages_read"] },
            { resource = "consumer", value = ".*", actions = ["view"] },
          ]
        },
      ] }
      server = { "forward-headers-strategy" = "framework" }
    }

    resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }

    ingress = {
      enabled          = true
      ingressClassName = "alb"
      host             = local.kafka_ui_fqdn
      path             = "/"
      pathType         = "Prefix"
      annotations = {
        "alb.ingress.kubernetes.io/scheme"                  = var.kafka_ui_alb_scheme
        "alb.ingress.kubernetes.io/target-type"             = "ip"
        "alb.ingress.kubernetes.io/listen-ports"            = jsonencode([{ HTTPS = 443 }])
        "alb.ingress.kubernetes.io/certificate-arn"         = aws_acm_certificate_validation.this.certificate_arn
        "alb.ingress.kubernetes.io/ssl-redirect"            = "443"
        "alb.ingress.kubernetes.io/healthcheck-path"        = "/actuator/health"
        "alb.ingress.kubernetes.io/inbound-cidrs"           = join(",", var.kafka_ui_allowed_cidrs)
        "alb.ingress.kubernetes.io/target-group-attributes" = "stickiness.enabled=true,stickiness.lb_cookie.duration_seconds=86400"
      }
    }
  })]

  depends_on = [helm_release.lbc_data, kubectl_manifest.kafka, time_sleep.keycloak_dns]
}

data "kubernetes_ingress_v1" "kafka_ui" {
  provider = kubernetes.data
  metadata {
    name      = "kafka-ui"
    namespace = kubernetes_namespace_v1.kafka.metadata[0].name
  }
  depends_on = [helm_release.kafka_ui]
}

resource "aws_route53_record" "kafka_ui" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.kafka_ui_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [data.kubernetes_ingress_v1.kafka_ui.status[0].load_balancer[0].ingress[0].hostname]
}
