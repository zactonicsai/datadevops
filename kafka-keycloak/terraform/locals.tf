locals {
  port_suffix  = var.http_host_port == 80 ? "" : ":${var.http_host_port}"
  keycloak_host = "keycloak.${var.domain}"
  kafka_ui_host = "kafka-ui.${var.domain}"
  keycloak_url  = "http://${local.keycloak_host}${local.port_suffix}"
  kafka_ui_url  = "http://${local.kafka_ui_host}${local.port_suffix}"
  issuer_uri    = "${local.keycloak_url}/realms/kafka"

  # In-cluster name of the ingress controller; CoreDNS rewrites keycloak.<domain> to it
  ingress_svc_fqdn = "ingress-nginx-controller.ingress-nginx.svc.cluster.local"
}
