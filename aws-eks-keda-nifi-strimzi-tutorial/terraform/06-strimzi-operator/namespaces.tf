resource "kubernetes_namespace_v1" "kafka" {
  metadata {
    name = "kafka"
  }
}

resource "kubernetes_namespace_v1" "strimzi" {
  metadata {
    name = "strimzi-system"
  }
}
