output "arn" { value = var.create ? aws_iam_role.this[0].arn : var.existing_role_arn }
output "name" { value = var.create ? aws_iam_role.this[0].name : element(split("/", var.existing_role_arn), 1) }
output "instance_profile_name" { value = try(aws_iam_instance_profile.this[0].name, null) }
output "instance_profile_arn" { value = try(aws_iam_instance_profile.this[0].arn, null) }
