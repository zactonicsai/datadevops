#!/usr/bin/env bash
# =============================================================================
# 13-launch-webapp.sh  —  ONE JOB: launch the little web app.
#
# WHAT IT IS: a ~40 line Python web page with a text box. You type a message,
# press Send, and it publishes that message to Kafka. That is all it does.
#
# WHY NO DOCKER BUILD? Building an image would need a registry (ECR), a build
# machine, and a push step. Instead we mount the code from a ConfigMap into a
# stock python image and install two libraries at startup.
#   + zero build infrastructure, easy to read and edit
#   - re-installs libraries on every restart, needs internet
# For a real app, build a proper image. See build-webapp-image.sh for that path.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl
require NS_APPS KAFKA_BOOTSTRAP

banner "Launch the web app (message producer)"

log "Storing the application code in a ConfigMap..."
cat <<'PYEOF' > /tmp/app.py
import json, os, datetime
from flask import Flask, request, render_template_string
from kafka import KafkaProducer

BOOTSTRAP = os.environ["KAFKA_BOOTSTRAP"]
TOPIC     = os.environ.get("KAFKA_TOPIC", "messages")

app = Flask(__name__)
producer = None

def get_producer():
    """Connect lazily so the pod starts even if Kafka is briefly unavailable."""
    global producer
    if producer is None:
        producer = KafkaProducer(
            bootstrap_servers=BOOTSTRAP,
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            retries=5,
        )
    return producer

PAGE = """
<!doctype html><title>Message Sender</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 20px}
 input,button{font-size:16px;padding:10px}
 input{width:70%} .ok{color:#0a7a34} .err{color:#b00}
 code{background:#f2f2f2;padding:2px 6px;border-radius:3px}
</style>
<h1>Send a message</h1>
<p>Goes to Kafka topic <code>{{topic}}</code>, then NiFi copies it to S3.</p>
<form method="post">
  <input name="message" placeholder="Type anything..." autofocus required>
  <button type="submit">Send</button>
</form>
{% if status %}<p class="{{cls}}">{{status}}</p>{% endif %}
"""

@app.route("/", methods=["GET", "POST"])
def index():
    status, cls = None, "ok"
    if request.method == "POST":
        text = request.form.get("message", "")
        payload = {
            "message": text,
            "sent_at": datetime.datetime.now(datetime.UTC).isoformat(),
            "source":  "webapp",
        }
        try:
            get_producer().send(TOPIC, payload).get(timeout=10)
            status = f"Sent to Kafka: {text}"
        except Exception as e:                    # noqa: BLE001
            status, cls = f"Failed: {e}", "err"
    return render_template_string(PAGE, status=status, cls=cls, topic=TOPIC)

@app.route("/healthz")
def healthz():
    return "ok", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
PYEOF

kubectl -n "$NS_APPS" create configmap webapp-code \
  --from-file=app.py=/tmp/app.py --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/app.py

log "Applying the web app manifest..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: webapp
  namespace: ${NS_APPS}
spec:
  selector: { app: webapp }
  ports:
    - { name: http, port: 80, targetPort: 8000 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
  namespace: ${NS_APPS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: webapp }
  template:
    metadata:
      labels: { app: webapp }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: webapp
          image: ${IMG_PYTHON}
          command: ["/bin/sh", "-c"]
          args:
            - |
              pip install --quiet --no-cache-dir --target /tmp/libs flask kafka-python-ng
              export PYTHONPATH=/tmp/libs
              exec python /app/app.py
          env:
            - { name: KAFKA_BOOTSTRAP, value: "${KAFKA_BOOTSTRAP}" }
            - { name: KAFKA_TOPIC,     value: "${KAFKA_TOPIC}" }
            - { name: HOME,            value: "/tmp" }
          ports:
            - { containerPort: 8000, name: http }
          volumeMounts:
            - { name: code, mountPath: /app }
            - { name: tmp,  mountPath: /tmp }
          resources:
            requests: { cpu: "50m",  memory: "128Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
          startupProbe:
            # Generous: it has to pip-install before it can serve anything
            httpGet: { path: /healthz, port: 8000 }
            failureThreshold: 40
            periodSeconds: 5
          readinessProbe:
            httpGet: { path: /healthz, port: 8000 }
            periodSeconds: 15
      volumes:
        - name: code
          configMap: { name: webapp-code }
        - name: tmp
          emptyDir: {}
YAML

log "Waiting for the web app..."
kubectl -n "$NS_APPS" rollout status deployment/webapp --timeout=300s

echo
ok "Web app is running."
echo
log "Open it:"
echo "  kubectl -n ${NS_APPS} port-forward svc/webapp 8000:80"
echo "  then browse to http://localhost:8000"
echo
log "Next: ./14-launch-grafana.sh   (or skip straight to ./15-create-nifi-flow.sh)"
