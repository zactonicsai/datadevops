###############################################################################
# Outputs
# Secret VALUES are never exposed - only the ARNs needed to fetch them.
###############################################################################

output "keycloak_url" {
  description = "URL where Keycloak is reachable."
  value       = local.enable_https ? "https://${local.keycloak_hostname}" : "http://${local.keycloak_hostname}"
}

output "alb_dns_name" {
  description = "DNS name of the load balancer - use this as the CNAME/alias target."
  value       = aws_lb.keycloak.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the ALB, for Route53 alias records."
  value       = aws_lb.keycloak.zone_id
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.keycloak.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = values(aws_subnet.public)[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private (application) subnets."
  value       = values(aws_subnet.private)[*].id
}

output "database_subnet_ids" {
  description = "IDs of the isolated database subnets."
  value       = values(aws_subnet.database)[*].id
}

output "security_group_ids" {
  description = "Security group IDs by tier."
  value = {
    alb      = aws_security_group.alb.id
    keycloak = aws_security_group.keycloak.id
    database = aws_security_group.database.id
  }
}

output "autoscaling_group_name" {
  description = "Name of the Keycloak Auto Scaling Group."
  value       = aws_autoscaling_group.keycloak.name
}

output "launch_template_id" {
  description = "ID of the Keycloak launch template."
  value       = aws_launch_template.keycloak.id
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group holding Keycloak container logs."
  value       = aws_cloudwatch_log_group.keycloak.name
}

output "rds_endpoint" {
  description = "RDS connection endpoint (host:port)."
  value       = aws_db_instance.keycloak.endpoint
}

output "rds_identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.keycloak.identifier
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the database credentials."
  value       = aws_secretsmanager_secret.db.arn
}

output "keycloak_admin_secret_arn" {
  description = "Secrets Manager ARN holding the Keycloak bootstrap admin credentials."
  value       = aws_secretsmanager_secret.keycloak_admin.arn
}

output "retrieve_admin_password_command" {
  description = "Command to read the Keycloak admin password."
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.keycloak_admin.name} --query SecretString --output text | jq -r .password"
}

output "alerts_topic_arn" {
  description = "SNS topic receiving CloudWatch alarm notifications."
  value       = try(aws_sns_topic.alerts[0].arn, var.alarm_sns_topic_arn)
}

output "name_prefix" {
  description = "Common name prefix used by the verify, backup and destroy scripts."
  value       = local.name_prefix
}
