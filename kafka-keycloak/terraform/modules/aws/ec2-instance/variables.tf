variable "name" { type = string }
variable "instance_count" {
  type    = number
  default = 1
}
variable "launch_template" {
  type = object({
    id      = string
    version = string
  })
}
variable "subnet_ids" {
  description = "Instances are spread round-robin over these"
  type        = list(string)
}
variable "target_group_arns" {
  description = "Register every instance with these target groups"
  type        = list(string)
  default     = []
}
variable "target_port" {
  type    = number
  default = 80
}
variable "tags" {
  type    = map(string)
  default = {}
}
