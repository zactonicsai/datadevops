# =============================================================================
# common-variables.tf
# =============================================================================
# This file DECLARES the variables (it asks the questions).
# common.auto.tfvars ANSWERS them.
#
# Terraform has no "include" or "import" statement, so a variable used in more
# than one layer has to be declared in each layer. Rather than copy-pasting this
# file nine times (and having nine copies drift apart), the setup script creates
# a SYMLINK to this one file inside every layer directory. Edit it once here and
# every layer sees the change.
#
# ANATOMY OF A VARIABLE BLOCK
#   type        - what shape of value is allowed. Terraform rejects wrong shapes
#                 before it touches AWS, which catches typos early.
#   description - human-readable help text, shown by `terraform console` and
#                 documentation tools.
#   default     - the value used when tfvars does not supply one. A variable
#                 with NO default is required; Terraform will stop and prompt.
#   validation  - an extra rule we enforce ourselves, with a custom error
#                 message. This is a best practice: fail fast with a clear
#                 message instead of failing 10 minutes later inside AWS.
# =============================================================================

variable "project_name" {
  type        = string
  description = "Short prefix glued onto the front of every resource name."
  default     = "eksdemo"

  validation {
    # can(regex(...)) returns true if the pattern matches, false otherwise.
    # ^ means "start of string", $ means "end of string", so the WHOLE name
    # must consist of lowercase letters, digits and dashes.
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, numbers, and dashes."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region where all infrastructure is created."
  default     = "us-east-1"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS control plane Kubernetes minor version, e.g. \"1.34\"."
  default     = "1.34"

  validation {
    # Matches "1.34" but rejects "1.34.2" or "v1.34". EKS wants MAJOR.MINOR
    # only; giving it a patch version is a common beginner error.
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like \"1.34\" (major.minor, no patch number)."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "IPv4 CIDR block for the VPC, e.g. \"10.42.0.0/16\"."
  default     = "10.42.0.0/16"

  validation {
    # cidrhost() is a built-in that fails if the string is not a valid CIDR.
    # Wrapping it in can() turns that failure into a clean false, which lets us
    # emit our own friendly message instead of a cryptic Terraform error.
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, such as 10.42.0.0/16."
  }
}

variable "availability_zone_count" {
  type        = number
  description = "How many Availability Zones to spread subnets across."
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "availability_zone_count must be between 2 and 4. EKS requires at least 2."
  }
}

variable "single_nat_gateway" {
  type        = bool
  description = "true = one shared NAT gateway (cheap). false = one per AZ (resilient)."
  default     = true
}

variable "node_instance_types" {
  type        = list(string)
  description = "Allowed EC2 instance types for worker nodes, in preference order."
  default     = ["m6i.large", "m5.large", "m6a.large"]
}

variable "node_group_min_size" {
  type        = number
  description = "Minimum number of worker nodes."
  default     = 3
}

variable "node_group_desired_size" {
  type        = number
  description = "Starting number of worker nodes."
  default     = 3
}

variable "node_group_max_size" {
  type        = number
  description = "Maximum number of worker nodes; your cost ceiling."
  default     = 6
}

variable "node_disk_size_gb" {
  type        = number
  description = "Root EBS volume size in GiB for each worker node."
  default     = 50

  validation {
    condition     = var.node_disk_size_gb >= 30
    error_message = "node_disk_size_gb must be at least 30. Container images fill smaller disks."
  }
}

variable "allowed_admin_cidrs" {
  type        = list(string)
  description = "Source IP ranges allowed to reach the public Kubernetes API endpoint."
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  # map(string) means "a dictionary whose keys and values are both text".
  type        = map(string)
  description = "Tags applied to every AWS resource that supports tagging."
  default = {
    Project   = "eks-platform-tutorial"
    ManagedBy = "terraform"
  }
}
