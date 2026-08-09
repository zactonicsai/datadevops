#!/usr/bin/env bash
# ==========================================================================
# 05-set-credentials.sh -- Change the NiFi login without touching the box.
#   ./05-set-credentials.sh <username> <password-12-chars-or-more>
# NiFi must be stopped while credentials change, so this restarts it.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state

NEW_USER="${1:-}"; NEW_PASS="${2:-}"
[ -n "$NEW_USER" ] && [ -n "$NEW_PASS" ] || die "Usage: $0 <username> <password>"
[ "${#NEW_PASS}" -ge 12 ] || die "NiFi requires a password of at least 12 characters."
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state."

log "Stopping NiFi, setting credentials, starting NiFi..."
CMD_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[
     \"systemctl stop nifi\",
     \"JH=\$(dirname \$(dirname \$(readlink -f \$(command -v java))))\",
     \"runuser -u nifi -- env JAVA_HOME=\$JH /opt/nifi/current/bin/nifi.sh set-single-user-credentials '${NEW_USER}' '${NEW_PASS}'\",
     \"systemctl start nifi\",
     \"sleep 5; systemctl is-active nifi\"
   ]" \
  --query 'Command.CommandId' --output text)"

for _ in $(seq 1 40); do
  sleep 3
  ST="$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query 'Status' --output text 2>/dev/null || echo Pending)"
  case "$ST" in
    Success) ok "Credentials updated for user '$NEW_USER'"; break ;;
    Failed|Cancelled|TimedOut)
      aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query 'StandardErrorContent' --output text
      die "Command $ST" ;;
  esac
done

warn "NiFi takes 1-3 minutes to finish restarting. Then log in at:"
echo "  https://${PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi"
