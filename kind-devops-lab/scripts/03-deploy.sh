#!/usr/bin/env bash
# Step 3: install Gitea (git server) and Jenkins (build server) into the cluster.
source "$(dirname "$0")/lib.sh"
need kubectl; need helm

log "creating the '${NAMESPACE}' namespace"
kubectl apply -f "${ROOT_DIR}/k8s/namespace.yaml"

log "deploying Gitea"
kubectl apply -f "${ROOT_DIR}/k8s/gitea.yaml"
kubectl -n "${NAMESPACE}" rollout status deploy/gitea --timeout=300s

log "adding the Jenkins helm chart repo"
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing Jenkins (first run downloads plugins, be patient)"
helm upgrade --install jenkins jenkins/jenkins \
  --namespace "${NAMESPACE}" \
  --values "${ROOT_DIR}/k8s/jenkins-values.yaml" \
  --wait --timeout 15m

kubectl -n "${NAMESPACE}" get pods,svc
log "Jenkins:  http://$(jenkins_addr)   (admin / admin123)"
log "Gitea:    http://$(gitea_addr)"
