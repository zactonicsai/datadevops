output "bootstrap_servers" { value = "${var.cluster_name}-kafka-bootstrap.${var.namespace}.svc.cluster.local:9092" }
output "namespace" { value = var.namespace }
output "cluster_name" { value = var.cluster_name }
output "topics" { value = keys(var.topics) }
