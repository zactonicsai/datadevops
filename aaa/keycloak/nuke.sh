#!/usr/bin/env bash
# Emergency teardown with the AWS CLI only (no Terraform state needed).
# Usage: ./scripts/nuke.sh [region] [project-name] [keycloak-domain] [zone-name]
set -euo pipefail
REGION="${1:-${AWS_REGION:-us-east-1}}"
NAME="${2:-keycloak}"
DOMAIN="${3:-}"
ZONE_NAME="${4:-}"
export AWS_DEFAULT_REGION="$REGION"

echo "About to DELETE all '$NAME' resources in $REGION (ALB, ACM, EC2, RDS incl. data, VPC, IAM, Route 53 records)."
read -r -p "Type 'nuke' to continue: " ANSWER
[[ "$ANSWER" == "nuke" ]] || { echo "Aborted."; exit 1; }
log() { printf '\n--> %s\n' "$*"; }

# 1. ALB, listeners, target group
log "Deleting load balancer"
LB=$(aws elbv2 describe-load-balancers --names "$NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [[ -n "$LB" && "$LB" != "None" ]]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$LB"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$LB"
fi
TG=$(aws elbv2 describe-target-groups --names "$NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
[[ -n "$TG" && "$TG" != "None" ]] && aws elbv2 delete-target-group --target-group-arn "$TG"

# 2. Route 53 records (alias + ACM validation CNAME)
if [[ -n "$DOMAIN" && -n "$ZONE_NAME" ]]; then
  log "Deleting Route 53 records for $DOMAIN"
  ZONE=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" --query 'HostedZones[0].Id' --output text)
  for REC in $(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
      --query "ResourceRecordSets[?Name=='$DOMAIN.' || (Type=='CNAME' && ends_with(Name, '$DOMAIN.'))].Name" --output text); do
    RS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" --query "ResourceRecordSets[?Name=='$REC'] | [0]" --output json)
    aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" \
      --change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$RS}]}" >/dev/null
    echo "deleted $REC"
  done
fi

# 3. ACM cert
if [[ -n "$DOMAIN" ]]; then
  log "Deleting ACM certificate"
  for ARN in $(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text); do
    aws acm delete-certificate --certificate-arn "$ARN" || echo "(cert still in use; retry after ALB is gone)"
  done
fi

# 4. EC2
log "Terminating EC2 instances"
IDS=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n "$IDS" ]]; then
  aws ec2 terminate-instances --instance-ids $IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $IDS
fi

# 5. RDS
log "Deleting RDS instance (several minutes)"
if aws rds describe-db-instances --db-instance-identifier "$NAME" >/dev/null 2>&1; then
  aws rds modify-db-instance --db-instance-identifier "$NAME" --no-deletion-protection --apply-immediately >/dev/null || true
  aws rds delete-db-instance --db-instance-identifier "$NAME" --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$NAME"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$NAME" 2>/dev/null || true

# 6. IAM
log "Deleting IAM"
aws iam remove-role-from-instance-profile --instance-profile-name "$NAME-ec2" --role-name "$NAME-ec2" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$NAME-ec2" 2>/dev/null || true
aws iam detach-role-policy --role-name "$NAME-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
aws iam delete-role --role-name "$NAME-ec2" 2>/dev/null || true

# 7. VPC
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$NAME" --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
  log "Deleting VPC $VPC_ID"
  SGS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)
  for SG in $SGS; do
    PERMS=$(aws ec2 describe-security-groups --group-ids "$SG" --query 'SecurityGroups[0].IpPermissions' --output json)
    [[ "$PERMS" != "[]" ]] && aws ec2 revoke-security-group-ingress --group-id "$SG" --ip-permissions "$PERMS" >/dev/null
  done
  for SG in $SGS; do aws ec2 delete-security-group --group-id "$SG"; done
  for S in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text); do aws ec2 delete-subnet --subnet-id "$S"; done
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' --output text); do aws ec2 delete-route-table --route-table-id "$RT"; done
  for IGW in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID"; aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
  done
  aws ec2 delete-vpc --vpc-id "$VPC_ID"
fi

log "Done. Remaining tagged resources (should be empty):"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$NAME" --query 'ResourceTagMappingList[].ResourceARN' --output text
