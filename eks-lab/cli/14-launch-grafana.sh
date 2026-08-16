#!/usr/bin/env bash
# =============================================================================
# 14-launch-grafana.sh  —  ONE JOB: launch monitoring.
#
# WHAT THIS IS:
#   Prometheus  = the collector. Every 30 seconds it visits each component and
#                 asks "what are your numbers right now?", then stores them.
#   Grafana     = the dashboard. It draws graphs from what Prometheus stored.
#
# We install both with one Helm chart: kube-prometheus-stack. It is the
# standard for Kubernetes monitoring.
#
# COST / SIZE WARNING: this is the heaviest thing in the lab (~1.5 GiB RAM).
# With the default 2 x t3.large you may need a third node:
#   NODE_DESIRED=3 ./07-create-nodegroup.sh   (or just skip this script)
#
# We turn OFF Alertmanager and shrink retention to keep it lean.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl helm
require NS_MON

banner "Launch Prometheus + Grafana"

warn "This adds roughly 1.5 GiB of memory usage to the cluster."
confirm "Install monitoring?"

log "Adding the Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

kubectl create namespace "$NS_MON" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n "$NS_MON" get secret grafana-admin >/dev/null 2>&1; then
  GF_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
  kubectl -n "$NS_MON" create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$GF_PASS"
fi

log "Installing kube-prometheus-stack (3-5 minutes)..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace "$NS_MON" \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.retention=2d \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=5Gi \
  --set grafana.admin.existingSecret=grafana-admin \
  --set grafana.persistence.enabled=false \
  --set grafana.resources.requests.cpu=50m \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.memory=256Mi \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --wait --timeout 10m

# ---------------------------------------------------------------------------
# Tell Prometheus to also scrape our own applications.
#
# A ServiceMonitor is a small object that says "scrape this Service, on this
# port, at this path". The Prometheus Operator watches for them and rewrites
# Prometheus's config automatically — you never edit a config file.
# ---------------------------------------------------------------------------
log "Adding a ServiceMonitor so Prometheus scrapes Keycloak..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak-metrics
  namespace: ${NS_APPS}
  labels: { app: keycloak, monitoring: "true" }
spec:
  selector: { app: keycloak }
  ports:
    - { name: management, port: 9000, targetPort: 9000 }
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: keycloak
  namespace: ${NS_MON}
  labels: { release: monitoring }
spec:
  namespaceSelector: { matchNames: ["${NS_APPS}"] }
  selector:
    matchLabels: { monitoring: "true" }
  endpoints:
    - port: management
      path: /metrics
      interval: 30s
YAML

echo
ok "Monitoring installed."
echo
log "Open Grafana:"
echo "  kubectl -n ${NS_MON} port-forward svc/monitoring-grafana 3000:80"
echo "  then browse to http://localhost:3000"
echo
echo "  username: admin"
echo -n "  password: "
kubectl -n "$NS_MON" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
echo
log "Dashboards already included: 'Kubernetes / Compute Resources / Namespace (Pods)'"
log "is the one to open first — pick namespace '${NS_APPS}' to watch your apps."
echo
log "Next: ./15-create-nifi-flow.sh"
