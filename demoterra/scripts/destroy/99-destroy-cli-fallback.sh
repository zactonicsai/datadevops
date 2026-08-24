#!/usr/bin/env bash
# CLI FALLBACK - tears the stack down with raw AWS CLI calls, in dependency
# order, without touching Terraform. Use when state is lost or corrupted, or
# when terraform destroy is stuck on a dependency.
#
#   ENV=dev DRY_RUN=1 ./scripts/destroy/99-destroy-cli-fallback.sh   # preview
#   ENV=dev ./scripts/destroy/99-destroy-cli-fallback.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "CLI TEARDOWN - ${NAME_PREFIX}"
banner_env
warn "this deletes resources directly; Terraform state will drift and should be discarded afterwards"

# --- Backups come first, always --------------------------------------------
if [[ "${SKIP_BACKUP:-0}" == "1" ]]; then
  warn "SKIP_BACKUP=1 - proceeding with no backup"
else
  log "running the backup suite before deleting anything"
  ENVIRONMENT="${ENVIRONMENT}" "${SCRIPTS_DIR}/backup/00-backup-all.sh" \
    || die "backup failed - refusing to destroy"
fi

confirm "Destroy every ${NAME_PREFIX} resource via the CLI? Confirm by typing the stack prefix:"
export FORCE=1  # already confirmed once; do not prompt per area

for step in "${DIR}"/[1-9]0-destroy-*.sh; do
  ENVIRONMENT="${ENVIRONMENT}" bash "${step}" || warn "step reported errors: $(basename "${step}")"
done

header "TEARDOWN COMPLETE"
log "post-teardown verification (everything below should be empty or absent)"
ENVIRONMENT="${ENVIRONMENT}" "${SCRIPTS_DIR}/verify/00-verify-all.sh" \
  && warn "resources are still responding - re-run this script" \
  || ok "verification found nothing left, as expected"
