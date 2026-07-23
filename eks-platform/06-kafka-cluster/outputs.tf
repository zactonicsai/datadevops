# =============================================================================
# 06-kafka-cluster/outputs.tf
# =============================================================================

output "kafka_cluster_name" {
  value       = var.kafka_cluster_name
  description = "Name of the Kafka cluster."
}

output "kafka_namespace" {
  value       = local.kafka_namespace
  description = "Namespace the Kafka cluster runs in."
}

output "bootstrap_servers_plain" {
  # ---- THE BOOTSTRAP ADDRESS: what every Kafka client needs ----
  #
  # Strimzi automatically creates a Service named
  # "<cluster-name>-kafka-bootstrap". A client connects here ONCE, receives
  # the full list of brokers and which partitions each one leads, and from
  # then on talks to brokers directly.
  #
  # That is why it is called "bootstrap" rather than "proxy": it is a
  # discovery endpoint, not a data path. You do not need to list every broker.
  value       = "${var.kafka_cluster_name}-kafka-bootstrap.${local.kafka_namespace}.svc.cluster.local:9092"
  description = "Plaintext bootstrap address for in-cluster clients. Use this in NiFi and the test script."
}

output "bootstrap_servers_tls" {
  value       = "${var.kafka_cluster_name}-kafka-bootstrap.${local.kafka_namespace}.svc.cluster.local:9093"
  description = "TLS bootstrap address. Requires the cluster CA cert; see the README."
}

output "test_topic_name" {
  value       = var.test_topic_name
  description = "Pre-created topic for verification tests."
}

output "expected_pod_count" {
  value       = var.controller_replicas + var.broker_replicas
  description = "Total Kafka pods that should reach Running: controllers + brokers."
}

output "cluster_ca_secret_name" {
  # Strimzi generates a CA and stores its public certificate here. A TLS
  # client needs this to verify the brokers. Extract it with:
  #   kubectl get secret <name> -n <ns> -o jsonpath='{.data.ca\.crt}' | base64 -d
  value       = "${var.kafka_cluster_name}-cluster-ca-cert"
  description = "Secret holding the cluster CA certificate, needed for TLS clients."
}

output "useful_commands" {
  value = {
    watch_pods = "kubectl get pods -n ${local.kafka_namespace} -w"

    # The Kafka resource reports overall health here. READY=True is the goal.
    check_cluster = "kubectl get kafka -n ${local.kafka_namespace}"

    check_nodepools = "kubectl get kafkanodepool -n ${local.kafka_namespace}"
    check_topics    = "kubectl get kafkatopic -n ${local.kafka_namespace}"

    # When the cluster will not become Ready, this is where the real answer is.
    describe_cluster = "kubectl describe kafka ${var.kafka_cluster_name} -n ${local.kafka_namespace}"

    # The operator log explains its reasoning step by step.
    operator_logs = "kubectl logs -n ${local.kafka_namespace} -l name=strimzi-cluster-operator --tail=100"

    # Produce a message interactively (type lines, Ctrl-D to finish).
    produce = "kubectl run -n ${local.kafka_namespace} kafka-producer -ti --rm --restart=Never --image=quay.io/strimzi/kafka:latest-kafka-${var.kafka_version} -- bin/kafka-console-producer.sh --bootstrap-server ${var.kafka_cluster_name}-kafka-bootstrap:9092 --topic ${var.test_topic_name}"

    # Read messages from the beginning of the topic.
    consume = "kubectl run -n ${local.kafka_namespace} kafka-consumer -ti --rm --restart=Never --image=quay.io/strimzi/kafka:latest-kafka-${var.kafka_version} -- bin/kafka-console-consumer.sh --bootstrap-server ${var.kafka_cluster_name}-kafka-bootstrap:9092 --topic ${var.test_topic_name} --from-beginning"
  }
  description = "Commands for inspecting and exercising the Kafka cluster."
}
