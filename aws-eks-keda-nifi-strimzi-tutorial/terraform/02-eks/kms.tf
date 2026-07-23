resource "aws_kms_key" "eks_secrets" {
  description             = "Encrypts Kubernetes Secrets for ${local.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${local.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}
