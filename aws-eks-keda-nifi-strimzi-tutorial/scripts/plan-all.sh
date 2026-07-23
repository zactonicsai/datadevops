#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

load_config
find_public_cidr
"${ROOT_DIR}/scripts/check-prerequisites.sh"

NETWORK_DIR="${ROOT_DIR}/terraform/01-network"
EKS_DIR="${ROOT_DIR}/terraform/02-eks"

# The network can always be planned because it has no earlier local-state dependency.
terraform_plan_folder "${NETWORK_DIR}"

# The EKS folder reads the network folder's local state. Skip it until that state exists.
if [[ -f "${NETWORK_DIR}/terraform.tfstate" ]]; then
  terraform_plan_folder "${EKS_DIR}"
else
  echo
  echo "Skipping 02-eks and later folders because 01-network has not been applied yet."
  echo "Run ./scripts/apply-all.sh, or apply 01-network first, then run this script again."
  exit 0
fi

# Kubernetes and Helm folders need both the EKS state and a working kubeconfig.
if [[ ! -f "${EKS_DIR}/terraform.tfstate" || ! -f "${KUBECONFIG_FILE}" ]]; then
  echo
  echo "Skipping Kubernetes and Helm folders because EKS or the project kubeconfig is not ready."
  echo "After EKS is applied, run ./scripts/update-kubeconfig.sh and run this script again."
  exit 0
fi

FOLDERS_AFTER_EKS=(
  "${ROOT_DIR}/terraform/03-metrics-server"
  "${ROOT_DIR}/terraform/04-keda"
  "${ROOT_DIR}/terraform/05-http-app"
  "${ROOT_DIR}/terraform/06-strimzi-operator"
  "${ROOT_DIR}/terraform/07-kafka-cluster"
  "${ROOT_DIR}/terraform/08-nifi-cluster"
  "${ROOT_DIR}/terraform/09-test-runner"
  "${ROOT_DIR}/terraform/10-test-tools"
)

for folder in "${FOLDERS_AFTER_EKS[@]}"; do
  terraform_plan_folder "${folder}"
done
