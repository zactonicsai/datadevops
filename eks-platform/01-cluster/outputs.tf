# =============================================================================
# 01-cluster/outputs.tf
# =============================================================================
# Everything published here is consumed by layers 02 through 08, which all
# need to authenticate to this cluster.
# =============================================================================

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Name of the EKS cluster. Used in `aws eks update-kubeconfig`."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "HTTPS URL of the Kubernetes API server."
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64-encoded CA certificate. Clients use it to verify the API server is genuine."

  # sensitive = true hides the value in CLI output and logs.
  #
  # BE CLEAR ABOUT WHAT THIS DOES AND DOES NOT DO: it only affects DISPLAY.
  # The value is still stored in plain text inside terraform.tfstate. That is
  # precisely why state files must never be committed to git, and why real
  # deployments use an encrypted remote backend.
  sensitive = true
}

output "cluster_version" {
  value       = module.eks.cluster_version
  description = "Kubernetes version actually running, e.g. 1.34."
}

output "cluster_security_group_id" {
  value       = module.eks.cluster_security_group_id
  description = "Security group EKS created for the control plane."
}

output "node_security_group_id" {
  value       = module.eks.node_security_group_id
  description = "Security group shared by all worker nodes."
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "ARN of the cluster's OIDC provider, used by the older IRSA pattern."
}

output "node_iam_role_arn" {
  value       = module.eks.eks_managed_node_groups["general"].iam_role_arn
  description = "IAM role assumed by the worker node EC2 instances."
}

output "configure_kubectl" {
  # A convenience output: the exact command to point kubectl at this cluster.
  # Small touches like this save every future reader a trip to the docs.
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Copy-paste command to configure kubectl for this cluster."
}

output "aws_region" {
  value       = var.aws_region
  description = "Region the cluster lives in. Re-published so later layers need only read one state file."
}
