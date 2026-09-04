variable "create" {
  type    = bool
  default = true
}
variable "existing_cluster_name" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "kubernetes_version" {
  type    = string
  default = "1.31"
}
variable "subnet_ids" { type = list(string) }
variable "cluster_role_arn" {
  description = "IAM role for the control plane (from iam-role module)"
  type        = string
}
variable "endpoint_public_access" {
  type    = bool
  default = true
}
variable "endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "additional_security_group_ids" {
  type    = list(string)
  default = []
}
variable "enabled_log_types" {
  type    = list(string)
  default = ["api", "audit", "authenticator"]
}
variable "tags" {
  type    = map(string)
  default = {}
}
