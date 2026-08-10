#!/usr/bin/env bash
# ==========================================================================
# 05-dns-sync.sh -- Point the DNS record at the instance's current address.
#
# A private IP normally survives a stop and start, unlike a public one. But
# it does change if the instance is replaced, rebuilt, or moved to another
# subnet. This puts the record back in step.
#
#   ./05-dns-sync.sh                 use the instance in the state file
#   ./05-dns-sync.sh i-0abc123       use a specific instance
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"
load_state

A=(aws --region "$AWS_REGION")
TARGET="${1:-${INSTANCE_ID:-}}"
[ -n "$TARGET" ] || die "No instance given and none in the state file."
[ -n "${HOSTED_ZONE_ID:-}" ] || die "No hosted zone in state. Run ./02-adopt.sh first."

CURRENT_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$TARGET" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)"
[ -n "$CURRENT_IP" ] && [ "$CURRENT_IP" != "None" ] || die "Instance $TARGET has no private address (is it running?)."

RECORDED="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.' && Type=='A']|[0].ResourceRecords[0].Value" \
  --output text 2>/dev/null)"

log "DNS says ${RECORDED:-nothing}; the instance is at ${CURRENT_IP}"
if [ "$RECORDED" = "$CURRENT_IP" ]; then
  ok "Already correct. Nothing to do."
  exit 0
fi

CHANGE_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{
    \"Comment\": \"resync to ${TARGET}\",
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"${NIFI_DNS_NAME}\", \"Type\": \"A\", \"TTL\": ${DNS_TTL},
        \"ResourceRecords\": [{\"Value\": \"${CURRENT_IP}\"}]
      }
    }]
  }" --query 'ChangeInfo.Id' --output text)"

aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || sleep 20
save_state INSTANCE_ID "$TARGET"
save_state PRIVATE_IP  "$CURRENT_IP"
save_state DNS_RECORD_VALUE "$CURRENT_IP"
ok "${NIFI_DNS_NAME} now points at ${CURRENT_IP}"

# NiFi checks the Host header against its own list, and that list was built
# at first boot. A new address means the list needs the new one too.
log "Refreshing nifi.web.proxy.host on the instance..."
CMD_ID="$("${A[@]}" ssm send-command --instance-ids "$TARGET" \
  --document-name AWS-RunShellScript --timeout-seconds 300 \
  --parameters "commands=[
     \"P=/opt/nifi/current/conf/nifi.properties\",
     \"PRIV=\$(hostname -I | awk '{print \$1}')\",
     \"HN=\$(hostname -f)\",
     \"sed -i \\\"s|^nifi.web.proxy.host=.*|nifi.web.proxy.host=${NIFI_DNS_NAME}:${NIFI_HTTPS_PORT},${NIFI_DNS_NAME},\${PRIV}:${NIFI_HTTPS_PORT},\${HN}:${NIFI_HTTPS_PORT},localhost:${NIFI_HTTPS_PORT}|\\\" \$P\",
     \"systemctl restart nifi\"
   ]" --query 'Command.CommandId' --output text)"

for _ in $(seq 1 40); do
  sleep 4
  case "$("${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
           --instance-id "$TARGET" --query Status --output text 2>/dev/null || echo Pending)" in
    Success) ok "NiFi updated and restarting (allow 2-3 minutes)"; break ;;
    Failed|Cancelled|TimedOut) warn "Could not update NiFi over SSM. Edit nifi.web.proxy.host by hand."; break ;;
  esac
done

echo
echo "  https://${NIFI_DNS_NAME}:${NIFI_HTTPS_PORT}/nifi"
