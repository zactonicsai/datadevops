#!/usr/bin/env bash
# ==========================================================================
# 04-nifi-restore.sh -- Put NiFi back exactly as it was before Keycloak.
#
# 03-nifi-oidc.sh copied every file it was going to touch into
# /opt/nifi/backups/pre-oidc-<timestamp>/ and wrote a MANIFEST listing them.
# This script copies those files back over the live ones, throws away the
# files OIDC mode created, and restarts NiFi. The old
# username-and-password login works again.
#
#   ./04-nifi-restore.sh                 restore the most recent backup
#   ./04-nifi-restore.sh --list          show every backup on the server
#   ./04-nifi-restore.sh <backup-path>   restore one specific backup
#   ./04-nifi-restore.sh --set-password  also reset the single-user password
#
# Keycloak itself is left running. To remove it too: ./99-kc-teardown.sh
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state

A=(aws --region "$AWS_REGION")
[ -n "${NIFI_INSTANCE_ID:-}" ] || die "NiFi instance not found in ../scripts/.deploy-state"

# Small helper: run a command on the NiFi box and print its output.
remote() {
  local cmd_id
  cmd_id="$("${A[@]}" ssm send-command --instance-ids "$NIFI_INSTANCE_ID" \
    --document-name AWS-RunShellScript --timeout-seconds 600 \
    --parameters "commands=[\"$1\"]" --query 'Command.CommandId' --output text)" || return 1
  for _ in $(seq 1 80); do
    sleep 4
    case "$("${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
             --instance-id "$NIFI_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)" in
      Success)
        "${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
          --instance-id "$NIFI_INSTANCE_ID" --query StandardOutputContent --output text
        return 0 ;;
      Failed|Cancelled|TimedOut)
        "${A[@]}" ssm get-command-invocation --command-id "$cmd_id" \
          --instance-id "$NIFI_INSTANCE_ID" --query StandardErrorContent --output text >&2
        return 1 ;;
    esac
  done
  return 1
}

# --------------------------------------------------------------------------
# --list: show what is available to restore
# --------------------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  log "Backups on the NiFi server:"
  remote "ls -1dt /opt/nifi/backups/pre-oidc-* 2>/dev/null | while read d; do echo \\\"\$d  ($(echo)\$(cat \$d/AUTH_MODE 2>/dev/null))  files: \$(tr '\\\\n' ' ' < \$d/MANIFEST 2>/dev/null)\\\"; done || echo 'none found'" \
    | sed 's/^/    /'
  echo
  log "Current mode: $(remote 'cat /opt/nifi/.auth-mode 2>/dev/null || echo single-user' | tr -d '\r\n')"
  exit 0
fi

SET_PASSWORD=false
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --set-password) SET_PASSWORD=true ;;
    /*)             TARGET="$arg" ;;
    *) die "Unknown option: $arg  (use --list, --set-password, or a /opt/nifi/backups/... path)" ;;
  esac
done

cat <<PLAN

  Restore NiFi to its pre-Keycloak login.

    Instance  ${NIFI_INSTANCE_ID}
    Backup    ${TARGET:-<most recent pre-oidc backup>}

  What happens:
    1. Copy the saved nifi.properties, authorizers.xml and
       login-identity-providers.xml back over the live files. Every OIDC
       setting disappears with them, because the saved copies never had any.
    2. Delete users.xml and authorizations.xml (created by OIDC mode), then
       restore the originals if the backup had any.
    3. Remove Keycloak's certificate from NiFi's truststore and drop the
       hosts entry. Neither would break anything, but tidy is better.
    4. Restart NiFi.

  Afterwards you log in again with the username and password from
  ../scripts/00-config.sh (NIFI_USERNAME / NIFI_PASSWORD).

PLAN

read -r -p "  Type 'restore' to continue: " ANSWER
[ "$ANSWER" = "restore" ] || die "Aborted. Nothing was changed."

# --------------------------------------------------------------------------
# Build the restore script that runs on the NiFi box.
# --------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
REMOTE="${BUILD_DIR}/nifi-restore.sh"

cat > "$REMOTE" <<'REMOTE_EOF'
#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/nifi-oidc-restore.log) 2>&1
echo "=== NiFi auth restore, $(date -Is) ==="

NIFI_HOME=/opt/nifi/current
CONF="${NIFI_HOME}/conf"
PROPS="${CONF}/nifi.properties"
KC_HOST="__KC_HOST__"
TARGET="__TARGET__"

# ---------- 0. Which backup? ----------------------------------------------
if [ -z "$TARGET" ]; then
  if [ -f /opt/nifi/backups/LATEST_PRE_OIDC ]; then
    TARGET="$(cat /opt/nifi/backups/LATEST_PRE_OIDC)"
  else
    TARGET="$(ls -1dt /opt/nifi/backups/pre-oidc-* 2>/dev/null | head -1)"
  fi
fi
[ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "No backup directory found - cannot restore."; exit 1; }
echo "restoring from: $TARGET"
cat "${TARGET}/MANIFEST" 2>/dev/null | sed 's/^/  will restore: /'

# ---------- 1. Safety net: snapshot the CURRENT (OIDC) config -------------
# So that rolling back the rollback is also possible.
STAMP="$(date +%Y%m%d-%H%M%S)"
CUR="/opt/nifi/backups/pre-restore-${STAMP}"
mkdir -p "$CUR"
for f in nifi.properties authorizers.xml login-identity-providers.xml users.xml authorizations.xml; do
  [ -f "${CONF}/${f}" ] && cp -a "${CONF}/${f}" "${CUR}/${f}"
done
echo "current config saved to $CUR"

# ---------- 2. Stop NiFi before swapping its configuration -----------------
systemctl stop nifi || true
sleep 5

# ---------- 3. Remove the files OIDC mode generated ------------------------
rm -f "${CONF}/users.xml" "${CONF}/authorizations.xml"

# ---------- 4. Copy the originals back -------------------------------------
while read -r f; do
  [ -z "$f" ] && continue
  if [ -f "${TARGET}/${f}" ]; then
    cp -a "${TARGET}/${f}" "${CONF}/${f}"
    echo "  restored ${f}"
  fi
done < "${TARGET}/MANIFEST"

# ---------- 5. Undo the trust and hosts changes ----------------------------
TS_REL="$(grep -E '^nifi\.security\.truststore=' "$PROPS" | cut -d= -f2-)"
TS_PW="$(grep -E '^nifi\.security\.truststorePasswd=' "$PROPS" | cut -d= -f2-)"
TS_TYPE="$(grep -E '^nifi\.security\.truststoreType=' "$PROPS" | cut -d= -f2-)"
TS_ABS="${TS_REL/#.\//${NIFI_HOME}/}"
KEYTOOL="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")/bin/keytool"
if [ -n "$TS_ABS" ] && [ -f "$TS_ABS" ]; then
  "$KEYTOOL" -delete -alias keycloak-nifi -keystore "$TS_ABS" \
    -storepass "$TS_PW" -storetype "${TS_TYPE:-PKCS12}" 2>/dev/null \
    && echo "  removed keycloak-nifi from the truststore" \
    || echo "  (no keycloak-nifi entry in the truststore)"
fi
[ -n "$KC_HOST" ] && sed -i "/ ${KC_HOST}\$/d" /etc/hosts && echo "  hosts entry removed"

# ---------- 6. Confirm the OIDC settings really are gone -------------------
if grep -qE '^nifi\.security\.user\.oidc\.discovery\.url=.+' "$PROPS"; then
  echo "  WARNING: a discovery URL is still set - clearing it by hand"
  sed -i 's|^nifi.security.user.oidc.discovery.url=.*|nifi.security.user.oidc.discovery.url=|' "$PROPS"
fi
echo "  login.identity.provider = $(grep -E '^nifi\.security\.user\.login\.identity\.provider=' "$PROPS" | cut -d= -f2-)"
echo "  authorizer              = $(grep -E '^nifi\.security\.user\.authorizer=' "$PROPS" | cut -d= -f2-)"

chown -R nifi:nifi "$CONF"
echo "single-user" > /opt/nifi/.auth-mode

# ---------- 7. Optional: reset the single-user password --------------------
if [ -n "__NEW_PASSWORD__" ]; then
  JH="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  runuser -u nifi -- env JAVA_HOME="$JH" "${NIFI_HOME}/bin/nifi.sh" \
    set-single-user-credentials "__NEW_USERNAME__" "__NEW_PASSWORD__"
  echo "  single-user credentials reset for __NEW_USERNAME__"
fi

# ---------- 8. Start ------------------------------------------------------
systemctl start nifi
sleep 10
systemctl is-active nifi || true
echo "=== RESTORE COMPLETE. NiFi is starting; allow 2-3 minutes. ==="
REMOTE_EOF

NEW_USER=""; NEW_PASS=""
if $SET_PASSWORD; then
  NEW_USER="$NIFI_USERNAME"; NEW_PASS="$NIFI_PASSWORD"
  [ "${#NEW_PASS}" -ge 12 ] || die "NIFI_PASSWORD in ../scripts/00-config.sh is under 12 characters."
fi

python3 - "$REMOTE" "${KC_HOST:-}" "$TARGET" "$NEW_USER" "$NEW_PASS" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
for k, v in zip(["__KC_HOST__","__TARGET__","__NEW_USERNAME__","__NEW_PASSWORD__"], sys.argv[2:]):
    s = s.replace(k, v)
p.write_text(s)
PY
chmod 600 "$REMOTE"
bash -n "$REMOTE" || die "Generated restore script has a syntax error."

B64="$(base64 -w0 < "$REMOTE" 2>/dev/null || base64 < "$REMOTE" | tr -d '\n')"
log "Sending restore to ${NIFI_INSTANCE_ID} ..."
CMD_ID="$("${A[@]}" ssm send-command --instance-ids "$NIFI_INSTANCE_ID" \
  --document-name AWS-RunShellScript --timeout-seconds 600 \
  --parameters "commands=[\"echo ${B64} | base64 -d > /tmp/restore.sh\",\"bash /tmp/restore.sh\",\"rm -f /tmp/restore.sh\"]" \
  --query 'Command.CommandId' --output text)"

for _ in $(seq 1 80); do
  sleep 5
  ST="$("${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  case "$ST" in
    Success)
      "${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query StandardOutputContent --output text | sed 's/^/    /'
      ok "Restored"; break ;;
    Failed|Cancelled|TimedOut)
      "${A[@]}" ssm get-command-invocation --command-id "$CMD_ID" \
        --instance-id "$NIFI_INSTANCE_ID" --query StandardErrorContent --output text | sed 's/^/    /'
      die "Restore $ST. Log in over SSM and inspect /var/log/nifi-oidc-restore.log" ;;
  esac
done

save_state OIDC_APPLIED "false"

cat <<EOF

  NiFi is back on its original login.

    URL       https://${NIFI_PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi
    Username  ${NIFI_USERNAME}
    Password  (NIFI_PASSWORD from ../scripts/00-config.sh)

  Forgot the password?  cd ../scripts && ./05-set-credentials.sh ${NIFI_USERNAME} <new-password>
  Switch back to SSO?   ./03-nifi-oidc.sh
  Remove Keycloak too?  ./99-kc-teardown.sh

EOF
