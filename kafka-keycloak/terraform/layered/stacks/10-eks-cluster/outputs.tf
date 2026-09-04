output "cluster_name" { value = module.cluster.name }
output "endpoint" { value = module.cluster.endpoint }
output "ca_certificate" { value = module.cluster.ca_certificate }
output "oidc_provider_arn" { value = module.cluster.oidc_provider_arn }
output "cluster_security_group_id" { value = module.cluster.cluster_security_group_id }
output "kubeconfig_command" { value = "aws eks update-kubeconfig --region ${var.region} --name ${module.cluster.name}" }
