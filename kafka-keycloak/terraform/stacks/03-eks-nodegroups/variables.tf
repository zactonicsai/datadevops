variable "node_role" {
  type = object({
    create             = optional(bool, true)
    existing_role_name = optional(string)
    extra_policy_arns  = optional(list(string), [])
  })
  default = {}
}

variable "launch_template" {
  description = "Optional custom launch template for all node groups (null = EKS default). ami_id null = EKS-optimized AMI chosen by EKS."
  type = object({
    enabled      = optional(bool, false)
    existing_id  = optional(string)
    key_name     = optional(string)
    root_volume  = optional(object({ size = optional(number, 80), type = optional(string, "gp3") }), {})
    extra_sg_ids = optional(list(string), [])
  })
  default = {}
}

variable "node_groups" {
  description = "map(name => node group spec)"
  type = map(object({
    instance_types = optional(list(string), ["m6i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    disk_size      = optional(number, 50)
    scaling        = optional(object({ desired = number, min = number, max = number }), { desired = 2, min = 1, max = 4 })
    subnet_ids     = optional(list(string)) # null = private subnets
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))
}

variable "namespaces" {
  description = "Namespaces to create, with optional labels"
  type        = map(map(string))
  default     = { kafka = {}, monitoring = {} }
}

variable "install_lb_controller" {
  type    = bool
  default = true
}

variable "default_storage_class" {
  description = "gp3 default StorageClass (needs the EBS CSI add-on from stack 02)"
  type        = bool
  default     = true
}
