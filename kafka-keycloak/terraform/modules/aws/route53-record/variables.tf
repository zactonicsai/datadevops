variable "zone_id" { type = string }
variable "name" { type = string }
variable "type" {
  type    = string
  default = "A"
}
variable "alias" {
  description = "Alias target (e.g. ALB dns_name + zone_id). Null = plain record using `records`."
  type = object({
    name    = string
    zone_id = string
  })
  default = null
}
variable "records" {
  type    = list(string)
  default = []
}
variable "ttl" {
  type    = number
  default = 60
}
