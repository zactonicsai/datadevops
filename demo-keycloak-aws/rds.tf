###############################################################################
# RDS for PostgreSQL - Keycloak persistence layer
# Lives in the isolated database subnets, reachable only from the Keycloak SG.
###############################################################################

resource "aws_db_subnet_group" "keycloak" {
  name        = "${local.name_prefix}-db-subnets"
  description = "Isolated database subnets for ${local.name_prefix}"
  subnet_ids  = values(aws_subnet.database)[*].id

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

resource "aws_db_parameter_group" "keycloak" {
  name_prefix = "${local.name_prefix}-pg-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"
  description = "Custom parameters for ${local.name_prefix}"

  dynamic "parameter" {
    for_each = var.db_parameters

    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = parameter.value.apply_method
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-pg" }
}

resource "aws_db_instance" "keycloak" {
  identifier = "${local.name_prefix}-postgres"

  engine                      = "postgres"
  engine_version              = var.db_engine_version
  auto_minor_version_upgrade  = var.db_auto_minor_version_upgrade
  instance_class              = var.db_instance_class
  allow_major_version_upgrade = false

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = var.db_port

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = var.db_storage_type
  iops                  = var.db_storage_iops
  storage_throughput    = var.db_storage_throughput
  storage_encrypted     = true
  kms_key_id            = var.rds_kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.keycloak.name
  vpc_security_group_ids = [aws_security_group.database.id]
  parameter_group_name   = aws_db_parameter_group.keycloak.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = var.db_backup_retention_period
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window
  copy_tags_to_snapshot   = true

  performance_insights_enabled    = var.db_performance_insights_enabled
  monitoring_interval             = var.db_monitoring_interval
  monitoring_role_arn             = var.db_monitoring_interval > 0 ? data.aws_iam_role.rds_monitoring[0].arn : null
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  apply_immediately         = var.db_apply_immediately

  lifecycle {
    # The password is rotated in Secrets Manager, not by re-running Terraform.
    # The snapshot identifier contains a timestamp and would otherwise churn.
    ignore_changes = [
      password,
      final_snapshot_identifier,
    ]
  }

  tags = { Name = "${local.name_prefix}-postgres" }
}

# ----------------------------------------------------------------------------
# Cross-region automated backup replication
# Survives the loss of an entire region, not just an AZ.
# ----------------------------------------------------------------------------
provider "aws" {
  alias  = "backup"
  region = var.backup_replication_region == null ? var.aws_region : var.backup_replication_region
}

resource "aws_db_instance_automated_backups_replication" "keycloak_backup_replica" {
  count = var.enable_cross_region_backup_replication ? 1 : 0

  provider = aws.backup

  source_db_instance_arn = aws_db_instance.keycloak.arn
  kms_key_id             = var.backup_replication_kms_key_arn
  retention_period       = var.db_backup_retention_period
}
