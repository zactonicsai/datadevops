#!/usr/bin/env bash
# ==========================================================================
# 99-teardown.sh -- Destroy everything, in the ONLY order AWS will accept.
#
#   ./99-teardown.sh              show the plan, then ask for confirmation
#   ./99-teardown.sh --dry-run    show the plan, change nothing
#   ./99-teardown.sh --yes        no questions asked
#   ./99-teardown.sh --yes --snapshots   also delete EBS snapshots
#   ./99-teardown.sh --keep-iam   leave the IAM role/profile behind
#   ./99-teardown.sh --keep-vpc   leave the VPC and subnets behind
#
# WHY THE ORDER MATTERS
#   AWS refuses to delete anything another resource still points at:
#
#     VPC ◀── subnet ◀── network interface ◀── instance
#      ▲         ▲
#      │         └── route table association
#      ├── route table
#      ├── internet gateway (must be DETACHED first)
#      └── security group
#
#   So we work from the outside in. The instance dies first, and the VPC —
#   which everything else lives inside — dies last.
#
#   The VPC, subnets, route tables and internet gateway are only deleted if
#   02-network.sh actually CREATED them (CREATED_* flags in .deploy-state).
#   If you set REUSE_DEFAULT_VPC=true, your default VPC is never touched.
# ==========================================================================
set -uo pipefail   # NOT -e: teardown must continue past "already gone"
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

DRY_RUN=false; ASSUME_YES=false; DEL_SNAPSHOTS=false; KEEP_IAM=false; KEEP_VPC=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --yes|-y)    ASSUME_YES=true ;;
    --snapshots) DEL_SNAPSHOTS=true ;;
    --keep-iam)  KEEP_IAM=true ;;
    --keep-vpc)  KEEP_VPC=true ;;
    *) die "Unknown option: $arg" ;;
  esac
done

# RUN prints the command in dry-run mode and does nothing else. It writes to
# fd 3 (a saved copy of stdout) so the ">/dev/null" at the call sites cannot
# swallow the dry-run output.
exec 3>&1
RUN() {
  if $DRY_RUN; then printf '    \033[2m$ %s\033[0m\n' "$*" >&3
  else "$@"; fi
}

A=(aws --region "$AWS_REGION")
TAGF="Name=tag:${TAG_KEY},Values=${TAG_VALUE}"

# ==========================================================================
# STEP 0 - Find what exists. The state file may be missing, so fall back to
#          searching by tag. We only ever tag things we created ourselves.
# ==========================================================================
log "STEP 0/12  Discovering resources tagged ${TAG_KEY}=${TAG_VALUE} ..."

find_ids() { "${A[@]}" ec2 "$@" 2>/dev/null | tr '\t' ' ' | xargs 2>/dev/null; }

[ -n "${INSTANCE_ID:-}" ] || INSTANCE_ID="$(find_ids describe-instances \
  --filters "$TAGF" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

[ -n "${ALLOC_ID:-}" ] || ALLOC_ID="$(find_ids describe-addresses \
  --filters "$TAGF" --query 'Addresses[].AllocationId' --output text)"

[ -n "${VPC_ID:-}" ] || VPC_ID="$(find_ids describe-vpcs \
  --filters "$TAGF" --query 'Vpcs[].VpcId' --output text)"

# Inside the VPC, find everything by VPC id rather than trusting the state file.
if [ -n "${VPC_ID:-}" ]; then
  # Every non-default security group in the VPC, not just NiFi's. The
  # Keycloak group lives here too, and any group left behind blocks the
  # VPC from being deleted.
  SG_ID="$(find_ids describe-security-groups \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  ALL_SUBNETS="$(find_ids describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[].SubnetId' --output text)"
  ALL_RTBS="$(find_ids describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' --output text)"
  IGW_ID="$(find_ids describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[].InternetGatewayId' --output text)"
else
  [ -n "${SG_ID:-}" ] || SG_ID="$(find_ids describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" --query 'SecurityGroups[].GroupId' --output text)"
  ALL_SUBNETS=""; ALL_RTBS=""; IGW_ID="${IGW_ID:-}"
fi

SNAP_IDS="$(find_ids describe-snapshots --owner-ids self --filters "$TAGF" \
  --query 'Snapshots[].SnapshotId' --output text)"

# Is the VPC ours to delete?
OWN_VPC=false
[ "${CREATED_VPC:-false}" = "true" ] && [ -n "${VPC_ID:-}" ] && OWN_VPC=true
$KEEP_VPC && OWN_VPC=false

cat <<PLAN

  ┌──────────────────────────────────────────────────────────────┐
  │  TEARDOWN PLAN — region ${AWS_REGION}
  ├──────────────────────────────────────────────────────────────┤
  │   1. EC2 instance(s) : ${INSTANCE_ID:-<none>}
  │      (root volume is DeleteOnTermination=true — your flow,
  │       queued data and provenance history go with it)
  │   2. EBS volumes     : any left in 'available' state
  │   3. Elastic IP(s)   : ${ALLOC_ID:-<none>}
  │   4. Network i/faces : any orphans in the VPC
  │   5. Security groups : ${SG_ID:-<none>}
  │      (all non-default groups in the VPC, Keycloak's included)
  │   6. Subnets         : $($OWN_VPC && echo "${ALL_SUBNETS:-<none>}" || echo "KEPT")
  │   7. Route tables    : $($OWN_VPC && echo "${ALL_RTBS:-<none>}" || echo "KEPT")
  │   8. Internet gwy    : $($OWN_VPC && echo "${IGW_ID:-<none>}" || echo "KEPT")
  │   9. VPC             : $($OWN_VPC && echo "${VPC_ID} (we created it)" || echo "${VPC_ID:-<none>} — KEPT, not ours")
  │  10. Key pair        : ${KEY_NAME:-<none>}
  │  11. IAM             : $($KEEP_IAM && echo "KEPT (--keep-iam)" || echo "${INSTANCE_PROFILE_NAME} / ${IAM_ROLE_NAME}")
  │  12. Snapshots       : $($DEL_SNAPSHOTS && echo "${SNAP_IDS:-<none>}" || echo "KEPT (use --snapshots)")
  └──────────────────────────────────────────────────────────────┘

PLAN

if $DRY_RUN; then
  warn "DRY RUN — nothing will change."
elif ! $ASSUME_YES; then
  warn "This is irreversible. Run ./90-backup.sh first if you want the flow."
  read -r -p "  Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted. Nothing was changed."
fi

# ==========================================================================
# STEP 1 - Instance. Everything else waits on this.
# ==========================================================================
if [ -n "${INSTANCE_ID:-}" ]; then
  log "STEP 1/12  Terminating: $INSTANCE_ID"
  for id in $INSTANCE_ID; do
    RUN "${A[@]}" ec2 modify-instance-attribute \
      --instance-id "$id" --no-disable-api-termination >/dev/null 2>&1
  done
  # shellcheck disable=SC2086
  RUN "${A[@]}" ec2 terminate-instances --instance-ids $INSTANCE_ID >/dev/null 2>&1
  if ! $DRY_RUN; then
    log "           Waiting for full termination (up to ~5 min)..."
    # shellcheck disable=SC2086
    "${A[@]}" ec2 wait instance-terminated --instance-ids $INSTANCE_ID 2>/dev/null
    ok "Terminated (root volume deleted with it)"
  fi
else
  ok "STEP 1/12  No instance"
fi

# ==========================================================================
# STEP 2 - Volumes that survived termination
# ==========================================================================
log "STEP 2/12  Leftover EBS volumes"
VOL_IDS="$(find_ids describe-volumes --filters "$TAGF" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text)"
if [ -n "$VOL_IDS" ]; then
  for v in $VOL_IDS; do
    RUN "${A[@]}" ec2 delete-volume --volume-id "$v" >/dev/null 2>&1 && ok "Deleted $v"
  done
else
  ok "None"
fi

# ==========================================================================
# STEP 3 - Elastic IPs. Billed hourly even when unattached.
# ==========================================================================
if [ -n "${ALLOC_ID:-}" ]; then
  log "STEP 3/12  Releasing Elastic IP(s): $ALLOC_ID"
  for a in $ALLOC_ID; do
    ASSOC="$("${A[@]}" ec2 describe-addresses --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    [ -n "$ASSOC" ] && [ "$ASSOC" != "None" ] && \
      RUN "${A[@]}" ec2 disassociate-address --association-id "$ASSOC" >/dev/null 2>&1
    RUN "${A[@]}" ec2 release-address --allocation-id "$a" >/dev/null 2>&1 && ok "Released $a"
  done
else
  ok "STEP 3/12  No Elastic IPs"
fi

# ==========================================================================
# STEP 4 - Orphan network interfaces. The usual reason steps 5-6 fail.
# ==========================================================================
log "STEP 4/12  Orphan network interfaces"
ENI_FILTER=("Name=status,Values=available")
[ -n "${VPC_ID:-}" ] && ENI_FILTER+=("Name=vpc-id,Values=${VPC_ID}")
[ -z "${VPC_ID:-}" ] && [ -n "${SG_ID:-}" ] && ENI_FILTER=("Name=group-id,Values=${SG_ID}" "Name=status,Values=available")
ENI_IDS="$(find_ids describe-network-interfaces --filters "${ENI_FILTER[@]}" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
if [ -n "$ENI_IDS" ]; then
  for e in $ENI_IDS; do
    RUN "${A[@]}" ec2 delete-network-interface --network-interface-id "$e" >/dev/null 2>&1 \
      && ok "Deleted $e"
  done
else
  ok "None"
fi

# ==========================================================================
# STEP 5 - Security group. Retries while ENIs finish detaching.
# ==========================================================================
if [ -n "${SG_ID:-}" ]; then
  log "STEP 5/12  Security group(s): $SG_ID"
  if $DRY_RUN; then
    for g in $SG_ID; do RUN "${A[@]}" ec2 delete-security-group --group-id "$g"; done
  else
    # Groups can reference each other (the Keycloak group allows traffic
    # from the NiFi group), and AWS will not delete a group another group
    # still points at. Strip every rule first, then delete.
    for g in $SG_ID; do
      PERMS="$("${A[@]}" ec2 describe-security-groups --group-ids "$g" \
        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)"
      if [ -n "$PERMS" ] && [ "$PERMS" != "[]" ] && [ "$PERMS" != "null" ]; then
        "${A[@]}" ec2 revoke-security-group-ingress --group-id "$g" \
          --ip-permissions "$PERMS" >/dev/null 2>&1 && ok "Cleared inbound rules on $g"
      fi
    done
    for g in $SG_ID; do
      DELETED=false
      for attempt in $(seq 1 12); do
        "${A[@]}" ec2 delete-security-group --group-id "$g" 2>/dev/null && { DELETED=true; break; }
        printf '\r           %s attempt %02d/12 - still in use, waiting 10s...' "$g" "$attempt"
        sleep 10
      done
      echo
      $DELETED && ok "Deleted $g" || warn "Could not delete $g — find the holder with:
             aws ec2 describe-network-interfaces --region $AWS_REGION --filters Name=group-id,Values=$g"
    done
  fi
else
  ok "STEP 5/12  No security groups"
fi

# ==========================================================================
# STEP 6 - Subnets. Only ours. A subnet will not delete while an ENI lives
#          in it, which is why steps 1 and 4 came first.
# ==========================================================================
if $OWN_VPC && [ -n "$ALL_SUBNETS" ]; then
  log "STEP 6/12  Subnets: $ALL_SUBNETS"
  for s in $ALL_SUBNETS; do
    if $DRY_RUN; then
      RUN "${A[@]}" ec2 delete-subnet --subnet-id "$s"
    else
      DEL=false
      for attempt in $(seq 1 6); do
        "${A[@]}" ec2 delete-subnet --subnet-id "$s" 2>/dev/null && { DEL=true; break; }
        sleep 10
      done
      $DEL && ok "Deleted $s" || warn "Could not delete $s (something still lives in it)"
    fi
  done
else
  ok "STEP 6/12  Subnets kept"
fi

# ==========================================================================
# STEP 7 - Route tables. Associations vanish with their subnets, but any
#          leftover association must be dropped before the table will go.
#          The VPC's MAIN route table cannot be deleted and is excluded.
# ==========================================================================
if $OWN_VPC && [ -n "$ALL_RTBS" ]; then
  log "STEP 7/12  Route tables: $ALL_RTBS"
  for rt in $ALL_RTBS; do
    for assoc in $("${A[@]}" ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
        --output text 2>/dev/null); do
      RUN "${A[@]}" ec2 disassociate-route-table --association-id "$assoc" >/dev/null 2>&1 \
        && ok "Disassociated $assoc"
    done
    RUN "${A[@]}" ec2 delete-route-table --route-table-id "$rt" >/dev/null 2>&1 \
      && ok "Deleted $rt"
  done
else
  ok "STEP 7/12  Route tables kept"
fi

# ==========================================================================
# STEP 8 - Internet gateway: DETACH, then delete. Skipping the detach gives
#          "DependencyViolation: has dependencies and cannot be deleted".
# ==========================================================================
if $OWN_VPC && [ -n "${IGW_ID:-}" ]; then
  log "STEP 8/12  Internet gateway $IGW_ID"
  for g in $IGW_ID; do
    RUN "${A[@]}" ec2 detach-internet-gateway \
      --internet-gateway-id "$g" --vpc-id "$VPC_ID" >/dev/null 2>&1 && ok "Detached $g"
    RUN "${A[@]}" ec2 delete-internet-gateway --internet-gateway-id "$g" >/dev/null 2>&1 \
      && ok "Deleted $g"
  done
else
  ok "STEP 8/12  Internet gateway kept"
fi

# ==========================================================================
# STEP 9 - The VPC itself. Its default security group, default route table
#          and network ACL are removed by AWS automatically.
# ==========================================================================
if $OWN_VPC; then
  log "STEP 9/12  VPC $VPC_ID"
  if $DRY_RUN; then
    RUN "${A[@]}" ec2 delete-vpc --vpc-id "$VPC_ID"
  else
    DEL=false
    for attempt in $(seq 1 6); do
      "${A[@]}" ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null && { DEL=true; break; }
      printf '\r           attempt %02d/6 - dependencies remain, waiting 10s...' "$attempt"
      sleep 10
    done
    echo
    if $DEL; then
      ok "Deleted $VPC_ID"
    else
      warn "Could not delete $VPC_ID. List what is still inside it:"
      echo "             aws ec2 describe-network-interfaces --region $AWS_REGION --filters Name=vpc-id,Values=$VPC_ID"
      echo "             aws ec2 describe-subnets            --region $AWS_REGION --filters Name=vpc-id,Values=$VPC_ID"
      echo "             aws ec2 describe-security-groups    --region $AWS_REGION --filters Name=vpc-id,Values=$VPC_ID"
    fi
  fi
else
  ok "STEP 9/12  VPC kept (${VPC_ID:-none} was not created by us, or --keep-vpc)"
fi

# ==========================================================================
# STEP 10 - Key pair
# ==========================================================================
if [ -n "${KEY_NAME:-}" ]; then
  log "STEP 10/12 Key pair $KEY_NAME"
  RUN "${A[@]}" ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 && ok "Deleted in AWS"
  [ -f "$KEY_FILE" ] && RUN rm -f "$KEY_FILE" && ok "Removed local $KEY_FILE"
else
  ok "STEP 10/12 No key pair"
fi

# ==========================================================================
# STEP 11 - IAM. Strict order: role out of profile -> delete profile ->
#           detach policies -> delete role.
# ==========================================================================
if $KEEP_IAM; then
  ok "STEP 11/12 IAM kept (--keep-iam)"
else
  log "STEP 11/12 IAM"
  RUN aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1
  RUN aws iam delete-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1
  if $DRY_RUN; then
    RUN aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  else
    for arn in $(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
                 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$arn" 2>/dev/null \
        && ok "Detached $(basename "$arn")"
    done
    for p in $(aws iam list-role-policies --role-name "$IAM_ROLE_NAME" \
               --query 'PolicyNames[]' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "$p" 2>/dev/null
    done
  fi
  RUN aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 && ok "Role deleted"
fi

# ==========================================================================
# STEP 12 - Snapshots (opt-in) and local files
# ==========================================================================
if $DEL_SNAPSHOTS && [ -n "$SNAP_IDS" ]; then
  log "STEP 12/12 Snapshots: $SNAP_IDS"
  for s in $SNAP_IDS; do
    RUN "${A[@]}" ec2 delete-snapshot --snapshot-id "$s" >/dev/null 2>&1 && ok "Deleted $s"
  done
elif [ -n "$SNAP_IDS" ]; then
  warn "STEP 12/12 Keeping snapshots: $SNAP_IDS (~\$0.05/GB-month). Delete with --snapshots"
else
  ok "STEP 12/12 No snapshots"
fi

RUN rm -f "$STATE_FILE"
RUN rm -rf "$BUILD_DIR"      # build/user-data.sh contains your password
ok "Local state and build directory cleaned (backups/ kept)"

# ==========================================================================
# VERIFY - trust nothing; ask AWS what is left.
# ==========================================================================
if $DRY_RUN; then
  echo; log "Dry run complete. Re-run without --dry-run to execute."
  exit 0
fi

echo
log "VERIFY  Anything still tagged ${TAG_KEY}=${TAG_VALUE}?"
LEFT=0
check() {  # check <label> <aws-subcommand...>
  local label="$1"; shift
  local out; out="$(find_ids "$@")"
  if [ -n "$out" ] && [ "$out" != "None" ]; then warn "$label: $out"; LEFT=$((LEFT+1))
  else ok "$label: clear"; fi
}
check "instances  " describe-instances --filters "$TAGF" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "volumes    " describe-volumes    --filters "$TAGF" --query 'Volumes[].VolumeId'       --output text
check "addresses  " describe-addresses  --filters "$TAGF" --query 'Addresses[].AllocationId' --output text
check "vpcs       " describe-vpcs       --filters "$TAGF" --query 'Vpcs[].VpcId'             --output text
check "subnets    " describe-subnets    --filters "$TAGF" --query 'Subnets[].SubnetId'       --output text
check "route tbls " describe-route-tables --filters "$TAGF" --query 'RouteTables[].RouteTableId' --output text
check "gateways   " describe-internet-gateways --filters "$TAGF" --query 'InternetGateways[].InternetGatewayId' --output text
check "sec groups " describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[].GroupId' --output text

echo
if [ "$LEFT" -eq 0 ]; then
  log "Teardown complete. Nothing left billing."
else
  warn "$LEFT resource type(s) still present — see above, or run ./99b-force-cleanup.sh"
fi
