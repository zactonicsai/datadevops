variable "create" {
  type    = bool
  default = true
}
variable "existing_arn" {
  type    = string
  default = null
}
variable "name" { type = string }
variable "vpc_id" {
  type    = string
  default = null
}
variable "port" {
  type    = number
  default = 80
}
variable "protocol" {
  type    = string
  default = "HTTP"
}
variable "target_type" {
  description = "instance | ip | alb | lambda"
  type        = string
  default     = "instance"
}
variable "health_check" {
  type = object({
    path                = optional(string, "/")
    port                = optional(string, "traffic-port")
    protocol            = optional(string, "HTTP")
    matcher             = optional(string, "200-399")
    interval            = optional(number, 30)
    timeout             = optional(number, 5)
    healthy_threshold   = optional(number, 2)
    unhealthy_threshold = optional(number, 3)
  })
  default = {}
}
variable "stickiness" {
  type = object({
    enabled  = optional(bool, false)
    type     = optional(string, "lb_cookie")
    duration = optional(number, 86400)
  })
  default = {}
}
variable "deregistration_delay" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}
