variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "cluster_name" {
  type    = string
  default = null
}
variable "cluster_security_group_id" {
  type    = string
  default = null
}
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
variable "namespace" {
  type    = string
  default = "kafka-ui"
}
variable "kafka_bootstrap_servers" {
  description = "null = from 40-kafka state"
  type        = string
  default     = null
}
variable "kafka_cluster_display_name" {
  type    = string
  default = "eks"
}
variable "keycloak_issuer_uri" {
  description = "null = from 30-keycloak-ec2 state"
  type        = string
  default     = null
}
variable "kafka_ui_client_secret" {
  type      = string
  sensitive = true
}
variable "route53_zone_name" { type = string }
variable "hostname" {
  type    = string
  default = "kafka-ui"
}
variable "image" {
  type    = string
  default = "ghcr.io/kafbat/kafka-ui:v1.5.0"
}
variable "replicas" {
  type    = number
  default = 2
}
variable "alb_internal" {
  type    = bool
  default = false
}
variable "alb_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "rbac_roles" {
  description = "Keycloak realm role -> Kafka UI permissions preset (admin | viewer)"
  type        = map(string)
  default     = { kafka-admin = "admin", kafka-viewer = "viewer" }
}

# ---- pre-existing infra ----
variable "existing_certificate_arn" {
  type    = string
  default = null
}
variable "existing_alb_security_group_id" {
  type    = string
  default = null
}
variable "existing_target_group_arn" {
  type    = string
  default = null
}
variable "existing_alb" {
  type    = object({ arn = string, dns_name = string, zone_id = string, https_listener_arn = string })
  default = null
}
