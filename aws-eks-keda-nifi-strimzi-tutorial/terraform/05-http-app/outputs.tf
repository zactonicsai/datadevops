output "service_dns_name" {
  description = "Internal DNS name used by pods to reach both hello servers."
  value       = "hello-web.web.svc.cluster.local"
}
