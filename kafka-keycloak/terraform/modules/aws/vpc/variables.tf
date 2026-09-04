variable "create" {
  description = "Create the VPC and subnets. If false, existing IDs below are returned as outputs."
  type        = bool
  default     = true
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
variable "name" { type = string }
variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "azs" {
  description = "AZs to use; null = first 3 available"
  type        = list(string)
  default     = null
}
variable "az_count" {
  type    = number
  default = 3
}
variable "public_subnet_cidrs" {
  description = "Override; default = cidrsubnet(cidr,4,i)"
  type        = list(string)
  default     = null
}
variable "private_subnet_cidrs" {
  description = "Override; default = cidrsubnet(cidr,4,i+8)"
  type        = list(string)
  default     = null
}
variable "enable_nat_gateway" {
  type    = bool
  default = true
}
variable "single_nat_gateway" {
  type    = bool
  default = true
}
variable "public_subnet_tags" {
  description = "e.g. { \"kubernetes.io/role/elb\" = \"1\" }"
  type        = map(string)
  default     = {}
}
variable "private_subnet_tags" {
  description = "e.g. { \"kubernetes.io/role/internal-elb\" = \"1\" }"
  type        = map(string)
  default     = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}
