variable "prefix" {
  description = "Parameter path prefix, e.g. /kafka-keycloak/keycloak"
  type        = string
}
variable "secrets" {
  description = "name -> value; stored as SecureString under <prefix>/<name>"
  type        = map(string)
  sensitive   = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
