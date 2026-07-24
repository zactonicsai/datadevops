# Terraform Create Plan Explained in Plain Language

> **Audience:** A new learner who is starting with Terraform and AWS.
>
> **Source:** The uploaded `terraform plan` output.
>
> **Plan result:** `Plan: 36 to add, 0 to change, 0 to destroy.`

## 1. The Big Idea

Terraform is like a construction manager holding a blueprint.

- The **Terraform configuration files** are the blueprint.
- The **Terraform state file** is the manager's tracking notebook.
- `terraform plan` compares the blueprint with what currently exists.
- `terraform apply` performs the approved work.

The command shown in the uploaded text was:

```text
terraform plan
```

A plan is only a preview. **Running `terraform plan` does not create the EC2 server, database, VPC, passwords, or any other resource.**

The final line says:

```text
Plan: 36 to add, 0 to change, 0 to destroy.
```

This means:

- Terraform plans to create 36 tracked objects.
- It does not plan to edit an existing tracked object.
- It does not plan to delete a tracked object.
- Of the 36 objects, 33 are AWS resources or AWS relationships.
- Three are Terraform Random provider objects used to make a suffix and two passwords.

## 2. How to Read the Create Plan

| Plan text | Plain meaning | Simple example |
|---|---|---|
| `# resource.name will be created` | Terraform plans to build that object during apply. | The construction list says a new room will be added. |
| `+` at the beginning of a line | This value or object is being added. | A plus sign means add it. |
| `(known after apply)` | AWS must create or inspect the object before Terraform can know the final value. | You know a new house will have an address, but the city has not assigned it yet. |
| `(sensitive value)` | Terraform knows the value but hides it from normal plan output. | A password is inside a sealed envelope. |
| `(write-only attribute)` | Terraform may send the value to AWS but cannot read it back later. | You place a letter in a one-way secure drop box. |
| `jsonencode(...)` | Terraform converts a Terraform map/list into valid JSON text for an AWS policy. | Terraform translates a permission checklist into AWS's policy language. |
| `# (N unchanged attributes hidden)` | Terraform shortened the display by hiding less-useful default fields. | A receipt says “11 normal details not printed.” |
| `tags` | Labels directly assigned to the resource. | A box label says its name. |
| `tags_all` | Direct tags plus provider-level default tags. | The box has its own label plus company-wide labels. |

### `known after apply` is not an error

It means the value depends on something AWS has not created yet. Examples include:

- EC2 instance ID
- public IP address
- VPC ID
- security-group ID
- RDS endpoint
- ARN
- generated random suffix

Terraform can still build the dependency graph because it knows which resource will provide each value.

## 3. Read-Only Data Lookups

The first lines say `Reading...` and then `Read complete`. These are **data sources**. They inspect existing information and do not create new AWS resources.

| Data source | What it reads | Result shown |
|---|---|---|
| `data.aws_ssm_parameter.al2023_arm64` | Reads the AWS public Systems Manager parameter that points to the latest Amazon Linux 2023 ARM64 AMI. This is a lookup, not a new SSM parameter. | /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 |
| `data.aws_iam_policy_document.ec2_trust` | Builds an IAM trust-policy JSON document that allows the EC2 service to assume the Keycloak role. This document exists inside Terraform until it is used by an IAM role. | Terraform-computed policy document ID `1186519591` |
| `data.aws_availability_zones.available` | Asks AWS which Availability Zones are available in the selected Region. The configuration then chooses `us-east-1a` and `us-east-1b`. | Region lookup result `us-east-1` |
| `data.aws_region.current` | Reads the current AWS Region from the provider configuration. | `us-east-1` |
| `data.aws_caller_identity.current` | Reads the current AWS account and caller identity. It is often used to build ARNs safely. | AWS account `406207085797` |
| `data.aws_iam_policy_document.read_db_secret` | Builds the JSON permissions document that allows only `GetSecretValue` and `DescribeSecret` on the Keycloak database secret path. | Terraform-computed policy document ID `591740106` |

### Why the data lookups happen first

Terraform needs facts before it can finish the plan. For example:

1. It reads the current Region.
2. It reads the AWS account number.
3. It looks up the newest Amazon Linux ARM64 AMI.
4. It builds IAM policy documents.
5. It asks which Availability Zones can be used.

No AWS infrastructure is built by these `data.` lines.

## 4. Planned AWS Architecture

```text
                         Internet
                            |
                            v
                 AWS Internet Gateway
                            |
           Public route: 0.0.0.0/0 -> IGW
                            |
           Public subnet 10.42.1.0/24
                   in us-east-1a
                            |
                 Keycloak EC2 server
                 - Amazon Linux 2023
                 - ARM64 t4g.small
                 - 20 GiB encrypted gp3
                 - Elastic public IPv4
                 - SSM IAM permissions
                 - Secret-reading permission
                 - ports 22, 8080, 8443
                   limited to one /32 IP
                            |
                 TCP 5432 allowed only
                 by security-group reference
                            |
                            v
              RDS PostgreSQL 18.3 database
                   - db.t4g.micro
                   - private, no public IP
                   - encrypted 20 GiB gp3
                   - Performance Insights
                   - seven-day backups
                    /                    \
                   /                      \
   Private subnet 10.42.11.0/24   Private subnet 10.42.12.0/24
          us-east-1a                      us-east-1b
```

### Network ranges in simple words

- `10.42.0.0/16` is the large VPC neighborhood.
- `10.42.1.0/24` is the public street for the Keycloak server.
- `10.42.11.0/24` and `10.42.12.0/24` are private database streets.
- A `/24` contains 256 IPv4 addresses. AWS reserves five in a normal subnet.
- `68.32.112.68/32` means one exact IPv4 address.
- `0.0.0.0/0` means every IPv4 destination.

## 5. Planned Resource Inventory

| # | Terraform address | Type | What apply plans to create |
|---:|---|---|---|
| 1 | `aws_db_instance.keycloak` | AWS | Creates a managed PostgreSQL 18.3 database named `keycloak-demo-db`. Keycloak will store identity information such as realms, users, clients, roles, and sessions in it. |
| 2 | `aws_db_parameter_group.keycloak` | AWS | Creates a PostgreSQL settings bundle. It logs statements that take at least one second, forces SSL, and raises the planned connection limit to 150. |
| 3 | `aws_db_subnet_group.main` | AWS | Groups the two private subnets so RDS can place its network interfaces in separate Availability Zones. |
| 4 | `aws_eip.keycloak` | AWS | Reserves a stable public IPv4 address. The number is not known until AWS allocates it. |
| 5 | `aws_eip_association.keycloak` | AWS | Connects the stable Elastic IP to the Keycloak EC2 instance. |
| 6 | `aws_iam_instance_profile.keycloak` | AWS | Creates the wrapper that lets an EC2 instance receive an IAM role. Think of it as the badge holder for the server's permissions badge. |
| 7 | `aws_iam_policy.read_db_secret` | AWS | Creates a least-privilege policy that permits reading and describing only Keycloak database secrets under the named Secrets Manager path. |
| 8 | `aws_iam_role.keycloak` | AWS | Creates the IAM role the EC2 service may assume. The role is meant for the Keycloak server, not a human user. |
| 9 | `aws_iam_role_policy_attachment.read_db_secret` | AWS | Attaches the custom secret-reading policy to the Keycloak EC2 role. |
| 10 | `aws_iam_role_policy_attachment.ssm_core` | AWS | Attaches AWS's Systems Manager core policy so the server can register with SSM and support Session Manager. |
| 11 | `aws_instance.keycloak` | AWS | Creates an ARM-based Amazon Linux 2023 EC2 server of size `t4g.small`, with a 20 GiB encrypted gp3 root disk and IMDSv2 required. |
| 12 | `aws_internet_gateway.main` | AWS | Creates the VPC's doorway to and from the public internet. |
| 13 | `aws_route_table.private` | AWS | Creates a route table for the private database subnets. No internet default route is planned. |
| 14 | `aws_route_table.public` | AWS | Creates a route table with `0.0.0.0/0` pointing to the internet gateway, allowing public-subnet traffic to reach the internet. |
| 15 | `aws_route_table_association.private_a` | AWS | Connects private subnet A to the private route table. |
| 16 | `aws_route_table_association.private_b` | AWS | Connects private subnet B to the private route table. |
| 17 | `aws_route_table_association.public` | AWS | Connects the public subnet to the public route table. |
| 18 | `aws_secretsmanager_secret.db` | AWS | Creates a named Secrets Manager container for the PostgreSQL administrator credentials. |
| 19 | `aws_secretsmanager_secret.keycloak_admin` | AWS | Creates a named Secrets Manager container for the first Keycloak administrator credentials. |
| 20 | `aws_secretsmanager_secret_version.db` | AWS | Stores the generated database username/password data as the current value of the database secret. |
| 21 | `aws_secretsmanager_secret_version.keycloak_admin` | AWS | Stores the generated Keycloak bootstrap administrator credential as the current value of the admin secret. |
| 22 | `aws_security_group.database` | AWS | Creates the virtual firewall attached to RDS. Its separate rule permits PostgreSQL only from resources using the Keycloak security group. |
| 23 | `aws_security_group.keycloak` | AWS | Creates the virtual firewall attached to the Keycloak server. Separate rules allow SSH, HTTP, and HTTPS from one exact IPv4 address. |
| 24 | `aws_subnet.private_a` | AWS | Creates the private `10.42.11.0/24` subnet in `us-east-1a`. New resources do not receive public IPv4 addresses automatically. |
| 25 | `aws_subnet.private_b` | AWS | Creates the private `10.42.12.0/24` subnet in `us-east-1b`. It gives RDS a second Availability Zone to choose from. |
| 26 | `aws_subnet.public` | AWS | Creates the public `10.42.1.0/24` subnet in `us-east-1a`. New network interfaces may receive public IPv4 addresses. |
| 27 | `aws_vpc.main` | AWS | Creates the isolated AWS network `10.42.0.0/16` with DNS support and DNS hostnames enabled. |
| 28 | `aws_vpc_security_group_egress_rule.db_none` | AWS | Creates a database outbound rule pointing only to `127.0.0.1/32`. This is effectively a way to avoid useful outbound network access from RDS. |
| 29 | `aws_vpc_security_group_egress_rule.keycloak_all_out` | AWS | Allows the Keycloak EC2 server to start outbound connections to any IPv4 address using any protocol. |
| 30 | `aws_vpc_security_group_ingress_rule.db_from_keycloak` | AWS | Allows TCP port 5432 into RDS only when the source network interface uses the Keycloak security group. |
| 31 | `aws_vpc_security_group_ingress_rule.keycloak_http` | AWS | Allows troubleshooting HTTP traffic on TCP port 8080 from exactly `68.32.112.68/32`. |
| 32 | `aws_vpc_security_group_ingress_rule.keycloak_https` | AWS | Allows Keycloak HTTPS traffic on TCP port 8443 from exactly `68.32.112.68/32`. |
| 33 | `aws_vpc_security_group_ingress_rule.keycloak_ssh` | AWS | Allows SSH on TCP port 22 from exactly `68.32.112.68/32`. |
| 34 | `random_id.suffix` | Terraform Random provider | Creates a three-byte random value inside Terraform. The hexadecimal form is used to make IAM and secret names less likely to collide. |
| 35 | `random_password.db` | Terraform Random provider | Generates a 32-character database password with uppercase, lowercase, numbers, and special characters. |
| 36 | `random_password.keycloak_admin` | Terraform Random provider | Generates a 24-character Keycloak administrator password with uppercase, lowercase, numbers, and selected special characters. |

## 6. Detailed Resource-by-Resource Explanation

Each section has four parts:

1. What Terraform plans to create.
2. Why it is needed.
3. A table explaining the named settings.
4. Commands to verify the result after `terraform apply`.

### 6.1. `aws_db_instance.keycloak` — Amazon RDS PostgreSQL database for Keycloak

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a managed PostgreSQL 18.3 database named `keycloak-demo-db`. Keycloak will store identity information such as realms, users, clients, roles, and sessions in it.

**Dependency idea:** Depends on the private subnets, DB subnet group, DB parameter group, database security group, password, and usually the secret setup.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `address` | `(known after apply)` | The DNS name clients used to reach the RDS database. Think of it as the database’s street name. |
| `allocated_storage` | `20` | The starting storage size in gibibytes (GiB). Here, `20` means about 20 GiB. |
| `apply_immediately` | `false` | Whether changes should happen right away instead of waiting for the maintenance window. |
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `auto_minor_version_upgrade` | `true` | Allows AWS to install compatible minor database engine updates automatically. |
| `availability_zone` | `(known after apply)` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `backup_retention_period` | `7` | How many days automated RDS backups were kept. `7` means one week. |
| `backup_target` | `(known after apply)` | Where RDS backups are managed. `region` means the normal regional RDS backup system. |
| `backup_window` | `"07:00-08:00"` | The daily UTC time window AWS preferred for automated backups. |
| `ca_cert_identifier` | `(known after apply)` | The AWS certificate authority used to prove the RDS server’s TLS identity. |
| `character_set_name` | `(known after apply)` | The character set used by database engines that support choosing one. PostgreSQL normally leaves this managed by the service. |
| `copy_tags_to_snapshot` | `true` | Copies the database tags to snapshots created from it. |
| `database_insights_mode` | `(known after apply)` | The level of database monitoring insights. `standard` is the standard mode. |
| `db_name` | `"keycloak"` | The initial PostgreSQL database created inside the RDS server. |
| `db_subnet_group_name` | `"keycloak-demo-db-subnets"` | The subnet group that told RDS where it could place network interfaces. |
| `dedicated_log_volume` | `false` | Whether database logs used a separate storage volume. `false` means they shared normal storage. |
| `delete_automated_backups` | `true` | Whether RDS automated backups should also be removed when the DB instance is deleted. |
| `deletion_protection` | `false` | A safety lock that blocks accidental database deletion. `false` means deletion was allowed. |
| `domain_fqdn` | `(known after apply)` | A fully qualified domain name used when a database joins a directory domain. It will normally stay empty unless domain integration is configured. |
| `enabled_cloudwatch_logs_exports` | `[` | Database log types sent to CloudWatch Logs. |
| `endpoint` | `(known after apply)` | The database DNS name plus its port. |
| `engine` | `"postgres"` | The database software. Here it was PostgreSQL. |
| `engine_lifecycle_support` | `(known after apply)` | The AWS lifecycle support program selected for the engine version. |
| `engine_version` | `"18.3"` | The requested PostgreSQL version. |
| `engine_version_actual` | `(known after apply)` | The PostgreSQL version actually running. |
| `hosted_zone_id` | `(known after apply)` | The AWS Route 53 hosted-zone identifier used internally for the RDS endpoint. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `identifier` | `"keycloak-demo-db"` | The chosen RDS database instance name. |
| `identifier_prefix` | `(known after apply)` | An optional beginning for an AWS-generated database identifier. A fixed `identifier` is already supplied here. |
| `instance_class` | `"db.t4g.micro"` | The RDS computer size. `db.t4g.micro` is a small ARM-based burstable class. |
| `iops` | `(known after apply)` | The number of storage input/output operations per second provisioned for the volume. |
| `kms_key_id` | `(known after apply)` | The KMS encryption key ARN used to protect data at rest. |
| `latest_restorable_time` | `(known after apply)` | The most recent time to which point-in-time recovery was available before deletion. |
| `license_model` | `(known after apply)` | The software license model. PostgreSQL uses its open-source license. |
| `listener_endpoint` | `(known after apply)` | Optional listener endpoints. Empty means none were configured. |
| `maintenance_window` | `"mon:08:30-mon:09:30"` | The weekly UTC window AWS preferred for maintenance. |
| `master_user_secret` | `(known after apply)` | Information about an RDS-managed master-user secret. Empty means Terraform managed the password another way. |
| `master_user_secret_kms_key_id` | `(known after apply)` | The KMS key that would encrypt an RDS-managed master-user secret. This plan manages the password separately, so AWS decides whether this field is used. |
| `max_allocated_storage` | `100` | The maximum storage size RDS autoscaling could grow to. |
| `monitoring_interval` | `0` | How often enhanced operating-system metrics were collected. `0` means enhanced monitoring was off. |
| `monitoring_role_arn` | `(known after apply)` | The IAM role used for RDS Enhanced Monitoring. The monitoring interval is zero, so Enhanced Monitoring is disabled. |
| `multi_az` | `false` | Whether a standby DB instance existed in another Availability Zone. `false` means no standby. |
| `nchar_character_set_name` | `(known after apply)` | An optional national character set for database engines that support it. It is normally not used for PostgreSQL. |
| `network_type` | `(known after apply)` | The IP family. `IPV4` means IPv4 only. |
| `option_group_name` | `(known after apply)` | The RDS option group. The shown value was the AWS default for PostgreSQL 18. |
| `parameter_group_name` | `"keycloak-demo-pg18-params"` | The custom database settings group attached to the instance. |
| `password` | `(sensitive value)` | The PostgreSQL master password. Terraform hid it because it is sensitive. |
| `password_wo` | `(write-only attribute)` | A write-only password field. Terraform can send it to AWS but does not read it back. |
| `performance_insights_enabled` | `true` | Turns on RDS Performance Insights for database performance analysis. |
| `performance_insights_kms_key_id` | `(known after apply)` | The KMS key used to encrypt Performance Insights data. |
| `performance_insights_retention_period` | `7` | How many days Performance Insights data was retained. |
| `port` | `(known after apply)` | The network port. PostgreSQL normally uses `5432`. |
| `publicly_accessible` | `false` | Whether RDS could receive a public internet address. `false` kept it private. |
| `replica_mode` | `(known after apply)` | How an RDS replica works when replication is configured. This database is planned as a normal standalone instance. |
| `replicas` | `(known after apply)` | Read-replica database identifiers. Empty means there were no read replicas. |
| `resource_id` | `(known after apply)` | An internal stable AWS identifier for the RDS database. |
| `skip_final_snapshot` | `true` | Whether RDS deletion skips creating a final manual snapshot. `true` means no final snapshot was made. |
| `snapshot_identifier` | `(known after apply)` | An existing snapshot from which AWS could restore the database. No fixed snapshot is shown, so Terraform plans a new database. |
| `status` | `(known after apply)` | The current service status, such as `available`. |
| `storage_encrypted` | `true` | Whether database storage was encrypted. |
| `storage_throughput` | `(known after apply)` | The gp3 storage throughput in MiB per second. |
| `storage_type` | `"gp3"` | The EBS-style RDS storage type. `gp3` is general-purpose SSD storage. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `timezone` | `(known after apply)` | An optional database time-zone setting for supported engines. AWS will decide the final value if it applies. |
| `username` | `"kcadmin"` | The PostgreSQL master login name. |
| `vpc_security_group_ids` | `(known after apply)` | The security-group IDs attached to the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_db_instance" "keycloak" {
    + address                               = (known after apply)
    + allocated_storage                     = 20
    + apply_immediately                     = false
    + arn                                   = (known after apply)
    + auto_minor_version_upgrade            = true
    + availability_zone                     = (known after apply)
    + backup_retention_period               = 7
    + backup_target                         = (known after apply)
    + backup_window                         = "07:00-08:00"
    + ca_cert_identifier                    = (known after apply)
    + character_set_name                    = (known after apply)
    + copy_tags_to_snapshot                 = true
    + database_insights_mode                = (known after apply)
    + db_name                               = "keycloak"
    + db_subnet_group_name                  = "keycloak-demo-db-subnets"
    + dedicated_log_volume                  = false
    + delete_automated_backups              = true
    + deletion_protection                   = false
    + domain_fqdn                           = (known after apply)
    + enabled_cloudwatch_logs_exports       = [
        + "postgresql",
        + "upgrade",
      ]
    + endpoint                              = (known after apply)
    + engine                                = "postgres"
    + engine_lifecycle_support              = (known after apply)
    + engine_version                        = "18.3"
    + engine_version_actual                 = (known after apply)
    + hosted_zone_id                        = (known after apply)
    + id                                    = (known after apply)
    + identifier                            = "keycloak-demo-db"
    + identifier_prefix                     = (known after apply)
    + instance_class                        = "db.t4g.micro"
    + iops                                  = (known after apply)
    + kms_key_id                            = (known after apply)
    + latest_restorable_time                = (known after apply)
    + license_model                         = (known after apply)
    + listener_endpoint                     = (known after apply)
    + maintenance_window                    = "mon:08:30-mon:09:30"
    + master_user_secret                    = (known after apply)
    + master_user_secret_kms_key_id         = (known after apply)
    + max_allocated_storage                 = 100
    + monitoring_interval                   = 0
    + monitoring_role_arn                   = (known after apply)
    + multi_az                              = false
    + nchar_character_set_name              = (known after apply)
    + network_type                          = (known after apply)
    + option_group_name                     = (known after apply)
    + parameter_group_name                  = "keycloak-demo-pg18-params"
    + password                              = (sensitive value)
    + password_wo                           = (write-only attribute)
    + performance_insights_enabled          = true
    + performance_insights_kms_key_id       = (known after apply)
    + performance_insights_retention_period = 7
    + port                                  = (known after apply)
    + publicly_accessible                   = false
    + replica_mode                          = (known after apply)
    + replicas                              = (known after apply)
    + resource_id                           = (known after apply)
    + skip_final_snapshot                   = true
    + snapshot_identifier                   = (known after apply)
    + status                                = (known after apply)
    + storage_encrypted                     = true
    + storage_throughput                    = (known after apply)
    + storage_type                          = "gp3"
    + tags                                  = {
        + "Name" = "keycloak-demo-db"
      }
    + tags_all                              = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-db"
        + "Project"     = "keycloak-demo"
      }
    + timezone                              = (known after apply)
    + username                              = "kcadmin"
    + vpc_security_group_ids                = (known after apply)
  }
```

#### Verify after apply

```bash
aws rds describe-db-instances   --region us-east-1   --db-instance-identifier keycloak-demo-db   --query "DBInstances[0].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,Endpoint.Address,Endpoint.Port,PubliclyAccessible,MultiAZ]"   --output table
```

### 6.2. `aws_db_parameter_group.keycloak` — Custom RDS PostgreSQL parameter group

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a PostgreSQL settings bundle. It logs statements that take at least one second, forces SSL, and raises the planned connection limit to 150.

**Dependency idea:** Can be created early because it mainly depends on the AWS provider and chosen PostgreSQL family.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak tuning for PostgreSQL 18"` | Human-readable notes explaining why the resource or rule exists. |
| `family` | `"postgres18"` | The database engine family that the parameter group supports. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-pg18-params"` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `skip_destroy` | `false` | Whether Terraform should leave the parameter group behind during destroy. `false` means delete it. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `parameter.apply_method` | `"immediate"` | When a database setting takes effect: immediately or after reboot. |
| `parameter.name` | `"log_min_duration_statement"` | The friendly AWS name of the object. |
| `parameter.value` | `"1000"` | The configured value for a parameter. |
| `parameter.name` | `"rds.force_ssl"` | The friendly AWS name of the object. |
| `parameter.value` | `"1"` | The configured value for a parameter. |
| `parameter.apply_method` | `"pending-reboot"` | When a database setting takes effect: immediately or after reboot. |
| `parameter.name` | `"max_connections"` | The friendly AWS name of the object. |
| `parameter.value` | `"150"` | The configured value for a parameter. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_db_parameter_group" "keycloak" {
    + arn          = (known after apply)
    + description  = "Keycloak tuning for PostgreSQL 18"
    + family       = "postgres18"
    + id           = (known after apply)
    + name         = "keycloak-demo-pg18-params"
    + name_prefix  = (known after apply)
    + skip_destroy = false
    + tags_all     = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }

    + parameter {
        + apply_method = "immediate"
        + name         = "log_min_duration_statement"
        + value        = "1000"
      }
    + parameter {
        + apply_method = "immediate"
        + name         = "rds.force_ssl"
        + value        = "1"
      }
    + parameter {
        + apply_method = "pending-reboot"
        + name         = "max_connections"
        + value        = "150"
      }
  }
```

#### Verify after apply

```bash
aws rds describe-db-parameter-groups   --region us-east-1   --db-parameter-group-name keycloak-demo-pg18-params   --output table

aws rds describe-db-parameters   --region us-east-1   --db-parameter-group-name keycloak-demo-pg18-params   --query "Parameters[?ParameterName=='log_min_duration_statement' || ParameterName=='max_connections' || ParameterName=='rds.force_ssl'].[ParameterName,ParameterValue,ApplyMethod,Source]"   --output table
```

### 6.3. `aws_db_subnet_group.main` — RDS database subnet group

**Type:** AWS resource or AWS relationship

**What apply will create:** Groups the two private subnets so RDS can place its network interfaces in separate Availability Zones.

**Dependency idea:** Depends on both private subnets.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Private subnets for the Keycloak database"` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `"keycloak-demo-db-subnets"` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `subnet_ids` | `(known after apply)` | The list of subnets in a subnet group. |
| `supported_network_types` | `(known after apply)` | IP network families supported by the subnet group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_db_subnet_group" "main" {
    + arn                     = (known after apply)
    + description             = "Private subnets for the Keycloak database"
    + id                      = (known after apply)
    + name                    = "keycloak-demo-db-subnets"
    + name_prefix             = (known after apply)
    + subnet_ids              = (known after apply)
    + supported_network_types = (known after apply)
    + tags                    = {
        + "Name" = "keycloak-demo-db-subnets"
      }
    + tags_all                = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-db-subnets"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id                  = (known after apply)
  }
```

#### Verify after apply

```bash
aws rds describe-db-subnet-groups   --region us-east-1   --db-subnet-group-name keycloak-demo-db-subnets   --query "DBSubnetGroups[0].[DBSubnetGroupName,VpcId,SubnetGroupStatus,Subnets[*].SubnetIdentifier]"   --output json
```

### 6.4. `aws_eip.keycloak` — Elastic IP address

**Type:** AWS resource or AWS relationship

**What apply will create:** Reserves a stable public IPv4 address. The number is not known until AWS allocates it.

**Dependency idea:** Can be allocated independently, but it is useful only after association.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `allocation_id` | `(known after apply)` | The AWS identifier for an allocated Elastic IP address. |
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `association_id` | `(known after apply)` | The identifier for the link between an Elastic IP and a network interface or instance. |
| `carrier_ip` | `(known after apply)` | A carrier-grade IP address used in special AWS networking designs such as Wavelength. It is not expected in a normal VPC Elastic IP setup. |
| `customer_owned_ip` | `(known after apply)` | An address from a customer-owned IP pool. This design uses an Amazon-owned Elastic IP instead. |
| `domain` | `"vpc"` | The network scope of the Elastic IP. `vpc` means it was for EC2-VPC. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `instance` | `(known after apply)` | The EC2 instance ID associated with the Elastic IP. |
| `ipam_pool_id` | `(known after apply)` | The VPC IP Address Manager pool that could supply the address. No pool is fixed in this plan. |
| `network_border_group` | `(known after apply)` | The AWS network location from which the public IP was advertised. |
| `network_interface` | `(known after apply)` | The Elastic Network Interface attached to the address. |
| `private_dns` | `(known after apply)` | The internal AWS DNS name. |
| `private_ip` | `(known after apply)` | The private IPv4 address inside the VPC. |
| `ptr_record` | `(known after apply)` | A reverse-DNS record for the public IP. AWS will report it if one exists. |
| `public_dns` | `(known after apply)` | The public AWS DNS name. |
| `public_ip` | `(known after apply)` | The public IPv4 address. |
| `public_ipv4_pool` | `(known after apply)` | The pool that supplied the public address. `amazon` means the normal AWS pool. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc` | `(known after apply)` | Legacy field confirming the Elastic IP belongs to a VPC. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_eip" "keycloak" {
    + allocation_id        = (known after apply)
    + arn                  = (known after apply)
    + association_id       = (known after apply)
    + carrier_ip           = (known after apply)
    + customer_owned_ip    = (known after apply)
    + domain               = "vpc"
    + id                   = (known after apply)
    + instance             = (known after apply)
    + ipam_pool_id         = (known after apply)
    + network_border_group = (known after apply)
    + network_interface    = (known after apply)
    + private_dns          = (known after apply)
    + private_ip           = (known after apply)
    + ptr_record           = (known after apply)
    + public_dns           = (known after apply)
    + public_ip            = (known after apply)
    + public_ipv4_pool     = (known after apply)
    + tags                 = {
        + "Name" = "keycloak-demo-keycloak-eip"
      }
    + tags_all             = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-keycloak-eip"
        + "Project"     = "keycloak-demo"
      }
    + vpc                  = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-addresses   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak-eip"   --query "Addresses[*].[AllocationId,PublicIp,AssociationId,InstanceId,PrivateIpAddress]"   --output table
```

### 6.5. `aws_eip_association.keycloak` — Elastic IP-to-EC2 association

**Type:** AWS resource or AWS relationship

**What apply will create:** Connects the stable Elastic IP to the Keycloak EC2 instance.

**Dependency idea:** Depends on both the Elastic IP and the EC2 instance.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `allocation_id` | `(known after apply)` | The AWS identifier for an allocated Elastic IP address. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `instance_id` | `(known after apply)` | The EC2 instance identifier used by the Elastic IP association. |
| `network_interface_id` | `(known after apply)` | The identifier of an Elastic Network Interface. |
| `private_ip_address` | `(known after apply)` | The private IPv4 address used by the association. |
| `public_ip` | `(known after apply)` | The public IPv4 address. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_eip_association" "keycloak" {
    + allocation_id        = (known after apply)
    + id                   = (known after apply)
    + instance_id          = (known after apply)
    + network_interface_id = (known after apply)
    + private_ip_address   = (known after apply)
    + public_ip            = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-addresses   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak-eip"   --query "Addresses[*].[PublicIp,AllocationId,AssociationId,InstanceId,NetworkInterfaceId]"   --output table
```

### 6.6. `aws_iam_instance_profile.keycloak` — IAM instance profile

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the wrapper that lets an EC2 instance receive an IAM role. Think of it as the badge holder for the server's permissions badge.

**Dependency idea:** Depends on the IAM role.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `create_date` | `(known after apply)` | The date and time AWS created the IAM object. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `(known after apply)` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `path` | `"/"` | The IAM folder-like path. `/` means the top level. |
| `role` | `(known after apply)` | The IAM role name placed in the instance profile or used by an attachment. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `unique_id` | `(known after apply)` | An AWS-generated IAM identifier that is different from the friendly name. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_iam_instance_profile" "keycloak" {
    + arn         = (known after apply)
    + create_date = (known after apply)
    + id          = (known after apply)
    + name        = (known after apply)
    + name_prefix = (known after apply)
    + path        = "/"
    + role        = (known after apply)
    + tags_all    = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + unique_id   = (known after apply)
  }
```

#### Verify after apply

```bash
aws iam list-instance-profiles   --query "InstanceProfiles[?starts_with(InstanceProfileName, 'keycloak-demo-keycloak-profile-')].[InstanceProfileName,Arn,Roles[0].RoleName]"   --output table
```

### 6.7. `aws_iam_policy.read_db_secret` — Customer-managed IAM policy for database-secret access

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a least-privilege policy that permits reading and describing only Keycloak database secrets under the named Secrets Manager path.

**Dependency idea:** Depends on the generated suffix and the policy document.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `attachment_count` | `(known after apply)` | How many users, groups, or roles currently had the policy attached. |
| `description` | `"Read only the Keycloak database secret"` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `(known after apply)` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `path` | `"/"` | The IAM folder-like path. `/` means the top level. |
| `policy` | `jsonencode(` | The JSON permissions document describing allowed or denied AWS actions. |
| `policy.Statement` | `[` | The list of permission or trust rules in a policy document. |
| `policy.Statement.Action` | `[` | The AWS API operations a policy statement controls. |
| `policy.Statement.Effect` | `"Allow"` | Whether the statement allows or denies the listed actions. |
| `policy.Statement.Resource` | `"arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-*"` | Which AWS resource ARNs the permission applies to. |
| `policy.Statement.Sid` | `"ReadOnlyTheKeycloakDbSecret"` | An optional statement name used to make a policy easier to read. |
| `Version` | `"2012-10-17"` | The IAM policy-language version, not a revision number for your policy. |
| `policy_id` | `(known after apply)` | AWS’s unique identifier for a customer-managed IAM policy. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_iam_policy" "read_db_secret" {
    + arn              = (known after apply)
    + attachment_count = (known after apply)
    + description      = "Read only the Keycloak database secret"
    + id               = (known after apply)
    + name             = (known after apply)
    + name_prefix      = (known after apply)
    + path             = "/"
    + policy           = jsonencode(
          {
            + Statement = [
                + {
                    + Action   = [
                        + "secretsmanager:GetSecretValue",
                        + "secretsmanager:DescribeSecret",
                      ]
                    + Effect   = "Allow"
                    + Resource = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-*"
                    + Sid      = "ReadOnlyTheKeycloakDbSecret"
                  },
              ]
            + Version   = "2012-10-17"
          }
      )
    + policy_id        = (known after apply)
    + tags_all         = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
  }
```

#### Verify after apply

```bash
aws iam list-policies   --scope Local   --query "Policies[?starts_with(PolicyName, 'keycloak-demo-read-db-secret-')].[PolicyName,Arn,AttachmentCount]"   --output table
```

### 6.8. `aws_iam_role.keycloak` — IAM role used by the Keycloak EC2 instance

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the IAM role the EC2 service may assume. The role is meant for the Keycloak server, not a human user.

**Dependency idea:** Depends on the EC2 trust-policy document and random suffix.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assume_role_policy` | `jsonencode(` | The trust policy describing who is allowed to use the role. |
| `assume_role_policy.Statement` | `[` | The list of permission or trust rules in a policy document. |
| `assume_role_policy.Statement.Action` | `"sts:AssumeRole"` | The AWS API operations a policy statement controls. |
| `assume_role_policy.Statement.Effect` | `"Allow"` | Whether the statement allows or denies the listed actions. |
| `assume_role_policy.Statement.Principal` | `{` | Who is trusted by a role policy. |
| `assume_role_policy.Statement.Principal.Service` | `"ec2.amazonaws.com"` | The AWS service principal. `ec2.amazonaws.com` means EC2. |
| `assume_role_policy.Statement.Sid` | `"AllowEC2ToAssume"` | An optional statement name used to make a policy easier to read. |
| `Version` | `"2012-10-17"` | The IAM policy-language version, not a revision number for your policy. |
| `create_date` | `(known after apply)` | The date and time AWS created the IAM object. |
| `description` | `"Least privilege role for the Keycloak EC2 instance"` | Human-readable notes explaining why the resource or rule exists. |
| `force_detach_policies` | `false` | Whether IAM should force-detach policies during role deletion. `false` means Terraform must detach them first. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `managed_policy_arns` | `(known after apply)` | Managed policies attached to the role. |
| `max_session_duration` | `3600` | The longest role session in seconds. `3600` means one hour. |
| `name` | `(known after apply)` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `path` | `"/"` | The IAM folder-like path. `/` means the top level. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `unique_id` | `(known after apply)` | An AWS-generated IAM identifier that is different from the friendly name. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_iam_role" "keycloak" {
    + arn                   = (known after apply)
    + assume_role_policy    = jsonencode(
          {
            + Statement = [
                + {
                    + Action    = "sts:AssumeRole"
                    + Effect    = "Allow"
                    + Principal = {
                        + Service = "ec2.amazonaws.com"
                      }
                    + Sid       = "AllowEC2ToAssume"
                  },
              ]
            + Version   = "2012-10-17"
          }
      )
    + create_date           = (known after apply)
    + description           = "Least privilege role for the Keycloak EC2 instance"
    + force_detach_policies = false
    + id                    = (known after apply)
    + managed_policy_arns   = (known after apply)
    + max_session_duration  = 3600
    + name                  = (known after apply)
    + name_prefix           = (known after apply)
    + path                  = "/"
    + tags_all              = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + unique_id             = (known after apply)

    + inline_policy (known after apply)
  }
```

#### Verify after apply

```bash
aws iam list-roles   --query "Roles[?starts_with(RoleName, 'keycloak-demo-keycloak-role-')].[RoleName,Arn,MaxSessionDuration]"   --output table
```

### 6.9. `aws_iam_role_policy_attachment.read_db_secret` — Database-secret policy attachment

**Type:** AWS resource or AWS relationship

**What apply will create:** Attaches the custom secret-reading policy to the Keycloak EC2 role.

**Dependency idea:** Depends on the custom policy and IAM role.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `policy_arn` | `(known after apply)` | The full ARN of the managed IAM policy being attached. |
| `role` | `(known after apply)` | The IAM role name placed in the instance profile or used by an attachment. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_iam_role_policy_attachment" "read_db_secret" {
    + id         = (known after apply)
    + policy_arn = (known after apply)
    + role       = (known after apply)
  }
```

#### Verify after apply

```bash
ROLE_NAME=$(aws iam list-roles   --query "Roles[?starts_with(RoleName, 'keycloak-demo-keycloak-role-')].RoleName | [0]"   --output text)

aws iam list-attached-role-policies   --role-name "$ROLE_NAME"   --query "AttachedPolicies[?starts_with(PolicyName, 'keycloak-demo-read-db-secret-')]"   --output table
```

### 6.10. `aws_iam_role_policy_attachment.ssm_core` — AWS Systems Manager policy attachment

**Type:** AWS resource or AWS relationship

**What apply will create:** Attaches AWS's Systems Manager core policy so the server can register with SSM and support Session Manager.

**Dependency idea:** Depends on the IAM role.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `policy_arn` | `"arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"` | The full ARN of the managed IAM policy being attached. |
| `role` | `(known after apply)` | The IAM role name placed in the instance profile or used by an attachment. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_iam_role_policy_attachment" "ssm_core" {
    + id         = (known after apply)
    + policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    + role       = (known after apply)
  }
```

#### Verify after apply

```bash
ROLE_NAME=$(aws iam list-roles   --query "Roles[?starts_with(RoleName, 'keycloak-demo-keycloak-role-')].RoleName | [0]"   --output text)

aws iam list-attached-role-policies   --role-name "$ROLE_NAME"   --query "AttachedPolicies[?PolicyName=='AmazonSSMManagedInstanceCore']"   --output table
```

### 6.11. `aws_instance.keycloak` — Keycloak EC2 virtual server

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates an ARM-based Amazon Linux 2023 EC2 server of size `t4g.small`, with a 20 GiB encrypted gp3 root disk and IMDSv2 required.

**Dependency idea:** Depends on the public subnet, Keycloak security group, IAM instance profile, selected AMI, startup data, and often the secrets.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `ami` | `(sensitive value)` | The Amazon Machine Image used to start the server. Terraform hid the value because it was marked sensitive. |
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `associate_public_ip_address` | `(known after apply)` | Whether the primary network interface received a public IPv4 address at launch. |
| `availability_zone` | `(known after apply)` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `cpu_core_count` | `(known after apply)` | Number of CPU cores shown for the instance. |
| `cpu_threads_per_core` | `(known after apply)` | Number of hardware threads per CPU core. |
| `disable_api_stop` | `(known after apply)` | A protection flag that can block API stop calls. `false` means stopping was allowed. |
| `disable_api_termination` | `(known after apply)` | A protection flag that can block termination. `false` means deletion was allowed. |
| `ebs_optimized` | `(known after apply)` | Whether the instance used explicitly enabled EBS optimization. Some newer types include it by default. |
| `enable_primary_ipv6` | `(known after apply)` | Whether the primary network interface should receive a primary IPv6 address. |
| `get_password_data` | `false` | Whether Terraform tried to retrieve Windows administrator password data. `false` is normal for Linux. |
| `host_id` | `(known after apply)` | The ID of a dedicated host if the instance runs on one. This instance uses normal shared tenancy. |
| `host_resource_group_arn` | `(known after apply)` | The resource group for a dedicated host. It normally stays unused for default tenancy. |
| `iam_instance_profile` | `(known after apply)` | The instance profile attached to the EC2 server. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `instance_initiated_shutdown_behavior` | `(known after apply)` | What AWS should do when the operating system shuts down. `stop` means stop, not terminate. |
| `instance_lifecycle` | `(known after apply)` | Whether the server is an on-demand, spot, or another lifecycle type. AWS reports the final value after creation. |
| `instance_state` | `(known after apply)` | The EC2 state at plan time. It was `running`. |
| `instance_type` | `"t4g.small"` | The EC2 computer size. `t4g.small` is an ARM-based burstable instance. |
| `ipv6_address_count` | `(known after apply)` | How many IPv6 addresses were assigned. |
| `ipv6_addresses` | `(known after apply)` | The actual IPv6 addresses. Empty means none. |
| `key_name` | `(known after apply)` | The EC2 key-pair name used for traditional SSH authentication. The final value depends on the Terraform configuration. |
| `monitoring` | `false` | Whether detailed one-minute EC2 monitoring was enabled. `false` means basic monitoring. |
| `outpost_arn` | `(known after apply)` | The AWS Outposts location ARN if the instance runs on customer premises. This normal regional instance should not use one. |
| `password_data` | `(known after apply)` | Encrypted Windows administrator password data. An Amazon Linux instance does not normally use it. |
| `placement_group` | `(known after apply)` | An optional EC2 placement group that controls how instances are physically placed. None is fixed here. |
| `placement_partition_number` | `(known after apply)` | Partition placement-group number. `0` means no special partition placement. |
| `primary_network_interface_id` | `(known after apply)` | The main virtual network card attached to the instance. |
| `private_dns` | `(known after apply)` | The internal AWS DNS name. |
| `private_ip` | `(known after apply)` | The private IPv4 address inside the VPC. |
| `public_dns` | `(known after apply)` | The public AWS DNS name. |
| `public_ip` | `(known after apply)` | The public IPv4 address. |
| `secondary_private_ips` | `(known after apply)` | Extra private IPv4 addresses. Empty means none. |
| `security_groups` | `(known after apply)` | Security-group names used in EC2-Classic style output. Empty is normal when IDs are used in a VPC. |
| `source_dest_check` | `true` | Normal EC2 packet checking. `true` is right for an application server; routers often disable it. |
| `spot_instance_request_id` | `(known after apply)` | The request ID when an instance is launched as Spot capacity. This design appears to use regular on-demand capacity. |
| `subnet_id` | `(known after apply)` | The subnet containing the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `tenancy` | `(known after apply)` | Whether hardware was shared or dedicated. `default` means standard shared tenancy. |
| `user_data` | `(known after apply)` | A hash of the startup script, not the script text itself. |
| `user_data_base64` | `(known after apply)` | A Base64-encoded startup script. The configuration may use plain `user_data` instead. |
| `user_data_replace_on_change` | `true` | Whether changing the startup script causes Terraform to replace the EC2 instance. |
| `vpc_security_group_ids` | `(known after apply)` | The security-group IDs attached to the resource. |
| `metadata_options.http_endpoint` | `"enabled"` | Whether the EC2 Instance Metadata Service endpoint was enabled. |
| `metadata_options.http_protocol_ipv6` | `"disabled"` | Whether metadata could be reached over IPv6. |
| `metadata_options.http_put_response_hop_limit` | `1` | How many network hops an IMDSv2 token response may travel. `1` is restrictive. |
| `metadata_options.http_tokens` | `"required"` | Whether IMDSv2 tokens are required. `required` blocks older IMDSv1 requests. |
| `metadata_options.instance_metadata_tags` | `"enabled"` | Whether instance tags can be read through the metadata service. |
| `root_block_device.delete_on_termination` | `true` | Whether the disk is automatically deleted when the EC2 instance is terminated. |
| `root_block_device.device_name` | `(known after apply)` | The Linux device mapping name for the disk. |
| `root_block_device.encrypted` | `true` | Whether the disk was encrypted. |
| `root_block_device.iops` | `(known after apply)` | The number of storage input/output operations per second provisioned for the volume. |
| `root_block_device.kms_key_id` | `(known after apply)` | The KMS encryption key ARN used to protect data at rest. |
| `root_block_device.tags_all` | `(known after apply)` | All labels after combining the resource’s own tags with provider-level default tags. |
| `root_block_device.throughput` | `(known after apply)` | The gp3 disk throughput in MiB per second. |
| `root_block_device.volume_id` | `(known after apply)` | The EBS volume identifier. |
| `root_block_device.volume_size` | `20` | Disk size in GiB. |
| `root_block_device.volume_type` | `"gp3"` | The EBS volume type. `gp3` is general-purpose SSD. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_instance" "keycloak" {
    + ami                                  = (sensitive value)
    + arn                                  = (known after apply)
    + associate_public_ip_address          = (known after apply)
    + availability_zone                    = (known after apply)
    + cpu_core_count                       = (known after apply)
    + cpu_threads_per_core                 = (known after apply)
    + disable_api_stop                     = (known after apply)
    + disable_api_termination              = (known after apply)
    + ebs_optimized                        = (known after apply)
    + enable_primary_ipv6                  = (known after apply)
    + get_password_data                    = false
    + host_id                              = (known after apply)
    + host_resource_group_arn              = (known after apply)
    + iam_instance_profile                 = (known after apply)
    + id                                   = (known after apply)
    + instance_initiated_shutdown_behavior = (known after apply)
    + instance_lifecycle                   = (known after apply)
    + instance_state                       = (known after apply)
    + instance_type                        = "t4g.small"
    + ipv6_address_count                   = (known after apply)
    + ipv6_addresses                       = (known after apply)
    + key_name                             = (known after apply)
    + monitoring                           = false
    + outpost_arn                          = (known after apply)
    + password_data                        = (known after apply)
    + placement_group                      = (known after apply)
    + placement_partition_number           = (known after apply)
    + primary_network_interface_id         = (known after apply)
    + private_dns                          = (known after apply)
    + private_ip                           = (known after apply)
    + public_dns                           = (known after apply)
    + public_ip                            = (known after apply)
    + secondary_private_ips                = (known after apply)
    + security_groups                      = (known after apply)
    + source_dest_check                    = true
    + spot_instance_request_id             = (known after apply)
    + subnet_id                            = (known after apply)
    + tags                                 = {
        + "Name" = "keycloak-demo-keycloak"
      }
    + tags_all                             = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-keycloak"
        + "Project"     = "keycloak-demo"
      }
    + tenancy                              = (known after apply)
    + user_data                            = (known after apply)
    + user_data_base64                     = (known after apply)
    + user_data_replace_on_change          = true
    + vpc_security_group_ids               = (known after apply)

    + capacity_reservation_specification (known after apply)

    + cpu_options (known after apply)

    + ebs_block_device (known after apply)

    + enclave_options (known after apply)

    + ephemeral_block_device (known after apply)

    + instance_market_options (known after apply)

    + maintenance_options (known after apply)

    + metadata_options {
        + http_endpoint               = "enabled"
        + http_protocol_ipv6          = "disabled"
        + http_put_response_hop_limit = 1
        + http_tokens                 = "required"
        + instance_metadata_tags      = "enabled"
      }

    + network_interface (known after apply)

    + private_dns_name_options (known after apply)

    + root_block_device {
        + delete_on_termination = true
        + device_name           = (known after apply)
        + encrypted             = true
        + iops                  = (known after apply)
        + kms_key_id            = (known after apply)
        + tags_all              = (known after apply)
        + throughput            = (known after apply)
        + volume_id             = (known after apply)
        + volume_size           = 20
        + volume_type           = "gp3"
      }
  }
```

#### Verify after apply

```bash
aws ec2 describe-instances   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak"             "Name=instance-state-name,Values=pending,running,stopping,stopped"   --query "Reservations[*].Instances[*].[InstanceId,State.Name,InstanceType,Architecture,PrivateIpAddress,PublicIpAddress,SubnetId,IamInstanceProfile.Arn]"   --output table
```

### 6.12. `aws_internet_gateway.main` — Internet gateway

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the VPC's doorway to and from the public internet.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_internet_gateway" "main" {
    + arn      = (known after apply)
    + id       = (known after apply)
    + owner_id = (known after apply)
    + tags     = {
        + "Name" = "keycloak-demo-igw"
      }
    + tags_all = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-igw"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id   = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-internet-gateways   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-igw"   --query "InternetGateways[*].[InternetGatewayId,Attachments[0].VpcId,Attachments[0].State]"   --output table
```

### 6.13. `aws_route_table.private` — Private route table

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a route table for the private database subnets. No internet default route is planned.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `propagating_vgws` | `(known after apply)` | Virtual private gateways automatically propagating routes. Empty means none. |
| `route` | `(known after apply)` | The route entries in the route table. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_route_table" "private" {
    + arn              = (known after apply)
    + id               = (known after apply)
    + owner_id         = (known after apply)
    + propagating_vgws = (known after apply)
    + route            = (known after apply)
    + tags             = {
        + "Name" = "keycloak-demo-rt-private"
      }
    + tags_all         = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-rt-private"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id           = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-rt-private"   --query "RouteTables[*].[RouteTableId,VpcId,Routes,Associations[*].SubnetId]"   --output json
```

### 6.14. `aws_route_table.public` — Public route table

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a route table with `0.0.0.0/0` pointing to the internet gateway, allowing public-subnet traffic to reach the internet.

**Dependency idea:** Depends on the VPC and internet gateway.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `propagating_vgws` | `(known after apply)` | Virtual private gateways automatically propagating routes. Empty means none. |
| `route` | `[` | The route entries in the route table. |
| `route.cidr_block` | `"0.0.0.0/0"` | An IPv4 network range written in CIDR form. |
| `route.gateway_id` | `(known after apply)` | The target internet gateway for a route. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_route_table" "public" {
    + arn              = (known after apply)
    + id               = (known after apply)
    + owner_id         = (known after apply)
    + propagating_vgws = (known after apply)
    + route            = [
        + {
            + cidr_block                 = "0.0.0.0/0"
            + gateway_id                 = (known after apply)
              # (11 unchanged attributes hidden)
          },
      ]
    + tags             = {
        + "Name" = "keycloak-demo-rt-public"
      }
    + tags_all         = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-rt-public"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id           = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-rt-public"   --query "RouteTables[*].[RouteTableId,VpcId,Routes[?DestinationCidrBlock=='0.0.0.0/0'].[DestinationCidrBlock,GatewayId,State],Associations[*].SubnetId]"   --output json
```

### 6.15. `aws_route_table_association.private_a` — Private subnet A route-table association

**Type:** AWS resource or AWS relationship

**What apply will create:** Connects private subnet A to the private route table.

**Dependency idea:** Depends on private subnet A and the private route table.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `(known after apply)` | The route table used by an association. |
| `subnet_id` | `(known after apply)` | The subnet containing the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_route_table_association" "private_a" {
    + id             = (known after apply)
    + route_table_id = (known after apply)
    + subnet_id      = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-rt-private"   --query "RouteTables[*].Associations[*].[RouteTableAssociationId,SubnetId,AssociationState.State]"   --output table
```

### 6.16. `aws_route_table_association.private_b` — Private subnet B route-table association

**Type:** AWS resource or AWS relationship

**What apply will create:** Connects private subnet B to the private route table.

**Dependency idea:** Depends on private subnet B and the private route table.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `(known after apply)` | The route table used by an association. |
| `subnet_id` | `(known after apply)` | The subnet containing the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_route_table_association" "private_b" {
    + id             = (known after apply)
    + route_table_id = (known after apply)
    + subnet_id      = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-rt-private"   --query "RouteTables[*].Associations[*].[RouteTableAssociationId,SubnetId,AssociationState.State]"   --output table
```

### 6.17. `aws_route_table_association.public` — Public subnet route-table association

**Type:** AWS resource or AWS relationship

**What apply will create:** Connects the public subnet to the public route table.

**Dependency idea:** Depends on the public subnet and public route table.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `route_table_id` | `(known after apply)` | The route table used by an association. |
| `subnet_id` | `(known after apply)` | The subnet containing the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_route_table_association" "public" {
    + id             = (known after apply)
    + route_table_id = (known after apply)
    + subnet_id      = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-rt-public"   --query "RouteTables[*].Associations[*].[RouteTableAssociationId,SubnetId,AssociationState.State]"   --output table
```

### 6.18. `aws_secretsmanager_secret.db` — Secrets Manager container for database credentials

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a named Secrets Manager container for the PostgreSQL administrator credentials.

**Dependency idea:** Depends on the random suffix used in its generated name.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak RDS PostgreSQL master credentials"` | Human-readable notes explaining why the resource or rule exists. |
| `force_overwrite_replica_secret` | `false` | Whether a replica secret with the same name may be overwritten. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `(known after apply)` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `policy` | `(known after apply)` | The JSON permissions or resource policy attached to an AWS object. |
| `recovery_window_in_days` | `0` | Days a deleted secret remains recoverable. `0` means force deletion without recovery. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_secretsmanager_secret" "db" {
    + arn                            = (known after apply)
    + description                    = "Keycloak RDS PostgreSQL master credentials"
    + force_overwrite_replica_secret = false
    + id                             = (known after apply)
    + name                           = (known after apply)
    + name_prefix                    = (known after apply)
    + policy                         = (known after apply)
    + recovery_window_in_days        = 0
    + tags                           = {
        + "Name" = "keycloak-demo-db-credentials"
      }
    + tags_all                       = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-db-credentials"
        + "Project"     = "keycloak-demo"
      }

    + replica (known after apply)
  }
```

#### Verify after apply

```bash
aws secretsmanager list-secrets   --region us-east-1   --filters Key=name,Values=keycloak-demo/db-credentials-   --query "SecretList[*].[Name,ARN,LastChangedDate]"   --output table
```

### 6.19. `aws_secretsmanager_secret.keycloak_admin` — Secrets Manager container for Keycloak administrator credentials

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a named Secrets Manager container for the first Keycloak administrator credentials.

**Dependency idea:** Depends on the random suffix used in its generated name.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Keycloak bootstrap admin credentials"` | Human-readable notes explaining why the resource or rule exists. |
| `force_overwrite_replica_secret` | `false` | Whether a replica secret with the same name may be overwritten. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `name` | `(known after apply)` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `policy` | `(known after apply)` | The JSON permissions or resource policy attached to an AWS object. |
| `recovery_window_in_days` | `0` | Days a deleted secret remains recoverable. `0` means force deletion without recovery. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_secretsmanager_secret" "keycloak_admin" {
    + arn                            = (known after apply)
    + description                    = "Keycloak bootstrap admin credentials"
    + force_overwrite_replica_secret = false
    + id                             = (known after apply)
    + name                           = (known after apply)
    + name_prefix                    = (known after apply)
    + policy                         = (known after apply)
    + recovery_window_in_days        = 0
    + tags                           = {
        + "Name" = "keycloak-demo-keycloak-admin"
      }
    + tags_all                       = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-keycloak-admin"
        + "Project"     = "keycloak-demo"
      }

    + replica (known after apply)
  }
```

#### Verify after apply

```bash
aws secretsmanager list-secrets   --region us-east-1   --filters Key=name,Values=keycloak-demo/db-keycloak-admin-   --query "SecretList[*].[Name,ARN,LastChangedDate]"   --output table
```

### 6.20. `aws_secretsmanager_secret_version.db` — Database credential value stored in Secrets Manager

**Type:** AWS resource or AWS relationship

**What apply will create:** Stores the generated database username/password data as the current value of the database secret.

**Dependency idea:** Depends on the database secret container and generated database password.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `has_secret_string_wo` | `(known after apply)` | Reports whether the write-only secret-string feature is in use. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `secret_id` | `(known after apply)` | The parent secret identifier. |
| `secret_string` | `(sensitive value)` | The encrypted text value. Terraform hid it because it is sensitive. |
| `secret_string_wo` | `(write-only attribute)` | A write-only secret value field. |
| `version_id` | `(known after apply)` | The identifier of one stored secret version. |
| `version_stages` | `(known after apply)` | Labels such as `AWSCURRENT` that identify which version applications should use. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_secretsmanager_secret_version" "db" {
    + arn                  = (known after apply)
    + has_secret_string_wo = (known after apply)
    + id                   = (known after apply)
    + secret_id            = (known after apply)
    + secret_string        = (sensitive value)
    + secret_string_wo     = (write-only attribute)
    + version_id           = (known after apply)
    + version_stages       = (known after apply)
  }
```

#### Verify after apply

```bash
DB_SECRET_NAME=$(aws secretsmanager list-secrets   --region us-east-1   --filters Key=name,Values=keycloak-demo/db-credentials-   --query "SecretList[0].Name"   --output text)

aws secretsmanager list-secret-version-ids   --region us-east-1   --secret-id "$DB_SECRET_NAME"   --query "Versions[*].[VersionId,VersionStages,CreatedDate]"   --output table
```

### 6.21. `aws_secretsmanager_secret_version.keycloak_admin` — Keycloak administrator credential value stored in Secrets Manager

**Type:** AWS resource or AWS relationship

**What apply will create:** Stores the generated Keycloak bootstrap administrator credential as the current value of the admin secret.

**Dependency idea:** Depends on the admin secret container and generated admin password.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `has_secret_string_wo` | `(known after apply)` | Reports whether the write-only secret-string feature is in use. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `secret_id` | `(known after apply)` | The parent secret identifier. |
| `secret_string` | `(sensitive value)` | The encrypted text value. Terraform hid it because it is sensitive. |
| `secret_string_wo` | `(write-only attribute)` | A write-only secret value field. |
| `version_id` | `(known after apply)` | The identifier of one stored secret version. |
| `version_stages` | `(known after apply)` | Labels such as `AWSCURRENT` that identify which version applications should use. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_secretsmanager_secret_version" "keycloak_admin" {
    + arn                  = (known after apply)
    + has_secret_string_wo = (known after apply)
    + id                   = (known after apply)
    + secret_id            = (known after apply)
    + secret_string        = (sensitive value)
    + secret_string_wo     = (write-only attribute)
    + version_id           = (known after apply)
    + version_stages       = (known after apply)
  }
```

#### Verify after apply

```bash
ADMIN_SECRET_NAME=$(aws secretsmanager list-secrets   --region us-east-1   --filters Key=name,Values=keycloak-demo/db-keycloak-admin-   --query "SecretList[0].Name"   --output text)

aws secretsmanager list-secret-version-ids   --region us-east-1   --secret-id "$ADMIN_SECRET_NAME"   --query "Versions[*].[VersionId,VersionStages,CreatedDate]"   --output table
```

### 6.22. `aws_security_group.database` — Database security group

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the virtual firewall attached to RDS. Its separate rule permits PostgreSQL only from resources using the Keycloak security group.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Postgres 5432 from the Keycloak SG only"` | Human-readable notes explaining why the resource or rule exists. |
| `egress` | `(known after apply)` | Rules for traffic leaving resources protected by the security group. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ingress` | `(known after apply)` | Rules for traffic entering resources protected by the security group. |
| `name` | `"keycloak-demo-db-sg"` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `revoke_rules_on_delete` | `false` | Whether Terraform should explicitly revoke all rules before deleting the security group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_security_group" "database" {
    + arn                    = (known after apply)
    + description            = "Postgres 5432 from the Keycloak SG only"
    + egress                 = (known after apply)
    + id                     = (known after apply)
    + ingress                = (known after apply)
    + name                   = "keycloak-demo-db-sg"
    + name_prefix            = (known after apply)
    + owner_id               = (known after apply)
    + revoke_rules_on_delete = false
    + tags                   = {
        + "Name" = "keycloak-demo-db-sg"
      }
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-db-sg"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id                 = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-db-sg"   --query "SecurityGroups[*].[GroupId,GroupName,VpcId,Description]"   --output table
```

### 6.23. `aws_security_group.keycloak` — Keycloak EC2 security group

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the virtual firewall attached to the Keycloak server. Separate rules allow SSH, HTTP, and HTTPS from one exact IPv4 address.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Allow admin console and SSH from one IP only"` | Human-readable notes explaining why the resource or rule exists. |
| `egress` | `(known after apply)` | Rules for traffic leaving resources protected by the security group. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ingress` | `(known after apply)` | Rules for traffic entering resources protected by the security group. |
| `name` | `"keycloak-demo-keycloak-sg"` | The friendly AWS name of the object. |
| `name_prefix` | `(known after apply)` | An optional beginning for a name that Terraform or AWS can finish with a unique suffix. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `revoke_rules_on_delete` | `false` | Whether Terraform should explicitly revoke all rules before deleting the security group. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_security_group" "keycloak" {
    + arn                    = (known after apply)
    + description            = "Allow admin console and SSH from one IP only"
    + egress                 = (known after apply)
    + id                     = (known after apply)
    + ingress                = (known after apply)
    + name                   = "keycloak-demo-keycloak-sg"
    + name_prefix            = (known after apply)
    + owner_id               = (known after apply)
    + revoke_rules_on_delete = false
    + tags                   = {
        + "Name" = "keycloak-demo-keycloak-sg"
      }
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-keycloak-sg"
        + "Project"     = "keycloak-demo"
      }
    + vpc_id                 = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-keycloak-sg"   --query "SecurityGroups[*].[GroupId,GroupName,VpcId,Description]"   --output table
```

### 6.24. `aws_subnet.private_a` — Private subnet A

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the private `10.42.11.0/24` subnet in `us-east-1a`. New resources do not receive public IPv4 addresses automatically.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1a"` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `(known after apply)` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.11.0/24"` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_resource_name_dns_a_record_on_launch` | `false` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ipv6_cidr_block_association_id` | `(known after apply)` | The ID of an IPv6 range attached to the subnet. This IPv4-only design should not need one. |
| `ipv6_native` | `false` | Whether the subnet was IPv6-only. |
| `map_public_ip_on_launch` | `false` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `(known after apply)` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_subnet" "private_a" {
    + arn                                            = (known after apply)
    + assign_ipv6_address_on_creation                = false
    + availability_zone                              = "us-east-1a"
    + availability_zone_id                           = (known after apply)
    + cidr_block                                     = "10.42.11.0/24"
    + enable_dns64                                   = false
    + enable_resource_name_dns_a_record_on_launch    = false
    + enable_resource_name_dns_aaaa_record_on_launch = false
    + id                                             = (known after apply)
    + ipv6_cidr_block_association_id                 = (known after apply)
    + ipv6_native                                    = false
    + map_public_ip_on_launch                        = false
    + owner_id                                       = (known after apply)
    + private_dns_hostname_type_on_launch            = (known after apply)
    + tags                                           = {
        + "Name" = "keycloak-demo-private-a"
        + "Tier" = "private"
      }
    + tags_all                                       = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-private-a"
        + "Project"     = "keycloak-demo"
        + "Tier"        = "private"
      }
    + vpc_id                                         = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-subnets   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-private-a"   --query "Subnets[*].[SubnetId,VpcId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,AvailableIpAddressCount]"   --output table
```

### 6.25. `aws_subnet.private_b` — Private subnet B

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the private `10.42.12.0/24` subnet in `us-east-1b`. It gives RDS a second Availability Zone to choose from.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1b"` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `(known after apply)` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.12.0/24"` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_resource_name_dns_a_record_on_launch` | `false` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ipv6_cidr_block_association_id` | `(known after apply)` | The ID of an IPv6 range attached to the subnet. This IPv4-only design should not need one. |
| `ipv6_native` | `false` | Whether the subnet was IPv6-only. |
| `map_public_ip_on_launch` | `false` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `(known after apply)` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_subnet" "private_b" {
    + arn                                            = (known after apply)
    + assign_ipv6_address_on_creation                = false
    + availability_zone                              = "us-east-1b"
    + availability_zone_id                           = (known after apply)
    + cidr_block                                     = "10.42.12.0/24"
    + enable_dns64                                   = false
    + enable_resource_name_dns_a_record_on_launch    = false
    + enable_resource_name_dns_aaaa_record_on_launch = false
    + id                                             = (known after apply)
    + ipv6_cidr_block_association_id                 = (known after apply)
    + ipv6_native                                    = false
    + map_public_ip_on_launch                        = false
    + owner_id                                       = (known after apply)
    + private_dns_hostname_type_on_launch            = (known after apply)
    + tags                                           = {
        + "Name" = "keycloak-demo-private-b"
        + "Tier" = "private"
      }
    + tags_all                                       = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-private-b"
        + "Project"     = "keycloak-demo"
        + "Tier"        = "private"
      }
    + vpc_id                                         = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-subnets   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-private-b"   --query "Subnets[*].[SubnetId,VpcId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,AvailableIpAddressCount]"   --output table
```

### 6.26. `aws_subnet.public` — Public subnet

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the public `10.42.1.0/24` subnet in `us-east-1a`. New network interfaces may receive public IPv4 addresses.

**Dependency idea:** Depends on the VPC.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `assign_ipv6_address_on_creation` | `false` | Whether new network interfaces automatically receive IPv6 addresses. |
| `availability_zone` | `"us-east-1a"` | The AWS data-center zone holding the resource, such as `us-east-1b`. |
| `availability_zone_id` | `(known after apply)` | The account-independent identifier for the Availability Zone. |
| `cidr_block` | `"10.42.1.0/24"` | An IPv4 network range written in CIDR form. |
| `enable_dns64` | `false` | Whether DNS64 translation support was enabled for IPv6-only workloads. |
| `enable_resource_name_dns_a_record_on_launch` | `false` | Whether launched resources get private IPv4 resource-name DNS records. |
| `enable_resource_name_dns_aaaa_record_on_launch` | `false` | Whether launched resources get private IPv6 resource-name DNS records. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ipv6_cidr_block_association_id` | `(known after apply)` | The ID of an IPv6 range attached to the subnet. This IPv4-only design should not need one. |
| `ipv6_native` | `false` | Whether the subnet was IPv6-only. |
| `map_public_ip_on_launch` | `true` | Whether new network interfaces in the subnet automatically receive public IPv4 addresses. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `private_dns_hostname_type_on_launch` | `(known after apply)` | The private DNS hostname style used for new resources. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `vpc_id` | `(known after apply)` | The VPC that contained the resource. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_subnet" "public" {
    + arn                                            = (known after apply)
    + assign_ipv6_address_on_creation                = false
    + availability_zone                              = "us-east-1a"
    + availability_zone_id                           = (known after apply)
    + cidr_block                                     = "10.42.1.0/24"
    + enable_dns64                                   = false
    + enable_resource_name_dns_a_record_on_launch    = false
    + enable_resource_name_dns_aaaa_record_on_launch = false
    + id                                             = (known after apply)
    + ipv6_cidr_block_association_id                 = (known after apply)
    + ipv6_native                                    = false
    + map_public_ip_on_launch                        = true
    + owner_id                                       = (known after apply)
    + private_dns_hostname_type_on_launch            = (known after apply)
    + tags                                           = {
        + "Name" = "keycloak-demo-public-a"
        + "Tier" = "public"
      }
    + tags_all                                       = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-public-a"
        + "Project"     = "keycloak-demo"
        + "Tier"        = "public"
      }
    + vpc_id                                         = (known after apply)
  }
```

#### Verify after apply

```bash
aws ec2 describe-subnets   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-public-a"   --query "Subnets[*].[SubnetId,VpcId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,AvailableIpAddressCount]"   --output table
```

### 6.27. `aws_vpc.main` — Virtual Private Cloud

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates the isolated AWS network `10.42.0.0/16` with DNS support and DNS hostnames enabled.

**Dependency idea:** This is a foundation resource. Many networking objects depend on it.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_block` | `"10.42.0.0/16"` | An IPv4 network range written in CIDR form. |
| `default_network_acl_id` | `(known after apply)` | The default stateless subnet firewall automatically created with the VPC. |
| `default_route_table_id` | `(known after apply)` | The default route table automatically created with the VPC. |
| `default_security_group_id` | `(known after apply)` | The default security group automatically created with the VPC. |
| `dhcp_options_id` | `(known after apply)` | The DHCP settings used by the VPC for DNS and network configuration. |
| `enable_dns_hostnames` | `true` | Whether instances with public IPs can receive public DNS hostnames. |
| `enable_dns_support` | `true` | Whether AWS-provided DNS resolution works inside the VPC. |
| `enable_network_address_usage_metrics` | `(known after apply)` | Whether VPC IP-address usage metrics were enabled. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `instance_tenancy` | `"default"` | Default hardware tenancy for instances launched in the VPC. |
| `ipv6_association_id` | `(known after apply)` | The ID of an IPv6 range association on the VPC. |
| `ipv6_cidr_block` | `(known after apply)` | The IPv6 address range assigned to the VPC, if IPv6 is enabled. |
| `ipv6_cidr_block_network_border_group` | `(known after apply)` | The AWS network border group in which an IPv6 range is advertised. |
| `main_route_table_id` | `(known after apply)` | The VPC’s main fallback route table. |
| `owner_id` | `(known after apply)` | The AWS account number that owned the resource. |
| `tags` | `{` | Labels written directly on this resource. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc" "main" {
    + arn                                  = (known after apply)
    + cidr_block                           = "10.42.0.0/16"
    + default_network_acl_id               = (known after apply)
    + default_route_table_id               = (known after apply)
    + default_security_group_id            = (known after apply)
    + dhcp_options_id                      = (known after apply)
    + enable_dns_hostnames                 = true
    + enable_dns_support                   = true
    + enable_network_address_usage_metrics = (known after apply)
    + id                                   = (known after apply)
    + instance_tenancy                     = "default"
    + ipv6_association_id                  = (known after apply)
    + ipv6_cidr_block                      = (known after apply)
    + ipv6_cidr_block_network_border_group = (known after apply)
    + main_route_table_id                  = (known after apply)
    + owner_id                             = (known after apply)
    + tags                                 = {
        + "Name" = "keycloak-demo-vpc"
      }
    + tags_all                             = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Name"        = "keycloak-demo-vpc"
        + "Project"     = "keycloak-demo"
      }
  }
```

#### Verify after apply

```bash
aws ec2 describe-vpcs   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-vpc"   --query "Vpcs[*].[VpcId,State,CidrBlock,IsDefault,InstanceTenancy]"   --output table
```

### 6.28. `aws_vpc_security_group_egress_rule.db_none` — Database outbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Creates a database outbound rule pointing only to `127.0.0.1/32`. This is effectively a way to avoid useful outbound network access from RDS.

**Dependency idea:** Depends on the database security group.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"127.0.0.1/32"` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"No meaningful egress needed"` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"-1"` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_egress_rule" "db_none" {
    + arn                    = (known after apply)
    + cidr_ipv4              = "127.0.0.1/32"
    + description            = "No meaningful egress needed"
    + id                     = (known after apply)
    + ip_protocol            = "-1"
    + security_group_id      = (known after apply)
    + security_group_rule_id = (known after apply)
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
  }
```

#### Verify after apply

```bash
DB_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-db-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$DB_SG_ID"   --query "SecurityGroupRules[?IsEgress==`true`].[SecurityGroupRuleId,IpProtocol,CidrIpv4,Description]"   --output table
```

### 6.29. `aws_vpc_security_group_egress_rule.keycloak_all_out` — Keycloak outbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Allows the Keycloak EC2 server to start outbound connections to any IPv4 address using any protocol.

**Dependency idea:** Depends on the Keycloak security group.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"0.0.0.0/0"` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Allow all outbound"` | Human-readable notes explaining why the resource or rule exists. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"-1"` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_egress_rule" "keycloak_all_out" {
    + arn                    = (known after apply)
    + cidr_ipv4              = "0.0.0.0/0"
    + description            = "Allow all outbound"
    + id                     = (known after apply)
    + ip_protocol            = "-1"
    + security_group_id      = (known after apply)
    + security_group_rule_id = (known after apply)
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
  }
```

#### Verify after apply

```bash
KC_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-keycloak-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$KC_SG_ID"   --query "SecurityGroupRules[?IsEgress==`true`].[SecurityGroupRuleId,IpProtocol,CidrIpv4,Description]"   --output table
```

### 6.30. `aws_vpc_security_group_ingress_rule.db_from_keycloak` — PostgreSQL inbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Allows TCP port 5432 into RDS only when the source network interface uses the Keycloak security group.

**Dependency idea:** Depends on both security groups.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `description` | `"Postgres from Keycloak instances only"` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `5432` | The first port in the allowed range. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp"` | The protocol field on a separate VPC security-group rule. |
| `referenced_security_group_id` | `(known after apply)` | The source security group trusted by an inbound rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `5432` | The last port in the allowed range. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
    + arn                          = (known after apply)
    + description                  = "Postgres from Keycloak instances only"
    + from_port                    = 5432
    + id                           = (known after apply)
    + ip_protocol                  = "tcp"
    + referenced_security_group_id = (known after apply)
    + security_group_id            = (known after apply)
    + security_group_rule_id       = (known after apply)
    + tags_all                     = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + to_port                      = 5432
  }
```

#### Verify after apply

```bash
DB_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-db-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$DB_SG_ID"   --query "SecurityGroupRules[?IsEgress==`false` && FromPort==`5432`].[SecurityGroupRuleId,IpProtocol,FromPort,ToPort,ReferencedGroupInfo.GroupId,Description]"   --output table
```

### 6.31. `aws_vpc_security_group_ingress_rule.keycloak_http` — Keycloak HTTP inbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Allows troubleshooting HTTP traffic on TCP port 8080 from exactly `68.32.112.68/32`.

**Dependency idea:** Depends on the Keycloak security group.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32"` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Keycloak HTTP from my IP (troubleshooting)"` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `8080` | The first port in the allowed range. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp"` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `8080` | The last port in the allowed range. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_ingress_rule" "keycloak_http" {
    + arn                    = (known after apply)
    + cidr_ipv4              = "68.32.112.68/32"
    + description            = "Keycloak HTTP from my IP (troubleshooting)"
    + from_port              = 8080
    + id                     = (known after apply)
    + ip_protocol            = "tcp"
    + security_group_id      = (known after apply)
    + security_group_rule_id = (known after apply)
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + to_port                = 8080
  }
```

#### Verify after apply

```bash
KC_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-keycloak-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$KC_SG_ID"   --query "SecurityGroupRules[?IsEgress==`false` && FromPort==`8080`].[SecurityGroupRuleId,CidrIpv4,FromPort,ToPort,Description]"   --output table
```

### 6.32. `aws_vpc_security_group_ingress_rule.keycloak_https` — Keycloak HTTPS inbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Allows Keycloak HTTPS traffic on TCP port 8443 from exactly `68.32.112.68/32`.

**Dependency idea:** Depends on the Keycloak security group.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32"` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"Keycloak HTTPS from my IP"` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `8443` | The first port in the allowed range. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp"` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `8443` | The last port in the allowed range. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_ingress_rule" "keycloak_https" {
    + arn                    = (known after apply)
    + cidr_ipv4              = "68.32.112.68/32"
    + description            = "Keycloak HTTPS from my IP"
    + from_port              = 8443
    + id                     = (known after apply)
    + ip_protocol            = "tcp"
    + security_group_id      = (known after apply)
    + security_group_rule_id = (known after apply)
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + to_port                = 8443
  }
```

#### Verify after apply

```bash
KC_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-keycloak-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$KC_SG_ID"   --query "SecurityGroupRules[?IsEgress==`false` && FromPort==`8443`].[SecurityGroupRuleId,CidrIpv4,FromPort,ToPort,Description]"   --output table
```

### 6.33. `aws_vpc_security_group_ingress_rule.keycloak_ssh` — SSH inbound firewall rule

**Type:** AWS resource or AWS relationship

**What apply will create:** Allows SSH on TCP port 22 from exactly `68.32.112.68/32`.

**Dependency idea:** Depends on the Keycloak security group.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `arn` | `(known after apply)` | Amazon Resource Name. This is the full, globally unique AWS label for the resource. |
| `cidr_ipv4` | `"68.32.112.68/32"` | One IPv4 CIDR source or destination for a separate security-group rule resource. |
| `description` | `"SSH from my IP only"` | Human-readable notes explaining why the resource or rule exists. |
| `from_port` | `22` | The first port in the allowed range. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `ip_protocol` | `"tcp"` | The protocol field on a separate VPC security-group rule. |
| `security_group_id` | `(known after apply)` | The security group that owns the rule. |
| `security_group_rule_id` | `(known after apply)` | The unique AWS ID for the individual rule. |
| `tags_all` | `{` | All labels after combining the resource’s own tags with provider-level default tags. |
| `to_port` | `22` | The last port in the allowed range. |

#### Exact create-plan excerpt

```hcl
+ resource "aws_vpc_security_group_ingress_rule" "keycloak_ssh" {
    + arn                    = (known after apply)
    + cidr_ipv4              = "68.32.112.68/32"
    + description            = "SSH from my IP only"
    + from_port              = 22
    + id                     = (known after apply)
    + ip_protocol            = "tcp"
    + security_group_id      = (known after apply)
    + security_group_rule_id = (known after apply)
    + tags_all               = {
        + "Environment" = "dev"
        + "ManagedBy"   = "terraform"
        + "Project"     = "keycloak-demo"
      }
    + to_port                = 22
  }
```

#### Verify after apply

```bash
KC_SG_ID=$(aws ec2 describe-security-groups   --region us-east-1   --filters "Name=group-name,Values=keycloak-demo-keycloak-sg"   --query "SecurityGroups[0].GroupId"   --output text)

aws ec2 describe-security-group-rules   --region us-east-1   --filters "Name=group-id,Values=$KC_SG_ID"   --query "SecurityGroupRules[?IsEgress==`false` && FromPort==`22`].[SecurityGroupRuleId,CidrIpv4,FromPort,ToPort,Description]"   --output table
```

### 6.34. `random_id.suffix` — Terraform random suffix

**Type:** Terraform Random provider object

**What apply will create:** Creates a three-byte random value inside Terraform. The hexadecimal form is used to make IAM and secret names less likely to collide.

**Dependency idea:** This is local Terraform provider data and can be made early.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `b64_std` | `(known after apply)` | The random bytes shown using standard Base64 text. |
| `b64_url` | `(known after apply)` | The random bytes shown using URL-safe Base64 text. |
| `byte_length` | `3` | How many random bytes were generated. |
| `dec` | `(known after apply)` | The same random value displayed as a decimal number. |
| `hex` | `(known after apply)` | The same random value displayed as hexadecimal text. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |

#### Exact create-plan excerpt

```hcl
+ resource "random_id" "suffix" {
    + b64_std     = (known after apply)
    + b64_url     = (known after apply)
    + byte_length = 3
    + dec         = (known after apply)
    + hex         = (known after apply)
    + id          = (known after apply)
  }
```

#### Verify after apply

```bash
terraform state list | grep '^random_id.suffix$'
terraform state show random_id.suffix
```

### 6.35. `random_password.db` — Terraform-generated database password

**Type:** Terraform Random provider object

**What apply will create:** Generates a 32-character database password with uppercase, lowercase, numbers, and special characters.

**Dependency idea:** This is local Terraform provider data and can be made early.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `bcrypt_hash` | `(sensitive value)` | A one-way bcrypt hash of the generated password. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `length` | `32` | The number of characters in the generated password. |
| `lower` | `true` | Whether lowercase letters were allowed. |
| `min_lower` | `2` | Minimum number of lowercase letters. |
| `min_numeric` | `2` | Minimum number of digits. |
| `min_special` | `2` | Minimum number of special characters. |
| `min_upper` | `2` | Minimum number of uppercase letters. |
| `number` | `true` | Older compatibility setting saying numbers are allowed. |
| `numeric` | `true` | Whether digits were allowed. |
| `override_special` | `"!#$%&*()-_=+[]{}<>:?"` | The exact special characters Terraform was allowed to use. |
| `result` | `(sensitive value)` | The generated password. Terraform hid it because it is sensitive. |
| `special` | `true` | Whether special characters were allowed. |
| `upper` | `true` | Whether uppercase letters were allowed. |

#### Exact create-plan excerpt

```hcl
+ resource "random_password" "db" {
    + bcrypt_hash      = (sensitive value)
    + id               = (known after apply)
    + length           = 32
    + lower            = true
    + min_lower        = 2
    + min_numeric      = 2
    + min_special      = 2
    + min_upper        = 2
    + number           = true
    + numeric          = true
    + override_special = "!#$%&*()-_=+[]{}<>:?"
    + result           = (sensitive value)
    + special          = true
    + upper            = true
  }
```

#### Verify after apply

```bash
terraform state list | grep '^random_password.db$'
terraform state show random_password.db

# Terraform will still hide the actual result because it is sensitive.
```

### 6.36. `random_password.keycloak_admin` — Terraform-generated Keycloak administrator password

**Type:** Terraform Random provider object

**What apply will create:** Generates a 24-character Keycloak administrator password with uppercase, lowercase, numbers, and selected special characters.

**Dependency idea:** This is local Terraform provider data and can be made early.

#### Named lines in this block

| Setting path | Value shown in the plan | Middle-school explanation |
|---|---|---|
| `bcrypt_hash` | `(sensitive value)` | A one-way bcrypt hash of the generated password. |
| `id` | `(known after apply)` | The main identifier Terraform used to track this real object. |
| `length` | `24` | The number of characters in the generated password. |
| `lower` | `true` | Whether lowercase letters were allowed. |
| `min_lower` | `2` | Minimum number of lowercase letters. |
| `min_numeric` | `2` | Minimum number of digits. |
| `min_special` | `2` | Minimum number of special characters. |
| `min_upper` | `2` | Minimum number of uppercase letters. |
| `number` | `true` | Older compatibility setting saying numbers are allowed. |
| `numeric` | `true` | Whether digits were allowed. |
| `override_special` | `"!#$%&*-_=+"` | The exact special characters Terraform was allowed to use. |
| `result` | `(sensitive value)` | The generated password. Terraform hid it because it is sensitive. |
| `special` | `true` | Whether special characters were allowed. |
| `upper` | `true` | Whether uppercase letters were allowed. |

#### Exact create-plan excerpt

```hcl
+ resource "random_password" "keycloak_admin" {
    + bcrypt_hash      = (sensitive value)
    + id               = (known after apply)
    + length           = 24
    + lower            = true
    + min_lower        = 2
    + min_numeric      = 2
    + min_special      = 2
    + min_upper        = 2
    + number           = true
    + numeric          = true
    + override_special = "!#$%&*-_=+"
    + result           = (sensitive value)
    + special          = true
    + upper            = true
  }
```

#### Verify after apply

```bash
terraform state list | grep '^random_password.keycloak_admin$'
terraform state show random_password.keycloak_admin

# Terraform will still hide the actual result because it is sensitive.
```

## 7. Important RDS Creation Settings

The RDS database is the most important data resource in the plan.

| Setting | Planned value | Meaning |
|---|---:|---|
| Engine | PostgreSQL `18.3` | AWS runs PostgreSQL for Keycloak. |
| Instance class | `db.t4g.micro` | A small ARM-based burstable database computer. |
| Initial storage | `20` GiB | The starting database disk size. |
| Maximum storage | `100` GiB | RDS storage autoscaling may grow the disk up to this limit. |
| Storage type | `gp3` | General-purpose SSD storage. |
| Encryption | `true` | Database storage is encrypted. |
| Public access | `false` | The database does not receive a public endpoint. |
| Multi-AZ | `false` | There is no standby database in a second zone. |
| Automated backup retention | `7` days | RDS keeps point-in-time backup data for one week while the DB exists. |
| Performance Insights | `true` | AWS collects database performance information. |
| Enhanced Monitoring | `0` seconds | Enhanced operating-system monitoring is disabled. |
| CloudWatch exports | `postgresql`, `upgrade` | PostgreSQL and upgrade logs go to CloudWatch Logs. |

### Database safety settings to understand before apply

```hcl
deletion_protection     = false
skip_final_snapshot     = true
delete_automated_backups = true
```

These values do not delete anything during creation. They control what can happen during a future destroy:

- `deletion_protection = false` means AWS will not block deletion.
- `skip_final_snapshot = true` means a future Terraform destroy can delete RDS without making a final snapshot.
- `delete_automated_backups = true` means automated backups are also marked for deletion with the DB.

For a learning environment, these settings make cleanup easier. For production, they are risky.

## 8. Important EC2 Creation Settings

| Setting | Planned value | Meaning |
|---|---|---|
| AMI | Latest Amazon Linux 2023 ARM64 parameter | The operating-system image is selected from an AWS public SSM parameter. |
| Instance type | `t4g.small` | An ARM-based Graviton burstable server. |
| Root disk | `20` GiB gp3 | The main operating-system disk. |
| Root disk encryption | `true` | Files on the root disk are encrypted at rest. |
| Delete disk on termination | `true` | Terminating EC2 also removes this root disk. |
| Detailed monitoring | `false` | Standard CloudWatch EC2 metrics are used. |
| IMDS endpoint | enabled | Software on the server may access instance metadata. |
| IMDS tokens | required | IMDSv2 is required, which is safer than allowing IMDSv1. |
| Metadata hop limit | `1` | Metadata requests are limited to the local instance network hop. |
| Replace on user-data change | `true` | Changing the startup script may replace the EC2 instance. |

### ARM64 reminder

`t4g.small` uses the ARM64 CPU architecture. The following items must support ARM64:

- selected Amazon Linux AMI
- Keycloak container or Java runtime
- native libraries
- monitoring agents
- command-line tools installed by startup scripts

The plan correctly looks up an Amazon Linux 2023 ARM64 AMI.

## 9. IAM Permission Flow

```text
EC2 service
   |
   | allowed by trust policy
   v
Keycloak IAM role
   |
   +-- AmazonSSMManagedInstanceCore
   |     lets the instance register with Systems Manager
   |
   +-- custom read-db-secret policy
         allows:
         - secretsmanager:GetSecretValue
         - secretsmanager:DescribeSecret
         only for:
         keycloak-demo/db-*
   |
   v
IAM instance profile
   |
   v
Keycloak EC2 instance
```

### Why the instance profile is needed

EC2 cannot directly wear an IAM role. AWS uses an instance profile as the holder that attaches the role to the server.

## 10. Security-Group Traffic Flow

### Allowed inbound traffic to Keycloak

| Port | Protocol | Source | Purpose |
|---:|---|---|---|
| 22 | TCP | `68.32.112.68/32` | SSH administration |
| 8080 | TCP | `68.32.112.68/32` | Temporary HTTP troubleshooting |
| 8443 | TCP | `68.32.112.68/32` | Keycloak HTTPS |

### Allowed database traffic

| Port | Protocol | Source | Purpose |
|---:|---|---|---|
| 5432 | TCP | Keycloak security group | PostgreSQL connection from the Keycloak server |

Using a security-group reference for the database is better than allowing an entire subnet or public IP range. It says, “allow network interfaces wearing this exact AWS firewall badge.”

### Outbound traffic

- Keycloak may start outbound connections to `0.0.0.0/0` using any protocol.
- The database is given only a loopback-style `127.0.0.1/32` egress destination, which provides no useful external route.

## 11. Secrets and Terraform State

The plan creates two random passwords and writes them into Secrets Manager.

```text
random_password.db
        |
        v
aws_secretsmanager_secret_version.db

random_password.keycloak_admin
        |
        v
aws_secretsmanager_secret_version.keycloak_admin
```

Terraform hides the password in normal plan output, but the secret values can still be present in the Terraform state file.

### Protect the state file

For a local state design:

- Do not email the state file.
- Do not commit it to Git.
- Add `*.tfstate`, `*.tfstate.*`, and `.terraform/` to `.gitignore`.
- Restrict local file permissions.
- Store backups securely.
- Do not paste `terraform show -json` output into public tickets because sensitive values can appear.

## 12. Expected Creation Order

Terraform may create independent resources at the same time, but the dependency flow is approximately:

1. Read current Region, account, Availability Zones, and latest AMI.
2. Build IAM policy documents.
3. Generate the random suffix and passwords.
4. Create the VPC.
5. Create public and private subnets.
6. Create security groups.
7. Create the internet gateway.
8. Create route tables and route-table associations.
9. Create IAM role, policies, attachments, and instance profile.
10. Create Secrets Manager containers and secret values.
11. Create the RDS parameter group and DB subnet group.
12. Create the EC2 server and RDS database when their dependencies are ready.
13. Allocate and associate the Elastic IP.
14. Finish computed outputs and update Terraform state.

Terraform's real order comes from references in the code, not simply the order of blocks in the `.tf` files.

## 13. Safe Commands to Run the Plan

### Format and validate first

```bash
terraform fmt -recursive
terraform init
terraform validate
```

### Create a saved plan

```bash
terraform plan -out=tfplan
```

A saved plan is safer because the file reviewed is the same plan applied.

### Read the saved plan

```bash
terraform show tfplan
```

### Apply the exact saved plan

```bash
terraform apply tfplan
```

When a saved plan file is supplied, Terraform normally does not ask for a second approval because the plan was already created for application.

### Check Terraform state afterward

```bash
terraform state list
```

Expected count:

```bash
terraform state list | wc -l
```

On PowerShell:

```powershell
(terraform state list | Measure-Object -Line).Lines
```

The count may include data sources depending on Terraform/provider behavior and what is retained in state, so verify the named resources rather than trusting only a number.

## 14. Master AWS CLI Verification Checklist

### 14.1 Confirm the AWS account and Region

```bash
aws sts get-caller-identity
aws configure get region
aws ec2 describe-availability-zones   --region us-east-1   --query "AvailabilityZones[?State=='available'].[ZoneName,ZoneId,State]"   --output table
```

Make sure the account is the intended account before applying.

### 14.2 Verify all tagged AWS resources

```bash
aws resourcegroupstaggingapi get-resources   --region us-east-1   --tag-filters Key=Project,Values=keycloak-demo   --query "ResourceTagMappingList[*].[ResourceARN,Tags]"   --output json
```

Some relationship objects and IAM objects may not appear in the Resource Groups Tagging API. Use the service-specific checks too.

### 14.3 Verify the VPC and subnets

```bash
aws ec2 describe-vpcs   --region us-east-1   --filters "Name=tag:Project,Values=keycloak-demo"   --query "Vpcs[*].[VpcId,State,CidrBlock]"   --output table

aws ec2 describe-subnets   --region us-east-1   --filters "Name=tag:Project,Values=keycloak-demo"   --query "Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key=='Name']|[0].Value]"   --output table
```

### 14.4 Verify routes

```bash
aws ec2 describe-route-tables   --region us-east-1   --filters "Name=tag:Project,Values=keycloak-demo"   --query "RouteTables[*].[RouteTableId,Tags[?Key=='Name']|[0].Value,Routes,Associations[*].SubnetId]"   --output json
```

The public route table should have a route similar to:

```text
0.0.0.0/0 -> igw-...
```

The private route table should not have a public internet default route.

### 14.5 Verify EC2 and Elastic IP

```bash
INSTANCE_ID=$(aws ec2 describe-instances   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak"             "Name=instance-state-name,Values=pending,running,stopping,stopped"   --query "Reservations[0].Instances[0].InstanceId"   --output text)

aws ec2 describe-instance-status   --region us-east-1   --instance-ids "$INSTANCE_ID"   --include-all-instances   --output table

aws ec2 describe-addresses   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak-eip"   --output table
```

### 14.6 Verify SSM registration

```bash
aws ssm describe-instance-information   --region us-east-1   --filters "Key=InstanceIds,Values=$INSTANCE_ID"   --query "InstanceInformationList[*].[InstanceId,PingStatus,PlatformName,PlatformVersion,AgentVersion]"   --output table
```

A healthy result should show `Online`.

Start a session:

```bash
aws ssm start-session   --region us-east-1   --target "$INSTANCE_ID"
```

### 14.7 Verify RDS

```bash
aws rds describe-db-instances   --region us-east-1   --db-instance-identifier keycloak-demo-db   --query "DBInstances[0].[DBInstanceStatus,Endpoint.Address,Endpoint.Port,DBSubnetGroup.VpcId,PubliclyAccessible,StorageEncrypted,PerformanceInsightsEnabled]"   --output table
```

A ready database should show `available`.

### 14.8 Verify CloudWatch RDS log exports

```bash
aws logs describe-log-groups   --region us-east-1   --log-group-name-prefix /aws/rds/instance/keycloak-demo-db   --query "logGroups[*].[logGroupName,storedBytes,retentionInDays]"   --output table
```

Log groups may not appear until the database produces the matching type of log event.

### 14.9 Verify Secrets Manager without printing passwords

```bash
aws secretsmanager list-secrets   --region us-east-1   --filters Key=tag-key,Values=Project Key=tag-value,Values=keycloak-demo   --query "SecretList[*].[Name,ARN,LastChangedDate]"   --output table
```

Avoid printing `SecretString` in a shared terminal or log.

### 14.10 Verify the IAM role and attachments

```bash
ROLE_NAME=$(aws iam list-roles   --query "Roles[?starts_with(RoleName, 'keycloak-demo-keycloak-role-')].RoleName | [0]"   --output text)

aws iam get-role   --role-name "$ROLE_NAME"

aws iam list-attached-role-policies   --role-name "$ROLE_NAME"   --output table
```

## 15. Functional Tests

Infrastructure existing does not prove Keycloak is healthy. Test the application too.

### 15.1 Get the public IP

```bash
PUBLIC_IP=$(aws ec2 describe-addresses   --region us-east-1   --filters "Name=tag:Name,Values=keycloak-demo-keycloak-eip"   --query "Addresses[0].PublicIp"   --output text)

echo "$PUBLIC_IP"
```

### 15.2 Test HTTPS

```bash
curl -k -I "https://${PUBLIC_IP}:8443/"
```

`-k` skips certificate verification. Use it only for a learning setup with a self-signed certificate. A production service should use a trusted certificate and DNS name.

### 15.3 Test temporary HTTP troubleshooting port

```bash
curl -I "http://${PUBLIC_IP}:8080/"
```

This request will work only from the allowed source IP and only if Keycloak is listening on port 8080.

### 15.4 Check Keycloak from SSM

After starting an SSM session:

```bash
sudo systemctl status keycloak --no-pager
sudo journalctl -u keycloak --since "30 minutes ago" --no-pager
sudo ss -lntp
curl -k -I https://localhost:8443/
```

The exact service name may differ if Keycloak runs in Docker or another process manager.

### 15.5 Test database name resolution and port from the EC2 server

Inside the EC2 session:

```bash
DB_ENDPOINT=$(aws rds describe-db-instances   --region us-east-1   --db-instance-identifier keycloak-demo-db   --query "DBInstances[0].Endpoint.Address"   --output text)

getent hosts "$DB_ENDPOINT"
timeout 5 bash -c "cat < /dev/null > /dev/tcp/${DB_ENDPOINT}/5432"   && echo "PostgreSQL port is reachable"   || echo "PostgreSQL port is not reachable"
```

This tests DNS and the TCP path. It does not log in to PostgreSQL.

## 16. Security Review

### Good security choices in the plan

- RDS is not publicly accessible.
- RDS storage is encrypted.
- EC2 root storage is encrypted.
- EC2 requires IMDSv2.
- Database ingress uses a security-group reference.
- SSH and Keycloak ports are limited to one `/32` address.
- Database and administrator passwords are randomly generated.
- Secrets are stored in Secrets Manager.
- The EC2 role has a narrow custom secret-reading policy.
- SSM access is available.

### Choices to review before production

1. **RDS is Single-AZ.** A production identity service usually needs stronger database availability.
2. **RDS deletion protection is off.**
3. **A final RDS snapshot is skipped during destroy.**
4. **Secrets use a zero-day recovery window.** A future destroy can permanently delete them immediately.
5. **HTTP port 8080 is open for troubleshooting.** Remove it when HTTPS is working.
6. **SSH port 22 is open.** SSM may allow you to remove SSH entirely.
7. **Keycloak has unrestricted IPv4 outbound traffic.**
8. **The EC2 server is directly public.** A production design normally uses an Application Load Balancer, DNS, and ACM certificate.
9. **Terraform local state contains sensitive values.**
10. **No NAT gateway or VPC endpoints are shown for private subnets.** This is acceptable for RDS, but private workloads needing AWS APIs would need another path.
11. **The source IP is hard-coded.** If the administrator's public IP changes, access will stop until Terraform updates the rule.
12. **Account number and source IP appear in the plan.** Do not publish the raw plan publicly.

## 17. Cost-Producing Resources

The following planned objects can create direct or indirect AWS charges:

- EC2 `t4g.small`
- EC2 gp3 root volume
- Elastic IPv4 address
- RDS `db.t4g.micro`
- RDS gp3 storage
- RDS backup storage beyond free allocation
- RDS Performance Insights depending on retention/mode and current pricing
- CloudWatch Logs ingestion and storage
- Secrets Manager secrets
- KMS API use if customer-managed keys are used
- Data transfer

The VPC, subnets, route tables, security groups, internet gateway attachment, IAM role, and IAM policy normally do not have a simple hourly resource charge by themselves, but traffic and connected services may cost money.

### Check Cost Explorer by tag

Cost allocation tags must be activated before they appear fully in billing reports.

```bash
aws ce get-cost-and-usage   --time-period Start=2026-07-01,End=2026-08-01   --granularity DAILY   --metrics UnblendedCost   --filter '{"Tags":{"Key":"Project","Values":["keycloak-demo"]}}'
```

Adjust the dates to the desired billing window.

## 18. Troubleshooting Common Apply Problems

### Error: AMI and instance type architecture do not match

Cause: `t4g.small` requires ARM64.

Check the AMI:

```bash
AMI_ID=$(aws ssm get-parameter   --region us-east-1   --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64   --query "Parameter.Value"   --output text)

aws ec2 describe-images   --region us-east-1   --image-ids "$AMI_ID"   --query "Images[0].[ImageId,Name,Architecture,State]"   --output table
```

Expected architecture: `arm64`.

### RDS remains in `creating`

```bash
aws rds describe-events   --region us-east-1   --source-type db-instance   --source-identifier keycloak-demo-db   --duration 120   --output table
```

Also check:

```bash
aws rds describe-db-instances   --region us-east-1   --db-instance-identifier keycloak-demo-db   --query "DBInstances[0].[DBInstanceStatus,PendingModifiedValues,DBSubnetGroup.SubnetGroupStatus]"   --output json
```

### EC2 is running but SSM is offline

Check:

- the IAM instance profile is attached
- `AmazonSSMManagedInstanceCore` is attached to the role
- the SSM agent is installed and running
- the server has outbound HTTPS access
- DNS works
- the operating system clock is correct

From a traditional SSH session, when available:

```bash
sudo systemctl status amazon-ssm-agent --no-pager
sudo journalctl -u amazon-ssm-agent --since "30 minutes ago" --no-pager
```

### Keycloak cannot connect to PostgreSQL

Check the database status:

```bash
aws rds describe-db-instances   --region us-east-1   --db-instance-identifier keycloak-demo-db   --query "DBInstances[0].[DBInstanceStatus,Endpoint.Address,Endpoint.Port]"   --output table
```

Check both security groups and verify that the RDS ingress rule references the Keycloak security-group ID.

### Port 8443 times out

Possible causes:

- your current public IP is not `68.32.112.68`
- Keycloak has not finished starting
- the service is listening only on localhost
- the certificate or configuration failed
- the Elastic IP is not associated
- the security-group rule did not apply

Find your current public IP using a trusted method, then compare it with the Terraform variable. Do not change the rule to `0.0.0.0/0` just to make troubleshooting easier.

## 19. PowerShell Examples for Windows

Set the Region:

```powershell
$Region = "us-east-1"
$env:AWS_REGION = $Region
$env:AWS_DEFAULT_REGION = $Region
```

Find the EC2 instance:

```powershell
$InstanceId = aws ec2 describe-instances `
  --region $Region `
  --filters "Name=tag:Name,Values=keycloak-demo-keycloak" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
  --query "Reservations[0].Instances[0].InstanceId" `
  --output text

$InstanceId
```

Find the public IP:

```powershell
$PublicIp = aws ec2 describe-addresses `
  --region $Region `
  --filters "Name=tag:Name,Values=keycloak-demo-keycloak-eip" `
  --query "Addresses[0].PublicIp" `
  --output text

$PublicIp
```

Test the HTTPS port:

```powershell
Test-NetConnection -ComputerName $PublicIp -Port 8443
```

Start SSM:

```powershell
aws ssm start-session --region $Region --target $InstanceId
```

## 20. Common Beginner Questions

### Did the plan already create AWS resources?

No. `terraform plan` calculated and displayed proposed actions. Creation starts only after `terraform apply`.

### Why are many IDs unknown?

AWS assigns IDs only after it receives and accepts create requests.

### Does `+` mean success?

No. It means “planned addition.” The apply log must show `Creation complete` for actual success.

### Why are the passwords hidden?

Terraform marks them sensitive so the normal plan does not print them. Protect the state file because sensitive data can still be stored there.

### Is the RDS endpoint public?

The DNS name exists, but `publicly_accessible = false` means the database should not have public network reachability.

### Why use two private subnets if RDS is not Multi-AZ?

RDS subnet groups normally need subnets in multiple Availability Zones. The database itself is still planned as Single-AZ because `multi_az = false`.

### Why use both a public IP and an Elastic IP?

The public subnet can assign a temporary public address, but the Elastic IP provides a stable address that can remain the same across some instance changes or reassociations.

### Can the EC2 server read both secrets?

The shown custom policy resource path is `keycloak-demo/db-*`. Both uploaded secret names begin with `keycloak-demo/db-`, so the policy pattern appears broad enough to match both the database and Keycloak administrator secrets. The description says database secret only, so review whether the wildcard is intentionally that broad.

### Can I use SSH without a key pair?

The plan says `key_name` is known after apply, so inspect the applied instance. If no key pair is attached, use SSM Session Manager instead of SSH.

## 21. Recommended Post-Apply Checklist

- [ ] `terraform apply` finishes without errors.
- [ ] `terraform state list` contains all expected resources.
- [ ] VPC is `available`.
- [ ] Three subnets exist in the intended CIDR ranges.
- [ ] Public subnet has the public route-table association.
- [ ] Private subnets use the private route table.
- [ ] Internet gateway is attached to the new VPC.
- [ ] Keycloak and database security groups exist.
- [ ] Only the intended `/32` source can reach ports 22, 8080, and 8443.
- [ ] RDS port 5432 is allowed only from the Keycloak security group.
- [ ] EC2 reaches `running`.
- [ ] Both EC2 status checks pass.
- [ ] Elastic IP is associated with EC2.
- [ ] SSM shows the instance as `Online`.
- [ ] RDS reaches `available`.
- [ ] RDS reports `PubliclyAccessible = false`.
- [ ] RDS reports encryption enabled.
- [ ] Both Secrets Manager containers exist.
- [ ] Secret versions have an `AWSCURRENT` stage.
- [ ] IAM role has both expected managed policies.
- [ ] Keycloak service is running.
- [ ] HTTPS port 8443 responds from the approved source IP.
- [ ] Keycloak can connect to PostgreSQL.
- [ ] Terraform state and plan files are not committed to Git.

## 22. Final Plan Summary

The uploaded plan proposes a complete small Keycloak learning environment:

- one new VPC
- one public subnet
- two private subnets
- one internet gateway
- public and private route tables
- route-table associations
- two security groups and five separate rules
- one Amazon Linux ARM64 EC2 instance
- one stable Elastic IPv4 address and association
- one PostgreSQL RDS database
- one RDS subnet group
- one RDS parameter group
- two Secrets Manager secret containers
- two secret versions
- one IAM role
- one IAM instance profile
- one custom IAM policy
- two role-policy attachments
- one random suffix
- two random passwords

The exact plan result is:

```text
Plan: 36 to add, 0 to change, 0 to destroy.
```

Remember: this is a promise of intended work, not proof that the work happened. The AWS CLI checks in this guide confirm the real result after apply.
