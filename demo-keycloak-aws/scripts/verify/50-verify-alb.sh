#!/usr/bin/env bash
# AREA 5/7 - Load balancer: listeners, target health, AZ spread.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 5/7 - LOAD BALANCER"

ALB_ARN="$(find_alb_arn)"
[[ -n "${ALB_ARN}" ]] || { check_fail "ALB ${NAME_PREFIX}-alb not found"; check_summary; exit 1; }

aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].{DNS:DNSName,State:State.Code,Scheme:Scheme,Type:Type,AZs:length(AvailabilityZones)}' \
  --output table

state="$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
         --query 'LoadBalancers[0].State.Code' --output text)"
[[ "${state}" == "active" ]] && check_pass "ALB active" || check_fail "ALB state: ${state}"

az_count="$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
            --query 'length(LoadBalancers[0].AvailabilityZones)' --output text)"
[[ "${az_count}" -ge 2 ]] \
  && check_pass "ALB spans ${az_count} AZs" \
  || check_fail "ALB spans only ${az_count} AZ"

# --- Attributes worth asserting --------------------------------------------
ATTRS="$(aws elbv2 describe-load-balancer-attributes --load-balancer-arn "${ALB_ARN}" --output json)"
for kv in "deletion_protection.enabled:deletion protection" \
          "routing.http2.enabled:HTTP/2" \
          "routing.http.drop_invalid_header_fields.enabled:invalid header dropping"; do
  key="${kv%%:*}"; label="${kv#*:}"
  val="$(jq -r --arg k "${key}" '.Attributes[] | select(.Key==$k) | .Value' <<< "${ATTRS}")"
  [[ "${val}" == "true" ]] && check_pass "${label} enabled" || warn "${label} is ${val:-unset}"
done

# --- Listeners --------------------------------------------------------------
aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,SSLPolicy:SslPolicy,Action:DefaultActions[0].Type}' \
  --output table

HTTPS_COUNT="$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
  --query 'length(Listeners[?Protocol==`HTTPS`])' --output text)"
[[ "${HTTPS_COUNT}" -ge 1 ]] \
  && check_pass "HTTPS listener present" \
  || warn "no HTTPS listener - set acm_certificate_arn before production traffic"

# --- Target health ----------------------------------------------------------
TG_ARN="$(find_target_group_arn)"
if [[ -n "${TG_ARN}" ]]; then
  aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table

  HEALTHY="$(aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)"
  HEALTHY_AZS="$(aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
    --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.AvailabilityZone' \
    --output text | tr '\t' '\n' | sort -u | wc -l)"

  [[ "${HEALTHY}" -ge 1 ]] && check_pass "healthy targets: ${HEALTHY}" || check_fail "no healthy targets"
  [[ "${HEALTHY_AZS}" -ge 2 ]] \
    && check_pass "healthy targets span ${HEALTHY_AZS} AZs" \
    || check_fail "healthy targets are confined to ${HEALTHY_AZS} AZ - not AZ resilient"
else
  check_fail "target group ${NAME_PREFIX}-tg not found"
fi

check_summary
