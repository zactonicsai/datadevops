resource "kubernetes_namespace_v1" "test_tools" {
  metadata {
    name = "test-tools"
  }
}
