output "arn" { value = var.create ? aws_lb.this[0].arn : var.existing_arn }
output "dns_name" { value = var.create ? aws_lb.this[0].dns_name : data.aws_lb.existing[0].dns_name }
output "zone_id" { value = var.create ? aws_lb.this[0].zone_id : data.aws_lb.existing[0].zone_id }
output "listener_arn" { value = local.listener_arn }
output "security_group_ids" { value = var.create ? var.security_group_ids : data.aws_lb.existing[0].security_groups }
