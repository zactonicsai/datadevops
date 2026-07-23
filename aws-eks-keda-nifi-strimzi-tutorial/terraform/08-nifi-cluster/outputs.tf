output "nifi_service" {
  description = "Internal NiFi URL used by cluster test pods."
  value       = "http://nifi.nifi.svc.cluster.local:8080/nifi/"
}
