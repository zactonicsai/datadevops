#!/usr/bin/env bash
# Apply the saved plan, then run the full verification suite.
#   ENV=prod ./scripts/tf-apply.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

header "terraform apply - ${ENVIRONMENT}"
banner_env

PLAN_FILE="${PROJECT_DIR}/${ENVIRONMENT}.tfplan"
if [[ -f "${PLAN_FILE}" ]]; then
  run terraform apply "${PLAN_FILE}"
  rm -f "${PLAN_FILE}"
else
  warn "no saved plan found - planning and applying in one step"
  [[ "${FORCE}" == "1" ]] && APPROVE=(-auto-approve) || APPROVE=()
  run terraform apply -var-file="${TFVARS_FILE}" "${APPROVE[@]}"
fi

ok "apply complete"
log "running verification"
ENVIRONMENT="${ENVIRONMENT}" "${SCRIPTS_DIR}/verify/00-verify-all.sh" || warn "verification reported problems"
