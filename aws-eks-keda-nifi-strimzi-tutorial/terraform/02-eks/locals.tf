locals {
  cluster_name = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Tutorial    = "EKS-KEDA-NiFi-Strimzi"
  }
}
