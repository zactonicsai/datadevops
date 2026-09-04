variable "cluster_name" { type = string }
variable "name" { type = string }
variable "node_role_arn" { type = string }
variable "subnet_ids" { type = list(string) }
variable "instance_types" {
  type    = list(string)
  default = ["m6i.large"]
}
variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"
}
variable "ami_type" {
  type    = string
  default = "AL2023_x86_64_STANDARD"
}
variable "desired_size" {
  type    = number
  default = 2
}
variable "min_size" {
  type    = number
  default = 1
}
variable "max_size" {
  type    = number
  default = 4
}
variable "launch_template_id" {
  type    = string
  default = null
}
variable "launch_template_version" {
  type    = string
  default = "$Latest"
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "taints" {
  type = list(object({ key = string, value = optional(string), effect = string }))
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
