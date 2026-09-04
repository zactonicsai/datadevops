# Shared-state plumbing: every stack can read upstream outputs from S3, but every
# upstream value can ALSO be provided directly via tfvars (pre-existing resources).
variable "state_bucket" {
  description = "S3 bucket holding the state of the other stacks"
  type        = string
}
variable "state_region" {
  type    = string
  default = null
}
variable "state_key_prefix" {
  description = "Key prefix, e.g. kafka-keycloak/dev"
  type        = string
}
locals {
  state_region = coalesce(var.state_region, var.region)
}
