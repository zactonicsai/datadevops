resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.name
    labels = var.labels
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  count = length(var.resource_quota) > 0 ? 1 : 0
  metadata {
    name      = "${var.name}-quota"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec { hard = var.resource_quota }
}
