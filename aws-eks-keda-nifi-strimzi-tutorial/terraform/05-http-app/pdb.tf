resource "kubernetes_pod_disruption_budget_v1" "server" {
  for_each = local.servers

  metadata {
    name      = each.value.name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        app    = "hello-web"
        server = each.key
      }
    }
  }
}
