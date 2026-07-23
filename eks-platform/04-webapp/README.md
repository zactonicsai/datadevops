# Layer 04: Hello-World Web App

Two nginx pods serving a page that shows which pod answered, a ClusterIP
service, an internet-facing NLB, and a KEDA ScaledObject.

**Key idea:** the page is rendered by an *init container* that substitutes the
pod name into a template. nginx `sub_filter` cannot read environment variables,
which is a common trap.

**Key idea:** `lifecycle { ignore_changes = [spec[0].replicas] }`. Without it,
Terraform and KEDA fight over the replica count forever.

**Why port 8080, not 80:** the container runs as a non-root user with all
capabilities dropped, so it cannot bind a port below 1024. The Service maps
public 80 to container 8080.

**Test it:** `./tests/load-test.sh 180` and watch pods appear.

**Cost:** ~$16/month for the NLB. Set `create_public_loadbalancer = false` to
skip it.

## Commands

```bash
cd 04-webapp
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 04-webapp
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
