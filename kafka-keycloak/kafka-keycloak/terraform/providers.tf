provider "kind" {}

provider "kubernetes" {
  config_path = kind_cluster.this.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = kind_cluster.this.kubeconfig_path
  }
}

provider "kubectl" {
  config_path      = kind_cluster.this.kubeconfig_path
  load_config_file = true
}
