#!/usr/bin/env bash
# ==========================================================================
# 04-verify.sh -- Is it working yet?
#   ./04-verify.sh            one-shot health report
#   ./04-verify.sh --follow   poll until the UI answers (or 20 min pass)
#   ./04-verify.sh --logs     dump the bootstrap + NiFi app logs
# Talks to the server through SSM Run Command - no SSH key required.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state. Run ./03-launch.sh first."

MODE="${1:-check}"

remote() {  # remote "<shell command>"  -> prints stdout from the instance
  local cmd_id
  cmd_id="$(aws ssm send-command --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"$1\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  for _ in $(seq 1 30); do
    sleep 2
    local status
    status="$(aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success|Failed|Cancelled|TimedOut)
        aws ssm get-command-invocation --region "$AWS_REGION" \
          --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
          --query 'StandardOutputContent' --output text
        return 0 ;;
    esac
  done
  return 1
}

ui_up() {  # -k because the certificate is self-signed on purpose
  curl -sk --max-time 8 -o /dev/null -w '%{http_code}' \
    "https://${PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi/" 2>/dev/null
}

case "$MODE" in
  --logs)
    log "Bootstrap log (last 60 lines):"
    remote "tail -n 60 /var/log/nifi-bootstrap.log" || warn "SSM not answering yet."
    log "NiFi application log (last 40 lines):"
    remote "tail -n 40 /opt/nifi/current/logs/nifi-app.log 2>/dev/null || echo 'not created yet'" || true
    ;;

  --follow)
    log "Polling until the NiFi UI responds (up to 20 minutes)..."
    for i in $(seq 1 80); do
      code="$(ui_up || echo 000)"
      if [ "$code" = "200" ] || [ "$code" = "302" ] || [ "$code" = "401" ]; then
        ok "UI answered with HTTP $code"
        break
      fi
      printf '\r  attempt %02d/80  http=%s  (still installing...)' "$i" "$code"
      sleep 15
    done
    echo
    ;;
esac

echo
log "=== Status report ==="
STATE="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' --output text)"
echo "  EC2 instance     : $INSTANCE_ID ($STATE)"
echo "  Public IP        : ${PUBLIC_IP:-none}"
echo "  Bootstrap done   : $(remote 'test -f /opt/nifi/.bootstrap-complete && echo yes || echo "not yet"' 2>/dev/null | tr -d "\r\n" || echo "unknown - SSM starting")"
echo "  systemd nifi     : $(remote 'systemctl is-active nifi 2>/dev/null || echo inactive' 2>/dev/null | tr -d "\r\n" || echo unknown)"
echo "  UI HTTP code     : $(ui_up || echo 'no answer')"
echo
echo "  Open:      https://${PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi"
echo "  Username:  ${NIFI_USERNAME}"
echo "  Password:  (the NIFI_PASSWORD from 00-config.sh)"
echo
echo "  Your browser WILL warn about the certificate. That is expected:"
echo "  NiFi generated a self-signed one. Click through, or install a real"
echo "  certificate later (see the tutorial, 'Making HTTPS real')."
echo
if [ "$ENABLE_SSH" = "true" ]; then
  echo "  SSH:  ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
fi
echo "  SSM:  aws ssm start-session --region ${AWS_REGION} --target ${INSTANCE_ID}"
