# =============================================================================
# 04-webapp/main.tf   --   TWO TINY HTTP SERVERS SERVING A HELLO PAGE
# =============================================================================
# THE GOAL OF THIS LAYER
# Run two small web servers that return a "hello" page, expose them through a
# load balancer, and wire up KEDA so the number of servers grows automatically
# when they get busy.
#
# THE KUBERNETES OBJECTS INVOLVED, AND WHY EACH EXISTS:
#
#   ConfigMap  - holds our HTML template and nginx config as plain text,
#                separate from the container image. This is the "separate
#                config from code" principle: we use the stock public nginx
#                image and inject our content, rather than building, hosting
#                and maintaining a custom image.
#
#   Deployment - says "keep N copies of this pod running". It creates a
#                ReplicaSet, which creates Pods. If a pod dies the ReplicaSet
#                replaces it. If you change the image, the Deployment rolls
#                the change out gradually instead of all at once.
#
#   Service    - gives the pods ONE stable address. Essential, because
#                individual pods are ephemeral: they get new IPs when they
#                restart, and there may be 2 of them or 12. A Service is a
#                stable name in front of a moving target.
#
#   ScaledObject - KEDA's instruction to watch a metric and adjust the
#                Deployment's replica count. (In scaling.tf.)
# =============================================================================

# -----------------------------------------------------------------------------
# NAMESPACE
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "webapp" {
  metadata {
    name = var.app_namespace

    labels = {
      # nginx as configured here runs as a non-root user on a high port with
      # no Linux capabilities, so it satisfies the strictest Pod Security
      # profile. See the security_context blocks in deployment.tf.
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"

      "app.kubernetes.io/part-of" = "hello-web"
    }
  }
}

# -----------------------------------------------------------------------------
# CONFIGMAP: our web page template and our nginx configuration
# -----------------------------------------------------------------------------
# A ConfigMap is a dictionary of text stored in the Kubernetes API. Pods mount
# its keys as files. Each key below becomes a file inside the container.
#
# LIMITS WORTH KNOWING:
#   - A ConfigMap maxes out at roughly 1 MiB. It is for configuration, not for
#     shipping application assets.
#   - It is NOT for secrets. Contents are stored unencrypted and readable by
#     anyone with ConfigMap read access in this namespace. Passwords belong in
#     a Secret, which IS encrypted at rest thanks to the KMS key from layer 01.
#
# HOW WE MAKE THE PAGE SHOW THE POD NAME:
# We store a TEMPLATE containing shell-style placeholders like ${POD_NAME}.
# An "init container" (a container that runs to completion before the main one
# starts) runs `envsubst` over the template, substituting real environment
# variables that Kubernetes injects via the Downward API. The rendered file
# lands in a shared emptyDir volume that nginx then serves.
#
# WHY THIS INDIRECTION RATHER THAN SOMETHING SIMPLER? Because nginx's
# sub_filter directive works on nginx's OWN variables, not on Unix environment
# variables -- a subtle distinction that trips up a lot of people. Rendering
# the file once at startup with envsubst is unambiguous and always works.
resource "kubernetes_config_map" "web_content" {
  metadata {
    name      = "web-content"
    namespace = kubernetes_namespace.webapp.metadata[0].name

    labels = {
      "app.kubernetes.io/name" = "hello-web"
    }
  }

  data = {
    # -------------------------------------------------------------------------
    # The HTML template.
    # -------------------------------------------------------------------------
    # $${POD_NAME} is Terraform escaping. Terraform's own template syntax uses
    # ${...}, so writing $${...} emits a LITERAL ${...} into the file. That is
    # exactly what envsubst expects to find and replace at container startup.
    "index.html.template" = <<-HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Hello from Kubernetes</title>
        <style>
          /* Inline CSS keeps this one self-contained file with no external
             requests, so the demo works even from a network that blocks CDNs. */
          body {
            font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
            display: flex; align-items: center; justify-content: center;
            min-height: 100vh; margin: 0;
            background: #0f172a; color: #e2e8f0;
          }
          .card {
            background: #1e293b; padding: 2.5rem 3rem;
            border-radius: 12px; border: 1px solid #334155;
            text-align: center; max-width: 34rem;
          }
          h1 { margin: 0 0 0.75rem; font-size: 1.75rem; color: #38bdf8; }
          p  { margin: 0.3rem 0; line-height: 1.55; }
          .label { color: #94a3b8; font-size: 0.8rem;
                   text-transform: uppercase; letter-spacing: 0.05em;
                   margin-top: 1rem; }
          .value { font-family: ui-monospace, "SF Mono", Menlo, monospace;
                   color: #4ade80; word-break: break-all; font-size: 0.95rem; }
          .hint { margin-top: 1.75rem; font-size: 0.8rem; color: #64748b; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Hello from Kubernetes</h1>
          <p>Served by a small nginx pod running on Amazon EKS.</p>

          <p class="label">Pod</p>
          <p class="value">$${POD_NAME}</p>

          <p class="label">Node</p>
          <p class="value">$${NODE_NAME}</p>

          <p class="label">Pod IP</p>
          <p class="value">$${POD_IP}</p>

          <p class="hint">
            Refresh a few times. The pod name should change as the load
            balancer sends you to a different replica &mdash; that is proof
            the Service is spreading traffic across pods.
          </p>
        </div>
      </body>
      </html>
    HTML

    # -------------------------------------------------------------------------
    # nginx configuration.
    # -------------------------------------------------------------------------
    # Note every $ that nginx should see is written as $$ so Terraform passes
    # it through literally rather than trying to interpolate it.
    "default.conf" = <<-NGINXCONF
      # ---------------------------------------------------------------------
      # nginx config for the hello-web demo.
      # ---------------------------------------------------------------------

      server {
        # LISTEN ON 8080, NOT 80 -- this is deliberate and important.
        #
        # On Linux, binding a port below 1024 requires root or the
        # CAP_NET_BIND_SERVICE capability. Our security policy runs this
        # container as a non-root user with ALL capabilities dropped, so port
        # 80 is simply unavailable to us.
        #
        # Listening on 8080 is what lets this pod satisfy the "restricted" Pod
        # Security profile. The Service maps public port 80 to this container
        # port, so users still just visit http://<address>/ with no port.
        listen 8080;
        server_name _;              # "_" matches any Host header

        # Serve from the emptyDir the init container rendered into.
        root /usr/share/nginx/html;
        index index.html;

        location / {
          try_files $$uri $$uri/ /index.html;
        }

        # ---- Health check endpoint ----
        # Kubernetes probes hit this. Returning a fixed string with no disk
        # access makes it fast and independent of whether content rendered.
        location = /healthz {
          access_log off;           # do not fill the log with probe traffic
          add_header Content-Type text/plain;
          return 200 'ok';
        }

        # ---- Load-generation endpoint, used to demonstrate autoscaling ----
        # There is no clever CPU-burning trick here, and that is on purpose:
        # nginx is extremely efficient, so a single request costs almost
        # nothing no matter what we ask it to do.
        #
        # The way we actually drive CPU up is VOLUME. Because we cap each pod
        # at 200m CPU (a fifth of one core) in deployment.tf, a few thousand
        # requests per second is more than enough to saturate it and trip the
        # KEDA threshold. tests/load-test.sh generates exactly that.
        #
        # This endpoint exists so load traffic is easy to distinguish from
        # real traffic in the access log, and so probes are not counted.
        location = /burn {
          access_log off;
          add_header Content-Type text/plain;
          # gzip the response to add a little per-request CPU cost.
          gzip on;
          gzip_types text/plain;
          gzip_min_length 1;
          return 200 '$$request_id $$request_id $$request_id $$request_id $$request_id $$request_id $$request_id $$request_id';
        }

        # ---- Basic hardening headers ----
        # Cheap, and good habits to build.
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
      }
    NGINXCONF
  }
}
