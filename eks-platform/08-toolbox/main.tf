# =============================================================================
# 08-toolbox/main.tf   --   A LINUX POD THAT CAN TALK TO EVERYTHING
# =============================================================================
# WHAT THIS IS FOR
#
# You asked for "a linux node that can talk to all the other nodes pods in
# cluster to test". This is that: a long-running pod with networking and
# diagnostic tools installed, sitting inside the cluster's network, from which
# you can reach every service directly.
#
# WHY THIS IS GENUINELY USEFUL AND NOT JUST A CONVENIENCE
#
# From your laptop you are OUTSIDE the cluster. Internal service DNS names like
# "demo-kafka-kafka-bootstrap.kafka.svc.cluster.local" do not resolve. ClusterIP
# services have no route from outside. So to test the things that matter you
# would otherwise need a port-forward per service, each in its own terminal,
# each masking the real DNS name behind localhost.
#
# A pod inside the cluster has none of those problems. It sees exactly what
# your applications see. When a test from here fails, the failure is real,
# not an artefact of tunnelling.
#
# WHY A DEPLOYMENT AND NOT A BARE POD
#
# A bare pod that dies is gone. A Deployment restarts it. Since the entire
# point is to have a reliable place to run diagnostics from -- often precisely
# when things are broken -- it should not be the first thing to disappear.
#
# ALTERNATIVES WORTH KNOWING ABOUT
#
#   kubectl run -ti --rm ...     - spins up a throwaway pod. Fine for a quick
#                                  check, but you reinstall your tools every
#                                  time and lose any scripts you wrote.
#   kubectl debug <pod>          - attaches an ephemeral debug container to an
#                                  EXISTING pod, sharing its network namespace.
#                                  Superb for "why can THIS pod not reach that
#                                  service", because you are literally inside
#                                  the affected pod's network view.
#   A persistent toolbox (this)  - best when you want a stable base with your
#                                  own scripts mounted, which is what the test
#                                  script in tests/ needs.
#
# The three complement each other. This tutorial uses the third because our
# verification script needs somewhere consistent to live.
# =============================================================================

locals {
  # Pull the real addresses from every previous layer. Nothing is typed twice,
  # so a rename in an earlier layer flows through automatically.
  webapp_namespace = data.terraform_remote_state.webapp.outputs.namespace
  webapp_dns       = data.terraform_remote_state.webapp.outputs.internal_dns_name

  kafka_namespace  = data.terraform_remote_state.kafka.outputs.kafka_namespace
  kafka_bootstrap  = data.terraform_remote_state.kafka.outputs.bootstrap_servers_plain
  kafka_topic      = data.terraform_remote_state.kafka.outputs.test_topic_name
  kafka_cluster    = data.terraform_remote_state.kafka.outputs.kafka_cluster_name

  nifi_namespace = data.terraform_remote_state.nifi.outputs.nifi_namespace
  nifi_dns       = data.terraform_remote_state.nifi.outputs.nifi_service_dns
}

# -----------------------------------------------------------------------------
# NAMESPACE
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "toolbox" {
  metadata {
    name = var.toolbox_namespace

    labels = {
      # "baseline" rather than "restricted", and here the reason is specific
      # and worth stating: some network diagnostic tools need capabilities
      # that "restricted" forbids. ping, for instance, needs NET_RAW to craft
      # ICMP packets.
      #
      # We still drop every capability we do not need -- see the container's
      # security context below, where NET_RAW is the ONLY one added back.
      # That is the principle: grant the specific privilege the job requires,
      # not a blanket relaxation.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"

      "app.kubernetes.io/part-of" = "diagnostics"
    }
  }
}

# -----------------------------------------------------------------------------
# SERVICE ACCOUNT AND RBAC
# -----------------------------------------------------------------------------
# BACKGROUND: WHAT IS A SERVICE ACCOUNT?
#
# Every pod runs as some Kubernetes identity. If you do not specify one, it
# gets the namespace's "default" service account, which by design has almost no
# permissions.
#
# Our toolbox needs to READ things across namespaces so the test script can
# check "are all Kafka pods running?" without a human running kubectl.
#
# THE PRINCIPLE APPLIED HERE IS LEAST PRIVILEGE: read-only, and only the
# resource types the tests actually inspect. Granting cluster-admin to a
# debugging pod is a genuinely common and genuinely bad habit -- that pod
# becomes a privilege-escalation stepping stone for anyone who compromises it.
resource "kubernetes_service_account" "toolbox" {
  metadata {
    name      = "toolbox"
    namespace = kubernetes_namespace.toolbox.metadata[0].name
  }

  # By default Kubernetes mounts an API token into the pod. We want that here,
  # because the test script uses kubectl. For a pod that never calls the API,
  # setting automount_service_account_token = false is the safer default.
  automount_service_account_token = true
}

# A ClusterRole defines permissions. On its own it grants nothing; it is a
# reusable definition that must be BOUND to a subject to take effect.
resource "kubernetes_cluster_role" "toolbox_reader" {
  metadata {
    name = "toolbox-reader"
  }

  # ---- Core API group ----
  rule {
    # "" (empty string) is the CORE api group: pods, services, nodes,
    # endpoints, configmaps. Its name being empty is a historical quirk.
    api_groups = [""]
    resources  = ["pods", "services", "endpoints", "nodes", "namespaces", "persistentvolumeclaims"]

    # READ ONLY. No create, no update, no delete, no patch.
    # "get" reads one named object, "list" reads all of them, "watch" streams
    # changes. All three are needed for kubectl to work comfortably.
    verbs = ["get", "list", "watch"]
  }

  # ---- Pod logs, a separate subresource ----
  rule {
    api_groups = [""]
    # Note "pods/log", not "pods". Kubernetes treats logs as a subresource
    # with its own permission, which is why granting "pods" alone still leaves
    # `kubectl logs` refused -- a frequent and confusing RBAC gotcha.
    resources = ["pods/log"]
    verbs     = ["get", "list"]
  }

  # ---- Workload objects ----
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }

  # ---- Autoscaling, so the test script can verify KEDA's HPA ----
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }

  # ---- KEDA's own custom resources ----
  rule {
    api_groups = ["keda.sh"]
    resources  = ["scaledobjects", "scaledjobs", "triggerauthentications"]
    verbs      = ["get", "list", "watch"]
  }

  # ---- Strimzi's custom resources ----
  rule {
    api_groups = ["kafka.strimzi.io"]
    resources  = ["kafkas", "kafkanodepools", "kafkatopics", "kafkausers"]
    verbs      = ["get", "list", "watch"]
  }

  # ---- Metrics, so `kubectl top` works from inside the toolbox ----
  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list"]
  }
}

# The binding is what actually grants the role to our service account.
# Role + Subject + Binding is the three-part structure of Kubernetes RBAC;
# missing the binding is the most common reason permissions "do not work".
resource "kubernetes_cluster_role_binding" "toolbox_reader" {
  metadata {
    name = "toolbox-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.toolbox_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.toolbox.metadata[0].name
    namespace = kubernetes_namespace.toolbox.metadata[0].name
  }
}

# -----------------------------------------------------------------------------
# CONFIGMAP: environment facts and the connectivity test script
# -----------------------------------------------------------------------------
# Putting the addresses in a ConfigMap means the test script does not hard-code
# anything. Rename a service in an earlier layer and this updates automatically.
resource "kubernetes_config_map" "toolbox_env" {
  metadata {
    name      = "toolbox-env"
    namespace = kubernetes_namespace.toolbox.metadata[0].name
  }

  data = {
    # Sourced by the shell on login (see the Deployment's bashrc mount).
    "cluster-env.sh" = <<-ENVSH
      # Addresses of everything in this platform, resolved by Terraform.
      # Source this file to get them as shell variables:
      #     . /etc/toolbox/cluster-env.sh

      export WEBAPP_NAMESPACE="${local.webapp_namespace}"
      export WEBAPP_URL="http://${local.webapp_dns}"

      export KAFKA_NAMESPACE="${local.kafka_namespace}"
      export KAFKA_CLUSTER="${local.kafka_cluster}"
      export KAFKA_BOOTSTRAP="${local.kafka_bootstrap}"
      export KAFKA_TOPIC="${local.kafka_topic}"

      export NIFI_NAMESPACE="${local.nifi_namespace}"
      export NIFI_URL="https://${local.nifi_dns}"
    ENVSH
  }
}

# -----------------------------------------------------------------------------
# THE TOOLBOX DEPLOYMENT
# -----------------------------------------------------------------------------
resource "kubernetes_deployment" "toolbox" {
  metadata {
    name      = "toolbox"
    namespace = kubernetes_namespace.toolbox.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "toolbox"
      "app.kubernetes.io/component"  = "diagnostics"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # One is enough. This is a place to stand, not a service.
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "toolbox"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "toolbox"
        }

        annotations = {
          # Restart the pod when the environment facts change, so the toolbox
          # never serves stale addresses.
          "checksum/env" = sha256(jsonencode(kubernetes_config_map.toolbox_env.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account.toolbox.metadata[0].name

        container {
          name = "toolbox"

          # ---- WHY THIS IMAGE ----
          # nicolaka/netshoot is the de facto standard Kubernetes network
          # debugging image. It bundles essentially every tool you would want:
          #   curl, wget          - HTTP testing
          #   dig, nslookup, host - DNS resolution
          #   ping, traceroute    - reachability (needs NET_RAW, see below)
          #   nc (netcat)         - raw TCP port testing, the workhorse
          #   tcpdump, termshark  - packet capture
          #   iperf3              - bandwidth measurement
          #   ss, netstat, iproute2 - socket and routing inspection
          #   jq                  - JSON parsing, essential for API responses
          #   openssl             - TLS inspection
          #
          # Building this yourself would take real effort and you would still
          # miss something at the worst moment.
          #
          # SECURITY NOTE, said plainly: a pod containing tcpdump and netcat is
          # a capable foothold if compromised. That is the price of a useful
          # diagnostic tool. Mitigations we apply: read-only RBAC, a
          # non-privileged security context, and a distinct namespace. In a
          # production cluster you would additionally scope it with a
          # NetworkPolicy and delete it when not actively debugging.
          image             = "nicolaka/netshoot:${var.netshoot_version}"
          image_pull_policy = "IfNotPresent"

          # Keep the container alive. Without a long-running process the
          # container exits immediately and the Deployment restarts it forever.
          # `sleep infinity` is the idiomatic way to say "just stay up".
          command = ["/bin/bash", "-c"]
          args    = ["sleep infinity"]

          # ---- Environment: addresses available without sourcing anything ----
          env {
            name  = "KAFKA_BOOTSTRAP"
            value = local.kafka_bootstrap
          }

          env {
            name  = "KAFKA_TOPIC"
            value = local.kafka_topic
          }

          env {
            name  = "WEBAPP_URL"
            value = "http://${local.webapp_dns}"
          }

          env {
            name  = "NIFI_URL"
            value = "https://${local.nifi_dns}"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              # Room for tcpdump buffers and a package install or two.
              memory = "512Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false

            # NOT read-only. Deliberately so, and worth explaining rather than
            # silently omitting: a diagnostic pod's whole value is that you can
            # install an extra tool, write a script, or dump a capture file
            # while investigating. A read-only root filesystem defeats that.
            #
            # This is a considered trade-off, not an oversight. Everywhere else
            # in this project the root filesystem IS read-only.
            read_only_root_filesystem = false

            capabilities {
              # Drop everything first...
              drop = ["ALL"]

              # ...then add back exactly one. NET_RAW allows crafting raw
              # packets, which ping and traceroute require. Nothing else is
              # granted.
              #
              # This drop-all-then-add-one pattern is the right way to handle
              # capabilities. The lazy alternative -- running privileged --
              # would grant roughly forty capabilities to get this one.
              add = ["NET_RAW"]
            }
          }

          volume_mount {
            name       = "toolbox-env"
            mount_path = "/etc/toolbox"
            read_only  = true
          }
        }

        volume {
          name = "toolbox-env"
          config_map {
            name = kubernetes_config_map.toolbox_env.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map.toolbox_env,
    kubernetes_cluster_role_binding.toolbox_reader,
  ]
}
