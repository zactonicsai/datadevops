# ADR-001: Adopt Amazon EKS with Strimzi-Managed Kafka for Data Analytics, ETL, and Data Management Services

| | |
|---|---|
| **Status** | Proposed |
| **Date** | 2026-06-28 |
| **Owners** | Data Platform Engineering |
| **Deciders** | Platform Architecture Review Board |
| **Supersedes** | — |

## Context

We operate a growing portfolio of data services — batch and streaming ETL pipelines, analytics workloads, and data management/governance tooling — for internal data teams. These workloads share a common need for a durable, high-throughput event backbone (Kafka) and a flexible compute substrate that can scale independently per workload.

Current pain points:

- **Operational toil.** Self-managed Kafka on EC2 requires manual broker provisioning, rolling upgrades, partition rebalancing, and certificate rotation.
- **Inconsistent compute.** ETL jobs, stream processors, and analytics services run across mismatched VMs and ad-hoc orchestration, complicating resource isolation and cost attribution.
- **Scaling friction.** Spiky ETL and analytics demand is hard to serve cost-effectively on statically sized clusters.
- **Weak multi-tenancy.** No consistent model for isolating teams, enforcing quotas, or managing topic/ACL lifecycle as code.

We need a platform that standardizes compute, makes Kafka operations declarative, and supports many tenant teams safely.

## Decision

We will run our data services on **Amazon EKS** (managed Kubernetes) and operate Kafka on that cluster using the **Strimzi operator**, managing brokers, topics, users, and connectors declaratively through Kubernetes custom resources.

Concretely:

- **Compute:** Amazon EKS with managed node groups plus **Karpenter** for just-in-time autoscaling. Workloads are isolated by namespace per tenant/domain.
- **Event backbone:** Strimzi-managed Kafka in **KRaft mode** (no ZooKeeper), deployed in a dedicated `kafka` namespace with rack awareness across Availability Zones.
- **Streaming integration:** Strimzi `KafkaConnect` for source/sink connectors used by ETL pipelines; topic and access management via `KafkaTopic` and `KafkaUser` custom resources.
- **GitOps:** All cluster and Kafka resources are declared in Git and reconciled by **Argo CD**, giving auditable, reviewable changes.

## Architecture Overview

### Layered View

| Layer | Component | Purpose |
|---|---|---|
| Compute | Amazon EKS + Karpenter | Elastic, multi-tenant Kubernetes substrate |
| Event Backbone | Strimzi Kafka (KRaft) | Durable, partitioned event streaming |
| Integration | Strimzi KafkaConnect | Connectors for ETL ingest/egress |
| Processing | Spark/Flink on K8s, custom services | Batch + stream ETL and analytics |
| Storage | Amazon S3, RDS/Redshift, EBS gp3 | Lake, warehouse, and stateful volumes |
| Delivery | Argo CD + Helm | GitOps reconciliation and packaging |
| Observability | Prometheus, Grafana, OpenTelemetry | Metrics, dashboards, tracing |

### Data Flow

1. Source systems publish to Kafka topics (directly or via KafkaConnect source connectors).
2. Stream processors (Flink/Kafka Streams) and batch jobs (Spark) consume topics for transformation and enrichment.
3. Processed data lands in S3 (lake), Redshift/RDS (warehouse), or is republished to downstream topics.
4. Analytics and data management services read from the lake/warehouse and from Kafka for real-time use cases.
5. Sink connectors move curated data to external destinations as needed.

## Tenancy & Access Model

- **Namespace per team/domain**, with `ResourceQuota` and `LimitRange` to cap CPU, memory, and storage.
- **Kafka multi-tenancy** via naming conventions (`<domain>.<dataset>`), per-tenant `KafkaUser` ACLs, and per-topic quotas.
- **RBAC** mapped to IdP groups via IRSA (IAM Roles for Service Accounts) for AWS access and Kubernetes RBAC for cluster access.
- **NetworkPolicies** restrict cross-namespace traffic; only approved namespaces may reach the Kafka listeners.

## Key Design Decisions

- **KRaft over ZooKeeper** — fewer moving parts, simpler upgrades, lower latency for metadata operations. ZooKeeper is deprecated in current Kafka.
- **Karpenter over Cluster Autoscaler** — faster, bin-packed scaling well-suited to bursty ETL/analytics; supports spot capacity for cost savings.
- **Spot for stateless processing, on-demand for brokers** — Kafka brokers and other stateful pods run on on-demand nodes with dedicated node pools; ETL/analytics jobs tolerate spot interruption.
- **gp3 EBS for broker storage** — provisioned IOPS/throughput decoupled from volume size; lower cost than gp2 at scale.
- **GitOps as the only change path** — no imperative `kubectl apply` in production; everything reconciled from Git.

## Consequences

### Positive

- Declarative, version-controlled Kafka and infrastructure; reproducible and auditable.
- Independent, elastic scaling per workload with strong cost attribution by namespace.
- Reduced Kafka operational toil (automated rolling upgrades, rebalancing via Cruise Control, cert rotation by the operator).
- Consistent multi-tenant isolation, quotas, and security posture across all data services.
- Portable, cloud-agnostic workload definitions (Kubernetes/Strimzi) reduce lock-in at the application layer.

### Negative / Costs

- **Kubernetes operational expertise required** — the team must be fluent in EKS, Strimzi CRDs, and GitOps.
- **Stateful workloads on K8s add complexity** — broker storage, PV lifecycle, and disaster recovery require care.
- **Operator abstraction risk** — debugging sometimes requires understanding both Strimzi and raw Kafka internals.
- **Initial migration effort** — moving existing pipelines and topics onto the platform is non-trivial.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Broker data loss on node failure | Replication factor ≥ 3, rack awareness across AZs, EBS-backed PVs, regular topic-config audits |
| Spot interruption disrupting brokers | Brokers pinned to on-demand node pools; only stateless jobs on spot |
| Noisy-neighbor tenants | ResourceQuotas, Kafka client quotas, NetworkPolicies |
| Cluster/Kafka upgrade regressions | Staged rollout (dev → staging → prod), Strimzi rolling updates, pre-prod soak tests |
| Skills gap | Runbooks, on-call training, and a platform support rotation |

## Alternatives Considered

- **Amazon MSK (managed Kafka).** Lower Kafka ops burden but less control over versions/configs, weaker fit with our GitOps model, and separate operational plane from compute. Rejected in favor of unified K8s-native management; may revisit for specific high-SLA topics.
- **Self-managed Kafka on EC2.** Maximum control, maximum toil. Rejected — does not address the operational pain points.
- **ECS/Fargate for compute.** Simpler than EKS but weaker ecosystem for data workloads (Spark/Flink operators, Strimzi) and less flexible scheduling. Rejected.
- **Confluent Cloud / Platform.** Rich feature set but higher cost and vendor lock-in; overlaps with capabilities we can self-operate via Strimzi. Rejected for the core backbone.

## References

- Strimzi documentation and Kafka custom resource APIs
- Amazon EKS Best Practices Guide
- Karpenter documentation
- Apache Kafka KRaft mode documentation

---

*This ADR is a living decision record. Material changes should be proposed as a new ADR that supersedes this one.*
