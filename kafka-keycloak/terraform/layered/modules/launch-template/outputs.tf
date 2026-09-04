output "id" { value = var.create ? aws_launch_template.this[0].id : var.existing_id }
output "latest_version" { value = try(aws_launch_template.this[0].latest_version, null) }
