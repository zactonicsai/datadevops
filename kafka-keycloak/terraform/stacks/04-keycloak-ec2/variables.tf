variable "dns" {
  type = object({
    zone_name = string # existing public hosted zone
    host      = optional(string, "auth")
  })
}

variable "keycloak" {
  type = object({
    version        = optional(string, "26.3.0")
    instance_type  = optional(string, "t3.medium")
    instance_count = optional(number, 1) # >1 clusters automatically via jdbc-ping on port 7800
    key_name       = optional(string)
    admin_user     = optional(string, "admin")
    realm_name     = optional(string, "kafka")
    kafka_ui_url   = string # e.g. https://kafka-ui.example.com  (redirect URI for the client)
  })
}

variable "keycloak_admin_password" {
  type      = string
  sensitive = true
}
variable "db_password" {
  type      = string
  sensitive = true
}
variable "kafka_ui_client_secret" {
  type      = string
  sensitive = true
}
variable "test_users" {
  type = map(object({
    password = string
    roles    = list(string)
  }))
  default   = {}
  sensitive = true
}

# ---- every dependency below can be created or pre-provided ----
variable "subnets" {
  description = "null = from network stack"
  type = object({
    lb_subnet_ids       = optional(list(string))
    instance_subnet_ids = optional(list(string))
    db_subnet_ids       = optional(list(string))
  })
  default = {}
}
variable "security_groups" {
  type = object({
    lb       = optional(object({ create = optional(bool, true), existing_id = optional(string) }), {})
    instance = optional(object({ create = optional(bool, true), existing_id = optional(string) }), {})
    db       = optional(object({ create = optional(bool, true), existing_id = optional(string) }), {})
  })
  default = {}
}
variable "lb_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
variable "lb_internal" {
  type    = bool
  default = false
}
variable "instance_role" {
  type = object({
    create             = optional(bool, true)
    existing_role_name = optional(string)
  })
  default = {}
}
variable "launch_template" {
  type = object({
    create      = optional(bool, true)
    existing_id = optional(string)
    ami_id      = optional(string) # null = latest Amazon Linux 2023
  })
  default = {}
}
variable "target_group" {
  type = object({
    create       = optional(bool, true)
    existing_arn = optional(string)
  })
  default = {}
}
variable "load_balancer" {
  type = object({
    create                      = optional(bool, true)
    existing_arn                = optional(string)
    existing_https_listener_arn = optional(string)
  })
  default = {}
}
variable "certificate" {
  type = object({
    create       = optional(bool, true)
    existing_arn = optional(string)
  })
  default = {}
}
variable "database" {
  type = object({
    create         = optional(bool, true)
    instance_class = optional(string, "db.t4g.small")
    multi_az       = optional(bool, false)
    existing = optional(object({
      address  = string
      port     = optional(number, 5432)
      db_name  = string
      username = string
    }))
  })
  default = {}
}
