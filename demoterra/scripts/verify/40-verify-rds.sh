#!/usr/bin/env bash
# AREA 4/7 - RDS: availability, Multi-AZ, backups, encryption, protection.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 4/7 - RDS"

DB_ID="$(db_identifier)"
DB="$(aws rds describe-db-instances --db-instance-identifier "${DB_ID}" \
      --query 'DBInstances[0]' --output json 2>/dev/null || true)"
[[ -n "${DB}" && "${DB}" != "null" ]] || { check_fail "RDS instance ${DB_ID} not found"; check_summary; exit 1; }

aws rds describe-db-instances --db-instance-identifier "${DB_ID}" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Engine:EngineVersion,MultiAZ:MultiAZ,AZ:AvailabilityZone,Standby:SecondaryAvailabilityZone,Storage:AllocatedStorage,Encrypted:StorageEncrypted}' \
  --output table

status="$(jq -r '.DBInstanceStatus' <<< "${DB}")"
[[ "${status}" == "available" ]] && check_pass "status: available" || check_fail "status: ${status}"

jq -e '.MultiAZ' >/dev/null <<< "${DB}" \
  && check_pass "Multi-AZ enabled (standby in $(jq -r '.SecondaryAvailabilityZone' <<< "${DB}"))" \
  || check_fail "Multi-AZ disabled - an AZ failure takes the database down"

jq -e '.StorageEncrypted' >/dev/null <<< "${DB}" \
  && check_pass "storage encrypted" || check_fail "storage is not encrypted"

jq -e '.PubliclyAccessible | not' >/dev/null <<< "${DB}" \
  && check_pass "not publicly accessible" || check_fail "instance is publicly accessible"

jq -e '.DeletionProtection' >/dev/null <<< "${DB}" \
  && check_pass "deletion protection on" || warn "deletion protection is off"

retention="$(jq -r '.BackupRetentionPeriod' <<< "${DB}")"
[[ "${retention}" -ge 7 ]] \
  && check_pass "backup retention: ${retention} days" \
  || check_fail "backup retention: ${retention} days - too short for production"

# --- Latest restorable point and recent snapshots --------------------------
log "latest restorable time: $(jq -r '.LatestRestorableTime // "n/a"' <<< "${DB}")"
aws rds describe-db-snapshots --db-instance-identifier "${DB_ID}" \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[:5].{Id:DBSnapshotIdentifier,Type:SnapshotType,Created:SnapshotCreateTime,Status:Status}' \
  --output table 2>/dev/null || warn "no snapshots yet"

# --- Cross-region backup replication ---------------------------------------
REPL="$(aws rds describe-db-instance-automated-backups \
  --query "DBInstanceAutomatedBackups[?DBInstanceIdentifier=='${DB_ID}'].{Region:Region,Status:Status}" \
  --output json 2>/dev/null || echo '[]')"
[[ "$(jq 'length' <<< "${REPL}")" -gt 0 ]] \
  && log "automated backups: $(jq -c . <<< "${REPL}")" \
  || warn "no replicated automated backups (enable_cross_region_backup_replication)"

check_summary
