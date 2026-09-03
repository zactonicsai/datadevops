variable "name" { type = string }
variable "kubernetes_version" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "public_subnet_ids" { type = list(string) }
variable "node_instance_types" { type = list(string) }
variable "node_desired" { type = number }
variable "node_min" { type = number }
variable "node_max" { type = number }
variable "tags" {
  type    = map(string)
  default = {}
}
