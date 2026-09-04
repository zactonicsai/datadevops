variable "name" { type = string }
variable "namespace" { type = string }
variable "chart_path" {
  description = "Local chart directory (vendored). No repository URL is ever used."
  type        = string
}
variable "values" {
  description = "List of YAML strings (use yamlencode())"
  type        = list(string)
  default     = []
}
variable "set_sensitive" {
  type      = map(string)
  default   = {}
  sensitive = true
}
variable "timeout" {
  type    = number
  default = 600
}
variable "wait" {
  type    = bool
  default = true
}
