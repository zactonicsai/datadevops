variable "create" {
  type    = bool
  default = true
}
variable "existing_id" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "description" {
  type    = string
  default = "Managed by Terraform"
}
variable "vpc_id" {
  type    = string
  default = null
}
variable "ingress_rules" {
  description = "Each rule: ports + ONE of cidr_blocks / source_security_group_id / self"
  type = list(object({
    from_port                = number
    to_port                  = number
    protocol                 = optional(string, "tcp")
    cidr_blocks              = optional(list(string))
    source_security_group_id = optional(string)
    self                     = optional(bool)
    description              = optional(string, "")
  }))
  default = []
}
variable "egress_rules" {
  type = list(object({
    from_port                = number
    to_port                  = number
    protocol                 = optional(string, "-1")
    cidr_blocks              = optional(list(string))
    source_security_group_id = optional(string)
    self                     = optional(bool)
    description              = optional(string, "")
  }))
  default = [{ from_port = 0, to_port = 0, protocol = "-1", cidr_blocks = ["0.0.0.0/0"], description = "all out" }]
}
variable "tags" {
  type    = map(string)
  default = {}
}
