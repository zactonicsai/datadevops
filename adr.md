# ADR-001: Adopt Amazon EKS with Strimzi-Managed Kafka for Data Analytics, ETL, and Data Management Services

| | |
|---|---|
| **Status** | Proposed |
| **Date** | 2026-06-28 |
| **Owners** | Data Platform Engineering |
| **Deciders** | Platform Architecture Review Board |
| **Supersedes** | — |
| **Primary goals** | 99.999% availability • self-service access • low-friction upgrades & maintenance • cost efficiency |

## Context

We operate a growing portfolio of data services — batch and streaming ETL pipelines, analytics workloads, and data management/governance tooling — for internal data teams. These workloads share a common need for a durable, high-throughput event backbone (Kafka) and a flexible compute substrate that can scale independently per workload.

### Current pain points

- **Operational toil.** Self-managed Kafka on EC2 requires manual broker provisioning, rolling upgrades, partition rebalancing, and certificate rotation.
- **Inconsistent compute.** ETL jobs, stream processors, and analytics services run across mismatched VMs and ad-hoc orchestration, complicating resource isolation and cost attribution.
- **Scaling friction.** Spiky ETL and analytics demand is hard to serve cost-effectively on statically sized clusters.
- **Weak multi-tenancy.** No consistent model for isolating teams, enforcing quotas, or managing topic/ACL lifecycle as code.

### Common issues data teams hit (and that this design must address)

These are the recurring problems that derail data platforms in practice; the design sections below map directly back to them.

- **Schema drift and breaking changes.** Producers change payloads and silently break downstream consumers and tables. *(See: Schema Registry & contracts.)*
- **Unbalanced partitions / hot brokers.** Skewed keys or uneven partition assignment create hotspots, lag, and uneven disk use. *(See: Cruise Control, partitioning guidance.)*
- **Consumer lag and silent pipeline stalls.** Jobs fall behind or die without anyone noticing until data is stale. *(See: lag-based alerting and SLOs.)*
- **"Mystery" data and no lineage.** Nobody knows where a dataset came from, who owns it, or what feeds it. *(See: catalog & lineage.)*
- **Data quality regressions.** Bad/late/duplicate records propagate downstream unchecked. *(See: data-quality gates.)*
- **Onboarding friction.** New teams wait days for topics, credentials, and namespaces via manual tickets. *(See: self-service platform.)*
- **Stateful upgrade fear.** Teams avoid Kafka/K8s upgrades because they're risky and manual, accumulating version debt. *(See: upgrade strategy.)*
- **Cost surprises.** Unbounded retention, oversized clusters, idle dev environments, and no per-team attribution produce runaway bills. *(See: cost management.)*
- **Noisy neighbors.** One team's runaway job starves everyone else on shared infrastructure. *(See: tenancy & quotas.)*
- **Secrets sprawl and weak access control.** Long-lived static credentials in configs; unclear who can read what. *(See: security & access.)*

We need a platform that standardizes compute, makes Kafka operations declarative, supports many tenant teams safely, and is engineered to a five-nines availability target while remaining cost-disciplined and easy to operate.

## Decision

We will run our data services on **Amazon EKS** (managed Kubernetes) and operate Kafka on that cluster using the **Strimzi operator**, managing brokers, topics, users, and connectors declaratively through Kubernetes custom resources.

Concretely:

- **Compute:** Amazon EKS with managed node groups plus **Karpenter** for just-in-time autoscaling. Workloads are isolated by namespace per tenant/domain across **three Availability Zones**.
- **Event backbone:** Strimzi-managed Kafka in **KRaft mode** (no ZooKeeper), deployed in a dedicated `kafka` namespace with rack awareness across AZs and a minimum of 3 brokers / 3 controllers.
- **Streaming integration:** Strimzi `KafkaConnect` for source/sink connectors used by ETL pipelines; topic and access management via `KafkaTopic` and `KafkaUser` custom resources.
- **Schema governance:** A Schema Registry (Apicurio or Confluent-compatible) with enforced compatibility checks on every topic carrying structured data.
- **GitOps:** All cluster and Kafka resources are declared in Git and reconciled by **Argo CD**, giving auditable, reviewable, self-service-friendly change management.
- **Self-service:** A thin internal developer platform (Backstage templates + golden Helm charts) lets teams request topics, namespaces, and connectors via pull request, not tickets.

## Architecture Overview

### Layered View

| Layer | Component | Purpose |
|---|---|---|
| Self-service | Backstage + golden templates | Onboarding, topic/namespace/connector requests as PRs |
| Delivery | Argo CD + Helm | GitOps reconciliation and packaging |
| Compute | Amazon EKS + Karpenter | Elastic, multi-tenant Kubernetes substrate (3 AZs) |
| Event Backbone | Strimzi Kafka (KRaft) + Cruise Control | Durable, partitioned, self-balancing event streaming |
| Governance | Schema Registry, data catalog, lineage | Contracts, discoverability, lineage |
| Integration | Strimzi KafkaConnect | Connectors for ETL ingest/egress |
| Processing | Spark/Flink on K8s, custom services | Batch + stream ETL and analytics |
| Storage | Amazon S3, RDS/Redshift, EBS gp3 | Lake, warehouse, and stateful volumes |
| Observability | Prometheus, Grafana, Alertmanager, OpenTelemetry, Loki | Metrics, dashboards, tracing, logs, alerting |
| Security | IRSA, External Secrets, OPA/Kyverno, cert-manager | Identity, secrets, policy, TLS |

### Data Flow

1. Source systems publish to Kafka topics (directly or via KafkaConnect source connectors), with payloads validated against the Schema Registry.
2. Stream processors (Flink/Kafka Streams) and batch jobs (Spark) consume topics for transformation and enrichment.
3. Processed data lands in S3 (lake), Redshift/RDS (warehouse), or is republished to downstream topics.
4. Analytics and data management services read from the lake/warehouse and from Kafka for real-time use cases.
5. Sink connectors move curated data to external destinations as needed.
6. Every stage emits metrics, logs, and lineage events to the observability and catalog layers.

## Availability: Engineering for Five Nines (99.999%)

Five nines is **~5.26 minutes of allowed downtime per year** (~26 seconds/month). This is an aggressive target and is only meaningful when defined per service with explicit SLOs and error budgets — a blanket "the platform is 5 nines" claim is not.

### Availability budget reference

| Target | Downtime/year | Downtime/month | Realistic scope |
|---|---|---|---|
| 99.9% (three nines) | 8.77 h | 43.8 min | Dev/internal tooling |
| 99.95% | 4.38 h | 21.9 min | Standard production services |
| 99.99% (four nines) | 52.6 min | 4.38 min | Core pipelines |
| **99.999% (five nines)** | **5.26 min** | **26.3 sec** | Critical real-time backbone only |

**Recommendation:** Apply the 99.999% target to the **Kafka event backbone and ingest path** specifically, and set tiered SLOs (99.9–99.99%) for downstream batch/analytics services where minutes of recovery are acceptable. Chasing five nines uniformly across batch ETL is rarely cost-justified.

### What five nines requires here

- **No single point of failure.** Minimum 3 brokers and 3 KRaft controllers spread across 3 AZs with Strimzi rack awareness (`broker.rack` per AZ).
- **Replication and durability.** Topic replication factor **3**, `min.insync.replicas=2`, producer `acks=all`. This survives a full AZ loss with no data loss and no write outage.
- **Pod Disruption Budgets.** PDBs on brokers (`maxUnavailable: 1`) so voluntary disruptions (node drains, upgrades) never take quorum below tolerance.
- **Spread constraints.** `topologySpreadConstraints` and anti-affinity ensure no two brokers share a node or AZ.
- **Control-plane resilience.** EKS managed control plane is multi-AZ by AWS design; we run critical add-ons (CoreDNS, Strimzi operator) with multiple replicas and PDBs.
- **Graceful client behavior.** Producers/consumers configured with sensible retries, idempotent producers, and backoff so transient broker rotation is invisible to applications.
- **Multi-region posture (tiered).** For the critical backbone, asynchronous replication to a second region via **MirrorMaker 2** (Strimzi `KafkaMirrorMaker2`) for disaster recovery, with documented RTO/RPO. (See DR table below.) True active/active multi-region is a later phase if business need justifies the cost and complexity.

### Disaster recovery objectives

| Scenario | Mechanism | Target RPO | Target RTO |
|---|---|---|---|
| Single broker/node failure | In-cluster replication + self-healing | 0 | Seconds (transparent) |
| Single AZ failure | 3-AZ replication, `min.insync.replicas=2` | 0 | Seconds to minutes |
| Cluster/namespace corruption | GitOps redeploy + PV restore | Minutes | < 1 hour |
| Full region failure | MirrorMaker 2 to standby region | Seconds–minutes (async) | < 1 hour (manual promote) |

> **Honest caveat:** AWS publishes EKS uptime SLAs at 99.9% for the control plane. Achieving *application-observed* five nines depends far more on our replication, client tuning, and operational discipline than on any single AWS SLA. Five nines should be validated empirically (via measured SLO attainment and game-day testing), not assumed from architecture alone.

## Operational Support Tasks: What We Automate and Improve

A core goal is to convert manual, error-prone support tasks into automated, self-healing, or self-service workflows. The table maps each task to its current burden and the target implementation.

| Support task | Today (typical) | Target implementation |
|---|---|---|
| Topic creation | Manual ticket → ops runs CLI | `KafkaTopic` CR via PR; Argo CD reconciles |
| User/ACL provisioning | Manual, inconsistent | `KafkaUser` CR with declarative ACLs; IRSA for AWS |
| Partition rebalancing | Manual, risky | **Cruise Control** auto-rebalancing with goals |
| Broker scaling | Manual capacity planning | Strimzi scale + Cruise Control rebalance; Karpenter for nodes |
| Certificate rotation | Manual, easy to forget | Strimzi auto-renews internal TLS; cert-manager for external |
| Kafka/K8s upgrades | Feared, manual, downtime-prone | Staged GitOps rollout + rolling updates (see Upgrades) |
| Secret rotation | Static creds in configs | **External Secrets Operator** + AWS Secrets Manager |
| Consumer lag monitoring | Ad hoc / none | Prometheus + Kafka exporter, lag SLO alerts |
| Capacity/cost review | Spreadsheet, after the fact | Kubecost dashboards + monthly FinOps review |
| Incident response | Tribal knowledge | Runbooks + alert-linked playbooks, on-call rotation |
| Schema changes | Uncontrolled | Registry compatibility gate in CI |
| Data quality checks | Manual / downstream discovery | Great Expectations / dbt tests in pipeline |
| Dead-letter handling | Lost messages | Standard DLQ topics + replay tooling |
| Backup/restore drills | Rarely tested | Scheduled game-days; PV snapshots + Git restore |

### Observability baseline (so nothing is "mystery downtime")

- **Metrics:** Prometheus scrapes Kafka (via JMX/Kafka exporter), KafkaConnect, JVM, node, and app metrics; Grafana dashboards per tenant and platform-wide.
- **Golden signals + Kafka-specific SLIs:** under-replicated partitions, offline partitions, request latency, consumer-group lag, broker disk %, controller health.
- **Logs:** centralized via Loki (or CloudWatch/OpenSearch) with structured logging.
- **Tracing:** OpenTelemetry across producers, processors, and sinks for end-to-end pipeline latency.
- **Alerting:** Alertmanager routes by severity and tenant; every alert links to a runbook. Page only on user-impacting, actionable conditions to avoid fatigue.
- **SLO tracking:** error budgets per service; burn-rate alerts drive whether to ship features or harden.

## Self-Service Access, Onboarding, and Easy Maintenance

The goal is "PR, not ticket" — teams move fast without ops becoming a bottleneck, while everything stays governed and auditable.

- **Golden paths.** Backstage software templates scaffold a new pipeline/service with sane defaults (namespace, quotas, dashboards, alerts, CI checks) pre-wired.
- **Declarative requests.** Topics (`KafkaTopic`), access (`KafkaUser`), connectors (`KafkaConnector`), and namespaces are requested by committing CRs; Argo CD applies them after review.
- **Policy as guardrails, not gates.** OPA Gatekeeper/Kyverno enforce naming, replication-factor minimums, resource limits, and labels automatically — teams can't accidentally create an unsafe topic.
- **Self-service observability.** Each new service automatically gets a Grafana dashboard and default alerts from templates.
- **Read access & discovery.** A data catalog (DataHub/OpenMetadata or AWS Glue + Amazon DataZone) makes datasets, owners, schemas, and lineage searchable, cutting "where does this come from?" investigations.
- **Easy local/dev access.** Scoped, short-lived credentials via IRSA and SSO; no shared long-lived secrets.

## Upgrades, Patching, and Maintenance Strategy

Designed so upgrades are routine and low-risk, eliminating the "version debt" that builds when teams fear upgrading.

- **Promotion pipeline.** Every change flows **dev → staging → prod** through Git; staging mirrors prod and runs soak tests before promotion.
- **Zero/low-downtime Kafka upgrades.** Strimzi performs **rolling broker updates** honoring PDBs and partition replication, so the cluster stays available throughout. KRaft removes the ZooKeeper-coordination step that historically complicated upgrades.
- **EKS version management.** Stay within AWS-supported Kubernetes versions; upgrade control plane then node groups. Karpenter-managed nodes roll via drift detection and node recycling with disruption budgets.
- **Add-on lifecycle.** Operators and add-ons (Strimzi, cert-manager, External Secrets, Karpenter) pinned to versions in Git and bumped deliberately with changelog review.
- **Automated dependency hygiene.** Renovate/Dependabot raises PRs for chart and image bumps; CI validates before merge.
- **Immutable, reproducible infra.** Terraform/OpenTofu for AWS resources; no click-ops. Cluster can be rebuilt from code.
- **Maintenance windows where needed.** Strimzi `maintenanceTimeWindows` confine certificate renewals and disruptive operations to defined low-traffic periods.
- **Backups.** PV snapshots (EBS) and optional topic-data tiering to S3; Git holds all declarative state, so recovery is redeploy + restore.

## Cost Management & FinOps

Addresses the "cost surprise" failure mode with continuous visibility and structural controls.

### Visibility

- **Per-tenant attribution.** Kubecost (or OpenCost) attributes compute, memory, and storage cost by namespace/team via labels; surfaced in Grafana.
- **AWS-side tagging.** Mandatory cost-allocation tags on all resources (team, environment, service) enforced by policy.
- **Monthly FinOps review.** Platform + finance review trends, anomalies, and rightsizing opportunities.

### Structural controls

- **Karpenter consolidation.** Continuously bin-packs and consolidates nodes, terminating underutilized capacity automatically.
- **Spot for interruptible work.** ETL/analytics batch and stream processing run on Spot with diversified instance pools; brokers and stateful pods stay on On-Demand/Reserved.
- **Savings Plans / Reserved capacity.** Cover the steady-state baseline (brokers, core nodes) with commitments; burst on Spot/On-Demand.
- **Storage discipline.**
  - Enforce **finite topic retention** by policy (no accidental infinite retention).
  - Use **tiered storage** to offload cold Kafka segments to S3, shrinking expensive broker EBS.
  - `gp3` volumes with right-sized IOPS/throughput instead of `gp2`.
  - S3 lifecycle policies (Standard → IA → Glacier) for lake data.
- **Right-sizing.** Requests/limits tuned from real usage (VPA in recommendation mode); quotas prevent over-allocation.
- **Kill idle environments.** Auto-scale dev/staging to zero off-hours; TTL on ephemeral preview environments.
- **Egress awareness.** Co-locate chatty producers/consumers and brokers in the same AZ where possible to reduce cross-AZ data-transfer charges (a frequently overlooked Kafka cost).

> **Tension to manage explicitly:** five-nines (3-AZ replication, On-Demand brokers, cross-region DR) *increases* cost, while FinOps pushes the other way. Resolve this by **tiering**: pay for high availability only on the critical backbone, and apply aggressive cost controls (Spot, scale-to-zero, shorter retention) to everything else.

## Tenancy & Access Model

- **Namespace per team/domain**, with `ResourceQuota` and `LimitRange` to cap CPU, memory, and storage — preventing noisy-neighbor starvation.
- **Kafka multi-tenancy** via naming conventions (`<domain>.<dataset>`), per-tenant `KafkaUser` ACLs, and per-client/topic **quotas** (throughput and connection limits).
- **RBAC** mapped to IdP groups via IRSA (IAM Roles for Service Accounts) for AWS access and Kubernetes RBAC for cluster access.
- **NetworkPolicies** restrict cross-namespace traffic; only approved namespaces may reach the Kafka listeners.
- **Secrets** delivered by External Secrets Operator from AWS Secrets Manager — no static credentials in manifests.

## Key Design Decisions

- **KRaft over ZooKeeper** — fewer moving parts, simpler/safer upgrades, lower-latency metadata. ZooKeeper mode is deprecated in current Kafka.
- **Karpenter over Cluster Autoscaler** — faster, bin-packed scaling and automatic consolidation; strong fit for bursty ETL/analytics and Spot.
- **Spot for stateless processing, On-Demand/Reserved for brokers** — stateful pods get stability; interruptible jobs get cost savings.
- **gp3 + tiered storage** — decouple IOPS from size and push cold data to S3 to control the largest Kafka cost driver.
- **Cruise Control for balancing** — automates the historically manual, risky partition-rebalancing task.
- **Schema Registry as a hard gate** — prevents the single most common cause of broken pipelines (schema drift).
- **GitOps as the only change path** — no imperative production changes; everything reviewable, auditable, and reversible.
- **Tiered availability targets** — five nines reserved for the critical backbone; pragmatic SLOs elsewhere.

## Consequences

### Positive

- Declarative, version-controlled Kafka and infrastructure; reproducible, auditable, and self-service-friendly.
- Independent, elastic scaling per workload with strong cost attribution by namespace.
- Dramatically reduced Kafka operational toil (auto rebalancing, rolling upgrades, cert/secret rotation, self-healing).
- Consistent multi-tenant isolation, quotas, and security posture across all data services.
- Schema, catalog, and lineage tooling directly attack the data-quality and discoverability problems teams face.
- Portable, cloud-agnostic workload definitions reduce application-layer lock-in.

### Negative / Costs

- **Kubernetes + Strimzi expertise required** — non-trivial learning curve; debugging may span operator and raw Kafka internals.
- **Stateful workloads on K8s add complexity** — broker storage, PV lifecycle, and DR demand care and rehearsal.
- **Five-nines engineering is expensive** — multi-AZ/multi-region redundancy, On-Demand brokers, and game-day discipline carry real cost and effort.
- **More moving parts** — registry, catalog, FinOps tooling, and policy engines each add operational surface.
- **Initial migration effort** — moving existing pipelines and topics onto the platform is significant.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Broker data loss on node/AZ failure | RF=3, `min.insync.replicas=2`, `acks=all`, rack awareness, EBS-backed PVs |
| Spot interruption disrupting brokers | Brokers on On-Demand/Reserved; only stateless jobs on Spot |
| Noisy-neighbor tenants | ResourceQuotas, Kafka client quotas, NetworkPolicies |
| Cluster/Kafka upgrade regressions | Staged rollout, Strimzi rolling updates honoring PDBs, soak tests |
| Schema drift breaking consumers | Registry compatibility checks enforced in CI |
| Unbalanced partitions / hot brokers | Cruise Control rebalancing with goals; partition-count guidance |
| Silent consumer lag | Lag SLOs with burn-rate alerts; DLQ + replay tooling |
| Cost overruns | Kubecost attribution, retention limits, tiered storage, Spot, scale-to-zero, monthly review |
| Secret leakage | External Secrets + Secrets Manager; no static creds; short-lived tokens |
| Five-nines claim unproven | Measure SLO attainment; quarterly DR/chaos game-days |
| Skills gap | Runbooks, golden templates, on-call training, platform support rotation |

## Alternatives Considered

- **Amazon MSK (managed Kafka).** Lower Kafka ops burden and integrated AWS SLAs, but less control over versions/configs, a separate operational plane from compute, and weaker fit with our unified GitOps model. Strong contender specifically for the five-nines backbone; we may adopt MSK for the most critical topics if self-operated Strimzi proves too costly to run at five nines. Rejected as the *default* in favor of K8s-native uniformity, with a documented option to revisit.
- **Self-managed Kafka on EC2.** Maximum control, maximum toil; does not address the operational pain points. Rejected.
- **ECS/Fargate for compute.** Simpler than EKS but weaker data-workload ecosystem (Spark/Flink/Strimzi operators) and less flexible scheduling. Rejected.
- **Confluent Cloud / Platform.** Rich features (registry, connectors, balancing, tiered storage out of the box) and can hit high availability, but higher cost and stronger vendor lock-in. Rejected for the core backbone; some managed pieces (e.g., registry) may be adopted pragmatically.
- **Uniform five-nines everywhere.** Rejected as not cost-justified; replaced with tiered SLOs.

## Open Questions

- Which specific services genuinely require five nines vs. four nines or 99.9%? (Drives cost.)
- Build vs. buy for Schema Registry and data catalog (Apicurio/DataHub self-hosted vs. Confluent/AWS managed)?
- Is cross-region DR required at launch, or a fast-follow once the single-region platform is proven?
- What is the realistic team headcount and on-call maturity to operate this at the target SLO?

## References

- Strimzi documentation and Kafka custom resource APIs
- Apache Kafka KRaft mode and replication/durability documentation
- Amazon EKS Best Practices Guide and EKS SLA
- Karpenter documentation
- Cruise Control for Apache Kafka
- AWS Well-Architected Framework (Reliability & Cost Optimization pillars)
- External Secrets Operator; OPA Gatekeeper / Kyverno

---

*This ADR is a living decision record. Material changes should be proposed as a new ADR that supersedes this one. Availability targets must be validated empirically through measured SLO attainment and regular game-day exercises rather than assumed from this design.*
