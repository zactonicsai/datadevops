variable "create" {
  type    = bool
  default = true
}
variable "existing_arn" {
  type    = string
  default = null
}
variable "domain_name" { type = string }
variable "subject_alternative_names" {
  type    = list(string)
  default = []
}
variable "route53_zone_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
