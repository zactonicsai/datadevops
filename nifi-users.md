# Setting Up an Admin User and Group Permissions in Apache NiFi 1.28 with Keycloak + Active Directory

**A complete, plain-language guide**

---

## Table of Contents

1. [Before We Start: The Big Picture](#1-before-we-start-the-big-picture)
2. [The Cast of Characters](#2-the-cast-of-characters)
3. [Quick Start: One Complete Working Example](#3-quick-start-one-complete-working-example)
4. [How NiFi Decides Who You Are (Authentication)](#4-how-nifi-decides-who-you-are-authentication)
5. [How NiFi Decides What You Can Do (Authorization)](#5-how-nifi-decides-what-you-can-do-authorization)
6. [All the Ways to Add Users and Groups](#6-all-the-ways-to-add-users-and-groups)
7. [Deep Dive: Automatic Group Sync from Active Directory](#7-deep-dive-automatic-group-sync-from-active-directory)
8. [Giving Permissions to Groups](#8-giving-permissions-to-groups)
9. [Complete Permission Reference](#9-complete-permission-reference)
10. [Keycloak Configuration in Detail](#10-keycloak-configuration-in-detail)
11. [Clusters: Extra Rules](#11-clusters-extra-rules)
12. [Best Practices](#12-best-practices)
13. [Troubleshooting](#13-troubleshooting)
14. [Glossary](#14-glossary)

---

## 1. Before We Start: The Big Picture

### Think of NiFi like a school building

Imagine your school has a front door with a security guard, and inside there are classrooms, the principal's office, the supply closet, and the gym.

Two totally separate questions get asked:

1. **"Who are you?"** — The guard checks your student ID at the front door. This is called **authentication**.
2. **"What are you allowed to open?"** — Once you're inside, your ID badge decides which doors unlock. A student can open classrooms. The principal can open everything. This is called **authorization**.

NiFi works exactly the same way, and this split is *the single most important idea in this whole guide*. Almost every problem people hit is because they mixed the two up.

| Question | Name | Who handles it in our setup |
|---|---|---|
| Who are you? | Authentication | **Keycloak** (which asks Active Directory) |
| What can you do? | Authorization | **NiFi itself** (using its own files) |

### Why do we need Keycloak at all?

Active Directory (AD) is where your company already keeps everyone's username and password. It speaks a protocol called **LDAP**.

NiFi *can* talk to LDAP directly. So why add Keycloak in the middle?

Keycloak gives you things plain LDAP can't:

- **Single sign-on (SSO)** — log in once, get into NiFi, Grafana, Jira, and everything else without typing your password again.
- **Multi-factor authentication** — add a phone code on top of the password.
- **One place to manage login rules** for every app in the company.
- **Modern tokens** instead of passing passwords around.

Keycloak "federates" Active Directory. *Federate* just means Keycloak doesn't store your password — it forwards your login to AD and trusts AD's answer.

### The full journey of one login

```
                                            ┌──────────────────────┐
                                            │  Active Directory    │
                                            │  (the real user list)│
                                            └──────────▲───────────┘
                                                       │ LDAP
                                                       │ "is this password right?"
                                            ┌──────────┴───────────┐
   ┌────────┐   1. "let me in"              │      Keycloak        │
   │ Browser├─────────────────────────────► │  (the ID checker)    │
   │        │   2. redirected to login page │                      │
   │        │ ◄─────────────────────────────┤                      │
   │        │   3. types username+password  │                      │
   │        ├─────────────────────────────► │                      │
   │        │   4. gets a signed ID token   │                      │
   │        │ ◄─────────────────────────────┴──────────────────────┘
   │        │
   │        │   5. hands token to NiFi      ┌──────────────────────┐
   │        ├─────────────────────────────► │       NiFi           │
   │        │                               │  reads the token,    │
   │        │   6. "you are jdoe"           │  finds "jdoe" inside │
   │        │                               │                      │
   │        │   7. NiFi looks up jdoe in    │  users.xml           │
   │        │      its OWN permission files │  authorizations.xml  │
   │        │ ◄─────────────────────────────┤                      │
   │        │   8. shows the canvas         └──────────────────────┘
   └────────┘
```

**Step 7 is where people get stuck.** Keycloak successfully proves you are `jdoe`, but NiFi has never heard of `jdoe` and shows you a blank screen with "Unknown user." Authentication worked. Authorization did not. These are separate problems with separate fixes.

### The one rule that matters most

> **The name Keycloak sends must match the name NiFi has stored — exactly. Same spelling, same capital letters, same everything.**

If Keycloak says `jdoe` and NiFi has `jdoe@company.com` stored, NiFi sees two completely different people. It will not guess. It will not be helpful about it. Half of all NiFi permission problems are this one rule being broken.

---

## 2. The Cast of Characters

Here's every piece of the puzzle and what it does. Keep this handy.

| Piece | What it is | Where it lives |
|---|---|---|
| **Active Directory** | Microsoft's user database. Holds real usernames, passwords, and groups. | Your company's domain controllers |
| **LDAP** | The language used to talk to Active Directory | Network protocol, port 389 or 636 |
| **Keycloak** | Login server. Handles the login page, SSO, MFA. Asks AD to verify passwords. | Its own server |
| **OIDC** | "OpenID Connect" — the modern login protocol Keycloak and NiFi use to talk | Network protocol over HTTPS |
| **ID token** | A small signed digital ID card Keycloak gives you after login | Passed in the browser |
| **Claim** | One fact inside the ID token, like `preferred_username: jdoe` | Inside the token |
| **`nifi.properties`** | NiFi's main settings file. Contains the Keycloak connection settings. | `$NIFI_HOME/conf/` |
| **`authorizers.xml`** | Tells NiFi *where to get* users, groups, and permissions from | `$NIFI_HOME/conf/` |
| **`users.xml`** | The actual list of users and groups NiFi knows about | `$NIFI_HOME/conf/` |
| **`authorizations.xml`** | The actual list of permissions (who can do what) | `$NIFI_HOME/conf/` |
| **`logback.xml`** | Logging settings — used for debugging | `$NIFI_HOME/conf/` |
| **`nifi-user.log`** | The log file that tells you exactly what identity NiFi received | `$NIFI_HOME/logs/` |

### A note on "user group provider" vs "access policy provider"

Inside `authorizers.xml` you'll see three kinds of blocks. Think of a school again:

- **`userGroupProvider`** = the *roster*. A list of who exists and which clubs they're in.
- **`accessPolicyProvider`** = the *rulebook*. "Chess club members may use Room 204."
- **`authorizer`** = the *hall monitor* who reads both and enforces them.

You always need one of each. The roster and rulebook are separate on purpose, because your roster might come from Active Directory while your rulebook lives in a NiFi file.

---

## 3. Quick Start: One Complete Working Example

This section builds one full, working setup from scratch. Follow it exactly, then read the rest of the guide to understand the choices and change them.

### Our example scenario

- Active Directory domain: `example.com`
- Domain controller: `dc01.example.com`
- Keycloak: `https://kc.example.com`, realm named `corp`
- NiFi: single node at `https://nifi.example.com:8443`
- Your admin account in AD: `jdoe`
- An AD group for admins: `NiFi-Admins`
- An AD group for regular users: `NiFi-Developers`

### Step 1 — Prepare Active Directory

Create (or identify) these things in AD:

1. **A service account** NiFi will use to read AD. It needs read-only access. Example: `svc-nifi` with DN `CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com`
2. **Two security groups**, both in `OU=Groups,DC=example,DC=com`:
   - `NiFi-Admins`
   - `NiFi-Developers`
3. **Add yourself** (`jdoe`) to `NiFi-Admins`.

> **Why a service account?** NiFi needs to browse AD to find out who is in which group. AD doesn't allow anonymous browsing. This account only reads — it never writes anything.

Verify from the NiFi server that AD is reachable:

```bash
ldapsearch -x -H ldaps://dc01.example.com:636 \
  -D "CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com" \
  -w 'ServicePassword123' \
  -b "DC=example,DC=com" \
  "(sAMAccountName=jdoe)" sAMAccountName memberOf
```

You should see `jdoe` and a list of `memberOf` lines including `CN=NiFi-Admins,OU=Groups,DC=example,DC=com`. If this command fails, stop here and fix it — nothing downstream will work.

### Step 2 — Connect Keycloak to Active Directory

In the Keycloak admin console:

1. Pick your realm (`corp`) → **User federation** → **Add Ldap provider**
2. Fill in:

| Setting | Value |
|---|---|
| Console display name | `active-directory` |
| Vendor | **Active Directory** |
| Connection URL | `ldaps://dc01.example.com:636` |
| Enable StartTLS | Off (we're already using LDAPS) |
| Bind type | `simple` |
| Bind DN | `CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com` |
| Bind credentials | `ServicePassword123` |
| Edit mode | `READ_ONLY` |
| Users DN | `OU=Users,DC=example,DC=com` |
| Username LDAP attribute | `sAMAccountName` |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |
| Search scope | `Subtree` |
| Trust email | On |

3. Click **Test connection** and **Test authentication**. Both must pass.
4. Save, then click **Action → Sync all users**.

> **Why `sAMAccountName`?** That's the short login name in AD — `jdoe`. The alternative is `userPrincipalName`, which is the email-style name — `jdoe@example.com`. **Pick one and remember it.** It becomes the identity NiFi sees. Mixing them up is the #1 cause of "Unknown user."

### Step 3 — Create the NiFi client in Keycloak

1. **Clients** → **Create client**
2. Client ID: `nifi`, Client type: `OpenID Connect`, click Next
3. **Client authentication: ON** (this makes it a "confidential" client — it gets a secret)
4. **Standard flow: ON**. Direct access grants: ON for now (helpful for debugging; turn it off later).
5. Valid redirect URIs — this must be exact:
   ```
   https://nifi.example.com:8443/nifi-api/access/oidc/callback
   ```
6. Web origins: `https://nifi.example.com:8443`
7. Save, then go to the **Credentials** tab and copy the **Client secret**.

### Step 4 — Configure NiFi to use Keycloak

Edit `$NIFI_HOME/conf/nifi.properties`:

```properties
# ---- Turn OFF other login methods. This MUST be blank when using OIDC. ----
nifi.security.user.login.identity.provider=
nifi.security.user.knox.url=
nifi.security.user.saml.idp.metadata.url=

# ---- Keycloak / OIDC ----
nifi.security.user.oidc.discovery.url=https://kc.example.com/realms/corp/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=PASTE_YOUR_SECRET_HERE
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=preferred_username
nifi.security.user.oidc.fallback.claims.identifying.user=email
nifi.security.user.oidc.truststore.strategy=JDK

# ---- Which authorizer to use ----
nifi.security.user.authorizer=managed-authorizer
nifi.authorizer.configuration.file=./conf/authorizers.xml

# ---- HTTPS (required; OIDC will not work over plain HTTP) ----
nifi.web.https.host=nifi.example.com
nifi.web.https.port=8443
nifi.web.http.host=
nifi.web.http.port=
```

Two settings deserve a closer look:

- **`nifi.security.user.oidc.claim.identifying.user=preferred_username`** — This tells NiFi *which fact in the ID token is the person's name*. With our Keycloak config, `preferred_username` will contain `jdoe`. **Remember this value — it must match what we configure in AD lookups later.**
- **`nifi.security.user.oidc.truststore.strategy=JDK`** — Use `JDK` if Keycloak's HTTPS certificate is from a well-known public authority. Use `NIFI` if it's a private/internal certificate, and then import that certificate into NiFi's truststore.

### Step 5 — Configure the authorizers

Replace `$NIFI_HOME/conf/authorizers.xml` with this. It sets up **both** a file-based roster (for manual additions) **and** an AD-based roster (for automatic group sync), then combines them.

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizers>

    <!-- ========================================================= -->
    <!-- ROSTER PART 1: the file. Editable from the NiFi UI.       -->
    <!-- Holds the bootstrap admin and the cluster nodes.          -->
    <!-- ========================================================= -->
    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>

        <!-- The admin, spelled EXACTLY as Keycloak will send it -->
        <property name="Initial User Identity 1">jdoe</property>
    </userGroupProvider>

    <!-- ========================================================= -->
    <!-- ROSTER PART 2: Active Directory. Read-only, auto-synced.  -->
    <!-- This is where groups come from.                           -->
    <!-- ========================================================= -->
    <userGroupProvider>
        <identifier>ldap-user-group-provider</identifier>
        <class>org.apache.nifi.ldap.tenants.LdapUserGroupProvider</class>

        <property name="Authentication Strategy">LDAPS</property>
        <property name="Manager DN">CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com</property>
        <property name="Manager Password">ServicePassword123</property>
        <property name="Url">ldaps://dc01.example.com:636</property>
        <property name="Referral Strategy">FOLLOW</property>
        <property name="Connect Timeout">10 secs</property>
        <property name="Read Timeout">10 secs</property>
        <property name="Page Size">500</property>
        <property name="Sync Interval">30 mins</property>
        <property name="Group Membership - Enforce Case Sensitivity">false</property>

        <property name="TLS - Truststore">./conf/truststore.p12</property>
        <property name="TLS - Truststore Password">truststorepass</property>
        <property name="TLS - Truststore Type">PKCS12</property>
        <property name="TLS - Client Auth">NONE</property>
        <property name="TLS - Protocol">TLS</property>
        <property name="TLS - Shutdown Gracefully">false</property>

        <!-- WHICH USERS to pull in -->
        <property name="User Search Base">OU=Users,DC=example,DC=com</property>
        <property name="User Object Class">user</property>
        <property name="User Search Scope">SUBTREE</property>
        <property name="User Search Filter">(&amp;(objectCategory=person)(sAMAccountName=*))</property>

        <!-- CRITICAL: this must produce the SAME string Keycloak sends -->
        <property name="User Identity Attribute">sAMAccountName</property>

        <!-- WHICH GROUPS to pull in -->
        <property name="Group Search Base">OU=Groups,DC=example,DC=com</property>
        <property name="Group Object Class">group</property>
        <property name="Group Search Scope">SUBTREE</property>
        <property name="Group Search Filter">(cn=NiFi-*)</property>
        <property name="Group Name Attribute">cn</property>
        <property name="Group Member Attribute">member</property>
        <property name="Group Member Attribute - Referenced User Attribute"></property>
    </userGroupProvider>

    <!-- ========================================================= -->
    <!-- COMBINE the two rosters into one                          -->
    <!-- ========================================================= -->
    <userGroupProvider>
        <identifier>composite-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.CompositeConfigurableUserGroupProvider</class>
        <property name="Configurable User Group Provider">file-user-group-provider</property>
        <property name="User Group Provider 1">ldap-user-group-provider</property>
    </userGroupProvider>

    <!-- ========================================================= -->
    <!-- THE RULEBOOK: who can do what                             -->
    <!-- ========================================================= -->
    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">composite-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>

        <!-- The one account that gets full power on first startup -->
        <property name="Initial Admin Identity">jdoe</property>

        <property name="Node Identity 1"></property>
        <property name="Node Group"></property>
    </accessPolicyProvider>

    <!-- ========================================================= -->
    <!-- THE HALL MONITOR                                          -->
    <!-- ========================================================= -->
    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>

</authorizers>
```

Notice the three things that all say `jdoe`, and the `User Identity Attribute` set to `sAMAccountName`. Those four settings are all describing the same person. If any one of them disagrees, permissions break.

### Step 6 — Clear the old state and start

**This step is mandatory and people skip it constantly.**

`Initial Admin Identity` and `Initial User Identity N` are read **only when `users.xml` and `authorizations.xml` do not exist**. NiFi uses them once to build those files, then ignores them forever. If the files already exist, your new admin setting does absolutely nothing — no error, no warning, just silence.

```bash
cd $NIFI_HOME
./bin/nifi.sh stop

# Back them up, don't just delete
mv conf/users.xml conf/users.xml.bak 2>/dev/null
mv conf/authorizations.xml conf/authorizations.xml.bak 2>/dev/null

./bin/nifi.sh start
tail -f logs/nifi-app.log
```

Wait for `NiFi has started`.

### Step 7 — Log in and verify

1. Go to `https://nifi.example.com:8443/nifi`
2. You get redirected to Keycloak. Log in as `jdoe`.
3. You land on the NiFi canvas as a full administrator.

Check that AD groups arrived: click the **☰ menu (top right) → Users**. You should see `NiFi-Admins` and `NiFi-Developers` listed as groups, with members, and a note that they're read-only (they come from AD, so you can't edit them in NiFi).

If you see the groups: everything works. If not, jump to [Troubleshooting](#13-troubleshooting).

### Step 8 — Give the AD groups permissions

Now use the UI (much safer than editing XML):

1. **☰ menu → Policies** (this is the global policy screen)
2. Choose a policy from the dropdown, e.g. **"view the user interface"**
3. Click the **+** icon, search for `NiFi-Developers`, add it
4. Repeat for the policies each group needs

For `NiFi-Admins`, add the group to all of these:

| Policy in the UI | What it does |
|---|---|
| view the user interface | See NiFi at all |
| access the controller — view + modify | Cluster settings, reporting tasks |
| access parameter contexts — view + modify | Manage parameters |
| query provenance | Search data history |
| access restricted components | Run powerful/dangerous processors |
| access all policies — view + modify | Manage permissions |
| access users/user groups — view + modify | Manage the user list |
| retrieve site-to-site details | Site-to-site transfers |
| view system diagnostics | Server health |
| proxy user requests | Cluster node communication |
| access counters — view + modify | Counters |

For `NiFi-Developers`, a reasonable starting set is: *view the user interface*, *query provenance*, and then component-level access (next step).

5. Now right-click on empty canvas → **Manage access policies** (or the padlock icon in the Operate palette with nothing selected). This controls the **root process group**.
6. Add `NiFi-Admins` to both **view the component** and **modify the component**.
7. Add `NiFi-Developers` to the same, or only *view the component* if they should be read-only.
8. Switch the dropdown to **view the data** / **modify the data** and add groups there — this controls who can look at the actual records flowing through and who can empty queues.

**You are done.** Everything below explains what you just did and what your alternatives were.

---

## 4. How NiFi Decides Who You Are (Authentication)

### What's inside an ID token

After you log in, Keycloak hands the browser a token. It's just text, encoded in three parts separated by dots. The middle part decoded looks like this:

```json
{
  "exp": 1739812345,
  "iss": "https://kc.example.com/realms/corp",
  "aud": "nifi",
  "sub": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "preferred_username": "jdoe",
  "email": "jdoe@example.com",
  "name": "John Doe",
  "given_name": "John",
  "family_name": "Doe",
  "groups": ["NiFi-Admins"]
}
```

Each line is a **claim** — one fact about you. NiFi picks exactly one claim to use as your identity, controlled by:

```properties
nifi.security.user.oidc.claim.identifying.user=preferred_username
```

### Which claim should you choose?

| Claim | Example value | Pros | Cons |
|---|---|---|---|
| `preferred_username` | `jdoe` | Short, readable, matches `sAMAccountName` in AD, easy to type into config files | Could theoretically be reused if a person leaves and a new hire gets the same name |
| `email` | `jdoe@example.com` | Globally unique, matches `userPrincipalName` in AD | Longer; changes if someone gets married or the domain changes |
| `sub` | `f47ac10b-58cc-...` | Never changes, never reused, truly unique | Unreadable. Your permissions files become impossible for a human to audit |

**Recommendation: `preferred_username`.** It's readable and it lines up naturally with `sAMAccountName`, which keeps your AD group sync simple. Use `email` if your organization already standardizes on `userPrincipalName` everywhere.

The `fallback.claims.identifying.user` setting is a safety net: if the main claim is missing from the token, NiFi tries these instead, in order.

### Identity mapping — cleaning up names

Sometimes the raw identity has junk in it you want to strip. NiFi can rewrite identities with regular expressions before using them.

```properties
# Turn a certificate DN like "CN=nifi-node-01.example.com, OU=NIFI"
# into just "nifi-node-01.example.com"
nifi.security.identity.mapping.pattern.dn=^CN=(.*?), OU=(.*?)$
nifi.security.identity.mapping.value.dn=$1
nifi.security.identity.mapping.transform.dn=NONE

# Turn "jdoe@EXAMPLE.COM" into "jdoe"
nifi.security.identity.mapping.pattern.upn=^(.*?)@example\.com$
nifi.security.identity.mapping.value.upn=$1
nifi.security.identity.mapping.transform.upn=LOWER
```

`transform` can be `NONE`, `LOWER`, or `UPPER`.

Group names can be mapped too:

```properties
nifi.security.group.mapping.pattern.anygroup=^(.*)$
nifi.security.group.mapping.value.anygroup=$1
nifi.security.group.mapping.transform.anygroup=LOWER
```

**Important:** these rules apply to identities coming from *every* source — certificates, LDAP sync, OIDC. That's exactly what makes them useful (they normalize everything to one format), but also what makes them dangerous (a rule meant for certificates can accidentally mangle usernames). Test carefully.

> **Practical tip:** if your AD stores `jdoe` but some certificates say `JDOE`, add a `LOWER` transform so everything becomes lowercase and matches.

### Common authentication failures

| Symptom | Cause | Fix |
|---|---|---|
| Browser never leaves NiFi, shows plain login box | `nifi.security.user.login.identity.provider` is not blank | Blank it out |
| Keycloak error: "Invalid parameter: redirect_uri" | Redirect URI mismatch | Must be exactly `https://host:port/nifi-api/access/oidc/callback` |
| "Unable to connect to the OpenId Connect Provider" | NiFi can't reach Keycloak or doesn't trust its certificate | Check firewall; set truststore strategy to `NIFI` and import the cert |
| Redirect loop | NiFi's public hostname doesn't match `nifi.web.https.host`, or a proxy is rewriting headers | Set `nifi.web.proxy.host` to the public name |
| "Unknown user with identity 'jdoe'" | **Authentication worked.** This is an authorization problem. | See Section 5 |

---

## 5. How NiFi Decides What You Can Do (Authorization)

### The two files

Once NiFi knows you're `jdoe`, it opens its own records.

**`users.xml`** — the roster:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<tenants>
    <groups>
        <group identifier="a1f0e0d0-0000-4000-8000-000000000001" name="nifi-admins">
            <user identifier="11111111-1111-4111-8111-111111111111"/>
            <user identifier="22222222-2222-4222-8222-222222222222"/>
        </group>
    </groups>
    <users>
        <user identifier="11111111-1111-4111-8111-111111111111" identity="jdoe"/>
        <user identifier="22222222-2222-4222-8222-222222222222" identity="asmith"/>
    </users>
</tenants>
```

**`authorizations.xml`** — the rulebook:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizations>
    <policies>
        <policy identifier="p0000001-0000-4000-8000-000000000001"
                resource="/flow" action="R">
            <group identifier="a1f0e0d0-0000-4000-8000-000000000001"/>
        </policy>
        <policy identifier="p0000001-0000-4000-8000-000000000002"
                resource="/controller" action="W">
            <user identifier="11111111-1111-4111-8111-111111111111"/>
        </policy>
    </policies>
</authorizations>
```

Read that as: *"Anyone in group `a1f0e0d0-…-0001` may Read the resource `/flow`."* Since `jdoe` is in that group, `jdoe` can see the UI.

### Anatomy of a policy

Every policy has exactly three things:

1. **`resource`** — what's being protected (`/flow`, `/controller`, `/process-groups/abc-123`)
2. **`action`** — either `R` (read/view) or `W` (write/modify). **There is no "RW".** If you want both, write two separate `<policy>` elements.
3. **A list of `<user>` and/or `<group>` children** — who it applies to

### Those UUIDs — the thing that trips everyone up

The `identifier` attributes are not random. NiFi's `FileUserGroupProvider` computes them from the identity string using a deterministic hash (Java's `UUID.nameUUIDFromBytes`, which is MD5-based). Given `jdoe`, it will always produce the same UUID.

This means:

- If you hand-write a random UUID for a file-based user, NiFi may regenerate it on next write, orphaning every policy that referenced your version.
- If you hand-write a UUID for an **LDAP-sourced** user or group, it will *never* match — the LDAP provider computes its own identifiers and never reads yours. Your policy silently applies to nobody.

To generate the identifier NiFi would generate:

```bash
python3 -c "
import hashlib, uuid, sys
b = bytearray(hashlib.md5(sys.argv[1].encode('utf-8')).digest())
b[6] = (b[6] & 0x0f) | 0x30   # version 3
b[8] = (b[8] & 0x3f) | 0x80   # variant
print(uuid.UUID(bytes=bytes(b)))
" jdoe
```

**But the real advice is: don't hand-write these files.** Use `Initial Admin Identity` to bootstrap, then do everything else in the UI or via the REST API. The XML files are a bootstrap mechanism, not a management interface. Treat them like a seed, not a spreadsheet.

### Policy inheritance

Components are nested — processors sit inside process groups, which sit inside other process groups, up to the root.

By default, a component **inherits** its parent's policies. If `NiFi-Developers` can modify the root process group, they can modify everything inside it.

But the moment you create a policy directly on a child component, inheritance stops for that component. The child now uses only its own policy list.

This has a surprising consequence: **an empty policy on a child blocks access rather than falling through to the parent.** If you click "Override" on a component's policy and then don't add anyone, nobody can access it — not even people who could access the parent.

```
Root Process Group          [NiFi-Developers: view + modify]
├── ETL Group               (no policy → inherits → Developers can modify)
│   ├── GetFile             (inherits → Developers can modify)
│   └── PutHDFS             (inherits → Developers can modify)
└── Finance Group           [NiFi-Finance only: view + modify]  ← override!
    ├── GetSFTP             (inherits from Finance Group → Developers CANNOT touch)
    └── PutDatabase         (inherits from Finance Group → Developers CANNOT touch)
```

This is how you carve out a private area inside a shared canvas.

### The four kinds of component policy

For any component you'll see these in the UI dropdown. They're genuinely different:

| Policy | Resource path | What it controls |
|---|---|---|
| view the component | `/process-groups/{id}` | Can see the box on the canvas and its configuration |
| modify the component | `/process-groups/{id}` | Can change settings, start/stop it, delete it |
| view the data | `/data/process-groups/{id}` | Can look at the **actual records** flowing through — list queues, download flowfile content |
| modify the data | `/data/process-groups/{id}` | Can **empty queues** and replay flowfiles |

> **Security note worth pausing on:** "view the component" and "view the data" are separate for a very good reason. A developer might need to build and debug a flow that processes payroll records without being allowed to read anyone's salary. Grant component access widely; grant data access narrowly.

---

## 6. All the Ways to Add Users and Groups

You asked what the options are. Here they all are, with honest trade-offs.

### Option A — Initial Admin bootstrap (`authorizers.xml`)

Set `Initial Admin Identity`, delete `users.xml` and `authorizations.xml`, restart. NiFi creates one user with every global permission.

**Pros**
- The only way to get your very first admin in. There is no other bootstrap path.
- Simple, no dependencies.

**Cons**
- Works **exactly once**. Changing it later does nothing unless you delete the files again.
- Deleting the files erases every permission you've configured since.
- One user only.

**Use it for:** first-time setup, and for emergency recovery when you've locked yourself out.

### Option B — Manual users and groups in the NiFi UI

Go to **☰ → Users → + icon**, type an identity, create groups, drag users in.

**Pros**
- No restart, no XML, no risk of corrupting files.
- Changes replicate across a cluster automatically.
- Fine-grained — perfect for the occasional contractor or service account.

**Cons**
- Entirely manual. Someone leaves the company, and their NiFi access stays until a human removes it.
- You must type the identity string perfectly by hand.
- Doesn't scale past a few dozen people.

**Use it for:** service accounts, external partners, anyone who isn't in AD, and small teams.

### Option C — Automatic sync from Active Directory (`LdapUserGroupProvider`)

NiFi connects to AD on a timer and pulls in users and groups.

**Pros**
- **Self-maintaining.** Add someone to `NiFi-Developers` in AD and they have access within 30 minutes. Remove them and access disappears.
- Group membership is managed by whoever already manages AD — usually the right people.
- Scales to thousands of users.
- Onboarding/offboarding becomes an AD ticket, not a NiFi ticket.

**Cons**
- Read-only in NiFi. You cannot edit these users or groups from the UI, which confuses people at first.
- Requires a second connection to AD (in addition to Keycloak's), with its own service account and its own TLS setup.
- **The identity attribute must exactly match the OIDC claim** or the whole thing silently fails to link up.
- Sync is on a timer, so changes aren't instant.
- If AD is unreachable at startup, NiFi may fail to start.

**Use it for:** this is the recommended production setup. Section 7 covers it in full.

### Option D — Composite providers (A + B + C together)

Combine a file provider with one or more read-only providers.

```xml
<userGroupProvider>
    <identifier>composite-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.CompositeConfigurableUserGroupProvider</class>
    <property name="Configurable User Group Provider">file-user-group-provider</property>
    <property name="User Group Provider 1">ldap-user-group-provider</property>
</userGroupProvider>
```

There are two composite classes and the difference matters:

| Class | Behavior |
|---|---|
| `CompositeUserGroupProvider` | Combines any number of providers. **All read-only.** You cannot add anyone from the UI. |
| `CompositeConfigurableUserGroupProvider` | Exactly **one** configurable (file) provider plus any number of read-only ones. You *can* add users from the UI. |

**Almost always use `CompositeConfigurableUserGroupProvider`.** It gives you AD groups for humans plus the ability to hand-add cluster nodes and service accounts.

**Pros**
- Best of both worlds.
- Cluster node identities live in the file provider where they belong; humans come from AD.

**Cons**
- More configuration to get wrong.
- Identity collisions between providers cause startup failures — the same identity must not appear in two providers.

### Option E — REST API scripting

Everything the UI does is a REST call, so you can automate it.

```bash
# Get a token (with a client certificate, or via OIDC in a browser first)
TOKEN=$(curl -sk --cert admin.pem --key admin.key \
  https://nifi.example.com:8443/nifi-api/access/token)

# List users
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/tenants/users | jq

# Create a user
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"revision":{"version":0},"component":{"identity":"svc-etl"}}' \
  https://nifi.example.com:8443/nifi-api/tenants/users

# Look at a global policy (action is "read" or "write")
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/policies/write/policies | jq
```

**Pros**
- Repeatable, version-controlled, reviewable.
- Perfect for dev/test/prod parity.
- No restarts.

**Cons**
- You must fetch and increment a `revision` version with every update, or you get a 409 conflict.
- More work up front.

**Use it for:** infrastructure-as-code shops, and for replaying a known-good permission set into a rebuilt environment.

### Option F — `ShellUserGroupProvider`

Reads users and groups from the **local operating system** of the NiFi server.

**Pros:** zero external dependencies.
**Cons:** only useful if your users have Linux accounts on the NiFi box, which almost nobody does in this architecture.

**Use it for:** rare edge cases. Not applicable to a Keycloak/AD setup.

### Option G — `AzureGraphUserGroupProvider`

If your "Active Directory" is actually **Microsoft Entra ID** (formerly Azure AD) rather than on-premises AD, this provider reads groups through the Microsoft Graph API instead of LDAP.

```xml
<userGroupProvider>
    <identifier>azure-graph-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.azure.AzureGraphUserGroupProvider</class>
    <property name="Refresh Delay">5 mins</property>
    <property name="Authority Endpoint">https://login.microsoftonline.com</property>
    <property name="Directory ID">your-tenant-id</property>
    <property name="Application ID">your-app-id</property>
    <property name="Client Secret">your-secret</property>
    <property name="Group Filter Prefix">NiFi-</property>
    <property name="Page Size">200</property>
    <property name="Claim for Username">upn</property>
</userGroupProvider>
```

**Pros:** works with cloud-only Entra ID where there's no LDAP endpoint to talk to.
**Cons:** Azure-specific; needs an app registration with `GroupMember.Read.All` permission.

### Option H — Group claims straight from Keycloak

This is the one everyone asks about, so let's be direct.

**NiFi 1.28 cannot use group information from the OIDC token for authorization.** There is no `nifi.security.user.oidc.claim.groups` setting and no OIDC-based user group provider. NiFi reads exactly one claim from the token — the identity — and then does all group lookups through its own configured `userGroupProvider`.

So even if you add a group mapper in Keycloak and the token arrives packed with `"groups": ["NiFi-Admins"]`, NiFi ignores it entirely.

**What to do instead:** point `LdapUserGroupProvider` at the *same* Active Directory that Keycloak federates. Keycloak handles the login; NiFi independently reads the group memberships from the same source of truth. Users experience it as "my AD group controls my NiFi access," which is what they wanted anyway.

> This is worth verifying against the release notes for your exact build before you architect around it, since NiFi's authorization internals have changed between major versions.

### Side-by-side comparison

| Option | Auto-updates | Editable in UI | Needs restart | Scales | Best for |
|---|---|---|---|---|---|
| A. Initial Admin | No | No | Yes | No | First login only |
| B. Manual UI | No | Yes | No | Poor | Service accounts, small teams |
| C. LDAP/AD sync | **Yes** | No | Yes (to configure) | **Excellent** | Production humans |
| D. Composite | Partly | Partly | Yes (to configure) | Excellent | **Recommended default** |
| E. REST API | No | Yes | No | Good | Automation, IaC |
| F. Shell | Yes | No | Yes | Poor | Edge cases |
| G. Azure Graph | Yes | No | Yes | Excellent | Entra ID / cloud |
| H. OIDC claims | — | — | — | — | **Not supported in 1.28** |

---

## 7. Deep Dive: Automatic Group Sync from Active Directory

### Two ways to figure out group membership

AD stores the relationship twice, so you can query it from either end.

**Group-centric (the `member` attribute).** Look at the group, read its list of members.

```xml
<property name="Group Member Attribute">member</property>
<property name="Group Member Attribute - Referenced User Attribute"></property>
<property name="User Group Name Attribute"></property>
```

Leaving *Referenced User Attribute* blank means "the values in `member` are full DNs" — which is true in AD.

**User-centric (the `memberOf` attribute).** Look at the user, read the groups they belong to.

```xml
<property name="User Group Name Attribute">memberOf</property>
<property name="User Group Name Attribute - Referenced Group Attribute"></property>
<property name="Group Member Attribute"></property>
```

| Approach | Pros | Cons |
|---|---|---|
| `member` (group-centric) | Straightforward; easy to filter to just the groups you care about | Very large groups can be truncated by AD's 1500-value range limit |
| `memberOf` (user-centric) | Avoids the large-group problem; naturally scoped to relevant users | Pulls in *every* group the user belongs to, including hundreds of irrelevant ones |

**Do not configure both directions at once.** Pick one. Configuring both produces duplicate and inconsistent membership.

**Recommendation for AD:** use `member` (group-centric) with a `Group Search Filter` like `(cn=NiFi-*)`. This keeps the result set small and readable, and the 1500-member limit is unlikely to matter for NiFi access groups.

### Filtering to just the groups you need

Without a filter, NiFi pulls in every group in your directory — often thousands. The UI becomes unusable and sync takes forever.

```xml
<property name="Group Search Filter">(cn=NiFi-*)</property>
```

Or list them explicitly:

```xml
<property name="Group Search Filter">(|(cn=NiFi-Admins)(cn=NiFi-Developers)(cn=NiFi-ReadOnly))</property>
```

Same idea for users — restrict to enabled accounts only:

```xml
<property name="User Search Filter">(&amp;(objectCategory=person)(sAMAccountName=*)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))</property>
```

That last clause excludes disabled accounts. Note that in XML you must write `&amp;` instead of `&`.

### Nested groups

AD lets groups contain other groups. If `NiFi-Admins` contains `Platform-Team` rather than listing people directly, plain `member` lookups won't find those people.

Use AD's special "matching rule in chain" operator:

```xml
<property name="User Search Filter">(&amp;(objectCategory=person)(memberOf:1.2.840.113556.1.4.1941:=CN=NiFi-Admins,OU=Groups,DC=example,DC=com))</property>
```

The magic number `1.2.840.113556.1.4.1941` means "search recursively through nested groups." It's Microsoft-specific and can be slow on large directories, so use it deliberately.

### Sync timing

```xml
<property name="Sync Interval">30 mins</property>
```

Minimum accepted value is 10 seconds, but be reasonable. Every sync is a full directory query.

| Interval | Trade-off |
|---|---|
| 5 mins | Changes apply fast; heavier load on domain controllers |
| 30 mins | Good default for most organizations |
| 4 hours | Very light load; a new hire waits half a day |

Remember: sync only affects **group membership**. A user who is removed from AD entirely will still be authenticated by Keycloak until Keycloak's own sync catches up — so disable accounts in AD, don't just remove them from groups.

### Case sensitivity

```xml
<property name="Group Membership - Enforce Case Sensitivity">false</property>
```

AD itself is case-insensitive; LDAP DNs may come back with inconsistent capitalization. Setting this to `false` prevents membership from silently breaking because one DN said `OU=Groups` and another said `ou=groups`. **Set it to `false` for Active Directory.**

### TLS to Active Directory

Never use plain LDAP in production — the service account password and every query travel in clear text.

```xml
<property name="Authentication Strategy">LDAPS</property>
<property name="Url">ldaps://dc01.example.com:636</property>
<property name="TLS - Truststore">./conf/truststore.p12</property>
<property name="TLS - Truststore Password">truststorepass</property>
<property name="TLS - Truststore Type">PKCS12</property>
```

You must import your domain controller's certificate (or its issuing CA) into that truststore:

```bash
# Grab the certificate
openssl s_client -connect dc01.example.com:636 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > dc01.pem

# Import it
keytool -importcert -alias dc01 -file dc01.pem \
  -keystore conf/truststore.p12 -storetype PKCS12 \
  -storepass truststorepass -noprompt
```

For redundancy, list multiple domain controllers separated by spaces:

```xml
<property name="Url">ldaps://dc01.example.com:636 ldaps://dc02.example.com:636</property>
```

### The identity-matching problem, one more time

This deserves its own section because it causes more wasted hours than anything else.

```
Keycloak sends:                        NiFi's AD sync produces:
  claim.identifying.user                 User Identity Attribute
  = preferred_username                   = sAMAccountName
  → "jdoe"                               → "jdoe"
         │                                        │
         └──────────── MUST MATCH ────────────────┘
```

If Keycloak's *Username LDAP attribute* is `userPrincipalName`, the token carries `jdoe@example.com`. If NiFi's *User Identity Attribute* is `sAMAccountName`, NiFi's roster contains `jdoe`. NiFi authenticates you as `jdoe@example.com`, finds no such person in its roster, and denies everything — while `jdoe` sits right there in the group list, taunting you.

**Matching combinations:**

| Keycloak "Username LDAP attribute" | NiFi "User Identity Attribute" | Result |
|---|---|---|
| `sAMAccountName` | `sAMAccountName` | ✅ Works |
| `userPrincipalName` | `userPrincipalName` | ✅ Works |
| `sAMAccountName` | `userPrincipalName` | ❌ Broken |
| `userPrincipalName` | `sAMAccountName` | ❌ Broken |

If you're stuck with a mismatch you can't change, use identity mapping to bridge it:

```properties
nifi.security.identity.mapping.pattern.upn=^(.*?)@example\.com$
nifi.security.identity.mapping.value.upn=$1
nifi.security.identity.mapping.transform.upn=LOWER
```

This strips the domain so `jdoe@example.com` becomes `jdoe` and matches the AD-synced roster.

---

## 8. Giving Permissions to Groups

### Method 1 — the UI (recommended)

**Global policies:** ☰ menu → **Policies**. Pick a policy from the dropdown, click **+**, add the group.

**Component policies:** select a component (or click empty canvas for the root group) → click the **padlock** icon in the Operate palette, or right-click → **Manage access policies**. Choose the policy type from the dropdown, add the group.

When you open a component policy for the first time you'll see a message saying it's inheriting from the parent, with an option to **Override**. Overriding starts a fresh, empty list — which will lock everyone out until you populate it. NiFi offers to copy the inherited entries as a starting point; take that offer.

### Method 2 — the REST API

```bash
# 1. Find the group's real identifier
GROUP_ID=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/tenants/user-groups \
  | jq -r '.userGroups[] | select(.component.identity=="NiFi-Developers") | .id')

# 2. Fetch the existing policy (URL form: /policies/{action}/{resource})
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/policies/read/flow > policy.json

# 3. Add the group to component.userGroups[], keep the revision, PUT it back
POLICY_ID=$(jq -r .id policy.json)
jq --arg gid "$GROUP_ID" \
  '.component.userGroups += [{"id":$gid}]' policy.json > policy-updated.json

curl -sk -X PUT -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d @policy-updated.json \
  https://nifi.example.com:8443/nifi-api/policies/$POLICY_ID
```

The URL pattern `/nifi-api/policies/{action}/{resource}` is readable: `/policies/write/policies` literally means "who may modify policies."

If the policy doesn't exist yet, `POST` to `/nifi-api/policies` with `resource` and `action` in the body instead.

### Method 3 — editing `authorizations.xml` directly

Only for bootstrap or disaster recovery. NiFi must be stopped.

```xml
<policy identifier="d0ba4b0d-1234-4000-8000-00000000000a"
        resource="/policies" action="R">
    <group identifier="a1f0e0d0-0000-4000-8000-000000000001"/>
</policy>
<policy identifier="d0ba4b0d-1234-4000-8000-00000000000b"
        resource="/policies" action="W">
    <group identifier="a1f0e0d0-0000-4000-8000-000000000001"/>
</policy>
```

**Remember:** you cannot reference AD-synced groups this way, because you don't know the identifiers the LDAP provider will generate. This method only works for file-provider users and groups.

### Full-admin policy set for a group

Here's every global policy an administrator group needs, in XML form. Replace `ADMIN_GRP` with the real identifier.

```xml
<policies>
    <!-- See the UI at all -->
    <policy identifier="pol-0001" resource="/flow" action="R">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Controller settings, reporting tasks, cluster node management -->
    <policy identifier="pol-0002" resource="/controller" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0003" resource="/controller" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Manage users and groups -->
    <policy identifier="pol-0004" resource="/tenants" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0005" resource="/tenants" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Manage permissions (this is effectively root — see warning below) -->
    <policy identifier="pol-0006" resource="/policies" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0007" resource="/policies" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Data lineage search -->
    <policy identifier="pol-0008" resource="/provenance" action="R">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Powerful processors like ExecuteScript, ExecuteStreamCommand -->
    <policy identifier="pol-0009" resource="/restricted-components" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0010" resource="/restricted-components" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Parameter contexts -->
    <policy identifier="pol-0011" resource="/parameter-contexts" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0012" resource="/parameter-contexts" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Counters -->
    <policy identifier="pol-0013" resource="/counters" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0014" resource="/counters" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Server health -->
    <policy identifier="pol-0015" resource="/system" action="R">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Site-to-site -->
    <policy identifier="pol-0016" resource="/site-to-site" action="R">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Everything on the root canvas -->
    <policy identifier="pol-0017" resource="/process-groups/ROOT_PG_UUID" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0018" resource="/process-groups/ROOT_PG_UUID" action="W">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0019" resource="/data/process-groups/ROOT_PG_UUID" action="R">
        <group identifier="ADMIN_GRP"/></policy>
    <policy identifier="pol-0020" resource="/data/process-groups/ROOT_PG_UUID" action="W">
        <group identifier="ADMIN_GRP"/></policy>

    <!-- Cluster nodes ONLY (not humans) -->
    <policy identifier="pol-0021" resource="/proxy" action="R">
        <group identifier="NODE_GRP"/></policy>
    <policy identifier="pol-0022" resource="/proxy" action="W">
        <group identifier="NODE_GRP"/></policy>
</policies>
```

> ⚠️ **`/policies` with `W` is the most dangerous permission in NiFi.** Anyone with it can grant themselves — or anyone else — every other permission, including access to all data. Treat membership in that group like root access on a server. Keep it to two or three people, and audit it.

Find `ROOT_PG_UUID` from the browser URL when you're on the root canvas, or:

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/flow/process-groups/root \
  | jq -r .processGroupFlow.id
```

### A worked example: three tiers of access

| Group | What they should be able to do |
|---|---|
| `NiFi-Admins` | Everything |
| `NiFi-Developers` | Build and change flows, see data for debugging, but not manage users |
| `NiFi-Viewers` | Watch the canvas and check whether things are running. See nothing else. |

| Policy | Admins | Developers | Viewers |
|---|:---:|:---:|:---:|
| `/flow` R | ✅ | ✅ | ✅ |
| `/process-groups/root` R | ✅ | ✅ | ✅ |
| `/process-groups/root` W | ✅ | ✅ | ❌ |
| `/data/process-groups/root` R | ✅ | ✅ | ❌ |
| `/data/process-groups/root` W | ✅ | ❌ | ❌ |
| `/provenance` R | ✅ | ✅ | ❌ |
| `/controller` R | ✅ | ✅ | ❌ |
| `/controller` W | ✅ | ❌ | ❌ |
| `/tenants` R/W | ✅ | ❌ | ❌ |
| `/policies` R/W | ✅ | ❌ | ❌ |
| `/restricted-components` R/W | ✅ | ❌ | ❌ |
| `/parameter-contexts` R | ✅ | ✅ | ❌ |
| `/parameter-contexts` W | ✅ | ❌ | ❌ |
| `/counters` R | ✅ | ✅ | ❌ |
| `/system` R | ✅ | ✅ | ❌ |

Then create the matching AD groups, and access becomes a matter of AD membership.

---

## 9. Complete Permission Reference

### Global resources

| Resource | Actions | Grants |
|---|---|---|
| `/flow` | R | See the UI at all. **Everyone needs this.** |
| `/controller` | R, W | Controller settings, reporting tasks, registry clients, node management |
| `/parameter-contexts` | R, W | Create and edit parameter contexts |
| `/provenance` | R | Submit provenance queries |
| `/restricted-components` | R, W | Run processors flagged as restricted |
| `/restricted-components/{permission}` | R, W | Narrower version, e.g. `/restricted-components/write-filesystem` |
| `/policies` | R, W | View and change permissions. **Effectively root.** |
| `/tenants` | R, W | View and change the user and group lists |
| `/site-to-site` | R | Retrieve site-to-site details |
| `/system` | R | System diagnostics and health |
| `/proxy` | R, W | Act on behalf of another user. **Cluster nodes only.** |
| `/counters` | R, W | View and reset counters |
| `/resources` | R | List available policy resources |

### Component resources

Substitute `{type}` with `process-groups`, `processors`, `input-ports`, `output-ports`, `funnels`, `labels`, `remote-process-groups`, `controller-services`, `reporting-tasks`, or `parameter-contexts`.

| Resource | Actions | Grants |
|---|---|---|
| `/{type}/{uuid}` | R, W | View / modify the component |
| `/data/{type}/{uuid}` | R, W | View queued data / empty queues and replay |
| `/provenance-data/{type}/{uuid}` | R | View provenance events for this component |
| `/policies/{type}/{uuid}` | R, W | View / change **this component's** policies |
| `/operation/{type}/{uuid}` | W | Start and stop **only** — cannot edit configuration |

> **`/operation` is underused and very handy.** It lets an on-call operator restart a stuck processor at 3 a.m. without giving them the ability to change how it works.

### Resource path cheat sheet

```
/flow                                          ← see the UI
/controller                                    ← controller settings
/policies                                      ← global permission management
/tenants                                       ← global user management
/proxy                                         ← node-to-node (nodes only)

/process-groups/abc-123                        ← that group's config
/data/process-groups/abc-123                   ← that group's flowing records
/provenance-data/process-groups/abc-123        ← that group's lineage events
/policies/process-groups/abc-123               ← who may change that group's permissions
/operation/process-groups/abc-123              ← start/stop only
```

---

## 10. Keycloak Configuration in Detail

### Mapping AD attributes into token claims

Under **User federation → active-directory → Mappers**, Keycloak creates several by default. The relevant ones:

| Mapper | Type | Maps |
|---|---|---|
| `username` | user-attribute-ldap-mapper | `sAMAccountName` → Keycloak username |
| `email` | user-attribute-ldap-mapper | `mail` → email |
| `first name` | user-attribute-ldap-mapper | `givenName` → first name |
| `last name` | user-attribute-ldap-mapper | `sn` → last name |

To add group synchronization into Keycloak (useful for other applications even though NiFi 1.28 won't use it):

1. **Mappers → Add mapper**, type `group-ldap-mapper`
2. Configure:

| Setting | Value |
|---|---|
| LDAP Groups DN | `OU=Groups,DC=example,DC=com` |
| Group Name LDAP Attribute | `cn` |
| Group Object Classes | `group` |
| Membership LDAP Attribute | `member` |
| Membership Attribute Type | `DN` |
| Mode | `READ_ONLY` |
| User Groups Retrieve Strategy | `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE` |

3. Add a **Groups** client scope mapper on the `nifi` client (Client scopes → nifi-dedicated → Add mapper → By configuration → Group Membership), token claim name `groups`, and **turn "Full group path" OFF** so you get `NiFi-Admins` rather than `/NiFi-Admins`.

Again: NiFi 1.28 won't read this claim. Do it anyway if other apps need it, and so the data is there if you upgrade.

### Inspecting the token to confirm the claim

The fastest way to see exactly what NiFi will receive:

```bash
curl -s -u nifi:CLIENT_SECRET \
  -d 'grant_type=password' \
  -d 'username=jdoe' \
  -d 'password=UserPassword' \
  -d 'scope=openid profile email' \
  https://kc.example.com/realms/corp/protocol/openid-connect/token \
  | jq -r .id_token | cut -d. -f2 | base64 -d 2>/dev/null | jq .
```

This needs **Direct access grants** enabled on the client. Turn it off again afterward.

No-curl alternative: Keycloak admin console → **Clients → nifi → Client scopes → Evaluate** tab. Pick a user, then click *Generated ID token*. Same information, no password needed.

### Turning on NiFi debug logging

Edit `conf/logback.xml`, add before `</configuration>`:

```xml
<logger name="org.apache.nifi.web.security" level="DEBUG"/>
<logger name="org.apache.nifi.web.security.oidc" level="DEBUG"/>
<logger name="org.apache.nifi.web.security.jwt" level="DEBUG"/>
<logger name="org.apache.nifi.authorization" level="DEBUG"/>
<logger name="org.apache.nifi.ldap" level="DEBUG"/>
<logger name="org.springframework.security" level="DEBUG"/>
<logger name="com.nimbusds" level="DEBUG"/>
```

`logback.xml` opens with `<configuration scan="true" scanPeriod="30 seconds">`, so changes apply within 30 seconds — no restart needed. Confirm that attribute is present in your file.

Then watch a login:

```bash
tail -f logs/nifi-user.log | grep -iE 'oidc|claim|identity|unknown'
```

The line you're hunting for:

```
WARN [NiFi Web Server-25] o.a.n.w.a.c.AccessDeniedExceptionMapper
    Unknown user with identity 'jdoe'. Returning Forbidden response.
```

**That string in quotes is the definitive answer.** Copy it character for character into `Initial Admin Identity`.

> **Turn these loggers back off when you're done.** `org.springframework.security` and `com.nimbusds` at DEBUG are extremely chatty and can write token material into your logs.

---

## 11. Clusters: Extra Rules

### Every node needs its own identity

Each node authenticates to the others using its TLS certificate. Those certificate identities must exist as users and have `/proxy` permissions, or every replicated request fails.

```xml
<userGroupProvider>
    <identifier>file-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
    <property name="Users File">./conf/users.xml</property>
    <property name="Initial User Identity 1">jdoe</property>
    <property name="Initial User Identity 2">CN=nifi-node-01.example.com, OU=NIFI</property>
    <property name="Initial User Identity 3">CN=nifi-node-02.example.com, OU=NIFI</property>
    <property name="Initial User Identity 4">CN=nifi-node-03.example.com, OU=NIFI</property>
</userGroupProvider>
```

And in the access policy provider:

```xml
<property name="Node Identity 1">CN=nifi-node-01.example.com, OU=NIFI</property>
<property name="Node Identity 2">CN=nifi-node-02.example.com, OU=NIFI</property>
<property name="Node Identity 3">CN=nifi-node-03.example.com, OU=NIFI</property>
```

If you applied DN identity mapping in `nifi.properties`, use the **mapped** value here (e.g. `nifi-node-01.example.com`), not the raw DN. Whatever appears in the "Untrusted proxy" log message is the correct string.

Alternatively, put all nodes in one group and use:

```xml
<property name="Node Group">nifi-nodes</property>
```

### Files must be identical across nodes

`users.xml` and `authorizations.xml` must match on every node at startup, or the joining node is rejected:

```
Failed to connect node to cluster because local flow controller partially updated.
Proposed Authorizer is not inheritable by the flow controller because of
Authorizer differences: Proposed Authorizations do not match current Authorizations
```

**Fix:** stop all nodes, copy one node's `conf/users.xml` and `conf/authorizations.xml` to all the others, start them. Don't edit each node separately — you will produce drift.

### Correct bootstrap order for a new cluster

1. Stop **all** nodes.
2. Delete `users.xml` and `authorizations.xml` on **all** nodes.
3. Make sure `authorizers.xml` is identical everywhere.
4. Start **one** node, let it fully come up.
5. Copy the generated `users.xml` and `authorizations.xml` to all other nodes.
6. Start the remaining nodes.

Skipping step 5 is the usual cause of a cluster that won't form after a permissions change.

### Changes made in the UI replicate automatically

Once the cluster is healthy, adding a user or policy through the UI updates every node. You only need the manual copy dance during bootstrap or recovery.

---

## 12. Best Practices

### Architecture

1. **Use `CompositeConfigurableUserGroupProvider`.** File provider for cluster nodes and service accounts, LDAP provider for humans.
2. **Never grant permissions to individual humans.** Always to groups. When someone changes teams, one AD change moves all their access.
3. **Name AD groups with a prefix** like `NiFi-` so your search filter is trivial and it's obvious what the group controls.
4. **Keep the Keycloak identity claim and the NiFi LDAP identity attribute aligned** — write it in your runbook in large letters.
5. **Point the LDAP provider at the same AD Keycloak federates.** Two sources of truth means two things to be out of sync.

### Security

6. **Guard `/policies` W jealously.** It's equivalent to root. Two or three people maximum.
7. **Separate component access from data access.** Developers can usually build flows without reading production records.
8. **Use `/operation` for on-call staff** instead of full modify rights.
9. **Always use LDAPS or STARTTLS**, never plain LDAP.
10. **Use a dedicated read-only service account** for the LDAP provider, with a password that never expires (and is stored in a secret manager, not in your notes).
11. **Encrypt sensitive values.** NiFi 1.28 ships `./bin/encrypt-config.sh`, which can encrypt the passwords in `authorizers.xml` and `nifi.properties`.
12. **Turn off Direct Access Grants** on the Keycloak client once you've finished debugging.
13. **Restrict who can use restricted components** — those processors can run arbitrary code on the NiFi server.

### Operations

14. **Back up `users.xml` and `authorizations.xml`** before every change, and after any successful change. They are small and they are the only record of your permission model.
15. **Keep an emergency access path.** A client certificate mapped to an admin identity gets you in when Keycloak is down. Test it before you need it.
16. **Version-control `authorizers.xml`, `nifi.properties`, and `logback.xml`** — with secrets externalized.
17. **Document your identity chain** in one place: which AD attribute → which Keycloak setting → which NiFi setting.
18. **Set a sane sync interval.** 30 minutes suits most organizations.
19. **Test in a non-production NiFi first.** Locking yourself out of production means downtime while you delete files and restart.
20. **Re-audit group membership quarterly.** Access accumulates.

### Things that will bite you

| Trap | Why it hurts |
|---|---|
| Editing `Initial Admin Identity` on a running system | Silently does nothing; the files already exist |
| Hand-writing UUIDs for LDAP-sourced users | They never match; the policy applies to nobody |
| Overriding a component policy and leaving it empty | Blocks everyone including the parent's users |
| Mismatched `users.xml` across cluster nodes | Cluster won't form |
| Forgetting `/proxy` for node identities | Every request returns "Untrusted proxy" |
| Not blanking `login.identity.provider` | NiFi ignores OIDC and shows a local login box |
| No `Group Search Filter` | Thousands of groups sync in; the UI becomes unusable |
| Both `member` and `memberOf` configured | Duplicate, inconsistent memberships |
| Leaving DEBUG logging on | Log volume explodes; token material lands in files |

---

## 13. Troubleshooting

### "Unknown user with identity 'X'"

**What it means:** authentication succeeded, authorization failed. NiFi knows who you are but has no record of you.

**Fix:**
1. Copy the exact string `X` from the log — including case and any domain suffix.
2. If bootstrapping: put it in `Initial Admin Identity`, stop NiFi, delete `users.xml` and `authorizations.xml`, start.
3. If already running: have an existing admin add `X` through the UI.
4. If AD sync should have provided it: check that `User Identity Attribute` produces the same format as the OIDC claim.

### Groups don't show up in the UI

**Check, in order:**

1. Is the LDAP provider actually loaded? `grep -i "ldap-user-group-provider" logs/nifi-app.log`
2. Any LDAP errors? `grep -iE "ldap|naming" logs/nifi-app.log | tail -50`
3. Does the search find anything from the command line?
   ```bash
   ldapsearch -x -H ldaps://dc01.example.com:636 \
     -D "CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com" -w 'pass' \
     -b "OU=Groups,DC=example,DC=com" "(cn=NiFi-*)" cn member
   ```
4. Is the composite provider wired into the access policy provider? (`User Group Provider` must name the composite, not the file provider.)
5. Has the sync interval elapsed? Restart to force an immediate sync.

### Groups appear but permissions don't apply

Almost certainly the identity mismatch. Compare:

```bash
# What NiFi's roster contains
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://nifi.example.com:8443/nifi-api/tenants/users \
  | jq -r '.users[].component.identity' | sort

# What Keycloak sends — from the log during a login attempt
grep -i "identity" logs/nifi-user.log | tail -20
```

If the two lists use different formats, you've found it.

### "Untrusted proxy CN=nifi-node-01..."

A cluster node isn't authorized to make requests on behalf of users.

1. Copy the exact DN from the error message.
2. Confirm it exists as a user in `users.xml`.
3. Confirm it has `/proxy` with both R and W.
4. If you use DN identity mapping, make sure you registered the **mapped** form.

### Cluster won't form after a permissions change

```
Proposed Authorizer is not inheritable by the flow controller
```

Stop all nodes, copy `users.xml` and `authorizations.xml` from one node to all others, start them.

### Blank canvas, no error at all

You have `/flow` R (so the UI loads) but no read permission on the root process group. Add the group to *view the component* on the root process group.

### Locked out completely

The nuclear recovery:

```bash
./bin/nifi.sh stop
cp conf/users.xml conf/users.xml.$(date +%F-%H%M)
cp conf/authorizations.xml conf/authorizations.xml.$(date +%F-%H%M)
rm conf/users.xml conf/authorizations.xml
# ensure Initial Admin Identity in authorizers.xml is the exact string from nifi-user.log
./bin/nifi.sh start
```

On a cluster, do this on all nodes, start one, copy the generated files out to the rest, then start them.

This wipes every policy you've configured. Restore from your backup afterward, or rebuild via the REST API from a script — which is exactly why keeping that script is worth the effort.

### Useful log commands

```bash
# Watch a login in real time
tail -f logs/nifi-user.log

# All authorization denials
grep -i "denied\|unknown user\|untrusted" logs/nifi-user.log

# LDAP sync activity
grep -i "ldap" logs/nifi-app.log | tail -50

# Did OIDC initialize?
grep -i "oidc\|openid" logs/nifi-app.log | head -30
```

---

## 14. Glossary

**Active Directory (AD)** — Microsoft's directory service. Stores users, passwords, and groups for a Windows domain.

**Authentication** — Proving who you are. Handled by Keycloak here.

**Authorization** — Deciding what you're allowed to do. Handled by NiFi here.

**Bind DN** — The full directory path of the account used to log in to LDAP, e.g. `CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com`.

**Claim** — One fact inside a token, like `preferred_username: jdoe`.

**Composite provider** — A NiFi user-group provider that merges several other providers into one list.

**DN (Distinguished Name)** — A directory object's full unique path. `CN=John Doe,OU=Users,DC=example,DC=com`.

**Federation** — One system trusting another to verify identities. Keycloak federates AD.

**Identity mapping** — NiFi's regex-based rewriting of identity strings into a consistent format.

**Initial Admin Identity** — A one-time bootstrap setting that creates the first full administrator.

**LDAP / LDAPS** — The protocol for talking to a directory. LDAPS is the encrypted version, port 636.

**OIDC (OpenID Connect)** — The modern login protocol built on OAuth 2.0 that NiFi and Keycloak use.

**Policy** — A rule pairing a resource, an action (R or W), and a set of users/groups.

**Process group** — A folder on the NiFi canvas that holds processors and other groups.

**Realm** — A self-contained tenant inside Keycloak with its own users, clients, and settings.

**Resource** — A protected thing in NiFi, named with a path like `/flow` or `/process-groups/abc-123`.

**`sAMAccountName`** — The short AD login name. `jdoe`.

**Tenant** — NiFi's umbrella term covering both users and groups.

**`userPrincipalName` (UPN)** — The email-style AD login name. `jdoe@example.com`.

---

## Appendix: Complete Reference Configuration

Every file, in one place, for the example scenario.

### `conf/nifi.properties` (security section)

```properties
# ===== HTTPS =====
nifi.web.https.host=nifi.example.com
nifi.web.https.port=8443
nifi.web.http.host=
nifi.web.http.port=
nifi.web.proxy.host=nifi.example.com:8443

# ===== Keystores =====
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=CHANGEME
nifi.security.keyPasswd=CHANGEME
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=CHANGEME

# ===== Disable other login methods =====
nifi.security.user.login.identity.provider=
nifi.security.user.knox.url=
nifi.security.user.saml.idp.metadata.url=

# ===== OIDC / Keycloak =====
nifi.security.user.oidc.discovery.url=https://kc.example.com/realms/corp/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=CHANGEME
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=profile,email
nifi.security.user.oidc.claim.identifying.user=preferred_username
nifi.security.user.oidc.fallback.claims.identifying.user=email
nifi.security.user.oidc.truststore.strategy=JDK

# ===== Authorizer =====
nifi.security.user.authorizer=managed-authorizer
nifi.authorizer.configuration.file=./conf/authorizers.xml

# ===== Identity mapping =====
nifi.security.identity.mapping.pattern.dn=^CN=(.*?), OU=(.*?)$
nifi.security.identity.mapping.value.dn=$1
nifi.security.identity.mapping.transform.dn=NONE
nifi.security.group.mapping.pattern.anygroup=^(.*)$
nifi.security.group.mapping.value.anygroup=$1
nifi.security.group.mapping.transform.anygroup=NONE
```

### `conf/authorizers.xml` (cluster version)

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<authorizers>

    <userGroupProvider>
        <identifier>file-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
        <property name="Users File">./conf/users.xml</property>
        <property name="Initial User Identity 1">jdoe</property>
        <property name="Initial User Identity 2">nifi-node-01.example.com</property>
        <property name="Initial User Identity 3">nifi-node-02.example.com</property>
        <property name="Initial User Identity 4">nifi-node-03.example.com</property>
    </userGroupProvider>

    <userGroupProvider>
        <identifier>ldap-user-group-provider</identifier>
        <class>org.apache.nifi.ldap.tenants.LdapUserGroupProvider</class>
        <property name="Authentication Strategy">LDAPS</property>
        <property name="Manager DN">CN=svc-nifi,OU=ServiceAccounts,DC=example,DC=com</property>
        <property name="Manager Password">CHANGEME</property>
        <property name="Url">ldaps://dc01.example.com:636 ldaps://dc02.example.com:636</property>
        <property name="Referral Strategy">FOLLOW</property>
        <property name="Connect Timeout">10 secs</property>
        <property name="Read Timeout">10 secs</property>
        <property name="Page Size">500</property>
        <property name="Sync Interval">30 mins</property>
        <property name="Group Membership - Enforce Case Sensitivity">false</property>
        <property name="TLS - Truststore">./conf/truststore.p12</property>
        <property name="TLS - Truststore Password">CHANGEME</property>
        <property name="TLS - Truststore Type">PKCS12</property>
        <property name="TLS - Client Auth">NONE</property>
        <property name="TLS - Protocol">TLS</property>
        <property name="TLS - Shutdown Gracefully">false</property>
        <property name="User Search Base">OU=Users,DC=example,DC=com</property>
        <property name="User Object Class">user</property>
        <property name="User Search Scope">SUBTREE</property>
        <property name="User Search Filter">(&amp;(objectCategory=person)(sAMAccountName=*))</property>
        <property name="User Identity Attribute">sAMAccountName</property>
        <property name="User Group Name Attribute"></property>
        <property name="Group Search Base">OU=Groups,DC=example,DC=com</property>
        <property name="Group Object Class">group</property>
        <property name="Group Search Scope">SUBTREE</property>
        <property name="Group Search Filter">(cn=NiFi-*)</property>
        <property name="Group Name Attribute">cn</property>
        <property name="Group Member Attribute">member</property>
        <property name="Group Member Attribute - Referenced User Attribute"></property>
    </userGroupProvider>

    <userGroupProvider>
        <identifier>composite-user-group-provider</identifier>
        <class>org.apache.nifi.authorization.CompositeConfigurableUserGroupProvider</class>
        <property name="Configurable User Group Provider">file-user-group-provider</property>
        <property name="User Group Provider 1">ldap-user-group-provider</property>
    </userGroupProvider>

    <accessPolicyProvider>
        <identifier>file-access-policy-provider</identifier>
        <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
        <property name="User Group Provider">composite-user-group-provider</property>
        <property name="Authorizations File">./conf/authorizations.xml</property>
        <property name="Initial Admin Identity">jdoe</property>
        <property name="Node Identity 1">nifi-node-01.example.com</property>
        <property name="Node Identity 2">nifi-node-02.example.com</property>
        <property name="Node Identity 3">nifi-node-03.example.com</property>
        <property name="Node Group"></property>
    </accessPolicyProvider>

    <authorizer>
        <identifier>managed-authorizer</identifier>
        <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
        <property name="Access Policy Provider">file-access-policy-provider</property>
    </authorizer>

</authorizers>
```

### Deployment checklist

```
[ ] AD service account created, read-only, tested with ldapsearch
[ ] AD groups created (NiFi-Admins, NiFi-Developers, NiFi-Viewers)
[ ] Admin user is a member of NiFi-Admins
[ ] Keycloak LDAP federation configured and tested
[ ] Keycloak "Username LDAP attribute" noted: ______________
[ ] Keycloak nifi client created, confidential, secret copied
[ ] Redirect URI exactly: https://HOST:PORT/nifi-api/access/oidc/callback
[ ] AD certificate imported into NiFi truststore
[ ] nifi.properties OIDC section complete
[ ] login.identity.provider is BLANK
[ ] claim.identifying.user matches the Keycloak attribute above
[ ] authorizers.xml: User Identity Attribute matches the same thing
[ ] Initial Admin Identity spelled exactly as the token will send it
[ ] Node identities registered (cluster only)
[ ] users.xml and authorizations.xml deleted before first start
[ ] Started one node, verified login
[ ] Verified AD groups visible under ☰ → Users
[ ] Assigned global policies to NiFi-Admins
[ ] Assigned root process group policies to each group
[ ] Copied users.xml + authorizations.xml to other nodes (cluster)
[ ] Started remaining nodes, cluster formed
[ ] Backed up users.xml and authorizations.xml
[ ] Emergency client-certificate access tested
[ ] Direct Access Grants turned off in Keycloak
[ ] DEBUG logging turned back off
```