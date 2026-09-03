variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "kafka-dev"
}

variable "http_host_port" {
  description = "Host port mapped to the cluster's ingress (80 needs no port in URLs; use e.g. 8000 if 80 is taken)"
  type        = number
  default     = 80
}

variable "kafka_host_port" {
  description = "Host port for the Kafka bootstrap server (Python client connects here)"
  type        = number
  default     = 29092
}

variable "domain" {
  description = "Wildcard domain that resolves to 127.0.0.1 (localtest.me does this publicly)"
  type        = string
  default     = "localtest.me"
}

variable "keycloak_admin_password" {
  type      = string
  default   = "admin"
  sensitive = true
}

variable "kafka_ui_client_secret" {
  description = "OIDC client secret shared by Keycloak and Kafka UI"
  type        = string
  default     = "kafka-ui-secret-change-me"
  sensitive   = true
}

variable "topics" {
  description = "Kafka topics to create"
  type = map(object({
    partitions = number
    config     = optional(map(string), {})
  }))
  default = {
    orders        = { partitions = 3 }
    payments      = { partitions = 3 }
    user-events   = { partitions = 6 }
    audit-log     = { partitions = 1, config = { "retention.ms" = "604800000", "cleanup.policy" = "delete" } }
  }
}

variable "versions" {
  description = "Pinned chart/image versions"
  type        = map(string)
  default = {
    ingress_nginx_chart = "4.11.3"
    strimzi_chart       = "0.45.0"
    kafka               = "3.9.0"
    kafka_ui_chart      = "1.4.10"
    keycloak_image      = "quay.io/keycloak/keycloak:26.3"
  }
}
