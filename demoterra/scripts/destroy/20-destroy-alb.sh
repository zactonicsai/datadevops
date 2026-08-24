#!/usr/bin/env bash
# TEARDOWN 2/6 - Load balancer: listeners, target group, ALB.
# Runs after the ASG so no instance is still registered against the target group.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 2/6 - LOAD BALANCER"
banner_env

ALB_ARN="$(find_alb_arn)"
if [[ -n "${ALB_ARN}" ]]; then
  # Deletion protection blocks the delete call - clear it explicitly.
  run_soft aws elbv2 modify-load-balancer-attributes --load-balancer-arn "${ALB_ARN}" \
    --attributes Key=deletion_protection.enabled,Value=false

  LISTENERS="$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
               --query 'Listeners[].ListenerArn' --output text 2>/dev/null || true)"
  for l in ${LISTENERS}; do
    [[ "${l}" == "None" ]] && continue
    run_soft aws elbv2 delete-listener --listener-arn "${l}"
  done

  run_soft aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}"
  [[ "${DRY_RUN}" == "1" ]] || run_soft aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}"
else
  warn "ALB ${NAME_PREFIX}-alb not found"
fi

TG_ARN="$(find_target_group_arn)"
if [[ -n "${TG_ARN}" ]]; then
  run_soft aws elbv2 delete-target-group --target-group-arn "${TG_ARN}"
else
  warn "target group ${NAME_PREFIX}-tg not found"
fi

# --- Verify -----------------------------------------------------------------
[[ -z "$(find_alb_arn)" ]] && ok "ALB deleted" || warn "ALB still present"
[[ -z "$(find_target_group_arn)" ]] && ok "target group deleted" || warn "target group still present"
