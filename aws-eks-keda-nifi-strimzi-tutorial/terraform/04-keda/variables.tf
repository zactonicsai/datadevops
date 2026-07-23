variable "cluster_name" {
  description = "kubectl and Helm context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig created by update-kubeconfig.sh."
  type        = string
}

variable "chart_version" {
  description = "Pinned Helm chart version."
  type        = string
  default     = "2.20.1"
}

