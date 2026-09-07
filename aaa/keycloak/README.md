# Keycloak on AWS (Terraform) — ALB + ACM + Route 53

```
Internet ─► Route 53 (auth.example.com) ─► ALB :443 (ACM cert) ─► EC2 :8080 Keycloak ─► RDS Postgres
                                            ALB :80  ─► 301 to https
```

What gets created:

- VPC, 2 public subnets, IGW (no NAT gateway)
- Application Load Balancer, HTTPS listener with an ACM certificate (DNS-validated via Route 53), HTTP→HTTPS redirect
- Route 53 A-alias record `keycloak_domain` → ALB
- 1× EC2 `t4g.small` running Keycloak in Docker on :8080, reachable only from the ALB security group
- 1× RDS Postgres 16 `db.t4g.micro`, reachable only from the EC2 security group
- IAM role for SSM Session Manager

Rough cost (us-east-1): EC2 ~$12 + RDS ~$12 + ALB ~$17 + storage/IP ~$5 ≈ **$46/month**.

## Prerequisites

- A public Route 53 hosted zone for your domain already exists.
- AWS CLI configured; `dig` and `curl` for the verify script.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit zone + domain
terraform init
terraform apply
./scripts/verify.sh                            # DNS, cert, target health, redirect, TLS, issuer, admin login
terraform output -raw admin_password
```

Apply takes ~10 min (RDS + ACM validation). Keycloak needs another ~3–5 min after that to pull images and boot; `verify.sh` step 3 will show the target `initial`/`unhealthy` until then — just rerun it.

## Operations

```bash
$(terraform output -raw ssm_shell_command)                  # shell on the host
sudo docker compose -f /opt/keycloak/compose.yaml logs -f keycloak
terraform apply -var='allowed_cidrs=["203.0.113.0/24"]'     # restrict access at the ALB
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/verify.sh` | End-to-end access check after apply. Exits non-zero if anything fails. |
| `scripts/view.sh [region] [name]` | List everything the stack created. |
| `scripts/destroy.sh` | `terraform destroy` with confirmation. |
| `scripts/nuke.sh [region] [name] [domain] [zone]` | AWS-CLI-only teardown when state is lost. Deletes the DB **without** a snapshot. |

## Notes

- Keycloak runs in production mode with `KC_HOSTNAME=https://<domain>` and trusts the ALB's `X-Forwarded-*` headers, so all generated URLs use the public name.
- ALB health check is `GET /realms/master` on :8080 (Keycloak 25+ moved `/health` to the management port 9000, so this is simpler).
- Single instance, single-AZ DB. For HA: put the instance in an ASG behind the same target group, enable `multi_az`, and switch Keycloak to a shared cache (Infinispan / JDBC-ping).
- Secrets are in Terraform state — use a remote encrypted backend for anything beyond a test.
