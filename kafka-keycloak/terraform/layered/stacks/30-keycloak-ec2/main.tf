locals {
  tags = { Project = var.project, Environment = var.environment, Stack = "30-keycloak-ec2", ManagedBy = "terraform" }
  name = "${var.project}-${var.environment}-keycloak"
  fqdn = "${var.hostname}.${var.route53_zone_name}"
  url  = "https://${local.fqdn}"
}

data "terraform_remote_state" "network" {
  count   = var.vpc_id == null || var.public_subnet_ids == null || var.private_subnet_ids == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/00-network.tfstate", region = local.state_region }
}

locals {
  vpc_id             = coalesce(var.vpc_id, try(data.terraform_remote_state.network[0].outputs.vpc_id, null))
  public_subnet_ids  = coalesce(var.public_subnet_ids, try(data.terraform_remote_state.network[0].outputs.public_subnet_ids, null))
  private_subnet_ids = coalesce(var.private_subnet_ids, try(data.terraform_remote_state.network[0].outputs.private_subnet_ids, null))
}

data "aws_route53_zone" "this" {
  name         = var.route53_zone_name
  private_zone = false
}

# ---------------- secrets (SSM SecureString; instances fetch at boot) ----------------
module "secrets" {
  source = "../../modules/ssm-secrets"
  prefix = "/${var.project}/${var.environment}/keycloak"
  secrets = {
    admin_password         = var.keycloak_admin_password
    db_password            = var.db_password
    kafka_ui_client_secret = var.kafka_ui_client_secret
  }
  tags = local.tags
}

# ---------------- security groups ----------------
module "sg_alb" {
  source      = "../../modules/security-group"
  create      = var.existing_alb_security_group_id == null
  existing_id = var.existing_alb_security_group_id
  name        = "${local.name}-alb"
  vpc_id      = local.vpc_id
  ingress = [
    { from_port = 443, to_port = 443, cidr_blocks = var.alb_allowed_cidrs, description = "https" },
    { from_port = 80, to_port = 80, cidr_blocks = var.alb_allowed_cidrs, description = "http->https redirect" },
  ]
  tags = local.tags
}

module "sg_app" {
  source      = "../../modules/security-group"
  create      = var.existing_app_security_group_id == null
  existing_id = var.existing_app_security_group_id
  name        = "${local.name}-app"
  vpc_id      = local.vpc_id
  ingress = [
    { from_port = 8080, to_port = 8080, source_security_group_id = module.sg_alb.id, description = "keycloak http from alb" },
    { from_port = 9000, to_port = 9000, source_security_group_id = module.sg_alb.id, description = "health from alb" },
  ]
  tags = local.tags
}

module "sg_db" {
  source      = "../../modules/security-group"
  create      = var.existing_db_security_group_id == null
  existing_id = var.existing_db_security_group_id
  name        = "${local.name}-db"
  vpc_id      = local.vpc_id
  ingress = [
    { from_port = 5432, to_port = 5432, source_security_group_id = module.sg_app.id, description = "postgres from app" },
  ]
  egress_all = false
  tags       = local.tags
}

# ---------------- database ----------------
module "db" {
  source             = "../../modules/rds"
  create             = var.existing_db_endpoint == null
  existing_endpoint  = var.existing_db_endpoint
  identifier         = local.name
  instance_class     = var.db_instance_class
  db_name            = "keycloak"
  username           = "keycloak"
  password           = var.db_password
  subnet_ids         = local.private_subnet_ids
  security_group_ids = [module.sg_db.id]
  tags               = local.tags
}

# ---------------- IAM (read its own secrets, SSM Session Manager, CloudWatch logs) ----------------
module "instance_role" {
  source                  = "../../modules/iam-role"
  create                  = var.existing_instance_role_arn == null
  existing_role_arn       = var.existing_instance_role_arn
  name                    = local.name
  trusted_services        = ["ec2.amazonaws.com"]
  create_instance_profile = var.existing_instance_role_arn == null
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]
  inline_policies = {
    read-secrets = jsonencode({
      Version = "2012-10-17"
      Statement = [
        { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = values(module.secrets.parameter_arns) },
        { Effect = "Allow", Action = ["kms:Decrypt"], Resource = "*", Condition = { StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" } } },
      ]
    })
  }
  tags = local.tags
}

# ---------------- launch template + ASG ----------------
locals {
  realm_json = templatefile("${path.module}/files/realm.json.tftpl", {
    kafka_ui_url = var.kafka_ui_url
    users        = var.test_users
  })
  user_data = templatefile("${path.module}/files/user-data.sh.tftpl", {
    region         = var.region
    keycloak_image = var.keycloak_image
    keycloak_url   = local.url
    db_host        = module.db.endpoint
    db_name        = module.db.db_name
    db_user        = module.db.username
    ssm_prefix     = "/${var.project}/${var.environment}/keycloak"
    realm_json_b64 = base64encode(local.realm_json)
  })
}

module "lt" {
  source                    = "../../modules/launch-template"
  create                    = var.existing_launch_template_id == null
  existing_id               = var.existing_launch_template_id
  name                      = local.name
  ami_id                    = var.ami_id
  instance_type             = var.instance_type
  key_name                  = var.key_name
  security_group_ids        = [module.sg_app.id]
  iam_instance_profile_name = coalesce(module.instance_role.instance_profile_name, var.existing_instance_profile_name)
  user_data                 = local.user_data
  root_volume_size          = 30
  tags                      = local.tags
}

module "tg" {
  source       = "../../modules/target-group"
  create       = var.existing_target_group_arn == null
  existing_arn = var.existing_target_group_arn
  name         = local.name
  vpc_id       = local.vpc_id
  port         = 8080
  target_type  = "instance"
  health_check = { path = "/health/ready", port = "9000", matcher = "200" }
  stickiness_enabled = true
  tags         = local.tags
}

module "asg" {
  source                  = "../../modules/ec2-asg"
  name                    = local.name
  launch_template_id      = module.lt.id
  subnet_ids              = local.private_subnet_ids
  min_size                = 1
  max_size                = 3
  desired_capacity        = var.desired_capacity
  target_group_arns       = [module.tg.arn]
  health_check_type       = "ELB"
  health_check_grace_period = 420
  tags                    = local.tags
}

# ---------------- TLS + ALB + DNS ----------------
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
  host_rules                  = var.existing_alb == null ? {} : { (local.fqdn) = module.tg.arn } # shared ALB: add a host rule
  tags                        = local.tags
}

module "dns" {
  source  = "../../modules/route53-record"
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  alias   = { dns_name = module.alb.dns_name, zone_id = module.alb.zone_id }
}
