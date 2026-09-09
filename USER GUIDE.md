# EC2 Terraform Modules — User Guide

This repository contains two small, reusable Terraform modules and two worked examples that show how to combine them into real applications.

| Path | What it is |
|---|---|
| `launch_template/` | Builds a hardened AWS **Launch Template** (the "recipe" for an EC2 instance) |
| `ec2_instance/` | Launches **one EC2 instance** from a launch template and optionally attaches an Elastic IP |
| `examples/nifi/` | **Simple app** — one NiFi server built from a launch template |
| `examples/keycloak/` | **Complex app** — Keycloak in Docker behind an internal load balancer, fully private |

The guide starts with a hands-on walkthrough, then explains the background, every variable, and best practices.

---

## 1. Quick start — deploy a simple app in 10 minutes

We will deploy the NiFi example. You need:

* Terraform ≥ 1.6 (or OpenTofu ≥ 1.6)
* AWS credentials with permission to create EC2, IAM, and security groups
* A VPC subnet id

### Step 1 — Get the code

```bash
unzip nifi-keycloak-terraform-examples.zip
cd examples/nifi
```

### Step 2 — Create your settings file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and change at least these lines:

```hcl
subnet_id                = "subnet-0123456789abcdef0"   # your subnet
nifi_sensitive_props_key = "a-long-random-string-here"  # ≥ 12 chars
nifi_single_user_password = "ChangeMePlease123!"        # ≥ 12 chars
```

### Step 3 — Initialise, preview, apply

```bash
terraform init      # downloads the AWS provider and links the local modules
terraform plan      # shows what will be created — nothing is changed yet
terraform apply     # type "yes" to build it
```

### Step 4 — Use it

When `apply` finishes it prints outputs such as:

```
nifi_url = "https://10.0.12.34:8443/nifi"
instance_id = "i-0abc..."
```

Open the URL from inside your network, log in with the single-user credentials, done.

### Step 5 — Change configuration

Edit the `nifi_properties` map in `terraform.tfvars`, run `terraform apply` again. Terraform creates a **new launch template version**; replace the instance (`terraform apply -replace=module.nifi_instance[0].aws_instance.this`) to pick it up.

### Step 6 — Clean up

```bash
terraform destroy
```

---

## 2. Background — the pieces and why they exist

### What is a launch template?

A launch template is a saved set of instructions AWS uses to start an EC2 server: which image (AMI), what size, which network, which disks, and a **user-data** script that runs on first boot. Launch templates are versioned — every change creates a new version, and old ones stay around, which makes rollbacks easy. Auto Scaling groups, spot fleets, and single instances can all be created from the same template.

### Why split "template" and "instance" into two modules?

* A **template** describes *how* to build a server. It is cheap, has no running cost, and can be shared.
* An **instance** is a *running* copy. You may want zero (template only, for an Auto Scaling group), one (a dev box), or many.

Keeping them separate means the same template can serve a single test instance today and an Auto Scaling group tomorrow without rewriting anything.

### What the `launch_template` module does for you (opinionated defaults)

| Feature | Default | Why |
|---|---|---|
| IMDSv2 required | on | Blocks a common credential-theft technique (SSRF against the metadata service) |
| Root volume encrypted, gp3 | on | Encryption at rest with no cost penalty; gp3 is cheaper and faster than gp2 |
| Single network interface, delete on termination | on | Keeps things simple and avoids orphaned ENIs |
| User data base64-encoded for you | yes | You pass plain text; the module handles encoding |
| Optional IAM instance profile | off | Lets the server call AWS APIs (e.g. SSM) without stored keys |
| Detailed monitoring | off | One-minute CloudWatch metrics cost money; turn on when needed |

Everything in that table can be overridden with a variable.

### Cloud-init / user data — how configuration reaches the server

Both examples generate a bash script with Terraform's `templatefile()` function, fill it with values from your variables, and hand it to the launch template. On first boot the instance runs the script as root. This is the key technique that lets you keep **application** settings (NiFi properties, Keycloak env vars) inside Terraform alongside **infrastructure** settings.

---

## 3. Module reference

### 3.1 `launch_template`

```hcl
module "lt" {
  source = "./launch_template"

  name               = "myapp"
  image_id           = "ami-0123456789abcdef0"
  instance_type      = "t3.medium"
  subnet_id          = "subnet-…"
  security_group_ids = ["sg-…"]
  user_data          = file("bootstrap.sh")
}
```

#### Required variables

| Variable | Type | Description |
|---|---|---|
| `name` | string | Prefix for the template name and every `Name` tag (`<name>-launch-template`, `<name>-ec2`, `<name>-root`) |
| `image_id` | string | AMI id |
| `instance_type` | string | e.g. `t3.medium`, `m6i.large` |
| `subnet_id` | string | Subnet the primary network interface is placed in |
| `security_group_ids` | list(string) | Security groups attached to the interface |

#### Optional variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `description` | string | `null` | Free-text description on the template |
| `key_name` | string | `null` | EC2 key pair for SSH. Prefer SSM Session Manager and leave this null |
| `iam_instance_profile_name` | string | `null` | Instance profile name; omit for no IAM role |
| `associate_public_ip_address` | bool | `true` | Give the instance a public IP. **Set `false` for private workloads** |
| `user_data` | string (sensitive) | `null` | Plain-text boot script; module base64-encodes it |
| `update_default_version` | bool | `true` | Make each new version the default |
| `ebs_optimized` | bool | `true` | Dedicated EBS bandwidth |
| `root_device_name` | string | `/dev/xvda` | Root device name for the AMI (Amazon Linux uses `/dev/xvda`; Ubuntu uses `/dev/sda1`) |
| `root_volume_type` | string | `gp3` | EBS volume type |
| `root_volume_size` | number | `20` | Root disk size in GiB |
| `root_volume_iops` | number | `null` | Provisioned IOPS (gp3 default is 3000) |
| `root_volume_throughput` | number | `null` | MiB/s (gp3 default is 125) |
| `root_volume_encrypted` | bool | `true` | Encrypt root volume |
| `root_volume_kms_key_id` | string | `null` | Customer-managed KMS key; null = AWS-managed key |
| `additional_volumes` | list(object) | `[]` | Extra EBS disks — see below |
| `require_imdsv2` | bool | `true` | Enforce IMDSv2 tokens |
| `metadata_hop_limit` | number | `1` | Set to `2` when **containers** on the host need IMDS (Docker, ECS agent) |
| `enable_instance_metadata_tags` | bool | `false` | Expose instance tags through IMDS |
| `detailed_monitoring` | bool | `false` | 1-minute CloudWatch metrics |
| `tags` | map(string) | `{}` | Applied to the template, instance, and volumes |
| `instance_tags` | map(string) | `{}` | Extra tags only on instances |
| `volume_tags` | map(string) | `{}` | Extra tags only on volumes |

`additional_volumes` entries:

```hcl
additional_volumes = [{
  device_name           = "/dev/xvdb"   # required
  volume_size           = 100           # required, GiB
  volume_type           = "gp3"         # optional
  encrypted             = true          # optional
  delete_on_termination = true          # optional — set false to keep data after termination
}]
```

The module only *attaches* the disk; your user-data must format and mount it (the NiFi example shows how).

#### Outputs

| Output | Description |
|---|---|
| `id` | Launch template id (`lt-…`) — pass to `ec2_instance` or an ASG |
| `arn` | Template ARN |
| `latest_version` | Numeric latest version |
| `name` | Generated template name |

### 3.2 `ec2_instance`

```hcl
module "server" {
  source = "./ec2_instance"

  name                    = "myapp"
  launch_template_id      = module.lt.id
  launch_template_version = tostring(module.lt.latest_version)
}
```

| Variable | Type | Default | Description |
|---|---|---|---|
| `name` | string | — | Used for the `Name` tag |
| `launch_template_id` | string | — | From `module.lt.id` |
| `launch_template_version` | string | `"$Latest"` | Pin with `tostring(module.lt.latest_version)` so Terraform notices template changes; `"$Latest"` resolves at launch only |
| `eip_allocation_id` | string | `null` | Existing Elastic IP allocation to bind |
| `termination_protection` | bool | `false` | Prevent accidental `terminate` calls |
| `tags` | map(string) | `{}` | Instance tags |

Outputs: `id`, `arn`, `private_ip`, `public_ip` (the EIP when attached), `availability_zone`.

> **Tip:** use `tostring(module.lt.latest_version)`, not `"$Latest"`. With `$Latest` Terraform does not see a change when the template gets a new version, so the instance is never replaced.

---

## 4. Simple app pattern — `examples/nifi`

**Shape:** one launch template → one instance. Good for dev servers, single-node tools, or anything with no load balancer.

```
your network ──► EC2 (NiFi, HTTPS :8443)
                 ├── root gp3 30 GiB
                 └── data gp3 100 GiB  /data/nifi  (repositories)
```

### What the example adds on top of the modules

* A security group opening the NiFi HTTPS port (and optionally SSH) to `allowed_cidr_blocks`
* An IAM role with `AmazonSSMManagedInstanceCore` so you can open a shell with Session Manager
* AMI lookup — latest Amazon Linux 2023 from the public SSM parameter, unless you pass `image_id`
* A user-data template that installs Java + NiFi, formats and mounts the data disk, applies your properties, and starts NiFi under systemd

### The two configuration maps

```hcl
# Overrides for conf/nifi.properties — existing keys replaced, new keys appended
nifi_properties = {
  "nifi.web.https.port"          = "8443"
  "nifi.queue.backpressure.size" = "2 GB"
}

# Custom variables available to processors as ${env}, ${s3_landing_bucket} …
nifi_user_properties = {
  env               = "dev"
  s3_landing_bucket = "acme-nifi-landing-dev"
}
```

Defaults are merged underneath `nifi_properties`, so you only list the keys you care about. The sensitive props key is applied separately so it never appears in plan output.

### Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-east-1` | AWS region |
| `name` | `nifi` | Resource name prefix |
| `subnet_id` | **required** | Subnet for the instance |
| `image_id` | `null` | AMI override |
| `instance_type` | `m6i.large` | NiFi likes memory; 8 GiB minimum for real work |
| `key_name` | `null` | SSH key pair (optional) |
| `enable_ssh` | `false` | Add a port-22 rule |
| `allowed_cidr_blocks` | `["10.0.0.0/8"]` | Who may reach the UI/SSH |
| `additional_security_group_ids` | `[]` | Extra SGs |
| `associate_public_ip_address` | `false` | Public IP on the instance |
| `root_volume_size` | `30` | GiB |
| `data_volume_device` | `/dev/xvdb` | Repository disk; `""` disables it |
| `data_volume_size` | `100` | GiB |
| `data_volume_mount` | `/data/nifi` | Mount point |
| `create_instance` | `true` | `false` = template only |
| `eip_allocation_id` | `null` | Attach an existing EIP |
| `termination_protection` | `false` | |
| `tags` | `{}` | |
| `nifi_version` | `2.4.0` | NiFi release to install |
| `nifi_download_url` | `null` | Internal mirror / S3 URL override |
| `java_version` | `21` | Corretto major version (NiFi 2.x needs 21) |
| `nifi_properties` | `{}` | See above |
| `nifi_user_properties` | `{}` | See above |
| `nifi_user_properties_file` | `custom.properties` | File name under `conf/` |
| `nifi_proxy_host` | `""` | `host:port` when behind a proxy/LB |
| `nifi_sensitive_props_key` | **required**, sensitive | Encrypts sensitive flow values; ≥ 12 chars |
| `nifi_single_user_username` | `admin` | `""` keeps NiFi's generated credentials |
| `nifi_single_user_password` | `""`, sensitive | ≥ 12 chars when set |

Outputs: `launch_template_id`, `launch_template_arn`, `launch_template_latest_version`, `security_group_id`, `instance_id`, `nifi_url`, `effective_nifi_properties` (sensitive).

---

## 5. Complex app pattern — `examples/keycloak`

**Shape:** launch template → instance → target group → internal ALB. Everything private. Good for web apps that need TLS termination, health checks, or will later scale out.

```
allowed_cidr_blocks ──► internal ALB (:443 or :80, ≥2 private subnets)
                            │  target group HTTP :8080
                            │  health check :9000 /health/ready
                            ▼
                   EC2 (private subnet, no public IP)
                   └─ docker run quay.io/keycloak/keycloak start
```

### What the example adds on top of the modules

* **Two security groups** — the ALB SG allows your CIDRs; the instance SG allows *only* the ALB SG on 8080/9000. There is no SSH rule at all.
* **Internal ALB + target group + listener** — HTTPS when you supply an ACM `certificate_arn`, HTTP otherwise.
* **Docker-based Keycloak** managed by a systemd unit, persistent data volume, logs to journald.
* **Guard rails** — `associate_public_ip_address` is hard-coded `false`, and `allowed_cidr_blocks` rejects `0.0.0.0/0`.
* `metadata_hop_limit = 2` so the container can reach the instance role.

### Configuration maps

```hcl
# Any KC_* option — merged over proxy/hostname/health defaults
keycloak_env = {
  KC_LOG_LEVEL = "info"
  KC_CACHE     = "local"
}

# Extra keycloak.conf entries mounted into the container
keycloak_user_properties = {
  "spi-theme-cache-themes" = "true"
}

# Appended to `kc.sh start`
keycloak_extra_args = ["--features=token-exchange"]
```

### Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-east-1` | |
| `name` | `keycloak` | Prefix (kept short — ALB/TG names are truncated to 6 chars + suffix) |
| `instance_subnet_id` | **required** | Private subnet for the instance |
| `lb_subnet_ids` | **required**, ≥ 2 | Private subnets in different AZs for the ALB |
| `allowed_cidr_blocks` | `["10.0.0.0/8"]` | Who may reach the ALB; `0.0.0.0/0` rejected |
| `image_id` | `null` | AMI override |
| `instance_type` | `t3.medium` | 4 GiB is the practical minimum for Keycloak |
| `key_name` | `null` | |
| `additional_security_group_ids` | `[]` | |
| `root_volume_size` | `30` | GiB |
| `create_instance` | `true` | `false` = template + ALB + TG only (attach an ASG yourself) |
| `termination_protection` | `false` | |
| `tags` | `{}` | |
| `certificate_arn` | `null` | ACM cert → HTTPS :443 listener; null → HTTP :80 |
| `ssl_policy` | `ELBSecurityPolicy-TLS13-1-2-2021-06` | TLS policy for HTTPS |
| `lb_idle_timeout` | `60` | Seconds |
| `keycloak_image` | `quay.io/keycloak/keycloak:26.3` | Pin a tag you have tested |
| `keycloak_hostname` | **required** | DNS name users type; becomes `KC_HOSTNAME` |
| `keycloak_http_port` | `8080` | Host port → container 8080; also the TG port |
| `keycloak_management_port` | `9000` | Host port → container 9000 (health/metrics) |
| `keycloak_env` | `{}` | See above |
| `keycloak_user_properties` | `{}` | See above |
| `keycloak_extra_args` | `[]` | See above |
| `keycloak_admin_username` | `admin` | Bootstrap admin |
| `keycloak_admin_password` | **required**, sensitive | ≥ 12 chars |
| `db_vendor` | `postgres` | `KC_DB` value |
| `db_url` | `null` | JDBC URL; null = embedded dev-file DB (**not for production**) |
| `db_username` | `keycloak` | |
| `db_password` | `""`, sensitive | |

Outputs: `launch_template_id`, `launch_template_latest_version`, `alb_dns_name`, `alb_zone_id`, `alb_arn`, `target_group_arn`, `alb_security_group_id`, `instance_security_group_id`, `instance_id`, `instance_private_ip`, `keycloak_url`, `effective_keycloak_env`.

### After apply

1. Create a **private Route 53 alias** for `keycloak_hostname` → `alb_dns_name`.
2. Make sure the private subnet has a **NAT gateway or VPC endpoints** (ssm, ssmmessages, ec2messages) — the instance must pull the Docker image and register with SSM.
3. Open `keycloak_url` from inside the network.

---

## 6. Building your own app on the modules

The examples follow a recipe you can copy for any workload:

1. **Look up an AMI** (SSM public parameter or a fixed id).
2. **Create security groups** — one per tier. Private tiers only trust the tier in front of them.
3. **Create an IAM role + instance profile** with `AmazonSSMManagedInstanceCore`.
4. **Write a user-data template** (`templates/user_data.sh.tftpl`) that installs and configures the app from Terraform variables. Use `%{ for k, v in map }` loops to turn maps into config files.
5. **Call `launch_template`** with the rendered script.
6. **Call `ec2_instance`** (single node) or wire the template into an Auto Scaling group (fleet).
7. Add a **load balancer** if the app is HTTP and needs TLS, health checks, or more than one node.

Minimal skeleton:

```hcl
locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    settings = var.app_settings   # map(string)
  })
}

module "lt" {
  source             = "../../launch_template"
  name               = var.name
  image_id           = data.aws_ssm_parameter.al2023.insecure_value
  instance_type      = var.instance_type
  subnet_id          = var.subnet_id
  security_group_ids = [aws_security_group.app.id]
  iam_instance_profile_name   = aws_iam_instance_profile.app.name
  associate_public_ip_address = false
  user_data          = local.user_data
}

module "server" {
  source                  = "../../ec2_instance"
  name                    = var.name
  launch_template_id      = module.lt.id
  launch_template_version = tostring(module.lt.latest_version)
}
```

---

## 7. Best practices and trade-offs

### Access

| Option | Pros | Cons |
|---|---|---|
| **SSM Session Manager** (default) | No open ports, no keys to rotate, audited in CloudTrail | Needs the SSM role and outbound reach to SSM endpoints |
| SSH with `key_name` + `enable_ssh` | Familiar, works without SSM | Port 22 exposed, key management burden |

### Networking

| Option | Pros | Cons |
|---|---|---|
| **Private subnet + internal ALB** (Keycloak) | No internet exposure, TLS at the LB, health checks, easy scale-out | Needs NAT/VPC endpoints, two subnets, more resources |
| Public IP on the instance (NiFi with `associate_public_ip_address = true`) | Simplest to reach | Instance directly reachable from the internet; only use with strict CIDRs |

### Storage

| Option | Pros | Cons |
|---|---|---|
| Separate data volume (`additional_volumes`) | Resize independently, `delete_on_termination = false` keeps data on rebuild | Must format/mount in user data |
| Everything on the root volume | Simpler | Data lost on instance replacement |

### Configuration changes

* Any change to the maps produces a **new launch template version**. Running instances are **not** re-configured — replace them (`-replace=`) or let an ASG roll them. Pros: immutable, reproducible, easy rollback. Cons: brief downtime for single-instance setups.
* Keep secrets out of `terraform.tfvars` in git: use `TF_VAR_nifi_single_user_password=…` environment variables, a secrets-backed tfvars, or read from AWS Secrets Manager with a `data` source.

### Databases (Keycloak)

The embedded dev-file store is fine for a first look but loses data on rebuild and can't be shared between nodes. Point `db_url` at RDS Postgres before anything real depends on it.

### Versioning

Pin `nifi_version` and `keycloak_image` to exact releases you've tested. Upgrading is then a deliberate change in tfvars, visible in `terraform plan`.

---

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| Instance never becomes healthy in the target group | `journalctl -u keycloak` via SSM; confirm `KC_HOSTNAME` matches the URL and the instance SG allows 9000 from the ALB SG |
| `docker pull` fails | Private subnet has no NAT/VPC endpoint route to the registry |
| NiFi UI unreachable | `/var/log/nifi-bootstrap.log`, then `/opt/nifi/logs/nifi-app.log`; confirm `nifi.web.proxy.host` includes the host:port you're using |
| Plan shows the instance replaced every time | You changed user data → new template version → expected. Use `"$Latest"` if you do *not* want Terraform to replace instances |
| `Error: lb_subnet_ids` validation | ALBs need two subnets in different AZs |
| Data disk empty after rebuild | `delete_on_termination` defaults to `true`; set it `false` on the data volume |
