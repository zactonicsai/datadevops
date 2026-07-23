# =============================================================================
# 04-webapp/outputs.tf
# =============================================================================

output "namespace" {
  value       = kubernetes_namespace.webapp.metadata[0].name
  description = "Namespace the web app runs in."
}

output "internal_service_name" {
  value       = kubernetes_service.hello_web_internal.metadata[0].name
  description = "ClusterIP service name."
}

output "internal_dns_name" {
  # ---- KUBERNETES DNS NAMING, WORTH MEMORISING ----
  # Every Service gets a DNS record in this shape:
  #     <service>.<namespace>.svc.cluster.local
  #
  # From inside the SAME namespace you can just use "hello-web".
  # From a DIFFERENT namespace you need at least "hello-web.hello-web".
  # The fully qualified form always works and is what scripts should use.
  value       = "${kubernetes_service.hello_web_internal.metadata[0].name}.${kubernetes_namespace.webapp.metadata[0].name}.svc.cluster.local"
  description = "Fully qualified in-cluster DNS name for the web service."
}

output "load_balancer_hostname" {
  # Digging the hostname out of the service status is fiddly because of the
  # conditional count and the nested status structure, so we build it in steps.
  #
  # try(expr, fallback) returns fallback if expr errors. It is the clean way to
  # handle "this may not exist" without a pile of length() checks.
  value = try(
    kubernetes_service.hello_web_public[0].status[0].load_balancer[0].ingress[0].hostname,
    "not created (create_public_loadbalancer = false)"
  )
  description = "Public DNS name of the Network Load Balancer."
}

output "web_url" {
  value = try(
    "http://${kubernetes_service.hello_web_public[0].status[0].load_balancer[0].ingress[0].hostname}",
    "no public load balancer; test from inside the cluster instead"
  )
  description = "Open this in a browser. DNS can take 2-3 minutes to resolve after creation."
}

output "scaledobject_name" {
  value       = var.enable_autoscaling ? "hello-web-scaler" : "autoscaling disabled"
  description = "Name of the KEDA ScaledObject."
}

output "useful_commands" {
  value = {
    watch_pods   = "kubectl get pods -n ${var.app_namespace} -w"
    check_hpa    = "kubectl get hpa -n ${var.app_namespace}"
    check_scaler = "kubectl get scaledobject -n ${var.app_namespace}"
    check_endpoints = "kubectl get endpoints -n ${var.app_namespace}"
    port_forward = "kubectl port-forward -n ${var.app_namespace} svc/hello-web 8080:80"
    logs         = "kubectl logs -n ${var.app_namespace} -l app.kubernetes.io/name=hello-web --tail=50"
  }
  description = "Handy commands for inspecting and testing this layer."
}
