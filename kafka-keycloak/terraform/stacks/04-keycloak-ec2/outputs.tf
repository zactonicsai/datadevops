output "keycloak_url" { value = local.url }
output "issuer_uri" { value = local.issuer_uri }
output "realm" { value = var.keycloak.realm_name }
output "lb_dns_name" { value = module.lb.dns_name }
output "lb_security_group_id" { value = module.sg_lb.id }
output "instance_ids" { value = module.instances.ids }
output "db_address" { value = module.db.address }
