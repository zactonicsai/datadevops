#!/usr/bin/env bash
# TEARDOWN 6/6 - Networking, last because everything else lives inside it.
# Internal order: endpoints -> NAT -> EIPs -> ENIs -> subnets -> SG rules ->
#                 SGs -> route tables -> IGW -> VPC
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 6/6 - NETWORKING"
banner_env

VPC_ID="$(find_vpc_id)"
[[ -n "${VPC_ID}" ]] || { warn "no VPC found for ${NAME_PREFIX} - nothing to do"; exit 0; }
log "VPC ${VPC_ID}"
confirm "Delete the VPC and everything still inside it? Confirm by typing the stack prefix:"

# --- 1. VPC endpoints -------------------------------------------------------
EPS="$(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=${VPC_ID}" \
       --query 'VpcEndpoints[].VpcEndpointId' --output text 2>/dev/null || true)"
if [[ -n "${EPS}" && "${EPS}" != "None" ]]; then
  run_soft aws ec2 delete-vpc-endpoints --vpc-endpoint-ids ${EPS}
  [[ "${DRY_RUN}" == "1" ]] || sleep 20
fi

# --- 2. NAT Gateways --------------------------------------------------------
NATS="$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
        --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null || true)"
for n in ${NATS}; do
  [[ "${n}" == "None" ]] && continue
  run_soft aws ec2 delete-nat-gateway --nat-gateway-id "${n}"
done
if [[ -n "${NATS}" && "${NATS}" != "None" && "${DRY_RUN}" != "1" ]]; then
  log "waiting for NAT Gateways to delete (can take a couple of minutes)"
  run_soft aws ec2 wait nat-gateway-deleted --nat-gateway-ids ${NATS}
fi

# --- 3. Elastic IPs ---------------------------------------------------------
ALLOCS="$(aws ec2 describe-addresses --filters "${TAG_FILTER[@]}" \
          --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)"
for a in ${ALLOCS}; do
  [[ "${a}" == "None" ]] && continue
  run_soft aws ec2 release-address --allocation-id "${a}"
done

# --- 4. Leftover ENIs (usually from deleted endpoints) ----------------------
ENIS="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'NetworkInterfaces[?Status==`available`].NetworkInterfaceId' --output text 2>/dev/null || true)"
for e in ${ENIS}; do
  [[ "${e}" == "None" ]] && continue
  run_soft aws ec2 delete-network-interface --network-interface-id "${e}"
done

# --- 5. Subnets -------------------------------------------------------------
SUBNETS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
           --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)"
for s in ${SUBNETS}; do
  [[ "${s}" == "None" ]] && continue
  run_soft aws ec2 delete-subnet --subnet-id "${s}"
done

# --- 6. Security group rules first ------------------------------------------
# The groups reference each other, so the rules have to go before the groups.
SGS="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}" \
       --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
for sg in ${SGS}; do
  [[ "${sg}" == "None" ]] && continue
  IN="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=${sg}" \
        --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)"
  OUT="$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=${sg}" \
         --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || true)"
  [[ -n "${IN}"  && "${IN}"  != "None" ]] && run_soft aws ec2 revoke-security-group-ingress --group-id "${sg}" --security-group-rule-ids ${IN}
  [[ -n "${OUT}" && "${OUT}" != "None" ]] && run_soft aws ec2 revoke-security-group-egress  --group-id "${sg}" --security-group-rule-ids ${OUT}
done

# --- 7. Security groups -----------------------------------------------------
for sg in ${SGS}; do
  [[ "${sg}" == "None" ]] && continue
  run_soft aws ec2 delete-security-group --group-id "${sg}"
done

# --- 8. Route tables (main is deleted with the VPC) -------------------------
RTS="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
       --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' --output text 2>/dev/null || true)"
for rt in ${RTS}; do
  [[ "${rt}" == "None" ]] && continue
  ASSOCS="$(aws ec2 describe-route-tables --route-table-ids "${rt}" \
            --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || true)"
  for a in ${ASSOCS}; do
    [[ "${a}" == "None" ]] && continue
    run_soft aws ec2 disassociate-route-table --association-id "${a}"
  done
  run_soft aws ec2 delete-route-table --route-table-id "${rt}"
done

# --- 9. Flow logs and Internet Gateway --------------------------------------
FLOWS="$(aws ec2 describe-flow-logs --filter "Name=resource-id,Values=${VPC_ID}" \
         --query 'FlowLogs[].FlowLogId' --output text 2>/dev/null || true)"
[[ -n "${FLOWS}" && "${FLOWS}" != "None" ]] && run_soft aws ec2 delete-flow-logs --flow-log-ids ${FLOWS}

IGW="$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
       --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | grep -v '^None$' || true)"
if [[ -n "${IGW}" ]]; then
  run_soft aws ec2 detach-internet-gateway --internet-gateway-id "${IGW}" --vpc-id "${VPC_ID}"
  run_soft aws ec2 delete-internet-gateway --internet-gateway-id "${IGW}"
fi

# --- 10. VPC ----------------------------------------------------------------
run_soft aws ec2 delete-vpc --vpc-id "${VPC_ID}"

# --- Verify -----------------------------------------------------------------
if [[ -z "$(find_vpc_id)" ]]; then
  ok "networking teardown complete"
else
  warn "VPC ${VPC_ID} still exists - check for dependencies:"
  aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}' --output table 2>/dev/null || true
fi
