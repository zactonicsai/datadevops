output "address" { value = var.create ? aws_db_instance.this[0].address : var.existing.address }
output "port" { value = var.create ? aws_db_instance.this[0].port : var.existing.port }
output "db_name" { value = var.create ? aws_db_instance.this[0].db_name : var.existing.db_name }
output "username" { value = var.create ? aws_db_instance.this[0].username : var.existing.username }
