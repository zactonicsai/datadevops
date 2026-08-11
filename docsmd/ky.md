# Keycloak: A Beginner's Guide (v20 & Migration to v26)

*Last updated: July 2026 — latest release is Keycloak 26.7.0*

---

## Quick Start: Run Keycloak in 5 Minutes (Example First)

The fastest way to understand Keycloak is to run it. This example uses the **modern v26** Quarkus distribution with Docker.

### Step 1 — Start the server

```bash
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.7.0 start-dev
```

`start-dev` runs in development mode (no HTTPS required, in-memory friendly). **Never use it in production.**

### Step 2 — Open the Admin Console

Go to **http://localhost:8080** and log in with `admin` / `admin`.

### Step 3 — Create a Realm

A **realm** is an isolated space that holds its own users, apps, and settings. Think of it like a separate "tenant."

1. Click the dropdown (top-left, says *Keycloak*) → **Create Realm**.
2. Name it `demo` → **Create**.

### Step 4 — Create a Client

A **client** is an application that wants to use Keycloak for login (e.g., your web app).

1. **Clients** → **Create client**.
2. Client ID: `my-app` → **Next**.
3. Turn on **Standard flow** → **Save**.
4. Under **Settings**, set **Valid redirect URIs** to `http://localhost:3000/*`.

### Step 5 — Create a User

1. **Users** → **Add user** → username `alice` → **Create**.
2. **Credentials** tab → **Set password** → turn **Temporary** off.

Done. Your app can now redirect users to Keycloak to log in, and Keycloak hands back a signed token proving who they are.

---

## What Is Keycloak?

Keycloak is a free, open-source **Identity and Access Management (IAM)** tool. In plain terms: it handles *logging people in* and *deciding what they're allowed to do* — so your applications don't have to build that themselves.

It was created by Red Hat and first released in 2014. It's written in Java and licensed under Apache 2.0.

**Analogy:** Imagine a large office building. Instead of every room having its own lock and its own list of who's allowed in, there's one front desk that checks your ID once and gives you a badge. That badge gets you into every room you're permitted to enter. Keycloak is that front desk — this pattern is called **Single Sign-On (SSO)**.

### Key vocabulary

| Term | Meaning |
|------|---------|
| **Realm** | An isolated container of users, apps, and settings. |
| **Client** | An application that uses Keycloak to authenticate users. |
| **User** | A person (or service) who logs in. |
| **Role** | A label like `admin` or `editor` that grants permissions. |
| **Token** | A signed digital "badge" proving identity (usually a JWT). |
| **IdP** | Identity Provider — Keycloak itself, or an external one like Google. |

---

## Why Is Keycloak Used?

You *could* write your own login system, but it's hard to do securely. Keycloak gives you a battle-tested solution for free.

**Main reasons teams choose it:**

- **Single Sign-On (SSO)** — log in once, access many apps.
- **Standard protocols** — supports **OpenID Connect (OIDC)**, **OAuth 2.0**, and **SAML 2.0** out of the box, so it works with almost anything.
- **Social & external login** — let users sign in with Google, GitHub, Microsoft, LDAP, or Active Directory.
- **User federation** — connect to an existing user directory instead of migrating everyone.
- **Multi-factor authentication (MFA)** — one-time passwords, WebAuthn/passkeys.
- **Self-service** — users reset their own passwords and manage their accounts.
- **Fine-grained authorization** — control access by role, group, or custom policy.
- **Open source & self-hosted** — no per-user licensing fees; you keep your data.

### Pros and Cons

| Pros | Cons |
|------|------|
| Free and open source | Java-based; can be memory-heavy |
| Supports all major auth standards | Steep learning curve at first |
| Highly customizable (themes, SPIs) | Clustering/HA setup is complex |
| Large community, actively maintained | Frequent releases mean regular upgrades |
| Self-hosted = full data control | You are responsible for uptime & security patches |

**Alternatives to consider:** Auth0, Okta, and AWS Cognito are cloud-hosted (easier setup, but paid and less control). Keycloak wins when you want self-hosting, no licensing costs, and full customization.

---

## How Keycloak Is Configured

There are two very different eras of Keycloak configuration. **This matters a lot for anyone on an older version.**

### The two distributions

- **Legacy (WildFly-based)** — versions **16 and earlier**. Configured with big XML files (`standalone.xml`) and a CLI tool called `jboss-cli`. This distribution is **end-of-life**.
- **Modern (Quarkus-based)** — versions **17 and later** (including v20 and v26). Configured with a simple `keycloak.conf` file, environment variables, or command-line flags. Faster startup, lower memory, container-friendly.

> **Version 20 note:** v20 is a Quarkus distribution, so it already uses the modern config model below. But it is quite old (released late 2022) and no longer receives security fixes — see the migration section.

### The two-phase model (Quarkus, v17+)

Modern Keycloak separates configuration into two phases:

1. **Build phase** (`kc.sh build`) — locks in structural options like the database vendor, features, and metrics. This creates an optimized, immutable image.
2. **Run phase** (`kc.sh start`) — supplies runtime values like passwords, hostnames, and URLs.

### Example production configuration

`conf/keycloak.conf`:

```properties
# Database
db=postgres
db-url=jdbc:postgresql://db-host:5432/keycloak
db-username=keycloak
db-password=change-me

# Hostname & HTTPS
hostname=auth.example.com
https-certificate-file=/etc/certs/tls.crt
https-certificate-key-file=/etc/certs/tls.key

# Observability
health-enabled=true
metrics-enabled=true
```

Then build and start:

```bash
bin/kc.sh build
bin/kc.sh start --optimized
```

Any setting can also be passed as an **environment variable** by prefixing `KC_`, uppercasing, and replacing `-` with `_`. So `db-url` becomes `KC_DB_URL`. This is the standard way to configure Keycloak in Docker and Kubernetes.

### Configuration best practices

- **Always use an external database** (PostgreSQL is the most common) in production. The default dev database loses data on restart.
- **Always enable HTTPS** in production; never run `start-dev`.
- **Set the `hostname`** explicitly so tokens contain the correct URLs.
- **Store secrets** (DB password, admin password) in a secrets manager or environment variables, never in committed files.
- **Use `--optimized`** with a pre-built image so startup is fast and reproducible.
- Enable `health-enabled` and `metrics-enabled` for monitoring.

---

## Migration Plan: Version 20 → Version 26

Good news: **both v20 and v26 are Quarkus-based**, so you avoid the hardest jump (the WildFly→Quarkus rewrite that happened at v17). Your `keycloak.conf` and environment variables largely carry over. The main work is database schema migration and reviewing breaking changes.

### Why migrate off v20?

- v20 is **end-of-life** — no security patches. Many CVEs have been fixed since.
- Only the **latest major version (26.x)** receives active development and security fixes.
- v26 adds Organizations (multi-tenancy), persistent user sessions, better metrics/health endpoints, and much-improved performance.

### Golden rule: don't jump straight across many majors

You *can* go 20 → 26 in one hop because both are Quarkus, but the safest, best-practice path steps through intermediate majors, testing at each stop, because database schema changes and deprecations accumulate:

```
20 → 21 → 22 → 23 → 24 → 25 → 26
```

At minimum, test one intermediate stop rather than blind-leaping. If you must do it in one move, test heavily in staging first.

### Step-by-step migration

**1. Read the upgrade guides.** For *each* major version between your current one and the target, read the official upgrading guide. Breaking changes are listed there.

**2. Back up everything.** This is non-negotiable.

```bash
# Back up the database (example: PostgreSQL)
pg_dump -U keycloak keycloak > keycloak-backup.sql
```

Also snapshot your config files and any custom themes/providers.

**3. Prefer database migration over export/import.** Keycloak automatically upgrades its database schema on startup. The recommended approach is to point the **new** version at a **copy** of the old database and let it migrate. (Realm export/import is fragile for full migrations — especially the `master` realm — and can drop users or fail silently.)

**4. Rebuild custom providers and themes.** The Quarkus runtime is immutable. Custom SPI providers go in the `providers/` directory (not `standalone/deployments`, which no longer exists) and may need dependency/packaging updates. Themes may need template adjustments between versions.

**5. Review key breaking changes on the way to 26:**
   - **Admin bootstrap variables renamed** — older `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` became `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`.
   - **Persistent user sessions** are the default in v25+ — sessions now live in the database, changing HA/cache behavior.
   - **Hostname options** were overhauled in v26 (hostname v2) — review `hostname` and `hostname-admin` settings.
   - Various default and cache-config changes; check each version's guide.

**6. Test in staging.** Verify: login flows, token issuance, redirect URIs, social/LDAP logins, MFA, custom themes, and every client app. Automated auth tests help here.

**7. Roll out with a rollback plan.** Deploy the new version pointed at the migrated database. Keep the old version and the pre-migration DB backup ready to restore. v26 supports zero-downtime patch releases within a minor stream, but major upgrades still warrant a maintenance window.

### Migration best practices summary

- **Never** upgrade production without a tested staging run and a full backup.
- Migrate via the **database**, not realm export/import, for whole-instance moves.
- Step through intermediate majors; don't skip several at once.
- Read **every** intervening version's upgrade guide — deprecations remove features one major later.
- Freeze config, themes, and providers in version control so you can diff and roll back.

---

## How to Troubleshoot

### General approach

1. **Check the logs first.** Keycloak logs to the console. In Docker: `docker logs <container>`. Increase detail with `--log-level=DEBUG`.
2. **Use the health endpoints.** With `health-enabled=true`, check `/health/ready` and `/health/live`.
3. **Reproduce in `start-dev`** locally to isolate whether it's a config or environment problem.

### Common problems and fixes

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| **"Invalid redirect URI"** on login | The app's redirect URL isn't whitelisted | Add the exact URL to the client's **Valid redirect URIs** (wildcards like `/*` allowed). |
| **Server won't start / DB errors** | Wrong DB URL, credentials, or DB unreachable | Verify `db-url`, `db-username`, `db-password`; confirm the database is running and reachable. |
| **HTTPS / "HTTPS required" error** | Running production mode without TLS configured | Provide certificates, or set the realm's *Require SSL* appropriately. Never disable SSL in prod. |
| **Redirect/URL is wrong behind a proxy** | Keycloak doesn't know its public hostname | Set `hostname` correctly and configure `proxy-headers` for your reverse proxy. |
| **Login loops or "Cookie not found"** | Clock skew, or proxy stripping headers | Sync server clocks (NTP); ensure the proxy forwards `X-Forwarded-*` headers. |
| **Token expired / clock issues** | Server time drift | Ensure NTP is running on all nodes. |
| **Changes to build options ignored** | Forgot to rebuild | Re-run `kc.sh build` after changing build-time options, then `start --optimized`. |
| **Can't log in as admin after upgrade** | Admin env var names changed | Use `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` on modern versions. |
| **Custom provider not loading** | Wrong directory or missing dependency | Place it in `providers/`, rebuild, and check the startup log for load errors. |

### Where to get help

- **Official docs:** keycloak.org/documentation
- **Upgrading guides:** keycloak.org/docs (one per version)
- **Community:** the Keycloak GitHub Discussions and mailing list are active and searchable — most errors have been hit by someone before.

---

## One-Page Cheat Sheet

```bash
# Dev server (never in production)
bin/kc.sh start-dev

# Production: build once, then run optimized
bin/kc.sh build
bin/kc.sh start --optimized

# Export a realm
bin/kc.sh export --dir ./backup --realm demo

# Verbose logging for troubleshooting
bin/kc.sh start-dev --log-level=DEBUG
```

**Golden rules:**
1. `start-dev` is for testing only — production needs a real DB + HTTPS.
2. Back up the database before any upgrade.
3. Migrate through intermediate versions; read every upgrade guide.
4. Rebuild after changing build-time options.
5. Only the latest major (26.x) gets security fixes — stay current.
