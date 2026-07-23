# Layer 06: Kafka Cluster

Creates 3 KRaft controllers, 2 brokers, and a test topic — all as custom
resources the Strimzi operator turns into ~40 real Kubernetes objects.

**Why 3 controllers:** Raft needs a majority. 1 tolerates 0 failures. **2 also
tolerates 0** (a majority of 2 is still 2). 3 tolerates 1. Controller counts
are always odd, and `variables.tf` enforces it.

**Why 2 brokers:** as requested. Be aware of the trade-off — with 2 brokers you
must set `min.insync.replicas` to 1 (writes survive restarts but a badly-timed
failure can lose acknowledged data) or 2 (safe writes but any restart stops
them). **The production standard is 3 brokers / replication 3 / min.insync 2.**

**Hard anti-affinity** on controllers: two on one node means losing that node
loses quorum, defeating the point of the third.

**JVM heap is ~50% of the container limit** so the OS page cache has room.

## Commands

```bash
cd 06-kafka-cluster
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 06-kafka-cluster
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
