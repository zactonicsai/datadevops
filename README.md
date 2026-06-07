# Grocery Operations Intelligence Platform

A dockerized, event-driven analytics platform for grocery-store operations. A Kafka cluster ingests operational messages (sales, inventory, deliveries, feedback, promotions, binary uploads), Python services compute profit/loss/forecast analytics, and an IBM Carbon–styled dashboard lets an **admin**, **manager**, and **investor** plan operations and project profit. An Ollama + ChromaDB assistant answers free-text **what-if** questions grounded in your live store metrics.

## Architecture

A standalone diagram is included at [`docs/architecture.svg`](docs/architecture.svg).

```
                         ┌──────────────────────────────┐
  Browser ─► :8080 LB ─► │  /        → dashboard         │
        (NGINX)          │  /api/    → message-api  (x3) │
                         │  /analytics/ → analytics     │
                         │  /nifi/   → Apache NiFi UI    │
                         └──────────────────────────────┘
                                       │
   message-api (x3) ──► Kafka (3 brokers / 2 zookeepers) ──► ingest-worker ──► Postgres
        │  (binary uploads → MinIO)         ▲                                       ▲
        ▼                                   │ (shared ensemble)                     │
   analytics ◄────────────────── reads ─────┴─ NiFi (state mgmt) ───────────────────┘
        │   ChromaDB (facts) + Ollama (llama3.2)  ◄── what-if RAG
        ▼
   SVG charts · JSON reports · forecasts
```

| Service        | Tech                                   | Port (host) | Purpose                                  |
|----------------|----------------------------------------|-------------|------------------------------------------|
| lb             | nginx 1.27                             | 8080        | Single entry point / load balancer       |
| dashboard      | FastAPI + static HTML/Tailwind         | (via LB)    | IBM-styled UI, light/dark, JSON/SVG export |
| message-api    | FastAPI + kafka-python-ng (3 replicas) | (via LB)    | Accept text/json/binary messages         |
| ingest-worker  | kafka-python-ng consumer + psycopg2    | —           | Persist Kafka events to Postgres         |
| analytics      | FastAPI + pandas + scikit-learn        | (via LB)    | KPIs, profit, forecast, charts, what-if  |
| nifi           | apache/nifi 2.6.0                      | (via LB)    | Visual dataflow; uses the ZK ensemble    |
| kafka1/2/3     | confluent cp-kafka 7.6.1 (RF=3, ISR=2) | 9092-9094   | Event backbone                           |
| zookeeper1/2   | confluent cp-zookeeper 7.6.1           | —           | Coordination for Kafka **and** NiFi      |
| postgres       | postgres:16                            | 5432        | Operational data store                   |
| minio          | MinIO                                  | 9000/9001   | Binary upload object store               |
| chromadb       | chromadb 0.5.5                         | 8000        | Vector store for what-if facts           |
| ollama         | ollama (llama3.2)                      | 11434       | Local LLM for what-if answers            |

> **Kafka client note:** the Python services use `kafka-python-ng` (the
> maintained fork), not the original `kafka-python`. The original 2.0.2
> release imports `kafka.vendor.six.moves`, which was removed in Python
> 3.12, so it crashes on the 3.12 base image. `kafka-python-ng` is a drop-in
> replacement (same `from kafka import ...` API) that works on 3.12+.

> **ZooKeeper note:** Confluent images are pinned to 7.6.1, the last line
> with first-class ZooKeeper support (ZooKeeper is removed in Confluent
> Platform 8.0 / Apache Kafka 4.0). Both Kafka and NiFi share the same
> two-node ensemble. NiFi runs unsecured over HTTP for local use and uses
> the ensemble for its state management (embedded ZooKeeper disabled).

## Quick start

```bash
# 1. Build and launch the whole stack
docker compose up -d --build

# 2. Wait for Kafka + the one-shot ollama-pull to finish (the llama3.2
#    pull is a few GB and can take several minutes on first run).
docker compose logs -f ollama-pull   # ctrl-C once it reports success

# 3. Seed demonstration data (90 days of grocery operations)
pip install psycopg2-binary
DATABASE_URL=postgresql://grocery:grocery_pw@localhost:5432/grocery \
  python scripts/seed_data.py

# 4. Open the dashboard
open http://localhost:8080
```

Everything is reached through the single load-balancer port **8080** — the
dashboard, API, and analytics services are on the internal Docker network only
(no host ports of their own), so the browser always goes through the LB:

- Dashboard: `http://localhost:8080/`
- Apache NiFi UI: `http://localhost:8080/nifi/` (unsecured/HTTP for local use)
- Message API: `http://localhost:8080/api/...`
- Analytics API: `http://localhost:8080/analytics/...`

> The what-if assistant builds its ChromaDB index from your metrics on
> first use; the dashboard warms it automatically in the background. If
> Ollama is still pulling the model, the assistant gracefully returns the
> retrieved facts until the model is ready.

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

## Notes

- Analytics logic was validated end-to-end against a real PostgreSQL 16 with seeded data: KPI summary, every metric query, demand/profit forecasts (multipliers move projections in the right direction), all five reports, and SVG chart generation.
- Charts are hand-rendered SVG (no chart library) so they export cleanly and inherit the current theme color via `currentColor`.
- The forecast models are intentionally transparent (linear regression with visible slope/assumptions) so an investor can see how projections are derived.
"# datadevops" 
