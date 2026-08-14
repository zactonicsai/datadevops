terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

##############################
# Variables
##############################

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for created resources"
  type        = string
  default     = "nifi"
}

variable "vpc_id" {
  description = "VPC in which the security group is created"
  type        = string
}

variable "ami_id" {
  description = "Base AMI. Must be a RHEL-family image with firewalld available (RHEL/Rocky/Alma/CentOS Stream). Leave null to use the latest RHEL 9 AMI."
  type        = string
  default     = null
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH access"
  type        = string
  default     = null
}

variable "instance_profile_name" {
  description = "Optional IAM instance profile (e.g. for SSM Session Manager)"
  type        = string
  default     = null
}

variable "nifi_version" {
  type    = string
  default = "1.28.1"
}

variable "http_port" {
  description = "NiFi UI port (plain HTTP, unauthenticated)"
  type        = number
  default     = 8080
}

variable "s2s_port" {
  description = "NiFi site-to-site raw socket port"
  type        = number
  default     = 10443
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the NiFi UI and SSH. Defaults to the whole internet, which is what an unauthenticated NiFi should NOT be exposed to."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "root_volume_size" {
  type    = number
  default = 50
}

##############################
# AMI lookup (RHEL 9, ships firewalld)
##############################

data "aws_ami" "rhel9" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = coalesce(var.ami_id, data.aws_ami.rhel9.id)
}

##############################
# Security group
##############################

resource "aws_security_group" "nifi" {
  name        = "${var.name}-sg"
  description = "Apache NiFi ${var.nifi_version} - UNAUTHENTICATED HTTP access"
  vpc_id      = var.vpc_id

  ingress {
    description = "NiFi UI / REST API (no auth)"
    from_port   = var.http_port
    to_port     = var.http_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "NiFi site-to-site"
    from_port   = var.s2s_port
    to_port     = var.s2s_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

##############################
# Launch template
##############################

resource "aws_launch_template" "nifi" {
  name_prefix   = "${var.name}-"
  description   = "Apache NiFi ${var.nifi_version}, open access, firewalld ports opened"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.nifi.id]

  dynamic "iam_instance_profile" {
    for_each = var.instance_profile_name == null ? [] : [var.instance_profile_name]
    content {
      name = iam_instance_profile.value
    }
  }

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    nifi_version = var.nifi_version
    http_port    = var.http_port
    s2s_port     = var.s2s_port
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = var.name
      App  = "nifi"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = var.name
    }
  }

  update_default_version = true

  lifecycle {
    create_before_destroy = true
  }
}

##############################
# Outputs
##############################

output "launch_template_id" {
  value = aws_launch_template.nifi.id
}

output "launch_template_latest_version" {
  value = aws_launch_template.nifi.latest_version
}

output "security_group_id" {
  value = aws_security_group.nifi.id
}

output "nifi_url_hint" {
  value = "http://<instance-public-ip>:${var.http_port}/nifi"
}
