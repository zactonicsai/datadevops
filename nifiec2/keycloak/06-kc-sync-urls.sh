#!/usr/bin/env bash
# ==========================================================================
# 06-kc-sync-urls.sh -- Fix the login loop after NiFi's public IP changes.
#
# Stop and start an EC2 instance without an Elastic IP and it gets a NEW
# public address. Keycloak still has the OLD one in its list of allowed
# redirect URIs, so after signing in you get:
#     "Invalid parameter: redirect_uri"
# This script rewrites those URIs to NiFi's current address, and also fixes
# nifi.web.proxy.host on the NiFi side.
#
#   ./06-kc-sync-urls.sh
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state
[ -n "${KC_HOST:-}" ] || die "Keycloak not deployed yet."

A=(aws --region "$AWS_REGION")
BASE="https://${KC_HOST}:${KC_PORT}"

# --------------------------------------------------------------------------
# 1. Ask AWS for NiFi's CURRENT address (the state file may be stale)
# --------------------------------------------------------------------------
CUR_IP="$("${A[@]}" ec2 describe-instances --instance-ids "$NIFI_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[ "$CUR_IP" != "None" ] && [ -n "$CUR_IP" ] || die "NiFi has no public IP right now (is it stopped?)."
log "NiFi's current public IP is ${CUR_IP} (state file says ${NIFI_PUBLIC_IP:-unknown})"

# Keep the NiFi state file honest.
python3 - "$NIFI_STATE_FILE" "$CUR_IP" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); ip = sys.argv[2]
lines = [l for l in p.read_text().splitlines() if not l.startswith("export PUBLIC_IP=")]
lines.append(f'export PUBLIC_IP="{ip}"')
p.write_text("\n".join(lines) + "\n")
PY

# --------------------------------------------------------------------------
# 2. Update the client in Keycloak
# --------------------------------------------------------------------------
TOKEN="$(curl -sk --max-time 20 -X POST \
  "${BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=${KC_ADMIN_USER}" --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
  | jq -r '.access_token // empty')"
[ -n "$TOKEN" ] || die "Could not get a Keycloak admin token."

CID="$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/admin/realms/${KC_REALM}/clients?clientId=${KC_CLIENT_ID}" | jq -r '.[0].id // empty')"
[ -n "$CID" ] || die "Client ${KC_CLIENT_ID} not found in realm ${KC_REALM}."

NEW_BASE="https://${CUR_IP}:${NIFI_HTTPS_PORT}"
log "Setting redirect URIs to ${NEW_BASE}/..."
jq -n --arg cb "${NEW_BASE}/nifi-api/access/oidc/callback" \
      --arg ui "${NEW_BASE}/nifi/*" --arg org "$NEW_BASE" \
  '{redirectUris:[$cb,$ui], webOrigins:[$org], attributes:{"post.logout.redirect.uris":$ui}}' \
  | curl -sk -X PUT "${BASE}/admin/realms/${KC_REALM}/clients/${CID}" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d @- \
  && ok "Keycloak client updated"

curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${BASE}/admin/realms/${KC_REALM}/clients/${CID}" \
  | jq -r '"    redirectUris: \(.redirectUris|join(", "))"'

# --------------------------------------------------------------------------
# 3. Update nifi.web.proxy.host on the NiFi side and restart
# --------------------------------------------------------------------------
log "Updating nifi.web.proxy.host and restarting NiFi..."
CMD_ID="$("${A[@]}" ssm send-command --instance-ids "$NIFI_INSTANCE_ID" \
  --document-name AWS-RunShellScript --timeout-seconds 300 \
  --parameters "commands=[
     \"P=/opt/nifi/current/conf/nifi.properties\",
     \"PRIV=\$(hostname -I | awk '{print \$1}')\",
     \"sed -i \\\"s|^nifi.web.proxy.host=.*|nifi.web.proxy.host=localhost:${NIFI_HTTPS_PORT},\${PRIV}:${NIFI_HTTPS_PORT},${CUR_IP}:${NIFI_HTTPS_PORT}|\\\" \$P\",
     \"systemctl restart nifi\"
   ]" --query 'Command.CommandId' --output text)"

for _ in $(seq 1 40); do
  sleep 4
  ST="$("${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$ST" in
    Success) ok "NiFi updated and restarting"; break ;;
    Failed|Cancelled|TimedOut) die "SSM command $ST" ;;
  esac
done

echo
echo "  Give NiFi 2-3 minutes, then open:  https://${CUR_IP}:${NIFI_HTTPS_PORT}/nifi"
echo
warn "Tired of this? Set ALLOCATE_EIP=\"true\" in ../scripts/00-config.sh so the"
warn "address never changes again (about \$3.60/month)."
