#!/usr/bin/env bash
set -euo pipefail
exec > >(tee -a /var/log/nifi-oidc-apply.log) 2>&1
echo "=== NiFi OIDC switch, $(date -Is) ==="

NIFI_HOME=/opt/nifi/current
CONF="${NIFI_HOME}/conf"
PROPS="${CONF}/nifi.properties"

KC_HOST="3.84.1.135.nip.io"
KC_PORT="8443"
KC_PRIVATE_IP="10.20.2.105"
DISCOVERY="https://3.84.1.135.nip.io:8443/realms/nifi/.well-known/openid-configuration"
CLIENT_ID="nifi"
CLIENT_SECRET="55e92df856c4ee54c8a89f4d97f27254e8e80f17ad149d1c"
IDENTITY_CLAIM="email"
INITIAL_ADMIN="nifi.admin@example.com"

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
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!--
  authorizers.xml for OIDC (single sign-on) mode.

  In single-user mode NiFi used "single-user-authorizer", which simply said
  "the one account can do everything". Once real users log in through
  Keycloak, NiFi needs to know WHO may do WHAT. That is this file's job.

  Three parts, each feeding the next:

    file-user-group-provider    -> the list of users and groups (users.xml)
    file-access-policy-provider -> who may do what        (authorizations.xml)
    managed-authorizer          -> ties the two together

  "Initial Admin Identity" is the single most important line. On first start
  with no authorizations.xml, NiFi grants that identity every permission, so
  there is somebody who can log in and grant access to everyone else. The
  value must match EXACTLY what Keycloak puts in the token claim NiFi reads
  (nifi.security.user.oidc.claim.identifying.user).
-->
<authorizers>

    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Legacy Authorized Users File"></property>
        <property name="Initial User Identity 1">nifi.admin@example.com</property>
    </userGroupProvider>

    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">nifi.admin@example.com</property>
        <property name="Legacy Authorized Users File"></property>
        <!-- Node identities are only needed for a NiFi cluster. -->
        <property name="Node Identity 1"></property>
        <property name="Node Group"></property>
    </accessPolicyProvider>

    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>

</authorizers>
AUTHZ_EOF
python3 - "${CONF}/authorizers.xml" "$INITIAL_ADMIN" <<'PY'
import sys
p, admin = sys.argv[1], sys.argv[2]
s = open(p).read().replace("nifi.admin@example.com", admin)
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
