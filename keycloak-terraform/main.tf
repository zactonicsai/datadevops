###############################################################################
# main.tf - Keycloak on EC2 + PostgreSQL on RDS
#
# This file creates ONLY:
#   1. An RDS PostgreSQL database (the "filing cabinet")
#   2. An EC2 instance running Keycloak (the "front desk")
#   3. A Secrets Manager secret holding the DB password
#   4. A target group attachment to your EXISTING load balancer
#
# Everything else (VPC, subnets, security groups, IAM roles, key pairs,
# load balancer, ACM certificate) must ALREADY EXIST. We look them up
# by ID/name using variables and data sources.
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # OPTIONAL but STRONGLY RECOMMENDED: remote state in S3.
  # Uncomment and fill in after you create the bucket + lock table.
  #
  # backend "s3" {
  #   bucket       = "my-terraform-state-bucket"
  #   key          = "keycloak/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true   # native S3 locking (Terraform 1.10+); replaces DynamoDB
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

###############################################################################
# DATA SOURCES — look up things that already exist
###############################################################################

# The latest Amazon Linux 2023 AMI, found automatically by SSM Parameter Store.
# AWS publishes the current AMI ID here, so we never hard-code a stale one.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

# Your existing VPC — used to validate subnet placement.
data "aws_vpc" "selected" {
  id = var.vpc_id
}

###############################################################################
# 1. DATABASE PASSWORD — generated, never typed by a human
###############################################################################

resource "random_password" "keycloak_db" {
  length  = 32
  special = true
  # RDS forbids these characters in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "keycloak_db" {
  name        = "${var.name_prefix}-db-credentials"
  description = "Master credentials for the Keycloak PostgreSQL database"

  # In dev you may want 0 so you can immediately recreate a deleted secret.
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "keycloak_db" {
  secret_id = aws_secretsmanager_secret.keycloak_db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.keycloak_db.result
    engine   = "postgres"
    host     = aws_db_instance.keycloak.address
    port     = aws_db_instance.keycloak.port
    dbname   = var.db_name
  })
}

###############################################################################
# 2. RDS SUBNET GROUP — tells RDS which private subnets it may live in
###############################################################################

resource "aws_db_subnet_group" "keycloak" {
  name        = "${var.name_prefix}-db-subnets"
  description = "Private subnets for the Keycloak RDS instance"
  subnet_ids  = var.db_subnet_ids
}

###############################################################################
# 3. THE POSTGRESQL DATABASE
###############################################################################

resource "aws_db_instance" "keycloak" {
  identifier = "${var.name_prefix}-db"

  # --- Engine ---
  engine         = "postgres"
  engine_version = var.db_engine_version

  # Only apply minor version upgrades in a maintenance window, never mid-day.
  auto_minor_version_upgrade = true

  # --- Sizing ---
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage # enables storage autoscaling
  storage_type          = "gp3"

  # --- Credentials & database ---
  db_name  = var.db_name
  username = var.db_username
  password = random_password.keycloak_db.result

  # --- Networking ---
  db_subnet_group_name   = aws_db_subnet_group.keycloak.name
  vpc_security_group_ids = var.db_security_group_ids
  publicly_accessible    = false # NEVER true for a Keycloak database
  port                   = 5432

  # --- Availability ---
  multi_az = var.db_multi_az

  # --- Encryption ---
  storage_encrypted = true
  kms_key_id        = var.db_kms_key_arn # null = AWS-managed key

  # --- Backups ---
  backup_retention_period = var.db_backup_retention_days
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window
  copy_tags_to_snapshot   = true

  # --- Monitoring ---
  performance_insights_enabled = var.db_performance_insights
  monitoring_interval          = var.db_monitoring_interval
  monitoring_role_arn          = var.db_monitoring_role_arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # --- Deletion protection ---
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.name_prefix}-db-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  # Apply changes during the maintenance window, not instantly.
  apply_immediately = false

  lifecycle {
    ignore_changes = [
      # timestamp() changes every plan; ignore so it doesn't force replacement.
      final_snapshot_identifier,
      # Password rotation is handled by Secrets Manager, not Terraform.
      password,
    ]
  }

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

###############################################################################
# 4. THE KEYCLOAK EC2 INSTANCE
###############################################################################

resource "aws_instance" "keycloak" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  subnet_id              = var.instance_subnet_id
  vpc_security_group_ids = var.instance_security_group_ids
  key_name               = var.key_pair_name

  # Existing instance profile that grants: SSM Session Manager access +
  # secretsmanager:GetSecretValue on the secret above.
  iam_instance_profile = var.iam_instance_profile_name

  # IMDSv2 required — blocks the SSRF attacks that leak instance credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.ebs_kms_key_arn
    delete_on_termination = true
  }

  # The bootstrap script. Changing it replaces the instance (immutable pattern).
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    keycloak_version = var.keycloak_version
    db_host          = aws_db_instance.keycloak.address
    db_port          = aws_db_instance.keycloak.port
    db_name          = var.db_name
    secret_arn       = aws_secretsmanager_secret.keycloak_db.arn
    aws_region       = var.aws_region
    keycloak_hostname = var.keycloak_hostname
    admin_username   = var.keycloak_admin_username
  })

  user_data_replace_on_change = true

  tags = {
    Name = "${var.name_prefix}-server"
  }

  depends_on = [aws_secretsmanager_secret_version.keycloak_db]
}

###############################################################################
# 5. ATTACH TO YOUR EXISTING LOAD BALANCER TARGET GROUP
###############################################################################

resource "aws_lb_target_group_attachment" "keycloak" {
  count = var.target_group_arn == null ? 0 : 1

  target_group_arn = var.target_group_arn
  target_id        = aws_instance.keycloak.id
  port             = 8080
}
