resource "kubernetes_config_map_v1" "web_content" {
  for_each = local.servers

  metadata {
    name      = each.value.name
    namespace = kubernetes_namespace_v1.web.metadata[0].name
  }

  data = {
    "index.html" = <<-HTML
      <!doctype html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>${each.value.heading}</title>
          <style>
            body { font-family: Arial, sans-serif; max-width: 760px; margin: 4rem auto; padding: 1rem; color: #102a43; }
            .box { border: 3px solid #102a43; border-radius: 12px; padding: 2rem; }
            code { background: #eef2f6; padding: .2rem .4rem; }
          </style>
        </head>
        <body>
          <main class="box">
            <h1>${each.value.heading}</h1>
            <p>${each.value.detail}</p>
            <p>This page is served by a small NGINX container running in EKS.</p>
          </main>
        </body>
      </html>
    HTML

    "nginx.conf" = <<-CONF
      worker_processes auto;
      pid /var/run/nginx.pid;
      events { worker_connections 1024; }
      http {
        include /etc/nginx/mime.types;
        default_type application/octet-stream;
        access_log /dev/stdout;
        error_log /dev/stderr warn;
        sendfile on;
        server {
          listen 8080;
          server_name _;
          root /usr/share/nginx/html;
          location / {
            try_files $uri $uri/ /index.html;
          }
          location /healthz {
            access_log off;
            return 200 "healthy\n";
          }
        }
      }
    CONF
  }
}
