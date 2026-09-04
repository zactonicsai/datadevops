variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "create_vpc" {
  description = "false = use the existing_* ids below"
  type        = bool
  default     = true
}
variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
variable "az_count" {
  type    = number
  default = 3
}
variable "single_nat_gateway" {
  type    = bool
  default = true
}
variable "existing_vpc_id" {
  type    = string
  default = null
}
variable "existing_public_subnet_ids" {
  type    = list(string)
  default = []
}
variable "existing_private_subnet_ids" {
  type    = list(string)
  default = []
}
variable "eks_cluster_names" {
  description = "Cluster names that will use these subnets (adds kubernetes.io/cluster/<name>=shared tags)"
  type        = list(string)
  default     = []
}
