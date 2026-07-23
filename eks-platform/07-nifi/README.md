# Layer 07: Apache NiFi

Two NiFi 2.10 pods as a StatefulSet, each with its own 10 GiB volume, plus a
headless service for per-pod DNS and a ClusterIP service for the UI.

**Why hand-written, not Helm:** Apache publishes no official NiFi chart, and
the community ones have gone stale (several still assume NiFi 1 and ZooKeeper).
~200 lines we control beats a chart that may not work with 2.x.

**Why StatefulSet:** pods get stable names (`nifi-0`, `nifi-1`) and each
reattaches to *its own* volume after a restart. A Deployment cannot do this.

**JVM heap is 1 GiB against a 3 GiB limit** — the JVM needs substantial
off-heap memory, and equalising them is the classic route to an OOMKill.

**Honest limitation:** these are two *independent* NiFi instances, not a NiFi
cluster. Each has its own canvas. See the note at the bottom of `main.tf`.

**Access:** `kubectl port-forward -n nifi svc/nifi 8443:8443`, then
`terraform output -raw nifi_password`.

## Commands

```bash
cd 07-nifi
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 07-nifi
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
