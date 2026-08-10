#!/usr/bin/env bash
# ==========================================================================
# 04-verify.sh -- Is it working, and does the name resolve?
#
#   ./04-verify.sh            one-shot report
#   ./04-verify.sh --follow   poll until NiFi answers
#   ./04-verify.sh --logs     bootstrap and application logs
#   ./04-verify.sh --tunnel   open a port-forward and tell you what to open
#
# Everything here works from outside the VPC, because the checks that need
# to be inside are run through SSM.
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-existing-config.sh"
load_state
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state. Run ./03-launch-private.sh first."

A=(aws --region "$AWS_REGION")

remote() {
  local cmd_id
  cmd_id="$("${A[@]}" ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript --parameters "commands=[\"$1\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  for _ in $(seq 1 30); do
    sleep 2
    case "$("${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
             --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)" in
      Success|Failed|Cancelled|TimedOut)
        "${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
          --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
        return 0 ;;
    esac
  done
  return 1
}

case "${1:-check}" in
  --tunnel)
    log "Opening a tunnel. Leave this running, then browse:"
    echo "    https://localhost:${NIFI_HTTPS_PORT}/nifi"
    echo
    exec "${A[@]}" ssm start-session --target "$INSTANCE_ID" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "{\"portNumber\":[\"${NIFI_HTTPS_PORT}\"],\"localPortNumber\":[\"${NIFI_HTTPS_PORT}\"]}"
    ;;
  --logs)
    log "Bootstrap log (last 40 lines):"
    remote "tail -n 40 /var/log/nifi-bootstrap.log" || warn "SSM not answering yet."
    log "NiFi application log (last 30 lines):"
    remote "tail -n 30 /opt/nifi/current/logs/nifi-app.log 2>/dev/null || echo 'not created yet'" || true
    ;;
  --follow)
    log "Polling from inside the VPC, through SSM (up to 20 minutes)..."
    for i in $(seq 1 40); do
      CODE="$(remote "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://localhost:${NIFI_HTTPS_PORT}/nifi/ || echo 000" 2>/dev/null | tr -d '\r\n')"
      case "$CODE" in
        200|302|401) ok "NiFi answered with HTTP $CODE"; break ;;
      esac
      printf '\r  attempt %02d/40  http=%s  (still installing...)' "$i" "${CODE:-...}"
      sleep 20
    done
    echo
    ;;
esac

echo
log "=== Status ==="
STATE="$("${A[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)"
echo "  Instance      : ${INSTANCE_ID} (${STATE})"
echo "  Private IP    : ${PRIVATE_IP:-unknown}"
echo "  DNS name      : ${NIFI_DNS_NAME}"
echo "  Bootstrap     : $(remote 'test -f /opt/nifi/.bootstrap-complete && echo done || echo "in progress"' 2>/dev/null | tr -d '\r\n' || echo 'unknown - SSM starting')"
echo "  Service       : $(remote 'systemctl is-active nifi 2>/dev/null || echo inactive' 2>/dev/null | tr -d '\r\n' || echo unknown)"

echo
log "=== DNS ==="
REC="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${NIFI_DNS_NAME}.' && Type=='A']|[0].[TTL,ResourceRecords[0].Value]" \
  --output text 2>/dev/null | tr '\t' ' ')"
if [ -n "$REC" ] && [ "$REC" != "None None" ]; then
  ok "Route 53 record: ${NIFI_DNS_NAME} -> $(echo "$REC" | awk '{print $2}') (TTL $(echo "$REC" | awk '{print $1}'))"
  RECIP="$(echo "$REC" | awk '{print $2}')"
  [ "$RECIP" = "${PRIVATE_IP:-}" ] && ok "The record matches the instance" \
    || warn "The record points at ${RECIP} but the instance is ${PRIVATE_IP}. Run ./05-dns-sync.sh"
else
  warn "No A record found for ${NIFI_DNS_NAME} in zone ${HOSTED_ZONE_ID}"
fi

# Does the name resolve from where YOU are? Often it will not, and that is
# expected for a private zone unless you are on the VPN.
LOCAL_RES="$(getent hosts "$NIFI_DNS_NAME" 2>/dev/null | awk '{print $1}' | head -1)"
if [ -n "$LOCAL_RES" ]; then
  ok "Resolves from here: ${NIFI_DNS_NAME} -> ${LOCAL_RES}"
else
  warn "Does not resolve from this machine. Normal for a private zone unless you are on the VPN."
  warn "Use  ./04-verify.sh --tunnel  to reach it anyway."
fi

# And from inside the VPC, which is what actually matters.
INSIDE="$(remote "getent hosts ${NIFI_DNS_NAME} | awk '{print \$1}' | head -1" 2>/dev/null | tr -d '\r\n')"
[ -n "$INSIDE" ] && ok "Resolves inside the VPC: ${NIFI_DNS_NAME} -> ${INSIDE}" \
  || warn "Does not resolve inside the VPC. Check the private zone is associated with ${VPC_ID}."

echo
echo "  Open:      https://${NIFI_DNS_NAME}:${NIFI_HTTPS_PORT}/nifi"
echo "  Username:  ${NIFI_USERNAME}"
echo "  Shell:     aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID}"
echo "  Tunnel:    ./04-verify.sh --tunnel"
echo
