#!/usr/bin/env bash
# End-to-end access check: DNS -> ALB -> TLS -> Keycloak -> admin login.
# Run from the module directory after `terraform apply`.
set -uo pipefail
DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DIR"

DOMAIN=$(terraform output -raw keycloak_url | sed 's#https://##')
ALB=$(terraform output -raw alb_dns_name)
TG=$(terraform output -raw target_group_arn)
REGION=$(terraform output -raw ssm_shell_command | sed -E 's/.*--region ([^ ]+).*/\1/')
ADMIN_PW=$(terraform output -raw admin_password)
FAIL=0

ok()   { printf '  [OK]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

echo "1. DNS: $DOMAIN -> ALB"
DNS_IPS=$(dig +short "$DOMAIN" | sort)
ALB_IPS=$(dig +short "$ALB" | sort)
if [[ -n "$DNS_IPS" && "$DNS_IPS" == "$ALB_IPS" ]]; then ok "resolves to $(echo $DNS_IPS)"; else fail "got [$DNS_IPS], ALB is [$ALB_IPS]"; fi

echo "2. ACM certificate"
CERT_STATUS=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN'].Status" --output text)
[[ "$CERT_STATUS" == *ISSUED* ]] && ok "status ISSUED" || fail "status: ${CERT_STATUS:-not found}"

echo "3. Target health"
TH=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' --output text)
echo "     $TH"
[[ "$TH" == *healthy* && "$TH" != *unhealthy* ]] && ok "target healthy" || fail "target not healthy (new instances take ~5 min)"

echo "4. HTTP -> HTTPS redirect"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$DOMAIN/")
[[ "$CODE" == "301" ]] && ok "301 redirect" || fail "got $CODE"

echo "5. TLS + Keycloak realm endpoint"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/realms/master")
[[ "$CODE" == "200" ]] && ok "https://$DOMAIN/realms/master -> 200 (valid cert)" || fail "got $CODE (curl exit $?)"

echo "6. Issuer URL uses the public hostname"
ISSUER=$(curl -s "https://$DOMAIN/realms/master/.well-known/openid-configuration" | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p')
[[ "$ISSUER" == "https://$DOMAIN/realms/master" ]] && ok "$ISSUER" || fail "issuer is '$ISSUER'"

echo "7. Admin login"
TOKEN=$(curl -s -X POST "https://$DOMAIN/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d username=admin -d "password=$ADMIN_PW" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[[ -n "$TOKEN" ]] && ok "obtained admin token" || fail "could not get admin token"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "All checks passed. Admin console: https://$DOMAIN/admin/  (user: admin)"
else
  echo "Some checks failed. Host logs:  $(terraform output -raw ssm_shell_command)"
  echo "  then: sudo docker compose -f /opt/keycloak/compose.yaml logs keycloak"
  exit 1
fi
