#!/usr/bin/env bash
# Initialise Terraform against the environment's remote state.
#   ENV=dev ./scripts/tf-init.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

header "terraform init - ${ENVIRONMENT}"
banner_env

BACKEND_CONFIG="${PROJECT_DIR}/environments/${ENVIRONMENT}.backend.hcl"
if [[ -f "${BACKEND_CONFIG}" ]]; then
  run terraform init -reconfigure -backend-config="${BACKEND_CONFIG}"
else
  warn "no backend config at ${BACKEND_CONFIG} - initialising with local state"
  run terraform init -reconfigure
fi
ok "initialised"
