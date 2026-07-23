output "bootstrap_server" {
  description = "Internal plaintext Kafka bootstrap address."
  value       = "tutorial-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
}

output "topic_name" {
  value = "tutorial-topic"
}
