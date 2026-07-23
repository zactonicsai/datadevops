resource "kubernetes_namespace_v1" "web" {
  metadata {
    name = "web"

    labels = {
      "app.kubernetes.io/part-of" = "eks-keda-tutorial"
    }
  }
}
