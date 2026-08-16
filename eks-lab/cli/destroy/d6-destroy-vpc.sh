#!/usr/bin/env bash
# d6-destroy-vpc.sh  —  delete the VPC and clear the state file.
#
# If this fails with "DependencyViolation", something is still inside the VPC.
# The command at the bottom lists what.
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: VPC"
R=(--region "$AWS_REGION")

if [ -z "${VPC_ID:-}" ]; then
  warn "No VPC in the state file — nothing to do."
else
  log "Deleting VPC ${VPC_ID} ..."
  if aws ec2 delete-vpc "${R[@]}" --vpc-id "$VPC_ID" 2>/dev/null; then
    ok "VPC deleted"
  else
    echo
    warn "Could not delete the VPC. Something is still inside it."
    warn "Most often: a leftover load balancer, or network interfaces that"
    warn "take a few minutes to clear after the nodes are gone."
    echo
    echo "Find what is left:"
    echo "  aws ec2 describe-network-interfaces --region ${AWS_REGION} \\"
    echo "    --filters Name=vpc-id,Values=${VPC_ID} --output table"
    echo "  aws elbv2 describe-load-balancers --region ${AWS_REGION} \\"
    echo "    --query \"LoadBalancers[?VpcId=='${VPC_ID}']\" --output table"
    echo
    echo "Wait 5 minutes and re-run this script."
    exit 1
  fi
fi

log "Clearing the state file..."
: > "$STATE_FILE"
ok "State cleared. The lab is fully destroyed."

echo
log "Final sanity check — anything still tagged Lab=${LAB_NAME}?"
aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
  --tag-filters "Key=Lab,Values=${LAB_NAME}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output table 2>/dev/null \
  || warn "(resourcegroupstaggingapi not available — check the console)"
