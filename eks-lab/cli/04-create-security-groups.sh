#!/usr/bin/env bash
# =============================================================================
# 04-create-security-groups.sh  —  ONE JOB: the firewalls.
#
# A SECURITY GROUP is a firewall attached to a network card. Two things make
# them easier than traditional firewalls:
#
#   1. They are STATEFUL. If you allow traffic out, the reply is automatically
#      allowed back in. You write one rule, not two.
#   2. They can reference EACH OTHER. Instead of "allow 10.42.32.0/20", you say
#      "allow anything wearing the node security group". Self-documenting, and
#      it keeps working when IP addresses change.
#
# We create three:
#   - node SG      : the worker nodes (and therefore the pods)
#   - alb SG       : the public load balancer
#   - endpoint SG  : reserved for VPC interface endpoints (unused in this lab,
#                    kept so the structure matches the production pattern)
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws
require VPC_ID

banner "Step 4 / Security groups"
R=(--region "$AWS_REGION")

mk_sg() {  # name description  -> prints group id
  local name="$1" desc="$2"
  local existing
  existing=$(aws ec2 describe-security-groups "${R[@]}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then echo "$existing"; return; fi
  aws ec2 create-security-group "${R[@]}" \
    --group-name "$name" --description "$desc" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Lab,Value=${LAB_NAME}}]" \
    --query 'GroupId' --output text
}

if [ -z "${SG_NODE:-}" ]; then
  log "Creating security groups..."
  save SG_NODE "$(mk_sg "${LAB_NAME}-node-sg"     "EKS worker nodes")"
  save SG_ALB  "$(mk_sg "${LAB_NAME}-alb-sg"      "Public load balancer")"
fi

# --- Rules -----------------------------------------------------------------
# Helper that ignores "rule already exists" so the script is safe to re-run.
allow() { aws ec2 authorize-security-group-ingress "${R[@]}" "$@" >/dev/null 2>&1 || true; }

log "node -> node : allow everything (pods talk to each other, CoreDNS, etc.)"
allow --group-id "$SG_NODE" --protocol -1 --source-group "$SG_NODE"

log "alb -> node : allow the load balancer to reach app ports"
# NodePort range. In a lab this is simplest; in production you would narrow it
# to the specific ports your Services use.
allow --group-id "$SG_NODE" --protocol tcp --port 30000-32767 --source-group "$SG_ALB"

log "internet -> alb : HTTP and HTTPS only"
# YOUR_IP restricts the lab to your own address. Strongly recommended.
# Find it with: curl -s https://checkip.amazonaws.com
MY_IP="${MY_IP:-}"
if [ -n "$MY_IP" ]; then
  allow --group-id "$SG_ALB" --protocol tcp --port 80  --cidr "${MY_IP}/32"
  allow --group-id "$SG_ALB" --protocol tcp --port 443 --cidr "${MY_IP}/32"
  ok "Load balancer restricted to ${MY_IP}/32"
else
  warn "MY_IP not set — opening the load balancer to 0.0.0.0/0 (the whole internet)."
  warn "For a safer lab, re-run with:  MY_IP=\$(curl -s https://checkip.amazonaws.com) ./04-create-security-groups.sh"
  allow --group-id "$SG_ALB" --protocol tcp --port 80  --cidr 0.0.0.0/0
  allow --group-id "$SG_ALB" --protocol tcp --port 443 --cidr 0.0.0.0/0
fi

# NOTE: we never open port 22 (SSH). Use SSM Session Manager instead:
#   aws ssm start-session --target <instance-id>
# No keys to lose, every session is logged in CloudTrail.

echo
log "Security groups:"
aws ec2 describe-security-groups "${R[@]}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[].{Name:GroupName,Id:GroupId}' --output table
echo
log "Next: ./05-create-cluster.sh"
