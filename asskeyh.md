# Moving & Upgrading Keycloak (Docker on AWS EC2 + RDS) — v20 → v26, The Offline Way

**A step-by-step guide written in plain, middle-school language.**
**Setup covered:** Keycloak running as a **Docker container on an AWS EC2 instance**, with its database on **AWS RDS (PostgreSQL)**.
**Two goals in one guide:**
1. **Move** your Keycloak data offline to a new server (Parts 1–5).
2. **Upgrade** from **Keycloak 20** to the **latest Keycloak 26** while you do it (Part 6 — read this if you're changing versions).

> As of this writing the newest release is **Keycloak 26.7.0** (July 2026). "Latest 26" below means "whatever the newest 26.x is when you do this." <cite index="47-1">Keycloak 26.7.0 is the current supported release.</cite>

---

## First, the big picture (read this — it saves you pain later)

Think of your system as three separate LEGO pieces:

1. **EC2 instance** = a rented computer in Amazon's cloud. It runs Docker.
2. **Keycloak Docker container** = the login program, running inside that EC2 computer. It has NO memory of its own.
3. **RDS PostgreSQL** = a *separate* Amazon-managed database. **This is where ALL your real data lives** — realms, users, passwords, clients, roles, everything.

The single most important idea:

> **Your Keycloak "state" is NOT inside the EC2 box or the Docker container. It lives in RDS.** The EC2 + container are basically disposable. The RDS database is the treasure.

That changes the whole job. Because the data is in RDS (not on the EC2 disk), "moving Keycloak" really means **"move the RDS database, then point a new Keycloak container at it."**

**"Offline process"** means: we make a backup *file*, physically carry that file to the new environment (USB, S3, secure copy — no direct DB-to-DB link), and load it in. Perfect for air-gapped, cross-account, or "the two networks can't talk" situations.

> 🆙 **Changing versions too (e.g. v20 → v26)?** Do the data move first (Parts 1–5), then follow **Part 6**, which walks the version jump one major at a time. Do NOT try to leap straight from 20 to 26 — it breaks the database migration.

### Two things you must copy (they live in different places)

| Thing | Where it lives | How to move it |
|-------|---------------|----------------|
| **The data** (realms, users, secrets) | RDS PostgreSQL | `pg_dump` → file → `pg_restore` (Method A, main path) |
| **The container setup** (image version, env vars, themes, providers) | Your Docker config on EC2 | Copy your Dockerfile / `docker-compose.yml` / env files + `/themes` + `/providers` |

---

## Two ways to grab the RDS data — pick your path

| Method | What it does | Best for |
|--------|-------------|----------|
| **A. `pg_dump` / `pg_restore`** ✅ Main path | Makes a portable file of the whole database. Works fully offline. | Cross-account, air-gapped, or new-region moves |
| **B. RDS Snapshot** | Amazon's built-in "freeze the whole DB" button. Fast, but stays inside AWS. | Same/linked AWS accounts where you can share a snapshot |

We'll fully walk through **Method A** (the true offline path), then show Method B as an option with pros/cons.

---

# PART 1 — The Quick Start (one complete example, Method A)

**Our example setup:**
- **OLD:** EC2 running Keycloak in Docker; RDS endpoint `old-kc.abc123.us-east-1.rds.amazonaws.com`, DB `keycloak`, user `kcadmin`
- **NEW:** A fresh EC2 with Docker installed; a brand-new empty RDS instance `new-kc.xyz789.us-west-2.rds.amazonaws.com`
- We'll carry the dump file offline (USB or a locked-down S3 bucket)

> **Note:** RDS is managed, so you do NOT get to SSH into the database machine. You run `pg_dump` **from the EC2 instance** (or any machine that can reach the RDS endpoint), pointing at the RDS hostname.

### Step 1 — Freeze writes: stop the Keycloak container
Stop Keycloak so nobody changes data mid-copy. (RDS keeps running — we just stop the app writing to it.)
```bash
# On the OLD EC2 instance
docker compose stop keycloak
# or, if not using compose:
docker stop keycloak
```
> Why: a login or admin edit *during* the dump can give you a half-copied, broken backup.

### Step 2 — Make the backup file, pointing at the RDS endpoint
Run this from the EC2 instance (it can already reach RDS). You can run `pg_dump` from the host, or from inside a small postgres container.
```bash
# On the OLD EC2 instance
export PGPASSWORD='YourOldDbPassword'

pg_dump -h old-kc.abc123.us-east-1.rds.amazonaws.com -p 5432 \
  -U kcadmin -d keycloak \
  --no-owner --no-acl --clean --if-exists \
  -F c -f keycloak_backup.dump
```
No `pg_dump` on the host? Use a throwaway postgres container:
```bash
docker run --rm -e PGPASSWORD='YourOldDbPassword' \
  -v "$PWD":/backup postgres:16 \
  pg_dump -h old-kc.abc123.us-east-1.rds.amazonaws.com -p 5432 \
    -U kcadmin -d keycloak \
    --no-owner --no-acl --clean --if-exists \
    -F c -f /backup/keycloak_backup.dump
```
> **Match the versions:** use a `pg_dump` whose version is **equal to or newer** than your RDS engine version, or it may refuse to dump.

### Step 3 — Check the file is real (don't skip!)
```bash
ls -lh keycloak_backup.dump   # must NOT be 0 bytes
```

### Step 4 — Carry it over (the "offline" part)
Move `keycloak_backup.dump` offline: to a USB drive, or upload to a **private, encrypted S3 bucket** and download on the new side. The two databases never talk to each other. Land the file on the **new EC2 instance** (e.g. in `/home/ec2-user/`).

> 🔒 The dump contains password hashes and client secrets. Encrypt it if it travels (`gpg` or S3 server-side encryption).

### Step 5 — Prepare the NEW RDS database
Your new RDS instance should already exist and be **empty**. From the new EC2, create the database and user (connect to the default `postgres` DB first):
```bash
# On the NEW EC2 instance
export PGPASSWORD='NewMasterPassword'

psql -h new-kc.xyz789.us-west-2.rds.amazonaws.com -U masteruser -d postgres \
  -c "CREATE DATABASE keycloak;"
psql -h new-kc.xyz789.us-west-2.rds.amazonaws.com -U masteruser -d postgres \
  -c "CREATE USER kcadmin WITH PASSWORD 'YourNewDbPassword';"
psql -h new-kc.xyz789.us-west-2.rds.amazonaws.com -U masteruser -d postgres \
  -c "GRANT ALL PRIVILEGES ON DATABASE keycloak TO kcadmin;"
```

### Step 6 — Load the backup into the NEW RDS
```bash
# On the NEW EC2 instance
export PGPASSWORD='YourNewDbPassword'

pg_restore -h new-kc.xyz789.us-west-2.rds.amazonaws.com -p 5432 \
  -U kcadmin -d keycloak \
  --no-owner --no-acl -j 2 \
  keycloak_backup.dump
```
(`-j 2` runs 2 jobs in parallel to speed up restore.)

### Step 7 — Point the new Keycloak container at the new RDS
In your new `docker-compose.yml` (or env file / Dockerfile), set the DB env vars to the **new** RDS:
```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.5   # same or newer than the old version
    command: start
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://new-kc.xyz789.us-west-2.rds.amazonaws.com:5432/keycloak
      KC_DB_USERNAME: kcadmin
      KC_DB_PASSWORD: YourNewDbPassword
      KC_HOSTNAME: auth.yourdomain.com      # your new public address
      KC_HEALTH_ENABLED: "true"
    ports:
      - "8080:8080"
```
> If you use a **custom image** with providers baked in, keep using it — just point it at the new RDS. Custom images need `kc.sh build` at image build time (see gotchas).

### Step 8 — Start Keycloak; let it upgrade the schema
```bash
# On the NEW EC2 instance
docker compose up -d keycloak
docker compose logs -f keycloak     # watch for "started in" and any ERROR lines
```
On first start, if the new Keycloak is newer, it **automatically upgrades the database structure**. <cite index="8-1">By default the database is automatically migrated when you start the new installation for the first time.</cite>

### Step 9 — Verify it worked
- Log into the admin console at your new address.
- Confirm all realms are present.
- Confirm the user list isn't empty.
- Actually log in as a test user.

🎉 **Done.** You've moved Keycloak (Docker + RDS) offline to a new server.

---

# PART 2 — The Checklist (print / tick as you go)

### ✅ Prerequisites
- [ ] You have the OLD RDS endpoint, port, DB name, username, password
- [ ] You have the NEW RDS endpoint + master credentials
- [ ] NEW RDS PostgreSQL **major version ≥** old one (never older)
- [ ] NEW Keycloak image version **≥** old one (never older), and no skipped major versions
- [ ] `pg_dump`/`pg_restore` available (host tools **or** a `postgres` Docker image)
- [ ] EC2 **security group** on the NEW RDS allows inbound 5432 from your EC2 (so you can restore)
- [ ] You saved your **Dockerfile / docker-compose.yml / .env** from the old side
- [ ] You noted custom **themes** (`/themes`) and **providers** (`/providers`) — these are files, NOT in RDS
- [ ] Maintenance window agreed (users can't log in while Keycloak is stopped)
- [ ] Somewhere safe/offline to store the dump (encrypted)

### ✅ On the OLD side
- [ ] Stopped the Keycloak container (freeze writes)
- [ ] Ran `pg_dump` against the old RDS endpoint
- [ ] Verified the dump file isn't empty
- [ ] Copied themes + providers + compose/env files

### ✅ Moving files (offline)
- [ ] Dump file on USB / encrypted S3
- [ ] Docker config + themes + providers copied
- [ ] File encrypted (it holds password hashes + client secrets!)

### ✅ On the NEW side
- [ ] Empty database + user created on new RDS
- [ ] Ran `pg_restore` into new RDS
- [ ] Placed themes/providers; rebuilt custom image if needed (`kc.sh build`)
- [ ] Updated compose/env with **new** RDS URL + new `KC_HOSTNAME`
- [ ] Started container, watched logs for errors
- [ ] Verified realms + users + a real login
- [ ] Updated DNS / load balancer / target group to point at the new EC2

---

# PART 3 — Gotchas (the stuff that bites people)

**1. The data is in RDS, not on EC2.** Backing up the EC2 disk or the Docker volume does almost nothing useful. <cite index="15-1">Keycloak's realm signing keys (RSA, EC, HMAC) are stored in the database under the COMPONENT and COMPONENT_CONFIG tables.</cite> Miss the database and you lose your signing keys — tokens break.

**2. You cannot SSH into RDS.** It's managed. Always run `pg_dump`/`pg_restore` **from EC2** (or another allowed host) pointing at the RDS **endpoint hostname**, not `localhost`.

**3. Security groups will block you silently.** The new RDS must allow inbound TCP **5432** from the new EC2's security group, or the restore just hangs/times out. This is the #1 "why won't it connect" cause on AWS.

**4. `pg_dump` version must be ≥ the RDS engine version.** An older client tool refuses to dump a newer server. Use a matching `postgres:XX` Docker image if your host tool is old.

**5. Themes & custom providers live on disk / in the image — NOT in RDS.** Your login branding and plugin `.jar` files won't come across in the dump. Copy `/themes` and `/providers`, and rebuild your image.

**6. Custom images need `kc.sh build`.** When connecting Keycloak to Postgres with a custom Dockerfile, <cite index="17-1">the "kc.sh build" command must be run first</cite> — it bakes in the DB provider and features. Do this at image build time, then `start` (not `start-dev`) in production.

**7. Don't skip Keycloak major versions.** <cite index="9-1">You cannot jump directly from Keycloak 8 to 24 or 26.</cite> Big jumps also changed the whole engine: <cite index="9-1">between versions 8 and 26, the project replaced its entire runtime (WildFly to Quarkus), redesigned its admin console, and restructured its configuration system.</cite> Go up in supported steps.

**8. Never restore into an OLDER Postgres or OLDER Keycloak.** Schema upgrades are one-way. Same-or-newer only.

**9. Test against a copy, not your live DB.** <cite index="9-1">Never upgrade in place. Run the new version as a separate instance pointing at a copy of your database.</cite> Since we're restoring into a brand-new RDS, you're already following this — keep the old RDS untouched until you've verified.

**10. `pg_dump` is fine under ~100 GB; above that, rethink.** The tool <cite index="16-1">is suitable if your database size is less than 100 GB</cite> and <cite index="16-1">may not be suitable if your database size is greater than 100 GB or you want to avoid downtime.</cite> Keycloak DBs are usually small, so you're almost always fine.

**11. The dump file has secrets.** Password hashes and client secrets are inside. Encrypt it in transit and at rest.

**12. Update the hostname + DNS/ALB.** New server = new address. Set `KC_HOSTNAME` correctly and repoint your Route 53 record / load balancer target, or logins and redirects fail even with perfect data. After a move, follow AWS's own advice: <cite index="15-1">run your standard authentication smoke tests, and only then re-add Keycloak to the load balancer or re-enable DNS.</cite>

**13. Active sessions won't survive.** Logged-in users must sign in again after the move. Normal.

---

# PART 4 — Your Options, With Pros & Cons

### Option A — `pg_dump` / `pg_restore` (portable file) ✅ Main path

**Pros**
- Fully **offline & portable** — it's just a file; carry it anywhere (USB, cross-account, cross-cloud, air-gap)
- Copies **everything** exactly — users, hashes, clients, signing keys
- Works between different AWS accounts/regions with zero networking between the databases
- Simple: dump → restore

**Cons**
- The file holds secrets (must encrypt)
- `pg_dump` client version must be ≥ RDS engine
- Slower for very large DBs; brief downtime while Keycloak is stopped
- Doesn't include themes/providers (separate files)

**Use when:** cross-account, air-gapped, new-region, or any true offline move. **This is your default.**

---

### Option B — RDS Snapshot (Amazon's built-in freeze)

Take a manual snapshot of the old RDS, then either restore it to a new RDS or share it to another account. You can even restore to a point in time:
```bash
aws rds create-db-snapshot \
  --db-instance-identifier old-kc \
  --db-snapshot-identifier kc-migration-snap
# later, restore into a new instance:
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier new-kc \
  --db-snapshot-identifier kc-migration-snap
```
On managed databases like RDS, <cite index="15-1">automated snapshots and PITR (point-in-time recovery) are typically built in and enabled by default</cite>, and <cite index="15-1">cross-region replication of automated backups provides geographic redundancy.</cite>

**Pros**
- Very fast and easy — no `pg_dump` needed
- Captures the whole engine cleanly, transaction-consistent
- Point-in-time restore possible; great for disaster recovery
- No downtime to take it (snapshots are online)

**Cons**
- **Stays inside AWS** — not a true "offline file you can carry on a USB"
- Cross-account requires **sharing** the snapshot (needs both accounts, KMS key sharing if encrypted) — not air-gap friendly
- Restores to a *new* RDS instance (you don't get a portable file)
- Region/account boundaries add setup steps

**Use when:** both environments are in AWS and can share a snapshot, or for routine DR. **Not for true air-gapped offline moves.**

---

### The smart combo
Many teams take an **RDS snapshot** (instant safety net) **and** a `pg_dump` file (the portable thing you actually carry offline). Snapshot = insurance; dump = the move.

---

# PART 5 — Extra Background (nice to understand)

**Why is a realm JSON export not enough here?** A Keycloak realm export (`kc.sh export`) only grabs configuration and, by default, skips users. For a real server move you want the **whole database**, because <cite index="15-1">a reliable Keycloak backup is fundamentally a database backup (using pg_dump, pg_basebackup, or managed PostgreSQL snapshots with PITR), not a realm export.</cite> Keep realm export in your back pocket for copying *settings* between dev/staging/prod — not for this migration.

**Typical AWS architecture you're working with:** Keycloak in <cite index="18-1">auto-scaling Docker containers deployed on EC2, accessible behind an ALB, with a PostgreSQL RDS backend inside your VPC.</cite> When you migrate, remember all three layers move or get recreated: EC2/containers, the ALB/DNS, and the RDS data.

**The RDS restore command shape** (straight from AWS's migration docs):
```bash
pg_restore -v -h <rds-endpoint> -U <username> -d <database_name> -j 2 <dumpfile>
```
where <cite index="16-1">-h is the target server, -U is the user on the target, and -d is the database created beforehand.</cite>

**Two dump formats you'll see:**
- **Custom** (`-F c`, a `.dump`) → restore with `pg_restore`. Compressed, flexible, supports parallel `-j`. Used above.
- **Plain SQL** (`.sql`) → restore by piping into `psql`. Human-readable. A container-based restore can unzip and pipe the SQL straight into `psql` against the RDS host.

---

# PART 6 — Upgrading Keycloak 20 → latest 26 (the version jump)

This is the part you need if you're **changing versions**, not just moving data. Moving the RDS data is only half the job; the container is also jumping **6 major versions**, and that path has real breaking changes.

## The golden rule: DON'T jump straight from 20 to 26

Keycloak upgrades work by running database migration scripts (called **Liquibase changesets**) **one version at a time, in order**. <cite index="24-1">Each intermediate version runs its own set of database migration scripts. These scripts are designed to run sequentially. If you skip versions, the migration engine may encounter changesets that assume prior migrations have already run, leading to failures or data corruption.</cite>

Think of it like climbing stairs: you step on each step. You don't leap from the bottom to the top — you'll trip.

## The recommended "hop" path

Go up major version by major version, letting each one fully start and migrate the database before moving on:

```
20  →  21  →  22  →  23  →  24  →  25  →  26 (latest)
```

At **each hop** you: swap the Docker image tag → start the container → let it migrate the DB → check the logs → verify it works → then move to the next hop.

> Good news: 20 and 26 are **both already the modern "Quarkus" Keycloak**, so you avoid the nastiest historical break (the old WildFly-to-Quarkus switch). Your jump is "modern to modern," just with several breaking changes to handle along the way.

## Do this on a COPY, never your live database

This is where the offline migration from Parts 1–5 pays off. You already restored your data into a **brand-new RDS**. Do all the version hops against **that copy**, leaving your original v20 RDS untouched until you're 100% happy. <cite index="9-1">Never upgrade in place. Run the new version as a separate instance pointing at a copy of your database.</cite>

## Step-by-step (one hop, then repeat)

**Before you start each hop:** take a fresh RDS snapshot (instant rollback point).

### Step 1 — Change the image tag
In your `docker-compose.yml`, bump ONE major version:
```yaml
services:
  keycloak:
    image: quay.io/keycloak/keycloak:21.1   # was 20.x — next hop
    command: start
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://new-kc.xyz789.us-west-2.rds.amazonaws.com:5432/keycloak
      KC_DB_USERNAME: kcadmin
      KC_DB_PASSWORD: YourNewDbPassword
```

### Step 2 — Start it and let the database migrate
```bash
docker compose up -d keycloak
docker compose logs -f keycloak
```
Watch for the migration to run and the line saying it started. If it starts cleanly, this hop's DB migration succeeded.

### Step 3 — Check for deprecation warnings
Fix warnings NOW, while you're already in migration mode — they become hard errors in later versions.
```bash
docker compose logs keycloak 2>&1 | grep -i "deprecat"
```
<cite index="24-1">These warnings indicate features that will break in a future version. Address them now while you are already in migration mode.</cite>

### Step 4 — Quick smoke test
Log in to the admin console, check a realm, log in as a test user.

### Step 5 — Repeat for the next hop
Bump to `22.x`, start, migrate, check… all the way to the latest `26.x`. <cite index="24-1">Once you have verified everything works at the current intermediate version, repeat the entire process for the next hop in your migration path.</cite>

## The BIG breaking changes on the road to 26 (don't get ambushed)

These are the specific things that change between 20 and 26. Handle each as you reach the version that introduces it.

**1. Hostname "v2" (introduced in v25) — this WILL bite you.** The whole hostname configuration was redesigned and is **not backward compatible**. <cite index="33-1">Hostname v2 options are supported by default, the old hostname options are deprecated, and the new options are activated by default, so Keycloak will not recognize the old ones.</cite> Your old `KC_HOSTNAME` style settings from v20 may be rejected or behave differently. Plan to rewrite your hostname/proxy settings at the v25 hop. On AWS behind an ALB this is the most common cause of "logins redirect to the wrong URL" after upgrade.

**2. Admin user creation changed (v26): `KC_BOOTSTRAP_ADMIN_*`.** The old `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` env vars were replaced. <cite index="34-1">Keycloak 26 lets you bootstrap a temporary admin account using the new KC_BOOTSTRAP_ADMIN_USERNAME and KC_BOOTSTRAP_ADMIN_PASSWORD environment variables.</cite> Update these in your compose/env file, or you may see admin-console login trouble on first v26 boot.

**3. Persistent user sessions on by default (v26).** In older Keycloak, restarting/upgrading logged everyone out. From v26 this changes: <cite index="31-1">Keycloak 25 introduced persistent-user-sessions, and in Keycloak 26 this feature is enabled by default, so all user sessions are persisted in the database by default.</cite> Nice bonus — but it also means your RDS will store more data, and the internal session format changed to Protostream, so if you run **multiple** Keycloak containers (a cluster) you must bring the old ones fully down before starting the new ones (they can't share the cache across formats).

**4. New default login theme (v26).** <cite index="33-1">For all new realms, keycloak.v2 will be the default login theme; also, any existing realm that never explicitly set a login theme will be switched to keycloak.v2.</cite> If you have a **custom** theme, resource paths changed — test your login page and fix broken CSS/JS references.

**5. Cache config options moved to runtime (v25).** <cite index="36-1">Options cache, cache-stack, and cache-config-file are no longer build options; they can be specified only during runtime, so you need to remove them from the build phase.</cite> If you use a custom Dockerfile with `kc.sh build`, take these out of the build step.

**6. Always read the per-version upgrading guide.** For any 26.x target: <cite index="25-1">review all the changes in each upgrading guide published between your version and the target, then perform the upgrade.</cite> Each hop's guide lists that version's specific breaking changes.

## AWS-specific upgrade gotchas

- **RDS engine version:** Modern Keycloak 26 needs a reasonably current PostgreSQL. Make sure your **new RDS** runs a Postgres version that Keycloak 26 supports (check the "Configuring the database" page for the exact supported list) — bump the RDS engine if needed *before* the final hop.
- **Snapshot before every hop:** RDS snapshots are your one-click undo. Take one before each version bump so a bad hop costs you minutes, not your weekend.
- **Downtime is expected across this span.** Per upgrade guidance, going across several majors means downtime even if the final hop alone wouldn't: <cite index="27-1">upgrading directly from version 21 to 26.1 will incur downtime because intermediate versions require downtime; if any intermediate version requires downtime, your whole upgrade will involve downtime.</cite> Plan a maintenance window.

## Upgrade checklist (v20 → v26)

- [ ] Data already restored into a **new RDS copy** (Parts 1–5 done)
- [ ] Old v20 RDS left **untouched** as a fallback
- [ ] New RDS Postgres engine version supported by Keycloak 26
- [ ] Hop plan written: 20→21→22→23→24→25→26
- [ ] RDS snapshot taken **before each hop**
- [ ] At each hop: image bumped → started → DB migrated → logs checked → smoke-tested
- [ ] Deprecation warnings fixed as they appear
- [ ] **v25 hop:** hostname settings rewritten for hostname **v2**
- [ ] **v26 hop:** switched to `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`
- [ ] **v26 hop:** custom theme paths checked; cache options moved to runtime
- [ ] Multi-container cluster: old replicas fully stopped before new ones start
- [ ] Final: full auth smoke tests, THEN repoint DNS/ALB to the new stack

---

## TL;DR
1. Your real Keycloak lives in **RDS**, not on the EC2 box or in the container.
2. **Stop container → `pg_dump` (from EC2, at the RDS endpoint) → carry file offline → `pg_restore` into new RDS → point new container at new RDS → start → verify.**
3. Also move your **Docker config + themes + providers** (they're separate from RDS).
4. Open **security group port 5432** on the new RDS, or the restore silently fails.
5. The dump **has secrets** — encrypt it. Update **`KC_HOSTNAME` + DNS/ALB**, then smoke-test before real traffic.
6. **Version upgrade (20→26):** hop one major at a time — **20→21→22→23→24→25→26** — never leap. Snapshot before each hop.
7. **Watch these breaks:** hostname **v2** (v25), `KC_BOOTSTRAP_ADMIN_*` (v26), persistent sessions on by default (v26), new v2 login theme (v26).
8. Do all hops on the **RDS copy**; keep the original v20 database safe until you've verified.
