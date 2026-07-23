# STATUS — Complete

All tasks from the original request are now implemented. This file is the
inventory and the caveats.

## Delivered

| Requirement | Where | Status |
|---|---|---|
| EKS cluster + nodegroup | `01-cluster/` | Done |
| Deployment, 2 micro HTTP servers, hello page | `04-webapp/` | Done |
| KEDA autoscaling | `03-keda/`, `04-webapp/scaling.tf` | Done |
| NiFi, 2 pods | `07-nifi/` | Done |
| Kafka via Strimzi | `05-strimzi-operator/`, `06-kafka-cluster/` | Done |
| Linux pod that reaches all others | `08-toolbox/` | Done |
| Separate subdirectory per resource | 9 numbered layers | Done |
| Local state files | `backend "local"` in every layer | Done |
| Shell script per setup, with logging | `scripts/apply-all.sh`, `destroy-all.sh` | Done |
| Test script from the test pod | `tests/run-tests.sh`, `load-test.sh` | Done |
| Per-layer README | `NN-*/README.md` × 9 | Done |
| Main tutorial README | `README.md` | Done |
| Line-by-line comments | every `.tf` and `.sh` | Done |
| CLI equivalents (aws/kubectl/helm) | `docs/cli-equivalents.md` | Done |
| Best practices + pros/cons documented | throughout, esp. README §9 | Done |

~7,000 lines total.

## Caveats you should read

**Nothing has been executed or validated.** No `terraform` binary was available
in my build environment and the network allowlist blocked HashiCorp's release
host, so I could not run `fmt`, `validate`, or `plan`. What I *did* verify
mechanically:

- brace balance on every `.tf` file
- `bash -n` syntax on all 5 shell scripts
- YAML parses on both `docs/*.yaml`

**Do this before anything else:**

```bash
for d in 0*/ ; do (cd "$d" && terraform fmt && terraform init -backend=false && terraform validate); done
```

Expect to fix some syntax on first run. The layers most likely to need it are
06, 07 and 08, because they lean on `kubernetes_manifest`, which validates CRD
schemas at *plan* time against a live cluster.

**One known false positive.** `04-webapp/deployment.tf` has two bare `${`
characters inside `#` comments (around line 163) explaining Terraform's `$${`
escaping. Harmless, but naive brace-counting tools will report an imbalance.

## Version findings

Verified rather than recalled. Two would have broken a from-memory build:

- **Strimzi 1.0.0 removed the `v1beta2` API.** Kafka resources must use
  `kafka.strimzi.io/v1`. Nearly every tutorial online still shows `v1beta2`.
  Kafka 4.2.0, KRaft only.
- **AWS Load Balancer Controller chart jumped to 3.x** with open CRD/Gateway-API
  crash-loop issues. Routed around it deliberately — a `Service` of type
  `LoadBalancer` gets a real NLB with zero extra components.

Pinned: EKS module 21.24, AWS provider 6.x, Kubernetes 1.34, KEDA 2.20.1,
metrics-server 3.13.0, Strimzi 1.0.0, Kafka 4.2.0, NiFi 2.10.0, netshoot v0.13,
Helm provider 3.x (new `kubernetes = {}` attribute syntax).

## Cost

~$350/month running 24/7. `./scripts/destroy-all.sh` tears down in reverse
order and checks for orphaned EBS volumes afterwards. See README §11.
