resource "kubernetes_cluster_role_v1" "tutorial_tester" {
  metadata {
    name = "tutorial-tester"
  }

  rule {
    api_groups = [""]
    resources = [
      "namespaces",
      "nodes",
      "pods",
      "pods/log",
      "services",
      "endpoints",
      "persistentvolumeclaims",
      "persistentvolumes",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["keda.sh"]
    resources  = ["scaledobjects"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["kafka.strimzi.io"]
    resources  = ["kafkas", "kafkanodepools", "kafkatopics"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "tutorial_tester" {
  metadata {
    name = "tutorial-tester"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.tutorial_tester.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "tutorial-testers"
    api_group = "rbac.authorization.k8s.io"
  }
}
