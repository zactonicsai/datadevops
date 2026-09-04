output "name" { value = local.cluster_name }
output "endpoint" { value = local.endpoint }
output "ca_certificate" { value = local.ca }
output "cluster_security_group_id" { value = local.cluster_sg }
output "oidc_issuer" { value = local.oidc_issuer }
output "oidc_issuer_host" { value = local.oidc_host }
output "oidc_provider_arn" { value = var.enable_irsa ? aws_iam_openid_connect_provider.this[0].arn : null }
output "version" { value = var.create ? aws_eks_cluster.this[0].version : data.aws_eks_cluster.existing[0].version }
