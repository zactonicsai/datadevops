# Keycloak on AWS — Terraform

Terraform project that deploys **Keycloak (Docker image on ECS Fargate)** behind an **Application Load Balancer**, backed by **Multi-AZ RDS for PostgreSQL**, with all credentials in **AWS Secrets Manager**.

Tuned for resilience: nothing in the running path is single-instance, single-AZ, or single-NAT by default. IAM roles are managed outside this project and referenced by name.

## Architecture

```
                        Internet
                           │
                  ┌────────▼────────┐   public subnets — one per AZ (3 by default)
                  │       ALB       │   :80 → 301 → :443, HTTP/2, cross-zone
                  │  sg: alb-sg     │
                  └────────┬────────┘
                           │ traffic :8080   health :9000
                  ┌────────▼────────┐   private subnets — one per AZ
                  │  ECS Fargate    │   3 tasks, spread across AZs,
                  │ sg: keycloak-sg │   AZ rebalancing + circuit breaker
                  └────────┬────────┘
                           │ PostgreSQL :5432
                  ┌────────▼────────┐   database subnets — no internet route
                  │  RDS Multi-AZ   │   automatic failover to the standby
                  │ sg: database-sg │
                  └─────────────────┘

  Secrets Manager  ── db credentials + bootstrap admin, optional cross-region replicas
  CloudWatch       ── 10 alarms → SNS topic
  VPC endpoints    ── secretsmanager, ecr.api, ecr.dkr, logs, s3
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
| `networking.tf` | VPC, three subnet tiers, NAT per AZ, routing, endpoints |
| `security_groups.tf` | ALB / Keycloak / RDS / endpoint security groups |
| `iam.tf` | **Lookups only** for the pre-existing roles |
| `secrets.tf` | Generated passwords in Secrets Manager, optional replicas |
| `rds.tf` | Subnet group, parameter group, Multi-AZ instance, backup replication |
| `alb.tf` | Load balancer, target group, listeners |
| `ecs.tf` | Cluster, task definition, service, autoscaling policies |
| `monitoring.tf` | SNS topic and CloudWatch alarms |
| `outputs.tf` | URLs, IDs and secret ARNs — never secret values |
| `environments/*.tfvars` | Per-environment configuration |
| `environments/*.backend.hcl` | Per-environment state location |
| `scripts/` | Terraform wrappers, verification, backup, teardown |
| `docs/aws-cli-commands.md` | Every verify/destroy CLI command, by area, in order |
| `docs/iam-requirements.json` | Policy documents for the roles this project expects |

Resources use descriptive names (`aws_vpc.keycloak`, `aws_db_instance.keycloak`, `aws_lb.keycloak`) rather than the `this` convention, so plan output and state addresses read plainly.

## Prerequisites

- Terraform >= 1.6, AWS CLI v2, `jq`, `curl`
- An S3 bucket and DynamoDB lock table for state, or comment out `backend.tf`
- **The IAM roles must already exist**, with the permissions in `docs/iam-requirements.json`:
  - `ecs_task_execution_role_name` — image pull, logs, plus `secretsmanager:GetSecretValue` on `<project>-<env>/*`
  - `ecs_task_role_name` — usually nothing; ECS Exec permissions if `enable_execute_command = true`
  - `rds_monitoring_role_name` — only when `db_monitoring_interval > 0`
  - `vpc_flow_logs_role_name` — only when `enable_vpc_flow_logs = true` (on by default)

## Usage

```bash
export ENV=dev            # every script reads ENV; defaults to dev

./scripts/tf-init.sh      # init against environments/dev.backend.hcl
./scripts/tf-validate.sh  # fmt -check + validate
./scripts/tf-plan.sh      # saves dev.tfplan
./scripts/tf-apply.sh     # applies it, then runs the full verification suite
./scripts/tf-output.sh keycloak_url
```

Retrieve the generated admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(./scripts/tf-output.sh keycloak_admin_secret_arn)" \
  --query SecretString --output text | jq -r .password
```

## Scripts

Every script reads `ENV` (default `dev`) and honours `DRY_RUN=1` to print commands without running them, and `FORCE=1` to skip confirmation prompts. They discover resources by **tag**, not by Terraform state — so they still work when state is lost, which is exactly when you need them.

### Verify — outside in

| Script | Area | Asserts |
|---|---|---|
| `verify/10-verify-network.sh` | VPC, subnets, NAT, routing | 3 tiers across ≥2 AZs, NAT per AZ, database tier has no default route, 5 endpoints |
| `verify/20-verify-security-groups.sh` | Security groups | Keycloak accepts only the ALB SG, RDS only the Keycloak SG, no CIDR ingress, nothing open to the world |
| `verify/30-verify-secrets.sh` | Secrets Manager | Secrets exist, have the expected keys, are encrypted (keys printed, never values) |
| `verify/40-verify-rds.sh` | RDS | Available, Multi-AZ with a standby, encrypted, private, protected, ≥7 days retention, recent snapshots |
| `verify/50-verify-alb.sh` | Load balancer | Active across ≥2 AZs, HTTPS listener, HTTP/2 and deletion protection on, healthy targets in ≥2 AZs |
| `verify/60-verify-ecs.sh` | ECS | Running == desired, ≥2 tasks, tasks in ≥2 AZs, circuit breaker with rollback, no alarms firing |
| `verify/70-verify-keycloak.sh` | Application | OIDC discovery, master realm and admin console respond; recent errors in the logs |
| `verify/00-verify-all.sh` | All | Runs 10→70 and reports one verdict |

### Backup — always before teardown

| Script | Produces |
|---|---|
| `backup/10-backup-state.sh` | `terraform.tfstate`, `terraform-outputs.json`, the tfvars used |
| `backup/20-backup-secrets.sh` | `secrets.json`, mode 600 — plaintext, move it to a vault |
| `backup/30-backup-rds-snapshot.sh` | A **manual** snapshot, waited to completion (manual snapshots outlive the instance; automated ones do not) |
| `backup/40-backup-inventory.sh` | Per-service `describe` output under `inventory/` |
| `backup/00-backup-all.sh` | Runs 10→40 into `.backups/<prefix>-<timestamp>/` with a manifest |

### Destroy — inside out, backup first

| Script | Removes |
|---|---|
| `destroy/10-destroy-ecs.sh` | Scaling policies, service drained to 0, tasks, task definitions, cluster |
| `destroy/20-destroy-alb.sh` | Deletion protection, listeners, ALB, target group |
| `destroy/30-destroy-rds.sh` | Instance (final snapshot), subnet group, parameter group |
| `destroy/40-destroy-secrets.sh` | Replicas, then secrets with a recovery window (`IMMEDIATE=1` to force) |
| `destroy/50-destroy-observability.sh` | Alarms, log groups, SNS topic |
| `destroy/60-destroy-network.sh` | Endpoints → NAT → EIPs → ENIs → subnets → SG rules → SGs → route tables → IGW → VPC |
| `destroy/00-destroy-all.sh` | **Primary path**: backup, clear protections, drain, `terraform destroy`, then confirm nothing is left |
| `destroy/99-destroy-cli-fallback.sh` | **Fallback**: backup, then runs 10→60 with raw CLI when Terraform can't finish or state is gone |

```bash
ENV=dev ./scripts/destroy/00-destroy-all.sh              # normal teardown
ENV=dev DRY_RUN=1 ./scripts/destroy/99-destroy-cli-fallback.sh   # preview the CLI path
```

Two safety gates worth knowing: `30-destroy-rds.sh` refuses to run without a completed manual snapshot, and destructive scripts require you to type the stack prefix to confirm.

`docs/aws-cli-commands.md` has the same commands in copy-paste form if you'd rather drive it by hand.

## Resilience posture

**Availability zones.** Three by default. Public, private and database subnets in each, a NAT Gateway per AZ (`single_nat_gateway = false`), and an ALB spanning all of them with cross-zone balancing.

**Compute.** Three Fargate tasks minimum, autoscaling on CPU and memory (request count available), scale-out cooldown 60s against scale-in 300s so capacity is shed reluctantly. `availability_zone_rebalancing` redistributes tasks after an AZ recovers.

**Deployments.** `minimum_healthy_percent = 100` and `maximum_percent = 200` mean a rolling deploy adds capacity before removing any. The circuit breaker aborts and rolls back automatically when new tasks fail to stabilise. Target group `slow_start` ramps traffic into a cold JVM instead of dropping full load on it.

**Health.** ALB checks `/health/ready` on the management port, and the container runs its own probe over bash `/dev/tcp` (the Keycloak image has no curl) with a 180s start period. Failed containers are replaced without waiting for the load balancer to notice.

**Database.** Multi-AZ with an automatic standby, 30 days of backups, storage autoscaling, deletion protection, and optional cross-region automated backup replication.

**Credentials.** Generated by Terraform, stored in Secrets Manager, injected by the ECS agent at runtime — never in the image, the task definition, or the outputs. Optionally replicated to other regions so a regional outage doesn't cost you the credentials needed to rebuild.

**Alarming.** Ten alarms across ALB, ECS and RDS. The ones where silence is itself bad news — no healthy hosts, task count below minimum, free storage low — use `treat_missing_data = "breaching"`, so a metric that stops reporting pages you.

## Configuration

Every value is a variable; nothing is hardcoded. Commonly changed:

| Variable | Default | Notes |
|---|---|---|
| `environment` | *(required)* | `dev`, `test`, `stg`, `prod` |
| `ecs_task_execution_role_name` | *(required)* | Existing role |
| `ecs_task_role_name` | *(required)* | Existing role |
| `az_count` | `3` | 2–4 |
| `single_nat_gateway` | `false` | `true` is cheaper, and a single point of failure |
| `acm_certificate_arn` | `null` | Set it to enable HTTPS plus the HTTP redirect |
| `keycloak_image` | `quay.io/keycloak/keycloak:26.0` | Point at ECR in production |
| `keycloak_desired_count` | `3` | |
| `db_multi_az` | `true` | |
| `db_backup_retention_period` | `30` | |
| `enable_alarms` | `true` | Add `alarm_email_endpoints` to actually get paged |
| `keycloak_extra_environment` | `{}` | Any additional `KC_*` settings |

```hcl
keycloak_extra_environment = {
  KC_FEATURES        = "token-exchange,admin-fine-grained-authz"
  KC_HOSTNAME_STRICT = "true"
}
```

## Notes and gotchas

- **Keycloak boot time.** The `start` command runs a build on first boot, so `health_check_grace_period` defaults to 300s. Build an optimised image (`kc.sh build`), push it to ECR and set `keycloak_image` for faster, deterministic starts — the prod tfvars assumes you have.
- **Health checks use port 9000.** Keycloak 25+ serves `/health/*` on the management interface, so the target group health check targets `keycloak_management_port` while traffic goes to `keycloak_http_port`.
- **Clustering.** `KC_CACHE_STACK = "jdbc-ping"` discovers peers through the shared database, since multicast is unavailable on Fargate. Ports 7800–7801 are open within the Keycloak SG so sessions replicate.
- **Hostname.** Without `acm_certificate_arn` and `keycloak_hostname`, Keycloak runs behind the raw ALB DNS name over HTTP — fine for a smoke test, not for production. Set both, point a Route53 alias at `alb_dns_name`/`alb_zone_id`, then set `KC_HOSTNAME_STRICT = "true"`.
- **State contains secrets.** Generated passwords are stored in state. Keep the bucket encrypted, versioned and tightly restricted.
- **Cost.** The resilient defaults are not cheap: three NAT Gateways, three Fargate tasks and a Multi-AZ database. `environments/dev.tfvars` strips all of that back.
- **Destroying prod** requires clearing deletion protection first. `destroy/00-destroy-all.sh` does it for you, deliberately and only after a backup.
