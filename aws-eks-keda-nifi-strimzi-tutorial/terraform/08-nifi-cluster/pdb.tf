resource "kubernetes_pod_disruption_budget_v1" "nifi" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        app = "nifi"
      }
    }
  }
}
