# Core AWS modules (application-agnostic)

Every module that creates an AWS resource follows the same contract:

* `create = true` (default) → the module creates the resource.
* `create = false` + `existing_*` → the module creates nothing and simply passes the
  provided identifiers through its outputs, so downstream code is identical either way.

| Module | Creates | Pre-existing input | Key outputs |
|--------|---------|--------------------|-------------|
| `vpc` | VPC, IGW, public/private subnets, NAT, route tables | `existing_vpc_id`, `existing_*_subnet_ids` | `vpc_id`, `public_subnet_ids`, `private_subnet_ids` |
| `security-group` | SG + ingress rules (CIDR or SG source) + all-egress | `existing_id` | `id` |
| `iam-role` | Role trusted by services **or** an EKS OIDC provider (IRSA), managed + inline (file/JSON) policies, optional instance profile | `existing_role_arn` | `arn`, `name`, `instance_profile_name` |
| `launch-template` | LT with AMI from SSM (or given), SG, profile, user-data, encrypted gp3 root, IMDSv2; `for_eks=true` for node groups | `existing_id` | `id`, `latest_version` |
| `target-group` | ALB target group (instance or ip) with health check/stickiness | `existing_arn` | `arn` |
| `alb` | ALB, HTTPS listener (+HTTP→HTTPS redirect) or HTTP, host-header rules | `existing_arn/dns_name/zone_id/https_listener_arn` | `dns_name`, `zone_id`, `listener_arn` |
| `acm-certificate` | DNS-validated cert via Route 53 | `existing_arn` | `arn` |
| `route53-record` | Alias (A) to an ALB or CNAME | – | `fqdn` |
| `rds` | PostgreSQL instance + subnet group | `existing_endpoint` | `endpoint`, `db_name`, `username` |
| `ec2-asg` | Auto Scaling group from a launch template, attached to target groups, rolling refresh | – | `name` |
| `ssm-secrets` | SecureString parameters under a prefix | – | `parameter_arns`, `parameter_names` |
| `eks-cluster` | Control plane + OIDC provider (IRSA) | `existing_cluster_name` (adopts) | `name`, `endpoint`, `ca_certificate`, `oidc_provider_arn`, `cluster_security_group_id` |
| `eks-node-group` | Managed node group using a launch template, labels, taints | – | `arn` |
| `eks-addon` | Any EKS add-on with optional IRSA role | – | `arn` |
| `k8s-namespace` | Namespace + optional ResourceQuota | – | `name` |
| `helm-app` | `helm_release` from a **local chart directory** | – | `name`, `status` |

Nothing in `modules/` knows about Kafka or Keycloak. A new application (e.g. a
Java API on EC2 or a Python service on EKS) is just a new `stacks/NN-<app>/`
directory that composes these modules with its own tfvars and state file.
