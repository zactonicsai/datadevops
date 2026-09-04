output "node_role_arn" { value = module.node_role.role_arn }
output "node_groups" { value = { for k, m in module.node_groups : k => m.arn } }
output "namespaces" { value = keys(kubernetes_namespace_v1.this) }
output "lb_controller_installed" { value = var.install_lb_controller }
output "storage_class" { value = var.default_storage_class ? "gp3" : null }
