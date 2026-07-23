#!/usr/bin/env bash
###############################################################################
# 93-destroy-keycloak.sh
#
# Backup teardown for the Keycloak layer (what 03-create-keycloak.sh built).
# Use this when 'terraform destroy' fails, or when you built with the CLI.
#
# Order matters and is the REVERSE of creation:
#   Elastic IP association -> instance -> Elastic IP -> secret
#
# Usage:  ./93-destroy-keycloak.sh          (asks for confirmation)
#         FORCE=yes ./93-destroy-keycloak.sh (no prompt)
###############################################################################

set -uo pipefail   # NOT -e: we want to keep going even if one delete fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/keycloak-state.env"

step() { echo ""; echo "=========================================================="; echo ">>> $*"; echo "=========================================================="; }
info() { echo "    $*"; }
warn() { echo "    [!] $*"; }

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  info "Loaded state from $STATE_FILE"
else
  warn "No state file. Falling back to tag-based discovery."
  export PROJECT="${PROJECT:-keycloak-demo}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi

# ---------------------------------------------------------------------------
# Confirmation - deleting is permanent
# ---------------------------------------------------------------------------
step "DESTROY: Keycloak compute layer"
echo "  This will PERMANENTLY delete:"
echo "    - EC2 instance ...... ${INSTANCE_ID:-<discover by tag>}"
echo "    - Elastic IP ........ ${PUBLIC_IP:-<discover by tag>}"
echo "    - Admin secret ...... ${KC_SECRET_NAME:-<discover by name>}"
echo ""

if [[ "${FORCE:-no}" != "yes" ]]; then
  read -r -p "  Type 'destroy' to continue: " CONFIRM
  [[ "$CONFIRM" == "destroy" ]] || { echo "  Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Find the instance if we don't have its ID
# ---------------------------------------------------------------------------
step "1/4  Locating the EC2 instance"

if [[ -z "${INSTANCE_ID:-}" ]]; then
  # Search by tag. Exclude already-terminated ones or we waste time waiting.
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=${PROJECT}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
  [[ "$INSTANCE_ID" == "None" ]] && INSTANCE_ID=""
fi

if [[ -n "$INSTANCE_ID" ]]; then
  info "Found $INSTANCE_ID"
else
  warn "No running instance found - skipping"
fi

# ---------------------------------------------------------------------------
# 2. Release the Elastic IP BEFORE terminating
# ---------------------------------------------------------------------------
step "2/4  Disassociating and releasing the Elastic IP"
# Do this first. An EIP left behind after the instance dies is "idle" and
# AWS charges roughly $3.60/month for it forever. This is the single most
# common way people leak money after a teardown.

if [[ -z "${EIP_ALLOC_ID:-}" ]]; then
  EIP_ALLOC_ID=$(aws ec2 describe-addresses \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null)
  [[ "$EIP_ALLOC_ID" == "None" ]] && EIP_ALLOC_ID=""
fi

if [[ -n "$EIP_ALLOC_ID" ]]; then
  ASSOC_ID=$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" \
    --query 'Addresses[0].AssociationId' --output text 2>/dev/null)

  if [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]]; then
    aws ec2 disassociate-address --association-id "$ASSOC_ID" && info "Disassociated $ASSOC_ID"
  fi

  aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" \
    && info "Released Elastic IP $EIP_ALLOC_ID (billing stopped)" \
    || warn "Could not release $EIP_ALLOC_ID - check the console manually"
else
  warn "No Elastic IP found - skipping"
fi

# ---------------------------------------------------------------------------
# 3. Terminate the instance
# ---------------------------------------------------------------------------
step "3/4  Terminating the EC2 instance"
# 'terminate' is permanent and also deletes the root volume, because we set
# DeleteOnTermination=true at launch. 'stop' would keep charging for storage.

if [[ -n "$INSTANCE_ID" ]]; then
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null \
    && info "Termination requested for $INSTANCE_ID"

  info "Waiting for the instance to fully terminate..."
  aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" \
    && info "Instance terminated - compute billing stopped" \
    || warn "Wait timed out; verify in the console"
else
  warn "Nothing to terminate"
fi

# ---------------------------------------------------------------------------
# 4. Delete the admin secret
# ---------------------------------------------------------------------------
step "4/4  Deleting the Keycloak admin secret"
# --force-delete-without-recovery skips the normal 7-30 day grace period.
# In production you would OMIT this flag so you can undo a mistake.

if [[ -n "${KC_SECRET_NAME:-}" ]]; then
  aws secretsmanager delete-secret \
    --secret-id "$KC_SECRET_NAME" \
    --force-delete-without-recovery >/dev/null 2>&1 \
    && info "Deleted $KC_SECRET_NAME" \
    || warn "Could not delete $KC_SECRET_NAME (may already be gone)"
else
  # Try to find it by prefix
  for S in $(aws secretsmanager list-secrets \
      --query "SecretList[?starts_with(Name, '${PROJECT}/db-keycloak-admin')].Name" \
      --output text 2>/dev/null); do
    aws secretsmanager delete-secret --secret-id "$S" --force-delete-without-recovery >/dev/null 2>&1 \
      && info "Deleted $S"
  done
fi

step "KEYCLOAK LAYER DESTROYED"
cat <<SUMMARY

  Monthly savings from this teardown: ~\$17.86

  Still running (delete with the next script):
    - RDS database
    - Database secret

  Next:  ./92-destroy-database.sh

SUMMARY
