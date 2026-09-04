variable "create" {
  type    = bool
  default = true
}
variable "existing_id" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "vpc_id" { type = string }
variable "description" {
  type    = string
  default = "managed by terraform"
}
variable "ingress" {
  description = "List of ingress rules; use cidr_blocks OR source_security_group_id"
  type = list(object({
    from_port                = number
    to_port                  = number
    protocol                 = optional(string, "tcp")
    cidr_blocks              = optional(list(string), [])
    source_security_group_id = optional(string)
    self                     = optional(bool, false)
    description              = optional(string, "")
  }))
  default = []
}
variable "egress_all" {
  type    = bool
  default = true
}
variable "tags" {
  type    = map(string)
  default = {}
}
