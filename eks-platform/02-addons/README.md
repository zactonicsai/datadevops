# Layer 02: Cluster Add-ons

Installs metrics-server.

**Small but essential.** metrics-server serves the metrics API that
HorizontalPodAutoscalers read. Without it, autoscaling *silently* never
happens: you get `<unknown>/50%` forever and no error anywhere.

**Watch out for:** `--kubelet-insecure-tls`. Required on EKS because kubelets
present self-signed certificates. Traffic stays encrypted; only identity
verification is skipped. Without it metrics-server crash-loops with an x509
error.

**Verify:** `kubectl top nodes` should print numbers within ~60 seconds.

## Commands

```bash
cd 02-addons
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 02-addons
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
