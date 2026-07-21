###############################################################################
# outputs.tf — values printed after apply, and readable later with
#              `terraform output <name>`
###############################################################################

output "instance_id" {
  description = "EC2 instance ID. Use it to open a shell: aws ssm start-session --target <id>"
  value       = aws_instance.keycloak.id
}

output "instance_private_ip" {
  description = "Private IP of the Keycloak server."
  value       = aws_instance.keycloak.private_ip
}

output "db_endpoint" {
  description = "RDS connection endpoint (hostname:port)."
  value       = aws_db_instance.keycloak.endpoint
}

output "db_address" {
  description = "RDS hostname without the port."
  value       = aws_db_instance.keycloak.address
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB credentials."
  value       = aws_secretsmanager_secret.keycloak_db.arn
}

output "db_secret_read_command" {
  description = "Copy-paste command to read the DB credentials."
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.keycloak_db.arn} --region ${var.aws_region} --query SecretString --output text | jq"
}

output "keycloak_url" {
  description = "Public URL where Keycloak will be reachable through your load balancer."
  value       = "https://${var.keycloak_hostname}"
}

output "session_manager_command" {
  description = "Open a shell on the instance without SSH or a bastion host."
  value       = "aws ssm start-session --target ${aws_instance.keycloak.id} --region ${var.aws_region}"
}
