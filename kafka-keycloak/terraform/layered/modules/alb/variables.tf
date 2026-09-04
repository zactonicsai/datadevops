variable "create" {
  type    = bool
  default = true
}
variable "existing_arn" {
  type    = string
  default = null
}
variable "existing_dns_name" {
  type    = string
  default = null
}
variable "existing_zone_id" {
  type    = string
  default = null
}
variable "existing_https_listener_arn" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "internal" {
  type    = bool
  default = false
}
variable "subnet_ids" {
  type    = list(string)
  default = []
}
variable "security_group_ids" {
  type    = list(string)
  default = []
}
variable "certificate_arn" {
  description = "ACM cert for the HTTPS listener; null = HTTP-only listener"
  type        = string
  default     = null
}
variable "default_target_group_arn" {
  type    = string
  default = null
}
variable "host_rules" {
  description = "Host-header -> target group ARN routing rules on the main listener"
  type        = map(string)
  default     = {}
}
variable "idle_timeout" {
  type    = number
  default = 60
}
variable "tags" {
  type    = map(string)
  default = {}
}
