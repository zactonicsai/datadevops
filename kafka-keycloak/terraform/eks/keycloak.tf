# ======================= Keycloak on the PLATFORM cluster =======================

# ---- RDS PostgreSQL ----
resource "aws_db_subnet_group" "keycloak" {
  name       = "${var.project}-keycloak"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_security_group" "keycloak_db" {
  name   = "${var.project}-keycloak-db"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.platform.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "keycloak" {
  identifier             = "${var.project}-keycloak"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t4g.small"
  allocated_storage      = 20
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = "keycloak"
  username               = "keycloak"
  password               = var.keycloak_db_password
  db_subnet_group_name   = aws_db_subnet_group.keycloak.name
  vpc_security_group_ids = [aws_security_group.keycloak_db.id]
  multi_az               = false
  backup_retention_period = 7
  skip_final_snapshot    = true
  deletion_protection    = false
}

# ---- namespace + secrets ----
resource "kubernetes_namespace_v1" "keycloak" {
  provider = kubernetes.platform
  metadata { name = "keycloak" }
  depends_on = [module.platform]
}

resource "kubernetes_secret_v1" "keycloak_db" {
  provider = kubernetes.platform
  metadata {
    name      = "keycloak-db"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = { username = aws_db_instance.keycloak.username, password = var.keycloak_db_password }
}

resource "kubernetes_secret_v1" "keycloak_admin" {
  provider = kubernetes.platform
  metadata {
    name      = "keycloak-initial-admin"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = { username = "admin", password = var.keycloak_admin_password }
}

resource "kubernetes_secret_v1" "kafka_ui_client" {
  provider = kubernetes.platform
  metadata {
    name      = "kafka-ui-client"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  }
  data = { secret = var.kafka_ui_client_secret }
}

# ---- Keycloak Operator from LOCAL manifests (CRDs first, then RBAC + Deployment) ----
data "kubectl_file_documents" "kc_crds" {
  content = join("\n---\n", [
    file("${path.module}/manifests/keycloak-operator/01-crd-keycloaks.yml"),
    file("${path.module}/manifests/keycloak-operator/02-crd-keycloakrealmimports.yml"),
  ])
}

resource "kubectl_manifest" "kc_crds" {
  provider           = kubectl.platform
  for_each           = data.kubectl_file_documents.kc_crds.manifests
  yaml_body          = each.value
  server_side_apply  = true # CRDs are too large for client-side apply annotations
  wait               = true
  depends_on         = [module.platform]
}

data "kubectl_file_documents" "kc_operator" {
  content = file("${path.module}/manifests/keycloak-operator/03-operator.yml")
}

resource "kubectl_manifest" "kc_operator" {
  provider           = kubectl.platform
  for_each           = data.kubectl_file_documents.kc_operator.manifests
  yaml_body          = each.value
  override_namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
  wait_for_rollout   = true
  depends_on         = [kubectl_manifest.kc_crds]
}

# ---- Keycloak instance ----
resource "kubectl_manifest" "keycloak" {
  provider  = kubectl.platform
  yaml_body = yamlencode({
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "Keycloak"
    metadata   = { name = "keycloak", namespace = kubernetes_namespace_v1.keycloak.metadata[0].name }
    spec = {
      instances = 2
      image     = var.images["keycloak"]
      bootstrapAdmin = { user = { secret = kubernetes_secret_v1.keycloak_admin.metadata[0].name } }
      db = {
        vendor         = "postgres"
        host           = aws_db_instance.keycloak.address
        port           = 5432
        database       = aws_db_instance.keycloak.db_name
        usernameSecret = { name = kubernetes_secret_v1.keycloak_db.metadata[0].name, key = "username" }
        passwordSecret = { name = kubernetes_secret_v1.keycloak_db.metadata[0].name, key = "password" }
      }
      hostname = { hostname = local.keycloak_url, strict = true } # -> token "iss"
      http     = { httpEnabled = true }                          # TLS ends at the ALB
      proxy    = { headers = "xforwarded" }
      ingress  = { enabled = false }
      additionalOptions = [
        { name = "health-enabled", value = "true" },
        { name = "metrics-enabled", value = "true" },
      ]
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "2", memory = "2Gi" }
      }
    }
  })
  wait_for {
    field {
      key   = "status.conditions.[0].status"
      value = "True"
    }
  }
  timeouts { create = "15m" }
  depends_on = [kubectl_manifest.kc_operator, aws_db_instance.keycloak]
}

# ---- ALB ingress ----
resource "kubernetes_ingress_v1" "keycloak" {
  provider = kubernetes.platform
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.keycloak.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTPS = 443 }])
      "alb.ingress.kubernetes.io/certificate-arn"  = aws_acm_certificate_validation.this.certificate_arn
      "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
      "alb.ingress.kubernetes.io/healthcheck-path" = "/realms/master"
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      host = local.keycloak_fqdn
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "keycloak-service" # created by the operator: <cr-name>-service
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
  wait_for_load_balancer = true
  depends_on             = [helm_release.lbc_platform, kubectl_manifest.keycloak]
}

resource "aws_route53_record" "keycloak" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.keycloak_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_ingress_v1.keycloak.status[0].load_balancer[0].ingress[0].hostname]
}

# ---- Realm (declarative import; client secret via operator placeholder, users from a variable) ----
resource "kubectl_manifest" "realm" {
  provider  = kubectl.platform
  yaml_body = yamlencode({
    apiVersion = "k8s.keycloak.org/v2alpha1"
    kind       = "KeycloakRealmImport"
    metadata   = { name = "kafka-realm", namespace = kubernetes_namespace_v1.keycloak.metadata[0].name }
    spec = {
      keycloakCRName = "keycloak"
      placeholders = {
        KAFKA_UI_CLIENT_SECRET = { secret = { name = kubernetes_secret_v1.kafka_ui_client.metadata[0].name, key = "secret" } }
      }
      realm = {
        realm       = "kafka"
        enabled     = true
        sslRequired = "external"
        roles = { realm = [
          { name = "kafka-admin", description = "Full access in Kafka UI" },
          { name = "kafka-viewer", description = "Read-only access in Kafka UI" },
        ] }
        clients = [{
          clientId                  = "kafka-ui"
          name                      = "Kafka UI"
          enabled                   = true
          protocol                  = "openid-connect"
          publicClient              = false
          clientAuthenticatorType   = "client-secret"
          secret                    = "$${KAFKA_UI_CLIENT_SECRET}" # substituted by the operator from the Secret
          standardFlowEnabled       = true
          directAccessGrantsEnabled = false
          implicitFlowEnabled       = false
          redirectUris              = ["${local.kafka_ui_url}/*"]
          webOrigins                = [local.kafka_ui_url]
          defaultClientScopes       = ["openid", "profile", "email", "roles"]
          protocolMappers = [{
            name           = "realm roles -> roles claim"
            protocol       = "openid-connect"
            protocolMapper = "oidc-usermodel-realm-role-mapper"
            config = {
              "claim.name"           = "roles"
              "jsonType.label"       = "String"
              "multivalued"          = "true"
              "id.token.claim"       = "true"
              "access.token.claim"   = "true"
              "userinfo.token.claim" = "true"
            }
          }]
        }]
        users = [for name, u in var.test_users : {
          username      = name
          enabled       = true
          emailVerified = true
          email         = "${name}@example.com"
          credentials   = [{ type = "password", value = u.password, temporary = false }]
          realmRoles    = u.roles
        }]
      }
    }
  })
  depends_on = [kubectl_manifest.keycloak]
}

# Give DNS a moment before Kafka UI validates the issuer
resource "time_sleep" "keycloak_dns" {
  create_duration = "90s"
  depends_on      = [aws_route53_record.keycloak, kubectl_manifest.realm]
}
