output "bootstrap_servers" { value = "${var.kafka_cluster_name}-kafka-bootstrap.${var.namespace}.svc.cluster.local:9092" }
output "bootstrap_servers_tls" { value = "${var.kafka_cluster_name}-kafka-bootstrap.${var.namespace}.svc.cluster.local:9093" }
output "namespace" { value = var.namespace }
output "topics" { value = keys(var.topics) }
