locals {
  tags = { Project = var.project, Environment = var.environment, Stack = "50-kafka-ui", ManagedBy = "terraform" }
  name = "${var.project}-${var.environment}-kafka-ui"
  fqdn = "${var.hostname}.${var.route53_zone_name}"
  url  = "https://${local.fqdn}"
}

# ---------- upstream state (each value can be overridden by tfvars) ----------
data "terraform_remote_state" "network" {
  count   = var.vpc_id == null || var.public_subnet_ids == null || var.private_subnet_ids == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/00-network.tfstate", region = local.state_region }
}
data "terraform_remote_state" "cluster" {
  count   = var.cluster_name == null || var.cluster_security_group_id == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/10-eks-cluster.tfstate", region = local.state_region }
}
data "terraform_remote_state" "keycloak" {
  count   = var.keycloak_issuer_uri == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/30-keycloak-ec2.tfstate", region = local.state_region }
}
data "terraform_remote_state" "kafka" {
  count   = var.kafka_bootstrap_servers == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/40-kafka.tfstate", region = local.state_region }
}

locals {
  cluster_name       = coalesce(var.cluster_name, try(data.terraform_remote_state.cluster[0].outputs.cluster_name, null))
  cluster_sg_id      = coalesce(var.cluster_security_group_id, try(data.terraform_remote_state.cluster[0].outputs.cluster_security_group_id, null))
  vpc_id             = coalesce(var.vpc_id, try(data.terraform_remote_state.network[0].outputs.vpc_id, null))
  public_subnet_ids  = coalesce(var.public_subnet_ids, try(data.terraform_remote_state.network[0].outputs.public_subnet_ids, null))
  private_subnet_ids = coalesce(var.private_subnet_ids, try(data.terraform_remote_state.network[0].outputs.private_subnet_ids, null))
  issuer_uri         = coalesce(var.keycloak_issuer_uri, try(data.terraform_remote_state.keycloak[0].outputs.issuer_uri, null))
  bootstrap          = coalesce(var.kafka_bootstrap_servers, try(data.terraform_remote_state.kafka[0].outputs.bootstrap_servers, null))
}

data "aws_route53_zone" "this" {
  name         = var.route53_zone_name
  private_zone = false
}

# ---------- AWS side: SG, target group (ip), ALB, cert, DNS (all reusable modules) ----------
module "sg_alb" {
  source      = "../../modules/security-group"
  create      = var.existing_alb_security_group_id == null
  existing_id = var.existing_alb_security_group_id
  name        = "${local.name}-alb"
  vpc_id      = local.vpc_id
  ingress = [
    { from_port = 443, to_port = 443, cidr_blocks = var.alb_allowed_cidrs },
    { from_port = 80, to_port = 80, cidr_blocks = var.alb_allowed_cidrs },
  ]
  tags = local.tags
}

# Allow the ALB to reach Kafka UI pods (pod IPs are in the cluster security group)
resource "aws_vpc_security_group_ingress_rule" "alb_to_pods" {
  security_group_id            = local.cluster_sg_id
  referenced_security_group_id = module.sg_alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "kafka-ui from alb"
}

module "tg" {
  source             = "../../modules/target-group"
  create             = var.existing_target_group_arn == null
  existing_arn       = var.existing_target_group_arn
  name               = local.name
  vpc_id             = local.vpc_id
  port               = 8080
  target_type        = "ip"
  health_check       = { path = "/actuator/health", matcher = "200" }
  stickiness_enabled = true
  tags               = local.tags
}

module "cert" {
  source          = "../../modules/acm-certificate"
  create          = var.existing_certificate_arn == null
  existing_arn    = var.existing_certificate_arn
  domain_name     = local.fqdn
  route53_zone_id = data.aws_route53_zone.this.zone_id
  tags            = local.tags
}

module "alb" {
  source                      = "../../modules/alb"
  create                      = var.existing_alb == null
  existing_arn                = try(var.existing_alb.arn, null)
  existing_dns_name           = try(var.existing_alb.dns_name, null)
  existing_zone_id            = try(var.existing_alb.zone_id, null)
  existing_https_listener_arn = try(var.existing_alb.https_listener_arn, null)
  name                        = local.name
  internal                    = var.alb_internal
  subnet_ids                  = var.alb_internal ? local.private_subnet_ids : local.public_subnet_ids
  security_group_ids          = [module.sg_alb.id]
  certificate_arn             = module.cert.arn
  default_target_group_arn    = var.existing_alb == null ? module.tg.arn : null
  host_rules                  = var.existing_alb == null ? {} : { (local.fqdn) = module.tg.arn }
  tags                        = local.tags
}

module "dns" {
  source  = "../../modules/route53-record"
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  alias   = { dns_name = module.alb.dns_name, zone_id = module.alb.zone_id }
}

# ---------- Kubernetes side: secret, Helm chart (local), TargetGroupBinding ----------
resource "kubernetes_secret_v1" "oidc" {
  metadata {
    name      = "kafka-ui-keycloak"
    namespace = var.namespace
  }
  data = { AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET = var.kafka_ui_client_secret }
}

locals {
  presets = {
    admin = [
      { resource = "applicationconfig", actions = "all" },
      { resource = "clusterconfig", actions = "all" },
      { resource = "topic", value = ".*", actions = "all" },
      { resource = "consumer", value = ".*", actions = "all" },
      { resource = "schema", value = ".*", actions = "all" },
      { resource = "connect", value = ".*", actions = "all" },
      { resource = "acl", actions = "all" },
      { resource = "audit", actions = "all" },
    ]
    viewer = [
      { resource = "clusterconfig", actions = ["view"] },
      { resource = "topic", value = ".*", actions = ["view", "messages_read"] },
      { resource = "consumer", value = ".*", actions = ["view"] },
    ]
  }
  image_parts = split(":", var.image)
  image_path  = split("/", local.image_parts[0])
}

module "kafka_ui" {
  source     = "../../modules/helm-app"
  name       = "kafka-ui"
  namespace  = var.namespace
  chart_path = "${path.module}/../../shared/charts/kafka-ui"
  timeout    = 900
  values = [yamlencode({
    replicaCount   = var.replicas
    image          = { registry = local.image_path[0], repository = join("/", slice(local.image_path, 1, length(local.image_path))), tag = local.image_parts[1] }
    existingSecret = kubernetes_secret_v1.oidc.metadata[0].name
    service        = { type = "ClusterIP", port = 80 }
    yamlApplicationConfig = {
      kafka = { clusters = [{ name = var.kafka_cluster_display_name, bootstrapServers = local.bootstrap }] }
      auth = { type = "OAUTH2", oauth2 = { client = { keycloak = {
        clientId              = "kafka-ui"
        scope                 = "openid"
        "issuer-uri"          = local.issuer_uri
        "user-name-attribute" = "preferred_username"
        "client-name"         = "Keycloak"
        provider              = "keycloak"
        "custom-params"       = { type = "oauth", "roles-field" = "roles" }
      } } } }
      rbac = { roles = [for role, preset in var.rbac_roles : {
        name        = role
        clusters    = [var.kafka_cluster_display_name]
        subjects    = [{ provider = "oauth", type = "role", value = role }]
        permissions = local.presets[preset]
      }] }
      server = { "forward-headers-strategy" = "framework" }
    }
    resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" } }
    ingress   = { enabled = false } # ALB + TargetGroupBinding instead
  })]
}

# Bind the Service's pods to the pre-created target group (AWS Load Balancer Controller CRD)
resource "kubectl_manifest" "tgb" {
  yaml_body = yamlencode({
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata   = { name = "kafka-ui", namespace = var.namespace }
    spec = {
      targetGroupARN = module.tg.arn
      targetType     = "ip"
      serviceRef     = { name = "kafka-ui", port = 80 }
    }
  })
  depends_on = [module.kafka_ui]
}
