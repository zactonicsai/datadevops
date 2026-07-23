resource "aws_instance" "runner" {
  ami           = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type = var.runner_instance_type

  subnet_id                   = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    aws_region   = var.aws_region
    cluster_name = local.cluster_name
  })

  tags = {
    Name = "${local.cluster_name}-test-runner"
    Role = "eks-test-runner"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_eks_access_entry.runner,
    aws_vpc_security_group_ingress_rule.runner_to_eks,
  ]
}
