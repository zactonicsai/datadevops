#!/usr/bin/env bash
# AREA 6/7 - ECS: service stability, task spread, deployment safety, alarms.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 6/7 - ECS SERVICE"

CLUSTER="$(cluster_name)"; SERVICE="$(service_name)"
SVC="$(aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
       --query 'services[0]' --output json 2>/dev/null || true)"
[[ -n "${SVC}" && "${SVC}" != "null" ]] || { check_fail "service ${SERVICE} not found"; check_summary; exit 1; }

aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
  --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDef:taskDefinition,Rollout:deployments[0].rolloutState}' \
  --output table

desired="$(jq -r '.desiredCount' <<< "${SVC}")"
running="$(jq -r '.runningCount' <<< "${SVC}")"
[[ "${running}" -eq "${desired}" && "${running}" -gt 0 ]] \
  && check_pass "running ${running}/${desired} tasks" \
  || check_fail "running ${running}/${desired} tasks"

[[ "${desired}" -ge 2 ]] \
  && check_pass "desired count ${desired} - survives losing a task" \
  || check_fail "desired count ${desired} - a single task is a single point of failure"

jq -e '.deploymentConfiguration.deploymentCircuitBreaker.rollback' >/dev/null <<< "${SVC}" \
  && check_pass "deployment circuit breaker with rollback enabled" \
  || check_fail "deployment circuit breaker rollback is off"

min_healthy="$(jq -r '.deploymentConfiguration.minimumHealthyPercent' <<< "${SVC}")"
[[ "${min_healthy}" -ge 100 ]] \
  && check_pass "minimum healthy percent ${min_healthy} - no capacity dip while deploying" \
  || warn "minimum healthy percent is ${min_healthy}"

rollout="$(jq -r '.deployments[0].rolloutState // "n/a"' <<< "${SVC}")"
[[ "${rollout}" == "COMPLETED" ]] && check_pass "rollout state: COMPLETED" || warn "rollout state: ${rollout}"

# --- Task spread across AZs -------------------------------------------------
TASK_ARNS="$(aws ecs list-tasks --cluster "${CLUSTER}" --service-name "${SERVICE}" \
             --desired-status RUNNING --query 'taskArns' --output text)"
if [[ -n "${TASK_ARNS}" && "${TASK_ARNS}" != "None" ]]; then
  aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
    --query 'tasks[].{Task:taskArn,AZ:availabilityZone,Last:lastStatus,Health:healthStatus,Started:startedAt}' \
    --output table
  AZS="$(aws ecs describe-tasks --cluster "${CLUSTER}" --tasks ${TASK_ARNS} \
        --query 'tasks[].availabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l)"
  [[ "${AZS}" -ge 2 ]] \
    && check_pass "tasks spread across ${AZS} AZs" \
    || check_fail "all tasks are in ${AZS} AZ"
fi

# --- Recent service events reveal flapping ---------------------------------
log "last 5 service events"
jq -r '.events[:5][] | "  \(.createdAt)  \(.message)"' <<< "${SVC}" 2>/dev/null || true

# --- Alarms -----------------------------------------------------------------
log "CloudWatch alarms for this stack"
aws cloudwatch describe-alarms --alarm-name-prefix "${NAME_PREFIX}-" \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Actions:length(AlarmActions)}' --output table 2>/dev/null || true

IN_ALARM="$(aws cloudwatch describe-alarms --alarm-name-prefix "${NAME_PREFIX}-" \
  --state-value ALARM --query 'length(MetricAlarms)' --output text 2>/dev/null || echo 0)"
[[ "${IN_ALARM}" -eq 0 ]] && check_pass "no alarms in ALARM state" || check_fail "${IN_ALARM} alarm(s) firing"

check_summary
