output "kafka_ui_url" { value = local.url }
output "alb_dns_name" { value = module.alb.dns_name }
output "target_group_arn" { value = module.tg.arn }
output "issuer_uri_used" { value = local.issuer_uri }
output "bootstrap_used" { value = local.bootstrap }
