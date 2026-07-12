# Federating Keycloak with Microsoft Active Directory: What's Required and How It Works

**Goal:** connect Keycloak (26.x) to a Microsoft Active Directory (AD) domain so your existing company users can log in to NiFi (or any app) with their **normal Windows username and password** — without copying passwords anywhere and without creating users by hand in Keycloak.

---

## 1. Background: what "federation" means here

So far in this series, Keycloak *was* the user database — we created `alice` inside Keycloak itself. Most companies already have a user database: **Active Directory**, the Microsoft service that Windows domains run on. Every employee already has an account there.

**User federation** means Keycloak stops being the source of truth and instead becomes a **front desk with a phone line to HR**:

1. Alice types `alice` / her Windows password into the Keycloak login page.
2. Keycloak does **not** check its own database. It phones AD over the **LDAP protocol** and asks: "Is this password correct for this user?" (technically: it performs an *LDAP bind* as Alice).
3. AD says yes/no. On yes, Keycloak **imports/updates a lightweight copy of Alice's profile** (name, email, groups — *never* the password) into its own database and issues the normal OIDC tokens to NiFi.

Key consequences to internalize:

- **Passwords stay in AD, always.** Keycloak verifies them live against AD each login. Disable Alice in AD → she can't log in anywhere. One kill switch.
- **Profiles are mirrored, not owned.** Keycloak keeps a local copy of user attributes so tokens are fast and apps can see users; a *sync* job keeps copies fresh.
- **Nothing changes on the app side.** NiFi still speaks plain OIDC to Keycloak. NiFi has no idea AD exists. That's the beauty of the layered design.

**LDAP in one sentence:** the Lightweight Directory Access Protocol is the standard query language for directories — AD's native external interface. Entries live in a tree addressed by **Distinguished Names (DNs)** like `CN=Alice Example,OU=Staff,DC=corp,DC=example,DC=com` (read right-to-left: domain corp.example.com → folder "Staff" → object "Alice Example").

> **Not to be confused with:** *Entra ID (Azure AD)*, Microsoft's **cloud** directory, does not speak LDAP — you connect it via **identity brokering** (OIDC/SAML) instead of federation. Section 7 compares the two. This tutorial covers classic on-prem/managed **AD Domain Services** over LDAP.

---

## 2. What is required — the checklist

Gather these **before** touching Keycloak. Nine times out of ten, a failed setup is a missing item on this list, not a wrong Keycloak setting.

| # | Requirement | Details / example |
|---|---|---|
| 1 | **Network path** from the Keycloak server to a domain controller (DC) | TCP **636 (LDAPS)** — or 389 with StartTLS. On AWS with on-prem AD this means a **Site-to-Site VPN or Direct Connect** plus security-group/firewall rules; with **AWS Managed Microsoft AD** it means VPC connectivity to the directory's ENIs |
| 2 | **DNS resolution** of the AD domain from Keycloak | `dc1.corp.example.com` must resolve. On AWS: Route 53 Resolver **outbound endpoint** forwarding `corp.example.com` to the AD DNS servers |
| 3 | **A service ("bind") account** in AD | An ordinary, *read-only* domain user, e.g. `svc-keycloak@corp.example.com`. Keycloak logs in as this account to *search* the directory. **Not** a Domain Admin — least privilege; default authenticated-user read rights are enough |
| 4 | **The Users DN** — where users live in the tree | e.g. `OU=Staff,DC=corp,DC=example,DC=com`. Ask your AD admin, or find it with the `dsquery`/ADUC tools |
| 5 | **LDAPS certificate trust** | The DC's TLS certificate must chain to a CA Keycloak trusts. Export the AD CS root CA cert; you'll hand it to Keycloak (Step 3.2). Required — never send passwords over unencrypted 389 |
| 6 | **Populated `mail` attributes** (for our NiFi setup) | NiFi identifies users by the `email` claim → each AD user needs `mail` filled in, or you switch NiFi's identifying claim (Section 6) |
| 7 | (Optional) **Group OU** if you'll map AD groups | e.g. `OU=Groups,DC=corp,DC=example,DC=com`, with groups like `nifi-admins` |

**Quick connectivity smoke test from the Keycloak box** (proves items 1–5 before blaming Keycloak):

```bash
# Port reachable?
nc -zv dc1.corp.example.com 636

# TLS cert chain visible?
openssl s_client -connect dc1.corp.example.com:636 -showcerts </dev/null

# Bind + search actually work? (ldap-utils package)
ldapsearch -H ldaps://dc1.corp.example.com:636 \
  -D "svc-keycloak@corp.example.com" -W \
  -b "OU=Staff,DC=corp,DC=example,DC=com" \
  "(sAMAccountName=alice)" mail displayName
```

If `ldapsearch` returns Alice with her mail attribute, the Keycloak part will work.

---

## 3. Step-by-step setup

### 3.1 Store the bind password safely

Same rule as always: no secrets in files or clicks that you'll forget. On AWS:

```bash
aws secretsmanager create-secret --name keycloak/ldap-bind-password \
  --secret-string 'THE-SVC-ACCOUNT-PASSWORD'
```

### 3.2 Make Keycloak trust the AD certificate

Keycloak 26 takes extra trusted CAs via the `truststore-paths` option. Copy the exported AD root CA (PEM) onto the Keycloak server and add one line to `/opt/keycloak/conf/keycloak.conf`:

```properties
truststore-paths=/opt/keycloak/conf/truststore/ad-root-ca.pem
```

Restart Keycloak. (Point it at a *directory* to trust several PEMs. If your DCs use certificates from a public CA, you can skip this — Java already trusts those.)

### 3.3 Create the LDAP provider in the admin console

Log in to the Keycloak admin console → select the **`nifi` realm** (federation is per-realm) → **User federation** → **Add new provider → LDAP**. The important fields:

| Field | Value | Why |
|---|---|---|
| Vendor | **Active Directory** | Pre-fills AD-specific attribute names and enables MSAD extensions — always set this first |
| Connection URL | `ldaps://dc1.corp.example.com:636` | LDAPS = encrypted. List a second DC space-separated for failover: `ldaps://dc1... ldaps://dc2...` |
| Bind type | `simple` | Username+password bind as the service account |
| Bind DN | `svc-keycloak@corp.example.com` | AD accepts the UPN form here (friendlier than a full DN) |
| Bind credentials | *(the service account password)* | Use **Test authentication** button — it must pass before continuing |
| Edit mode | **READ_ONLY** | Keycloak may read AD but never write to it. Safest default; see Section 5 for the other modes |
| Users DN | `OU=Staff,DC=corp,DC=example,DC=com` | The subtree to search |
| Username LDAP attribute | `sAMAccountName` | The classic short Windows logon name (`alice`). Alternative: `userPrincipalName` for email-style logons (`alice@corp.example.com`) |
| RDN LDAP attribute | `cn` | AD names user objects by CN |
| UUID LDAP attribute | `objectGUID` | AD's permanent unique ID — survives renames, so Keycloak never confuses a renamed user with a new one |
| User object classes | `person, organizationalPerson, user` | What counts as "a user" in AD |
| Custom user LDAP filter | e.g. `(memberOf=CN=nifi-users,OU=Groups,DC=corp,DC=example,DC=com)` | *(Optional but recommended)* import only one group's members instead of the whole company |
| Search scope | `Subtree` | Include nested OUs under the Users DN |
| Pagination | On | AD caps result pages at 1000 entries; pagination handles big directories |
| Import users | On | Keep local mirror copies (recommended; "off" = pure pass-through, slower and limits features) |
| Sync Registrations | Off | We're read-only |
| Periodic full sync | On, e.g. `86400` (daily) | Refresh all mirrored profiles |
| Periodic changed users sync | On, e.g. `3600` (hourly) | Pick up new/edited users quickly (uses AD's change timestamps) |

Click **Save**, then use the **Action → Test connection / Test authentication** and finally **Action → Sync all users**. The realm's *Users* list should fill with AD users, each tagged with the federation link.

### 3.4 Check the attribute mappers (usually auto-created)

Under the provider's **Mappers** tab, the *Active Directory* vendor preset creates the translations between AD's attribute names and the OIDC claims your token needs:

| Keycloak/OIDC field → claim | AD attribute | Matters because |
|---|---|---|
| username | `sAMAccountName` (or `userPrincipalName`) | The login name |
| **email → `email` claim** | **`mail`** | **This is the claim NiFi identifies users by** — the whole chain hangs on this mapper |
| first name | `givenName` | `profile` scope |
| last name | `sn` | `profile` scope |
| *MSAD account controls* | `userAccountControl`, `pwdLastSet` | Respects AD's "account disabled", "account locked", and "must change password" flags — this mapper is why disabling a user in AD instantly blocks their Keycloak login |

### 3.5 Map AD groups into Keycloak (the scalable authorization pattern)

Add a mapper: **Mappers → Add → `group-ldap-mapper`**:

- LDAP Groups DN: `OU=Groups,DC=corp,DC=example,DC=com`
- Group Name LDAP Attribute: `cn` · Group Object Classes: `group`
- Membership LDAP Attribute: `member` · Membership Attribute Type: `DN`
- Mode: **READ_ONLY** · User Groups Retrieve Strategy: `LOAD_GROUPS_BY_MEMBER_ATTRIBUTE`
- (Tick *Preserve Group Inheritance* if you use nested groups)

Then add a **group membership token mapper on the `nifi` client** (Clients → nifi → Client scopes → dedicated scope → Add mapper → *Group Membership*, token claim name `groups`, full path **off**) so tokens carry `"groups": ["nifi-admins", ...]`.

### 3.6 Test the end-to-end login

1. Open `https://nifi.example.com/nifi` (or the local sandbox) → Keycloak login page.
2. Log in with an **AD username and Windows password** — e.g. `alice` + her domain password. No Keycloak-local account exists for her; the bind happens live against AD.
3. NiFi shows her as `alice@corp.example.com` (her AD `mail`).
4. Grant her NiFi policies — or better, grant policies to the `nifi-admins` **group** after setting NiFi's `nifi.security.user.oidc.claim.groups=groups` (env: `NIFI_SECURITY_USER_OIDC_CLAIM_GROUPS: groups`). From then on, onboarding = "add to AD group," full stop.

---

## 4. How it works under the hood (the login sequence, revisited)

The OIDC dance between NiFi and Keycloak from the previous tutorial is **unchanged** — federation only swaps out what happens inside Step 3 (password check):

```
Alice → NiFi → redirect → Keycloak login page
                              │ 1. search: bind as svc-keycloak, find
                              │    (sAMAccountName=alice) under Users DN → get her DN
                              │ 2. verify: try an LDAP bind AS Alice's DN
                              │    with the typed password  → AD says OK/fail
                              │ 3. mirror: import/refresh her profile + groups
                              ▼    (password is NOT stored — only verified)
                        issue OIDC tokens → NiFi (email claim = AD mail)
```

Two-step trick worth understanding: the **service account only searches**; the **user's own bind verifies the password**. That's why the service account needs no special privileges and why password policy, lockout, and MFA-at-the-DC all remain AD's job.

---

## 5. The knobs that deserve a decision, with pros and cons

**Edit mode**

| Mode | Meaning | Use when |
|---|---|---|
| **READ_ONLY** (our choice) | Keycloak never writes to AD; users can't change passwords/profile via Keycloak | Default. AD team stays fully in control |
| WRITABLE | Keycloak can update AD attributes and passwords (bind account needs write rights, password changes need LDAPS) | You want self-service password reset through Keycloak |
| UNSYNCED | Edits are saved only in Keycloak's copy, diverging from AD | Rarely a good idea — two versions of the truth |

**Import on vs. off:** Import **on** (mirror copies, our choice) = fast logins, searchable users, offline features; slight staleness between syncs. Import **off** = every lookup hits AD live; no staleness but slower and some features unavailable. On is the norm.

**`sAMAccountName` vs `userPrincipalName` as the login name:** short names (`alice`) are what Windows users type by habit; UPNs (`alice@corp.example.com`) are unambiguous across multi-domain forests. Pick what your users already type — and note it's independent of what NiFi calls them (that's the email claim).

**Kerberos SSO (the optional gold-plating):** the LDAP provider has a Kerberos integration — domain-joined Windows machines inside the office network can then log in to Keycloak **with zero password prompt** (SPNEGO ticket from their Windows session). Requires a keytab and SPN setup with the AD team; genuinely magical UX, meaningful extra setup. Add later, not on day one.

---

## 6. The NiFi gotcha: empty `mail` attributes

Real-world AD directories often have users with **no `mail` attribute** (service accounts, contractors, older records). For those users the token has no `email` claim → NiFi cannot determine an identity → login fails *after* a successful password check (confusing!). Your options:

1. **Fix the data** — populate `mail` in AD (cleanest; email is genuinely useful metadata).
2. **Switch the identifying claim** — set NiFi's `CLAIM_IDENTIFYING_USER: preferred_username` so identities become `alice` / `alice@corp.example.com`. Remember to update `INITIAL_ADMIN_IDENTITY` and any existing NiFi policies to the new strings (exact, case-sensitive match, as always).
3. **Use the fallback property** — `nifi.security.user.oidc.fallback.claims.identifying.user=preferred_username` keeps `email` primary but falls back when it's missing. Beware: one human could appear as two different identities depending on which claim fired.

---

## 7. LDAP federation vs. Entra ID brokering vs. AWS Managed AD

| | **LDAP federation** (this tutorial) | **Entra ID brokering** | **AWS Managed Microsoft AD** |
|---|---|---|---|
| What it is | Keycloak checks passwords live against on-prem/managed AD DS over LDAPS | Keycloak *redirects* the browser to Microsoft's cloud login (OIDC/SAML); Microsoft checks the password | Real AD domain controllers run *by AWS* inside your VPC; federate to them over LDAP exactly as above |
| Password check happens | At your DCs | At Microsoft | At the AWS-hosted DCs |
| Network needs | Line-of-sight to DCs (VPN/DX) | Just internet | VPC-internal — simplest networking |
| MFA / Conditional Access | Whatever AD/your DCs enforce | Entra's full MFA & policies apply automatically | As configured in the managed domain |
| Setup | This tutorial | Identity providers → OpenID Connect: paste Entra's discovery URL + client ID/secret from an Entra "App registration" (~15 min, no certs, no service account) | AWS `ds create-microsoft-ad`, then this tutorial pointed at it |
| Choose when | Users live in classic AD DS and you can reach the DCs | Your org is on Microsoft 365 / Entra ID (most cloud-first orgs) — **prefer this if available** | You want AD semantics fully inside AWS |

The three are not exclusive: many enterprises broker to Entra *and* federate to legacy AD in the same realm, and the login page offers both.

---

## 8. Best-practices checklist

- ✅ **LDAPS only** (636), CA cert installed via `truststore-paths`; never plain 389 in production.
- ✅ **Least-privilege service account**: plain read-only user, long random password stored in Secrets Manager, documented rotation plan (rotate in AD → update secret → update provider).
- ✅ Vendor = **Active Directory**, UUID = `objectGUID`, MSAD account-controls mapper present (so AD disable/lockout is enforced).
- ✅ **READ_ONLY** edit mode unless self-service password reset is an explicit requirement.
- ✅ **Scope the import** with a custom LDAP filter (a `memberOf=` group) — don't mirror 40,000 users so 12 can use NiFi.
- ✅ Two DCs in the connection URL for failover; pagination on for big directories.
- ✅ Sensible sync cadence (changed-users hourly, full daily); after org restructures, run a manual *Sync all users*.
- ✅ **Groups, not individuals**: AD groups → group-ldap-mapper → `groups` token claim → NiFi group policies.
- ✅ Test the failure modes on purpose: disable a test user in AD (login must fail), remove them from the filter group (they must vanish after sync).
- ✅ On AWS: security-group rule *from* the Keycloak SG *to* the DC/Managed-AD SG on 636; Route 53 Resolver outbound endpoint for the AD domain; document the VPN/DX dependency — if the tunnel drops, **all federated logins fail** (a reason cloud-first orgs prefer Entra brokering).

---

**One-sentence summary:** you need a network path + DNS to a domain controller, a read-only service account, the Users DN, and the AD CA certificate; with those four things, Keycloak's LDAP provider (vendor = Active Directory) verifies passwords live against AD, mirrors profiles and groups into the realm, and NiFi keeps working unchanged — it just suddenly accepts everyone's Windows login.
