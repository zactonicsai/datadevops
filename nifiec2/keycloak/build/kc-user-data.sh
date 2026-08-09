#!/usr/bin/env bash
# ==========================================================================
# kc-user-data.sh -- runs ONCE, as root, on the Keycloak instance's first
# boot. Placeholders (__LIKE_THIS__) are filled in by 01-kc-launch.sh.
# Output goes to /var/log/keycloak-bootstrap.log on the server.
# ==========================================================================
set -euxo pipefail
exec > >(tee -a /var/log/keycloak-bootstrap.log) 2>&1

# These are inserted already shell-quoted by 01-kc-launch.sh, so passwords
# containing quotes, backslashes, $ or backticks cannot break the script.
KC_VERSION=26.7.0
KC_IMAGE=quay.io/keycloak/keycloak
KC_PORT=8443
KC_ADMIN_USER=kcadmin
KC_ADMIN_PASSWORD='ChangeMe-KcAdmin-2026!'
KC_REALM=nifi
KC_CLIENT_ID=nifi
NIFI_HOST=98.92.97.11
NIFI_PORT=8443

echo "=== [1/6] Packages: docker + openssl ==="
dnf -y update --security || true
dnf -y install docker openssl
systemctl enable --now docker

echo "=== [2/6] Work out our own hostname ==="
# Ask the instance metadata service (IMDSv2) for our addresses.
TOKEN="$(curl -s -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
PUBLIC_IP="$(meta public-ipv4)"
PRIVATE_IP="$(meta local-ipv4)"

# nip.io is a free public DNS service: any name of the form
# <ip-address>.nip.io resolves to that IP address. It gives us a real
# hostname without buying a domain, which OIDC needs because the issuer in
# the token has to match the URL exactly.
KC_HOST="${PUBLIC_IP}.nip.io"
echo "$KC_HOST" > /opt/kc-host.txt
echo "Keycloak hostname will be ${KC_HOST}"

echo "=== [3/6] Self-signed TLS certificate ==="
mkdir -p /opt/keycloak/certs /opt/keycloak/data/import
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout /opt/keycloak/certs/server.key.pem \
  -out    /opt/keycloak/certs/server.crt.pem \
  -subj "/CN=${KC_HOST}/O=NiFi Lab" \
  -addext "subjectAltName=DNS:${KC_HOST},DNS:localhost,IP:${PUBLIC_IP},IP:${PRIVATE_IP}" \
  -addext "basicConstraints=CA:FALSE" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
# NiFi will need to trust this certificate; 03-nifi-oidc.sh fetches it.
openssl x509 -in /opt/keycloak/certs/server.crt.pem -noout -text | head -20

echo "=== [4/6] Realm import file ==="
# Keycloak reads every *.json in /opt/keycloak/data/import when started with
# --import-realm, and creates the realm only if it does not already exist.
# This file was fully rendered by 01-kc-launch.sh using a real JSON encoder,
# so nothing needs substituting here - we only check it parses before
# handing it to Keycloak, because a malformed file makes Keycloak exit with
# a stack trace that is far harder to read.
cat > /opt/keycloak/data/import/realm-nifi.json <<'REALM_JSON'
{
  "realm": "nifi",
  "enabled": true,
  "displayName": "NiFi Single Sign-On",
  "sslRequired": "external",
  "registrationAllowed": false,
  "resetPasswordAllowed": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,
  "accessTokenLifespan": 300,
  "ssoSessionIdleTimeout": 1800,
  "ssoSessionMaxLifespan": 36000,
  "clients": [
    {
      "clientId": "nifi",
      "name": "Apache NiFi",
      "description": "Apache NiFi dataflow UI",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "55e92df856c4ee54c8a89f4d97f27254e8e80f17ad149d1c",
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "frontchannelLogout": true,
      "redirectUris": [
        "https://98.92.97.11:8443/nifi-api/access/oidc/callback",
        "https://98.92.97.11:8443/nifi/*"
      ],
      "webOrigins": [
        "https://98.92.97.11:8443"
      ],
      "attributes": {
        "post.logout.redirect.uris": "https://98.92.97.11:8443/nifi/*"
      }
    }
  ],
  "roles": {
    "realm": [
      {
        "name": "nifi-admin",
        "description": "Full control of the NiFi flow"
      },
      {
        "name": "nifi-user",
        "description": "Read and operate the NiFi flow"
      }
    ]
  },
  "groups": [
    {
      "name": "nifi-admins"
    },
    {
      "name": "nifi-users"
    }
  ],
  "users": [
    {
      "username": "nifiadmin",
      "email": "nifi.admin@example.com",
      "emailVerified": true,
      "firstName": "NiFi",
      "lastName": "Admin",
      "enabled": true,
      "groups": [
        "/nifi-admins"
      ],
      "credentials": [
        {
          "type": "password",
          "value": "ChangeMe-NiFiAdmin-2026!",
          "temporary": false
        }
      ]
    }
  ]
}
REALM_JSON
python3 -c "import json,sys; d=json.load(open('/opt/keycloak/data/import/realm-nifi.json')); \
print('realm file is valid JSON: realm=%s, clients=%d, users=%d' % (d['realm'], len(d.get('clients',[])), len(d.get('users',[]))))"

# The Keycloak container runs as user id 1000.
chown -R 1000:1000 /opt/keycloak
chmod 600 /opt/keycloak/certs/server.key.pem

echo "=== [5/6] Start Keycloak ==="
docker pull "${KC_IMAGE}:${KC_VERSION}"
docker rm -f keycloak 2>/dev/null || true
docker run -d --name keycloak --restart unless-stopped \
  -p "${KC_PORT}:8443" \
  -p 127.0.0.1:9000:9000 \
  -v /opt/keycloak/certs:/opt/keycloak/certs:ro \
  -v /opt/keycloak/data:/opt/keycloak/data \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="${KC_ADMIN_USER}" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}" \
  "${KC_IMAGE}:${KC_VERSION}" \
  start \
    --import-realm \
    --db=dev-file \
    --hostname="https://${KC_HOST}:${KC_PORT}" \
    --https-certificate-file=/opt/keycloak/certs/server.crt.pem \
    --https-certificate-key-file=/opt/keycloak/certs/server.key.pem \
    --health-enabled=true \
    --http-management-port=9000

echo "=== [6/6] Wait for readiness ==="
READY=false
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:9000/health/ready >/dev/null 2>&1; then READY=true; break; fi
  sleep 5
done
$READY && echo "Keycloak is READY" || { echo "NOT READY - last 50 log lines:"; docker logs --tail 50 keycloak; }

# A tiny helper so you can restart Keycloak by hand later.
cat > /usr/local/bin/kc <<'HELPER'
#!/usr/bin/env bash
case "${1:-status}" in
  status)  docker ps --filter name=keycloak --format '{{.Status}}' ;;
  logs)    docker logs --tail "${2:-100}" -f keycloak ;;
  restart) docker restart keycloak ;;
  host)    cat /opt/kc-host.txt ;;
  *) echo "usage: kc {status|logs [n]|restart|host}" ;;
esac
HELPER
chmod +x /usr/local/bin/kc

touch /opt/keycloak/.bootstrap-complete
echo "=== BOOTSTRAP COMPLETE at $(date -Is) ==="
echo "Admin console: https://${KC_HOST}:${KC_PORT}/admin/"
echo "Discovery URL: https://${KC_HOST}:${KC_PORT}/realms/${KC_REALM}/.well-known/openid-configuration"
