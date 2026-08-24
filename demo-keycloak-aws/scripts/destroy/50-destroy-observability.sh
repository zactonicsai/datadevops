#!/usr/bin/env bash
# TEARDOWN 5/6 - CloudWatch alarms, log groups and the SNS alert topic.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 5/6 - ALARMS, LOGS, NOTIFICATIONS"
banner_env

# --- Alarms -----------------------------------------------------------------
ALARMS="$(aws cloudwatch describe-alarms --alarm-name-prefix "${NAME_PREFIX}-" \
  --query 'MetricAlarms[].AlarmName' --output text 2>/dev/null || true)"
if [[ -n "${ALARMS}" && "${ALARMS}" != "None" ]]; then
  run_soft aws cloudwatch delete-alarms --alarm-names ${ALARMS}
else
  warn "no alarms found"
fi

# --- Log groups -------------------------------------------------------------
for lg in "/aws/ecs/${NAME_PREFIX}/keycloak" "/aws/vpc/${NAME_PREFIX}/flow-logs"; do
  if aws logs describe-log-groups --log-group-name-prefix "${lg}" \
       --query 'length(logGroups)' --output text 2>/dev/null | grep -qv '^0$'; then
    warn "deleting ${lg} - all retained logs go with it"
    run_soft aws logs delete-log-group --log-group-name "${lg}"
  fi
done

# --- SNS topic --------------------------------------------------------------
TOPIC_ARN="$(aws sns list-topics --query "Topics[?ends_with(TopicArn,':${NAME_PREFIX}-alerts')].TopicArn" \
             --output text 2>/dev/null || true)"
if [[ -n "${TOPIC_ARN}" && "${TOPIC_ARN}" != "None" ]]; then
  run_soft aws sns delete-topic --topic-arn "${TOPIC_ARN}"
else
  warn "no SNS topic ${NAME_PREFIX}-alerts"
fi

ok "observability teardown complete"
