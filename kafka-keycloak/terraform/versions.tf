terraform {
  required_version = ">= 1.5"
  required_providers {
    kind       = { source = "tehcyx/kind", version = "~> 0.5" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    kubectl    = { source = "alekc/kubectl", version = "~> 2.1" }
  }
}
