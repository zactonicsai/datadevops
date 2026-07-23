# =============================================================================
# 07-nifi/main.tf   --   APACHE NIFI, TWO PODS
# =============================================================================
# BACKGROUND: WHAT IS NIFI?
#
# Apache NiFi is a visual dataflow tool. You drag "processors" onto a canvas
# and draw arrows between them, and data flows along those arrows. A typical
# flow might be: read files from S3 -> parse JSON -> filter out bad records ->
# write the good ones to Kafka.
#
# The point is that a data engineer builds and changes pipelines in a browser
# rather than by writing and deploying code. NiFi also tracks the complete
# lineage of every record (where it came from, every transformation applied),
# which is why it is popular in regulated industries.
#
# NiFi is the natural companion to Kafka in this stack: layer 06 gives you a
# message bus, and NiFi gives you a way to get data into and out of it without
# writing producers and consumers by hand.
#
# =============================================================================
# WHY A HAND-WRITTEN STATEFULSET RATHER THAN A HELM CHART
# =============================================================================
# Every other component in this project is installed from an official Helm
# chart. NiFi is the exception, deliberately.
#
# Apache does not publish an official NiFi Helm chart. The community charts
# that exist (cetic/nifi being the best known) have gone largely unmaintained
# and lag well behind the current NiFi 2.x line -- several still assume NiFi 1
# and ZooKeeper-based clustering.
#
# So the choice is between:
#   (a) depending on a stale third-party chart that may not work with 2.10, or
#   (b) writing ~200 lines of StatefulSet that we fully control and understand.
#
# We choose (b). It is more code, but it is pinned, current, and every line is
# explainable -- which matters more in a tutorial than brevity does. This is
# also a realistic lesson: sometimes the honest answer is that no good
# off-the-shelf package exists and you write it yourself.
#
# =============================================================================
# WHY A STATEFULSET AND NOT A DEPLOYMENT
# =============================================================================
# Layer 04's web app used a Deployment. NiFi uses a StatefulSet. The difference
# matters and is worth understanding.
#
#   DEPLOYMENT           - pods are interchangeable. Random names
#                          (hello-web-7d4f8b-x9k2p). Any pod can be replaced by
#                          any other. Right for stateless work.
#
#   STATEFULSET          - pods have STABLE IDENTITY. Predictable names
#                          (nifi-0, nifi-1). Each keeps its OWN persistent
#                          volume across restarts, and nifi-0 always gets the
#                          volume that belonged to nifi-0. They start in order
#                          and stop in reverse order.
#
# NiFi needs the StatefulSet properties because each node holds queued data in
# its own repositories on disk. If a NiFi pod restarted and attached to a
# different volume, it would lose track of in-flight data.
#
# =============================================================================
# SIZING: WHY THESE NUMBERS
# =============================================================================
# NiFi is a JVM application and is memory-hungry by nature -- it buffers
# flowfile content in memory and maintains several on-disk repositories.
#
#   Container memory request: 2 GiB, limit 3 GiB
#   JVM heap:                 1 GiB (-Xms1g -Xmx1g)
#
# WHY IS THE HEAP ONLY A THIRD OF THE LIMIT? Two reasons:
#   1. The JVM needs substantial off-heap memory beyond the heap: metaspace,
#      thread stacks, direct byte buffers, code cache. Sizing the heap equal
#      to the container limit is the classic way to get OOMKilled by the
#      kernel even though the JVM thinks it has room.
#   2. NiFi's provenance and content repositories benefit from OS page cache,
#      the same argument as Kafka.
#
# A heap around 30-50% of the container limit is the safe rule for JVM
# workloads in containers.
#
#   CPU request 500m, limit 2000m. NiFi is bursty: mostly idle, then briefly
#   busy when a flow runs. A low request with a high limit lets it burst
#   without reserving capacity it usually does not need.
#
#   Storage: 10 GiB per pod, holding the flowfile, content, provenance and
#   database repositories. In production these are often separate volumes on
#   separate disks, because provenance writes are heavy and can starve content
#   writes. One volume is fine at demo scale.
#
# TWO PODS, as requested. Note honestly: these are two INDEPENDENT NiFi
# instances, not a clustered NiFi. See the note on clustering at the bottom of
# this file.
# =============================================================================

locals {
  # Read the Kafka bootstrap address so NiFi is pre-configured to talk to it.
  # This is a concrete example of why layered Terraform beats copy-pasting:
  # the address is derived, never typed twice.
  kafka_bootstrap = data.terraform_remote_state.kafka.outputs.bootstrap_servers_plain
  kafka_topic     = data.terraform_remote_state.kafka.outputs.test_topic_name
}

# -----------------------------------------------------------------------------
# NAMESPACE
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "nifi" {
  metadata {
    name = var.nifi_namespace

    labels = {
      # "baseline" rather than "restricted".
      #
      # The official apache/nifi image runs its entrypoint as a non-root user
      # but performs some filesystem setup at startup that the strictest
      # profile blocks. Baseline still prevents privileged containers, host
      # networking and host path mounts -- the things that actually matter.
      #
      # Same honest trade-off as the Kafka namespace: use the strictest
      # profile that works, not the strictest that exists.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"

      "app.kubernetes.io/part-of" = "dataflow"
    }
  }
}

# -----------------------------------------------------------------------------
# SECRET: the NiFi single-user login
# -----------------------------------------------------------------------------
# NiFi 2.x refuses to start with HTTP; it requires HTTPS and authentication.
# The simplest supported mode is "single user", where one username and password
# are supplied via environment variables.
#
# WHY A RANDOM PASSWORD RATHER THAN A HARD-CODED ONE:
# A hard-coded password in Terraform code ends up in git, forever, in the
# history even after you "remove" it. Generating one means nothing sensitive
# is ever written in the repository.
#
# BE CLEAR ABOUT THE LIMITATION: the generated password IS stored in plain text
# in terraform.tfstate. With local state that means it is a plain file on your
# disk. This is exactly why production uses an encrypted remote backend, and
# why .gitignore blocks state files. For real secrets, use AWS Secrets Manager
# or External Secrets Operator instead.
resource "random_password" "nifi_admin" {
  # NiFi requires at least 12 characters and rejects shorter ones at startup
  # with a message that is not especially clear. 24 is comfortably safe.
  length = 24

  # Avoid characters that need shell escaping. The password is passed through
  # environment variables and occasionally through curl commands in tests;
  # quoting bugs here waste a lot of time for no security benefit, since
  # length already provides the entropy.
  special          = true
  override_special = "-_=+"
}

resource "kubernetes_secret" "nifi_credentials" {
  metadata {
    name      = "nifi-credentials"
    namespace = kubernetes_namespace.nifi.metadata[0].name
  }

  # Kubernetes base64-encodes these automatically; we supply plain values.
  data = {
    username = var.nifi_username
    password = random_password.nifi_admin.result
  }

  type = "Opaque"
}

# -----------------------------------------------------------------------------
# HEADLESS SERVICE: stable per-pod DNS names
# -----------------------------------------------------------------------------
# A StatefulSet REQUIRES a headless service. "Headless" means clusterIP: None
# -- no virtual IP and no load balancing.
#
# What it gives you instead is a DNS record PER POD:
#     nifi-0.nifi-headless.nifi.svc.cluster.local
#     nifi-1.nifi-headless.nifi.svc.cluster.local
#
# That is the whole point of a StatefulSet: you can address one specific
# instance rather than "whichever one the load balancer picks". Essential for
# clustered software where members must find each other by name.
resource "kubernetes_service" "nifi_headless" {
  metadata {
    name      = "nifi-headless"
    namespace = kubernetes_namespace.nifi.metadata[0].name

    labels = {
      "app.kubernetes.io/name" = "nifi"
    }
  }

  spec {
    # This single line is what makes it headless.
    cluster_ip = "None"

    selector = {
      "app.kubernetes.io/name" = "nifi"
    }

    port {
      name        = "https"
      port        = 8443
      target_port = 8443
      protocol    = "TCP"
    }

    port {
      # NiFi's site-to-site port, used when NiFi instances exchange data with
      # each other. Declared for completeness.
      name        = "site-to-site"
      port        = 10443
      target_port = 10443
      protocol    = "TCP"
    }

    # ---- A SUBTLE BUT IMPORTANT SETTING ----
    # By default a pod is only added to a Service's DNS once it is READY.
    # NiFi takes 60-120 seconds to start, and during that window the DNS name
    # does not resolve at all.
    #
    # Setting this to false publishes the DNS record immediately, before the
    # pod is ready. For clustered software that must resolve peers DURING
    # startup, this is the difference between forming a cluster and deadlocking
    # while every member waits for the others to appear.
    publish_not_ready_addresses = true
  }
}

# -----------------------------------------------------------------------------
# CLUSTERIP SERVICE: one address for the UI
# -----------------------------------------------------------------------------
# The headless service addresses individual pods. This one load balances across
# both, which is what you want for reaching the web UI.
resource "kubernetes_service" "nifi_ui" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace.nifi.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = "nifi"
      "app.kubernetes.io/component" = "ui"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "nifi"
    }

    port {
      name        = "https"
      port        = 8443
      target_port = 8443
      protocol    = "TCP"
    }

    # ---- SESSION AFFINITY, and why it is right HERE specifically ----
    # In layer 04 we set this to "None" and argued against affinity. NiFi is
    # the opposite case, and it is worth seeing why.
    #
    # Our two NiFi pods are INDEPENDENT instances, each with its own login
    # session and its own canvas. If the service bounced you between them
    # mid-session you would be logged out at random and see a different canvas
    # each refresh -- deeply confusing.
    #
    # ClientIP affinity pins each browser to one pod. This is a genuine case
    # where affinity is the correct answer rather than a workaround.
    session_affinity = "ClientIP"

    session_affinity_config {
      client_ip {
        # Stick for 3 hours.
        timeout_seconds = 10800
      }
    }
  }
}

# -----------------------------------------------------------------------------
# THE STATEFULSET
# -----------------------------------------------------------------------------
resource "kubernetes_stateful_set" "nifi" {
  metadata {
    name      = "nifi"
    namespace = kubernetes_namespace.nifi.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "nifi"
      "app.kubernetes.io/component"  = "dataflow"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # Two pods, as requested.
    replicas = var.nifi_replicas

    # Links this StatefulSet to the headless service that provides per-pod DNS.
    # This field is mandatory and immutable.
    service_name = kubernetes_service.nifi_headless.metadata[0].name

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "nifi"
      }
    }

    # ---- POD MANAGEMENT POLICY ----
    # "Parallel" starts all pods at once.
    # The default, "OrderedReady", starts nifi-0, waits for it to be fully
    # ready, then starts nifi-1.
    #
    # Ordered is correct for something like a database primary/replica pair
    # where order genuinely matters. Our two NiFi instances are independent, so
    # starting them together halves the wait -- and NiFi takes long enough to
    # boot that this is a noticeable difference.
    pod_management_policy = "Parallel"

    update_strategy {
      type = "RollingUpdate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "nifi"
          "app.kubernetes.io/component" = "dataflow"
        }
      }

      spec {
        # NiFi needs a genuinely long time to shut down cleanly: it must flush
        # its repositories to disk. Killing it early risks corrupting them.
        # 180 seconds is a safe allowance.
        termination_grace_period_seconds = 180

        security_context {
          # UID 1000 is "nifi" inside the official image.
          run_as_user = 1000
          run_as_group = 1000

          # fs_group makes Kubernetes chown the mounted volume to this group,
          # so the non-root NiFi process can write to its own data directory.
          # WITHOUT THIS the pod starts and then fails with permission errors
          # on the persistent volume -- a very common StatefulSet mistake.
          fs_group = 1000
        }

        container {
          name = "nifi"

          # NiFi 2.10.0, released June 2026. Requires Java 21, which the
          # official image bundles.
          image             = "apache/nifi:${var.nifi_version}"
          image_pull_policy = "IfNotPresent"

          port {
            name           = "https"
            container_port = 8443
            protocol       = "TCP"
          }

          port {
            name           = "site-to-site"
            container_port = 10443
            protocol       = "TCP"
          }

          # ---- ENVIRONMENT CONFIGURATION ----
          # The official image reads these and rewrites nifi.properties at
          # startup, which is why we need no custom config file.

          env {
            # HTTPS port. NiFi 2.x has no plaintext HTTP option at all.
            name  = "NIFI_WEB_HTTPS_PORT"
            value = "8443"
          }

          env {
            # ---- A SETTING THAT WILL OTHERWISE LOCK YOU OUT ----
            # NiFi validates the Host header of incoming requests and rejects
            # anything not on this list, returning a bare "Invalid host
            # header" with no explanation.
            #
            # Because we reach the UI through kubectl port-forward (which
            # presents as localhost) and through the service DNS name, both
            # must be listed. Forgetting this is one of the most common NiFi-
            # on-Kubernetes frustrations.
            name  = "NIFI_WEB_PROXY_HOST"
            value = "localhost:8443,127.0.0.1:8443,nifi.${var.nifi_namespace}.svc.cluster.local:8443,nifi:8443"
          }

          env {
            name = "SINGLE_USER_CREDENTIALS_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.nifi_credentials.metadata[0].name
                key  = "username"
              }
            }
          }

          env {
            # Reading the password from a Secret rather than putting it inline
            # means it does not appear in `kubectl describe pod` output.
            name = "SINGLE_USER_CREDENTIALS_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.nifi_credentials.metadata[0].name
                key  = "password"
              }
            }
          }

          env {
            # ---- JVM HEAP ----
            # 1 GiB against a 3 GiB container limit. See the sizing discussion
            # at the top of this file for why the gap is deliberate.
            #
            # -Xms and -Xmx set equal prevents the JVM from spending time
            # growing the heap under load, which causes latency spikes.
            name  = "NIFI_JVM_HEAP_INIT"
            value = var.nifi_jvm_heap
          }

          env {
            name  = "NIFI_JVM_HEAP_MAX"
            value = var.nifi_jvm_heap
          }

          env {
            # Convenience: pre-populate the Kafka address so that when you
            # drag a PublishKafka processor onto the canvas, you can paste
            # this in rather than hunting for it.
            #
            # NiFi does not read this automatically -- it is documentation
            # delivered as an environment variable, visible via
            # `kubectl exec ... -- env | grep KAFKA`.
            name  = "DEMO_KAFKA_BOOTSTRAP"
            value = local.kafka_bootstrap
          }

          env {
            name  = "DEMO_KAFKA_TOPIC"
            value = local.kafka_topic
          }

          env {
            # The pod's own name, so each instance can identify itself.
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          resources {
            requests = {
              cpu    = var.nifi_cpu_request
              memory = var.nifi_memory_request
            }
            limits = {
              cpu    = var.nifi_cpu_limit
              memory = var.nifi_memory_limit
            }
          }

          # ---- PROBES ----
          # NiFi is slow to start. The probe configuration reflects that, and
          # getting it wrong is the difference between a working deployment and
          # an endless CrashLoopBackOff.

          startup_probe {
            tcp_socket {
              # A TCP check rather than HTTP, because NiFi's HTTPS uses a
              # self-signed certificate that an HTTP probe would reject.
              # TCP simply asks "is anything listening?", which is exactly the
              # right question during startup.
              port = 8443
            }

            period_seconds = 10

            # 10s x 60 = up to 10 MINUTES to start.
            #
            # That sounds absurd until you watch NiFi boot on a cold node: it
            # must pull a ~1.5 GB image, then the JVM initialises, then NiFi
            # builds its repositories. On first run this genuinely can take
            # several minutes. A tight startup probe here causes a restart
            # loop that never resolves, because each restart begins again.
            failure_threshold = 60
          }

          readiness_probe {
            tcp_socket {
              port = 8443
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
          }

          liveness_probe {
            tcp_socket {
              port = 8443
            }
            period_seconds  = 30
            timeout_seconds = 10

            # Deliberately forgiving. A NiFi instance processing a large batch
            # can be briefly unresponsive; restarting it mid-batch would be
            # worse than waiting. Six failures over three minutes before we
            # conclude it is genuinely wedged.
            failure_threshold = 6
          }

          # ---- VOLUME MOUNT ----
          # One volume holding all four NiFi repositories.
          volume_mount {
            name       = "nifi-data"
            mount_path = "/opt/nifi/nifi-current/data"
          }
        }

        # ---- SPREAD THE TWO PODS ACROSS NODES ----
        # "preferred" rather than "required" here, unlike Kafka's controllers.
        #
        # The reasoning: our two NiFi instances are independent, so losing both
        # at once is an availability inconvenience, not a data-consistency
        # catastrophe the way losing Kafka quorum would be. Preferring
        # separation while still allowing co-location is the right balance --
        # especially since these pods are large and may not always find a
        # node with room.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = {
                    "app.kubernetes.io/name" = "nifi"
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
      }
    }

    # ---- VOLUME CLAIM TEMPLATES: the StatefulSet superpower ----
    # This does NOT create one volume. It creates one volume PER POD, named
    # after the pod, and reattaches the same volume when that pod restarts:
    #
    #     nifi-data-nifi-0
    #     nifi-data-nifi-1
    #
    # A Deployment cannot do this; every pod would share one volume or none.
    #
    # IMPORTANT: these PVCs are NOT deleted when the StatefulSet is deleted.
    # Kubernetes deliberately keeps them, on the theory that data outliving an
    # accidental deletion is better than the reverse. The teardown script
    # cleans them up explicitly -- otherwise they keep billing you silently.
    volume_claim_template {
      metadata {
        name = "nifi-data"
      }

      spec {
        # ReadWriteOnce = mountable by one node at a time. This is the only
        # mode EBS supports, and it is correct here: each pod owns its volume
        # exclusively.
        access_modes = ["ReadWriteOnce"]

        # gp3, the default class we set in layer 01.
        storage_class_name = "gp3"

        resources {
          requests = {
            storage = var.nifi_storage_size
          }
        }
      }
    }
  }

  # StatefulSets with large images and slow startup need generous timeouts, or
  # Terraform gives up while Kubernetes is still working perfectly well.
  timeouts {
    create = "20m"
    update = "20m"
    delete = "10m"
  }

  depends_on = [
    kubernetes_service.nifi_headless,
    kubernetes_secret.nifi_credentials,
  ]
}

# =============================================================================
# NOTE ON NIFI CLUSTERING -- AN HONEST LIMITATION
# =============================================================================
# What we have built is TWO INDEPENDENT NiFi INSTANCES, not a NiFi CLUSTER.
#
# Each pod has its own canvas, its own flow definition, and its own data. A
# flow you build on nifi-0 does not appear on nifi-1. They do not share work.
#
# THAT IS FINE for this tutorial's purpose -- you asked for two pods, and two
# pods demonstrate StatefulSet identity, per-pod volumes, and independent
# scaling. But it would be dishonest to call it a cluster.
#
# A REAL NIFI CLUSTER additionally requires:
#   - a ZooKeeper ensemble (NiFi still uses ZooKeeper for cluster coordination
#     and leader election, even though Kafka has moved away from it), OR
#     NiFi's newer built-in Kubernetes-native leader election
#   - nifi.cluster.is.node=true and matching cluster protocol ports
#   - a shared, consistent flow definition across all nodes
#   - mutual TLS between nodes, since cluster protocol traffic must be secured
#
# That is a substantial amount of additional configuration and would roughly
# double the length of this file. If you need genuine NiFi clustering, budget
# real time for it and start from the Apache NiFi System Administrator's Guide
# rather than adapting this.
# =============================================================================
