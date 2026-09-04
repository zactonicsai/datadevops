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
  description = "AMI id; null = resolve from ami_ssm_parameter"
  type        = string
  default     = null
}
variable "ami_ssm_parameter" {
  description = "SSM public parameter for the AMI (default: Amazon Linux 2023 x86_64). Ignored for EKS node groups (leave ami_id null and set for_eks=true)."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
variable "for_eks" {
  description = "When true, omit the AMI/instance type so the EKS managed node group supplies them"
  type        = bool
  default     = false
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
variable "root_volume_size" {
  type    = number
  default = 30
}
variable "root_volume_type" {
  type    = string
  default = "gp3"
}
variable "root_device_name" {
  type    = string
  default = "/dev/xvda"
}
variable "metadata_http_tokens" {
  type    = string
  default = "required"
}
variable "tags" {
  type    = map(string)
  default = {}
}
