# NiFi 1.28 + Keycloak OIDC — The Complete Guide

This guide explains **every single line** we changed, why we changed it, and how
to redo it on a different system. It assumes you know almost nothing about OIDC.
Read it top to bottom, or jump to the part you need.

---

## Table of contents

1. [The big idea (background)](#1-the-big-idea-background)
2. [Quick setup — one working example](#2-quick-setup--one-working-example)
3. [nifi.properties, line by line](#3-nifiproperties-line-by-line)
4. [authorizers.xml, line by line](#4-authorizersxml-line-by-line)
5. [The Keycloak realm file, line by line](#5-the-keycloak-realm-file-line-by-line)
6. [Doing the Keycloak part by hand (clicking)](#6-doing-the-keycloak-part-by-hand-clicking)
7. [Moving this to another system](#7-moving-this-to-another-system)
8. [Choices you can make, with pros and cons](#8-choices-you-can-make-with-pros-and-cons)
9. [Troubleshooting](#9-troubleshooting)
10. [Making it safe for real use](#10-making-it-safe-for-real-use)

---

## 1. The big idea (background)

### What problem are we solving?

Normally NiFi keeps its own list of usernames and passwords. That is fine for one
person, but painful for a company: every new employee needs a new NiFi account,
and every person who leaves needs to be deleted from NiFi by hand.

**Single sign-on (SSO)** fixes this. You keep all your users in *one* place. Every
app asks that one place "is this person real?" NiFi never sees a password.

### The three characters in the story

Think of going to a concert.

| Character | In our setup | Concert version |
|---|---|---|
| **The user** | You, in your web browser | A fan at the gate |
| **The application** | Apache NiFi | The concert venue |
| **The identity provider (IdP)** | Keycloak | The ticket booth |

The venue does not check your ID. It checks your **ticket**. The ticket booth is
the only place that checks ID. That is exactly how OIDC works.

### What is OIDC?

**OIDC** stands for **OpenID Connect**. It is a set of rules (a "protocol") that
says how an app and an identity provider talk to each other. It is built on top
of an older standard called OAuth 2.0.

The important thing OIDC adds is the **ID token**: a small piece of text that
says "this is Jane, her email is jane@example.com, and I, the ticket booth,
promise it is true." It is digitally signed, so NiFi can check nobody faked it.

An ID token is a **JWT** (JSON Web Token). It looks like three chunks of
gibberish separated by dots:

```
eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6ImFkbWluQG5pZmkubG9jYWwifQ.SIGNATURE
   ^ header             ^ payload (the facts)                 ^ signature
```

The middle chunk is just Base64-encoded JSON. Decoded, it holds **claims** —
facts about the user:

```json
{
  "iss": "http://keycloak:8080/realms/nifi",
  "sub": "f1b2c3d4-...",
  "email": "admin@nifi.local",
  "preferred_username": "nifi-admin",
  "exp": 1754750000
}
```

Words to remember:

- **claim** — one fact inside the token, like `email`.
- **issuer** (`iss`) — who made the token. Very important later.
- **subject** (`sub`) — a permanent random ID for the user.
- **scope** — a request for certain kinds of information ("please include email").
- **client** — the app asking for tokens. NiFi is a client.
- **realm** — a Keycloak word meaning "one separate world of users and apps."

### The login dance, step by step

This is the **Authorization Code Flow**. Follow the arrows:

```
 1. You                -> https://localhost:8443/nifi
 2. NiFi               -> "I don't know you." Redirects your browser to Keycloak
 3. Browser            -> Keycloak login page
 4. You                -> type username + password
 5. Keycloak           -> redirects browser BACK to NiFi with a short "code"
 6. NiFi (server side) -> quietly calls Keycloak: "here's the code + my secret"
 7. Keycloak           -> hands NiFi the ID token
 8. NiFi               -> reads the email claim, decides who you are
 9. NiFi               -> gives your browser its own cookie. You are logged in.
```

Two details worth noticing:

- **Step 6 happens server to server.** Your browser never sees the client
  secret. That is why NiFi is called a **confidential client** — it can keep a
  secret. (A mobile app cannot, so those are "public clients.")
- **The code is used once and expires fast.** That limits the damage if someone
  steals it out of a URL.

### Authentication vs authorization

These two words look alike and mean different things. Getting them straight
solves most confusion later.

- **Authentication** = *Who are you?* Keycloak answers this.
- **Authorization** = *What are you allowed to do?* **NiFi** answers this.

Keycloak can prove you are `admin@nifi.local`. It has no idea whether that person
may start a processor. NiFi keeps its own permission list in `authorizers.xml`,
`users.xml`, and `authorizations.xml`.

So a user can log in perfectly and still see an empty, useless NiFi screen. That
is not a broken login. That is a missing permission.

---

## 2. Quick setup — one working example

Do these in order.

### Step 1 — Add a hosts entry

Your browser and the NiFi container must reach Keycloak using **the exact same
web address**. Section 3 explains why this matters so much.

Linux or macOS:

```bash
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

Windows: open Notepad **as Administrator**, open
`C:\Windows\System32\drivers\etc\hosts`, add `127.0.0.1 keycloak`, save.

Check it worked:

```bash
ping -c1 keycloak
```

### Step 2 — Start both containers

```bash
cd nifi-oidc
chmod +x *.sh nifi/*.sh
docker compose up -d
```

The first start takes 2–3 minutes. NiFi is large. Watch it:

```bash
docker compose logs -f nifi
```

Wait for a line containing **"NiFi has started"**. Press `Ctrl+C` to stop watching.

### Step 3 — Test it

```bash
./verify.sh
```

This performs a real login using `curl` and checks NiFi reports the identity
`admin@nifi.local`. Every check should say PASS.

### Step 4 — Log in with your browser

Go to <https://localhost:8443/nifi>.

Your browser shows a scary warning about the certificate. That is expected — we
made our own certificate instead of buying one. Click **Advanced** → **Proceed**.

You land on the Keycloak login page. Sign in:

| Who | Username | Password |
|---|---|---|
| NiFi admin | `nifi-admin` | `nifi-admin-password` |
| Ordinary user (no NiFi permissions yet) | `nifi-user` | `nifi-user-password` |
| Keycloak admin console | `admin` | `admin` |

Log in as `nifi-admin` and you should see the NiFi canvas with your name in the
top right corner.

---

## 3. nifi.properties, line by line

`nifi.properties` is NiFi's main settings file. It lives at
`/opt/nifi/nifi-current/conf/nifi.properties` inside the container. It is a plain
list of `name=value` lines.

Our script `nifi/oidc-entrypoint.sh` edits it automatically at startup. Below is
every property we set and what it does.

> **How to read a property name.** They are grouped by prefix.
> `nifi.web.*` = the website part. `nifi.security.*` = encryption and login.
> `nifi.security.user.oidc.*` = the OIDC settings specifically.

### 3.1 Turning off plain HTTP

```properties
nifi.web.http.host=
nifi.web.http.port=
```

Both are set to **empty on purpose**. Empty means "turn this off."

Out of the box, NiFi listens on plain, unencrypted HTTP on port 8080. **NiFi
refuses to do OIDC over plain HTTP.** It will not start, or it will not offer
the login link.

Why so strict? Over plain HTTP, everything travels as readable text. Anyone on
the same network could grab your ID token and become you. Encryption is not
optional here.

> **Rule:** in NiFi properties, an empty value is a real setting meaning
> "disabled." Do not delete the line — leave the name with nothing after `=`.

### 3.2 Turning on HTTPS

```properties
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
```

- `0.0.0.0` means "accept connections on every network interface." Inside a
  container this is what you want. If you set `localhost` here, NiFi would only
  listen inside the container and Docker could not forward your traffic in.
- `8443` is the port. There is nothing magic about 8443; it is just the
  traditional "alternative HTTPS" port. It must match the `ports:` line in
  `docker-compose.yml` (`"8443:8443"`).

### 3.3 The allowed address list

```properties
nifi.web.proxy.host=localhost:8443,nifi:8443,127.0.0.1:8443
```

Every web request carries a `Host:` header saying which address you typed. NiFi
compares that header against this list and **rejects anything not on it** with
the message *"System Error / Host header invalid."*

This is a defense against **host header injection**, where an attacker tricks an
app into generating links pointing at the attacker's site.

Because we might reach NiFi as `localhost`, as `nifi` (from another container),
or as `127.0.0.1`, all three are listed, each with the port.

**When you move to a real server, this is one of the lines you must change** —
add `nifi.example.com:8443` or whatever people will type.

### 3.4 Secure site-to-site

```properties
nifi.remote.input.secure=true
```

NiFi instances can send data to each other, a feature called **Site-to-Site**.
Since our whole instance is now HTTPS-only, this must be `true` to match. Leaving
it `false` on a secured NiFi causes startup complaints.

### 3.5 The certificate settings

```properties
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=changeMeKeystore123
nifi.security.keyPasswd=changeMeKeystore123
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=changeMeKeystore123
```

To do HTTPS, a server needs a **certificate** and a **private key**.

- A **certificate** is like an ID card for a website. It says "I really am
  localhost" and includes a public key.
- The **private key** is the matching secret. The server never shares it.
- A **keystore** is an encrypted file holding your own certificate and private
  key. Think: your wallet with your own ID in it.
- A **truststore** is an encrypted file holding certificates you *trust from
  other people*. Think: the list of ID cards you'd accept from a stranger.

Line by line:

| Line | Meaning |
|---|---|
| `keystore` | Path to our own ID. `./` means relative to the NiFi install folder, so this is `/opt/nifi/nifi-current/conf/keystore.p12` |
| `keystoreType=PKCS12` | The file format. PKCS12 (`.p12`) is the modern standard. The old Java format was JKS, now discouraged |
| `keystorePasswd` | Password that unlocks the file |
| `keyPasswd` | Password for the key inside the file. **With PKCS12, make it the same as the store password** — NiFi warns or fails if they differ |
| `truststore` | Certificates we trust. Ours contains only our own self-signed cert |
| `truststoreType` / `truststorePasswd` | Same idea as above |

**Where did these files come from?** Our entrypoint script made them on first
boot with `keytool`, a tool built into Java:

```bash
keytool -genkeypair -alias nifi-key -keyalg RSA -keysize 2048 -validity 3650 \
  -dname "CN=localhost, OU=NiFi, O=Local, C=US" \
  -ext "SAN=dns:localhost,dns:nifi,ip:127.0.0.1" \
  -keystore conf/keystore.p12 -storetype PKCS12 \
  -storepass "$PASS" -keypass "$PASS"
```

Decoding that command:

- `-genkeypair` — make a new private key plus a matching certificate.
- `-alias nifi-key` — a nickname for this entry inside the file.
- `-keyalg RSA -keysize 2048` — the math used. 2048-bit RSA is the safe minimum today.
- `-validity 3650` — good for 10 years. Fine for a test; too long for production.
- `-dname "CN=localhost"` — **CN** is "Common Name," the main name on the ID card.
- `-ext "SAN=dns:localhost,dns:nifi,ip:127.0.0.1"` — **SAN** is "Subject
  Alternative Name," the list of *all* addresses this certificate is valid for.
  Modern browsers ignore CN completely and look only at SAN. **If you access
  NiFi by a name not in the SAN list, your browser will refuse.** This is the
  single most common certificate mistake.

Because we signed the certificate ourselves ("self-signed"), no browser trusts
it, which is why you see the warning. That is a trust problem, not a security
weakness in the encryption itself.

### 3.6 Making OIDC the only way in

```properties
nifi.security.user.login.identity.provider=
nifi.security.user.knox.url=
nifi.security.user.authorizer=managed-authorizer
nifi.security.allow.anonymous.authentication=false
```

- `login.identity.provider=` — **emptied on purpose.** A fresh NiFi ships with
  `single-user-provider`, the built-in one-username-and-password login. NiFi
  allows only **one** login mechanism at a time. If both this and OIDC are set,
  NiFi refuses to start and complains about multiple login providers. Clearing
  this line is mandatory, and forgetting it is the most common OIDC setup error.
- `knox.url=` — emptied for the same reason. Apache Knox is a different SSO
  system we are not using.
- `authorizer=managed-authorizer` — points at the permission system defined in
  `authorizers.xml` (Section 4). The default `single-user-authorizer` gives one
  person everything and must be replaced.
- `allow.anonymous.authentication=false` — no browsing without logging in.

### 3.7 The OIDC settings themselves

```properties
nifi.security.user.oidc.discovery.url=http://keycloak:8080/realms/nifi/.well-known/openid-configuration
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=nifi-client-secret-change-me
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
```

**`discovery.url`** — the one setting that makes everything else automatic.

Every OIDC provider publishes a "menu" at a standard address ending in
`/.well-known/openid-configuration`. Open it in a browser and you get JSON
listing all the other addresses NiFi needs:

```json
{
  "issuer": "http://keycloak:8080/realms/nifi",
  "authorization_endpoint": "http://keycloak:8080/realms/nifi/protocol/openid-connect/auth",
  "token_endpoint": "http://keycloak:8080/realms/nifi/protocol/openid-connect/token",
  "jwks_uri": "http://keycloak:8080/realms/nifi/protocol/openid-connect/certs",
  "scopes_supported": ["openid", "email", "profile", "offline_access", "..."]
}
```

NiFi reads this **when it starts up**. Consequences:

- If Keycloak is down at that moment, NiFi logs *"Unable to retrieve OpenId
  Connect Provider metadata"*. That is why `docker-compose.yml` makes NiFi wait
  for a Keycloak healthcheck.
- If you change anything in Keycloak, **restart NiFi** so it re-reads the menu.

> ### The single most important gotcha: the issuer must match
>
> Look at `"issuer"` above. Keycloak stamps that exact string inside every token
> it makes. When NiFi validates a token, it checks the `iss` claim equals the
> issuer from the discovery document.
>
> Now imagine your browser reaches Keycloak at `http://localhost:8080`, but the
> NiFi container reaches it at `http://keycloak:8080`. Keycloak stamps one URL,
> NiFi expects the other, they do not match, and login fails — usually with a
> confusing message about the authorization request not being found.
>
> **That is why we add `127.0.0.1 keycloak` to the hosts file.** It forces both
> your browser and the container to use the identical address, `keycloak:8080`.
> We also set `KC_HOSTNAME: http://keycloak:8080` in `docker-compose.yml` so
> Keycloak agrees. All three must line up.

**`client.id` and `client.secret`** — NiFi's own username and password when it
talks to Keycloak in step 6 of the dance. The secret must be **character for
character identical** to the one in Keycloak, or you get `invalid_client`.

**`claim.identifying.user=email`** — this is the bridge between the two systems.
It tells NiFi: *"whatever is in the `email` claim, that string IS the username."*

So a token containing `"email": "admin@nifi.local"` makes NiFi treat you as the
user literally named `admin@nifi.local`. That exact string must then appear in
`authorizers.xml` (Section 4), or you log in successfully and can do nothing.

Alternatives are compared in [Section 8](#81-which-claim-should-be-the-username).

**`connect.timeout` / `read.timeout`** — how long NiFi waits for Keycloak. The
default is `5 secs`; we doubled it to `10 secs` because containers starting at
the same time can be slow. Note the format is a number, a space, then a unit.

### 3.8 The sensitive properties key

```properties
nifi.sensitive.props.key=changeMeSensitiveProps123
```

NiFi encrypts secrets you type into processors (database passwords, API keys)
before saving them to disk. This is the master password for that encryption. It
must be **at least 12 characters**. NiFi will not start without it.

It also encrypts stored OIDC refresh tokens.

> **Warning:** if you change this key later, NiFi can no longer decrypt existing
> saved passwords. Choose one and keep it. In production, feed it from a secrets
> manager, never a file in Git.

### 3.9 The complete list, for copying

If you are configuring a NiFi 1.28 that is *not* in our container setup, these
are the lines to change:

```properties
# --- turn off HTTP, turn on HTTPS ---
nifi.web.http.host=
nifi.web.http.port=
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
nifi.web.proxy.host=YOUR-HOSTNAME:8443

# --- certificates ---
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=YOUR-KEYSTORE-PASSWORD
nifi.security.keyPasswd=YOUR-KEYSTORE-PASSWORD
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=YOUR-KEYSTORE-PASSWORD

# --- one login method only ---
nifi.security.user.login.identity.provider=
nifi.security.user.knox.url=
nifi.security.user.authorizer=managed-authorizer
nifi.security.allow.anonymous.authentication=false

# --- OIDC ---
nifi.security.user.oidc.discovery.url=https://YOUR-IDP/realms/YOUR-REALM/.well-known/openid-configuration
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=YOUR-SECRET
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs

# --- required ---
nifi.sensitive.props.key=AT-LEAST-12-CHARACTERS
nifi.remote.input.secure=true
```

---

## 4. authorizers.xml, line by line

This file answers the *authorization* question: what is each person allowed to do?

It lives next to `nifi.properties` in the `conf` folder. Here is ours in full,
followed by an explanation of each block.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizers>
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Legacy Authorized Users File"></property>
        <property name="Initial User Identity 1">admin@nifi.local</property>
    </userGroupProvider>
    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">admin@nifi.local</property>
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
```

### The three blocks and how they connect

Think of a school:

1. **userGroupProvider** — the enrollment list. *Who exists?*
2. **accessPolicyProvider** — the rulebook. *Who may enter which room?*
3. **authorizer** — the hall monitor who reads both and says yes or no.

They are chained together by name. The `<identifier>` in one block is referenced
by a `<property>` in the next:

```
managed-authorizer
   └─ "Access Policy Provider" -> file-access-policy-provider
                                     └─ "User Group Provider" -> file-user-group-provider
```

And `nifi.properties` points at the top of the chain with
`nifi.security.user.authorizer=managed-authorizer`. **If any of those names are
misspelled, NiFi will not start.**

### Block 1 — userGroupProvider

| Line | What it does |
|---|---|
| `<identifier>file-user-group-provider</identifier>` | The nickname other blocks use to refer to this one. You can rename it, but change every reference |
| `<class>...FileUserGroupProvider</class>` | The Java code that does the work. This one stores users in a file. Other classes exist for LDAP or Azure AD |
| `Users File = ./conf/users.xml` | Where the user list gets saved. **NiFi creates and edits this file itself** — you do not write it by hand |
| `Legacy Authorized Users File` | Empty. Only used when upgrading from NiFi 0.x, which is ancient |
| `Initial User Identity 1` | Create this user the very first time NiFi starts |

**About "Initial" properties — read this carefully.**

They only take effect when `users.xml` and `authorizations.xml` **do not yet
exist**. On the first boot NiFi reads them, writes the two files, and from then
on ignores these lines forever.

So if you change `Initial User Identity 1` and restart, *nothing happens.* You
must either edit users through the NiFi UI, or delete `users.xml` and
`authorizations.xml` and restart to start over. In our Docker setup that means:

```bash
docker compose down -v      # deletes the volumes holding those files
docker compose up -d
```

To add more users at first boot, number them upward:

```xml
<property name="Initial User Identity 1">admin@nifi.local</property>
<property name="Initial User Identity 2">bob@nifi.local</property>
<property name="Initial User Identity 3">carol@nifi.local</property>
```

Users 2 and 3 will exist but have **no permissions** until the admin grants them
some in the UI.

### Block 2 — accessPolicyProvider

| Line | What it does |
|---|---|
| `User Group Provider` | Points back to block 1. Where to find the people |
| `Authorizations File` | Where permission rules get saved. NiFi manages this file too |
| `Initial Admin Identity` | **The most important line in this file.** This person gets full administrator rights on first boot |
| `Node Identity 1` / `Node Group` | Empty. Only for NiFi **clusters**, where servers authenticate to each other with certificates. We run one node |

**`Initial Admin Identity` must exactly match the value NiFi extracts from the
token.** Since we set `claim.identifying.user=email` and our Keycloak user's
email is `admin@nifi.local`, that is the string here. It is:

- **case sensitive** — `Admin@nifi.local` is a different person
- **whitespace sensitive** — a trailing space breaks it
- **format sensitive** — if you switch to the `sub` claim, this becomes a UUID

The admin gets these policies automatically: view the UI, access all data, modify
the root process group, manage users, manage policies, and more.

### Block 3 — authorizer

`StandardManagedAuthorizer` is the normal choice. "Managed" means the rules can
be edited live in the UI instead of only in files. There is also
`FileAuthorizer` (older, file-only) and third-party ones like OPA.

### The files NiFi generates

After first boot, look in `conf/`:

```bash
docker compose exec nifi cat conf/users.xml
```

```xml
<users>
    <user identifier="a1b2..." identity="admin@nifi.local"/>
</users>
```

That `identity` attribute is what your token must produce. **This is the single
best debugging command** when someone logs in but has no permissions — compare
this string to what is actually in their token.

### Adding a second person later

1. Log in as admin.
2. Top-right hamburger menu → **Users** → **+** → type their exact identity
   (their email, if you kept `claim.identifying.user=email`).
3. Hamburger menu → **Policies**, or right-click the canvas → **Manage access
   policies**, and grant what they need.

Common starting policies: `view the user interface`, plus `view` and `modify`
on the root process group.

---

## 5. The Keycloak realm file, line by line

`keycloak/realm-nifi.json` describes a whole realm as a file. Keycloak imports it
on first start so you do not have to click through the admin console.

> **Important:** import happens **only when Keycloak's database is empty.**
> Editing this file and restarting does nothing. See Section 5.4.

### 5.1 Realm-level settings

```json
{
  "realm": "nifi",
  "enabled": true,
  "sslRequired": "none",
  "registrationAllowed": false,
  "loginWithEmailAllowed": true,
  "accessTokenLifespan": 900,
```

| Line | Meaning |
|---|---|
| `"realm": "nifi"` | The realm's name. It appears **in every URL**: `/realms/nifi/...`. Change it and you must change the discovery URL too |
| `"enabled": true` | The realm is on. `false` would reject all logins |
| `"sslRequired": "none"` | Allow plain HTTP to Keycloak. **Development only.** Real deployments use `"external"` (HTTPS required except from localhost) or `"all"` |
| `"registrationAllowed": false` | No public "Create account" link. Users are created by an admin |
| `"loginWithEmailAllowed": true` | People may type either their username or their email on the login page |
| `"accessTokenLifespan": 900` | Access tokens expire after 900 seconds (15 minutes). Shorter is safer; too short means more refreshes |

### 5.2 The client block

A **client** is one application that trusts this realm. NiFi is a client.

```json
  "clients": [
    {
      "clientId": "nifi",
      "name": "Apache NiFi",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "bearerOnly": false,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false,
      "secret": "nifi-client-secret-change-me",
      "redirectUris": [
        "https://localhost:8443/*",
        "https://127.0.0.1:8443/*"
      ],
      "webOrigins": ["https://localhost:8443"],
      "attributes": {
        "post.logout.redirect.uris": "https://localhost:8443/*"
      }
    }
  ],
```

| Line | Meaning |
|---|---|
| `clientId: "nifi"` | The app's username. **Must equal** `nifi.security.user.oidc.client.id` |
| `name` | Friendly label shown in the Keycloak console only |
| `protocol: "openid-connect"` | Use OIDC, not the older SAML |
| `publicClient: false` | This client **can** keep a secret. This makes NiFi a *confidential* client, which is required — a public client would break the token exchange in step 6 |
| `bearerOnly: false` | This client starts logins. `true` would mean "API only, never shows a login page" |
| `standardFlowEnabled: true` | **Enables Authorization Code Flow** — the dance from Section 1. Without this, login is impossible |
| `directAccessGrantsEnabled: true` | Allows username+password straight to the token endpoint. NiFi does not use this; **our `verify.sh` uses it to test**. Turn it off in production |
| `serviceAccountsEnabled: false` | We don't need a robot account for the client itself |
| `secret` | The password NiFi uses. **Must equal** `nifi.security.user.oidc.client.secret` |
| `redirectUris` | See below — a security whitelist |
| `webOrigins` | Which websites may call Keycloak with JavaScript (CORS). Usually the same address |
| `post.logout.redirect.uris` | Where users may be sent after logging out |

**About `redirectUris`.** After you log in, Keycloak sends your browser back to
NiFi with the code attached. An attacker who could choose that return address
would steal codes. So Keycloak only sends users to addresses on this list.

The `*` at the end is a wildcard covering NiFi's actual callback path,
`/nifi-api/access/oidc/callback`. If this list is wrong you see the Keycloak
error **"Invalid parameter: redirect_uri"** — which means the list here does not
include the address you are actually using.

Being precise is better than a wildcard in production:

```json
"redirectUris": ["https://nifi.example.com:8443/nifi-api/access/oidc/callback"]
```

### 5.3 The users block

```json
  "users": [
    {
      "username": "nifi-admin",
      "enabled": true,
      "emailVerified": true,
      "email": "admin@nifi.local",
      "firstName": "NiFi",
      "lastName": "Admin",
      "credentials": [
        { "type": "password", "value": "nifi-admin-password", "temporary": false }
      ],
      "realmRoles": ["default-roles-nifi", "offline_access", "uma_authorization"]
    }
  ]
```

| Line | Meaning |
|---|---|
| `username` | What you type on the login page |
| `enabled: true` | Account is active |
| `emailVerified: true` | Skips the "please confirm your email" step. Without it, login can stall on a verification screen |
| `email` | **This becomes the NiFi identity**, because we set `claim.identifying.user=email`. It must match `Initial Admin Identity` in `authorizers.xml` |
| `credentials.temporary: false` | Do **not** force a password change at first login. If `true`, the browser gets stuck on a change-password screen mid-login |
| `realmRoles` | See the box below |

> ### Why `realmRoles` matters — a real bug we hit
>
> When you create a user by clicking in the Keycloak console, Keycloak
> automatically gives them the realm's default roles. When a user is **imported
> from a JSON file, it does not.** An imported user with no `realmRoles` has no
> roles at all.
>
> One of those default roles is `offline_access`. Starting with version 1.21,
> NiFi reads `scopes_supported` from the discovery document and asks for **all**
> the scopes listed there — and Keycloak lists `offline_access`. Because our
> imported user lacked that role, Keycloak refused with:
>
> ```
> error="not_allowed", error_description="Offline tokens not allowed for the user or client"
> ```
>
> Adding `"realmRoles": ["default-roles-nifi", "offline_access", "uma_authorization"]`
> fixes it. Note `default-roles-nifi` includes the realm name — in your realm it
> would be `default-roles-YOURREALM`.
>
> A related symptom is `error="invalid_scope"` listing many scope names. That
> means the *client* is missing scopes rather than the user missing roles; fix it
> by assigning all client scopes to the client (`./fix-keycloak.sh --scopes`).
>
> *Caveat on sourcing:* the "NiFi requests every supported scope" behavior comes
> from user reports of the 1.20→1.21 upgrade, where the error listed that realm's
> full scope set including custom scopes. It matches what we observed, but it is
> not something I verified in NiFi's source code.

### 5.4 Re-importing after you edit this file

The import only runs against an empty database. Because `start-dev` keeps its
database inside the container (not in a named volume), deleting the container is
enough, and your NiFi data is untouched:

```bash
docker compose rm -sf keycloak
docker compose up -d keycloak
```

To wipe absolutely everything including NiFi:

```bash
docker compose down -v
docker compose up -d
```

Or skip re-importing entirely and patch the running server:

```bash
./fix-keycloak.sh
```

---

## 6. Doing the Keycloak part by hand (clicking)

On another system you may not have a realm file. Here is the same setup through
the admin console. Sign in at your Keycloak address with the admin account.

### 6.1 Create the realm

1. Click the realm dropdown in the top-left → **Create realm**.
2. **Realm name:** `nifi` → **Create**.

### 6.2 Create the client

1. Left menu → **Clients** → **Create client**.
2. **Client type:** OpenID Connect. **Client ID:** `nifi` → **Next**.
3. Turn **ON** *Client authentication*. ← this is what makes it confidential
4. Under Authentication flow, check **Standard flow**. Leave Direct access grants
   on only if you want to script tests → **Next**.
5. **Valid redirect URIs:** `https://YOUR-NIFI-HOST:8443/*`
6. **Web origins:** `https://YOUR-NIFI-HOST:8443` → **Save**.

### 6.3 Copy the secret

1. Open the client → **Credentials** tab.
2. Copy **Client secret** into `nifi.security.user.oidc.client.secret`.

### 6.4 Create a user

1. Left menu → **Users** → **Add user**.
2. **Username**, and **Email** — the email is what NiFi will use as the identity.
3. Turn **ON** *Email verified* → **Create**.
4. **Credentials** tab → **Set password** → turn **OFF** *Temporary* → **Save**.
5. **Role mapping** tab → confirm `default-roles-<realm>` is assigned. If not,
   click **Assign role** and add it.

### 6.5 Check the discovery URL

Visit `https://YOUR-KEYCLOAK/realms/nifi/.well-known/openid-configuration`.
You should get JSON. Confirm `"issuer"` is the address NiFi will use. Paste the
full URL into `nifi.security.user.oidc.discovery.url`.

---

## 7. Moving this to another system

### 7.1 The checklist

Work through these in order. Each row is something that **must** change when you
leave localhost.

| # | Thing | Where | Change it to |
|---|---|---|---|
| 1 | Certificate SAN | `keytool` command | Your real hostname |
| 2 | `nifi.web.proxy.host` | nifi.properties | `nifi.example.com:8443` |
| 3 | `discovery.url` | nifi.properties | Your Keycloak address |
| 4 | `client.secret` | nifi.properties | The value from the Credentials tab |
| 5 | `redirectUris` | Keycloak client | `https://nifi.example.com:8443/*` |
| 6 | `webOrigins` | Keycloak client | `https://nifi.example.com:8443` |
| 7 | `Initial Admin Identity` | authorizers.xml | The real admin's email |
| 8 | `sensitive.props.key` | nifi.properties | A fresh 12+ character secret |
| 9 | Keystore passwords | nifi.properties | Fresh secrets |
| 10 | Keycloak `sslRequired` | realm | `external` or `all` |

### 7.2 The four things that must match

Draw this on a whiteboard before you start. Almost every failure is one of these
four pairs being out of sync.

```
  client id       nifi.properties  <-->  Keycloak client        "clientId"
  client secret   nifi.properties  <-->  Keycloak Credentials   tab
  callback URL    NiFi's real URL  <-->  Keycloak               "redirectUris"
  identity        token's email    <-->  authorizers.xml        "Initial Admin Identity"
```

Plus one that must match **itself** in three places: the Keycloak address used by
your browser, by the NiFi server, and in `KC_HOSTNAME` / the issuer.

### 7.3 Order of operations

1. Get NiFi working on **HTTPS with no OIDC at all** first. Confirm you can
   reach the login page. Certificate problems are much easier to debug alone.
2. Then create the Keycloak realm, client, and user.
3. Then add the six OIDC properties and restart NiFi.
4. Then check the identity string in `users.xml` matches the token.

Doing all three at once and debugging the pile is how people lose a day.

---

## 8. Choices you can make, with pros and cons

### 8.1 Which claim should be the username?

`nifi.security.user.oidc.claim.identifying.user` decides. There is no perfect
answer; pick with your eyes open.

| Choice | Pros | Cons |
|---|---|---|
| `email` (our choice) | Readable in the UI and audit logs; matches how people think about colleagues; easy to type into policies | Breaks if someone changes their email — the new address is a brand-new NiFi user with zero permissions |
| `preferred_username` | Short and readable; changes less often than email | Not guaranteed unique across all IdPs; can be reassigned when someone leaves |
| `sub` (subject) | Truly permanent and unique; survives name and email changes | A UUID like `f1b2c3d4-...`. Policy screens become unreadable; you cannot tell who anyone is |

**Best practice:** use `email` or `preferred_username` for readability, and write
down the recovery procedure for when an identity changes. There is also
`nifi.security.user.oidc.fallback.claims.identifying.user` for a backup claim if
the primary is missing.

### 8.2 Managing permissions per person vs per group

| Approach | Pros | Cons |
|---|---|---|
| Add each user in NiFi's UI (what we do) | Simple; no extra configuration; fine for a handful of people | Manual work for every hire; you must remember to remove leavers |
| Map Keycloak groups into NiFi (`nifi.security.user.oidc.claim.groups`) | Access follows your directory automatically; one place to manage | More moving parts; requires a groups mapper in Keycloak; harder to debug |

For more than roughly ten users, groups are worth the setup cost.

### 8.3 Self-signed vs real certificate

| Approach | Pros | Cons |
|---|---|---|
| Self-signed (what we do) | Free, instant, no external dependency | Browser warnings; every client must be told to trust it; unacceptable for real users |
| Internal company CA | Trusted automatically on managed machines; free | Needs a CA to exist and be maintained |
| Public CA (Let's Encrypt) | Trusted by every browser with no setup; automatic renewal | Requires a public DNS name and reachable server |

### 8.4 Keycloak `start-dev` vs `start`

| Mode | Pros | Cons |
|---|---|---|
| `start-dev` (what we use) | No database to set up; HTTP allowed; relaxed hostname checks | Data lives in a throwaway in-container database; **loses everything** when the container is replaced; not supported for production |
| `start` with PostgreSQL | Durable; strict, correct hostname handling; supported | You must run a database, provide TLS certificates, and set hostname properly |

### 8.5 Hosts-file entry vs real DNS

We used a hosts entry because it is one line and needs no infrastructure. On a
real network, give Keycloak a real DNS name instead. The hosts trick does not
scale — every user's laptop would need editing.

---

## 9. Troubleshooting

### 9.1 Where to look first

```bash
docker compose logs nifi | tail -50                       # startup failures
docker compose exec nifi tail -f logs/nifi-app.log        # live NiFi log
docker compose exec nifi grep -i oidc logs/nifi-app.log   # OIDC lines only
docker compose exec nifi cat conf/users.xml               # who NiFi knows about
docker compose logs keycloak | tail -50                   # Keycloak side
curl -s http://keycloak:8080/realms/nifi/.well-known/openid-configuration
```

### 9.2 Error messages and what they mean

| Message | Where it appears | Cause and fix |
|---|---|---|
| `Unable to retrieve OpenId Connect Provider metadata` | NiFi log at startup | Keycloak was down or unreachable when NiFi started. Start Keycloak first, then restart NiFi |
| NiFi will not start, complains about multiple login providers | NiFi log | `nifi.security.user.login.identity.provider` is not empty. Clear it |
| `Invalid parameter: redirect_uri` | Keycloak page | The address you used is not in the client's `redirectUris` |
| `invalid_client` | Keycloak | Client secret mismatch between NiFi and Keycloak, or the client is set to public |
| `not_allowed` / `Offline tokens not allowed` | Keycloak | User lacks the `offline_access` role. Run `./fix-keycloak.sh` |
| `invalid_scope` listing many scopes | Keycloak | Client is missing scopes NiFi requests. Run `./fix-keycloak.sh --scopes` |
| `authorization_request_not_found` | NiFi | The pending login expired, was reused, or its cookie was lost. Clear cookies, use one tab, log in without pausing. Also appears when the issuer does not match |
| Login works, then a blank or read-only NiFi | NiFi UI | Authentication succeeded, authorization did not. Compare `conf/users.xml` to the token's email |
| `System Error` / host header invalid | NiFi UI | Add the address you typed to `nifi.web.proxy.host` |
| Certificate warning that will not clear | Browser | The name you typed is not in the certificate's SAN list |

### 9.3 Reading a token yourself

Decode the middle chunk of a JWT to see exactly what NiFi received:

```bash
TOKEN='eyJhbGciOi....'
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null
```

Check that `email` is present and that `iss` is the address NiFi expects.

### 9.4 Start completely over

```bash
docker compose down -v
docker compose up -d
```

`-v` deletes the volumes, which removes `users.xml` and `authorizations.xml` so
the `Initial Admin Identity` takes effect again.

---

## 10. Making it safe for real use

Our setup is a **learning and testing** environment. Before real users touch it:

**Certificates**
- Replace the self-signed certificate with one from a real CA.
- Shorten validity from 10 years to 1 year or less, and plan renewals.

**Secrets**
- Change every password in `.env`; nothing there is a real secret today.
- Keep secrets out of Git. Use Docker secrets, Vault, or your cloud's secret manager.
- Rotate the client secret on a schedule.

**Keycloak**
- Switch from `start-dev` to `start` with PostgreSQL.
- Put Keycloak behind HTTPS and set `sslRequired` to `external` or `all`.
- Turn off `directAccessGrantsEnabled` once you no longer need scripted tests.
- Replace the wildcard `redirectUris` with the exact callback path.
- Require multi-factor authentication for admins.

**NiFi**
- Give each person the least access they need, not admin.
- Prefer group-based policies once you have more than a few users.
- Back up `conf/users.xml`, `conf/authorizations.xml`, and your flow.
- Keep `nifi.security.allow.anonymous.authentication=false`.

**Operations**
- Watch the logs for repeated failed logins.
- Write down the recovery plan for a lost `Initial Admin Identity` — it involves
  deleting `users.xml` and `authorizations.xml` and restarting.
- Test your upgrade path on a copy first; OIDC behavior has changed between NiFi
  1.x releases.

---

## Appendix: quick reference

**NiFi's OIDC endpoints**

| Path | Purpose |
|---|---|
| `/nifi-api/access/oidc/request` | Starts login; redirects to Keycloak |
| `/nifi-api/access/oidc/callback` | Where Keycloak sends you back |
| `/nifi-api/access/config` | Basic info; handy for checking NiFi is alive |
| `/nifi-api/flow/current-user` | Who am I, and what may I do |

**Keycloak's endpoints**

| Path | Purpose |
|---|---|
| `/realms/{realm}/.well-known/openid-configuration` | The menu of all other endpoints |
| `/realms/{realm}/protocol/openid-connect/auth` | The login page |
| `/realms/{realm}/protocol/openid-connect/token` | Where codes become tokens |
| `/realms/{realm}/protocol/openid-connect/certs` | Public keys for checking signatures |

**Vocabulary**

| Word | Meaning |
|---|---|
| OIDC | OpenID Connect, the login protocol |
| IdP | Identity provider; the system that checks passwords (Keycloak) |
| Client | An app that trusts the IdP (NiFi) |
| Realm | One isolated world of users and apps inside Keycloak |
| Claim | One fact inside a token, like `email` |
| Scope | A request for certain claims |
| Issuer | Who made the token; must match exactly |
| JWT | JSON Web Token; the token format |
| SAN | Subject Alternative Name; the list of names a certificate is valid for |
| Keystore | File holding your own certificate and private key |
| Truststore | File holding certificates you trust from others |
| Authentication | Who are you? |
| Authorization | What may you do? |
