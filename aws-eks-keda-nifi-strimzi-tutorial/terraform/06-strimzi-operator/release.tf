resource "helm_release" "strimzi" {
  name      = "strimzi-cluster-operator"
  namespace = kubernetes_namespace_v1.strimzi.metadata[0].name

  repository = "oci://quay.io/strimzi-helm"
  chart      = "strimzi-kafka-operator"
  version    = var.chart_version

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    file("${path.module}/../../helm/strimzi-values.yaml"),
  ]

  depends_on = [kubernetes_namespace_v1.kafka]
}
