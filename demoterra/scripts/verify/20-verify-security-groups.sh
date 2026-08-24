#!/usr/bin/env bash
# AREA 2/7 - Security groups: the ALB -> Keycloak -> RDS chain.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 2/7 - SECURITY GROUPS"

ALB_SG="$(find_sg_id alb-sg)"
KC_SG="$(find_sg_id keycloak-sg)"
DB_SG="$(find_sg_id database-sg)"

for pair in "alb:${ALB_SG}" "keycloak:${KC_SG}" "database:${DB_SG}"; do
  name="${pair%%:*}"; id="${pair#*:}"
  [[ -n "${id}" ]] && check_pass "${name} SG ${id}" || check_fail "${name} SG not found"
done

[[ -n "${KC_SG}" && -n "${DB_SG}" ]] || { check_summary; exit 1; }

# --- Keycloak must accept traffic only from the ALB SG ----------------------
KC_SOURCES="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${KC_SG}" \
  --query 'SecurityGroupRules[?!IsEgress].ReferencedGroupInfo.GroupId' --output text)"
grep -q "${ALB_SG}" <<< "${KC_SOURCES}" \
  && check_pass "Keycloak ingress references the ALB security group" \
  || check_fail "Keycloak ingress does not reference the ALB security group"

KC_OPEN_CIDRS="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${KC_SG}" \
  --query 'SecurityGroupRules[?!IsEgress].CidrIpv4' --output text | tr -d '\t')"
[[ -z "${KC_OPEN_CIDRS}" || "${KC_OPEN_CIDRS}" == "None" ]] \
  && check_pass "Keycloak has no CIDR-based ingress" \
  || check_fail "Keycloak has CIDR-based ingress: ${KC_OPEN_CIDRS}"

# --- RDS must accept traffic only from the Keycloak SG ---------------------
DB_SOURCES="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${DB_SG}" \
  --query 'SecurityGroupRules[?!IsEgress].ReferencedGroupInfo.GroupId' --output text)"
grep -q "${KC_SG}" <<< "${DB_SOURCES}" \
  && check_pass "database ingress references the Keycloak security group" \
  || check_fail "database ingress does not reference the Keycloak security group"

DB_PUBLIC="$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=${DB_SG}" \
  --query 'SecurityGroupRules[?CidrIpv4==`0.0.0.0/0`]' --output json)"
[[ "$(jq 'length' <<< "${DB_PUBLIC}")" -eq 0 ]] \
  && check_pass "database is not open to 0.0.0.0/0" \
  || check_fail "database is open to the world"

# --- Full rule dump for the record -----------------------------------------
log "ALB security group rules"
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=${ALB_SG}" \
  --query 'SecurityGroupRules[].{Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SG:ReferencedGroupInfo.GroupId}' \
  --output table

check_summary
