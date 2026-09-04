variable "state_bucket" { type = string }
variable "state_region" {
  type    = string
  default = null
}
variable "state_key_prefix" { type = string }
locals {
  state_region = coalesce(var.state_region, var.region)
}
