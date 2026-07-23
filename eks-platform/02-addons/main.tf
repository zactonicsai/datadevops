# =============================================================================
# 02-addons/main.tf   --   CLUSTER-WIDE SUPPORTING SERVICES
# =============================================================================
# Layers 03 through 08 install our actual applications. This layer installs the
# shared plumbing they all depend on. Keeping it separate means you can rebuild
# an application layer without touching the plumbing.
#
# WHAT GOES IN HERE:
#   metrics-server - collects CPU and memory usage from every node and pod.
#
# WHY METRICS-SERVER MATTERS FOR THIS PROJECT:
# It is a hard prerequisite for autoscaling. Kubernetes' HorizontalPodAutoscaler
# reads pod CPU usage from the "metrics API", and NOTHING serves that API
# unless metrics-server is installed. Without it:
#   - `kubectl top pods` fails with "Metrics API not available"
#   - any CPU-based scaling sits forever showing "<unknown>/50%"
#
# KEDA (layer 03) creates HPAs under the hood, so our CPU-triggered scaling in
# layer 04 depends on this being here first. This is a genuinely common
# stumbling block: people install KEDA, wonder why nothing scales, and the
# answer is that metrics-server was never installed.
#
# A NOTE ON WHY WE ARE NOT INSTALLING THE AWS LOAD BALANCER CONTROLLER:
# Many EKS tutorials install it here so you can use Ingress resources. We
# deliberately do not, for two reasons:
#   1. It adds a large IAM policy, webhooks, and CRDs -- a lot of surface area
#      and a lot of ways for a tutorial to break.
#   2. We do not need it. A Kubernetes Service of type LoadBalancer is handled
#      by the in-tree AWS cloud provider that EKS ships with, and gives us a
#      real Network Load Balancer with zero extra components.
# If you later want path-based HTTP routing, TLS termination at the load
# balancer, or a single ALB shared by many services, THAT is when you install
# the AWS Load Balancer Controller. The README explains how.
# =============================================================================

# -----------------------------------------------------------------------------
# METRICS-SERVER
# -----------------------------------------------------------------------------
resource "helm_release" "metrics_server" {
  # The Helm release name. This is what shows up in `helm list`.
  name = "metrics-server"

  # Where to download the chart from. This is the official upstream repo run by
  # the Kubernetes SIG that maintains metrics-server.
  #
  # BEST PRACTICE: prefer the project's own chart repository over third-party
  # mirrors. Mirrors go stale or, worse, get taken over.
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  # Pin the chart version. Same reasoning as pinning providers: without this,
  # `terraform apply` two months from now installs a different version and you
  # will not know why behaviour changed.
  version = "3.13.0"

  # kube-system is the conventional namespace for cluster infrastructure.
  namespace = "kube-system"

  # Wait for the pods to actually become Ready before declaring success.
  # Without this, Terraform reports "created" the instant Kubernetes ACCEPTS
  # the objects, and the next layer starts against a service that is not
  # serving yet.
  wait    = true
  timeout = 600 # seconds; 10 minutes

  # ---- Chart values ----
  # `set` blocks override individual values in the chart's values.yaml.
  # For a handful of settings this is more readable than a YAML blob.
  # (For many settings, use the `values` argument with a heredoc or a file.)

  set = [
    {
      # Two replicas so a single node failure does not blind your autoscaling.
      # metrics-server is tiny; the redundancy is nearly free.
      name  = "replicas"
      value = "2"
    },
    {
      # ---- THE MOST IMPORTANT SETTING IN THIS FILE ----
      # metrics-server scrapes each node's kubelet over HTTPS. The kubelet
      # presents a SELF-SIGNED certificate whose subject name does not match
      # the node's address. Strict TLS verification therefore fails and
      # metrics-server crash-loops with "x509: cannot validate certificate".
      #
      # --kubelet-insecure-tls skips that verification.
      #
      # IS THIS SAFE? Be clear-eyed about it. This is a documented, universally
      # used workaround for managed Kubernetes (EKS, GKE and AKS all need it or
      # an equivalent). The traffic is still ENCRYPTED; what is skipped is
      # verifying the server's identity. The exposure is a machine-in-the-
      # middle attacker already inside the cluster's private network, at which
      # point you have larger problems.
      #
      # The rigorous alternative is to enable kubelet serving certificate
      # rotation signed by the cluster CA, which EKS does not expose as a
      # configurable option. So in practice, on EKS, this is the answer.
      name  = "args[0]"
      value = "--kubelet-insecure-tls"
    },
    {
      # How often to scrape. 15 seconds is the default and is a sensible
      # balance. Scraping faster gives autoscaling quicker reactions but puts
      # more load on every kubelet.
      name  = "args[1]"
      value = "--metric-resolution=15s"
    },
    {
      # ---- Resource requests and limits ----
      # A "request" is what the scheduler RESERVES for this container; it
      # guarantees the pod gets at least this much and is used to decide which
      # node has room.
      # A "limit" is the hard ceiling; exceeding a memory limit gets the
      # container killed (OOMKilled).
      #
      # BEST PRACTICE: always set both on every workload. Pods with no requests
      # are scheduled blindly and are the first to be evicted when a node runs
      # short. Pods with no memory limit can take a whole node down with them.
      name  = "resources.requests.cpu"
      value = "50m" # "m" = millicores; 50m is 5% of one CPU core
    },
    {
      name  = "resources.requests.memory"
      value = "128Mi"
    },
    {
      name  = "resources.limits.memory"
      value = "256Mi"
    },
  ]
}

# NOTE ON CPU LIMITS, since you will see them everywhere:
# We set a memory limit above but deliberately NO cpu limit.
#
# Memory is INCOMPRESSIBLE: a container cannot be given "less memory for a
# moment", so a limit is the only way to stop one pod eating the node.
# CPU is COMPRESSIBLE: the kernel simply hands out fewer time slices.
#
# A CPU limit does not protect the node (requests already do that) but it does
# actively throttle your container even when the node is idle, which adds
# latency for no benefit. The modern consensus is: always set CPU requests,
# usually skip CPU limits, always set memory limits and requests to the same
# value for critical workloads.
