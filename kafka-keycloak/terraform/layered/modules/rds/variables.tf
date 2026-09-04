variable "create" {
  type    = bool
  default = true
}
variable "existing_endpoint" {
  type    = string
  default = null
}
variable "identifier" { type = string }
variable "engine" {
  type    = string
  default = "postgres"
}
variable "engine_version" {
  type    = string
  default = "16"
}
variable "instance_class" {
  type    = string
  default = "db.t4g.small"
}
variable "allocated_storage" {
  type    = number
  default = 20
}
variable "db_name" { type = string }
variable "username" { type = string }
variable "password" {
  type      = string
  sensitive = true
}
variable "subnet_ids" {
  type    = list(string)
  default = []
}
variable "security_group_ids" {
  type    = list(string)
  default = []
}
variable "multi_az" {
  type    = bool
  default = false
}
variable "backup_retention_period" {
  type    = number
  default = 7
}
variable "deletion_protection" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}
