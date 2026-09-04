output "arn" { value = var.create ? aws_lb_target_group.this[0].arn : var.existing_arn }
output "name" { value = try(aws_lb_target_group.this[0].name, null) }
