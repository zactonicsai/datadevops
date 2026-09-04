variable "create" {
  type    = bool
  default = true
}
variable "existing" {
  description = "Use an existing DB: { address, port, db_name, username }"
  type = object({
    address  = string
    port     = optional(number, 5432)
    db_name  = string
    username = string
  })
  default = null
}
variable "name" { type = string }
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
variable "db_name" {
  type    = string
  default = "app"
}
variable "username" {
  type    = string
  default = "app"
}
variable "password" {
  type      = string
  sensitive = true
  default   = null
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
variable "backup_retention_days" {
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
