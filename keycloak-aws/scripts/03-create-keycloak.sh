#!/usr/bin/env bash
###############################################################################
# 03-create-keycloak.sh
#
# CLI equivalent of terraform/03-keycloak.tf.
# Launches an EC2 instance, gives it the IAM role from script 01, attaches an
# Elastic IP, and bootstraps Keycloak 26.7.0 pointed at the RDS database.
#
# Run 01 and 02 first.
# Usage:  ./03-create-keycloak.sh
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/keycloak-state.env"

[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run 01-create-network.sh first."; exit 1; }
# shellcheck source=/dev/null
source "$STATE_FILE"

[[ -n "${DB_ENDPOINT:-}" ]] || { echo "ERROR: no DB_ENDPOINT in state. Run 02-create-database.sh first."; exit 1; }

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-26.7.0}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.small}"
KC_ADMIN_USER="${KC_ADMIN_USER:-kcadmin}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-20}"
SSH_KEY_NAME="${SSH_KEY_NAME:-}"   # empty = no SSH key, use SSM instead

KC_SECRET_NAME="${PROJECT}/db-keycloak-admin-${SUFFIX}"

step() { echo ""; echo "=========================================================="; echo ">>> $*"; echo "=========================================================="; }
info() { echo "    $*"; }
save() { echo "export $1='$2'" >> "$STATE_FILE"; info "saved $1=$2"; }

# ---------------------------------------------------------------------------
# 1. Find the newest Amazon Linux 2023 ARM image
# ---------------------------------------------------------------------------
step "1/6  Looking up the latest Amazon Linux 2023 (ARM64) AMI"
# Never hard-code an AMI ID. They differ per region and go stale within weeks,
# meaning you'd launch an unpatched OS. AWS publishes the current one in SSM
# Parameter Store, so we just ask.

AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64" \
  --query 'Parameter.Value' --output text)
info "AMI: $AMI_ID"
save AMI_ID "$AMI_ID"

# ---------------------------------------------------------------------------
# 2. Allocate an Elastic IP
# ---------------------------------------------------------------------------
step "2/6  Allocating an Elastic IP"
# A regular public IP changes every time the instance stops and starts.
# An Elastic IP is yours to keep, so bookmarks and DNS entries keep working.
# We allocate it BEFORE launching because the bootstrap script needs to bake
# the address into Keycloak's hostname setting and TLS certificate.

EIP_ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-keycloak-eip},{Key=Project,Value=${PROJECT}}]" \
  --query 'AllocationId' --output text)
save EIP_ALLOC_ID "$EIP_ALLOC_ID"

PUBLIC_IP=$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" \
  --query 'Addresses[0].PublicIp' --output text)
save PUBLIC_IP "$PUBLIC_IP"
info "Reserved public IP: $PUBLIC_IP"

# ---------------------------------------------------------------------------
# 3. Generate and store the Keycloak admin password
# ---------------------------------------------------------------------------
step "3/6  Creating the Keycloak admin credentials"

KC_ADMIN_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!#$%&*_+=-' </dev/urandom | head -c 24)

KC_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "$KC_SECRET_NAME" \
  --description "Keycloak bootstrap admin credentials" \
  --secret-string "$(jq -n --arg u "$KC_ADMIN_USER" --arg p "$KC_ADMIN_PASS" '{username:$u,password:$p}')" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'ARN' --output text)

save KC_SECRET_NAME "$KC_SECRET_NAME"
save KC_SECRET_ARN "$KC_SECRET_ARN"
unset KC_ADMIN_PASS
info "Admin password stored in Secrets Manager (never printed here)"

# ---------------------------------------------------------------------------
# 4. Write the bootstrap script
# ---------------------------------------------------------------------------
step "4/6  Building the user-data bootstrap script"
# user-data is a script AWS runs as root the first time the instance boots.
# Notice it contains NO passwords: it fetches them from Secrets Manager using
# the IAM role. That way nothing sensitive is stored in EC2 metadata, which
# any process on the box can read.

USER_DATA_FILE=$(mktemp)
cat > "$USER_DATA_FILE" <<BOOTSTRAP
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/keycloak-bootstrap.log | logger -t keycloak-bootstrap) 2>&1

echo "=== [1/8] Updating OS and installing Java 21 ==="
dnf update -y
dnf install -y java-21-amazon-corretto-headless jq unzip tar gzip awscli

echo "=== [2/8] Creating the keycloak service user ==="
useradd --system --shell /sbin/nologin --home-dir /opt/keycloak keycloak || true

echo "=== [3/8] Downloading Keycloak ${KEYCLOAK_VERSION} ==="
cd /opt
curl -fsSL -o keycloak.tar.gz \\
  "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz"
tar -xzf keycloak.tar.gz
rm -f keycloak.tar.gz
rm -rf /opt/keycloak
mv "keycloak-${KEYCLOAK_VERSION}" /opt/keycloak

echo "=== [4/8] Reading secrets via the IAM instance role ==="
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION}"

DB_SECRET=\$(aws secretsmanager get-secret-value --secret-id "${DB_SECRET_NAME}" --query SecretString --output text)
DB_USER=\$(echo "\$DB_SECRET" | jq -r .username)
DB_PASS=\$(echo "\$DB_SECRET" | jq -r .password)

KC_SECRET=\$(aws secretsmanager get-secret-value --secret-id "${KC_SECRET_NAME}" --query SecretString --output text)
KC_ADMIN_USER=\$(echo "\$KC_SECRET" | jq -r .username)
KC_ADMIN_PASS=\$(echo "\$KC_SECRET" | jq -r .password)

echo "=== [5/8] Downloading the RDS certificate bundle ==="
curl -fsSL -o /opt/keycloak/conf/rds-ca.pem \\
  "https://truststore.pki.rds.amazonaws.com/${AWS_DEFAULT_REGION}/${AWS_DEFAULT_REGION}-bundle.pem"
chmod 644 /opt/keycloak/conf/rds-ca.pem

echo "=== [6/8] Generating a self-signed TLS certificate ==="
keytool -genkeypair -storepass changeit -keyalg RSA -keysize 2048 \\
  -dname "CN=${PUBLIC_IP}" -alias server -ext "SAN=IP:${PUBLIC_IP}" \\
  -keystore /opt/keycloak/conf/server.keystore -validity 3650

echo "=== [7/8] Writing keycloak.conf ==="
cat > /opt/keycloak/conf/keycloak.conf <<KCCONF
db=postgres
db-url=jdbc:postgresql://${DB_ENDPOINT}:5432/${DB_NAME}?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem
db-username=\$DB_USER
db-password=\$DB_PASS
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20

http-enabled=true
http-port=8080
https-port=8443
https-key-store-file=/opt/keycloak/conf/server.keystore
https-key-store-password=changeit

hostname=https://${PUBLIC_IP}:8443
hostname-strict=false

health-enabled=true
metrics-enabled=true

log=console,file
log-file=/var/log/keycloak/keycloak.log
log-level=INFO
KCCONF

chmod 600 /opt/keycloak/conf/keycloak.conf
mkdir -p /var/log/keycloak
chown -R keycloak:keycloak /opt/keycloak /var/log/keycloak

echo "=== [8/8] Building and starting Keycloak ==="
sudo -u keycloak /opt/keycloak/bin/kc.sh build --db=postgres

cat > /etc/systemd/system/keycloak.service <<UNIT
[Unit]
Description=Keycloak Identity and Access Management
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=keycloak
Group=keycloak
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=\$KC_ADMIN_USER
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=\$KC_ADMIN_PASS
Environment=JAVA_OPTS_APPEND=-Xms512m -Xmx1024m
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=15
LimitNOFILE=102642
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now keycloak
echo "=== Bootstrap complete ==="
BOOTSTRAP

info "Bootstrap script written ($(wc -l < "$USER_DATA_FILE") lines)"

# ---------------------------------------------------------------------------
# 5. Launch the instance
# ---------------------------------------------------------------------------
step "5/6  Launching the EC2 instance"
# Two hardening choices worth noticing:
#   HttpTokens=required  -> forces IMDSv2. This blocks the classic attack
#                           where a tricked web app is used to steal the
#                           instance's IAM credentials.
#   Encrypted=true       -> the root disk is encrypted at rest. Free.

KEY_ARG=()
[[ -n "$SSH_KEY_NAME" ]] && KEY_ARG=(--key-name "$SSH_KEY_NAME")

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$PUBLIC_SUBNET_ID" \
  --security-group-ids "$KEYCLOAK_SG_ID" \
  --iam-instance-profile "Name=${PROFILE_NAME}" \
  --user-data "file://${USER_DATA_FILE}" \
  --metadata-options "HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=1" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"Encrypted\":true,\"DeleteOnTermination\":true}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}-keycloak},{Key=Project,Value=${PROJECT}}]" \
  "${KEY_ARG[@]}" \
  --query 'Instances[0].InstanceId' --output text)

save INSTANCE_ID "$INSTANCE_ID"
rm -f "$USER_DATA_FILE"

info "Instance $INSTANCE_ID launching. Waiting for 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
info "Instance is running"

# ---------------------------------------------------------------------------
# 6. Attach the Elastic IP
# ---------------------------------------------------------------------------
step "6/6  Attaching the Elastic IP"

aws ec2 associate-address \
  --instance-id "$INSTANCE_ID" --allocation-id "$EIP_ALLOC_ID" >/dev/null
info "$PUBLIC_IP now points at $INSTANCE_ID"

step "KEYCLOAK LAUNCHED"
cat <<SUMMARY

  Keycloak needs another 3-6 minutes to download Java, unpack itself and
  run its first database migration. Be patient before opening the URL.

  Admin console ....... https://${PUBLIC_IP}:8443/admin
  Reachable only from . ${MY_IP_CIDR}
  Instance ............ $INSTANCE_ID  ($INSTANCE_TYPE)
  Database ............ $DB_ENDPOINT

  Get your admin password:
    aws secretsmanager get-secret-value --secret-id "${KC_SECRET_NAME}" \\
      --query SecretString --output text | jq .

  Open a shell WITHOUT SSH:
    aws ssm start-session --target ${INSTANCE_ID}

  Watch the bootstrap progress:
    aws ssm start-session --target ${INSTANCE_ID} \\
      --document-name AWS-StartInteractiveCommand \\
      --parameters 'command="tail -f /var/log/keycloak-bootstrap.log"'

  Your browser WILL warn about the certificate. That is expected: it is
  self-signed. Click "Advanced" then "Proceed".

  Estimated cost of THIS script:
    t4g.small on-demand ......... ~\$12.26/month
    20 GB gp3 root volume ....... ~\$1.60/month
    Public IPv4 address ......... ~\$3.60/month
    Secrets Manager (1 secret) .. ~\$0.40/month
    ----------------------------------------------
    Subtotal .................... ~\$17.86/month

  Running total for the whole stack: ~\$33/month

SUMMARY
