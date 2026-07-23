# =============================================================================
# 04-webapp/service.tf   --   GIVING THE PODS A STABLE ADDRESS
# =============================================================================
# BACKGROUND: WHY SERVICES EXIST
#
# Pods are disposable and their IP addresses change constantly. A pod that
# restarts gets a new IP. Scale from 2 to 6 and there are four new IPs. Nothing
# can be hard-coded to talk to a pod.
#
# A Service is a stable front door. It gets:
#   - a permanent virtual IP (the "cluster IP") that never changes
#   - a permanent DNS name
#   - an automatically maintained list of healthy backing pods
#
# When a pod fails its readiness probe, Kubernetes removes it from that list
# within seconds and traffic stops going there. When a new pod becomes ready,
# it is added. You never touch it.
#
# THE FOUR SERVICE TYPES, and when to use each:
#
#   ClusterIP    - reachable only from inside the cluster. The default and by
#                  far the most common. Use for anything other services call.
#
#   NodePort     - opens the same high port (30000-32767) on EVERY node. Crude
#                  and rarely the right answer on a cloud; mostly a building
#                  block that LoadBalancer uses internally.
#
#   LoadBalancer - asks the cloud provider for a real load balancer with a
#                  public address. This is how you get traffic from the
#                  internet on AWS, GCP or Azure.
#
#   ExternalName - just a DNS CNAME to something outside the cluster. No
#                  proxying at all.
#
# We create TWO services for the same pods, which is a deliberate and common
# pattern: an internal one for cluster traffic and testing, and an external one
# for real users.
# =============================================================================

# -----------------------------------------------------------------------------
# SERVICE 1: ClusterIP -- the internal address
# -----------------------------------------------------------------------------
# This is what our toolbox pod (layer 08) will curl to prove in-cluster
# networking works. It costs nothing and is always available.
resource "kubernetes_service" "hello_web_internal" {
  metadata {
    name      = "hello-web"
    namespace = kubernetes_namespace.webapp.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = "hello-web"
      "app.kubernetes.io/component" = "frontend"
    }
  }

  spec {
    type = "ClusterIP"

    # ---- THE SELECTOR ----
    # This is the entire mechanism. The Service continuously watches for pods
    # carrying these labels and routes to whichever are currently READY.
    #
    # There is no explicit link between the Service and the Deployment. They
    # are connected ONLY by these labels matching. That loose coupling is
    # powerful (you can point a service at pods from several deployments during
    # a migration) and is also the number one source of "my service has no
    # endpoints" confusion. If traffic is not flowing, check the labels first:
    #     kubectl get endpoints hello-web -n <ns>
    # An empty ENDPOINTS column means the selector matches nothing, or no pod
    # is passing its readiness probe.
    selector = {
      "app.kubernetes.io/name"     = "hello-web"
      "app.kubernetes.io/instance" = "hello-web"
    }

    port {
      name = "http"

      # The port the SERVICE listens on. Callers use this.
      port = 80

      # The port on the POD to forward to. Our nginx listens on 8080 because
      # it runs as a non-root user (see main.tf for why).
      #
      # This remapping is exactly why Services are useful: internal details can
      # change without callers ever knowing.
      target_port = 8080

      protocol = "TCP"
    }

    # Distribute each new connection to a random ready pod.
    #
    # The alternative, "ClientIP", pins each client to one pod for a while
    # (session affinity). Only use that if your app stores session state in
    # memory -- and if it does, consider fixing that instead.
    session_affinity = "None"
  }

  depends_on = [kubernetes_deployment.hello_web]
}

# -----------------------------------------------------------------------------
# SERVICE 2: LoadBalancer -- the public address
# -----------------------------------------------------------------------------
# Creating this makes the EKS cloud controller call the AWS API and provision a
# real load balancer, then write its DNS name back into this object's status.
#
# COST WARNING: a Network Load Balancer costs roughly $0.0225/hour (about
# $16/month) plus a charge per "Load Balancer Capacity Unit". Set
# `create_public_loadbalancer = false` in your tfvars to skip it and test
# purely from inside the cluster instead.
resource "kubernetes_service" "hello_web_public" {
  # Conditional creation: 1 resource if the flag is true, 0 if false.
  count = var.create_public_loadbalancer ? 1 : 0

  metadata {
    name      = "hello-web-public"
    namespace = kubernetes_namespace.webapp.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = "hello-web"
      "app.kubernetes.io/component" = "frontend-public"
    }

    # ---- ANNOTATIONS: how you configure the AWS load balancer ----
    # Annotations are free-form key/value metadata. AWS's controller reads
    # these to decide what kind of load balancer to build. This is the standard
    # Kubernetes escape hatch for cloud-specific settings that do not belong in
    # the portable core API.
    annotations = {
      # ---- NLB vs ALB vs Classic: choosing the right one ----
      # "external" + nlb-ip means: build a NETWORK Load Balancer (layer 4,
      # TCP) that targets pod IPs directly.
      #
      #   NLB (what we use)  - operates at TCP level. Extremely fast, handles
      #                        millions of connections, preserves the client's
      #                        source IP, supports any TCP protocol. Cannot do
      #                        HTTP path routing or terminate TLS with a
      #                        WAF attached.
      #   ALB                - operates at HTTP level. Can route /api to one
      #                        service and /web to another, integrates with
      #                        AWS WAF and Cognito. Requires the AWS Load
      #                        Balancer Controller to be installed.
      #   Classic (CLB)      - the previous generation. Do not use for new work.
      #
      # We choose NLB because it works with the in-tree cloud provider that
      # EKS ships by default, meaning ZERO extra components to install.
      "service.beta.kubernetes.io/aws-load-balancer-type" = "external"

      # "ip" mode sends traffic straight to POD IPs. The alternative,
      # "instance" mode, sends to a NodePort on each node, which then does a
      # second hop to the pod. IP mode removes that extra hop, which is both
      # faster and preserves the client IP more cleanly.
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"

      # Put the load balancer in the PUBLIC subnets so it is internet
      # reachable. Setting this to "internal" instead makes it VPC-only,
      # which is what you want for internal APIs.
      "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"

      # Health check settings. The load balancer stops sending traffic to any
      # target that fails these, independently of Kubernetes' own probes.
      # Both layers checking is correct -- they protect against different
      # failures.
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"            = "HTTP"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"                = "/healthz"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"                = "8080"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval-seconds"    = "10"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold"   = "2"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold" = "2"

      # Spread across all Availability Zones. Without this, an NLB only sends
      # traffic to targets in the same zone as the client's entry point, which
      # can leave capacity idle and cause uneven load.
      "service.beta.kubernetes.io/aws-load-balancer-attributes" = "load_balancing.cross_zone.enabled=true"
    }
  }

  spec {
    type = "LoadBalancer"

    # Same selector: both services front the identical set of pods.
    selector = {
      "app.kubernetes.io/name"     = "hello-web"
      "app.kubernetes.io/instance" = "hello-web"
    }

    port {
      name        = "http"
      port        = 80    # what the public types in their browser
      target_port = 8080  # what nginx actually listens on
      protocol    = "TCP"
    }

    # ---- Restrict who can reach the load balancer ----
    # This becomes a security group rule on the load balancer. Narrowing it to
    # your own IP is a good habit even for a demo.
    load_balancer_source_ranges = var.allowed_admin_cidrs

    # ---- externalTrafficPolicy ----
    # "Local" means a node only forwards to pods on ITSELF, never to another
    # node.
    #
    #   PRO: preserves the real client IP (useful for logs, rate limiting,
    #        geo rules) and removes an extra network hop.
    #   CON: if a node has no ready pod, its health check fails and the load
    #        balancer stops using it. With few replicas spread unevenly, this
    #        can concentrate traffic.
    #
    # "Cluster" (the alternative) balances perfectly but SNATs the source
    # address, so every request appears to come from a node IP.
    #
    # Because we use NLB IP-target mode, traffic goes straight to pods anyway,
    # so "Local" gives us the client IP with none of the usual downside.
    external_traffic_policy = "Local"
  }

  # Terraform will wait for AWS to finish provisioning and report back a
  # hostname. That genuinely takes 2-4 minutes; it is not stuck.
  wait_for_load_balancer = true

  timeouts {
    create = "15m"
    delete = "15m"
  }

  depends_on = [kubernetes_deployment.hello_web]
}
