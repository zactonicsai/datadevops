# Moving Apache NiFi 1.28 from FreeIPA LDAP to Keycloak OIDC (with AD Federation)

**Scope of this guide:** only three files —
`conf/login-identity-providers.xml`, `conf/authorizers.xml`, `conf/nifi.properties`.
Plus the two files those settings *write into* (`conf/users.xml`, `conf/authorizations.xml`), because you cannot understand rollback without them.

---

## Table of Contents

- [Part 0 — The 60-Second Version](#part-0--the-60-second-version)
- [Part 1 — Background: What Is Actually Happening](#part-1--background-what-is-actually-happening)
- [Part 2 — Why Do This At All (Pros and Cons)](#part-2--why-do-this-at-all-pros-and-cons)
- [Part 3 — Step-by-Step Worked Example](#part-3--step-by-step-worked-example)
- [Part 4 — File-by-File Detail](#part-4--file-by-file-detail)
- [Part 5 — Initial Admin Identity: The One Thing That Breaks Everything](#part-5--initial-admin-identity-the-one-thing-that-breaks-everything)
- [Part 6 — How to Restore / Roll Back](#part-6--how-to-restore--roll-back)
- [Part 7 — Best Practices Checklist](#part-7--best-practices-checklist)
- [Part 8 — Troubleshooting Table](#part-8--troubleshooting-table)
- [Part 9 — Design Options and Their Trade-offs](#part-9--design-options-and-their-trade-offs)

---

## Part 0 — The 60-Second Version

**What you are changing:**

| File | Before (IPA LDAP) | After (Keycloak OIDC) |
|---|---|---|
| `login-identity-providers.xml` | `ldap-provider` active, points at FreeIPA | **Nothing active.** The whole provider is commented out. |
| `nifi.properties` | `nifi.security.user.login.identity.provider=ldap-provider` | That line is **blank**, and the `nifi.security.user.oidc.*` block is filled in |
| `authorizers.xml` | `Initial Admin Identity` = an LDAP DN or uid | `Initial Admin Identity` = **the exact string Keycloak puts in the ID token claim**, e.g. `jsmith@corp.example.com` |

**The single most important rule:**
`Initial Admin Identity` must be **character-for-character identical** to the identity NiFi receives from Keycloak, and it is only ever read **on a first start where `users.xml` and `authorizations.xml` do not exist**. Get either half wrong and you get a "no permissions" screen with no way in.

---

## Part 1 — Background: What Is Actually Happening

### 1.1 Two different jobs: Authentication and Authorization

Think of NiFi as a building.

- **Authentication (AuthN) = the front door guard.** "Prove you are who you say you are." This produces one thing: a **user identity string**, like `jsmith@corp.example.com`.
- **Authorization (AuthZ) = the keys inside the building.** "Now that I know you're Jane, which rooms may you open?" This is decided by comparing that identity string against policies.

NiFi keeps these completely separate, and they live in different files:

| Job | File that controls it |
|---|---|
| Authentication | `login-identity-providers.xml` **or** the OIDC block in `nifi.properties` |
| Authorization | `authorizers.xml` (which reads/writes `users.xml` and `authorizations.xml`) |

**This is the key insight of the whole migration:** you are only replacing the *front door guard*. The *keys inside* still work exactly the same way. Your process groups, your policies, your flow — none of that changes.

### 1.2 How it worked with FreeIPA LDAP

1. User types a username and password into NiFi's own login page.
2. NiFi (the `ldap-provider` in `login-identity-providers.xml`) takes those credentials and does an LDAP *bind* against FreeIPA.
3. If the bind works, NiFi builds an identity string from the LDAP entry — often the full DN, e.g. `uid=jsmith,cn=users,cn=accounts,dc=corp,dc=example,dc=com`.
4. NiFi mints its own short-lived JWT and hands it to the browser.

NiFi *held the user's password in its own hands*. That is the part we are getting rid of.

### 1.3 How it works with Keycloak OIDC

1. User clicks "Log In" in NiFi. NiFi **redirects the browser to Keycloak**. NiFi never sees a password.
2. Keycloak authenticates the user. Because Keycloak has **User Federation** configured against Active Directory, Keycloak itself does the LDAP bind against AD (or uses Kerberos). AD is still the real source of truth — it's just one hop further away now.
3. Keycloak redirects the browser back to `https://nifi.example.com:8443/nifi-api/access/oidc/callback` with a one-time code.
4. NiFi swaps that code for an **ID token** (a signed JWT) over a back-channel call.
5. NiFi pulls **one claim** out of that token and uses it as the identity string. By default that claim is `email`.
6. NiFi mints its own JWT, as before. From here on, everything downstream is identical to the LDAP case.

```
   Before:   Browser ──password──> NiFi ──LDAP bind──> FreeIPA

   After:    Browser ──redirect──> Keycloak ──LDAP/Kerberos──> Active Directory
                  └──ID token──> NiFi
```

### 1.4 The thing most people get wrong

> **NiFi 1.28 does not use the `groups` claim from the OIDC token to decide permissions.**

You can add a groups mapper in Keycloak, you can see `"groups": ["nifi-admins"]` in the token, and NiFi will still ignore it for authorization. This is a well-known gap in the NiFi 1.x line — <cite index="11-1">authentication via OIDC works, but there is no native support for authorization from the OIDC provider, so authorization has to be defined somewhere else</cite>. Community reports show exactly this symptom: <cite index="14-1">groups arrive in the callback token, then the token is re-minted with an empty groups list and the user lands on "Insufficient Permissions"</cite>.

Group membership for policies must therefore come from a **UserGroupProvider** in `authorizers.xml` — either the file-based one (you type users in by hand / manage them in the UI) or an `LdapUserGroupProvider` that syncs *directly from AD*, bypassing Keycloak. See [Part 9](#part-9--design-options-and-their-trade-offs) for the trade-offs.

### 1.5 What does *not* change

- Cluster node-to-node authentication (still TLS client certificates).
- `nifi.security.keystore*` / `truststore*` settings.
- Your flow (`flow.json.gz` / `flow.xml.gz`).
- The requirement that NiFi run over **HTTPS**. OIDC over plain HTTP will not work.
- NiFi Registry — it has its own separate config with the same pattern.

---

## Part 2 — Why Do This At All (Pros and Cons)

### Pros

| Benefit | What it means in practice |
|---|---|
| **NiFi stops handling passwords** | The password never touches NiFi's JVM or logs. Smaller blast radius if NiFi is compromised. |
| **Real SSO** | A user already logged into Keycloak for other apps lands in NiFi without typing anything. |
| **MFA / conditional access for free** | Enforced centrally in Keycloak. NiFi needs zero changes to gain MFA. |
| **One integration point** | Keycloak federates AD once. Add Okta, Entra ID, or a second AD forest later without touching NiFi. |
| **Central session control** | Disable a user in AD → Keycloak refuses them → NiFi refuses them. |
| **No LDAP bind account inside NiFi** | You delete a long-lived service-account password from `login-identity-providers.xml`. |

### Cons / costs

| Cost | Mitigation |
|---|---|
| **Keycloak becomes a hard dependency.** If Keycloak is down, nobody logs into NiFi. | Keep a **break-glass client-certificate admin** (see Part 7). Cluster Keycloak. |
| **Groups don't flow from the token** (Part 1.4). | Keep an `LdapUserGroupProvider` pointed at AD, or manage groups in the NiFi UI. |
| **The identity string format changes**, so every existing policy referencing the old DN breaks. | Plan the identity mapping *before* cutover (Part 5.3). |
| **Harder to debug.** Failures span three systems (browser redirects, Keycloak, NiFi). | Turn on the debug logging in Part 8. |
| **Automation/scripts using username+password login break.** | Scripts must move to client certificates or a Keycloak service-account token. |
| **Clock skew now matters.** JWT validation fails if NiFi and Keycloak clocks drift. | Enforce NTP on both. |

---

## Part 3 — Step-by-Step Worked Example

This is one complete, concrete example. Do this first, understand it, then read Part 4 for the variations.

### 3.0 The example environment

| Thing | Value used in this guide |
|---|---|
| NiFi URL | `https://nifi.example.com:8443/nifi` |
| NiFi home | `/opt/nifi/nifi-1.28.1` |
| Keycloak base | `https://sso.example.com` |
| Keycloak realm | `corp` |
| Keycloak client ID | `nifi-prod` |
| Keycloak client secret | `s3cr3t-REPLACE-ME` |
| Identifying claim | `email` |
| Admin's email in AD | `jsmith@corp.example.com` |
| AD domain | `corp.example.com` |
| Cluster node DNs | `CN=nifi-node1.example.com, OU=NIFI`, etc. |

**Keycloak side (prerequisite, done before you touch NiFi):**
- Realm `corp` exists, with **User Federation** of type `ldap`, vendor **Active Directory**, syncing users from AD.
- Client `nifi-prod`: Client authentication **ON** (confidential), Standard flow **ON**, Direct access grants **OFF**.
- Valid redirect URI: `https://nifi.example.com:8443/nifi-api/access/oidc/callback`
  For a cluster, add one line per node hostname **and** the load-balancer hostname.
- Valid post-logout redirect URI: `https://nifi.example.com:8443/nifi`
- Web origins: `https://nifi.example.com:8443`
- Confirm the `email` claim is actually populated — if AD users have no `mail` attribute, the login will fail and you must use `preferred_username` instead.

**Verify the discovery URL responds before going further:**

```bash
curl -s https://sso.example.com/realms/corp/.well-known/openid-configuration | head -c 400
```

You should see JSON containing `authorization_endpoint`, `token_endpoint`, `jwks_uri`, and `end_session_endpoint`.

---

### 3.1 Step 1 — Back up everything (do not skip)

```bash
cd /opt/nifi/nifi-1.28.1
sudo systemctl stop nifi        # or ./bin/nifi.sh stop

STAMP=$(date +%Y%m%d-%H%M)
sudo mkdir -p /opt/nifi/backups/$STAMP
sudo cp -p conf/nifi.properties \
           conf/authorizers.xml \
           conf/login-identity-providers.xml \
           conf/users.xml \
           conf/authorizations.xml \
           /opt/nifi/backups/$STAMP/
sudo chmod -R 400 /opt/nifi/backups/$STAMP
ls -l /opt/nifi/backups/$STAMP
```

Those five files are your entire rollback kit. `users.xml` and `authorizations.xml` are the two people forget, and they are the two that matter most.

---

### 3.2 Step 2 — Turn off LDAP in `login-identity-providers.xml`

Open `conf/login-identity-providers.xml` and **comment out the entire `<provider>` block** whose identifier is `ldap-provider`.

**Before:**

```xml
<loginIdentityProviders>
    <provider>
        <identifier>ldap-provider</identifier>
        <class>org.apache.nifi.ldap.LdapProvider</class>
        <property name="Authentication Strategy">SIMPLE</property>
        <property name="Manager DN">uid=nifi-bind,cn=sysaccounts,cn=etc,dc=corp,dc=example,dc=com</property>
        <property name="Manager Password">bindPassword</property>
        <property name="Referral Strategy">FOLLOW</property>
        <property name="Connect Timeout">10 secs</property>
        <property name="Read Timeout">10 secs</property>
        <property name="Url">ldaps://ipa.corp.example.com:636</property>
        <property name="User Search Base">cn=users,cn=accounts,dc=corp,dc=example,dc=com</property>
        <property name="User Search Filter">uid={0}</property>
        <property name="Identity Strategy">USE_DN</property>
        <property name="Authentication Expiration">12 hours</property>
    </provider>
</loginIdentityProviders>
```

**After:**

```xml
<loginIdentityProviders>
    <!--
      DISABLED 2026-08-13 — replaced by Keycloak OIDC (see nifi.properties).
      Kept verbatim for rollback. Do NOT re-enable while the OIDC block in
      nifi.properties is populated: NiFi refuses to start with both configured.

    <provider>
        <identifier>ldap-provider</identifier>
        <class>org.apache.nifi.ldap.LdapProvider</class>
        ... (original content preserved) ...
    </provider>
    -->
</loginIdentityProviders>
```

> ⚠️ **XML comment trap:** an XML comment cannot contain `--`. If your original block has a comment inside it containing `--`, or a password with `--`, the file will not parse. Move the block to a `.disabled` file instead of commenting it if that happens.

**Why comment instead of delete?** Because the exact bind DN, search base, and filter are your rollback path, and reconstructing them from memory at 2 a.m. is miserable.

---

### 3.3 Step 3 — Configure OIDC in `nifi.properties`

Two edits. The first one is the one people forget.

**Edit A — blank out the login identity provider:**

```properties
# BEFORE
nifi.security.user.login.identity.provider=ldap-provider

# AFTER — must be empty
nifi.security.user.login.identity.provider=
```

> 🔴 **If you leave this set AND configure OIDC, NiFi will refuse to start.** NiFi allows exactly one interactive authentication mechanism. The startup error in `logs/nifi-app.log` reads roughly: *"Only one type of login identity provider can be configured at a time."*

**Edit B — fill in the OIDC block:**

```properties
# ---------- OpenId Connect SSO Properties ----------
nifi.security.user.oidc.discovery.url=https://sso.example.com/realms/corp/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
nifi.security.user.oidc.client.id=nifi-prod
nifi.security.user.oidc.client.secret=s3cr3t-REPLACE-ME
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.fallback.claims.identifying.user=preferred_username
nifi.security.user.oidc.truststore.strategy=JDK
nifi.security.user.oidc.token.refresh.window=60 secs
```

Also confirm these are correct — OIDC will not work without them:

```properties
nifi.web.https.host=nifi.example.com
nifi.web.https.port=8443
nifi.web.proxy.host=nifi.example.com:8443,nifi-lb.example.com:8443
nifi.web.proxy.context.path=
```

Leave `nifi.security.user.knox.url` and any SAML properties **blank** — same "only one at a time" rule.

Finally, encrypt the secret rather than leaving it in plain text:

```bash
./bin/encrypt-config.sh -n conf/nifi.properties -l conf/login-identity-providers.xml \
                        -a conf/authorizers.xml -b conf/bootstrap.conf
```

---

### 3.4 Step 4 — Set the Initial Admin in `authorizers.xml`

This is the heart of the migration.

```xml
<authorizers>

    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Legacy Authorized Users File"></property>

        <!-- The human admin, EXACTLY as Keycloak's `email` claim will present them -->
        <property name="Initial User Identity 1">jsmith@corp.example.com</property>

        <!-- Cluster node certificate DNs. Keep these identical to before. -->
        <property name="Initial User Identity 2">CN=nifi-node1.example.com, OU=NIFI</property>
        <property name="Initial User Identity 3">CN=nifi-node2.example.com, OU=NIFI</property>
        <property name="Initial User Identity 4">CN=nifi-node3.example.com, OU=NIFI</property>

        <!-- Optional break-glass certificate admin -->
        <property name="Initial User Identity 5">CN=nifi-breakglass, OU=NIFI</property>
    </userGroupProvider>

    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>

        <!-- THE key line for this migration -->
        <property name="Initial Admin Identity">jsmith@corp.example.com</property>

        <property name="Legacy Authorized Users File"></property>

        <property name="Node Identity 1">CN=nifi-node1.example.com, OU=NIFI</property>
        <property name="Node Identity 2">CN=nifi-node2.example.com, OU=NIFI</property>
        <property name="Node Identity 3">CN=nifi-node3.example.com, OU=NIFI</property>
        <property name="Node Group"></property>
    </accessPolicyProvider>

    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>

</authorizers>
```

And in `nifi.properties`, confirm:

```properties
nifi.security.user.authorizer=managed-authorizer
```

**Rules for `Initial Admin Identity` — memorize these:**

1. It must appear **both** as an `Initial User Identity N` in the user-group provider **and** as the `Initial Admin Identity` in the access policy provider.
2. It must match the token claim **exactly** — case, domain, spacing. `JSmith@Corp.Example.com` ≠ `jsmith@corp.example.com`.
3. It is **only read when `users.xml` and `authorizations.xml` are absent.** If those files already exist from your LDAP era, NiFi reads them and completely ignores everything you just typed. That is the subject of the next step.

---

### 3.5 Step 5 — Deal with the existing `users.xml` and `authorizations.xml`

Because you already ran NiFi with LDAP, both files exist and contain your old DN-shaped identities. Pick one path:

**Path A — Re-seed from scratch (simplest, loses all policies):**

```bash
cd /opt/nifi/nifi-1.28.1/conf
sudo mv users.xml users.xml.ldap-era
sudo mv authorizations.xml authorizations.xml.ldap-era
```
On next start NiFi rebuilds both from the `Initial *` properties. **All component-level policies you built in the UI are gone** and must be recreated. Fine for dev; usually not fine for production.

**Path B — Surgically rename the identities (keeps all policies):**
Edit `users.xml` and change only the `identity` attribute of each human user, leaving the `identifier` UUID untouched. Because `authorizations.xml` references users by that UUID, every policy follows automatically.

```xml
<!-- users.xml : BEFORE -->
<user identifier="a1b2c3d4-0000-1111-2222-333344445555"
      identity="uid=jsmith,cn=users,cn=accounts,dc=corp,dc=example,dc=com"/>

<!-- users.xml : AFTER — same identifier, new identity -->
<user identifier="a1b2c3d4-0000-1111-2222-333344445555"
      identity="jsmith@corp.example.com"/>
```

Do **not** change node/certificate users. Path B is almost always the right answer for production.

> 💡 Whichever path you pick, do it on **every node** of a cluster, and make the files byte-identical.

---

### 3.6 Step 6 — Start and verify

```bash
sudo systemctl start nifi
tail -f /opt/nifi/nifi-1.28.1/logs/nifi-app.log
```

Verification checklist:

1. Log shows `NiFi has started` with no `BeanCreationException` / `AuthorizerFactoryBean` errors.
2. Browse to `https://nifi.example.com:8443/nifi` → you are redirected to the Keycloak login page.
3. Log in as `jsmith` → you land back in the NiFi canvas.
4. Top-right shows the identity **`jsmith@corp.example.com`** — if it shows anything else, that other string is what belongs in `Initial Admin Identity`.
5. The hamburger menu shows **Users** and **Policies** (proof the admin policies bound correctly).
6. `conf/users.xml` now contains your identity; `conf/authorizations.xml` contains `/flow`, `/tenants`, `/policies`, `/controller` policies referencing your UUID.
7. On a cluster: all nodes connected, no "Untrusted proxy" errors.

---

## Part 4 — File-by-File Detail

### 4.1 `login-identity-providers.xml`

**What it is for:** *username + password* login mechanisms that NiFi itself performs — LDAP and Kerberos. Nothing else.

**What it must look like after migration:** every `<provider>` commented out, or the file left with just its empty root element. The `single-user-provider` (dev default) must also be gone.

| Situation | Result |
|---|---|
| `ldap-provider` active + OIDC configured | ❌ NiFi refuses to start |
| Nothing active + OIDC configured | ✅ Correct |
| Nothing active + no OIDC | ❌ No way to log in at all (cert-only) |

The file may keep commented-out content safely — NiFi only instantiates a provider if it is (a) uncommented **and** (b) named in `nifi.security.user.login.identity.provider`.

---

### 4.2 `nifi.properties` — OIDC property reference

| Property | Example | Notes |
|---|---|---|
| `nifi.security.user.login.identity.provider` | *(blank)* | **Must be blank.** The #1 startup failure. |
| `nifi.security.user.oidc.discovery.url` | `https://sso.example.com/realms/corp/.well-known/openid-configuration` | Presence of this value is what switches OIDC on. Must be reachable from every NiFi node. |
| `nifi.security.user.oidc.connect.timeout` | `10 secs` | Raise from the default `5 secs` on slow networks. |
| `nifi.security.user.oidc.read.timeout` | `10 secs` | Same. |
| `nifi.security.user.oidc.client.id` | `nifi-prod` | From the Keycloak client. |
| `nifi.security.user.oidc.client.secret` | `s3cr3t...` | Keycloak client → Credentials tab. Encrypt it. |
| `nifi.security.user.oidc.preferred.jwsalgorithm` | `RS256` | <cite index="7-1">If blank it defaults to RS256; a value of `none` makes NiFi attempt to validate unsecured tokens, and other values are parsed as RSA or EC algorithms used with the JWK from the `jwks_uri` in the discovery metadata</cite>. Never use `none`. |
| `nifi.security.user.oidc.additional.scopes` | `profile,email` | `openid` is always requested automatically. Add `groups` only if you have built a custom group provider that consumes it. |
| `nifi.security.user.oidc.claim.identifying.user` | `email` | <cite index="7-1">The claim identifying the user to be logged in; the default is `email`, and it may need to be requested via the additional scopes property</cite>. **This value determines your identity string, so it determines `Initial Admin Identity`.** |
| `nifi.security.user.oidc.fallback.claims.identifying.user` | `preferred_username` | Comma-separated. Used when the primary claim is missing — a real risk with AD users lacking a `mail` attribute. |
| `nifi.security.user.oidc.truststore.strategy` | `JDK` | `JDK` = trust the Java CA bundle (right for a publicly-signed Keycloak). `NIFI` = use NiFi's own truststore (right for an internal/private CA — import the Keycloak CA there). |
| `nifi.security.user.oidc.token.refresh.window` | `60 secs` | How early NiFi tries to refresh before token expiry. |
| `nifi.web.proxy.host` | `nifi.example.com:8443,nifi-lb.example.com:8443` | Every hostname:port a browser or LB may use. Missing entries → "System Error" / blank page after callback. |

**Choosing the identifying claim — pros and cons:**

| Claim | Identity looks like | Pros | Cons |
|---|---|---|---|
| `email` (default) | `jsmith@corp.example.com` | Human-readable; stable-ish; matches AD `mail`; reads naturally in policy lists | Breaks if a user has no email or changes email/surname |
| `preferred_username` | `jsmith` or `jsmith@CORP.EXAMPLE.COM` | Always present; maps cleanly to AD `sAMAccountName` | Format varies with Keycloak's username-mapping config; can collide across federated sources |
| `sub` | `f7b1c...` (UUID) | Truly immutable — survives renames | Policy screens become unreadable UUIDs; support nightmare |

**Recommendation:** use `email` with `preferred_username` as fallback, and use identity mapping (below) to normalize.

**Identity mapping (optional but powerful).** These normalize identity strings so the same human coming in via certificate and via OIDC ends up as one NiFi user:

```properties
# Lower-case everything and strip the AD domain from OIDC identities
nifi.security.identity.mapping.pattern.oidc=^(.*?)@corp\\.example\\.com$
nifi.security.identity.mapping.value.oidc=$1
nifi.security.identity.mapping.transform.oidc=LOWER
```

With that in place, the token claim `JSmith@corp.example.com` becomes the NiFi identity `jsmith` — and **that** shorter string is then what must go in `Initial Admin Identity`. Decide on mapping *before* first start, and verify the final rendered identity in the NiFi UI rather than assuming.

---

### 4.3 `authorizers.xml` — the three moving parts

```
userGroupProvider   → WHO exists (users and groups)
accessPolicyProvider → WHAT each user/group may do
authorizer          → ties them together (managed-authorizer)
```

**Provider choices for the userGroupProvider:**

| Provider | Where users come from | Editable in UI? | Fits OIDC? |
|---|---|---|---|
| `FileUserGroupProvider` | `users.xml` | ✅ Yes | ✅ Yes — the default choice |
| `LdapUserGroupProvider` | Direct LDAP sync (point it at **AD**, not Keycloak) | ❌ Read-only | ✅ Yes, for groups |
| `CompositeConfigurableUserGroupProvider` | One writable + one or more read-only | Partly | ✅ Best of both |

**Composite example** — file-based users *plus* AD groups, which is the usual production shape:

```xml
<userGroupProvider>
    <identifier>file-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
    <property name="Users File">./conf/users.xml</property>
    <property name="Initial User Identity 1">jsmith@corp.example.com</property>
</userGroupProvider>

<userGroupProvider>
    <identifier>ad-user-group-provider</identifier>
    <class>org.apache.nifi.ldap.tenants.LdapUserGroupProvider</class>
    <property name="Authentication Strategy">LDAPS</property>
    <property name="Manager DN">CN=nifi-bind,OU=Service Accounts,DC=corp,DC=example,DC=com</property>
    <property name="Manager Password">bindPassword</property>
    <property name="Url">ldaps://dc1.corp.example.com:636</property>
    <property name="Page Size">500</property>
    <property name="Sync Interval">30 mins</property>

    <property name="User Search Base">OU=Users,DC=corp,DC=example,DC=com</property>
    <property name="User Object Class">user</property>
    <property name="User Search Scope">SUBTREE</property>
    <!-- CRITICAL: must produce the SAME string as the OIDC claim -->
    <property name="User Identity Attribute">mail</property>
    <property name="User Group Name Attribute">memberOf</property>

    <property name="Group Search Base">OU=Groups,DC=corp,DC=example,DC=com</property>
    <property name="Group Object Class">group</property>
    <property name="Group Name Attribute">cn</property>
    <property name="Group Member Attribute">member</property>
</userGroupProvider>

<userGroupProvider>
    <identifier>composite-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.CompositeConfigurableUserGroupProvider</class>
    <property name="Configurable User Group Provider">file-user-group-provider</property>
    <property name="User Group Provider 1">ad-user-group-provider</property>
</userGroupProvider>

<accessPolicyProvider>
    <identifier>file-access-policy-provider</identifier>
    <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
    <property name="User Group Provider">composite-user-group-provider</property>
    <property name="Authorizations File">./conf/authorizations.xml</property>
    <property name="Initial Admin Identity">jsmith@corp.example.com</property>
    <property name="Node Identity 1">CN=nifi-node1.example.com, OU=NIFI</property>
</accessPolicyProvider>
```

> 🔴 **The identity-alignment trap.** If `User Identity Attribute` is `sAMAccountName` (→ `jsmith`) but the OIDC claim is `email` (→ `jsmith@corp.example.com`), NiFi sees **two different people**. The user logs in successfully and gets none of their group's permissions. Set `User Identity Attribute` to `mail`, or use identity mapping to make both sides collapse to the same string.

**Other `authorizers.xml` notes:**

- `Node Identity N` grants each cluster node the "proxy user requests" policy. Unchanged by this migration — do not remove them.
- `Node Group` is an alternative to listing node identities individually.
- `Legacy Authorized Users File` should stay empty (it is for NiFi 0.x upgrades).
- `authorizers.xml` must be **identical on every node** of a cluster.

---

## Part 5 — Initial Admin Identity: The One Thing That Breaks Everything

### 5.1 What it actually does

On startup, `FileAccessPolicyProvider` checks whether `authorizations.xml` exists.

- **Exists** → load it. `Initial Admin Identity` is **ignored entirely**.
- **Does not exist** → create it, and grant the `Initial Admin Identity` the bootstrap policies:
  `/flow` (read), `/tenants` (read+write), `/policies` (read+write), `/controller` (read+write), plus root process group read/write.

Likewise `FileUserGroupProvider` only reads `Initial User Identity N` when `users.xml` is absent.

**Mental model:** these are *seed* values, like the admin password you set when first installing a database. Changing them later does nothing on its own.

### 5.2 The three failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Login succeeds, then **"Insufficient Permissions"** / "Unable to view the user interface" | Identity string mismatch, or files were pre-existing so seeding never ran | Read the exact identity from the error message or `nifi-user.log`, then use Part 6.3 or 6.4 |
| Startup fails, `authorizers.xml` bean error | `Initial Admin Identity` present but not listed as an `Initial User Identity` | Add it to the user group provider too |
| Admin works but group policies do nothing | Groups came from the OIDC token (ignored) or identity attribute mismatch | Part 4.3 |

### 5.3 Getting the string exactly right — do this *before* cutover

Decode a real token from Keycloak and look at the claim with your own eyes:

```bash
# Requires Direct Access Grants temporarily enabled on a test client
curl -s -X POST \
  https://sso.example.com/realms/corp/protocol/openid-connect/token \
  -d grant_type=password -d client_id=nifi-test \
  -d username=jsmith -d 'password=***' \
  | python3 -c "import sys,json,base64; t=json.load(sys.stdin)['id_token']; p=t.split('.')[1]; print(json.dumps(json.loads(base64.urlsafe_b64decode(p+'=='*(-len(p)%4))),indent=2))"
```

Look for the line `"email": "jsmith@corp.example.com"`. **Copy and paste that value** into `authorizers.xml` — do not retype it.

If you cannot get a token, the empirical method works too: configure OIDC, start NiFi, log in, and read the identity NiFi reports in the "Insufficient Permissions" banner or in `logs/nifi-user.log`. That string is authoritative. Then apply Part 6.3.

---

## Part 6 — How to Restore / Roll Back

### 6.1 What "restore" can mean

| Scenario | Section |
|---|---|
| "Undo everything, go back to IPA LDAP" | 6.2 |
| "OIDC works but nobody has admin rights" | 6.3 (nuclear) or 6.4 (surgical) |
| "I'm locked out entirely and Keycloak is down" | 6.5 |
| "One node in the cluster is out of sync" | 6.6 |

### 6.2 Full rollback to FreeIPA LDAP

```bash
sudo systemctl stop nifi
cd /opt/nifi/nifi-1.28.1

STAMP=<the-backup-you-took-in-step-3.1>
sudo cp -p /opt/nifi/backups/$STAMP/nifi.properties                conf/
sudo cp -p /opt/nifi/backups/$STAMP/authorizers.xml               conf/
sudo cp -p /opt/nifi/backups/$STAMP/login-identity-providers.xml  conf/
sudo cp -p /opt/nifi/backups/$STAMP/users.xml                     conf/
sudo cp -p /opt/nifi/backups/$STAMP/authorizations.xml            conf/
sudo chown nifi:nifi conf/*.xml conf/nifi.properties

sudo systemctl start nifi
```

Then verify these four things are true again:

1. `login-identity-providers.xml` → `ldap-provider` block **uncommented**.
2. `nifi.properties` → `nifi.security.user.login.identity.provider=ldap-provider`.
3. `nifi.properties` → the entire `nifi.security.user.oidc.*` block **blank** (blanking `discovery.url` alone is enough to disable OIDC, but blank them all to avoid confusion).
4. `users.xml` / `authorizations.xml` are the LDAP-era copies.

**On a cluster:** restore on every node, keep the files identical, then start nodes one at a time and confirm each joins before starting the next.

**Rollback rehearsal is mandatory.** Practice 6.2 in a non-production instance *before* the production cutover, timed. A rollback you have never executed is a hope, not a plan.

### 6.3 Re-seed the initial admin (nuclear — destroys all policies)

Use when you are locked out and can afford to rebuild policies (dev/test, or a NiFi with few custom policies).

```bash
sudo systemctl stop nifi
cd /opt/nifi/nifi-1.28.1/conf

# Never delete — always move, so you can go back
sudo mv users.xml          users.xml.bak-$(date +%s)
sudo mv authorizations.xml authorizations.xml.bak-$(date +%s)

# Fix the identity strings in authorizers.xml to the verified value, then:
sudo systemctl start nifi
```

NiFi rebuilds both files from the `Initial *` properties. **Everything you configured in the UI Policies screens is lost.** Component-level grants must be recreated by hand.

**Cluster:** do this on all nodes with identical files, then start node 1, wait for it to elect, then the rest.

### 6.4 Surgical fix — keep every policy (preferred in production)

Because `authorizations.xml` refers to users by UUID, you can rename or add an identity without disturbing a single policy.

**To rename an existing admin to their OIDC identity:**

```xml
<!-- conf/users.xml -->
<user identifier="a1b2c3d4-0000-1111-2222-333344445555"
      identity="jsmith@corp.example.com"/>   <!-- was the old LDAP DN -->
```

**To add a brand-new admin (generate a fresh UUID):**

```bash
uuidgen   # e.g. 9f3c21ae-77aa-4c10-b0b1-6ee7d2a10f42
```

```xml
<!-- 1. add to users.xml -->
<user identifier="9f3c21ae-77aa-4c10-b0b1-6ee7d2a10f42"
      identity="newadmin@corp.example.com"/>
```

```xml
<!-- 2. add that UUID to the admin policies in authorizations.xml -->
<policy identifier="..." resource="/flow" action="R">
    <user identifier="9f3c21ae-77aa-4c10-b0b1-6ee7d2a10f42"/>
</policy>
```

Repeat for `/flow` (R), `/tenants` (R,W), `/policies` (R,W), `/controller` (R,W), and the root process group resource. NiFi must be **stopped** while you edit; it caches and rewrites these files. Copy the edited pair to every node.

### 6.5 Break-glass access when Keycloak is unavailable

Client-certificate authentication in NiFi is **always active** and completely independent of OIDC. This is your emergency door.

1. Issue a client certificate, e.g. `CN=nifi-breakglass, OU=NIFI`, signed by a CA in NiFi's truststore.
2. Add that DN as an `Initial User Identity` **and** give it admin policies (via seeding or 6.4).
3. Store the PKCS#12 in your password vault, not on the NiFi host.
4. To use: import into the browser, browse to NiFi, select the certificate when prompted.

Test this *before* you need it. Rotate it annually.

### 6.6 Cluster-specific restore notes

- `authorizers.xml`, `users.xml`, and `authorizations.xml` must be **byte-identical across nodes**. Mismatches cause nodes to disconnect with authorization inconsistency errors.
- Node certificate DNs must remain in both `Initial User Identity N` and `Node Identity N`. Losing them produces "Untrusted proxy CN=..." errors.
- Recovery order: stop all → fix all → start one → confirm connected → start the rest.

---

## Part 7 — Best Practices Checklist

**Before cutover**
- [ ] Rehearse the whole migration *and the rollback* in a non-production NiFi.
- [ ] Decode a real Keycloak ID token and copy the exact claim value (Part 5.3).
- [ ] Confirm every AD-federated user actually has the claim populated.
- [ ] Verify NTP on Keycloak and all NiFi nodes.
- [ ] Create the break-glass certificate admin **first**, and test it.
- [ ] Take the five-file backup (Part 3.1) and store it off-host.
- [ ] Schedule a maintenance window — NiFi must restart.

**During**
- [ ] Change one thing at a time; restart and verify between changes where practical.
- [ ] Keep the old LDAP config commented rather than deleted.
- [ ] Prefer the surgical identity rename (6.4) over re-seeding (6.3) in production.

**After**
- [ ] Encrypt the client secret with `encrypt-config.sh`.
- [ ] Confirm file permissions: `chown nifi:nifi conf/* && chmod 600 conf/nifi.properties conf/authorizers.xml`.
- [ ] Put `conf/` under version control **with secrets excluded**.
- [ ] Document the identity format (`email`, mapped or not) in your runbook — the next person will need it.
- [ ] Set a short-ish Keycloak SSO session idle timeout; NiFi honours token expiry.
- [ ] Add monitoring for Keycloak availability, since NiFi logins now depend on it.
- [ ] Re-test break-glass access after every NiFi upgrade.

---

## Part 8 — Troubleshooting Table

| Symptom | Likely cause | Fix |
|---|---|---|
| NiFi won't start; "only one login identity provider" | `nifi.security.user.login.identity.provider` still set | Blank it (3.3 Edit A) |
| Not redirected to Keycloak; still see NiFi login form | `discovery.url` blank/unreachable, or a login provider still active | Curl the discovery URL from the NiFi host |
| Redirect loop | Clock skew, or cookie blocked on HTTP | Fix NTP; ensure HTTPS end-to-end |
| "Invalid redirect_uri" (shown by Keycloak) | Redirect URI not registered | Add `https://<host>:8443/nifi-api/access/oidc/callback` in the Keycloak client |
| Blank page / "System Error" after callback | `nifi.web.proxy.host` missing the host:port used | Add every hostname:port including the LB |
| TLS handshake error to Keycloak | Wrong `truststore.strategy` | Internal CA → set `NIFI` and import the CA; public CA → `JDK` |
| Login OK, "Insufficient Permissions" | Identity mismatch, or policies were never seeded | Part 5.2, then 6.3 or 6.4 |
| Identity shows as a UUID | `claim.identifying.user` resolving to `sub` | Set it to `email` and ensure the scope is requested |
| Group policies have no effect | OIDC groups claim is ignored by NiFi 1.x | Use `LdapUserGroupProvider` against AD (Part 4.3) |
| "Untrusted proxy CN=..." on a cluster | Node identity missing from `authorizers.xml` | Restore `Node Identity N` entries |

**Useful log settings** in `conf/logback.xml` (revert after debugging — these are verbose and can log identity data):

```xml
<logger name="org.apache.nifi.web.security" level="DEBUG"/>
<logger name="org.apache.nifi.authorization" level="DEBUG"/>
```

Watch `logs/nifi-user.log` for the exact identity string NiFi computed — it is the fastest way to resolve mismatches.

---

## Part 9 — Design Options and Their Trade-offs

### Option A — File-based users only (simplest)

`FileUserGroupProvider` alone; admins add users and groups in the NiFi UI.

| Pros | Cons |
|---|---|
| Fewest moving parts, no LDAP credentials in NiFi at all | Manual user management; onboarding/offboarding is a human process |
| Fully editable in the UI | Users disabled in AD still exist as NiFi tenants (they just can't authenticate) |
| Easy to back up (`users.xml` is small and readable) | Doesn't scale past a few dozen users |

**Good for:** small teams, or as the deliberate first step in a phased migration.

### Option B — File users + `LdapUserGroupProvider` against AD (recommended)

Keycloak handles *who you are*; a direct AD sync handles *what group you're in*.

| Pros | Cons |
|---|---|
| Group-based policies work; AD group membership drives access | NiFi still needs an LDAP bind account — you didn't fully eliminate LDAP |
| Users appear automatically; offboarding in AD removes group access | Identity strings must be aligned between the OIDC claim and the LDAP attribute |
| Battle-tested and fully supported in 1.28 | Two directory paths to keep in sync conceptually |

**Good for:** most production deployments. This is the pragmatic answer to the NiFi 1.x group gap.

### Option C — Custom Keycloak UserGroupProvider (custom NAR)

Write or adopt a provider that queries the Keycloak Admin API for users and groups.

| Pros | Cons |
|---|---|
| Truly single source of truth (Keycloak only) | Third-party or in-house code you must maintain and re-validate on every NiFi upgrade |
| No direct AD access needed from NiFi | Needs a privileged Keycloak admin client; larger security review |
| Groups match exactly what Keycloak shows | Not supported by the Apache NiFi project |

**Good for:** organizations with the engineering capacity, or those where NiFi cannot reach AD at all.

### Option D — Upgrade to NiFi 2.x instead

Worth evaluating alongside this work. NiFi 2.x reworked the security stack around standard Spring Security OIDC, and its authorization story around external identity providers is better developed than 1.x. If a NiFi upgrade is already on your roadmap, doing the OIDC migration once — on 2.x — may be cheaper than doing it twice. The trade-off is that 2.x removed many deprecated components and requires Java 21, so it is a real migration project rather than a config change.

---

## Appendix A — Quick Reference Card

```
FILE 1: conf/login-identity-providers.xml
        → comment out ldap-provider. Nothing active.

FILE 2: conf/nifi.properties
        → nifi.security.user.login.identity.provider=        (BLANK!)
        → nifi.security.user.oidc.discovery.url=https://sso.example.com/realms/corp/.well-known/openid-configuration
        → nifi.security.user.oidc.client.id / .client.secret
        → nifi.security.user.oidc.claim.identifying.user=email
        → nifi.web.proxy.host=<every host:port>
        → nifi.security.user.authorizer=managed-authorizer

FILE 3: conf/authorizers.xml
        → Initial User Identity 1 = jsmith@corp.example.com   (the OIDC claim value)
        → Initial Admin Identity  = jsmith@corp.example.com   (identical string!)
        → Node Identity N         = cluster cert DNs (unchanged)

SEED FILES: conf/users.xml + conf/authorizations.xml
        → Initial* values are read ONLY if these two do not exist.
        → Lost admin? Either move them aside (loses policies)
          or edit users.xml identity in place (keeps policies).

KEYCLOAK: redirect URI = https://nifi.example.com:8443/nifi-api/access/oidc/callback

ROLLBACK: restore all five files from backup, restart, verify ldap-provider
          uncommented + login.identity.provider=ldap-provider + oidc block blank.
```

## Appendix B — Glossary

| Term | Plain-English meaning |
|---|---|
| **OIDC** | OpenID Connect — a login standard layered on OAuth 2.0. Your app never sees the password. |
| **ID token** | A signed JWT from Keycloak describing who logged in. |
| **Claim** | One field inside that token (`email`, `preferred_username`, `sub`). |
| **Discovery URL** | The `/.well-known/openid-configuration` address that lists all of Keycloak's other endpoints. |
| **Realm** | A Keycloak tenant — its own users, clients, and settings. |
| **User Federation** | Keycloak feature that pulls users from an external directory such as Active Directory. |
| **Identity string** | The single text value NiFi uses to represent a person everywhere in authorization. |
| **UserGroupProvider** | The `authorizers.xml` component that knows which users and groups exist. |
| **Initial Admin Identity** | Seed value granting first-time admin rights — read **only** when `authorizations.xml` is absent. |
| **Break-glass** | An emergency access path (here, a client certificate) that works when normal login is broken. |

---

*Verify property names and behaviour against the System Administrator's Guide shipped with your exact 1.28.x build (`docs/html/administration-guide.html` inside the NiFi distribution) before applying to production — it is the authoritative reference for the version you are running.*
