## Updated files

* [Download the complete NiFi + Keycloak project](sandbox:/mnt/data/nifi-keycloak.zip)
* [Download the updated Docker Compose file](sandbox:/mnt/data/docker-compose-keycloak.yml)
* [Read the detailed setup and troubleshooting guide](sandbox:/mnt/data/nifi-keycloak/README.md)

The project uses pinned current releases:

* Apache NiFi `2.10.0`, released June 18, 2026. ([Apache NiFi][1])
* Keycloak `26.7.0`, released July 9, 2026. ([Keycloak][2])
* PostgreSQL `17-alpine` for the Keycloak database.

Pinned versions are safer than `latest` because an unexpected future image update will not silently change your environment.

## What was added

The updated stack includes:

* Apache NiFi configured for Keycloak login using OpenID Connect.
* Keycloak with its own PostgreSQL database.
* An automatically imported `nifi` realm.
* An automatically created confidential Keycloak client named `nifi`.
* An initial Keycloak user named `nifi-admin`.
* HTTPS certificates for NiFi and Keycloak.
* A NiFi truststore containing the Keycloak certificate.
* Keycloak and NiFi health checks.
* Persistent NiFi repositories, configuration, state, logs, and flows.
* Your original AWS credential variables and S3 download directory.
* A `.env.example` file for passwords, secrets, memory, and image versions.

NiFi’s official OIDC mode requires explicit keystore and truststore files, so the project includes a one-time `security-setup` container that creates them automatically. ([GitHub][3])

## Important NiFi 2.10 change

NiFi 2.10 accepts OIDC discovery addresses using `https` or `file` schemes. Therefore, Keycloak is also configured with HTTPS instead of plain HTTP. The official NiFi callback path is:

```text
/nifi-api/access/oidc/callback/consumer
```

([Apache NiFi][4])

The complete redirect URI configured in Keycloak is:

```text
https://localhost:8443/nifi-api/access/oidc/callback/consumer
```

## Basic startup steps

### 1. Extract the project

```bash
unzip nifi-keycloak.zip
cd nifi-keycloak
```

### 2. Create your environment file

macOS or Linux:

```bash
cp .env.example .env
```

Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Open `.env` and change every password or secret beginning with:

```text
ChangeMe-
```

### 3. Add the Keycloak hostname

NiFi uses the Docker service name `keycloak`. Your browser must use that same name.

On macOS or Linux:

```bash
sudo sh -c 'grep -qE "(^|[[:space:]])keycloak([[:space:]]|$)" /etc/hosts || echo "127.0.0.1 keycloak" >> /etc/hosts'
```

On Windows, open PowerShell as Administrator:

```powershell
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

if (-not (Select-String -Path $hostsFile -Pattern '(^|\s)keycloak(\s|$)' -Quiet)) {
    Add-Content -Path $hostsFile -Value "`r`n127.0.0.1 keycloak"
}
```

Test it:

```bash
ping keycloak
```

It should resolve to:

```text
127.0.0.1
```

### 4. Start everything

```bash
docker compose up -d
```

Watch startup:

```bash
docker compose logs -f security-setup keycloak nifi
```

Check status:

```bash
docker compose ps
```

The `security-setup` container should exit with code `0`. That is normal because it is a one-time setup job.

## Login addresses

### Keycloak administration

```text
https://keycloak:8444/admin/
```

Use the values from `.env`:

```text
KEYCLOAK_ADMIN_USERNAME
KEYCLOAK_ADMIN_PASSWORD
```

Keycloak supports startup realm imports from `/opt/keycloak/data/import` when started with `--import-realm`; the project uses that official process. ([Keycloak][5])

### NiFi

```text
https://localhost:8443/nifi/
```

Use:

```text
Username: nifi-admin
Password: value of NIFI_ADMIN_PASSWORD
```

Your browser will warn about the self-signed certificates. For this local development setup, open the advanced browser option and continue.

## How the login works

Keycloak handles **authentication**, which means proving who the person is.

NiFi handles **authorization**, which means deciding what the person may read, change, start, stop, or delete.

The login trip works like this:

1. You open NiFi.
2. NiFi sends your browser to Keycloak.
3. Keycloak checks the username and password.
4. Keycloak sends a signed login result back to NiFi.
5. NiFi reads the `preferred_username` claim.
6. NiFi sees the identity `nifi-admin`.
7. Because `INITIAL_ADMIN_IDENTITY` is also `nifi-admin`, NiFi grants that first identity administrator access.

These values must match exactly:

```yaml
INITIAL_ADMIN_IDENTITY: "nifi-admin"

NIFI_SECURITY_USER_OIDC_CLAIM_IDENTIFYING_USER: preferred_username
```

## Important reset warning

Your original Compose file used NiFi single-user authentication. The new file uses OIDC authentication.

For a new local environment, use a clean reset:

```bash
docker compose down -v
docker compose up -d
```

**Warning:** `docker compose down -v` deletes stored NiFi flows, users, policies, repository data, Keycloak data, and generated certificates. Back up existing NiFi configuration before using it.

I validated the YAML and JSON files and executed the certificate and realm-generation script successfully. Docker itself was not installed in my execution environment, so I could not launch the complete containers here.

[1]: https://nifi.apache.org/download/?utm_source=chatgpt.com "Download - Apache NiFi"
[2]: https://www.keycloak.org/2026/07/keycloak-2670-released?utm_source=chatgpt.com "Keycloak 26.7.0 released"
[3]: https://raw.githubusercontent.com/apache/nifi/rel/nifi-2.10.0/nifi-docker/dockerhub/sh/secure.sh "https://raw.githubusercontent.com/apache/nifi/rel/nifi-2.10.0/nifi-docker/dockerhub/sh/secure.sh"
[4]: https://nifi.apache.org/nifi-docs/administration-guide.html "https://nifi.apache.org/nifi-docs/administration-guide.html"
[5]: https://www.keycloak.org/server/containers "Running Keycloak in a container - Keycloak"
