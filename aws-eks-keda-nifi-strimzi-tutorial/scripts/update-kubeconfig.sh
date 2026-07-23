#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config

mkdir -p "$(dirname "${KUBECONFIG_FILE}")"
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${PROJECT_NAME}-${ENVIRONMENT}" \
  --alias "${PROJECT_NAME}-${ENVIRONMENT}" \
  --kubeconfig "${KUBECONFIG_FILE}"

kubectl config current-context
kubectl get nodes
