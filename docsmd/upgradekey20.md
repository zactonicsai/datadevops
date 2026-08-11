# Upgrading Keycloak 20 → 26.7.0 with Docker Compose and PostgreSQL

*Verified against the official Keycloak documentation on 4 August 2026.*

---

## Part 0 — Background: what is actually happening when you "upgrade Keycloak"

If you are new to this, read this part first. Everything later makes more sense once you understand these five ideas.

**1. Keycloak is two things at once: a program and a database.**
The program (the container) holds no important data. All of your realms, users, groups, roles, clients, client secrets and redirect URLs live in PostgreSQL. Upgrading means: throw away the old program, start a new program, and point it at the *same* database.

**2. The new program rewrites the database on first start.**
Keycloak uses a tool called Liquibase. When Keycloak 26 starts and sees a database built by Keycloak 20, it runs every schema change from versions 21, 22, 23, 24, 25 and 26 in order — adding tables, adding columns, moving data. This is automatic. It happens once. **It cannot be undone.** After it runs, Keycloak 20 can no longer read that database.

That single fact is why every step below is built around one rule: **back up first**.

**3. "20 → 26" is one jump, not six.**
The official upgrading guide does not require you to install each version in between. The migration scripts chain together on their own. What you *do* owe is reading the migration notes for the versions you skip, because those describe behaviour changes that can break your applications even when the database migrates perfectly.

**4. Version 20 is already the "modern" Keycloak.**
The hard break in Keycloak's history was version 17, when the server moved from WildFly to Quarkus. You are past that. Your `kc.sh`, your `start-dev` command and your `KC_*` environment variables all still exist in 26. This upgrade is a medium-sized jump, not a rewrite.

**5. Sessions are not data you keep.**
Anyone logged in right now will be logged out. That is normal and expected for a single-node setup. Realms, users and passwords are kept; "who is currently logged in" is not.

---

## Part 1 — Facts checked against the official docs (August 2026)

| Claim | Status |
|---|---|
| Latest Keycloak release is **26.7.0**, released 9 July 2026 | Correct |
| PostgreSQL **15.x** is supported (14 through 18 are listed) | Correct |
| Keycloak supports **OpenJDK 17, 21 and 25**; the official container image uses **21** | Correct |
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` replaced the old `KEYCLOAK_ADMIN` variables (since 26.0) | Correct |
| They only create an admin if none exists — they never reset an existing password | Correct |
| Health and metrics are served on the **management port 9000** (since 25.0) | Correct |
| Persistent user sessions are **on by default** in Keycloak 26 | Correct |
| Keycloak has **no LTS** — only the newest version gets security fixes | Correct |
| `--optimized` requires `kc.sh build` to have run first | Correct |
| Account Console **v2** was removed in Keycloak **25** | Correct |
| Most Java adapters (Spring, Spring Boot, Tomcat, WildFly, servlet filter) were removed in **25** | Correct |
| Hostname v1 (`KC_PROXY`, old `KC_HOSTNAME_*` semantics) was **removed** in 26.0 | Correct |

### What the earlier draft got wrong or left out

1. **Building Keycloak from the ZIP onto a plain `eclipse-temurin` base image is unnecessary work.** The official image `quay.io/keycloak/keycloak:26.7.0` already contains the right JDK, the right JVM flags and the right container tuning. Use it unless you have a specific reason not to. (See Part 6 for the trade-off.)
2. **Dev mode now binds to localhost.** Since Keycloak 26.6, `start-dev` defaults `http-host` to `localhost` instead of every interface. Inside a container that means the port mapping can silently stop working. Set `KC_HTTP_HOST=0.0.0.0` explicitly.
3. **Publishing port 9000 was missing.** You cannot `curl http://localhost:9000/health/ready` from your machine unless the management port is mapped.
4. **The 26.6 schema migration can be slow.** It adds a `REALM_ID` column to `OFFLINE_CLIENT_SESSION` and back-fills it, and adds two new indexes. On big tables (roughly 300,000+ rows) Keycloak *skips* index creation and prints the SQL for you to run manually. On a local dev database this is instant, but you should know the log lines when you see them.
5. **The riskiest changes for a 20 → 26 jump are not in the database — they are in behaviour**, and the draft only listed a few. Redirect-URI matching, token introspection, UserInfo and client authentication all changed in ways that break working applications. Part 5 has the full list.
6. **The download link in the earlier draft was a dead sandbox path.** Everything you need is written out inline below instead.
7. **The "go through 25.0.6 to preserve sessions" path does nothing for you.** In-memory sessions from a single node cannot be migrated at all. Skip it.

---

## Part 2 — Before you start: the checklist

Answer these before touching anything.

- [ ] Do I know the exact PostgreSQL database name, user and password Keycloak 20 uses? (They must not change.)
- [ ] Do I know the Docker volume that holds the database?
- [ ] Do I have custom provider `.jar` files in `/opt/keycloak/providers`?
- [ ] Do I have custom themes in `/opt/keycloak/themes`?
- [ ] Do any of my apps use a Keycloak Java adapter (Spring Boot, Tomcat, WildFly)?
- [ ] Do any of my clients use redirect URIs with a `*` in them?
- [ ] Does any service call the **token introspection** endpoint?
- [ ] Am I ready for everyone to be logged out?

Every "yes" after the third one has a matching section in Part 5. Read those before you start, not after.

---

## Part 3 — The step-by-step upgrade

This is the complete worked example. Copy it line by line.

### Step 1 — Work inside the original project directory

Docker Compose names volumes after the folder the compose file lives in. If you run the new compose file from a *different* folder, Docker will create a brand-new empty database and it will look like every user vanished.

```bash
cd keycloak-20-source-compose
```

Confirm the volume that holds your data:

```bash
docker volume ls | grep postgres
```

You should see something like `keycloak-20-source-compose_keycloak_postgres_data`. The part after the underscore (`keycloak_postgres_data`) is the name you must keep in the new compose file.

### Step 2 — Save your current files

```bash
mkdir -p pre-upgrade-keycloak20
cp docker-compose.yml pre-upgrade-keycloak20/ 2>/dev/null
cp Dockerfile          pre-upgrade-keycloak20/ 2>/dev/null
cp .env                pre-upgrade-keycloak20/ 2>/dev/null
cp README.md           pre-upgrade-keycloak20/ 2>/dev/null
```

Note the exact values of `POSTGRES_DB`, `POSTGRES_USER` and `POSTGRES_PASSWORD`. You will reuse them unchanged.

### Step 3 — Back up the database (do not skip this)

Make sure PostgreSQL is running, then take a compressed dump:

```bash
mkdir -p backups
docker compose up -d postgres

docker compose exec -T postgres \
  pg_dump -U keycloak -d keycloak -Fc \
  > "backups/keycloak-before-upgrade-$(date +%Y%m%d-%H%M%S).dump"

ls -lh backups/
```

Replace `keycloak` with your real user and database names if they differ.

**Belt and braces (recommended):** also take a cold copy of the whole volume. This is the only backup that restores *bit for bit*.

```bash
docker compose down                      # stop everything, keep volumes
docker run --rm \
  -v keycloak-20-source-compose_keycloak_postgres_data:/data \
  -v "$PWD/backups":/backup \
  alpine tar czf /backup/pgdata-volume.tgz -C /data .
```

Use the full volume name from Step 1.

**Optional third net:** export your realms to JSON from Keycloak 20 while it can still read the database. Useful if you ever want to rebuild from scratch. Note that a realm export does **not** include user password hashes unless you add `--users realm_file`, and it never includes client secrets in a form you can reuse blindly.

### Step 4 — Never run this command

```bash
docker compose down --volumes    # ← deletes the database volume
```

`--volumes` (or `-v`) is what removes your data. Plain `docker compose down` is safe.

### Step 5 — Write the new `.env`

```dotenv
# Must match Keycloak 20 exactly — do not change these three
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=change-this-database-password

# Only used if no admin exists yet; ignored otherwise
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=change-this-admin-password
```

Your existing Keycloak 20 admin account still works after the upgrade. The bootstrap variables are a fallback, not a password reset.

### Step 6 — Write the new `docker-compose.yml`

```yaml
services:
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - keycloak_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12

  keycloak:
    image: quay.io/keycloak/keycloak:26.7.0
    command: ["start-dev"]
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/${POSTGRES_DB}
      KC_DB_USERNAME: ${POSTGRES_USER}
      KC_DB_PASSWORD: ${POSTGRES_PASSWORD}

      KC_BOOTSTRAP_ADMIN_USERNAME: ${KC_BOOTSTRAP_ADMIN_USERNAME}
      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}

      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"

      # Required since 26.6: dev mode otherwise binds to localhost inside the container
      KC_HTTP_ENABLED: "true"
      KC_HTTP_HOST: "0.0.0.0"
    ports:
      - "8080:8080"   # Keycloak itself
      - "9000:9000"   # management: /health, /metrics
    # volumes:
    #   - ./providers:/opt/keycloak/providers
    #   - ./themes:/opt/keycloak/themes

volumes:
  keycloak_postgres_data:
```

Three things to check before saving:

1. The volume key `keycloak_postgres_data` matches what Step 1 showed.
2. The service name `postgres` matches the hostname in `KC_DB_URL`. If your old file called it `db`, use `db` in both places.
3. Uncomment the `volumes:` block only if you actually have providers or themes.

### Step 7 — Stop Keycloak 20, keep PostgreSQL

```bash
docker compose stop keycloak
docker compose rm -f keycloak
```

The old container is gone; the database is untouched.

### Step 8 — Start Keycloak 26 and watch the migration

```bash
docker compose pull
docker compose up -d
docker compose logs -f keycloak
```

What you want to see, roughly in this order:

```text
Updating database
Successfully released change log lock
Keycloak 26.7.0 on JVM (powered by Quarkus ...) started in 24.512s
Listening on: http://0.0.0.0:8080
```

**Do not press Ctrl-C on `docker compose logs` in a panic and then stop the container** — logs are just a viewer, but stopping the container mid-migration is what leaves a half-migrated schema. The first start is always slower than later ones.

If a table is large you may instead see a line telling you index creation was skipped and printing SQL to run by hand. Copy that SQL somewhere safe and apply it after startup finishes.

### Step 9 — Check that it is alive

```bash
docker compose ps
curl http://localhost:9000/health/ready
```

Expected:

```json
{"status": "UP", "checks": []}
```

Then open the Admin Console:

```text
http://localhost:8080/admin/
```

And confirm the OpenID Connect metadata still describes your realm:

```bash
curl -s http://localhost:8080/realms/master/.well-known/openid-configuration | head -c 400
```

You can also confirm the schema version Keycloak wrote:

```bash
docker compose exec -T postgres \
  psql -U keycloak -d keycloak -c \
  "SELECT id, version, update_time FROM migration_model ORDER BY update_time DESC LIMIT 5;"
```

The top row should say `26.7.0`.

### Step 10 — Test your real data

Work down this list and tick things off. Anything that fails is almost certainly explained in Part 5.

```text
[ ] Admin login with your existing admin account
[ ] All realms present
[ ] Users, groups, roles present
[ ] Clients present, client secrets unchanged
[ ] Redirect URIs still accepted        ← most common breakage
[ ] Normal user login through your app
[ ] Token refresh
[ ] Token introspection (if you use it) ← second most common breakage
[ ] UserInfo endpoint
[ ] Logout
[ ] Password reset email
[ ] LDAP / Active Directory federation
[ ] External identity providers (Google, SAML, ...)
[ ] Custom login theme
[ ] Custom account theme
[ ] Custom providers loaded (check startup log for errors)
```

### Step 11 — Rolling back, if you must

```bash
docker compose stop keycloak

# Restore the dump
docker compose exec -T postgres \
  pg_restore -U keycloak -d keycloak --clean --if-exists \
  < backups/keycloak-before-upgrade-YYYYMMDD-HHMMSS.dump

# Put the old files back
cp pre-upgrade-keycloak20/docker-compose.yml .
cp pre-upgrade-keycloak20/.env .
docker compose up -d
```

If `pg_restore` complains, use the volume tarball instead: `docker compose down`, delete the volume, recreate it, and untar the backup into it. That path is uglier but exact.

---

## Part 4 — The same thing, condensed

```text
1.  cd into the ORIGINAL compose directory
2.  copy old compose/env files to pre-upgrade-keycloak20/
3.  pg_dump  → backups/          (+ optional volume tarball)
4.  write new .env  (same DB credentials)
5.  write new docker-compose.yml  (image 26.7.0, KC_HTTP_HOST=0.0.0.0, port 9000)
6.  docker compose stop keycloak && docker compose rm -f keycloak
7.  docker compose up -d && docker compose logs -f keycloak
8.  curl localhost:9000/health/ready
9.  work through the test checklist
10. rollback = restore dump + restore old files
```

---

## Part 5 — What changed between 20 and 26 that can break you

Grouped by how likely it is to bite you. Each item says what to do.

### Very likely

**Redirect URI wildcards no longer cover the hostname (26.6.3).**
A pattern like `https://example.com*` used to also match `https://example.com.attacker.com`. It is now treated as `https://example.com/*`. Separately, since 23.0.2 redirect URIs are compared with exact string matching unless a wildcard is present.
→ Open every client, list its valid redirect URIs, and replace loose wildcards with explicit paths. `https://*` still works but you should not use it.

**Token introspection now checks the audience (26.6.2).**
An authenticated client can only introspect a token if that client appears in the token's `aud` claim. Otherwise the endpoint returns `{"active": false}` — which looks exactly like "the token is invalid".
→ Add an audience protocol mapper so the introspecting client lands in `aud`. As a temporary bridge there is a server-wide option `allow-token-introspection-without-audience-check` and a per-client "Allow token introspection without audience check" switch, both already deprecated.

**UserInfo rejects lightweight access tokens (26.6.2).**
Returns 401 now.
→ Use introspection for lightweight tokens, or exchange for a full token. Temporary switch: `allow-userinfo-with-lightweight-access-token`.

**Java adapters are gone (removed in 25).**
Spring, Spring Boot, Tomcat, WildFly/EAP, servlet filter, KeycloakInstalled, JAAS modules.
→ Move apps to the OAuth 2.0 / OIDC support built into their own framework (Spring Security OAuth2 Client / Resource Server, etc.). Old adapters may still talk to a 26 server, but nothing is guaranteed and nothing is fixed.

### Likely if you customised anything

**Custom provider JARs.** Keycloak 22 moved to Quarkus 3 and Jakarta EE. Anything compiled against `javax.*` must be rebuilt against `jakarta.*` and current Keycloak dependencies. A provider that fails to load usually shows up as a stack trace during startup, so read the first 100 log lines carefully.

**Custom themes.** Several compounding changes: Account Console v2 removed (25); `keycloak.v2` is the current login theme and the old `keycloak` login theme is deprecated (26.0); base themes are now *abstract* and can no longer be selected directly in the admin console (26.6); FreeMarker moved to `VERSION_2_3_32` defaults, which can break templates relying on legacy syntax or `?api` (26.7); login page button layout changed (26.7).
→ Test every custom login, account, admin and email theme page.

**Hostname and reverse proxy.** Hostname v1 was removed in 26.0. `KC_PROXY` is gone; `KC_HOSTNAME_URL` and `KC_HOSTNAME_ADMIN_URL` changed meaning under hostname v2.
→ For a local `start-dev` box you can ignore this. For anything behind a proxy, use `KC_HOSTNAME`, `KC_HOSTNAME_ADMIN` and `KC_PROXY_HEADERS=xforwarded|forwarded`.

**Keycloak JS adapter.** The UMD build was removed — it must be imported as a module, not read off a global variable.

### Worth knowing

- **Persistent user sessions are on by default in 26.** Sessions are written to PostgreSQL as well as cached. Sessions now survive restarts, at the cost of more database writes. On 26.7 with PostgreSQL, those session writes use async commit; logouts still commit synchronously. You can turn the feature off, but do not do so casually.
- **The 26.6 migration adds a `REALM_ID` column to `OFFLINE_CLIENT_SESSION` and back-fills it.** Roughly 7,500 rows/second in the project's own PostgreSQL tests. Trivial locally; plan a window in production.
- **New index creation is skipped on tables above ~300,000 rows**, with the SQL printed to the log for you to run manually.
- **`view-system` admin role removed (26.7).** Full server info now requires `manage-realm` in the `master` realm.
- **Identity Provider alias is immutable (26.7).** Renaming via the Admin REST API returns 400.
- **X509 client authentication requires a CA Subject DN (26.7).** Existing configs keep working for now; the next major version will reject them.
- **Realm `displayName` became a real column (26.7)** and is truncated at 255 characters during migration.
- **Self-registration now verifies email before password setup (26.7).** Revert with "Always set password on register form" if you need the old flow.
- **Client secrets generated from now on are 86 characters.** Existing secrets are untouched, but check any column or field with a length limit.
- **Session cookies now hashed with SHA-384 (26.7).** No action needed; stale cookies are silently replaced.
- **Health endpoints open the port during startup (26.6)** so long migrations are not killed by Kubernetes probes. Disable with `--server-async-bootstrap=false` if you dislike it.
- **Shutdown timeout extended to 10 seconds (26.7).**

---

## Part 6 — Options and their trade-offs

### Official image vs. building from the ZIP

| | Official `quay.io/keycloak/keycloak:26.7.0` | Custom `Dockerfile` over `eclipse-temurin` |
|---|---|---|
| **Pros** | Correct JDK and JVM container tuning already applied; patched by the project; two lines of YAML; easy to bump versions | Full control over base OS; can pin your own JDK; can bake in providers and run `kc.sh build` for an optimized image |
| **Cons** | Less control over the base layer | You own JDK compatibility, JVM flags and security patching; more to get wrong; the official image already supports `FROM ... AS builder` for the same purpose |
| **Use when** | Almost always, and certainly for a local dev setup | You need a specific base image for policy reasons — and even then, build `FROM quay.io/keycloak/keycloak:26.7.0` |

### One jump vs. stepping through versions

| | Direct 20 → 26.7.0 | 20 → 22 → 24 → 26 |
|---|---|---|
| **Pros** | Supported; the migration scripts chain automatically; far less work | Failures are easier to localise; you can test apps against each intermediate |
| **Cons** | If something breaks you have six versions of changes to search through | Every hop is a one-way database migration needing its own backup; several times the work |
| **Use when** | Local/dev, or production with a good backup and a test run | Huge production database, heavy customisation, or a strict change process |

You are on `start-dev` with a local database. Go direct.

### Going through 25 to preserve sessions

Do not bother. Persistent sessions must be enabled at the *first* Keycloak 25 start to migrate anything, and in-memory sessions from a single-node deployment cannot be migrated at all. The extra hop costs you a migration and preserves nothing.

### `start-dev` vs `start --optimized`

| | `start-dev` | `start --optimized` |
|---|---|---|
| **Pros** | No build step; relaxed hostname/TLS checks; fine for local work | Fast startup; production-correct; configuration validated at build time |
| **Cons** | Insecure defaults; never for production; binds to localhost since 26.6 unless you set `KC_HTTP_HOST` | Requires `kc.sh build` in the image first; build-time options cannot change at runtime |

Never combine them: `start-dev --optimized` is not a valid thing to run.

The production version of the Keycloak service looks like this:

```dockerfile
FROM quay.io/keycloak/keycloak:26.7.0 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.7.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

```yaml
    command: ["start", "--optimized"]
```

---

## Part 7 — Best practices

1. **Back up twice, in two formats.** A `pg_dump` restores selectively; a volume tarball restores exactly. They fail in different ways.
2. **Rehearse on a copy.** Duplicate the volume into a scratch project, upgrade that, and only then touch the real one.
3. **Change one thing at a time.** Do not upgrade PostgreSQL and Keycloak in the same step. If both break, you will not know which one did it.
4. **Pin exact versions.** `26.7.0`, not `latest`. Reproducibility beats convenience, and Keycloak ships often.
5. **Read the migration notes for every version you skip**, not just the destination version. Most of Part 5 lives in 25 and 26.6, not in 26.7.
6. **Keep upgrading.** Keycloak has no LTS: only the newest release gets security fixes. Sitting on 20 for years is how a one-afternoon upgrade turns into a project. If you need long-term support on a fixed version, that is what Red Hat build of Keycloak exists for.
7. **Never run `docker compose down -v`** in a directory that holds data you care about.
8. **Write down what you tested.** The checklist in Step 10 is the deliverable, not the upgrade itself.

---

## Part 8 — Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Admin console shows an empty, fresh install | Compose created a new volume | Check the project directory and volume name from Step 1 |
| `Connection refused` on port 8080 | Dev mode bound to localhost inside the container (26.6+) | Set `KC_HTTP_HOST=0.0.0.0` |
| `curl localhost:9000` refused | Management port not published | Add `"9000:9000"` to `ports` |
| Health endpoint 404 | Health not enabled | `KC_HEALTH_ENABLED=true` |
| Startup hangs on "change log lock" | A previous start was killed mid-migration | Restore the backup and start again cleanly |
| App gets "Invalid redirect URI" after upgrade | Wildcard hostname matching change | See Part 5 |
| Introspection suddenly returns `active: false` | Audience validation (26.6.2) | See Part 5 |
| Custom provider silently missing | Built against `javax.*` | Rebuild against `jakarta.*` |
| `FATAL: password authentication failed` | `.env` credentials drifted from the old ones | Copy them from `pre-upgrade-keycloak20/` |

---

## Sources

- Keycloak 26.7.0 release announcement — https://www.keycloak.org/2026/07/keycloak-2670-released
- Upgrading Guide (migration changes for 26.7.0 back to 20.0.0) — https://www.keycloak.org/docs/latest/upgrading/index.html
- Supported Configurations (JDK, databases) — https://www.keycloak.org/server/supported-configurations
- Running Keycloak in a container — https://www.keycloak.org/server/containers
- Server Administration Guide — https://www.keycloak.org/docs/latest/server_admin/
- Keycloak 26.0.0 release announcement (persistent sessions, hostname v2, login theme v2) — https://www.keycloak.org/2024/10/keycloak-2600-released
- Keycloak 25.0.0 release announcement (adapter removal, Account Console v2 removal) — https://www.keycloak.org/2024/06/keycloak-2500-released
