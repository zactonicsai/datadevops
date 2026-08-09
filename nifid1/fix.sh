#!/usr/bin/env bash
# Repairs the Keycloak realm in place - no re-import, no data loss.
# Grants each realm user the roles NiFi's OIDC request needs, and (optionally)
# assigns every client scope to the nifi client.
#
#   ./fix-keycloak.sh           diagnose + fix roles
#   ./fix-keycloak.sh --scopes  also assign all client scopes to the client
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
set -a; [ -f ./.env ] && . ./.env; set +a

REALM=nifi
CLIENT=nifi
ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KCADM="/opt/keycloak/bin/kcadm.sh"
kc() { docker compose exec -T keycloak "$KCADM" "$@"; }

echo "== authenticating kcadm =="
kc config credentials --server http://localhost:8080 \
   --realm master --user admin --password "$ADMIN_PW" || {
  echo "FAILED: could not log in to Keycloak. Is the container up?"; exit 1; }

echo
echo "== current role mappings =="
for U in nifi-admin nifi-user; do
  ROLES=$(kc get-roles -r "$REALM" --uusername "$U" --fields name \
          --format csv --noquotes 2>/dev/null | tr -d '\r' | paste -sd' ' -)
  printf '  %-12s %s\n' "$U" "${ROLES:-<none>}"
done

echo
echo "== granting offline_access + default-roles-${REALM} =="
for U in nifi-admin nifi-user; do
  for R in "default-roles-${REALM}" offline_access uma_authorization; do
    if kc add-roles -r "$REALM" --uusername "$U" --rolename "$R" >/dev/null 2>&1; then
      echo "  ${U}: added ${R}"
    else
      echo "  ${U}: ${R} already present or unavailable"
    fi
  done
done

if [ "${1:-}" = "--scopes" ]; then
  echo
  echo "== assigning all client scopes to client '${CLIENT}' =="
  CID=$(kc get clients -r "$REALM" -q "clientId=${CLIENT}" --fields id \
        --format csv --noquotes 2>/dev/null | tr -d '\r' | head -1)
  if [ -z "$CID" ]; then
    echo "  FAILED: client ${CLIENT} not found"
  else
    kc get client-scopes -r "$REALM" --fields id,name --format csv --noquotes 2>/dev/null \
    | tr -d '\r' | while IFS=, read -r SID SNAME; do
        [ -z "${SID:-}" ] && continue
        if kc update "clients/${CID}/optional-client-scopes/${SID}" -r "$REALM" >/dev/null 2>&1; then
          echo "  + ${SNAME}"
        fi
      done
  fi
fi

echo
echo "== verifying =="
for U in nifi-admin nifi-user; do
  ROLES=$(kc get-roles -r "$REALM" --uusername "$U" --fields name \
          --format csv --noquotes 2>/dev/null | tr -d '\r' | paste -sd' ' -)
  case "$ROLES" in
    *offline_access*) printf '  PASS  %-12s has offline_access\n' "$U" ;;
    *)                printf '  FAIL  %-12s roles: %s\n' "$U" "${ROLES:-<none>}" ;;
  esac
done

echo
echo "Now clear cookies for localhost:8443 and log in again."