#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
find_public_cidr
"${ROOT_DIR}/scripts/check-prerequisites.sh"

FOLDERS_BEFORE_KUBECONFIG=(
  "${ROOT_DIR}/terraform/01-network"
  "${ROOT_DIR}/terraform/02-eks"
)

FOLDERS_AFTER_KUBECONFIG=(
  "${ROOT_DIR}/terraform/03-metrics-server"
  "${ROOT_DIR}/terraform/04-keda"
  "${ROOT_DIR}/terraform/05-http-app"
  "${ROOT_DIR}/terraform/06-strimzi-operator"
  "${ROOT_DIR}/terraform/07-kafka-cluster"
  "${ROOT_DIR}/terraform/08-nifi-cluster"
  "${ROOT_DIR}/terraform/09-test-runner"
  "${ROOT_DIR}/terraform/10-test-tools"
)

for folder in "${FOLDERS_BEFORE_KUBECONFIG[@]}"; do
  terraform_apply_folder "${folder}"
done

run_logged "update-kubeconfig" "${ROOT_DIR}/scripts/update-kubeconfig.sh"

for folder in "${FOLDERS_AFTER_KUBECONFIG[@]}"; do
  terraform_apply_folder "${folder}"
done

run_logged "cluster-tests" "${ROOT_DIR}/scripts/run-tests-local.sh"

echo
echo "Build complete. Read README.md for browser, load-test, and SSM commands."
