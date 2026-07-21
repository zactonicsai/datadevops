# Keycloak on AWS — Terraform

Deploys **only** an EC2 instance running Keycloak and an RDS PostgreSQL
database. All networking, IAM, keys, security groups, and load balancers are
consumed as pre-existing resources.

## Files

| File | Purpose |
|---|---|
| `TUTORIAL.md` | **Start here.** Full step-by-step guide with background and best practices. |
| `main.tf` | Resource definitions (EC2, RDS, Secrets Manager, TG attachment). |
| `variables.tf` | All input variables with descriptions and validation. |
| `outputs.tf` | Values printed after apply. |
| `user_data.sh.tftpl` | Instance bootstrap script. |
| `terraform.tfvars.example` | Production values — copy to `prod.tfvars` and edit. |
| `dev.tfvars.example` | Cheap disposable values — copy to `dev.tfvars` and edit. |

## Quick start

```bash
cp dev.tfvars.example dev.tfvars
# Edit dev.tfvars — replace every <REPLACE-ME>
grep -n "REPLACE-ME" dev.tfvars   # must print nothing

terraform init
terraform validate
terraform plan  -var-file=dev.tfvars -out=dev.tfplan
terraform apply dev.tfplan
```

Then follow steps 8–11 in `TUTORIAL.md` to verify health and secure the
admin account.

## What gets created

1. `random_password` — 32-char DB password
2. `aws_secretsmanager_secret` + `_version` — credential vault entry
3. `aws_db_subnet_group` — RDS subnet placement
4. `aws_db_instance` — PostgreSQL
5. `aws_instance` — Keycloak server
6. `aws_lb_target_group_attachment` — registers instance with your ALB

## What you must supply

VPC ID · private subnet IDs (≥2 AZs for RDS) · app security group · DB
security group · target group ARN · IAM instance profile name · hostname

See §3 of `TUTORIAL.md` for the CLI commands that find each one.

## Before you commit

```bash
cat > .gitignore <<'EOF'
*.tfvars
!*.tfvars.example
*.tfstate
*.tfstate.*
.terraform/
EOF
```
