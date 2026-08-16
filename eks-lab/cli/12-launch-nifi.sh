#!/usr/bin/env bash
# =============================================================================
# 12-launch-nifi.sh  —  ONE JOB: launch NiFi.
#
# WHAT NIFI IS: a visual conveyor-belt builder. You drag boxes onto a canvas
# and connect them with arrows. Each box is a "processor" that does one thing
# (read from Kafka, filter, write to S3). NiFi runs the flow continuously and
# remembers exactly what happened to every message.
#
# THE KEY PART: this pod uses the ServiceAccount "nifi" that step 08
# annotated with an IAM role. That is how NiFi gets permission to write to S3
# WITHOUT any AWS keys stored anywhere. No access key, no secret key, nothing
# to leak. The credentials are fetched at runtime and expire in an hour.
#
# LAB SIMPLIFICATION: single-user login (a generated username/password).
# Run ./12b-enable-nifi-oidc.sh afterwards to switch it to Keycloak login.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl
require NS_APPS S3_BUCKET NIFI_ROLE_ARN

banner "Launch NiFi"

NIFI_USER="${NIFI_USER:-labadmin}"
if ! kubectl -n "$NS_APPS" get secret nifi-single-user >/dev/null 2>&1; then
  # NiFi requires a password of at least 12 characters
  NIFI_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
  kubectl -n "$NS_APPS" create secret generic nifi-single-user \
    --from-literal=username="$NIFI_USER" --from-literal=password="$NIFI_PASS"
  ok "Generated NiFi credentials"
fi

log "Applying the NiFi manifest..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: nifi
  namespace: ${NS_APPS}
spec:
  selector: { app: nifi }
  ports:
    - { name: https, port: 8443, targetPort: 8443 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nifi
  namespace: ${NS_APPS}
spec:
  serviceName: nifi
  replicas: 1
  selector:
    matchLabels: { app: nifi }
  template:
    metadata:
      labels: { app: nifi }
    spec:
      # <<< THIS LINE is what connects the pod to its AWS permissions >>>
      serviceAccountName: nifi
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: nifi
          image: ${IMG_NIFI}
          env:
            - name: NIFI_WEB_HTTPS_PORT
              value: "8443"
            - name: SINGLE_USER_CREDENTIALS_USERNAME
              valueFrom: { secretKeyRef: { name: nifi-single-user, key: username } }
            - name: SINGLE_USER_CREDENTIALS_PASSWORD
              valueFrom: { secretKeyRef: { name: nifi-single-user, key: password } }
            # NiFi refuses requests whose Host header it does not recognise.
            # This is a real security control (it blocks Host-header injection),
            # but it means you MUST list every name people will use.
            - name: NIFI_WEB_PROXY_HOST
              value: "localhost:8443,nifi.${NS_APPS}.svc.cluster.local:8443,127.0.0.1:8443"
            - name: NIFI_JVM_HEAP_INIT
              value: "512m"
            - name: NIFI_JVM_HEAP_MAX
              value: "1g"
          ports:
            - { containerPort: 8443, name: https }
          volumeMounts:
            - { name: data, mountPath: /opt/nifi/nifi-current/repositories }
          resources:
            requests: { cpu: "300m", memory: "1536Mi" }
            limits:   { cpu: "1500m", memory: "3Gi" }
          startupProbe:
            # NiFi is slow to start (60-120s). Be generous here so the
            # liveness probe does not kill it mid-boot in a loop.
            tcpSocket: { port: 8443 }
            failureThreshold: 40
            periodSeconds: 10
          readinessProbe:
            tcpSocket: { port: 8443 }
            periodSeconds: 15
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources: { requests: { storage: 10Gi } }
YAML

log "Waiting for NiFi (this one is slow — up to 3 minutes)..."
kubectl -n "$NS_APPS" rollout status statefulset/nifi --timeout=600s

echo
log "Proving IRSA works — asking the pod who it is in AWS:"
kubectl -n "$NS_APPS" exec nifi-0 -- env | grep -E 'AWS_ROLE_ARN|AWS_WEB_IDENTITY' || \
  warn "AWS env vars missing — the service account annotation may be wrong"
echo
ok "If AWS_ROLE_ARN above ends in '-nifi-irsa', the pod has its own AWS identity."
echo
log "Open the NiFi UI:"
echo "  kubectl -n ${NS_APPS} port-forward svc/nifi 8443:8443"
echo "  then browse to https://localhost:8443/nifi"
echo "  (your browser will warn about the self-signed certificate — that is expected)"
echo
echo -n "  username: "; kubectl -n "$NS_APPS" get secret nifi-single-user -o jsonpath='{.data.username}' | base64 -d; echo
echo -n "  password: "; kubectl -n "$NS_APPS" get secret nifi-single-user -o jsonpath='{.data.password}' | base64 -d; echo
echo
log "Next: ./13-launch-webapp.sh"
