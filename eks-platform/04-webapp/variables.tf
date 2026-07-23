# =============================================================================
# 04-webapp/variables.tf
# =============================================================================
# Variables used ONLY by this layer. Shared ones (aws_region, tags,
# allowed_admin_cidrs) come from the symlinked common-variables.tf.
# =============================================================================

variable "app_namespace" {
  type        = string
  description = "Kubernetes namespace for the web application."
  default     = "hello-web"
}

variable "initial_replicas" {
  type        = number
  description = "Replica count at creation time. KEDA owns it after that."
  default     = 2 # Two, as requested: enough to demonstrate load balancing.
}

variable "enable_autoscaling" {
  type        = bool
  description = "Create the KEDA ScaledObject. Set false to run at a fixed size."
  default     = true
}

variable "min_replicas" {
  type        = number
  description = "Floor KEDA will not scale below."
  default     = 2

  validation {
    # Values below 0 are meaningless. 0 IS allowed and is KEDA's scale-to-zero
    # feature, though we default to 2 for a user-facing service (see the
    # discussion in scaling.tf).
    condition     = var.min_replicas >= 0
    error_message = "min_replicas cannot be negative."
  }
}

variable "max_replicas" {
  type        = number
  description = "Ceiling KEDA will not scale above. Your cost and blast-radius limit."
  default     = 10
}

variable "cpu_target_percent" {
  type        = number
  description = "Target CPU utilisation as a percentage OF THE CPU REQUEST, not of a whole core."
  default     = 50

  validation {
    condition     = var.cpu_target_percent > 0 && var.cpu_target_percent <= 100
    error_message = "cpu_target_percent must be between 1 and 100."
  }
}

variable "create_public_loadbalancer" {
  type        = bool
  description = "Create an internet-facing NLB (~$16/month). Set false to test only from inside the cluster."
  default     = true
}
