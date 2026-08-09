#!/usr/bin/env bash
# ==========================================================================
# 03-launch.sh -- Render the bootstrap script, find the newest Amazon Linux
# 2023 image, and start the EC2 instance that will run NiFi.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

[ -n "${SG_ID:-}" ] && [ -n "${SUBNET_ID:-}" ] || die "Missing state. Run ./02-network.sh first."

# --------------------------------------------------------------------------
# 1. Render user-data from the template
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
UD="${BUILD_DIR}/user-data.sh"
log "Rendering user-data..."
sed -e "s|__NIFI_VERSION__|${NIFI_VERSION}|g" \
    -e "s|__NIFI_MIRROR__|${NIFI_MIRROR}|g" \
    -e "s|__JAVA_PKG__|${JAVA_PKG}|g" \
    -e "s|__NIFI_HEAP__|${NIFI_HEAP}|g" \
    -e "s|__NIFI_HTTPS_PORT__|${NIFI_HTTPS_PORT}|g" \
    -e "s|__NIFI_USERNAME__|${NIFI_USERNAME}|g" \
    -e "s|__NIFI_PASSWORD__|${NIFI_PASSWORD}|g" \
    "${SCRIPT_DIR}/user-data.sh.tmpl" > "$UD"
chmod 600 "$UD"   # it contains your password
bash -n "$UD" || die "Rendered user-data has a syntax error."
ok "Wrote $UD ($(wc -c < "$UD") bytes; the EC2 limit is 16384)"

# --------------------------------------------------------------------------
# 2. Find the AMI (machine image) via the AWS-managed SSM parameter,
#    so you always get the newest patched Amazon Linux 2023.
# --------------------------------------------------------------------------
case "$INSTANCE_TYPE" in
  *g.*|*gd.*|*gn.*) ARCH="arm64" ;;   # Graviton families: t4g, m7g, c7gn...
  *)                ARCH="x86_64" ;;
esac
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}"
log "Looking up AMI ($ARCH)..."
AMI_ID="$(aws ssm get-parameters --region "$AWS_REGION" --names "$AMI_PARAM" \
  --query 'Parameters[0].Value' --output text)"
[ "$AMI_ID" != "None" ] || die "Could not resolve AMI from $AMI_PARAM"
ok "AMI $AMI_ID"
save_state AMI_ID "$AMI_ID"

# --------------------------------------------------------------------------
# 3. Launch
# --------------------------------------------------------------------------
KEY_ARG=()
[ "$ENABLE_SSH" = "true" ] && KEY_ARG=(--key-name "$KEY_NAME")

log "Launching $INSTANCE_TYPE ..."
INSTANCE_ID="$(aws ec2 run-instances --region "$AWS_REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  "${KEY_ARG[@]}" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --associate-public-ip-address \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"${VOLUME_TYPE}\",\"DeleteOnTermination\":true,\"Encrypted\":true}}]" \
  --user-data "file://${UD}" \
  --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${PROJECT}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
  --query 'Instances[0].InstanceId' --output text)"
save_state INSTANCE_ID "$INSTANCE_ID"
ok "Instance $INSTANCE_ID requested"

log "Waiting for the instance to be running..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
ok "Running"

# --------------------------------------------------------------------------
# 4. Optional fixed public IP
# --------------------------------------------------------------------------
if [ "$ALLOCATE_EIP" = "true" ]; then
  log "Allocating an Elastic IP..."
  ALLOC_ID="$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
    --query 'AllocationId' --output text)"
  aws ec2 associate-address --region "$AWS_REGION" \
    --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" >/dev/null
  save_state ALLOC_ID "$ALLOC_ID"
  ok "Elastic IP attached ($ALLOC_ID)"
fi

PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
PUBLIC_DNS="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"
save_state PUBLIC_IP "$PUBLIC_IP"
save_state PUBLIC_DNS "$PUBLIC_DNS"

log "Waiting for EC2 status checks (2-3 minutes)..."
aws ec2 wait instance-status-ok --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
ok "Instance healthy at $PUBLIC_IP"

cat <<EOF

  The machine is up, but NiFi is still installing in the background.
  Downloading and unpacking a 1.2 GB archive typically takes 5-10 minutes.

  Watch progress:   ./04-verify.sh --follow
  UI (when ready):  https://${PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi

EOF
