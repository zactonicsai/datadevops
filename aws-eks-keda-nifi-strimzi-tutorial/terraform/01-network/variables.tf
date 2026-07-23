variable "aws_region" {
  description = "AWS region used for the tutorial."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name used in resource names and tags."
  type        = string
  default     = "eks-keda-lab"
}

variable "environment" {
  description = "Environment label such as dev or test."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "Large private IPv4 range for the tutorial VPC."
  type        = string
  default     = "10.40.0.0/16"
}
