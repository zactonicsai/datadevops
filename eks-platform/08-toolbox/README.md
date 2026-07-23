# Layer 08: Test Toolbox

A long-running Linux pod (`nicolaka/netshoot`) with curl, dig, nc, tcpdump,
openssl, jq and kubectl, plus read-only RBAC across the cluster.

**Why it exists:** from your laptop you are *outside* the cluster. Internal DNS
names like `demo-kafka-kafka-bootstrap.kafka.svc.cluster.local` do not resolve
and ClusterIP services have no route. A pod inside sees exactly what your
applications see.

**Least privilege:** read-only RBAC on only the resource types the tests
inspect. Granting cluster-admin to a debug pod is a common and bad habit.

**Capabilities:** drops ALL, then adds back only `NET_RAW` so `ping` works.
That drop-then-add pattern is the right way; running privileged would grant
~40 capabilities to get one.

**Use it:** `kubectl exec -it -n toolbox deploy/toolbox -- /bin/bash`, then
`. /etc/toolbox/cluster-env.sh` to load every address.

## Commands

```bash
cd 08-toolbox
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 08-toolbox
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
