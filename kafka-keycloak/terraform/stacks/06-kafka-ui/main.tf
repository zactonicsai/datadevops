locals {
  net      = data.terraform_remote_state.network.outputs
  keycloak = data.terraform_remote_state.keycloak.outputs
  kafka    = data.terraform_remote_state.kafka.outputs
  fqdn     = "${var.dns.host}.${var.dns.zone_name}"
  url      = "https://${local.fqdn}"
  name     = "${var.project}-kafka-ui"
  ns       = var.kafka_ui.namespace
  subnets  = coalesce(var.lb_subnet_ids, var.lb_internal ? local.net.private_subnet_ids : local.net.public_subnet_ids)
}

data "aws_route53_zone" "this" {
  name         = var.dns.zone_name
  private_zone = false
}

# ---------------- AWS side: SG, cert, target group (ip targets = pods), ALB ----------------
module "sg_lb" {
  source      = "../../modules/aws/security-group"
  create      = var.security_group.create
  existing_id = var.security_group.existing_id
  name        = "${local.name}-alb"
  vpc_id      = local.net.vpc_id
  ingress_rules = [
    { from_port = 443, to_port = 443, cidr_blocks = var.lb_allowed_cidrs, description = "https" },
    { from_port = 80, to_port = 80, cidr_blocks = var.lb_allowed_cidrs, description = "http redirect" },
  ]
  tags = local.tags
}

module "cert" {
  source       = "../../modules/aws/acm-certificate"
  create       = var.certificate.create
  existing_arn = var.certificate.existing_arn
  domain_name  = local.fqdn
  zone_id      = data.aws_route53_zone.this.zone_id
  tags         = local.tags
}

module "tg" {
  source       = "../../modules/aws/target-group"
  create       = var.target_group.create
  existing_arn = var.target_group.existing_arn
  name         = substr(local.name, 0, 32)
  vpc_id       = local.net.vpc_id
  port         = 8080
  protocol     = "HTTP"
  target_type  = "ip" # pods registered by the LB controller via TargetGroupBinding
  health_check = { path = "/actuator/health", matcher = "200" }
  stickiness   = { enabled = true }
  tags         = local.tags
}

module "lb" {
  source                      = "../../modules/aws/load-balancer"
  create                      = var.load_balancer.create
  existing_arn                = var.load_balancer.existing_arn
  existing_https_listener_arn = var.load_balancer.existing_https_listener_arn
  name                        = substr(local.name, 0, 32)
  type                        = "application"
  internal                    = var.lb_internal
  subnet_ids                  = local.subnets
  security_group_ids          = [module.sg_lb.id]
  certificate_arn             = module.cert.arn
  default_target_group_arn    = var.load_balancer.create ? module.tg.arn : null
  host_rules                  = var.load_balancer.create ? [] : [{ hosts = [local.fqdn], target_group_arn = module.tg.arn }]
  tags                        = local.tags
}

module "dns" {
  source  = "../../modules/aws/route53-record"
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  type    = "A"
  alias   = { name = module.lb.dns_name, zone_id = module.lb.zone_id }
}

# ---------------- Kubernetes side ----------------
resource "kubernetes_secret_v1" "oidc" {
  metadata {
    name      = "kafka-ui-keycloak"
    namespace = local.ns
  }
  data = { AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET = var.kafka_ui_client_secret }
}

resource "helm_release" "kafka_ui" {
  name      = "kafka-ui"
  namespace = local.ns
  chart     = "${path.module}/../../vendor/charts/kafka-ui" # local, no network
  wait      = true
  timeout   = 900

  values = [yamlencode({
    replicaCount   = var.kafka_ui.replicas
    image          = { tag = var.kafka_ui.image_tag }
    existingSecret = kubernetes_secret_v1.oidc.metadata[0].name
    service        = { type = "ClusterIP", port = 80 }
    ingress        = { enabled = false } # ALB is managed by the core modules above

    yamlApplicationConfig = {
      kafka = { clusters = [{ name = var.kafka_ui.cluster_display_name, bootstrapServers = local.kafka.bootstrap_servers }] }
      auth = {
        type = "OAUTH2"
        oauth2 = { client = { keycloak = {
          clientId              = "kafka-ui"
          scope                 = "openid"
          "issuer-uri"          = local.keycloak.issuer_uri
          "user-name-attribute" = "preferred_username"
          "client-name"         = "Keycloak"
          provider              = "keycloak"
          "custom-params"       = { type = "oauth", "roles-field" = "roles" }
        } } }
      }
      rbac = { roles = [
        {
          name = "admins", clusters = [var.kafka_ui.cluster_display_name]
          subjects = [{ provider = "oauth", type = "role", value = var.kafka_ui.admin_role }]
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
          name = "viewers", clusters = [var.kafka_ui.cluster_display_name]
          subjects = [{ provider = "oauth", type = "role", value = var.kafka_ui.viewer_role }]
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
  })]
}

# Register the Service's pods in the pre-created target group (LB controller does the wiring
# and opens the node/pod security group for the ALB SG on port 8080).
resource "kubectl_manifest" "tgb" {
  yaml_body = yamlencode({
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata   = { name = "kafka-ui", namespace = local.ns }
    spec = {
      targetGroupARN = module.tg.arn
      targetType     = "ip"
      serviceRef     = { name = "kafka-ui", port = 80 }
      networking = { ingress = [{
        from  = [{ securityGroup = { groupID = module.sg_lb.id } }]
        ports = [{ protocol = "TCP", port = 8080 }]
      }] }
    }
  })
  depends_on = [helm_release.kafka_ui]
}
