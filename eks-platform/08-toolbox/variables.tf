# =============================================================================
# 08-toolbox/variables.tf
# =============================================================================

variable "toolbox_namespace" {
  type        = string
  description = "Namespace for the diagnostic toolbox pod."
  default     = "toolbox"
}

variable "netshoot_version" {
  type        = string
  description = "nicolaka/netshoot image tag. Pinned rather than 'latest' so the tool set is reproducible."
  default     = "v0.13"
}
