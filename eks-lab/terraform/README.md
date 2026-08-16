# Terraform version — layer reference

Same infrastructure as `../cli/`, declared instead of scripted.

## Run it

```bash
./apply-all.sh                      # everything, in order

# or one layer at a time (the real workflow)
cd 01-vpc
terraform init
terraform plan  -var-file=../dev.tfvars -out=tfplan
terraform show tfplan | less        # actually read it
terraform apply tfplan
```

Always `plan -out` then `apply` the saved plan. Without it, `apply` re-plans,
and the world may have changed between your review and the apply.

## Layers

```
01-vpc        VPC, subnets, IGW, NAT, routes, S3 endpoint
   ↓ outputs
02-iam-sg     cluster role, node role, security groups
   ↓ outputs
03-cluster    EKS control plane, OIDC provider, S3 bucket, IRSA roles, add-ons
   ↓ outputs
04-nodegroup  launch template + managed node group
   ↓
05-apps       Keycloak, Kafka, NiFi, web app, monitoring  (Kubernetes provider)
```

Each layer has its own state file. Later layers read earlier ones through
`terraform_remote_state`, which is **read-only** — layer 4 can see the VPC id
but can never modify the VPC.

## Everything environment-specific is in `dev.tfvars`

```bash
cp dev.tfvars stage.tfvars     # then edit the values
terraform apply -var-file=../stage.tfvars
```

The `.tf` files never change between environments. If you need to edit a `.tf`
file to make another environment work, add a variable instead.

## Per-layer commands

```bash
terraform fmt -recursive              # format
terraform validate                    # syntax check, no AWS calls
terraform plan -var-file=../dev.tfvars
terraform output                      # what this layer exposes
terraform output -raw nifi_password   # a single sensitive value
terraform state list                  # everything this layer manages
terraform plan -refresh-only          # detect manual changes (drift)
terraform destroy -var-file=../dev.tfvars
```

## Save money without destroying everything

Delete just the workers overnight:

```bash
cd 04-nodegroup && terraform destroy -var-file=../dev.tfvars
# next morning:
terraform apply -var-file=../dev.tfvars
```

The VPC, cluster and IAM survive. You keep paying $0.10/hour for the control
plane, and nothing for EC2.

## Known gotchas in this lab

- **`05-apps` needs a reachable cluster at PLAN time.** `kubernetes_manifest`
  validates against the live API server, so layers 1–4 must exist and
  `aws eks update-kubeconfig` must have run before you can even plan layer 5.
- **State is local.** Fine for one person learning. For a team, uncomment the
  `backend "s3"` block at the top of each `main.tf`. Local state means no
  locking (two applies can corrupt each other), no history, and no sharing.
- **`force_destroy = true` on the S3 bucket** lets `terraform destroy` empty
  it. That is a lab convenience and a production footgun. Never set it on a
  bucket with data you care about.
- **`ignore_changes = [scaling_config[0].desired_size]`** on the node group is
  intentional. If you add a cluster autoscaler later, it owns that number at
  runtime, and without this Terraform and the autoscaler fight forever.

## Protecting something you care about

```hcl
resource "aws_eks_cluster" "this" {
  # ...
  lifecycle {
    prevent_destroy = true    # apply hard-fails instead of deleting
  }
}
```

Also worth doing in a real setup: enable S3 bucket versioning on the state
bucket (your undo button), and grep the plan for `must be replaced` in CI.
