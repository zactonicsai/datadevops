# Example Output

```
 terraform init
Initializing provider plugins found in the configuration...
- Finding hashicorp/random versions matching "~> 3.6"...
- Finding hashicorp/aws versions matching "~> 5.70"...
- Installing hashicorp/random v3.9.0...
- Installed hashicorp/random v3.9.0 (signed by HashiCorp)
- Installing hashicorp/aws v5.100.0...
- Installed hashicorp/aws v5.100.0 (signed by HashiCorp)

Initializing the backend...


Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

Terraform has been successfully initialized!

You may now begin working with Terraform. Try running "terraform plan" to see
any changes that are required for your infrastructure. All Terraform commands
should now work.

If you ever set or change modules or backend configuration for Terraform,
rerun this command to reinitialize your working directory. If you forget, other
commands will detect it and remind you to do so if necessary.

 CMD: 
****
 
  terraform plan
data.aws_ssm_parameter.al2023_arm64: Reading...
data.aws_iam_policy_document.ec2_trust: Reading...
data.aws_availability_zones.available: Reading...
data.aws_region.current: Reading...
data.aws_caller_identity.current: Reading...
data.aws_region.current: Read complete after 0s [id=us-east-1]
data.aws_iam_policy_document.ec2_trust: Read complete after 0s [id=1186519591]
data.aws_caller_identity.current: Read complete after 0s [id=406207085797]
data.aws_iam_policy_document.read_db_secret: Reading...
data.aws_iam_policy_document.read_db_secret: Read complete after 0s [id=591740106]
data.aws_ssm_parameter.al2023_arm64: Read complete after 0s [id=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64]
data.aws_availability_zones.available: Read complete after 0s [id=us-east-1]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the
following symbols:
  + create

Terraform will perform the following actions:

  # aws_db_instance.keycloak will be created
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

  # aws_db_parameter_group.keycloak will be created
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

  # aws_db_subnet_group.main will be created
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

  # aws_eip.keycloak will be created
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

  # aws_eip_association.keycloak will be created
  + resource "aws_eip_association" "keycloak" {
      + allocation_id        = (known after apply)
      + id                   = (known after apply)
      + instance_id          = (known after apply)
      + network_interface_id = (known after apply)
      + private_ip_address   = (known after apply)
      + public_ip            = (known after apply)
    }

  # aws_iam_instance_profile.keycloak will be created
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

  # aws_iam_policy.read_db_secret will be created
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

  # aws_iam_role.keycloak will be created
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

  # aws_iam_role_policy_attachment.read_db_secret will be created
  + resource "aws_iam_role_policy_attachment" "read_db_secret" {
      + id         = (known after apply)
      + policy_arn = (known after apply)
      + role       = (known after apply)
    }

  # aws_iam_role_policy_attachment.ssm_core will be created
  + resource "aws_iam_role_policy_attachment" "ssm_core" {
      + id         = (known after apply)
      + policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      + role       = (known after apply)
    }

  # aws_instance.keycloak will be created
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

  # aws_internet_gateway.main will be created
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

  # aws_route_table.private will be created
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

  # aws_route_table.public will be created
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

  # aws_route_table_association.private_a will be created
  + resource "aws_route_table_association" "private_a" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.private_b will be created
  + resource "aws_route_table_association" "private_b" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.public will be created
  + resource "aws_route_table_association" "public" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_secretsmanager_secret.db will be created
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

  # aws_secretsmanager_secret.keycloak_admin will be created
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

  # aws_secretsmanager_secret_version.db will be created
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

  # aws_secretsmanager_secret_version.keycloak_admin will be created
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

  # aws_security_group.database will be created
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

  # aws_security_group.keycloak will be created
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

  # aws_subnet.private_a will be created
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

  # aws_subnet.private_b will be created
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

  # aws_subnet.public will be created
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

  # aws_vpc.main will be created
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

  # aws_vpc_security_group_egress_rule.db_none will be created
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

  # aws_vpc_security_group_egress_rule.keycloak_all_out will be created
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

  # aws_vpc_security_group_ingress_rule.db_from_keycloak will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_http will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_https will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_ssh will be created
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

  # random_id.suffix will be created
  + resource "random_id" "suffix" {
      + b64_std     = (known after apply)
      + b64_url     = (known after apply)
      + byte_length = 3
      + dec         = (known after apply)
      + hex         = (known after apply)
      + id          = (known after apply)
    }

  # random_password.db will be created
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

  # random_password.keycloak_admin will be created
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

Plan: 36 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + allowed_source_ip          = "68.32.112.68/32"
  + database_sg_id             = (known after apply)
  + db_endpoint                = (known after apply)
  + db_jdbc_url                = (known after apply)
  + db_port                    = (known after apply)
  + db_secret_arn              = (known after apply)
  + db_secret_name             = (known after apply)
  + db_subnet_group_name       = "keycloak-demo-db-subnets"
  + get_admin_password_command = (known after apply)
  + instance_profile_name      = (known after apply)
  + keycloak_admin_console     = (known after apply)
  + keycloak_admin_secret_name = (known after apply)
  + keycloak_instance_id       = (known after apply)
  + keycloak_public_ip         = (known after apply)
  + keycloak_sg_id             = (known after apply)
  + keycloak_url               = (known after apply)
  + private_subnet_ids         = [
      + (known after apply),
      + (known after apply),
    ]
  + public_subnet_id           = (known after apply)
  + resource_suffix            = (known after apply)
  + ssm_shell_command          = (known after apply)
  + vpc_id                     = (known after apply)

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Note: You didn't use the -out option to save this plan, so Terraform can't guarantee to take exactly these actions if
you run "terraform apply" now.

 CMD: 
****
 
  terraform plan -out tplan
data.aws_caller_identity.current: Reading...
data.aws_availability_zones.available: Reading...
data.aws_region.current: Reading...
data.aws_iam_policy_document.ec2_trust: Reading...
data.aws_ssm_parameter.al2023_arm64: Reading...
data.aws_region.current: Read complete after 0s [id=us-east-1]
data.aws_iam_policy_document.ec2_trust: Read complete after 0s [id=1186519591]
data.aws_caller_identity.current: Read complete after 0s [id=406207085797]
data.aws_iam_policy_document.read_db_secret: Reading...
data.aws_iam_policy_document.read_db_secret: Read complete after 0s [id=591740106]
data.aws_ssm_parameter.al2023_arm64: Read complete after 0s [id=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64]
data.aws_availability_zones.available: Read complete after 0s [id=us-east-1]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the
following symbols:
  + create

Terraform will perform the following actions:

  # aws_db_instance.keycloak will be created
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

  # aws_db_parameter_group.keycloak will be created
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

  # aws_db_subnet_group.main will be created
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

  # aws_eip.keycloak will be created
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

  # aws_eip_association.keycloak will be created
  + resource "aws_eip_association" "keycloak" {
      + allocation_id        = (known after apply)
      + id                   = (known after apply)
      + instance_id          = (known after apply)
      + network_interface_id = (known after apply)
      + private_ip_address   = (known after apply)
      + public_ip            = (known after apply)
    }

  # aws_iam_instance_profile.keycloak will be created
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

  # aws_iam_policy.read_db_secret will be created
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

  # aws_iam_role.keycloak will be created
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

  # aws_iam_role_policy_attachment.read_db_secret will be created
  + resource "aws_iam_role_policy_attachment" "read_db_secret" {
      + id         = (known after apply)
      + policy_arn = (known after apply)
      + role       = (known after apply)
    }

  # aws_iam_role_policy_attachment.ssm_core will be created
  + resource "aws_iam_role_policy_attachment" "ssm_core" {
      + id         = (known after apply)
      + policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      + role       = (known after apply)
    }

  # aws_instance.keycloak will be created
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

  # aws_internet_gateway.main will be created
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

  # aws_route_table.private will be created
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

  # aws_route_table.public will be created
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

  # aws_route_table_association.private_a will be created
  + resource "aws_route_table_association" "private_a" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.private_b will be created
  + resource "aws_route_table_association" "private_b" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.public will be created
  + resource "aws_route_table_association" "public" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_secretsmanager_secret.db will be created
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

  # aws_secretsmanager_secret.keycloak_admin will be created
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

  # aws_secretsmanager_secret_version.db will be created
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

  # aws_secretsmanager_secret_version.keycloak_admin will be created
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

  # aws_security_group.database will be created
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

  # aws_security_group.keycloak will be created
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

  # aws_subnet.private_a will be created
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

  # aws_subnet.private_b will be created
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

  # aws_subnet.public will be created
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

  # aws_vpc.main will be created
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

  # aws_vpc_security_group_egress_rule.db_none will be created
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

  # aws_vpc_security_group_egress_rule.keycloak_all_out will be created
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

  # aws_vpc_security_group_ingress_rule.db_from_keycloak will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_http will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_https will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_ssh will be created
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

  # random_id.suffix will be created
  + resource "random_id" "suffix" {
      + b64_std     = (known after apply)
      + b64_url     = (known after apply)
      + byte_length = 3
      + dec         = (known after apply)
      + hex         = (known after apply)
      + id          = (known after apply)
    }

  # random_password.db will be created
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

  # random_password.keycloak_admin will be created
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

Plan: 36 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + allowed_source_ip          = "68.32.112.68/32"
  + database_sg_id             = (known after apply)
  + db_endpoint                = (known after apply)
  + db_jdbc_url                = (known after apply)
  + db_port                    = (known after apply)
  + db_secret_arn              = (known after apply)
  + db_secret_name             = (known after apply)
  + db_subnet_group_name       = "keycloak-demo-db-subnets"
  + get_admin_password_command = (known after apply)
  + instance_profile_name      = (known after apply)
  + keycloak_admin_console     = (known after apply)
  + keycloak_admin_secret_name = (known after apply)
  + keycloak_instance_id       = (known after apply)
  + keycloak_public_ip         = (known after apply)
  + keycloak_sg_id             = (known after apply)
  + keycloak_url               = (known after apply)
  + private_subnet_ids         = [
      + (known after apply),
      + (known after apply),
    ]
  + public_subnet_id           = (known after apply)
  + resource_suffix            = (known after apply)
  + ssm_shell_command          = (known after apply)
  + vpc_id                     = (known after apply)

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

Saved the plan to: tplan

To perform exactly these actions, run the following command to apply:
    terraform apply "tplan"

 CMD: 
****
 
  

 CMD: 
****
 
  terraform apply
data.aws_availability_zones.available: Reading...
data.aws_iam_policy_document.ec2_trust: Reading...
data.aws_ssm_parameter.al2023_arm64: Reading...
data.aws_region.current: Reading...
data.aws_caller_identity.current: Reading...
data.aws_iam_policy_document.ec2_trust: Read complete after 0s [id=1186519591]
data.aws_region.current: Read complete after 0s [id=us-east-1]
data.aws_caller_identity.current: Read complete after 0s [id=406207085797]
data.aws_iam_policy_document.read_db_secret: Reading...
data.aws_iam_policy_document.read_db_secret: Read complete after 0s [id=591740106]
data.aws_ssm_parameter.al2023_arm64: Read complete after 0s [id=/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64]
data.aws_availability_zones.available: Read complete after 0s [id=us-east-1]

Terraform used the selected providers to generate the following execution plan. Resource actions are indicated with the
following symbols:
  + create

Terraform will perform the following actions:

  # aws_db_instance.keycloak will be created
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

  # aws_db_parameter_group.keycloak will be created
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

  # aws_db_subnet_group.main will be created
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

  # aws_eip.keycloak will be created
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

  # aws_eip_association.keycloak will be created
  + resource "aws_eip_association" "keycloak" {
      + allocation_id        = (known after apply)
      + id                   = (known after apply)
      + instance_id          = (known after apply)
      + network_interface_id = (known after apply)
      + private_ip_address   = (known after apply)
      + public_ip            = (known after apply)
    }

  # aws_iam_instance_profile.keycloak will be created
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

  # aws_iam_policy.read_db_secret will be created
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

  # aws_iam_role.keycloak will be created
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

  # aws_iam_role_policy_attachment.read_db_secret will be created
  + resource "aws_iam_role_policy_attachment" "read_db_secret" {
      + id         = (known after apply)
      + policy_arn = (known after apply)
      + role       = (known after apply)
    }

  # aws_iam_role_policy_attachment.ssm_core will be created
  + resource "aws_iam_role_policy_attachment" "ssm_core" {
      + id         = (known after apply)
      + policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      + role       = (known after apply)
    }

  # aws_instance.keycloak will be created
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

  # aws_internet_gateway.main will be created
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

  # aws_route_table.private will be created
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

  # aws_route_table.public will be created
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

  # aws_route_table_association.private_a will be created
  + resource "aws_route_table_association" "private_a" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.private_b will be created
  + resource "aws_route_table_association" "private_b" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_route_table_association.public will be created
  + resource "aws_route_table_association" "public" {
      + id             = (known after apply)
      + route_table_id = (known after apply)
      + subnet_id      = (known after apply)
    }

  # aws_secretsmanager_secret.db will be created
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

  # aws_secretsmanager_secret.keycloak_admin will be created
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

  # aws_secretsmanager_secret_version.db will be created
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

  # aws_secretsmanager_secret_version.keycloak_admin will be created
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

  # aws_security_group.database will be created
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

  # aws_security_group.keycloak will be created
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

  # aws_subnet.private_a will be created
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

  # aws_subnet.private_b will be created
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

  # aws_subnet.public will be created
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

  # aws_vpc.main will be created
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

  # aws_vpc_security_group_egress_rule.db_none will be created
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

  # aws_vpc_security_group_egress_rule.keycloak_all_out will be created
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

  # aws_vpc_security_group_ingress_rule.db_from_keycloak will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_http will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_https will be created
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

  # aws_vpc_security_group_ingress_rule.keycloak_ssh will be created
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

  # random_id.suffix will be created
  + resource "random_id" "suffix" {
      + b64_std     = (known after apply)
      + b64_url     = (known after apply)
      + byte_length = 3
      + dec         = (known after apply)
      + hex         = (known after apply)
      + id          = (known after apply)
    }

  # random_password.db will be created
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

  # random_password.keycloak_admin will be created
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

Plan: 36 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + allowed_source_ip          = "68.32.112.68/32"
  + database_sg_id             = (known after apply)
  + db_endpoint                = (known after apply)
  + db_jdbc_url                = (known after apply)
  + db_port                    = (known after apply)
  + db_secret_arn              = (known after apply)
  + db_secret_name             = (known after apply)
  + db_subnet_group_name       = "keycloak-demo-db-subnets"
  + get_admin_password_command = (known after apply)
  + instance_profile_name      = (known after apply)
  + keycloak_admin_console     = (known after apply)
  + keycloak_admin_secret_name = (known after apply)
  + keycloak_instance_id       = (known after apply)
  + keycloak_public_ip         = (known after apply)
  + keycloak_sg_id             = (known after apply)
  + keycloak_url               = (known after apply)
  + private_subnet_ids         = [
      + (known after apply),
      + (known after apply),
    ]
  + public_subnet_id           = (known after apply)
  + resource_suffix            = (known after apply)
  + ssm_shell_command          = (known after apply)
  + vpc_id                     = (known after apply)

Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

random_id.suffix: Creating...
random_password.db: Creating...
random_password.keycloak_admin: Creating...
random_id.suffix: Creation complete after 0s [id=OWks]
random_password.keycloak_admin: Creation complete after 0s [id=none]
random_password.db: Creation complete after 0s [id=none]
aws_iam_policy.read_db_secret: Creating...
aws_secretsmanager_secret.db: Creating...
aws_iam_role.keycloak: Creating...
aws_secretsmanager_secret.keycloak_admin: Creating...
aws_vpc.main: Creating...
aws_db_parameter_group.keycloak: Creating...
aws_secretsmanager_secret.keycloak_admin: Creation complete after 1s [id=arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5]
aws_secretsmanager_secret_version.keycloak_admin: Creating...
aws_secretsmanager_secret.db: Creation complete after 1s [id=arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h]
aws_iam_policy.read_db_secret: Creation complete after 1s [id=arn:aws:iam::406207085797:policy/keycloak-demo-read-db-secret-39692c]
aws_iam_role.keycloak: Creation complete after 1s [id=keycloak-demo-keycloak-role-39692c]
aws_iam_role_policy_attachment.ssm_core: Creating...
aws_iam_role_policy_attachment.read_db_secret: Creating...
aws_iam_instance_profile.keycloak: Creating...
aws_iam_role_policy_attachment.read_db_secret: Creation complete after 0s [id=keycloak-demo-keycloak-role-39692c-20260723234716141700000004]
aws_iam_role_policy_attachment.ssm_core: Creation complete after 0s [id=keycloak-demo-keycloak-role-39692c-20260723234716141700000005]
aws_secretsmanager_secret_version.keycloak_admin: Creation complete after 0s [id=arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-keycloak-admin-39692c-4ykvf5|terraform-20260723234715876100000003]
aws_db_parameter_group.keycloak: Creation complete after 2s [id=keycloak-demo-pg18-params]
aws_iam_instance_profile.keycloak: Creation complete after 6s [id=keycloak-demo-keycloak-profile-39692c]
aws_vpc.main: Still creating... [00m10s elapsed]
aws_vpc.main: Creation complete after 13s [id=vpc-0d470b94ebdffafc5]
aws_subnet.private_b: Creating...
aws_internet_gateway.main: Creating...
aws_security_group.database: Creating...
aws_subnet.public: Creating...
aws_security_group.keycloak: Creating...
aws_route_table.private: Creating...
aws_subnet.private_a: Creating...
aws_internet_gateway.main: Creation complete after 0s [id=igw-0fb2b12baa6f748ae]
aws_eip.keycloak: Creating...
aws_route_table.public: Creating...
aws_route_table.private: Creation complete after 0s [id=rtb-019c61d71d5eb425a]
aws_subnet.private_b: Creation complete after 0s [id=subnet-018ec8fc3cc46a312]
aws_subnet.private_a: Creation complete after 0s [id=subnet-0267a69101df5beb2]
aws_route_table_association.private_a: Creating...
aws_route_table_association.private_b: Creating...
aws_db_subnet_group.main: Creating...
aws_route_table_association.private_a: Creation complete after 1s [id=rtbassoc-08721f9399f1f752e]
aws_route_table_association.private_b: Creation complete after 1s [id=rtbassoc-023dca32d5ff4761d]
aws_route_table.public: Creation complete after 1s [id=rtb-04b1e80ee066674dd]
aws_security_group.database: Creation complete after 1s [id=sg-0267d26156f2a1007]
aws_vpc_security_group_egress_rule.db_none: Creating...
aws_security_group.keycloak: Creation complete after 1s [id=sg-0e73f9e971b5c6e36]
aws_vpc_security_group_ingress_rule.keycloak_https: Creating...
aws_vpc_security_group_ingress_rule.keycloak_http: Creating...
aws_vpc_security_group_ingress_rule.db_from_keycloak: Creating...
aws_vpc_security_group_egress_rule.keycloak_all_out: Creating...
aws_vpc_security_group_ingress_rule.keycloak_ssh: Creating...
aws_db_subnet_group.main: Creation complete after 2s [id=keycloak-demo-db-subnets]
aws_db_instance.keycloak: Creating...
aws_vpc_security_group_ingress_rule.keycloak_http: Creation complete after 1s [id=sgr-01805c9192553ee68]
aws_vpc_security_group_ingress_rule.keycloak_https: Creation complete after 1s [id=sgr-0714563e5a3283970]
aws_vpc_security_group_ingress_rule.db_from_keycloak: Creation complete after 1s [id=sgr-0471fa8452df1c8f7]
aws_vpc_security_group_egress_rule.db_none: Creation complete after 1s [id=sgr-0fe3258df2a14cff8]
aws_vpc_security_group_ingress_rule.keycloak_ssh: Creation complete after 1s [id=sgr-0fc1836196cedc6a8]
aws_vpc_security_group_egress_rule.keycloak_all_out: Creation complete after 1s [id=sgr-0cc4f4b38072fc1cb]
aws_eip.keycloak: Creation complete after 2s [id=eipalloc-00b08d704aacb7029]
aws_subnet.public: Still creating... [00m10s elapsed]
aws_subnet.public: Creation complete after 11s [id=subnet-09369b387fc6af56d]
aws_route_table_association.public: Creating...
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-0096ef281f7a8d3d1]
aws_db_instance.keycloak: Still creating... [00m10s elapsed]
aws_db_instance.keycloak: Still creating... [00m20s elapsed]
aws_db_instance.keycloak: Still creating... [00m30s elapsed]
aws_db_instance.keycloak: Still creating... [00m40s elapsed]
aws_db_instance.keycloak: Still creating... [00m50s elapsed]
aws_db_instance.keycloak: Still creating... [01m00s elapsed]
aws_db_instance.keycloak: Still creating... [01m10s elapsed]
aws_db_instance.keycloak: Still creating... [01m20s elapsed]
aws_db_instance.keycloak: Still creating... [01m30s elapsed]
aws_db_instance.keycloak: Still creating... [01m40s elapsed]
aws_db_instance.keycloak: Still creating... [01m50s elapsed]
aws_db_instance.keycloak: Still creating... [02m00s elapsed]
aws_db_instance.keycloak: Still creating... [02m10s elapsed]
aws_db_instance.keycloak: Still creating... [02m20s elapsed]
aws_db_instance.keycloak: Still creating... [02m30s elapsed]
aws_db_instance.keycloak: Still creating... [02m40s elapsed]
aws_db_instance.keycloak: Still creating... [02m50s elapsed]
aws_db_instance.keycloak: Still creating... [03m00s elapsed]
aws_db_instance.keycloak: Still creating... [03m10s elapsed]
aws_db_instance.keycloak: Still creating... [03m20s elapsed]
aws_db_instance.keycloak: Still creating... [03m30s elapsed]
aws_db_instance.keycloak: Still creating... [03m40s elapsed]
aws_db_instance.keycloak: Still creating... [03m50s elapsed]
aws_db_instance.keycloak: Still creating... [04m00s elapsed]
aws_db_instance.keycloak: Still creating... [04m10s elapsed]
aws_db_instance.keycloak: Still creating... [04m20s elapsed]
aws_db_instance.keycloak: Still creating... [04m30s elapsed]
aws_db_instance.keycloak: Still creating... [04m40s elapsed]
aws_db_instance.keycloak: Still creating... [04m50s elapsed]
aws_db_instance.keycloak: Still creating... [05m00s elapsed]
aws_db_instance.keycloak: Still creating... [05m10s elapsed]
aws_db_instance.keycloak: Still creating... [05m20s elapsed]
aws_db_instance.keycloak: Still creating... [05m30s elapsed]
aws_db_instance.keycloak: Still creating... [05m40s elapsed]
aws_db_instance.keycloak: Still creating... [05m50s elapsed]
aws_db_instance.keycloak: Still creating... [06m00s elapsed]
aws_db_instance.keycloak: Still creating... [06m10s elapsed]
aws_db_instance.keycloak: Still creating... [06m20s elapsed]
aws_db_instance.keycloak: Still creating... [06m30s elapsed]
aws_db_instance.keycloak: Still creating... [06m40s elapsed]
aws_db_instance.keycloak: Still creating... [06m50s elapsed]
aws_db_instance.keycloak: Still creating... [07m00s elapsed]
aws_db_instance.keycloak: Still creating... [07m10s elapsed]
aws_db_instance.keycloak: Still creating... [07m20s elapsed]
aws_db_instance.keycloak: Still creating... [07m30s elapsed]
aws_db_instance.keycloak: Still creating... [07m40s elapsed]
aws_db_instance.keycloak: Still creating... [07m50s elapsed]
aws_db_instance.keycloak: Still creating... [08m00s elapsed]
aws_db_instance.keycloak: Still creating... [08m10s elapsed]
aws_db_instance.keycloak: Still creating... [08m20s elapsed]
aws_db_instance.keycloak: Still creating... [08m30s elapsed]
aws_db_instance.keycloak: Still creating... [08m40s elapsed]
aws_db_instance.keycloak: Still creating... [08m50s elapsed]
aws_db_instance.keycloak: Still creating... [09m00s elapsed]
aws_db_instance.keycloak: Still creating... [09m10s elapsed]
aws_db_instance.keycloak: Still creating... [09m20s elapsed]
aws_db_instance.keycloak: Creation complete after 9m21s [id=db-3HQ7YMCLDBJFS4RVQX2UZEPJ4E]
aws_secretsmanager_secret_version.db: Creating...
aws_secretsmanager_secret_version.db: Creation complete after 1s [id=arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h|terraform-20260723235651393200000008]
aws_instance.keycloak: Creating...
aws_instance.keycloak: Still creating... [00m10s elapsed]
aws_instance.keycloak: Creation complete after 13s [id=i-0f7317687e9066068]
aws_eip_association.keycloak: Creating...
aws_eip_association.keycloak: Creation complete after 2s [id=eipassoc-0d1b25e1f4657391e]

Apply complete! Resources: 36 added, 0 changed, 0 destroyed.

Outputs:

allowed_source_ip = "68.32.112.68/32"
database_sg_id = "sg-0267d26156f2a1007"
db_endpoint = "keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com"
db_jdbc_url = "jdbc:postgresql://keycloak-demo-db.cshyikuwi6xh.us-east-1.rds.amazonaws.com:5432/keycloak?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem"
db_port = 5432
db_secret_arn = "arn:aws:secretsmanager:us-east-1:406207085797:secret:keycloak-demo/db-credentials-39692c-RXXr8h"
db_secret_name = "keycloak-demo/db-credentials-39692c"
db_subnet_group_name = "keycloak-demo-db-subnets"
get_admin_password_command = "aws secretsmanager get-secret-value --secret-id keycloak-demo/db-keycloak-admin-39692c --query SecretString --output text | jq ."
instance_profile_name = "keycloak-demo-keycloak-profile-39692c"
keycloak_admin_console = "https://34.197.55.175:8443/admin"
keycloak_admin_secret_name = "keycloak-demo/db-keycloak-admin-39692c"
keycloak_instance_id = "i-0f7317687e9066068"
keycloak_public_ip = "34.197.55.175"
keycloak_sg_id = "sg-0e73f9e971b5c6e36"
keycloak_url = "https://34.197.55.175:8443"
private_subnet_ids = [
  "subnet-0267a69101df5beb2",
  "subnet-018ec8fc3cc46a312",
]
public_subnet_id = "subnet-09369b387fc6af56d"
resource_suffix = "39692c"
ssm_shell_command = "aws ssm start-session --target i-0f7317687e9066068"
vpc_id = "vpc-0d470b94ebdffafc5"

 CMD: 
****
 
  terraform output -raw get_admin_password_command
aws secretsmanager get-secret-value --secret-id keycloak-demo/db-keycloak-admin-39692c --query SecretString --output text | jq .%                                                                                                               
 CMD: 
****
 
  aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw keycloak_admin_secret_name 2>/dev/null || echo "keycloak-demo/db-keycloak-admin") \
  --query SecretString --output text | jq .
{
  "password": "5G34zd=!EpiG-MIOdyTs9SV9",
  "username": "kcadmin"
}
```