variable "dns" {
  type = object({
    zone_name = string
    host      = optional(string, "kafka-ui")
  })
}
variable "kafka_ui" {
  type = object({
    namespace    = optional(string, "kafka")
    replicas     = optional(number, 2)
    image_tag    = optional(string, "v1.5.0")
    cluster_display_name = optional(string, "eks")
    admin_role   = optional(string, "kafka-admin")  # Keycloak realm role names
    viewer_role  = optional(string, "kafka-viewer")
  })
  default = {}
}
variable "kafka_ui_client_secret" {
  type      = string
  sensitive = true
}
variable "lb_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "lb_internal" {
  type    = bool
  default = true
}
variable "lb_subnet_ids" {
  description = "null = private (internal) or public subnets from network stack"
  type        = list(string)
  default     = null
}
variable "security_group" {
  type = object({
    create      = optional(bool, true)
    existing_id = optional(string)
  })
  default = {}
}
variable "certificate" {
  type = object({
    create       = optional(bool, true)
    existing_arn = optional(string)
  })
  default = {}
}
variable "target_group" {
  type = object({
    create       = optional(bool, true)
    existing_arn = optional(string)
  })
  default = {}
}
variable "load_balancer" {
  type = object({
    create                      = optional(bool, true)
    existing_arn                = optional(string)
    existing_https_listener_arn = optional(string)
  })
  default = {}
}
