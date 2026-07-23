output "toolbox_command" {
  description = "Command that opens a shell inside the cluster test pod."
  value       = "kubectl exec -it -n test-tools deployment/toolbox -- bash"
}
