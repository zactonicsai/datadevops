#!/usr/bin/env bash
# TEARDOWN 3/6 - RDS: instance, subnet group, parameter group.
# Refuses to run unless a completed manual snapshot exists.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 3/6 - RDS"
banner_env

DB_ID="$(db_identifier)"
STATUS="$(find_db_status)"

if [[ -n "${STATUS}" && "${STATUS}" != "None" ]]; then
  # --- Safety gate: a manual snapshot must already exist -------------------
  SNAP_COUNT="$(aws rds describe-db-snapshots --db-instance-identifier "${DB_ID}" \
    --snapshot-type manual --query 'length(DBSnapshots[?Status==`available`])' --output text 2>/dev/null || echo 0)"
  if [[ "${SNAP_COUNT}" -eq 0 && "${FORCE}" != "1" ]]; then
    die "no completed manual snapshot for ${DB_ID}. Run ./scripts/backup/30-backup-rds-snapshot.sh first (or set FORCE=1)."
  fi
  ok "manual snapshots available: ${SNAP_COUNT}"

  confirm "Delete RDS instance ${DB_ID}? Confirm by typing the stack prefix:"

  run_soft aws rds modify-db-instance --db-instance-identifier "${DB_ID}" \
    --no-deletion-protection --apply-immediately

  FINAL_SNAP="${NAME_PREFIX}-final-$(date -u +%Y%m%d%H%M%S)"
  run aws rds delete-db-instance --db-instance-identifier "${DB_ID}" \
    --final-db-snapshot-identifier "${FINAL_SNAP}" --no-skip-final-snapshot \
    || run_soft aws rds delete-db-instance --db-instance-identifier "${DB_ID}" --skip-final-snapshot

  if [[ "${DRY_RUN}" != "1" ]]; then
    log "waiting for ${DB_ID} to be deleted (several minutes)"
    run_soft aws rds wait db-instance-deleted --db-instance-identifier "${DB_ID}"
  fi
else
  warn "RDS instance ${DB_ID} not found"
fi

# --- Dependent groups, only deletable once the instance is gone ------------
run_soft aws rds delete-db-subnet-group --db-subnet-group-name "${NAME_PREFIX}-db-subnets"

PGS="$(aws rds describe-db-parameter-groups \
  --query "DBParameterGroups[?starts_with(DBParameterGroupName,'${NAME_PREFIX}-pg-')].DBParameterGroupName" \
  --output text 2>/dev/null || true)"
for pg in ${PGS}; do
  [[ "${pg}" == "None" ]] && continue
  run_soft aws rds delete-db-parameter-group --db-parameter-group-name "${pg}"
done

# --- Verify -----------------------------------------------------------------
if [[ -z "$(find_db_status)" || "$(find_db_status)" == "None" ]]; then
  ok "RDS teardown complete"
  log "surviving snapshots:"
  aws rds describe-db-snapshots --snapshot-type manual \
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier,'${NAME_PREFIX}')].{Id:DBSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime}" \
    --output table 2>/dev/null || true
else
  warn "RDS instance still present (status: $(find_db_status))"
fi
