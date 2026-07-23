#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
find_public_cidr

FOLDERS=(
  "${ROOT_DIR}/terraform/10-test-tools"
  "${ROOT_DIR}/terraform/09-test-runner"
  "${ROOT_DIR}/terraform/08-nifi-cluster"
  "${ROOT_DIR}/terraform/07-kafka-cluster"
  "${ROOT_DIR}/terraform/06-strimzi-operator"
  "${ROOT_DIR}/terraform/05-http-app"
  "${ROOT_DIR}/terraform/04-keda"
  "${ROOT_DIR}/terraform/03-metrics-server"
  "${ROOT_DIR}/terraform/02-eks"
  "${ROOT_DIR}/terraform/01-network"
)

for folder in "${FOLDERS[@]}"; do
  terraform_destroy_folder "${folder}"
done

echo "Destroy sequence complete. Review retained EBS volumes if retention was enabled."
