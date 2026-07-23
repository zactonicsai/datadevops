resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "general"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = data.terraform_remote_state.network.outputs.private_subnet_ids

  version        = var.kubernetes_version
  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = var.node_instance_types
  disk_size      = var.node_disk_size_gb

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable_percentage = 25
  }

  labels = {
    workload = "general"
  }

  tags = {
    Name = "${local.cluster_name}-general-node"
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.container_registry,
    aws_iam_role_policy_attachment.vpc_cni,
  ]
}
