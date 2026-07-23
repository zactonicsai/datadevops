# Layer 01: EKS Cluster

Creates the EKS control plane, a managed node group of AL2023 workers, core
add-ons, an IAM role for the EBS CSI driver via Pod Identity, and a `gp3`
default StorageClass.

**Slowest layer:** 10-15 minutes. Nothing can hurry the control plane.

**Key idea:** `enable_cluster_creator_admin_permissions = true`. Without it you
build a healthy cluster and are then completely locked out of it.

**Why gp3:** EKS ships `gp2` as default, which is slower, pricier, and ties
performance to volume size. We demote it and promote `gp3`.

**Watch out for:** `volume_binding_mode = "WaitForFirstConsumer"`. Without it,
an EBS volume can be created in a different AZ from the pod that needs it, and
the pod hangs forever.

**Cost:** ~$73/month control plane plus ~$210/month for three m6i.large.

## Commands

```bash
cd 01-cluster
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 01-cluster
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
