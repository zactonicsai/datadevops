# Moving Keycloak (with all its data) to a New Server — The Offline Way

**A step-by-step guide written in plain, middle-school language.**

---

## First, the big picture (read this — it saves you pain later)

Think of Keycloak like a **video game console**, and PostgreSQL (we'll call it "Postgres") like the **memory card** that saves your game.

- **Keycloak** is the program that logs people in. It runs, but it doesn't *remember* anything by itself.
- **Postgres** is the database. It's where Keycloak keeps EVERYTHING: your realms, users, passwords, clients, roles, login settings — all of it.

So here's the key idea that trips people up:

> **If you copy the game console (Keycloak) but forget the memory card (Postgres), you lose all your saves.** The real "state" of Keycloak lives in Postgres, not in the Keycloak folder.

**"Offline process"** just means: we make a backup file, physically carry that file to the new server (USB drive, secure copy, whatever), and load it in. The two servers never talk to each other directly. This is great for air-gapped, high-security, or "no network between them" situations.

There are **two main ways** to do this. We'll do a full walkthrough of the recommended one first, then compare both.

| Method | What it copies | Best for |
|--------|---------------|----------|
| **A. Postgres dump (`pg_dump`)** ✅ Recommended | The *entire* database — every realm, every user, sessions, everything, exactly as-is | Real migrations & backups |
| **B. Keycloak realm export (`kc.sh export`)** | Just the config of one or more realms as JSON | Copying settings between environments |

**Rule of thumb:** For *moving a whole server*, use **Method A**. A realm export is NOT a full backup — <cite index="13-1">it omits users by default, lacks transactional consistency with live data, and cannot restore a production system on its own.</cite>

---

# PART 1 — The Quick Start (one complete example, Method A)

This is the whole job start-to-finish. Later sections explain every piece in detail.

**Our example setup:**
- Old server database is named `keycloak`, user `keycloak`, running on `localhost:5432`
- New server has a fresh, empty Postgres ready to go
- We're carrying the file on a USB drive

### Step 1 — Freeze writes on the OLD server
Stop Keycloak so nobody changes data while you're copying it.
```bash
# On the OLD server
sudo systemctl stop keycloak
```
> Why: if users log in or admins edit things *during* the dump, you can get a half-copied, broken backup.

### Step 2 — Make the backup file (the "dump")
```bash
# On the OLD server
pg_dump -h localhost -p 5432 -U keycloak -d keycloak \
  --no-owner --no-acl --clean --if-exists \
  -F c -f keycloak_backup.dump
```
This creates one file: `keycloak_backup.dump`. That file **is your entire Keycloak.**

### Step 3 — Check the file is real (don't skip this!)
```bash
ls -lh keycloak_backup.dump   # should NOT be 0 bytes / a few bytes
```

### Step 4 — Carry it over (the "offline" part)
Copy `keycloak_backup.dump` to a USB drive (or use `scp` if there's a network). Walk it to the new server. Put it somewhere like `/tmp/` on the new box.

### Step 5 — Create the empty database on the NEW server
```bash
# On the NEW server
sudo -u postgres createdb keycloak
sudo -u postgres createuser keycloak
# give the user a password + rights
sudo -u postgres psql -c "ALTER USER keycloak WITH PASSWORD 'YourStrongPasswordHere';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;"
```

### Step 6 — Load the backup in (the "restore")
```bash
# On the NEW server
pg_restore -h localhost -p 5432 -U keycloak -d keycloak \
  --no-owner --no-acl keycloak_backup.dump
```

### Step 7 — Point the new Keycloak at this database
In the new server's `conf/keycloak.conf`, make sure the DB settings match:
```properties
db=postgres
db-url=jdbc:postgresql://localhost:5432/keycloak
db-username=keycloak
db-password=YourStrongPasswordHere
```

### Step 8 — Start Keycloak and let it check the schema
```bash
# On the NEW server
sudo systemctl start keycloak
```
On first start, Keycloak looks at the database and, if the new Keycloak is a newer version, **automatically upgrades the database structure.** <cite index="8-1">By default the database is automatically migrated when you start the new installation for the first time.</cite>

### Step 9 — Verify it worked
- Log into the admin console on the new server.
- Check your realms are all there.
- Check a user list isn't empty.
- Actually log in as a test user.

🎉 **Done.** If all that works, you've migrated Keycloak offline.

---

# PART 2 — The Checklist (print this / tick as you go)

### ✅ Before you start (prerequisites)
- [ ] You know your DB name, username, password, host, and port
- [ ] Old and new Postgres are the **same major version** (or new one is newer — never older)
- [ ] New Keycloak version is the **same or newer** than the old one (never older)
- [ ] You have `pg_dump` and `pg_restore` installed (they come with Postgres client tools)
- [ ] You have enough disk space for the dump on both machines
- [ ] You have admin/sudo access on both servers
- [ ] You noted down any **custom themes** (`/themes/`) and **providers/extensions** (`/providers/`) — these are files, NOT in the database
- [ ] You saved a copy of `keycloak.conf`
- [ ] You have a maintenance window (users can't log in while Keycloak is stopped)

### ✅ On the OLD server
- [ ] Stopped Keycloak (freeze writes)
- [ ] Ran `pg_dump`
- [ ] Verified the dump file isn't empty
- [ ] Copied over custom themes & providers folders too

### ✅ Moving the files (offline)
- [ ] Dump file on USB / secure media
- [ ] Themes + providers folders copied
- [ ] `keycloak.conf` copied
- [ ] (Optional) file encrypted if it leaves a secure area — it contains password hashes!

### ✅ On the NEW server
- [ ] Empty database + user created
- [ ] Ran `pg_restore`
- [ ] Copied themes into `/themes/`, providers into `/providers/`
- [ ] Ran `kc.sh build` if you added providers/features (see gotchas)
- [ ] Edited `keycloak.conf` with correct DB details
- [ ] Started Keycloak, watched logs for errors
- [ ] Logged in and verified realms + users + a real login

---

# PART 3 — Gotchas (the stuff that bites people)

These are the "why isn't it working?!" landmines. Read them **before** you start.

**1. A realm export is NOT a full backup.** This is the #1 mistake. The JSON export skips users by default and isn't a true snapshot. For moving a server, always use `pg_dump`. <cite index="13-1">If you are running Keycloak in production and you have not confirmed a working restore procedure, you do not have a backup.</cite>

**2. You can't skip Keycloak versions.** If you're jumping several major versions, you must upgrade in steps. <cite index="9-1">You cannot jump directly from Keycloak 8 to 24 or 26.</cite> Keycloak also completely changed its engine over the years (from "WildFly" to "Quarkus"), so <cite index="9-1">between versions 8 and 26, the project replaced its entire runtime (WildFly to Quarkus), redesigned its admin console, and restructured its configuration system.</cite>

**3. Never restore into an OLDER Postgres or OLDER Keycloak.** Schema upgrades are one-way. Going backward corrupts things. Same-version-or-newer only.

**4. Don't upgrade "in place."** The safe pattern is to run the new version against a *copy* of the database. <cite index="9-1">Never upgrade in place. Run the new version as a separate instance pointing at a copy of your database.</cite> If it breaks, your original is untouched.

**5. Themes and custom extensions live on DISK, not in Postgres.** The dump does NOT include your custom login screens or plugin `.jar` files. You must copy `/themes/` and `/providers/` separately, or your branding/features vanish.

**6. If you add providers or turn on features, you must re-`build`.** Keycloak "bakes in" certain settings. Run `kc.sh build` after adding providers, then start. Some options <cite index="5-1">are build time configuration options.</cite>

**7. The dump file contains secrets.** It has user password hashes and client secrets inside. Treat it like a password list — encrypt it if it travels on a USB drive or over a network.

**8. Ownership/permission errors on restore.** Using `--no-owner --no-acl` (shown in the commands above) sidesteps most "role does not exist" errors when the new server's usernames differ from the old one's.

**9. `--clean --if-exists` wipes matching tables first.** Great for a clean reload, dangerous if you point it at a database that has other data you care about. Only restore into a database meant for Keycloak.

**10. Hostname/URL settings.** After moving, your new server may have a different address. Update `KC_HOSTNAME` / `hostname` settings, or logins and redirects will fail even though the data is fine.

**11. Old active sessions won't survive.** People who were logged in will need to log in again after the move. That's normal.

---

# PART 4 — Your Options, With Pros & Cons

### Option A — Full Postgres dump with `pg_dump` / `pg_restore` ✅ (what we did above)

The gold standard for moving a whole server offline.

**Pros**
- Copies **everything** exactly — users, hashes, clients, sessions, roles, the lot
- It's a real, restorable backup
- Simple two commands (dump, restore)
- Works perfectly offline — it's just a file

**Cons**
- The file has secrets in it (must protect it)
- Both databases should be the same/compatible Postgres version
- Doesn't include themes/providers (those are separate files)

**Use when:** migrating a whole server, doing real backups, disaster recovery. **This is your default.**

---

### Option B — Keycloak realm export (`kc.sh export` to JSON)

Exports the *configuration* of realms into human-readable JSON files.

```bash
# Export one realm, including users, to a folder
/opt/keycloak/bin/kc.sh export --dir /tmp/export --users realm_file --realm my-realm
```
On the new server you import it at startup:
```bash
/opt/keycloak/bin/kc.sh start --import-realm
```
<cite index="2-1">The --import-realm flag tells Keycloak to scan /opt/keycloak/data/import/ at startup and import any JSON files found there.</cite>

**Pros**
- Human-readable — you can open the JSON and see/edit settings
- Great for "config as code" and copying between dev/staging/prod
- Version-tolerant — moves config between different Keycloak versions more easily than a raw DB dump
- You can pick just one realm

**Cons**
- **Not a full backup.** <cite index="2-1">Client secrets and user password hashes are excluded from partial exports via the Admin Console.</cite> (Full CLI exports can include users, but it's still not a transaction-safe snapshot.)
- Import is skipped if the realm already exists, unless you override. <cite index="2-1">If a realm with the same name already exists, the import is skipped unless you use the --override flag (available in Keycloak 24+).</cite>
- You often need the Postgres JDBC driver configured for the export to reach the DB
- Easy to accidentally lose users

**Use when:** copying realm *settings* between environments, seeding a fresh system, storing config in Git. **Not for a full server move on its own.**

---

### The smart combo (best of both, optional)
For a bulletproof migration many teams do **both**: take the `pg_dump` (the real move) AND a realm JSON export (a readable safety copy you can diff/inspect). If something looks off after restore, the JSON gives you a second reference.

---

# PART 5 — Extra Background (nice to understand)

**What actually lives in the database?** <cite index="13-1">Keycloak stores all its state (realms, users, clients, roles, credentials, and session metadata) in its database.</cite> That's why the database IS the backup. <cite index="13-1">Keycloak is a stateful application. Every action taken by users, admins, or applications is persisted in the database.</cite>

**What are the `--users` export choices?** When exporting realms, you control how users are saved: <cite index="5-1">users can export into different JSON files depending on a max-users-per-file setting (the default), be skipped entirely, or be written into the same file as the realm settings.</cite>

**Two dump formats you'll see:**
- **Custom format** (`-F c`, makes a `.dump`) → restore with `pg_restore`. Flexible, compressible. Used in our Quick Start.
- **Plain SQL** (makes a `.sql`) → restore by piping into `psql`. Human-readable. A common plain-SQL command looks like:
  ```bash
  pg_dump -h host -p port -U user -d dbname \
    --no-owner --no-acl --clean --if-exists \
    -f keycloak_backup.sql
  ```
  Both work offline; pick one and stay consistent.

**Why "same or newer" matters:** newer Keycloak automatically runs a schema migration on first boot to update table structures. It can move data *forward* to a new layout, but it has no way to move it *backward*.

---

## TL;DR
1. It's really a **database migration** — the database is Keycloak's brain.
2. **Stop Keycloak → `pg_dump` → carry the file → `pg_restore` → point new Keycloak at it → start → verify.**
3. Also copy **themes** and **providers** (they're separate files).
4. Keep versions **same or newer**, never older, and don't skip major versions.
5. The dump file **has secrets** — protect it.
6. A realm JSON export is handy but is **not** a full backup by itself.
