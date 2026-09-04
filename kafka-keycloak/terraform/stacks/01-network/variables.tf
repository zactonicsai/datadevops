variable "vpc" {
  description = "Create a VPC or point at an existing one"
  type = object({
    create                      = optional(bool, true)
    existing_vpc_id             = optional(string)
    existing_public_subnet_ids  = optional(list(string), [])
    existing_private_subnet_ids = optional(list(string), [])
    name                        = optional(string, "main")
    cidr                        = optional(string, "10.42.0.0/16")
    az_count                    = optional(number, 3)
    single_nat_gateway          = optional(bool, true)
  })
  default = {}
}
variable "eks_cluster_names" {
  description = "Cluster names that will use these subnets (adds kubernetes.io/cluster/<name>=shared tags)"
  type        = list(string)
  default     = []
}
