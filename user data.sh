#!/usr/bin/env bash
#
# Installs Apache NiFi ${nifi_version} in fully open mode:
#   - plain HTTP, no TLS
#   - no login provider, anonymous users get full permissions
#   - firewalld ports opened
#
set -euxo pipefail
exec > /var/log/nifi-bootstrap.log 2>&1

NIFI_VERSION="${nifi_version}"
HTTP_PORT="${http_port}"
S2S_PORT="${s2s_port}"
NIFI_DIR="/opt/nifi-$NIFI_VERSION"

# ---------------------------------------------------------------
# Packages (NiFi 1.28 runs on Java 11/17/21; 17 is the safe pick)
# ---------------------------------------------------------------
dnf -y install java-17-openjdk-headless unzip tar firewalld

# ---------------------------------------------------------------
# firewalld: open the NiFi ports
# ---------------------------------------------------------------
systemctl enable --now firewalld
firewall-cmd --permanent --add-port=$HTTP_PORT/tcp
firewall-cmd --permanent --add-port=$S2S_PORT/tcp
firewall-cmd --reload
firewall-cmd --list-ports

# ---------------------------------------------------------------
# Service account
# ---------------------------------------------------------------
id nifi >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/nifi --shell /sbin/nologin nifi

# ---------------------------------------------------------------
# Install NiFi
# ---------------------------------------------------------------
curl -fsSL --retry 5 --retry-delay 10 -o /tmp/nifi.zip \
  "https://archive.apache.org/dist/nifi/$NIFI_VERSION/nifi-$NIFI_VERSION-bin.zip"

unzip -q /tmp/nifi.zip -d /opt
rm -f /tmp/nifi.zip
ln -sfn "$NIFI_DIR" /opt/nifi
chown -R nifi:nifi "$NIFI_DIR"

PROPS="$NIFI_DIR/conf/nifi.properties"

set_prop() {
  key="$1"
  val="$2"
  if grep -q "^$key=" "$PROPS"; then
    sed -i "s|^$key=.*|$key=$val|" "$PROPS"
  else
    echo "$key=$val" >> "$PROPS"
  fi
}

# ---------------------------------------------------------------
# Hostnames NiFi will accept in the Host header
# ---------------------------------------------------------------
TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || echo "")
md() { curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1" || true; }

PRIVATE_IP=$(md local-ipv4)
PRIVATE_HOST=$(md local-hostname)
PUBLIC_IP=$(md public-ipv4)
PUBLIC_HOST=$(md public-hostname)

PROXY_HOSTS="localhost:$HTTP_PORT,127.0.0.1:$HTTP_PORT"
for h in "$PRIVATE_IP" "$PRIVATE_HOST" "$PUBLIC_IP" "$PUBLIC_HOST"; do
  if [ -n "$h" ]; then
    PROXY_HOSTS="$PROXY_HOSTS,$h,$h:$HTTP_PORT"
  fi
done

# ---------------------------------------------------------------
# Open / unauthenticated configuration
# ---------------------------------------------------------------
set_prop "nifi.web.http.host"   "0.0.0.0"
set_prop "nifi.web.http.port"   "$HTTP_PORT"
set_prop "nifi.web.https.host"  ""
set_prop "nifi.web.https.port"  ""
set_prop "nifi.web.proxy.host"  "$PROXY_HOSTS"

# No TLS material at all
set_prop "nifi.security.keystore"           ""
set_prop "nifi.security.keystoreType"       ""
set_prop "nifi.security.keystorePasswd"     ""
set_prop "nifi.security.keyPasswd"          ""
set_prop "nifi.security.truststore"         ""
set_prop "nifi.security.truststoreType"     ""
set_prop "nifi.security.truststorePasswd"   ""
set_prop "nifi.security.autoreload.enabled" "false"

# No login provider -> every request is anonymous with full authority
set_prop "nifi.security.user.login.identity.provider"      ""
set_prop "nifi.security.user.authorizer"                   "single-user-authorizer"
set_prop "nifi.security.allow.anonymous.authentication"    "true"

# Site-to-site, unsecured
set_prop "nifi.remote.input.host"          "$PRIVATE_HOST"
set_prop "nifi.remote.input.secure"        "false"
set_prop "nifi.remote.input.socket.port"   "$S2S_PORT"
set_prop "nifi.remote.input.http.enabled"  "true"

# Sensitive properties key (required since NiFi 1.14)
SENSITIVE_KEY=$(head -c 48 /dev/urandom | base64 | tr -d '=+/' | cut -c1-32)
set_prop "nifi.sensitive.props.key" "$SENSITIVE_KEY"

# Heap sizing
sed -i 's|^java.arg.2=.*|java.arg.2=-Xms2g|' "$NIFI_DIR/conf/bootstrap.conf"
sed -i 's|^java.arg.3=.*|java.arg.3=-Xmx4g|' "$NIFI_DIR/conf/bootstrap.conf"

chown -R nifi:nifi "$NIFI_DIR"

# ---------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------
cat > /etc/systemd/system/nifi.service <<'UNIT'
[Unit]
Description=Apache NiFi
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nifi
Group=nifi
ExecStart=/opt/nifi/bin/nifi.sh run
ExecStop=/opt/nifi/bin/nifi.sh stop
Restart=on-failure
RestartSec=10
LimitNOFILE=50000
LimitNPROC=10000
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now nifi

echo "NiFi $NIFI_VERSION starting on http://$PUBLIC_IP:$HTTP_PORT/nifi (no authentication)"
