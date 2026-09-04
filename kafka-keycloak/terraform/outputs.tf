output "kafka_ui_url" {
  value = local.kafka_ui_url
}

output "keycloak_url" {
  value = "${local.keycloak_url}  (admin / ${nonsensitive(var.keycloak_admin_password)})"
}

output "kafka_bootstrap" {
  value       = "localhost:${var.kafka_host_port}"
  description = "Use with: python client/producer.py -b localhost:${var.kafka_host_port}"
}

output "kubeconfig" {
  value = "export KUBECONFIG=${abspath(kind_cluster.this.kubeconfig_path)}"
}

output "test_users" {
  value = "alice / alice123 (admin), bob / bob123 (viewer)"
}
