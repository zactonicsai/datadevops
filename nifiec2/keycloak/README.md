# Adding Keycloak Single Sign-On to NiFi 1.28

Right now your NiFi has one login: a username and a password that everybody
shares. This guide replaces that with **Keycloak**, so each person gets their
own account — and puts a one-command way back if anything goes wrong.

**Prerequisite:** the NiFi deployment in `../scripts` is already running. This
builds on the same VPC, key pair and IAM role.

---

## 1. What are we building, and why?

### The problem with one shared password

A single shared login has three problems. You cannot tell who did what. When
somebody leaves the team, you have to change the password for everyone. And
you cannot say "Ana may edit the flow, Ben may only watch it" — there is only
one account, and it can do everything.

### What Keycloak does

**Keycloak** is an open-source *identity server*. Its whole job is to answer
one question: "is this person who they claim to be?" It holds the accounts,
shows the login page, checks the password, and can add multi-factor
authentication, or connect to your company's Active Directory.

NiFi then asks a different question: "this person is Ana — what is she allowed
to do?" Those two jobs have names:

| Word | Plain meaning | Who does it here |
| --- | --- | --- |
| **Authentication** | Proving who you are | Keycloak |
| **Authorization** | What you may do once you are in | NiFi |

That split matters later: adding somebody in Keycloak lets them *log in*, but
you must still give them permissions *inside NiFi*.

### How the login actually flows

The protocol is **OIDC** (OpenID Connect), a standard layer on top of OAuth 2.
Nothing here is NiFi-specific — the same dance happens when a site offers
"Sign in with Google".

```
  1. You open  https://nifi:8443/nifi
  2. NiFi: "I don't know you" -> redirects your browser to Keycloak
  3. Keycloak shows its login page. You type your password THERE.
     (NiFi never sees your password. That is the point.)
  4. Keycloak sends your browser back to NiFi with a short-lived code
  5. NiFi calls Keycloak SERVER-TO-SERVER: "here is the code and my
     client secret — who was that?"          <- the "back channel"
  6. Keycloak returns an ID token: a signed statement saying
     "this is nifi.admin@example.com"
  7. NiFi checks the signature, reads the email, and looks it up in its
     own list of users to decide what you may do
```

Step 5 is the reason two machines must be able to reach each other, and step 6
is the reason NiFi must *trust Keycloak's certificate*. Both come up below.

### The finished picture

```
        Your browser
             │
    ┌────────┴─────────┐            VPC 10.20.0.0/16
    │                  │
    ▼ (2) login page   ▼ (1) NiFi UI
┌──────────────┐   ┌──────────────┐
│  Keycloak    │   │    NiFi      │
│  t3.small    │◀──│  t3.large    │   (5) back channel, over the
│  public-2    │   │  public-1    │       PRIVATE network
│  AZ-b        │   │  AZ-a        │
│  :8443 HTTPS │   │  :8443 HTTPS │
└──────────────┘   └──────────────┘
```

---

## 2. Three problems this setup has to solve

These are the things that make OIDC setups fail. Worth understanding before
you run anything, because the error messages are unhelpful.

### Problem 1: OIDC needs a real hostname, not an IP address

The ID token contains an **issuer** — the exact URL Keycloak thinks it lives
at. NiFi compares that string to the one it was configured with. If they
differ by even one character, the login fails.

An EC2 public IP is not a hostname, and buying a domain for a lab is
annoying. The solution used here is **nip.io**: a free public DNS service
where any name shaped like `54.1.2.3.nip.io` resolves to `54.1.2.3`. You get
a real hostname for free, and TLS certificates can carry it.

### Problem 2: the browser and NiFi reach Keycloak by different routes

Your browser is on the internet, so it needs Keycloak's **public** address.
NiFi is in the same VPC, so it should use the **private** address — traffic
that never leaves the VPC is faster and cannot be intercepted.

But both must use the *same hostname*, or the issuer check in step 6 fails.

The fix: Keycloak's hostname is `<public-ip>.nip.io` for everyone, and on the
NiFi server we add one line to `/etc/hosts` pointing that name at Keycloak's
**private** IP. Same name, two different routes, issuer matches. This is why
the Keycloak security group allows port 8443 from the *NiFi security group*
rather than from a public IP range.

### Problem 3: Keycloak's certificate is self-signed

Your browser will warn you and let you click through. NiFi will not — Java
refuses to talk to a server whose certificate it cannot verify, and you get
`PKIX path building failed` buried in `nifi-app.log`.

The fix: `03-nifi-oidc.sh` downloads Keycloak's certificate, imports it into
NiFi's truststore with `keytool`, and sets
`nifi.security.user.oidc.truststore.strategy=NIFI` so NiFi consults that
truststore instead of Java's built-in list of public authorities.

---

## 3. The scripts

| Script | What it does |
| --- | --- |
| `00-kc-config.sh` | All settings. Inherits region/VPC/tags from `../scripts/00-config.sh` |
| `01-kc-launch.sh` | Security group + EC2 instance running Keycloak in Docker |
| `02-kc-verify.sh` | Is it up? `--follow` polls, `--logs` shows the logs |
| `03-nifi-oidc.sh` | **Backs up**, then switches NiFi to Keycloak |
| `04-nifi-restore.sh` | **Puts NiFi back exactly as it was** |
| `05-kc-add-user.sh` | Adds another person to Keycloak |
| `06-kc-sync-urls.sh` | Fixes the redirect URIs after NiFi's IP changes |
| `99-kc-teardown.sh` | Restores NiFi, then deletes Keycloak |

---

## 4. Step by step

### Step 1 — Check NiFi is running

```bash
cd ../scripts && ./04-verify.sh
```

You need a public IP and an answering UI. If not, fix that first — the
Keycloak scripts read NiFi's address out of `../scripts/.deploy-state`.

### Step 2 — Edit the settings

```bash
cd ../keycloak
nano 00-kc-config.sh
```

Change these four, at minimum:

```bash
export KC_ADMIN_PASSWORD="..."       # Keycloak's own admin console
export NIFI_ADMIN_EMAIL="you@yourcompany.com"
export NIFI_ADMIN_USERNAME="you"
export NIFI_ADMIN_PASSWORD="..."     # your personal NiFi login
```

`NIFI_ADMIN_EMAIL` is the important one. It becomes NiFi's **Initial Admin
Identity** — the one account that starts with every permission, and the
account you use to grant access to everybody else. Use an address you will
actually type.

Leave `KC_CLIENT_SECRET` empty and one will be generated for you.

### Step 3 — Launch Keycloak

```bash
./01-kc-launch.sh
```

Takes about two minutes to create:

- a security group allowing `8443` from **your IP** (browser) and from the
  **NiFi security group** (back channel)
- a `t3.small` in the second public subnet, so Keycloak and NiFi are in
  different Availability Zones
- the same IAM instance profile as NiFi, so SSM works here too

The instance then installs Docker, generates a self-signed certificate for its
own `nip.io` hostname, writes the realm import file, and starts Keycloak.

### Step 4 — Wait for Keycloak

```bash
./02-kc-verify.sh --follow
```

Three to five minutes: pulling the container image is the slow part. When it
finishes you will see the discovery document's contents — issuer,
authorization endpoint, token endpoint, JWKS URI. Those are the four URLs NiFi
needs, and it will fetch them itself.

Stuck? `./02-kc-verify.sh --logs` shows both the bootstrap log and the
container log.

Optional: open `https://<kc-host>:8443/admin/` and log in as `kcadmin` to look
around. Realm `nifi` should exist, with a client called `nifi` and one user.

### Step 5 — Point NiFi at Keycloak

```bash
./03-nifi-oidc.sh
```

It prints exactly what it is going to change and waits for you to type
`apply`. Use `--show` to see the plan without doing anything.

Before it touches a single file it copies these into
`/opt/nifi/backups/pre-oidc-<timestamp>/` on the NiFi server:

```
nifi.properties  authorizers.xml  login-identity-providers.xml
users.xml        authorizations.xml        /etc/hosts
```

and writes a `MANIFEST` listing them. That directory is what `04-nifi-restore.sh`
reads. **Nothing is overwritten without a copy being kept first.**

Then it makes the changes described in section 2, replaces `authorizers.xml`,
deletes `users.xml` and `authorizations.xml` so NiFi rebuilds them with the
new admin, and restarts NiFi.

### Step 6 — Log in as yourself

Wait two to three minutes, then open:

```
https://<nifi-public-ip>:8443/nifi
```

What should happen:

1. Certificate warning for NiFi → proceed
2. Redirect to `https://<kc-host>:8443/realms/nifi/...`
3. Certificate warning for Keycloak → proceed
4. Keycloak's login page → your email and `NIFI_ADMIN_PASSWORD`
5. Back to the NiFi canvas, your name in the top-right corner

Two certificate warnings are expected. Both certificates are self-signed on
purpose; section 8 covers replacing them.

### Step 7 — Add a second person

```bash
./05-kc-add-user.sh ana ana@yourcompany.com 'LongPassword123!' Ana Silva
```

That creates the account in Keycloak. She can now *log in*, but NiFi will show
her an access-denied page, because NiFi has never heard of her. As the admin:

1. **☰ menu → Users → Add User** → identity `ana@yourcompany.com`
   (exactly as typed above — NiFi matches the whole string)
2. **☰ menu → Policies**, or right-click the canvas → **Manage access
   policies**, and grant what she needs. Start with *view the user interface*;
   without it she sees nothing at all.

### Step 8 — Going back (the important one)

```bash
./04-nifi-restore.sh
```

Type `restore`. It stops NiFi, copies the saved files back over the live ones,
deletes the user/policy files OIDC mode created, removes Keycloak's
certificate from the truststore and the `/etc/hosts` line, then starts NiFi.
Your old `admin` / password login works again.

Useful variations:

```bash
./04-nifi-restore.sh --list           # every backup on the server, newest first
./04-nifi-restore.sh /opt/nifi/backups/pre-oidc-20260809-142530
./04-nifi-restore.sh --set-password   # also reset the single-user password
```

It also snapshots the *current* OIDC config into `pre-restore-<timestamp>/`
before overwriting, so you can undo the undo.

Forgotten the old password? `cd ../scripts && ./05-set-credentials.sh admin <new-password>`

---

## 5. Files that change on the NiFi server

Everything happens in `/opt/nifi/current/conf/`.

### `nifi.properties`

| Property | Single-user (before) | Keycloak (after) |
| --- | --- | --- |
| `nifi.security.user.login.identity.provider` | `single-user-provider` | *(empty)* |
| `nifi.security.user.authorizer` | `single-user-authorizer` | `managed-authorizer` |
| `nifi.security.user.oidc.discovery.url` | *(empty)* | `https://<kc-host>:8443/realms/nifi/.well-known/openid-configuration` |
| `nifi.security.user.oidc.client.id` | *(empty)* | `nifi` |
| `nifi.security.user.oidc.client.secret` | *(empty)* | the generated secret |
| `nifi.security.user.oidc.claim.identifying.user` | *(empty)* | `email` |
| `nifi.security.user.oidc.additional.scopes` | *(empty)* | `profile,email` |
| `nifi.security.user.oidc.truststore.strategy` | *(empty)* | `NIFI` |

The first line is what actually disables the old password login: with no
identity provider set, NiFi has no local login form to show.

### `authorizers.xml`

Replaced wholesale. The template is in `templates/authorizers.xml.tmpl`, and
the one line that matters is:

```xml
<property name="Initial Admin Identity">nifi.admin@example.com</property>
```

On first start with no `authorizations.xml`, NiFi grants that identity every
permission. It is read **only** when `authorizations.xml` does not exist,
which is why the script deletes the old one. If you skip that deletion, NiFi
starts fine and nobody can log in — the single most common mistake in this
whole setup.

### `users.xml` and `authorizations.xml`

Deleted, then regenerated by NiFi. From then on the NiFi UI edits them; do not
hand-edit them while NiFi is running.

### The truststore

`conf/truststore.p12` gets one new entry, alias `keycloak-nifi`. Inspect it:

```bash
aws ssm start-session --target <nifi-instance-id>
sudo /opt/nifi/current/bin/../../..//usr/bin/keytool -list \
  -keystore /opt/nifi/current/conf/truststore.p12 -storetype PKCS12 \
  -storepass "$(grep truststorePasswd /opt/nifi/current/conf/nifi.properties | cut -d= -f2)"
```

---

## 6. Troubleshooting

| What you see | Why | Fix |
| --- | --- | --- |
| `sed: -e: No such file or directory` while rendering user-data | An old copy of `01-kc-launch.sh` using GNU-only `sed -i`. macOS needs a backup-suffix argument after `-i`, so it ate the first `-e` | Use the current script — the render is done in Python now |
| `Invalid parameter: redirect_uri` on the Keycloak page | NiFi's public IP changed, so it no longer matches the client's allowed list | `./06-kc-sync-urls.sh` |
| Login works, then NiFi says "Unable to view the user interface" | Authentication succeeded, authorisation did not | Add the identity under **Users**, grant *view the user interface* |
| `PKIX path building failed` in `nifi-app.log` | NiFi does not trust Keycloak's certificate | Re-run `./03-nifi-oidc.sh`; check the truststore has the `keycloak-nifi` alias |
| NiFi redirect loop, or an issuer mismatch error | The hostname NiFi uses differs from Keycloak's configured hostname | Both must be `<kc-public-ip>.nip.io`. Check `/etc/hosts` on the NiFi box |
| Keycloak login page never appears; connection times out | Security group, or your IP changed | Re-run `../scripts/01-preflight.sh`, then `./01-kc-launch.sh` to re-add the rule |
| NiFi will not start after the switch | Usually a typo in `authorizers.xml` or a missing Initial Admin | `sudo journalctl -u nifi -n 50`, then `./04-nifi-restore.sh` |
| Nobody can log in and Keycloak is gone | Keycloak was deleted while NiFi still pointed at it | `./04-nifi-restore.sh` |
| `Connection refused` on the back channel | The NiFi→Keycloak security group rule is missing | Check the Keycloak SG allows 8443 from the NiFi SG |

Logs worth knowing:

```bash
# NiFi side
sudo tail -100 /var/log/nifi-oidc-apply.log        # what the switch did
sudo tail -100 /var/log/nifi-oidc-restore.log      # what the rollback did
sudo grep -i oidc /opt/nifi/current/logs/nifi-app.log | tail -30

# Keycloak side
kc status ; kc logs 100 ; kc host                  # helper installed by the bootstrap
docker logs --tail 100 keycloak
```

---

## 7. What this setup is not

Be honest about the gaps before anyone calls it production:

- **Keycloak uses a file database** (`--db=dev-file`). Fine for a lab, not for
  production. Real deployments use PostgreSQL — on RDS, ideally in the private
  subnets that `../scripts/02-network.sh` already created.
- **One Keycloak, no redundancy.** If it stops, nobody can log in to NiFi.
- **Self-signed certificates everywhere**, so users are trained to click
  through warnings — a bad habit that phishing relies on.
- **The client secret and passwords sit in `.kc-state`** on your laptop, in
  plain text. Production keeps them in AWS Secrets Manager.
- **No group-to-permission mapping.** Keycloak has `nifi-admins` and
  `nifi-users` groups, but NiFi is not reading them yet. Every user is added
  to NiFi by hand. Wiring groups through needs a `userGroupProvider` that
  reads them from the token, or LDAP sync.

---

## 8. Best practices and options

### Making the certificates real

| Option | Pros | Cons |
| --- | --- | --- |
| **Self-signed** (this guide) | Free, automatic, encrypted on the wire | Warnings; no identity guarantee |
| Let's Encrypt on both boxes | Free and trusted by browsers | Needs a real domain and port 80; renewal cron |
| ACM certificate on an ALB in front of each | Trusted, clean names, WAF available | ~$16/month per load balancer; more `nifi.web.proxy.host` config |

`nip.io` names work with Let's Encrypt, so that is a realistic upgrade path
without buying a domain.

### Where identities should really come from

| Option | Pros | Cons |
| --- | --- | --- |
| Users created directly in Keycloak (this guide) | Simple; works offline | Another password list to manage |
| Keycloak federated to LDAP / Active Directory | One corporate account per person; joiners and leavers handled centrally | LDAP config is fiddly |
| Keycloak as a broker to Google / Microsoft / Okta | No passwords at all in Keycloak; MFA inherited | Depends on an external provider |

### Hardening worth doing next

- Turn on **MFA** in Keycloak: Authentication → Required Actions → Configure OTP.
- Shorten `ssoSessionIdleTimeout` (30 minutes here) for sensitive flows.
- Move Keycloak into a **private subnet** and reach it through an ALB, or via
  SSM port forwarding. It does not have to be on the public internet.
- Give both instances **Elastic IPs**, or all URLs break on every restart.
- Back up Keycloak's data directory (`/opt/keycloak/data`) — the realm, the
  users and the signing keys live there. Losing the signing keys invalidates
  every issued token.
- Rotate the client secret periodically: change it in Keycloak, then re-run
  `./03-nifi-oidc.sh`.

### Cost

| Item | Roughly |
| --- | --- |
| `t3.small` for Keycloak, 24/7 | ~$15/month |
| 20 GB gp3 disk | ~$1.60/month |
| Public IPv4 address | ~$3.60/month |
| **Added to the NiFi stack** | **~$20/month** |

Stop the instance when you are not using it, or tear the whole thing down.

---

## 9. Removing Keycloak

```bash
./99-kc-teardown.sh --dry-run    # see the plan
./99-kc-teardown.sh              # do it
```

It restores NiFi's original login **first**, on purpose: deleting the identity
server while NiFi still points at it leaves a NiFi nobody can enter. Only then
does it terminate the instance, release any Elastic IP, delete the security
group, and remove the local state file (which holds passwords).

`--keep-nifi-oidc` skips the restore, if you are replacing Keycloak with a
different identity provider and know what you are doing.

To remove everything, NiFi and the VPC included:

```bash
cd ../scripts && ./99-teardown.sh
```

The main teardown finds the Keycloak instance too — it carries the same
`Project=nifi-demo` tag — and deletes every non-default security group in the
VPC, so the VPC can be removed cleanly.

---

## 10. Cheat sheet

```bash
# set up
./01-kc-launch.sh && ./02-kc-verify.sh --follow && ./03-nifi-oidc.sh

# day to day
./02-kc-verify.sh                 # status
./02-kc-verify.sh --logs          # logs
./05-kc-add-user.sh ana ana@co.com 'LongPassword123!'
./06-kc-sync-urls.sh              # after NiFi's IP changes

# going back
./04-nifi-restore.sh --list       # what backups exist
./04-nifi-restore.sh              # restore the newest
./03-nifi-oidc.sh                 # switch to SSO again

# shell on either box
aws ssm start-session --target <instance-id>
kc status | kc logs | kc restart  # on the Keycloak box

# remove
./99-kc-teardown.sh               # Keycloak only (restores NiFi first)
cd ../scripts && ./99-teardown.sh # everything, VPC included
```
