output "cluster_name" { value = module.eks.name }
output "endpoint" { value = module.eks.endpoint }
output "ca_certificate" { value = module.eks.ca_certificate }
output "cluster_security_group_id" { value = module.eks.cluster_security_group_id }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "oidc_issuer_host" { value = module.eks.oidc_issuer_host }
output "kubernetes_version" { value = module.eks.version }
output "kubeconfig_command" { value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.name}" }
