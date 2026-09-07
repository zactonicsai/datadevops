variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "keycloak"
}

variable "route53_zone_name" {
  description = "Existing public Route 53 hosted zone, e.g. example.com"
  type        = string
}

variable "keycloak_domain" {
  description = "FQDN for Keycloak inside that zone, e.g. auth.example.com"
  type        = string
}

variable "keycloak_version" {
  description = "Keycloak container image tag"
  type        = string
  default     = "26.3"
}

variable "instance_type" {
  description = "EC2 instance type (ARM/Graviton)"
  type        = string
  default     = "t4g.small"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the load balancer on 80/443"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_key_name" {
  description = "Optional existing EC2 key pair name. Leave empty to use SSM Session Manager only."
  type        = string
  default     = ""
}
