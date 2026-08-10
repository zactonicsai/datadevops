#!/usr/bin/env bash
# ==========================================================================
# 01-discover.sh -- Look at the network you have been given and report what
# is really there. CREATES NOTHING. Changes nothing. Safe to run any time.
#
# Run this first, and read every line of the output. Most of the problems in
# this mode come from an assumption about somebody else's network that turns
# out to be wrong.
#
#   ./01-discover.sh
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"

A=(aws --region "$AWS_REGION")
PROBLEMS=0
WARNINGS=0
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }
soft() { printf '  \033[1;33mWARN\033[0m %s\n' "$*"; WARNINGS=$((WARNINGS+1)); }

echo
log "=============================================================="
log " Inventory of the existing network"
log "=============================================================="

# --------------------------------------------------------------------------
# 0. Credentials
# --------------------------------------------------------------------------
CALLER="$("${A[@]}" sts get-caller-identity --output json 2>/dev/null)" \
  || die "AWS credentials are not working."
ok "Account $(echo "$CALLER" | jq -r .Account) as $(echo "$CALLER" | jq -r .Arn)"

# --------------------------------------------------------------------------
# 1. The VPC
# --------------------------------------------------------------------------
echo; log "1. VPC"
VPC_JSON="$("${A[@]}" ec2 describe-vpcs --vpc-ids "$EXISTING_VPC_ID" --output json 2>/dev/null)"
if [ -z "$VPC_JSON" ]; then
  fail "VPC $EXISTING_VPC_ID not found in $AWS_REGION. Check the id and the region."
  echo; die "Cannot continue without a VPC."
fi
VPC_CIDR_ACTUAL="$(echo "$VPC_JSON" | jq -r '.Vpcs[0].CidrBlock')"
VPC_NAME="$(echo "$VPC_JSON" | jq -r '.Vpcs[0].Tags[]?|select(.Key=="Name")|.Value' 2>/dev/null)"
ok "$EXISTING_VPC_ID  ${VPC_NAME:+($VPC_NAME)  }$VPC_CIDR_ACTUAL"

DNS_SUP="$("${A[@]}" ec2 describe-vpc-attribute --vpc-id "$EXISTING_VPC_ID" \
  --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text)"
DNS_HOST="$("${A[@]}" ec2 describe-vpc-attribute --vpc-id "$EXISTING_VPC_ID" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)"
[ "$DNS_SUP" = "True" ] && ok "enableDnsSupport   : True" \
  || fail "enableDnsSupport is False. A private hosted zone cannot resolve inside this VPC without it."
[ "$DNS_HOST" = "True" ] && ok "enableDnsHostnames : True" \
  || soft "enableDnsHostnames is False. Usually fine here, since we use our own DNS name."

# --------------------------------------------------------------------------
# 2. The subnets
# --------------------------------------------------------------------------
echo; log "2. Subnets"
if [ -n "$SUBNET_TAG_KEY" ]; then
  log "  Looking up by tag ${SUBNET_TAG_KEY}=${SUBNET_TAG_VALUE} ..."
  EXISTING_SUBNET_IDS="$("${A[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" \
              "Name=tag:${SUBNET_TAG_KEY},Values=${SUBNET_TAG_VALUE}" \
              "Name=state,Values=available" \
    --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')"
  [ -n "$EXISTING_SUBNET_IDS" ] || fail "No subnets carry that tag."
fi

USABLE_SUBNETS=""
AZ_LIST=""
for sid in $EXISTING_SUBNET_IDS; do
  S="$("${A[@]}" ec2 describe-subnets --subnet-ids "$sid" --output json 2>/dev/null)"
  if [ -z "$S" ]; then fail "Subnet $sid not found."; continue; fi

  S_VPC="$(echo "$S" | jq -r '.Subnets[0].VpcId')"
  S_AZ="$(echo "$S" | jq -r '.Subnets[0].AvailabilityZone')"
  S_CIDR="$(echo "$S" | jq -r '.Subnets[0].CidrBlock')"
  S_FREE="$(echo "$S" | jq -r '.Subnets[0].AvailableIpAddressCount')"
  S_PUB="$(echo "$S" | jq -r '.Subnets[0].MapPublicIpOnLaunch')"
  S_NAME="$(echo "$S" | jq -r '.Subnets[0].Tags[]?|select(.Key=="Name")|.Value' 2>/dev/null)"

  if [ "$S_VPC" != "$EXISTING_VPC_ID" ]; then
    fail "$sid is in $S_VPC, not $EXISTING_VPC_ID"; continue
  fi

  # Which route table governs this subnet? An explicit association if there
  # is one, otherwise the VPC's main table.
  RT="$("${A[@]}" ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${sid}" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)"
  if [ "$RT" = "None" ] || [ -z "$RT" ]; then
    RT="$("${A[@]}" ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=association.main,Values=true" \
      --query 'RouteTables[0].RouteTableId' --output text)"
    RT_NOTE="(main table)"
  else
    RT_NOTE=""
  fi
  DEFAULT_TARGET="$("${A[@]}" ec2 describe-route-tables --route-table-ids "$RT" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,NatGatewayId,TransitGatewayId]' \
    --output text 2>/dev/null | tr '\t' ' ' | sed 's/None//g' | xargs)"

  case "$DEFAULT_TARGET" in
    igw-*) ROUTE_KIND="INTERNET GATEWAY - this is a PUBLIC subnet" ;;
    nat-*) ROUTE_KIND="NAT gateway (outbound internet available)" ;;
    tgw-*) ROUTE_KIND="transit gateway" ;;
    "")    ROUTE_KIND="no default route (fully private)" ;;
    *)     ROUTE_KIND="$DEFAULT_TARGET" ;;
  esac

  echo "    $sid  ${S_NAME:+$S_NAME  }$S_CIDR  $S_AZ  free=$S_FREE"
  echo "        route table $RT $RT_NOTE -> $ROUTE_KIND"

  [ "$S_FREE" -lt 8 ] && soft "$sid has only $S_FREE free addresses left."
  [ "$S_PUB" = "true" ] && soft "$sid sets MapPublicIpOnLaunch=true. We override that at launch, so no public IP is assigned."
  case "$DEFAULT_TARGET" in
    igw-*) soft "$sid routes straight to an internet gateway. That is a public subnet; check this is what your network team intended for NiFi." ;;
  esac

  USABLE_SUBNETS="${USABLE_SUBNETS} ${sid}"
  AZ_LIST="${AZ_LIST} ${S_AZ}"
  # Remember the outbound story for the first subnet, which is where we launch.
  [ -z "${FIRST_ROUTE:-}" ] && FIRST_ROUTE="$DEFAULT_TARGET"
done
USABLE_SUBNETS="$(echo "$USABLE_SUBNETS" | xargs)"
[ -n "$USABLE_SUBNETS" ] || fail "No usable subnets."

UNIQUE_AZS="$(echo "$AZ_LIST" | tr ' ' '\n' | sort -u | grep -c . || echo 0)"
[ "$UNIQUE_AZS" -ge 2 ] && ok "Subnets span $UNIQUE_AZS Availability Zones" \
  || soft "All subnets are in one Availability Zone. Fine for one instance; a load balancer would need two."

# --------------------------------------------------------------------------
# 3. How does the instance reach the outside world?
# --------------------------------------------------------------------------
echo; log "3. Outbound path (the bootstrap must download ~1.2 GB)"
NATS="$("${A[@]}" ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=${EXISTING_VPC_ID}" "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null | tr '\t' ' ')"
[ -n "$NATS" ] && ok "NAT gateway(s) in this VPC: $NATS" || echo "    no NAT gateways in this VPC"

log "  VPC endpoints:"
EPS="$("${A[@]}" ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${EXISTING_VPC_ID}" \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output text 2>/dev/null)"
if [ -n "$EPS" ]; then echo "$EPS" | sed 's/^/    /'; else echo "    none"; fi
has_ep() { echo "$EPS" | grep -q "\.${1}\b"; }

case "$FIRST_ROUTE" in
  nat-*|igw-*)
    ok "The launch subnet has a route out. NIFI_SOURCE_MODE=\"internet\" will work."
    [ "$NIFI_SOURCE_MODE" = "s3" ] && soft "You set NIFI_SOURCE_MODE=s3, which is fine but not required here." ;;
  *)
    soft "The launch subnet has NO default route. Downloads from the internet will hang."
    if has_ep "s3"; then
      ok "An S3 endpoint exists - dnf and an S3-hosted NiFi zip will work."
    else
      fail "No S3 VPC endpoint and no NAT. The instance cannot install anything. Ask for an S3 gateway endpoint."
    fi
    [ "$NIFI_SOURCE_MODE" != "s3" ] && fail "Set NIFI_SOURCE_MODE=\"s3\" and NIFI_S3_PREFIX, or ask for a NAT gateway." ;;
esac

# SSM is how we get a shell and how the verify script works.
if [ -n "$NATS" ] || [[ "$FIRST_ROUTE" == igw-* ]]; then
  ok "SSM will reach AWS over the NAT/internet route."
else
  MISSING=""
  for svc in ssm ssmmessages ec2messages; do has_ep "$svc" || MISSING="$MISSING $svc"; done
  if [ -n "$MISSING" ]; then
    soft "Missing interface endpoints for:$MISSING - Session Manager and remote commands will not work."
    soft "Either ask for those endpoints, or plan to use SSH from inside the network."
  else
    ok "ssm, ssmmessages and ec2messages endpoints are present."
  fi
fi

# --------------------------------------------------------------------------
# 4. The hosted zone
# --------------------------------------------------------------------------
echo; log "4. Hosted zone"
if [ -z "$HOSTED_ZONE_ID" ]; then
  WANT="${HOSTED_ZONE_NAME%.}."
  HOSTED_ZONE_ID="$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${WANT}'].Id" --output text 2>/dev/null | head -1 | sed 's|/hostedzone/||')"
fi
if [ -z "$HOSTED_ZONE_ID" ]; then
  fail "Could not find a hosted zone for '${HOSTED_ZONE_NAME}'. Set HOSTED_ZONE_ID directly."
else
  Z="$(aws route53 get-hosted-zone --id "$HOSTED_ZONE_ID" --output json 2>/dev/null)"
  if [ -z "$Z" ]; then
    fail "Hosted zone $HOSTED_ZONE_ID not readable. Check the id and your permissions."
  else
    ZNAME="$(echo "$Z" | jq -r '.HostedZone.Name')"
    ZPRIV="$(echo "$Z" | jq -r '.HostedZone.Config.PrivateZone')"
    ZCOUNT="$(echo "$Z" | jq -r '.HostedZone.ResourceRecordSetCount')"
    ok "$HOSTED_ZONE_ID  $ZNAME  private=$ZPRIV  records=$ZCOUNT"

    if [ "$ZPRIV" = "true" ]; then
      ZVPCS="$(echo "$Z" | jq -r '.VPCs[]?.VPCId' | tr '\n' ' ')"
      echo "    associated VPCs: $ZVPCS"
      if echo "$ZVPCS" | grep -qw "$EXISTING_VPC_ID"; then
        ok "This zone is associated with $EXISTING_VPC_ID - names will resolve inside the VPC."
      else
        fail "This PRIVATE zone is NOT associated with $EXISTING_VPC_ID. Nothing in the VPC can resolve it."
      fi
    else
      soft "This is a PUBLIC hosted zone. A record pointing at a private 10.x address will be published"
      soft "to the whole internet. It still resolves correctly for your users, but it tells outsiders"
      soft "your internal addressing. A private zone is the cleaner choice."
    fi

    # Is the name we want actually inside the zone?
    case "${NIFI_DNS_NAME}." in
      *".${ZNAME}") ok "$NIFI_DNS_NAME sits inside $ZNAME" ;;
      "${ZNAME}")   ok "$NIFI_DNS_NAME is the zone apex" ;;
      *) fail "$NIFI_DNS_NAME is not inside $ZNAME. You cannot create that record in this zone." ;;
    esac

    # Would we be overwriting something?
    EXIST="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.']|[0].[Type,ResourceRecords[0].Value]" \
      --output text 2>/dev/null | sed 's/None//g' | xargs)"
    [ -n "$EXIST" ] && soft "A record already exists: ${NIFI_DNS_NAME} -> ${EXIST}. It WILL be overwritten." \
                    || ok "No record for $NIFI_DNS_NAME yet."
  fi
fi

# --------------------------------------------------------------------------
# 5. Can we create the few things we need?
# --------------------------------------------------------------------------
echo; log "5. Permissions"
if "${A[@]}" ec2 create-security-group --dry-run --group-name "probe-$$" \
     --description probe --vpc-id "$EXISTING_VPC_ID" 2>&1 | grep -q "DryRunOperation"; then
  ok "May create security groups"
else
  fail "Cannot create a security group in $EXISTING_VPC_ID (ec2:CreateSecurityGroup)"
fi
if "${A[@]}" ec2 run-instances --dry-run --image-id ami-00000000000000000 \
     --instance-type "$EX_INSTANCE_TYPE" 2>&1 | grep -qE "DryRunOperation|InvalidAMIID"; then
  ok "May launch instances"
else
  soft "Could not confirm ec2:RunInstances. The dry run was inconclusive."
fi
if [ -n "$HOSTED_ZONE_ID" ] && aws route53 list-resource-record-sets \
     --hosted-zone-id "$HOSTED_ZONE_ID" --max-items 1 >/dev/null 2>&1; then
  ok "May read the hosted zone (writing is only proven when we try)"
fi
if [ -n "$EXISTING_INSTANCE_PROFILE" ]; then
  aws iam get-instance-profile --instance-profile-name "$EXISTING_INSTANCE_PROFILE" >/dev/null 2>&1 \
    && ok "Existing instance profile $EXISTING_INSTANCE_PROFILE found - no IAM will be created" \
    || fail "Instance profile $EXISTING_INSTANCE_PROFILE not found."
else
  aws iam get-user >/dev/null 2>&1 || true
  soft "No EXISTING_INSTANCE_PROFILE set, so 02-adopt.sh will try to create a role. If your account"
  soft "does not let you create IAM roles, ask for one and put its profile name in the config."
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo
log "=============================================================="
if [ "$PROBLEMS" -gt 0 ]; then
  printf '  \033[1;31m%s problem(s)\033[0m and %s warning(s). Fix the problems before continuing.\n' "$PROBLEMS" "$WARNINGS"
  exit 1
fi
printf '  \033[1;32mNo blocking problems\033[0m, %s warning(s).\n' "$WARNINGS"
echo
echo "  Launch subnet : $(echo "$USABLE_SUBNETS" | awk '{print $1}')"
echo "  DNS name      : $NIFI_DNS_NAME  (zone $HOSTED_ZONE_ID)"
echo "  Reachable from: $ALLOWED_CIDRS"
echo "  Source mode   : $NIFI_SOURCE_MODE"
echo
log "Next: ./02-adopt.sh"
