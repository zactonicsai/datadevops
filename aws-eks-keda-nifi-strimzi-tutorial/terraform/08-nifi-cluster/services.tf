resource "kubernetes_service_v1" "headless" {
  metadata {
    name      = "nifi-headless"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = true

    selector = {
      app = "nifi"
    }

    port {
      name        = "cluster"
      port        = 11443
      target_port = "cluster"
    }

    port {
      name        = "load-balance"
      port        = 6342
      target_port = "load-balance"
    }
  }
}

resource "kubernetes_service_v1" "nifi" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  spec {
    selector = {
      app = "nifi"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = "http"
    }

    type = "ClusterIP"
  }
}
