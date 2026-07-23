provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.cluster_name
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.cluster_name
  }
}
