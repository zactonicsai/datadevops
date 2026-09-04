variable "cluster_name" { type = string }
variable "name" { type = string }
variable "node_role_arn" { type = string }
variable "subnet_ids" { type = list(string) }
variable "instance_types" {
  type    = list(string)
  default = ["m6i.large"]
}
variable "capacity_type" {
  description = "ON_DEMAND | SPOT"
  type        = string
  default     = "ON_DEMAND"
}
variable "ami_type" {
  type    = string
  default = "AL2023_x86_64_STANDARD"
}
variable "disk_size" {
  description = "Only used when no launch template is given"
  type        = number
  default     = 50
}
variable "scaling" {
  type = object({
    desired = number
    min     = number
    max     = number
  })
  default = { desired = 2, min = 1, max = 4 }
}
variable "launch_template" {
  description = "Optional { id, version } from the launch-template module"
  type = object({
    id      = string
    version = string
  })
  default = null
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "taints" {
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = []
}
variable "max_unavailable" {
  type    = number
  default = 1
}
variable "tags" {
  type    = map(string)
  default = {}
}
