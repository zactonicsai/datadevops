#!/usr/bin/env bash
# Run every backup step in order. ALWAYS run this before any destroy.
#   ENV=prod ./scripts/backup/00-backup-all.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BACKUP_DIR="${BACKUP_ROOT}/${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)"
export BACKUP_DIR
mkdir -p "${BACKUP_DIR}"
printf '%s\n' "${BACKUP_DIR}" > "${BACKUP_ROOT}/.last"

header "BACKUP - ${NAME_PREFIX}"
banner_env
log "destination: ${BACKUP_DIR}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for step in "${DIR}"/[1-9]0-backup-*.sh; do
  ENVIRONMENT="${ENVIRONMENT}" BACKUP_DIR="${BACKUP_DIR}" bash "${step}" \
    || die "backup step failed: $(basename "${step}") - refusing to continue"
done

cat > "${BACKUP_DIR}/MANIFEST.txt" << MEOF
Backup manifest
  project      ${PROJECT_NAME}
  environment  ${ENVIRONMENT}
  region       ${AWS_REGION}
  account      $(aws_account_id)
  taken        $(date -u +%Y-%m-%dT%H:%M:%SZ)

Contents
  terraform.tfstate        state at backup time
  terraform-outputs.json   resolved outputs
  secrets.json             plaintext credentials (mode 600 - move to a vault)
  rds-snapshot-id.txt      manual snapshot that survives instance deletion
  inventory/               per-service describe output
MEOF

header "BACKUP COMPLETE"
ok "${BACKUP_DIR}"
find "${BACKUP_DIR}" -type f | sed 's|^|  |'
