#!/usr/bin/env bash
# ==========================================================================
# 99b-force-cleanup.sh -- The "I lost the state file" / "something is still
# billing me" sweeper. It ignores .deploy-state entirely and hunts by TAG.
#
#   ./99b-force-cleanup.sh                 sweep the configured region
#   ./99b-force-cleanup.sh --dry-run       list only
#   ./99b-force-cleanup.sh --all-regions   check EVERY region (slow, ~1 min)
#   ./99b-force-cleanup.sh --yes           no prompt
#
# Use this when 99-teardown.sh reported leftovers, or when you deployed twice
# and only cleaned up once.
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

DRY_RUN=false; ASSUME_YES=false; ALL_REGIONS=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=true ;;
    --yes|-y)      ASSUME_YES=true ;;
    --all-regions) ALL_REGIONS=true ;;
    *) die "Unknown option: $arg" ;;
  esac
done

REGIONS="$AWS_REGION"
if $ALL_REGIONS; then
  log "Listing all enabled regions..."
  REGIONS="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' ' ')"
  ok "Will scan: $REGIONS"
fi

FOUND_ANY=false

sweep_region() {
  local R="$1"
  local A=(aws --region "$R")
  local TAGF=("Name=tag:${TAG_KEY},Values=${TAG_VALUE}")

  local inst sg eip vol snap vpc
  inst="$("${A[@]}" ec2 describe-instances \
    --filters "${TAGF[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ')"
  vpc="$("${A[@]}" ec2 describe-vpcs --filters "${TAGF[@]}" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null | tr '\t' ' ')"
  sg="$("${A[@]}" ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' ' ')"
  eip="$("${A[@]}" ec2 describe-addresses --filters "${TAGF[@]}" \
    --query 'Addresses[].AllocationId' --output text 2>/dev/null | tr '\t' ' ')"
  vol="$("${A[@]}" ec2 describe-volumes --filters "${TAGF[@]}" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' ' ')"
  snap="$("${A[@]}" ec2 describe-snapshots --owner-ids self --filters "${TAGF[@]}" \
    --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' ' ')"

  if [ -z "${inst}${sg}${eip}${vol}${snap}${vpc}" ]; then
    $ALL_REGIONS && printf '  %-16s clean\n' "$R"
    return 0
  fi
  FOUND_ANY=true

  echo
  log "=== $R ==="
  [ -n "$inst" ] && echo "    instances : $inst"
  [ -n "$vol"  ] && echo "    volumes   : $vol"
  [ -n "$eip"  ] && echo "    elastic ip: $eip"
  [ -n "$sg"   ] && echo "    sec group : $sg"
  [ -n "$vpc"  ] && echo "    vpc       : $vpc (+ its subnets, route tables, gateway)"
  [ -n "$snap" ] && echo "    snapshots : $snap  (NOT deleted by this script)"

  if $DRY_RUN; then
    warn "dry-run: nothing deleted in $R"
    return 0
  fi
  if ! $ASSUME_YES; then
    read -r -p "  Delete these in ${R}? type 'yes': " A2
    [ "$A2" = "yes" ] || { warn "Skipped $R"; return 0; }
  fi

  # --- same dependency order as 99-teardown.sh ---
  if [ -n "$inst" ]; then
    # shellcheck disable=SC2086
    for i in $inst; do
      "${A[@]}" ec2 modify-instance-attribute --instance-id "$i" \
        --no-disable-api-termination >/dev/null 2>&1
    done
    # shellcheck disable=SC2086
    "${A[@]}" ec2 terminate-instances --instance-ids $inst >/dev/null 2>&1
    log "  waiting for termination..."
    # shellcheck disable=SC2086
    "${A[@]}" ec2 wait instance-terminated --instance-ids $inst 2>/dev/null
    ok "instances gone"
  fi

  for v in $vol; do
    "${A[@]}" ec2 delete-volume --volume-id "$v" >/dev/null 2>&1 && ok "volume $v deleted"
  done

  for a in $eip; do
    ASSOC="$("${A[@]}" ec2 describe-addresses --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    [ -n "$ASSOC" ] && [ "$ASSOC" != "None" ] && \
      "${A[@]}" ec2 disassociate-address --association-id "$ASSOC" >/dev/null 2>&1
    "${A[@]}" ec2 release-address --allocation-id "$a" >/dev/null 2>&1 && ok "eip $a released"
  done

  for g in $sg; do
    for e in $("${A[@]}" ec2 describe-network-interfaces \
                --filters "Name=group-id,Values=$g" "Name=status,Values=available" \
                --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
      "${A[@]}" ec2 delete-network-interface --network-interface-id "$e" >/dev/null 2>&1
    done
    for _ in $(seq 1 12); do
      "${A[@]}" ec2 delete-security-group --group-id "$g" 2>/dev/null && { ok "sg $g deleted"; break; }
      sleep 10
    done
  done

  # --- network, innermost first: subnets -> route tables -> igw -> vpc ---
  for v in $vpc; do
    for e in $("${A[@]}" ec2 describe-network-interfaces \
                --filters "Name=vpc-id,Values=$v" "Name=status,Values=available" \
                --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
      "${A[@]}" ec2 delete-network-interface --network-interface-id "$e" >/dev/null 2>&1
    done

    for s in $("${A[@]}" ec2 describe-subnets --filters "Name=vpc-id,Values=$v" \
                --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
      for _ in $(seq 1 6); do
        "${A[@]}" ec2 delete-subnet --subnet-id "$s" 2>/dev/null && { ok "subnet $s deleted"; break; }
        sleep 10
      done
    done

    # the VPC's MAIN route table cannot be deleted; it goes with the VPC
    for rt in $("${A[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=$v" \
                 --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' \
                 --output text 2>/dev/null); do
      for as in $("${A[@]}" ec2 describe-route-tables --route-table-ids "$rt" \
                   --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' \
                   --output text 2>/dev/null); do
        "${A[@]}" ec2 disassociate-route-table --association-id "$as" >/dev/null 2>&1
      done
      "${A[@]}" ec2 delete-route-table --route-table-id "$rt" >/dev/null 2>&1 \
        && ok "route table $rt deleted"
    done

    for g in $("${A[@]}" ec2 describe-internet-gateways \
                --filters "Name=attachment.vpc-id,Values=$v" \
                --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
      "${A[@]}" ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$v" >/dev/null 2>&1
      "${A[@]}" ec2 delete-internet-gateway --internet-gateway-id "$g" >/dev/null 2>&1 \
        && ok "igw $g deleted"
    done

    for _ in $(seq 1 6); do
      "${A[@]}" ec2 delete-vpc --vpc-id "$v" 2>/dev/null && { ok "vpc $v deleted"; break; }
      sleep 10
    done
  done

  "${A[@]}" ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 && ok "key pair deleted"
}

log "Sweeping for ${TAG_KEY}=${TAG_VALUE} ..."
for R in $REGIONS; do
  sweep_region "$R"
done

# IAM is global, so it is handled once, outside the region loop.
echo
log "IAM (global)..."
if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  if $DRY_RUN; then
    warn "would delete role ${IAM_ROLE_NAME} and profile ${INSTANCE_PROFILE_NAME}"
  else
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1
    aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1
    for arn in $(aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
                 --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      aws iam detach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$arn" >/dev/null 2>&1
    done
    aws iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 && ok "role deleted"
  fi
else
  ok "no ${IAM_ROLE_NAME} role"
fi

rm -f "$STATE_FILE" 2>/dev/null
$FOUND_ANY || ok "Nothing tagged ${TAG_KEY}=${TAG_VALUE} found anywhere. You are clean."
