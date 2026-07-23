# =============================================================================
# 08-toolbox/outputs.tf
# =============================================================================

output "toolbox_namespace" {
  value       = kubernetes_namespace.toolbox.metadata[0].name
  description = "Namespace the toolbox runs in."
}

output "exec_command" {
  # The single most useful output in this whole project: how to get a shell
  # inside the cluster.
  value       = "kubectl exec -it -n ${var.toolbox_namespace} deploy/toolbox -- /bin/bash"
  description = "Open an interactive shell in the toolbox pod."
}

output "run_tests_command" {
  value       = "./tests/run-tests.sh"
  description = "Run the full connectivity test suite from your laptop; it execs into the toolbox for you."
}

output "known_targets" {
  # Everything the toolbox is pre-configured to reach.
  value = {
    webapp = "http://${local.webapp_dns}"
    kafka  = local.kafka_bootstrap
    nifi   = "https://${local.nifi_dns}"
    topic  = local.kafka_topic
  }
  description = "Addresses the toolbox knows about, resolved from earlier layers."
}

output "quick_checks" {
  value = {
    web_page  = "kubectl exec -n ${var.toolbox_namespace} deploy/toolbox -- curl -s ${local.webapp_dns}"
    dns_kafka = "kubectl exec -n ${var.toolbox_namespace} deploy/toolbox -- dig +short ${split(":", local.kafka_bootstrap)[0]}"
    tcp_kafka = "kubectl exec -n ${var.toolbox_namespace} deploy/toolbox -- nc -zv ${split(":", local.kafka_bootstrap)[0]} 9092"
    list_pods = "kubectl exec -n ${var.toolbox_namespace} deploy/toolbox -- kubectl get pods -A"
  }
  description = "One-liner checks you can run without opening a shell."
}
