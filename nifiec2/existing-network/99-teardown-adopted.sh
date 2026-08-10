#!/usr/bin/env bash
# ==========================================================================
# 99-teardown-adopted.sh -- Remove ONLY what this mode created.
#
#   the DNS record        (or restore the value that was there before)
#   the EC2 instance      and its encrypted volume
#   the security group
#   the IAM role          (skipped if you reused somebody else's)
#
# IT NEVER TOUCHES:
#   the VPC, the subnets, route tables, gateways, NAT, VPC endpoints,
#   or the hosted zone itself. Those are marked ADOPTED in the state file
#   and are somebody else's property.
#
#   ./99-teardown-adopted.sh --dry-run    show the plan only
#   ./99-teardown-adopted.sh              interactive
#   ./99-teardown-adopted.sh --yes        unattended
#   ./99-teardown-adopted.sh --keep-dns   leave the DNS record in place
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"
load_state

DRY_RUN=false; ASSUME_YES=false; KEEP_DNS=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=true ;;
    --yes|-y)   ASSUME_YES=true ;;
    --keep-dns) KEEP_DNS=true ;;
    *) die "Unknown option: $arg" ;;
  esac
done

exec 3>&1
RUN() { if $DRY_RUN; then printf '    \033[2m$ %s\033[0m\n' "$*" >&3; else "$@"; fi; }
A=(aws --region "$AWS_REGION")

# Discover by tag if the state file is gone. The Mode tag keeps this
# deployment separate from the build-your-own-network one.
[ -n "${INSTANCE_ID:-}" ] || INSTANCE_ID="$("${A[@]}" ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=tag:Mode,Values=existing-network" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ')"
[ -n "${SG_ID:-}" ] || SG_ID="$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${EX_SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
[ "${SG_ID:-}" = "None" ] && SG_ID=""

cat <<PLAN

  ┌──────────────────────────────────────────────────────────────┐
  │  ADOPTED — WILL NOT BE TOUCHED                               │
  ├──────────────────────────────────────────────────────────────┤
  │  VPC             ${VPC_ID:-<none>}
  │  Subnets         ${SUBNET_IDS:-<none>}
  │  Hosted zone     ${HOSTED_ZONE_ID:-<none>}  (the zone itself stays)
  │  Route tables, gateways, NAT, endpoints — untouched
  ├──────────────────────────────────────────────────────────────┤
  │  WILL BE DELETED                                             │
  ├──────────────────────────────────────────────────────────────┤
  │  1. DNS record   $($KEEP_DNS && echo "KEPT (--keep-dns)" || echo "${NIFI_DNS_NAME}")
  │  2. Instance     ${INSTANCE_ID:-<none>}   (and its encrypted volume)
  │  3. Security grp ${SG_ID:-<none>}
  │  4. IAM          $([ "${CREATED_IAM:-false}" = "true" ] && echo "${IAM_ROLE_NAME} / ${INSTANCE_PROFILE_NAME}" || echo "none — you reused an existing profile")
  │  5. Local state  ${STATE_FILE}
  └──────────────────────────────────────────────────────────────┘

PLAN

if $DRY_RUN; then
  warn "DRY RUN — nothing will change."
elif ! $ASSUME_YES; then
  read -r -p "  Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted. Nothing was changed."
fi

# --------------------------------------------------------------------------
# 1. DNS FIRST. Do it while you still know what the record says, and so
#    nobody is sent to an address that is about to stop answering.
# --------------------------------------------------------------------------
if $KEEP_DNS; then
  ok "STEP 1/5  DNS record kept"
elif [ "${DNS_RECORD_CREATED:-false}" = "true" ] && [ -n "${HOSTED_ZONE_ID:-}" ]; then
  log "STEP 1/5  DNS record ${NIFI_DNS_NAME}"
  CUR="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.' && Type=='A']|[0]" --output json 2>/dev/null)"

  if [ -z "$CUR" ] || [ "$CUR" = "null" ]; then
    ok "Already gone"
  elif [ "${DNS_RECORD_PREEXISTED:-false}" = "true" ] && [ -f "${BUILD_DIR}/previous-record.json" ]; then
    # Something was there before us. Put it back rather than deleting it.
    log "  Restoring the record that existed before we changed it"
    if $DRY_RUN; then
      RUN aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "UPSERT <previous-record.json>"
    else
      BATCH="$(jq -c --argjson r "$(cat "${BUILD_DIR}/previous-record.json")" \
        -n '{Comment:"restore pre-NiFi value",Changes:[{Action:"UPSERT",ResourceRecordSet:$r}]}')"
      aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch "$BATCH" >/dev/null && ok "Previous value restored"
    fi
  else
    # A delete must match the existing record exactly, so we send back
    # precisely what Route 53 currently holds.
    if $DRY_RUN; then
      RUN aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "DELETE ${NIFI_DNS_NAME} A"
    else
      BATCH="$(jq -c --argjson r "$CUR" -n '{Comment:"remove NiFi",Changes:[{Action:"DELETE",ResourceRecordSet:$r}]}')"
      aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
        --change-batch "$BATCH" >/dev/null && ok "Record deleted" \
        || warn "Could not delete the record — check it by hand in zone ${HOSTED_ZONE_ID}"
    fi
  fi
else
  ok "STEP 1/5  No DNS record recorded as ours"
fi

# --------------------------------------------------------------------------
# 2. The instance
# --------------------------------------------------------------------------
if [ -n "${INSTANCE_ID:-}" ]; then
  log "STEP 2/5  Terminating ${INSTANCE_ID}"
  for id in $INSTANCE_ID; do
    RUN "${A[@]}" ec2 modify-instance-attribute --instance-id "$id" --no-disable-api-termination >/dev/null 2>&1
  done
  # shellcheck disable=SC2086
  RUN "${A[@]}" ec2 terminate-instances --instance-ids $INSTANCE_ID >/dev/null 2>&1
  if ! $DRY_RUN; then
    log "          Waiting for termination..."
    # shellcheck disable=SC2086
    "${A[@]}" ec2 wait instance-terminated --instance-ids $INSTANCE_ID 2>/dev/null
    ok "Terminated (its volume went with it)"
  fi
else
  ok "STEP 2/5  No instance"
fi

# --------------------------------------------------------------------------
# 3. The security group we made. The subnet and VPC stay.
# --------------------------------------------------------------------------
if [ -n "${SG_ID:-}" ] && [ "${CREATED_SG:-true}" = "true" ]; then
  log "STEP 3/5  Security group ${SG_ID}"
  if $DRY_RUN; then
    RUN "${A[@]}" ec2 delete-security-group --group-id "$SG_ID"
  else
    DEL=false
    for attempt in $(seq 1 12); do
      "${A[@]}" ec2 delete-security-group --group-id "$SG_ID" 2>/dev/null && { DEL=true; break; }
      printf '\r          attempt %02d/12 - the network interface is still detaching...' "$attempt"
      sleep 10
    done
    echo
    $DEL && ok "Deleted" || warn "Could not delete ${SG_ID}. Something else may reference it:
             aws ec2 describe-network-interfaces --region $AWS_REGION --filters Name=group-id,Values=$SG_ID"
  fi
else
  ok "STEP 3/5  Security group kept"
fi

# --------------------------------------------------------------------------
# 4. IAM, only if we made it
# --------------------------------------------------------------------------
if [ "${CREATED_IAM:-false}" = "true" ]; then
  log "STEP 4/5  IAM"
  RUN aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1
  RUN aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1
  if ! $DRY_RUN; then
    for p in $(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
               --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$p" 2>/dev/null \
        && ok "Removed inline policy $p"
    done
    for arn in $(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
                 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$arn" 2>/dev/null \
        && ok "Detached $(basename "$arn")"
    done
  fi
  RUN aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 && ok "Role deleted"
else
  ok "STEP 4/5  IAM kept (you reused an existing instance profile)"
fi

# --------------------------------------------------------------------------
# 5. Local files
# --------------------------------------------------------------------------
log "STEP 5/5  Local cleanup"
RUN rm -f "$STATE_FILE"
RUN rm -rf "$BUILD_DIR"     # build/user-data-private.sh contains your password
ok "State and build directory removed"

if $DRY_RUN; then
  echo; log "Dry run complete."
  exit 0
fi

echo
log "VERIFY"
LEFT="$("${A[@]}" ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=tag:Mode,Values=existing-network" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | xargs)"
[ -z "$LEFT" ] && ok "No instances remain" || warn "Still present: $LEFT"

REC="$(aws route53 list-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID:-}" \
  --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.']|[0].Name" --output text 2>/dev/null)"
[ "$REC" = "None" ] || [ -z "$REC" ] && ok "No ${NIFI_DNS_NAME} record" || warn "Record still present: $REC"

echo
ok "The VPC, its subnets and the hosted zone are exactly as you found them."
