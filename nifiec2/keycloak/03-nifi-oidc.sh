#!/usr/bin/env bash
# ==========================================================================
# 03-nifi-oidc.sh -- Switch NiFi from its single shared login to Keycloak
# single sign-on.
#
# BEFORE IT CHANGES ANYTHING it copies every file it is about to touch into
# /opt/nifi/backups/pre-oidc-<timestamp>/ on the NiFi server, and records
# that path. ./04-nifi-restore.sh puts it all back from there.
#
#   ./03-nifi-oidc.sh              apply
#   ./03-nifi-oidc.sh --show       print the changes it would make, no action
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state

A=(aws --region "$AWS_REGION")
[ -n "${KC_HOST:-}" ]        || die "Keycloak not deployed. Run ./01-kc-launch.sh first."
[ -n "${NIFI_INSTANCE_ID:-}" ] || die "NiFi instance not found in ../scripts/.deploy-state"

DISCOVERY="https://${KC_HOST}:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration"
INITIAL_ADMIN="$NIFI_ADMIN_EMAIL"
[ "$OIDC_IDENTITY_CLAIM" = "preferred_username" ] && INITIAL_ADMIN="$NIFI_ADMIN_USERNAME"

# --------------------------------------------------------------------------
# Make sure Keycloak is actually answering before we touch NiFi.
# --------------------------------------------------------------------------
log "Checking Keycloak first..."
CODE="$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$DISCOVERY" || echo 000)"
[ "$CODE" = "200" ] || die "Keycloak discovery URL returned HTTP ${CODE}.
       Fix that before changing NiFi: ./02-kc-verify.sh --follow"
ok "Keycloak is serving its discovery document"

cat <<PLAN

  Changes about to be made on the NiFi server (${NIFI_INSTANCE_ID}):

   1. Back up  nifi.properties, authorizers.xml, login-identity-providers.xml,
      users.xml, authorizations.xml  ->  /opt/nifi/backups/pre-oidc-<timestamp>/
   2. Add a hosts entry so ${KC_HOST} resolves to Keycloak's PRIVATE address
      (${KC_PRIVATE_IP}) - the back-channel then stays inside the VPC
   3. Import Keycloak's certificate into NiFi's truststore, so NiFi trusts it
   4. nifi.properties:
        nifi.security.user.login.identity.provider =            (emptied)
        nifi.security.user.authorizer               = managed-authorizer
        nifi.security.user.oidc.discovery.url       = ${DISCOVERY}
        nifi.security.user.oidc.client.id           = ${KC_CLIENT_ID}
        nifi.security.user.oidc.client.secret       = (from .kc-state)
        nifi.security.user.oidc.claim.identifying.user = ${OIDC_IDENTITY_CLAIM}
        nifi.security.user.oidc.truststore.strategy = NIFI
   5. authorizers.xml: replace single-user-authorizer with managed-authorizer,
      Initial Admin Identity = ${INITIAL_ADMIN}
   6. Delete users.xml and authorizations.xml so NiFi rebuilds them and the
      new Initial Admin actually takes effect
   7. Restart NiFi

  After this, the old admin/password login STOPS working. Everyone signs in
  through Keycloak instead. ./04-nifi-restore.sh reverses all of it.

PLAN

[ "${1:-}" = "--show" ] && { log "--show given, stopping here."; exit 0; }

read -r -p "  Type 'apply' to continue: " ANSWER
[ "$ANSWER" = "apply" ] || die "Aborted. Nothing was changed."

# --------------------------------------------------------------------------
# Build the script that will run ON the NiFi box.
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
REMOTE="${BUILD_DIR}/nifi-apply-oidc.sh"
AUTHZ="$(cat "${KC_DIR}/templates/authorizers.xml.tmpl")"

cat > "$REMOTE" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/nifi-oidc-apply.log) 2>&1
echo "=== NiFi OIDC switch, $(date -Is) ==="

NIFI_HOME=/opt/nifi/current
CONF="${NIFI_HOME}/conf"
PROPS="${CONF}/nifi.properties"

KC_HOST="__KC_HOST__"
KC_PORT="__KC_PORT__"
KC_PRIVATE_IP="__KC_PRIVATE_IP__"
DISCOVERY="__DISCOVERY__"
CLIENT_ID="__CLIENT_ID__"
CLIENT_SECRET="__CLIENT_SECRET__"
IDENTITY_CLAIM="__IDENTITY_CLAIM__"
INITIAL_ADMIN="__INITIAL_ADMIN__"

# ---------- 1. BACK UP -----------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/opt/nifi/backups/pre-oidc-${STAMP}"
mkdir -p "$BK"
for f in nifi.properties authorizers.xml login-identity-providers.xml users.xml authorizations.xml; do
  if [ -f "${CONF}/${f}" ]; then
    cp -a "${CONF}/${f}" "${BK}/${f}"
    echo "$f" >> "${BK}/MANIFEST"
    echo "  backed up ${f}"
  fi
done
cp -a /etc/hosts "${BK}/hosts" 2>/dev/null || true
echo "single-user" > "${BK}/AUTH_MODE"
echo "$BK" > /opt/nifi/backups/LATEST_PRE_OIDC
chmod -R go-rwx "$BK"
echo "backup complete: $BK"

# ---------- 2. HOSTS ENTRY -------------------------------------------------
# Keycloak's public hostname is <public-ip>.nip.io. We point that name at its
# PRIVATE address here, so NiFi's server-to-server calls never leave the VPC,
# while your browser still uses the public address. Both see the same
# hostname, so the "issuer" inside the token matches either way.
sed -i "/ ${KC_HOST}\$/d" /etc/hosts
echo "${KC_PRIVATE_IP} ${KC_HOST}" >> /etc/hosts
getent hosts "$KC_HOST" || true

# ---------- 3. TRUST KEYCLOAK'S CERTIFICATE --------------------------------
# Keycloak uses a self-signed certificate, so NiFi will refuse to talk to it
# until that certificate is inside NiFi's truststore.
TS_REL="$(grep -E '^nifi\.security\.truststore=' "$PROPS" | cut -d= -f2-)"
TS_PW="$(grep -E '^nifi\.security\.truststorePasswd=' "$PROPS" | cut -d= -f2-)"
TS_TYPE="$(grep -E '^nifi\.security\.truststoreType=' "$PROPS" | cut -d= -f2-)"
TS_ABS="${TS_REL/#.\//${NIFI_HOME}/}"
echo "truststore: $TS_ABS (${TS_TYPE:-PKCS12})"

openssl s_client -connect "${KC_HOST}:${KC_PORT}" -servername "${KC_HOST}" </dev/null 2>/dev/null \
  | openssl x509 > /tmp/keycloak.crt
[ -s /tmp/keycloak.crt ] || { echo "FAILED to fetch Keycloak certificate"; exit 1; }
openssl x509 -in /tmp/keycloak.crt -noout -subject -dates

KEYTOOL="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")/bin/keytool"
"$KEYTOOL" -delete -alias keycloak-nifi -keystore "$TS_ABS" \
  -storepass "$TS_PW" -storetype "${TS_TYPE:-PKCS12}" 2>/dev/null || true
"$KEYTOOL" -importcert -noprompt -alias keycloak-nifi -file /tmp/keycloak.crt \
  -keystore "$TS_ABS" -storepass "$TS_PW" -storetype "${TS_TYPE:-PKCS12}"
chown nifi:nifi "$TS_ABS"
echo "certificate imported as alias keycloak-nifi"

# ---------- 4. nifi.properties --------------------------------------------
set_prop() {
  if grep -q "^${1}=" "$PROPS"; then
    python3 - "$PROPS" "$1" "${2:-}" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    out.append(f"{key}={val}\n" if line.startswith(key + "=") else line)
open(path, "w").writelines(out)
PY
  else
    printf '%s=%s\n' "$1" "${2:-}" >> "$PROPS"
  fi
}

# Turn OFF the single shared login.
set_prop "nifi.security.user.login.identity.provider" ""
# Turn ON per-user permissions.
set_prop "nifi.security.user.authorizer" "managed-authorizer"
# Point at Keycloak.
set_prop "nifi.security.user.oidc.discovery.url"          "$DISCOVERY"
set_prop "nifi.security.user.oidc.connect.timeout"        "10 secs"
set_prop "nifi.security.user.oidc.read.timeout"           "10 secs"
set_prop "nifi.security.user.oidc.client.id"              "$CLIENT_ID"
set_prop "nifi.security.user.oidc.client.secret"          "$CLIENT_SECRET"
set_prop "nifi.security.user.oidc.preferred.jwsalgorithm" "RS256"
set_prop "nifi.security.user.oidc.additional.scopes"      "profile,email"
set_prop "nifi.security.user.oidc.claim.identifying.user" "$IDENTITY_CLAIM"
# Use NiFi's own truststore (where we just put Keycloak's certificate)
# instead of the JDK's list of public certificate authorities.
set_prop "nifi.security.user.oidc.truststore.strategy"    "NIFI"

# ---------- 5. authorizers.xml --------------------------------------------
cat > "${CONF}/authorizers.xml" <<'AUTHZ_EOF'
__AUTHORIZERS_XML__
AUTHZ_EOF
python3 - "${CONF}/authorizers.xml" "$INITIAL_ADMIN" <<'PY'
import sys
p, admin = sys.argv[1], sys.argv[2]
s = open(p).read().replace("__INITIAL_ADMIN__", admin)
open(p, "w").write(s)
PY
echo "authorizers.xml written, Initial Admin Identity = ${INITIAL_ADMIN}"

# ---------- 6. FORCE A REBUILD OF THE USER/POLICY FILES --------------------
# These are only generated when they do not exist. If we left the old ones in
# place, the new Initial Admin Identity would be silently ignored and nobody
# could log in.
rm -f "${CONF}/users.xml" "${CONF}/authorizations.xml"

chown -R nifi:nifi "$CONF"
echo "oidc" > /opt/nifi/.auth-mode

# ---------- 7. RESTART -----------------------------------------------------
systemctl restart nifi
sleep 10
systemctl is-active nifi || true
echo "=== DONE. NiFi is restarting; give it 2-3 minutes. ==="
REMOTE_EOF

python3 - "$REMOTE" "$AUTHZ" "$KC_HOST" "$KC_PORT" "$KC_PRIVATE_IP" "$DISCOVERY" \
         "$KC_CLIENT_ID" "$KC_CLIENT_SECRET" "$OIDC_IDENTITY_CLAIM" "$INITIAL_ADMIN" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
authz = sys.argv[2]
s = s.replace("__AUTHORIZERS_XML__", authz.rstrip())
for k, v in zip(["__KC_HOST__","__KC_PORT__","__KC_PRIVATE_IP__","__DISCOVERY__",
                 "__CLIENT_ID__","__CLIENT_SECRET__","__IDENTITY_CLAIM__","__INITIAL_ADMIN__"],
                sys.argv[3:]):
    s = s.replace(k, v)
p.write_text(s)
PY
chmod 600 "$REMOTE"
bash -n "$REMOTE" || die "Generated remote script has a syntax error."
ok "Built $REMOTE"

# --------------------------------------------------------------------------
# Ship it. Base64 avoids every quoting problem SSM would otherwise cause.
# --------------------------------------------------------------------------
B64="$(base64 -w0 < "$REMOTE" 2>/dev/null || base64 < "$REMOTE" | tr -d '\n')"
log "Sending to ${NIFI_INSTANCE_ID} via SSM..."
CMD_ID="$("${A[@]}" ssm send-command --instance-ids "$NIFI_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --timeout-seconds 600 \
  --parameters "commands=[\"echo ${B64} | base64 -d > /tmp/apply-oidc.sh\",\"bash /tmp/apply-oidc.sh\",\"rm -f /tmp/apply-oidc.sh\"]" \
  --query 'Command.CommandId' --output text)"

for _ in $(seq 1 80); do
  sleep 5
  ST="$("${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$ST" in
    Success)
      "${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query StandardOutputContent --output text | sed 's/^/    /'
      ok "Applied"
      break ;;
    Failed|Cancelled|TimedOut)
      "${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query StandardErrorContent --output text | sed 's/^/    /'
      die "Command $ST. NiFi was NOT fully reconfigured - run ./04-nifi-restore.sh to roll back." ;;
  esac
done

save_state OIDC_APPLIED "true"
# Not `date -Is`: that is GNU-only and fails on macOS. This format works
# on both. (The scripts that RUN ON THE INSTANCES may use -Is freely -
# Amazon Linux has GNU coreutils.)
save_state OIDC_APPLIED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat <<EOF

  ┌──────────────────────────────────────────────────────────────┐
  │  NiFi now uses Keycloak for login                            │
  ├──────────────────────────────────────────────────────────────┤
  │  NiFi UI      https://${NIFI_PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi
  │  Sign in as   ${NIFI_ADMIN_EMAIL}
  │  Password     (NIFI_ADMIN_PASSWORD from 00-kc-config.sh)
  │
  │  Two certificate warnings are normal: one for NiFi, one for
  │  Keycloak. Both are self-signed on purpose.
  └──────────────────────────────────────────────────────────────┘

  Wait 2-3 minutes for NiFi to restart, then open the UI. You will be
  redirected to Keycloak, log in there, and land back in NiFi.

  Something wrong?   ./04-nifi-restore.sh        (back to the old login)
  Add more people?   ./05-kc-add-user.sh
  NiFi's IP changed? ./06-kc-sync-urls.sh

EOF
