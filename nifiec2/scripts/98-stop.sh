#!/usr/bin/env bash
# ==========================================================================
# 98-stop.sh -- The gentle alternative to destroying everything.
#
#   ./98-stop.sh          shut the instance down (keeps the disk + your flow)
#   ./98-stop.sh --start  turn it back on
#
# Stopped instance  = no compute charge, but you STILL pay for the EBS disk
#                     (~$3.20/month for 40 GB gp3) and any Elastic IP.
# Terminated        = pays nothing, keeps nothing.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state file."

if [ "${1:-}" = "--start" ]; then
  log "Starting $INSTANCE_ID ..."
  aws ec2 start-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

  NEW_IP="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  save_state PUBLIC_IP "$NEW_IP"
  ok "Running at $NEW_IP"

  if [ "$ALLOCATE_EIP" != "true" ]; then
    warn "No Elastic IP, so the public IP CHANGED. NiFi will reject the new"
    warn "address until nifi.web.proxy.host is updated. Fixing that now..."
    aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[
        \"IP=\$(curl -s -H \\\"X-aws-ec2-metadata-token: \$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')\\\" http://169.254.169.254/latest/meta-data/public-ipv4)\",
        \"sed -i \\\"s|^nifi.web.proxy.host=.*|nifi.web.proxy.host=localhost:${NIFI_HTTPS_PORT},\\\${IP}:${NIFI_HTTPS_PORT}|\\\" /opt/nifi/current/conf/nifi.properties\",
        \"systemctl restart nifi\"
      ]" >/dev/null
    ok "proxy.host updated and NiFi restarting (give it 2-3 minutes)"
  fi
  echo "  https://${NEW_IP}:${NIFI_HTTPS_PORT}/nifi"
  exit 0
fi

log "Stopping NiFi cleanly first, so queued FlowFiles are checkpointed..."
aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop nifi"]' >/dev/null 2>&1 \
  && sleep 25 && ok "NiFi service stopped" \
  || warn "Could not reach SSM; stopping the instance anyway"

log "Stopping instance $INSTANCE_ID ..."
aws ec2 stop-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
ok "Stopped. Compute charges have ended; the EBS volume is still billed."
echo "  Resume with: ./98-stop.sh --start"
echo "  Destroy with: ./99-teardown.sh"
