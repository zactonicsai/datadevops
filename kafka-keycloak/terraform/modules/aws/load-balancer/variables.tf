variable "create" {
  type    = bool
  default = true
}
variable "existing_arn" {
  type    = string
  default = null
}
variable "existing_https_listener_arn" {
  description = "When using an existing LB, the listener to attach host rules to"
  type        = string
  default     = null
}
variable "name" { type = string }
variable "type" {
  description = "application | network"
  type        = string
  default     = "application"
}
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
  description = "ACM cert for the HTTPS/TLS listener (null = HTTP/TCP only)"
  type        = string
  default     = null
}
variable "listener_port" {
  type    = number
  default = 443
}
variable "default_target_group_arn" {
  description = "Default action target for the main listener (null = fixed 404)"
  type        = string
  default     = null
}
variable "http_redirect" {
  description = "Add an :80 listener redirecting to HTTPS (ALB only)"
  type        = bool
  default     = true
}
variable "host_rules" {
  description = "Host-header routing rules on the main listener"
  type = list(object({
    hosts            = list(string)
    target_group_arn = string
    priority         = optional(number)
  }))
  default = []
}
variable "idle_timeout" {
  type    = number
  default = 60
}
variable "tags" {
  type    = map(string)
  default = {}
}
