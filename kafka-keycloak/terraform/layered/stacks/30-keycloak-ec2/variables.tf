variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }

# ---- networking (null = from 00-network state) ----
variable "vpc_id" {
  type    = string
  default = null
}
variable "public_subnet_ids" {
  type    = list(string)
  default = null
}
variable "private_subnet_ids" {
  type    = list(string)
  default = null
}

# ---- DNS / TLS ----
variable "route53_zone_name" { type = string }
variable "hostname" {
  description = "Host label for Keycloak, e.g. auth -> auth.<zone>"
  type        = string
  default     = "auth"
}
variable "existing_certificate_arn" {
  type    = string
  default = null
}

# ---- pre-existing infrastructure (all optional) ----
variable "existing_alb_security_group_id" {
  type    = string
  default = null
}
variable "existing_app_security_group_id" {
  type    = string
  default = null
}
variable "existing_db_security_group_id" {
  type    = string
  default = null
}
variable "existing_instance_role_arn" {
  type    = string
  default = null
}
variable "existing_instance_profile_name" {
  description = "Required together with existing_instance_role_arn"
  type        = string
  default     = null
}
variable "existing_launch_template_id" {
  type    = string
  default = null
}
variable "existing_target_group_arn" {
  type    = string
  default = null
}
variable "existing_alb" {
  description = "Reuse an ALB: { arn, dns_name, zone_id, https_listener_arn }"
  type        = object({ arn = string, dns_name = string, zone_id = string, https_listener_arn = string })
  default     = null
}
variable "existing_db_endpoint" {
  type    = string
  default = null
}

# ---- compute ----
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "key_name" {
  type    = string
  default = null
}
variable "ami_id" {
  type    = string
  default = null
}
variable "desired_capacity" {
  type    = number
  default = 1
}
variable "alb_internal" {
  type    = bool
  default = false
}
variable "alb_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

# ---- Keycloak ----
variable "keycloak_image" {
  type    = string
  default = "quay.io/keycloak/keycloak:26.3.0"
}
variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}
variable "db_password" {
  type      = string
  sensitive = true
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}
variable "kafka_ui_url" {
  description = "Redirect URL of Kafka UI (https://kafka-ui.<zone>)"
  type        = string
}
variable "kafka_ui_client_secret" {
  type      = string
  sensitive = true
}
variable "test_users" {
  type      = map(object({ password = string, roles = list(string) }))
  default   = {}
  sensitive = true
}
