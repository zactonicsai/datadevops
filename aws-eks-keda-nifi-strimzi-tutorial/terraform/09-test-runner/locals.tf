locals {
  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Tutorial    = "EKS-KEDA-NiFi-Strimzi"
  }
}
