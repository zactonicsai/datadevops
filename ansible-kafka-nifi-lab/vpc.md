# AWS VPC — Terraform + AWS CLI

A production-grade AWS Virtual Private Cloud (VPC) built with Terraform, plus a
matching AWS CLI script that creates the same network by hand. This README
explains what every file does, how to run it, and what each command means.

> **New to VPCs, subnets, or CIDR?** Open `../vpc-tutorial.html` first. It
> explains all the concepts from scratch at an easy reading level, with
> diagrams and links to the official 2026 AWS docs. This README assumes you
> just want to *run* the code.

---

## What this builds

A single VPC (`10.0.0.0/16`, 65,536 addresses) spread across **3 Availability
Zones** for failover, with four kinds of subnet in every zone:

| Tier | Size | Usable IPs | What lives here |
|------|------|-----------:|-----------------|
| **public** | `/24` | 251 | Load balancers, NAT gateways, bastion — the only internet-facing layer |
| **private — small** | `/27` | 27 | Bastions, small tools |
| **private — medium** | `/24` | 251 | Java/Node web apps, backend APIs, NiFi |
| **private — large** | `/20` | 4,091 | Kafka/MSK, Postgres/RDS, OpenSearch — stateful, growth-heavy |

The exact, verified-non-overlapping address plan:

```
public   10.0.0.0/24    10.0.1.0/24     10.0.2.0/24
medium   10.0.8.0/24    10.0.9.0/24     10.0.10.0/24
small    10.0.16.0/27   10.0.16.32/27   10.0.16.64/27
large    10.0.64.0/20   10.0.80.0/20    10.0.96.0/20
```

It also creates: an internet gateway, NAT gateways (one per AZ by default),
route tables, an S3 gateway endpoint, interface (PrivateLink) endpoints for
SQS/SNS/Kafka/OpenSearch/KMS/Secrets Manager/ECR/SSM/CloudWatch, a data-tier
network ACL, three tiered security groups (ALB → app → data), and VPC flow logs
to CloudWatch with 90-day retention.

---

## Prerequisites

- **An AWS account** and credentials configured locally. The quickest way:
  run `aws configure` (AWS CLI v2) and enter an access key, secret, and region.
  Terraform reads the same credentials automatically.
- **Terraform ≥ 1.9** — download from <https://developer.hashicorp.com/terraform/install>.
  Check with `terraform version`.
- For the shell script only: **AWS CLI v2** and **`jq`** installed.
- **Permissions:** the credentials need to create VPC, EC2, IAM, and CloudWatch
  Logs resources. An admin-level role is simplest for a first run; tighten later.

> **Cost warning.** NAT gateways and interface endpoints are *not* free — they
> bill per hour plus per GB of data. A multi-AZ deployment runs three of each.
> For learning or dev, set `single_nat_gateway = true` to cut that to one.
> Always run `terraform destroy` (or the CLI teardown) when you're done.

---

## File guide

### Terraform files

| File | What it does |
|------|--------------|
| `main.tf` | Declares the required Terraform version, pins the AWS provider to the v6 major line (`~> 6.0`), and sets `default_tags` (Project, Environment, ManagedBy, Owner) applied to every resource. |
| `variables.tf` | Every input you can tune, with sensible defaults and inline docs. Holds the **CIDR sizing strategy** — the `private_tier_newbits` object that decides the small/medium/large sizes. |
| `vpc.tf` | The network itself: VPC, internet gateway, all four subnet tiers, EIPs, NAT gateways, route tables, and their associations. Contains the `locals` block that does the `cidrsubnet()` math. |
| `security.tf` | The S3 gateway endpoint, the interface endpoints, the data-tier NACL, the three tiered security groups, and the flow-logs setup (log group + IAM role + flow log). |
| `outputs.tf` | What the stack prints after apply: the VPC ID, all subnet IDs by tier, a human-readable `subnet_cidr_plan`, NAT gateway IDs, and the security-group IDs. Other Terraform modules can consume these. |
| `terraform.tfvars.example` | A ready-to-edit sample of all the variable values. Copy it to `terraform.tfvars` to customize. |

### Shell script

| File | What it does |
|------|--------------|
| `aws-cli-equivalent.sh` | Builds the **same** network using only AWS CLI v2. Each numbered section is annotated with the Terraform resource it replaces (e.g. `# 1. CREATE THE VPC (= aws_vpc.main)`). It's a *learning aid* — for real infrastructure use Terraform, which tracks state and detects drift. |

---

## How to run the Terraform

From inside this `terraform-vpc/` directory:

```bash
# 1. (Optional) Customize values. Defaults work out of the box.
cp terraform.tfvars.example terraform.tfvars
#    then edit terraform.tfvars in your editor

# 2. Download the AWS provider and set up the working directory.
terraform init

# 3. Catch syntax/logic errors before touching AWS. Free, no resources made.
terraform validate

# 4. Preview EXACTLY what will be created. Read this before applying.
terraform plan

# 5. Build it. Terraform prints the plan again and asks you to type "yes".
terraform apply

# 6. When you're done, tear everything down to stop billing.
terraform destroy
```

### What each Terraform command means

- **`terraform init`** — reads `main.tf`, downloads the AWS provider plugin into
  a local `.terraform/` folder, and prepares the backend. Run it once per
  checkout, and again whenever you change provider versions.
- **`terraform validate`** — checks that your `.tf` files are syntactically
  valid and internally consistent. It does *not* contact AWS, so it's instant
  and free. Great first gate.
- **`terraform plan`** — compares your code against the real world and prints a
  diff: every resource it will **+ add**, **~ change**, or **− destroy**.
  Nothing is changed yet. Always read this carefully — it's your safety check.
- **`terraform apply`** — executes the plan and actually creates/updates AWS
  resources. It shows the plan again and waits for you to type `yes`. To skip
  the prompt in automation, use `terraform apply -auto-approve` (be careful).
- **`terraform destroy`** — deletes everything this configuration created.
  This is how you stop paying for NAT gateways and endpoints. It also asks for
  `yes` confirmation.

### Reading the outputs

After `apply`, Terraform prints the values from `outputs.tf`. You can reprint
them any time, or pull a single one:

```bash
terraform output                      # show all outputs
terraform output subnet_cidr_plan     # show just the CIDR plan
terraform output -raw vpc_id          # raw value, handy for scripts
```

Feed these into other stacks — e.g. give `private_large_subnet_ids` to an RDS
or MSK module so your database and Kafka brokers land in the large tier.

### Common tweaks

All of these live in `terraform.tfvars` (or as `-var` flags):

```bash
# Cheaper dev run: one shared NAT gateway instead of three.
single_nat_gateway = true

# Deploy to a different region (remember to change the AZ list too).
aws_region         = "eu-west-1"
availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

# Resize a tier — e.g. give "medium" a /23 (512 IPs) by adding 7 bits.
private_tier_newbits = { small = 11, medium = 7, large = 4 }
```

You can also pass a variable inline without editing files:

```bash
terraform apply -var="single_nat_gateway=true"
```

---

## How to run the shell script

The script mirrors the Terraform build with raw AWS CLI calls. Use it to *see*
the underlying API calls, not to manage production.

```bash
# Make sure the AWS CLI is configured and jq is installed first.
aws configure          # one-time, if you haven't already
jq --version           # confirm jq is present

# Read it top to bottom — it's heavily commented and worth studying.
less aws-cli-equivalent.sh

# Run the whole thing (set -euo pipefail means it stops on any error).
bash aws-cli-equivalent.sh
```

### What the script does, section by section

1. **Create the VPC** (`= aws_vpc.main`) — `aws ec2 create-vpc`, then enables
   DNS support and DNS hostnames.
2. **Internet gateway** (`= aws_internet_gateway.main`) — creates the IGW and
   attaches it to the VPC.
3. **Subnets** (`= aws_subnet.*`) — creates all four tiers across the 3 AZs
   using the same verified CIDR plan shown above.
4. **NAT gateways** (`= aws_eip.nat` + `aws_nat_gateway.main`) — allocates an
   Elastic IP per AZ and places a NAT gateway in each public subnet.
5. **Route tables** (`= aws_route_table.*` + associations) — public table
   routes `0.0.0.0/0` to the IGW; private tables route outbound through NAT.
6. **S3 gateway endpoint** (`= aws_vpc_endpoint.s3`) — the free gateway
   endpoint so S3 traffic skips the internet.
7. **Security groups** (`= aws_security_group.alb/.app/.data`) — the tiered
   firewalls, where each tier allows traffic from the tier above it by
   security-group reference (not hardcoded IPs).

### Tearing down the CLI build

The script does **not** auto-delete. A commented teardown block at the bottom
shows the reverse-order deletes (NAT gateways → subnets → detach/delete IGW →
route tables → finally `aws ec2 delete-vpc`). Uncomment and run those, or delete
the VPC from the AWS console. Deleting in the wrong order fails because
resources are still attached — always remove dependents first.

---

## Terraform vs. the shell script — which should I use?

**Use Terraform for anything real.** It records what it created in a *state
file*, so it can update in place, detect drift, and cleanly destroy. The shell
script has none of that — re-running it creates duplicates, and cleanup is
manual. The script exists purely to teach you which AWS API calls sit behind
each Terraform resource.

---

## Troubleshooting

- **`terraform: command not found`** — Terraform isn't installed or isn't on
  your PATH. Install it from the link in Prerequisites.
- **`Error: configuring Terraform AWS Provider … no valid credential sources`**
  — run `aws configure`, or set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  environment variables.
- **`UnauthorizedOperation` / `AccessDenied`** — your IAM user/role lacks a
  permission the stack needs (VPC, EC2, IAM, or CloudWatch Logs). Add the
  missing permission or use a broader role for the first run.
- **`AddressLimitExceeded` on apply** — you've hit the Elastic IP limit for the
  account (NAT gateways each need one). Release unused EIPs or request a limit
  increase.
- **The script errors partway through** — because of `set -e` it stops on the
  first failure, which can leave half-built resources. Delete them (console or
  the teardown block) before re-running.
- **Unexpected charges** — almost always NAT gateways or interface endpoints
  left running. `terraform destroy` removes them; confirm in the AWS console
  that nothing lingers.

---

## Official references (2026)

- VPC User Guide — <https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html>
- Terraform AWS provider — <https://registry.terraform.io/providers/hashicorp/aws/latest/docs>
- `cidrsubnet()` function — <https://developer.hashicorp.com/terraform/language/functions/cidrsubnet>
- VPC endpoints / PrivateLink — <https://docs.aws.amazon.com/vpc/latest/privatelink/concepts.html>
- VPC Flow Logs — <https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html>
- AWS CLI v2 reference — <https://docs.aws.amazon.com/cli/latest/reference/ec2/>
