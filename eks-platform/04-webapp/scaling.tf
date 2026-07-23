# =============================================================================
# 04-webapp/scaling.tf   --   TELLING KEDA TO AUTOSCALE OUR WEB SERVERS
# =============================================================================
# A ScaledObject is KEDA's core custom resource. It says, in effect:
#
#     "Watch <this metric>. When it crosses <this threshold>, adjust the
#      replica count of <this deployment>, staying between <min> and <max>."
#
# WHY WE USE THE kubernetes_manifest RESOURCE HERE
#
# Terraform's kubernetes provider has typed resources for built-in objects
# (kubernetes_deployment, kubernetes_service). It cannot have typed resources
# for CUSTOM resources like ScaledObject, because those are defined by whatever
# CRDs happen to be installed.
#
# kubernetes_manifest is the generic escape hatch: hand it any Kubernetes YAML
# (expressed as HCL) and it applies it.
#
# ONE IMPORTANT GOTCHA, and it bites everyone once:
# kubernetes_manifest validates the object against the cluster's schema during
# `terraform plan`. That means THE CRD MUST ALREADY EXIST WHEN YOU PLAN. You
# cannot install KEDA and create a ScaledObject in the same apply.
#
# Our layered design sidesteps this entirely: layer 03 installs KEDA and
# completes, then layer 04 runs. This is a concrete example of why splitting
# into ordered layers is not merely tidy but sometimes necessary.
# =============================================================================

resource "kubernetes_manifest" "hello_web_scaledobject" {
  # Only create this if autoscaling is enabled, so you can turn the whole
  # feature off without deleting code.
  count = var.enable_autoscaling ? 1 : 0

  # The `manifest` argument takes the object exactly as it would appear in
  # YAML, translated to HCL maps. Compare this side by side with the YAML in
  # docs/keda-scaledobject.yaml -- they are the same thing.
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"

    metadata = {
      name      = "hello-web-scaler"
      namespace = kubernetes_namespace.webapp.metadata[0].name

      labels = {
        "app.kubernetes.io/name"      = "hello-web"
        "app.kubernetes.io/component" = "autoscaling"
      }
    }

    spec = {
      # ---- WHAT TO SCALE ----
      scaleTargetRef = {
        # The Deployment KEDA should resize. It must be in the same namespace;
        # a ScaledObject cannot reach across namespaces, by design.
        name = kubernetes_deployment.hello_web.metadata[0].name
        # kind defaults to "Deployment"; stated explicitly for clarity.
        kind = "Deployment"
      }

      # ---- SCALING BOUNDS ----
      # minReplicaCount = never go below this.
      #
      # We use 2 (not 0) deliberately. KEDA CAN scale to zero, and for a
      # queue worker that is the headline feature. But scaling a WEB server to
      # zero means the first visitor after an idle period waits for a cold
      # start -- several seconds of pulling an image and booting. For a
      # user-facing service that is usually unacceptable.
      #
      # RULE OF THUMB: scale-to-zero for asynchronous work (queue consumers,
      # batch jobs, cron-like tasks) where latency does not matter. Keep a
      # warm floor for anything a human is waiting on.
      minReplicaCount = var.min_replicas

      # Your cost ceiling and your blast-radius limit. A runaway metric (or a
      # denial-of-service attack) cannot scale you to a thousand pods.
      maxReplicaCount = var.max_replicas

      # How often KEDA checks the metric, in seconds. 15 is a sensible default:
      # responsive without hammering the metrics source. For Kafka lag you
      # might go to 5; for a slow external API, 60.
      pollingInterval = 15

      # After scaling DOWN, wait this many seconds before scaling down again.
      # This is the "cooldown", and it exists to prevent THRASHING: load dips
      # for ten seconds, you scale in, load returns, you scale out, repeat.
      # Every cycle costs pod startup time and disrupts in-flight requests.
      # 300 seconds (5 minutes) is a conservative, safe default.
      cooldownPeriod = 300

      # ---- ADVANCED: fine-tuning the HPA that KEDA creates ----
      advanced = {
        # Remember: KEDA does not scale anything itself. It creates a normal
        # HorizontalPodAutoscaler and feeds it metrics. This block passes
        # settings straight through to that HPA.
        horizontalPodAutoscalerConfig = {
          behavior = {
            # ---- SCALING UP: be fast ----
            # When load arrives, users are already suffering. React quickly.
            scaleUp = {
              # Look at only the last 30 seconds of metrics when deciding.
              # A short window means fast reaction.
              stabilizationWindowSeconds = 30

              policies = [
                {
                  # May add up to 100% more pods (i.e. double) ...
                  type          = "Percent"
                  value         = 100
                  periodSeconds = 30 # ... at most once every 30 seconds
                },
                {
                  # ... or add 2 pods, whichever the selectPolicy picks.
                  type          = "Pods"
                  value         = 2
                  periodSeconds = 30
                },
              ]

              # "Max" = choose whichever policy permits the BIGGER increase.
              # At 2 replicas, Percent allows +2 and Pods allows +2, so we go
              # to 4. At 8 replicas Percent allows +8, so we can jump to 16.
              # This gives gentle growth when small and aggressive growth when
              # already under real load.
              selectPolicy = "Max"
            }

            # ---- SCALING DOWN: be slow and careful ----
            # Scaling in too eagerly is how you turn a brief traffic dip into
            # an outage when traffic returns. Removing capacity should always
            # be more cautious than adding it.
            scaleDown = {
              # Require FIVE MINUTES of consistently low usage. The HPA looks
              # at the highest recommendation in this window, so one brief
              # spike keeps capacity for another five minutes.
              stabilizationWindowSeconds = 300

              policies = [
                {
                  # Remove at most 1 pod per minute. Slow and undramatic.
                  type          = "Pods"
                  value         = 1
                  periodSeconds = 60
                },
              ]

              # With one policy this makes no practical difference, but stating
              # it documents the intent: when in doubt, remove fewer.
              selectPolicy = "Min"
            }
          }
        }
      }

      # ---- TRIGGERS: what KEDA actually watches ----
      # A list, and KEDA evaluates every entry. If ANY trigger says "scale up",
      # it scales up. The final replica count is the MAXIMUM demanded by any
      # trigger, so a single busy signal is never masked by a quiet one.
      triggers = [
        {
          # The "cpu" scaler reads from the metrics API -- which is why
          # metrics-server (layer 02) is a hard prerequisite. Without it this
          # trigger reports <unknown> forever and nothing scales.
          type = "cpu"

          metricType = "Utilization"

          metadata = {
            # 50 means "50% of the CPU REQUEST".
            #
            # READ THAT CAREFULLY, because it is the most misunderstood number
            # in Kubernetes autoscaling. Our container requests 100m. So the
            # target is 50m of actual usage per pod -- NOT 50% of a core, and
            # NOT 50% of the 200m limit.
            #
            # The HPA arithmetic is roughly:
            #   desired = ceil( current_replicas x current_usage / target )
            # With 2 pods averaging 90m against a 50m target:
            #   ceil(2 x 90 / 50) = ceil(3.6) = 4 pods.
            value = tostring(var.cpu_target_percent)
          }
        },

        {
          # A SECOND trigger on memory. Having two is a good illustration of
          # the max-of-all-triggers rule: a memory leak can now trigger
          # scaling even while CPU stays flat.
          #
          # (In production, scaling on memory is often a smell -- it usually
          # means you have a leak that scaling merely papers over. It is
          # included here because it demonstrates the mechanism clearly.)
          type       = "memory"
          metricType = "Utilization"
          metadata = {
            # 80% of the 64Mi request.
            value = "80"
          }
        },
      ]
    }
  }

  # ---- ORDERING ----
  # The Deployment must exist before we point a ScaledObject at it. KEDA
  # tolerates a missing target (it reports NotReady and retries), but creating
  # things in a sensible order avoids confusing status messages.
  depends_on = [
    kubernetes_deployment.hello_web,
  ]
}

# =============================================================================
# THE EQUIVALENT AS PLAIN YAML AND kubectl
# =============================================================================
# The same object, written the way you would in a normal Kubernetes workflow,
# is saved at docs/keda-scaledobject.yaml. Apply it with:
#
#     kubectl apply -f docs/keda-scaledobject.yaml
#
# USEFUL COMMANDS ONCE IT EXISTS:
#
#   # Is KEDA happy with it?
#   kubectl get scaledobject -n hello-web
#   # The READY and ACTIVE columns are what matter. READY=True means KEDA
#   # parsed it and is watching. ACTIVE=True means a trigger is currently
#   # above its threshold.
#
#   # Why is it not working?
#   kubectl describe scaledobject hello-web-scaler -n hello-web
#   # Read the Events at the bottom first. That is where the real answer is.
#
#   # See the HPA that KEDA created on your behalf
#   kubectl get hpa -n hello-web
#   # The TARGETS column shows current/target, e.g. "12%/50%". If it shows
#   # "<unknown>/50%", metrics-server is not working -- go back to layer 02.
#
#   # Watch scaling happen live
#   kubectl get pods -n hello-web -w
# =============================================================================
