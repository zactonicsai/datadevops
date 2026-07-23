# =============================================================================
# 05-strimzi-operator/variables.tf
# =============================================================================

variable "kafka_namespace" {
  type        = string
  description = "Namespace for the Strimzi operator and the Kafka cluster it manages."
  default     = "kafka"
}

variable "strimzi_version" {
  type        = string
  description = "Strimzi Helm chart version. 1.0.0 supports Kafka 4.x and the v1 CRD API only."
  default     = "1.0.0"
}
