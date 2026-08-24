#!/usr/bin/env bash
# AREA 6/7 - EC2 hosts: Auto Scaling Group, instance health, AZ spread.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 6/7 - KEYCLOAK HOSTS"

ASG="$(asg_name)"
JSON="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
        --query 'AutoScalingGroups[0]' --output json 2>/dev/null || true)"
[[ -n "${JSON}" && "${JSON}" != "null" ]] || { check_fail "ASG ${ASG} not found"; check_summary; exit 1; }

aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,HealthCheck:HealthCheckType,Grace:HealthCheckGracePeriod,AZs:join(`,`,AvailabilityZones)}' \
  --output table

desired="$(jq -r '.DesiredCapacity' <<< "${JSON}")"
in_service="$(jq '[.Instances[] | select(.LifecycleState=="InService")] | length' <<< "${JSON}")"
[[ "${in_service}" -eq "${desired}" && "${in_service}" -gt 0 ]] \
  && check_pass "instances in service: ${in_service}/${desired}" \
  || check_fail "instances in service: ${in_service}/${desired}"

# --- Health check type must be ELB, or a wedged container is never replaced --
hc="$(jq -r '.HealthCheckType' <<< "${JSON}")"
[[ "${hc}" == "ELB" ]] \
  && check_pass "health check type ELB - unhealthy targets get replaced" \
  || check_fail "health check type is ${hc}; use ELB so Keycloak failures are noticed"

# --- Instance health and AZ spread ------------------------------------------
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,State:LifecycleState,Health:HealthStatus}' \
  --output table

AZS="$(jq -r '[.Instances[].AvailabilityZone] | unique | length' <<< "${JSON}")"
if [[ "${desired}" -ge 2 ]]; then
  [[ "${AZS}" -ge 2 ]] \
    && check_pass "instances spread across ${AZS} AZs" \
    || check_fail "all instances are in ${AZS} AZ"
else
  warn "desired capacity is ${desired} - a single instance is a single point of failure"
fi

UNHEALTHY="$(jq '[.Instances[] | select(.HealthStatus!="Healthy")] | length' <<< "${JSON}")"
[[ "${UNHEALTHY}" -eq 0 ]] && check_pass "no unhealthy instances" || check_fail "${UNHEALTHY} unhealthy instance(s)"

# --- Recent scaling activity reveals a crash loop ---------------------------
log "last 5 scaling activities"
aws autoscaling describe-scaling-activities --auto-scaling-group-name "${ASG}" --max-items 5 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:Description}' --output table 2>/dev/null || true

# --- Alarms -----------------------------------------------------------------
IN_ALARM="$(aws cloudwatch describe-alarms --alarm-name-prefix "${NAME_PREFIX}-" \
  --state-value ALARM --query 'length(MetricAlarms)' --output text 2>/dev/null || echo 0)"
[[ "${IN_ALARM}" -eq 0 ]] && check_pass "no alarms in ALARM state" || check_fail "${IN_ALARM} alarm(s) firing"

check_summary
