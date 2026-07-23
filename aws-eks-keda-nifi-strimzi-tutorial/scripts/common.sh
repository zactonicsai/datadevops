#!/usr/bin/env bash
# Shared helper functions for all project scripts.

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ROOT_DIR}/config/project.env"
LOG_DIR="${ROOT_DIR}/logs"
KUBECONFIG_FILE="${ROOT_DIR}/.kube/config"

mkdir -p "${LOG_DIR}" "$(dirname "${KUBECONFIG_FILE}")"

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Missing ${CONFIG_FILE}."
    echo "Create it with: cp config/project.env.example config/project.env"
    exit 1
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  export AWS_REGION PROJECT_NAME ENVIRONMENT KUBERNETES_VERSION
  export AWS_DEFAULT_REGION="${AWS_REGION}"
  export KUBECONFIG="${KUBECONFIG_FILE}"

  export TF_VAR_aws_region="${AWS_REGION}"
  export TF_VAR_project_name="${PROJECT_NAME}"
  export TF_VAR_environment="${ENVIRONMENT}"
  export TF_VAR_kubernetes_version="${KUBERNETES_VERSION}"
  export TF_VAR_cluster_name="${PROJECT_NAME}-${ENVIRONMENT}"
  export TF_VAR_kubeconfig_path="${KUBECONFIG_FILE}"
  export TF_VAR_node_instance_types="[\"${NODE_INSTANCE_TYPE}\"]"
  export TF_VAR_node_desired_size="${NODE_DESIRED_SIZE}"
  export TF_VAR_node_min_size="${NODE_MIN_SIZE}"
  export TF_VAR_node_max_size="${NODE_MAX_SIZE}"
  export TF_VAR_node_disk_size_gb="${NODE_DISK_SIZE_GB}"
  export TF_VAR_runner_instance_type="${RUNNER_INSTANCE_TYPE}"
  export TF_VAR_retain_application_volumes="${RETAIN_APPLICATION_VOLUMES}"
}

find_public_cidr() {
  if [[ -n "${PUBLIC_ACCESS_CIDR:-}" ]]; then
    export TF_VAR_public_access_cidrs="[\"${PUBLIC_ACCESS_CIDR}\"]"
    return
  fi

  local public_ip
  public_ip="$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '[:space:]')"
  if [[ -z "${public_ip}" ]]; then
    echo "Could not discover the public IP address."
    echo "Set PUBLIC_ACCESS_CIDR in config/project.env, for example 203.0.113.10/32."
    exit 1
  fi

  export TF_VAR_public_access_cidrs="[\"${public_ip}/32\"]"
  echo "EKS public API access will be limited to ${public_ip}/32."
}

run_logged() {
  local name="$1"
  shift
  local log_file="${LOG_DIR}/${name}-$(date +%Y%m%d-%H%M%S).log"

  echo
  echo "===== ${name} ====="
  echo "Log: ${log_file}"
  "$@" 2>&1 | tee "${log_file}"
}

terraform_apply_folder() {
  local folder="$1"
  local name
  name="$(basename "${folder}")"

  pushd "${folder}" >/dev/null
  run_logged "${name}-init" terraform init -upgrade
  run_logged "${name}-apply" terraform apply -auto-approve
  popd >/dev/null
}

terraform_plan_folder() {
  local folder="$1"
  local name
  name="$(basename "${folder}")"

  pushd "${folder}" >/dev/null
  run_logged "${name}-init" terraform init -upgrade
  run_logged "${name}-plan" terraform plan
  popd >/dev/null
}

terraform_destroy_folder() {
  local folder="$1"
  local name
  name="$(basename "${folder}")"

  if [[ ! -f "${folder}/terraform.tfstate" ]]; then
    echo "Skipping ${name}; no local state file exists."
    return
  fi

  pushd "${folder}" >/dev/null
  run_logged "${name}-destroy" terraform destroy -auto-approve
  popd >/dev/null
}
