variable "cluster_name" {
  description = "kubectl and Helm context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the project kubeconfig."
  type        = string
}

variable "chart_version" {
  description = "Pinned Strimzi operator chart version."
  type        = string
  default     = "1.1.0"
}
