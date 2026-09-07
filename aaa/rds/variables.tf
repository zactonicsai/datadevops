variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "snapshot_identifier" {
  description = "Name or ARN of the RDS snapshot to restore from"
  type        = string
}

variable "db_identifier" {
  description = "Identifier for the new DB instance"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "storage_type" {
  description = "Storage type (gp2, gp3, io1)"
  type        = string
  default     = "gp3"
}

variable "allocated_storage" {
  description = "Allocated storage in GB (must be >= snapshot size)"
  type        = number
  default     = null
}

variable "vpc_id" {
  description = "VPC where the DB will live"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group (at least two AZs)"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the DB port"
  type        = list(string)
  default     = []
}

variable "publicly_accessible" {
  type    = bool
  default = false
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "backup_retention_period" {
  description = "Days to keep automated backups"
  type        = number
  default     = 7
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "skip_final_snapshot" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
