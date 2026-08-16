#!/usr/bin/env bash
# d5-destroy-networking.sh  —  NAT gateway, endpoints, routes, subnets, IGW.
#
# The NAT gateway goes FIRST because it holds an Elastic IP and lives in a
# subnet — you cannot delete the subnet while it is there.
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: networking"
R=(--region "$AWS_REGION")

if [ -n "${VPCE_S3:-}" ]; then
  log "Deleting the S3 VPC endpoint..."
  aws ec2 delete-vpc-endpoints "${R[@]}" --vpc-endpoint-ids "$VPCE_S3" >/dev/null 2>&1 || true
fi

if [ -n "${NAT_GW_ID:-}" ]; then
  log "Deleting the NAT gateway (this is the expensive one — takes ~2 min)..."
  aws ec2 delete-nat-gateway "${R[@]}" --nat-gateway-id "$NAT_GW_ID" >/dev/null 2>&1 || true
  log "Waiting for it to disappear..."
  aws ec2 wait nat-gateway-deleted "${R[@]}" --nat-gateway-ids "$NAT_GW_ID" 2>/dev/null || true
  ok "NAT gateway deleted"
fi

if [ -n "${EIP_ALLOC:-}" ]; then
  log "Releasing the Elastic IP (unattached EIPs are billed hourly!)..."
  aws ec2 release-address "${R[@]}" --allocation-id "$EIP_ALLOC" 2>/dev/null || warn "already released"
fi

for rtb in "${RTB_PRIVATE:-}" "${RTB_PUBLIC:-}"; do
  [ -z "$rtb" ] && continue
  log "Deleting route table $rtb ..."
  # associations must be removed first
  for assoc in $(aws ec2 describe-route-tables "${R[@]}" --route-table-ids "$rtb" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    aws ec2 disassociate-route-table "${R[@]}" --association-id "$assoc" 2>/dev/null || true
  done
  aws ec2 delete-route-table "${R[@]}" --route-table-id "$rtb" 2>/dev/null || warn "$rtb busy"
done

if [ -n "${IGW_ID:-}" ] && [ -n "${VPC_ID:-}" ]; then
  log "Detaching and deleting the internet gateway..."
  aws ec2 detach-internet-gateway "${R[@]}" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
  aws ec2 delete-internet-gateway "${R[@]}" --internet-gateway-id "$IGW_ID" 2>/dev/null || true
fi

for sn in "${SUBNET_PUB_A:-}" "${SUBNET_PUB_B:-}" "${SUBNET_PRIV_A:-}" "${SUBNET_PRIV_B:-}"; do
  [ -z "$sn" ] && continue
  log "Deleting subnet $sn ..."
  aws ec2 delete-subnet "${R[@]}" --subnet-id "$sn" 2>/dev/null || warn "$sn still has network interfaces attached"
done

ok "Done. Next: ./d6-destroy-vpc.sh"
