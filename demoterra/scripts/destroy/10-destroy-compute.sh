#!/usr/bin/env bash
# TEARDOWN 1/6 - EC2 hosts: scale the ASG to zero, then delete it.
# Runs first so nothing is still registered with the ALB.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 1/6 - KEYCLOAK HOSTS"
banner_env

ASG="$(asg_name)"

if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
     --query 'length(AutoScalingGroups)' --output text 2>/dev/null | grep -qv '^0$'; then

  # Scaling policies first, or they will fight the scale-down.
  POLICIES="$(aws autoscaling describe-policies --auto-scaling-group-name "${ASG}" \
              --query 'ScalingPolicies[].PolicyName' --output text 2>/dev/null || true)"
  for p in ${POLICIES}; do
    [[ "${p}" == "None" ]] && continue
    run_soft aws autoscaling delete-policy --auto-scaling-group-name "${ASG}" --policy-name "${p}"
  done

  log "scaling ${ASG} to zero and waiting for instances to terminate"
  run aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG}" \
    --min-size 0 --max-size 0 --desired-capacity 0

  if [[ "${DRY_RUN}" != "1" ]]; then
    for _ in $(seq 1 60); do
      COUNT="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}" \
               --query 'length(AutoScalingGroups[0].Instances)' --output text 2>/dev/null || echo 0)"
      [[ "${COUNT}" == "0" ]] && break
      printf '  ... %s instance(s) still terminating\n' "${COUNT}"
      sleep 10
    done
  fi

  run_soft aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "${ASG}" --force-delete
else
  warn "ASG ${ASG} not found"
fi

# --- Launch templates -------------------------------------------------------
LTS="$(aws ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=${NAME_PREFIX}-*" \
  --query 'LaunchTemplates[].LaunchTemplateId' --output text 2>/dev/null || true)"
for lt in ${LTS}; do
  [[ "${lt}" == "None" ]] && continue
  run_soft aws ec2 delete-launch-template --launch-template-id "${lt}"
done

# --- Verify -----------------------------------------------------------------
LEFT="$(find_instance_ids)"
[[ -z "${LEFT}" || "${LEFT}" == "None" ]] \
  && ok "no Keycloak instances remain" \
  || warn "instances still running: ${LEFT}"
