# Simple Linux hello-world pod, managed by a Deployment
resource "kubernetes_deployment_v1" "hello" {
  metadata {
    name = "hello-world"
    labels = { app = "hello-world" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "hello-world" }
    }

    template {
      metadata {
        labels = { app = "hello-world" }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"

          port {
            container_port = 80
          }
        }
      }
    }
  }

  depends_on = [module.eks]
}

# Public load balancer so you can hit it from a browser
resource "kubernetes_service_v1" "hello" {
  metadata {
    name = "hello-world"
  }

  spec {
    selector = { app = "hello-world" }
    type     = "LoadBalancer"

    port {
      port        = 80
      target_port = 80
    }
  }
}
