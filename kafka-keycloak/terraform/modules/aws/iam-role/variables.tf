variable "create" {
  type    = bool
  default = true
}
variable "existing_role_name" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "trusted_services" {
  description = "AWS service principals allowed to assume (e.g. [\"ec2.amazonaws.com\"], [\"eks.amazonaws.com\"])"
  type        = list(string)
  default     = []
}
variable "trusted_role_arns" {
  type    = list(string)
  default = []
}
variable "oidc" {
  description = "IRSA trust: provider ARN + issuer host + allowed service accounts (namespace:name)"
  type = object({
    provider_arn     = string
    issuer_host      = string
    service_accounts = list(string)
  })
  default = null
}
variable "managed_policy_arns" {
  type    = list(string)
  default = []
}
variable "inline_policies" {
  description = "map(name => policy JSON)"
  type        = map(string)
  default     = {}
}
variable "policy_files" {
  description = "map(name => path to JSON file) — becomes customer-managed policies"
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
