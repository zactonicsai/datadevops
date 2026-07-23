resource "aws_eks_access_entry" "runner" {
  cluster_name      = local.cluster_name
  principal_arn     = aws_iam_role.runner.arn
  kubernetes_groups = ["tutorial-testers"]
  type              = "STANDARD"
}
