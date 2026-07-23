# =============================================================================
# 07-nifi/variables.tf
# =============================================================================
# The sizing defaults here are explained in detail at the top of main.tf.
# The short version: NiFi is a JVM application, so the container memory limit
# must be substantially larger than the JVM heap to leave room for metaspace,
# thread stacks, direct buffers and OS page cache.
# =============================================================================

variable "nifi_namespace" {
  type        = string
  description = "Namespace for the NiFi instances."
  default     = "nifi"
}

variable "nifi_version" {
  type        = string
  description = "Apache NiFi image tag. 2.10.0 is current as of July 2026 and requires Java 21 (bundled in the image)."
  default     = "2.10.0"
}

variable "nifi_replicas" {
  type        = number
  description = "Number of NiFi pods. Two, as requested. NOTE: these are independent instances, not a NiFi cluster."
  default     = 2
}

variable "nifi_username" {
  type        = string
  description = "Login name for NiFi single-user authentication."
  default     = "admin"
}

# ---- Resource sizing ----

variable "nifi_cpu_request" {
  type        = string
  description = "CPU reserved per pod. NiFi is bursty, so we request modestly and allow a high limit."
  default     = "500m"
}

variable "nifi_cpu_limit" {
  type        = string
  description = "CPU ceiling per pod. Generous, so a running flow can burst."
  default     = "2000m"
}

variable "nifi_memory_request" {
  type        = string
  description = "Memory reserved per pod."
  default     = "2Gi"
}

variable "nifi_memory_limit" {
  type        = string
  description = "Memory ceiling per pod. Must exceed the JVM heap by a wide margin or the kernel OOMKills the container."
  default     = "3Gi"
}

variable "nifi_jvm_heap" {
  type        = string
  description = "JVM heap size. Roughly a third of nifi_memory_limit; see the sizing discussion in main.tf."
  default     = "1g"
}

variable "nifi_storage_size" {
  type        = string
  description = "Persistent volume size per pod, holding all four NiFi repositories."
  default     = "10Gi"
}
