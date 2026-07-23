# =============================================================================
# 04-webapp/deployment.tf   --   THE DEPLOYMENT
# =============================================================================
# WHAT A DEPLOYMENT ACTUALLY DOES
#
# You do not create pods directly in real Kubernetes. You create a Deployment,
# and it maintains pods for you. The chain is:
#
#   Deployment  ->  ReplicaSet  ->  Pods
#
#   The Deployment owns the ROLLOUT STRATEGY (how to move from version 1 to
#   version 2 without downtime) and keeps a history so you can roll back.
#   The ReplicaSet owns the COUNT ("there must be exactly 2 pods matching this
#   template"). Each new version gets a fresh ReplicaSet; the old one is scaled
#   to 0 but kept around so rollback is instant.
#
# WHY NOT CREATE PODS DIRECTLY? A bare pod is a pet. If its node dies, it is
# simply gone; nothing recreates it. A Deployment makes pods cattle: any one
# can die and be replaced without anyone noticing.
# =============================================================================

resource "kubernetes_deployment" "hello_web" {
  metadata {
    name      = "hello-web"
    namespace = kubernetes_namespace.webapp.metadata[0].name

    # ---- The recommended standard labels ----
    # Kubernetes defines a set of conventional label names. Using them means
    # tooling (dashboards, service meshes, cost allocation) can understand your
    # application without custom configuration. It costs nothing to adopt.
    labels = {
      "app.kubernetes.io/name"      = "hello-web"
      "app.kubernetes.io/instance"  = "hello-web"
      "app.kubernetes.io/component" = "frontend"
      "app.kubernetes.io/part-of"   = "hello-web"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # ---- INITIAL replica count ----
    # Two, as requested: enough to demonstrate load balancing across pods.
    #
    # IMPORTANT SUBTLETY: once KEDA takes over, KEDA owns this number. If you
    # let Terraform keep managing it, the two will fight -- KEDA scales to 5,
    # Terraform's next apply scales back to 2, KEDA scales up again, forever.
    # The `lifecycle` block at the bottom of this resource stops that.
    replicas = var.initial_replicas

    # ---- The selector: how the Deployment finds "its" pods ----
    # This is a label query. The Deployment manages every pod carrying these
    # labels. It MUST match the template's labels below, or the Deployment
    # creates pods it then cannot see, and loops creating more forever.
    #
    # The selector is IMMUTABLE after creation. Changing it requires deleting
    # and recreating the Deployment. Choose it carefully and never edit it.
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "hello-web"
        "app.kubernetes.io/instance" = "hello-web"
      }
    }

    # ---- Rollout strategy ----
    strategy {
      # RollingUpdate replaces pods gradually so the service stays up.
      # The alternative, "Recreate", kills everything then starts the new
      # version -- correct only when two versions genuinely cannot coexist
      # (for instance because of an incompatible database migration).
      type = "RollingUpdate"

      rolling_update {
        # At most 1 pod may be unavailable during the rollout. With 2 replicas
        # that guarantees at least 1 is always serving.
        max_unavailable = 1

        # At most 1 EXTRA pod above the desired count may exist temporarily.
        # This is what lets Kubernetes start the new pod before stopping an
        # old one, so capacity never dips.
        max_surge = 1
      }
    }

    # How many old ReplicaSets to keep for rollback. The default is 10, which
    # clutters `kubectl get rs`. Three is plenty.
    revision_history_limit = 3

    # ---- THE POD TEMPLATE ----
    # Everything below describes the pods this Deployment should create.
    template {
      metadata {
        # These MUST include everything in the selector above.
        labels = {
          "app.kubernetes.io/name"      = "hello-web"
          "app.kubernetes.io/instance"  = "hello-web"
          "app.kubernetes.io/component" = "frontend"
        }

        annotations = {
          # ---- THE CONFIG-CHANGE ROLLOUT TRICK ----
          # Kubernetes does NOT restart pods when a mounted ConfigMap changes.
          # The file updates on disk eventually, but nginx has already read it
          # and will not notice.
          #
          # By putting a hash of the ConfigMap's contents in an annotation, we
          # change the POD TEMPLATE whenever the config changes. A changed
          # template triggers a rolling update automatically.
          #
          # This is a widely used idiom; you will see it in most production
          # Helm charts as `checksum/config`.
          "checksum/config" = sha256(jsonencode(kubernetes_config_map.web_content.data))
        }
      }

      spec {
        # ---- POD-LEVEL SECURITY CONTEXT ----
        # Applies to every container in the pod.
        security_context {
          # Refuse to start if the image would run as root. This is a
          # guarantee, not a request: if someone swaps in a root image, the
          # pod fails loudly instead of quietly running privileged.
          run_as_non_root = true

          # UID 101 is the "nginx" user inside the official nginx image.
          run_as_user  = 101
          run_as_group = 101

          # Files created in mounted volumes get this group, so our non-root
          # process can write to the emptyDir volumes below.
          fs_group = 101

          seccomp_profile {
            # Apply the container runtime's default syscall filter. Removes a
            # large slice of kernel attack surface for free.
            type = "RuntimeDefault"
          }
        }

        # ---- INIT CONTAINER ----
        # Init containers run to completion BEFORE the main containers start.
        # If one fails, Kubernetes restarts the pod. They are the right tool
        # for setup work: rendering config, waiting for a dependency,
        # running a migration.
        #
        # Ours renders index.html.template into real HTML, substituting the
        # pod's identity.
        init_container {
          name = "render-page"

          # busybox includes `envsubst`? No -- it does not. We use `sed`,
          # which busybox definitely has, and which is entirely sufficient for
          # three fixed substitutions. Choosing a tool you can rely on beats
          # choosing the fancier one.
          image             = "busybox:1.37"
          image_pull_policy = "IfNotPresent"

          command = ["/bin/sh", "-c"]
          args = [
            # Read the template, replace the three placeholders with the real
            # environment variable values, write the result to the shared
            # volume that nginx serves from.
            # ESCAPING NOTE, because two layers of quoting meet here:
            #   - Terraform reads this heredoc first. In Terraform, $${ emits
            #     a literal ${ , so $${POD_NAME} lands in the file as the
            #     seven characters  ${POD_NAME}  -- the exact placeholder text
            #     we put in index.html.template.
            #   - The shell reads it second. The sed SEARCH patterns are in
            #     SINGLE quotes, so the shell leaves ${POD_NAME} completely
            #     alone. The REPLACEMENT values are in double quotes, so the
            #     shell DOES expand $POD_NAME to the real pod name.
            # Single-quoting the search side is what makes this unambiguous.
            <<-SCRIPT
              set -eu
              sed \
                -e 's|$${POD_NAME}|'"$POD_NAME"'|g' \
                -e 's|$${NODE_NAME}|'"$NODE_NAME"'|g' \
                -e 's|$${POD_IP}|'"$POD_IP"'|g' \
                /template/index.html.template > /html/index.html
              echo "Rendered index.html for pod $POD_NAME on node $NODE_NAME"
            SCRIPT
          ]

          # ---- THE DOWNWARD API ----
          # This is how a pod learns facts about itself. Kubernetes injects
          # values from the pod's own metadata as environment variables.
          # No API call, no permissions needed, no service account token.
          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                # spec.nodeName is filled in by the scheduler once it picks a
                # node, so this tells us which machine we landed on.
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }

          # Read-only mount of the template from the ConfigMap.
          volume_mount {
            name       = "web-template"
            mount_path = "/template"
            read_only  = true
          }

          # Writable mount where we place the rendered output. Shared with the
          # nginx container below.
          volume_mount {
            name       = "html"
            mount_path = "/html"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 101
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "32Mi"
            }
          }
        }

        # ---- THE MAIN CONTAINER ----
        container {
          name = "nginx"

          # nginx:1.29-alpine.
          #
          # WHY ALPINE? The image is roughly 50 MB instead of 190 MB. Smaller
          # images pull faster (which matters when scaling up under load) and
          # contain fewer packages, therefore fewer CVEs to patch.
          #
          # WHY A MINOR-VERSION TAG rather than "latest" or a full pin?
          #   "latest"       - never do this. It is not reproducible and you
          #                    get silent major upgrades.
          #   "1.29-alpine"  - what we use. Picks up patch releases (security
          #                    fixes) automatically, never a breaking change.
          #   "nginx@sha256:..." - a digest pin. Maximum reproducibility, used
          #                    for regulated environments, but you must update
          #                    it manually for every security fix.
          image = "nginx:1.29-alpine"

          # IfNotPresent = use the cached copy if the node already has it.
          # "Always" would re-check the registry every start, which is slower
          # and can fail if the registry is unreachable.
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          # ---- RESOURCE REQUESTS AND LIMITS ----
          # requests = what the scheduler reserves. This is what determines
          #            which node the pod fits on, and what the HPA/KEDA
          #            percentage is calculated AGAINST.
          # limits   = the hard ceiling.
          #
          # We keep these small on purpose. Our KEDA rule scales at 50% CPU
          # utilisation, and "50%" means 50% of the REQUEST (100m), i.e. 50m.
          # Small requests make the demo respond to modest load rather than
          # requiring you to generate serious traffic.
          resources {
            requests = {
              cpu    = "100m"  # 0.1 of a CPU core
              memory = "64Mi"
            }
            limits = {
              # A CPU limit here is unusual (see the note in 02-addons) but is
              # justified for THIS pod specifically: capping at 200m makes the
              # autoscaling demo predictable and fast to trigger, because a
              # pod cannot absorb unlimited load.
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          # ---- CONTAINER-LEVEL SECURITY CONTEXT ----
          security_context {
            allow_privilege_escalation = false

            # Root filesystem is read-only. An attacker cannot write a payload
            # to disk. nginx needs scratch space, which we supply as explicit
            # emptyDir volumes below -- that is the correct pattern: enumerate
            # exactly what must be writable rather than making everything so.
            read_only_root_filesystem = true

            run_as_non_root = true
            run_as_user     = 101

            capabilities {
              drop = ["ALL"]
            }
          }

          # ---- HEALTH PROBES ----
          # Kubernetes offers three, and using the right one matters:
          #
          # startupProbe   - "has it finished booting?" While this is failing,
          #                  the other two probes are suspended. Use it for
          #                  slow-starting apps so you do not need a huge
          #                  initialDelaySeconds on the liveness probe.
          #
          # readinessProbe - "should it receive traffic RIGHT NOW?" Failing
          #                  removes the pod from the Service's endpoint list.
          #                  The pod is NOT restarted. This is the probe that
          #                  protects your users.
          #
          # livenessProbe  - "is it wedged and unrecoverable?" Failing RESTARTS
          #                  the container. Be conservative: an aggressive
          #                  liveness probe on a merely-slow app causes a
          #                  restart storm that turns a slowdown into an
          #                  outage. This is a classic production incident.

          startup_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            # Check every 2s, allow up to 30 failures = 60 seconds to start.
            period_seconds    = 2
            failure_threshold = 30
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 5
            timeout_seconds   = 2
            # One failure is enough to stop sending traffic. Fast reaction is
            # safe here because it does not restart anything.
            failure_threshold = 1
            success_threshold = 1
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds  = 10
            timeout_seconds = 3
            # THREE consecutive failures over 30 seconds before restarting.
            # Deliberately more forgiving than the readiness probe.
            failure_threshold = 3
          }

          # ---- VOLUME MOUNTS ----
          volume_mount {
            # The rendered HTML, produced by the init container.
            name       = "html"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }

          volume_mount {
            # Our nginx server config.
            name       = "web-template"
            mount_path = "/etc/nginx/conf.d/default.conf"

            # sub_path mounts a SINGLE FILE from the ConfigMap rather than
            # replacing the whole directory. Without it, mounting here would
            # hide every other file in /etc/nginx/conf.d.
            sub_path  = "default.conf"
            read_only = true
          }

          # nginx must write to these three paths at runtime. Because the root
          # filesystem is read-only, each needs its own writable volume.
          # Discovering this list is the usual friction when hardening a
          # container: run it, read the permission-denied error, add a volume,
          # repeat.
          volume_mount {
            name       = "nginx-cache"
            mount_path = "/var/cache/nginx"
          }

          volume_mount {
            name       = "nginx-run"
            mount_path = "/var/run"
          }

          volume_mount {
            name       = "nginx-tmp"
            mount_path = "/tmp"
          }
        }

        # ---- VOLUMES ----
        # Declared once at pod level; mounted by name in the containers above.

        volume {
          name = "web-template"
          config_map {
            name = kubernetes_config_map.web_content.metadata[0].name
          }
        }

        volume {
          name = "html"
          # emptyDir = scratch space that lives as long as the pod does. It is
          # created empty when the pod starts and deleted when it stops.
          # Perfect for sharing files between an init container and the main
          # container, which is exactly our use.
          empty_dir {}
        }

        volume {
          name = "nginx-cache"
          empty_dir {}
        }

        volume {
          name = "nginx-run"
          empty_dir {}
        }

        volume {
          name = "nginx-tmp"
          empty_dir {}
        }

        # ---- POD SPREADING ----
        # Without this, the scheduler is free to put both replicas on the same
        # node -- and then one node failure takes out your entire service,
        # defeating the point of running two.
        topology_spread_constraint {
          # Spread across NODES. The label kubernetes.io/hostname is unique
          # per node, so "one topology domain" = "one node".
          topology_key = "kubernetes.io/hostname"

          # The maximum allowed difference in pod count between the busiest
          # and emptiest node. 1 means as even as arithmetic permits.
          max_skew = 1

          # ScheduleAnyway = treat this as a strong preference, not a hard
          # rule. If there is genuinely nowhere balanced to put the pod, run
          # it somewhere rather than leaving it Pending.
          #
          # The alternative, DoNotSchedule, makes it mandatory. That is right
          # for Kafka brokers (where co-location loses data) and wrong for
          # stateless web servers (where a Pending pod is worse than an
          # unbalanced one).
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = {
              "app.kubernetes.io/name" = "hello-web"
            }
          }
        }

        # How long Kubernetes waits for graceful shutdown before sending
        # SIGKILL. 30 seconds is the default and is fine for nginx, which
        # finishes in-flight requests quickly.
        termination_grace_period_seconds = 30
      }
    }
  }

  # ---------------------------------------------------------------------------
  # LIFECYCLE: THE SINGLE MOST IMPORTANT BLOCK IN THIS FILE
  # ---------------------------------------------------------------------------
  lifecycle {
    ignore_changes = [
      # STOP TERRAFORM FROM FIGHTING KEDA.
      #
      # Terraform's model is "the code is the truth; make reality match".
      # KEDA's model is "the metrics are the truth; adjust replicas".
      #
      # Both want to own spec.replicas. Without this line:
      #   - Load arrives, KEDA scales to 6.
      #   - You run `terraform apply` for an unrelated change.
      #   - Terraform sees 6, its code says 2, and scales you back down
      #     mid-incident.
      #   - KEDA notices and scales back up.
      # You have built a control loop that fights itself.
      #
      # ignore_changes tells Terraform: set this on CREATE, then never look at
      # it again. This is the standard pattern any time an in-cluster
      # controller owns a field that Terraform also declares.
      spec[0].replicas,
    ]
  }

  depends_on = [
    kubernetes_config_map.web_content,
  ]
}
