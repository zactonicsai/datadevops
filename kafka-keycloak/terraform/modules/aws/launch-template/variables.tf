variable "create" {
  type    = bool
  default = true
}
variable "existing_id" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "ami_id" {
  description = "Explicit AMI; null = resolve ami_ssm_parameter"
  type        = string
  default     = null
}
variable "ami_ssm_parameter" {
  description = "SSM public parameter for the AMI (default Amazon Linux 2023 x86_64). Ignored when ami_id set or for EKS node groups (leave both null)."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
variable "instance_type" {
  type    = string
  default = null
}
variable "key_name" {
  type    = string
  default = null
}
variable "security_group_ids" {
  type    = list(string)
  default = []
}
variable "iam_instance_profile_name" {
  type    = string
  default = null
}
variable "user_data" {
  description = "Plain-text user data (base64 encoded by the module)"
  type        = string
  default     = null
}
variable "root_volume" {
  type = object({
    size       = optional(number, 30)
    type       = optional(string, "gp3")
    encrypted  = optional(bool, true)
    device     = optional(string, "/dev/xvda")
    iops       = optional(number)
    throughput = optional(number)
  })
  default = {}
}
variable "require_imdsv2" {
  type    = bool
  default = true
}
variable "monitoring" {
  type    = bool
  default = false
}
variable "instance_tags" {
  type    = map(string)
  default = {}
}
variable "tags" {
  type    = map(string)
  default = {}
}
