output "cluster_name" { value = local.cluster_name }
output "node_role_arn" { value = module.node_role.arn }
output "launch_template_id" { value = module.node_lt.id }
output "node_groups" { value = { for k, m in module.node_group : k => m.arn } }
output "namespaces" { value = keys(module.namespace) }
output "lb_controller_installed" { value = var.install_lb_controller }
