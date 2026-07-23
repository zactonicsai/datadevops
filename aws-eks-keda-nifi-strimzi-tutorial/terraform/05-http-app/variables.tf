variable "cluster_name" {
  description = "kubectl context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the project kubeconfig."
  type        = string
}

variable "http_image" {
  description = "Pinned NGINX image used by both micro web servers."
  type        = string
  default     = "nginx:1.29-alpine"
}
