# Layered Terraform: reusable AWS modules + one stack per stage

```
terraform/layered/
├── modules/            application-agnostic building blocks (see modules/README.md)
├── shared/             vendored Helm charts, operator manifests, IAM policies (no downloads at apply)
├── stacks/
│   ├── 00-network/         VPC + subnets                      (or adopt existing)
│   ├── 10-eks-cluster/     EKS control plane + IAM + OIDC     (or adopt existing)
│   ├── 20-eks-nodegroups/  node IAM role, launch template, node groups, EBS CSI + gp3,
│   │                       AWS Load Balancer Controller, application namespaces
│   ├── 30-keycloak-ec2/    Keycloak OUTSIDE EKS: SSM secrets, SGs, RDS, IAM, launch template,
│   │                       ASG, target group, ALB, ACM, Route 53
│   ├── 40-kafka/           Strimzi operator + KRaft Kafka + topics on EKS
│   └── 50-kafka-ui/        Kafka UI on EKS behind its own ALB/target group (TargetGroupBinding),
│                           OIDC against the EC2 Keycloak
└── Makefile
```

Each stack has **its own state file** (`backend.<env>.hcl`), **its own tfvars**
(`<env>.tfvars`) and reads what it needs from upstream stacks through
`terraform_remote_state` — **unless** you supply the value in tfvars, in which
case the remote lookup is skipped. That is how "pre-existing or provided" works:
every VPC/subnet/SG/role/launch-template/target-group/ALB/cert can come from
tfvars, from another stack's state, or be created.

## Order of operations
```bash
export TF_VAR_keycloak_admin_password=… TF_VAR_db_password=… TF_VAR_kafka_ui_client_secret=…
make bootstrap-state BUCKET=my-tf-state-bucket REGION=us-east-1     # once
for s in stacks/*/; do cp $s/backend.dev.hcl.example $s/backend.dev.hcl; done   # edit bucket name
make apply STACK=00-network        ENV=dev
make apply STACK=10-eks-cluster    ENV=dev
make apply STACK=20-eks-nodegroups ENV=dev
make apply STACK=30-keycloak-ec2   ENV=dev
make apply STACK=40-kafka          ENV=dev
make apply STACK=50-kafka-ui       ENV=dev
# or: make all ENV=dev
```
A second environment = copy `dev.tfvars` → `prod.tfvars` and `backend.dev.hcl` → `backend.prod.hcl`.

Full tutorial: `docs/terraform-layered.md`.
