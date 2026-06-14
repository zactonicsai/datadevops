# EKS hello-world via CloudFormation

Stands up an Amazon EKS cluster and runs three hello-world website pods behind a
load balancer. Infrastructure is defined as CloudFormation; the workload is a
Kubernetes manifest.

## Files

| File | Purpose |
|------|---------|
| `01-vpc.yaml` | VPC, 2 public + 2 private subnets, internet gateway, NAT gateway, route tables. Subnets tagged for EKS + load balancer discovery. |
| `02-eks-cluster.yaml` | EKS control plane, cluster + node IAM roles, and a 2-node managed node group (autoscales 2–3). Imports subnets from the VPC stack. |
| `03-hello-world.yaml` | Kubernetes Deployment (3 replicas) + LoadBalancer Service. |
| `deploy.sh` | Creates both stacks, wires kubectl, applies the manifest. |
| `teardown.sh` | Deletes the load balancer, then both stacks, in the correct order. |

## Prerequisites

- **AWS CLI v2**, configured: `aws configure` (needs EKS, EC2, CloudFormation, IAM, VPC permissions).
- **kubectl** installed.
- The IAM principal you run this as becomes the cluster admin automatically
  (via `BootstrapClusterCreatorAdminPermissions`).

## Deploy

```bash
./deploy.sh                              # defaults: hello-world-cluster, us-east-1
./deploy.sh my-cluster us-west-2         # or pass name + region
```

The EKS stack takes ~15–20 minutes for the control plane plus a few more for the
node group — this is normal.

## Access the website

After deploy finishes, grab the load balancer hostname (allow 2–3 min for it to
populate):

```bash
kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl http://<that-hostname>     # refresh repeatedly to see the 3 pods load-balance
```

Each response shows the serving pod's name and IP, so you can watch traffic
spread across the three pods.

## Tear down

```bash
./teardown.sh                            # same args as deploy.sh
```

Always use this rather than deleting stacks in the console directly: it removes
the Kubernetes Service first so the AWS load balancer is released before the VPC
is torn down. An orphaned load balancer both blocks VPC deletion and keeps
billing.

## Cost note

While running, you pay for: the EKS control plane (~$0.10/hr), two `t3.medium`
EC2 instances, one NAT gateway, and one network load balancer. Tear down when
finished.

## Customizing

Common overrides live as parameters in `02-eks-cluster.yaml`:

- `KubernetesVersion` (default `1.33`)
- `NodeInstanceType` (default `t3.medium`)
- `NodeGroupDesiredSize` / `MinSize` / `MaxSize` (default `2` / `2` / `3`)

Pass them through with extra `--parameter-overrides` if you call
`aws cloudformation deploy` directly, or edit the defaults in the template.
