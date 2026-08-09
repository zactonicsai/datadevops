# Manual Guide: Connecting an Existing NiFi to an Existing Keycloak

No scripts. Every command is typed by a person, and every change is explained
before you make it.

**Assumes:** NiFi 1.x is already running, and Keycloak already exists —
probably run by a different team. You need to ask them for some things and
create some others.

**Downtime:** one NiFi restart, 2–4 minutes, at the very end.

---

## Part 0 — How this guide is laid out

| Part | What you do | NiFi is |
| --- | --- | --- |
| 1 | Collect information | running |
| 2 | Create things in Keycloak | running |
| 3 | Prove Keycloak works, before touching NiFi | running |
| 4 | Back up NiFi | running |
| 5 | Change NiFi's files | running (changes not yet active) |
| 6 | Restart — **the only outage** | **down 2–4 min** |
| 7 | Verify | running |
| 8 | Back out, if needed | down 2–4 min |

Parts 1 through 5 change nothing about how NiFi behaves. You can stop at the
end of Part 5 and walk away; NiFi carries on exactly as before, because it
only reads these files when it starts.

Throughout, replace these with your real values:

```
NIFI_URL      https://nifi.example.com:8443
KC_URL        https://sso.example.com
KC_REALM      nifi
NIFI_HOME     /opt/nifi/current
```

---

## Part 1 — Information to collect

### 1.1 From your own NiFi server

Log in and run each command. Write the answers in the table in Appendix A.

```bash
cd /opt/nifi/current

# Which login system is in use right now? This decides a critical step later.
grep -E '^nifi\.security\.user\.(authorizer|login\.identity\.provider)=' conf/nifi.properties

# Is HTTPS already on? OIDC requires it.
grep -E '^nifi\.web\.https\.(host|port)=' conf/nifi.properties

# What hostnames does NiFi accept? You may need to add one.
grep -E '^nifi\.web\.proxy\.host=' conf/nifi.properties

# Where is the truststore, and what is its password?
grep -E '^nifi\.security\.truststore' conf/nifi.properties

# Single server or cluster?
grep -E '^nifi\.cluster\.is\.node=' conf/nifi.properties

# Which OS user runs NiFi? Files must stay owned by them.
ps -o user= -p "$(pgrep -f 'org.apache.nifi.NiFi' | head -1)"

# Which Java? You need its keytool later.
readlink -f "$(command -v java)"
```

The first command matters most:

| Result | Meaning | Later effect |
| --- | --- | --- |
| `authorizer=single-user-authorizer` | One shared login | **Case A** — you will delete `users.xml` and `authorizations.xml` |
| `authorizer=managed-authorizer` | Real users and permissions already exist | **Case B** — you must **KEEP** those two files |

> ⚠️ In Case B, deleting `authorizations.xml` destroys every permission your
> team has set up. There is no undo except your backup. Read 5.5 carefully.

### 1.2 Ask the Keycloak team for these

Send this list. Every item is needed; none of it is secret except the last.

| # | Ask for | Looks like | Why you need it |
| --- | --- | --- | --- |
| 1 | The base URL of Keycloak | `https://sso.example.com` | Everything else is built from it |
| 2 | Which **realm** to use | `nifi`, or an existing `corp` | A realm is one set of users. Yours must contain the people who will use NiFi |
| 3 | The **issuer** string for that realm | `https://sso.example.com/realms/corp` | Must match NiFi's config exactly, character for character |
| 4 | Whether **confidential clients** are allowed | yes/no | NiFi needs a client with a secret. Some teams only permit public clients — that will not work |
| 5 | Who may create a client, and how | "raise a ticket" / "you have admin on realm `corp`" | Decides whether Part 2 is you or them |
| 6 | Is the **email** claim in tokens, and is it filled in for everyone? | yes/no | If emails are blank, use `preferred_username` as the identity instead |
| 7 | The **CA certificate** of Keycloak's TLS cert, or the name of the CA | a `.pem` file, or "DigiCert" | If it is a public CA, NiFi already trusts it. If internal or self-signed, you must import it |
| 8 | **SSO session timeouts** | idle 30 min / max 10 h | So you can tell your users when they will be asked to log in again |
| 9 | Whether MFA is enforced | yes/no | Affects your rollout note to the team |
| 10 | The **client secret**, once the client exists | a long random string | Goes in `nifi.properties`. Treat as a password — send it over a secret channel, not email |

### 1.3 What must be created in Keycloak

Whether you do this or they do, these objects must exist:

| Object | Name | New or reuse |
| --- | --- | --- |
| Realm | `nifi` or an existing one | **Reuse** if the company already has one with your people in it |
| Client | `nifi` | **Create.** One per application |
| Client secret | generated | **Create** (Keycloak generates it) |
| Redirect URIs on that client | 2 entries | **Create** |
| Web origins on that client | 1 entry | **Create** |
| `email` scope on the client | default scope | Usually already there — **verify** |
| Users | your team | **Reuse** if they exist; create only for testing |
| Groups | `nifi-admins`, `nifi-users` | Optional; useful later |

**New realm or reuse an existing one?**

| Option | Pros | Cons |
| --- | --- | --- |
| Reuse the company realm | People already have accounts; joiners and leavers handled for you | You probably cannot change realm-wide settings; you need permission to add a client |
| New realm just for NiFi | Full control of settings and sessions | You maintain a second list of users, or set up federation again |

For most teams with an existing Keycloak: **reuse the realm, create your own
client.** A client is small and isolated; a realm is not.

### 1.4 Decide the identity claim — do this before anything else

NiFi stores each person as **one string of text**, taken from one claim.

| Choice | Ana becomes | Notes |
| --- | --- | --- |
| `email` | `ana@example.com` | Usual choice. Unique, and people know their own |
| `preferred_username` | `ana` | Use when emails are missing or not unique |

It is **case sensitive**, and changing it later means re-creating every user
and every permission in NiFi. Decide now, write it down, tell the team.

---

## Part 2 — Create the client in Keycloak

Three ways to do the same thing. Pick one. The click-path is easiest for a
first time; the command-line versions are better because you can paste them
into a ticket or a change record.

### 2.1 Option A — the admin console (clicking)

1. Sign in at `https://sso.example.com/admin/`
2. Top-left realm selector → choose your realm (`corp` or `nifi`)
3. **Clients → Create client**
4. Page 1 — General settings:
   - Client type: **OpenID Connect**
   - Client ID: `nifi`
   - Name: `Apache NiFi`
   - → Next
5. Page 2 — Capability config:
   - **Client authentication: On** ← this is the important one. On means
     "confidential", meaning it gets a secret. Off will not work with NiFi.
   - Authorization: Off
   - Authentication flow: tick **Standard flow** only
   - Untick Direct access grants, Implicit flow, Service accounts roles
   - → Next
6. Page 3 — Login settings:
   - Root URL: `https://nifi.example.com:8443`
   - Valid redirect URIs — add **two** entries:
     - `https://nifi.example.com:8443/nifi-api/access/oidc/callback`
     - `https://nifi.example.com:8443/nifi/*`
   - Valid post logout redirect URIs: `https://nifi.example.com:8443/nifi/*`
   - Web origins: `https://nifi.example.com:8443`
   - → Save
7. Open the **Credentials** tab → copy the **Client secret**
8. **Settings → Logout settings → Front channel logout: On**

### 2.2 Option B — `kcadm.sh` (Keycloak's own command-line tool)

Runs on any machine with the Keycloak distribution, or inside the Keycloak
container: `docker exec -it keycloak /opt/keycloak/bin/kcadm.sh …`

```bash
KCADM=/opt/keycloak/bin/kcadm.sh

# 1. Log in. It stores a token in ~/.keycloak/kcadm.config.
#    Leave off --password and it prompts, so the password stays out of your
#    shell history.
$KCADM config credentials \
  --server https://sso.example.com \
  --realm master \
  --user admin

# If Keycloak uses a private CA, point kcadm at a truststore first:
#   $KCADM config truststore --trustpass <pass> /path/to/truststore.jks

# 2. Confirm the realm exists and note the exact spelling
$KCADM get realms --fields realm

# 3. Create the client. Each -s sets one field.
$KCADM create clients -r nifi \
  -s clientId=nifi \
  -s name='Apache NiFi' \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s standardFlowEnabled=true \
  -s implicitFlowEnabled=false \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=false \
  -s frontchannelLogout=true \
  -s 'rootUrl=https://nifi.example.com:8443' \
  -s 'redirectUris=["https://nifi.example.com:8443/nifi-api/access/oidc/callback","https://nifi.example.com:8443/nifi/*"]' \
  -s 'webOrigins=["https://nifi.example.com:8443"]' \
  -s 'attributes."post.logout.redirect.uris"=https://nifi.example.com:8443/nifi/*'

# 4. Find the client's internal id (a UUID, different from the clientId)
CID=$($KCADM get clients -r nifi -q clientId=nifi --fields id --format csv --noquotes)
echo "internal id: $CID"

# 5. Read the generated secret. WRITE THIS DOWN somewhere safe.
$KCADM get clients/$CID/client-secret -r nifi

# 6. Read the whole client back and check it
$KCADM get clients/$CID -r nifi \
  --fields clientId,publicClient,standardFlowEnabled,redirectUris,webOrigins
```

### 2.3 Option C — raw REST with `curl`

Useful when you have no Keycloak binaries at all.

```bash
KC=https://sso.example.com
REALM=nifi

# 1. Get an admin token. admin-cli is Keycloak's built-in client for this.
#    read -s keeps the password off the screen and out of history.
read -s -p "Keycloak admin password: " KCPW; echo
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password \
  -d username=admin --data-urlencode "password=$KCPW" \
  | jq -r .access_token)
[ "$TOKEN" != "null" ] && echo "got a token" || echo "LOGIN FAILED"

# 2. Create the client
curl -s -X POST "$KC/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "nifi",
    "name": "Apache NiFi",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "frontchannelLogout": true,
    "rootUrl": "https://nifi.example.com:8443",
    "redirectUris": [
      "https://nifi.example.com:8443/nifi-api/access/oidc/callback",
      "https://nifi.example.com:8443/nifi/*"
    ],
    "webOrigins": ["https://nifi.example.com:8443"],
    "attributes": {
      "post.logout.redirect.uris": "https://nifi.example.com:8443/nifi/*"
    }
  }' -w '\nHTTP %{http_code}\n'
# 201 = created.  409 = a client with that ID already exists.

# 3. Get the internal id
CID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients?clientId=nifi" | jq -r '.[0].id')
echo "internal id: $CID"

# 4. Get the secret
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID/client-secret" | jq -r .value

# 5. Read it back and eyeball it
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID" \
  | jq '{clientId, publicClient, standardFlowEnabled, redirectUris, webOrigins}'
```

### 2.4 What every field means, and what breaks

| Field | Set to | If it is wrong |
| --- | --- | --- |
| `clientId` | `nifi` | Must equal `nifi.security.user.oidc.client.id`. Mismatch → Keycloak says "unknown client" |
| `publicClient` | `false` | `true` means no secret exists; NiFi's step-5 call is rejected |
| `standardFlowEnabled` | `true` | `false` and login does nothing at all |
| `directAccessGrantsEnabled` | `false` | `true` lets anyone swap a username and password for a token outside the browser. Not needed, so turn it off |
| `redirectUris` | the two exact URLs | Keycloak only returns people to addresses on this list. Wrong → `Invalid parameter: redirect_uri`. **Include the port.** Never use bare `*` — anyone could steal the login code |
| `webOrigins` | `https://nifi.example.com:8443` | Browser CORS rules; blank can cause quiet failures |
| `frontchannelLogout` | `true` | Signing out of NiFi also ends the Keycloak session |
| Client secret | generated | Wrong value → `invalid_client` in the Keycloak log |

### 2.5 Check the email claim is actually there

NiFi reads a claim that only appears if the matching scope is assigned.

```bash
# Which scopes does the client send by default?
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID/default-client-scopes" | jq -r '.[].name'
# You want to see: email, profile, roles, web-origins
```

If `email` is missing:

```bash
SCOPE_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/client-scopes" | jq -r '.[]|select(.name=="email")|.id')
curl -s -X PUT -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID/default-client-scopes/$SCOPE_ID" \
  -w 'HTTP %{http_code}\n'
```

Also make sure each user actually **has** an email, and that **Email
verified** is On. A blank email means NiFi cannot work out who they are, and
the login fails at the very last step.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/users?username=ana&exact=true" \
  | jq '.[]|{username,email,emailVerified,enabled}'
```

---

## Part 3 — Prove Keycloak works before touching NiFi

Do not skip this. Every minute spent here saves ten during the outage.

### 3.1 The discovery document

```bash
curl -s "$KC/realms/$REALM/.well-known/openid-configuration" | jq .
```

Check three things:

```bash
curl -s "$KC/realms/$REALM/.well-known/openid-configuration" \
  | jq '{issuer, authorization_endpoint, token_endpoint}'
```

- `issuer` must be **exactly** what you will put in NiFi. `http` vs `https`,
  a port, a trailing slash — any difference and NiFi rejects every token.
- If this returns nothing, the realm name is wrong.

### 3.2 The same test, run from the NiFi server

This is the step-5 back-channel path, and the one people forget. A working
browser proves nothing about it.

```bash
ssh nifi-server
curl -sv "https://sso.example.com/realms/nifi/.well-known/openid-configuration" 2>&1 | tail -20
```

| What you see | Meaning | Fix |
| --- | --- | --- |
| JSON | Good | — |
| `Connection timed out` | Firewall or security group | Open the port from NiFi to Keycloak |
| `Could not resolve host` | DNS | Add DNS, or a line in `/etc/hosts` |
| `certificate verify failed` | Private or self-signed CA | Part 5.3 fixes it for NiFi; for this test add `-k` |

### 3.3 Do one full login by hand

This proves the client, the secret, the redirect URI and the email claim all
work — before NiFi is involved at all.

**Step 1.** Paste this into a browser, all one line:

```
https://sso.example.com/realms/nifi/protocol/openid-connect/auth?client_id=nifi&response_type=code&scope=openid%20email%20profile&redirect_uri=https%3A%2F%2Fnifi.example.com%3A8443%2Fnifi-api%2Faccess%2Foidc%2Fcallback&state=manualtest
```

**Step 2.** Log in as a test user. The browser lands on NiFi and shows an
error — expected, NiFi is not configured yet. Look at the **address bar**:

```
https://nifi.example.com:8443/nifi-api/access/oidc/callback?state=manualtest&code=abc123.def456.ghi789
```

Copy the `code` value. It is valid for about a minute and can be used once.

**Step 3.** Trade the code for tokens, quickly:

```bash
CODE='paste-the-code-here'
SECRET='paste-the-client-secret-here'

curl -s -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=authorization_code \
  -d client_id=nifi \
  --data-urlencode "client_secret=$SECRET" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=https://nifi.example.com:8443/nifi-api/access/oidc/callback" \
  > /tmp/tokens.json

jq -r 'keys' /tmp/tokens.json     # expect access_token, id_token, refresh_token
```

**Step 4.** Look inside the ID token. It is three base64 parts separated by
dots; the middle one holds the claims:

```bash
jq -r .id_token /tmp/tokens.json \
  | cut -d. -f2 \
  | python3 -c 'import sys,base64,json; s=sys.stdin.read().strip(); \
      print(json.dumps(json.loads(base64.urlsafe_b64decode(s + "="*(-len(s)%4))), indent=2))'
```

You are looking for:

```json
{
  "iss": "https://sso.example.com/realms/nifi",
  "aud": "nifi",
  "preferred_username": "ana",
  "email": "ana@example.com",
  "email_verified": true
}
```

| Check | Must be |
| --- | --- |
| `iss` | Identical to the issuer you will configure in NiFi |
| `aud` | `nifi` — your client ID |
| The claim you chose in 1.4 | Present and filled in |

If `email` is missing or empty, stop and fix Keycloak (section 2.5). NiFi
cannot invent it. If everything is right, Keycloak is done — the rest is NiFi.

```bash
rm -f /tmp/tokens.json     # it holds a real token
```

---

## Part 4 — Back up NiFi

NiFi is still running normally.

```bash
cd /opt/nifi/current
BK=/opt/nifi/backups/pre-oidc-$(date +%Y%m%d-%H%M%S)
sudo mkdir -p "$BK"

# The files you are about to change
sudo cp -a conf/nifi.properties               "$BK"/
sudo cp -a conf/authorizers.xml               "$BK"/
sudo cp -a conf/login-identity-providers.xml  "$BK"/
sudo cp -a conf/truststore.p12                "$BK"/
# These two may not exist in Case A - the || true stops the script complaining
sudo cp -a conf/users.xml          "$BK"/ 2>/dev/null || true
sudo cp -a conf/authorizations.xml "$BK"/ 2>/dev/null || true
# Your dataflow. Not changed by any of this, but back it up anyway.
sudo cp -a conf/flow.json.gz "$BK"/

sudo chmod -R go-rwx "$BK"
ls -l "$BK"
echo "$BK" | sudo tee /opt/nifi/backups/LATEST_PRE_OIDC
```

Now copy it **off the machine**. A backup that lives only on the server you
are about to change is half a backup:

```bash
sudo tar czf /tmp/nifi-preoidc-backup.tgz -C "$BK" .
# then, from your laptop:
scp nifi-server:/tmp/nifi-preoidc-backup.tgz .
# or:  aws s3 cp /tmp/nifi-preoidc-backup.tgz s3://your-bucket/nifi-backups/
```

Record the path. You will type it in Part 8 under pressure.

---

## Part 5 — Change NiFi's files

Still no downtime. NiFi has these files open only at startup, so editing them
now changes nothing until the restart in Part 6.

### 5.1 Add the hostname to `nifi.web.proxy.host`

NiFi rejects any request whose `Host` header it does not recognise. After the
redirect back from Keycloak this is checked again, so a missing entry shows
up as a blank page right after a successful login.

```bash
grep '^nifi.web.proxy.host=' conf/nifi.properties
```

Every name or address people type must be listed, **with the port**, comma
separated:

```properties
nifi.web.proxy.host=nifi.example.com:8443,10.0.1.20:8443,localhost:8443
```

Edit with `sudo vi conf/nifi.properties` (or `nano`).

### 5.2 The two lines that switch modes

Find these and change them. They must change **together**.

```properties
# BEFORE
nifi.security.user.login.identity.provider=single-user-provider
nifi.security.user.authorizer=single-user-authorizer

# AFTER
nifi.security.user.login.identity.provider=
nifi.security.user.authorizer=managed-authorizer
```

| Line | What it controls | Why the change |
| --- | --- | --- |
| `login.identity.provider` | Which **local** login form NiFi shows | Emptying it removes the username-and-password box. With no local form, NiFi uses OIDC |
| `authorizer` | Who decides permissions | `single-user-authorizer` = "the one account may do anything". `managed-authorizer` = "look people up in `users.xml` and `authorizations.xml`" |

In **Case B** the second line already says `managed-authorizer`. Leave it
alone. Only empty the first line — and only when you are ready to stop using
your old login method.

### 5.3 Trust Keycloak's certificate

Skip this only if Keycloak uses a certificate from a public authority such as
Let's Encrypt or DigiCert — Java already trusts those. For a private or
self-signed CA, NiFi refuses the step-5 call with `PKIX path building failed`
until you do this.

```bash
# 1. Get the certificate Keycloak presents.
#    Best: ask for the CA certificate file. Otherwise pull the server's:
openssl s_client -connect sso.example.com:443 -servername sso.example.com \
  </dev/null 2>/dev/null | openssl x509 > /tmp/keycloak.crt

# 2. Look at it. Confirm the name and that it has not expired.
openssl x509 -in /tmp/keycloak.crt -noout -subject -issuer -dates

# 3. Find the truststore and its password
grep -E '^nifi\.security\.truststore' conf/nifi.properties
#   nifi.security.truststore=./conf/truststore.p12
#   nifi.security.truststoreType=PKCS12
#   nifi.security.truststorePasswd=abc123...

# 4. Import it. Use the password from step 3.
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
sudo "$JAVA_HOME/bin/keytool" -importcert -noprompt \
  -alias keycloak \
  -file /tmp/keycloak.crt \
  -keystore /opt/nifi/current/conf/truststore.p12 \
  -storetype PKCS12 \
  -storepass '<truststorePasswd>'

# 5. Confirm it is in there
sudo "$JAVA_HOME/bin/keytool" -list -alias keycloak \
  -keystore /opt/nifi/current/conf/truststore.p12 \
  -storetype PKCS12 -storepass '<truststorePasswd>'

# 6. Keep ownership correct
sudo chown nifi:nifi /opt/nifi/current/conf/truststore.p12
rm -f /tmp/keycloak.crt
```

> **Prefer a real certificate.** If Keycloak can use Let's Encrypt or your
> corporate CA, you skip this section entirely — and you skip the day the
> self-signed certificate expires and every login breaks at once.

### 5.4 Add the OIDC block to `nifi.properties`

These properties already exist in the file, further down, with empty values.
Find them and fill them in — do not add a second copy.

```properties
nifi.security.user.oidc.discovery.url=https://sso.example.com/realms/nifi/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=<the secret from Part 2>
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.fallback.claims.identifying.user=
nifi.security.user.oidc.truststore.strategy=NIFI
```

| Property | What it does | What goes wrong |
| --- | --- | --- |
| `discovery.url` | One address listing all of Keycloak's endpoints. NiFi fetches it **at startup** and configures itself from it | Typo or unreachable → NiFi starts fine, every login fails. Check the startup log |
| `connect.timeout` | How long to wait to open the connection | Too low on a slow link → random failures |
| `read.timeout` | How long to wait for the answer | Same |
| `client.id` | Must equal the Client ID from Part 2 | "unknown client" |
| `client.secret` | The secret from Part 2 | `invalid_client` in Keycloak's log |
| `preferred.jwsalgorithm` | Signature algorithm to expect. Keycloak uses `RS256` | Mismatch → token rejected |
| `additional.scopes` | Extra information to request. `openid` is always sent automatically | Missing `email` → "unable to determine user identity" |
| `claim.identifying.user` | **Your decision from 1.4.** Which claim becomes the identity | Changing it later means redoing every user and policy |
| `fallback.claims.identifying.user` | Second choice if the first is absent. Leave blank | — |
| `truststore.strategy` | `JDK` = trust public authorities. `NIFI` = trust NiFi's own truststore | Self-signed Keycloak plus `JDK` → `PKIX path building failed` |

Check your work:

```bash
grep -E '^nifi\.security\.user\.(oidc|authorizer|login)' conf/nifi.properties
```

### 5.5 Replace `authorizers.xml`

This file says who decides permissions. Write it out fully:

```bash
sudo tee /opt/nifi/current/conf/authorizers.xml > /dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<authorizers>

  <!-- PART 1: the list of people. Written to users.xml. -->
  <userGroupProvider>
    <identifier>file-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
    <property name="Users File">./conf/users.xml</property>
    <property name="Legacy Authorized Users File"></property>
    <property name="Initial User Identity 1">ana@example.com</property>
  </userGroupProvider>

  <!-- PART 2: who may do what. Written to authorizations.xml. -->
  <accessPolicyProvider>
    <identifier>file-access-policy-provider</identifier>
    <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
    <property name="User Group Provider">file-user-group-provider</property>
    <property name="Authorizations File">./conf/authorizations.xml</property>
    <property name="Initial Admin Identity">ana@example.com</property>
    <property name="Legacy Authorized Users File"></property>
    <property name="Node Identity 1"></property>
    <property name="Node Group"></property>
  </accessPolicyProvider>

  <!-- PART 3: the glue. nifi.properties points at this name. -->
  <authorizer>
    <identifier>managed-authorizer</identifier>
    <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
    <property name="Access Policy Provider">file-access-policy-provider</property>
  </authorizer>

</authorizers>
EOF

sudo chown nifi:nifi /opt/nifi/current/conf/authorizers.xml
xmllint --noout /opt/nifi/current/conf/authorizers.xml && echo "XML is valid"
```

Replace `ana@example.com` (twice) with **your** first admin, spelled exactly
as it appeared in the token in step 3.4.

| Line | Meaning |
| --- | --- |
| `identifier` (×3) | Nicknames. Part 2 refers to Part 1 by nickname, Part 3 to Part 2, and `nifi.properties` to Part 3 as `managed-authorizer`. One typo and NiFi will not start |
| `Initial User Identity 1` | Creates this person on first start. Add `Initial User Identity 2`, `3`, … to pre-load the whole team |
| `Initial Admin Identity` | **The critical line.** On first start this person gets every permission, so somebody can log in and grant access to everyone else |
| `Node Identity 1` / `Node Group` | Clusters only, where nodes authenticate to each other. Leave empty for one server |

### 5.6 `users.xml` and `authorizations.xml` — the dangerous step

NiFi reads `Initial Admin Identity` **only when `authorizations.xml` does not
exist.** If the old file is still there, NiFi starts normally and nobody can
log in. This is the most common failure in the whole procedure.

**Case A** (you had single-user auth) — delete them. They contain nothing you
want:

```bash
sudo rm -f /opt/nifi/current/conf/users.xml \
           /opt/nifi/current/conf/authorizations.xml
```

**Case B** (you already had managed-authorizer) — **do not delete them.** They
hold every permission your team has built. Instead, while still on your old
login method:

1. Log in with the existing method.
2. **☰ menu → Users → Add User**, and add each person's **new** identity
   (their email) *alongside* their existing one.
3. **☰ menu → Policies**, and give the new identity the same policies as the
   old one.
4. Only then empty `login.identity.provider` and restart.

Both identities work during the changeover, so if OIDC misbehaves your people
still have their old way in. Remove the old identities weeks later, once you
are confident.

### 5.7 Final check before the outage

```bash
cd /opt/nifi/current

# 1. The three settings that matter
grep -E '^nifi\.security\.user\.(authorizer|login\.identity\.provider)=' conf/nifi.properties
grep -E '^nifi\.security\.user\.oidc\.(discovery|client\.id|claim)' conf/nifi.properties

# 2. Valid XML
xmllint --noout conf/authorizers.xml && echo "authorizers.xml OK"

# 3. Ownership - a root-owned file NiFi cannot read stops it starting
ls -l conf/nifi.properties conf/authorizers.xml conf/truststore.p12

# 4. Compare against the backup, and read it aloud to a colleague
sudo diff "$BK/nifi.properties" conf/nifi.properties
```

Three things to confirm out loud:

1. The discovery URL's issuer matches what you saw in step 3.4.
2. The client secret is the current one.
3. The Initial Admin Identity is spelled and cased exactly as the claim value.

---

## Part 6 — Restart (the only downtime)

```bash
# 1. Note the time, tell the team
date

# 2. Stop cleanly - this lets NiFi finish writing its queues to disk
sudo systemctl stop nifi

# 3. Confirm it really stopped
sudo systemctl status nifi --no-pager | head -5

# 4. Start
sudo systemctl start nifi

# 5. Watch it come up. Startup takes 1-3 minutes; do not panic at minute one.
sudo tail -f /opt/nifi/current/logs/nifi-app.log
#    Wait for a line about the server having started.
#    Ctrl-C to stop watching.
```

Look for problems while it starts:

```bash
sudo grep -iE 'error|exception|oidc|openid' /opt/nifi/current/logs/nifi-app.log | tail -30
```

**No `nifi.sh` command? Not using systemd?**

```bash
sudo -u nifi /opt/nifi/current/bin/nifi.sh stop
sudo -u nifi /opt/nifi/current/bin/nifi.sh start
sudo -u nifi /opt/nifi/current/bin/nifi.sh status
```

**Data safety:** queued FlowFiles are written to disk continuously and
survive the restart. But processors that *listen* for incoming connections
(`ListenHTTP`, `ListenSyslog`, `ListenTCP`) refuse connections while NiFi is
down, and those messages are lost unless the sender retries. Check for them
before choosing your window.

---

## Part 7 — Verify

```
☐ 1. Open https://nifi.example.com:8443/nifi
      Expect: redirected to Keycloak.

☐ 2. Log in as the Initial Admin.
      Expect: back on the NiFi canvas, name in the top-right corner.

☐ 3. The flow looks exactly as before. Processors in the same state.

☐ 4. A second person logs in.
      Expect: login works; they see little or nothing until you grant
      policies. That is authorization working, not a bug.

☐ 5. Grant that person their policies:
      ☰ → Users → Add User → their exact identity
      ☰ → Policies → give them "view the user interface" first

☐ 6. Check the log:
      sudo grep -iE 'oidc|authoriz' logs/nifi-app.log | tail -20
```

**Set a limit.** If step 2 fails and ten minutes of looking has not fixed it,
go to Part 8 and try again tomorrow. Debugging a login system while the team
waits is how a small problem becomes a long outage.

### Adding everyone else — two places, always

| Where | What you do | Result if you skip it |
| --- | --- | --- |
| Keycloak | The person has an account (or already does via LDAP) | They cannot log in |
| NiFi → Users | Add their exact identity string | They log in, then see an access-denied page |
| NiFi → Policies | Grant permissions | They log in, see NiFi, but cannot do anything |

Creating a user in Keycloak by hand, if they are not in LDAP:

```bash
curl -s -X POST "$KC/admin/realms/$REALM/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"username":"ben","email":"ben@example.com","firstName":"Ben",
       "lastName":"Ortiz","enabled":true,"emailVerified":true,
       "credentials":[{"type":"password","value":"ChangeThisLater1!",
                       "temporary":true}]}' \
  -w '\nHTTP %{http_code}\n'
```

`"temporary": true` makes Keycloak ask them to choose their own password at
first login. Good practice for real people.

---

## Part 8 — Backing out

Everything you changed lives in the backup from Part 4. Restoring
`nifi.properties` removes all ten OIDC lines at once, because the saved copy
never had them. There is no half-configured state to untangle.

### 8.1 The rollback

```bash
# 1. Tell the team you are rolling back
date

# 2. Find the backup
BK=$(cat /opt/nifi/backups/LATEST_PRE_OIDC)
# or: BK=$(ls -1dt /opt/nifi/backups/pre-oidc-* | head -1)
ls -l "$BK"

# 3. Stop NiFi
sudo systemctl stop nifi

# 4. OPTIONAL but recommended: keep the OIDC config for a post-mortem
CUR=/opt/nifi/backups/failed-oidc-$(date +%Y%m%d-%H%M%S)
sudo mkdir -p "$CUR"
sudo cp -a /opt/nifi/current/conf/{nifi.properties,authorizers.xml} "$CUR"/

# 5. Put the originals back
cd /opt/nifi/current
sudo cp -a "$BK"/nifi.properties              conf/
sudo cp -a "$BK"/authorizers.xml              conf/
sudo cp -a "$BK"/login-identity-providers.xml conf/

# 6. Remove what OIDC mode created, then restore the originals if there were any
sudo rm -f conf/users.xml conf/authorizations.xml
sudo cp -a "$BK"/users.xml          conf/ 2>/dev/null || true
sudo cp -a "$BK"/authorizations.xml conf/ 2>/dev/null || true

# 7. Ownership
sudo chown -R nifi:nifi conf/

# 8. Start
sudo systemctl start nifi
sudo tail -f logs/nifi-app.log
```

### 8.2 Confirm the OIDC settings are really gone

```bash
grep -E '^nifi\.security\.user\.(oidc\.discovery\.url|login\.identity\.provider|authorizer)=' \
  conf/nifi.properties
```

Expect an empty discovery URL, and your original provider and authorizer
values back.

### 8.3 Optional tidy-up

Neither of these breaks anything if you leave it, but tidy is better:

```bash
# Remove Keycloak's certificate from the truststore
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
sudo "$JAVA_HOME/bin/keytool" -delete -alias keycloak \
  -keystore /opt/nifi/current/conf/truststore.p12 \
  -storetype PKCS12 -storepass '<truststorePasswd>'

# Remove a hosts entry, if you added one
sudo sed -i '/sso.example.com/d' /etc/hosts
```

### 8.4 On the Keycloak side

The Keycloak client does nothing on its own — an unused client is harmless.
Leave it in place if you plan to try again; that keeps the secret and the
redirect URIs you already verified.

To remove it:

```bash
# kcadm
$KCADM delete clients/$CID -r nifi

# or curl
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID" -w 'HTTP %{http_code}\n'
```

If you created a realm just for this, deleting the client is enough — do not
delete a realm anyone else might be using.

### 8.5 Rolling back the rollback

If you fix the problem and want to try OIDC again, everything from Part 5 is
in `failed-oidc-<timestamp>/` from step 4. Copy those two files back, restart,
and you are in OIDC mode again.

---

## Part 9 — Common failures

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Invalid parameter: redirect_uri` | The URL NiFi sent is not on the client's list | Add the exact URL, with port, to Valid redirect URIs |
| Login succeeds, then "Unable to view the user interface" | Authentication worked, authorization did not | Add the identity under Users, grant *view the user interface* |
| `PKIX path building failed` | NiFi does not trust Keycloak's certificate | Section 5.3; confirm `truststore.strategy=NIFI` |
| "Unable to determine user identity" | The claim you named is missing or empty | Section 2.5; check the user's email and Email verified |
| Blank page right after login | `nifi.web.proxy.host` missing the hostname | Section 5.1, then restart |
| NiFi will not start | Bad XML or mismatched identifier in `authorizers.xml` | `journalctl -u nifi -n 50`; `xmllint --noout`; roll back |
| Everybody locked out, admin included | `authorizations.xml` was left in place in Case A | Delete both files, restart — Initial Admin is reapplied |
| `invalid_client` in Keycloak's log | Wrong secret, or the client is public not confidential | Re-copy the secret; set Client authentication On |
| Worked yesterday, fails today | Certificate expired, secret rotated, or NiFi's address changed | Check all three |

**Break-glass.** Once OIDC is on, a Keycloak outage locks everyone out of
NiFi — running dataflows keep going, but nobody can open the UI. Either keep
Part 8 within arm's reach, or configure a certificate-based admin identity
alongside OIDC so one operator can always get in.

---

## Appendix A — Values to record

Fill this in before you start. Keep it with your change ticket; keep the
secret somewhere else.

| # | Item | Your value |
| --- | --- | --- |
| 1 | NiFi URL, as users type it | |
| 2 | NiFi install path | |
| 3 | OS user running NiFi | |
| 4 | Case A or Case B | |
| 5 | Cluster? nodes? | |
| 6 | Truststore path | |
| 7 | Truststore password | *(store separately)* |
| 8 | Keycloak base URL | |
| 9 | Realm name | |
| 10 | Issuer string (exact) | |
| 11 | Client ID | `nifi` |
| 12 | Client internal id (UUID) | |
| 13 | Client secret | *(store separately)* |
| 14 | Identity claim (`email` / `preferred_username`) | |
| 15 | Initial Admin Identity (exact) | |
| 16 | Backup directory path | |
| 17 | Off-server backup location | |
| 18 | Change window start / end | |
| 19 | Who performs the rollback | |

## Appendix B — Every command, in order

```bash
# ---- PART 1: collect ----
grep -E '^nifi\.security\.user\.(authorizer|login\.identity\.provider)=' conf/nifi.properties
grep -E '^nifi\.security\.truststore' conf/nifi.properties

# ---- PART 2: Keycloak client ----
TOKEN=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d grant_type=password -d username=admin \
  --data-urlencode "password=$KCPW" | jq -r .access_token)
curl -s -X POST "$KC/admin/realms/$REALM/clients" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d @client.json
CID=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients?clientId=nifi" | jq -r '.[0].id')
curl -s -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients/$CID/client-secret" | jq -r .value

# ---- PART 3: verify Keycloak ----
curl -s "$KC/realms/$REALM/.well-known/openid-configuration" | jq .issuer
ssh nifi-server 'curl -s https://sso.example.com/realms/nifi/.well-known/openid-configuration | head -c 80'

# ---- PART 4: backup ----
BK=/opt/nifi/backups/pre-oidc-$(date +%Y%m%d-%H%M%S); sudo mkdir -p "$BK"
sudo cp -a conf/{nifi.properties,authorizers.xml,login-identity-providers.xml,truststore.p12,flow.json.gz} "$BK"/
sudo cp -a conf/{users.xml,authorizations.xml} "$BK"/ 2>/dev/null || true
echo "$BK" | sudo tee /opt/nifi/backups/LATEST_PRE_OIDC

# ---- PART 5: edit ----
sudo "$JAVA_HOME/bin/keytool" -importcert -noprompt -alias keycloak \
  -file /tmp/keycloak.crt -keystore conf/truststore.p12 -storetype PKCS12 -storepass '<pw>'
sudo vi conf/nifi.properties          # 2 lines changed, 10 filled in
sudo vi conf/authorizers.xml          # replaced
sudo rm -f conf/users.xml conf/authorizations.xml     # CASE A ONLY
sudo chown -R nifi:nifi conf/
xmllint --noout conf/authorizers.xml

# ---- PART 6: restart ----
sudo systemctl stop nifi && sudo systemctl start nifi
sudo tail -f logs/nifi-app.log

# ---- PART 8: roll back ----
BK=$(cat /opt/nifi/backups/LATEST_PRE_OIDC)
sudo systemctl stop nifi
sudo cp -a "$BK"/{nifi.properties,authorizers.xml,login-identity-providers.xml} conf/
sudo rm -f conf/users.xml conf/authorizations.xml
sudo cp -a "$BK"/{users.xml,authorizations.xml} conf/ 2>/dev/null || true
sudo chown -R nifi:nifi conf/
sudo systemctl start nifi
```
