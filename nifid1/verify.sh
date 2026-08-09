#!/usr/bin/env bash
# End-to-end check of the NiFi 1.28 + Keycloak OIDC stack.
# Run from the project directory AFTER `docker compose up -d`.
set -uo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
set -a; . ./.env; set +a

KC="http://keycloak:8080"
NIFI="https://localhost:8443"
REALM="nifi"
PASS=0; FAIL=0

ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
step() { echo; echo "== $* =="; }

# ---------------------------------------------------------------- 1. host DNS
step "1. Host can resolve 'keycloak'"
if getent hosts keycloak >/dev/null 2>&1 || ping -c1 -W1 keycloak >/dev/null 2>&1; then
  ok "keycloak resolves on this machine"
else
  bad "add '127.0.0.1 keycloak' to /etc/hosts (C:\\Windows\\System32\\drivers\\etc\\hosts) first"
  echo; echo "Aborting: the rest of the checks depend on this."; exit 1
fi

# ------------------------------------------------------------ 2. config drift
step "2. Config consistency"
if grep -q "\"secret\": \"${OIDC_CLIENT_SECRET}\"" keycloak/realm-nifi.json; then
  ok "client secret matches between .env and realm-nifi.json"
else
  bad "OIDC_CLIENT_SECRET in .env != 'secret' in keycloak/realm-nifi.json"
fi
if grep -q "\"email\": \"${NIFI_ADMIN_IDENTITY}\"" keycloak/realm-nifi.json; then
  ok "NIFI_ADMIN_IDENTITY matches a Keycloak user email"
else
  bad "NIFI_ADMIN_IDENTITY (${NIFI_ADMIN_IDENTITY}) is not the email of any realm user"
fi

# ------------------------------------------------------------- 3. containers
step "3. Containers"
for c in keycloak nifi; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ]; then
    ok "$c is running"
  else
    bad "$c is not running  (docker compose logs $c)"
  fi
done

# ------------------------------------------------------------- 4. discovery
step "4. Keycloak OIDC discovery"
DISC=$(curl -sf --max-time 10 "${KC}/realms/${REALM}/.well-known/openid-configuration")
if [ -n "$DISC" ]; then
  ok "discovery document served"
  ISS=$(printf '%s' "$DISC" | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p')
  if [ "$ISS" = "${KC}/realms/${REALM}" ]; then
    ok "issuer is ${ISS} (same URL the browser and NiFi both use)"
  else
    bad "issuer is '${ISS}', expected '${KC}/realms/${REALM}' -> token validation will fail"
  fi
else
  bad "cannot reach ${KC}/realms/${REALM}/.well-known/openid-configuration"
fi

# ------------------------------------- 5. NiFi container can reach Keycloak
step "5. NiFi container -> Keycloak network path"
if docker exec nifi bash -c 'exec 3<>/dev/tcp/keycloak/8080' 2>/dev/null; then
  ok "nifi container can open a TCP connection to keycloak:8080"
else
  bad "nifi container cannot reach keycloak:8080"
fi

# ------------------------------------------------------------- 6. NiFi HTTPS
step "6. NiFi is up on HTTPS"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "${NIFI}/nifi-api/access/config")
if [ "$CODE" = "200" ]; then
  ok "GET /nifi-api/access/config -> 200"
else
  bad "GET /nifi-api/access/config -> ${CODE} (NiFi may still be booting; wait and rerun)"
fi
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8443/ 2>/dev/null)" = "000" ]; then
  ok "plain HTTP is disabled (HTTPS only)"
fi

# ------------------------------------------------ 7. NiFi advertises OIDC
step "7. NiFi redirects login to Keycloak"
REDIR=$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 15 "${NIFI}/nifi-api/access/oidc/request")
case "$REDIR" in
  ${KC}/realms/${REALM}/protocol/openid-connect/auth*)
    ok "/access/oidc/request -> Keycloak authorization endpoint"
    ;;
  *)
    bad "/access/oidc/request -> '${REDIR}' (expected the Keycloak auth endpoint)"
    ;;
esac

# --------------------------------------------- 8. ID token carries the email
step "8. ID token contains the 'email' claim NiFi maps to an identity"
TOK=$(curl -sf --max-time 10 -X POST \
  "${KC}/realms/${REALM}/protocol/openid-connect/token" \
  -d "client_id=nifi" -d "client_secret=${OIDC_CLIENT_SECRET}" \
  -d "grant_type=password" -d "scope=openid" \
  -d "username=nifi-admin" -d "password=${NIFI_ADMIN_PASSWORD}")
IDT=$(printf '%s' "$TOK" | sed -n 's/.*"id_token":"\([^"]*\)".*/\1/p')
if [ -n "$IDT" ]; then
  PAYLOAD=$(printf '%s' "$IDT" | cut -d. -f2 | tr '_-' '/+')
  case $(( ${#PAYLOAD} % 4 )) in 2) PAYLOAD="${PAYLOAD}==";; 3) PAYLOAD="${PAYLOAD}=";; esac
  CLAIMS=$(printf '%s' "$PAYLOAD" | base64 -d 2>/dev/null)
  EMAIL=$(printf '%s' "$CLAIMS" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p')
  if [ "$EMAIL" = "${NIFI_ADMIN_IDENTITY}" ]; then
    ok "id_token email = ${EMAIL}"
  else
    bad "id_token email = '${EMAIL}', expected '${NIFI_ADMIN_IDENTITY}'"
  fi
else
  bad "could not obtain a token from Keycloak (check client secret / user password)"
fi

# --------------------------------- 9. full authorization-code login via curl
step "9. Full OIDC login (authorization code flow, like a browser)"
JAR=$(mktemp)
AUTH_URL=$(curl -sk -c "$JAR" -o /dev/null -w '%{redirect_url}' "${NIFI}/nifi-api/access/oidc/request")
LOGIN_HTML=$(curl -s -c "$JAR" -b "$JAR" "$AUTH_URL")
ACTION=$(printf '%s' "$LOGIN_HTML" | grep -oE 'action="[^"]+"' | head -1 \
         | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
if [ -z "$ACTION" ]; then
  bad "could not find the Keycloak login form"
else
  CALLBACK=$(curl -s -c "$JAR" -b "$JAR" -o /dev/null -w '%{redirect_url}' \
    --data-urlencode "username=nifi-admin" \
    --data-urlencode "password=${NIFI_ADMIN_PASSWORD}" \
    --data-urlencode "credentialId=" "$ACTION")
  case "$CALLBACK" in
    ${NIFI}/nifi-api/access/oidc/callback*) ok "Keycloak redirected back to the NiFi callback" ;;
    *) bad "unexpected redirect after login: '${CALLBACK}'" ;;
  esac
  curl -sk -c "$JAR" -b "$JAR" -o /dev/null "$CALLBACK"

  JWT=$(awk '/Authorization-Bearer/ {print $NF}' "$JAR" | tail -1)
  USER_JSON=$(curl -sk -b "$JAR" \
    ${JWT:+-H "Authorization: Bearer ${JWT}"} \
    "${NIFI}/nifi-api/flow/current-user")
  IDENT=$(printf '%s' "$USER_JSON" | sed -n 's/.*"identity":"\([^"]*\)".*/\1/p')
  if [ "$IDENT" = "${NIFI_ADMIN_IDENTITY}" ]; then
    ok "logged in to NiFi as ${IDENT}"
  else
    bad "NiFi did not authenticate the user (response: $(printf '%s' "$USER_JSON" | head -c 200))"
  fi
  case "$USER_JSON" in
    *'"canRead":true'*) ok "admin has read access (initial admin policies applied)" ;;
    *) bad "user authenticated but has no policies - check Initial Admin Identity in authorizers.xml" ;;
  esac
fi
rm -f "$JAR"

echo
echo "================================"
echo " passed: ${PASS}   failed: ${FAIL}"
echo "================================"
[ "$FAIL" -eq 0 ]
