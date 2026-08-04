## Recommended upgrade path

The current Keycloak 26 server release is **26.7.0**, released July 9, 2026. Your existing PostgreSQL 15 database is supported by Keycloak 26.7.0. ([Keycloak][1])([Keycloak][1])start-dev` environment, I recommend:

```text
Keycloak 20.0.5
      ↓
Keycloak 26.7.0
```

This direct upgrade is reasonable for your local setup as long as users can log in again. Keycloak 20 normally keeps online sessions in memory, so stopping the Keycloak 20 container already ends those sessions. Keycloak 26 also changed its cache serialization and clears incompatible caches during the upgrade. ([Keycloak][2])oad the upgraded project

[Download the Keycloak 20-to-26 upgrade project](sandbox:/mnt/data/keycloak-26-upgrade-compose.zip)

It contains:

```text
keycloak-26-upgrade-compose/
├── Dockerfile
├── docker-compose.yml
├── .env.example
├── README.md
└── scripts/
    ├── backup-database.sh
    ├── upgrade-to-26.sh
    ├── restore-database.sh
    └── show-database-version.sh
```

## Important warning

Keycloak automatically upgrades the PostgreSQL database schema during its first startup. After that happens, the upgraded database should not be used with Keycloak 20. A rollback requires restoring the database backup. Keycloak’s official guide specifically requires backing up the installation and database before an upgrade. ([Keycloak][2])un:

```bash
docker compose down --volumes
```

That can delete the PostgreSQL volume.

## Step 1: Work from the original directory

Run the upgrade from the **same directory that currently contains your Keycloak 20 Compose file**.

Docker Compose uses the project directory when naming volumes. Using a different directory could cause Docker to create a new, empty database volume.

Save your old files:

```bash
cd keycloak-20-source-compose

mkdir -p pre-upgrade-keycloak20

cp Dockerfile \
   docker-compose.yml \
   README.md \
   pre-upgrade-keycloak20/
```

Check the existing volume:

```bash
docker volume ls | grep keycloak_postgres_data
```

You should see something similar to:

```text
keycloak-20-source-compose_keycloak_postgres_data
```

## Step 2: Copy the upgraded files

Unzip the downloaded project:

```bash
unzip keycloak-26-upgrade-compose.zip
```

Copy its files over the original project:

```bash
cp keycloak-26-upgrade-compose/Dockerfile .
cp keycloak-26-upgrade-compose/docker-compose.yml .
cp keycloak-26-upgrade-compose/.env.example .
cp -R keycloak-26-upgrade-compose/scripts .
```

Create the environment file:

```bash
cp .env.example .env
```

Edit `.env`:

```dotenv
KEYCLOAK_VERSION=26.7.0

POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=change-this-database-password

KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=change-this-admin-password
```

The PostgreSQL values must exactly match the values used by Keycloak 20.

The new `KC_BOOTSTRAP_ADMIN_USERNAME` and `KC_BOOTSTRAP_ADMIN_PASSWORD` variables replace the older administrator bootstrap variable names. They create an administrator only when one does not already exist; they do not change an existing administrator’s password. ([Keycloak][3])3: Run the automated upgrade

Make sure the scripts are executable:

```bash
chmod +x scripts/*.sh
```

Run:

```bash
./scripts/upgrade-to-26.sh
```

The script will:

1. Start PostgreSQL if needed.
2. Create a PostgreSQL backup.
3. Stop Keycloak 20 without deleting the database.
4. Build Keycloak 26.7.0 from the official ZIP distribution.
5. Start Keycloak 26.
6. Let Keycloak automatically migrate the database.

The backup will be stored under:

```text
backups/keycloak-before-upgrade-YYYYMMDD-HHMMSS.dump
```

## Step 4: Watch the migration

Follow the logs:

```bash
docker compose logs -f keycloak
```

The first startup can take longer because Keycloak must update the database.

Do not stop the container while schema migration is running.

Check the containers:

```bash
docker compose ps
```

## Step 5: Test health

Keycloak 26 serves health and metrics through the management interface, normally on port `9000`. ([Keycloak][4])`bash
curl [http://localhost:9000/health/ready](http://localhost:9000/health/ready)

````

Expected result:

```json
{
  "status": "UP"
}
````

Open the Admin Console:

```text
http://localhost:8080/admin/
```

Check the database migration version:

```bash
./scripts/show-database-version.sh
```

## Step 6: Test existing data

Verify:

```text
Administrator login
Realms
Users
Groups
Roles
Clients
Client secrets
Redirect URLs
Normal user login
Token refresh
Logout
Password reset
LDAP or Active Directory
External identity providers
Custom themes
Custom providers
```

Test the OpenID Connect discovery endpoint:

```bash
curl \
  http://localhost:8080/realms/master/.well-known/openid-configuration
```

You should receive a large JSON response describing the Keycloak endpoints.

## What changed in the Dockerfile

The upgraded Dockerfile uses Java 21:

```dockerfile
FROM eclipse-temurin:21-jre-jammy
```

Keycloak currently supports Java 17, 21, and 25, while its official container image uses Java 21. ([Keycloak][5])oads:

```text
keycloak-26.7.0.zip
```

Then prepares PostgreSQL, health, and metrics support before starting:

```dockerfile
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build
```

Development startup remains:

```yaml
command:
  - start-dev
```

Do not use:

```text
start-dev --optimized
```

For production, because the Dockerfile already runs `kc.sh build`, use:

```yaml
command:
  - start
  - --optimized
```

The `--optimized` option requires the server to have been built first. ([Keycloak][6])tibility problems to check

### Custom provider JAR files

Keycloak 22 moved to Quarkus 3 and Jakarta EE. Custom providers compiled against older `javax.*` APIs might need to be rebuilt using `jakarta.*` APIs and Keycloak 26 dependencies. ([Keycloak][7])om themes

Keycloak 25 removed Account Console v2, and Keycloak 26 uses a newer default login theme. Test all custom login, account, admin, and email themes. ([Keycloak][8])Java adapters

Most older Java application adapters—including the Spring, Spring Boot, Tomcat, WildFly, servlet-filter, and similar adapters—were removed from Keycloak downloads. Applications should generally use the OAuth 2.0 or OpenID Connect support provided by their application framework. ([Keycloak][9])name and reverse proxy settings

Keycloak 25 introduced its newer hostname configuration. Older settings such as `KC_PROXY`, `KC_HOSTNAME_URL`, and `KC_HOSTNAME_ADMIN_URL` may require migration when Keycloak runs behind a load balancer or reverse proxy. ([Keycloak][9]) sessions

Persistent user sessions are enabled by default in Keycloak 26, meaning session data is now stored in PostgreSQL as well as cached in memory. This helps sessions survive restarts but increases database activity. ([Keycloak][7])to upgrade through Keycloak 25

Use this longer path when you have external Infinispan or JDBC-backed session storage and must preserve active sessions:

```text
20.0.5
   ↓
25.0.6 with persistent-user-sessions enabled
   ↓
26.7.0
```

Keycloak 25.0.6 was the final 25.0 patch release. The persistent session feature must be enabled during the first Keycloak 25 startup for supported session migration. In-memory sessions from older single-node deployments cannot be migrated, so this extra step does not preserve the current sessions in your existing local Compose setup. ([Keycloak][10])ack

Stop Keycloak 26:

```bash
docker compose stop keycloak
```

Find the backup:

```bash
ls -lh backups/
```

Restore it:

```bash
CONFIRM_RESTORE=YES \
./scripts/restore-database.sh \
backups/keycloak-before-upgrade-YYYYMMDD-HHMMSS.dump
```

Restore the old files:

```bash
cp pre-upgrade-keycloak20/Dockerfile .
cp pre-upgrade-keycloak20/docker-compose.yml .
cp pre-upgrade-keycloak20/README.md .
```

Rebuild Keycloak 20:

```bash
docker compose build --no-cache keycloak
docker compose up -d
```

The Compose YAML and shell-script syntax in the package were validated. A complete Docker image build could not be run in my environment because Docker is not installed.

[1]: https://www.keycloak.org/2026/07/keycloak-2670-released?utm_source=chatgpt.com "Keycloak 26.7.0 released - Keycloak"
[2]: https://www.keycloak.org/docs/latest/upgrading/index.html?utm_source=chatgpt.com "Upgrading Guide"
[3]: https://www.keycloak.org/docs/latest/server_admin/?utm_source=chatgpt.com "Server Administration Guide"
[4]: https://www.keycloak.org/server/containers?utm_source=chatgpt.com "Running Keycloak in a container - Keycloak"
[5]: https://www.keycloak.org/server/supported-configurations?utm_source=chatgpt.com "Supported Configurations - Keycloak"
[6]: https://www.keycloak.org/docs/latest/upgrading/?utm_source=chatgpt.com "Upgrading Guide"
[7]: https://www.keycloak.org/docs/latest/release_notes/index?utm_source=chatgpt.com "Release Notes"
[8]: https://www.keycloak.org/docs/latest/release_notes/index.html?utm_source=chatgpt.com "Release Notes"
[9]: https://www.keycloak.org/2024/06/keycloak-2500-released?utm_source=chatgpt.com "Keycloak 25.0.0 released - Keycloak"
[10]: https://www.keycloak.org/2024/09/keycloak-2506-released?utm_source=chatgpt.com "Keycloak 25.0.6 released - Keycloak"
