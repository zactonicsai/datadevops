#!/usr/bin/env bash
# ==========================================================================
# 05-kc-add-user.sh -- Add another person who can sign in to NiFi.
#
#   ./05-kc-add-user.sh <username> <email> <password> [First] [Last]
#
# Two separate systems are involved, and BOTH need the person:
#   1. Keycloak decides whether they are who they say they are  (this script)
#   2. NiFi decides what they are allowed to do  (you, in the NiFi UI)
#
# After running this, log in to NiFi as the admin and go to
#   ☰  ->  Users  ->  Add User  ->  type their email exactly
#   ☰  ->  Policies  (or right-click the canvas -> Manage access policies)
# and grant them what they need. Until you do, they can log in but will see
# "Unable to view the user interface" - that is authorisation, not a bug.
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state

USERNAME="${1:-}"; EMAIL="${2:-}"; PASSWORD="${3:-}"
FIRST="${4:-NiFi}"; LAST="${5:-User}"
[ -n "$USERNAME" ] && [ -n "$EMAIL" ] && [ -n "$PASSWORD" ] \
  || die "Usage: $0 <username> <email> <password> [First] [Last]"
[ "${#PASSWORD}" -ge 12 ] || die "Use a password of at least 12 characters."
[ -n "${KC_HOST:-}" ] || die "Keycloak not deployed yet."

BASE="https://${KC_HOST}:${KC_PORT}"

# --------------------------------------------------------------------------
# 1. Get an admin token. -k because the certificate is self-signed.
#    admin-cli is Keycloak's built-in client for exactly this.
# --------------------------------------------------------------------------
log "Signing in to Keycloak as ${KC_ADMIN_USER} ..."
TOKEN="$(curl -sk --max-time 20 -X POST \
  "${BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=${KC_ADMIN_USER}" --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
  | jq -r '.access_token // empty')"
[ -n "$TOKEN" ] || die "Could not get an admin token. Check KC_ADMIN_PASSWORD in 00-kc-config.sh."
ok "Authenticated"

# --------------------------------------------------------------------------
# 2. Create the user
# --------------------------------------------------------------------------
log "Creating ${USERNAME} <${EMAIL}> in realm ${KC_REALM} ..."
CODE="$(jq -n --arg u "$USERNAME" --arg e "$EMAIL" --arg f "$FIRST" --arg l "$LAST" --arg p "$PASSWORD" \
  '{username:$u, email:$e, firstName:$f, lastName:$l, enabled:true, emailVerified:true,
    credentials:[{type:"password", value:$p, temporary:false}]}' \
  | curl -sk -o /tmp/kc-adduser.out -w '%{http_code}' -X POST \
      "${BASE}/admin/realms/${KC_REALM}/users" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d @-)"

case "$CODE" in
  201) ok "User created" ;;
  409) warn "That username or email already exists in Keycloak - updating the password instead"
       UID_="$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
         "${BASE}/admin/realms/${KC_REALM}/users?username=${USERNAME}&exact=true" | jq -r '.[0].id // empty')"
       [ -n "$UID_" ] || die "Could not find the existing user."
       jq -n --arg p "$PASSWORD" '{type:"password", value:$p, temporary:false}' \
         | curl -sk -X PUT "${BASE}/admin/realms/${KC_REALM}/users/${UID_}/reset-password" \
             -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d @- >/dev/null
       ok "Password reset" ;;
  *)   cat /tmp/kc-adduser.out; die "Keycloak returned HTTP ${CODE}" ;;
esac
rm -f /tmp/kc-adduser.out

IDENTITY="$EMAIL"
[ "$OIDC_IDENTITY_CLAIM" = "preferred_username" ] && IDENTITY="$USERNAME"

cat <<EOF

  Done in Keycloak. One step remains, and it has to be done in NiFi:

    1. Open  https://${NIFI_PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi  as the admin
       (${NIFI_ADMIN_EMAIL})
    2. Menu (top right)  ->  Users  ->  Add User
    3. Identity:  ${IDENTITY}
       It must match character for character - NiFi compares the whole string.
    4. Menu  ->  Policies, or right-click the canvas -> Manage access policies,
       and grant the permissions they need. Useful starting points:
         "view the user interface"        - lets them see NiFi at all
         "view the data" / "modify the data" on a process group
         "view the flow" / "modify the flow" on a process group

  Until step 4, signing in succeeds but NiFi shows an access-denied page.

EOF
