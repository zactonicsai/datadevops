aws_region          = "us-east-1"
snapshot_identifier = "my-prod-db-snapshot-2026-09-01"
db_identifier       = "my-restored-db"

instance_class    = "db.t3.medium"
storage_type      = "gp3"
allocated_storage = 100

vpc_id     = "vpc-0123456789abcdef0"
subnet_ids = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]

allowed_cidr_blocks = ["10.0.0.0/16"]

publicly_accessible     = false
multi_az                = false
backup_retention_period = 7
deletion_protection     = false
skip_final_snapshot     = true

tags = {
  Environment = "staging"
  ManagedBy   = "terraform"
}
