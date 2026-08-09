#!/usr/bin/env bash
# ==========================================================================
# 01-preflight.sh -- Check that your laptop has everything needed BEFORE
# we start creating things in AWS. Cheap to run, saves a lot of pain.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"

log "Checking local tools..."

command -v aws  >/dev/null || die "AWS CLI not found. Install AWS CLI v2 first."
command -v jq   >/dev/null || die "jq not found. Install it: 'brew install jq' or 'sudo dnf install jq'."
command -v curl >/dev/null || die "curl not found."

AWS_MAJOR="$(aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9]*\).*#\1#p')"
[ "${AWS_MAJOR:-1}" -ge 2 ] || die "You have AWS CLI v1. Version 2 is required."
ok "aws $(aws --version 2>&1 | awk '{print $1}'), jq $(jq --version)"

log "Checking AWS credentials..."
CALLER="$(aws sts get-caller-identity --output json 2>/dev/null)" \
  || die "AWS credentials are not working. Run 'aws configure' or 'aws sso login'."
ACCOUNT_ID="$(echo "$CALLER" | jq -r .Account)"
ok "Account $ACCOUNT_ID as $(echo "$CALLER" | jq -r .Arn)"
save_state ACCOUNT_ID "$ACCOUNT_ID"

log "Checking region and quota basics..."
aws ec2 describe-availability-zones --region "$AWS_REGION" >/dev/null \
  || die "Cannot talk to EC2 in region $AWS_REGION."
ok "Region $AWS_REGION reachable"

log "Validating config values..."
[ "${#NIFI_PASSWORD}" -ge 12 ] \
  || die "NIFI_PASSWORD must be at least 12 characters. Edit 00-config.sh."
[ "$NIFI_PASSWORD" != "ChangeMe-Str0ngPass!" ] \
  || warn "You are still using the example password. Change it in 00-config.sh."
ok "NiFi $NIFI_VERSION, instance $INSTANCE_TYPE, ${ROOT_VOLUME_GB}GB $VOLUME_TYPE"

log "Verifying the NiFi download URL exists (this is the #1 cause of failures)..."
NIFI_URL="${NIFI_MIRROR}/${NIFI_VERSION}/nifi-${NIFI_VERSION}-bin.zip"
if curl -sfIL --max-time 25 "$NIFI_URL" >/dev/null; then
  ok "Download URL reachable: $NIFI_URL"
else
  warn "Could not HEAD $NIFI_URL from here. It may still work from EC2, but double-check the version."
fi

log "Detecting your public IP (used to lock down the firewall)..."
MY_IP="$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not detect your public IP."
save_state MY_CIDR "${MY_IP}/32"
ok "Your IP is $MY_IP -> firewall will allow ${MY_IP}/32 only"

log "Preflight passed. Next: ./02-network.sh"
