output "name" { value = aws_eks_cluster.this.name }
output "endpoint" { value = aws_eks_cluster.this.endpoint }
output "ca_certificate" { value = aws_eks_cluster.this.certificate_authority[0].data }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.this.arn }
output "lbc_role_arn" { value = aws_iam_role.lbc.arn }
output "node_group_id" { value = aws_eks_node_group.default.id }
output "node_security_group_id" { value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id }
