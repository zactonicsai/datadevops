# =============================================================================
# 07-nifi/outputs.tf
# =============================================================================

output "nifi_namespace" {
  value       = kubernetes_namespace.nifi.metadata[0].name
  description = "Namespace NiFi runs in."
}

output "nifi_service_dns" {
  value       = "${kubernetes_service.nifi_ui.metadata[0].name}.${kubernetes_namespace.nifi.metadata[0].name}.svc.cluster.local:8443"
  description = "In-cluster address of the NiFi UI service."
}

output "nifi_pod_dns_names" {
  # StatefulSet pods get predictable names, so we can compute their per-pod DNS
  # addresses without querying the cluster. This is exactly the property that
  # distinguishes a StatefulSet from a Deployment.
  value = [
    for i in range(var.nifi_replicas) :
    "nifi-${i}.${kubernetes_service.nifi_headless.metadata[0].name}.${kubernetes_namespace.nifi.metadata[0].name}.svc.cluster.local:8443"
  ]
  description = "Stable per-pod DNS names, for addressing one specific NiFi instance."
}

output "nifi_username" {
  value       = var.nifi_username
  description = "NiFi login name."
}

output "nifi_password" {
  value       = random_password.nifi_admin.result
  description = "Generated NiFi password. Retrieve with: terraform output -raw nifi_password"

  # Hides it from ordinary CLI output. NOTE this only affects DISPLAY -- the
  # value is still plain text inside terraform.tfstate. See main.tf.
  sensitive = true
}

output "kafka_bootstrap_for_nifi" {
  value       = local.kafka_bootstrap
  description = "Paste this into a PublishKafka or ConsumeKafka processor in the NiFi canvas."
}

output "useful_commands" {
  value = {
    watch_pods = "kubectl get pods -n ${var.nifi_namespace} -w"

    # NiFi uses a self-signed cert, so your browser will warn. That is expected.
    port_forward = "kubectl port-forward -n ${var.nifi_namespace} svc/nifi 8443:8443"
    open_ui      = "https://localhost:8443/nifi  (accept the self-signed certificate warning)"

    get_password = "terraform output -raw nifi_password"

    logs = "kubectl logs -n ${var.nifi_namespace} nifi-0 --tail=100"

    # Confirms each pod got its own volume.
    check_volumes = "kubectl get pvc -n ${var.nifi_namespace}"
  }
  description = "Commands for reaching and inspecting NiFi."
}
