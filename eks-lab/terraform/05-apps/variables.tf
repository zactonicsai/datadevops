# =============================================================================
# All layers share this same variables file, so a single dev.tfvars works
# everywhere. Terraform errors on values it does not recognise, which is why
# every variable is declared even in layers that do not use it.
# =============================================================================

variable "lab_name" {
  description = "Prefix for every resource name"
  type        = string
}

variable "region" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  description = "Availability zones. Two is the EKS minimum."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "use_nat" {
  description = "true = nodes in private subnets behind a NAT (~$33/mo). false = nodes in public subnets, free."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- cluster ----
variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "endpoint_public_access" {
  description = "Keep true for a laptop-accessible lab. false for anything real."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "Who may reach the API server and load balancer. Narrow this!"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---- nodes ----
variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_capacity_type" {
  description = "SPOT is ~70% cheaper but can be reclaimed. ON_DEMAND for prod."
  type        = string
  default     = "SPOT"
}

variable "node_min" {
  type    = number
  default = 2
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "node_max" {
  type    = number
  default = 3
}

variable "node_disk_gb" {
  type    = number
  default = 40
}

# ---- apps ----
variable "namespace" {
  type    = string
  default = "lab"
}

variable "kafka_topic" {
  type    = string
  default = "messages"
}

variable "image_keycloak" {
  type    = string
  default = "quay.io/keycloak/keycloak:26.7.1"
}

variable "image_kafka" {
  type    = string
  default = "apache/kafka:3.9.0"
}

variable "image_nifi" {
  type    = string
  default = "apache/nifi:2.11.0"
}

variable "image_python" {
  type    = string
  default = "python:3.12-slim"
}

variable "enable_monitoring" {
  type    = bool
  default = true
}
