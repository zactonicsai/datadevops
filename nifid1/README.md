# Apache NiFi 1.28 + Keycloak OIDC login

Two containers, one script. NiFi runs on HTTPS and hands login off to Keycloak.

## Setup (4 steps)

**1. Add a hosts entry.** Browser and NiFi must reach Keycloak at the *same* URL,
otherwise the token issuer won't match and login fails.

```bash
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```
Windows: add `127.0.0.1 keycloak` to `C:\Windows\System32\drivers\etc\hosts` as admin.

**2. Start it.**

```bash
chmod +x verify.sh nifi/oidc-entrypoint.sh
docker compose up -d
docker compose logs -f nifi     # wait for "NiFi has started"  (~2 min first time)
```

**3. Verify.**

```bash
./verify.sh
```
It performs a real authorization-code login with curl and checks that NiFi
returns the identity `admin@nifi.local` with admin policies.

**4. Log in.** Open <https://localhost:8443/nifi> → accept the self-signed cert
warning → you land on the Keycloak login page.

| | user | password |
|---|---|---|
| NiFi admin | `nifi-admin` | `nifi-admin-password` |
| plain user (no NiFi policies yet) | `nifi-user` | `nifi-user-password` |
| Keycloak console (<http://keycloak:8080>) | `admin` | `admin` |

## Files

```
docker-compose.yml           two services, keycloak + nifi
.env                         every password/secret in one place
keycloak/realm-nifi.json     realm "nifi", client "nifi", two users
nifi/oidc-entrypoint.sh      certs + nifi.properties + authorizers.xml, then starts NiFi
verify.sh                    end-to-end test
fix-keycloak.sh              repairs roles/scopes on a running Keycloak
```

## How it works

- **TLS is mandatory.** NiFi refuses OIDC over plain HTTP, so the entrypoint
  generates a self-signed PKCS12 keystore/truststore (SAN: `localhost`, `nifi`,
  `127.0.0.1`) on first boot and turns `nifi.web.http.port` off.
- **Identity mapping.** `nifi.security.user.oidc.claim.identifying.user=email`,
  so the Keycloak user's email (`admin@nifi.local`) *is* the NiFi username. That
  same string is the `Initial Admin Identity` in `authorizers.xml`.
- **One auth mechanism only.** NiFi 1.x fails to start if OIDC and a login
  identity provider are both configured, so `single-user-provider` is cleared.
- **NiFi asks for every scope.** Since 1.21, NiFi reads `scopes_supported` from
  the discovery document and requests all of them, including `offline_access`.
  So each realm user needs the `offline_access` role, and the client needs every
  realm scope assigned. `fix-keycloak.sh` handles both.
- **Startup order.** NiFi reads the discovery document at boot, so it waits on a
  Keycloak healthcheck.

## Common changes

**Give another user access:** log in as admin → hamburger menu → Users → Add
User with their email → then Policies. Or add their email as
`Initial User Identity 2` in the entrypoint and wipe the `nifi-conf` volume.

**Change a password/secret:** edit `.env` *and* `keycloak/realm-nifi.json` (the
client secret and user passwords live in both). `verify.sh` step 2 catches drift.

**Re-import the realm after editing `realm-nifi.json`:** the import only runs on an
empty Keycloak database, so recreate the container:
`docker compose rm -sf keycloak && docker compose up -d keycloak`

**Reset everything:** `docker compose down -v && docker compose up -d`

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Unable to retrieve OpenId Connect Provider metadata` in nifi logs | Keycloak not up, or discovery URL wrong |
| Login loops, or `Unable to exchange authorization code` | issuer mismatch — you skipped the `/etc/hosts` entry |
| `Invalid parameter: redirect_uri` on the Keycloak page | you're using a URL other than `https://localhost:8443` |
| Logged in but "Untrusted proxy" / no permissions | identity ≠ Initial Admin Identity; check `docker compose exec nifi cat conf/users.xml` |
| NiFi exits at boot | check `docker compose logs nifi` for the property it rejected |
| Keycloak: `Offline tokens not allowed for the user or client` | user lacks the `offline_access` role — run `./fix-keycloak.sh` |
| Keycloak: `Invalid scopes: ... offline_access` | client is missing scopes NiFi requests — run `./fix-keycloak.sh --scopes` |
| Keycloak: `bootstrap-admin-username available only when bootstrap admin password is set` | `.env` not found by Compose — run `docker compose config \| grep BOOTSTRAP` and check `ls -la` shows `.env` next to `docker-compose.yml` |

Logs: `docker compose exec nifi tail -f logs/nifi-app.log`

## Not for production

Self-signed certs, secrets in plaintext, Keycloak in `start-dev` with an
in-memory database. For real use: a real CA cert, Keycloak on HTTPS with
Postgres, and secrets from a vault rather than `.env`.
