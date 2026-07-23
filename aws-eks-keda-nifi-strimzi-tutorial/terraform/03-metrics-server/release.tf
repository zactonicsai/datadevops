resource "helm_release" "this" {
  name             = "metrics-server"
  namespace        = "kube-system"
  create_namespace = true

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_version

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    file("${path.module}/../../helm/metrics-server-values.yaml"),
  ]
}
