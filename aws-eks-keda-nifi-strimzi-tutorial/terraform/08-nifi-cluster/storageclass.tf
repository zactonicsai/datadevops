resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3-nifi"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = var.retain_application_volumes ? "Retain" : "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
