variable "name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}
variable "resource_quota" {
  description = "Optional quota, e.g. { \"requests.cpu\" = \"8\", \"requests.memory\" = \"32Gi\" }"
  type        = map(string)
  default     = {}
}
