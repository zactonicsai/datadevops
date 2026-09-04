output "arn" { value = var.create ? aws_lb.this[0].arn : var.existing_arn }
output "dns_name" { value = var.create ? aws_lb.this[0].dns_name : var.existing_dns_name }
output "zone_id" { value = var.create ? aws_lb.this[0].zone_id : var.existing_zone_id }
output "listener_arn" { value = local.main_listener_arn }
