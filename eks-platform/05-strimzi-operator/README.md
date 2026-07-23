# Layer 05: Strimzi Operator

Installs the Strimzi Kafka operator. Creates no Kafka yet.

**CRITICAL:** Strimzi 1.0.0 **removed the `v1beta2` API**. Custom resources
must use `kafka.strimzi.io/v1`. Nearly every Kafka-on-Kubernetes tutorial
online still shows `v1beta2` and will be rejected with "no matches for kind".

**Also note:** ZooKeeper is gone. Kafka 4.x is KRaft-only. Any tutorial
mentioning ZooKeeper predates 2025.

**Scoped deliberately:** `watchNamespaces = []` means the operator only watches
its own namespace, so it needs Roles rather than cluster-wide ClusterRoles.
Least privilege in practice.

**Includes a 30-second settle timer** so the CRDs finish registering before
layer 06 plans against them.

## Commands

```bash
cd 05-strimzi-operator
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 05-strimzi-operator
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
