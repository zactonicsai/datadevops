#!/usr/bin/env bash
###############################################################################
# 91-destroy-network.sh
#
# Backup teardown for the network layer (what 01-create-network.sh built).
# Run this LAST - AWS refuses to delete a VPC while anything still lives in it.
#
# Teardown order (strict, because of dependencies):
#   IAM profile/role/policy
#   -> DB subnet group
#   -> security group RULES (break the circular reference)
#   -> security groups
#   -> route table associations -> route tables
#   -> subnets
#   -> internet gateway
#   -> VPC
#
# Usage:  ./91-destroy-network.sh
#         FORCE=yes ./91-destroy-network.sh
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/keycloak-state.env"

step() { echo ""; echo "=========================================================="; echo ">>> $*"; echo "=========================================================="; }
info() { echo "    $*"; }
warn() { echo "    [!] $*"; }

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  warn "No state file. Using tag-based discovery."
  export PROJECT="${PROJECT:-keycloak-demo}"
  export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
fi

step "DESTROY: Network and IAM layer"
echo "  This will PERMANENTLY delete:"
echo "    - VPC ............... ${VPC_ID:-<discover>}"
echo "    - All subnets, route tables, security groups inside it"
echo "    - IAM role .......... ${ROLE_NAME:-<discover>}"
echo "    - IAM policy ........ ${POLICY_NAME:-<discover>}"
echo ""
echo "  Run 93- and 92- FIRST. This will fail if the EC2 instance or RDS"
echo "  database still exist."
echo ""

if [[ "${FORCE:-no}" != "yes" ]]; then
  read -r -p "  Type 'destroy' to continue: " CONFIRM
  [[ "$CONFIRM" == "destroy" ]] || { echo "  Cancelled."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. IAM instance profile
# ---------------------------------------------------------------------------
step "1/8  Deleting the IAM instance profile"
# You must first remove the role FROM the profile, then delete the profile.
# Deleting a profile that still holds a role fails.

if [[ -n "${PROFILE_NAME:-}" ]]; then
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" --role-name "${ROLE_NAME:-}" 2>/dev/null \
    && info "Removed role from profile"

  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null \
    && info "Deleted $PROFILE_NAME" \
    || warn "Could not delete $PROFILE_NAME"
else
  warn "No instance profile in state"
fi

# ---------------------------------------------------------------------------
# 2. IAM role and policy
# ---------------------------------------------------------------------------
step "2/8  Deleting the IAM role and customer-managed policy"
# A role cannot be deleted while policies are attached. Detach every attached
# policy first, then delete the role, then delete our own policy.

if [[ -n "${ROLE_NAME:-}" ]]; then
  for ARN in $(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$ARN" 2>/dev/null \
      && info "Detached $ARN"
  done

  # Inline policies too, in case any were added by hand
  for P in $(aws iam list-role-policies --role-name "$ROLE_NAME" \
      --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$P" 2>/dev/null
  done

  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null \
    && info "Deleted role $ROLE_NAME" \
    || warn "Could not delete role $ROLE_NAME"
fi

if [[ -n "${POLICY_ARN:-}" ]]; then
  # Delete all non-default versions first, or the delete is rejected.
  for V in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
      --query 'Versions[?!IsDefaultVersion].VersionId' --output text 2>/dev/null); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$V" 2>/dev/null
  done

  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null \
    && info "Deleted policy $POLICY_ARN" \
    || warn "Could not delete policy $POLICY_ARN"
fi

# ---------------------------------------------------------------------------
# 3. RDS subnet group
# ---------------------------------------------------------------------------
step "3/8  Deleting the RDS DB subnet group"
# This holds a reference to the subnets, so it must go before they do.

if [[ -z "${DB_SUBNET_GROUP:-}" ]]; then
  DB_SUBNET_GROUP=$(aws rds describe-db-subnet-groups \
    --query "DBSubnetGroups[?starts_with(DBSubnetGroupName, '${PROJECT}-db-subnets')].DBSubnetGroupName | [0]" \
    --output text 2>/dev/null)
  [[ "$DB_SUBNET_GROUP" == "None" ]] && DB_SUBNET_GROUP=""
fi

if [[ -n "$DB_SUBNET_GROUP" ]]; then
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null \
    && info "Deleted $DB_SUBNET_GROUP" \
    || warn "Could not delete $DB_SUBNET_GROUP (is the database really gone?)"
fi

# ---------------------------------------------------------------------------
# 4. Find the VPC if we don't have it
# ---------------------------------------------------------------------------
step "4/8  Locating the VPC"

if [[ -z "${VPC_ID:-}" ]]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Project,Values=${PROJECT}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
  [[ "$VPC_ID" == "None" ]] && VPC_ID=""
fi

if [[ -z "$VPC_ID" ]]; then
  warn "No VPC found. Nothing left to clean up."
  step "NETWORK LAYER ALREADY CLEAN"
  exit 0
fi
info "VPC: $VPC_ID"

# ---------------------------------------------------------------------------
# 5. Security groups
# ---------------------------------------------------------------------------
step "5/8  Deleting security groups"
# IMPORTANT: our two groups reference each other (the DB group allows traffic
# from the Keycloak group). AWS will not delete a group that another group
# still points at. So: strip every RULE from every group first, THEN delete
# the groups. This breaks the circular dependency.

SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null)

for SG in $SG_IDS; do
  info "Stripping rules from $SG"

  INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" \
    --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
  if [[ "$INGRESS" != "[]" && -n "$INGRESS" ]]; then
    aws ec2 revoke-security-group-ingress --group-id "$SG" \
      --ip-permissions "$INGRESS" >/dev/null 2>&1
  fi

  EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" \
    --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)
  if [[ "$EGRESS" != "[]" && -n "$EGRESS" ]]; then
    aws ec2 revoke-security-group-egress --group-id "$SG" \
      --ip-permissions "$EGRESS" >/dev/null 2>&1
  fi
done

for SG in $SG_IDS; do
  # Retry: network interfaces from a just-terminated instance can linger.
  for ATTEMPT in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$SG" 2>/dev/null; then
      info "Deleted $SG"
      break
    fi
    warn "Attempt $ATTEMPT on $SG failed (ENI may still be detaching), retry in 15s"
    sleep 15
  done
done

# ---------------------------------------------------------------------------
# 6. Subnets
# ---------------------------------------------------------------------------
step "6/8  Deleting subnets"

for SUBNET in $(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
  for ATTEMPT in 1 2 3; do
    if aws ec2 delete-subnet --subnet-id "$SUBNET" 2>/dev/null; then
      info "Deleted $SUBNET"
      break
    fi
    warn "Attempt $ATTEMPT on $SUBNET failed, retry in 15s"
    sleep 15
  done
done

# ---------------------------------------------------------------------------
# 7. Route tables and internet gateway
# ---------------------------------------------------------------------------
step "7/8  Deleting route tables and the internet gateway"
# The VPC's MAIN route table cannot be deleted on its own - it disappears
# with the VPC. We skip it and delete only the ones we created.

for RT in $(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'RouteTables[?!(Associations[?Main==`true`])].RouteTableId' \
    --output text 2>/dev/null); do

  # Any leftover associations must be removed first
  for ASSOC in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
      --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
      --output text 2>/dev/null); do
    aws ec2 disassociate-route-table --association-id "$ASSOC" 2>/dev/null
  done

  aws ec2 delete-route-table --route-table-id "$RT" 2>/dev/null \
    && info "Deleted $RT" \
    || warn "Could not delete $RT"
done

for IGW in $(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC_ID" 2>/dev/null \
    && info "Detached $IGW"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" 2>/dev/null \
    && info "Deleted $IGW" \
    || warn "Could not delete $IGW"
done

# ---------------------------------------------------------------------------
# 8. The VPC itself
# ---------------------------------------------------------------------------
step "8/8  Deleting the VPC"

for ATTEMPT in 1 2 3 4 5; do
  if aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null; then
    info "Deleted $VPC_ID"
    break
  fi
  warn "Attempt $ATTEMPT failed. Something is still inside the VPC."
  warn "Checking for leftover network interfaces..."
  aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Status:Status}' \
    --output table 2>/dev/null
  sleep 20
done

# ---------------------------------------------------------------------------
# Tidy up the state file
# ---------------------------------------------------------------------------
if [[ -f "$STATE_FILE" ]]; then
  mv "$STATE_FILE" "${STATE_FILE}.destroyed-$(date +%Y%m%d%H%M%S)"
  info "State file archived"
fi

step "TEARDOWN COMPLETE"
cat <<'SUMMARY'

  Everything should now be gone. Verify with:

    aws ec2 describe-instances \
      --filters "Name=tag:Project,Values=keycloak-demo" \
                "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].InstanceId'

    aws rds describe-db-instances \
      --query 'DBInstances[].DBInstanceIdentifier'

    aws ec2 describe-addresses --query 'Addresses[].PublicIp'

  All three should return empty. If 'describe-addresses' shows an IP you no
  longer want, release it - idle Elastic IPs cost about $3.60/month.

  Final check: look at Billing > Cost Explorer tomorrow. Charges lag by
  about 24 hours, so a clean teardown today shows up as $0 tomorrow.

SUMMARY
