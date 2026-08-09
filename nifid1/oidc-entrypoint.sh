#!/bin/bash
# Configures Apache NiFi 1.28 for HTTPS + Keycloak OIDC, then starts it.
# Idempotent: safe to run on every container start.
set -euo pipefail

NIFI_HOME="${NIFI_HOME:-/opt/nifi/nifi-current}"
CONF="${NIFI_HOME}/conf"
PROPS="${CONF}/nifi.properties"

KEYSTORE="${CONF}/keystore.p12"
TRUSTSTORE="${CONF}/truststore.p12"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:?KEYSTORE_PASSWORD is required}"
NIFI_ADMIN_IDENTITY="${NIFI_ADMIN_IDENTITY:?NIFI_ADMIN_IDENTITY is required}"
NIFI_SENSITIVE_PROPS_KEY="${NIFI_SENSITIVE_PROPS_KEY:?NIFI_SENSITIVE_PROPS_KEY is required}"

KEYTOOL="$(command -v keytool || echo "${JAVA_HOME:-/opt/java/openjdk}/bin/keytool")"

log() { echo "[oidc-entrypoint] $*"; }

# --- 1. Self-signed TLS cert (NiFi refuses OIDC over plain HTTP) --------------
if [ ! -f "${KEYSTORE}" ]; then
  log "generating self-signed keystore/truststore"
  "${KEYTOOL}" -genkeypair \
    -alias nifi-key -keyalg RSA -keysize 2048 -validity 3650 \
    -dname "CN=localhost, OU=NiFi, O=Local, C=US" \
    -ext "SAN=dns:localhost,dns:nifi,ip:127.0.0.1" \
    -keystore "${KEYSTORE}" -storetype PKCS12 \
    -storepass "${KEYSTORE_PASSWORD}" -keypass "${KEYSTORE_PASSWORD}"

  "${KEYTOOL}" -exportcert -rfc -alias nifi-key \
    -keystore "${KEYSTORE}" -storetype PKCS12 -storepass "${KEYSTORE_PASSWORD}" \
    -file /tmp/nifi-cert.pem

  "${KEYTOOL}" -importcert -noprompt -alias nifi-cert \
    -file /tmp/nifi-cert.pem \
    -keystore "${TRUSTSTORE}" -storetype PKCS12 -storepass "${KEYSTORE_PASSWORD}"

  rm -f /tmp/nifi-cert.pem
else
  log "keystore already present, reusing it"
fi

# --- 2. nifi.properties ------------------------------------------------------
set_prop() {
  local key="$1" value="${2:-}" key_re esc
  key_re="$(printf '%s' "${key}" | sed 's/[.[\*^$]/\\&/g')"
  esc="$(printf '%s' "${value}" | sed 's/[\/&]/\\&/g')"
  if grep -q "^${key_re}=" "${PROPS}"; then
    sed -i "s/^${key_re}=.*/${key}=${esc}/" "${PROPS}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${PROPS}"
  fi
}

log "writing nifi.properties"
# HTTP off, HTTPS on
set_prop nifi.web.http.host ""
set_prop nifi.web.http.port ""
set_prop nifi.web.https.host "0.0.0.0"
set_prop nifi.web.https.port "${NIFI_WEB_HTTPS_PORT:-8443}"
set_prop nifi.web.proxy.host "${NIFI_WEB_PROXY_HOST:-localhost:8443}"
set_prop nifi.remote.input.secure "true"

# TLS
set_prop nifi.security.keystore "./conf/keystore.p12"
set_prop nifi.security.keystoreType "PKCS12"
set_prop nifi.security.keystorePasswd "${KEYSTORE_PASSWORD}"
set_prop nifi.security.keyPasswd "${KEYSTORE_PASSWORD}"
set_prop nifi.security.truststore "./conf/truststore.p12"
set_prop nifi.security.truststoreType "PKCS12"
set_prop nifi.security.truststorePasswd "${KEYSTORE_PASSWORD}"

# Authentication: OIDC only. NiFi refuses to start if a login identity
# provider (e.g. single-user) or Knox SSO is configured at the same time.
set_prop nifi.security.user.login.identity.provider ""
set_prop nifi.security.user.knox.url ""
set_prop nifi.security.user.authorizer "managed-authorizer"
set_prop nifi.security.allow.anonymous.authentication "false"

set_prop nifi.security.user.oidc.discovery.url "${OIDC_DISCOVERY_URL}"
set_prop nifi.security.user.oidc.client.id "${OIDC_CLIENT_ID}"
set_prop nifi.security.user.oidc.client.secret "${OIDC_CLIENT_SECRET}"
set_prop nifi.security.user.oidc.claim.identifying.user "email"
set_prop nifi.security.user.oidc.connect.timeout "10 secs"
set_prop nifi.security.user.oidc.read.timeout "10 secs"

set_prop nifi.sensitive.props.key "${NIFI_SENSITIVE_PROPS_KEY}"

# --- 3. authorizers.xml ------------------------------------------------------
# Initial identities are only applied the first time, i.e. while
# users.xml / authorizations.xml do not yet exist.
log "writing authorizers.xml (initial admin: ${NIFI_ADMIN_IDENTITY})"
cat > "${CONF}/authorizers.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizers>
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Legacy Authorized Users File"></property>
        <property name="Initial User Identity 1">${NIFI_ADMIN_IDENTITY}</property>
    </userGroupProvider>
    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">${NIFI_ADMIN_IDENTITY}</property>
        <property name="Legacy Authorized Users File"></property>
        <property name="Node Identity 1"></property>
        <property name="Node Group"></property>
    </accessPolicyProvider>
    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>
</authorizers>
EOF

log "starting NiFi"
exec "${NIFI_HOME}/bin/nifi.sh" run
