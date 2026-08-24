#!/usr/bin/env bash
# BACKUP 3/4 - Take a manual RDS snapshot and wait for it to complete.
# Manual snapshots outlive the instance; automated ones do not.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEST="${BACKUP_DIR:-$(cat "${BACKUP_ROOT}/.last" 2>/dev/null || echo "${BACKUP_ROOT}/${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)")}"
mkdir -p "${DEST}"

header "BACKUP 3/4 - RDS SNAPSHOT"

DB_ID="$(db_identifier)"
STATUS="$(find_db_status)"
[[ -n "${STATUS}" && "${STATUS}" != "None" ]] || { warn "RDS ${DB_ID} not found - skipping"; exit 0; }
[[ "${STATUS}" == "available" ]] || warn "instance status is ${STATUS} - the snapshot may fail"

SNAP_ID="${NAME_PREFIX}-manual-$(date -u +%Y%m%d%H%M%S)"

run aws rds create-db-snapshot \
  --db-instance-identifier "${DB_ID}" \
  --db-snapshot-identifier "${SNAP_ID}" \
  --tags "Key=Project,Value=${PROJECT_NAME}" "Key=Environment,Value=${ENVIRONMENT}" "Key=Purpose,Value=pre-destroy"

if [[ "${DRY_RUN}" != "1" ]]; then
  log "waiting for ${SNAP_ID} to complete (this can take several minutes)"
  aws rds wait db-snapshot-completed --db-snapshot-identifier "${SNAP_ID}" \
    && ok "snapshot ${SNAP_ID} available" \
    || die "snapshot ${SNAP_ID} did not complete - do NOT destroy anything"

  aws rds describe-db-snapshots --db-snapshot-identifier "${SNAP_ID}" \
    --query 'DBSnapshots[0].{Id:DBSnapshotIdentifier,Status:Status,Size:AllocatedStorage,Created:SnapshotCreateTime,Encrypted:Encrypted}' \
    --output table | tee "${DEST}/rds-snapshot.txt"
  printf '%s\n' "${SNAP_ID}" > "${DEST}/rds-snapshot-id.txt"
fi

log "restore later with:"
log "  aws rds restore-db-instance-from-db-snapshot --db-instance-identifier ${DB_ID}-restored --db-snapshot-identifier ${SNAP_ID}"
