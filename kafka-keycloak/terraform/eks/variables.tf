variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "kafka-keycloak"
}

variable "kubernetes_version" {
  type    = string
  default = "1.31"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "route53_zone_name" {
  description = "Existing public Route 53 hosted zone, e.g. example.com"
  type        = string
}

variable "keycloak_host" {
  description = "Hostname for Keycloak (record created in the zone)"
  type        = string
  default     = "auth"
}

variable "kafka_ui_host" {
  description = "Hostname for Kafka UI (record created in the zone)"
  type        = string
  default     = "kafka-ui"
}

variable "kafka_ui_alb_scheme" {
  description = "internal (VPN users) or internet-facing"
  type        = string
  default     = "internet-facing"
}

variable "kafka_ui_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kafka UI ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}

variable "keycloak_db_password" {
  type      = string
  sensitive = true
}

variable "kafka_ui_client_secret" {
  description = "OIDC client secret shared by Keycloak and Kafka UI"
  type        = string
  sensitive   = true
}

variable "test_users" {
  description = "Users to seed into the realm (dev/test only)"
  type = map(object({
    password = string
    roles    = list(string)
  }))
  default = {
    alice = { password = "alice123", roles = ["kafka-admin"] }
    bob   = { password = "bob123", roles = ["kafka-viewer"] }
  }
  sensitive = true
}

variable "topics" {
  type = map(object({
    partitions = number
    replicas   = optional(number, 3)
    config     = optional(map(string), {})
  }))
  default = {
    orders      = { partitions = 6 }
    payments    = { partitions = 6 }
    user-events = { partitions = 12 }
    audit-log   = { partitions = 3, config = { "retention.ms" = "604800000", "cleanup.policy" = "delete" } }
  }
}

variable "platform_nodes" {
  type = object({ instance_types = list(string), desired = number, min = number, max = number })
  default = { instance_types = ["m6i.large"], desired = 2, min = 2, max = 3 }
}

variable "data_nodes" {
  type = object({ instance_types = list(string), desired = number, min = number, max = number })
  default = { instance_types = ["m6i.xlarge"], desired = 3, min = 3, max = 5 }
}

variable "images" {
  description = "Container images (the ONLY things pulled from the network at apply time, by the nodes)"
  type        = map(string)
  default = {
    keycloak = "quay.io/keycloak/keycloak:26.3.0"
    kafka_ui = "ghcr.io/kafbat/kafka-ui:v1.5.0"
    # Strimzi / LBC images are pinned inside the vendored charts' values.yaml
  }
}

variable "kafka_version" {
  type    = string
  default = "3.9.0"
}
