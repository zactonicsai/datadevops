variable "create" {
  type    = bool
  default = true
}
variable "existing_role_arn" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "trusted_services" {
  description = "AWS service principals allowed to assume the role (e.g. ec2.amazonaws.com, eks.amazonaws.com)"
  type        = list(string)
  default     = []
}
variable "oidc_provider_arn" {
  description = "For IRSA: the EKS OIDC provider ARN"
  type        = string
  default     = null
}
variable "oidc_subjects" {
  description = "For IRSA: allowed 'system:serviceaccount:<ns>:<sa>' values"
  type        = list(string)
  default     = []
}
variable "managed_policy_arns" {
  type    = list(string)
  default = []
}
variable "inline_policy_files" {
  description = "Map of policy name -> path to a JSON policy document"
  type        = map(string)
  default     = {}
}
variable "inline_policies" {
  description = "Map of policy name -> JSON policy document string"
  type        = map(string)
  default     = {}
}
variable "create_instance_profile" {
  type    = bool
  default = false
}
variable "tags" {
  type    = map(string)
  default = {}
}
