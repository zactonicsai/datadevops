output "fqdn" { value = var.alias != null ? aws_route53_record.alias[0].fqdn : aws_route53_record.cname[0].fqdn }
