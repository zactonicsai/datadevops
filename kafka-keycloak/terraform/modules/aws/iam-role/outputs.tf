output "role_name" { value = local.role_name }
output "role_arn" { value = local.role_arn }
output "instance_profile_name" { value = var.create && var.create_instance_profile ? aws_iam_instance_profile.this[0].name : null }
output "instance_profile_arn" { value = var.create && var.create_instance_profile ? aws_iam_instance_profile.this[0].arn : null }
