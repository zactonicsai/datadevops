output "keycloak_url" {
  value = "https://${var.keycloak_domain}"
}

output "admin_console_url" {
  value = "https://${var.keycloak_domain}/admin/"
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "admin_username" {
  value = "admin"
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "db_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "instance_id" {
  value = aws_instance.this.id
}

output "target_group_arn" {
  value = aws_lb_target_group.keycloak.arn
}

output "ssm_shell_command" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}
