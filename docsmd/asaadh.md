# Tutorial: Apache NiFi Behind an AWS Application Load Balancer with Keycloak Login

## The Big Picture (Read This First!)

We want three things working together:

- **Apache NiFi** = a drag-and-drop "data plumbing" tool. It moves and transforms data between systems. It has a web UI that must be protected by login.
- **Keycloak** = the ticket office. An open-source *identity provider* (IdP) that stores users and checks passwords.
- **AWS Application Load Balancer (ALB)** = the front door. It terminates TLS, load-balances a NiFi cluster, and forwards traffic.

### ⚠️ One Honest Truth Before We Start (This Changes the Design!)

In the Spring Boot version of this pattern, the ALB did the login itself (`authenticate-oidc`) and *passed the user's identity through* to the app in the `x-amzn-oidc-*` headers, and we wrote code to trust those headers.

**NiFi cannot do that.** NiFi is a security-hardened, pre-built application — you don't write its auth code. It will **ignore** the ALB's `x-amzn-oidc-data` header because it only trusts identities from its own supported mechanisms: **its built-in OIDC login, SAML, LDAP, Kerberos, Knox SSO, or client certificates (mTLS)**. There's no setting that says "trust a header from my load balancer." (NiFi *does* have proxy pass-through via the `X-ProxiedEntitiesChain` header — but only when the proxy authenticates to NiFi with a **client TLS certificate**, and an ALB cannot present a client certificate to its targets. So that door is closed too.)

**The correct, supported architecture is therefore:**

```
Browser ──HTTPS──▶ ALB (plain HTTPS forward, no auth action)
                     │  passes X-Forwarded-* headers
                     ▼
                  NiFi (HTTPS :8443)
                     │  NiFi's OWN built-in OIDC client
                     ▼
                  Keycloak (the login page users see)
```

The ALB "passes through" the traffic; **NiFi itself speaks OIDC directly to Keycloak**. Users still get exactly one Keycloak login page and single sign-on with your other apps — the login just happens app-side instead of LB-side. This is the pattern the NiFi community and docs support.

Versions used (current as of July 2026): **NiFi 2.10.0** (the 1.x line is end-of-life — don't deploy it), **Keycloak 26.7.x**.

---

## Part 1: Step-by-Step Setup (One Complete Example)

Goal: `https://nifi.example.com` → ALB → NiFi 2.10 on port 8443, login via Keycloak realm `myrealm`.

### Prerequisites

- Keycloak running at `https://auth.example.com` (see the Spring tutorial's Step 1 — identical)
- ACM certificate for `nifi.example.com`
- EC2/ECS/EKS hosts for NiFi with Java 21
- A VPC, subnets, Route 53 (or other DNS)

### Step 1 — Create the Keycloak Client for NiFi

In the Keycloak Admin Console, realm `myrealm`:

1. Clients → *Create client*
   - Type: **OpenID Connect**, Client ID: `nifi`
   - **Client authentication: ON** (confidential client — NiFi needs a secret)
   - Standard flow: **ON**
2. **Valid redirect URIs** — NiFi's callback paths (these are NiFi's, not the ALB's `/oauth2/idpresponse` from the other tutorial!):
   ```
   https://nifi.example.com/nifi-api/access/oidc/callback
   https://nifi.example.com/nifi-api/access/oidc/logoutCallback
   ```
3. **Valid post logout redirect URIs:** `https://nifi.example.com/*`
4. Save → **Credentials** tab → copy the **Client Secret**.
5. Create a test user with an **email address** and password (NiFi will identify users by a token claim — we'll use `email`).

### Step 2 — Secure NiFi Itself with TLS

A secured NiFi **must** run HTTPS on its own (the ALB→NiFi hop is encrypted too — no plain HTTP targets). Generate a keystore/truststore per node (the NiFi toolkit or your internal CA both work) and in `nifi.properties`:

```properties
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=<password>
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=<password>
```

### Step 3 — Tell NiFi About Keycloak (the OIDC part)

Still in `nifi.properties`:

```properties
# Point at Keycloak's discovery document (note: no /auth prefix in modern Keycloak)
nifi.security.user.oidc.discovery.url=https://auth.example.com/realms/myrealm/.well-known/openid-configuration

nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=<SECRET_FROM_KEYCLOAK>

# Which token claim becomes the NiFi user identity
nifi.security.user.oidc.claim.identifying.user=email

# Ask Keycloak for these scopes (email is needed for the claim above)
nifi.security.user.oidc.additional.scopes=profile,email

# How long NiFi trusts a login before re-checking
nifi.security.user.oidc.connect.timeout=5 secs
nifi.security.user.oidc.read.timeout=5 secs
```

If Keycloak's HTTPS certificate is from a private CA, also set `nifi.security.user.oidc.truststore.strategy=NIFI` and import the CA into NiFi's truststore.

### Step 4 — The Header That Trips Everyone: `nifi.web.proxy.host`

NiFi validates the `Host` header of every request as an anti-abuse measure. Behind an ALB, the browser's Host is `nifi.example.com`, not the instance's name, so NiFi will reject requests with *"request contained an invalid host header"* unless you whitelist it:

```properties
nifi.web.proxy.host=nifi.example.com,nifi.example.com:443
```

(If you served NiFi under a sub-path via ALB rules, you'd also set `nifi.web.proxy.context.path` — with a plain hostname setup you don't need it.)

### Step 5 — Bootstrap the First Admin

NiFi's authorization (who may *do* things) is separate from authentication (who you *are*). In `conf/authorizers.xml`, set the initial admin to your Keycloak user's identity — the **exact** value of the claim you chose (here, the email):

```xml
<userGroupProvider>
    ...
    <property name="Initial User Identity 1">admin@example.com</property>
</userGroupProvider>
<accessPolicyProvider>
    ...
    <property name="Initial Admin Identity">admin@example.com</property>
</accessPolicyProvider>
```

Delete `conf/users.xml` and `conf/authorizations.xml` if they exist from earlier runs (NiFi only reads the initial identities when generating them fresh). Start NiFi.

### Step 6 — Build the ALB (No Auth Action This Time!)

```bash
# Target group: HTTPS all the way to NiFi
aws elbv2 create-target-group \
  --name nifi-tg --protocol HTTPS --port 8443 \
  --vpc-id vpc-xxxx \
  --health-check-protocol HTTPS --health-check-path /nifi/ \
  --matcher HttpCode=200-399

# Sticky sessions: important for NiFi clusters so a user's UI session
# keeps talking to the same node
aws elbv2 modify-target-group-attributes \
  --target-group-arn <TG_ARN> \
  --attributes Key=stickiness.enabled,Value=true \
               Key=stickiness.type,Value=lb_cookie \
               Key=stickiness.lb_cookie.duration_seconds,Value=86400

# Listener: a PLAIN forward. Do NOT add authenticate-oidc here —
# NiFi is doing the OIDC login itself.
aws elbv2 create-listener \
  --load-balancer-arn <ALB_ARN> \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn=<ACM_CERT_ARN> \
  --default-actions Type=forward,TargetGroupArn=<TG_ARN>
```

Add the usual HTTP→HTTPS redirect listener, and point `nifi.example.com` at the ALB in DNS.

Security groups: NiFi's SG allows 8443 **only from the ALB's SG**; cluster nodes additionally allow NiFi's cluster ports from each other.

### Step 7 — Test the Flow

1. Browse to `https://nifi.example.com/nifi` → NiFi immediately redirects you to the **Keycloak login page**.
2. Log in as `admin@example.com` → Keycloak redirects to `/nifi-api/access/oidc/callback` → NiFi exchanges the code for tokens, reads the `email` claim, and issues its own session JWT to your browser.
3. You land on the NiFi canvas with admin rights. Add more users under the Users/Policies menus (their identity = their Keycloak email).
4. Logout (top-right menu) → NiFi calls Keycloak's end-session endpoint → you're logged out of both. (This is nicer than the Spring/ALB version, where logout was manual!)

**What actually happened:** the ALB never knew who you were — it just moved encrypted bytes and stuck you to a node. NiFi acted as the OIDC client, exactly like Spring Security would have in "Option B" of the previous tutorial.

---

## Part 2: Background — Why NiFi Won't Accept ALB Header Pass-Through

- **NiFi's trust model:** every request to a secured NiFi must carry either a NiFi-issued session token (from OIDC/SAML/LDAP/Kerberos login) or a client TLS certificate. Arbitrary HTTP headers are untrusted input — by design, because header-trusting apps behind misconfigured proxies are a classic breach pattern (compare "ALBeast" from the Spring tutorial: even there, the app had to cryptographically verify the header).
- **`X-ProxiedEntitiesChain`:** NiFi *does* support proxies acting on behalf of users — that's how NiFi nodes and NiFi Registry talk to each other. But the proxy must authenticate with **mutual TLS**, and it must be granted the "proxy user requests" policy. ALB terminates TLS toward targets without presenting a client certificate, so it can never qualify. An NGINX/HAProxy box with a client cert *could* — but then you're running your own proxy anyway.
- **Knox SSO:** NiFi can trust JWTs from Apache Knox (`nifi.security.user.knox.*`). Some enterprises chain Keycloak → Knox → NiFi. It works but adds a whole extra gateway product; only sensible if you already run Knox.
- **So "pass-through" here means:** the ALB passes the traffic through untouched, and identity flows Keycloak → NiFi directly.

### Can I still put `authenticate-oidc` on the ALB in front of NiFi?

You *can* add it as a perimeter gate (users must pass Keycloak at the ALB **and then again** inside NiFi — usually silent SSO the second time since it's the same Keycloak session). It adds defense-in-depth for exposed deployments, but it does **not** replace NiFi's own login, and misconfigured, it breaks NiFi's API/token endpoints. Most teams skip it and rely on NiFi's OIDC plus network controls.

---

## Part 3: Best Practices Checklist

- ✅ **NiFi 2.x only** — NiFi 1.x reached end-of-life (1.28.1 was final) and recent CVEs are fixed only in 2.x. Track the latest 2.x release.
- ✅ **HTTPS end-to-end**: ACM cert on the ALB, NiFi's own keystore on 8443. Never an HTTP target group for a secured NiFi.
- ✅ Set `nifi.web.proxy.host` to every hostname (and host:port) users will hit — forgetting it is the most common "it worked until I added the load balancer" failure.
- ✅ **Sticky sessions on** for clusters; health check `/nifi/` with 200–399 accepted.
- ✅ Use a **stable identifying claim** (`email` or `preferred_username`) and keep it consistent forever — NiFi policies are keyed on the exact identity string.
- ✅ Map **Keycloak groups → NiFi groups**: add a Group Membership mapper to the `nifi` client in Keycloak, and NiFi 2.x can read a group claim (`nifi.security.user.oidc.claim.groups=groups`) so authorization scales beyond per-user policies.
- ✅ Lock NiFi's security group to the ALB only; cluster ports only node-to-node.
- ✅ Confidential Keycloak client, exact redirect URIs (no `*` on the callback), rotate the secret on a schedule.
- ✅ Keep clocks in sync (NTP/chrony) — OIDC token validation is time-sensitive.
- ✅ Back up `users.xml`, `authorizations.xml`, `flow.json.gz` — your policies live there.

---

## Part 4: Options Compared — Pros and Cons

### Option A: ALB (plain forward) + NiFi native OIDC → Keycloak ✅ *(this tutorial — recommended)*

**Pros:** fully supported by NiFi; real SSO + clean logout; per-user identity inside NiFi for fine-grained policies and audit; ALB stays simple (TLS, health checks, stickiness).
**Cons:** OIDC config lives in `nifi.properties` on every node (automate it); NiFi must reach Keycloak over the network; private-CA Keycloak certs need truststore work.

### Option B: ALB `authenticate-oidc` in front of NiFi (perimeter gate)

**Pros:** blocks anonymous traffic before it ever reaches NiFi; nice for internet-exposed clusters.
**Cons:** identity does **not** flow into NiFi — you still need Option A (or certs) inside, so it's an *addition*, not a replacement; can interfere with programmatic API clients; two session lifetimes to reason about.

### Option C: Knox SSO chain (Keycloak → Knox → NiFi)

**Pros:** true header/JWT-based pass-through that NiFi actually trusts; central gateway for a whole Hadoop-ish estate.
**Cons:** a whole extra product to run and secure; overkill unless Knox is already deployed.

### Option D: mTLS proxy with `X-ProxiedEntitiesChain` (NGINX/HAProxy, not ALB)

**Pros:** the only genuine "proxy asserts the user" mechanism NiFi supports; used by NiFi's own cluster internals.
**Cons:** you must run and certify your own proxy (ALB can't present client certs); user identity management gets awkward; rarely the right choice for human UI logins.

### Option E: Client certificates for users (no IdP at all)

**Pros:** no Keycloak dependency; strongest cryptographic identity.
**Cons:** distributing/rotating browser certs to humans is painful; no SSO; doesn't answer the original goal.

**Rule of thumb:** for "NiFi on AWS behind an ALB with Keycloak," Option A is the standard answer. Add Option B only if the endpoint is internet-facing and you want a second wall.

---

## Quick Troubleshooting Table

| Symptom | Likely cause |
|---|---|
| "System Error – request contained an invalid host header" | `nifi.web.proxy.host` missing the ALB DNS name (add `host` **and** `host:443`) |
| Keycloak error `Invalid parameter: redirect_uri` | Client's Valid redirect URIs missing `/nifi-api/access/oidc/callback` |
| Login loop / blank canvas after login | Sticky sessions off on a cluster, or clock skew between NiFi and Keycloak |
| "Unknown user" / no permissions after successful login | Identity claim value ≠ `Initial Admin Identity` string (case and claim must match exactly) |
| ALB health checks flapping | Health check using HTTP against HTTPS port, or matcher not allowing 3xx on `/nifi/` |
| Works direct to node, fails via ALB | Target group protocol HTTP instead of HTTPS, or NiFi SG not allowing the ALB SG |
| Logout leaves user signed in | Post-logout redirect URI not whitelisted in the Keycloak client |

---

*Written July 2026. Versions referenced: Apache NiFi 2.10.0, Keycloak 26.7.x. NiFi 1.x is end-of-life — migrate before building anything new on it.*
