# Grocery Operations Intelligence Platform — Plan & Architecture

## 1. Who uses this, and what each role needs

Before any code, here is what the three stakeholder groups actually need from the
system. Every dashboard panel, report, and metric below maps back to one of these.

### 1.1 Store Admin (day-to-day operator)
The admin keeps the doors open and the shelves full. Their questions are operational
and short-horizon:
- **What is expiring soon?** A ranked list of inventory by days-to-expiry, with the
  retail value at risk, so they can mark down or pull product before it becomes loss.
- **What is low or out of stock?** Reorder triggers against par levels, with vendor
  lead times so reorders go out before a gap appears on the shelf.
- **Which vendor deliveries are late or short?** Delivery accuracy by vendor (ordered
  vs received vs on-time) feeds both reorder timing and vendor scorecards.
- **Where is shrink coming from?** Loss broken out by cause (expiry, damage, theft,
  markdown) and by category, so corrective action is targeted.
- **Is today tracking to plan?** Sales vs forecast for the current day/week.

### 1.2 Store Manager (performance & planning)
The manager owns profit and growth for the location. Medium-horizon questions:
- **Profit by category, by shelf, and by product.** Gross margin after cost of goods,
  plus an allocation of shelf space so "profit per linear foot" is visible. This is the
  single most important merchandising lever in grocery.
- **Which promotions actually paid off?** Lift vs baseline for each discount/ad program,
  net of the discount cost — separating real incremental sales from giveaway.
- **Marketing & ad-program ROI.** Spend vs attributable margin per campaign.
- **Demand forecast.** Next 7–28 days of unit demand per category so labor, ordering,
  and shelf allocation can be planned, not reacted to.
- **Customer feedback signal.** Sentiment trend and the specific themes driving it
  (price, freshness, service, availability), tied back to categories where possible.
- **What-if planning.** "If I cut dairy prices 5% and double the endcap, what happens to
  margin?" — handled by the AI scenario assistant (Ollama + retrieval over the store's
  own data in ChromaDB).

### 1.3 Investor / Owner (financial health & trajectory)
The investor cares about returns and risk, long-horizon:
- **Profit trend and margin %** over time, with the loss line subtracted so the number
  is true net contribution.
- **Revenue growth rate** and same-store trajectory.
- **Shrink as a % of revenue** — a key efficiency and theft/spoilage indicator.
- **Category mix** and which categories are growing vs declining.
- **Forward projection** — a simple, transparent profit/loss projection with the
  assumptions exposed (not a black box), so the number can be trusted and stress-tested.
- **One exportable report** — JSON for systems, SVG charts/images for decks.

## 2. Reports the platform produces
1. **Daily Operations Report** — expiring soon, low stock, late deliveries, today's sales vs forecast.
2. **Profit & Margin Report** — margin by category / shelf / product, profit per linear foot, loss breakdown.
3. **Promotion & Marketing ROI Report** — lift, incremental margin, and spend payback per program.
4. **Forecast & Plan Report** — 7/28-day demand forecast per category with reorder and shelf recommendations.
5. **Investor Summary** — revenue, net profit, margin %, shrink %, growth, and forward projection.

All five export as **JSON** (full data) and their charts export as **SVG** (vector, deck-ready).

## 3. Architecture

```
                       ┌─────────────────────────────────────────────┐
   browser ───────────►│  NGINX load balancer  (:8080)                │
                       │   /            -> dashboard                   │
                       │   /api/        -> message-api (round-robin)   │
                       │   /analytics/  -> analytics service           │
                       └───────┬───────────────┬──────────────┬────────┘
                               │               │              │
                  ┌────────────▼───┐   ┌────────▼────────┐  ┌──▼───────────┐
                  │  message-api   │   │  dashboard      │  │  analytics    │
                  │  x? (FastAPI)  │   │  (FastAPI+HTML) │  │  (FastAPI/py) │
                  │  text/json/bin │   │  Tailwind, SVG  │  │  pandas/skl   │
                  └───────┬────────┘   └─────────────────┘  └──┬───────────┘
                          │ produce                            │ query
              ┌───────────▼────────────┐                       │
              │   KAFKA cluster x3      │◄──────────────────────┘ consume
              │  kafka1 kafka2 kafka3   │
              └───────────┬────────────┘
                          │ coordinated by
              ┌───────────▼────────────┐
              │  ZOOKEEPER x2 (zk1 zk2) │
              └─────────────────────────┘

   ingest-worker  ── consumes Kafka topics, writes to ──►  PostgreSQL
   analytics      ── reads PostgreSQL, serves metrics/forecasts/reports
   ollama + chromadb ── power the "what-if" scenario assistant (RAG)
```

### Services (all in one `docker-compose.yml`)
| Service | Image / build | Purpose |
|---|---|---|
| `zookeeper1`, `zookeeper2` | confluentinc/cp-zookeeper | Kafka coordination (2 nodes, ensemble) |
| `kafka1`, `kafka2`, `kafka3` | confluentinc/cp-kafka | 3-broker Kafka cluster, replication factor 3 |
| `lb` | nginx | Load balancer / reverse proxy, single entry point :8080 |
| `message-api` (scaled to 3) | build ./services/message-api | Accepts text / JSON / binary uploads, produces to Kafka |
| `ingest-worker` | build ./services/ingest-worker | Consumes topics, persists to Postgres + MinIO |
| `analytics` | build ./services/analytics | pandas/scikit-learn metrics, forecasts, projections, reports |
| `dashboard` | build ./services/dashboard | Static-HTML + Tailwind UI, SVG charts, JSON/SVG export |
| `postgres` | postgres:16 | System of record for all grocery facts |
| `minio` | minio/minio | Object store for uploaded binary files |
| `chromadb` | chromadb/chroma | Vector store for what-if retrieval context |
| `ollama` | ollama/ollama | Local LLM (model: `llama3.2`) for scenario reasoning |

### Why these tools (all common open-source)
- **Kafka + Zookeeper** — the requested durable, replayable message backbone.
- **FastAPI** — fast, typed Python web framework; same stack for every service keeps it simple.
- **PostgreSQL** — reliable relational store for sales/inventory/vendor facts.
- **pandas + scikit-learn** — the standard Python analytics pair; transparent forecasting
  (linear/seasonal-naive) so investors can see the assumptions.
- **MinIO** — S3-compatible object storage for the binary-upload requirement.
- **ChromaDB + Ollama (llama3.2)** — fully local retrieval-augmented "what-if" assistant;
  no data leaves the cluster.
- **NGINX** — battle-tested load balancer.
- **Tailwind (CDN) + vanilla JS** — static HTML, IBM-style (white bg / dark text), light+dark mode, SVG charts.

## 4. Message API — supported message types
`POST /api/messages` (JSON body) for **text** and **json** payloads, and
`POST /api/upload` (multipart) for **binary files**. Every message is tagged with a
`dataset` (sales, inventory, vendor_delivery, customer_feedback, shelf_space, ad_program,
marketing, discount_program, expiry) and routed to the matching Kafka topic. The worker
validates and lands it in Postgres (or MinIO for binaries).

## 5. Data model (grocery store example)
Core tables: `products`, `shelves`, `vendors`, `sales`, `inventory`, `vendor_deliveries`,
`customer_feedback`, `ad_programs`, `discount_programs`, `loss_events`. A seed script
generates ~90 days of realistic grocery data across produce, dairy, bakery, meat, frozen,
beverages, snacks, and household so the dashboard and forecasts have something real to chew on.

## 6. Frontend spec
- Static HTML served by FastAPI, **Tailwind via CDN**, **IBM-style palette**: white
  background, near-black text (`#161616`), IBM blue accent (`#0f62fe`).
- **Light & dark mode** toggle (persisted in localStorage).
- All charts are **hand-rendered SVG** (no chart lib) so they export cleanly as vector.
- **Export**: every panel exports its underlying data as **JSON**; every chart exports as **SVG**;
  the whole dashboard state exports as a single JSON document.
- **What-if box**: a `<textarea>` in its own dashboard section posts to the analytics
  service, which retrieves relevant store context from ChromaDB and asks Ollama to reason.
