# Configuring Kafka UI to log in with Keycloak — the complete guide

This document explains **every setting** needed to make Kafka UI (the
`kafbat/kafka-ui` image) use Keycloak as its login system, and *why* each
setting exists. It starts with a working example you can copy, then goes
deeper into how the login actually works, the role-based permissions, and the
mistakes that trip people up.

---

## Part 1 – Step-by-step setup (one working example)

### Step 1: Create a Keycloak realm
A **realm** is a separate "world" of users, roles and apps inside Keycloak.

1. Open the Keycloak admin console (e.g. `http://keycloak:8180`) → log in as admin.
2. Top-left dropdown → **Create realm** → name it `kafka` → **Create**.

### Step 2: Create two realm roles
Roles are labels you stick on users. Kafka UI will look at them later.

*Realm roles → Create role*:
* `kafka-admin`
* `kafka-viewer`

### Step 3: Create the Kafka UI client
A **client** is an application that is allowed to ask Keycloak "who is this user?".

*Clients → Create client*:

| Screen | Field | Value | Why |
|--------|-------|-------|-----|
| General | Client type | `OpenID Connect` | The protocol Kafka UI speaks. |
| General | Client ID | `kafka-ui` | Must match `clientId` in Kafka UI config. |
| Capability | Client authentication | **On** | Makes it a *confidential* client with a secret. Kafka UI is a server-side app, so it can keep a secret. |
| Capability | Standard flow | **On** | This is the "Authorization Code" flow — the browser-redirect login. |
| Capability | Direct access grants, Implicit flow, Service accounts | Off | Not needed; leaving them off reduces attack surface. |
| Login settings | Valid redirect URIs | `http://localhost:8080/*` | After login Keycloak may only send the user back to these URLs. Use your real Kafka UI address. |
| Login settings | Web origins | `http://localhost:8080` | Allowed CORS origin. |

Save, then open the **Credentials** tab and copy the **Client secret**.

### Step 4: Put the user's roles into the token
By default Keycloak puts realm roles under `realm_access.roles` inside the
token — a *nested* field Kafka UI cannot read. Add a mapper that writes them
to a *flat* claim called `roles`.

*Clients → kafka-ui → Client scopes → kafka-ui-dedicated → Add mapper → By configuration → **User Realm Role***:

| Field | Value |
|-------|-------|
| Name | `realm roles -> roles claim` |
| Token Claim Name | `roles` |
| Claim JSON Type | String |
| Multivalued | On |
| Add to ID token | On |
| Add to access token | On |
| Add to userinfo | On |

### Step 5: Create users and give them roles
*Users → Add user* → username `alice` → **Credentials** tab → set password
(temporary **off**) → **Role mapping** → assign `kafka-admin`.
Repeat for `bob` with `kafka-viewer`.

### Step 6: Configure Kafka UI
Kafka UI can be configured with **environment variables** (used in this
project's `docker-compose.yml`) or a **`config.yml`** file. Both shown; pick one.

#### Option A — environment variables
```yaml
kafka-ui:
  image: ghcr.io/kafbat/kafka-ui:latest
  environment:
    KAFKA_CLUSTERS_0_NAME: local
    KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:9092

    AUTH_TYPE: OAUTH2
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTID: kafka-ui
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET: <secret from Step 3>
    AUTH_OAUTH2_CLIENT_KEYCLOAK_SCOPE: openid
    AUTH_OAUTH2_CLIENT_KEYCLOAK_ISSUER_URI: http://keycloak:8180/realms/kafka
    AUTH_OAUTH2_CLIENT_KEYCLOAK_USER_NAME_ATTRIBUTE: preferred_username
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENT_NAME: Keycloak
    AUTH_OAUTH2_CLIENT_KEYCLOAK_PROVIDER: keycloak
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CUSTOM_PARAMS_TYPE: oauth
    AUTH_OAUTH2_CLIENT_KEYCLOAK_CUSTOM_PARAMS_ROLES_FIELD: roles
```

#### Option B — `config.yml` (mount it and set `SPRING_CONFIG_ADDITIONAL-LOCATION=/config.yml`)
```yaml
kafka:
  clusters:
    - name: local
      bootstrapServers: kafka:9092

auth:
  type: OAUTH2
  oauth2:
    client:
      keycloak:                       # any name; it becomes the registration id
        clientId: kafka-ui
        clientSecret: <secret from Step 3>
        scope: openid
        issuer-uri: http://keycloak:8180/realms/kafka
        user-name-attribute: preferred_username
        client-name: Keycloak
        provider: keycloak
        custom-params:
          type: oauth
          roles-field: roles

rbac:
  roles:
    - name: admins
      clusters: [ local ]
      subjects:
        - provider: oauth
          type: role
          value: kafka-admin
      permissions:
        - resource: applicationconfig
          actions: all
        - resource: clusterconfig
          actions: all
        - resource: topic
          value: ".*"
          actions: all
        - resource: consumer
          value: ".*"
          actions: all
        - resource: schema
          value: ".*"
          actions: all
        - resource: connect
          value: ".*"
          actions: all
        - resource: acl
          actions: all
        - resource: audit
          actions: all

    - name: viewers
      clusters: [ local ]
      subjects:
        - provider: oauth
          type: role
          value: kafka-viewer
      permissions:
        - resource: clusterconfig
          actions: [ view ]
        - resource: topic
          value: ".*"
          actions: [ view, messages_read ]
        - resource: consumer
          value: ".*"
          actions: [ view ]
```

### Step 7: Start and test
```bash
docker compose up -d kafka-ui
docker compose logs -f kafka-ui        # look for "Started KafkaUiApplication"
```
Open Kafka UI → you should see a **Keycloak** login button → log in as alice.

---

## Part 2 – Background: what happens when you log in

1. You open Kafka UI. It has no session for you, so it **redirects** your
   browser to Keycloak's login page (the *authorization endpoint*).
2. You type your password **into Keycloak**, never into Kafka UI.
3. Keycloak sends your browser back to Kafka UI's *redirect URI* with a
   one-time **authorization code**.
4. Kafka UI (server side) exchanges the code + its **client secret** for
   tokens at Keycloak's *token endpoint*.
5. Keycloak returns an **ID token** (a signed JWT). Kafka UI checks the
   signature using Keycloak's public keys (*JWKS endpoint*) and reads the
   claims: `preferred_username`, `roles`, …
6. Kafka UI creates a session and applies **RBAC** rules based on `roles`.

Kafka UI discovers all those endpoint URLs automatically from one address —
the **issuer URI** — by fetching
`<issuer>/.well-known/openid-configuration`. That is why the issuer must be
correct and reachable from the Kafka UI container.

---

## Part 3 – Every setting explained

### `auth.type`
| Value | Meaning |
|-------|---------|
| `DISABLED` | No login (default). |
| `LOGIN_FORM` | Simple built-in username/password list. |
| `OAUTH2` | Delegate login to an OIDC provider such as Keycloak. **Use this.** |
| `LDAP` | Bind against an LDAP/AD server. |

### `auth.oauth2.client.<name>.*`
`<name>` (we used `keycloak`) is just a label; it appears in the callback URL
`/login/oauth2/code/<name>`. Env-var form: `AUTH_OAUTH2_CLIENT_<NAME>_<SETTING>`.

| Setting | Required | Value for Keycloak | What it does |
|---------|----------|--------------------|--------------|
| `clientId` | yes | `kafka-ui` | The client ID you created in Keycloak. |
| `clientSecret` | yes | from Credentials tab | Proves to Keycloak that it is really Kafka UI exchanging the code. |
| `scope` | yes | `openid` | Asks for an OIDC ID token. Add `profile email` if you want name/email claims (Keycloak adds them by default anyway). |
| `issuer-uri` | yes | `http(s)://<host>/realms/<realm>` | Base URL of the realm. Kafka UI fetches `/.well-known/openid-configuration` from it and also checks that tokens' `iss` claim equals this exact string. Keycloak < 17 used `/auth/realms/<realm>`. |
| `user-name-attribute` | recommended | `preferred_username` | Which claim becomes the displayed username. Alternatives: `email`, `sub`. |
| `client-name` | no | `Keycloak` | Label on the login button. |
| `provider` | recommended | `keycloak` | Tells Kafka UI which role-extraction logic to use. Other values: `github`, `google`, `cognito`. |
| `custom-params.type` | for RBAC | `oauth` | Selects the generic OAuth role extractor. |
| `custom-params.roles-field` | for RBAC | `roles` | Name of the (flat, top-level) claim that holds the user's roles. Must match the mapper from Step 4. |
| `redirect-uri` | no | `{baseUrl}/login/oauth2/code/{registrationId}` | Override only if Kafka UI sits behind a reverse proxy with a different public URL. |
| `authorization-uri`, `token-uri`, `user-info-uri`, `jwk-set-uri` | no | (auto-discovered) | Set these explicitly only if you cannot use `issuer-uri` discovery. |

### `rbac.roles[]`
Without an `rbac` block, **every** authenticated user gets full access. With
it, users get only what their matched roles grant.

| Field | Meaning |
|-------|---------|
| `name` | Name of the Kafka UI role (free text). |
| `clusters` | Which cluster names (from `kafka.clusters[].name`) the role applies to. |
| `subjects[]` | Who gets this role. `provider: oauth`, `type: role`, `value: <Keycloak role name>` matches a value inside the `roles` claim. `type: user` matches a username instead. |
| `permissions[]` | List of `resource` + `actions` (+ `value` regex for named resources). |

**Resources and their actions**

| Resource | Needs `value` (regex)? | Actions |
|----------|------------------------|---------|
| `applicationconfig` | no | `view`, `edit` |
| `clusterconfig` | no | `view`, `edit` |
| `topic` | yes | `view`, `create`, `edit`, `delete`, `messages_read`, `messages_produce`, `messages_delete`, `analysis_view`, `analysis_run` |
| `consumer` | yes | `view`, `delete`, `reset_offsets` |
| `schema` | yes | `view`, `create`, `delete`, `edit`, `modify_global_compatibility` |
| `connect` | yes | `view`, `edit`, `create`, `restart` |
| `ksql` | no | `execute` |
| `acl` | no | `view`, `edit` |
| `audit` | no | `view` |

`actions: all` is shorthand for every action on that resource.

### Keycloak-side settings that matter to Kafka UI

| Keycloak setting | Why it matters |
|------------------|----------------|
| `KC_HOSTNAME` (or the URL you access Keycloak with) | Determines the `iss` claim in tokens. It **must** equal `issuer-uri` character for character, including scheme and port. |
| Valid redirect URIs on the client | Must include `<kafka-ui-url>/login/oauth2/code/<name>` (a `/*` wildcard covers it). |
| Client authentication = On | Required, because Kafka UI sends a client secret. |
| Realm role mapper → flat claim | Required for RBAC; otherwise everyone matches no role and sees nothing. |

---

## Part 4 – Options, pros and cons

| Decision | Option 1 | Option 2 |
|----------|----------|----------|
| Config format | **Env vars** – all in compose file, easy to override per environment; long RBAC lists get noisy. | **config.yml** – readable, supports comments, natural for RBAC; one more file to mount. |
| Role source | **Realm roles** (this guide) – simple, global to the realm. | **Client roles** – scoped to the `kafka-ui` client; use mapper type *User Client Role* and point `roles-field` at its claim. Better when one realm serves many apps. |
| Role source | **Groups** – map Keycloak groups with a *Group Membership* mapper (claim `groups`, "full group path" off) and set `roles-field: groups`. Handy when groups already mirror teams. | |
| Endpoint discovery | **issuer-uri** – one setting, auto-discovers everything, validates issuer. | **Explicit URIs** – needed when browser and container reach Keycloak by different hostnames; more settings, no issuer validation. |
| Transport | **HTTP** – fine on a laptop. | **HTTPS** – mandatory outside localhost; tokens are bearer credentials. |

### Best practices
* Give Kafka UI its **own client** in Keycloak; don't reuse another app's client.
* Keep the client secret out of git: reference it from a `.env` file or a secrets manager.
* Always define an `rbac` block in shared environments; default-deny beats default-allow.
* Use a **dedicated viewer role** as the default for humans and reserve admin for operators.
* Set `KC_HOSTNAME` explicitly so the issuer doesn't change when someone hits Keycloak via a different URL.
* Test with two users (admin + viewer) so you notice broken role mapping immediately.

---

## Part 5 – Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Kafka UI crashes at startup: *Unable to resolve the Configuration with the provided Issuer* | Container can't reach `issuer-uri`. | Use a hostname resolvable inside Docker (`keycloak`), make sure Keycloak is up first (`depends_on` + healthcheck). |
| Browser: "keycloak refused to connect" | Browser can't resolve the hostname in the redirect. | Add hosts-file entry, or use explicit `authorization-uri` with a browser-reachable host. |
| Keycloak page: *Invalid parameter: redirect_uri* | Redirect URI not whitelisted. | Add `<kafka-ui-url>/*` to the client's Valid redirect URIs. |
| Login loops / *invalid_id_token* / issuer mismatch | `iss` in the token ≠ `issuer-uri`. | Align `KC_HOSTNAME` and `issuer-uri` exactly (scheme, host, port, no trailing slash). |
| *unauthorized_client* or *invalid_client_credentials* | Wrong secret or client auth off. | Re-copy the secret; turn on Client authentication. |
| Logged in but every page is empty / 403 | RBAC enabled but roles claim missing. | Add the realm-role mapper (Step 4); confirm `roles-field` matches the claim name; inspect the token at jwt.io. |
| Username shows as a long UUID | `user-name-attribute` not set. | Set it to `preferred_username`. |
| Clock-related token errors | Container clock skew. | Sync host time; Docker containers inherit it. |

To see exactly what Keycloak puts in the token: Keycloak console → Clients →
kafka-ui → Client scopes → **Evaluate** → pick a user → *Generated ID token*.
