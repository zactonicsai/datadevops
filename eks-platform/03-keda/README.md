# Layer 03: KEDA

Installs the KEDA autoscaling operator (3 deployments: operator, metrics
apiserver, admission webhooks) plus its CRDs.

**Key idea:** KEDA does not scale anything itself. It creates a normal
HorizontalPodAutoscaler and feeds it metrics from any source. So when
debugging, `kubectl describe hpa` shows you exactly what KEDA sees.

**Why KEDA over a plain HPA:** a plain HPA only reads CPU and memory, and can
never go below 1 replica. KEDA reads 70+ sources (queue depth, database rows,
HTTP endpoints) and can scale to zero.

**Must complete before layer 04**, because `kubernetes_manifest` validates
against CRD schemas at *plan* time.

## Commands

```bash
cd 03-keda
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 03-keda
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
