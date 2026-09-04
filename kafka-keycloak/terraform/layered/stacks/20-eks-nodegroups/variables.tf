variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "cluster_name" {
  description = "null = from 10-eks-cluster state"
  type        = string
  default     = null
}
variable "private_subnet_ids" {
  description = "null = from 00-network state"
  type        = list(string)
  default     = null
}
variable "vpc_id" {
  type    = string
  default = null
}
variable "oidc_provider_arn" {
  type    = string
  default = null
}
variable "existing_node_role_arn" {
  type    = string
  default = null
}
variable "existing_launch_template_id" {
  description = "Provide to use a pre-built node launch template"
  type        = string
  default     = null
}
variable "node_key_name" {
  type    = string
  default = null
}
variable "node_root_volume_size" {
  type    = number
  default = 80
}
variable "node_groups" {
  type = map(object({
    instance_types = list(string)
    desired        = number
    min            = number
    max            = number
    capacity_type  = optional(string, "ON_DEMAND")
    labels         = optional(map(string), {})
    taints         = optional(list(object({ key = string, value = optional(string), effect = string })), [])
  }))
}
variable "namespaces" {
  description = "Namespaces to create for application stacks"
  type = map(object({
    labels         = optional(map(string), {})
    resource_quota = optional(map(string), {})
  }))
  default = {}
}
variable "install_lb_controller" {
  type    = bool
  default = true
}
variable "install_ebs_csi" {
  type    = bool
  default = true
}
