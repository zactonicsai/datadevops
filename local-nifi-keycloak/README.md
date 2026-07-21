# Local NiFi + Keycloak + simulated Active Directory (Docker Compose)

A three-tier sandbox that reproduces the full enterprise login chain on your laptop:
**NiFi 2.10.0** → OIDC → **Keycloak 26.6** → LDAP federation → **Active Directory**
(simulated by a **Samba AD Domain Controller**). No AWS, no Windows Server, no cost.

```
Browser ──https──▶ NiFi  https://localhost:8443/nifi
   │                 │
   │  redirect       │  OIDC discovery + token exchange
   ▼                 ▼
Keycloak  http://keycloak:8080     realm "nifi" (imported on first boot)
                     │
                     │  LDAP bind & search (federation, port 389)
                     ▼
Samba AD DC   domain CORP.EXAMPLE.COM     users: bob, carol · group: nifi-admins
```

**Why Samba?** Samba's AD DC mode is a genuine open-source reimplementation of
Microsoft Active Directory — same LDAP schema (`sAMAccountName`, `objectGUID`,
`mail`, `userAccountControl`), same account-disable semantics. Keycloak is
configured with **Vendor = Active Directory**, exactly as it would be against
real Windows DCs, so everything you test here transfers 1:1.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The stack: AD DC + cert generator + Keycloak + NiFi |
| `ad/Dockerfile` | Ubuntu + Samba image for the domain controller |
| `ad/entrypoint.sh` | First-boot provisioning: domain, users bob/carol, group `nifi-admins` |
| `keycloak/realm-nifi.json` | Realm import: OIDC client, local user alice, **and the AD LDAP federation provider with all mappers** |

## One-time prep: hosts entry

```
127.0.0.1  keycloak
```
(`/etc/hosts` on Linux/macOS, `C:\Windows\System32\drivers\etc\hosts` as Administrator on Windows.)

## Run it

```bash
docker compose up -d --build
docker compose logs -f ad        # first boot: watch the domain provision (~30-60s)
docker compose logs -f nifi      # wait for "Started Application" (~1-2 min)
```

### Test 1 — local Keycloak user (the admin)
Open **https://localhost:8443/nifi** → accept the cert warning → log in **alice / password**.
Alice lives *inside Keycloak* and is NiFi's initial admin.

### Test 2 — Active Directory user (the federation payoff)
Log out, log in as **bob / Password1!**.
Bob does **not exist in Keycloak** — Keycloak finds him via LDAP in the Samba DC and
verifies the password with a live bind against AD. He lands in NiFi as
`bob@corp.example.com` (his AD `mail` attribute → the `email` claim).

Bob will see *"No applicable policies"* — that's authentication vs. authorization,
live: AD/Keycloak proved who he is; NiFi hasn't granted him anything. Fix it as alice:
NiFi menu → **Policies** → *view the user interface* → Add user `bob@corp.example.com`.

### Test 3 — the AD kill switch
```bash
docker compose exec ad samba-tool user disable bob
```
Bob's next login fails instantly (the MSAD account-controls mapper honors AD's
disabled flag) — the "one kill switch" property of federation. Re-enable:
```bash
docker compose exec ad samba-tool user enable bob
```

### Poke at the directory
```bash
# List users straight from the DC
docker compose exec ad samba-tool user list
# Search over LDAP like Keycloak does
docker compose exec ad ldbsearch -H /var/lib/samba/private/sam.ldb \
  '(sAMAccountName=bob)' mail memberOf
# Add a brand-new employee — she can log in to NiFi seconds later
docker compose exec ad samba-tool user create dave 'Password1!' \
  --given-name=Dave --surname=Doe --mail-address=dave@corp.example.com
```

Keycloak admin console: **http://keycloak:8080** (admin/admin) → realm `nifi` →
**User federation → active-directory** to see the provider, its mappers, and the
*Sync all users* action. Federated users appear under *Users* after first login or sync.

## What the federation config in `realm-nifi.json` does

The `components` block is the same LDAP provider you'd click together in the console
(see the AD federation tutorial), captured as code:

- **`vendor: ad`**, `usernameLDAPAttribute: sAMAccountName`, `uuidLDAPAttribute: objectGUID` — AD dialect.
- **`bindDn` = Administrator** — sandbox shortcut; production uses a read-only service account.
- **`customUserSearchFilter: (&(mail=*)(!(sAMAccountName=krbtgt)))`** — import only
  real users that have an email (NiFi identifies by the `email` claim), and skip
  AD's internal `krbtgt` account.
- **`editMode: READ_ONLY`**, `trustEmail: true`, hourly changed-user sync, daily full sync.
- **Mappers**: username/email/first/last attribute mappers, the **MSAD account controls**
  mapper (AD disable ⇒ login blocked), and a **group mapper** that mirrors any AD group
  named `nifi-*` (bob is in `nifi-admins`) into Keycloak groups.

## Reset / tear down

```bash
docker compose down          # stop (AD domain, realm, certs kept in volumes)
docker compose down -v       # wipe everything, re-provision from scratch next up
```

## Sandbox vs. production differences

| Here (local) | Production (see the AD federation tutorial) |
|---|---|
| Plain LDAP on 389 inside Docker | **LDAPS 636** + AD CA cert via `truststore-paths` |
| Bind as `Administrator` | Dedicated **read-only service account**, secret in Secrets Manager |
| Samba AD DC container | Real Windows DCs (via VPN/Direct Connect) or AWS Managed Microsoft AD |
| Passwords `Password1!` etc. | Real AD password policy, MFA, lockout |
| Federation config baked in realm JSON | Ansible `keycloak_*` modules / console, per environment |
