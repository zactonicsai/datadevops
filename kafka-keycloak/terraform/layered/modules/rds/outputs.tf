output "endpoint" { value = var.create ? aws_db_instance.this[0].address : var.existing_endpoint }
output "port" { value = 5432 }
output "db_name" { value = var.db_name }
output "username" { value = var.username }
