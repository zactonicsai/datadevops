#!/usr/bin/env bash
###############################################################################
# 92-destroy-database.sh
#
# Backup teardown for the database layer (what 02-create-database.sh built).
#
# Order: instance -> wait for it to be gone -> parameter group -> secret
# The parameter group CANNOT be deleted while any instance still uses it,
# which is why we wait.
#
# Usage:  ./92-destroy-database.sh
#         FORCE=yes KEEP_SNAPSHOT=yes ./92-destroy-database.sh
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/keycloak-state.env"

step() { echo ""; echo "=========================================================="; echo ">>> $*"; echo "=========================================================="; }
info() { echo "    $*"; }
warn() { echo "    [!] $*"; }

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  warn "No state file. Using tag-based discovery."
  export PROJECT="${PROJECT:-keycloak-demo}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi

KEEP_SNAPSHOT="${KEEP_SNAPSHOT:-no}"

step "DESTROY: Database layer"
echo "  This will PERMANENTLY delete:"
echo "    - RDS instance ...... ${DB_IDENTIFIER:-<discover>}"
echo "    - Parameter group ... ${PARAM_GROUP:-<discover>}"
echo "    - DB secret ......... ${DB_SECRET_NAME:-<discover>}"
echo ""
echo "  ALL DATA IN THE DATABASE WILL BE LOST."
[[ "$KEEP_SNAPSHOT" == "yes" ]] && echo "  (KEEP_SNAPSHOT=yes: a final snapshot will be taken first)"
echo ""

if [[ "${FORCE:-no}" != "yes" ]]; then
  read -r -p "  Type 'destroy' to continue: " CONFIRM
  [[ "$CONFIRM" == "destroy" ]] || { echo "  Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Find the instance
# ---------------------------------------------------------------------------
step "1/5  Locating the RDS instance"

if [[ -z "${DB_IDENTIFIER:-}" ]]; then
  DB_IDENTIFIER=$(aws rds describe-db-instances \
    --query "DBInstances[?starts_with(DBInstanceIdentifier, '${PROJECT}-db')].DBInstanceIdentifier | [0]" \
    --output text 2>/dev/null)
  [[ "$DB_IDENTIFIER" == "None" ]] && DB_IDENTIFIER=""
fi

[[ -n "$DB_IDENTIFIER" ]] && info "Found $DB_IDENTIFIER" || warn "No RDS instance found"

# ---------------------------------------------------------------------------
# 2. Turn off deletion protection
# ---------------------------------------------------------------------------
step "2/5  Disabling deletion protection"
# If deletion protection is on, the delete call fails with a confusing error.
# Turning it off first makes the teardown reliable.

if [[ -n "$DB_IDENTIFIER" ]]; then
  aws rds modify-db-instance \
    --db-instance-identifier "$DB_IDENTIFIER" \
    --no-deletion-protection --apply-immediately >/dev/null 2>&1 \
    && info "Deletion protection off" \
    || info "Already off (or instance not modifiable right now)"
  sleep 5
fi

# ---------------------------------------------------------------------------
# 3. Delete the instance
# ---------------------------------------------------------------------------
step "3/5  Deleting the RDS instance (5-10 minutes)"

if [[ -n "$DB_IDENTIFIER" ]]; then
  if [[ "$KEEP_SNAPSHOT" == "yes" ]]; then
    SNAP_ID="${DB_IDENTIFIER}-final-$(date +%Y%m%d%H%M%S)"
    info "Taking a final snapshot: $SNAP_ID"
    info "NOTE: snapshots keep costing ~\$0.095/GB/month until you delete them."
    aws rds delete-db-instance \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --final-db-snapshot-identifier "$SNAP_ID" >/dev/null
  else
    aws rds delete-db-instance \
      --db-instance-identifier "$DB_IDENTIFIER" \
      --skip-final-snapshot \
      --delete-automated-backups >/dev/null
    info "Deleting with no final snapshot"
  fi

  info "Waiting for deletion to complete..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_IDENTIFIER" \
    && info "Database deleted - billing stopped" \
    || warn "Wait timed out; check the console"
else
  warn "Nothing to delete"
fi

# ---------------------------------------------------------------------------
# 4. Delete the parameter group
# ---------------------------------------------------------------------------
step "4/5  Deleting the DB parameter group"
# This only works once no instance references it, which is why we waited.

if [[ -z "${PARAM_GROUP:-}" ]]; then
  PARAM_GROUP=$(aws rds describe-db-parameter-groups \
    --query "DBParameterGroups[?starts_with(DBParameterGroupName, '${PROJECT}-pg18')].DBParameterGroupName | [0]" \
    --output text 2>/dev/null)
  [[ "$PARAM_GROUP" == "None" ]] && PARAM_GROUP=""
fi

if [[ -n "$PARAM_GROUP" ]]; then
  # Retry a few times: RDS sometimes reports the instance gone slightly
  # before it releases the parameter group.
  for ATTEMPT in 1 2 3 4 5; do
    if aws rds delete-db-parameter-group --db-parameter-group-name "$PARAM_GROUP" 2>/dev/null; then
      info "Deleted $PARAM_GROUP"
      break
    fi
    warn "Attempt $ATTEMPT failed, retrying in 20s..."
    sleep 20
  done
else
  warn "No parameter group found"
fi

# ---------------------------------------------------------------------------
# 5. Delete the secret
# ---------------------------------------------------------------------------
step "5/5  Deleting the database secret"

if [[ -n "${DB_SECRET_NAME:-}" ]]; then
  aws secretsmanager delete-secret --secret-id "$DB_SECRET_NAME" \
    --force-delete-without-recovery >/dev/null 2>&1 \
    && info "Deleted $DB_SECRET_NAME" \
    || warn "Could not delete $DB_SECRET_NAME"
else
  for S in $(aws secretsmanager list-secrets \
      --query "SecretList[?starts_with(Name, '${PROJECT}/db-credentials')].Name" \
      --output text 2>/dev/null); do
    aws secretsmanager delete-secret --secret-id "$S" --force-delete-without-recovery >/dev/null 2>&1 \
      && info "Deleted $S"
  done
fi

step "DATABASE LAYER DESTROYED"
cat <<SUMMARY

  Monthly savings from this teardown: ~\$15.11

  Still present (free, but tidy up with the next script):
    - VPC, subnets, security groups, route tables
    - IAM role, policy, instance profile

  Next:  ./91-destroy-network.sh

SUMMARY
