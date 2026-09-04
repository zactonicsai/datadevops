output "kafka_ui_url" { value = local.url }
output "issuer_uri_in_use" { value = local.keycloak.issuer_uri }
output "lb_dns_name" { value = module.lb.dns_name }
output "target_group_arn" { value = module.tg.arn }
