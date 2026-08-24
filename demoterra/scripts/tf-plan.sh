#!/usr/bin/env bash
# Produce a saved plan for the environment.
#   ENV=prod ./scripts/tf-plan.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

header "terraform plan - ${ENVIRONMENT}"
banner_env

[[ -f "${TFVARS_FILE}" ]] || die "missing ${TFVARS_FILE}"
run terraform plan -var-file="${TFVARS_FILE}" -out="${ENVIRONMENT}.tfplan"
ok "plan saved to ${ENVIRONMENT}.tfplan"
log "apply it with: ENV=${ENVIRONMENT} ./scripts/tf-apply.sh"
