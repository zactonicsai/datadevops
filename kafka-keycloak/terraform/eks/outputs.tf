output "kafka_ui_url" { value = local.kafka_ui_url }
output "keycloak_url" { value = local.keycloak_url }
output "issuer_uri" { value = local.issuer_uri }
output "kafka_bootstrap_in_cluster" { value = "my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092" }
output "kubeconfig_commands" {
  value = {
    platform = "aws eks update-kubeconfig --region ${var.region} --name ${module.platform.name}"
    data     = "aws eks update-kubeconfig --region ${var.region} --name ${module.data.name}"
  }
}
output "keycloak_db_endpoint" { value = aws_db_instance.keycloak.address }
