variable "cluster_name" {
  description = "kubectl context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the project kubeconfig."
  type        = string
}

variable "toolbox_image" {
  description = "Network troubleshooting image used by the test pod."
  type        = string
  default     = "nicolaka/netshoot:v0.13"
}
