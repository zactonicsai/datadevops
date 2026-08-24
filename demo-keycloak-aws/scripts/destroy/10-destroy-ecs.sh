#!/usr/bin/env bash
# TEARDOWN 1/6 - ECS: stop traffic consumers first, before anything they depend on.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 1/6 - ECS SERVICE, TASKS, CLUSTER"
banner_env

CLUSTER="$(cluster_name)"; SERVICE="$(service_name)"

# --- Autoscaling first, or it will fight the scale-to-zero -----------------
RES_ID="service/${CLUSTER}/${SERVICE}"
for policy in "${NAME_PREFIX}-cpu-target-tracking" "${NAME_PREFIX}-memory-target-tracking" "${NAME_PREFIX}-request-target-tracking"; do
  run_soft aws application-autoscaling delete-scaling-policy \
    --service-namespace ecs --resource-id "${RES_ID}" \
    --scalable-dimension ecs:service:DesiredCount --policy-name "${policy}"
done
run_soft aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs --resource-id "${RES_ID}" --scalable-dimension ecs:service:DesiredCount

# --- Drain the service ------------------------------------------------------
if aws ecs describe-services --cluster "${CLUSTER}" --services "${SERVICE}" \
     --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
  log "scaling ${SERVICE} to 0 and waiting for tasks to drain"
  run aws ecs update-service --cluster "${CLUSTER}" --service "${SERVICE}" --desired-count 0
  [[ "${DRY_RUN}" == "1" ]] || run_soft aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"
  run_soft aws ecs delete-service --cluster "${CLUSTER}" --service "${SERVICE}" --force
else
  warn "service ${SERVICE} not found"
fi

# --- Any orphaned tasks -----------------------------------------------------
TASKS="$(aws ecs list-tasks --cluster "${CLUSTER}" --query 'taskArns' --output text 2>/dev/null || true)"
if [[ -n "${TASKS}" && "${TASKS}" != "None" ]]; then
  for t in ${TASKS}; do
    run_soft aws ecs stop-task --cluster "${CLUSTER}" --task "${t}" --reason "stack teardown"
  done
fi

# --- Deregister task definition revisions ----------------------------------
REVS="$(aws ecs list-task-definitions --family-prefix "${NAME_PREFIX}-keycloak" \
        --status ACTIVE --query 'taskDefinitionArns' --output text 2>/dev/null || true)"
for r in ${REVS}; do
  [[ "${r}" == "None" ]] && continue
  run_soft aws ecs deregister-task-definition --task-definition "${r}"
done

# --- Cluster ----------------------------------------------------------------
run_soft aws ecs delete-cluster --cluster "${CLUSTER}"

# --- Verify -----------------------------------------------------------------
if aws ecs describe-clusters --clusters "${CLUSTER}" \
     --query 'clusters[0].status' --output text 2>/dev/null | grep -qE 'ACTIVE'; then
  warn "cluster ${CLUSTER} still reports ACTIVE - re-run after tasks finish draining"
else
  ok "ECS teardown complete"
fi
