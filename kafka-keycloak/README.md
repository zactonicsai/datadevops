# Kafka + Kafka UI + Keycloak login — a step-by-step tutorial

This project starts, with one command, a small **Apache Kafka** cluster, a web
dashboard (**Kafka UI**) that you must **log in to through Keycloak**, four
ready-made topics, and a tiny Python program that sends test messages.

```
Browser ──login──▶ Keycloak (identity)      Python producer.py
   │                     ▲                        │
   ▼                     │ verifies token         ▼ localhost:29092
Kafka UI ────────────────┘ ───────────────▶ Kafka broker (topics: orders, payments, ...)
```

---

## Part 1 – Set it up (about 5 minutes)

### Step 1: Requirements
* Docker Desktop (or Docker Engine + Compose v2)
* Python 3.9+ (only for the test client)

### Step 2: Add one line to your hosts file
Keycloak must be reachable under the **same name** from your browser *and* from
the Kafka UI container, otherwise the login redirect fails. We use the name
`keycloak` for both.

| OS | File | Line to add |
|----|------|-------------|
| macOS / Linux | `/etc/hosts` (use `sudo`) | `127.0.0.1  keycloak` |
| Windows | `C:\Windows\System32\drivers\etc\hosts` (run editor as admin) | `127.0.0.1  keycloak` |

### Step 3: Start everything
```bash
docker compose up -d
docker compose logs -f kafka-init     # watch the topics get created, then Ctrl+C
```
The first start downloads images and takes ~1–2 minutes. Keycloak imports the
realm automatically; Kafka UI waits until Keycloak reports healthy.

### Step 4: Log in to Kafka UI
1. Open <http://localhost:8080> — you are redirected to Keycloak.
2. Log in with **alice / alice123** (full admin) or **bob / bob123** (read-only).
3. You land on cluster `local` with the topics `orders`, `payments`,
   `user-events`, `audit-log`.

Keycloak admin console (to add users/roles): <http://keycloak:8180> → **admin / admin**.

### Step 5: Send test messages with Python
```bash
cd client
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt

python producer.py                 # 5 JSON messages into every demo topic
python producer.py -t orders -n 50 # 50 messages into one topic
python consumer.py -t orders       # read them back (Ctrl+C to stop)
```
Refresh **Topics → orders → Messages** in Kafka UI and you will see them.

### Step 6: Stop / reset
```bash
docker compose down        # stop, keep Kafka data
docker compose down -v     # stop and delete all data (fresh start)
```

---

## Part 2 – Background: what are these pieces?

**Kafka** is a *message log*. Programs (producers) write records to named
**topics**; other programs (consumers) read them, at their own pace. Each topic
is split into **partitions** so many consumers can read in parallel; messages
with the same **key** always land in the same partition, so they stay in order.

**KRaft** is Kafka's built-in cluster coordination. Older setups needed a
separate ZooKeeper service; since Kafka 3.x that is no longer required, so this
compose file has a single `kafka` container acting as both broker and controller.

**Kafka UI** (the `kafbat/kafka-ui` image, the maintained successor of
Provectus UI) is a web app to browse topics, messages, consumer groups and
create topics by clicking. It has no users of its own — it trusts an identity
provider.

**Keycloak** is an open-source identity provider. It stores users, passwords and
roles, and speaks **OpenID Connect (OIDC)**: when Kafka UI needs to know who you
are, it bounces you to Keycloak's login page, Keycloak sends back a signed
**ID token** containing your username and roles, and Kafka UI verifies the
signature.

---

## Part 3 – How the pieces are wired (file by file)

### `docker-compose.yml`

| Service | What it does | Key settings |
|---------|--------------|--------------|
| `kafka` | Single KRaft broker | Two listeners: `kafka:9092` for containers, `localhost:29092` for your laptop. Auto-topic creation is **off** so only intentional topics exist. |
| `kafka-init` | Runs once, creates topics, exits | Uses `--if-not-exists`, so re-running is safe. `audit-log` shows per-topic config (7-day retention). |
| `keycloak` | Identity provider (dev mode) | `--import-realm` loads `keycloak/realm-kafka.json` on first boot. `KC_HOSTNAME=http://keycloak:8180` pins the token *issuer* URL. |
| `kafka-ui` | Dashboard | `AUTH_TYPE=OAUTH2` + `AUTH_OAUTH2_CLIENT_KEYCLOAK_*` configure the OIDC client; `RBAC_ROLES_*` map Keycloak roles to permissions. |

### `keycloak/realm-kafka.json`
* Realm **kafka** with two realm roles: `kafka-admin`, `kafka-viewer`.
* Client **kafka-ui** (confidential, secret `kafka-ui-secret-change-me`) allowed
  to redirect back to `http://localhost:8080/*`.
* A **protocol mapper** that copies the user's realm roles into a `roles` claim
  in the ID token and userinfo. Kafka UI reads that claim
  (`CUSTOM_PARAMS_ROLES_FIELD: roles`) to decide what you may do.
* Users **alice** (admin) and **bob** (viewer).

### `client/producer.py` / `client/consumer.py`
Plain `confluent-kafka` (librdkafka) clients. The producer builds realistic JSON
per topic, uses a delivery callback so you see partition/offset per message,
and calls `flush()` before exiting so nothing is lost. The consumer uses a
consumer group and starts from the earliest offset.

---

## Part 4 – Try these next

* **Add a user**: Keycloak console → realm *kafka* → Users → Add → set password
  → Role mapping → assign `kafka-viewer`. Log in as that user: you can read
  messages but the "Produce message" and "Delete topic" buttons are gone.
* **Add a topic**: as alice, Topics → Add a Topic. Then
  `python producer.py -t mytopic`.
* **Change permissions**: edit the `RBAC_ROLES_*` block in the compose file,
  `docker compose up -d kafka-ui`.

---

## Part 5 – Options, pros and cons

| Choice made here | Alternative | Trade-off |
|------------------|-------------|-----------|
| Hosts-file entry `keycloak` | Real DNS name + TLS | The hosts entry is quick for local dev; in production use a proper hostname with HTTPS and `KC_HOSTNAME_STRICT=true`. |
| Keycloak `start-dev` (in-memory H2 DB) | `start` with PostgreSQL | Dev mode is zero-config but loses data on `down -v`; production needs an external DB and TLS. |
| Broker listeners are `PLAINTEXT` | SASL/OAUTHBEARER against Keycloak, or mTLS | Only the *UI* is protected here. To make the *broker* require Keycloak tokens, add `security.protocol=SASL_SSL` + `sasl.mechanism=OAUTHBEARER` (Kafka's built-in OIDC support) — a good follow-up project. |
| RBAC via env vars | `config.yml` mounted into Kafka UI | Env vars keep everything in one file; YAML is nicer once you have many roles. |
| `confluent-kafka` Python client | `kafka-python` | confluent-kafka is faster and actively maintained (C library); kafka-python is pure Python and easier to install where a compiler is missing. |
| Static secret in files | `.env` file / Docker secrets | Fine for a demo. Never commit real secrets; rotate the client secret in Keycloak and the compose file together. |

## Best practices worth keeping
* Keep `KAFKA_AUTO_CREATE_TOPICS_ENABLE=false` — typos then fail loudly instead of silently creating topics.
* Always set a **key** on messages that must stay ordered (orders by `order_id`, events by `user`).
* Always `flush()` a producer before your program exits.
* Give every consumer program its own `group.id`, and name it after the program.
* Give users the *least* role that works (`kafka-viewer` by default, `kafka-admin` only for operators).

## Troubleshooting
| Symptom | Fix |
|---------|-----|
| Browser shows "keycloak refused to connect" | Hosts-file line missing (Step 2). |
| Kafka UI keeps restarting with "issuer" errors | Keycloak not healthy yet — `docker compose logs keycloak`; it retries automatically. |
| "Invalid redirect URI" on Keycloak page | You opened Kafka UI on a URL other than `http://localhost:8080`. Add it to `redirectUris` in the realm JSON and `docker compose down -v && up -d`. |
| Python: "Connection refused" | Use `-b localhost:29092`, not 9092 (9092 is only reachable inside Docker). |
| Realm changes not applied | Import runs only on an empty database: `docker compose down -v` then `up -d`. |
