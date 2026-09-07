#!/usr/bin/env bash
# List every AWS resource this stack created.
# Usage: ./scripts/view.sh [region] [project-name]
set -euo pipefail
REGION="${1:-${AWS_REGION:-us-east-1}}"
NAME="${2:-keycloak}"
export AWS_DEFAULT_REGION="$REGION"

hr() { printf '\n== %s ==\n' "$1"; }

hr "Tagged resources (Project=$NAME)"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$NAME" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sort

hr "Load balancer / target group"
aws elbv2 describe-load-balancers --names "$NAME" \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' --output table 2>/dev/null || echo "(none)"
TG=$(aws elbv2 describe-target-groups --names "$NAME" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
[[ -n "$TG" && "$TG" != "None" ]] && aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' --output table

hr "ACM certificates"
aws acm list-certificates --query 'CertificateSummaryList[].{Domain:DomainName,Status:Status,Arn:CertificateArn}' --output table

hr "EC2 instances"
aws ec2 describe-instances --filters "Name=tag:Project,Values=$NAME" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,PublicIP:PublicIpAddress}' --output table

hr "RDS"
aws rds describe-db-instances --db-instance-identifier "$NAME" \
  --query 'DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass,Endpoint:Endpoint.Address}' --output table 2>/dev/null || echo "(none)"
aws rds describe-db-snapshots --db-instance-identifier "$NAME" \
  --query 'DBSnapshots[].{Id:DBSnapshotIdentifier,Type:SnapshotType}' --output table 2>/dev/null || true

hr "VPC / subnets / IGW / route tables / security groups"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$NAME" --query 'Vpcs[0].VpcId' --output text)
if [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]]; then
  echo "VPC: $VPC_ID"
  aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table
  aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[].InternetGatewayId' --output text
  aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[].{Id:RouteTableId,Main:Associations[0].Main}' --output table
  aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[].{Id:GroupId,Name:GroupName}' --output table
else
  echo "(no VPC named $NAME)"
fi

hr "IAM"
aws iam get-role --role-name "$NAME-ec2" --query 'Role.Arn' --output text 2>/dev/null || echo "(no role)"
aws iam get-instance-profile --instance-profile-name "$NAME-ec2" --query 'InstanceProfile.Arn' --output text 2>/dev/null || echo "(no instance profile)"

hr "Route 53 records mentioning $NAME or the ALB"
for ZONE in $(aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==`false`].Id' --output text); do
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" \
    --query "ResourceRecordSets[?contains(to_string(@), '$NAME') || contains(to_string(@), 'elb.amazonaws.com') || contains(Name, '_acme') || Type=='CNAME' && contains(to_string(ResourceRecords), 'acm-validations')].{Name:Name,Type:Type}" --output table
done
