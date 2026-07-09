# AWS EKS Best Practices: Scheduled Pod Shutdown/Startup with Dependency Ordering

A practical guide for turning workloads off and on at scheduled times (e.g., dev/test environments overnight and on weekends), tracking ownership with tags/labels, and handling startup dependencies for stateful data services like Kafka, NiFi, and OpenSearch.

---

## 1. Why Schedule Pods Off/On

| Benefit | Detail |
|---|---|
| Cost savings | Non-prod clusters often idle 65%+ of the week (nights + weekends). Scaling to zero lets Karpenter/Cluster Autoscaler remove nodes. |
| Reduced blast radius | Fewer running workloads = fewer patching/security concerns off-hours. |
| Forcing function for resilience | Regular restarts expose hidden startup bugs, bad readiness probes, and undeclared dependencies. |

**Key principle:** In Kubernetes you don't "stop" pods directly — you scale the controller (Deployment/StatefulSet) replicas to `0`, and rely on the node autoscaler to reclaim compute.

---

## 2. Core Approaches to Scheduled Scaling

### Option A: KEDA Cron Scaler (Recommended)

[KEDA](https://keda.sh/) is a CNCF-graduated autoscaler that supports cron-based schedules and can scale workloads to zero.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: nifi-business-hours
  namespace: data-platform
spec:
  scaleTargetRef:
    kind: StatefulSet
    name: nifi
  minReplicaCount: 0          # scale to zero outside the window
  cooldownPeriod: 300
  triggers:
    - type: cron
      metadata:
        timezone: America/New_York
        start: "0 7 * * 1-5"   # 7:00 AM Mon–Fri: scale up
        end: "0 19 * * 1-5"    # 7:00 PM Mon–Fri: scale down
        desiredReplicas: "3"
```

**Pros:** Declarative, GitOps-friendly, timezone-aware, combines with other scalers (CPU, queue depth).
**Cons:** Another operator to run; StatefulSet support requires care with PVCs (see §6).

### Option B: kube-downscaler / GoDaddy Kubernetes Downscaler

Annotation-driven downscaling of Deployments/StatefulSets on a schedule:

```yaml
metadata:
  annotations:
    downscaler/uptime: "Mon-Fri 07:00-19:00 America/New_York"
    # or exclude a workload entirely:
    downscaler/exclude: "true"
```

**Pros:** Very low effort — teams opt in via annotations, no per-workload CRDs.
**Cons:** No native dependency ordering; project maintenance varies (check the fork you use).

### Option C: Native CronJobs + kubectl scale

A CronJob running a small container with RBAC to patch replicas:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: scale-down-evening
  namespace: data-platform
spec:
  schedule: "0 19 * * 1-5"
  timeZone: "America/New_York"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: scheduler-sa
          restartPolicy: Never
          containers:
            - name: scaler
              image: bitnami/kubectl:latest
              command:
                - /bin/sh
                - -c
                - |
                  kubectl scale statefulset/nifi --replicas=0 -n data-platform
                  # wait for NiFi to drain before stopping Kafka
                  kubectl wait --for=delete pod -l app=nifi -n data-platform --timeout=600s
                  kubectl scale statefulset/kafka --replicas=0 -n data-platform
```

**Pros:** No extra operators; full scripting control (great for ordered shutdown).
**Cons:** Imperative; you own the scripts, RBAC, and error handling.

RBAC for the scaler service account (least privilege):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: scale-workloads
  namespace: data-platform
rules:
  - apiGroups: ["apps"]
    resources: ["deployments/scale", "statefulsets/scale"]
    verbs: ["get", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
```

### Option D: Node-level scheduling (managed node groups / Karpenter)

Scale the *nodes* instead of (or in addition to) pods:

- **Managed node groups:** EventBridge Scheduler + Lambda calling `eks:UpdateNodegroupConfig` to set `desiredSize=0` at night.
- **Karpenter:** scale pods to zero and Karpenter consolidates nodes away automatically — no separate node schedule needed. This is the cleanest pattern: **schedule the pods, let Karpenter handle the nodes.**

> ⚠️ Scaling nodes to zero without scaling pods first causes pods to go `Pending` and pages your on-call. Always drive from the workload side.

### Option E: AWS Instance Scheduler / EventBridge (cluster-level)

For entire non-prod clusters, schedule Fargate profiles or node groups via the AWS Instance Scheduler solution or EventBridge + Lambda. Best for "the whole cluster sleeps" scenarios.

---

## 3. Tags and Labels for Team Tracking — Yes, Use Both

You asked whether tags are a way to track what teams need. Yes — but understand the two layers:

| Layer | Mechanism | Purpose |
|---|---|---|
| **AWS resources** (nodes, EBS, ELB) | AWS **tags** | Cost allocation (Cost Explorer, CUR), Instance Scheduler targeting |
| **Kubernetes objects** (pods, deployments) | K8s **labels** & **annotations** | Selection, scheduling policy, ownership, automation opt-in/out |

### Recommended label taxonomy

Define an org-wide standard and enforce it with policy (Kyverno/Gatekeeper):

```yaml
metadata:
  labels:
    app.kubernetes.io/name: nifi
    app.kubernetes.io/part-of: data-ingestion
    team: data-engineering          # ownership
    cost-center: cc-4521            # chargeback
    environment: dev                # dev|staging|prod
    scheduling.acme.io/tier: "2"    # startup order tier (see §5)
  annotations:
    scheduling.acme.io/schedule: "business-hours"   # opt into a named schedule
    scheduling.acme.io/exclude: "false"
    scheduling.acme.io/contact: "data-eng@acme.com"
    scheduling.acme.io/depends-on: "kafka"          # documented dependency
```

### How this drives automation

1. **Schedule opt-in by label** — your downscaler or CronJob selects targets with `-l scheduling.acme.io/schedule=business-hours` instead of hardcoding names. Teams self-serve by labeling.
2. **Cost attribution** — enable the AWS **split cost allocation data** for EKS in the Cost and Usage Report; it attributes node cost to pods using their labels (`team`, `cost-center`). Tag node groups/Karpenter NodePools with the same keys.
3. **Enforcement** — a Kyverno policy rejects Deployments/StatefulSets in non-prod namespaces missing `team` or `scheduling.acme.io/schedule`, so nothing escapes the savings program:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-scheduling-labels
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-team-and-schedule
      match:
        any:
          - resources:
              kinds: ["Deployment", "StatefulSet"]
              namespaceSelector:
                matchLabels:
                  environment: dev
      validate:
        message: "team label and scheduling.acme.io/schedule annotation are required"
        pattern:
          metadata:
            labels:
              team: "?*"
```

4. **Exception process** — `scheduling.acme.io/exclude: "true"` plus a required `exclude-reason` annotation gives teams a documented escape hatch (e.g., overnight batch runs) that you can audit.

---

## 4. Handling Startup Dependencies (Kafka → NiFi)

Kubernetes has **no built-in cross-workload startup ordering** — this is deliberate. You have four viable patterns, ordered from most to least Kubernetes-idiomatic:

### Pattern 1: Init containers that wait for readiness (preferred)

NiFi doesn't start its main container until Kafka is provably ready:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nifi
spec:
  template:
    spec:
      initContainers:
        - name: wait-for-kafka
          image: confluentinc/cp-kafka:7.6.0
          command:
            - /bin/sh
            - -c
            - |
              until kafka-broker-api-versions --bootstrap-server kafka:9092 >/dev/null 2>&1; do
                echo "waiting for kafka..."; sleep 10
              done
              echo "kafka is ready"
      containers:
        - name: nifi
          image: apache/nifi:2.0.0
          # ...
```

**Why this is best:** it's self-healing. If Kafka restarts at 2 AM, NiFi pods that restart will still wait correctly. Your scheduler can then scale *everything* up simultaneously — init containers serialize the actual startup.

> Tip: prefer a real protocol check (broker API call, HTTP health endpoint) over a bare TCP port check. "Port open" ≠ "cluster stable."

### Pattern 2: Staggered schedules (simple, time-based)

Offset the cron windows and let time do the ordering:

```yaml
# Kafka ScaledObject
start: "0 7 * * 1-5"    # up at 7:00

# NiFi ScaledObject
start: "20 7 * * 1-5"   # up at 7:20, after Kafka has stabilized
```

Shutdown reverses the order — consumers stop before brokers:

```yaml
# NiFi:  end: "0 19 * * 1-5"    down at 19:00
# Kafka: end: "20 19 * * 1-5"   down at 19:20
```

**Weakness:** time-based guessing. If Kafka takes 25 minutes one morning (e.g., long log recovery), NiFi starts against a broken cluster. **Combine Pattern 2 with Pattern 1** — stagger for efficiency, init-container for correctness.

### Pattern 3: Orchestrated scripts (explicit sequencing)

The CronJob script from §2 Option C, with health gates between steps:

```bash
#!/bin/sh
set -e
# --- Startup sequence ---
kubectl scale statefulset/kafka -n data-platform --replicas=3
kubectl rollout status statefulset/kafka -n data-platform --timeout=15m

# extra stability gate: under-replicated partitions must be 0
until [ "$(kubectl exec kafka-0 -n data-platform -- \
  kafka-topics --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions | wc -l)" -eq 0 ]; do
  echo "kafka partitions still recovering..."; sleep 15
done

kubectl scale statefulset/nifi -n data-platform --replicas=3
kubectl rollout status statefulset/nifi -n data-platform --timeout=10m
```

Best when order matters *and* readiness alone isn't sufficient (e.g., "stable" means ISR fully caught up, not just probes passing). Argo Workflows is the heavier-duty version of this if the DAG grows.

### Pattern 4: Operators manage their own lifecycle

If you run **Strimzi** (Kafka) or the **OpenSearch Operator**, don't scale their StatefulSets directly — the operator will fight you. Instead:

- **Strimzi:** annotate to pause, or set `spec.kafka.replicas` in the `Kafka` CR via your scheduler script; Strimzi ≥0.34 supports `strimzi.io/pause-reconciliation`.
- Scale the **custom resource**, never the underlying StatefulSet.

```bash
# scale Kafka via Strimzi CR
kubectl patch kafka my-cluster -n data-platform --type merge \
  -p '{"spec":{"kafka":{"replicas":0}}}'
```

### Readiness/liveness fundamentals (applies to all patterns)

- Every service in a dependency chain **must** have an accurate readiness probe — it's what init containers and `kubectl rollout status` key off.
- Use `startupProbe` for slow starters (Kafka log recovery, OpenSearch shard recovery) so liveness probes don't kill pods mid-recovery:

```yaml
startupProbe:
  httpGet: { path: /_cluster/health, port: 9200 }
  failureThreshold: 60      # 60 × 10s = 10 min grace
  periodSeconds: 10
```

- Set `PodDisruptionBudgets` so voluntary evictions during scale events don't take quorum below minimum.

---

## 5. A Tiered Startup Model for Data Platforms

Assign each service a **tier label** and start tiers in order. Typical data-platform tiers:

| Tier | Services | Rationale |
|---|---|---|
| 0 | ZooKeeper (if not KRaft), etcd-like stores, cert-manager | Coordination primitives |
| 1 | Kafka, OpenSearch master nodes, PostgreSQL, Schema Registry | Storage & messaging backbone |
| 2 | OpenSearch data nodes, Kafka Connect, NiFi, Flink JobManager | Depends on tier 1 |
| 3 | NiFi Registry, Flink TaskManagers, Logstash, dashboards (OpenSearch Dashboards, Grafana), APIs | Consumers of tiers 1–2 |

Startup: tier 0 → 3 with health gates between. **Shutdown: exactly the reverse (3 → 0)** so consumers drain before producers/brokers disappear.

Scheduler pseudo-logic driven by labels:

```bash
for tier in 0 1 2 3; do
  kubectl scale --replicas-from-annotation \
    -l "scheduling.acme.io/tier=$tier,scheduling.acme.io/schedule=business-hours" ...
  wait_for_tier_ready "$tier"
done
```

(Store the "restore" replica count in an annotation like `scheduling.acme.io/restore-replicas: "3"` when scaling down, so scale-up knows the target.)

---

## 6. Service-Specific Guidance

### Kafka

- **Graceful shutdown order:** stop consumers/producers (NiFi, Connect) first; then brokers. Give brokers a long `terminationGracePeriodSeconds` (120–300s) so they do controlled shutdown and leader handoff.
- **Startup "stable" definition:** all brokers registered **and** under-replicated partitions = 0 **and** no ongoing leader elections. Probe readiness is necessary but not sufficient — gate downstream services on URP=0 (Pattern 3).
- **KRaft vs ZooKeeper:** KRaft removes the ZK tier but controllers still need quorum — start all controller-eligible nodes together.
- **PVCs persist across scale-to-zero** — data survives; only compute stops. Verify your `StorageClass` uses `Retain`/default EBS behavior, and remember EBS volumes still cost money while pods are off (usually fine — it's the nodes that dominate cost).

### NiFi

- Enable **flow file drain on shutdown**: long `terminationGracePeriodSeconds` (300s+) so in-flight FlowFiles complete or checkpoint.
- Consider stopping root process groups via NiFi API before scaling to zero (avoids queued-data alarms on restart):
  ```bash
  curl -X PUT .../nifi-api/flow/process-groups/root \
    -d '{"id":"root","state":"STOPPED"}'
  ```
- On startup, wait for Kafka (init container) **and** for NiFi's own cluster election to finish before re-enabling process groups.

### OpenSearch

- **Before scale-down**, disable shard allocation to prevent a rebalancing storm:
  ```bash
  curl -X PUT "opensearch:9200/_cluster/settings" -H 'Content-Type: application/json' \
    -d '{"persistent":{"cluster.routing.allocation.enable":"primaries"}}'
  curl -X POST "opensearch:9200/_flush"
  ```
- **After scale-up**, wait for `_cluster/health` = `green` (or ≥ `yellow` in single-replica dev), then re-enable allocation (`"all"`). Gate Dashboards/Logstash on this.
- Master-eligible nodes need quorum — scale masters up first and together (tier 1), data nodes second (tier 2), Dashboards last (tier 3).
- Long `startupProbe` — shard recovery after restart can take many minutes with large indices.

### Flink / Spark / Airflow (bonus)

- **Flink:** stop with a savepoint before scale-down; restore from savepoint on start. JobManager (tier 2) before TaskManagers (tier 3).
- **Airflow:** pause DAG schedules or set `end` window to avoid a thundering herd of "missed" DAG runs at morning scale-up (`catchup=False`).
- **Spark on K8s:** driver pods are Jobs, not long-running — usually exclude from scheduling; instead gate *submission* windows.

---

## 7. Operational Best Practices Checklist

- [ ] **GitOps everything** — ScaledObjects/annotations live in the same repo as the workload; schedules are code-reviewed.
- [ ] **Store restore state** — record pre-shutdown replica counts in annotations; never assume "3".
- [ ] **Reverse order on shutdown** — consumers → processors → brokers → coordination.
- [ ] **Health-gate, don't time-gate** — init containers + real protocol checks beat fixed delays.
- [ ] **PDBs + graceful termination** — protect quorum services from careless drains; generous `terminationGracePeriodSeconds` for stateful apps.
- [ ] **Alert suppression windows** — silence "pods down" alerts during scheduled windows (Alertmanager mute time intervals) or you'll train on-call to ignore pages.
- [ ] **Monday-morning canary** — a synthetic check after weekend scale-up verifies the full chain (produce → Kafka → NiFi → OpenSearch → query) before teams arrive.
- [ ] **Timezones & DST** — always set `timezone`/`timeZone` explicitly; never rely on cluster UTC math.
- [ ] **Karpenter consolidation** — pods to zero → nodes disappear; verify `consolidationPolicy: WhenEmptyOrUnderutilized`.
- [ ] **Measure savings** — tag NodePools with `team`/`cost-center`; use EKS split cost allocation to report per-team savings and drive adoption.
- [ ] **Exclusion audit** — monthly review of `scheduling.acme.io/exclude=true` workloads with reasons.
- [ ] **Chaos-test the ordering** — occasionally kill Kafka mid-day; NiFi should recover on its own if init containers/probes are right.

---

## 8. Quick Decision Guide

| Situation | Use |
|---|---|
| Simple dev namespace, many teams | kube-downscaler annotations + Kyverno label enforcement |
| Mixed schedules, GitOps, scale-to-zero | KEDA cron ScaledObjects |
| Strict ordering with health gates (Kafka→NiFi) | CronJob script (or Argo Workflows) + init containers |
| Kafka via Strimzi / OpenSearch via operator | Patch the custom resource, never the StatefulSet |
| Whole cluster sleeps | EventBridge/Instance Scheduler on node groups |
| Nodes should follow pods automatically | Karpenter with consolidation |

---

*Adapt tier assignments, schedules, and label keys (`acme.io`) to your organization's conventions.*
