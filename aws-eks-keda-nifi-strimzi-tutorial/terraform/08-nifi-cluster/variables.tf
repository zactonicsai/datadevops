variable "cluster_name" {
  description = "kubectl context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the project kubeconfig."
  type        = string
}

variable "nifi_image" {
  description = "Pinned official Apache NiFi image."
  type        = string
  default     = "apache/nifi:2.10.0"
}

variable "nifi_storage_size" {
  description = "gp3 EBS disk requested by each NiFi pod."
  type        = string
  default     = "20Gi"
}

variable "retain_application_volumes" {
  description = "Keep NiFi EBS volumes after deleting the StatefulSet."
  type        = bool
  default     = true
}
