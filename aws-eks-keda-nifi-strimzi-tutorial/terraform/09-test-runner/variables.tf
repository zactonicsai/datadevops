variable "aws_region" {
  description = "AWS region used by the test runner."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in tags."
  type        = string
  default     = "eks-keda-lab"
}

variable "environment" {
  description = "Environment label."
  type        = string
  default     = "dev"
}

variable "runner_instance_type" {
  description = "EC2 size for the SSM-only command runner."
  type        = string
  default     = "t3.small"
}
