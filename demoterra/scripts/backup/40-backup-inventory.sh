#!/usr/bin/env bash
# BACKUP 4/4 - Full resource inventory, so the stack can be reconstructed or
# audited even if state and snapshots are lost.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEST="${BACKUP_DIR:-$(cat "${BACKUP_ROOT}/.last" 2>/dev/null || echo "${BACKUP_ROOT}/${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)")}"
mkdir -p "${DEST}/inventory"
INV="${DEST}/inventory"

header "BACKUP 4/4 - RESOURCE INVENTORY"

VPC_ID="$(find_vpc_id)"
ASG="$(asg_name)"; DB_ID="$(db_identifier)"
ALB_ARN="$(find_alb_arn)"; TG_ARN="$(find_target_group_arn)"

dump() { # dump <file> <command...>
  local f="$1"; shift
  if "$@" > "${INV}/$f" 2>/dev/null; then ok "${f}"; else warn "${f} (skipped)"; rm -f "${INV}/$f"; fi
}

if [[ -n "${VPC_ID}" ]]; then
  dump vpc.json           aws ec2 describe-vpcs --vpc-ids "${VPC_ID}"
  dump subnets.json       aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}"
  dump route-tables.json  aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}"
  dump nat-gateways.json  aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}"
  dump security-groups.json aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_ID}"
fi

[[ -n "${ALB_ARN}" ]] && {
  dump alb.json       aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}"
  dump listeners.json aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}"
}
[[ -n "${TG_ARN}" ]] && dump target-group.json aws elbv2 describe-target-groups --target-group-arns "${TG_ARN}"

dump asg.json             aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG}"
dump launch-templates.json aws ec2 describe-launch-templates --filters "Name=launch-template-name,Values=${NAME_PREFIX}-*"
dump instances.json       aws ec2 describe-instances --filters "${TAG_FILTER[@]}"
dump rds.json             aws rds describe-db-instances --db-instance-identifier "${DB_ID}"
dump rds-snapshots.json   aws rds describe-db-snapshots --db-instance-identifier "${DB_ID}"
dump secrets-metadata.json aws secretsmanager list-secrets --filters "Key=name,Values=${NAME_PREFIX}/"
dump alarms.json          aws cloudwatch describe-alarms --alarm-name-prefix "${NAME_PREFIX}-"

ok "inventory written to ${INV}"
