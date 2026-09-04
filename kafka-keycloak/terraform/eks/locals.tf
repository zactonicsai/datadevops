locals {
  tags = { Project = var.project, ManagedBy = "terraform" }

  keycloak_fqdn = "${var.keycloak_host}.${var.route53_zone_name}"
  kafka_ui_fqdn = "${var.kafka_ui_host}.${var.route53_zone_name}"
  keycloak_url  = "https://${local.keycloak_fqdn}"
  kafka_ui_url  = "https://${local.kafka_ui_fqdn}"
  issuer_uri    = "${local.keycloak_url}/realms/kafka"

  charts = {
    lbc      = "${path.module}/charts/aws-load-balancer-controller"
    strimzi  = "${path.module}/charts/strimzi-kafka-operator"
    kafka_ui = "${path.module}/charts/kafka-ui"
  }

  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}
