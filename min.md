# Grafana + Loki + Prometheus: The Complete Beginner-to-Practical Guide

**Last updated: August 20, 2026**
Written for absolute beginners. If you can copy a file and type a command in a terminal, you can do everything in this guide.

---

## Table of contents

1. [How to use this guide](#1-how-to-use-this-guide)
2. [Background: what problem are we solving?](#2-background-what-problem-are-we-solving)
3. [The three tools in plain English](#3-the-three-tools-in-plain-english)
4. [Version table (what is current in August 2026)](#4-version-table-what-is-current-in-august-2026)
5. [START HERE: build the whole stack on your laptop with Docker](#5-start-here-build-the-whole-stack-on-your-laptop-with-docker)
6. [Prometheus in depth](#6-prometheus-in-depth)
7. [Loki in depth](#7-loki-in-depth)
8. [Grafana in depth](#8-grafana-in-depth)
9. [Grafana Alloy: the agent that ships your data](#9-grafana-alloy-the-agent-that-ships-your-data)
10. [Docker: production-shaped configuration](#10-docker-production-shaped-configuration)
11. [AWS EC2 + Launch Templates](#11-aws-ec2--launch-templates)
12. [Amazon EKS (Kubernetes)](#12-amazon-eks-kubernetes)
13. [Dashboards and alerts](#13-dashboards-and-alerts)
14. [PromQL and LogQL cheat sheets](#14-promql-and-logql-cheat-sheets)
15. [Best practices](#15-best-practices)
16. [Pros, cons, and alternatives](#16-pros-cons-and-alternatives)
17. [Troubleshooting](#17-troubleshooting)
18. [Glossary](#18-glossary)
19. [Official documentation and references](#19-official-documentation-and-references)

---

## 1. How to use this guide

This guide is built in the order that actually helps a beginner:

1. **First**, a little background so the words make sense.
2. **Then**, one complete working example you can run in about 15 minutes on your own computer (Docker).
3. **Then**, the deep explanation of each tool, now that you have seen it work.
4. **Then**, the two "real world" deployments people ask about most: **AWS EC2 with Launch Templates**, and **Amazon EKS (Kubernetes)**.
5. **Finally**, best practices, comparisons, and troubleshooting.

**What you need**

| Section | What you need |
|---|---|
| Docker example | A laptop with Docker Desktop or Docker Engine + Docker Compose v2 |
| AWS EC2 example | An AWS account, permission to create EC2 instances, IAM roles, and security groups |
| EKS example | An AWS account, `kubectl`, `helm` v3, and `eksctl` (or Terraform) |

> **Tip:** Do the Docker example first even if your goal is AWS. Everything in AWS is the same idea, just with more moving parts.

---

## 2. Background: what problem are we solving?

### 2.1 The story

Imagine you run a small pizza website. One Saturday night customers start complaining: "the site is slow." You log in to the server and stare at it. Is the CPU busy? Is the database slow? Did a bug start throwing errors? Was it slow 10 minutes ago too, or only right now?

Without instrumentation, you are guessing. **Observability** is the practice of making a system explain itself, so that you can answer questions like the ones above *without* guessing and *without* being logged into the server when it breaks.

### 2.2 The three kinds of data

Almost all observability data falls into three buckets, often called the "three pillars":

| Pillar | What it is | Everyday analogy | Tool in this guide |
|---|---|---|---|
| **Metrics** | Numbers measured repeatedly over time (CPU 42%, 130 requests/sec, 3 errors/sec) | The dashboard in your car: speed, fuel, temperature | **Prometheus** |
| **Logs** | Lines of text that describe individual events ("user 42 failed to log in at 21:03") | A diary, or a store's receipt tape | **Loki** |
| **Traces** | The step-by-step path one request took through many services | A package tracking page: warehouse → truck → doorstep | Tempo / Jaeger (not covered in depth here) |

And you need something to **look** at all of it: that is **Grafana**.

### 2.3 Metrics vs. logs — why not just one?

This confuses beginners more than anything else, so here is the core idea:

- **Metrics are small and cheap.** A CPU number stored every 15 seconds for a year is a few megabytes. You can keep metrics for everything, forever, and graph them instantly. But a metric cannot tell you *which* customer got the error or *why*.
- **Logs are big and detailed.** A log line tells you exactly what happened, with the user ID and the stack trace. But storing every log line from every server is expensive, and searching all of them is slow.

The professional workflow is: **metrics tell you *that* something is wrong and *when*; logs tell you *why*.** You see a spike on a Grafana graph at 21:03, then you click through to the logs from 21:03 and read the error.

### 2.4 Pull vs. push (a word you will see everywhere)

- **Pull:** the monitoring server reaches out on a schedule and asks each machine, "what are your numbers right now?" Prometheus works this way by default.
- **Push:** each machine sends its data to the server whenever it wants. Loki works this way for logs, and Prometheus can also *receive* pushed metrics ("remote write") when pulling is impossible.

Pull is great inside a network you control: the monitoring server has one list of who to ask, and if a machine stops answering, you instantly know it is down. Push is better when machines are short-lived, behind firewalls, or in someone else's network.

---

## 3. The three tools in plain English

### 3.1 Prometheus — the number collector

Prometheus is a **time-series database** plus a **scraper**. Every 15 seconds (you choose), it visits a URL on each of your machines and apps — usually `http://the-machine:9100/metrics` — and copies down the numbers it finds. It stores them with a timestamp, forever-ish, and lets you ask questions with a query language called **PromQL**.

A metrics page looks like this (this is literally just text over HTTP):

```text
# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 102934.52
node_cpu_seconds_total{cpu="0",mode="user"} 4021.17
http_requests_total{method="GET",status="200"} 91823
```

Each line is: **metric name** + **labels in curly braces** + **a number**. Labels are what make it powerful — you can later ask "show me only status=500 requests, grouped by method."

### 3.2 Loki — the log collector

Loki is often described as "Prometheus, but for logs," and that is accurate in one very specific way: **Loki indexes labels, not words.**

Traditional log systems (Elasticsearch/OpenSearch) build a giant index of every word in every log line so you can search anything instantly. That is powerful but expensive — the index can be as big as the logs themselves.

Loki instead stores each log line in a compressed **chunk** in cheap object storage (Amazon S3), and only indexes a small set of **labels** like `{app="checkout", env="prod", level="error"}`. When you search, Loki uses the labels to pick a small pile of chunks, then brute-force greps inside them. The result: far cheaper storage, and queries that are fast *if you use labels well* (see [cardinality](#152-the-single-most-important-rule-cardinality)).

### 3.3 Grafana — the screen

Grafana is the web UI. It connects to data sources (Prometheus, Loki, CloudWatch, MySQL, and 150+ others), draws dashboards, and sends alerts. It does not store your metrics or logs itself — it asks the other systems and draws the answer.

### 3.4 How they fit together

```text
   ┌────────────────────────────────────────────────────────────────┐
   │  YOUR MACHINES / CONTAINERS / PODS                             │
   │                                                                │
   │   app  ──exposes──►  /metrics  ◄────scrape (pull)──────┐       │
   │   app  ──writes──►   stdout / log files ──┐            │       │
   └───────────────────────────────────────────┼────────────┼───────┘
                                               │            │
                                    ┌──────────▼──────┐     │
                                    │  Grafana Alloy  │     │
                                    │  (the agent)    │     │
                                    └──────────┬──────┘     │
                                        push logs           │
                                               │            │
                              ┌────────────────▼──┐   ┌─────▼────────┐
                              │       LOKI        │   │  PROMETHEUS  │
                              │  logs + labels    │   │  metrics DB  │
                              │  chunks on S3     │   │  local TSDB  │
                              └────────────────┬──┘   └─────┬────────┘
                                               │            │
                                        ┌──────▼────────────▼──────┐
                                        │        GRAFANA           │
                                        │  dashboards + alerts     │
                                        └──────────────────────────┘
```

**One sentence:** Alloy collects, Prometheus stores numbers, Loki stores text, Grafana shows both.

---

## 4. Version table (what is current in August 2026)

Pin versions in real deployments. `latest` will eventually break you at 3 a.m.

| Component | Version to use | Notes |
|---|---|---|
| Prometheus | **3.13.x (LTS)** | 3.13 is the current Long-Term-Support line, supported to ~July 2027. LTS gets bug and security fixes for a year. |
| Grafana | **13.x** | Grafana 13 shipped April 2026. Grafana 11 and older are past end of life. |
| Loki | **3.7.x** | 3.7.6 is current; Loki 3.5 went EOL in March 2026. |
| Log agent | **Grafana Alloy** | **Promtail reached end of life on March 2, 2026.** Do not start new projects with Promtail. |
| Node metrics | node_exporter 1.9.x+ | Or use Alloy's built-in `prometheus.exporter.unix`. |
| K8s metrics stack | kube-prometheus-stack **88.x** | Helm chart from `prometheus-community`. |
| K8s Loki chart | `grafana-community/loki` **18.x** | The OSS Loki chart moved to the `grafana-community` repo on March 16, 2026. The old `grafana/loki` chart is now for Grafana Enterprise Logs only. |

> **Two facts that trip people up in 2026:**
> 1. **Promtail is dead.** Every old blog post uses it. Use **Alloy**. If you inherit a Promtail config, convert it with one command: `alloy convert --source-format=promtail --output=config.alloy promtail.yaml`
> 2. **The Loki Helm chart moved repos** and renumbered (6.x → 7.x → 18.x). Old `helm repo add grafana ...` instructions for Loki are stale for open-source users.

---

## 5. START HERE: build the whole stack on your laptop with Docker

**Goal:** in ~15 minutes you will have Prometheus, Loki, Grafana, and Alloy running, collecting real data from your own computer, with a graph and a log search working.

### Step 0 — Check Docker works

```bash
docker --version
docker compose version
```

You should see version numbers. If not, install **Docker Desktop** (Windows/macOS) or Docker Engine + the Compose plugin (Linux) first.

### Step 1 — Make a folder

```bash
mkdir observability-lab
cd observability-lab
mkdir -p prometheus loki alloy grafana/provisioning/datasources
```

Why folders? Each tool reads a config file. We keep them tidy so we can mount them into containers.

### Step 2 — Write the Prometheus config

Create **`prometheus/prometheus.yml`**:

```yaml
# How often to collect numbers, and default rules for everyone.
global:
  scrape_interval: 15s          # ask every target every 15 seconds
  evaluation_interval: 15s      # check alert rules every 15 seconds
  external_labels:
    cluster: laptop             # stamped on data sent to other systems
    env: dev

# WHO to collect from. Each "job" is a group of similar targets.
scrape_configs:
  # 1. Prometheus watching itself. Good first sanity check.
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # 2. The machine's CPU / RAM / disk, via node_exporter.
  - job_name: node
    static_configs:
      - targets: ["node-exporter:9100"]
        labels:
          host: laptop

  # 3. Per-container CPU / memory, via cAdvisor.
  - job_name: cadvisor
    static_configs:
      - targets: ["cadvisor:8080"]

  # 4. Alloy's own health metrics.
  - job_name: alloy
    static_configs:
      - targets: ["alloy:12345"]
```

**Read it like a sentence:** "Every 15 seconds, go to `node-exporter:9100/metrics` and write down everything you see, tagging it `job=node, host=laptop`."

### Step 3 — Write the Loki config

Create **`loki/loki-config.yaml`**:

```yaml
auth_enabled: false             # single-tenant. Do NOT expose this to the internet.

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: info

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:                 # laptop mode: store chunks on disk, not S3
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

# How Loki organises its index. v13 + tsdb is the current recommended pair.
schema_config:
  configs:
    - from: 2024-04-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  retention_period: 168h        # keep logs 7 days
  allow_structured_metadata: true
  volume_enabled: true          # enables the "Logs volume" bar in Grafana
  ingestion_rate_mb: 8
  ingestion_burst_size_mb: 16

compactor:
  working_directory: /loki/compactor
  retention_enabled: true       # actually delete old logs
  delete_request_store: filesystem

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

analytics:
  reporting_enabled: false
```

### Step 4 — Write the Alloy config

Alloy's config language is not YAML. It is a set of **components** wired together with `forward_to`, a bit like plugging audio cables between boxes. Read it bottom-up: each block sends its output to the next.

Create **`alloy/config.alloy`**:

```alloy
// Alloy's own logging
logging {
  level  = "info"
  format = "logfmt"
}

// 1. FIND: ask Docker for the list of running containers
discovery.docker "containers" {
  host             = "unix:///var/run/docker.sock"
  refresh_interval = "5s"
}

// 2. LABEL: turn Docker metadata into clean Loki labels
discovery.relabel "containers" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"          // strip the leading slash Docker adds
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_docker_container_log_stream"]
    target_label  = "stream"         // stdout or stderr
  }
  rule {
    target_label = "job"
    replacement  = "docker"
  }
}

// 3. READ: tail the logs of those containers
loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.relabel.containers.output
  labels     = { host = "laptop", env = "dev" }
  forward_to = [loki.write.default.receiver]
}

// 4. SEND: push to Loki
loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

### Step 5 — Tell Grafana about its data sources automatically

Create **`grafana/provisioning/datasources/datasources.yml`**:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      timeInterval: 15s

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      maxLines: 1000
```

This is called **provisioning**: instead of clicking through the UI, Grafana reads this file at startup. Configuration you can commit to Git beats configuration you clicked.

### Step 6 — Write the Compose file

Create **`docker-compose.yml`**:

```yaml
name: observability-lab

services:
  prometheus:
    image: prom/prometheus:v3.13.2
    container_name: prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.enable-lifecycle          # allows config reload without restart
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"           # bound to localhost only = safer

  loki:
    image: grafana/loki:3.7.6
    container_name: loki
    restart: unless-stopped
    command: -config.file=/etc/loki/loki-config.yaml
    volumes:
      - ./loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro
      - loki-data:/loki
    ports:
      - "127.0.0.1:3100:3100"

  alloy:
    image: grafana/alloy:latest         # pin a real version in production
    container_name: alloy
    restart: unless-stopped
    command:
      - run
      - --server.http.listen-addr=0.0.0.0:12345
      - --storage.path=/var/lib/alloy/data
      - /etc/alloy/config.alloy
    volumes:
      - ./alloy/config.alloy:/etc/alloy/config.alloy:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - alloy-data:/var/lib/alloy/data
    ports:
      - "127.0.0.1:12345:12345"         # Alloy's own web UI
    depends_on: [loki]

  node-exporter:
    image: quay.io/prometheus/node-exporter:v1.9.1
    container_name: node-exporter
    restart: unless-stopped
    command:
      - --path.rootfs=/host
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    pid: host
    volumes:
      - /:/host:ro,rslave

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.52.1
    container_name: cadvisor
    restart: unless-stopped
    privileged: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro

  grafana:
    image: grafana/grafana:13.0.0
    container_name: grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: changeme
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_FEATURE_TOGGLES_ENABLE: traceToMetrics
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on: [prometheus, loki]

volumes:
  prometheus-data:
  loki-data:
  grafana-data:
  alloy-data:
```

**Two details worth understanding:**

- **Named volumes** (`prometheus-data:`) keep your data when containers restart. Without them, a `docker compose down` throws away your history.
- **`127.0.0.1:9090:9090`** publishes the port only to your own machine. Plain `9090:9090` would expose Prometheus to your whole network — and Prometheus has **no login screen**.

### Step 7 — Start it

```bash
docker compose up -d
docker compose ps
```

All services should show `running`. If one is restarting, read its logs:

```bash
docker compose logs --tail=50 loki
```

### Step 8 — Verify each piece, one at a time

Check things bottom-up. This habit will save you hours later.

```bash
# Prometheus is alive and healthy?
curl -s http://localhost:9090/-/healthy

# Prometheus is actually scraping? (all should say "up")
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"[a-z]*"'

# Loki is ready?
curl -s http://localhost:3100/ready

# Loki has received labels from Alloy?
curl -s http://localhost:3100/loki/api/v1/labels
```

Also open the built-in web UIs:

- Prometheus targets page: <http://localhost:9090/targets> — everything should be green/UP
- Alloy UI: <http://localhost:12345> — shows each component and whether it is healthy
- Grafana: <http://localhost:3000> — log in with `admin` / `changeme`

### Step 9 — Your first metric graph

1. In Grafana, click **Explore** (compass icon) in the left menu.
2. Choose the **Prometheus** data source at the top.
3. Switch to **Code** mode and paste:

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

4. Click **Run query**. That is your CPU usage percentage.

**What that query says, word by word:**
- `node_cpu_seconds_total{mode="idle"}` — the counter of seconds the CPU spent doing nothing.
- `rate(...[5m])` — how fast that counter grew, per second, averaged over the last 5 minutes. (Counters only go up, so you almost always wrap them in `rate`.)
- `avg by (instance)` — average across all CPU cores, keeping one result per machine.
- `100 - (... * 100)` — idle fraction turned into "busy percent."

### Step 10 — Your first log search

1. Still in **Explore**, switch the data source to **Loki**.
2. Use the **Label browser** or paste this into Code mode:

```logql
{job="docker"}
```

3. Run it. You should see live logs from your own containers.
4. Now filter to errors only:

```logql
{job="docker", container="grafana"} |= "error"
```

`|=` means "line contains." That is the whole trick: pick a small set of streams with labels in `{}`, then filter the text with `|=`, `!=`, `|~` (regex).

### Step 11 — Import a real dashboard

You do not have to build dashboards by hand.

1. Grafana → **Dashboards** → **New** → **Import**.
2. Enter dashboard ID **1860** (the classic "Node Exporter Full") and click **Load**.
3. Select your **Prometheus** data source, click **Import**.

You now have ~80 panels of machine health. Browse [grafana.com/grafana/dashboards](https://grafana.com/grafana/dashboards/) for thousands more.

### Step 12 — Clean up (when you are done)

```bash
docker compose down          # stop containers, keep data
docker compose down -v       # stop AND delete the volumes (fresh start)
```

**Congratulations — you have a complete observability stack.** Everything after this section is explanation and scaling up.

---

## 6. Prometheus in depth

### 6.1 What Prometheus actually is

Prometheus is a single Go binary that does four jobs:

1. **Service discovery** — figure out the list of things to scrape (a static list, or ask AWS/Kubernetes/Consul for it).
2. **Scraping** — fetch `/metrics` over HTTP on a schedule.
3. **Storage** — write samples to a local time-series database (TSDB) on disk.
4. **Rules and alerts** — evaluate PromQL expressions on a schedule; fire alerts to Alertmanager.

It is deliberately **not** clustered, **not** long-term storage, and **not** a log system. When you outgrow one server, you either shard it or send data onward to Mimir, Thanos, or Amazon Managed Service for Prometheus.

### 6.2 The four metric types

| Type | Meaning | Example | How you query it |
|---|---|---|---|
| **Counter** | Only goes up (resets to 0 on restart) | `http_requests_total` | Always `rate()` or `increase()` |
| **Gauge** | Goes up and down | `node_memory_MemAvailable_bytes` | Use directly, or `avg_over_time()` |
| **Histogram** | Counts observations into buckets | `http_request_duration_seconds_bucket` | `histogram_quantile()` |
| **Summary** | Pre-computed quantiles from the client | `rpc_duration_seconds{quantile="0.9"}` | Use directly (cannot aggregate across instances) |

> **Beginner trap:** graphing a counter directly gives a boring line that climbs forever. `rate(counter[5m])` is what you actually want — "how many per second lately."

### 6.3 How data is identified

A time series is identified by its **metric name plus every label**. These are two different series:

```text
http_requests_total{method="GET",  status="200", instance="10.0.1.5:8080"}
http_requests_total{method="POST", status="200", instance="10.0.1.5:8080"}
```

Prometheus adds two labels for you on every scrape: `job` (from the job_name) and `instance` (host:port).

### 6.4 Exporters: how to monitor things that do not speak Prometheus

An **exporter** is a small program that translates something else into `/metrics` format.

| What you want to monitor | Exporter | Default port |
|---|---|---|
| Linux/Windows machine | node_exporter / windows_exporter | 9100 / 9182 |
| Docker containers | cAdvisor | 8080 |
| PostgreSQL / MySQL | postgres_exporter / mysqld_exporter | 9187 / 9104 |
| Redis | redis_exporter | 9121 |
| Nginx | nginx-prometheus-exporter | 9113 |
| An HTTP endpoint / TLS cert / ping | blackbox_exporter | 9115 |
| AWS CloudWatch metrics | yace / cloudwatch_exporter | 5000 / 9106 |
| Anything with no exporter | Instrument your app with a client library | your app's port |

Full list: <https://prometheus.io/docs/instrumenting/exporters/>

### 6.5 Instrumenting your own app (Python example)

```python
from prometheus_client import Counter, Histogram, start_http_server
import time, random

REQUESTS = Counter("app_requests_total", "Total requests", ["endpoint", "status"])
LATENCY  = Histogram("app_request_duration_seconds", "Request duration", ["endpoint"])

def handle(endpoint):
    with LATENCY.labels(endpoint).time():
        time.sleep(random.uniform(0.01, 0.4))
    REQUESTS.labels(endpoint, "200").inc()

if __name__ == "__main__":
    start_http_server(8000)      # now http://localhost:8000/metrics exists
    while True:
        handle(random.choice(["/", "/cart", "/checkout"]))
```

Client libraries exist for Go, Java, Python, Ruby, Rust, .NET, Node.js and more: <https://prometheus.io/docs/instrumenting/clientlibs/>

**Naming rules that make future-you happy:** use `snake_case`, end counters in `_total`, include the base unit (`_seconds`, `_bytes`), and never put a unit prefix like `milliseconds` in the name — always use seconds and bytes.

### 6.6 Service discovery

Static lists are fine for 3 servers and terrible for 300 that come and go. Prometheus can ask an authority for the current list:

```yaml
scrape_configs:
  # AWS EC2 — asks the EC2 API which instances exist right now
  - job_name: ec2
    ec2_sd_configs:
      - region: us-east-1
        port: 9100

  # Kubernetes — asks the API server for pods
  - job_name: k8s-pods
    kubernetes_sd_configs:
      - role: pod

  # A file another program writes — the simplest dynamic option
  - job_name: file
    file_sd_configs:
      - files: ["/etc/prometheus/targets/*.json"]
        refresh_interval: 30s
```

Discovery gives you `__meta_*` labels (like `__meta_ec2_tag_Name`), which you reshape with **relabeling** — see the [AWS section](#11-aws-ec2--launch-templates).

### 6.7 Storage and retention

```bash
--storage.tsdb.path=/prometheus
--storage.tsdb.retention.time=15d     # by age
--storage.tsdb.retention.size=50GB    # or by size; whichever hits first
```

Rough sizing: each sample costs about **1–2 bytes** after compression. So:

```text
bytes ≈ active_series × (seconds_of_retention ÷ scrape_interval) × 2
```

Example: 200,000 series, 15s interval, 15 days ≈ 200,000 × 86,400 ≈ 17 GB. Add 30–50% headroom, and use fast disks (gp3 EBS or better).

**Prometheus TSDB is not a backup.** For long retention, use `remote_write` to Mimir, Thanos, VictoriaMetrics, or Amazon Managed Service for Prometheus.

### 6.8 Alerting rules and Alertmanager

Prometheus evaluates rules and sends firing alerts to **Alertmanager**, which does grouping, silencing, deduplication, and routing to Slack/PagerDuty/email.

`rules/node.yml`:

```yaml
groups:
  - name: node-basics
    interval: 30s
    rules:
      # A RECORDING rule pre-computes an expensive query.
      - record: instance:node_cpu_utilisation:rate5m
        expr: 1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

      # An ALERTING rule fires when a condition stays true.
      - alert: HighCpu
        expr: instance:node_cpu_utilisation:rate5m > 0.85
        for: 10m                    # must be true for 10 straight minutes
        labels:
          severity: warning
        annotations:
          summary: "CPU above 85% on {{ $labels.instance }}"
          description: "CPU has been at {{ $value | humanizePercentage }} for 10 minutes."

      - alert: DiskWillFillIn4Hours
        expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4*3600) < 0
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "Disk on {{ $labels.instance }} fills within 4 hours"

      - alert: TargetDown
        expr: up == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.job }} target {{ $labels.instance }} is down"
```

Wire it up in `prometheus.yml`:

```yaml
rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

Minimal `alertmanager.yml`:

```yaml
route:
  receiver: slack
  group_by: [alertname, cluster]
  group_wait: 30s          # wait to batch related alerts
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: [severity="critical"]
      receiver: pagerduty

receivers:
  - name: slack
    slack_configs:
      - api_url: https://hooks.slack.com/services/XXX/YYY/ZZZ
        channel: "#alerts"
        title: "{{ .CommonAnnotations.summary }}"
  - name: pagerduty
    pagerduty_configs:
      - routing_key: YOUR_INTEGRATION_KEY

inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [alertname, instance]     # don't page twice for the same thing
```

Always test rules before shipping:

```bash
promtool check config /etc/prometheus/prometheus.yml
promtool check rules /etc/prometheus/rules/*.yml
promtool test rules tests.yml        # unit tests for alerts!
```

### 6.9 Reloading without downtime

```bash
curl -X POST http://localhost:9090/-/reload      # requires --web.enable-lifecycle
```

### 6.10 Prometheus 3.x: what changed

Prometheus 3.0 (November 2024) was the first major release in seven years, and 3.13 is the current LTS. Highlights that matter to you:

- **UTF-8 metric and label names** are now allowed, so OpenTelemetry names survive intact.
- **A rewritten web UI** with a much better query explorer.
- **Native histograms** (experimental but excellent): far higher resolution latency data at lower cost than classic bucket histograms.
- **Remote Write 2.0** protocol: more efficient shipping to long-term storage.
- **OTLP ingestion**: Prometheus can receive OpenTelemetry metrics directly (`--web.enable-otlp-receiver`).
- **Range selectors now behave consistently** at boundaries — if you migrate from 2.x, re-check any query that depended on the old edge behaviour, and read the official migration guide first.

---

## 7. Loki in depth

### 7.1 The mental model

```text
log line ──► labels {app,env,level} ──► stream ──► chunk (compressed) ──► object storage (S3)
                    │
                    └──► tiny index (which stream, which time range, which chunk)
```

- A **stream** is a unique combination of labels. All lines with the same labels go into the same stream.
- A **chunk** is a compressed block of one stream's lines, flushed to storage when it is full or old.
- The **index** only records label sets and time ranges — that is why it is small.

### 7.2 Deployment modes

| Mode | What runs | Good for |
|---|---|---|
| **Monolithic** (single binary) | one process, all components | up to roughly 100 GB/day, labs, small teams |
| **Simple scalable** | read / write / backend targets | mid-size — **but this mode is being deprecated before Loki 4.0** |
| **Microservices** | distributor, ingester, querier, query-frontend, compactor, index-gateway, ruler each separately | large scale, high availability; what Grafana Labs runs internally |

Start monolithic. Move to microservices when you actually need to; Grafana now recommends jumping straight to microservices for production rather than adopting simple-scalable.

### 7.3 Storage configuration (the part that matters)

The current recommended setup is **TSDB index + schema v13 + object storage**. For AWS:

```yaml
schema_config:
  configs:
    - from: 2026-01-01          # date you START using this schema
      store: tsdb
      object_store: s3
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /loki/index
    cache_location: /loki/index_cache
  aws:
    region: us-east-1
    bucketnames: my-company-loki-chunks
    s3forcepathstyle: false
```

> **Never edit an existing schema entry.** To change schema, append a *new* entry with a future `from:` date. Loki reads old data with the old rules and new data with the new rules. Editing history corrupts queries.

### 7.4 Retention and deletion

```yaml
limits_config:
  retention_period: 720h        # 30 days globally

  # Optional: keep some streams longer / shorter
  retention_stream:
    - selector: '{namespace="prod", level="error"}'
      priority: 1
      period: 2160h             # 90 days for prod errors
    - selector: '{namespace="dev"}'
      priority: 2
      period: 72h               # 3 days for dev

compactor:
  working_directory: /loki/compactor
  retention_enabled: true       # without this, nothing is ever deleted
  delete_request_store: s3
  compaction_interval: 10m
```

Also consider an **S3 lifecycle policy** as a safety net, but be careful: deleting objects S3-side that Loki still has in its index causes query errors. Prefer Loki-managed retention.

### 7.5 LogQL: querying logs

A LogQL query has two halves: a **stream selector** (required) and a **pipeline** (optional).

```logql
{app="checkout", env="prod"} |= "timeout" | json | duration > 2s
 └──── selector ───────────┘ └── filter ─┘ └parser┘ └── label filter ──┘
```

Filters, in the order you should apply them (cheapest first):

```logql
{app="api"} |= "error"           # contains
{app="api"} != "healthcheck"     # does not contain
{app="api"} |~ "5\\d\\d"          # regex match
{app="api"} !~ "debug|trace"     # regex not-match
```

Parsers turn a line into fields you can filter on:

```logql
{app="api"} | json                              # parse JSON lines
{app="api"} | logfmt                            # parse key=value lines
{app="api"} | pattern "<ip> - - <_> \"<method> <path>\""
{app="api"} | regexp "(?P<status>\\d{3})"
```

Then formatting and metrics:

```logql
{app="api"} | json | line_format "{{.level}} {{.msg}}"

# COUNT: errors per second over 5-minute windows, grouped by pod
sum by (pod) (rate({app="api"} |= "error" [5m]))

# EXTRACT A NUMBER out of logs and average it
avg_over_time({app="api"} | json | unwrap duration_ms [5m])

# 95th percentile latency, computed from logs
quantile_over_time(0.95, {app="api"} | json | unwrap duration_ms [5m]) by (route)
```

That last trick is the killer feature: **you can build metrics out of logs**, which means you can alert on things you never instrumented.

### 7.6 Structured metadata (Loki 3.x)

You can attach high-cardinality details (trace IDs, user IDs, pod IPs) to a line *without* creating new streams:

```yaml
limits_config:
  allow_structured_metadata: true
```

This is the correct place for anything unique-per-request. Putting those in labels would explode your stream count — see the cardinality rule below.

### 7.7 Loki alerting rules

Loki has its own ruler that speaks the same format as Prometheus:

```yaml
groups:
  - name: log-alerts
    rules:
      - alert: ErrorRateSpike
        expr: |
          sum by (app) (rate({env="prod"} |= "ERROR" [5m])) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.app }} is logging more than 10 errors/sec"
```

---

## 8. Grafana in depth

### 8.1 The pieces

| Concept | What it means |
|---|---|
| **Data source** | A connection to Prometheus, Loki, CloudWatch, Postgres, etc. |
| **Dashboard** | A saved page of panels, stored as JSON |
| **Panel** | One visualization (time series, stat, table, logs, gauge, heatmap) |
| **Variable** | A dropdown at the top of a dashboard (`$namespace`, `$instance`) that rewrites the queries |
| **Annotation** | A vertical marker on graphs (a deploy, an incident) |
| **Explore** | Ad-hoc querying without saving a dashboard — where you actually debug |
| **Alerting** | Grafana's own unified alert engine, which can alert on *any* data source |
| **Drilldown** | Point-and-click exploration of metrics and logs with no query writing |

### 8.2 Provision everything as code

Anything you can click, you can also define in files. Three provisioning folders live under `/etc/grafana/provisioning/`:

```text
provisioning/
├── datasources/datasources.yml
├── dashboards/dashboards.yml     # points at a folder of dashboard JSON
└── alerting/rules.yml
```

Dashboard provider file:

```yaml
apiVersion: 1
providers:
  - name: "default"
    orgId: 1
    folder: "Platform"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false          # dashboards come only from Git
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

### 8.3 Correlating metrics and logs (the payoff)

In your Loki data source, turn on **derived fields** so a trace ID in a log line becomes a clickable link. And in the Prometheus data source, enable the exemplars link. Practical version for a Docker/K8s setup: use the *same label names* in both systems (`app`, `env`, `namespace`, `instance`). Then in Grafana you can:

1. See a latency spike on a Prometheus panel.
2. Select that time range.
3. Click **Explore → split → Loki**, and the label filters carry over.

Consistent labels across Prometheus and Loki is the single highest-value convention in this whole guide.

### 8.4 Security basics

```ini
# grafana.ini (or GF_* environment variables)
[security]
admin_user = admin
admin_password = $__env{GRAFANA_ADMIN_PASSWORD}
cookie_secure = true
disable_gravatar = true

[users]
allow_sign_up = false

[auth.anonymous]
enabled = false

[server]
root_url = https://grafana.example.com
```

Use SSO (Google, Okta, Azure AD, GitHub, generic OAuth/SAML) rather than local users as soon as you have more than a handful of people. Never put Grafana on the public internet on port 3000 with a default password.

### 8.5 Grafana 13 (April 2026) — what is new for beginners

- **Drilldown** apps for metrics and logs let you explore without writing PromQL/LogQL at all — start here if queries feel scary.
- **Dashboard schema v2** and improved edit/versioning workflows.
- Continued investment in **Grafana Alerting** and in **dashboards-as-code** tooling.

Because features move quickly, confirm specifics in the release notes: <https://grafana.com/docs/grafana/latest/whatsnew/>

---

## 9. Grafana Alloy: the agent that ships your data

### 9.1 Why Alloy exists

Grafana used to ship several agents: Promtail (logs), Grafana Agent (metrics/logs/traces), and various OpenTelemetry setups. That is now consolidated into **Alloy**, a distribution of the OpenTelemetry Collector with native Prometheus and Loki pipelines built in.

**Promtail reached end of life on March 2, 2026.** Alloy is the supported path.

Migrating an old config is one command:

```bash
alloy convert --source-format=promtail --output=/etc/alloy/config.alloy promtail.yaml
# also supports: --source-format=prometheus | static | otelcol
```

### 9.2 The component model

Alloy configs are components that reference each other's outputs. Every component has a type, a name, and a set of arguments and exports.

```alloy
component_type "label" {
  argument   = value
  forward_to = [next_component.receiver]
}
```

Common components:

| Component | Job |
|---|---|
| `discovery.docker`, `discovery.kubernetes`, `discovery.ec2`, `discovery.file` | find things |
| `discovery.relabel` | rename/drop/keep labels before collection |
| `loki.source.file`, `loki.source.docker`, `loki.source.kubernetes`, `loki.source.journal` | read logs |
| `loki.process` | parse, filter, add labels, drop noise |
| `loki.write` | push to Loki |
| `prometheus.exporter.unix`, `prometheus.exporter.redis`, ... | built-in exporters, no separate binary |
| `prometheus.scrape` | pull `/metrics` |
| `prometheus.relabel`, `prometheus.remote_write` | reshape and push metrics |
| `otelcol.receiver.*`, `otelcol.exporter.*` | OpenTelemetry pipelines |

### 9.3 A realistic Linux server config

```alloy
logging { level = "info" }

// ---------- METRICS ----------
prometheus.exporter.unix "host" {
  disable_collectors = ["ipvs", "btrfs", "infiniband", "xfs", "zfs"]
  enable_collectors  = ["systemd"]
}

prometheus.scrape "host" {
  targets         = prometheus.exporter.unix.host.targets
  scrape_interval = "15s"
  forward_to      = [prometheus.remote_write.central.receiver]
}

prometheus.remote_write "central" {
  endpoint {
    url = "http://prometheus.internal:9090/api/v1/write"
    // For Amazon Managed Prometheus, add sigv4 { region = "us-east-1" }
  }
  external_labels = {
    env = "prod",
  }
}

// ---------- LOGS ----------
local.file_match "applogs" {
  path_targets = [
    { __path__ = "/var/log/myapp/*.log", job = "myapp", env = "prod" },
  ]
}

loki.source.file "applogs" {
  targets    = local.file_match.applogs.targets
  forward_to = [loki.process.clean.receiver]
}

loki.process "clean" {
  // parse JSON logs and promote a couple of fields to labels
  stage.json {
    expressions = { level = "level", msg = "message" }
  }
  stage.labels {
    values = { level = "level" }        // low-cardinality only!
  }
  // throw away health-check noise before it costs you money
  stage.drop {
    expression = ".*GET /healthz.*"
    drop_counter_reason = "healthcheck"
  }
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  endpoint {
    url = "http://loki.internal:3100/loki/api/v1/push"
  }
}

// also collect systemd journal
loki.source.journal "systemd" {
  max_age    = "12h"
  labels     = { job = "systemd-journal" }
  forward_to = [loki.write.central.receiver]
}
```

> If you use `prometheus.remote_write` to a self-hosted Prometheus, start Prometheus with `--web.enable-remote-write-receiver`. Otherwise it will refuse the writes.

### 9.4 Alloy's UI

Alloy serves a web UI (default `:12345`) showing every component, its health, and live data flow. When something is not arriving, **open this first** — it usually tells you exactly which component is unhealthy and why.

---

## 10. Docker: production-shaped configuration

The lab in section 5 is fine for learning. Here is what to change for something people depend on.

### 10.1 Hardening checklist

| Change | Why |
|---|---|
| Pin exact image tags (`grafana/loki:3.7.6`) | `latest` silently upgrades and breaks configs |
| Bind ports to `127.0.0.1` and put a reverse proxy (Caddy/Nginx/Traefik) with TLS + auth in front | Prometheus and Loki have **no built-in authentication** |
| Set `mem_limit` / `cpus` per service | one runaway query should not take down the host |
| Use named volumes and back them up | container restarts must not lose data |
| Add `healthcheck:` blocks | Compose and orchestrators can restart the truly broken |
| Run containers as non-root where possible | limit blast radius |
| Keep secrets in a `.env` file or Docker secrets, never in Git | obvious in hindsight |

### 10.2 Additions to the Compose file

```yaml
services:
  loki:
    image: grafana/loki:3.7.6
    mem_limit: 2g
    cpus: 1.0
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O- http://localhost:3100/ready | grep -q ready"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 60s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }   # stop logs eating the disk
```

### 10.3 Two ways to collect container logs

**Option A — Alloy reads the Docker socket** (what we did): no change to your apps, works with any log driver that writes to the local json-file, and Alloy adds container labels automatically.

**Option B — the Docker Loki plugin**: Docker sends logs directly to Loki.

```bash
docker plugin install grafana/loki-docker-driver:3.7.6 --alias loki --grant-all-permissions
```

```yaml
services:
  myapp:
    image: myapp:1.2.3
    logging:
      driver: loki
      options:
        loki-url: "http://localhost:3100/loki/api/v1/push"
        loki-retries: "5"
        loki-batch-size: "400"
        max-size: "10m"
```

| | Alloy on the socket | Loki Docker driver |
|---|---|---|
| Pros | Central config, buffering, parsing, works if Loki is down, one agent for logs+metrics | Very little setup, no agent container |
| Cons | Needs socket access (a privilege) | If Loki is unreachable, containers can block or drop logs; `docker logs` may stop working locally; plugin upgrades are fiddly |

**Recommendation:** use Alloy.

### 10.4 Adding Alertmanager to the lab

```yaml
  alertmanager:
    image: prom/alertmanager:v0.28.1
    restart: unless-stopped
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --web.external-url=http://localhost:9093
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager-data:/alertmanager
    ports:
      - "127.0.0.1:9093:9093"
```

### 10.5 Backups

```bash
# Grafana: the dashboards + users database
docker run --rm -v observability-lab_grafana-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/grafana-$(date +%F).tar.gz -C /data .

# Prometheus: use the admin API snapshot (needs --web.enable-admin-api)
curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot
```

Better long-term answer: keep dashboards in Git (provisioning), and keep metrics in remote storage. Then a lost server is an annoyance, not an outage.

---

## 11. AWS EC2 + Launch Templates

### 11.1 What a Launch Template is (and why it matters here)

A **Launch Template** is a saved recipe for an EC2 instance: which AMI, which instance type, which security groups, which IAM role, and — most importantly for us — a **user-data script** that runs automatically the first time the instance boots.

That last part is the whole trick: instead of SSH-ing into every new server to install monitoring agents, you bake the installation into the template. Every instance launched from it — by hand, by an Auto Scaling Group, or by a deployment pipeline — arrives already monitored.

**Architecture we are building:**

```text
      ┌────────────── Monitoring VPC/subnet ──────────────┐
      │  EC2 "monitoring" instance                        │
      │    Prometheus (:9090)  Loki (:3100)  Grafana(:3000)│
      └───────▲───────────────────────▲───────────────────┘
              │ scrape :9100          │ push logs
   ┌──────────┴───────────┐   ┌───────┴────────────┐
   │ App instance (ASG)   │   │ App instance (ASG) │
   │  node_exporter :9100 │   │  node_exporter     │
   │  Alloy (logs)        │   │  Alloy             │
   └──────────────────────┘   └────────────────────┘
       ▲ all launched from the same Launch Template
```

### 11.2 Step 1 — IAM role for the monitored instances

Instances need permission for nothing at all if you only run node_exporter — but if you want Alloy to write to Amazon Managed Prometheus or read tags, attach a role. Minimum useful policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSMForRemoteAccess",
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:*",
        "ec2messages:*"
      ],
      "Resource": "*"
    }
  ]
}
```

Attach the AWS managed policy `AmazonSSMManagedInstanceCore` instead of hand-writing this — then you can use **Session Manager** to get a shell without opening SSH to the world.

### 11.3 Step 2 — IAM role for the Prometheus server

Prometheus needs to *ask AWS which instances exist* in order to scrape them:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:DescribeInstances",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeTags"
    ],
    "Resource": "*"
  }]
}
```

(`ec2:Describe*` actions do not support resource-level restriction, so `"Resource": "*"` is expected here. Restrict by condition keys or by using a dedicated account/role if you need tighter control.)

### 11.4 Step 3 — Security groups

Create two:

| Group | Inbound rule | Meaning |
|---|---|---|
| `sg-monitoring-server` | 3000 from your office/VPN CIDR only | Grafana UI |
| `sg-monitored-node` | 9100 **from `sg-monitoring-server`** (source = the security group, not a CIDR) | node_exporter |

Referencing a security group as the source is the AWS-native way to say "only my Prometheus box may scrape these instances," and it keeps working as IPs change.

**Never** open 9090, 9100, or 3100 to `0.0.0.0/0`. Those endpoints have no authentication and happily expose your whole infrastructure.

### 11.5 Step 4 — The user-data script

This runs as root on first boot. This version targets **Amazon Linux 2023** (use `apt-get` and the Grafana APT repo for Ubuntu).

```bash
#!/bin/bash
set -euxo pipefail

LOKI_URL="http://loki.internal:3100/loki/api/v1/push"
PROM_URL="http://prometheus.internal:9090/api/v1/write"
NODE_EXPORTER_VERSION="1.9.1"

############################################
# 1. node_exporter (machine metrics on :9100)
############################################
useradd --system --no-create-home --shell /sbin/nologin node_exporter || true

curl -fsSL -o /tmp/ne.tar.gz \
  "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
tar -xzf /tmp/ne.tar.gz -C /tmp
install -m 0755 "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/node_exporter

cat >/etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.systemd \
  --collector.processes \
  --web.listen-address=:9100
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now node_exporter

############################################
# 2. Grafana Alloy (logs, and optionally metrics)
############################################
cat >/etc/yum.repos.d/grafana.repo <<'REPO'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPO

dnf install -y alloy

# Pull instance identity from IMDSv2 so logs carry useful labels
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

mkdir -p /etc/alloy
cat >/etc/alloy/config.alloy <<ALLOY
logging { level = "info" }

loki.source.journal "systemd" {
  max_age    = "12h"
  labels     = { job = "systemd-journal", instance = "${IID}", az = "${AZ}", env = "prod" }
  forward_to = [loki.write.central.receiver]
}

local.file_match "applogs" {
  path_targets = [{
    __path__ = "/var/log/app/*.log",
    job      = "app",
    instance = "${IID}",
    env      = "prod",
  }]
}

loki.source.file "applogs" {
  targets    = local.file_match.applogs.targets
  forward_to = [loki.write.central.receiver]
}

loki.write "central" {
  endpoint { url = "${LOKI_URL}" }
}
ALLOY

systemctl enable --now alloy

echo "monitoring bootstrap complete"
```

> **Debugging user-data:** output goes to `/var/log/cloud-init-output.log` on the instance. `set -euxo pipefail` at the top makes failures loud instead of silent. User-data runs **once** by default on first boot.

### 11.6 Step 5 — Create the Launch Template

**Console path:** EC2 → Launch Templates → Create launch template → fill in AMI, instance type, key pair, security group `sg-monitored-node`, IAM instance profile, then **Advanced details → User data** → paste the script.

**CLI:**

```bash
# user-data must be base64 encoded for the CLI
B64=$(base64 -w0 user-data.sh)

aws ec2 create-launch-template \
  --launch-template-name app-monitored \
  --version-description "v1 node_exporter + alloy" \
  --launch-template-data "{
    \"ImageId\": \"ami-0abcdef1234567890\",
    \"InstanceType\": \"t3.small\",
    \"IamInstanceProfile\": {\"Name\": \"app-instance-profile\"},
    \"SecurityGroupIds\": [\"sg-0monitorednode\"],
    \"MetadataOptions\": {\"HttpTokens\": \"required\", \"HttpEndpoint\": \"enabled\"},
    \"Monitoring\": {\"Enabled\": true},
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\",       \"Value\": \"app-server\"},
        {\"Key\": \"Monitoring\", \"Value\": \"true\"},
        {\"Key\": \"Env\",        \"Value\": \"prod\"},
        {\"Key\": \"Service\",    \"Value\": \"checkout\"}
      ]
    }],
    \"UserData\": \"${B64}\"
  }"
```

**Terraform:**

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "app-monitored-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.small"

  iam_instance_profile { name = aws_iam_instance_profile.app.name }
  vpc_security_group_ids = [aws_security_group.monitored_node.id]

  metadata_options {
    http_tokens   = "required"   # IMDSv2 only
    http_endpoint = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    loki_url = "http://loki.internal:3100/loki/api/v1/push"
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "app-server"
      Monitoring = "true"
      Env        = "prod"
      Service    = "checkout"
    }
  }

  lifecycle { create_before_destroy = true }
}

resource "aws_autoscaling_group" "app" {
  min_size            = 2
  max_size            = 10
  desired_capacity    = 2
  vpc_zone_identifier = var.private_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Monitoring"
    value               = "true"
    propagate_at_launch = true
  }
}
```

> **The tags are the important part.** Prometheus will use them to discover and label these instances. Decide your tag vocabulary (`Env`, `Service`, `Monitoring`) before you create 200 instances.

### 11.7 Step 6 — Teach Prometheus to find instances automatically

On the monitoring server, in `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: ec2-nodes
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        refresh_interval: 60s
        filters:
          - name: tag:Monitoring
            values: ["true"]
          - name: instance-state-name
            values: ["running"]

    relabel_configs:
      # Scrape the PRIVATE ip, never the public one
      - source_labels: [__meta_ec2_private_ip]
        replacement: "$1:9100"
        target_label: __address__

      # Turn EC2 tags into friendly labels
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance_name
      - source_labels: [__meta_ec2_tag_Env]
        target_label: env
      - source_labels: [__meta_ec2_tag_Service]
        target_label: service
      - source_labels: [__meta_ec2_instance_id]
        target_label: instance_id
      - source_labels: [__meta_ec2_availability_zone]
        target_label: az
      - source_labels: [__meta_ec2_instance_type]
        target_label: instance_type

      # Safety net: drop anything not explicitly opted in
      - source_labels: [__meta_ec2_tag_Monitoring]
        regex: "true"
        action: keep
```

**Relabeling in one sentence:** it is a small pipeline of find-and-replace rules that runs *before* scraping, letting you rewrite the target address and turn discovery metadata into permanent labels.

Verify on the monitoring server:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health: .health, err: .lastError}'
```

### 11.8 Step 7 — The monitoring server itself

Two sane options:

**Option A — one EC2 instance running the Docker Compose stack from section 5.** Simple, cheap, and adequate for tens of servers. Give it:
- gp3 EBS volume sized from the formula in [6.7](#67-storage-and-retention), mounted at `/var/lib/docker/volumes`
- an EBS snapshot schedule (Data Lifecycle Manager)
- Grafana behind an Application Load Balancer with an ACM certificate and OIDC auth

**Option B — AWS managed services.** Replace self-hosted pieces:

| Self-hosted | AWS managed equivalent |
|---|---|
| Prometheus storage | **Amazon Managed Service for Prometheus (AMP)** — you still run a scraper (Alloy or an AWS-managed collector) and `remote_write` to AMP |
| Grafana | **Amazon Managed Grafana (AMG)** — SSO via IAM Identity Center, no upgrades to run |
| Loki | No AWS equivalent; use CloudWatch Logs, OpenSearch, or run Loki yourself on S3 |

With AMP, your Alloy `remote_write` needs SigV4 signing:

```alloy
prometheus.remote_write "amp" {
  endpoint {
    url = "https://aps-workspaces.us-east-1.amazonaws.com/workspaces/ws-abc123/api/v1/remote_write"
    sigv4 { region = "us-east-1" }
  }
}
```

**Cost sanity check:** a self-hosted `t3.medium` + 100 GB gp3 is roughly $40–50/month. AMP and AMG bill per ingested sample / per active user, which is often cheaper at small scale and pricier at large scale. Model both before committing.

### 11.9 Common EC2 mistakes

| Symptom | Cause |
|---|---|
| Targets show `context deadline exceeded` | Security group does not allow 9100 from the Prometheus SG |
| `ec2_sd_configs` returns zero targets | Missing IAM permission `ec2:DescribeInstances`, or wrong region, or filter typo (`tag:Monitoring` is case-sensitive) |
| user-data did not run | Instance launched from a snapshot/AMI that already booted, or a syntax error — check `/var/log/cloud-init-output.log` |
| IMDS calls hang | IMDSv2 required but script used the old unauthenticated call — always fetch a token first |
| Metrics vanish when instances scale in | Normal. Use `avg by (service)` rather than per-instance panels for ASG workloads |

---

## 12. Amazon EKS (Kubernetes)

Kubernetes is where this stack really shines, because everything is dynamic and label-driven.

### 12.1 What you will install

| Piece | Helm chart | What it gives you |
|---|---|---|
| Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics + operator | `prometheus-community/kube-prometheus-stack` | metrics and ~30 ready dashboards |
| Loki | `grafana-community/loki` | log storage on S3 |
| Alloy | `grafana/alloy` | collects pod logs (DaemonSet) |

### 12.2 Step 1 — Prerequisites

```bash
kubectl version --client
helm version            # v3.2+
eksctl version
aws sts get-caller-identity
```

Create a cluster if you do not have one (`cluster.yaml`):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: obs-demo
  region: us-east-1
  version: "1.33"

iam:
  withOIDC: true              # required for IRSA

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver  # required for PersistentVolumes
  - name: eks-pod-identity-agent

managedNodeGroups:
  - name: ng-default
    instanceType: t3.large
    desiredCapacity: 3
    minSize: 2
    maxSize: 6
    volumeSize: 50
    volumeType: gp3
```

```bash
eksctl create cluster -f cluster.yaml
```

> **Why the EBS CSI driver?** Prometheus, Grafana, and Loki all want persistent disks. Without the driver, PersistentVolumeClaims stay `Pending` forever — one of the most common "it just hangs" problems on EKS.

Create a gp3 StorageClass (EKS still defaults to gp2 in many versions):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  type: gp3
  encrypted: "true"
```

### 12.3 Step 2 — Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl create namespace monitoring
```

`values-kps.yaml`:

```yaml
# EKS runs the control plane for you, and does NOT expose these components.
# Leaving them enabled produces permanently-red targets and false alerts.
kubeEtcd:            { enabled: false }
kubeControllerManager: { enabled: false }
kubeScheduler:       { enabled: false }
kubeProxy:           { enabled: true }

prometheus:
  prometheusSpec:
    retention: 15d
    retentionSize: 45GB
    scrapeInterval: 30s
    # Pick up ServiceMonitors from ALL namespaces, not just ones with the chart's label
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests: { cpu: 500m, memory: 2Gi }
      limits:   { memory: 4Gi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: ["ReadWriteOnce"]
          resources:
            requests: { storage: 5Gi }

grafana:
  enabled: true
  adminPassword: ""                      # set via existingSecret in real life
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  persistence:
    enabled: true
    storageClassName: gp3
    size: 10Gi
  # Add Loki as a second data source
  additionalDataSources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki-gateway.monitoring.svc.cluster.local
      jsonData:
        maxLines: 1000
  service:
    type: ClusterIP                      # expose via Ingress/ALB, not LoadBalancer:3000
  grafana.ini:
    server:
      root_url: https://grafana.example.com
    users:
      allow_sign_up: false

nodeExporter: { enabled: true }
kubeStateMetrics: { enabled: true }
```

```bash
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"

helm install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f values-kps.yaml

kubectl get pods -n monitoring -w
```

Open Grafana:

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# then browse http://localhost:3000
kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

### 12.4 Step 3 — Scrape your own applications with a ServiceMonitor

The Prometheus **Operator** means you never edit `prometheus.yml` again. You create Kubernetes objects instead:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: checkout
  namespace: shop
  labels:
    release: kps               # some setups match on this; harmless to include
spec:
  selector:
    matchLabels:
      app: checkout            # matches the SERVICE's labels
  namespaceSelector:
    matchNames: [shop]
  endpoints:
    - port: http-metrics       # the NAME of the port in the Service, not the number
      path: /metrics
      interval: 30s
```

And an alert, as a `PrometheusRule`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: checkout-rules
  namespace: shop
spec:
  groups:
    - name: checkout
      rules:
        - alert: CheckoutHighErrorRate
          expr: |
            sum(rate(http_requests_total{job="checkout",status=~"5.."}[5m]))
              /
            sum(rate(http_requests_total{job="checkout"}[5m])) > 0.05
          for: 10m
          labels: { severity: critical }
          annotations:
            summary: "Checkout 5xx rate above 5%"
```

### 12.5 Step 4 — S3 bucket and IAM for Loki

```bash
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="loki-chunks-${ACCOUNT_ID}"

aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION"
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

IAM policy `loki-s3-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::loki-chunks-ACCOUNT_ID"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::loki-chunks-ACCOUNT_ID/*"
    }
  ]
}
```

Give the Loki pods that permission. Two ways:

**IRSA (classic, still fine):**

```bash
eksctl create iamserviceaccount \
  --cluster obs-demo \
  --namespace monitoring \
  --name loki \
  --attach-policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/loki-s3 \
  --approve
```

**EKS Pod Identity (newer, simpler — no OIDC trust policy juggling):**

```bash
aws eks create-pod-identity-association \
  --cluster-name obs-demo \
  --namespace monitoring \
  --service-account loki \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/loki-s3-role
```

Pod Identity is the recommended default for new clusters; IRSA remains supported and is what most existing tutorials show.

### 12.6 Step 5 — Install Loki

> **Important 2026 change:** the open-source Loki Helm chart now lives in the **grafana-community** repo, and the version numbers restarted (6.x in the old repo → 7.x and up in the new one). Chart values change between major versions, so always run `helm show values` for the exact version you install.

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update
helm show values grafana-community/loki --version 18.9.0 > /tmp/loki-defaults.yaml
```

`values-loki.yaml` (monolithic mode, S3 storage — good for up to roughly 100 GB/day):

```yaml
deploymentMode: Monolithic        # renamed from "SingleBinary" in chart 12.0.0

loki:
  auth_enabled: false             # single tenant; keep it inside the cluster
  schemaConfig:
    configs:
      - from: "2026-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: loki-chunks-ACCOUNT_ID
      ruler:  loki-chunks-ACCOUNT_ID
    s3:
      region: us-east-1
  limits_config:
    retention_period: 720h
    allow_structured_metadata: true
    volume_enabled: true
    max_query_series: 100000
  compactor:
    retention_enabled: true
    delete_request_store: s3

serviceAccount:
  create: false
  name: loki                      # the SA you bound to the IAM role above

monolithic:                       # was "singleBinary:" in older chart versions
  replicas: 1
  persistence:
    enabled: true
    storageClass: gp3
    size: 30Gi
  resources:
    requests: { cpu: 500m, memory: 2Gi }
    limits:   { memory: 4Gi }

# Turn off the components a monolithic install does not use
read:    { replicas: 0 }
write:   { replicas: 0 }
backend: { replicas: 0 }

# The built-in MinIO subchart is deprecated (removal planned 2026-10-31).
minio: { enabled: false }

chunksCache:  { enabled: false }   # enable for larger installs
resultsCache: { enabled: false }

gateway:
  enabled: true                    # nginx that fronts Loki; this is the URL Grafana uses
```

```bash
helm install loki grafana-community/loki -n monitoring -f values-loki.yaml
kubectl get pods -n monitoring -l app.kubernetes.io/name=loki
```

Sanity check from inside the cluster:

```bash
kubectl run curl --rm -it --image=curlimages/curl -n monitoring --restart=Never -- \
  curl -s http://loki-gateway/loki/api/v1/labels
```

### 12.7 Step 6 — Install Alloy to collect pod logs

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

`values-alloy.yaml`:

```yaml
controller:
  type: daemonset               # one Alloy per node

alloy:
  mounts:
    varlog: true                # /var/log so it can read container logs
  configMap:
    content: |-
      logging { level = "info" }

      // find every pod in the cluster
      discovery.kubernetes "pods" {
        role = "pod"
      }

      // only tail pods on THIS node, and build clean labels
      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          regex         = sys.env("HOSTNAME")
          action        = "keep"
        }
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
          target_label  = "app"
        }
        rule {
          target_label = "cluster"
          replacement  = "obs-demo"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pods.output
        forward_to = [loki.process.pipeline.receiver]
      }

      loki.process "pipeline" {
        // drop kube-system noise you will never read
        stage.drop {
          source              = "namespace"
          expression          = "kube-system"
          drop_counter_reason = "kube_system_noise"
        }
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
        }
      }

  resources:
    requests: { cpu: 100m, memory: 128Mi }
    limits:   { memory: 512Mi }
```

```bash
helm install alloy grafana/alloy -n monitoring -f values-alloy.yaml
kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy
```

### 12.8 Step 7 — Verify the whole thing

```bash
# metrics targets healthy?
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
# open http://localhost:9090/targets

# logs arriving?
kubectl port-forward -n monitoring svc/loki-gateway 8080:80
curl -s "http://localhost:8080/loki/api/v1/labels"
```

Then in Grafana → Explore → Loki:

```logql
{namespace="shop"} |= "error"
```

And a Kubernetes metric:

```promql
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```

### 12.9 Exposing Grafana properly on EKS

Use an ALB Ingress with ACM TLS rather than a raw LoadBalancer service:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/abc
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
    - host: grafana.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kps-grafana
                port: { number: 80 }
```

This requires the AWS Load Balancer Controller. Even better: put the ALB behind Cognito or your OIDC provider so authentication happens before Grafana is reached.

### 12.10 EKS-specific gotchas

| Problem | Fix |
|---|---|
| etcd / scheduler / controller-manager targets always down | Disable them — AWS manages the control plane and does not expose them |
| PVCs stuck `Pending` | Install the `aws-ebs-csi-driver` add-on and set a default StorageClass |
| Prometheus pod OOMKilled | Too many series. Raise memory, drop unused metrics with `metricRelabelings`, shorten retention |
| Loki `AccessDenied` on S3 | Service account not bound to the IAM role, or the chart created its own SA — check `kubectl describe sa loki -n monitoring` |
| Admission webhook errors with custom CNI | Set `prometheusOperator.admissionWebhooks.patch.enabled` / hostNetwork options per the chart README |
| Helm upgrade fails on CRDs | kube-prometheus-stack CRDs are **not** upgraded by Helm; apply the new CRDs manually before a major chart upgrade |
| Costs creep up | Karpenter/Spot churn creates lots of short-lived series; drop `container_*` metrics you never use |

---

## 13. Dashboards and alerts

### 13.1 Dashboards worth importing on day one

| ID | Dashboard | Needs |
|---|---|---|
| 1860 | Node Exporter Full | node_exporter |
| 15757 | Kubernetes / Views / Global | kube-state-metrics |
| 15760 | Kubernetes / Views / Pods | kube-state-metrics |
| 13639 | Loki logs / app | Loki |
| 19268 | Prometheus overview (self-monitoring) | Prometheus |

Import: **Dashboards → New → Import → paste ID → pick data source**.

### 13.2 Build one panel yourself

1. New dashboard → **Add visualization** → pick Prometheus.
2. Query: `sum by (status) (rate(http_requests_total[5m]))`
3. Legend: `{{status}}`
4. Panel options → Unit → **requests/sec (rps)**
5. Add a **variable**: Dashboard settings → Variables → New → Query → `label_values(http_requests_total, service)`, name it `service`. Now use `{service="$service"}` in queries and you get a dropdown.

### 13.3 The four golden signals

Design dashboards around these, not around whatever metric was easy:

| Signal | Question | Typical query |
|---|---|---|
| **Latency** | How slow? | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` |
| **Traffic** | How busy? | `sum(rate(http_requests_total[5m]))` |
| **Errors** | How broken? | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| **Saturation** | How full? | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |

For infrastructure, the parallel model is **USE**: Utilization, Saturation, Errors.

### 13.4 Alert design rules

- **Alert on symptoms, not causes.** "Checkout error rate is 8%" wakes the right person. "CPU is 91%" often does not matter at all.
- **Always use `for:`.** A 30-second blip is not an incident.
- **Every alert needs an owner and a runbook link** in its annotations. An alert nobody knows how to fix trains people to ignore alerts.
- **Route by severity**: `critical` → pager, `warning` → chat, `info` → dashboard only.
- **Review firing history monthly** and delete alerts that never led to action.

---

## 14. PromQL and LogQL cheat sheets

### 14.1 PromQL

```promql
# --- basics ---
node_memory_MemAvailable_bytes                    # instant value
node_memory_MemAvailable_bytes{instance="a:9100"} # filter by label
{__name__=~"node_cpu.*"}                          # regex on metric name

# --- counters ---
rate(http_requests_total[5m])                     # per-second average
irate(http_requests_total[5m])                    # per-second, last 2 points (spiky)
increase(http_requests_total[1h])                 # total added in 1 hour

# --- aggregation ---
sum by (job) (rate(http_requests_total[5m]))
avg without (instance) (node_load1)
topk(5, sum by (pod) (rate(container_cpu_usage_seconds_total[5m])))
count(up == 1)

# --- percentiles from histograms ---
histogram_quantile(0.99,
  sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))

# --- ratios (error budget style) ---
sum(rate(http_requests_total{status=~"5.."}[5m]))
  / sum(rate(http_requests_total[5m]))

# --- prediction and time ---
predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0
time() - node_boot_time_seconds                   # uptime in seconds

# --- comparing / joining ---
node_filesystem_avail_bytes / node_filesystem_size_bytes * 100
kube_pod_info * on(pod) group_left(node) kube_pod_container_info

# --- absence and staleness ---
absent(up{job="checkout"})                        # alert when a job disappears entirely
changes(process_start_time_seconds[1h]) > 3       # crash-looping
```

**Golden rules:** wrap counters in `rate()`; use a range at least 4× your scrape interval (`[2m]` minimum at 30s scrapes); `sum` *after* `rate`, never before.

### 14.2 LogQL

```logql
# --- selectors (always required, always first) ---
{app="checkout"}
{namespace="prod", container=~"api|worker"}

# --- line filters (cheap, apply early) ---
{app="checkout"} |= "ERROR" != "healthz"
{app="checkout"} |~ `(?i)timeout|refused`

# --- parsers ---
{app="checkout"} | json
{app="checkout"} | logfmt
{app="checkout"} | pattern `<_> <method> <path> <status> <duration>`

# --- label filters after parsing ---
{app="checkout"} | json | status >= 500 | duration > 1s

# --- formatting output ---
{app="checkout"} | json | line_format "{{.ts}} {{.level}} {{.msg}}"

# --- metrics FROM logs ---
sum by (level) (rate({app="checkout"}[5m]))
count_over_time({app="checkout"} |= "ERROR" [1h])
sum by (route) (
  quantile_over_time(0.95, {app="checkout"} | json | unwrap duration_ms [5m])
)
bytes_over_time({app="checkout"}[1h])             # how much volume this app produces
```

**Query performance rules:** narrow the time range, use the most specific labels you have, put `|=` string filters before parsers, and avoid regex when a plain contains-filter works.

---

## 15. Best practices

### 15.1 Naming and labels

- Use the **same label names everywhere**: `env`, `cluster`, `service`, `namespace`, `instance`. This is what makes metric→log correlation one click instead of a research project.
- Metric names: `snake_case`, base units (`_seconds`, `_bytes`), counters end in `_total`.
- Add `external_labels` (`cluster`, `region`, `env`) on every Prometheus and every Alloy so data merged into a central store never becomes ambiguous.

### 15.2 The single most important rule: cardinality

**Cardinality** = the number of unique label combinations. Every unique combination is a separate time series (Prometheus) or stream (Loki), and cost grows with it.

**Never use as a label:** user ID, request ID, trace ID, session ID, full URL with parameters, timestamp, IP address, error message text, pod IP.

```text
BAD:  http_requests_total{user_id="83719", url="/order/9931?ref=abc"}
      → millions of series, Prometheus dies

GOOD: http_requests_total{route="/order/:id", status="200"}
      → dozens of series, everything is fast
```

Put the unique details in the **log line** (Loki) or in **structured metadata**, not in labels. A useful ceiling for a single Prometheus: keep total active series under a few million, and any one metric under ~10,000 series.

Check your worst offenders:

```promql
topk(10, count by (__name__)({__name__=~".+"}))     # biggest metrics
```

### 15.3 Retention strategy

| Data | Typical retention | Where |
|---|---|---|
| Raw metrics | 15–30 days | Prometheus local disk |
| Downsampled metrics | 1–2 years | Mimir / Thanos / AMP |
| Application logs | 7–30 days | Loki on S3 |
| Audit / compliance logs | 1–7 years | S3 Glacier, separate from Loki |

### 15.4 Security

- Prometheus, Loki, and Alertmanager ship with **no authentication**. Assume anything that can reach them can read everything and, with admin APIs enabled, delete it. Keep them on private networks and front them with a proxy that does TLS + auth.
- Grafana: SSO, no anonymous access, rotate the admin password, use least-privilege data source permissions and (in Grafana Enterprise/Cloud) data source-level RBAC.
- Encrypt S3 buckets, block public access, use IAM roles instead of static keys everywhere.
- Scrub secrets *before* they are logged — the cheapest place to fix a leaked token is the application.

### 15.5 Reliability

- Do not monitor your monitoring with itself alone. Add a dead-man's-switch: an alert that is *always* firing and a receiver that pages you if it *stops* arriving (Alertmanager's `Watchdog` in kube-prometheus-stack does exactly this).
- Run two Prometheus servers scraping the same targets for HA (Alertmanager deduplicates).
- Put Loki chunks in S3, not on an instance disk. Instances die; buckets do not.
- Test your restores. A backup you have never restored is a rumour.

### 15.6 Cost control

- Drop metrics you never query, at scrape time:

```yaml
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: "go_gc_duration_seconds.*|apiserver_request_duration_seconds_bucket"
        action: drop
```

- Drop noisy logs at the agent (`stage.drop`) — health checks and access logs for static assets are usually 60%+ of volume.
- Use recording rules for expensive dashboard queries.
- Sample high-volume debug logs rather than dropping the class entirely.

---

## 16. Pros, cons, and alternatives

### 16.1 Prometheus vs. the field

| Option | Pros | Cons |
|---|---|---|
| **Prometheus (self-hosted)** | Free, huge ecosystem, PromQL, works everywhere, no vendor lock-in | Single node, no built-in HA or long-term storage, you operate it |
| **Amazon Managed Prometheus (AMP)** | No servers, scales, IAM-integrated, AWS-native | Pay per sample; still need a collector; limited configuration control |
| **CloudWatch Metrics** | Zero setup for AWS services, integrated alarms | Expensive at high cardinality, weak query language, 1-minute granularity by default |
| **VictoriaMetrics** | Very fast, much lower RAM, drop-in PromQL compatible | Smaller community; some subtle PromQL differences |
| **Datadog / New Relic** | Everything in one product, great UX, support | Cost grows fast and unpredictably; lock-in |

### 16.2 Loki vs. the field

| Option | Pros | Cons |
|---|---|---|
| **Loki** | Cheap (S3 + tiny index), same labels as Prometheus, great Grafana integration, LogQL can generate metrics | Full-text search is slower than an inverted index; bad labeling ruins performance; operating microservices mode is real work |
| **OpenSearch / Elasticsearch** | Fast arbitrary full-text search, mature analytics | Expensive storage and RAM, heavier to operate, cluster management |
| **CloudWatch Logs** | Zero setup on AWS, integrated with Lambda/ECS | Ingestion and query costs add up; Logs Insights is limited |
| **ClickHouse-based (SigNoz, Quickwit)** | Very fast, columnar, strong price/performance | Newer ecosystems, fewer ready-made dashboards |

### 16.3 Agent comparison

| Agent | Status 2026 | Use when |
|---|---|---|
| **Grafana Alloy** | Current, recommended | Default choice for Grafana stack; one agent for logs, metrics, traces, profiles |
| **Promtail** | **End of life March 2, 2026** | Never for new work — migrate with `alloy convert` |
| **Grafana Agent** | Retired, replaced by Alloy | Migrate |
| **OpenTelemetry Collector** | Healthy, vendor-neutral | You want maximum vendor neutrality and OTel-native pipelines |
| **Fluent Bit / Fluentd** | Healthy | Logs only, very light footprint, huge output plugin list |
| **Prometheus Agent mode** | Healthy | Metrics only, minimal config, straight remote_write |

### 16.4 Should you self-host at all?

| | Self-hosted OSS | Grafana Cloud | AWS managed (AMP/AMG) |
|---|---|---|---|
| Money | Cheapest in raw infra | Per-usage; free tier is generous for small teams | Per-usage, AWS-billed |
| Time | You run upgrades, storage, scaling | Almost none | Low |
| Control | Total | Limited | Limited |
| Best for | Cost-sensitive teams with ops skills; strict data residency | Small teams and startups who value time over money | Shops standardized on AWS + IAM |

An honest rule of thumb: **fewer than ~5 engineers and no dedicated ops person → use a managed offering.** Your time is worth more than the license.

---

## 17. Troubleshooting

### 17.1 Prometheus

| Symptom | Check |
|---|---|
| Target `DOWN`, `connection refused` | Is the exporter running? `curl http://target:9100/metrics` from the Prometheus host |
| Target `DOWN`, `context deadline exceeded` | Firewall/security group, or the target takes longer than `scrape_timeout` |
| No data in graph but target is UP | Metric name typo, or the time range predates the data. Try the raw metric name with no filters |
| `out of order sample` errors | Two scrapers writing the same series, or clock skew — check NTP |
| Prometheus OOM | Too many series. Use `topk(10, count by (__name__)({__name__=~".+"}))` and drop the worst |
| Config change not applied | `promtool check config` then `curl -XPOST .../-/reload` |

### 17.2 Loki

| Symptom | Check |
|---|---|
| `no such table` / empty results | `schema_config` `from:` date is in the future, or you edited an existing schema entry |
| `entry too far behind` / out-of-order | Clock skew on the sending host, or a very old log file being tailed |
| `429 ingestion rate limit exceeded` | Raise `ingestion_rate_mb` / `ingestion_burst_size_mb`, or drop noisy logs at the agent |
| `max streams per user exceeded` | Cardinality — you put something unique in a label |
| Queries very slow | Time range too wide, or too few labels in the selector; add `|=` filters before parsers |
| Logs stop after a rollout | Agent lost the file position, or the pod name label changed — check the Alloy UI |

### 17.3 Grafana

| Symptom | Check |
|---|---|
| "Data source not found" on an imported dashboard | The dashboard has a hard-coded UID; re-select the data source when importing |
| Panel shows "No data" | Run the same query in Explore; nine times out of ten it is a label typo |
| Slow dashboards | Too many panels, too-wide ranges, no recording rules; set a sane min interval |
| Cannot log in after upgrade | Check the container logs; do not delete the volume — that deletes all your dashboards |

### 17.4 A general debugging ladder

1. Is the process running? (`docker compose ps`, `kubectl get pods`, `systemctl status`)
2. Is it healthy? (`/-/healthy`, `/ready`, the Alloy UI)
3. Can the collector reach the target? (`curl` from inside the same network namespace)
4. Is data arriving? (`/api/v1/targets` for Prometheus, `/loki/api/v1/labels` for Loki)
5. Is the query right? (test in Explore with the simplest possible query first)

Work top to bottom. Skipping to step 5 is why debugging takes hours instead of minutes.

---

## 18. Glossary

| Term | Meaning |
|---|---|
| **Agent / collector** | A small program on each machine that gathers telemetry and ships it onward (Alloy) |
| **Cardinality** | Number of unique label combinations; the main driver of cost and failure |
| **Chunk** | A compressed block of log lines in Loki |
| **Exporter** | A program that translates a system's internals into Prometheus metrics |
| **Instance / job** | Labels Prometheus adds: `instance` = host:port, `job` = group name |
| **PromQL / LogQL** | Query languages for Prometheus and Loki |
| **Relabeling** | Rewrite/keep/drop rules applied to labels before scraping or storing |
| **Remote write** | Prometheus pushing samples to another system |
| **Scrape** | One HTTP fetch of a `/metrics` page |
| **Series** | A unique metric name + label set over time |
| **ServiceMonitor** | A Kubernetes object telling the Prometheus Operator what to scrape |
| **Stream** | A unique label set in Loki; the log equivalent of a series |
| **TSDB** | Time-series database — the on-disk format Prometheus and Loki's index use |

---

## 19. Official documentation and references

**Prometheus**
- Docs home: <https://prometheus.io/docs/introduction/overview/>
- Getting started: <https://prometheus.io/docs/prometheus/latest/getting_started/>
- Configuration reference: <https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- PromQL basics: <https://prometheus.io/docs/prometheus/latest/querying/basics/>
- Alerting rules: <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Alertmanager: <https://prometheus.io/docs/alerting/latest/alertmanager/>
- Exporters list: <https://prometheus.io/docs/instrumenting/exporters/>
- Client libraries: <https://prometheus.io/docs/instrumenting/clientlibs/>
- Naming best practices: <https://prometheus.io/docs/practices/naming/>
- Release cycle / LTS: <https://prometheus.io/docs/introduction/release-cycle/>
- Migration to 3.x: <https://prometheus.io/docs/prometheus/latest/migration/>

**Loki**
- Docs home: <https://grafana.com/docs/loki/latest/>
- Get started: <https://grafana.com/docs/loki/latest/get-started/>
- Configuration reference: <https://grafana.com/docs/loki/latest/configure/>
- LogQL: <https://grafana.com/docs/loki/latest/query/>
- Helm install (community chart): <https://grafana.com/docs/loki/latest/setup/install/helm/>
- Storage / schema: <https://grafana.com/docs/loki/latest/operations/storage/>
- Retention: <https://grafana.com/docs/loki/latest/operations/storage/retention/>
- Best practices: <https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/>

**Grafana**
- Docs home: <https://grafana.com/docs/grafana/latest/>
- Data sources: <https://grafana.com/docs/grafana/latest/datasources/>
- Provisioning: <https://grafana.com/docs/grafana/latest/administration/provisioning/>
- Alerting: <https://grafana.com/docs/grafana/latest/alerting/>
- Dashboard library: <https://grafana.com/grafana/dashboards/>
- What's new: <https://grafana.com/docs/grafana/latest/whatsnew/>

**Grafana Alloy**
- Docs home: <https://grafana.com/docs/alloy/latest/>
- Components reference: <https://grafana.com/docs/alloy/latest/reference/components/>
- Migrate from Promtail: <https://grafana.com/docs/alloy/latest/set-up/migrate/from-promtail/>
- Promtail EOL notice: <https://grafana.com/docs/loki/latest/send-data/promtail/>

**Kubernetes / Helm**
- kube-prometheus-stack chart: <https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>
- Prometheus Operator API: <https://prometheus-operator.dev/docs/api-reference/api/>
- Loki community chart: <https://github.com/grafana-community/helm-charts/tree/main/charts/loki>
- Alloy chart: <https://github.com/grafana/alloy/tree/main/operations/helm/charts/alloy>

**AWS**
- Launch templates: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-launch-templates.html>
- EC2 user data: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html>
- IMDSv2: <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- EKS user guide: <https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html>
- EKS Pod Identity: <https://docs.aws.amazon.com/eks/latest/userguide/pod-identity.html>
- IRSA: <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
- EBS CSI driver: <https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html>
- Amazon Managed Prometheus: <https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-Prometheus.html>
- Amazon Managed Grafana: <https://docs.aws.amazon.com/grafana/latest/userguide/what-is-Amazon-Managed-Service-Grafana.html>

**Further reading**
- Google SRE Book, Monitoring chapter: <https://sre.google/sre-book/monitoring-distributed-systems/>
- OpenTelemetry: <https://opentelemetry.io/docs/>

---

## Appendix: one-page quick reference

```bash
# --- Docker lab ---
docker compose up -d
docker compose logs -f loki
docker compose down -v

# --- health ---
curl localhost:9090/-/healthy            # Prometheus
curl localhost:9090/api/v1/targets       # who is being scraped
curl localhost:3100/ready                # Loki
curl localhost:3100/loki/api/v1/labels   # Loki has data?
curl localhost:12345                     # Alloy UI

# --- validate before you deploy ---
promtool check config prometheus.yml
promtool check rules rules/*.yml
alloy fmt config.alloy
alloy validate config.alloy
helm template loki grafana-community/loki -f values-loki.yaml | less

# --- reload without restart ---
curl -XPOST localhost:9090/-/reload

# --- kubernetes ---
kubectl get pods -n monitoring
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=100
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

**Remember the three sentences that matter most:**
1. Metrics tell you *that* something broke; logs tell you *why*.
2. Labels are cheap only when they have few possible values — never put IDs in labels.
3. Pin your versions, keep config in Git, and never expose Prometheus or Loki to the internet.
