#!/usr/bin/env bash
# ==========================================================================
# 99-teardown.sh -- Destroy everything, in the ONLY order AWS will accept.
#
#   ./99-teardown.sh              show the plan, then ask for confirmation
#   ./99-teardown.sh --dry-run    show the plan, change nothing
#   ./99-teardown.sh --yes        no questions asked
#   ./99-teardown.sh --yes --snapshots   also delete EBS snapshots
#   ./99-teardown.sh --keep-iam   leave the IAM role/profile behind
#
# WHY THE ORDER MATTERS
#   AWS refuses to delete a resource that something else still points at.
#   The dependency chain here is:
#       instance -> network interface -> security group
#       instance -> volume
#       instance -> instance profile -> role -> attached policies
#   So we always go from the outside in: terminate the instance first, wait
#   for it to really be gone, then unpick everything that was attached to it.
# ==========================================================================
set -uo pipefail   # NOT -e: teardown should keep going past "already gone"
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

DRY_RUN=false; ASSUME_YES=false; DEL_SNAPSHOTS=false; KEEP_IAM=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --yes|-y)    ASSUME_YES=true ;;
    --snapshots) DEL_SNAPSHOTS=true ;;
    --keep-iam)  KEEP_IAM=true ;;
    *) die "Unknown option: $arg" ;;
  esac
done

# RUN prints the command; in dry-run mode that is ALL it does.
# It writes to fd 3 (a saved copy of the real stdout) so that the
# ">/dev/null 2>&1" on the call sites cannot swallow the dry-run output.
exec 3>&1
RUN() {
  if $DRY_RUN; then
    printf '    \033[2m$ %s\033[0m\n' "$*" >&3
  else
    "$@"
  fi
}

AWSQ=(aws --region "$AWS_REGION")

# --------------------------------------------------------------------------
# STEP 0 - Work out what actually exists. The state file may be missing or
#          stale, so fall back to searching by tag.
# --------------------------------------------------------------------------
log "STEP 0/9  Discovering resources tagged ${TAG_KEY}=${TAG_VALUE} ..."

if [ -z "${INSTANCE_ID:-}" ]; then
  INSTANCE_ID="$("${AWSQ[@]}" ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')"
fi
if [ -z "${SG_ID:-}" ]; then
  SG_ID="$("${AWSQ[@]}" ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
  [ "$SG_ID" = "None" ] && SG_ID=""
fi
if [ -z "${ALLOC_ID:-}" ]; then
  ALLOC_ID="$("${AWSQ[@]}" ec2 describe-addresses \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --query 'Addresses[].AllocationId' --output text | tr '\t' ' ')"
fi
SNAP_IDS="$("${AWSQ[@]}" ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
  --query 'Snapshots[].SnapshotId' --output text | tr '\t' ' ')"

cat <<PLAN

  ┌──────────────────────────────────────────────────────────────┐
  │  TEARDOWN PLAN — region ${AWS_REGION}
  ├──────────────────────────────────────────────────────────────┤
  │  1. EC2 instance(s)   : ${INSTANCE_ID:-<none found>}
  │     (its root volume is DeleteOnTermination=true — the flow,
  │      queued data and provenance history all go with it)
  │  2. Extra EBS volumes : detected after termination
  │  3. Elastic IP(s)     : ${ALLOC_ID:-<none>}
  │  4. Orphan ENIs       : detected after termination
  │  5. Security group    : ${SG_ID:-<none>}
  │  6. Key pair          : ${KEY_NAME:-<none>} (+ ${KEY_FILE})
  │  7. IAM profile/role  : $($KEEP_IAM && echo "SKIPPED (--keep-iam)" || echo "${INSTANCE_PROFILE_NAME} / ${IAM_ROLE_NAME}")
  │  8. Snapshots         : $($DEL_SNAPSHOTS && echo "${SNAP_IDS:-<none>}" || echo "KEPT (pass --snapshots to delete)")
  │  9. Local state       : ${STATE_FILE}
  └──────────────────────────────────────────────────────────────┘

PLAN

if $DRY_RUN; then
  warn "DRY RUN — the commands below would be executed. Nothing will change."
elif ! $ASSUME_YES; then
  warn "This is irreversible. Run ./90-backup.sh first if you want the flow."
  read -r -p "  Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted. Nothing was changed."
fi

# --------------------------------------------------------------------------
# STEP 1 - Terminate the instance and WAIT. Everything else depends on this.
# --------------------------------------------------------------------------
if [ -n "${INSTANCE_ID:-}" ]; then
  log "STEP 1/9  Terminating instance(s): $INSTANCE_ID"

  # Termination protection blocks the API call, so clear it first.
  for id in $INSTANCE_ID; do
    RUN "${AWSQ[@]}" ec2 modify-instance-attribute \
      --instance-id "$id" --no-disable-api-termination >/dev/null 2>&1
  done

  # shellcheck disable=SC2086
  RUN "${AWSQ[@]}" ec2 terminate-instances --instance-ids $INSTANCE_ID >/dev/null 2>&1
  if ! $DRY_RUN; then
    log "          Waiting for full termination (up to ~5 min)..."
    # shellcheck disable=SC2086
    "${AWSQ[@]}" ec2 wait instance-terminated --instance-ids $INSTANCE_ID 2>/dev/null
    ok "Instance terminated (root volume deleted with it)"
  fi
else
  ok "STEP 1/9  No instance to terminate"
fi

# --------------------------------------------------------------------------
# STEP 2 - Any volume that survived (DeleteOnTermination=false, or a second
#          data disk you attached later).
# --------------------------------------------------------------------------
log "STEP 2/9  Checking for leftover EBS volumes..."
VOL_IDS="$("${AWSQ[@]}" ec2 describe-volumes \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text | tr '\t' ' ')"
if [ -n "$VOL_IDS" ]; then
  for v in $VOL_IDS; do
    RUN "${AWSQ[@]}" ec2 delete-volume --volume-id "$v" >/dev/null 2>&1 \
      && ok "Deleted volume $v"
  done
else
  ok "None (root volume already went with the instance)"
fi

# --------------------------------------------------------------------------
# STEP 3 - Elastic IPs. An UNATTACHED Elastic IP is billed hourly, so this
#          is the single easiest thing to forget and pay for forever.
# --------------------------------------------------------------------------
if [ -n "${ALLOC_ID:-}" ]; then
  log "STEP 3/9  Releasing Elastic IP(s): $ALLOC_ID"
  for a in $ALLOC_ID; do
    ASSOC="$("${AWSQ[@]}" ec2 describe-addresses --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    [ "$ASSOC" != "None" ] && [ -n "$ASSOC" ] && \
      RUN "${AWSQ[@]}" ec2 disassociate-address --association-id "$ASSOC" >/dev/null 2>&1
    RUN "${AWSQ[@]}" ec2 release-address --allocation-id "$a" >/dev/null 2>&1 \
      && ok "Released $a"
  done
else
  ok "STEP 3/9  No Elastic IPs"
fi

# --------------------------------------------------------------------------
# STEP 4 - Orphan network interfaces. These are the usual reason a security
#          group refuses to delete ("resource has a dependent object").
# --------------------------------------------------------------------------
if [ -n "${SG_ID:-}" ]; then
  log "STEP 4/9  Checking for network interfaces still using $SG_ID ..."
  ENI_IDS="$("${AWSQ[@]}" ec2 describe-network-interfaces \
    --filters "Name=group-id,Values=${SG_ID}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text | tr '\t' ' ')"
  if [ -n "$ENI_IDS" ]; then
    for e in $ENI_IDS; do
      RUN "${AWSQ[@]}" ec2 delete-network-interface --network-interface-id "$e" >/dev/null 2>&1 \
        && ok "Deleted ENI $e"
    done
  else
    ok "None"
  fi
else
  ok "STEP 4/9  No security group, so no interfaces to check"
fi

# --------------------------------------------------------------------------
# STEP 5 - Security group. Retries, because ENI detachment lags behind
#          termination by 30-90 seconds no matter what the waiter says.
# --------------------------------------------------------------------------
if [ -n "${SG_ID:-}" ]; then
  log "STEP 5/9  Deleting security group $SG_ID ..."
  if $DRY_RUN; then
    RUN "${AWSQ[@]}" ec2 delete-security-group --group-id "$SG_ID"
  else
    DELETED=false
    for attempt in $(seq 1 12); do
      if "${AWSQ[@]}" ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null; then
        DELETED=true; break
      fi
      printf '\r          attempt %02d/12 - still in use, waiting 10s...' "$attempt"
      sleep 10
    done
    echo
    $DELETED && ok "Deleted" || warn "Could not delete $SG_ID. Find the holder with:
            aws ec2 describe-network-interfaces --region $AWS_REGION \\
              --filters Name=group-id,Values=$SG_ID"
  fi
else
  ok "STEP 5/9  No security group"
fi

# --------------------------------------------------------------------------
# STEP 6 - Key pair (AWS side and the private key on your laptop).
# --------------------------------------------------------------------------
if [ -n "${KEY_NAME:-}" ]; then
  log "STEP 6/9  Deleting key pair $KEY_NAME ..."
  RUN "${AWSQ[@]}" ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 && ok "Deleted in AWS"
  if [ -f "$KEY_FILE" ]; then
    RUN rm -f "$KEY_FILE" && ok "Removed local $KEY_FILE"
  fi
else
  ok "STEP 6/9  No key pair"
fi

# --------------------------------------------------------------------------
# STEP 7 - IAM. Strict order: role out of profile -> delete profile ->
#          detach policies -> delete role. Skipping a step gives
#          "DeleteConflict: must remove roles from instance profile first".
# --------------------------------------------------------------------------
if $KEEP_IAM; then
  ok "STEP 7/9  IAM kept (--keep-iam)"
else
  log "STEP 7/9  Removing IAM objects..."
  RUN aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1
  RUN aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1
  # Detach every managed policy, not just the one we know about.
  if ! $DRY_RUN; then
    for arn in $(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
                 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$arn" 2>/dev/null \
        && ok "Detached $(basename "$arn")"
    done
    for p in $(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
               --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$p" 2>/dev/null
    done
  else
    RUN aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  fi
  RUN aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 && ok "Role deleted"
fi

# --------------------------------------------------------------------------
# STEP 8 - Snapshots (opt-in: they are your only rollback).
# --------------------------------------------------------------------------
if $DEL_SNAPSHOTS && [ -n "$SNAP_IDS" ]; then
  log "STEP 8/9  Deleting snapshots: $SNAP_IDS"
  for s in $SNAP_IDS; do
    RUN "${AWSQ[@]}" ec2 delete-snapshot --snapshot-id "$s" >/dev/null 2>&1 && ok "Deleted $s"
  done
elif [ -n "$SNAP_IDS" ]; then
  warn "STEP 8/9  Keeping snapshots: $SNAP_IDS  (~\$0.05/GB-month). Delete with --snapshots"
else
  ok "STEP 8/9  No snapshots"
fi

# --------------------------------------------------------------------------
# STEP 9 - Local files.
# --------------------------------------------------------------------------
log "STEP 9/9  Cleaning local files..."
RUN rm -f "$STATE_FILE"
RUN rm -rf "$BUILD_DIR"     # build/user-data.sh contains your password
ok "State and build directory removed (backups/ kept)"

# --------------------------------------------------------------------------
# VERIFY - trust nothing; ask AWS what is left.
# --------------------------------------------------------------------------
if $DRY_RUN; then
  echo; log "Dry run complete. Re-run without --dry-run to execute."
  exit 0
fi

echo
log "VERIFY  Anything still tagged ${TAG_KEY}=${TAG_VALUE}?"
LEFT=0
check() {  # check <label> <command...>
  local label="$1"; shift
  local out; out="$("$@" 2>/dev/null | tr '\t' ' ' | xargs 2>/dev/null)"
  if [ -n "$out" ] && [ "$out" != "None" ]; then
    warn "$label: $out"; LEFT=$((LEFT+1))
  else
    ok "$label: clear"
  fi
}
check "instances " "${AWSQ[@]}" ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "volumes   " "${AWSQ[@]}" ec2 describe-volumes \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Volumes[].VolumeId' --output text
check "addresses " "${AWSQ[@]}" ec2 describe-addresses \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Addresses[].AllocationId' --output text
check "sec groups" "${AWSQ[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" --query 'SecurityGroups[].GroupId' --output text

echo
if [ "$LEFT" -eq 0 ]; then
  log "Teardown complete. Nothing left billing."
else
  warn "$LEFT resource type(s) still present — see above, or run ./99b-force-cleanup.sh"
fi
