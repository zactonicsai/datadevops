resource "kubernetes_service_v1" "hello_web" {
  metadata {
    name      = "hello-web"
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  spec {
    selector = {
      app = "hello-web"
    }

    port {
      name        = "http"
      port        = 80
      target_port = "http"
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}
