terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Look up the snapshot to validate it exists (and read engine info from it)
data "aws_db_snapshot" "source" {
  db_snapshot_identifier = var.snapshot_identifier
  most_recent            = true
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.db_identifier}-subnet-group"
  subnet_ids = var.subnet_ids

  tags = var.tags
}

resource "aws_security_group" "db" {
  name        = "${var.db_identifier}-sg"
  description = "Allow DB access"
  vpc_id      = var.vpc_id

  ingress {
    description = "DB port"
    from_port   = data.aws_db_snapshot.source.port
    to_port     = data.aws_db_snapshot.source.port
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_instance" "from_snapshot" {
  identifier          = var.db_identifier
  snapshot_identifier = data.aws_db_snapshot.source.id

  # Engine/version/storage size come from the snapshot; these can be overridden
  instance_class    = var.instance_class
  storage_type      = var.storage_type
  allocated_storage = var.allocated_storage # must be >= snapshot size

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = var.publicly_accessible
  multi_az               = var.multi_az

  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.db_identifier}-final"

  apply_immediately = true

  tags = var.tags
}
