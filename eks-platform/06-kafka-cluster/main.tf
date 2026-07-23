# =============================================================================
# 06-kafka-cluster/main.tf   --   THE ACTUAL KAFKA CLUSTER
# =============================================================================
# Layer 05 installed the Strimzi OPERATOR (the robot that knows how to run
# Kafka). This layer tells that robot what to build.
#
# The relationship is worth being precise about, because it explains why this
# file is so short relative to what it produces:
#
#   We write ~3 custom resources.
#   Strimzi turns them into StrimziPodSets, Services, ConfigMaps, Secrets,
#   PersistentVolumeClaims, certificates, and NetworkPolicies -- around 40
#   Kubernetes objects, continuously reconciled.
#
# =============================================================================
# CRITICAL API VERSION NOTE
# =============================================================================
# Strimzi 1.0.0 REMOVED the v1beta2 API. Everything here uses:
#
#     apiVersion: kafka.strimzi.io/v1
#
# Nearly every Kafka-on-Kubernetes tutorial, blog post and Stack Overflow
# answer you will find still shows v1beta2. Those manifests are REJECTED by
# Strimzi 1.0 with "no matches for kind". If you copy examples from elsewhere,
# this is the first thing to change.
# =============================================================================

locals {
  # Read the namespace the operator watches. The Kafka resources MUST live in
  # that namespace, because we configured the operator with watchNamespaces=[]
  # (own namespace only) back in layer 05.
  kafka_namespace = data.terraform_remote_state.strimzi.outputs.kafka_namespace
}

# =============================================================================
# SIZING: WHY 3 CONTROLLERS AND 2 BROKERS
# =============================================================================
# You asked for "kafka with two pods nodes" and for best-practice sizing. Those
# two things pull in slightly different directions, so here is the reasoning.
#
# ---- CONTROLLERS: WHY THREE, AND WHY IT MUST BE ODD ----
#
# KRaft controllers maintain cluster metadata using the Raft consensus
# algorithm. Raft requires a MAJORITY (a "quorum") of controllers to agree
# before any metadata change commits. The tolerance formula is:
#
#     failures tolerated = floor((N - 1) / 2)
#
#     N=1  ->  0 failures tolerated.  Any restart is a full outage.
#     N=2  ->  0 failures tolerated.  TWO gives you NOTHING over one, because
#              a majority of 2 is still 2. You doubled cost for no resilience.
#     N=3  ->  1 failure tolerated.   The first genuinely useful number.
#     N=4  ->  1 failure tolerated.   Again, no gain over 3.
#     N=5  ->  2 failures tolerated.  For large production clusters.
#
# This is why controller counts are ALWAYS odd. Even numbers buy cost without
# buying availability. Three is the universal default and what we use: it
# survives losing one node (or one AZ, since we spread across three).
#
# ---- BROKERS: WHY TWO ----
#
# Brokers store the actual partition data. Your requirement was two, and two is
# defensible for a demo: it demonstrates replication (a partition can have a
# leader on one broker and a follower on the other) and load distribution.
#
# BE HONEST ABOUT THE LIMITATION, THOUGH. With 2 brokers you can set
# replication.factor=2, but then min.insync.replicas must be 1 for writes to
# continue during a broker restart -- and min.insync.replicas=1 means a single
# broker failure at the wrong moment CAN lose acknowledged writes.
#
# The production standard is 3 brokers with replication.factor=3 and
# min.insync.replicas=2. That combination tolerates one broker failing with
# zero data loss and no write interruption. If you take one thing from this
# file into real work, take that: 3/3/2.
#
# We use 2 brokers as requested and configure the topic defaults as safely as
# 2 brokers permits, with the trade-off spelled out in comments below.
#
# ---- WHY NOT COMBINED ROLES? ----
#
# You CAN give a node both roles (roles: [controller, broker]), which would
# make a 3-node cluster instead of 5. That is common for development and is
# cheaper.
#
# We separate them because it is the production pattern and it teaches the
# distinction: controller workload is small, latency-sensitive metadata
# consensus; broker workload is large, throughput-heavy disk I/O. Mixing them
# means a broker under heavy load can starve the controller and destabilise
# metadata consensus for the whole cluster. Separation isolates that.
#
# ---- TOTAL FOOTPRINT ----
#   3 controllers x (0.5 CPU, 1 GiB RAM, 10 GiB disk)
#   2 brokers     x (1 CPU,   2 GiB RAM, 20 GiB disk)
#   = 5 pods, 3.5 CPU requested, 7 GiB RAM requested, 70 GiB EBS
#
# That fits on our three m6i.large nodes (6 vCPU / 24 GiB total) alongside
# NiFi, but not with much room. See the capacity discussion in the main README.
# =============================================================================

# -----------------------------------------------------------------------------
# KAFKA NODE POOL: THE CONTROLLERS
# -----------------------------------------------------------------------------
# A KafkaNodePool is a group of Kafka nodes sharing configuration. Splitting
# controllers and brokers into separate pools is what lets us size them
# differently -- which is the entire point of node pools.
resource "kubernetes_manifest" "kafka_controllers" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"

    metadata = {
      name      = "controller"
      namespace = local.kafka_namespace

      labels = {
        # THIS LABEL IS MANDATORY AND IS THE #1 THING PEOPLE GET WRONG.
        # It is how Strimzi knows which Kafka cluster this pool belongs to.
        # Without it, the pool is silently ignored and your Kafka resource
        # waits forever for nodes that never arrive.
        "strimzi.io/cluster" = var.kafka_cluster_name
      }
    }

    spec = {
      # Three, for quorum. See the long explanation above.
      replicas = var.controller_replicas

      # ---- ROLES ----
      # "controller" only: these nodes vote on metadata and store no partition
      # data. They are deliberately small.
      roles = ["controller"]

      # ---- STORAGE ----
      resources = {
        requests = {
          cpu    = "500m"
          memory = "1Gi"
        }
        limits = {
          # Kafka is a JVM application. Without a memory limit the JVM heap
          # plus off-heap buffers can grow until the node is destabilised.
          # ALWAYS limit memory on JVM workloads.
          memory = "1536Mi"
        }
      }

      storage = {
        # "jbod" = Just a Bunch Of Disks. Even with a single volume, JBOD is
        # the recommended storage type in KRaft mode because it is the only
        # one that lets you ADD volumes later without recreating the cluster.
        # Choosing "persistent-claim" directly paints you into a corner.
        type = "jbod"

        volumes = [
          {
            # Volume IDs must be stable forever. Changing an ID is interpreted
            # as "remove that disk, add a different one" and loses its data.
            id   = 0
            type = "persistent-claim"

            # Controllers store only the metadata log, which is small. 10 GiB
            # is generous. (Brokers are the ones that need real space.)
            size = "10Gi"

            # deleteClaim = false means the EBS volume SURVIVES deletion of the
            # Kafka resource.
            #
            # TRADE-OFF, stated plainly: false is the SAFE production setting
            # (an accidental `kubectl delete kafka` does not destroy your data)
            # but it means `terraform destroy` leaves volumes behind that keep
            # billing you. Our teardown script explicitly cleans these up; see
            # scripts/destroy-all.sh. For a throwaway demo you may prefer true.
            deleteClaim = var.delete_pvcs_on_destroy

            # Use the gp3 StorageClass we made default in layer 01.
            class = "gp3"
          },
        ]
      }

      # ---- SPREADING CONTROLLERS ACROSS NODES ----
      # This is not a nicety. If two of three controllers land on the same
      # worker node and that node dies, you lose quorum and the ENTIRE cluster
      # stops accepting metadata changes -- exactly the outage the third
      # controller was supposed to prevent.
      template = {
        pod = {
          affinity = {
            podAntiAffinity = {
              # "required" (not "preferred") makes this a HARD rule. A pod that
              # cannot be placed on its own node stays Pending rather than
              # doubling up.
              #
              # This is the opposite choice from the web app in layer 04, and
              # deliberately so: for a stateless web server a Pending pod is
              # worse than an unbalanced one; for a quorum member, co-location
              # silently destroys the guarantee you are paying for.
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      "strimzi.io/cluster"   = var.kafka_cluster_name
                      "strimzi.io/pool-name" = "controller"
                    }
                  }
                  # One pod per node.
                  topologyKey = "kubernetes.io/hostname"
                },
              ]
            }
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# KAFKA NODE POOL: THE BROKERS
# -----------------------------------------------------------------------------
resource "kubernetes_manifest" "kafka_brokers" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaNodePool"

    metadata = {
      name      = "broker"
      namespace = local.kafka_namespace

      labels = {
        "strimzi.io/cluster" = var.kafka_cluster_name
      }
    }

    spec = {
      # Two, as requested.
      replicas = var.broker_replicas

      roles = ["broker"]

      resources = {
        requests = {
          # Brokers do the real work: compression, replication, disk I/O.
          # They get roughly double the controllers.
          cpu    = "1"
          memory = "2Gi"
        }
        limits = {
          memory = "3Gi"
        }
      }

      storage = {
        type = "jbod"
        volumes = [
          {
            id   = 0
            type = "persistent-claim"

            # 20 GiB per broker. Sizing storage properly in production means
            # working out: (messages/sec x message size x retention seconds x
            # replication factor) / brokers, then adding 30% headroom because
            # a full Kafka disk is an outage, not a warning.
            size        = "20Gi"
            deleteClaim = var.delete_pvcs_on_destroy
            class       = "gp3"
          },
        ]
      }

      template = {
        pod = {
          affinity = {
            podAntiAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = [
                {
                  labelSelector = {
                    matchLabels = {
                      "strimzi.io/cluster"   = var.kafka_cluster_name
                      "strimzi.io/pool-name" = "broker"
                    }
                  }
                  topologyKey = "kubernetes.io/hostname"
                },
              ]
            }
          }
        }

        # ---- JVM HEAP SIZING ----
        # A very common and expensive mistake: giving the JVM a heap as large
        # as the container's memory limit. Kafka relies HEAVILY on the OS page
        # cache for read performance -- reading from page cache is what makes
        # Kafka fast. If the heap eats all the memory, there is no page cache
        # left and throughput collapses.
        #
        # RULE OF THUMB: JVM heap around 50% of the container limit, never
        # more than about 6 GiB regardless. The rest is for page cache and
        # off-heap buffers.
        #
        # Here: 3 GiB limit -> 1.5 GiB heap.
        kafkaContainer = {
          env = [
            {
              name  = "KAFKA_HEAP_OPTS"
              value = "-Xms1536m -Xmx1536m"
            },
          ]
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# THE KAFKA CLUSTER ITSELF
# -----------------------------------------------------------------------------
resource "kubernetes_manifest" "kafka_cluster" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "Kafka"

    metadata = {
      name      = var.kafka_cluster_name
      namespace = local.kafka_namespace

      annotations = {
        # ---- TWO ANNOTATIONS THAT ARE STILL REQUIRED ----
        # Even though KRaft and node pools are the only supported mode in
        # Strimzi 1.0, these annotations must still be present. Omitting them
        # produces a cluster that never becomes Ready, with an error that does
        # not obviously point at a missing annotation.
        "strimzi.io/kraft"      = "enabled"
        "strimzi.io/node-pools" = "enabled"
      }
    }

    spec = {
      kafka = {
        # Kafka 4.2.0, the newest version Strimzi 1.0.0 supports.
        version = var.kafka_version

        # ---- LISTENERS: how clients connect ----
        # A listener is a network endpoint with its own port, protocol and
        # security settings. You can define several for different audiences.
        listeners = [
          {
            # An INTERNAL listener: reachable only from inside the cluster.
            # This is what NiFi and our toolbox pod will use.
            name = "plain"
            port = 9092
            type = "internal"

            # tls: false = unencrypted.
            #
            # BE CLEAR THAT THIS IS A DEMO CHOICE. Traffic inside the cluster
            # is unencrypted here so that testing with simple command-line
            # tools requires no certificate wrangling.
            #
            # FOR PRODUCTION: set tls: true and add an authentication block
            # (Strimzi supports mTLS and SCRAM-SHA-512). Strimzi generates and
            # rotates all the certificates for you, so the cost of doing this
            # properly is much lower than it would be outside Kubernetes.
            tls = false
          },
          {
            # A second, TLS-enabled internal listener on a different port.
            # Included so you can see the pattern and switch clients over
            # without redeploying the cluster.
            name = "tls"
            port = 9093
            type = "internal"
            tls  = true
          },
        ]

        # ---- BROKER CONFIGURATION ----
        # These become entries in server.properties on every broker.
        config = {
          # ---- REPLICATION SETTINGS: THE MOST IMPORTANT LINES HERE ----
          #
          # offsets.topic.replication.factor controls the internal topic that
          # tracks every consumer group's position. If it is 1 and that broker
          # dies, EVERY consumer group loses its place and reprocesses or skips
          # data. With 2 brokers we set 2, which is the maximum available.
          "offsets.topic.replication.factor" = var.broker_replicas

          # Same reasoning for the transaction state log.
          "transaction.state.log.replication.factor" = var.broker_replicas

          # min.insync.replicas: how many replicas must acknowledge a write
          # before it is considered committed (when a producer uses acks=all).
          #
          # THE HONEST TRADE-OFF WITH ONLY 2 BROKERS:
          #   min.insync=2 -> writes are safe, but ANY broker restart (including
          #                   a routine rolling upgrade) stops writes entirely.
          #   min.insync=1 -> writes continue during a restart, but a failure at
          #                   the wrong instant can lose acknowledged data.
          #
          # There is no good answer with 2 brokers; this is precisely why the
          # production standard is 3. We choose 1 so the demo stays usable
          # during restarts, and flag the risk rather than hiding it.
          "transaction.state.log.min.isr" = 1

          # Default replication for topics created automatically.
          "default.replication.factor" = var.broker_replicas
          "min.insync.replicas"        = 1

          # ---- DATA RETENTION ----
          # How long messages are kept before deletion. 7 days is the Kafka
          # default. Retention is the main driver of disk sizing.
          "log.retention.hours" = 168

          # Roll to a new log segment at 1 GiB. Retention only deletes whole
          # closed segments, so segment size sets the granularity of cleanup.
          "log.segment.bytes" = 1073741824

          # ---- AUTO TOPIC CREATION ----
          # false is the right production setting. When true, a typo in a topic
          # name silently creates a new topic with default settings rather than
          # failing loudly, and you end up with a cluster full of junk topics
          # that nobody dares delete.
          #
          # We manage topics explicitly with KafkaTopic resources instead.
          "auto.create.topics.enable" = false
        }
      }

      # ---- ENTITY OPERATOR ----
      # Two small sidecar operators that let you manage Kafka topics and users
      # as Kubernetes resources instead of shelling into a broker.
      entityOperator = {
        # Watches KafkaTopic resources and creates/updates real topics.
        topicOperator = {
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        # Watches KafkaUser resources, creates credentials and ACLs.
        # Not strictly needed since we have no authentication enabled, but it
        # costs little and is there when you turn TLS on.
        userOperator = {
          resources = {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }
      }
    }
  }

  # The node pools must exist first. Strimzi tolerates the reverse order (it
  # simply waits), but creating in dependency order avoids a confusing spell
  # where the cluster reports NotReady for reasons that look like errors.
  depends_on = [
    kubernetes_manifest.kafka_controllers,
    kubernetes_manifest.kafka_brokers,
  ]
}

# -----------------------------------------------------------------------------
# A TEST TOPIC
# -----------------------------------------------------------------------------
# Created declaratively so the test script in tests/ has something to produce
# to and consume from without any manual setup.
resource "kubernetes_manifest" "test_topic" {
  manifest = {
    apiVersion = "kafka.strimzi.io/v1"
    kind       = "KafkaTopic"

    metadata = {
      name      = var.test_topic_name
      namespace = local.kafka_namespace

      labels = {
        # Again mandatory: tells the Topic Operator which cluster to act on.
        "strimzi.io/cluster" = var.kafka_cluster_name
      }
    }

    spec = {
      # ---- PARTITIONS: the unit of parallelism ----
      # A topic's partitions are distributed across brokers. The number of
      # partitions is the MAXIMUM number of consumers in one consumer group
      # that can work in parallel -- a 3-partition topic can never usefully
      # have more than 3 active consumers in a group.
      #
      # You can INCREASE partitions later but never decrease them, and
      # increasing changes which partition a given key hashes to, which breaks
      # per-key ordering guarantees. So it is worth a moment's thought up
      # front. Three is a reasonable starting point for a small cluster.
      partitions = 3

      # Each partition is stored on 2 brokers, so one can fail without data
      # becoming unavailable.
      replicas = var.broker_replicas

      config = {
        # Keep test messages for 1 hour rather than the cluster default of a
        # week. 3600000 milliseconds.
        "retention.ms" = "3600000"

        # "delete" = old segments are removed once past retention.
        # The alternative, "compact", keeps only the newest message per key
        # forever, which is what you want for a changelog or a lookup table.
        "cleanup.policy" = "delete"
      }
    }
  }

  depends_on = [kubernetes_manifest.kafka_cluster]
}
