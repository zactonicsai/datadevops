resource "kubernetes_namespace_v1" "nifi" {
  metadata {
    name = "nifi"
  }
}
