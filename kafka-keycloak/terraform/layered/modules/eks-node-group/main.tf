resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types
  capacity_type   = var.capacity_type
  ami_type        = var.ami_type
  labels          = var.labels

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }
  update_config { max_unavailable = 1 }

  dynamic "launch_template" {
    for_each = var.launch_template_id == null ? [] : [1]
    content {
      id      = var.launch_template_id
      version = var.launch_template_version
    }
  }

  dynamic "taint" {
    for_each = var.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = var.tags
  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
}
