#!/usr/bin/env bash
# ==========================================================================
# 02-kc-verify.sh -- Is Keycloak up, and is its OIDC discovery document
# reachable? NiFi cannot be configured until both are true.
#
#   ./02-kc-verify.sh            one-shot report
#   ./02-kc-verify.sh --follow   poll until ready (up to 10 minutes)
#   ./02-kc-verify.sh --logs     show the bootstrap and container logs
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state
[ -n "${KC_INSTANCE_ID:-}" ] || die "No Keycloak instance in state. Run ./01-kc-launch.sh first."

A=(aws --region "$AWS_REGION")
DISCOVERY="https://${KC_HOST}:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration"

remote() {  # run a shell command on the Keycloak box through SSM
  local cmd_id
  cmd_id="$("${A[@]}" ssm send-command --instance-ids "$KC_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"$1\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null)" || return 1
  for _ in $(seq 1 30); do
    sleep 2
    case "$("${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
             --instance-id "$KC_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)" in
      Success|Failed|Cancelled|TimedOut)
        "${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
          --instance-id "$KC_INSTANCE_ID" --query StandardOutputContent --output text
        return 0 ;;
    esac
  done
  return 1
}

# -k because the certificate is self-signed, which is expected here.
probe() { curl -sk --max-time 8 -o /dev/null -w '%{http_code}' "$DISCOVERY" 2>/dev/null; }

case "${1:-check}" in
  --logs)
    log "Bootstrap log (last 40 lines):"
    remote "tail -n 40 /var/log/keycloak-bootstrap.log" || warn "SSM not answering yet."
    log "Keycloak container log (last 40 lines):"
    remote "docker logs --tail 40 keycloak 2>&1 || echo 'container not running'" || true
    ;;
  --follow)
    log "Polling ${DISCOVERY}"
    for i in $(seq 1 40); do
      code="$(probe || echo 000)"
      if [ "$code" = "200" ]; then ok "Discovery document served (HTTP 200)"; break; fi
      printf '\r  attempt %02d/40  http=%s  (image pull + realm import take a few minutes...)' "$i" "$code"
      sleep 15
    done
    echo
    ;;
esac

echo
log "=== Keycloak status ==="
echo "  Instance      : ${KC_INSTANCE_ID} ($("${A[@]}" ec2 describe-instances --instance-ids "$KC_INSTANCE_ID" \
                          --query 'Reservations[0].Instances[0].State.Name' --output text))"
echo "  Hostname      : ${KC_HOST}  ->  ${KC_PUBLIC_IP}"
echo "  Bootstrap     : $(remote 'test -f /opt/keycloak/.bootstrap-complete && echo done || echo "in progress"' 2>/dev/null | tr -d '\r\n' || echo 'unknown')"
echo "  Container     : $(remote 'docker ps --filter name=keycloak --format "{{.Status}}" 2>/dev/null || echo none' 2>/dev/null | tr -d '\r\n' || echo unknown)"
echo "  Health/ready  : $(remote 'curl -sf http://127.0.0.1:9000/health/ready >/dev/null && echo UP || echo DOWN' 2>/dev/null | tr -d '\r\n' || echo unknown)"
echo "  Discovery URL : $(probe || echo 'no answer')  ${DISCOVERY}"
echo

if [ "$(probe || echo 000)" = "200" ]; then
  log "Endpoints Keycloak is advertising:"
  curl -sk "$DISCOVERY" | jq -r '
    "    issuer        : \(.issuer)",
    "    authorization : \(.authorization_endpoint)",
    "    token         : \(.token_endpoint)",
    "    jwks          : \(.jwks_uri)"' 2>/dev/null || warn "Could not parse the discovery document."
  echo
  echo "  Admin console : https://${KC_HOST}:${KC_PORT}/admin/"
  echo "  Admin login   : ${KC_ADMIN_USER}"
  echo
  echo "  Next: ./03-nifi-oidc.sh   (points NiFi at Keycloak)"
else
  warn "Not ready yet. Try:  ./02-kc-verify.sh --follow   or   ./02-kc-verify.sh --logs"
fi
