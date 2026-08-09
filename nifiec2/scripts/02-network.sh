#!/usr/bin/env bash
# ==========================================================================
# 02-network.sh -- Build a dedicated network for NiFi, from nothing.
#
#   1. VPC                 10.20.0.0/16      the private network itself
#   2. Internet gateway                      its door to the internet
#   3. Public subnets      10.20.1.0/24 + 10.20.2.0/24   (2 AZs)
#      + public route table with 0.0.0.0/0 -> internet gateway
#   4. Private subnets     10.20.11.0/24 + 10.20.12.0/24 (2 AZs)
#      + private route table (deliberately NO internet route)
#   5. SSH key pair
#   6. Security group      the firewall, locked to your IP
#   7. IAM role            so SSM can manage the box without SSH
#
# Everything created is tagged Project=nifi-demo and recorded with a
# CREATED_* flag, so 99-teardown.sh can delete exactly what we made and
# nothing else. Safe to re-run.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

A=(aws --region "$AWS_REGION")
tagspec() { printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=%s,Value=%s},{Key=Tier,Value=%s}]' \
  "$1" "$2" "$TAG_KEY" "$TAG_VALUE" "${3:-shared}"; }

# ==========================================================================
# 1. VPC
# ==========================================================================
log "STEP 1/7  VPC"

# Did an earlier run already build ours? Find it by tag.
VPC_ID="$("${A[@]}" ec2 describe-vpcs \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=state,Values=available" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)"

if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  ok "Reusing our VPC $VPC_ID from an earlier run"
  save_state CREATED_VPC "true"

elif [ "$REUSE_DEFAULT_VPC" = "true" ]; then
  VPC_ID="$("${A[@]}" ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)"
  [ "$VPC_ID" != "None" ] || die "REUSE_DEFAULT_VPC=true but this account has no default VPC.
       Either set it back to false, or run: aws ec2 create-default-vpc --region $AWS_REGION"
  ok "Using the account's DEFAULT VPC $VPC_ID (teardown will NOT delete it)"
  save_state CREATED_VPC "false"

else
  log "  Creating VPC ${VPC_CIDR} ..."
  VPC_ID="$("${A[@]}" ec2 create-vpc \
    --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tagspec vpc "${PROJECT}-vpc")" \
    --query 'Vpc.VpcId' --output text)"
  "${A[@]}" ec2 wait vpc-available --vpc-ids "$VPC_ID"

  # A hand-made VPC has DNS hostnames turned OFF. Without this the instance
  # gets no public DNS name, and package/SSM lookups become unreliable.
  "${A[@]}" ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support  '{"Value":true}'
  "${A[@]}" ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
  save_state CREATED_VPC "true"
  ok "Created VPC $VPC_ID with DNS support + hostnames enabled"
fi
save_state VPC_ID "$VPC_ID"

# ==========================================================================
# 2. Internet gateway
# ==========================================================================
log "STEP 2/7  Internet gateway"
IGW_ID="$("${A[@]}" ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[0].InternetGatewayId' --output text)"

if [ "$IGW_ID" != "None" ] && [ -n "$IGW_ID" ]; then
  ok "Already attached: $IGW_ID"
  [ "${CREATED_IGW:-}" = "true" ] || save_state CREATED_IGW "false"
else
  IGW_ID="$("${A[@]}" ec2 create-internet-gateway \
    --tag-specifications "$(tagspec internet-gateway "${PROJECT}-igw")" \
    --query 'InternetGateway.InternetGatewayId' --output text)"
  "${A[@]}" ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  save_state CREATED_IGW "true"
  ok "Created and attached $IGW_ID"
fi
save_state IGW_ID "$IGW_ID"

# ==========================================================================
# Helper: create one subnet (or find it if the CIDR is already there)
# ==========================================================================
read -r -a AZS <<< "$("${A[@]}" ec2 describe-availability-zones \
  --filters Name=state,Values=available \
  --query 'AvailabilityZones[].ZoneName' --output text | tr '\t' ' ')"
[ "${#AZS[@]}" -ge 2 ] || die "Region $AWS_REGION reports fewer than 2 usable AZs."

SUBNET_RESULT=""
make_subnet() {   # make_subnet <cidr> <az> <name> <public|private>
  local cidr="$1" az="$2" name="$3" tier="$4" sid
  sid="$("${A[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=cidr-block,Values=${cidr}" \
    --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo None)"
  if [ "$sid" != "None" ] && [ -n "$sid" ]; then
    ok "  ${cidr} ${az} -> $sid (already exists)"
    SUBNET_RESULT="$sid"; return
  fi
  sid="$("${A[@]}" ec2 create-subnet \
    --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
    --tag-specifications "$(tagspec subnet "${name}" "${tier}")" \
    --query 'Subnet.SubnetId' --output text)"
  "${A[@]}" ec2 wait subnet-available --subnet-ids "$sid"
  # Public subnets hand out a public IP automatically; private ones must not.
  if [ "$tier" = "public" ]; then
    "${A[@]}" ec2 modify-subnet-attribute --subnet-id "$sid" --map-public-ip-on-launch
  else
    "${A[@]}" ec2 modify-subnet-attribute --subnet-id "$sid" --no-map-public-ip-on-launch
  fi
  ok "  ${cidr} ${az} -> $sid (created, ${tier})"
  SUBNET_RESULT="$sid"
}

# ==========================================================================
# 3. Public subnets + public route table
# ==========================================================================
log "STEP 3/7  Public subnets"
PUBLIC_SUBNET_IDS=""
i=0
for cidr in $PUBLIC_SUBNET_CIDRS; do
  make_subnet "$cidr" "${AZS[$i]}" "${PROJECT}-public-$((i+1))" "public"
  PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS} ${SUBNET_RESULT}"
  i=$((i+1))
done
PUBLIC_SUBNET_IDS="$(echo "$PUBLIC_SUBNET_IDS" | xargs)"
save_state PUBLIC_SUBNET_IDS "$PUBLIC_SUBNET_IDS"

# The instance launches into the first public subnet.
SUBNET_ID="${PUBLIC_SUBNET_IDS%% *}"
save_state SUBNET_ID "$SUBNET_ID"
save_state AZ "${AZS[0]}"

log "  Public route table (0.0.0.0/0 -> ${IGW_ID})"
PUB_RTB_ID="$("${A[@]}" ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-public-rtb" \
  --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo None)"

if [ "$PUB_RTB_ID" = "None" ] || [ -z "$PUB_RTB_ID" ]; then
  # We make our own table rather than editing the VPC's main table, so
  # teardown can delete it cleanly without side effects.
  PUB_RTB_ID="$("${A[@]}" ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tagspec route-table "${PROJECT}-public-rtb" public)" \
    --query 'RouteTable.RouteTableId' --output text)"
  "${A[@]}" ec2 create-route --route-table-id "$PUB_RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  save_state CREATED_PUB_RTB "true"
  ok "  Created $PUB_RTB_ID with default route to the internet"
else
  ok "  Reusing $PUB_RTB_ID"
fi
save_state PUB_RTB_ID "$PUB_RTB_ID"

for sid in $PUBLIC_SUBNET_IDS; do
  EXISTING="$("${A[@]}" ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${sid}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo None)"
  if [ "$EXISTING" = "$PUB_RTB_ID" ]; then
    ok "  $sid already associated"
  else
    "${A[@]}" ec2 associate-route-table --route-table-id "$PUB_RTB_ID" --subnet-id "$sid" \
      --query 'AssociationId' --output text >/dev/null
    ok "  $sid associated with $PUB_RTB_ID"
  fi
done

# ==========================================================================
# 4. Private subnets + private route table (no internet route on purpose)
# ==========================================================================
PRIVATE_SUBNET_IDS=""
if [ -n "${PRIVATE_SUBNET_CIDRS// /}" ]; then
  log "STEP 4/7  Private subnets"
  i=0
  for cidr in $PRIVATE_SUBNET_CIDRS; do
    make_subnet "$cidr" "${AZS[$i]}" "${PROJECT}-private-$((i+1))" "private"
    PRIVATE_SUBNET_IDS="${PRIVATE_SUBNET_IDS} ${SUBNET_RESULT}"
    i=$((i+1))
  done
  PRIVATE_SUBNET_IDS="$(echo "$PRIVATE_SUBNET_IDS" | xargs)"

  PRIV_RTB_ID="$("${A[@]}" ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${PROJECT}-private-rtb" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo None)"
  if [ "$PRIV_RTB_ID" = "None" ] || [ -z "$PRIV_RTB_ID" ]; then
    PRIV_RTB_ID="$("${A[@]}" ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tagspec route-table "${PROJECT}-private-rtb" private)" \
      --query 'RouteTable.RouteTableId' --output text)"
    save_state CREATED_PRIV_RTB "true"
    ok "  Created $PRIV_RTB_ID (local routes only - no NAT gateway, so no"
    ok "  outbound internet from here. A NAT gateway costs ~\$32/month.)"
  else
    ok "  Reusing $PRIV_RTB_ID"
  fi
  for sid in $PRIVATE_SUBNET_IDS; do
    "${A[@]}" ec2 associate-route-table --route-table-id "$PRIV_RTB_ID" --subnet-id "$sid" \
      --query 'AssociationId' --output text >/dev/null 2>&1 \
      && ok "  $sid associated" || ok "  $sid already associated"
  done
  save_state PRIV_RTB_ID "$PRIV_RTB_ID"
else
  log "STEP 4/7  Private subnets skipped (PRIVATE_SUBNET_CIDRS is empty)"
fi
save_state PRIVATE_SUBNET_IDS "$PRIVATE_SUBNET_IDS"

# ==========================================================================
# 5. SSH key pair
# ==========================================================================
log "STEP 5/7  Key pair"
if [ "$ENABLE_SSH" = "true" ]; then
  if "${A[@]}" ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
    ok "$KEY_NAME already exists"
    [ -f "$KEY_FILE" ] || warn "AWS has the key but $KEY_FILE is missing locally - SSH will not work."
  else
    mkdir -p "$(dirname "$KEY_FILE")"
    "${A[@]}" ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
      --tag-specifications "$(tagspec key-pair "$KEY_NAME")" \
      --query 'KeyMaterial' --output text > "$KEY_FILE"
    chmod 400 "$KEY_FILE"
    ok "Private key at $KEY_FILE (chmod 400). AWS keeps no copy."
  fi
  save_state KEY_NAME "$KEY_NAME"
else
  save_state KEY_NAME ""
  ok "SSH disabled - SSM Session Manager only"
fi

# ==========================================================================
# 6. Security group
# ==========================================================================
log "STEP 6/7  Security group"
SG_ID="$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  SG_ID="$("${A[@]}" ec2 create-security-group \
    --group-name "$SG_NAME" --description "Apache NiFi ${NIFI_VERSION} access" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "$(tagspec security-group "$SG_NAME")" \
    --query 'GroupId' --output text)"
  ok "Created $SG_ID"
else
  ok "$SG_ID already exists"
fi
save_state SG_ID "$SG_ID"

add_rule() {  # add_rule <port> <cidr> <description>
  "${A[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$1,ToPort=$1,IpRanges=[{CidrIp=$2,Description='$3'}]" \
    >/dev/null 2>&1 && ok "Allowed tcp/$1 from $2" || ok "Rule tcp/$1 from $2 already present"
}
add_rule "$NIFI_HTTPS_PORT" "$MY_CIDR" "NiFi UI HTTPS"
[ "$ENABLE_SSH" = "true" ] && add_rule 22 "$MY_CIDR" "SSH admin"

# ==========================================================================
# 7. IAM role for SSM
# ==========================================================================
log "STEP 7/7  IAM role"
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --description "Allows the NiFi EC2 instance to be managed by AWS Systems Manager" \
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

cat <<SUMMARY

  ┌────────────────────────────────────────────────────────────┐
  │  NETWORK BUILT                                             │
  ├────────────────────────────────────────────────────────────┤
  │  VPC              ${VPC_ID}  ${VPC_CIDR}
  │  Internet gateway ${IGW_ID}
  │  Public subnets   ${PUBLIC_SUBNET_IDS}
  │  Public route tbl ${PUB_RTB_ID}  (0.0.0.0/0 -> igw)
  │  Private subnets  ${PRIVATE_SUBNET_IDS:-<none>}
  │  Private route tbl ${PRIV_RTB_ID:-<none>}  (local only)
  │  Security group   ${SG_ID}  (tcp/${NIFI_HTTPS_PORT}$([ "$ENABLE_SSH" = true ] && echo ", tcp/22") from ${MY_CIDR})
  │  NiFi launches in ${SUBNET_ID} (${AZS[0]})
  └────────────────────────────────────────────────────────────┘

SUMMARY
log "Next: ./03-launch.sh"
