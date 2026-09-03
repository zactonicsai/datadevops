resource "kubernetes_namespace_v1" "ingress" {
  metadata { name = "ingress-nginx" }
  depends_on = [kind_cluster.this]
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  namespace  = kubernetes_namespace_v1.ingress.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.versions["ingress_nginx_chart"]
  wait       = true
  timeout    = 600

  values = [yamlencode({
    controller = {
      hostPort               = { enabled = true }
      service                = { type = "NodePort" }
      nodeSelector           = { "ingress-ready" = "true" }
      watchIngressWithoutClass = true
      ingressClassResource   = { default = true }
      tolerations = [{
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Equal"
        effect   = "NoSchedule"
      }]
      admissionWebhooks = { enabled = false }
    }
  })]
}

# CoreDNS rewrite: inside the cluster, keycloak.<domain> would resolve to 127.0.0.1 (useless
# from a pod). Rewrite it to the ingress controller so Kafka UI reaches Keycloak by the
# SAME hostname the browser uses -> OIDC issuer matches.
resource "kubernetes_config_map_v1_data" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }
  force = true
  data = {
    Corefile = <<-EOT
      .:53 {
          errors
          health {
             lameduck 5s
          }
          ready
          rewrite name ${local.keycloak_host} ${local.ingress_svc_fqdn}
          rewrite name ${local.kafka_ui_host} ${local.ingress_svc_fqdn}
          kubernetes cluster.local in-addr.arpa ip6.arpa {
             pods insecure
             fallthrough in-addr.arpa ip6.arpa
             ttl 30
          }
          prometheus :9153
          forward . /etc/resolv.conf {
             max_concurrency 1000
          }
          cache 30
          loop
          reload
          loadbalance
      }
    EOT
  }
  depends_on = [helm_release.ingress_nginx]
}
