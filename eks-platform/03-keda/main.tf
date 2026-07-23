# =============================================================================
# 03-keda/main.tf   --   KEDA: EVENT-DRIVEN AUTOSCALING
# =============================================================================
# BACKGROUND: THE PROBLEM KEDA SOLVES
#
# Kubernetes has always had a HorizontalPodAutoscaler (HPA). Out of the box it
# can scale on exactly two things: CPU usage and memory usage. That is fine for
# a web server, but consider a worker that reads jobs from a Kafka topic:
#
#   - 50,000 messages are waiting.
#   - Your two workers are chewing through them slowly.
#   - Their CPU is at 30% because they spend most of their time waiting on
#     network I/O.
#   - A CPU-based HPA sees 30% and concludes everything is fine. It never
#     scales up. Your backlog grows all night.
#
# The number that MATTERS is the queue depth, and plain Kubernetes cannot see
# it. KEDA (Kubernetes Event-Driven Autoscaling) fixes exactly this.
#
# HOW KEDA WORKS -- the key insight is that it does not replace the HPA:
#
#   1. You create a ScaledObject: "watch THIS source, scale THAT deployment".
#   2. KEDA's operator sees it and CREATES A NORMAL HPA on your behalf.
#   3. KEDA also runs a "metrics adapter" that serves the external metrics API.
#   4. The standard HPA controller asks that API "what is the current value?"
#   5. KEDA queries the real source (Kafka, SQS, Prometheus, a database, an
#      HTTP endpoint, 70+ options) and answers.
#   6. The HPA does the actual scaling arithmetic, exactly as it always has.
#
# So KEDA is a TRANSLATOR between "things in the real world" and "numbers the
# HPA understands". This matters practically: when debugging, remember you can
# `kubectl describe hpa` and see everything the HPA sees.
#
# KEDA'S OTHER SUPERPOWER: SCALE TO ZERO.
# A plain HPA cannot go below 1 replica, ever. KEDA can take a deployment to 0
# pods when there is no work, then wake it back up when a message arrives. For
# workloads that are idle most of the day this is a large cost saving, and it
# is impossible with vanilla Kubernetes.
#
# ALTERNATIVES AND WHY WE CHOSE KEDA:
#   vs. plain HPA       - simpler, zero extra components, but CPU/memory only
#                         and never scales to zero.
#   vs. Knative         - excellent scale-to-zero for HTTP request-driven
#                         services, but it is a whole serverless platform with
#                         its own routing layer. Much heavier.
#   vs. custom scripts  - you will reinvent KEDA badly.
# KEDA is a CNCF GRADUATED project (the top maturity tier, same as Kubernetes
# itself), so it is a safe long-term bet.
# =============================================================================

# -----------------------------------------------------------------------------
# NAMESPACE
# -----------------------------------------------------------------------------
# A namespace is a folder that groups related Kubernetes objects. It gives you
# a scope for names (two namespaces can each have a "web" service), for
# permissions (RBAC rules are usually namespace-scoped), and for quotas.
#
# BEST PRACTICE: give each operator its own namespace. It makes
# `kubectl get all -n keda` genuinely useful and makes cleanup trivial.
#
# We create the namespace explicitly rather than letting Helm do it with
# create_namespace = true, because that way Terraform owns the namespace object
# and can add labels to it (see below).
resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"

    labels = {
      # ---- Pod Security Admission labels ----
      # Since Kubernetes 1.25 the built-in "Pod Security Admission" controller
      # enforces three profiles per namespace:
      #
      #   privileged - no restrictions at all
      #   baseline   - blocks known privilege escalations (host networking,
      #                privileged containers, hostPath mounts)
      #   restricted - baseline plus: must run as non-root, must drop all
      #                Linux capabilities, must set seccomp
      #
      # KEDA's components run fine under "restricted", so we ask for the
      # strictest setting. This is defense in depth: even if an attacker gets
      # code execution inside a KEDA pod, the kernel-level escape routes are
      # already closed.
      "pod-security.kubernetes.io/enforce" = "restricted"

      # "audit" and "warn" log or warn about violations without blocking. Set
      # to the same level so you get told about problems rather than silently
      # having pods rejected.
      "pod-security.kubernetes.io/audit" = "restricted"
      "pod-security.kubernetes.io/warn"  = "restricted"

      # A plain descriptive label. Useful for selecting with
      # `kubectl get ns -l app.kubernetes.io/part-of=autoscaling`.
      "app.kubernetes.io/part-of" = "autoscaling"
    }
  }
}

# -----------------------------------------------------------------------------
# THE KEDA HELM CHART
# -----------------------------------------------------------------------------
# Installing this chart gives you three deployments:
#
#   keda-operator                        - watches ScaledObjects, creates HPAs
#   keda-operator-metrics-apiserver      - serves the external metrics API
#   keda-admission-webhooks              - validates your ScaledObjects and
#                                          rejects invalid ones at submit time
#                                          with a clear error, rather than
#                                          failing mysteriously later
#
# It also installs the CRDs (Custom Resource Definitions) that TEACH Kubernetes
# what a "ScaledObject" is. A CRD extends the Kubernetes API with new object
# types. Before the CRD exists, `kubectl get scaledobject` returns "the server
# doesn't have a resource type". After it, ScaledObject is as first-class as a
# Deployment.
resource "helm_release" "keda" {
  name = "keda"

  repository = "https://kedacore.github.io/charts"
  chart      = "keda"

  # KEDA 2.20.1, current stable as of July 2026.
  version = "2.20.1"

  # Reference the namespace RESOURCE, not the literal string "keda".
  # This creates a dependency edge so Terraform builds the namespace first.
  # Using the literal string would work by luck, not by design.
  namespace = kubernetes_namespace.keda.metadata[0].name

  # Do not proceed until all three deployments report Ready.
  wait          = true
  wait_for_jobs = true
  timeout       = 900 # 15 min; CRD installation plus three deployments

  # If the install fails partway, roll back and delete the mess rather than
  # leaving a half-installed release that blocks the next attempt.
  atomic  = true
  cleanup_on_fail = true

  # ---- Values ----
  # Passed as a YAML document. For more than a handful of settings this is far
  # more readable than a pile of `set` blocks, and it is exactly what you would
  # put in a values.yaml for a raw `helm install -f values.yaml`.
  values = [
    yamlencode({

      # ---- The operator: the brain ----
      operator = {
        # One replica is correct here. KEDA uses LEADER ELECTION: with several
        # replicas only one is ever active and the rest idle as hot spares.
        # Two would buy faster failover; it does not buy more throughput.
        replicaCount = 1
      }

      # ---- Resource requests and limits for each component ----
      resources = {
        operator = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            memory = "512Mi"
          }
        }

        metricServer = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            memory = "512Mi"
          }
        }

        webhooks = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            memory = "256Mi"
          }
        }
      }

      # ---- Prometheus metrics ----
      # Expose KEDA's own metrics. Even without Prometheus installed today,
      # turning this on now means the data is there the moment you add
      # monitoring. It is free.
      prometheus = {
        metricServer = {
          enabled = true
          port    = 9022
        }
        operator = {
          enabled = true
          port    = 8080
        }
      }

      # ---- Security context ----
      # Belt and braces alongside the namespace-level "restricted" label.
      # The namespace label ENFORCES these rules; setting them here means the
      # pods actually comply rather than being rejected.
      podSecurityContext = {
        # Do not run as the root user. If a container is compromised, the
        # attacker starts as an unprivileged user, which blocks most
        # container-escape techniques.
        runAsNonRoot = true
        runAsUser    = 1000

        # Files created in mounted volumes get this group, so a non-root
        # process can actually write to them.
        fsGroup = 1000

        seccompProfile = {
          # seccomp filters which Linux SYSTEM CALLS the container may make.
          # "RuntimeDefault" applies the container runtime's curated block
          # list, which removes a large class of kernel attack surface at
          # essentially no cost.
          type = "RuntimeDefault"
        }
      }

      securityContext = {
        # Once running, this process can never gain more privileges (e.g. via
        # a setuid binary). Cheap and effective.
        allowPrivilegeEscalation = false

        # Make the container's root filesystem read-only. An attacker who gets
        # code execution cannot drop a payload onto disk. If an app genuinely
        # needs scratch space, mount an emptyDir at that path instead.
        readOnlyRootFilesystem = true

        capabilities = {
          # Linux capabilities are fine-grained root powers (bind to low
          # ports, change file ownership, load kernel modules...). KEDA needs
          # none of them, so we drop every single one.
          drop = ["ALL"]
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.keda]
}

# =============================================================================
# HOW TO DO THIS SAME THING WITH THE HELM CLI INSTEAD OF TERRAFORM
# =============================================================================
# Everything above is equivalent to:
#
#   # 1. Register the chart repository (a one-time step per machine)
#   helm repo add kedacore https://kedacore.github.io/charts
#   helm repo update
#
#   # 2. See what versions exist
#   helm search repo kedacore/keda --versions | head
#
#   # 3. Look at every value you could set
#   helm show values kedacore/keda --version 2.20.1 > keda-values.yaml
#
#   # 4. Install
#   helm install keda kedacore/keda \
#     --namespace keda \
#     --create-namespace \
#     --version 2.20.1 \
#     --values keda-values.yaml \
#     --wait \
#     --timeout 15m
#
#   # 5. Verify
#   helm list -n keda
#   kubectl get pods -n keda
#   kubectl get crd | grep keda
#
# WHEN WOULD YOU PREFER THE CLI?
#   - Debugging. `helm install --dry-run --debug` prints the exact rendered
#     YAML, which is the fastest way to understand what a chart actually does.
#   - `helm rollback keda 1` instantly reverts a bad upgrade. Terraform has no
#     direct equivalent.
#   - `helm diff upgrade` (a plugin) shows precisely what an upgrade changes.
#
# WHEN WOULD YOU PREFER TERRAFORM (as we do here)?
#   - One tool and one `destroy` for AWS resources and cluster resources alike.
#   - Values can reference outputs (IAM role ARNs) with no copy-paste.
#   - The state file records exactly what is installed, which is auditable.
# =============================================================================
