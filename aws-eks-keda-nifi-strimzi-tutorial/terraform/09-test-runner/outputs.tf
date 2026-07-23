output "instance_id" {
  description = "EC2 instance ID used by Session Manager."
  value       = aws_instance.runner.id
}

output "runner_role_arn" {
  description = "IAM role mapped to the tutorial-testers Kubernetes group."
  value       = aws_iam_role.runner.arn
}

output "session_command" {
  description = "AWS CLI command that opens an SSM shell."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.runner.id}"
}
