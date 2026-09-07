output "db_endpoint" {
  value = aws_db_instance.from_snapshot.endpoint
}

output "db_address" {
  value = aws_db_instance.from_snapshot.address
}

output "db_port" {
  value = aws_db_instance.from_snapshot.port
}

output "db_engine" {
  value = "${aws_db_instance.from_snapshot.engine} ${aws_db_instance.from_snapshot.engine_version}"
}

output "security_group_id" {
  value = aws_security_group.db.id
}
