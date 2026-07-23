resource "helm_release" "this" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true

  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.chart_version

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  values = [
    file("${path.module}/../../helm/keda-values.yaml"),
  ]
}
