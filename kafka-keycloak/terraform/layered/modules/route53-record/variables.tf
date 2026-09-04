variable "zone_id" { type = string }
variable "name" { type = string }
variable "alias" {
  description = "Alias to an ALB: {dns_name, zone_id}. If null, a CNAME to var.cname is created."
  type        = object({ dns_name = string, zone_id = string })
  default     = null
}
variable "cname" {
  type    = string
  default = null
}
variable "ttl" {
  type    = number
  default = 60
}
