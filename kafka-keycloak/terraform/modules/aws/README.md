# Reusable AWS core modules

Every module that wraps a resource other apps may already own follows the same
**create-or-provide** contract:

```hcl
create      = true            # create it (default)
existing_id = null            # ...or set create = false and pass the existing id/arn/name
```
Outputs are identical either way (`id`, `arn`, `dns_name`, …), so a stack can be
pointed at pre-existing infrastructure just by changing `terraform.tfvars`.

| Module | Creates | "existing" input | Typical consumers |
|--------|---------|------------------|-------------------|
| `vpc` | VPC, public/private subnets, IGW, NAT, route tables | `existing_vpc_id`, `existing_*_subnet_ids` | everything |
| `security-group` | SG + ingress/egress rules (rules also apply to an existing SG) | `existing_id` | ALBs, EC2, RDS, EKS |
| `iam-role` | role with service / cross-account / OIDC (IRSA) trust, managed + inline + file policies, optional instance profile | `existing_role_name` | EKS control plane & nodes, EC2, IRSA |
| `launch-template` | LT with AMI (explicit or SSM), IMDSv2, root volume, SGs, profile, user data | `existing_id` | EC2 apps, EKS managed node groups |
| `target-group` | ALB/NLB target group (instance / ip) with health check & stickiness | `existing_arn` | EC2 apps, EKS pods via TargetGroupBinding |
| `load-balancer` | ALB or NLB, HTTPS/TLS listener, HTTP→HTTPS redirect, host rules (host rules also attach to an existing listener) | `existing_arn`, `existing_https_listener_arn` | any web app |
| `eks-cluster` | control plane, OIDC provider (IRSA), add-ons | `existing_cluster_name` | any EKS workload |
| `eks-node-group` | managed node group (optional launch template, labels, taints, spot) | — | any EKS workload |
| `ec2-instance` | N instances from a launch template spread over subnets, registered to target groups | — | any EC2 app |
| `acm-certificate` | DNS-validated ACM cert | `existing_arn` | any HTTPS endpoint |
| `route53-record` | A/CNAME/alias record | — | any endpoint |
| `rds-postgres` | PostgreSQL instance + subnet group | `existing {address, db_name, username}` | Keycloak, any app DB |

Example — a new app on EC2 behind a shared ALB:
```hcl
module "tg" { source = "../../modules/aws/target-group"; name = "myapp"; vpc_id = ...; port = 3000; target_type = "instance" }
module "lb" {
  source = "../../modules/aws/load-balancer"
  create = false
  existing_arn                = "arn:...:loadbalancer/app/shared/abc"
  existing_https_listener_arn = "arn:...:listener/app/shared/abc/def"
  name       = "shared"
  host_rules = [{ hosts = ["myapp.example.com"], target_group_arn = module.tg.arn }]
}
```
