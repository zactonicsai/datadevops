#!/usr/bin/env bash
# =============================================================================
# 02-create-networking.sh  —  ONE JOB: subnets, gateways and routing.
#
# WHAT WE BUILD AND WHY
#
#   Internet Gateway (IGW)   the front door of the VPC
#   Public subnets  x2       where the load balancer lives; has a route to IGW
#   Private subnets x2       where the worker nodes live; NO direct route in
#   NAT Gateway              lets private subnets call OUT (to pull images)
#                            without letting the internet call IN
#   Route tables             the signposts that say "traffic for X goes this way"
#
# "x2" means two Availability Zones = two physically separate data centres.
# If one has a problem, the other keeps running. EKS requires at least two.
#
# COST NOTE: the NAT gateway is the most expensive thing in this lab
# (~$0.045/hour ≈ $33/month, plus data charges). Set USE_NAT=false in
# 00-config.sh to skip it — nodes then sit in the public subnets instead.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws
require VPC_ID

banner "Step 2 / Networking: subnets, gateways, routes"

R=(--region "$AWS_REGION")

# ---------------------------------------------------------------------------
# 1. Internet Gateway — the VPC's connection to the internet
# ---------------------------------------------------------------------------
if [ -z "${IGW_ID:-}" ]; then
  log "Creating internet gateway..."
  IGW_ID=$(aws ec2 create-internet-gateway "${R[@]}" \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${LAB_NAME}-igw},{Key=Lab,Value=${LAB_NAME}}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway "${R[@]}" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  save IGW_ID "$IGW_ID"
fi

# ---------------------------------------------------------------------------
# 2. Subnets
#
# A subnet is a slice of the VPC that lives in exactly one Availability Zone.
# The kubernetes.io/role tags are how the AWS Load Balancer Controller finds
# the right subnets later. Without them, Ingress objects never get an address.
# ---------------------------------------------------------------------------
make_subnet() {   # name cidr az  role-tag
  local name="$1" cidr="$2" az="$3" role="$4"
  aws ec2 create-subnet "${R[@]}" \
    --vpc-id "$VPC_ID" --cidr-block "$cidr" --availability-zone "$az" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Lab,Value=${LAB_NAME}},{Key=${role},Value=1},{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared}]" \
    --query 'Subnet.SubnetId' --output text
}

if [ -z "${SUBNET_PUB_A:-}" ]; then
  log "Creating public subnets (for the load balancer)..."
  save SUBNET_PUB_A "$(make_subnet "${LAB_NAME}-public-a" "$PUBLIC_CIDR_A" "$AZ_A" "kubernetes.io/role/elb")"
  save SUBNET_PUB_B "$(make_subnet "${LAB_NAME}-public-b" "$PUBLIC_CIDR_B" "$AZ_B" "kubernetes.io/role/elb")"

  log "Creating private subnets (for the worker nodes)..."
  save SUBNET_PRIV_A "$(make_subnet "${LAB_NAME}-private-a" "$PRIVATE_CIDR_A" "$AZ_A" "kubernetes.io/role/internal-elb")"
  save SUBNET_PRIV_B "$(make_subnet "${LAB_NAME}-private-b" "$PRIVATE_CIDR_B" "$AZ_B" "kubernetes.io/role/internal-elb")"
fi

# Public subnets auto-assign a public IP to anything launched in them.
for s in "$SUBNET_PUB_A" "$SUBNET_PUB_B"; do
  aws ec2 modify-subnet-attribute "${R[@]}" --subnet-id "$s" --map-public-ip-on-launch
done
ok "Public subnets will auto-assign public IPs"

# ---------------------------------------------------------------------------
# 3. Public route table: everything not local goes out the internet gateway
# ---------------------------------------------------------------------------
if [ -z "${RTB_PUBLIC:-}" ]; then
  log "Creating public route table..."
  RTB_PUBLIC=$(aws ec2 create-route-table "${R[@]}" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-rtb-public},{Key=Lab,Value=${LAB_NAME}}]" \
    --query 'RouteTable.RouteTableId' --output text)
  save RTB_PUBLIC "$RTB_PUBLIC"
  # 0.0.0.0/0 means "any address anywhere"
  aws ec2 create-route "${R[@]}" --route-table-id "$RTB_PUBLIC" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table "${R[@]}" --route-table-id "$RTB_PUBLIC" --subnet-id "$SUBNET_PUB_A" >/dev/null
  aws ec2 associate-route-table "${R[@]}" --route-table-id "$RTB_PUBLIC" --subnet-id "$SUBNET_PUB_B" >/dev/null
  ok "Public subnets can reach the internet"
fi

# ---------------------------------------------------------------------------
# 4. NAT gateway + private route table  (optional, costs money)
#
# A NAT gateway is a one-way door: things inside can start a conversation with
# the outside world, but the outside world cannot start one with them. Nodes
# need it to download container images.
#
# We use ONE NAT gateway shared by both AZs. In production you would use one
# per AZ so an AZ failure cannot take out the other AZ's internet access —
# but that doubles the cost, and this is a lab.
# ---------------------------------------------------------------------------
if [ "$USE_NAT" = "true" ]; then
  if [ -z "${NAT_GW_ID:-}" ]; then
    log "Allocating an Elastic IP for the NAT gateway..."
    EIP_ALLOC=$(aws ec2 allocate-address "${R[@]}" --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${LAB_NAME}-nat-eip},{Key=Lab,Value=${LAB_NAME}}]" \
      --query 'AllocationId' --output text)
    save EIP_ALLOC "$EIP_ALLOC"

    log "Creating NAT gateway (this takes ~2 minutes)..."
    NAT_GW_ID=$(aws ec2 create-nat-gateway "${R[@]}" \
      --subnet-id "$SUBNET_PUB_A" --allocation-id "$EIP_ALLOC" \
      --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${LAB_NAME}-nat},{Key=Lab,Value=${LAB_NAME}}]" \
      --query 'NatGateway.NatGatewayId' --output text)
    save NAT_GW_ID "$NAT_GW_ID"
    aws ec2 wait nat-gateway-available "${R[@]}" --nat-gateway-ids "$NAT_GW_ID"
    ok "NAT gateway is available"
  fi

  if [ -z "${RTB_PRIVATE:-}" ]; then
    log "Creating private route table pointing at the NAT gateway..."
    RTB_PRIVATE=$(aws ec2 create-route-table "${R[@]}" --vpc-id "$VPC_ID" \
      --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-rtb-private},{Key=Lab,Value=${LAB_NAME}}]" \
      --query 'RouteTable.RouteTableId' --output text)
    save RTB_PRIVATE "$RTB_PRIVATE"
    aws ec2 create-route "${R[@]}" --route-table-id "$RTB_PRIVATE" \
      --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW_ID" >/dev/null
    aws ec2 associate-route-table "${R[@]}" --route-table-id "$RTB_PRIVATE" --subnet-id "$SUBNET_PRIV_A" >/dev/null
    aws ec2 associate-route-table "${R[@]}" --route-table-id "$RTB_PRIVATE" --subnet-id "$SUBNET_PRIV_B" >/dev/null
  fi
  # Nodes will go in the private subnets
  save NODE_SUBNETS "${SUBNET_PRIV_A},${SUBNET_PRIV_B}"
else
  warn "USE_NAT=false — skipping the NAT gateway to save money."
  warn "Worker nodes will be placed in the PUBLIC subnets with public IPs."
  warn "They are still protected by security groups, but this is lab-only."
  save NODE_SUBNETS "${SUBNET_PUB_A},${SUBNET_PUB_B}"
fi

# ---------------------------------------------------------------------------
# 5. A free S3 gateway endpoint.
#
# Our NiFi flow writes to S3. Without this, that traffic goes out through the
# NAT gateway and you pay per gigabyte. A gateway endpoint is FREE and keeps
# S3 traffic on the AWS network. Always add it — there is no downside.
# ---------------------------------------------------------------------------
if [ -z "${VPCE_S3:-}" ]; then
  RTBS="$RTB_PUBLIC"
  [ -n "${RTB_PRIVATE:-}" ] && RTBS="$RTB_PUBLIC $RTB_PRIVATE"
  log "Creating the (free) S3 gateway VPC endpoint..."
  # shellcheck disable=SC2086
  VPCE_S3=$(aws ec2 create-vpc-endpoint "${R[@]}" \
    --vpc-id "$VPC_ID" --service-name "com.amazonaws.${AWS_REGION}.s3" \
    --vpc-endpoint-type Gateway --route-table-ids $RTBS \
    --query 'VpcEndpoint.VpcEndpointId' --output text)
  save VPCE_S3 "$VPCE_S3"
fi

echo
log "Networking summary:"
aws ec2 describe-subnets "${R[@]}" --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,Id:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' \
  --output table
echo
log "Next: ./03-create-iam.sh"
