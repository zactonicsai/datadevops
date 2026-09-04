variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "kafka-ui-eks"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.30"
}

variable "kafka_cluster_name" {
  description = "Display name for the Kafka cluster in Kafka UI"
  type        = string
  default     = "my-kafka"
}

variable "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers, e.g. b-1.msk.amazonaws.com:9092,b-2...:9092"
  type        = string
  default     = ""
}

# --- OIDC auth ---
variable "oidc_issuer_uri" {
  description = "OIDC issuer URL, e.g. https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXXX or https://login.microsoftonline.com/<tenant>/v2.0"
  type        = string
}

variable "oidc_client_id" {
  description = "OIDC client ID"
  type        = string
}

variable "oidc_client_secret" {
  description = "OIDC client secret"
  type        = string
  sensitive   = true
}

variable "oidc_scope" {
  description = "OIDC scopes"
  type        = string
  default     = "openid,profile,email"
}

variable "oidc_username_attribute" {
  description = "Claim used as the display username (e.g. email, preferred_username, cognito:username)"
  type        = string
  default     = "email"
}
