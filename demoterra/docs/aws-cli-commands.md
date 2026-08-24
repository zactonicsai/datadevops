# AWS CLI reference — verify and destroy, by area, in order

Every command below is what the scripts in `scripts/verify/` and `scripts/destroy/` actually run. Use them directly when you want to inspect one thing, or when a script needs adapting.

Set these first:

```bash
export PROJECT=keycloak ENV=dev AWS_REGION=us-east-1
export PREFIX="${PROJECT}-${ENV}"
export TAGS="Name=tag:Project,Values=${PROJECT} Name=tag:Environment,Values=${ENV}"
```

**Order matters.** Verification runs outside-in (network first, application last). Teardown runs the opposite way — consumers before the things they consume — because AWS refuses to delete a resource that anything still depends on.

---

## Backup — always first (`scripts/backup/`)

```bash
# 1. State and outputs
terraform state pull > terraform.tfstate.bak
terraform output -json > outputs.json

# 2. Secrets (plaintext — move to a vault, then delete)
aws secretsmanager list-secrets --filters "Key=name,Values=${PREFIX}/" --query 'SecretList[].ARN' --output text
aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text

# 3. Manual RDS snapshot — the only copy that outlives the instance
aws rds create-db-snapshot \
  --db-instance-identifier "${PREFIX}-postgres" \
  --db-snapshot-identifier "${PREFIX}-manual-$(date -u +%Y%m%d%H%M%S)"
aws rds wait db-snapshot-completed --db-snapshot-identifier "${PREFIX}-manual-..."

# 4. Inventory
aws ec2 describe-vpcs --filters ${TAGS} > vpc.json
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${PREFIX}-asg" > asg.json
aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" > rds.json
```

Restore a database from a snapshot:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "${PREFIX}-postgres-restored" \
  --db-snapshot-identifier "${PREFIX}-manual-YYYYMMDDHHMMSS" \
  --db-subnet-group-name "${PREFIX}-db-subnets" \
  --vpc-security-group-ids <database-sg-id> \
  --multi-az --no-publicly-accessible
```

---

## Verify — area 1: networking

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters ${TAGS} --query 'Vpcs[0].VpcId' --output text)

aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Tier:Tags[?Key==`Tier`]|[0].Value}' --output table

aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[?State==`available`].{Id:NatGatewayId,Subnet:SubnetId}' --output table

# The database route table must have no 0.0.0.0/0 route
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" \
  "Name=tag:Name,Values=${PREFIX}-rt-database" --query 'RouteTables[0].Routes' --output table

```

## Verify — area 2: security groups

```bash
for tier in alb keycloak database vpce; do
  aws ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-${tier}-sg" \
    --query 'SecurityGroups[0].{Name:GroupName,Id:GroupId}' --output text
done

# Keycloak ingress should reference the ALB SG and contain no CIDR rules
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=<keycloak-sg>" \
  --query 'SecurityGroupRules[?!IsEgress].{Port:FromPort,CIDR:CidrIpv4,SG:ReferencedGroupInfo.GroupId}' --output table
```

## Verify — area 3: secrets

```bash
aws secretsmanager list-secrets --filters "Key=name,Values=${PREFIX}/" \
  --query 'SecretList[].{Name:Name,Kms:KmsKeyId,Replicas:length(ReplicationStatus||`[]`)}' --output table

# Keys only, never the values
aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text | jq 'keys'
```

## Verify — area 4: RDS

```bash
aws rds describe-db-instances --db-instance-identifier "${PREFIX}-postgres" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,MultiAZ:MultiAZ,AZ:AvailabilityZone,Standby:SecondaryAvailabilityZone,Encrypted:StorageEncrypted,Retention:BackupRetentionPeriod,Protected:DeletionProtection}' --output table

aws rds describe-db-snapshots --db-instance-identifier "${PREFIX}-postgres" \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[:5].{Id:DBSnapshotIdentifier,Type:SnapshotType,Status:Status}' --output table
```

## Verify — area 5: load balancer

```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${PREFIX}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names "${PREFIX}-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,SSL:SslPolicy}' --output table

# Healthy targets should appear in more than one AZ
aws elbv2 describe-target-health --target-group-arn "${TG_ARN}" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason}' --output table
```

## Verify — area 6: EC2 hosts

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${PREFIX}-asg" \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,HealthCheck:HealthCheckType}' --output table

# Instances should be InService, Healthy, and in more than one AZ
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${PREFIX}-asg" \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,AZ:AvailabilityZone,State:LifecycleState,Health:HealthStatus}' --output table

# Why an instance was replaced
aws autoscaling describe-scaling-activities --auto-scaling-group-name "${PREFIX}-asg" --max-items 5 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:Description}' --output table

# Bootstrap trouble: read cloud-init output on the box
aws ssm start-session --target <instance-id>
#   sudo tail -100 /var/log/cloud-init-output.log
#   sudo docker ps && sudo docker logs keycloak --tail 100
```


## Verify — area 7: Keycloak

```bash
DNS=$(aws elbv2 describe-load-balancers --names "${PREFIX}-alb" --query 'LoadBalancers[0].DNSName' --output text)

curl -sS "https://${DNS}/realms/master/.well-known/openid-configuration" | jq '.issuer'
curl -sS -o /dev/null -w '%{http_code}\n' "https://${DNS}/realms/master"

aws logs filter-log-events --log-group-name "/aws/ec2/${PREFIX}/keycloak" \
  --start-time $(( ($(date +%s) - 900) * 1000 )) --filter-pattern 'ERROR' \
  --query 'events[].message' --output text
```

---

## Destroy — reverse order

Run the backup section above first. Each step assumes the previous one finished.

### 1. EC2 hosts (consumers first)

```bash
aws autoscaling delete-policy --auto-scaling-group-name "${PREFIX}-asg" --policy-name <policy>

aws autoscaling update-auto-scaling-group --auto-scaling-group-name "${PREFIX}-asg" \
  --min-size 0 --max-size 0 --desired-capacity 0
# wait until Instances[] is empty, then:
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "${PREFIX}-asg" --force-delete

aws ec2 delete-launch-template --launch-template-id <id>
```


### 2. Load balancer

```bash
aws elbv2 modify-load-balancer-attributes --load-balancer-arn "${ALB_ARN}" \
  --attributes Key=deletion_protection.enabled,Value=false
aws elbv2 delete-listener --listener-arn <each-listener-arn>
aws elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}"
aws elbv2 wait load-balancers-deleted --load-balancer-arns "${ALB_ARN}"
aws elbv2 delete-target-group --target-group-arn "${TG_ARN}"
```

### 3. RDS

```bash
aws rds modify-db-instance --db-instance-identifier "${PREFIX}-postgres" \
  --no-deletion-protection --apply-immediately
aws rds delete-db-instance --db-instance-identifier "${PREFIX}-postgres" \
  --final-db-snapshot-identifier "${PREFIX}-final-$(date -u +%Y%m%d%H%M%S)" --no-skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier "${PREFIX}-postgres"

aws rds delete-db-subnet-group --db-subnet-group-name "${PREFIX}-db-subnets"
aws rds delete-db-parameter-group --db-parameter-group-name <pg-name>
```

### 4. Secrets

```bash
# Recoverable (preferred)
aws secretsmanager delete-secret --secret-id <arn> --recovery-window-in-days 7
aws secretsmanager restore-secret --secret-id <arn>          # undo

# Permanent
aws secretsmanager delete-secret --secret-id <arn> --force-delete-without-recovery
```

### 5. Alarms, logs, notifications

```bash
aws cloudwatch delete-alarms --alarm-names $(aws cloudwatch describe-alarms \
  --alarm-name-prefix "${PREFIX}-" --query 'MetricAlarms[].AlarmName' --output text)
aws logs delete-log-group --log-group-name "/aws/ec2/${PREFIX}/keycloak"
aws sns delete-topic --topic-arn <topic-arn>
```

### 6. Networking (last)

```bash
aws ec2 delete-nat-gateway --nat-gateway-id <id>
aws ec2 wait nat-gateway-deleted --nat-gateway-ids <ids>
aws ec2 release-address --allocation-id <id>
aws ec2 delete-network-interface --network-interface-id <id>     # leftovers
aws ec2 delete-subnet --subnet-id <id>
aws ec2 revoke-security-group-ingress --group-id <sg> --security-group-rule-ids <ids>
aws ec2 delete-security-group --group-id <sg>
aws ec2 delete-route-table --route-table-id <id>
aws ec2 detach-internet-gateway --internet-gateway-id <igw> --vpc-id "${VPC_ID}"
aws ec2 delete-internet-gateway --internet-gateway-id <igw>
aws ec2 delete-vpc --vpc-id "${VPC_ID}"
```

When `delete-vpc` reports a dependency violation, something still holds an ENI:

```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}' --output table
```
