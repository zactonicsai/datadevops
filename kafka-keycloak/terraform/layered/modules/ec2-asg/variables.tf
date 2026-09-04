variable "name" { type = string }
variable "launch_template_id" { type = string }
variable "launch_template_version" {
  type    = string
  default = "$Latest"
}
variable "subnet_ids" { type = list(string) }
variable "min_size" {
  type    = number
  default = 1
}
variable "max_size" {
  type    = number
  default = 2
}
variable "desired_capacity" {
  type    = number
  default = 1
}
variable "target_group_arns" {
  type    = list(string)
  default = []
}
variable "health_check_type" {
  description = "EC2 or ELB"
  type        = string
  default     = "ELB"
}
variable "health_check_grace_period" {
  type    = number
  default = 300
}
variable "tags" {
  type    = map(string)
  default = {}
}
