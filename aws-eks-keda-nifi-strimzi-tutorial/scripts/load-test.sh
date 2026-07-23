#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config

cleanup() {
  kubectl delete -f "${ROOT_DIR}/kubectl/http/load-generator.yaml" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl apply -f "${ROOT_DIR}/kubectl/http/load-generator.yaml"
kubectl rollout status deployment/load-generator -n test-tools --timeout=3m

scaled=false
echo "Generating HTTP load and watching KEDA-managed replicas."
for _ in $(seq 1 18); do
  kubectl get deployment -n web
  kubectl get hpa -n web

  replicas_a="$(kubectl get deployment hello-server-a -n web -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
  replicas_b="$(kubectl get deployment hello-server-b -n web -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"

  if [[ "${replicas_a:-0}" -gt 1 || "${replicas_b:-0}" -gt 1 ]]; then
    scaled=true
    break
  fi

  sleep 10
done

if [[ "${scaled}" != true ]]; then
  echo "KEDA did not raise either Deployment above one replica during this test."
  echo "Check: kubectl describe scaledobject -n web"
  exit 1
fi

echo "PASS: KEDA increased at least one web Deployment above one replica."
echo "The load generator will now be removed. KEDA will scale down after cooldown."
