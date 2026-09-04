resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.launch_template == null ? var.instance_types : null
  capacity_type   = var.capacity_type
  ami_type        = var.ami_type
  disk_size       = var.launch_template == null ? var.disk_size : null
  labels          = var.labels

  scaling_config {
    desired_size = var.scaling.desired
    min_size     = var.scaling.min
    max_size     = var.scaling.max
  }
  update_config { max_unavailable = var.max_unavailable }

  dynamic "launch_template" {
    for_each = var.launch_template != null ? [var.launch_template] : []
    content {
      id      = launch_template.value.id
      version = launch_template.value.version
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

  tags = merge(var.tags, { Name = var.name })
  lifecycle { ignore_changes = [scaling_config[0].desired_size] } # let autoscalers manage
}
