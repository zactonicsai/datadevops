#!/usr/bin/env bash
# AREA 1/7 - Networking: VPC, subnet tiers, routing, NAT, endpoints.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 1/7 - NETWORKING"

VPC_ID="$(find_vpc_id)"
if [[ -z "${VPC_ID}" ]]; then
  check_fail "no VPC tagged Project=${PROJECT_NAME} Environment=${ENVIRONMENT}"
  check_summary; exit 1
fi
check_pass "VPC ${VPC_ID}"

# --- CLI: VPC detail --------------------------------------------------------
aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" \
  --query 'Vpcs[0].{CIDR:CidrBlock,State:State,DnsHostnames:EnableDnsHostnames}' --output table

# --- Subnets, grouped by tier ----------------------------------------------
for tier in public private database; do
  ids="$(subnet_ids_by_tier "${tier}")"
  count="$(wc -w <<< "${ids}")"
  azs="$(aws ec2 describe-subnets --subnet-ids ${ids} \
          --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' ' ')"
  if [[ "${count}" -ge 2 ]]; then
    check_pass "${tier} subnets: ${count} across AZs [${azs}]"
  else
    check_fail "${tier} subnets: ${count} - at least 2 AZs are required for resilience"
  fi
done

# --- NAT Gateways -----------------------------------------------------------
NAT_JSON="$(aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
  --query 'NatGateways[].{Id:NatGatewayId,AZ:SubnetId,State:State}' --output json)"
NAT_COUNT="$(jq 'length' <<< "${NAT_JSON}")"
if [[ "${NAT_COUNT}" -ge 2 ]]; then
  check_pass "NAT Gateways: ${NAT_COUNT} (one per AZ - no single point of failure)"
elif [[ "${NAT_COUNT}" -eq 1 ]]; then
  warn "NAT Gateways: 1 - a shared NAT is a single point of failure; set single_nat_gateway=false"
  check_pass "NAT Gateway present"
else
  check_fail "no NAT Gateways - instances cannot pull the Docker image"
fi

# --- Routing ----------------------------------------------------------------
DB_RT_ROUTES="$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-rt-database" \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' --output json 2>/dev/null || echo '[]')"
if [[ "$(jq 'length' <<< "${DB_RT_ROUTES}")" -eq 0 ]]; then
  check_pass "database tier has no route to the internet"
else
  check_fail "database tier has a default route - it should be fully isolated"
fi

check_summary
