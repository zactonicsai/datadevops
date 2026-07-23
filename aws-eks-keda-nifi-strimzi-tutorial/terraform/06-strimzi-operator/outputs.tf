output "operator_namespace" {
  value = kubernetes_namespace_v1.strimzi.metadata[0].name
}

output "kafka_namespace" {
  value = kubernetes_namespace_v1.kafka.metadata[0].name
}
