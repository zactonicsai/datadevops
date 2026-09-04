variable "create" {
  description = "Create the VPC. If false, existing_* inputs are passed through as outputs."
  type        = bool
  default     = true
}
variable "name" { type = string }
variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "az_count" {
  type    = number
  default = 3
}
variable "single_nat_gateway" {
  type    = bool
  default = true
}
variable "public_subnet_tags" {
  type    = map(string)
  default = {}
}
variable "private_subnet_tags" {
  type    = map(string)
  default = {}
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
variable "tags" {
  type    = map(string)
  default = {}
}
