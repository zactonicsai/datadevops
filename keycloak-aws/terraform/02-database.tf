###############################################################################
# 02-database.tf
# Amazon RDS for PostgreSQL 18.3 - the filing cabinet Keycloak stores
# users, realms, clients and sessions in.
#
# Key safety choices made here:
#   * publicly_accessible = false  -> no internet-facing endpoint, ever
#   * storage_encrypted   = true   -> data at rest is encrypted (free)
#   * rds.force_ssl = 1            -> connections MUST use TLS
#   * password stored in Secrets Manager, never in the .tf file or state
###############################################################################

variable "db_engine_version" {
  description = "PostgreSQL major.minor version. 18.3 is current on RDS as of mid-2026."
  type        = string
  default     = "18.3"
}

variable "db_instance_class" {
  description = <<-EOT
    Size of the database server.
    db.t4g.micro  - cheapest, ARM Graviton, ~2 vCPU burst / 1 GB RAM. Fine for a lab.
    db.t4g.small  - 2 GB RAM. Better if you expect real users.
    db.m7g.large  - production-grade.
  EOT
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Starting disk size in GB. Minimum billable is 20 GB for gp3."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the database Keycloak will use."
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username. 'postgres', 'admin' and 'rdsadmin' are reserved words to avoid."
  type        = string
  default     = "kcadmin"
}

variable "db_multi_az" {
  description = "Run a standby copy in a second AZ. Doubles the cost. Off for a lab, ON for production."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "How many days of automatic backups to keep. 0 disables backups (not recommended)."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Blocks accidental deletion. Set false while learning so destroy works."
  type        = bool
  default     = false
}

###############################################################################
# PASSWORD GENERATION AND STORAGE
#
# We generate a strong random password, then park it in AWS Secrets Manager.
# The EC2 instance reads it at boot using the least-privilege IAM role from
# 01-network.tf. It never appears in a shell history or a config file.
#
# Excluded characters: RDS forbids / @ " and spaces in master passwords.
###############################################################################

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "aws_secretsmanager_secret" "db" {
  # The name MUST start with "<project>/db-" to match the IAM policy in 01.
  name                    = "${var.project_name}/db-credentials-${random_id.suffix.hex}"
  description             = "Keycloak RDS PostgreSQL master credentials"

  # 0 = delete immediately on destroy. Use 7-30 in production so you can
  # recover from a mistake.
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "postgres"
    host     = aws_db_instance.keycloak.address
    port     = 5432
    dbname   = var.db_name
  })
}

###############################################################################
# PARAMETER GROUP - database settings
#
# rds.force_ssl = 1 is the single most valuable setting here. Without it a
# client can silently connect in plaintext. With it, Postgres refuses.
###############################################################################

resource "aws_db_parameter_group" "keycloak" {
  name        = "${var.project_name}-pg18-params"
  family      = "postgres18"
  description = "Keycloak tuning for PostgreSQL 18"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Log any query slower than 1 second. Cheap insight into a slow login page.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  # Keycloak opens a pool of connections; the t4g.micro default (~112) is
  # plenty, but pinning it makes behaviour predictable across instance sizes.
  parameter {
    name         = "max_connections"
    value        = "150"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# THE DATABASE INSTANCE
###############################################################################

resource "aws_db_instance" "keycloak" {
  identifier = "${var.project_name}-db"

  # --- Engine -------------------------------------------------------------
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  # Let AWS apply security patches (18.3 -> 18.4) during the maintenance
  # window. Major versions (18 -> 19) are never automatic.
  auto_minor_version_upgrade = true

  # --- Storage ------------------------------------------------------------
  # gp3 gives a fixed 3000 IOPS baseline at the 20 GB tier - better and no
  # more expensive than the older gp2 for small volumes.
  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5 # autoscale ceiling
  storage_encrypted     = true                          # free; always on

  # --- Credentials --------------------------------------------------------
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # --- Networking ---------------------------------------------------------
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  # THE most important line in this file. Keep it false.
  publicly_accessible = false

  # --- Availability -------------------------------------------------------
  multi_az = var.db_multi_az

  # --- Backups and maintenance -------------------------------------------
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "07:00-08:00" # UTC = 2-3am US Central
  maintenance_window      = "Mon:08:30-Mon:09:30"
  copy_tags_to_snapshot   = true

  # --- Monitoring ---------------------------------------------------------
  # Performance Insights free tier: 7 days retention at no charge.
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  # --- Settings -----------------------------------------------------------
  parameter_group_name = aws_db_parameter_group.keycloak.name

  # --- Deletion behaviour -------------------------------------------------
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = true # set false + name below in production
  final_snapshot_identifier = null

  # Terraform would otherwise try to "fix" a password AWS rotated.
  lifecycle {
    ignore_changes = [password]
  }

  tags = {
    Name = "${var.project_name}-db"
  }
}

###############################################################################
# OUTPUTS
###############################################################################

output "db_endpoint" {
  description = "Hostname Keycloak connects to (private, resolvable only inside the VPC)"
  value       = aws_db_instance.keycloak.address
}

output "db_port" {
  description = "PostgreSQL port"
  value       = aws_db_instance.keycloak.port
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB credentials"
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Secrets Manager secret name"
  value       = aws_secretsmanager_secret.db.name
}

output "db_jdbc_url" {
  description = "Ready-made JDBC URL with TLS enforced"
  value       = "jdbc:postgresql://${aws_db_instance.keycloak.address}:${aws_db_instance.keycloak.port}/${var.db_name}?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem"
}
