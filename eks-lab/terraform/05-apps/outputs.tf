output "namespace"       { value = var.namespace }
output "s3_bucket"       { value = data.terraform_remote_state.cluster.outputs.s3_bucket }
output "kafka_bootstrap" { value = local.kafka_bootstrap }

output "keycloak_password" {
  value     = random_password.keycloak.result
  sensitive = true    # hidden from normal output; read with `terraform output -raw`
}

output "nifi_password" {
  value     = random_password.nifi.result
  sensitive = true
}

output "next_steps" {
  value = <<-EOT
    Port-forward and open each app:
      kubectl -n ${var.namespace} port-forward svc/webapp   8000:80
      kubectl -n ${var.namespace} port-forward svc/nifi     8443:8443
      kubectl -n ${var.namespace} port-forward svc/keycloak 8080:8080

    Get the passwords:
      terraform output -raw nifi_password
      terraform output -raw keycloak_password

    Then build the NiFi flow — see README section "Build the NiFi flow".
  EOT
}
