locals {
  net        = data.terraform_remote_state.network.outputs
  fqdn       = "${var.dns.host}.${var.dns.zone_name}"
  url        = "https://${local.fqdn}"
  issuer_uri = "${local.url}/realms/${var.keycloak.realm_name}"
  name       = "${var.project}-keycloak"

  lb_subnets   = coalesce(var.subnets.lb_subnet_ids, var.lb_internal ? local.net.private_subnet_ids : local.net.public_subnet_ids)
  inst_subnets = coalesce(var.subnets.instance_subnet_ids, local.net.private_subnet_ids)
  db_subnets   = coalesce(var.subnets.db_subnet_ids, local.net.private_subnet_ids)
}

data "aws_route53_zone" "this" {
  name         = var.dns.zone_name
  private_zone = false
}

# ---------------- Security groups ----------------
module "sg_lb" {
  source      = "../../modules/aws/security-group"
  create      = var.security_groups.lb.create
  existing_id = var.security_groups.lb.existing_id
  name        = "${local.name}-alb"
  vpc_id      = local.net.vpc_id
  ingress_rules = [
    { from_port = 443, to_port = 443, cidr_blocks = var.lb_allowed_cidrs, description = "https" },
    { from_port = 80, to_port = 80, cidr_blocks = var.lb_allowed_cidrs, description = "http redirect" },
  ]
  tags = local.tags
}

module "sg_instance" {
  source      = "../../modules/aws/security-group"
  create      = var.security_groups.instance.create
  existing_id = var.security_groups.instance.existing_id
  name        = "${local.name}-ec2"
  vpc_id      = local.net.vpc_id
  ingress_rules = [
    { from_port = 8080, to_port = 8080, source_security_group_id = module.sg_lb.id, description = "from alb" },
    { from_port = 9000, to_port = 9000, source_security_group_id = module.sg_lb.id, description = "health from alb" },
    { from_port = 7800, to_port = 7800, self = true, description = "jgroups cluster" },
  ]
  tags = local.tags
}

module "sg_db" {
  source      = "../../modules/aws/security-group"
  create      = var.security_groups.db.create
  existing_id = var.security_groups.db.existing_id
  name        = "${local.name}-db"
  vpc_id      = local.net.vpc_id
  ingress_rules = [
    { from_port = 5432, to_port = 5432, source_security_group_id = module.sg_instance.id, description = "postgres from keycloak" },
  ]
  tags = local.tags
}

# ---------------- Database ----------------
module "db" {
  source             = "../../modules/aws/rds-postgres"
  create             = var.database.create
  existing           = var.database.existing
  name               = local.name
  db_name            = "keycloak"
  username           = "keycloak"
  password           = var.db_password
  instance_class     = var.database.instance_class
  multi_az           = var.database.multi_az
  subnet_ids         = local.db_subnets
  security_group_ids = [module.sg_db.id]
  tags               = local.tags
}

# ---------------- IAM (instance role + profile) ----------------
module "instance_role" {
  source                  = "../../modules/aws/iam-role"
  create                  = var.instance_role.create
  existing_role_name      = var.instance_role.existing_role_name
  name                    = "${local.name}-ec2"
  trusted_services        = ["ec2.amazonaws.com"]
  managed_policy_arns     = ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"]
  create_instance_profile = true
  tags                    = local.tags
}

# ---------------- Certificate + LB + target group ----------------
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
  target_type  = "instance"
  health_check = { path = "/health/ready", port = "9000", matcher = "200" }
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
  subnet_ids                  = local.lb_subnets
  security_group_ids          = [module.sg_lb.id]
  certificate_arn             = module.cert.arn
  default_target_group_arn    = var.load_balancer.create ? module.tg.arn : null
  host_rules                  = var.load_balancer.create ? [] : [{ hosts = [local.fqdn], target_group_arn = module.tg.arn }]
  tags                        = local.tags
}

# ---------------- Launch template + instances ----------------
locals {
  realm_json = jsonencode({
    realm       = var.keycloak.realm_name
    enabled     = true
    sslRequired = "external"
    roles = { realm = [
      { name = "kafka-admin", description = "Full access in Kafka UI" },
      { name = "kafka-viewer", description = "Read-only access in Kafka UI" },
    ] }
    clients = [{
      clientId                  = "kafka-ui"
      enabled                   = true
      protocol                  = "openid-connect"
      publicClient              = false
      clientAuthenticatorType   = "client-secret"
      secret                    = var.kafka_ui_client_secret
      standardFlowEnabled       = true
      directAccessGrantsEnabled = false
      redirectUris              = ["${var.keycloak.kafka_ui_url}/*"]
      webOrigins                = [var.keycloak.kafka_ui_url]
      defaultClientScopes       = ["openid", "profile", "email", "roles"]
      protocolMappers = [{
        name           = "realm roles -> roles claim"
        protocol       = "openid-connect"
        protocolMapper = "oidc-usermodel-realm-role-mapper"
        config = {
          "claim.name" = "roles", "jsonType.label" = "String", "multivalued" = "true"
          "id.token.claim" = "true", "access.token.claim" = "true", "userinfo.token.claim" = "true"
        }
      }]
    }]
    users = [for n, u in var.test_users : {
      username = n, enabled = true, emailVerified = true, email = "${n}@example.com"
      credentials = [{ type = "password", value = u.password, temporary = false }]
      realmRoles  = u.roles
    }]
  })

  user_data = templatefile("${path.module}/files/user-data.sh.tftpl", {
    keycloak_version = var.keycloak.version
    hostname_url     = local.url
    admin_user       = var.keycloak.admin_user
    admin_password   = var.keycloak_admin_password
    db_host          = module.db.address
    db_port          = module.db.port
    db_name          = module.db.db_name
    db_user          = module.db.username
    db_password      = var.db_password
    realm_json_b64   = base64encode(local.realm_json)
  })
}

module "lt" {
  source                    = "../../modules/aws/launch-template"
  create                    = var.launch_template.create
  existing_id               = var.launch_template.existing_id
  name                      = local.name
  ami_id                    = var.launch_template.ami_id
  instance_type             = var.keycloak.instance_type
  key_name                  = var.keycloak.key_name
  security_group_ids        = [module.sg_instance.id]
  iam_instance_profile_name = module.instance_role.instance_profile_name
  user_data                 = local.user_data
  root_volume               = { size = 30 }
  tags                      = local.tags
}

module "instances" {
  source            = "../../modules/aws/ec2-instance"
  name              = local.name
  instance_count    = var.keycloak.instance_count
  launch_template   = { id = module.lt.id, version = tostring(module.lt.latest_version) }
  subnet_ids        = local.inst_subnets
  target_group_arns = [module.tg.arn]
  target_port       = 8080
  tags              = local.tags
}

# ---------------- DNS ----------------
module "dns" {
  source  = "../../modules/aws/route53-record"
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  type    = "A"
  alias   = { name = module.lb.dns_name, zone_id = module.lb.zone_id }
}
