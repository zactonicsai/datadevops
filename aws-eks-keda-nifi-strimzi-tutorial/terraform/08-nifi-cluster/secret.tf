resource "random_password" "sensitive_properties_key" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "nifi" {
  metadata {
    name      = "nifi-secrets"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  data = {
    sensitive_properties_key = random_password.sensitive_properties_key.result
  }

  type = "Opaque"
}
