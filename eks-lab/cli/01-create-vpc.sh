#!/usr/bin/env bash
# =============================================================================
# 01-create-vpc.sh  —  ONE JOB: create the VPC itself. Nothing else.
#
# A VPC is your own private network inside AWS. Think of it as renting a whole
# floor of a building: nobody else can walk around inside it, and you decide
# where the walls and doors go.
#
# We only create the empty VPC here. Subnets, routing and gateways come next,
# in 02-create-networking.sh. Keeping them separate means you can read one
# small script at a time.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws

banner "Step 1 / Create the VPC"

if [ -n "${VPC_ID:-}" ]; then
  warn "VPC already recorded in state: ${VPC_ID}"
  warn "Delete ${STATE_FILE} or run the destroy scripts to start over."
  exit 0
fi

log "Checking AWS credentials..."
aws sts get-caller-identity --output table || die "AWS credentials are not working"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
save ACCOUNT_ID "$ACCOUNT_ID"
save AWS_REGION "$AWS_REGION"

log "Creating VPC with CIDR ${VPC_CIDR} ..."
# --cidr-block 10.42.0.0/16 gives us ~65,000 private IP addresses to hand out.
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --region "$AWS_REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${LAB_NAME}-vpc},{Key=Lab,Value=${LAB_NAME}}]" \
  --query 'Vpc.VpcId' --output text)
save VPC_ID "$VPC_ID"

# These two settings are MANDATORY for EKS.
#  - dns-support:   lets instances resolve names at all
#  - dns-hostnames: lets AWS give instances DNS names, which EKS needs so that
#                   nodes and the control plane can find each other.
# Forgetting these produces mysterious "node NotReady" failures later.
log "Enabling DNS support and DNS hostnames (required by EKS)..."
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support  --region "$AWS_REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION"
ok "DNS attributes enabled"

echo
log "Done. Verify with:"
echo "  aws ec2 describe-vpcs --vpc-ids ${VPC_ID} --region ${AWS_REGION} --output table"
echo
log "Next: ./02-create-networking.sh"
