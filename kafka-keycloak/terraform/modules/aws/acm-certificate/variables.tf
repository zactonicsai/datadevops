variable "create" {
  type    = bool
  default = true
}
variable "existing_arn" {
  type    = string
  default = null
}
variable "domain_name" {
  type    = string
  default = null
}
variable "subject_alternative_names" {
  type    = list(string)
  default = []
}
variable "zone_id" {
  description = "Route 53 zone for DNS validation"
  type        = string
  default     = null
}
variable "tags" {
  type    = map(string)
  default = {}
}
