###############################################################################
# variables.tf — every knob you can turn.
#
# Variables WITHOUT a default are REQUIRED: you must set them in your .tfvars.
# Variables WITH a default are optional overrides.
###############################################################################

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into, e.g. us-east-1."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to every resource name. Keep it short and lowercase, e.g. 'keycloak-prod'."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,25}$", var.name_prefix))
    error_message = "name_prefix must be 3-26 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "common_tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Pre-existing networking (you supply these — Terraform does NOT create them)
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID of the existing VPC, e.g. vpc-0123456789abcdef0."
  type        = string
}

variable "instance_subnet_id" {
  description = "Subnet ID where the Keycloak EC2 instance is placed. Should be a PRIVATE subnet behind your load balancer."
  type        = string
}

variable "db_subnet_ids" {
  description = "At least two subnet IDs in DIFFERENT availability zones for the RDS subnet group. Use private subnets."
  type        = list(string)

  validation {
    condition     = length(var.db_subnet_ids) >= 2
    error_message = "RDS requires at least two subnets in two different availability zones."
  }
}

variable "instance_security_group_ids" {
  description = "Existing security group IDs to attach to the EC2 instance. Must allow inbound 8080 from the load balancer SG and outbound 5432 to the DB SG."
  type        = list(string)
}

variable "db_security_group_ids" {
  description = "Existing security group IDs to attach to RDS. Must allow inbound 5432 from the EC2 instance SG only."
  type        = list(string)
}

variable "target_group_arn" {
  description = "ARN of the existing ALB target group to register the instance in. Set to null to skip registration."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Pre-existing IAM and keys
# ---------------------------------------------------------------------------

variable "iam_instance_profile_name" {
  description = "Name of the existing IAM instance profile for the EC2 instance. Needs AmazonSSMManagedInstanceCore plus secretsmanager:GetSecretValue."
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair. Set to null if you use only SSM Session Manager (recommended)."
  type        = string
  default     = null
}

variable "ebs_kms_key_arn" {
  description = "KMS key ARN for encrypting the EC2 root volume. null uses the AWS-managed aws/ebs key."
  type        = string
  default     = null
}

variable "db_kms_key_arn" {
  description = "KMS key ARN for encrypting RDS storage. null uses the AWS-managed aws/rds key."
  type        = string
  default     = null
}

variable "db_monitoring_role_arn" {
  description = "ARN of an existing IAM role for RDS Enhanced Monitoring. Required only if db_monitoring_interval > 0."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Keycloak needs at least 2 GB RAM; t3.medium is a sane starting point."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 30
}

variable "keycloak_version" {
  description = "Keycloak release to install, e.g. 26.4.0. Check github.com/keycloak/keycloak/releases for the current version."
  type        = string
  default     = "26.4.0"
}

variable "keycloak_hostname" {
  description = "Public DNS name users will reach Keycloak on, e.g. auth.example.com. Must match your load balancer certificate."
  type        = string
}

variable "keycloak_admin_username" {
  description = "Bootstrap admin username created on first start. Change the password immediately after first login."
  type        = string
  default     = "admin"
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL
# ---------------------------------------------------------------------------

variable "db_engine_version" {
  description = "PostgreSQL major.minor version. Use a major version only (e.g. '17') to let AWS pick the latest minor."
  type        = string
  default     = "17"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.medium is a good low-cost start; use db.m7g.large or larger for production."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB. Minimum 20."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Upper bound for storage autoscaling in GiB. Set equal to db_allocated_storage to disable autoscaling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the database Keycloak will use."
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username for PostgreSQL. Cannot be 'postgres', 'admin', 'rdsadmin' or other reserved words."
  type        = string
  default     = "kcadmin"
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ for automatic failover. true for production, false to halve cost in dev."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Days to keep automated backups. 0 disables backups (never do this in production)."
  type        = number
  default     = 7
}

variable "db_backup_window" {
  description = "Daily backup window in UTC, format hh:mm-hh:mm. Pick a low-traffic hour."
  type        = string
  default     = "03:00-04:00"
}

variable "db_maintenance_window" {
  description = "Weekly maintenance window in UTC, format ddd:hh:mm-ddd:hh:mm. Must not overlap the backup window."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "db_performance_insights" {
  description = "Enable Performance Insights. Free for 7 days of retention."
  type        = bool
  default     = true
}

variable "db_monitoring_interval" {
  description = "Enhanced Monitoring granularity in seconds: 0 (off), 1, 5, 10, 15, 30 or 60."
  type        = number
  default     = 0
}

variable "db_deletion_protection" {
  description = "Block accidental deletion of the database. Keep true in production."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. true only in throwaway environments."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Secrets Manager
# ---------------------------------------------------------------------------

variable "secret_recovery_window_days" {
  description = "Days a deleted secret stays recoverable: 0 (immediate delete) or 7-30."
  type        = number
  default     = 7
}
