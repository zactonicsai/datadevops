#!/usr/bin/env bash
# ==========================================================================
# 02-adopt.sh -- Record the network we were given, and create the only two
# things this mode adds to it:
#
#     a security group   (inside the existing VPC)
#     an IAM role        (skipped if EXISTING_INSTANCE_PROFILE is set)
#
# It does NOT create or modify: the VPC, subnets, route tables, gateways,
# NAT, or the hosted zone. Everything it records is marked ADOPTED, so the
# teardown knows to leave it alone.
#
#   ./02-adopt.sh
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"
load_state

A=(aws --region "$AWS_REGION")

# --------------------------------------------------------------------------
# 1. Record what we were given. ADOPTED means "not ours - never delete".
# --------------------------------------------------------------------------
log "Recording the existing network..."
"${A[@]}" ec2 describe-vpcs --vpc-ids "$EXISTING_VPC_ID" >/dev/null \
  || die "VPC $EXISTING_VPC_ID not found. Run ./01-discover.sh first."

save_state VPC_ID       "$EXISTING_VPC_ID"
save_state ADOPTED_VPC  "true"
save_state CREATED_VPC  "false"
save_state CREATED_IGW  "false"
save_state CREATED_SUBNET "false"

SUBNETS="$EXISTING_SUBNET_IDS"
if [ -n "$SUBNET_TAG_KEY" ]; then
  SUBNETS="$("${A[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" \
              "Name=tag:${SUBNET_TAG_KEY},Values=${SUBNET_TAG_VALUE}" \
              "Name=state,Values=available" \
    --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')"
fi
[ -n "$SUBNETS" ] || die "No subnets resolved. Check EXISTING_SUBNET_IDS or the tag filter."

LAUNCH_SUBNET="$(echo "$SUBNETS" | awk '{print $1}')"
LAUNCH_AZ="$("${A[@]}" ec2 describe-subnets --subnet-ids "$LAUNCH_SUBNET" \
  --query 'Subnets[0].AvailabilityZone' --output text)"

save_state SUBNET_IDS      "$SUBNETS"
save_state SUBNET_ID       "$LAUNCH_SUBNET"
save_state AZ              "$LAUNCH_AZ"
save_state ADOPTED_SUBNETS "true"
ok "VPC $EXISTING_VPC_ID, launching into $LAUNCH_SUBNET ($LAUNCH_AZ)"

# --------------------------------------------------------------------------
# 2. Record the hosted zone. Also adopted - we only add one record to it.
# --------------------------------------------------------------------------
ZID="$HOSTED_ZONE_ID"
if [ -z "$ZID" ]; then
  WANT="${HOSTED_ZONE_NAME%.}."
  ZID="$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${WANT}'].Id" --output text | head -1 | sed 's|/hostedzone/||')"
fi
[ -n "$ZID" ] || die "Hosted zone not found. Set HOSTED_ZONE_ID in 00-existing-config.sh."
aws route53 get-hosted-zone --id "$ZID" >/dev/null || die "Cannot read hosted zone $ZID."

save_state HOSTED_ZONE_ID "$ZID"
save_state NIFI_DNS_NAME  "$NIFI_DNS_NAME"
save_state ADOPTED_ZONE   "true"
ok "Hosted zone $ZID will hold the record $NIFI_DNS_NAME"

# --------------------------------------------------------------------------
# 3. The security group -- created by us, so teardown deletes it
# --------------------------------------------------------------------------
log "Security group ${EX_SG_NAME} ..."
SG_ID="$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${EX_SG_NAME}" "Name=vpc-id,Values=${EXISTING_VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$("${A[@]}" ec2 create-security-group \
    --group-name "$EX_SG_NAME" \
    --description "Apache NiFi ${NIFI_VERSION} - private, reached via ${NIFI_DNS_NAME}" \
    --vpc-id "$EXISTING_VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${EX_SG_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Mode,Value=existing-network}]" \
    --query 'GroupId' --output text)"
  ok "Created $SG_ID"
else
  ok "$SG_ID already exists"
fi
save_state SG_ID "$SG_ID"
save_state CREATED_SG "true"

# There is no public IP here, so we allow internal ranges, not "your laptop".
for cidr in $ALLOWED_CIDRS; do
  "${A[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=${NIFI_HTTPS_PORT},ToPort=${NIFI_HTTPS_PORT},IpRanges=[{CidrIp=${cidr},Description='NiFi UI via ${NIFI_DNS_NAME}'}]" \
    >/dev/null 2>&1 && ok "Allowed tcp/${NIFI_HTTPS_PORT} from ${cidr}" \
    || ok "Rule for ${cidr} already present"
done

for sg in $ALLOWED_SOURCE_SGS; do
  "${A[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=${NIFI_HTTPS_PORT},ToPort=${NIFI_HTTPS_PORT},UserIdGroupPairs=[{GroupId=${sg},Description='allowed upstream'}]" \
    >/dev/null 2>&1 && ok "Allowed tcp/${NIFI_HTTPS_PORT} from security group ${sg}" \
    || ok "Rule for ${sg} already present"
done

if [ -n "$EX_KEY_NAME" ]; then
  for cidr in $ALLOWED_CIDRS; do
    "${A[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${cidr},Description='SSH from internal network'}]" \
      >/dev/null 2>&1 && ok "Allowed tcp/22 from ${cidr}" || true
  done
  save_state KEY_NAME "$EX_KEY_NAME"
else
  save_state KEY_NAME ""
  ok "SSH not enabled - use SSM Session Manager"
fi

# --------------------------------------------------------------------------
# 4. IAM -- reuse if you were given one, otherwise create
# --------------------------------------------------------------------------
if [ -n "$EXISTING_INSTANCE_PROFILE" ]; then
  aws iam get-instance-profile --instance-profile-name "$EXISTING_INSTANCE_PROFILE" >/dev/null \
    || die "Instance profile $EXISTING_INSTANCE_PROFILE not found."
  save_state INSTANCE_PROFILE_NAME "$EXISTING_INSTANCE_PROFILE"
  save_state CREATED_IAM "false"
  ok "Using the existing instance profile $EXISTING_INSTANCE_PROFILE (teardown will not touch it)"
else
  log "IAM role ${IAM_ROLE_NAME} ..."
  if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role --role-name "$IAM_ROLE_NAME" \
      --description "NiFi on an existing private network - SSM management" \
      --assume-role-policy-document '{
        "Version":"2012-10-17",
        "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
      }' --tags Key="$TAG_KEY",Value="$TAG_VALUE" >/dev/null
    ok "Role created"
  else
    ok "Role already exists"
  fi
  aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  ok "AmazonSSMManagedInstanceCore attached"

  # Reading the NiFi zip out of your own bucket needs one extra permission.
  if [ "$NIFI_SOURCE_MODE" = "s3" ]; then
    BUCKET="$(echo "$NIFI_S3_PREFIX" | sed -E 's|^s3://([^/]+).*|\1|')"
    aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
      --policy-name "read-nifi-artifacts" \
      --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
        {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"},
        {\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":\"arn:aws:s3:::${BUCKET}\"}]}" >/dev/null
    ok "Granted read access to s3://${BUCKET}"
  fi

  if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
      --tags Key="$TAG_KEY",Value="$TAG_VALUE" >/dev/null
    aws iam add-role-to-instance-profile \
      --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
    log "  Waiting 12s for IAM to propagate..."
    sleep 12
    ok "Instance profile created"
  else
    ok "Instance profile already exists"
  fi
  save_state INSTANCE_PROFILE_NAME "$INSTANCE_PROFILE_NAME"
  save_state CREATED_IAM "true"
fi

cat <<SUMMARY

  ┌────────────────────────────────────────────────────────────┐
  │  ADOPTED (never deleted by our teardown)                   │
  ├────────────────────────────────────────────────────────────┤
  │  VPC           ${EXISTING_VPC_ID}
  │  Subnets       ${SUBNETS}
  │  Hosted zone   ${ZID}
  ├────────────────────────────────────────────────────────────┤
  │  CREATED BY US (deleted by our teardown)                   │
  ├────────────────────────────────────────────────────────────┤
  │  Security grp  ${SG_ID}
  │  IAM           $([ -n "$EXISTING_INSTANCE_PROFILE" ] && echo "none - reusing ${EXISTING_INSTANCE_PROFILE}" || echo "${IAM_ROLE_NAME} / ${INSTANCE_PROFILE_NAME}")
  │  DNS record    ${NIFI_DNS_NAME}   (added in the next step)
  └────────────────────────────────────────────────────────────┘

SUMMARY
log "Next: ./03-launch-private.sh"
