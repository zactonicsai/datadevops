# Layer 00: Network

Builds the VPC, public and private subnets across Availability Zones, an
Internet Gateway, NAT gateway(s), route tables, and a free S3 gateway endpoint.

**Why first:** nothing else can exist without a network.

**Key idea:** worker machines go in *private* subnets with no inbound route
from the internet. Load balancers go in *public* subnets. That separation is
defence in depth.

**Watch out for:** subnet tags. EKS discovers subnets by scanning for
`kubernetes.io/role/elb` and `kubernetes.io/cluster/<name>`. Get them wrong and
load balancers silently fail to provision.

**Cost:** the NAT gateway is ~$32/month and is the main charge here.

## Commands

```bash
cd 00-network
terraform init
terraform plan          # preview
terraform apply         # build
terraform output        # see what it produced
```

Or via the wrapper, which logs to `logs/`:

```bash
./scripts/apply-all.sh 00-network
```

See the main [README](../README.md) for the full tutorial and
[docs/cli-equivalents.md](../docs/cli-equivalents.md) for the kubectl/helm way.
