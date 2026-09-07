data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

# SSM access so you can get a shell without SSH keys.
resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2"
  role = aws_iam_role.ec2.name
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.al2023_arm.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  associate_public_ip_address = true # needed for outbound internet (image pulls) without a NAT gateway

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    keycloak_version = var.keycloak_version
    keycloak_domain  = var.keycloak_domain
    db_host          = aws_db_instance.this.address
    db_name          = aws_db_instance.this.db_name
    db_user          = aws_db_instance.this.username
    db_password      = random_password.db.result
    admin_user       = "admin"
    admin_password   = random_password.admin.result
  })
  user_data_replace_on_change = true

  tags = { Name = var.name }
}
