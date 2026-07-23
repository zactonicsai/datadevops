output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA used by Kubernetes clients."
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider used by IAM roles for Kubernetes service accounts."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_role_arn" {
  description = "IAM role used by managed EKS worker nodes."
  value       = aws_iam_role.eks_nodes.arn
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.general.node_group_name
}

output "cluster_security_group_id" {
  description = "Primary EKS security group attached to the control plane and managed nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
