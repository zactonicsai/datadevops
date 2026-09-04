data "aws_ssm_parameter" "ami" {
  count = var.create && var.ami_id == null && var.ami_ssm_parameter != null ? 1 : 0
  name  = var.ami_ssm_parameter
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : (length(data.aws_ssm_parameter.ami) > 0 ? data.aws_ssm_parameter.ami[0].value : null)
}

resource "aws_launch_template" "this" {
  count         = var.create ? 1 : 0
  name          = var.name
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name
  user_data     = var.user_data != null ? base64encode(var.user_data) : null
  update_default_version = true

  vpc_security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  dynamic "iam_instance_profile" {
    for_each = var.iam_instance_profile_name != null ? [1] : []
    content { name = var.iam_instance_profile_name }
  }

  block_device_mappings {
    device_name = var.root_volume.device
    ebs {
      volume_size = var.root_volume.size
      volume_type = var.root_volume.type
      encrypted   = var.root_volume.encrypted
      iops        = var.root_volume.iops
      throughput  = var.root_volume.throughput
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.require_imdsv2 ? "required" : "optional"
    http_put_response_hop_limit = 2
  }

  monitoring { enabled = var.monitoring }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, var.instance_tags, { Name = var.name })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = var.name })
  }
  tags = var.tags
}

data "aws_launch_template" "existing" {
  count = var.create ? 0 : 1
  id    = var.existing_id
}
