#!/usr/bin/env bash
# ==========================================================================
# 99-teardown.sh -- Delete everything these scripts created, so the bill
# stops. Order matters: you cannot delete a security group that an instance
# is still using, so the instance goes first.
#   ./99-teardown.sh          asks for confirmation
#   ./99-teardown.sh --yes    no questions
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

echo "This will DELETE:"
echo "  instance      ${INSTANCE_ID:-<none>}   (and its encrypted EBS volume + all flow data)"
echo "  elastic ip    ${ALLOC_ID:-<none>}"
echo "  security grp  ${SG_ID:-<none>}"
echo "  key pair      ${KEY_NAME:-<none>}"
echo "  iam role      ${IAM_ROLE_NAME} + ${INSTANCE_PROFILE_NAME}"
echo
if [ "${1:-}" != "--yes" ]; then
  read -r -p "Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted."
fi

# 1. Instance ---------------------------------------------------------------
if [ -n "${INSTANCE_ID:-}" ]; then
  log "Terminating $INSTANCE_ID..."
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" 2>/dev/null || true
  ok "Terminated"
fi

# 2. Elastic IP (billed while unattached - always release it) ---------------
if [ -n "${ALLOC_ID:-}" ]; then
  log "Releasing Elastic IP..."
  aws ec2 release-address --region "$AWS_REGION" --allocation-id "$ALLOC_ID" 2>/dev/null || true
  ok "Released"
fi

# 3. Security group ---------------------------------------------------------
if [ -n "${SG_ID:-}" ]; then
  log "Deleting security group..."
  for _ in $(seq 1 10); do
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" 2>/dev/null && break
    sleep 10   # ENI detachment lags behind termination
  done
  ok "Deleted (or already gone)"
fi

# 4. Key pair ---------------------------------------------------------------
if [ -n "${KEY_NAME:-}" ]; then
  log "Deleting key pair..."
  aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$KEY_NAME" 2>/dev/null || true
  [ -f "$KEY_FILE" ] && rm -f "$KEY_FILE" && ok "Removed local $KEY_FILE"
fi

# 5. IAM (role must be emptied before deletion) -----------------------------
log "Removing IAM objects..."
aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
  --role-name "$IAM_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" 2>/dev/null || true
aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam delete-role --role-name "$IAM_ROLE_NAME" 2>/dev/null || true
ok "IAM cleaned"

rm -f "$STATE_FILE"
rm -rf "$BUILD_DIR"
log "Teardown complete. Verify nothing is left:"
echo "  aws ec2 describe-instances --region $AWS_REGION --filters Name=tag:${TAG_KEY},Values=${TAG_VALUE} Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId'"
