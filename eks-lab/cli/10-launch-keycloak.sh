#!/usr/bin/env bash
# =============================================================================
# 10-launch-keycloak.sh  —  ONE JOB: launch Keycloak.
#
# WHAT KEYCLOAK IS: the ID card office. It stores users, checks passwords, and
# hands out signed "hall passes" (tokens) that other applications trust.
#
# LAB SIMPLIFICATION: we run `start-dev`, which uses a small built-in database
# inside the pod. That means:
#   + no RDS instance to pay for (~$25/month saved)
#   + starts in 30 seconds
#   - everything is LOST if the pod restarts
#   - not supported for production, at all
# For production see Part 12 of the main tutorial (RDS + the Keycloak Operator).
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl
require NS_APPS

banner "Launch Keycloak"

kubectl create namespace "$NS_APPS" --dry-run=client -o yaml | kubectl apply -f -

# A random admin password, stored as a Kubernetes Secret rather than typed
# into a YAML file. Never put passwords in files you commit.
if ! kubectl -n "$NS_APPS" get secret keycloak-admin >/dev/null 2>&1; then
  KC_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  kubectl -n "$NS_APPS" create secret generic keycloak-admin \
    --from-literal=username=admin --from-literal=password="$KC_PASS"
  ok "Generated a random admin password"
fi

log "Applying the Keycloak manifest..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${NS_APPS}
spec:
  selector: { app: keycloak }
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${NS_APPS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: keycloak }
  template:
    metadata:
      labels: { app: keycloak }
    spec:
      securityContext:
        # Do not run as root. Ever. This is free security.
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: keycloak
          image: ${IMG_KEYCLOAK}
          args: ["start-dev"]
          env:
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom: { secretKeyRef: { name: keycloak-admin, key: username } }
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: { secretKeyRef: { name: keycloak-admin, key: password } }
            - name: KC_HTTP_ENABLED
              value: "true"
            - name: KC_HEALTH_ENABLED
              value: "true"
            # Tell Keycloak its own address so the links it generates work
            - name: KC_HOSTNAME_STRICT
              value: "false"
            - name: KC_PROXY_HEADERS
              value: "xforwarded"
          ports:
            - { containerPort: 8080, name: http }
            - { containerPort: 9000, name: management }
          resources:
            # requests = what the scheduler reserves. limits = the hard ceiling.
            # Always set both, or one greedy pod can starve the whole node.
            requests: { cpu: "200m", memory: "512Mi" }
            limits:   { cpu: "1",    memory: "1Gi" }
          startupProbe:
            # Keycloak takes ~40s to boot. A startup probe gives it room
            # WITHOUT making the liveness probe sloppy.
            httpGet: { path: /health/started, port: 9000 }
            failureThreshold: 30
            periodSeconds: 5
          readinessProbe:
            httpGet: { path: /health/ready, port: 9000 }
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /health/live, port: 9000 }
            periodSeconds: 30
            failureThreshold: 5
YAML

log "Waiting for Keycloak to be ready..."
kubectl -n "$NS_APPS" rollout status deployment/keycloak --timeout=300s

echo
ok "Keycloak is running."
echo
log "Open the admin console:"
echo "  kubectl -n ${NS_APPS} port-forward svc/keycloak 8080:8080"
echo "  then browse to http://localhost:8080"
echo
echo "  username: admin"
echo -n "  password: "
kubectl -n "$NS_APPS" get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d; echo
echo
log "Next: ./11-launch-kafka.sh"
