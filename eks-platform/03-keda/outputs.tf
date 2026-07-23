# =============================================================================
# 03-keda/outputs.tf
# =============================================================================

output "keda_namespace" {
  value       = kubernetes_namespace.keda.metadata[0].name
  description = "Namespace where the KEDA operator runs."
}

output "keda_version" {
  value       = helm_release.keda.version
  description = "KEDA chart version installed."
}

output "keda_status" {
  value       = helm_release.keda.status
  description = "Helm release status; \"deployed\" means success."
}

output "verify_commands" {
  # A list output is a handy way to hand the reader a checklist.
  value = [
    "kubectl get pods -n keda",
    "kubectl get crd | grep keda.sh",
    "kubectl api-resources --api-group=keda.sh",
  ]
  description = "Commands to confirm KEDA installed correctly."
}
