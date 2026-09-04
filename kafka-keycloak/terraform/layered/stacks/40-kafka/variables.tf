variable "region" { type = string }
variable "project" { type = string }
variable "environment" { type = string }
variable "cluster_name" {
  type    = string
  default = null
}
variable "namespace" {
  type    = string
  default = "kafka"
}
variable "kafka_cluster_name" {
  type    = string
  default = "my-cluster"
}
variable "kafka_version" {
  type    = string
  default = "3.9.0"
}
variable "controllers" {
  type    = number
  default = 3
}
variable "brokers" {
  type    = number
  default = 3
}
variable "broker_storage_gi" {
  type    = number
  default = 100
}
variable "storage_class" {
  type    = string
  default = "gp3"
}
variable "node_selector" {
  description = "Schedule Kafka pods on a dedicated node group (labels from 20-eks-nodegroups)"
  type        = map(string)
  default     = {}
}
variable "tolerations" {
  type    = list(object({ key = string, value = optional(string), effect = string, operator = optional(string, "Equal") }))
  default = []
}
variable "topics" {
  type = map(object({
    partitions = number
    replicas   = optional(number, 3)
    config     = optional(map(string), {})
  }))
  default = {}
}
