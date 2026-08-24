# Keycloak on AWS — Terraform

Deploys **Keycloak (Docker) on EC2** behind an **Application Load Balancer**, backed by **RDS for PostgreSQL**, with credentials in **AWS Secrets Manager**.

No ECS, no container orchestrator: a launch template installs Docker, reads the credentials, and runs the Keycloak container. An Auto Scaling Group keeps the instances registered with the ALB and replaces any that go unhealthy.

## Architecture

```
                      Internet
                         │
                ┌────────▼────────┐   public subnets — one per AZ
                │       ALB       │   :80 → 301 → :443
                │  sg: alb-sg     │
                └────────┬────────┘
                         │ traffic :8080   health :9000
                ┌────────▼────────┐   private subnets — one per AZ
                │  EC2 + Docker   │   Auto Scaling Group, ELB health checks
                │ sg: keycloak-sg │   user_data: dnf install docker → docker run
                └────────┬────────┘
                         │ PostgreSQL :5432
                ┌────────▼────────┐   database subnets — no internet route
                │  RDS PostgreSQL │
                │ sg: database-sg │
                └─────────────────┘

  Secrets Manager ── db credentials + bootstrap admin, read at boot
  CloudWatch      ── container logs + 4 alarms → SNS
```

## File layout

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version pinning |
| `backend.tf` | S3 remote state (partial config, supplied at `init`) |
| `providers.tf` | Provider setup and `default_tags` |
| `variables.tf` | Every input variable, with validation |
| `locals.tf` | Naming convention, tags, CIDR maths |
| `data.tf` | Account, region and AZ lookups |
| `networking.tf` | VPC, three subnet tiers, NAT, routing |
| `security_groups.tf` | ALB / Keycloak / RDS security groups |
| `iam.tf` | **Lookup only** for the pre-existing instance profile |
| `secrets.tf` | Generated passwords in Secrets Manager |
| `rds.tf` | Subnet group, parameter group, PostgreSQL instance |
| `alb.tf` | Load balancer, target group, listeners |
| `compute.tf` | Launch template, Auto Scaling Group, optional CPU scaling |
| `templates/user_data.sh.tftpl` | Instance bootstrap: Docker, secrets, `docker run` |
| `monitoring.tf` | SNS topic and four CloudWatch alarms |
| `outputs.tf` | URLs, IDs and secret ARNs — never secret values |
| `environments/*.tfvars` | Per-environment configuration |
| `scripts/` | Terraform wrappers, verification, backup, teardown |
| `docs/aws-cli-commands.md` | Every verify/destroy CLI command, by area, in order |
| `docs/iam-requirements.json` | Policy documents for the instance profile |

Resources carry descriptive names (`aws_vpc.keycloak`, `aws_autoscaling_group.keycloak`, `aws_db_instance.keycloak`) rather than the `this` convention.

## Prerequisites

- Terraform >= 1.6, AWS CLI v2, `jq`
- An S3 bucket and DynamoDB lock table for state, or comment out `backend.tf`
- **An IAM instance profile must already exist** with: `secretsmanager:GetSecretValue` on `<project>-<env>/*`, `logs:PutLogEvents` on the Keycloak log group, and `AmazonSSMManagedInstanceCore` for shell access. Full policy documents are in `docs/iam-requirements.json`.

## Usage

```bash
export ENV=dev            # every script reads ENV; defaults to dev

./scripts/tf-init.sh
./scripts/tf-plan.sh
./scripts/tf-apply.sh     # applies, then runs the verification suite
./scripts/tf-output.sh keycloak_url
```

Admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(./scripts/tf-output.sh keycloak_admin_secret_arn)" \
  --query SecretString --output text | jq -r .password
```

## Scripts

All read `ENV` (default `dev`), honour `DRY_RUN=1` to print without executing and `FORCE=1` to skip prompts, and discover resources **by tag** rather than from state — so they still work when state is gone.

**Verify** (outside in): `10` network → `20` security groups → `30` secrets → `40` RDS → `50` ALB → `60` EC2 hosts → `70` Keycloak itself. `00-verify-all.sh` runs them all and gives one verdict.

**Backup** (always before teardown): `10` state and outputs → `20` secrets → `30` a manual RDS snapshot, waited to completion → `40` resource inventory. `00-backup-all.sh` writes it all to `.backups/<prefix>-<timestamp>/`.

**Destroy** (inside out): `10` ASG and launch templates → `20` ALB → `30` RDS → `40` secrets → `50` alarms and logs → `60` networking. `00-destroy-all.sh` is the normal path (backup, clear protections, drain, `terraform destroy`, confirm); `99-destroy-cli-fallback.sh` runs `10`–`60` with raw CLI when Terraform can't finish.

```bash
ENV=dev ./scripts/destroy/00-destroy-all.sh
ENV=dev DRY_RUN=1 ./scripts/destroy/99-destroy-cli-fallback.sh    # preview
```

`30-destroy-rds.sh` refuses to run without a completed manual snapshot, and destructive scripts make you type the stack prefix to confirm.

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `environment` | *(required)* | `dev`, `test`, `stg`, `prod` |
| `instance_profile_name` | *(required)* | Existing instance profile |
| `az_count` | `2` | 2–4 |
| `single_nat_gateway` | `true` | `false` gives one per AZ |
| `acm_certificate_arn` | `null` | Set it to enable HTTPS plus the HTTP redirect |
| `keycloak_image` | `quay.io/keycloak/keycloak:26.0` | Any registry the instance can reach |
| `instance_type` | `t3.medium` | |
| `asg_desired_capacity` | `2` | Set to `1` for a genuinely minimal stack |
| `ami_id` | `null` | Null resolves the latest Amazon Linux 2023 from SSM |
| `db_multi_az` | `true` | |
| `keycloak_extra_environment` | `{}` | Any additional `KC_*` settings |

## Notes and gotchas

- **Bootstrap takes a few minutes.** Instances install Docker, pull the image and start Keycloak, so `health_check_grace_period` defaults to 300s. If targets never turn healthy, connect with `aws ssm start-session --target <id>` and read `/var/log/cloud-init-output.log`, then `sudo docker logs keycloak`.
- **Health checks use port 9000.** Keycloak 25+ serves `/health/*` on the management interface, so the target group checks `keycloak_management_port` while traffic goes to `keycloak_http_port`.
- **ASG health check type is ELB**, not EC2 — otherwise an instance with a dead container stays in service because the hardware is fine.
- **Clustering.** `KC_CACHE_STACK=jdbc-ping` discovers peers through the shared database; ports 7800–7801 are open within the Keycloak SG so sessions replicate across instances.
- **Changing the launch template** (new image, new instance type) triggers a rolling instance refresh at `instance_refresh_min_healthy_percent`.
- **Credentials** are generated by Terraform, stored in Secrets Manager, and read at boot with the instance profile — never baked into an AMI or passed as plaintext user data. They do land in Terraform state, so keep the state bucket encrypted and restricted.
- **Hostname.** Without `acm_certificate_arn` and `keycloak_hostname` you're on the raw ALB DNS name over HTTP — fine for a smoke test, not for production. Set both, point a Route53 alias at `alb_dns_name`/`alb_zone_id`, then set `KC_HOSTNAME_STRICT = "true"`.
