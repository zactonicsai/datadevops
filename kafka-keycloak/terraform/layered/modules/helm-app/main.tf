resource "helm_release" "this" {
  name      = var.name
  namespace = var.namespace
  chart     = var.chart_path
  values    = var.values
  wait      = var.wait
  timeout   = var.timeout
  atomic    = false

  dynamic "set_sensitive" {
    for_each = nonsensitive(var.set_sensitive)
    content {
      name  = set_sensitive.key
      value = set_sensitive.value
    }
  }
}
