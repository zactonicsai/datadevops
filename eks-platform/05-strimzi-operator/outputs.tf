# =============================================================================
# 05-strimzi-operator/outputs.tf
# =============================================================================

output "kafka_namespace" {
  value       = kubernetes_namespace.kafka.metadata[0].name
  description = "Namespace where the operator runs and where Kafka resources belong."
}

output "strimzi_version" {
  value       = helm_release.strimzi.version
  description = "Strimzi chart version installed."
}

output "strimzi_status" {
  value       = helm_release.strimzi.status
  description = "Helm release status; \"deployed\" means success."
}

output "crds_ready" {
  # Referencing the time_sleep resource means anything consuming this output
  # inherits the wait, which is a tidy way to propagate the dependency.
  value       = time_sleep.wait_for_crds.id != "" ? true : false
  description = "True once the post-install settling period has elapsed."
}

output "verify_commands" {
  value = [
    "kubectl get pods -n ${var.kafka_namespace}",
    "kubectl get crd | grep strimzi",
    "kubectl api-resources --api-group=kafka.strimzi.io",
  ]
  description = "Commands to confirm the operator and its CRDs are installed."
}
