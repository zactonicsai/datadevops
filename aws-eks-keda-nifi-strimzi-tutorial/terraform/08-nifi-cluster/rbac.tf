resource "kubernetes_service_account_v1" "nifi" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }
}

resource "kubernetes_role_v1" "nifi_leader_election" {
  metadata {
    name      = "nifi-leader-election"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["create", "get", "list", "watch", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "nifi_leader_election" {
  metadata {
    name      = "nifi-leader-election"
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.nifi_leader_election.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.nifi.metadata[0].name
    namespace = kubernetes_namespace_v1.nifi.metadata[0].name
  }
}
