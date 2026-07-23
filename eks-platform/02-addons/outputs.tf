# =============================================================================
# 02-addons/outputs.tf
# =============================================================================

output "metrics_server_status" {
  value       = helm_release.metrics_server.status
  description = "Helm release status. \"deployed\" means the install succeeded."
}

output "metrics_server_version" {
  value       = helm_release.metrics_server.version
  description = "Chart version installed."
}

output "verify_command" {
  value       = "kubectl top nodes"
  description = "Run this to confirm metrics-server works. It may take ~60 seconds after install before numbers appear."
}
