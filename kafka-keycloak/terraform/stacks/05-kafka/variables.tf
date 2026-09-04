variable "namespace" {
  type    = string
  default = "kafka"
}
variable "cluster_name" {
  description = "Strimzi Kafka CR name"
  type        = string
  default     = "my-cluster"
}
variable "kafka_version" {
  type    = string
  default = "3.9.0"
}
variable "controllers" {
  type = object({
    replicas     = optional(number, 3)
    storage_size = optional(string, "20Gi")
  })
  default = {}
}
variable "brokers" {
  type = object({
    replicas      = optional(number, 3)
    storage_size  = optional(string, "100Gi")
    cpu_request   = optional(string, "1")
    memory        = optional(string, "4Gi")
    node_selector = optional(map(string), {})
    tolerations = optional(list(object({
      key      = string
      operator = optional(string, "Equal")
      value    = optional(string)
      effect   = string
    })), [])
  })
  default = {}
}
variable "storage_class" {
  type    = string
  default = "gp3"
}
variable "topics" {
  type = map(object({
    partitions = number
    replicas   = optional(number, 3)
    config     = optional(map(string), {})
  }))
  default = {}
}
