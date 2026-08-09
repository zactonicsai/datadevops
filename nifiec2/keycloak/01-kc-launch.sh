#!/usr/bin/env bash
# ==========================================================================
# 01-kc-launch.sh -- Start a Keycloak server next to NiFi.
#
# It lands in the SECOND public subnet (a different Availability Zone from
# NiFi), inside the same VPC that ../scripts/02-network.sh built.
#
#   ./01-kc-launch.sh
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state

A=(aws --region "$AWS_REGION")

# --------------------------------------------------------------------------
# 0. Sanity checks
# --------------------------------------------------------------------------
command -v jq >/dev/null || die "jq is required."
[ -n "${VPC_ID:-}" ]        || die "No VPC in the NiFi state. Run ../scripts/02-network.sh first."
[ -n "${NIFI_PUBLIC_IP:-}" ] || die "NiFi has no public IP yet. Run ../scripts/03-launch.sh first."
[ "${#KC_ADMIN_PASSWORD}" -ge 12 ]     || die "KC_ADMIN_PASSWORD must be 12+ characters."
[ "${#NIFI_ADMIN_PASSWORD}" -ge 12 ]   || die "NIFI_ADMIN_PASSWORD must be 12+ characters."
[ -n "${MY_CIDR:-}" ] || die "MY_CIDR missing. Run ../scripts/01-preflight.sh."

# Generate the shared secret between NiFi and Keycloak if you left it blank.
if [ -z "${KC_CLIENT_SECRET}" ]; then
  KC_CLIENT_SECRET="$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | base64 | tr -d '/+=')"
  ok "Generated a client secret (stored in .kc-state, not in your config file)"
fi
save_state KC_CLIENT_SECRET "$KC_CLIENT_SECRET"

log "NiFi is at ${NIFI_PUBLIC_IP}:${NIFI_HTTPS_PORT} in VPC ${VPC_ID}"

# --------------------------------------------------------------------------
# 1. Pick a subnet - prefer the SECOND public subnet, so Keycloak and NiFi
#    sit in different Availability Zones.
# --------------------------------------------------------------------------
KC_SUBNET_ID="$(echo "${PUBLIC_SUBNET_IDS:-}" | awk '{print $2}')"
[ -n "$KC_SUBNET_ID" ] || KC_SUBNET_ID="${SUBNET_ID:-}"
[ -n "$KC_SUBNET_ID" ] || die "No public subnet found in the NiFi state."
KC_AZ="$("${A[@]}" ec2 describe-subnets --subnet-ids "$KC_SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' --output text)"
save_state KC_SUBNET_ID "$KC_SUBNET_ID"
ok "Keycloak will run in $KC_SUBNET_ID ($KC_AZ)"

# --------------------------------------------------------------------------
# 2. Security group
#    Two different callers need to reach Keycloak on 8443:
#      a) YOUR BROWSER, from the public internet  -> allow MY_CIDR
#      b) THE NiFi SERVER, for the back-channel token exchange
#         -> allow the NiFi security group, which keeps that traffic private
# --------------------------------------------------------------------------
log "Security group ${KC_SG_NAME} ..."
KC_SG_ID="$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${KC_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [ "$KC_SG_ID" = "None" ] || [ -z "$KC_SG_ID" ]; then
  KC_SG_ID="$("${A[@]}" ec2 create-security-group \
    --group-name "$KC_SG_NAME" --description "Keycloak for NiFi SSO" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${KC_SG_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Component,Value=keycloak}]" \
    --query 'GroupId' --output text)"
  ok "Created $KC_SG_ID"
else
  ok "$KC_SG_ID already exists"
fi
save_state KC_SG_ID "$KC_SG_ID"

"${A[@]}" ec2 authorize-security-group-ingress --group-id "$KC_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=${KC_PORT},ToPort=${KC_PORT},IpRanges=[{CidrIp=${MY_CIDR},Description='Keycloak admin console + login page'}]" \
  >/dev/null 2>&1 && ok "Allowed tcp/${KC_PORT} from your IP" || ok "Browser rule already present"

"${A[@]}" ec2 authorize-security-group-ingress --group-id "$KC_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=${KC_PORT},ToPort=${KC_PORT},UserIdGroupPairs=[{GroupId=${NIFI_SG_ID},Description='NiFi back-channel token exchange'}]" \
  >/dev/null 2>&1 && ok "Allowed tcp/${KC_PORT} from the NiFi security group" || ok "NiFi rule already present"

if [ "$ENABLE_SSH" = "true" ]; then
  "${A[@]}" ec2 authorize-security-group-ingress --group-id "$KC_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_CIDR},Description='SSH admin'}]" \
    >/dev/null 2>&1 && ok "Allowed tcp/22 from your IP" || ok "SSH rule already present"
fi

# --------------------------------------------------------------------------
# 3. Render the bootstrap script (realm JSON is embedded inside it)
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
UD="${BUILD_DIR}/kc-user-data.sh"
log "Rendering user-data..."

# Everything is substituted in one Python pass. This used to be `sed -i`,
# which is NOT portable: on macOS/BSD `-i` demands a backup-suffix argument,
# so `sed -i -e ...` swallows the first -e and then treats the rest as
# filenames ("sed: -e: No such file or directory"). Python behaves the same
# on every platform, and it does not care about /, |, & or \ inside the
# passwords and secrets we are inserting.
python3 - "$KC_DIR" "$UD" \
  "$KC_VERSION" "$KC_IMAGE" "$KC_PORT" "$KC_ADMIN_USER" "$KC_ADMIN_PASSWORD" \
  "$NIFI_PUBLIC_IP" "$NIFI_HTTPS_PORT" "$KC_REALM" "$KC_CLIENT_ID" "$KC_CLIENT_SECRET" \
  "$NIFI_ADMIN_USERNAME" "$NIFI_ADMIN_EMAIL" "$NIFI_ADMIN_PASSWORD" <<'PY'
import json, pathlib, shlex, sys

kc_dir, out = sys.argv[1], sys.argv[2]
names = ["KC_VERSION", "KC_IMAGE", "KC_PORT", "KC_ADMIN_USER", "KC_ADMIN_PASSWORD",
         "NIFI_HOST", "NIFI_PORT", "KC_REALM", "KC_CLIENT_ID", "KC_CLIENT_SECRET",
         "NIFI_ADMIN_USERNAME", "NIFI_ADMIN_EMAIL", "NIFI_ADMIN_PASSWORD"]
values = sys.argv[3:]
if len(values) != len(names):
    sys.exit(f"expected {len(names)} values, got {len(values)}")
val = dict(zip(names, values))

# ---- 1. The realm file -------------------------------------------------
# Parse the template as JSON, substitute inside the parsed structure, then
# re-encode. json.dumps does the escaping, so a password containing a quote
# or a backslash produces valid JSON instead of a file Keycloak rejects.
realm_tmpl = json.loads(pathlib.Path(kc_dir, "templates", "realm-nifi.json.tmpl").read_text())

def substitute(node):
    if isinstance(node, str):
        for name, value in val.items():
            node = node.replace(f"__{name}__", value)
        return node
    if isinstance(node, list):
        return [substitute(item) for item in node]
    if isinstance(node, dict):
        return {key: substitute(item) for key, item in node.items()}
    return node

realm_json = json.dumps(substitute(realm_tmpl), indent=2)

# ---- 2. The bootstrap script -------------------------------------------
# Shell values are inserted with shlex.quote, so quotes, backslashes, $ and
# backticks in a password cannot break (or be executed by) the script.
text = pathlib.Path(kc_dir, "kc-user-data.sh.tmpl").read_text()
text = text.replace("__REALM_JSON__", realm_json)
for name, value in val.items():
    text = text.replace(f"__{name}__", shlex.quote(value))

pathlib.Path(out).write_text(text)

# ---- 3. Prove nothing was missed ---------------------------------------
leftover = sorted({word.strip('",') for word in text.split()
                   if word.strip('",').startswith("__")
                   and word.strip('",').endswith("__")} - {"__LIKE_THIS__"})
if leftover:
    sys.exit("placeholders left unreplaced: " + ", ".join(leftover))
json.loads(realm_json)   # belt and braces
print(f"rendered {len(text)} bytes, realm file {len(realm_json)} bytes")
PY

chmod 600 "$UD"           # it contains two passwords and the client secret
bash -n "$UD" || die "Rendered user-data has a syntax error."
ok "Wrote $UD ($(wc -c < "$UD") bytes; EC2 limit is 16384)"

# --------------------------------------------------------------------------
# 4. Launch
# --------------------------------------------------------------------------
AMI_ID="$("${A[@]}" ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)"
ok "AMI $AMI_ID"

KEY_ARG=()
[ "$ENABLE_SSH" = "true" ] && [ -n "${KEY_NAME:-}" ] && KEY_ARG=(--key-name "$KEY_NAME")

log "Launching ${KC_INSTANCE_TYPE} ..."
KC_INSTANCE_ID="$("${A[@]}" ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$KC_INSTANCE_TYPE" \
  "${KEY_ARG[@]}" \
  --subnet-id "$KC_SUBNET_ID" \
  --security-group-ids "$KC_SG_ID" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --associate-public-ip-address \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${KC_ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true,\"Encrypted\":true}}]" \
  --user-data "file://${UD}" \
  --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${KC_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Component,Value=keycloak}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=${KC_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Component,Value=keycloak}]" \
  --query 'Instances[0].InstanceId' --output text)"
save_state KC_INSTANCE_ID "$KC_INSTANCE_ID"
ok "Instance $KC_INSTANCE_ID requested"

"${A[@]}" ec2 wait instance-running --instance-ids "$KC_INSTANCE_ID"

if [ "$KC_ALLOCATE_EIP" = "true" ]; then
  KC_ALLOC_ID="$("${A[@]}" ec2 allocate-address --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${KC_NAME}},{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Component,Value=keycloak}]" \
    --query 'AllocationId' --output text)"
  "${A[@]}" ec2 associate-address --instance-id "$KC_INSTANCE_ID" --allocation-id "$KC_ALLOC_ID" >/dev/null
  save_state KC_ALLOC_ID "$KC_ALLOC_ID"
  ok "Elastic IP attached"
fi

KC_PUBLIC_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$KC_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
KC_PRIVATE_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$KC_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
KC_HOST="${KC_PUBLIC_IP}.nip.io"

save_state KC_PUBLIC_IP  "$KC_PUBLIC_IP"
save_state KC_PRIVATE_IP "$KC_PRIVATE_IP"
save_state KC_HOST       "$KC_HOST"
save_state KC_ADMIN_USER "$KC_ADMIN_USER"
save_state KC_REALM      "$KC_REALM"
save_state KC_CLIENT_ID  "$KC_CLIENT_ID"
save_state NIFI_ADMIN_EMAIL "$NIFI_ADMIN_EMAIL"

log "Waiting for EC2 status checks..."
"${A[@]}" ec2 wait instance-status-ok --instance-ids "$KC_INSTANCE_ID"

cat <<EOF

  Keycloak instance is up. Docker is now pulling the image and importing the
  realm; that usually takes 3-5 minutes.

    Hostname       ${KC_HOST}      (nip.io resolves this to ${KC_PUBLIC_IP})
    Private IP     ${KC_PRIVATE_IP}   (how NiFi will reach it)
    Admin console  https://${KC_HOST}:${KC_PORT}/admin/
    Admin login    ${KC_ADMIN_USER} / (KC_ADMIN_PASSWORD from 00-kc-config.sh)

  Next:  ./02-kc-verify.sh --follow

EOF
