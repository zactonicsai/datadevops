output "id" { value = var.create ? aws_launch_template.this[0].id : var.existing_id }
output "latest_version" { value = var.create ? aws_launch_template.this[0].latest_version : data.aws_launch_template.existing[0].latest_version }
output "ami_id" { value = local.ami_id }
