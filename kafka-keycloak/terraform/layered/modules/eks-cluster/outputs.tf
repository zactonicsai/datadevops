output "name" { value = local.name }
output "endpoint" { value = local.endpoint }
output "ca_certificate" { value = local.ca }
output "oidc_issuer" { value = local.oidc_issuer }
output "oidc_provider_arn" { value = var.create ? aws_iam_openid_connect_provider.this[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn }
output "cluster_security_group_id" { value = local.cluster_sg }
output "version" { value = var.create ? aws_eks_cluster.this[0].version : data.aws_eks_cluster.existing[0].version }
