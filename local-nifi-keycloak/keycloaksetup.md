# How NiFi and Keycloak Connect: The OIDC Settings and the Realm File, Explained Line by Line

This tutorial explains exactly what the eight `NIFI_SECURITY_USER_OIDC_*` settings in the Docker Compose file do, and how the `realm-nifi.json` file builds the Keycloak side of the handshake. By the end you will see that the two files are **two halves of one contract** — every important line in one has a matching line in the other.

---

## 1. The big picture first: what problem do these settings solve?

Out of the box, NiFi 2.x runs in *single-user mode*: it invents one random username/password and that's it. That's fine for a laptop demo, useless for a team. We want:

- Real named users (Alice, Bob…) managed in **one central place** (Keycloak).
- NiFi to **never see or store passwords**.
- Login through the browser with redirects — the standard **OpenID Connect (OIDC)** dance.

Think of it like a nightclub:

- **NiFi is the club.** It has a bouncer, but the bouncer doesn't keep an ID database.
- **Keycloak is the government ID office.** It knows everyone and issues ID cards.
- **The OIDC settings are the bouncer's instruction card:** "IDs must come from *this* office (discovery URL), we are registered with them as *this* club (client ID + secret), read the person's name from *this* line on the ID (claim), and here's how long to wait on the phone with the office (timeouts)."
- **The realm file is the ID office's records:** "the club called `nifi` is legit, here is its shared password, here is the only door we'll send visitors back to (redirect URI), and here is citizen Alice."

## 2. Step-by-step: the login walkthrough (follow one click through every setting)

Here is what happens, in order, when Alice opens `https://localhost:8443/nifi` — with the exact setting or JSON field that powers each step in **bold**:

**Step 0 — NiFi boots and phones the ID office.**
At startup, NiFi fetches the **`DISCOVERY_URL`** (`http://keycloak:8080/realms/nifi/.well-known/openid-configuration`). Keycloak answers with a JSON "business card" listing everything NiFi needs: the login page URL (*authorization endpoint*), the token-exchange URL (*token endpoint*), the public-keys URL (*JWKS*), and the *issuer* name. One URL configures everything — that's the point of "discovery." The **`CONNECT_TIMEOUT` / `READ_TIMEOUT`** (5 secs each) say how long NiFi waits for this and every later call before giving up.

**Step 1 — Alice arrives with no badge.**
NiFi sees no session cookie → responds "go log in" and redirects her browser to Keycloak's authorization endpoint (learned in Step 0), adding three query parameters: its **`CLIENT_ID`** (`nifi` — "I am the club called nifi"), the scopes it wants (`openid` plus the **`ADDITIONAL_SCOPES`** `email,profile` — "I'd like to see her email and name"), and the redirect URI it wants her sent back to (`https://localhost:8443/nifi-api/access/oidc/callback`).

**Step 2 — Keycloak checks its records (the realm file!).**
Keycloak looks up client `nifi` inside realm `nifi` — the objects created by **`realm-nifi.json`**. It verifies the requested redirect URI is on the client's **`redirectUris`** allow-list. Match → show the login page. No match → the famous error `Invalid parameter: redirect_uri` and the flow stops cold. This allow-list is a security feature: it prevents an attacker from tricking Keycloak into sending Alice's login code to an evil website.

**Step 3 — Alice proves who she is *to Keycloak only*.**
She types `alice` / `password` — checked against the **`users`** entry in the realm file. NiFi is not involved; her password never touches NiFi. Keycloak then redirects her browser back to NiFi's callback URL with a one-time **authorization code** (think: a numbered claim ticket, useless by itself).

**Step 4 — NiFi trades the ticket for the real ID, backstage.**
NiFi's server calls Keycloak's token endpoint *directly* (container-to-container over the Docker network — the browser never sees this) and says: "Here's the code, and here's proof I'm really the nifi club: my **`CLIENT_SECRET`** (`nifi-local-secret`)." Keycloak checks the secret against the **`secret`** field in the realm file. This is why the client secret exists: without it, anyone who stole the code in transit could redeem it. Keycloak responds with an **ID token** — a signed JWT containing claims like `email: alice@example.com`, `name: Alice Example`, `iss` (issuer), `aud` (audience = `nifi`), `exp` (expiry).

**Step 5 — NiFi verifies the ID is genuine.**
NiFi checks the token's digital signature using Keycloak's public keys (from the JWKS URL in Step 0), and checks the issuer and audience match. The **`TRUSTSTORE_STRATEGY: JDK`** setting governs *how NiFi trusts the TLS connection* when making these HTTPS calls to the identity provider — `JDK` means "use Java's built-in list of trusted certificate authorities" (the same list your browser effectively uses). The alternative, `NIFI`, means "only trust certs in NiFi's own truststore." Locally it barely matters (Keycloak is plain HTTP here); in production with a public Keycloak behind an ACM/Let's Encrypt certificate, `JDK` is the setting that just works, while `NIFI` would force you to import the CA into NiFi's truststore.

**Step 6 — NiFi decides what to call her.**
The token contains several name-like claims. **`CLAIM_IDENTIFYING_USER: email`** says: "her NiFi identity is whatever the `email` claim says" → `alice@example.com`. This exact string is then matched (case-sensitively!) against NiFi's authorization records — including `INITIAL_ADMIN_IDENTITY=alice@example.com` — which is why the realm file *must* give Alice an email and mark it **`emailVerified: true`**. Authentication is done (Keycloak's job); authorization begins (NiFi's job).

**Step 7 — Logged in.** NiFi issues its own session, and the canvas loads with `alice@example.com` in the corner. Later, logging out sends the browser to Keycloak's logout endpoint, which is only willing to bounce her back to the URL in the realm file's **`post.logout.redirect.uris`** attribute — the same allow-list idea as Step 2, applied to logout.

## 3. The NiFi side: every environment variable in detail

These env vars are just a Docker convenience — the container's start script copies each one into the matching `nifi.security.user.oidc.*` property in `nifi.properties`. Same knowledge applies to a bare-metal install.

| Env var | `nifi.properties` key | What it really does |
|---|---|---|
| `..._DISCOVERY_URL` | `nifi.security.user.oidc.discovery.url` | **The master switch.** Setting it flips NiFi from single-user mode into OIDC mode. The URL encodes the realm: `/realms/nifi/` — change the realm name in Keycloak and this URL must change too. The `/.well-known/openid-configuration` suffix is an internet standard (RFC 8414); every OIDC provider (Keycloak, Cognito, Okta, Google) publishes this same document, which is why swapping providers only means swapping this URL, ID, and secret. |
| `..._CLIENT_ID` | `...client.id` | NiFi's public name at the ID office. Sent openly in browser URLs — it is *not* a secret. Must equal `clientId` in the realm file. |
| `..._CLIENT_SECRET` | `...client.secret` | NiFi's *password* at the ID office, used only server-to-server in Step 4. Must equal `secret` in the realm file. Because NiFi can keep this confidential (it's a backend server, not JavaScript in a browser), it is a **confidential client** — the strongest client type. |
| `..._CLAIM_IDENTIFYING_USER` | `...claim.identifying.user` | Which token field becomes the NiFi username. `email` is the common choice (human-readable, stable, easy to type into NiFi policies). Alternatives below in §5. There is also a `fallback.claims.identifying.user` property for "use `email`, but if missing fall back to `upn`" setups. |
| `..._ADDITIONAL_SCOPES` | `...additional.scopes` | Extra permission "categories" NiFi requests beyond the mandatory `openid`. `email` and `profile` are standard OIDC scopes that unlock the email/name claims. Without the `email` scope, some providers omit the `email` claim entirely — and then Step 6 fails with a confusing "unable to determine identity" error. Cheap insurance: always request the scope for the claim you identify by. |
| `..._CONNECT_TIMEOUT` / `..._READ_TIMEOUT` | `...connect.timeout` / `...read.timeout` | How long NiFi waits to open a connection to Keycloak / to receive its reply. NiFi duration syntax (`5 secs`). Too short + slow network = flaky logins; too long = users staring at a spinner when Keycloak is down. 5 seconds is a sane local value; 10 secs is typical in production. |
| `..._TRUSTSTORE_STRATEGY` | `...truststore.strategy` | `JDK` = trust the standard certificate authorities; `NIFI` = trust only NiFi's own truststore (for private/internal CAs). See Step 5. |

**Two settings that are conspicuously *not* here, and why:**
- The callback path (`/nifi-api/access/oidc/callback`) is **hard-coded into NiFi** — you never configure it on the NiFi side, you only *copy it into Keycloak's allow-list*.
- There is no "OIDC on/off" flag — the presence of a discovery URL *is* the on switch.

## 4. The Keycloak side: `realm-nifi.json` field by field

Keycloak's `--import-realm` startup flag reads every JSON file in `/opt/keycloak/data/import` and creates the described objects **once, on first boot** (an existing realm is not overwritten — hence `docker compose down -v` for a clean re-import). This file is "identity as code": the same declarative idea as Terraform, applied to Keycloak. In the AWS tutorial the identical objects are created by Ansible's `keycloak_realm`/`keycloak_client` modules; the JSON import is the zero-dependency local equivalent.

### 4.1 The realm — the container for everything

```json
"realm": "nifi",
"enabled": true,
"registrationAllowed": false,
```

- **`realm: nifi`** — a realm is an isolated universe of users + clients + settings. Its name appears **inside NiFi's discovery URL** (`/realms/nifi/`) — the first of the matching pairs. We never put apps in Keycloak's built-in `master` realm (that one governs Keycloak itself; separate universe = smaller blast radius).
- **`registrationAllowed: false`** — no self-service "create account" link on the login page. Only an admin creates users. Flip to `true` for open sign-up scenarios.

### 4.2 The client — NiFi's registration card

```json
"clientId": "nifi",
"protocol": "openid-connect",
"publicClient": false,
"secret": "nifi-local-secret",
```

- **`clientId`** must equal NiFi's `CLIENT_ID`. **`protocol`** picks OIDC rather than the older SAML.
- **`publicClient: false`** = *confidential* client: it possesses a **`secret`**, which must equal NiFi's `CLIENT_SECRET`. (A *public* client — a mobile app or pure browser app — cannot hide a secret, so it gets none and must use extra protections like PKCE. NiFi is a server, so it takes the stronger option.)

```json
"standardFlowEnabled": true,
"implicitFlowEnabled": false,
"directAccessGrantsEnabled": false,
"serviceAccountsEnabled": false,
```

These four switches enable/disable the four ways a client may obtain tokens — a perfect example of **least privilege**: turn on exactly one.

| Flow | Setting | What it is | Why our choice |
|---|---|---|---|
| Authorization Code | `standardFlowEnabled: true` | The redirect dance in §2 | **The** secure browser-login flow; the only one NiFi needs |
| Implicit | `implicitFlowEnabled: false` | Ancient shortcut: token delivered in the browser URL | Deprecated by the OAuth 2.0 Security Best Current Practice — tokens leak via URLs/history. Always off |
| Direct Access Grants | `directAccessGrantsEnabled: false` | App collects the password itself and POSTs it to Keycloak | Defeats SSO's whole purpose (app sees the password), breaks MFA. Off unless you have a legacy reason |
| Service Accounts | `serviceAccountsEnabled: false` | The *client itself* logs in (machine-to-machine, no human) | NiFi logs humans in; not needed. Turn on only for API-bot clients |

```json
"redirectUris": ["https://localhost:8443/nifi-api/access/oidc/callback"],
"webOrigins": ["https://localhost:8443"],
"attributes": { "post.logout.redirect.uris": "https://localhost:8443/nifi-api/access/oidc/logoutCallback" }
```

- **`redirectUris`** — the login-return allow-list checked in Step 2. Exact-match, which is why opening NiFi at `https://127.0.0.1:8443` fails while `https://localhost:8443` works: to Keycloak those are different strings. In production this becomes `https://nifi.example.com/nifi-api/access/oidc/callback`. Wildcards (`https://localhost:8443/*`) are allowed by Keycloak but are a bad practice — the wider the allow-list, the more room for redirect attacks.
- **`webOrigins`** — the CORS allow-list: which website origins may make JavaScript calls to Keycloak. Set to NiFi's origin.
- **`post.logout.redirect.uris`** — the logout-return allow-list (Step 7). Newer Keycloak versions require it explicitly; forgetting it produces an "Invalid redirect uri" error *at logout* — a classic head-scratcher because login works fine.

### 4.3 The user — Alice's record

```json
"username": "alice",
"email": "alice@example.com",
"emailVerified": true,
"credentials": [{ "type": "password", "value": "password", "temporary": false }]
```

- **`username`** is what she types on the login form. **`email`** is what NiFi will call her — because NiFi's `CLAIM_IDENTIFYING_USER` is `email`. Two different strings doing two different jobs.
- **`emailVerified: true`** — pre-mark the email trusted so Keycloak doesn't demand a verification email (there's no mail server in this sandbox). Some setups won't emit the email claim for unverified addresses, so this flag quietly protects Step 6.
- **`temporary: false`** — otherwise Keycloak forces a password change on first login (a good *production* default for admin-created accounts; skipped here for convenience).

## 5. The contract table — pin this up

Every connection between the two systems, in one view. If login breaks, one of these rows is mismatched:

| # | NiFi setting (compose) | Must match | Keycloak (realm JSON) |
|---|---|---|---|
| 1 | `DISCOVERY_URL` contains `/realms/nifi/` | ↔ | `"realm": "nifi"` |
| 2 | `CLIENT_ID: nifi` | ↔ | `"clientId": "nifi"` |
| 3 | `CLIENT_SECRET: nifi-local-secret` | ↔ | `"secret": "nifi-local-secret"` |
| 4 | NiFi's built-in callback path `/nifi-api/access/oidc/callback` on the host the browser uses | ↔ | `"redirectUris": ["https://localhost:8443/nifi-api/access/oidc/callback"]` |
| 5 | `CLAIM_IDENTIFYING_USER: email` + `ADDITIONAL_SCOPES: email,profile` | ↔ | user has `"email": "alice@example.com"`, `"emailVerified": true` |
| 6 | `INITIAL_ADMIN_IDENTITY=alice@example.com` (authorization side) | ↔ | the value of that same email claim, character for character |
| 7 | NiFi's logout redirect `/nifi-api/access/oidc/logoutCallback` | ↔ | `"post.logout.redirect.uris"` attribute |

## 6. Options, pros and cons

**Which claim should identify users?**

| Claim | Pros | Cons |
|---|---|---|
| `email` (chosen) | Human-readable; easy to type into NiFi policies; globally unique in practice | Changes if the person's email changes (NiFi then sees a "new" user; policies must be re-granted) |
| `preferred_username` | Short; matches the login name | Not guaranteed unique/stable across federated sources; easy to collide |
| `sub` (subject ID) | Truly permanent and unique — the technically "correct" identifier | An opaque UUID; NiFi policy screens become unreadable |

Pragmatic best practice: `email` for human-managed setups; `sub` only if identities must survive email changes and you automate policy management.

**Users vs. groups for authorization.** Granting NiFi policies to individual emails (this tutorial) is simple but doesn't scale. The scalable pattern: create **groups** in Keycloak (`nifi-admins`, `nifi-operators`), add a *group membership mapper* to the client so the token carries a `groups` claim, set `nifi.security.user.oidc.claim.groups=groups` (env: `NIFI_SECURITY_USER_OIDC_CLAIM_GROUPS`), and grant NiFi policies to the groups. Onboarding then becomes "add user to group in Keycloak" — zero NiFi changes.

**JSON import vs. clicking vs. Ansible.** Clicking in the admin console is great for learning and one-offs but unrepeatable. JSON import is perfectly repeatable but only applied at first boot (no drift correction). Ansible's Keycloak modules (used in the AWS tutorial) are repeatable *and* converge an existing realm to the desired state — the production choice.

## 7. Security footnotes on this sandbox (what's deliberately "wrong")

For learning honesty, the local stack cuts four corners you must not cut in production: the client secret is hardcoded in a file (production: generated by Keycloak, stored in Secrets Manager/SSM); Keycloak runs plain HTTP and `start-dev` (production: `start`, TLS at the load balancer, proxy headers, real hostname); passwords are `password`/`admin` (production: strong + MFA for admins); and the discovery URL is `http://` (production: always `https://` — the token exchange must be encrypted in transit).

---

**One-sentence summary:** the eight NiFi variables tell NiFi *where the ID office is, who NiFi is to that office, and which line of the ID card to read a person's name from* — while `realm-nifi.json` writes the office's matching records: the realm (universe), the client (NiFi's registration, secret, and door allow-lists), and the user (Alice, with the email that becomes her NiFi identity).