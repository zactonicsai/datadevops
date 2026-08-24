#!/usr/bin/env bash
# AREA 7/7 - Keycloak itself: health endpoints, realm response, admin login.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_cmd curl

header "VERIFY 7/7 - KEYCLOAK APPLICATION"

ALB_ARN="$(find_alb_arn)"
[[ -n "${ALB_ARN}" ]] || { check_fail "ALB not found"; check_summary; exit 1; }

DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" \
       --query 'LoadBalancers[0].DNSName' --output text)"
HAS_HTTPS="$(aws elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" \
             --query 'length(Listeners[?Protocol==`HTTPS`])' --output text)"
[[ "${HAS_HTTPS}" -ge 1 ]] && BASE="https://${DNS}" || BASE="http://${DNS}"
log "base URL: ${BASE}"

http_code() { curl -sS -o /dev/null -w '%{http_code}' -m 15 -k "$1" 2>/dev/null || echo 000; }

# --- Public endpoints through the ALB --------------------------------------
code="$(http_code "${BASE}/realms/master/.well-known/openid-configuration")"
[[ "${code}" == "200" ]] \
  && check_pass "OIDC discovery document returns 200" \
  || check_fail "OIDC discovery returned ${code}"

code="$(http_code "${BASE}/realms/master")"
[[ "${code}" == "200" ]] && check_pass "master realm returns 200" || check_fail "master realm returned ${code}"

code="$(http_code "${BASE}/admin/")"
[[ "${code}" =~ ^(200|302)$ ]] \
  && check_pass "admin console reachable (${code})" \
  || check_fail "admin console returned ${code}"

# --- Issuer must match the configured hostname, not the raw ALB ------------
ISSUER="$(curl -sS -m 15 -k "${BASE}/realms/master/.well-known/openid-configuration" 2>/dev/null \
          | jq -r '.issuer // empty')"
[[ -n "${ISSUER}" ]] && log "issuer: ${ISSUER}" || warn "could not read the issuer"

# --- Container-side health, read from the logs -----------------------------
LOG_GROUP="/aws/ecs/${NAME_PREFIX}/keycloak"
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" \
     --query 'length(logGroups)' --output text 2>/dev/null | grep -qv '^0$'; then
  check_pass "log group ${LOG_GROUP} exists"
  log "recent errors in the last 15 minutes (if any)"
  aws logs filter-log-events --log-group-name "${LOG_GROUP}" \
    --start-time "$(( ($(date +%s) - 900) * 1000 ))" \
    --filter-pattern 'ERROR' --max-items 10 \
    --query 'events[].message' --output text 2>/dev/null | head -20 || true
else
  check_fail "log group ${LOG_GROUP} not found"
fi

log "admin password: aws secretsmanager get-secret-value --secret-id ${NAME_PREFIX}/keycloak/admin-<suffix> --query SecretString --output text | jq -r .password"

check_summary
