# NiFi Logins: From Linux IPA to Keycloak
### A plain-English tutorial (with a real, working example)

*Written August 2026. Versions used: Apache NiFi 2.10.0 (released June 18, 2026) and Keycloak 26.7.0 (released July 9, 2026).*

---

## Table of Contents

1. [The whole idea in one story](#1-the-whole-idea-in-one-story)
2. [Meet the three characters](#2-meet-the-three-characters)
3. [The important news you need to know first](#3-the-important-news-you-need-to-know-first)
4. [PART 1 — Build it: one complete working example](#part-1--build-it-one-complete-working-example)
5. [PART 2 — Now the details: how this actually works](#part-2--now-the-details-how-this-actually-works)
6. [PART 3 — Migrating a real system without breaking it](#part-3--migrating-a-real-system-without-breaking-it)
7. [Pros and cons of every option](#pros-and-cons-of-every-option)
8. [Best practices checklist](#best-practices-checklist)
9. [Troubleshooting: the 10 errors everyone hits](#troubleshooting-the-10-errors-everyone-hits)
10. [Glossary](#glossary)

---

## 1. The whole idea in one story

Imagine a big school.

**The school office** keeps a folder for every single student: name, photo, grade, which clubs they're in. The office doesn't teach classes. It just *knows who everyone is*.

> That folder cabinet is **FreeIPA** (also called Red Hat IdM, or what people casually call "Linux IPA").

**The science lab** is a room students want to get into. The lab teacher doesn't keep student folders. When a kid shows up at the door, the teacher has to figure out: *Are you really who you say you are? And are you allowed in here?*

> That lab is **Apache NiFi**.

Right now, your lab teacher walks down the hall to the office and asks about every single student, one at a time. It works, but it's slow, and every room in the school has to do the same walk.

**The new idea:** put a **front desk** at the school entrance. Every student checks in there once. The front desk looks them up in the office cabinet, confirms they're real, and hands them a **wristband** that says who they are and what clubs they're in. Now every room — the lab, the gym, the library — just looks at the wristband. No more hallway walks.

> That front desk is **Keycloak**. The wristband is a **token**.

The office cabinet doesn't go away. Keycloak still asks it who's who. You're not deleting FreeIPA — **you're putting a smart front desk in front of it.**

```
BEFORE:                          AFTER:

  You                              You
   |                                |
   | username + password            | 1. redirected to front desk
   v                                v
 [ NiFi ] ---asks---> [ IPA ]    [ Keycloak ] ---asks---> [ IPA ]
                                    |
                                    | 2. hands you a wristband (token)
                                    v
                                 [ NiFi ] reads the wristband
```

---

## 2. Meet the three characters

### FreeIPA (Linux IPA / Red Hat IdM)

FreeIPA is not one program — it's a bundle, like a school backpack with several things inside:

| What's inside | What it does | Real-world comparison |
|---|---|---|
| **389 Directory Server** (LDAP) | The actual list of users and groups | The filing cabinet |
| **MIT Kerberos KDC** | Hands out "hall passes" (tickets) so you log in once and use many machines | The hall-pass desk |
| **Dogtag CA** | Issues certificates (digital ID cards for servers) | The ID card printer |
| **BIND DNS** | Name lookups | The school directory |
| **SSSD** (on each Linux machine) | The client that talks to all of the above | The kid who runs errands to the office |

When people say "we use IPA for NiFi," they almost always mean one of two things:

- **A)** NiFi shows a username/password box, and NiFi checks that password against IPA's LDAP directory. (Most common.)
- **B)** NiFi used Kerberos, so users didn't type a password at all. (Less common — and see the next section, because this one is in trouble.)

### Apache NiFi

NiFi is a tool that moves and transforms data between systems, driven by a drag-and-drop web canvas. Because that canvas can read databases and write to production systems, **who is allowed in matters a lot.**

NiFi separates two ideas, and mixing them up is the #1 source of confusion:

- **Authentication** = *"Prove you are Maria."* → answers **who**
- **Authorization** = *"Maria is allowed to view this flow but not delete it."* → answers **what**

Think of a concert: authentication is showing your ID at the gate. Authorization is whether your wristband is General Admission or Backstage. Two separate checks, two separate config files in NiFi.

### Keycloak

Keycloak is an open-source **identity provider** (IdP). Its job is to be that front desk. It speaks the two standard "wristband languages" of the modern web:

- **OIDC (OpenID Connect)** — the modern one, built on OAuth 2.0. This is what we'll use.
- **SAML 2** — older, still widely used in enterprises.

Keycloak's superpower for you: **User Federation.** It can log users in against an existing LDAP directory — including FreeIPA — without copying passwords anywhere. <cite index="30-1">Whether you are running OpenLDAP, 389 Directory Server, FreeIPA, or another LDAP-compliant directory, Keycloak's User Federation feature lets you connect to it and authenticate users against your existing directory without migrating user data.</cite>

---

## 3. The important news you need to know first

If you are on, or moving to, **NiFi 2.x**, this changes your plan:

**Kerberos SPNEGO login was removed from NiFi 2.** The NiFi team explained that <cite index="6-1">SPNEGO authentication is not common and requires specialized client browser configuration for access; popular web browsers do not support SPNEGO in the default configuration, and Google Chrome requires either a custom policy or launch from the command line with arguments that list permitted DNS names.</cite> They deprecated it <cite index="2-1">in light of more common Single Sign-On strategies using OpenID Connect and SAML 2</cite>, and <cite index="4-1">NiFi 2.0.0-M4 removed direct framework integration for Kerberos SPNEGO authentication.</cite>

**And the Kerberos username/password provider is on its way out too.** <cite index="8-1">NiFi 2.7.0 deprecated the Kerberos Login Identity Provider for removal</cite>, because <cite index="4-1">it depends on the Spring Security Kerberos library, which has received minimal maintenance over the years.</cite>

**What this means in plain terms:**

- If you were doing Kerberos-based NiFi login → **you must move.** OIDC is the replacement.
- If you were doing LDAP-against-IPA login → still supported, still works, but it's the old way.
- **Keycloak isn't just a nice-to-have anymore. It's the paved road.**

One more version note: <cite index="13-1">NiFi 1.28 is the last minor release of the version 1 series, and the NiFi team strongly encourages users to upgrade to NiFi 2, because multiple fundamental dependencies in NiFi 1 — including Jetty 9.4, Spring Framework 5.3, and AngularJS 1.8 — cannot be upgraded.</cite> If you're still on NiFi 1.x, plan the version upgrade and the auth migration as two separate steps, not one.

---

# PART 1 — Build it: one complete working example

We're going to build the whole thing end to end, in a lab, before touching anything real. **Do this on test machines first.** Every time.

### Our imaginary company

| Thing | Value |
|---|---|
| Domain | `example.com` |
| IPA server | `ipa.example.com` |
| Keycloak server | `sso.example.com` |
| NiFi server | `nifi.example.com` (port 8443) |
| LDAP base DN | `dc=example,dc=com` |
| Our admin user | `maria` |
| Our group | `nifi-admins` |

Replace these everywhere with your real values. Anything in `ANGLE BRACKETS` is a placeholder.

---

## Step 1 — Make sure IPA has a user and a group

On the IPA server, log in as the IPA admin and create what we need:

```bash
kinit admin

# Create a group and a user
ipa group-add nifi-admins --desc "People who can administer NiFi"
ipa user-add maria --first=Maria --last=Gomez --password
ipa group-add-member nifi-admins --users=maria

# Check it worked
ipa user-show maria --all | grep -i memberof
```

You should see `nifi-admins` in the output.

**What just happened:** you put a folder in the filing cabinet and stapled a club membership to it.

---

## Step 2 — Create a read-only "librarian account" in IPA

Keycloak needs to *look things up* in IPA. It should **not** use the `admin` account for that — that's like giving the front desk the principal's master key when all they need is read access to the student list.

FreeIPA has a special place for robot accounts: `cn=sysaccounts,cn=etc,dc=example,dc=com`. There's no `ipa` command for this, so we use raw LDAP:

```bash
ldapmodify -x -D "cn=Directory Manager" -W <<'EOF'
dn: uid=keycloak-bind,cn=sysaccounts,cn=etc,dc=example,dc=com
changetype: add
objectclass: account
objectclass: simplesecurityobject
uid: keycloak-bind
userPassword: PUT-A-LONG-RANDOM-PASSWORD-HERE
passwordExpirationTime: 20380119031407Z
nsIdleTimeout: 0
EOF
```

Test it from the Keycloak machine — **always test the plumbing before you configure the app:**

```bash
ldapsearch -x -H ldaps://ipa.example.com \
  -D "uid=keycloak-bind,cn=sysaccounts,cn=etc,dc=example,dc=com" \
  -w 'PUT-A-LONG-RANDOM-PASSWORD-HERE' \
  -b "cn=users,cn=accounts,dc=example,dc=com" \
  "(uid=maria)" uid cn mail memberOf
```

If that prints Maria's entry, your plumbing is good. If it doesn't, **stop here and fix it** — nothing downstream will work.

> **Analogy:** the librarian account is a library card that can only *read* books, never write in them or take them home.

---

## Step 3 — Give Keycloak the IPA certificate

FreeIPA runs its own certificate authority. Keycloak has never heard of it, so an LDAPS connection will fail with a scary-looking SSL error unless you introduce them.

```bash
# Copy the IPA CA cert to the Keycloak machine
scp root@ipa.example.com:/etc/ipa/ca.crt /tmp/ipa-ca.crt

# Import it into a truststore Keycloak will use
keytool -importcert -noprompt \
  -alias ipa-ca \
  -file /tmp/ipa-ca.crt \
  -keystore /opt/keycloak/conf/truststore.p12 \
  -storetype PKCS12 \
  -storepass CHANGEME
```

Then start Keycloak pointing at it:

```bash
bin/kc.sh start \
  --hostname=https://sso.example.com \
  --https-certificate-file=/opt/keycloak/conf/tls.crt \
  --https-certificate-key-file=/opt/keycloak/conf/tls.key \
  --truststore-paths=/opt/keycloak/conf/truststore.p12
```

> **Analogy:** the certificate is a wax seal. Keycloak needs a copy of the school's official seal so it can tell a real letter from a forged one.

---

## Step 4 — Create a realm in Keycloak

A **realm** is a self-contained world of users, groups, and apps. Never use the `master` realm for real applications — that one is for administering Keycloak itself.

1. Open `https://sso.example.com` → **Administration Console**
2. Top-left dropdown → **Create realm**
3. Name: `company` → **Create**

> **Analogy:** a realm is one school building. The `master` realm is the district office. You don't hold gym class in the district office.

---

## Step 5 — Connect Keycloak to IPA (User Federation)

This is the heart of the whole migration. In realm `company`:

**User federation → Add LDAP provider**, and fill in:

| Field | Value | Why |
|---|---|---|
| Console display name | `freeipa` | Just a label |
| Vendor | **Red Hat Directory Server** | FreeIPA is built on 389 DS |
| Connection URL | `ldaps://ipa.example.com:636` | Encrypted. Never plain `ldap://` |
| Bind type | `simple` | |
| Bind DN | `uid=keycloak-bind,cn=sysaccounts,cn=etc,dc=example,dc=com` | The librarian |
| Bind credential | your random password | |
| Edit mode | **READ_ONLY** | IPA stays the boss. Keycloak never writes back |
| Users DN | `cn=users,cn=accounts,dc=example,dc=com` | Where people live |
| Username LDAP attribute | `uid` | |
| RDN LDAP attribute | `uid` | |
| UUID LDAP attribute | **`ipaUniqueID`** | ← FreeIPA-specific. Get this wrong and users duplicate |
| User object classes | `inetOrgPerson, organizationalPerson` | |
| Import users | `On` | Keeps a local shadow copy for speed |
| Sync registrations | `Off` | Read-only, remember |

Click **Test connection** and **Test authentication**. Both must be green. Then **Save**.

> ⚠️ **The `ipaUniqueID` line is the single most common FreeIPA-specific mistake.** Keycloak's default is `entryUUID`, which FreeIPA doesn't use as its stable identifier. If you leave the default, users can get re-imported as duplicates on every sync.

Now **Mappers → Add mapper** to pull in group memberships:

| Field | Value |
|---|---|
| Name | `ipa-groups` |
| Mapper type | `group-ldap-mapper` |
| LDAP Groups DN | `cn=groups,cn=accounts,dc=example,dc=com` |
| Group Name LDAP Attribute | `cn` |
| Group Object Classes | `groupOfNames` |
| Membership LDAP Attribute | `member` |
| Membership Attribute Type | `DN` |
| User Groups Retrieve Strategy | `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE` |
| Mode | `READ_ONLY` |

Save, then go back to the LDAP provider → **Action → Sync all users**.

Check **Users → View all users**. Maria should be there. Click her → **Groups** tab → `nifi-admins` should be listed.

🎉 **Keycloak can now see into IPA.** Half the job is done.

---

## Step 6 — Register NiFi as a client in Keycloak

A **client** is one application that trusts this front desk.

**Clients → Create client:**

| Field | Value |
|---|---|
| Client type | `OpenID Connect` |
| Client ID | `nifi` |
| Client authentication | **On** (this makes it a confidential client with a secret) |
| Authentication flow | ✅ Standard flow only. **Uncheck Direct access grants** |
| Root URL | `https://nifi.example.com:8443` |
| Valid redirect URIs | `https://nifi.example.com:8443/nifi-api/access/oidc/callback`<br>`https://nifi.example.com:8443/nifi-api/access/oidc/logout/callback` |
| Valid post logout redirect URIs | `https://nifi.example.com:8443/nifi` |
| Web origins | `https://nifi.example.com:8443` |

**Save.** Then go to the **Credentials** tab and copy the **Client secret**. You'll need it in Step 7.

> 🔴 **Clustered NiFi:** every node has its own hostname, and users may land on any of them. Add the callback URIs for *every* node. Missing one produces a maddening "works sometimes" bug. If you put a load balancer in front, register the load balancer's hostname too.

> **Analogy:** the redirect URI list is the front desk's rule that says *"I will only mail wristbands to these exact addresses."* It stops an attacker from redirecting your login to their own site.

### Add the groups to the wristband

By default Keycloak does not put group names in the token. Add them:

**Clients → nifi → Client scopes → nifi-dedicated → Add mapper → By configuration → Group Membership:**

| Field | Value |
|---|---|
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | **Off** ← important |
| Add to ID token | On |
| Add to access token | On |
| Add to userinfo | On |

"Full group path Off" means the token says `nifi-admins`, not `/nifi-admins`. NiFi matches group names as exact text, so the leading slash would break matching.

---

## Step 7 — Point NiFi at Keycloak

Edit `conf/nifi.properties` on **every** NiFi node:

```properties
# --- Web ---
nifi.web.https.host=nifi.example.com
nifi.web.https.port=8443

# --- Turn OFF the old login box ---
nifi.security.user.login.identity.provider=
nifi.security.allow.anonymous.authentication=false
nifi.security.user.authorizer=managed-authorizer

# --- Server TLS (required; OIDC will not work over plain HTTP) ---
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=CHANGEME
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=CHANGEME

# --- OpenID Connect / Keycloak ---
nifi.security.user.oidc.discovery.url=https://sso.example.com/realms/company/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=5 secs
nifi.security.user.oidc.read.timeout=5 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=PASTE-SECRET-FROM-STEP-6
nifi.security.user.oidc.preferred.jwsalgorithm=
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=preferred_username
nifi.security.user.oidc.claim.groups=groups
nifi.security.user.oidc.truststore.strategy=NIFI
nifi.security.user.oidc.token.refresh.window=60 secs
```

Two lines deserve extra attention:

- **`login.identity.provider=` is deliberately empty.** Leaving the old `ldap-provider` value there while OIDC is on causes confusing double-login behavior.
- **`truststore.strategy`** is `JDK` (trust the standard public certificate authorities) or `NIFI` (trust what's in NiFi's own truststore). If Keycloak uses a certificate from your internal CA — very likely if IPA issued it — use `NIFI` and import that CA into `conf/truststore.p12`.

---

## Step 8 — Tell NiFi who the boss is

Authentication is done. Now **authorization**. Edit `conf/authorizers.xml`:

```xml
<authorizers>
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Initial User Identity 1">maria</property>
        <property name="Initial User Identity 2">CN=nifi.example.com, OU=NIFI</property>
    </userGroupProvider>

    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">file-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">maria</property>
        <property name="Node Identity 1">CN=nifi.example.com, OU=NIFI</property>
    </accessPolicyProvider>

    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>
</authorizers>
```

> ⚠️ **`Initial Admin Identity` only takes effect on a first, clean start.** If `conf/users.xml` and `conf/authorizations.xml` already exist, NiFi ignores it. In a lab, delete those two files and restart. **In production, never delete them** — you'd wipe every access policy you've ever created. Add users through the UI instead.

The identity string `maria` must match **exactly** what Keycloak sends in `preferred_username`. Not `Maria`. Not `maria@example.com`. **NiFi identity matching is case-sensitive.**

---

## Step 9 — Start it and log in

```bash
./bin/nifi.sh start
tail -f logs/nifi-app.log
```

Browse to `https://nifi.example.com:8443/nifi`. You should be bounced to the Keycloak login page, type Maria's **IPA password**, and land back inside NiFi as `maria`.

**Pause and notice what just happened:** Maria's password never touched NiFi. It went from her browser to Keycloak, Keycloak checked it against IPA, and NiFi only ever saw a signed token. That's the whole security win in one sentence.

---

## Step 10 — Wire up groups so you stop managing people one at a time

In NiFi: **☰ menu → Users → Add → Group**, name it **exactly** `nifi-admins`.

This step surprises people, so let's be explicit about the rule:

> **NiFi groups must be created inside NiFi with names matching the identity provider's group names.** As one integration write-up puts it: <cite index="60-1">NiFi groups must be defined with names matching the identity provider's groups in order for NiFi to use membership for authorization.</cite> Keycloak sends the *name* in the token; NiFi matches it against a group it already knows about.

Then **☰ → Policies** and grant `nifi-admins` the permissions you want.

From now on: adding a new NiFi admin = `ipa group-add-member nifi-admins --users=carlos`. That's the entire task. No NiFi change, no restart. **That's the payoff.**

---

# PART 2 — Now the details: how this actually works

## The old way, in detail (what you're migrating from)

With the LDAP login provider, `conf/login-identity-providers.xml` looked roughly like this:

```xml
<provider>
    <identifier>ldap-provider</identifier>
    <class>org.apache.nifi.ldap.LdapProvider</class>
    <property name="Authentication Strategy">LDAPS</property>
    <property name="Manager DN">uid=nifi-bind,cn=sysaccounts,cn=etc,dc=example,dc=com</property>
    <property name="Manager Password">secret</property>
    <property name="TLS - Truststore">./conf/truststore.p12</property>
    <property name="TLS - Truststore Type">PKCS12</property>
    <property name="Url">ldaps://ipa.example.com:636</property>
    <property name="User Search Base">cn=users,cn=accounts,dc=example,dc=com</property>
    <property name="User Search Filter">(uid={0})</property>
    <property name="Identity Strategy">USE_USERNAME</property>
    <property name="Authentication Expiration">12 hours</property>
</provider>
```

Note `(uid={0})` — that's the FreeIPA filter. Tutorials written for Active Directory use `(sAMAccountName={0})`, which **will not work against IPA.** Copy-pasting the AD version is a classic time-waster.

The `Identity Strategy` line matters enormously for migration, and we'll come back to it in Part 3.

## The four ways NiFi can know who you are

| Method | How it feels | Status in NiFi 2.10 |
|---|---|---|
| **Single User** | One auto-generated username/password | Default for a fresh install. Dev only |
| **Mutual TLS (client certificates)** | Browser presents a certificate, no typing | Fully supported. Best for machines |
| **LDAP login provider** | Username/password box drawn by NiFi | Supported, but the old way |
| **Kerberos login provider** | Username/password box, checked by KDC | <cite index="8-1">Deprecated for removal as of 2.7.0</cite> |
| **Kerberos SPNEGO** | Silent desktop SSO, no typing | ❌ **Removed in NiFi 2** |
| **OIDC / SAML 2** | Redirect to Keycloak | ✅ The recommended path |

## What's actually in the wristband

An OIDC token is a **JWT** — three chunks of text separated by dots, with a cryptographic signature on the end. Decoded, the middle chunk looks like:

```json
{
  "iss": "https://sso.example.com/realms/company",
  "sub": "f7c2a1b4-...",
  "aud": "nifi",
  "exp": 1754400000,
  "preferred_username": "maria",
  "email": "maria@example.com",
  "groups": ["nifi-admins"]
}
```

- `iss` — who issued it (the front desk)
- `sub` — a permanent internal ID for this person
- `aud` — who it's for
- `exp` — when it stops being valid
- `preferred_username` — what NiFi uses as the identity, because we set `claim.identifying.user`
- `groups` — the club list, because we added that mapper

The signature is the part that makes this safe. NiFi downloads Keycloak's public key (automatically, via that `discovery.url`) and verifies the signature. **A forged wristband fails the check.** This is why NiFi never needs to phone Keycloak on every click.

> **Analogy:** it's a concert wristband with a hologram. The security guard doesn't call the box office — the hologram is enough. And it's stamped with an expiry time, so a wristband from last week is worthless.

## What the discovery URL is for

`https://sso.example.com/realms/company/.well-known/openid-configuration` returns a JSON menu of every endpoint: where to send users to log in, where to fetch tokens, where the signing keys are, where to log out.

Open it in a browser. Seriously — **do this from the NiFi server itself**, with `curl`, before you debug anything else:

```bash
curl -v https://sso.example.com/realms/company/.well-known/openid-configuration
```

If that fails from the NiFi box, nothing else will work. Firewall, DNS, and certificate problems all show up right here.

## The logout question

Logout is the part everyone forgets. There are two of them:

- **NiFi logout** — you're out of NiFi, but Keycloak still thinks you're logged in, so clicking "log in" walks you straight back in with no password. This confuses users, who think logout is broken.
- **Single logout** — NiFi tells Keycloak to end the whole session too.

NiFi handles this for you if Keycloak advertises it: <cite index="21-1">the implementation enables OpenID Connect RP-Initiated Logout 1.0 when the Authorization Server includes an end_session_endpoint element in the OpenID Discovery configuration.</cite> Keycloak does include it. Just make sure you registered that **post-logout redirect URI** back in Step 6.

Related: <cite index="21-1">NiFi tracks the expiration of the application Bearer Token and uses a stored Refresh Token to renew access before the token expires, based on the configured token refresh window.</cite> That's `nifi.security.user.oidc.token.refresh.window=60 secs` — it means a user working on a long flow doesn't get thrown out mid-edit.

## Authentication vs. authorization, one more time

Here's the exact handoff, because this is where most "it should be working!" tickets come from:

```
1. Keycloak verifies Maria's password against IPA        ← AUTHENTICATION
2. Keycloak issues a token saying "preferred_username: maria"
3. NiFi verifies the signature and extracts the string "maria"
   ── everything above this line is done ──
4. NiFi hands the string "maria" to its authorizer        ← AUTHORIZATION
5. The authorizer looks up "maria" in users.xml
6. It finds her groups and checks the policies
7. Allow or deny
```

As a NiFi community expert put it: <cite index="56-1">Authentication and authorization happen in two steps. At the end of authentication, all that is available and passed on for authorization is the user identity.</cite>

So if you can log in but see **"Insufficient Permissions"** or an empty canvas — **authentication succeeded.** Stop debugging Keycloak. Your problem is in `authorizers.xml` or the NiFi Users/Policies screen, and it is almost always a string that doesn't match exactly.

## Bonus: you can keep silent desktop login

NiFi 2 dropped SPNEGO — but **Keycloak didn't.** Keycloak's LDAP federation has an "Allow Kerberos authentication" option. Give Keycloak an IPA service keytab and Kerberos-joined desktops can be logged in silently by Keycloak, which then hands NiFi a normal OIDC token.

```bash
ipa service-add HTTP/sso.example.com
ipa-getkeytab -s ipa.example.com -p HTTP/sso.example.com -k /opt/keycloak/conf/keycloak.keytab
```

**Kerberos SSO survives the migration — it just moves one building over.** Only Keycloak needs the browser configuration now, instead of every application.

---

# PART 3 — Migrating a real system without breaking it

## The trap that catches almost everyone: the identity string

NiFi doesn't store "Maria the person." It stores a **string**, and it compares strings exactly.

Under LDAP with `Identity Strategy = USE_DN`, your `users.xml` is full of entries like:

```
uid=maria,cn=users,cn=accounts,dc=example,dc=com
```

Under OIDC with `preferred_username`, NiFi will receive:

```
maria
```

Those are different strings. **Every single access policy you have will silently stop matching.** People log in fine and see nothing. This is the #1 way a NiFi-to-Keycloak migration goes wrong.

**Three ways to handle it, best first:**

**Option A — Normalize *before* you migrate (recommended).**
While still on LDAP, switch `Identity Strategy` to `USE_USERNAME` and fix up your users/policies to use short names. Verify everything works. *Then* flip to OIDC — and the strings already match. You've turned one risky change into two boring ones.

**Option B — Use NiFi's identity mapping.**
NiFi can rewrite an incoming identity with a regular expression:

```properties
nifi.security.identity.mapping.pattern.dn=^uid=(.*?),cn=users,cn=accounts,dc=example,dc=com$
nifi.security.identity.mapping.value.dn=$1
nifi.security.identity.mapping.transform.dn=LOWER
```

This turns the long DN into `maria` on the way in. Useful, but a regex you'll have to remember in two years.

**Option C — Make Keycloak send what NiFi expects.**
Add a Keycloak mapper that emits the full DN. This works, but it drags the ugly old format into your shiny new system. Not recommended.

## Machines and scripts need a different plan

Humans use browsers, and browsers can follow redirects to Keycloak. **Your automation can't.** Any script hitting `/nifi-api/access/token` with a username and password will break the day you turn off the LDAP provider.

Plan for this **before** cutover:

- **Best:** give each script a **client certificate** and use mutual TLS. IPA's built-in CA can issue these. Register the certificate's subject DN as a NiFi user identity, exactly like a human.
- Inventory every automation *now*. Grep your cron jobs, CI pipelines, and monitoring checks for `access/token`. Finding these on cutover night is not fun.

## A phased plan that lets you sleep

| Phase | What you do | Rollback |
|---|---|---|
| **0. Inventory** | List every user, group, policy, script, and node identity. Back up `users.xml`, `authorizations.xml`, `nifi.properties` | n/a |
| **1. Lab** | Build Part 1 of this tutorial end to end on throwaway VMs | Delete the VMs |
| **2. Normalize identities** | Switch to `USE_USERNAME` on the real system, fix policies, confirm nothing broke | Restore config, restart |
| **3. Stand up Keycloak** | Deploy Keycloak + IPA federation. Nobody uses it yet | It's not connected to anything |
| **4. Certificates for robots** | Move automation to client certs, verify each one | Scripts still have their old credentials |
| **5. Cut over a non-prod NiFi** | Full OIDC on a dev/staging NiFi. Let real users bang on it for a week | Config file swap |
| **6. Cut over production** | Off-hours. One node first if clustered. Keep the old config files on disk | Swap the files back, restart |
| **7. Clean up** | Delete the IPA bind account NiFi used, remove old `ldap-provider` block, update runbooks | — |

**Rollback is genuinely easy here** — it's a config file change and a restart, as long as you didn't delete `users.xml`. Say that out loud in the change-approval meeting; it makes the whole thing an easier sell.

## Two things that do *not* change

Worth saying explicitly, because people worry about them:

1. **Cluster node-to-node communication.** NiFi nodes authenticate to each other with certificates, not user logins. OIDC doesn't touch this. Your `Node Identity` entries stay exactly as they are.
2. **FreeIPA keeps its day job.** SSH logins, sudo rules, `sssd`, host enrollment, POSIX identities — all untouched. **You are not replacing IPA.** You're adding a translator on top of it.

---

## Pros and cons of every option

### Option 1 — Keep NiFi talking straight to IPA over LDAP

**Pros**
- Already works; zero new servers
- One fewer thing to patch and monitor
- No token concepts to learn
- Fine for a single NiFi with 10 users

**Cons**
- Users type their IPA password into every app separately — no SSO
- NiFi holds a bind password to your central directory
- Every new app repeats this whole setup
- No MFA unless IPA is configured for it, and it's clumsy through LDAP simple bind
- Old-fashioned; the NiFi project's direction is clearly elsewhere

### Option 2 — Keycloak in front of IPA (this tutorial)

**Pros**
- **True SSO** across NiFi, Grafana, Superset, internal apps — log in once
- **MFA in one place.** Turn it on in Keycloak and every app gets it, including NiFi, which has no MFA of its own
- Passwords stay in IPA; you didn't migrate a single account
- Aligned with where NiFi is going, now that SPNEGO is gone
- Central audit log of every login attempt across all apps
- Later you can add social login, step-up auth, or another directory without touching NiFi

**Cons**
- A new server to run, patch, back up, and monitor
- **It becomes a single point of failure** — if Keycloak is down, nobody logs into anything. Run at least two nodes
- Real learning curve: realms, clients, scopes, mappers, flows
- Keycloak has no LTS release. <cite index="41-1">Only the newest release receives active development and security fixes</cite>, and <cite index="42-1">there are four minor releases planned per year</cite>. Budget for regular upgrades — or use the commercial Red Hat build, where <cite index="41-1">the 26.x line is supported for at least two years and 27.x and later for three</cite>
- Two hops means two places to check when login breaks

### Option 3 — Keycloak as your only user store (drop IPA)

**Pros**
- One system instead of two

**Cons**
- Your Linux hosts still need POSIX identity, sudo rules, and host-based access control. Keycloak doesn't do those. <cite index="37-1">FreeIPA handles considerably more than what is typically configured in Keycloak</cite>, and provisioning users into it from outside is genuinely awkward
- Migrating password hashes is painful and disruptive
- **Don't do this.** It's the wrong tool swap

### Option 4 — SAML 2 instead of OIDC

**Pros**
- NiFi supports it; sometimes mandated by an existing enterprise IdP

**Cons**
- Heavier: XML, signed assertions, metadata files
- Fiddlier to debug than a JSON token you can paste into a decoder
- No advantage over OIDC for a greenfield Keycloak setup

---

## Best practices checklist

**Security**

- [ ] `ldaps://` (port 636) everywhere. Never plain LDAP, even "just inside the firewall"
- [ ] A dedicated read-only bind account in `cn=sysaccounts`. Never the IPA `admin` account
- [ ] `Edit mode: READ_ONLY` in Keycloak's LDAP provider — IPA stays the source of truth
- [ ] Turn on MFA in Keycloak. This is free security that NiFi cannot give you on its own
- [ ] Client authentication **On**; **Direct access grants Off**. That flow lets an app collect passwords directly, which is exactly what you're trying to stop
- [ ] `nifi.security.allow.anonymous.authentication=false`
- [ ] Keep secrets out of Git. Use environment variables or a vault. Keycloak 26.6 added the ability to manage <cite index="35-1">client secrets through the Vault SPI</cite>
- [ ] Rotate the NiFi client secret on a schedule and write down the procedure
- [ ] Stay current. Both projects ship security fixes constantly — Keycloak 26.5.6 alone <cite index="33-1">fixed CVEs including a blind SSRF via jwks_uri and a refresh-token reuse bypass</cite>

**Reliability**

- [ ] Keycloak in HA (2+ nodes behind a load balancer). It's now on the critical path for every login
- [ ] Back up the Keycloak database — realms, clients, and mappers live there
- [ ] Back up `users.xml` and `authorizations.xml` before *any* NiFi auth change
- [ ] Export your realm config (`kc.sh export`) and keep it in version control

**Operations**

- [ ] Grant permissions to **groups**, never individuals. Then all access management happens with `ipa group-add-member`
- [ ] Pick one identity format and never deviate. Short lowercase usernames are the sane choice
- [ ] Document the exact identity string format in your runbook. Future-you will thank present-you
- [ ] Test with a *normal* user, not just your admin account. Admin accounts hide permission bugs
- [ ] Write down the rollback steps before you start, not during the incident

---

## Troubleshooting: the 10 errors everyone hits

**1. "Unable to validate the access token" / login loop**
Clock skew. Tokens have hard expiry times, so a server whose clock is 90 seconds off will reject perfectly good tokens. Run `chronyc sources` on all three machines. IPA machines usually sync automatically; **your Keycloak box might not be enrolled.**

**2. "Invalid parameter: redirect_uri"**
The URI in Keycloak doesn't exactly match what NiFi sent. Check for a missing port, `http` vs `https`, a trailing slash, or — in a cluster — a node you forgot to register.

**3. Login succeeds, then "Insufficient Permissions"**
Authentication worked; authorization didn't. The identity string in `users.xml` doesn't match what Keycloak sent. Decode the token (paste it into a JWT decoder) and compare `preferred_username` **character for character** with your NiFi user. Watch for capitalization — NiFi is case-sensitive.

**4. Groups aren't working**
Three things must all be true: (a) the Group Membership mapper exists on the client, (b) "Full group path" is **Off**, (c) a group with that **exact name** exists inside NiFi. Missing (c) is the most common. Confirm the `groups` array is actually in the decoded token first.

**5. SSL handshake failure between NiFi and Keycloak**
The IPA-issued certificate isn't trusted. Set `truststore.strategy=NIFI` and import the IPA CA into NiFi's truststore.

**6. Keycloak can't connect to IPA**
Test with `ldapsearch` from the Keycloak box first. Nine times out of ten it's the IPA CA cert missing from Keycloak's truststore, or port 636 blocked.

**7. Users appear twice in Keycloak**
`UUID LDAP attribute` isn't set to `ipaUniqueID`. Fix it, remove the imported users, and re-sync.

**8. `Initial Admin Identity` seems to be ignored**
`users.xml` and `authorizations.xml` already exist. That setting only applies on a clean first start. Add the user through the UI instead.

**9. Everything works, then breaks after a Keycloak upgrade**
Read the upgrade notes. LDAP behavior does change between versions — for instance, Red Hat's build added <cite index="31-1">filtering of LDAP referrals by default to mitigate a CVE</cite>, which can alter how your directory queries resolve.

**10. Automation broke on cutover night**
Your scripts were using the username/password token endpoint, which is gone. Move them to client certificates. (This is why it's Phase 4, not an afterthought.)

**Where to look:** `logs/nifi-user.log` on NiFi — it's specifically the authentication and authorization log, and it's far more useful here than `nifi-app.log`. On Keycloak, the realm's **Events** tab shows every login attempt with a failure reason.

---

## Glossary

| Term | Plain English |
|---|---|
| **LDAP** | The language for asking a directory "who is this person?" |
| **DN (Distinguished Name)** | A person's full address in the directory: `uid=maria,cn=users,...` |
| **Bind** | Logging in to the directory itself |
| **Kerberos** | A hall-pass system: prove yourself once, use many services |
| **SPNEGO** | The trick that lets a *browser* use a Kerberos hall pass. Removed from NiFi 2 |
| **Keytab** | A file holding a service's Kerberos secret. Guard it like a password |
| **SSO** | Single sign-on: log in once, use everything |
| **IdP** | Identity Provider — the front desk. Keycloak |
| **OIDC** | The modern standard for a front desk to vouch for you, built on OAuth 2.0 |
| **SAML 2** | The older XML-based version of the same idea |
| **JWT** | The wristband itself: signed JSON you can decode but not forge |
| **Claim** | One fact inside the wristband (`preferred_username`, `groups`) |
| **Realm** | One self-contained world of users and apps inside Keycloak |
| **Client** | One application registered with Keycloak |
| **Mapper** | A rule for what goes into the wristband |
| **User Federation** | Keycloak reading users from an outside directory instead of storing its own |
| **Authorizer** | The NiFi component that decides what you're allowed to do |
| **Policy** | One NiFi rule: "this group may do this thing to this component" |

---

## The short version

1. **FreeIPA stays.** It remains your source of truth for people and passwords.
2. **Keycloak goes in front of it** as a read-only reader, using a dedicated bind account and `ipaUniqueID`.
3. **NiFi stops asking about passwords entirely** and just reads signed tokens.
4. **The dangerous part isn't the tokens — it's the identity strings.** Normalize them *before* you cut over.
5. **Grant everything to groups**, so future access changes are one IPA command.
6. **Move your scripts to client certificates** before you turn the old login off.

The clock is a real factor here: SPNEGO is already gone from NiFi 2, and <cite index="8-1">the Kerberos Login Identity Provider was deprecated for removal in 2.7.0</cite>. If your NiFi authentication touches Kerberos today, this migration has a deadline attached to it.

---

*Sources: Apache NiFi System Administrator's Guide and project JIRA (NIFI-13296, NIFI-13297, NIFI-15287); Keycloak 26.6 and 26.7 release notes and server administration documentation; FreeIPA documentation.*
