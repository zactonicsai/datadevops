## The stack, component by component

Grafana Labs calls it **LGTM + Grafana**: each piece handles one telemetry signal, all query-able from one UI.

- **Grafana** — the visualization and alerting layer. Dashboards, unified alerting, plugin-based datasources (~150+, including most AWS services). It stores no telemetry itself; it's a query federator.
- **Mimir** — horizontally scalable, long-term Prometheus-compatible metrics store. Object-storage backed (S3), multi-tenant, handles high-cardinality far better than vanilla Prometheus.
- **Loki** — log aggregation. Indexes only labels, not log content, and dumps compressed chunks to S3. Cheap by design; queried with LogQL, which mirrors PromQL.
- **Tempo** — distributed tracing backend. Accepts OTLP, Jaeger, Zipkin. Also S3-backed, with no index on span content — you find traces by ID or by TraceQL, or by jumping from a metric/log.
- **Pyroscope** — continuous profiling (CPU, memory, goroutines) correlated to the same time ranges.
- **Alloy** — the collector, and the piece most people get wrong. It's Grafana's OpenTelemetry Collector distribution (it superseded Grafana Agent) and can scrape Prometheus targets, tail logs, receive OTLP, and remote-write to any of the above.
- **Faro** (browser RUM), **Beyla** (eBPF auto-instrumentation, zero code change), **k6** (load testing) round it out.

The glue that makes it a *stack* rather than four products is correlation: **exemplars** attach trace IDs to metric samples, Loki's `derived fields` extract trace IDs from log lines, and Tempo's span metrics generate RED metrics from traces. One click takes you latency spike → exact trace → the pod's logs → a flame graph.

## Three ways to run it on AWS

**1. Fully self-managed on EKS.** Helm charts (`kube-prometheus-stack`, `loki`, `tempo-distributed`, `mimir-distributed`, `alloy`) with S3 for all chunk/block storage. Cheapest at scale, most operational burden — you own compaction, retention, ingester rollouts, and quorum.

**2. AWS-managed.** *Amazon Managed Service for Prometheus (AMP)* is Cortex/Mimir-derived and takes `remote_write` with SigV4. *Amazon Managed Grafana (AMG)* is Grafana Enterprise-flavored, priced per active user, integrated with IAM Identity Center/SAML. There's no AWS-managed Loki or Tempo — logs typically fall back to CloudWatch and traces to X-Ray, which is the main gap in this option.

**3. Grafana Cloud (SaaS)**, reachable over PrivateLink, with an out-of-the-box AWS integration that pulls CloudWatch metrics via the CloudWatch API or Kinesis Firehose metric streams.

In practice, hybrids dominate: AMP for metrics, self-hosted Loki on S3 for logs (CloudWatch Logs ingest at ~$0.50/GB gets brutal fast), Tempo or X-Ray for traces, AMG on top.

## What this looks like on EKS specifically

**Collection.** Alloy or ADOT runs as a DaemonSet for node-level signals (kubelet/cAdvisor, node-exporter, container stdout from `/var/log/pods`) plus a Deployment for cluster-scoped scrapes (kube-state-metrics, API server, scheduler, controller-manager, CoreDNS). Apps emit OTLP to a local Alloy endpoint.

**Identity.** This is the part that trips people up. Writing to S3 or AMP needs **EKS Pod Identity** (or IRSA) — a service account annotated with an IAM role, and SigV4 signing enabled in the remote-write config. Same on the read side: AMG uses a service-managed IAM role to query AMP, CloudWatch, X-Ray, and Athena.

**Fargate caveat.** DaemonSets don't run on Fargate. You either sidecar the collector into each pod or use the built-in Fluent Bit log router. Worth knowing before you design the topology.

**Cross-account.** A single AMG workspace can assume roles into many accounts, or you layer it over CloudWatch cross-account observability with a monitoring account. For metrics, an AMP workspace per region with Grafana federating queries is typical.

## Concrete use cases

- **Cluster health and capacity.** Node pressure, pod restarts, pending pods, PV usage, Karpenter provisioning latency and consolidation events. The classic reason to run Prometheus on EKS at all.
- **Golden-signal app dashboards with drill-down.** Rate/errors/duration per service, then exemplar → trace → logs. Cuts MTTR far more than any single-signal setup.
- **Cost observability.** OpenCost or Kubecost exporting Prometheus metrics gives per-namespace/per-team EKS spend. Pair with the AWS **Cost and Usage Report in S3, queried through Athena** as a Grafana datasource, and you get cluster cost next to account-wide spend on one dashboard.
- **Log cost reduction.** Route application logs to Loki on S3 instead of CloudWatch Logs; keep CloudWatch only for control-plane audit logs (or ship those to Loki too, for `kubectl`-level audit search).
- **Hybrid traces across serverless boundaries.** A request hits ALB → EKS service → SQS → Lambda. OTel instrumentation everywhere lets Tempo show the whole path; if you're on X-Ray instead, Grafana's X-Ray datasource renders the same service map.
- **Managed-service infrastructure panels.** RDS/Aurora, MSK, ElastiCache, DynamoDB, ALB, NAT Gateway — all via the CloudWatch datasource, sitting alongside your Kubernetes metrics so you can see "pod latency spiked *because* the Aurora writer hit CPU."
- **SLOs and alerting.** Grafana Alerting evaluates multi-datasource queries (a rule can span AMP + CloudWatch), routes to SNS, PagerDuty, Slack, or AWS Incident Manager. Error-budget burn-rate alerts are the standard pattern.
- **Load testing in CI.** k6 in a pipeline writing results to Prometheus, overlaid on the same dashboards used in prod — makes regressions visible before deploy.

## Tradeoffs worth weighing up front

AMP bills per sample ingested and per query sample processed, so cardinality discipline (drop unused labels at the collector) is a real cost lever, not hygiene. AMG bills per active user per month, which gets expensive if you want read-only dashboards for a large org — self-hosted Grafana OSS with Cognito OIDC is often cheaper there. And self-hosted Mimir/Loki/Tempo are genuinely distributed systems: budget for someone who understands ingesters, compactors, and ring topology, or take the managed option.

Since AWS and Grafana both ship changes here frequently, verify current pricing and component support against the docs before committing to an architecture.