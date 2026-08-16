output "cluster_name"     { value = aws_eks_cluster.this.name }
output "cluster_endpoint" { value = aws_eks_cluster.this.endpoint }
output "cluster_ca"       { value = aws_eks_cluster.this.certificate_authority[0].data }
output "cluster_version"  { value = aws_eks_cluster.this.version }
# The security group EKS creates ITSELF (different from the one you passed in).
# Node groups need it, and forgetting this is a classic confusion.
output "cluster_sg_id"    { value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id }
output "oidc_provider_arn" { value = aws_iam_openid_connect_provider.this.arn }
output "s3_bucket"        { value = aws_s3_bucket.messages.bucket }
output "nifi_role_arn"    { value = aws_iam_role.nifi.arn }
