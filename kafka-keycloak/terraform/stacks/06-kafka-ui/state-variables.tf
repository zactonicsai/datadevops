# Where the other stacks keep their state (same bucket, different keys)
variable "state_bucket" { type = string }
variable "state_region" { type = string }
variable "state_prefix" {
  type    = string
  default = "kafka-keycloak"
}
variable "region" { type = string }
variable "project" {
  type    = string
  default = "kafka-keycloak"
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  tags = merge({ Project = var.project, ManagedBy = "terraform" }, var.tags)
}
