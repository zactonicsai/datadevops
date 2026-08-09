#!/usr/bin/env bash
# ==========================================================================
# 02-network.sh -- Build the "surroundings" the server needs:
#   1. find a VPC + public subnet   (the virtual network)
#   2. create an SSH key pair       (your private door key)
#   3. create a security group      (the firewall)
#   4. create an IAM role           (the server's own ID badge, for SSM)
# Safe to re-run: every step checks whether the thing already exists.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

TAGS="ResourceType=%s,Tags=[{Key=Name,Value=${PROJECT}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]"

# --------------------------------------------------------------------------
# 1. VPC + subnet
# --------------------------------------------------------------------------
log "Finding default VPC..."
VPC_ID="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)"
[ "$VPC_ID" != "None" ] || die "No default VPC in $AWS_REGION. Create one: aws ec2 create-default-vpc --region $AWS_REGION"
save_state VPC_ID "$VPC_ID"
ok "VPC $VPC_ID"

log "Picking a public subnet (one that auto-assigns public IPs)..."
SUBNET_ID="$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets | sort_by(@,&AvailableIpAddressCount) | [-1].SubnetId' --output text)"
[ "$SUBNET_ID" != "None" ] || die "No public subnet found in $VPC_ID."
AZ="$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' --output text)"
save_state SUBNET_ID "$SUBNET_ID"
save_state AZ "$AZ"
ok "Subnet $SUBNET_ID in $AZ"

# --------------------------------------------------------------------------
# 2. SSH key pair (only if you enabled SSH)
# --------------------------------------------------------------------------
if [ "$ENABLE_SSH" = "true" ]; then
  if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
    ok "Key pair $KEY_NAME already exists"
    [ -f "$KEY_FILE" ] || warn "AWS has the key but $KEY_FILE is missing locally. You will not be able to SSH."
  else
    log "Creating key pair $KEY_NAME..."
    mkdir -p "$(dirname "$KEY_FILE")"
    aws ec2 create-key-pair --region "$AWS_REGION" \
      --key-name "$KEY_NAME" \
      --key-type ed25519 \
      --tag-specifications "$(printf "$TAGS" key-pair)" \
      --query 'KeyMaterial' --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    ok "Private key written to $KEY_FILE (chmod 400). AWS keeps no copy - do not lose it."
  fi
  save_state KEY_NAME "$KEY_NAME"
else
  save_state KEY_NAME ""
  ok "SSH disabled - will use SSM Session Manager only"
fi

# --------------------------------------------------------------------------
# 3. Security group (the firewall)
# --------------------------------------------------------------------------
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  log "Creating security group $SG_NAME..."
  SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "Apache NiFi ${NIFI_VERSION} access" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$(printf "$TAGS" security-group)" \
    --query 'GroupId' --output text)"
  ok "Created $SG_ID"
else
  ok "Security group $SG_ID already exists"
fi
save_state SG_ID "$SG_ID"

add_rule() {  # add_rule <port> <cidr> <description>
  aws ec2 authorize-security-group-ingress --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$1,ToPort=$1,IpRanges=[{CidrIp=$2,Description='$3'}]" \
    >/dev/null 2>&1 && ok "Allowed tcp/$1 from $2" \
    || ok "Rule tcp/$1 from $2 already present"
}

log "Opening ports for ${MY_CIDR} only..."
add_rule "$NIFI_HTTPS_PORT" "$MY_CIDR" "NiFi UI HTTPS"
[ "$ENABLE_SSH" = "true" ] && add_rule 22 "$MY_CIDR" "SSH admin"

# --------------------------------------------------------------------------
# 4. IAM role so the instance can be managed by SSM (no SSH needed)
# --------------------------------------------------------------------------
log "Setting up IAM role $IAM_ROLE_NAME..."
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --description "Allows the NiFi EC2 instance to be managed by AWS Systems Manager" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' \
    --tags Key="$TAG_KEY",Value="$TAG_VALUE" >/dev/null
  ok "Role created"
else
  ok "Role already exists"
fi

aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
ok "Attached AmazonSSMManagedInstanceCore"

if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --tags Key="$TAG_KEY",Value="$TAG_VALUE" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
  log "Waiting 12s for IAM to propagate (IAM is eventually consistent)..."
  sleep 12
  ok "Instance profile created"
else
  ok "Instance profile already exists"
fi
save_state INSTANCE_PROFILE_NAME "$INSTANCE_PROFILE_NAME"

log "Network + identity ready. Next: ./03-launch.sh"
