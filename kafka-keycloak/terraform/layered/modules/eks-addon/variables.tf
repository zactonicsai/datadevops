variable "cluster_name" { type = string }
variable "addon_name" { type = string }
variable "addon_version" {
  type    = string
  default = null
}
variable "service_account_role_arn" {
  type    = string
  default = null
}
variable "configuration_values" {
  type    = string
  default = null
}
