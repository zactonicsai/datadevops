# =============================================================================
# 06-kafka-cluster/variables.tf
# =============================================================================

variable "kafka_cluster_name" {
  type        = string
  description = "Name of the Kafka cluster. Becomes part of every pod and service name."
  default     = "demo-kafka"
}

variable "kafka_version" {
  type        = string
  description = "Apache Kafka version. Must be one Strimzi 1.0.0 supports (4.1.0, 4.1.1, 4.1.2, 4.2.0)."
  default     = "4.2.0"
}

variable "controller_replicas" {
  type        = number
  description = "KRaft controller count. MUST be odd for quorum; 3 is the standard."
  default     = 3

  validation {
    # An even number of controllers gives no more fault tolerance than the odd
    # number below it, while costing more. Refusing even values here saves
    # someone from an expensive misunderstanding.
    condition     = var.controller_replicas % 2 == 1
    error_message = "controller_replicas must be ODD (1, 3, 5). An even count buys cost without buying fault tolerance -- a majority of 2 is still 2."
  }
}

variable "broker_replicas" {
  type        = number
  description = "Kafka broker count. 2 as requested; 3 is the production standard."
  default     = 2

  validation {
    condition     = var.broker_replicas >= 1
    error_message = "broker_replicas must be at least 1."
  }
}

variable "test_topic_name" {
  type        = string
  description = "Topic created for the verification script to produce to and consume from."
  default     = "demo-topic"
}

variable "delete_pvcs_on_destroy" {
  type        = bool
  description = "If true, Kafka's EBS volumes are deleted with the cluster. false is safer for real data but leaves volumes billing after destroy."
  default     = true # true for a demo, so teardown is complete. Use false for anything real.
}
