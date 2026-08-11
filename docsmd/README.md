# Grocery Operations Intelligence Platform

A dockerized, event-driven analytics platform for grocery-store operations. A Kafka cluster ingests operational messages (sales, inventory, deliveries, feedback, promotions, binary uploads), Python services compute profit/loss/forecast analytics, and an IBM Carbon–styled dashboard lets an **admin**, **manager**, and **investor** plan operations and project profit. An Ollama + ChromaDB assistant answers free-text **what-if** questions grounded in your live store metrics.

## Architecture

A standalone diagram is included at [`docs/architecture.svg`](docs/architecture.svg).

An interactive, line-by-line tutorial covering every service, its configuration, and how they work together is in [`docs/tutorial.html`](docs/tutorial.html) — a single static HTML page (light/dark mode, font-size scaler, expandable code annotations and detail popups).

Example Apache NiFi flows wired to the grocery scenarios (simulate sales into Kafka, branch feedback by sentiment, scheduled what-if report) are documented in [`docs/nifi-flows.html`](docs/nifi-flows.html).

```
                         ┌──────────────────────────────┐
  Browser ─► :8080 LB ─► │  /        → dashboard         │
        (NGINX)          │  /api/    → message-api  (x3) │
                         │  /analytics/ → analytics     │
                         │  /nifi/   → Apache NiFi UI    │
                         └──────────────────────────────┘
                                       │
   message-api (x3) ──► Kafka (3 brokers, KRaft) ──► ingest-worker ──► Postgres
        │  (binary uploads → MinIO)                                          ▲
        ▼                                                                    │
   analytics ◄──────────────────────────────── reads metrics ───────────────┘
        │   ChromaDB (facts) + Ollama (llama3.2)  ◄── what-if RAG
        ▼
   SVG charts · JSON reports · forecasts

   NiFi ──► zookeeper-nifi   (ZooKeeper kept only for NiFi state management)
```

| Service        | Tech                                   | Port (host) | Purpose                                  |
|----------------|----------------------------------------|-------------|------------------------------------------|
| lb             | nginx 1.27                             | 8080        | Single entry point / load balancer       |
| prometheus     | prom/prometheus v2.54.1                | 9090        | Scrapes service metrics                  |
| grafana        | grafana/grafana 11.2.0                 | 3000        | Monitoring dashboards                    |
| dashboard      | FastAPI + static HTML/Tailwind         | (via LB)    | IBM-styled UI, light/dark, JSON/SVG export |
| message-api    | FastAPI + kafka-python-ng (3 replicas) | (via LB)    | Accept text/json/binary messages         |
| ingest-worker  | kafka-python-ng consumer + psycopg2    | —           | Persist Kafka events to Postgres         |
| analytics      | FastAPI + pandas + scikit-learn        | (via LB)    | KPIs, profit, forecast, charts, what-if  |
| nifi           | apache/nifi 2.6.0                      | (via LB)    | Visual dataflow; uses the ZK ensemble    |
| seed           | python:3.12-slim (one-shot)            | —           | Auto-loads demo data + scenarios on boot |
| kafka1/2/3     | confluent cp-kafka 7.6.1, KRaft (RF=3) | 9092-9094   | Event backbone (broker+controller)       |
| zookeeper-nifi | confluent cp-zookeeper 7.6.1           | —           | State coordination for NiFi only         |
| postgres       | postgres:16                            | 5432        | Operational data store                   |
| minio          | MinIO                                  | 9000/9001   | Binary upload object store               |
| chromadb       | chromadb 0.5.5                         | 8000        | Vector store for what-if facts           |
| ollama         | ollama (llama3.2)                      | 11434       | Local LLM for what-if answers            |

> **Kafka client note:** the Python services use `kafka-python-ng` (the
> maintained fork), not the original `kafka-python`. The original 2.0.2
> release imports `kafka.vendor.six.moves`, which was removed in Python
> 3.12, so it crashes on the 3.12 base image. `kafka-python-ng` is a drop-in
> replacement (same `from kafka import ...` API) that works on 3.12+.

> **Kafka runs in KRaft mode** (no ZooKeeper). The three brokers each run as a
> combined `broker,controller`, forming a 3-voter controller quorum that
> tolerates one node failure. They share a fixed `CLUSTER_ID` (override by
> exporting `CLUSTER_ID` to a 22-char base64 UUID from `kafka-storage
> random-uuid`). Combined mode is ideal for a local/demo stack; for production
> Confluent recommends dedicated controller nodes.
>
> **ZooKeeper is kept only for NiFi.** A single `zookeeper-nifi` node provides
> NiFi's state-management coordination (embedded ZooKeeper disabled). A single
> node always has quorum, so it sidesteps multi-node ensemble setup. Images are
> pinned to Confluent 7.6.1, the last line with first-class ZooKeeper support.

## Quick start

```bash
# 1. Build and launch the whole stack
docker compose up -d --build

# 2. Wait for Kafka + the one-shot ollama-pull to finish (the llama3.2
#    pull is a few GB and can take several minutes on first run).
docker compose logs -f ollama-pull   # ctrl-C once it reports success

# 3. Open the dashboard — it already has data
open http://localhost:8080
```

**Seeding is automatic.** A one-shot `seed` service loads ~90 days of demo data
(plus the scenarios below) as soon as Postgres is healthy, and `analytics` waits
for it to finish — so the dashboard has data on first load with no manual step.
The seed is idempotent: it skips if the database already has sales rows, so
restarts are a no-op.

To wipe and reseed (e.g. to regenerate the scenarios):

```bash
docker compose run --rm -e SEED_FORCE=1 seed
```

You can also run it from the host against the published Postgres port if you
prefer:

```bash
pip install psycopg2-binary
DATABASE_URL=postgresql://grocery:grocery_pw@localhost:5432/grocery \
  SEED_FORCE=1 python scripts/seed_data.py
```

### Seeded scenarios

The demo data is shaped so each stakeholder view tells a clear story. These are
configured in the `SCENARIOS` block at the top of `scripts/seed_data.py`:

1. **Margin squeeze (Meat)** — vendor unit cost ramps up ~18% across the window, so Meat shows the lowest, eroding margin even though revenue holds. That vendor is also less reliable (late/short deliveries on the scorecard).
2. **Shrink problem (Produce)** — heavy expiry/spoilage loss makes Produce dominate the loss breakdown and pushes store-wide shrink above the dashboard's warning threshold.
3. **Winning promo (Snack Attack)** — a 20%-off Snacks promo with strong lift shows clearly positive incremental margin / ROI.
4. **Losing promo (Frozen Fest)** — a deep 30%-off Frozen promo with weak lift shows negative incremental margin (a discount that didn't pay for itself).
5. **Expiry crisis (Dairy + Bakery)** — a cluster of stock expiring within a few days lights up "expiring soon."

Customer feedback corroborates the Produce story (more low-rated "freshness"
complaints), so the manager view lines up with the loss data.

Everything is reached through the single load-balancer port **8080** — the
dashboard, API, and analytics services are on the internal Docker network only
(no host ports of their own), so the browser always goes through the LB:

- Dashboard: `http://localhost:8080/`
- Grafana monitoring: `http://localhost:3000` (login `admin` / `grocery`) — the **Grocery Platform — Service Overview** dashboard is auto-provisioned.
- Prometheus: `http://localhost:9090` (scrapes the services' `/metrics`).
- Apache NiFi UI: `https://localhost:8443/nifi` — **HTTPS** with single-user login `admin` / `groceryAdmin2024`. NiFi auto-generates a self-signed certificate, so your browser will show a security warning on first visit — that's expected; proceed past it.
- Message API: `http://localhost:8080/api/...`
- Analytics API: `http://localhost:8080/analytics/...`

> If you ever see "No data yet" across the dashboard, the database hasn't been
> seeded — check `docker compose logs seed`, or run the force-reseed command
> above. Charts render a clean "No data yet" placeholder rather than erroring
> when a table is empty.

> The what-if assistant builds its ChromaDB index from your metrics on
> first use; the dashboard warms it automatically in the background. If
> Ollama is still pulling the model, the assistant gracefully returns the
> retrieved facts until the model is ready.

### Troubleshooting the what-if assistant

A `Scenario failed: analytics returned 504` means the request **timed out**,
almost always because the Ollama model is still loading. The model is loaded on
CPU and the very first inference can take a while; the `ollama-pull` service
pulls **and** warms the model on startup, but if you ask before that finishes
you may see a slow response or a one-off timeout. It usually succeeds on retry
once the model is resident (it's kept in memory for 30 minutes).

How to check each piece of the what-if path:

```bash
# 1. Is the model pulled and warmed? (this one-shot exits 'done' when ready)
docker compose logs ollama-pull          # look for: warming up model... / done
docker compose logs -f ollama            # watch model load / inference activity

# 2. Is Ollama itself responding, and is the model present?
curl http://localhost:11434/api/tags                      # lists installed models
docker compose exec ollama ollama list                    # same, from inside

# 3. Ask Ollama directly (bypasses the dashboard + analytics)
curl http://localhost:11434/api/generate \
  -d '{"model":"llama3.2","prompt":"say ok","stream":false}'

# 4. Hit the analytics what-if endpoint directly (bypasses the dashboard)
curl -X POST http://localhost:8080/analytics/whatif \
  -H 'content-type: application/json' \
  -d '{"question":"What if we cut Produce shrink in half?"}'

# 5. Check the services are healthy
docker compose ps                         # all should be Up / healthy
docker compose logs analytics             # look for tracebacks
```

If step 3 is slow but works, the model just needed to load — retry the
dashboard. If step 4 returns JSON with a `facts_used` list but the `answer`
says "model is still warming up," Ollama isn't ready yet (analytics returns its
grounded fallback rather than erroring). If step 4 itself fails, check
`docker compose logs analytics`.

The request path has a nested timeout ladder so a slow model degrades to a
grounded fallback instead of a proxy error: Ollama call **90s** < dashboard
proxy **150s** < NGINX **180s**. To pre-warm manually:

```bash
docker compose exec ollama ollama run llama3.2 --keepalive 30m "ok"
```

## Sending messages

```bash
# Text
curl -X POST http://localhost:8080/api/messages \
  -H 'Content-Type: application/json' \
  -d '{"dataset":"text","type":"text","text":"morning shift note"}'

# JSON (e.g. a sale)
curl -X POST http://localhost:8080/api/messages \
  -H 'Content-Type: application/json' \
  -d '{"dataset":"sales","type":"json","data":{"sku":"A100","units":3}}'

# Binary file upload (stored in MinIO, metadata to Kafka)
curl -X POST http://localhost:8080/api/upload \
  -F dataset=binary -F description="planogram" -F file=@plan.pdf
```

Each response includes `served_by` (the replica hostname) so you can watch
the load balancer round-robin across the three `message-api` instances.

## Dashboard

- **Role tabs:** Overview, Manager, Admin, Growth, Investor, Planning.
- **Light/Dark mode** toggle (IBM Carbon palette: white bg, `#161616` ink, `#0f62fe` accent). Charts re-render on toggle so they inherit the theme.
- **Export JSON** per panel, or the whole dashboard (all five reports) at once.
- **Export SVG** for every chart (vector, theme-aware).
- **Reports:** Daily Operations, Profit & Margin, Promotion & Marketing ROI, Forecast & Plan, Investor Summary.
- **What-if** (Planning tab): a textarea question box answered by Ollama, grounded in ChromaDB facts and a 30-day baseline projection, with assumptions shown.

## API surface (analytics, proxied at `/analytics/`)

`/metrics/{kpi,profit/category,profit/shelf,loss,expiring,lowstock,vendors,promotions,ads,feedback,revenue/daily}` ·
`/forecast/demand` · `/forecast/profit?revenue_multiplier=&cost_multiplier=` ·
`/reports` and `/reports/{name}` · `/charts/{name}.svg` · `POST /whatif` · `POST /whatif/reindex`.

## Monitoring

The stack ships with Prometheus + Grafana. The three FastAPI services
(`message-api`, `analytics`, `dashboard`) expose Prometheus metrics at
`/metrics` via `prometheus-fastapi-instrumentator` — request counts, latency
histograms, and status codes. Prometheus (`:9090`) scrapes them every 15s, and
Grafana (`:3000`, `admin`/`grocery`) auto-loads a **Service Overview** dashboard
with request rate, p95 latency, error rate, and per-endpoint breakdowns.

Open Grafana from the dashboard's top bar (**Monitoring** button) or directly at
`http://localhost:3000`. To add your own panels, drop a dashboard JSON into
`monitoring/grafana/dashboards/` — it's picked up automatically.

## Notes

- Analytics logic was validated end-to-end against a real PostgreSQL 16 with seeded data: KPI summary, every metric query, demand/profit forecasts (multipliers move projections in the right direction), all five reports, and SVG chart generation.
- Charts are hand-rendered SVG (no chart library) so they export cleanly and inherit the current theme color via `currentColor`.
- The forecast models are intentionally transparent (linear regression with visible slope/assumptions) so an investor can see how projections are derived.
