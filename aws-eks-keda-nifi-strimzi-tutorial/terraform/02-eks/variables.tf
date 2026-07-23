variable "aws_region" {
  description = "AWS region used for EKS."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in resource names."
  type        = string
  default     = "eks-keda-lab"
}

variable "environment" {
  description = "Environment label."
  type        = string
  default     = "dev"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes major.minor version."
  type        = string
  default     = "1.35"
}

variable "public_access_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public EKS API endpoint."
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "Provide at least one public access CIDR, normally your public IP with /32."
  }
}

variable "node_instance_types" {
  description = "Allowed EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_desired_size" {
  description = "Starting worker-node count."
  type        = number
  default     = 4
}

variable "node_min_size" {
  description = "Minimum worker-node count."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum worker-node count."
  type        = number
  default     = 6
}

variable "node_disk_size_gb" {
  description = "Root disk size for each worker node."
  type        = number
  default     = 50
}
