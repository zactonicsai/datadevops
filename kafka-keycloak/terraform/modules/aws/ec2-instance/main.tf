resource "aws_instance" "this" {
  count     = var.instance_count
  subnet_id = var.subnet_ids[count.index % length(var.subnet_ids)]

  launch_template {
    id      = var.launch_template.id
    version = var.launch_template.version
  }

  tags = merge(var.tags, { Name = "${var.name}-${count.index}" })
  lifecycle { ignore_changes = [ami] }
}

locals {
  attachments = { for pair in setproduct(range(var.instance_count), var.target_group_arns) : "${pair[0]}-${pair[1]}" => { idx = pair[0], tg = pair[1] } }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each         = local.attachments
  target_group_arn = each.value.tg
  target_id        = aws_instance.this[each.value.idx].id
  port             = var.target_port
}
