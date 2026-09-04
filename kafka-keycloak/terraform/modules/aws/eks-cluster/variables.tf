variable "create" {
  type    = bool
  default = true
}
variable "existing_cluster_name" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
variable "cluster_role_arn" {
  description = "IAM role for the control plane (from iam-role module)"
  type        = string
  default     = null
}
variable "subnet_ids" {
  type    = list(string)
  default = []
}
variable "additional_security_group_ids" {
  type    = list(string)
  default = []
}
variable "endpoint_public_access" {
  type    = bool
  default = true
}
variable "endpoint_private_access" {
  type    = bool
  default = true
}
variable "public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "enable_irsa" {
  type    = bool
  default = true
}
variable "enabled_log_types" {
  type    = list(string)
  default = ["api", "audit", "authenticator"]
}
variable "addons" {
  description = "map(addon name => { version, service_account_role_arn })"
  type = map(object({
    version                  = optional(string)
    service_account_role_arn = optional(string)
  }))
  default = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}
