# =============================================================================
# 05-strimzi-operator/main.tf   --   THE STRIMZI KAFKA OPERATOR
# =============================================================================
# BACKGROUND: WHAT IS KAFKA?
#
# Apache Kafka is a distributed commit log. The mental model:
#
#   A TOPIC is like a shared notebook. Producers append messages to the end.
#   Consumers read from wherever they left off, at their own pace. Crucially,
#   reading does NOT remove the message -- ten different consumers can each
#   read the same message independently, and a new consumer can go back and
#   replay history from the beginning.
#
# That "reading does not consume" property is what separates Kafka from a
# traditional message queue like RabbitMQ or SQS, and it is why Kafka became
# the backbone of event-driven architectures.
#
# A topic is split into PARTITIONS, which is where the scaling comes from.
# Partitions are spread across BROKERS (the servers). More partitions means
# more consumers can work in parallel. Order is guaranteed WITHIN a partition,
# never across them -- a detail that surprises people in production.
#
# -----------------------------------------------------------------------------
# BACKGROUND: WHAT IS AN OPERATOR, AND WHY DOES KAFKA NEED ONE?
#
# Running Kafka by hand on Kubernetes is genuinely difficult: certificates
# between brokers, rolling restarts that must never take two brokers down at
# once, storage that must follow a broker if it moves, cluster membership,
# topic management. Getting one of these wrong loses data.
#
# An OPERATOR is a program that runs inside your cluster and encodes an
# expert's operational knowledge as software. It watches for custom resources
# and continuously reconciles reality toward them.
#
# So instead of writing hundreds of lines of StatefulSet YAML, you write:
#
#     kind: Kafka
#     spec:
#       kafka:
#         version: 4.2.0
#
# and Strimzi does everything else -- and keeps doing it, forever, including
# during upgrades and failures.
#
# -----------------------------------------------------------------------------
# A NOTE ON KRaft (this matters if you read older tutorials)
#
# Kafka historically needed a separate Apache ZooKeeper cluster to track
# cluster metadata. That meant running and operating TWO distributed systems.
#
# KRaft (Kafka Raft) moves metadata management inside Kafka itself. ZooKeeper
# support was REMOVED in Kafka 4.0, and Strimzi dropped it after 0.45.
# Everything here is KRaft-only. If you find a tutorial mentioning ZooKeeper,
# it predates 2025 and its YAML will not work with a current operator.
#
# In KRaft, nodes take one or both of two roles:
#   CONTROLLER - votes on cluster metadata. Needs an ODD number (3 is standard)
#                so a majority can always be reached.
#   BROKER     - stores partition data and serves clients.
#
# -----------------------------------------------------------------------------
# IMPORTANT VERSION NOTE FOR STRIMZI 1.0
#
# Strimzi 1.0.0 REMOVED the old v1beta2 API. Custom resources must now use
# apiVersion "kafka.strimzi.io/v1". Almost every blog post and Stack Overflow
# answer online still shows v1beta2, and those manifests will be REJECTED.
# Layer 06 uses v1 throughout.
# =============================================================================

# -----------------------------------------------------------------------------
# NAMESPACE
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "kafka" {
  metadata {
    name = var.kafka_namespace

    labels = {
      # NOTE: "baseline", not "restricted".
      #
      # Kafka broker containers need to adjust some filesystem ownership on
      # their data volumes at startup, which the strictest profile blocks.
      # "baseline" still prevents the dangerous things -- privileged
      # containers, host networking, host path mounts -- while allowing the
      # operator to work.
      #
      # This is a real and common trade-off: security profiles must fit the
      # workload. Forcing "restricted" here produces pods stuck in
      # CreateContainerConfigError, and the honest answer is to use the
      # strictest profile that actually works rather than the strictest one
      # that exists.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"

      "app.kubernetes.io/part-of" = "kafka"
    }
  }
}

# -----------------------------------------------------------------------------
# THE STRIMZI CLUSTER OPERATOR
# -----------------------------------------------------------------------------
resource "helm_release" "strimzi" {
  name = "strimzi-kafka-operator"

  # Strimzi's own chart repository.
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"

  # Strimzi 1.0.0 -- the first stable major release, from April 2026.
  # It supports Kafka 4.1.x and 4.2.0, and only the v1 CRD API.
  version = var.strimzi_version

  namespace = kubernetes_namespace.kafka.metadata[0].name

  wait    = true
  timeout = 900

  atomic          = true
  cleanup_on_fail = true

  values = [
    yamlencode({
      # ---- WHICH NAMESPACES DOES THE OPERATOR WATCH? ----
      # Three options, and the choice matters:
      #
      #   watchNamespaces: []      - watch ONLY its own namespace (our choice)
      #   watchNamespaces: [a, b]  - watch a specific list
      #   watchAnyNamespace: true  - watch the whole cluster
      #
      # We keep it scoped to one namespace. That means the operator needs only
      # namespace-level Roles rather than cluster-wide ClusterRoles, which is
      # the principle of least privilege in action. Cluster-wide watching is
      # convenient for a platform team running Kafka for many tenants, and is
      # unnecessary risk for a single deployment.
      watchNamespaces   = []
      watchAnyNamespace = false

      # One operator replica. Strimzi uses leader election, so extra replicas
      # sit idle as failover spares rather than sharing work.
      replicas = 1

      resources = {
        requests = {
          cpu    = "200m"
          memory = "384Mi"
        }
        limits = {
          # The operator is a Java application. Java's garbage collector will
          # happily expand to fill whatever it is given, so a memory limit is
          # not optional here -- without one it can starve the node.
          memory = "768Mi"
        }
      }

      # ---- Logging ----
      # INFO is right for normal running. Switch to DEBUG when a Kafka
      # resource refuses to become Ready and the events are not telling you
      # enough; the operator log then explains its reasoning step by step.
      logLevel = "INFO"

      # ---- Full reconciliation interval (milliseconds) ----
      # The operator reacts to changes immediately via watches. Separately, it
      # does a full sweep on this interval to catch anything a missed watch
      # event let slip. 120000 ms = 2 minutes.
      fullReconciliationIntervalMs = 120000

      # ---- Feature gates ----
      # Strimzi ships experimental features behind named gates. We enable none,
      # which is the right choice unless you specifically need one. Defaults
      # are what the maintainers test most heavily.
      featureGates = ""
    })
  ]

  depends_on = [kubernetes_namespace.kafka]
}

# -----------------------------------------------------------------------------
# WAIT FOR THE CRDs TO BE FULLY REGISTERED
# -----------------------------------------------------------------------------
# THE PROBLEM THIS SOLVES, which is subtle and worth understanding:
#
# Helm reports success once the operator DEPLOYMENT is ready. But the CRDs it
# installed take a few more seconds to be fully served by the Kubernetes API
# server (the API discovery cache has to refresh).
#
# Layer 06 uses kubernetes_manifest, which validates against the live schema
# AT PLAN TIME. If it plans during that window, you get:
#     "no matches for kind Kafka in group kafka.strimzi.io"
#
# This is a race, so it fails intermittently -- the worst kind of bug, because
# re-running appears to "fix" it.
#
# The time_sleep resource is a small, honest guard against that race. It is not
# elegant; a truly robust solution would poll the API. But it is simple,
# reliable in practice, and clearly documented, which beats a clever solution
# nobody understands.
resource "time_sleep" "wait_for_crds" {
  depends_on = [helm_release.strimzi]

  create_duration = "30s"
}
