variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "kafka-ui-eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "kafka_cluster_name" {
  description = "Display name for the Kafka cluster in Kafka UI"
  type        = string
  default     = "my-kafka"
}

variable "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers, e.g. b-1.msk.amazonaws.com:9092,b-2...:9092"
  type        = string
  default     = ""
}
