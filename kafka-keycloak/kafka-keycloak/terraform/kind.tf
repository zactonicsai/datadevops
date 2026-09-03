# One control-plane node. Host ports are mapped so the browser and the Python client
# can reach ingress (HTTP) and Kafka (bootstrap + broker 0) on localhost.
resource "kind_cluster" "this" {
  name            = var.cluster_name
  wait_for_ready  = true
  kubeconfig_path = "${path.module}/kubeconfig"

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Label the node so ingress-nginx (hostPort) is scheduled on it
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]

      extra_port_mappings {
        container_port = 80
        host_port      = var.http_host_port
      }
      extra_port_mappings {
        container_port = 30092             # Kafka bootstrap NodePort
        host_port      = var.kafka_host_port
      }
      extra_port_mappings {
        container_port = 30093             # Kafka broker-0 NodePort
        host_port      = var.kafka_host_port + 1
      }
    }
  }
}
