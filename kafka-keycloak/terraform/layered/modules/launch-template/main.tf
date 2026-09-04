data "aws_ssm_parameter" "ami" {
  count = var.create && !var.for_eks && var.ami_id == null ? 1 : 0
  name  = var.ami_ssm_parameter
}

locals {
  ami_id = var.for_eks ? null : coalesce(var.ami_id, try(data.aws_ssm_parameter.ami[0].value, null))
}

resource "aws_launch_template" "this" {
  count         = var.create ? 1 : 0
  name          = var.name
  image_id      = local.ami_id
  instance_type = var.for_eks ? null : var.instance_type
  key_name      = var.key_name
  user_data     = var.user_data == null ? null : base64encode(var.user_data)
  update_default_version = true

  vpc_security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  dynamic "iam_instance_profile" {
    for_each = var.iam_instance_profile_name == null ? [] : [1]
    content { name = var.iam_instance_profile_name }
  }

  block_device_mappings {
    device_name = var.root_device_name
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.metadata_http_tokens
    http_put_response_hop_limit = 2
  }

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name })
  }
  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = var.name })
  }
  tags = var.tags
}
