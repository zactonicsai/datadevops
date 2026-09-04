variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "cluster_name" { type = string }
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
variable "create_cluster" {
  description = "false = adopt an existing cluster named cluster_name"
  type        = bool
  default     = true
}
variable "subnet_ids" {
  description = "Subnets for the control plane; null = private+public from the 00-network state"
  type        = list(string)
  default     = null
}
variable "existing_cluster_role_arn" {
  description = "Provide to reuse an existing control-plane IAM role"
  type        = string
  default     = null
}
variable "endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
