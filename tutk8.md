# Kubernetes Enterprise Training: Stateful Workloads (Kafka, Keycloak, OpenSearch, NiFi)

## Module 1: Kubernetes Foundations for Enterprise Clusters
- Cluster architecture: control plane HA, etcd sizing, multi-master topology
- Node pools and workload isolation (system, stateful, compute pools)
- Namespaces, resource quotas, and limit ranges per tenant/app
- RBAC design and service account strategy
- Cluster sizing and capacity planning for stateful workloads

## Module 2: Storage for Stateful Workloads
- StorageClasses, CSI drivers, and dynamic provisioning
- PersistentVolume/PersistentVolumeClaim lifecycle and reclaim policies
- StatefulSets vs Deployments: when and why
- Volume expansion, snapshots, and storage performance tiers (IOPS/throughput)
- Local vs network-attached storage tradeoffs for Kafka and OpenSearch

## Module 3: Networking & Service Exposure
- CNI selection and network policy enforcement
- Service types, headless services for StatefulSets, and DNS
- Ingress controllers, load balancers, and external traffic
- mTLS, service mesh overview (Istio/Linkerd) for inter-service security
- Cross-AZ/region networking and latency considerations

## Module 4: Security & Compliance Baseline
- Pod Security Standards and admission control (OPA/Gatekeeper, Kyverno)
- Secrets management (external secrets, Vault integration, encryption at rest)
- Image scanning, signing, and trusted registries
- Network segmentation and zero-trust principles
- Audit logging and compliance reporting

## Module 5: Operators & Lifecycle Management
- Operator pattern fundamentals and the Operator Lifecycle Manager
- Helm vs Operators vs raw manifests: selection criteria
- GitOps workflows (ArgoCD/Flux) for declarative deployments
- Upgrade strategies and rollback procedures

## Module 6: Kafka on Kubernetes
- Deploying with Strimzi operator: brokers, KRaft/ZooKeeper, topics
- Storage layout, partition placement, and rack awareness
- Listeners, authentication (SASL/mTLS), and authorization (ACLs)
- Scaling brokers, rebalancing (Cruise Control), and rolling updates
- Monitoring lag, throughput, and broker health; disaster recovery

## Module 7: Keycloak on Kubernetes
- Deploying with the Keycloak operator in HA mode
- External database configuration and connection pooling
- Realm/client management as code and import/export strategy
- High availability, caching (Infinispan), and session replication
- TLS, reverse proxy setup, and integration with cluster RBAC/OIDC

## Module 8: OpenSearch on Kubernetes
- Deploying with the OpenSearch operator: master, data, coordinating nodes
- Shard/replica strategy, index lifecycle management (ISM)
- Resource tuning: heap, JVM, and node roles
- Security plugin: users, roles, TLS, and fine-grained access control
- Snapshot/restore, cluster scaling, and hot-warm-cold architecture

## Module 9: NiFi on Kubernetes
- Deploying NiFi clusters (NiFiKop operator) and state management
- Flow versioning with NiFi Registry and promotion across environments
- Securing NiFi: TLS, authentication via Keycloak/OIDC, policies
- Scaling, load distribution, and back-pressure handling
- Integrating NiFi with Kafka and OpenSearch in data pipelines

## Module 10: Observability
- Metrics stack (Prometheus, Grafana) and per-workload dashboards
- Centralized logging (Fluent Bit/Fluentd → OpenSearch/Loki)
- Distributed tracing fundamentals
- Alerting strategy, SLOs/SLIs, and on-call runbooks
- Resource utilization analysis and right-sizing

## Module 11: Reliability, Backup & Disaster Recovery
- Backup strategies per workload (Velero, app-native snapshots)
- Multi-AZ and multi-region resilience patterns
- PodDisruptionBudgets, affinity/anti-affinity, and topology spread
- DR testing, RTO/RPO definition, and restore drills
- Chaos engineering basics

## Module 12: Operations, Maintenance & Cost
- Cluster and node upgrade procedures (zero-downtime)
- Autoscaling: HPA, VPA, and Cluster Autoscaler tuning
- Capacity reviews, resource governance, and cost optimization (FinOps)
- Incident response, troubleshooting playbooks, and escalation paths
- Documentation standards and team handoff practices

## Module 13: Capstone
- End-to-end deployment of all four workloads on a hardened cluster
- Build a data pipeline: NiFi → Kafka → OpenSearch, secured by Keycloak
- Simulate failures, perform recovery, and execute an upgrade cycle

tted course document (with durations, labs, and prerequisites per module), or adjust the depth/scope for a specific audience or timeframe?