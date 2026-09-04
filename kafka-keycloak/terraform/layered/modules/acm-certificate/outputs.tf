output "arn" { value = var.create ? aws_acm_certificate_validation.this[0].certificate_arn : var.existing_arn }
