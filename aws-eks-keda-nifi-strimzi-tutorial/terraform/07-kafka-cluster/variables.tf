variable "cluster_name" {
  description = "kubectl context name."
  type        = string
}

variable "kubeconfig_path" {
  description = "Path to the project kubeconfig."
  type        = string
}

variable "kafka_version" {
  description = "Apache Kafka version supported by the pinned Strimzi operator."
  type        = string
  default     = "4.3.0"
}

variable "kafka_storage_size" {
  description = "gp3 EBS disk requested by each Kafka pod."
  type        = string
  default     = "10Gi"
}

variable "retain_application_volumes" {
  description = "Keep Kafka PVC-backed EBS volumes when the Kafka resource is deleted."
  type        = bool
  default     = true
}
