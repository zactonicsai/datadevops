#!/usr/bin/env bash
# ==========================================================================
# 03-launch-private.sh -- Launch NiFi with NO public IP into the existing
# subnet, then point the existing hosted zone at its private address.
#
#   ./03-launch-private.sh
#
# The DNS record is the only change made to the hosted zone. Everything else
# in the zone is untouched.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"
load_state

A=(aws --region "$AWS_REGION")
[ -n "${SUBNET_ID:-}" ] && [ -n "${SG_ID:-}" ] || die "Run ./02-adopt.sh first."
[ -n "${HOSTED_ZONE_ID:-}" ] || die "No hosted zone in state. Run ./02-adopt.sh first."

# --------------------------------------------------------------------------
# 1. Render the bootstrap script
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
UD="${BUILD_DIR}/user-data-private.sh"
log "Rendering user-data for ${NIFI_DNS_NAME} ..."

python3 - "$EX_DIR" "$UD" \
  "$NIFI_VERSION" "$NIFI_MIRROR" "$NIFI_SOURCE_MODE" "$NIFI_S3_PREFIX" "$JAVA_PKG" \
  "$NIFI_HEAP" "$NIFI_HTTPS_PORT" "$NIFI_USERNAME" "$NIFI_PASSWORD" \
  "$NIFI_DNS_NAME" "$GENERATE_CERT_FOR_DNS" <<'PY'
import pathlib, shlex, sys
ex_dir, out = sys.argv[1], sys.argv[2]
names = ["NIFI_VERSION","NIFI_MIRROR","SOURCE_MODE","S3_PREFIX","JAVA_PKG",
         "NIFI_HEAP","NIFI_HTTPS_PORT","NIFI_USERNAME","NIFI_PASSWORD",
         "DNS_NAME","GENERATE_CERT"]
values = sys.argv[3:]
if len(values) != len(names):
    sys.exit(f"expected {len(names)} values, got {len(values)}")
text = pathlib.Path(ex_dir, "user-data-private.sh.tmpl").read_text()
for name, value in zip(names, values):
    text = text.replace(f"__{name}__", shlex.quote(value))
pathlib.Path(out).write_text(text)
left = sorted({w.strip('",') for w in text.split()
               if w.strip('",').startswith("__") and w.strip('",').endswith("__")})
if left:
    sys.exit("placeholders left unreplaced: " + ", ".join(left))
print(f"rendered {len(text)} bytes")
PY

chmod 600 "$UD"
bash -n "$UD" || die "Rendered user-data has a syntax error."
ok "Wrote $UD"

# --------------------------------------------------------------------------
# 2. Launch, with NO public address
# --------------------------------------------------------------------------
AMI_ID="$("${A[@]}" ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
ok "AMI $AMI_ID"

EBS="{\"VolumeSize\":${EX_ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":true"
[ -n "$EBS_KMS_KEY_ID" ] && EBS="${EBS},\"KmsKeyId\":\"${EBS_KMS_KEY_ID}\""
EBS="${EBS}}"

KEY_ARG=()
[ -n "${KEY_NAME:-}" ] && KEY_ARG=(--key-name "$KEY_NAME")

log "Launching ${EX_INSTANCE_TYPE} into ${SUBNET_ID} with no public IP..."
INSTANCE_ID="$("${A[@]}" ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$EX_INSTANCE_TYPE" \
  "${KEY_ARG[@]}" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --no-associate-public-ip-address \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":${EBS}}]" \
  --user-data "file://${UD}" \
  --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${EX_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Mode,Value=existing-network},{Key=DnsName,Value=${NIFI_DNS_NAME}}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${EX_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Mode,Value=existing-network}]" \
  --query 'Instances[0].InstanceId' --output text)"
save_state INSTANCE_ID "$INSTANCE_ID"
ok "Instance $INSTANCE_ID requested"

"${A[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PRIVATE_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
PUBLIC_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
save_state PRIVATE_IP "$PRIVATE_IP"
ok "Private address ${PRIVATE_IP}"
[ "$PUBLIC_IP" != "None" ] && warn "A public IP (${PUBLIC_IP}) was assigned anyway - the subnet forces it. Tell your network team." \
                           || ok "No public IP, as intended"

# --------------------------------------------------------------------------
# 3. The one change we make to the hosted zone
# --------------------------------------------------------------------------
log "Pointing ${NIFI_DNS_NAME} at ${PRIVATE_IP} ..."

# Keep a copy of whatever was there before, so teardown can restore it.
PREV="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.' && Type=='A']|[0]" --output json 2>/dev/null)"
if [ -n "$PREV" ] && [ "$PREV" != "null" ]; then
  mkdir -p "$BUILD_DIR"
  echo "$PREV" > "${BUILD_DIR}/previous-record.json"
  warn "A record already existed and is being replaced. The old value is saved in build/previous-record.json"
  save_state DNS_RECORD_PREEXISTED "true"
else
  save_state DNS_RECORD_PREEXISTED "false"
fi

CHANGE_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Comment\": \"NiFi ${NIFI_VERSION} on ${INSTANCE_ID}\",
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${NIFI_DNS_NAME}\",
        \"Type\": \"A\",
        \"TTL\": ${DNS_TTL},
        \"ResourceRecords\": [{\"Value\": \"${PRIVATE_IP}\"}]
      }
    }]
  }" --query 'ChangeInfo.Id' --output text)"

save_state DNS_RECORD_CREATED "true"
save_state DNS_RECORD_VALUE   "$PRIVATE_IP"
log "  Waiting for the change to propagate..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || sleep 20
ok "${NIFI_DNS_NAME}  A  ${PRIVATE_IP}  (TTL ${DNS_TTL})"

log "Waiting for EC2 status checks..."
"${A[@]}" ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

cat <<EOF

  ┌──────────────────────────────────────────────────────────────┐
  │  NiFi is installing. Allow 5-10 minutes for the download.     │
  ├──────────────────────────────────────────────────────────────┤
  │  URL           https://${NIFI_DNS_NAME}:${NIFI_HTTPS_PORT}/nifi
  │  Resolves to   ${PRIVATE_IP}   (private - no route from the internet)
  │  Reachable by  anyone on ${ALLOWED_CIDRS}
  │  Username      ${NIFI_USERNAME}
  └──────────────────────────────────────────────────────────────┘

  Watch it:   ./04-verify.sh --follow
  Shell:      aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID}

  Not on the corporate network right now? Tunnel to it:
    aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID} \\
      --document-name AWS-StartPortForwardingSession \\
      --parameters '{"portNumber":["${NIFI_HTTPS_PORT}"],"localPortNumber":["${NIFI_HTTPS_PORT}"]}'
    then browse https://localhost:${NIFI_HTTPS_PORT}/nifi

EOF
