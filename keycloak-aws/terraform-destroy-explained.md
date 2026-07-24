# Terraform Destroy Plan Explained in Plain Language

> **Audience:** A new learner who is starting with Terraform and AWS.
> 
> **Source:** The uploaded Terraform destroy plan and the completed destroy log.
> 
> **Result shown by the log:** `Destroy complete! Resources: 36 destroyed.`

## 1. The Big Idea

Terraform is like a building manager with a checklist. The Terraform state file is the checklist. It connects names in your code, such as `aws_instance.keycloak`, to real AWS objects, such as `i-0f7317687e9066068`.

A normal `terraform apply` tries to make AWS match the Terraform code. A `terraform destroy` changes the goal to: **none of the managed resources should exist**. Terraform first builds a destroy plan, shows the plan, asks for the exact word `yes`, and then deletes resources in a safe dependency order.

The plan showed:

```text
Plan: 0 to add, 0 to change, 36 to destroy.
```

This means Terraform did not plan to build or edit anything. It planned to remove 36 tracked items.

Of those 36 items:

- **33 were AWS resources or AWS relationships.**
- **3 were local Terraform Random provider values.** They were not separate AWS objects.

## 2. How to Read the Destroy Symbols

| Plan text | Plain meaning | Simple example |
|---|---|---|
| `# resource.name will be destroyed` | Terraform plans to delete that tracked object. | A label on a box says the whole box will be thrown away. |
| `-` at the start of a line | This value is being removed. | A minus sign means take it away. |
| `old value -> null` | The value exists now, but after destroy Terraform expects no value because the resource will not exist. | A desk number changes from `Desk 12` to no desk. |
| `(sensitive value) -> null` | Terraform knows a secret value exists but refuses to print it. It will still remove the tracked value or resource. | The plan says “password present” without showing the password. |
| `(write-only attribute) -> null` | Terraform sent the value to AWS but AWS does not return it later. | Like placing a letter in a locked drop box. |
| `# (N unchanged attributes hidden)` | Terraform left some less-useful lines out of the display to keep the plan shorter. They belong to the resource being deleted too. | A receipt says “13 more normal details not printed.” |
| `[] -> null` | An empty list belonged to the resource. When the resource is deleted, even the empty list field disappears. | An empty drawer is removed with the cabinet. |
| `{...} -> null` | A map or object, such as tags or a policy, is removed with the resource. | A folder and all labels on the folder are removed. |

### Important difference: `null` does not mean the AWS API stores the word null

In this plan, `null` means **Terraform expects the attribute to have no value after deletion because the whole object is gone**. It is a plan idea, not usually a field AWS saves.

## 3. What the AWS Design Looked Like Before Destroy

```text
Internet
   |
   v
Internet Gateway
   |
Public Route Table: 0.0.0.0/0 -> Internet Gateway
   |
Public Subnet 10.42.1.0/24 in us-east-1a
   |
Keycloak EC2 t4g.small
  - Private IP: 10.42.1.210
  - Elastic IP: 34.197.55.175
  - Ports 22, 8080, and 8443 allowed from one /32 address
  - IAM role for SSM and Secrets Manager
   | TCP 5432, allowed by security-group reference
   v
RDS PostgreSQL 18.3, db.t4g.micro, private only
  - Private subnet A: 10.42.11.0/24 in us-east-1a
  - Private subnet B: 10.42.12.0/24 in us-east-1b
  - 20 GiB gp3 encrypted storage
  - Secrets stored in AWS Secrets Manager
```

### Network ranges in simple words

- `10.42.0.0/16` was the large VPC neighborhood. It can hold about 65,536 IPv4 addresses before AWS reservations and design choices.
- Each `/24` subnet is a smaller street with 256 addresses. AWS keeps five addresses in every normal subnet, so about 251 are usable.
- `68.32.112.68/32` means exactly one IPv4 address. A `/32` is like putting one exact person on a guest list.
- `0.0.0.0/0` means every IPv4 destination. In a route table, it is the default path for traffic that does not match a more specific route.

## 4. What Was Permanently Important

### RDS data

The database contained Keycloak identity data. The plan had both:

```text
skip_final_snapshot     = true
delete_automated_backups = true
```

That combination means Terraform deleted the DB without asking RDS to create a final manual snapshot and asked RDS to delete retained automated backups. Any separate manual snapshots made earlier are not shown in this plan and would normally remain unless separately deleted.

### EC2 root disk

The root EBS volume had:

```text
delete_on_termination = true
```

So the 20 GiB root disk was deleted with the EC2 instance. Files stored only on that disk are not recoverable unless a snapshot or backup exists elsewhere.

### Secrets

Both Secrets Manager resources had:

```text
recovery_window_in_days = 0
```

This requests force deletion without the normal recovery window. The secret values and their versions were deleted, although AWS can take a short time to finish background cleanup.

## 5. Resource Inventory

| # | Terraform address | What it was | Where it lived |
|---:|---|---|---|
| 1 | `aws_db_instance.keycloak` | Amazon RDS PostgreSQL database for Keycloak | AWS |
| 2 | `aws_db_parameter_group.keycloak` | Custom RDS PostgreSQL parameter group | AWS |
| 3 | `aws_db_subnet_group.main` | RDS database subnet group | AWS |
| 4 | `aws_eip.keycloak` | Elastic IP address | AWS |
| 5 | `aws_eip_association.keycloak` | Elastic IP-to-EC2 association | AWS |
| 6 | `aws_iam_instance_profile.keycloak` | IAM instance profile | AWS |
| 7 | `aws_iam_policy.read_db_secret` | Customer-managed IAM policy for database-secret access | AWS |
| 8 | `aws_iam_role.keycloak` | IAM role used by the Keycloak EC2 instance | AWS |
| 9 | `aws_iam_role_policy_attachment.read_db_secret` | Attachment of the database-secret policy to the role | AWS |
| 10 | `aws_iam_role_policy_attachment.ssm_core` | Attachment of the AWS SSM managed policy | AWS |
| 11 | `aws_instance.keycloak` | Keycloak EC2 virtual server | AWS |
| 12 | `aws_internet_gateway.main` | Internet gateway | AWS |
| 13 | `aws_route_table.private` | Private route table | AWS |
| 14 | `aws_route_table.public` | Public route table | AWS |
| 15 | `aws_route_table_association.private_a` | Private subnet A route-table association | AWS |
| 16 | `aws_route_table_association.private_b` | Private subnet B route-table association | AWS |
| 17 | `aws_route_table_association.public` | Public subnet route-table association | AWS |
| 18 | `aws_secretsmanager_secret.db` | Secrets Manager container for database credentials | AWS |
| 19 | `aws_secretsmanager_secret.keycloak_admin` | Secrets Manager container for Keycloak bootstrap administrator credentials | AWS |
| 20 | `aws_secretsmanager_secret_version.db` | Stored version of the database credential value | AWS |
| 21 | `aws_secretsmanager_secret_version.keycloak_admin` | Stored version of the Keycloak admin credential value | AWS |
| 22 | `aws_security_group.database` | Database security group | AWS |
| 23 | `aws_security_group.keycloak` | Keycloak EC2 security group | AWS |
| 24 | `aws_subnet.private_a` | Private subnet A | AWS |
| 25 | `aws_subnet.private_b` | Private subnet B | AWS |
| 26 | `aws_subnet.public` | Public subnet | AWS |
| 27 | `aws_vpc.main` | Virtual Private Cloud | AWS |
| 28 | `aws_vpc_security_group_egress_rule.db_none` | Database security-group outbound rule | AWS |
| 29 | `aws_vpc_security_group_egress_rule.keycloak_all_out` | Keycloak security-group outbound rule | AWS |
| 30 | `aws_vpc_security_group_ingress_rule.db_from_keycloak` | PostgreSQL inbound firewall rule | AWS |
| 31 | `aws_vpc_security_group_ingress_rule.keycloak_http` | Keycloak HTTP inbound firewall rule | AWS |
| 32 | `aws_vpc_security_group_ingress_rule.keycloak_https` | Keycloak HTTPS inbound firewall rule | AWS |
| 33 | `aws_vpc_security_group_ingress_rule.keycloak_ssh` | SSH inbound firewall rule | AWS |
| 34 | `random_id.suffix` | Terraform random suffix | Local Terraform provider |
| 35 | `random_password.db` | Terraform-generated database password | Local Terraform provider |
| 36 | `random_password.keycloak_admin` | Terraform-generated Keycloak administrator password | Local Terraform provider |

## 6. Detailed Resource-by-Resource Explanation

Each section has four parts:

1. What the resource did.
2. What the destroy operation removed.
3. A table explaining every named attribute shown in that resource block. Repeated list values and tag entries remain visible in the raw excerpt.
4. AWS CLI or Terraform commands to check it.

### 6.1. `aws_db_instance.keycloak` — Amazon RDS PostgreSQL database for Keycloak

**Type:** AWS

**What it did:** A managed PostgreSQL database that stored Keycloak users, realms, clients, roles, sessions, and other identity data.

**What destroy removed:** AWS deleted the DB instance named `keycloak-demo-db`. Because `skip_final_snapshot = true`, Terraform did not ask RDS to create a final manual snapshot. Because `delete_automated_backups = true`, its retained automated backups were also set to be removed.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `address` | `"keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com" -> null` | The DNS name clients used to reach the RDS database. Think of it as the database’s street name. |
| `allocated_storage` | `20 -> null` | The starting storage size in gibibytes (GiB). Here, `20` means about 20 GiB. |
| `apply_immediately` | `false -> null` | Whether changes should happen right away instead of waiting for the maintenance window. |
| `arn` | `"arn:aws:rds:us-east-1:406207085797:db:keycloak-demo-db" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `auto_minor_version_upgrade` | `true -> null` | Allows AWS to install compatible minor database engine updates automatically. |
| `availability_zone` | `"us-east-1b" -> null` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `backup_retention_period` | `7 -> null` | How many days automated RDS backups were kept. `7` means one week. |
| `backup_target` | `"region" -> null` | Where RDS backups are managed. `region` means the normal regional RDS backup system. |
| `backup_window` | `"07:00-08:00" -> null` | The daily UTC time window AWS preferred for automated backups. |
| `ca_cert_identifier` | `"rds-ca-rsa2048-g1" -> null` | The AWS certificate authority used to prove the RDS server’s TLS identity. |
| `copy_tags_to_snapshot` | `true -> null` | Copies the database tags to snapshots created from it. |
| `customer_owned_ip_enabled` | `false -> null` | Whether the database used customer-owned IP addresses. `false` means it did not. |
| `database_insights_mode` | `"standard" -> null` | The level of database monitoring insights. `standard` is the standard mode. |
| `db_name` | `"keycloak" -> null` | The initial PostgreSQL database created inside the RDS server. |
| `db_subnet_group_name` | `"keycloak-demo-db-subnets" -> null` | The subnet group that told RDS where it could place network interfaces. |
| `dedicated_log_volume` | `false -> null` | Whether database logs used a separate storage volume. `false` means they shared normal storage. |
| `delete_automated_backups` | `true -> null` | Whether RDS automated backups should also be removed when the DB instance is deleted. |
| `deletion_protection` | `false -> null` | A safety lock that blocks accidental database deletion. `false` means deletion was allowed. |
| `domain_dns_ips` | `[] -> null` | DNS server addresses for a joined directory domain. Empty means no such domain was configured. |
| `enabled_cloudwatch_logs_exports` | `[` | Database log types sent to CloudWatch Logs. |
| `endpoint` | `"keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com:5432" -> null` | The database DNS name plus its port. |
| `engine` | `"postgres" -> null` | The database software. Here it was PostgreSQL. |
| `engine_lifecycle_support` | `"open-source-rds-extended-support" -> null` | The AWS lifecycle support program selected for the engine version. |
| `engine_version` | `"18.3" -> null` | The requested PostgreSQL version. |
| `engine_version_actual` | `"18.3" -> null` | The PostgreSQL version actually running. |
| `hosted_zone_id` | `"Z2R2ITUGPM61AM" -> null` | The AWS Route 53 hosted-zone identifier used internally for the RDS endpoint. |
| `iam_database_authentication_enabled` | `false -> null` | Whether users could log in to PostgreSQL with temporary IAM authentication tokens. |
| `id` | `"db-3HQ7YMCLDBJFS4RVQX2UZEPJ4E" -> null` | The main identifier Terraform used to track this real object. |
| `identifier` | `"keycloak-demo-db" -> null` | The chosen RDS database instance name. |
| `instance_class` | `"db.t4g.micro" -> null` | The RDS computer size. `db.t4g.micro` is a small ARM-based burstable class. |
| `iops` | `3000 -> null` | The number of storage input/output operations per second provisioned for the volume. |
| `kms_key_id` | `"arn:aws:kms:us-east-1:406207085797:key/a5760f13-77af-453f-bb8a-534a85a4bb90" -> null` | The KMS encryption key ARN used to protect data at rest. |
| `latest_restorable_time` | `"2026-07-24T00:01:56Z" -> null` | The most recent time to which point-in-time recovery was available before deletion. |
| `license_model` | `"postgresql-license" -> null` | The software license model. PostgreSQL uses its open-source license. |
| `listener_endpoint` | `[] -> null` | Optional listener endpoints. Empty means none were configured. |
| `maintenance_window` | `"mon:08:30-mon:09:30" -> null` | The weekly UTC window AWS preferred for maintenance. |
| `master_user_secret` | `[] -> null` | Information about an RDS-managed master-user secret. Empty means Terraform managed the password another way. |
| `max_allocated_storage` | `100 -> null` | The maximum storage size RDS autoscaling could grow to. |
| `monitoring_interval` | `0 -> null` | How often enhanced operating-system metrics were collected. `0` means enhanced monitoring was off. |
| `multi_az` | `false -> null` | Whether a standby DB instance existed in another Availability Zone. `false` means no standby. |
| `network_type` | `"IPV4" -> null` | The IP family. `IPV4` means IPv4 only. |
| `option_group_name` | `"default:postgres-18" -> null` | The RDS option group. The shown value was the AWS default for PostgreSQL 18. |
| `parameter_group_name` | `"keycloak-demo-pg18-params" -> null` | The custom database settings group attached to the instance. |
| `password` | `(sensitive value) -> null` | The PostgreSQL master password. Terraform hid it because it is sensitive. |
| `password_wo` | `(write-only attribute) -> null` | A write-only password field. Terraform can send it to AWS but does not read it back. |
| `performance_insights_enabled` | `true -> null` | Turns on RDS Performance Insights for database performance analysis. |
| `performance_insights_kms_key_id` | `"arn:aws:kms:us-east-1:406207085797:key/a5760f13-77af-453f-bb8a-534a85a4bb90" -> null` | The KMS key used to encrypt Performance Insights data. |
| `performance_insights_retention_period` | `7 -> null` | How many days Performance Insights data was retained. |
| `port` | `5432 -> null` | The network port. PostgreSQL normally uses `5432`. |
| `publicly_accessible` | `false -> null` | Whether RDS could receive a public internet address. `false` kept it private. |
| `replicas` | `[] -> null` | Read-replica database identifiers. Empty means there were no read replicas. |
| `resource_id` | `"db-3HQ7YMCLDBJFS4RVQX2UZEPJ4E" -> null` | An internal stable AWS identifier for the RDS database. |
| `skip_final_snapshot` | `true -> null` | Whether RDS deletion skips creating a final manual snapshot. `true` means no final snapshot was made. |
| `status` | `"available" -> null` | The current service status, such as `available`. |
| `storage_encrypted` | `true -> null` | Whether database storage was encrypted. |
| `storage_throughput` | `125 -> null` | The gp3 storage throughput in MiB per second. |
| `storage_type` | `"gp3" -> null` | The EBS-style RDS storage type. `gp3` is general-purpose SSD storage. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `username` | `"kcadmin" -> null` | The PostgreSQL master login name. |
| `vpc_security_group_ids` | `[` | The security-group IDs attached to the resource. |

#### Exact destroy-plan excerpt

```hcl
resource "aws_db_instance" "keycloak" {
      - address                               = "keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com" -> null
      - allocated_storage                     = 20 -> null
      - apply_immediately                     = false -> null
      - arn                                   = "arn:aws:rds:us-east-1:406207085797:db:keycloak-demo-db" -> null
      - auto_minor_version_upgrade            = true -> null
      - availability_zone                     = "us-east-1b" -> null
      - backup_retention_period               = 7 -> null
      - backup_target                         = "region" -> null
      - backup_window                         = "07:00-08:00" -> null
      - ca_cert_identifier                    = "rds-ca-rsa2048-g1" -> null
      - copy_tags_to_snapshot                 = true -> null
      - customer_owned_ip_enabled             = false -> null
      - database_insights_mode                = "standard" -> null
      - db_name                               = "keycloak" -> null
      - db_subnet_group_name                  = "keycloak-demo-db-subnets" -> null
      - dedicated_log_volume                  = false -> null
      - delete_automated_backups              = true -> null
      - deletion_protection                   = false -> null
      - domain_dns_ips                        = [] -> null
      - enabled_cloudwatch_logs_exports       = [
          - "postgresql",
          - "upgrade",
        ] -> null
      - endpoint                              = "keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com:5432" -> null
      - engine                                = "postgres" -> null
      - engine_lifecycle_support              = "open-source-rds-extended-support" -> null
      - engine_version                        = "18.3" -> null
      - engine_version_actual                 = "18.3" -> null
      - hosted_zone_id                        = "Z2R2ITUGPM61AM" -> null
      - iam_database_authentication_enabled   = false -> null
      - id                                    = "db-3HQ7YMCLDBJFS4RVQX2UZEPJ4E" -> null
      - identifier                            = "keycloak-demo-db" -> null
      - instance_class                        = "db.t4g.micro" -> null
      - iops                                  = 3000 -> null
      - kms_key_id                            = "arn:aws:kms:us-east-1:406207085797:key/a5760f13-77af-453f-bb8a-534a85a4bb90" -> null
      - latest_restorable_time                = "2026-07-24T00:01:56Z" -> null
      - license_model                         = "postgresql-license" -> null
      - listener_endpoint                     = [] -> null
      - maintenance_window                    = "mon:08:30-mon:09:30" -> null
      - master_user_secret                    = [] -> null
      - max_allocated_storage                 = 100 -> null
      - monitoring_interval                   = 0 -> null
      - multi_az                              = false -> null
      - network_type                          = "IPV4" -> null
      - option_group_name                     = "default:postgres-18" -> null
      - parameter_group_name                  = "keycloak-demo-pg18-params" -> null
      - password                              = (sensitive value) -> null
      - password_wo                           = (write-only attribute) -> null
      - performance_insights_enabled          = true -> null
      - performance_insights_kms_key_id       = "arn:aws:kms:us-east-1:406207085797:key/a5760f13-77af-453f-bb8a-534a85a4bb90" -> null
      - performance_insights_retention_period = 7 -> null
      - port                                  = 5432 -> null
      - publicly_accessible                   = false -> null
      - replicas                              = [] -> null
      - resource_id                           = "db-3HQ7YMCLDBJFS4RVQX2UZEPJ4E" -> null
      - skip_final_snapshot                   = true -> null
      - status                                = "available" -> null
      - storage_encrypted                     = true -> null
      - storage_throughput                    = 125 -> null
      - storage_type                          = "gp3" -> null
      - tags                                  = {
          - "Name" = "keycloak-demo-db"
        } -> null
      - tags_all                              = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-db"
          - "Project"     = "keycloak-demo"
        } -> null
      - username                              = "kcadmin" -> null
      - vpc_security_group_ids                = [
          - "sg-0267d26156f2a1007",
        ] -> null
        # (13 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws rds describe-db-instances   --db-instance-identifier keycloak-demo-db   --region "$AWS_REGION"   --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Engine:Engine,Version:EngineVersion}'
```

**Expected after successful destroy:** The command should fail with `DBInstanceNotFound`, or a filtered list command should return `[]`.

### 6.2. `aws_db_parameter_group.keycloak` — Custom RDS PostgreSQL parameter group

**Type:** AWS

**What it did:** A named set of database settings for PostgreSQL 18. It changed logging, connection limits, and SSL behavior.

**What destroy removed:** AWS deleted the custom parameter group after the database stopped using it.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:rds:us-east-1:406207085797:pg:keycloak-demo-pg18-params" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak tuning for PostgreSQL 18" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `family` | `"postgres18" -> null` | The database engine family that the parameter group supports. |
| `id` | `"keycloak-demo-pg18-params" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-pg18-params" -> null` | The friendly AWS name of the object. |
| `skip_destroy` | `false -> null` | Whether Terraform should leave the parameter group behind during destroy. `false` means delete it. |
| `tags` | `{} -> null` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `apply_method` | `"immediate" -> null` | When a database setting takes effect: immediately or after reboot. |
| `value` | `"1000" -> null` | The configured value for a parameter. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_db_parameter_group" "keycloak" {
      - arn          = "arn:aws:rds:us-east-1:406207085797:pg:keycloak-demo-pg18-params" -> null
      - description  = "Keycloak tuning for PostgreSQL 18" -> null
      - family       = "postgres18" -> null
      - id           = "keycloak-demo-pg18-params" -> null
      - name         = "keycloak-demo-pg18-params" -> null
      - skip_destroy = false -> null
      - tags         = {} -> null
      - tags_all     = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
        # (1 unchanged attribute hidden)

      - parameter {
          - apply_method = "immediate" -> null
          - name         = "log_min_duration_statement" -> null
          - value        = "1000" -> null
        }
      - parameter {
          - apply_method = "pending-reboot" -> null
          - name         = "max_connections" -> null
          - value        = "150" -> null
        }
      - parameter {
          - apply_method = "pending-reboot" -> null
          - name         = "rds.force_ssl" -> null
          - value        = "1" -> null
        }
    }
```

#### Check whether it exists

```bash
aws rds describe-db-parameter-groups   --db-parameter-group-name keycloak-demo-pg18-params   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `DBParameterGroupNotFound`.

### 6.3. `aws_db_subnet_group.main` — RDS database subnet group

**Type:** AWS

**What it did:** A list telling RDS which private subnets it was allowed to use. It included one private subnet in `us-east-1a` and one in `us-east-1b`.

**What destroy removed:** AWS deleted the subnet group after the RDS database was gone.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:rds:us-east-1:406207085797:subgrp:keycloak-demo-db-subnets" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Private subnets for the Keycloak database" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `"keycloak-demo-db-subnets" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-db-subnets" -> null` | The friendly AWS name of the object. |
| `subnet_ids` | `[` | The list of subnets in a subnet group. |
| `supported_network_types` | `[` | IP network families supported by the subnet group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_db_subnet_group" "main" {
      - arn                     = "arn:aws:rds:us-east-1:406207085797:subgrp:keycloak-demo-db-subnets" -> null
      - description             = "Private subnets for the Keycloak database" -> null
      - id                      = "keycloak-demo-db-subnets" -> null
      - name                    = "keycloak-demo-db-subnets" -> null
      - subnet_ids              = [
          - "subnet-018ec8fc3cc46a312",
          - "subnet-0267a69101df5beb2",
        ] -> null
      - supported_network_types = [
          - "IPV4",
        ] -> null
      - tags                    = {
          - "Name" = "keycloak-demo-db-subnets"
        } -> null
      - tags_all                = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-db-subnets"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id                  = "vpc-0d470b94ebdffafc5" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws rds describe-db-subnet-groups   --db-subnet-group-name keycloak-demo-db-subnets   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `DBSubnetGroupNotFoundFault`.

### 6.4. `aws_eip.keycloak` — Elastic IP address

**Type:** AWS

**What it did:** A fixed public IPv4 address assigned to the Keycloak EC2 server so the public address would not change during a normal stop and start.

**What destroy removed:** Terraform released allocation `eipalloc-00b08d704aacb7029`. The address `34.197.55.175` returned to the AWS public address pool and should not be treated as yours anymore.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `allocation_id` | `"eipalloc-00b08d704aacb7029" -> null` | The AWS identifier for an allocated Elastic IP address. |
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:elastic-ip/eipalloc-00b08d704aacb7029" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `association_id` | `"eipassoc-0d1b25e1f4657391e" -> null` | The identifier for the link between an Elastic IP and a network interface or instance. |
| `domain` | `"vpc" -> null` | The network scope of the Elastic IP. `vpc` means it was for EC2-VPC. |
| `id` | `"eipalloc-00b08d704aacb7029" -> null` | The main identifier Terraform used to track this real object. |
| `instance` | `"i-0f7317687e9066068" -> null` | The EC2 instance ID associated with the Elastic IP. |
| `network_border_group` | `"us-east-1" -> null` | The AWS network location from which the public IP was advertised. |
| `network_interface` | `"eni-0c96e91f003c0c99a" -> null` | The Elastic Network Interface attached to the address. |
| `private_dns` | `"ip-10-42-1-210.ec2.internal" -> null` | The internal AWS DNS name. |
| `private_ip` | `"10.42.1.210" -> null` | The private IPv4 address inside the VPC. |
| `public_dns` | `"ec2-34-197-55-175.compute-1.amazonaws.com" -> null` | The public AWS DNS name. |
| `public_ip` | `"34.197.55.175" -> null` | The public IPv4 address. |
| `public_ipv4_pool` | `"amazon" -> null` | The pool that supplied the public address. `amazon` means the normal AWS pool. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc` | `true -> null` | Legacy field confirming the Elastic IP belongs to a VPC. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_eip" "keycloak" {
      - allocation_id            = "eipalloc-00b08d704aacb7029" -> null
      - arn                      = "arn:aws:ec2:us-east-1:406207085797:elastic-ip/eipalloc-00b08d704aacb7029" -> null
      - association_id           = "eipassoc-0d1b25e1f4657391e" -> null
      - domain                   = "vpc" -> null
      - id                       = "eipalloc-00b08d704aacb7029" -> null
      - instance                 = "i-0f7317687e9066068" -> null
      - network_border_group     = "us-east-1" -> null
      - network_interface        = "eni-0c96e91f003c0c99a" -> null
      - private_dns              = "ip-10-42-1-210.ec2.internal" -> null
      - private_ip               = "10.42.1.210" -> null
      - public_dns               = "ec2-34-197-55-175.compute-1.amazonaws.com" -> null
      - public_ip                = "34.197.55.175" -> null
      - public_ipv4_pool         = "amazon" -> null
      - tags                     = {
          - "Name" = "keycloak-demo-keycloak-eip"
        } -> null
      - tags_all                 = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-keycloak-eip"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc                      = true -> null
        # (4 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-addresses   --allocation-ids eipalloc-00b08d704aacb7029   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidAllocationID.NotFound` or return no address when filtering.

### 6.5. `aws_eip_association.keycloak` — Elastic IP-to-EC2 association

**Type:** AWS

**What it did:** The link that attached the Elastic IP to the Keycloak network interface and private address.

**What destroy removed:** Terraform removed the link before terminating the instance and releasing the Elastic IP.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `allocation_id` | `"eipalloc-00b08d704aacb7029" -> null` | The AWS identifier for an allocated Elastic IP address. |
| `id` | `"eipassoc-0d1b25e1f4657391e" -> null` | The main identifier Terraform used to track this real object. |
| `instance_id` | `"i-0f7317687e9066068" -> null` | The EC2 instance identifier used by the Elastic IP association. |
| `network_interface_id` | `"eni-0c96e91f003c0c99a" -> null` | The identifier of an Elastic Network Interface. |
| `private_ip_address` | `"10.42.1.210" -> null` | The private IPv4 address used by the association. |
| `public_ip` | `"34.197.55.175" -> null` | The public IPv4 address. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_eip_association" "keycloak" {
      - allocation_id        = "eipalloc-00b08d704aacb7029" -> null
      - id                   = "eipassoc-0d1b25e1f4657391e" -> null
      - instance_id          = "i-0f7317687e9066068" -> null
      - network_interface_id = "eni-0c96e91f003c0c99a" -> null
      - private_ip_address   = "10.42.1.210" -> null
      - public_ip            = "34.197.55.175" -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-addresses   --filters Name=association-id,Values=eipassoc-0d1b25e1f4657391e   --region "$AWS_REGION"   --query 'Addresses'
```

**Expected after successful destroy:** The command should return `[]`.

### 6.6. `aws_iam_instance_profile.keycloak` — IAM instance profile

**Type:** AWS

**What it did:** The container that let an IAM role be attached to the EC2 instance.

**What destroy removed:** AWS deleted the instance profile after the EC2 instance no longer needed it.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:iam::406207085797:instance-profile/keycloak-demo-keycloak-profile-39692c" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `create_date` | `"2026-07-23T23:47:16Z" -> null` | The date and time AWS created the IAM object. |
| `id` | `"keycloak-demo-keycloak-profile-39692c" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-keycloak-profile-39692c" -> null` | The friendly AWS name of the object. |
| `path` | `"/" -> null` | The IAM folder-like path. `/` means the top level. |
| `role` | `"keycloak-demo-keycloak-role-39692c" -> null` | The IAM role name placed in the instance profile or used by an attachment. |
| `tags` | `{} -> null` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `unique_id` | `"AIPAV5E6UHTS72ORWXQ3K" -> null` | An AWS-generated IAM identifier that is different from the friendly name. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_iam_instance_profile" "keycloak" {
      - arn         = "arn:aws:iam::406207085797:instance-profile/keycloak-demo-keycloak-profile-39692c" -> null
      - create_date = "2026-07-23T23:47:16Z" -> null
      - id          = "keycloak-demo-keycloak-profile-39692c" -> null
      - name        = "keycloak-demo-keycloak-profile-39692c" -> null
      - path        = "/" -> null
      - role        = "keycloak-demo-keycloak-role-39692c" -> null
      - tags        = {} -> null
      - tags_all    = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - unique_id   = "AIPAV5E6UHTS72ORWXQ3K" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws iam get-instance-profile   --instance-profile-name keycloak-demo-keycloak-profile-39692c
```

**Expected after successful destroy:** The command should fail with `NoSuchEntity`.

### 6.7. `aws_iam_policy.read_db_secret` — Customer-managed IAM policy for database-secret access

**Type:** AWS

**What it did:** A least-privilege permission document that allowed only `DescribeSecret` and `GetSecretValue` for the Keycloak database secret path.

**What destroy removed:** Terraform detached and then deleted the customer-managed policy.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `attachment_count` | `1 -> null` | How many users, groups, or roles currently had the policy attached. |
| `description` | `"Read only the Keycloak database secret" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `"arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-read-db-secret-39692c" -> null` | The friendly AWS name of the object. |
| `path` | `"/" -> null` | The IAM folder-like path. `/` means the top level. |
| `policy` | `jsonencode(` | The JSON permissions document describing allowed or denied AWS actions. |
| `Statement` | `[` | The list of permission or trust rules in a policy document. |
| `Action` | `[` | The AWS API operations a policy statement controls. |
| `Effect` | `"Allow"` | Whether the statement allows or denies the listed actions. |
| `Resource` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-*"` | Which AWS resource ARNs the permission applies to. |
| `Sid` | `"ReadOnlyTheKeycloakDbSecret"` | An optional statement name used to make a policy easier to read. |
| `Version` | `"2012-10-17"` | The IAM policy-language version, not a revision number for your policy. |
| `policy_id` | `"ANPAV5E6UHTS362TYLWS3" -> null` | AWS’s unique identifier for a customer-managed IAM policy. |
| `tags` | `{} -> null` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_iam_policy" "read_db_secret" {
      - arn              = "arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null
      - attachment_count = 1 -> null
      - description      = "Read only the Keycloak database secret" -> null
      - id               = "arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null
      - name             = "keycloak-demo-read-db-secret-39692c" -> null
      - path             = "/" -> null
      - policy           = jsonencode(
            {
              - Statement = [
                  - {
                      - Action   = [
                          - "secretsmanager:GetSecretValue",
                          - "secretsmanager:DescribeSecret",
                        ]
                      - Effect   = "Allow"
                      - Resource = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-*"
                      - Sid      = "ReadOnlyTheKeycloakDbSecret"
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> null
      - policy_id        = "ANPAV5E6UHTS362TYLWS3" -> null
      - tags             = {} -> null
      - tags_all         = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws iam get-policy   --policy-arn arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c
```

**Expected after successful destroy:** The command should fail with `NoSuchEntity`.

### 6.8. `aws_iam_role.keycloak` — IAM role used by the Keycloak EC2 instance

**Type:** AWS

**What it did:** The AWS identity used by software on the EC2 instance. EC2 was trusted to assume it. It had SSM access and permission to read the database secret.

**What destroy removed:** Terraform detached its policies, removed it from the instance profile, and deleted the role.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:iam::406207085797:role/keycloak-demo-keycloak-role-39692c" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assume_role_policy` | `jsonencode(` | The trust policy describing who is allowed to use the role. |
| `Statement` | `[` | The list of permission or trust rules in a policy document. |
| `Action` | `"sts:AssumeRole"` | The AWS API operations a policy statement controls. |
| `Effect` | `"Allow"` | Whether the statement allows or denies the listed actions. |
| `Principal` | `{` | Who is trusted by a role policy. |
| `Service` | `"ec2.amazonaws.com"` | The AWS service principal. `ec2.amazonaws.com` means EC2. |
| `Sid` | `"AllowEC2ToAssume"` | An optional statement name used to make a policy easier to read. |
| `Version` | `"2012-10-17"` | The IAM policy-language version, not a revision number for your policy. |
| `create_date` | `"2026-07-23T23:47:15Z" -> null` | The date and time AWS created the IAM object. |
| `description` | `"Least privilege role for the Keycloak EC2 instance" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `force_detach_policies` | `false -> null` | Whether IAM should force-detach policies during role deletion. `false` means Terraform must detach them first. |
| `id` | `"keycloak-demo-keycloak-role-39692c" -> null` | The main identifier Terraform used to track this real object. |
| `managed_policy_arns` | `[` | Managed policies attached to the role. |
| `max_session_duration` | `3600 -> null` | The longest role session in seconds. `3600` means one hour. |
| `name` | `"keycloak-demo-keycloak-role-39692c" -> null` | The friendly AWS name of the object. |
| `path` | `"/" -> null` | The IAM folder-like path. `/` means the top level. |
| `tags` | `{} -> null` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `unique_id` | `"AROAV5E6UHTSX5PY3EVUP" -> null` | An AWS-generated IAM identifier that is different from the friendly name. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_iam_role" "keycloak" {
      - arn                   = "arn:aws:iam::406207085797:role/keycloak-demo-keycloak-role-39692c" -> null
      - assume_role_policy    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRole"
                      - Effect    = "Allow"
                      - Principal = {
                          - Service = "ec2.amazonaws.com"
                        }
                      - Sid       = "AllowEC2ToAssume"
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> null
      - create_date           = "2026-07-23T23:47:15Z" -> null
      - description           = "Least privilege role for the Keycloak EC2 instance" -> null
      - force_detach_policies = false -> null
      - id                    = "keycloak-demo-keycloak-role-39692c" -> null
      - managed_policy_arns   = [
          - "arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c",
          - "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        ] -> null
      - max_session_duration  = 3600 -> null
      - name                  = "keycloak-demo-keycloak-role-39692c" -> null
      - path                  = "/" -> null
      - tags                  = {} -> null
      - tags_all              = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - unique_id             = "AROAV5E6UHTSX5PY3EVUP" -> null
        # (2 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws iam get-role   --role-name keycloak-demo-keycloak-role-39692c
```

**Expected after successful destroy:** The command should fail with `NoSuchEntity`.

### 6.9. `aws_iam_role_policy_attachment.read_db_secret` — Attachment of the database-secret policy to the role

**Type:** AWS

**What it did:** A relationship that connected the custom secret-reading policy to the EC2 role.

**What destroy removed:** Terraform detached the policy before deleting either the policy or role.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `id` | `"keycloak-demo-keycloak-role-39692c-20260723234716141700000004" -> null` | The main identifier Terraform used to track this real object. |
| `policy_arn` | `"arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null` | The full ARN of the managed IAM policy being attached. |
| `role` | `"keycloak-demo-keycloak-role-39692c" -> null` | The IAM role name placed in the instance profile or used by an attachment. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_iam_role_policy_attachment" "read_db_secret" {
      - id         = "keycloak-demo-keycloak-role-39692c-20260723234716141700000004" -> null
      - policy_arn = "arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c" -> null
      - role       = "keycloak-demo-keycloak-role-39692c" -> null
    }
```

#### Check whether it exists

```bash
aws iam list-attached-role-policies   --role-name keycloak-demo-keycloak-role-39692c
```

**Expected after successful destroy:** The role is gone, so the command should fail with `NoSuchEntity`. Before deletion, the policy ARN would have appeared in the list.

### 6.10. `aws_iam_role_policy_attachment.ssm_core` — Attachment of the AWS SSM managed policy

**Type:** AWS

**What it did:** A relationship that gave the EC2 server the standard permissions needed to register with AWS Systems Manager Session Manager.

**What destroy removed:** Terraform detached the AWS-managed policy from this role. The global AWS-managed policy itself was not deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `id` | `"keycloak-demo-keycloak-role-39692c-20260723234716141700000005" -> null` | The main identifier Terraform used to track this real object. |
| `policy_arn` | `"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" -> null` | The full ARN of the managed IAM policy being attached. |
| `role` | `"keycloak-demo-keycloak-role-39692c" -> null` | The IAM role name placed in the instance profile or used by an attachment. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_iam_role_policy_attachment" "ssm_core" {
      - id         = "keycloak-demo-keycloak-role-39692c-20260723234716141700000005" -> null
      - policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" -> null
      - role       = "keycloak-demo-keycloak-role-39692c" -> null
    }
```

#### Check whether it exists

```bash
aws iam list-attached-role-policies   --role-name keycloak-demo-keycloak-role-39692c
```

**Expected after successful destroy:** The role is gone, so the command should fail with `NoSuchEntity`. The AWS-managed policy `AmazonSSMManagedInstanceCore` still exists in AWS.

### 6.11. `aws_instance.keycloak` — Keycloak EC2 virtual server

**Type:** AWS

**What it did:** A `t4g.small` ARM-based virtual server in the public subnet. It ran Keycloak, had an encrypted 20 GiB root disk, a public address, and an IAM role.

**What destroy removed:** Terraform terminated instance `i-0f7317687e9066068`. Its root EBS volume had `delete_on_termination = true`, so that disk was also deleted. The attached network interface and public DNS record were removed as part of termination.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `ami` | `(sensitive value) -> null` | The Amazon Machine Image used to start the server. Terraform hid the value because it was marked sensitive. |
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:instance/i-0f7317687e9066068" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `associate_public_ip_address` | `true -> null` | Whether the primary network interface received a public IPv4 address at launch. |
| `availability_zone` | `"us-east-1a" -> null` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `cpu_core_count` | `2 -> null` | Number of CPU cores shown for the instance. |
| `cpu_threads_per_core` | `1 -> null` | Number of hardware threads per CPU core. |
| `disable_api_stop` | `false -> null` | A protection flag that can block API stop calls. `false` means stopping was allowed. |
| `disable_api_termination` | `false -> null` | A protection flag that can block termination. `false` means deletion was allowed. |
| `ebs_optimized` | `false -> null` | Whether the instance used explicitly enabled EBS optimization. Some newer types include it by default. |
| `get_password_data` | `false -> null` | Whether Terraform tried to retrieve Windows administrator password data. `false` is normal for Linux. |
| `hibernation` | `false -> null` | Whether EC2 hibernation was enabled. |
| `iam_instance_profile` | `"keycloak-demo-keycloak-profile-39692c" -> null` | The instance profile attached to the EC2 server. |
| `id` | `"i-0f7317687e9066068" -> null` | The main identifier Terraform used to track this real object. |
| `instance_initiated_shutdown_behavior` | `"stop" -> null` | What AWS should do when the operating system shuts down. `stop` means stop, not terminate. |
| `instance_state` | `"running" -> null` | The EC2 state at plan time. It was `running`. |
| `instance_type` | `"t4g.small" -> null` | The EC2 computer size. `t4g.small` is an ARM-based burstable instance. |
| `ipv6_address_count` | `0 -> null` | How many IPv6 addresses were assigned. |
| `ipv6_addresses` | `[] -> null` | The actual IPv6 addresses. Empty means none. |
| `monitoring` | `false -> null` | Whether detailed one-minute EC2 monitoring was enabled. `false` means basic monitoring. |
| `placement_partition_number` | `0 -> null` | Partition placement-group number. `0` means no special partition placement. |
| `primary_network_interface_id` | `"eni-0c96e91f003c0c99a" -> null` | The main virtual network card attached to the instance. |
| `private_dns` | `"ip-10-42-1-210.ec2.internal" -> null` | The internal AWS DNS name. |
| `private_ip` | `"10.42.1.210" -> null` | The private IPv4 address inside the VPC. |
| `public_dns` | `"ec2-34-197-55-175.compute-1.amazonaws.com" -> null` | The public AWS DNS name. |
| `public_ip` | `"34.197.55.175" -> null` | The public IPv4 address. |
| `secondary_private_ips` | `[] -> null` | Extra private IPv4 addresses. Empty means none. |
| `security_groups` | `[] -> null` | Security-group names used in EC2-Classic style output. Empty is normal when IDs are used in a VPC. |
| `source_dest_check` | `true -> null` | Normal EC2 packet checking. `true` is right for an application server; routers often disable it. |
| `subnet_id` | `"subnet-09369b387fc6af56d" -> null` | The subnet containing the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `tenancy` | `"default" -> null` | Whether hardware was shared or dedicated. `default` means standard shared tenancy. |
| `user_data` | `"069d98eed022b4232528fd05dac20ed514bc0377" -> null` | A hash of the startup script, not the script text itself. |
| `user_data_replace_on_change` | `true -> null` | Whether changing the startup script causes Terraform to replace the EC2 instance. |
| `vpc_security_group_ids` | `[` | The security-group IDs attached to the resource. |
| `capacity_reservation_preference` | `"open" -> null` | Whether the instance may use an open matching Capacity Reservation. |
| `core_count` | `2 -> null` | Number of CPU cores in the nested CPU options block. |
| `threads_per_core` | `1 -> null` | Number of CPU threads per core in the nested CPU options block. |
| `cpu_credits` | `"unlimited" -> null` | How burst credits work. `unlimited` allows bursting beyond earned credits, which can add charges. |
| `enabled` | `false -> null` | Whether the feature in that nested block was enabled. |
| `auto_recovery` | `"default" -> null` | How EC2 handles automatic recovery from host problems. `default` lets AWS use its default behavior. |
| `http_endpoint` | `"enabled" -> null` | Whether the EC2 Instance Metadata Service endpoint was enabled. |
| `http_protocol_ipv6` | `"disabled" -> null` | Whether metadata could be reached over IPv6. |
| `http_put_response_hop_limit` | `1 -> null` | How many network hops an IMDSv2 token response may travel. `1` is restrictive. |
| `http_tokens` | `"required" -> null` | Whether IMDSv2 tokens are required. `required` blocks older IMDSv1 requests. |
| `instance_metadata_tags` | `"enabled" -> null` | Whether instance tags can be read through the metadata service. |
| `enable_resource_name_dns_a_record` | `false -> null` | Whether an IPv4 A record was created for the resource-based private DNS name. |
| `enable_resource_name_dns_aaaa_record` | `false -> null` | Whether an IPv6 AAAA record was created. |
| `hostname_type` | `"ip-name" -> null` | The private hostname style. `ip-name` uses the private IP in the name. |
| `delete_on_termination` | `true -> null` | Whether the disk is automatically deleted when the EC2 instance is terminated. |
| `device_name` | `"/dev/xvda" -> null` | The Linux device mapping name for the disk. |
| `encrypted` | `true -> null` | Whether the disk was encrypted. |
| `iops` | `3000 -> null` | The number of storage input/output operations per second provisioned for the volume. |
| `kms_key_id` | `"arn:aws:kms:us-east-1:406207085797:key/1393b9ee-5131-4e8d-b093-c8f31ac3eb7e" -> null` | The KMS encryption key ARN used to protect data at rest. |
| `throughput` | `125 -> null` | The gp3 disk throughput in MiB per second. |
| `volume_id` | `"vol-011815d81364dd80f" -> null` | The EBS volume identifier. |
| `volume_size` | `20 -> null` | Disk size in GiB. |
| `volume_type` | `"gp3" -> null` | The EBS volume type. `gp3` is general-purpose SSD. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_instance" "keycloak" {
      - ami                                  = (sensitive value) -> null
      - arn                                  = "arn:aws:ec2:us-east-1:406207085797:instance/i-0f7317687e9066068" -> null
      - associate_public_ip_address          = true -> null
      - availability_zone                    = "us-east-1a" -> null
      - cpu_core_count                       = 2 -> null
      - cpu_threads_per_core                 = 1 -> null
      - disable_api_stop                     = false -> null
      - disable_api_termination              = false -> null
      - ebs_optimized                        = false -> null
      - get_password_data                    = false -> null
      - hibernation                          = false -> null
      - iam_instance_profile                 = "keycloak-demo-keycloak-profile-39692c" -> null
      - id                                   = "i-0f7317687e9066068" -> null
      - instance_initiated_shutdown_behavior = "stop" -> null
      - instance_state                       = "running" -> null
      - instance_type                        = "t4g.small" -> null
      - ipv6_address_count                   = 0 -> null
      - ipv6_addresses                       = [] -> null
      - monitoring                           = false -> null
      - placement_partition_number           = 0 -> null
      - primary_network_interface_id         = "eni-0c96e91f003c0c99a" -> null
      - private_dns                          = "ip-10-42-1-210.ec2.internal" -> null
      - private_ip                           = "10.42.1.210" -> null
      - public_dns                           = "ec2-34-197-55-175.compute-1.amazonaws.com" -> null
      - public_ip                            = "34.197.55.175" -> null
      - secondary_private_ips                = [] -> null
      - security_groups                      = [] -> null
      - source_dest_check                    = true -> null
      - subnet_id                            = "subnet-09369b387fc6af56d" -> null
      - tags                                 = {
          - "Name" = "keycloak-demo-keycloak"
        } -> null
      - tags_all                             = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-keycloak"
          - "Project"     = "keycloak-demo"
        } -> null
      - tenancy                              = "default" -> null
      - user_data                            = "069d98eed022b4232528fd05dac20ed514bc0377" -> null
      - user_data_replace_on_change          = true -> null
      - vpc_security_group_ids               = [
          - "sg-0e73f9e971b5c6e36",
        ] -> null
        # (7 unchanged attributes hidden)

      - capacity_reservation_specification {
          - capacity_reservation_preference = "open" -> null
        }

      - cpu_options {
          - core_count       = 2 -> null
          - threads_per_core = 1 -> null
            # (1 unchanged attribute hidden)
        }

      - credit_specification {
          - cpu_credits = "unlimited" -> null
        }

      - enclave_options {
          - enabled = false -> null
        }

      - maintenance_options {
          - auto_recovery = "default" -> null
        }

      - metadata_options {
          - http_endpoint               = "enabled" -> null
          - http_protocol_ipv6          = "disabled" -> null
          - http_put_response_hop_limit = 1 -> null
          - http_tokens                 = "required" -> null
          - instance_metadata_tags      = "enabled" -> null
        }

      - private_dns_name_options {
          - enable_resource_name_dns_a_record    = false -> null
          - enable_resource_name_dns_aaaa_record = false -> null
          - hostname_type                        = "ip-name" -> null
        }

      - root_block_device {
          - delete_on_termination = true -> null
          - device_name           = "/dev/xvda" -> null
          - encrypted             = true -> null
          - iops                  = 3000 -> null
          - kms_key_id            = "arn:aws:kms:us-east-1:406207085797:key/1393b9ee-5131-4e8d-b093-c8f31ac3eb7e" -> null
          - tags                  = {} -> null
          - tags_all              = {
              - "Environment" = "dev"
              - "ManagedBy"   = "terraform"
              - "Project"     = "keycloak-demo"
            } -> null
          - throughput            = 125 -> null
          - volume_id             = "vol-011815d81364dd80f" -> null
          - volume_size           = 20 -> null
          - volume_type           = "gp3" -> null
        }
    }
```

#### Check whether it exists

```bash
aws ec2 describe-instances   --instance-ids i-0f7317687e9066068   --region "$AWS_REGION"   --query 'Reservations[].Instances[].{State:State.Name,Type:InstanceType,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress}'
```

**Expected after successful destroy:** For a short time, the result can still show `terminated`. Later it normally fails with `InvalidInstanceID.NotFound` or returns no instance.

### 6.12. `aws_internet_gateway.main` — Internet gateway

**Type:** AWS

**What it did:** The VPC doorway to and from the public internet. The public route table sent internet-bound traffic to it.

**What destroy removed:** Terraform detached and deleted the internet gateway after the public subnet and EC2 internet dependencies were gone.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:internet-gateway/igw-0fb2b12baa6f748ae" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `"igw-0fb2b12baa6f748ae" -> null` | The main identifier Terraform used to track this real object. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_internet_gateway" "main" {
      - arn      = "arn:aws:ec2:us-east-1:406207085797:internet-gateway/igw-0fb2b12baa6f748ae" -> null
      - id       = "igw-0fb2b12baa6f748ae" -> null
      - owner_id = "406207085797" -> null
      - tags     = {
          - "Name" = "keycloak-demo-igw"
        } -> null
      - tags_all = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-igw"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id   = "vpc-0d470b94ebdffafc5" -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-internet-gateways   --internet-gateway-ids igw-0fb2b12baa6f748ae   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidInternetGatewayID.NotFound`.

### 6.13. `aws_route_table.private` — Private route table

**Type:** AWS

**What it did:** The traffic map for the two private database subnets. Its route list was empty except for the automatic local VPC route, so it did not provide internet access.

**What destroy removed:** Terraform removed its subnet associations and then deleted the route table.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:route-table/rtb-019c61d71d5eb425a" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `"rtb-019c61d71d5eb425a" -> null` | The main identifier Terraform used to track this real object. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `propagating_vgws` | `[] -> null` | Virtual private gateways automatically propagating routes. Empty means none. |
| `route` | `[] -> null` | The route entries in the route table. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_route_table" "private" {
      - arn              = "arn:aws:ec2:us-east-1:406207085797:route-table/rtb-019c61d71d5eb425a" -> null
      - id               = "rtb-019c61d71d5eb425a" -> null
      - owner_id         = "406207085797" -> null
      - propagating_vgws = [] -> null
      - route            = [] -> null
      - tags             = {
          - "Name" = "keycloak-demo-rt-private"
        } -> null
      - tags_all         = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-rt-private"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id           = "vpc-0d470b94ebdffafc5" -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-route-tables   --route-table-ids rtb-019c61d71d5eb425a   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidRouteTableID.NotFound`.

### 6.14. `aws_route_table.public` — Public route table

**Type:** AWS

**What it did:** The traffic map for the public subnet. It included `0.0.0.0/0` pointing to the internet gateway.

**What destroy removed:** Terraform removed the subnet association and deleted this route table.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:route-table/rtb-04b1e80ee066674dd" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `"rtb-04b1e80ee066674dd" -> null` | The main identifier Terraform used to track this real object. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `propagating_vgws` | `[] -> null` | Virtual private gateways automatically propagating routes. Empty means none. |
| `route` | `[` | The route entries in the route table. |
| `cidr_block` | `"0.0.0.0/0"` | An IPv4 network range written in CIDR form. |
| `gateway_id` | `"igw-0fb2b12baa6f748ae"` | The target internet gateway for a route. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_route_table" "public" {
      - arn              = "arn:aws:ec2:us-east-1:406207085797:route-table/rtb-04b1e80ee066674dd" -> null
      - id               = "rtb-04b1e80ee066674dd" -> null
      - owner_id         = "406207085797" -> null
      - propagating_vgws = [] -> null
      - route            = [
          - {
              - cidr_block                 = "0.0.0.0/0"
              - gateway_id                 = "igw-0fb2b12baa6f748ae"
                # (11 unchanged attributes hidden)
            },
        ] -> null
      - tags             = {
          - "Name" = "keycloak-demo-rt-public"
        } -> null
      - tags_all         = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-rt-public"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id           = "vpc-0d470b94ebdffafc5" -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-route-tables   --route-table-ids rtb-04b1e80ee066674dd   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidRouteTableID.NotFound`.

### 6.15. `aws_route_table_association.private_a` — Private subnet A route-table association

**Type:** AWS

**What it did:** The link that told subnet `subnet-0267a69101df5beb2` to use the private route table.

**What destroy removed:** Terraform deleted this relationship before deleting the route table or subnet.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `id` | `"rtbassoc-08721f9399f1f752e" -> null` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `"rtb-019c61d71d5eb425a" -> null` | The route table used by an association. |
| `subnet_id` | `"subnet-0267a69101df5beb2" -> null` | The subnet containing the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_route_table_association" "private_a" {
      - id             = "rtbassoc-08721f9399f1f752e" -> null
      - route_table_id = "rtb-019c61d71d5eb425a" -> null
      - subnet_id      = "subnet-0267a69101df5beb2" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-route-tables   --filters Name=association.route-table-association-id,Values=rtbassoc-08721f9399f1f752e   --region "$AWS_REGION"   --query 'RouteTables'
```

**Expected after successful destroy:** The command should return `[]`.

### 6.16. `aws_route_table_association.private_b` — Private subnet B route-table association

**Type:** AWS

**What it did:** The link that told subnet `subnet-018ec8fc3cc46a312` to use the private route table.

**What destroy removed:** Terraform deleted this relationship before deleting the route table or subnet.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `id` | `"rtbassoc-023dca32d5ff4761d" -> null` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `"rtb-019c61d71d5eb425a" -> null` | The route table used by an association. |
| `subnet_id` | `"subnet-018ec8fc3cc46a312" -> null` | The subnet containing the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_route_table_association" "private_b" {
      - id             = "rtbassoc-023dca32d5ff4761d" -> null
      - route_table_id = "rtb-019c61d71d5eb425a" -> null
      - subnet_id      = "subnet-018ec8fc3cc46a312" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-route-tables   --filters Name=association.route-table-association-id,Values=rtbassoc-023dca32d5ff4761d   --region "$AWS_REGION"   --query 'RouteTables'
```

**Expected after successful destroy:** The command should return `[]`.

### 6.17. `aws_route_table_association.public` — Public subnet route-table association

**Type:** AWS

**What it did:** The link that made the public subnet use the public route table.

**What destroy removed:** Terraform deleted this relationship before deleting the public route table and subnet.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `id` | `"rtbassoc-0096ef281f7a8d3d1" -> null` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `"rtb-04b1e80ee066674dd" -> null` | The route table used by an association. |
| `subnet_id` | `"subnet-09369b387fc6af56d" -> null` | The subnet containing the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_route_table_association" "public" {
      - id             = "rtbassoc-0096ef281f7a8d3d1" -> null
      - route_table_id = "rtb-04b1e80ee066674dd" -> null
      - subnet_id      = "subnet-09369b387fc6af56d" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-route-tables   --filters Name=association.route-table-association-id,Values=rtbassoc-0096ef281f7a8d3d1   --region "$AWS_REGION"   --query 'RouteTables'
```

**Expected after successful destroy:** The command should return `[]`.

### 6.18. `aws_secretsmanager_secret.db` — Secrets Manager container for database credentials

**Type:** AWS

**What it did:** A protected AWS object that held the Keycloak PostgreSQL administrator credentials.

**What destroy removed:** Terraform deleted the secret with `recovery_window_in_days = 0`, which means force deletion without a recovery waiting period. AWS may finish the final cleanup asynchronously.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak RDS PostgreSQL master credentials" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `force_overwrite_replica_secret` | `false -> null` | Whether a replica secret with the same name may be overwritten. |
| `id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo/db-credentials-39692c" -> null` | The friendly AWS name of the object. |
| `recovery_window_in_days` | `0 -> null` | Days a deleted secret remains recoverable. `0` means force deletion without recovery. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_secretsmanager_secret" "db" {
      - arn                            = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null
      - description                    = "Keycloak RDS PostgreSQL master credentials" -> null
      - force_overwrite_replica_secret = false -> null
      - id                             = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null
      - name                           = "keycloak-demo/db-credentials-39692c" -> null
      - recovery_window_in_days        = 0 -> null
      - tags                           = {
          - "Name" = "keycloak-demo-db-credentials"
        } -> null
      - tags_all                       = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-db-credentials"
          - "Project"     = "keycloak-demo"
        } -> null
        # (3 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws secretsmanager describe-secret   --secret-id keycloak-demo/db-credentials-39692c   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `ResourceNotFoundException`. Immediately after force deletion, retry if AWS is still finishing background cleanup.

### 6.19. `aws_secretsmanager_secret.keycloak_admin` — Secrets Manager container for Keycloak bootstrap administrator credentials

**Type:** AWS

**What it did:** A protected AWS object that held the initial Keycloak admin username and password.

**What destroy removed:** Terraform force-deleted the secret because its recovery window was zero.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak bootstrap admin credentials" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `force_overwrite_replica_secret` | `false -> null` | Whether a replica secret with the same name may be overwritten. |
| `id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo/db-keycloak-admin-39692c" -> null` | The friendly AWS name of the object. |
| `recovery_window_in_days` | `0 -> null` | Days a deleted secret remains recoverable. `0` means force deletion without recovery. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_secretsmanager_secret" "keycloak_admin" {
      - arn                            = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null
      - description                    = "Keycloak bootstrap admin credentials" -> null
      - force_overwrite_replica_secret = false -> null
      - id                             = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null
      - name                           = "keycloak-demo/db-keycloak-admin-39692c" -> null
      - recovery_window_in_days        = 0 -> null
      - tags                           = {
          - "Name" = "keycloak-demo-keycloak-admin"
        } -> null
      - tags_all                       = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-keycloak-admin"
          - "Project"     = "keycloak-demo"
        } -> null
        # (3 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws secretsmanager describe-secret   --secret-id keycloak-demo/db-keycloak-admin-39692c   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `ResourceNotFoundException`.

### 6.20. `aws_secretsmanager_secret_version.db` — Stored version of the database credential value

**Type:** AWS

**What it did:** The actual encrypted value version inside the database secret. `AWSCURRENT` marked it as the active version.

**What destroy removed:** The version disappeared when the parent secret was deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h\|terraform-2026072323...` | The main identifier Terraform used to track this real object. |
| `secret_id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null` | The parent secret identifier. |
| `secret_string` | `(sensitive value) -> null` | The encrypted text value. Terraform hid it because it is sensitive. |
| `secret_string_wo` | `(write-only attribute) -> null` | A write-only secret value field. |
| `version_id` | `"terraform-20260723235651393200000008" -> null` | The identifier of one stored secret version. |
| `version_stages` | `[` | Labels such as `AWSCURRENT` that identify which version applications should use. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_secretsmanager_secret_version" "db" {
      - arn              = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null
      - id               = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h|terraform-20260723235651393200000008" -> null
      - secret_id        = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h" -> null
      - secret_string    = (sensitive value) -> null
      - secret_string_wo = (write-only attribute) -> null
      - version_id       = "terraform-20260723235651393200000008" -> null
      - version_stages   = [
          - "AWSCURRENT",
        ] -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws secretsmanager list-secret-version-ids   --secret-id keycloak-demo/db-credentials-39692c   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `ResourceNotFoundException`.

### 6.21. `aws_secretsmanager_secret_version.keycloak_admin` — Stored version of the Keycloak admin credential value

**Type:** AWS

**What it did:** The encrypted username/password payload inside the Keycloak admin secret.

**What destroy removed:** The version disappeared when its parent secret was deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5\|terraform-2026072...` | The main identifier Terraform used to track this real object. |
| `secret_id` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null` | The parent secret identifier. |
| `secret_string` | `(sensitive value) -> null` | The encrypted text value. Terraform hid it because it is sensitive. |
| `secret_string_wo` | `(write-only attribute) -> null` | A write-only secret value field. |
| `version_id` | `"terraform-20260723234715876100000003" -> null` | The identifier of one stored secret version. |
| `version_stages` | `[` | Labels such as `AWSCURRENT` that identify which version applications should use. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_secretsmanager_secret_version" "keycloak_admin" {
      - arn              = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null
      - id               = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5|terraform-20260723234715876100000003" -> null
      - secret_id        = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5" -> null
      - secret_string    = (sensitive value) -> null
      - secret_string_wo = (write-only attribute) -> null
      - version_id       = "terraform-20260723234715876100000003" -> null
      - version_stages   = [
          - "AWSCURRENT",
        ] -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws secretsmanager list-secret-version-ids   --secret-id keycloak-demo/db-keycloak-admin-39692c   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `ResourceNotFoundException`.

### 6.22. `aws_security_group.database` — Database security group

**Type:** AWS

**What it did:** A stateful firewall around RDS. It accepted PostgreSQL port 5432 only from resources using the Keycloak security group.

**What destroy removed:** Terraform removed its individual rules and deleted security group `sg-0267d26156f2a1007` after RDS was deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group/sg-0267d26156f2a1007" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Postgres 5432 from the Keycloak SG only" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `egress` | `[` | Rules for traffic leaving resources protected by the security group. |
| `cidr_blocks` | `[` | IPv4 source or destination network ranges for a security-group rule. |
| `from_port` | `0` | The first port in the allowed range. |
| `ipv6_cidr_blocks` | `[]` | IPv6 network ranges. Empty means no IPv6 access. |
| `prefix_list_ids` | `[]` | AWS-managed or customer-managed prefix lists. Empty means none. |
| `protocol` | `"-1"` | The IP protocol, such as `tcp`; `-1` means all protocols. |
| `security_groups` | `[]` | Security-group names used in EC2-Classic style output. Empty is normal when IDs are used in a VPC. |
| `self` | `false` | Whether members of the same security group can use the rule as the source. |
| `to_port` | `0` | The last port in the allowed range. |
| `id` | `"sg-0267d26156f2a1007" -> null` | The main identifier Terraform used to track this real object. |
| `ingress` | `[` | Rules for traffic entering resources protected by the security group. |
| `name` | `"keycloak-demo-db-sg" -> null` | The friendly AWS name of the object. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `revoke_rules_on_delete` | `false -> null` | Whether Terraform should explicitly revoke all rules before deleting the security group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_security_group" "database" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group/sg-0267d26156f2a1007" -> null
      - description            = "Postgres 5432 from the Keycloak SG only" -> null
      - egress                 = [
          - {
              - cidr_blocks      = [
                  - "127.0.0.1/32",
                ]
              - description      = "No meaningful egress needed"
              - from_port        = 0
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "-1"
              - security_groups  = []
              - self             = false
              - to_port          = 0
            },
        ] -> null
      - id                     = "sg-0267d26156f2a1007" -> null
      - ingress                = [
          - {
              - cidr_blocks      = []
              - description      = "Postgres from Keycloak instances only"
              - from_port        = 5432
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "tcp"
              - security_groups  = [
                  - "sg-0e73f9e971b5c6e36",
                ]
              - self             = false
              - to_port          = 5432
            },
        ] -> null
      - name                   = "keycloak-demo-db-sg" -> null
      - owner_id               = "406207085797" -> null
      - revoke_rules_on_delete = false -> null
      - tags                   = {
          - "Name" = "keycloak-demo-db-sg"
        } -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-db-sg"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id                 = "vpc-0d470b94ebdffafc5" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-groups   --group-ids sg-0267d26156f2a1007   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidGroup.NotFound`.

### 6.23. `aws_security_group.keycloak` — Keycloak EC2 security group

**Type:** AWS

**What it did:** A stateful firewall around the EC2 server. It allowed SSH 22, Keycloak HTTP 8080, and Keycloak HTTPS 8443 only from one `/32` public IP, and allowed all outbound traffic.

**What destroy removed:** Terraform removed each rule and deleted security group `sg-0e73f9e971b5c6e36` after the EC2 instance was terminated.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group/sg-0e73f9e971b5c6e36" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Allow admin console and SSH from one IP only" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `egress` | `[` | Rules for traffic leaving resources protected by the security group. |
| `cidr_blocks` | `[` | IPv4 source or destination network ranges for a security-group rule. |
| `from_port` | `0` | The first port in the allowed range. |
| `ipv6_cidr_blocks` | `[]` | IPv6 network ranges. Empty means no IPv6 access. |
| `prefix_list_ids` | `[]` | AWS-managed or customer-managed prefix lists. Empty means none. |
| `protocol` | `"-1"` | The IP protocol, such as `tcp`; `-1` means all protocols. |
| `security_groups` | `[]` | Security-group names used in EC2-Classic style output. Empty is normal when IDs are used in a VPC. |
| `self` | `false` | Whether members of the same security group can use the rule as the source. |
| `to_port` | `0` | The last port in the allowed range. |
| `id` | `"sg-0e73f9e971b5c6e36" -> null` | The main identifier Terraform used to track this real object. |
| `ingress` | `[` | Rules for traffic entering resources protected by the security group. |
| `name` | `"keycloak-demo-keycloak-sg" -> null` | The friendly AWS name of the object. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `revoke_rules_on_delete` | `false -> null` | Whether Terraform should explicitly revoke all rules before deleting the security group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_security_group" "keycloak" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group/sg-0e73f9e971b5c6e36" -> null
      - description            = "Allow admin console and SSH from one IP only" -> null
      - egress                 = [
          - {
              - cidr_blocks      = [
                  - "0.0.0.0/0",
                ]
              - description      = "Allow all outbound"
              - from_port        = 0
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "-1"
              - security_groups  = []
              - self             = false
              - to_port          = 0
            },
        ] -> null
      - id                     = "sg-0e73f9e971b5c6e36" -> null
      - ingress                = [
          - {
              - cidr_blocks      = [
                  - "68.32.112.68/32",
                ]
              - description      = "Keycloak HTTP from my IP (troubleshooting)"
              - from_port        = 8080
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "tcp"
              - security_groups  = []
              - self             = false
              - to_port          = 8080
            },
          - {
              - cidr_blocks      = [
                  - "68.32.112.68/32",
                ]
              - description      = "Keycloak HTTPS from my IP"
              - from_port        = 8443
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "tcp"
              - security_groups  = []
              - self             = false
              - to_port          = 8443
            },
          - {
              - cidr_blocks      = [
                  - "68.32.112.68/32",
                ]
              - description      = "SSH from my IP only"
              - from_port        = 22
              - ipv6_cidr_blocks = []
              - prefix_list_ids  = []
              - protocol         = "tcp"
              - security_groups  = []
              - self             = false
              - to_port          = 22
            },
        ] -> null
      - name                   = "keycloak-demo-keycloak-sg" -> null
      - owner_id               = "406207085797" -> null
      - revoke_rules_on_delete = false -> null
      - tags                   = {
          - "Name" = "keycloak-demo-keycloak-sg"
        } -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-keycloak-sg"
          - "Project"     = "keycloak-demo"
        } -> null
      - vpc_id                 = "vpc-0d470b94ebdffafc5" -> null
        # (1 unchanged attribute hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-groups   --group-ids sg-0e73f9e971b5c6e36   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidGroup.NotFound`.

### 6.24. `aws_subnet.private_a` — Private subnet A

**Type:** AWS

**What it did:** A private IP neighborhood `10.42.11.0/24` in `us-east-1a` used by the RDS subnet group.

**What destroy removed:** Terraform deleted the subnet after the database, subnet group, route association, and dependent security resources were gone.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:subnet/subnet-0267a69101df5beb2" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false -> null` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1a" -> null` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `"use1-az1" -> null` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.11.0/24" -> null` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false -> null` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_lni_at_device_index` | `0 -> null` | Local Network Interface device index. `0` means not enabled. |
| `enable_resource_name_dns_a_record_on_launch` | `false -> null` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false -> null` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `"subnet-0267a69101df5beb2" -> null` | The main identifier Terraform used to track this real object. |
| `ipv6_native` | `false -> null` | Whether the subnet was IPv6-only. |
| `map_customer_owned_ip_on_launch` | `false -> null` | Whether customer-owned IPs are automatically assigned at launch. |
| `map_public_ip_on_launch` | `false -> null` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `"ip-name" -> null` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_subnet" "private_a" {
      - arn                                            = "arn:aws:ec2:us-east-1:406207085797:subnet/subnet-0267a69101df5beb2" -> null
      - assign_ipv6_address_on_creation                = false -> null
      - availability_zone                              = "us-east-1a" -> null
      - availability_zone_id                           = "use1-az1" -> null
      - cidr_block                                     = "10.42.11.0/24" -> null
      - enable_dns64                                   = false -> null
      - enable_lni_at_device_index                     = 0 -> null
      - enable_resource_name_dns_a_record_on_launch    = false -> null
      - enable_resource_name_dns_aaaa_record_on_launch = false -> null
      - id                                             = "subnet-0267a69101df5beb2" -> null
      - ipv6_native                                    = false -> null
      - map_customer_owned_ip_on_launch                = false -> null
      - map_public_ip_on_launch                        = false -> null
      - owner_id                                       = "406207085797" -> null
      - private_dns_hostname_type_on_launch            = "ip-name" -> null
      - tags                                           = {
          - "Name" = "keycloak-demo-private-a"
          - "Tier" = "private"
        } -> null
      - tags_all                                       = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-private-a"
          - "Project"     = "keycloak-demo"
          - "Tier"        = "private"
        } -> null
      - vpc_id                                         = "vpc-0d470b94ebdffafc5" -> null
        # (4 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-subnets   --subnet-ids subnet-0267a69101df5beb2   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSubnetID.NotFound`.

### 6.25. `aws_subnet.private_b` — Private subnet B

**Type:** AWS

**What it did:** A private IP neighborhood `10.42.12.0/24` in `us-east-1b`, giving RDS subnet coverage in a second Availability Zone.

**What destroy removed:** Terraform deleted the subnet after RDS dependencies were gone.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:subnet/subnet-018ec8fc3cc46a312" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false -> null` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1b" -> null` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `"use1-az2" -> null` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.12.0/24" -> null` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false -> null` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_lni_at_device_index` | `0 -> null` | Local Network Interface device index. `0` means not enabled. |
| `enable_resource_name_dns_a_record_on_launch` | `false -> null` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false -> null` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `"subnet-018ec8fc3cc46a312" -> null` | The main identifier Terraform used to track this real object. |
| `ipv6_native` | `false -> null` | Whether the subnet was IPv6-only. |
| `map_customer_owned_ip_on_launch` | `false -> null` | Whether customer-owned IPs are automatically assigned at launch. |
| `map_public_ip_on_launch` | `false -> null` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `"ip-name" -> null` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_subnet" "private_b" {
      - arn                                            = "arn:aws:ec2:us-east-1:406207085797:subnet/subnet-018ec8fc3cc46a312" -> null
      - assign_ipv6_address_on_creation                = false -> null
      - availability_zone                              = "us-east-1b" -> null
      - availability_zone_id                           = "use1-az2" -> null
      - cidr_block                                     = "10.42.12.0/24" -> null
      - enable_dns64                                   = false -> null
      - enable_lni_at_device_index                     = 0 -> null
      - enable_resource_name_dns_a_record_on_launch    = false -> null
      - enable_resource_name_dns_aaaa_record_on_launch = false -> null
      - id                                             = "subnet-018ec8fc3cc46a312" -> null
      - ipv6_native                                    = false -> null
      - map_customer_owned_ip_on_launch                = false -> null
      - map_public_ip_on_launch                        = false -> null
      - owner_id                                       = "406207085797" -> null
      - private_dns_hostname_type_on_launch            = "ip-name" -> null
      - tags                                           = {
          - "Name" = "keycloak-demo-private-b"
          - "Tier" = "private"
        } -> null
      - tags_all                                       = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-private-b"
          - "Project"     = "keycloak-demo"
          - "Tier"        = "private"
        } -> null
      - vpc_id                                         = "vpc-0d470b94ebdffafc5" -> null
        # (4 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-subnets   --subnet-ids subnet-018ec8fc3cc46a312   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSubnetID.NotFound`.

### 6.26. `aws_subnet.public` — Public subnet

**Type:** AWS

**What it did:** A public IP neighborhood `10.42.1.0/24` in `us-east-1a` where the Keycloak EC2 server lived.

**What destroy removed:** Terraform deleted the subnet after terminating the instance, deleting its route-table association, and releasing its public address.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:subnet/subnet-09369b387fc6af56d" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false -> null` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1a" -> null` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `"use1-az1" -> null` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.1.0/24" -> null` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false -> null` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_lni_at_device_index` | `0 -> null` | Local Network Interface device index. `0` means not enabled. |
| `enable_resource_name_dns_a_record_on_launch` | `false -> null` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false -> null` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `"subnet-09369b387fc6af56d" -> null` | The main identifier Terraform used to track this real object. |
| `ipv6_native` | `false -> null` | Whether the subnet was IPv6-only. |
| `map_customer_owned_ip_on_launch` | `false -> null` | Whether customer-owned IPs are automatically assigned at launch. |
| `map_public_ip_on_launch` | `true -> null` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `"ip-name" -> null` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `"vpc-0d470b94ebdffafc5" -> null` | The VPC that contained the resource. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_subnet" "public" {
      - arn                                            = "arn:aws:ec2:us-east-1:406207085797:subnet/subnet-09369b387fc6af56d" -> null
      - assign_ipv6_address_on_creation                = false -> null
      - availability_zone                              = "us-east-1a" -> null
      - availability_zone_id                           = "use1-az1" -> null
      - cidr_block                                     = "10.42.1.0/24" -> null
      - enable_dns64                                   = false -> null
      - enable_lni_at_device_index                     = 0 -> null
      - enable_resource_name_dns_a_record_on_launch    = false -> null
      - enable_resource_name_dns_aaaa_record_on_launch = false -> null
      - id                                             = "subnet-09369b387fc6af56d" -> null
      - ipv6_native                                    = false -> null
      - map_customer_owned_ip_on_launch                = false -> null
      - map_public_ip_on_launch                        = true -> null
      - owner_id                                       = "406207085797" -> null
      - private_dns_hostname_type_on_launch            = "ip-name" -> null
      - tags                                           = {
          - "Name" = "keycloak-demo-public-a"
          - "Tier" = "public"
        } -> null
      - tags_all                                       = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-public-a"
          - "Project"     = "keycloak-demo"
          - "Tier"        = "public"
        } -> null
      - vpc_id                                         = "vpc-0d470b94ebdffafc5" -> null
        # (4 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-subnets   --subnet-ids subnet-09369b387fc6af56d   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSubnetID.NotFound`.

### 6.27. `aws_vpc.main` — Virtual Private Cloud

**Type:** AWS

**What it did:** The main private network `10.42.0.0/16` that contained all subnets, routing, security groups, EC2, and RDS networking.

**What destroy removed:** Terraform deleted the VPC last, after all dependent resources had been removed.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:vpc/vpc-0d470b94ebdffafc5" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_generated_ipv6_cidr_block` | `false -> null` | Whether AWS automatically assigned an IPv6 range to the VPC. |
| `cidr_block` | `"10.42.0.0/16" -> null` | An IPv4 network range written in CIDR form. |
| `default_network_acl_id` | `"acl-01d3d90e659e44c8d" -> null` | The default stateless subnet firewall automatically created with the VPC. |
| `default_route_table_id` | `"rtb-0da6caf0028b45e8a" -> null` | The default route table automatically created with the VPC. |
| `default_security_group_id` | `"sg-05cb47638f49dd271" -> null` | The default security group automatically created with the VPC. |
| `dhcp_options_id` | `"dopt-0c245e0b2f28782f3" -> null` | The DHCP settings used by the VPC for DNS and network configuration. |
| `enable_dns_hostnames` | `true -> null` | Whether instances with public IPs can receive public DNS hostnames. |
| `enable_dns_support` | `true -> null` | Whether AWS-provided DNS resolution works inside the VPC. |
| `enable_network_address_usage_metrics` | `false -> null` | Whether VPC IP-address usage metrics were enabled. |
| `id` | `"vpc-0d470b94ebdffafc5" -> null` | The main identifier Terraform used to track this real object. |
| `instance_tenancy` | `"default" -> null` | Default hardware tenancy for instances launched in the VPC. |
| `ipv6_netmask_length` | `0 -> null` | IPv6 prefix length. `0` means no IPv6 CIDR was assigned. |
| `main_route_table_id` | `"rtb-0da6caf0028b45e8a" -> null` | The VPC’s main fallback route table. |
| `owner_id` | `"406207085797" -> null` | The AWS account number that owned the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc" "main" {
      - arn                                  = "arn:aws:ec2:us-east-1:406207085797:vpc/vpc-0d470b94ebdffafc5" -> null
      - assign_generated_ipv6_cidr_block     = false -> null
      - cidr_block                           = "10.42.0.0/16" -> null
      - default_network_acl_id               = "acl-01d3d90e659e44c8d" -> null
      - default_route_table_id               = "rtb-0da6caf0028b45e8a" -> null
      - default_security_group_id            = "sg-05cb47638f49dd271" -> null
      - dhcp_options_id                      = "dopt-0c245e0b2f28782f3" -> null
      - enable_dns_hostnames                 = true -> null
      - enable_dns_support                   = true -> null
      - enable_network_address_usage_metrics = false -> null
      - id                                   = "vpc-0d470b94ebdffafc5" -> null
      - instance_tenancy                     = "default" -> null
      - ipv6_netmask_length                  = 0 -> null
      - main_route_table_id                  = "rtb-0da6caf0028b45e8a" -> null
      - owner_id                             = "406207085797" -> null
      - tags                                 = {
          - "Name" = "keycloak-demo-vpc"
        } -> null
      - tags_all                             = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Name"        = "keycloak-demo-vpc"
          - "Project"     = "keycloak-demo"
        } -> null
        # (4 unchanged attributes hidden)
    }
```

#### Check whether it exists

```bash
aws ec2 describe-vpcs   --vpc-ids vpc-0d470b94ebdffafc5   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidVpcID.NotFound`.

### 6.28. `aws_vpc_security_group_egress_rule.db_none` — Database security-group outbound rule

**Type:** AWS

**What it did:** An unusual rule allowing all protocols only to `127.0.0.1/32`. It was used to avoid meaningful outbound network access from the database security group.

**What destroy removed:** Terraform deleted the individual rule before deleting the database security group.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0fe3258df2a14cff8" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"127.0.0.1/32" -> null` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"No meaningful egress needed" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `"sgr-0fe3258df2a14cff8" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"-1" -> null` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `"sg-0267d26156f2a1007" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-0fe3258df2a14cff8" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_egress_rule" "db_none" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0fe3258df2a14cff8" -> null
      - cidr_ipv4              = "127.0.0.1/32" -> null
      - description            = "No meaningful egress needed" -> null
      - id                     = "sgr-0fe3258df2a14cff8" -> null
      - ip_protocol            = "-1" -> null
      - security_group_id      = "sg-0267d26156f2a1007" -> null
      - security_group_rule_id = "sgr-0fe3258df2a14cff8" -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-0fe3258df2a14cff8   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.29. `aws_vpc_security_group_egress_rule.keycloak_all_out` — Keycloak security-group outbound rule

**Type:** AWS

**What it did:** Allowed the Keycloak EC2 instance to start outbound connections to any IPv4 address using any protocol.

**What destroy removed:** Terraform deleted the rule before deleting the Keycloak security group.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0cc4f4b38072fc1cb" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"0.0.0.0/0" -> null` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Allow all outbound" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `"sgr-0cc4f4b38072fc1cb" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"-1" -> null` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `"sg-0e73f9e971b5c6e36" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-0cc4f4b38072fc1cb" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_egress_rule" "keycloak_all_out" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0cc4f4b38072fc1cb" -> null
      - cidr_ipv4              = "0.0.0.0/0" -> null
      - description            = "Allow all outbound" -> null
      - id                     = "sgr-0cc4f4b38072fc1cb" -> null
      - ip_protocol            = "-1" -> null
      - security_group_id      = "sg-0e73f9e971b5c6e36" -> null
      - security_group_rule_id = "sgr-0cc4f4b38072fc1cb" -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-0cc4f4b38072fc1cb   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.30. `aws_vpc_security_group_ingress_rule.db_from_keycloak` — PostgreSQL inbound firewall rule

**Type:** AWS

**What it did:** Allowed TCP port 5432 into the database security group only when the source resource used the Keycloak security group.

**What destroy removed:** Terraform deleted the rule before deleting either security group.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0471fa8452df1c8f7" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Postgres from Keycloak instances only" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `5432 -> null` | The first port in the allowed range. |
| `id` | `"sgr-0471fa8452df1c8f7" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp" -> null` | The protocol field on a separate VPC security-group rule. |
| `referenced_security_group_id` | `"sg-0e73f9e971b5c6e36" -> null` | The source security group trusted by an inbound rule. |
| `security_group_id` | `"sg-0267d26156f2a1007" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-0471fa8452df1c8f7" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `5432 -> null` | The last port in the allowed range. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
      - arn                          = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0471fa8452df1c8f7" -> null
      - description                  = "Postgres from Keycloak instances only" -> null
      - from_port                    = 5432 -> null
      - id                           = "sgr-0471fa8452df1c8f7" -> null
      - ip_protocol                  = "tcp" -> null
      - referenced_security_group_id = "sg-0e73f9e971b5c6e36" -> null
      - security_group_id            = "sg-0267d26156f2a1007" -> null
      - security_group_rule_id       = "sgr-0471fa8452df1c8f7" -> null
      - tags_all                     = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - to_port                      = 5432 -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-0471fa8452df1c8f7   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.31. `aws_vpc_security_group_ingress_rule.keycloak_http` — Keycloak HTTP inbound firewall rule

**Type:** AWS

**What it did:** Allowed TCP port 8080 from the single source address `68.32.112.68/32` for troubleshooting.

**What destroy removed:** Terraform removed the rule.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-01805c9192553ee68" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32" -> null` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Keycloak HTTP from my IP (troubleshooting)" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `8080 -> null` | The first port in the allowed range. |
| `id` | `"sgr-01805c9192553ee68" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp" -> null` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `"sg-0e73f9e971b5c6e36" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-01805c9192553ee68" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `8080 -> null` | The last port in the allowed range. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_ingress_rule" "keycloak_http" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-01805c9192553ee68" -> null
      - cidr_ipv4              = "68.32.112.68/32" -> null
      - description            = "Keycloak HTTP from my IP (troubleshooting)" -> null
      - from_port              = 8080 -> null
      - id                     = "sgr-01805c9192553ee68" -> null
      - ip_protocol            = "tcp" -> null
      - security_group_id      = "sg-0e73f9e971b5c6e36" -> null
      - security_group_rule_id = "sgr-01805c9192553ee68" -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - to_port                = 8080 -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-01805c9192553ee68   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.32. `aws_vpc_security_group_ingress_rule.keycloak_https` — Keycloak HTTPS inbound firewall rule

**Type:** AWS

**What it did:** Allowed TCP port 8443 from the single approved source address.

**What destroy removed:** Terraform removed the rule.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0714563e5a3283970" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32" -> null` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Keycloak HTTPS from my IP" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `8443 -> null` | The first port in the allowed range. |
| `id` | `"sgr-0714563e5a3283970" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp" -> null` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `"sg-0e73f9e971b5c6e36" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-0714563e5a3283970" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `8443 -> null` | The last port in the allowed range. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_ingress_rule" "keycloak_https" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0714563e5a3283970" -> null
      - cidr_ipv4              = "68.32.112.68/32" -> null
      - description            = "Keycloak HTTPS from my IP" -> null
      - from_port              = 8443 -> null
      - id                     = "sgr-0714563e5a3283970" -> null
      - ip_protocol            = "tcp" -> null
      - security_group_id      = "sg-0e73f9e971b5c6e36" -> null
      - security_group_rule_id = "sgr-0714563e5a3283970" -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - to_port                = 8443 -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-0714563e5a3283970   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.33. `aws_vpc_security_group_ingress_rule.keycloak_ssh` — SSH inbound firewall rule

**Type:** AWS

**What it did:** Allowed TCP port 22 from the single approved source address.

**What destroy removed:** Terraform removed the rule.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `arn` | `"arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0fc1836196cedc6a8" -> null` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32" -> null` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"SSH from my IP only" -> null` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `22 -> null` | The first port in the allowed range. |
| `id` | `"sgr-0fc1836196cedc6a8" -> null` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp" -> null` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `"sg-0e73f9e971b5c6e36" -> null` | The security group that owns the rule. |
| `security_group_rule_id` | `"sgr-0fc1836196cedc6a8" -> null` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `22 -> null` | The last port in the allowed range. |

#### Exact destroy-plan excerpt

```hcl
  - resource "aws_vpc_security_group_ingress_rule" "keycloak_ssh" {
      - arn                    = "arn:aws:ec2:us-east-1:406207085797:security-group-rule/sgr-0fc1836196cedc6a8" -> null
      - cidr_ipv4              = "68.32.112.68/32" -> null
      - description            = "SSH from my IP only" -> null
      - from_port              = 22 -> null
      - id                     = "sgr-0fc1836196cedc6a8" -> null
      - ip_protocol            = "tcp" -> null
      - security_group_id      = "sg-0e73f9e971b5c6e36" -> null
      - security_group_rule_id = "sgr-0fc1836196cedc6a8" -> null
      - tags_all               = {
          - "Environment" = "dev"
          - "ManagedBy"   = "terraform"
          - "Project"     = "keycloak-demo"
        } -> null
      - to_port                = 22 -> null
    }
```

#### Check whether it exists

```bash
aws ec2 describe-security-group-rules   --security-group-rule-ids sgr-0fc1836196cedc6a8   --region "$AWS_REGION"
```

**Expected after successful destroy:** The command should fail with `InvalidSecurityGroupRuleId.NotFound` or return no matching rule.

### 6.34. `random_id.suffix` — Terraform random suffix

**Type:** Local Terraform provider

**What it did:** A short random value (`39692c`) added to names so resources would not collide with old or similarly named resources.

**What destroy removed:** No AWS service was called for this item. Terraform removed the random value from its state.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `b64_std` | `"OWks" -> null` | The random bytes shown using standard Base64 text. |
| `b64_url` | `"OWks" -> null` | The random bytes shown using URL-safe Base64 text. |
| `byte_length` | `3 -> null` | How many random bytes were generated. |
| `dec` | `"3762476" -> null` | The same random value displayed as a decimal number. |
| `hex` | `"39692c" -> null` | The same random value displayed as hexadecimal text. |
| `id` | `"OWks" -> null` | The main identifier Terraform used to track this real object. |

#### Exact destroy-plan excerpt

```hcl
  - resource "random_id" "suffix" {
      - b64_std     = "OWks" -> null
      - b64_url     = "OWks" -> null
      - byte_length = 3 -> null
      - dec         = "3762476" -> null
      - hex         = "39692c" -> null
      - id          = "OWks" -> null
    }
```

#### Check whether it exists

```bash
terraform state show random_id.suffix
```

**Expected after successful destroy:** Terraform should report that no matching instance exists in state.

### 6.35. `random_password.db` — Terraform-generated database password

**Type:** Local Terraform provider

**What it did:** A 32-character generated password meeting lowercase, uppercase, number, and special-character rules.

**What destroy removed:** No separate AWS password resource existed. Terraform removed the generated value from state. The copy stored in Secrets Manager was separately deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `bcrypt_hash` | `(sensitive value) -> null` | A one-way bcrypt hash of the generated password. |
| `id` | `"none" -> null` | The main identifier Terraform used to track this real object. |
| `length` | `32 -> null` | The number of characters in the generated password. |
| `lower` | `true -> null` | Whether lowercase letters were allowed. |
| `min_lower` | `2 -> null` | Minimum number of lowercase letters. |
| `min_numeric` | `2 -> null` | Minimum number of digits. |
| `min_special` | `2 -> null` | Minimum number of special characters. |
| `min_upper` | `2 -> null` | Minimum number of uppercase letters. |
| `number` | `true -> null` | Older compatibility setting saying numbers are allowed. |
| `numeric` | `true -> null` | Whether digits were allowed. |
| `override_special` | `"!#$%&*()-_=+[]{}<>:?" -> null` | The exact special characters Terraform was allowed to use. |
| `result` | `(sensitive value) -> null` | The generated password. Terraform hid it because it is sensitive. |
| `special` | `true -> null` | Whether special characters were allowed. |
| `upper` | `true -> null` | Whether uppercase letters were allowed. |

#### Exact destroy-plan excerpt

```hcl
  - resource "random_password" "db" {
      - bcrypt_hash      = (sensitive value) -> null
      - id               = "none" -> null
      - length           = 32 -> null
      - lower            = true -> null
      - min_lower        = 2 -> null
      - min_numeric      = 2 -> null
      - min_special      = 2 -> null
      - min_upper        = 2 -> null
      - number           = true -> null
      - numeric          = true -> null
      - override_special = "!#$%&*()-_=+[]{}<>:?" -> null
      - result           = (sensitive value) -> null
      - special          = true -> null
      - upper            = true -> null
    }
```

#### Check whether it exists

```bash
terraform state show random_password.db
```

**Expected after successful destroy:** Terraform should report that no matching instance exists in state.

### 6.36. `random_password.keycloak_admin` — Terraform-generated Keycloak administrator password

**Type:** Local Terraform provider

**What it did:** A 24-character generated password for the Keycloak bootstrap administrator.

**What destroy removed:** Terraform removed the generated value from local state. The Secrets Manager copy was separately deleted.

#### Named lines in this block

| Line name | Value shown at plan time | Middle-school explanation |
|---|---|---|
| `bcrypt_hash` | `(sensitive value) -> null` | A one-way bcrypt hash of the generated password. |
| `id` | `"none" -> null` | The main identifier Terraform used to track this real object. |
| `length` | `24 -> null` | The number of characters in the generated password. |
| `lower` | `true -> null` | Whether lowercase letters were allowed. |
| `min_lower` | `2 -> null` | Minimum number of lowercase letters. |
| `min_numeric` | `2 -> null` | Minimum number of digits. |
| `min_special` | `2 -> null` | Minimum number of special characters. |
| `min_upper` | `2 -> null` | Minimum number of uppercase letters. |
| `number` | `true -> null` | Older compatibility setting saying numbers are allowed. |
| `numeric` | `true -> null` | Whether digits were allowed. |
| `override_special` | `"!#$%&*-_=+" -> null` | The exact special characters Terraform was allowed to use. |
| `result` | `(sensitive value) -> null` | The generated password. Terraform hid it because it is sensitive. |
| `special` | `true -> null` | Whether special characters were allowed. |
| `upper` | `true -> null` | Whether uppercase letters were allowed. |

#### Exact destroy-plan excerpt

```hcl
  - resource "random_password" "keycloak_admin" {
      - bcrypt_hash      = (sensitive value) -> null
      - id               = "none" -> null
      - length           = 24 -> null
      - lower            = true -> null
      - min_lower        = 2 -> null
      - min_numeric      = 2 -> null
      - min_special      = 2 -> null
      - min_upper        = 2 -> null
      - number           = true -> null
      - numeric          = true -> null
      - override_special = "!#$%&*-_=+" -> null
      - result           = (sensitive value) -> null
      - special          = true -> null
      - upper            = true -> null
    }
```

#### Check whether it exists

```bash
terraform state show random_password.keycloak_admin
```

**Expected after successful destroy:** Terraform should report that no matching instance exists in state.

## 7. Terraform Outputs That Were Removed

Terraform outputs are convenient labels printed after `terraform apply`. They are not separate AWS resources. When the resources and state entries disappeared, these outputs changed to `null` and were removed.

| Output | Meaning before destroy |
|---|---|
| `allowed_source_ip` | Terraform output showing the one approved client IPv4 address. |
| `database_sg_id` | Terraform output containing the database security-group ID. |
| `db_endpoint` | Terraform output containing the RDS DNS endpoint. |
| `db_jdbc_url` | Terraform output containing a Java JDBC connection string for PostgreSQL with TLS settings. |
| `db_port` | Terraform output containing the database port. |
| `db_secret_arn` | Terraform output containing the full database secret ARN. |
| `db_secret_name` | Terraform output containing the database secret’s friendly name. |
| `db_subnet_group_name` | The subnet group that told RDS where it could place network interfaces. |
| `get_admin_password_command` | Terraform output containing a ready-made AWS CLI command to read the admin secret. |
| `instance_profile_name` | Terraform output containing the IAM instance-profile name. |
| `keycloak_admin_console` | Terraform output containing the Keycloak admin-console URL. |
| `keycloak_admin_secret_name` | Terraform output containing the Keycloak admin secret name. |
| `keycloak_instance_id` | Terraform output containing the EC2 instance ID. |
| `keycloak_public_ip` | Terraform output containing the server’s public IP address. |
| `keycloak_sg_id` | Terraform output containing the Keycloak security-group ID. |
| `keycloak_url` | Terraform output containing the main Keycloak URL. |
| `private_subnet_ids` | Terraform output listing the two private subnet IDs. |
| `public_subnet_id` | Terraform output containing the public subnet ID. |
| `resource_suffix` | Terraform output containing the random naming suffix. |
| `ssm_shell_command` | Terraform output containing the command used to start an SSM session. |
| `vpc_id` | The VPC that contained the resource. |

Check the outputs:

```bash
terraform output
```

After a complete destroy of this stack, Terraform should report that no outputs are found.

## 8. Why Terraform Deleted Things in This Order

AWS does not let you delete a container while something still depends on it. Terraform builds a dependency graph, like a teacher making sure students leave a bus before the bus is removed.

The log shows this safe order:

1. Security-group rules, route-table associations, IAM policy attachments, and the Elastic IP association were removed first.
2. Route tables and the custom IAM policy were removed after their links were gone.
3. The EC2 instance was terminated.
4. The public subnet, instance profile, secrets, Keycloak security group, Elastic IP, IAM role, and internet gateway were removed.
5. RDS took the longest because AWS had to safely delete a managed database.
6. After RDS was gone, Terraform removed the DB subnet group, DB parameter group, DB security group, and private subnets.
7. The VPC was deleted last.

### Reading execution messages

| Log message | Meaning |
|---|---|
| `Destroying...` | Terraform sent a delete, detach, terminate, or release request. |
| `Still destroying... 00m40s elapsed` | AWS accepted the operation, but the resource was still shutting down. Terraform was polling its status. |
| `Destruction complete after 40s` | The provider confirmed the resource reached its deleted state. |
| `Destroy complete! Resources: 36 destroyed.` | Terraform finished all planned deletions without a reported error. |

The EC2 instance took about 40 seconds. The RDS database took about 3 minutes 54 seconds. That is normal because managed databases have more cleanup work.

## 9. Master AWS CLI Verification Checklist

### 9.1 Confirm the account and region first

Never check or delete cloud resources until you know which account and region your CLI is using.

```bash
export AWS_REGION=us-east-1
aws sts get-caller-identity
aws configure get region
```

The account should be the account that owned the resources. The plan showed account `406207085797` and region `us-east-1`.

### 9.2 Quick filtered checks that return empty lists

These checks are easier for beginners because many of them return `[]` when no match remains.

```bash
# EC2 instance. It may show terminated for a short time.
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters Name=instance-id,Values=i-0f7317687e9066068 \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'

# VPC
aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters Name=vpc-id,Values=vpc-0d470b94ebdffafc5 \
  --query 'Vpcs'

# Subnets
aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters Name=vpc-id,Values=vpc-0d470b94ebdffafc5 \
  --query 'Subnets'

# Security groups
aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters Name=vpc-id,Values=vpc-0d470b94ebdffafc5 \
  --query 'SecurityGroups'

# Route tables
aws ec2 describe-route-tables --region "$AWS_REGION" \
  --filters Name=vpc-id,Values=vpc-0d470b94ebdffafc5 \
  --query 'RouteTables'

# Internet gateway
aws ec2 describe-internet-gateways --region "$AWS_REGION" \
  --filters Name=attachment.vpc-id,Values=vpc-0d470b94ebdffafc5 \
  --query 'InternetGateways'

# Elastic IP allocation
aws ec2 describe-addresses --region "$AWS_REGION" \
  --filters Name=allocation-id,Values=eipalloc-00b08d704aacb7029 \
  --query 'Addresses'

# RDS by identifier
aws rds describe-db-instances --region "$AWS_REGION" \
  --query "DBInstances[?DBInstanceIdentifier=='keycloak-demo-db']"

# Secrets by name. list-secrets normally excludes secrets marked for deletion.
aws secretsmanager list-secrets --region "$AWS_REGION" \
  --filters Key=name,Values=keycloak-demo/db-credentials-39692c,keycloak-demo/db-keycloak-admin-39692c \
  --query 'SecretList[].Name'
```

Expected final result: empty lists or no matching names. The EC2 instance can remain visible as `terminated` for roughly an hour before it disappears from describe results.

### 9.3 Check Terraform state

```bash
terraform state list
terraform output
```

If this working directory managed only this Keycloak stack, `terraform state list` should print nothing. If it managed other stacks too, those unrelated addresses can still appear.

## 10. Checks for Data and Billing Leftovers

A successful Terraform destroy proves the 36 planned resources were deleted. It does not prove that every possible manually created or service-created object is gone.

### 10.1 Manual RDS snapshots

The destroy plan skipped a final snapshot, but older manual snapshots may still exist.

```bash
aws rds describe-db-snapshots \
  --db-instance-identifier keycloak-demo-db \
  --snapshot-type manual \
  --region "$AWS_REGION" \
  --query 'DBSnapshots[].{Id:DBSnapshotIdentifier,Status:Status,Created:SnapshotCreateTime}'
```

An empty list means no matching manual DB snapshots remain.

### 10.2 RDS automated backups

```bash
aws rds describe-db-instance-automated-backups \
  --db-instance-identifier keycloak-demo-db \
  --region "$AWS_REGION" \
  --query 'DBInstanceAutomatedBackups'
```

The plan requested deletion of automated backups. A not-found response or empty list is expected after cleanup.

### 10.3 EC2 root volume

```bash
aws ec2 describe-volumes \
  --volume-ids vol-011815d81364dd80f \
  --region "$AWS_REGION"
```

The volume should be gone because `delete_on_termination = true`.

### 10.4 CloudWatch log groups

RDS exported PostgreSQL and upgrade logs. CloudWatch log groups may outlive a database unless separately managed and deleted.

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/rds/instance/keycloak-demo-db/ \
  --region "$AWS_REGION" \
  --query 'logGroups[].{Name:logGroupName,Bytes:storedBytes,Retention:retentionInDays}'
```

If log groups remain, review them before deleting because they may contain useful audit or troubleshooting data.

### 10.5 KMS keys were referenced, not destroyed

The plan referenced KMS keys for RDS, Performance Insights, and the EC2 root volume, but no `aws_kms_key` resource appeared in the 36-item destroy plan. Therefore, these keys were not deleted by this run.

```bash
aws kms describe-key --key-id a5760f13-77af-453f-bb8a-534a85a4bb90 --region "$AWS_REGION"
aws kms describe-key --key-id 1393b9ee-5131-4e8d-b093-c8f31ac3eb7e --region "$AWS_REGION"
```

Do not schedule a KMS key for deletion until you know every encrypted resource and backup using it is no longer needed.

### 10.6 The AMI was referenced, not destroyed

The EC2 instance used an AMI, but the plan did not include an `aws_ami` or `aws_ami_from_instance` resource. Destroying the instance does not deregister the AMI.

If you know the AMI ID, verify it with:

```bash
aws ec2 describe-images --image-ids ami-REPLACE_ME --region "$AWS_REGION"
```

## 11. Windows PowerShell Setup

The same AWS CLI commands work in PowerShell. Set the region like this:

```powershell
$env:AWS_REGION = "us-east-1"
aws sts get-caller-identity
aws configure get region
```

PowerShell uses the backtick character for line continuation, but beginners can place each AWS CLI command on one line to avoid quoting problems.

## 12. Common Beginner Questions

### Did Terraform delete the AWS account?

No. It deleted only resources tracked in this Terraform state and included in the destroy plan.

### Did it delete the AWS-managed SSM policy?

No. It only detached `AmazonSSMManagedInstanceCore` from the custom role. AWS owns that managed policy.

### Did it delete the KMS encryption keys?

No KMS key resource appeared in the plan. The keys were referenced but not part of this destroy.

### Why did RDS take longer than EC2?

RDS is a managed database service. AWS must stop database work, remove storage and network connections, process backups, and update service records. That usually takes longer than terminating one virtual server.

### Why can I still see a terminated EC2 instance?

AWS keeps terminated instance records visible for a short period. Seeing state `terminated` soon after destroy does not mean the server is still running or billing for compute.

### Can I undo this destroy?

Terraform destroy has no undo button. You can run `terraform apply` to build new replacement infrastructure, but deleted database data, disk files, passwords, public IP ownership, and generated IDs will not automatically come back.

## 13. Safer Destroy Routine for Next Time

1. Confirm account and region with `aws sts get-caller-identity` and `aws configure get region`.
2. Save a destroy plan: `terraform plan -destroy -out=destroy.tfplan`.
3. Read it with `terraform show destroy.tfplan`.
4. Search for databases, disks, secrets, buckets, snapshots, and anything marked `skip_final_snapshot = true`.
5. Back up important data.
6. Apply the reviewed plan: `terraform apply destroy.tfplan`.
7. Run the AWS CLI verification checks.
8. Review Cost Explorer later because billing records can lag behind resource deletion.

## 14. Final Result From This Log

The uploaded execution log ended with:

```text
Destroy complete! Resources: 36 destroyed.
```

That confirms Terraform completed the planned teardown without showing an error. It removed the Keycloak EC2 server, RDS database, network, firewall rules, routing, public IP, IAM objects, secrets, and local generated values included in the plan.

The most important follow-up checks are:

- Confirm the RDS instance is gone.
- Confirm the VPC and subnets are gone.
- Confirm both secrets are gone.
- Check for manual RDS snapshots.
- Check for CloudWatch log groups.
- Confirm the referenced KMS keys and AMI were intentionally left behind.

## 15. Reference Commands Used

This guide uses AWS CLI v2 command families for STS, EC2, RDS, IAM, Secrets Manager, KMS, and CloudWatch Logs, plus Terraform CLI commands `plan`, `show`, `destroy`, `state list`, and `output`.
