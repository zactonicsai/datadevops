#!/usr/bin/env bash
# BACKUP 1/4 - Terraform state and the resolved configuration.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEST="${BACKUP_DIR:-${BACKUP_ROOT}/${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "${DEST}"

header "BACKUP 1/4 - TERRAFORM STATE"
cd "${PROJECT_DIR}"

if command -v terraform >/dev/null && [[ -d .terraform ]]; then
  terraform state pull > "${DEST}/terraform.tfstate" 2>/dev/null \
    && ok "state -> ${DEST}/terraform.tfstate" \
    || warn "could not pull remote state"
  terraform output -json > "${DEST}/terraform-outputs.json" 2>/dev/null \
    && ok "outputs -> ${DEST}/terraform-outputs.json" \
    || warn "no outputs available"
else
  warn "terraform not initialised here - skipping state backup"
fi

cp -f "${TFVARS_FILE}" "${DEST}/" 2>/dev/null && ok "tfvars copied"
printf '%s\n' "${DEST}" > "${BACKUP_ROOT}/.last"
