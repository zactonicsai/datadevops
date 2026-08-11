# AWS Terraform Tutorial — From LEGO Instructions to Real Kafka, NiFi, Postgres, Load Balancers, and Multi-Tenant EKS

**Audience:** Beginner to intermediate AWS learners.  
**Reading level:** Middle school language, but with real engineering detail.  
**Goal:** Teach how to read Terraform, understand the AWS infrastructure it creates, and build a practical example for data platforms and Kubernetes.

> **Cost warning:** This tutorial describes real AWS resources. EC2 instances, NAT Gateways, Load Balancers, EKS clusters, and RDS databases cost money. Use a sandbox AWS account, set an AWS Budget, and destroy resources when finished.

---

## Table of Contents

1. [The Big Idea](#1-the-big-idea)
2. [Terraform Basics](#2-terraform-basics)
3. [The Three-Step Dance: init, plan, apply](#3-the-three-step-dance-init-plan-apply)
4. [The Terraform State File](#4-the-terraform-state-file)
5. [Declarative Means “Tell Terraform the Finish Line”](#5-declarative-means-tell-terraform-the-finish-line)
6. [How to Read a `.tf` File](#6-how-to-read-a-tf-file)
7. [CIDR Network Numbers Explained Plainly](#7-cidr-network-numbers-explained-plainly)
8. [Every Important Terraform Block Type](#8-every-important-terraform-block-type)
9. [Common Terraform Arguments and Keywords](#9-common-terraform-arguments-and-keywords)
10. [Tags Deep Dive](#10-tags-deep-dive)
11. [AWS Infrastructure We Are Building](#11-aws-infrastructure-we-are-building)
12. [VPC, Subnets, Routes, NAT, and Security Groups](#12-vpc-subnets-routes-nat-and-security-groups)
13. [Kafka on EC2](#13-kafka-on-ec2)
14. [NiFi on EC2](#14-nifi-on-ec2)
15. [Postgres on EC2 and the RDS Alternative](#15-postgres-on-ec2-and-the-rds-alternative)
16. [Load Balancers: ALB, Target Group, Listener, Health Check](#16-load-balancers-alb-target-group-listener-health-check)
17. [EKS Cluster: Kubernetes on AWS](#17-eks-cluster-kubernetes-on-aws)
18. [Multi-Tenant EKS Deep Dive](#18-multi-tenant-eks-deep-dive)
19. [Dedicated Worker Pools, Taints, and Tolerations](#19-dedicated-worker-pools-taints-and-tolerations)
20. [Pro File Structure](#20-pro-file-structure)
21. [Backend Block and Remote State](#21-backend-block-and-remote-state)
22. [Outputs](#22-outputs)
23. [Full Command Workflow](#23-full-command-workflow)
24. [Recap](#24-recap)
25. [One-Page Glossary](#25-one-page-glossary)
26. [Official References](#26-official-references)

---

## 1. The Big Idea

Terraform is like a **LEGO instruction sheet for cloud infrastructure**.

Instead of clicking around the AWS Console, you write files that say:

- I want a network.
- I want public and private subnets.
- I want EC2 servers.
- I want Kafka, NiFi, and Postgres servers.
- I want a load balancer.
- I want an EKS Kubernetes cluster.
- I want teams separated inside that EKS cluster.

Terraform reads your files and asks AWS to build the pieces.

### Why teams use Terraform

Terraform helps a cloud team:

- Build the same thing again and again.
- Review infrastructure changes before they happen.
- Store infrastructure code in Git.
- Track who changed what.
- Avoid “mystery clicking” in the AWS Console.
- Rebuild environments after mistakes or disasters.

### The simple mental model

Think of Terraform like this:

| Real World | Terraform Meaning |
|---|---|
| LEGO instruction book | `.tf` files |
| LEGO bricks | AWS resources |
| Finished LEGO castle picture | Desired infrastructure |
| Checking the instructions | `terraform plan` |
| Building the castle | `terraform apply` |
| Box label saying what was built | Terraform state file |

---

## 2. Terraform Basics

Terraform is an **Infrastructure as Code** tool.

That means cloud infrastructure is written like code.

A normal app developer writes code like this:

```java
User user = new User();
```

A cloud engineer writes Terraform like this:

```hcl
resource "aws_instance" "nifi" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.large"
  subnet_id     = aws_subnet.private["us-east-1a"].id

  tags = {
    Name = "demo-nifi"
  }
}
```

This says:

> “AWS, please create one EC2 server for NiFi.”

### Terraform file names

Terraform files usually end in `.tf`.

Examples:

```text
versions.tf
providers.tf
variables.tf
network.tf
security_groups.tf
eks.tf
outputs.tf
```

Terraform reads all `.tf` files in the same folder together. The file names are mostly for humans. Terraform cares about the blocks inside them.

---

## 3. The Three-Step Dance: init, plan, apply

Terraform usually uses three main commands.

### Step 1: `terraform init`

This prepares the folder.

It downloads provider plugins, such as the AWS provider.

```bash
terraform init
```

Middle school meaning:

> “Terraform, get your tools ready.”

### Step 2: `terraform plan`

This shows what Terraform wants to create, change, or destroy.

```bash
terraform plan
```

Middle school meaning:

> “Terraform, show me the shopping list before you buy anything.”

### Step 3: `terraform apply`

This makes the changes in AWS.

```bash
terraform apply
```

Middle school meaning:

> “Terraform, build it now.”

### Bonus: `terraform destroy`

This deletes what Terraform created.

```bash
terraform destroy
```

Middle school meaning:

> “Terraform, take the LEGO castle apart.”

---

## 4. The Terraform State File

Terraform needs to remember what it built.

It stores that memory in a **state file**.

The default file is:

```text
terraform.tfstate
```

The state file connects your Terraform code to real AWS resources.

Example:

```text
Terraform name: aws_instance.nifi
Real AWS ID:    i-0123456789abcdef0
```

### Why state matters

Without state, Terraform would not know:

- Which EC2 instance belongs to this code.
- Which VPC it created.
- Which load balancer it owns.
- Whether to create a new thing or update an old thing.

### State file safety

The state file can contain sensitive information. For a team, do **not** keep it only on one laptop.

Use a remote backend such as:

- S3 bucket for storing state.
- DynamoDB table for locking state so two people do not change infrastructure at the same time.

---

## 5. Declarative Means “Tell Terraform the Finish Line”

Terraform is mostly **declarative**.

Declarative means:

> You describe the final result you want. Terraform figures out the steps.

Example:

```hcl
resource "aws_instance" "kafka" {
  count         = 3
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.large"
}
```

You do **not** write:

1. Click EC2.
2. Choose AMI.
3. Choose size.
4. Launch server.
5. Repeat 3 times.

You write:

> “I want 3 Kafka EC2 servers.”

Terraform figures out the AWS API calls.

---

## 6. How to Read a `.tf` File

Most Terraform blocks have the same shape.

```hcl
block_type "label_1" "label_2" {
  argument_name = argument_value

  nested_block {
    nested_argument = nested_value
  }
}
```

### Universal block shape

Example:

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "demo-vpc"
  }
}
```

Read it like this:

| Part | Meaning |
|---|---|
| `resource` | Terraform will create or manage something. |
| `aws_vpc` | The AWS resource type. |
| `main` | The local nickname inside Terraform. |
| `{ ... }` | The settings for that resource. |
| `cidr_block` | The IP address range for the VPC. |
| `tags` | Labels added to the AWS resource. |

### The secret-handshake referencing pattern

Terraform resources can point to each other.

Pattern:

```hcl
resource_type.local_name.attribute
```

Example:

```hcl
vpc_id = aws_vpc.main.id
```

Read it as:

> “Use the ID from the VPC resource named `main`.”

Another example:

```hcl
subnet_id = aws_subnet.private["us-east-1a"].id
```

Read it as:

> “Use the ID from the private subnet in Availability Zone `us-east-1a`.”

### Comments

Comments are notes for humans.

Terraform ignores them.

```hcl
# This is a one-line comment.

// This is also a one-line comment.

/*
This is a multi-line comment.
*/
```

---

## 7. CIDR Network Numbers Explained Plainly

CIDR looks scary, but it is just a way to describe a group of IP addresses.

Example:

```text
10.0.0.0/16
```

Think of it like a neighborhood.

- `10.0.0.0` is the start of the neighborhood.
- `/16` tells how big the neighborhood is.

### Common CIDR sizes

| CIDR | Approx Size | Simple Meaning |
|---|---:|---|
| `/16` | About 65,000 IPs | Big VPC network |
| `/20` | About 4,000 IPs | Good subnet size |
| `/24` | About 250 IPs | Small subnet |
| `/32` | 1 IP | One exact computer |

### Example layout

```text
VPC:            10.0.0.0/16
Public subnet:  10.0.1.0/24
Public subnet:  10.0.2.0/24
Private subnet: 10.0.11.0/24
Private subnet: 10.0.12.0/24
```

### Public vs private subnet

A **public subnet** has a route to the internet through an Internet Gateway.

A **private subnet** does not let the internet start a connection to its servers. Private servers can still go out to download updates if they use a NAT Gateway.

---

## 8. Every Important Terraform Block Type

Terraform has several block types. These are the ones you will see every day.

### 1. `terraform` block

This configures Terraform itself.

```hcl
terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

Meaning:

- `required_version` says which Terraform version is allowed.
- `required_providers` says which plugins are needed.
- `source = "hashicorp/aws"` means use the official AWS provider.
- `version = "~> 6.0"` means use AWS provider version 6.x, not 7.x.

### 2. `provider` block

This tells Terraform how to talk to AWS.

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
```

Meaning:

- `provider "aws"` says “Use AWS.”
- `region` says which AWS region, such as `us-east-1`.
- `default_tags` adds common tags to supported AWS resources.

### 3. `resource` block

This creates or manages a real thing.

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}
```

Meaning:

- Create an AWS VPC.
- Locally call it `main`.
- Use the CIDR value from `var.vpc_cidr`.

### 4. `data` block

This reads something that already exists.

```hcl
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
```

Meaning:

> “Find the latest Amazon Linux 2023 AMI from AWS.”

A data block does not create the AMI. It looks it up.

### 5. `variable` block

This lets users pass values into Terraform.

```hcl
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}
```

Meaning:

- `description` explains the variable.
- `type` says what kind of value it accepts.
- `default` gives a value if the user does not provide one.

### Other common blocks you need

Terraform has more than five useful block types. These are also very common.

#### `output` block

Shows important results after apply.

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}
```

#### `locals` block

Creates reusable helper values.

```hcl
locals {
  name_prefix = "demo-data-platform"
}
```

#### `module` block

Calls reusable Terraform code.

```hcl
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
}
```

This tutorial uses mostly raw resources so you can learn what is happening.

---

## 9. Common Terraform Arguments and Keywords

### `ami`

Used by EC2 instances.

```hcl
ami = data.aws_ami.amazon_linux_2023.id
```

An AMI is like a computer image. It says what operating system the server starts with.

### `instance_type`

Used by EC2 instances.

```hcl
instance_type = "t3.large"
```

This is the server size.

Small example:

- `t3.micro`: tiny test server.
- `t3.large`: larger test server.
- `m7i.large`: general purpose newer generation.
- `r7i.large`: memory-focused.

Kafka, NiFi, and Postgres need more memory than a tiny web server.

### `count`

Creates a number of copies.

```hcl
resource "aws_instance" "kafka" {
  count = 3
}
```

This creates:

```text
aws_instance.kafka[0]
aws_instance.kafka[1]
aws_instance.kafka[2]
```

Use `count` when the items are mostly the same.

### `count.index`

This gives the copy number.

```hcl
Name = "kafka-${count.index + 1}"
```

Output:

```text
kafka-1
kafka-2
kafka-3
```

### `for_each`

Creates one copy for each item in a map or set.

```hcl
resource "aws_subnet" "private" {
  for_each = local.private_subnets_by_az

  availability_zone = each.key
  cidr_block        = each.value
}
```

If the map is:

```hcl
{
  "us-east-1a" = "10.0.11.0/24"
  "us-east-1b" = "10.0.12.0/24"
}
```

Terraform creates:

```text
aws_subnet.private["us-east-1a"]
aws_subnet.private["us-east-1b"]
```

Use `for_each` when each item has a name.

### `each.key` and `each.value`

Inside `for_each`:

- `each.key` is the item name.
- `each.value` is the item value.

### `depends_on`

Terraform usually figures out order by references.

Example:

```hcl
subnet_id = aws_subnet.private["us-east-1a"].id
```

This automatically tells Terraform:

> “Create the subnet before the EC2 instance.”

Sometimes you need to be extra clear.

```hcl
depends_on = [aws_internet_gateway.main]
```

Use `depends_on` only when Terraform cannot figure it out from references.

### `lifecycle`

Controls special behavior.

```hcl
lifecycle {
  prevent_destroy = true
}
```

This means:

> “Do not destroy this by accident.”

Common lifecycle settings:

| Setting | Meaning |
|---|---|
| `prevent_destroy` | Stops accidental deletion. |
| `create_before_destroy` | Creates replacement before deleting old one. |
| `ignore_changes` | Ignore changes to selected arguments. |

Example:

```hcl
lifecycle {
  ignore_changes = [desired_size]
}
```

This is useful if an autoscaler changes the desired node count.

### `user_data`

A startup script for an EC2 instance.

```hcl
user_data = file("${path.module}/user_data/nifi.sh")
```

Middle school meaning:

> “When the server boots, run this setup script.”

### `templatefile()`

Loads a file and fills in blanks.

```hcl
user_data = templatefile("${path.module}/user_data/kafka.sh", {
  broker_id = count.index + 1
})
```

### `file()`

Reads a local file.

```hcl
user_data = file("${path.module}/user_data/postgres.sh")
```

### `path.module`

The current Terraform folder.

```hcl
"${path.module}/user_data/nifi.sh"
```

This avoids hardcoding your laptop path.

### `sensitive`

Hides a value in CLI output.

```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```

Important: `sensitive` does not magically remove the value from state. Protect your state file.

### `validation`

Checks variable input.

```hcl
variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be dev, test, or prod."
  }
}
```

### `dynamic` block

Creates nested blocks from a list or map.

You will see this in advanced modules. For beginners, avoid it until you are comfortable.

### `locals`

Use locals to avoid repeating yourself.

```hcl
locals {
  name_prefix = "${var.project}-${var.environment}"
}
```

### `merge()`

Combines maps.

```hcl
tags = merge(local.common_tags, {
  Name = "${local.name_prefix}-vpc"
})
```

If both maps have the same key, the later map wins.

---

## 10. Tags Deep Dive

Tags are labels on AWS resources.

Example:

```hcl
tags = {
  Name        = "demo-vpc"
  Environment = "dev"
  Owner       = "cloud-team"
  CostCenter  = "training"
}
```

### The four tag superpowers

#### Superpower 1: Finding things

Tags make it easier to search AWS.

Example:

```text
Show me all resources where Project = data-platform
```

#### Superpower 2: Cost tracking

Tags help answer:

> “Which team is spending money?”

Example:

```hcl
CostCenter = "analytics"
```

#### Superpower 3: Automation

Scripts can find resources by tag.

Example:

```text
Stop all dev EC2 instances at night.
```

#### Superpower 4: Security and ownership

Tags can show who owns a system.

Example:

```hcl
Owner = "platform-team"
DataClassification = "internal"
```

### The special `Name` tag

AWS often shows the `Name` tag in the console.

```hcl
tags = {
  Name = "demo-kafka-1"
}
```

This does not usually change the real AWS resource ID. It is a human-friendly label.

### `default_tags`

In the AWS provider, you can set tags once and apply them to many supported resources.

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
```

### The `locals + merge()` pattern

This is a very useful pattern.

```hcl
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}
```

Read it like this:

> “Use the common tags everywhere, but add a special Name tag for this resource.”

---

## 11. AWS Infrastructure We Are Building

This tutorial project creates a data platform style environment.

### Main AWS pieces

```text
AWS Region
└── VPC 10.0.0.0/16
    ├── Public Subnets
    │   ├── Internet Gateway
    │   ├── NAT Gateway
    │   └── Application Load Balancer
    │
    ├── Private Subnets
    │   ├── Kafka EC2 Broker 1
    │   ├── Kafka EC2 Broker 2
    │   ├── Kafka EC2 Broker 3
    │   ├── NiFi EC2 Server
    │   ├── Postgres EC2 Server
    │   ├── Optional RDS Postgres
    │   └── EKS Worker Nodes
    │
    └── EKS Cluster
        ├── Platform node group
        ├── Tenant A node group
        ├── Tenant B node group
        ├── Namespaces
        ├── Resource quotas
        ├── Limit ranges
        ├── RBAC roles
        └── Network policies
```

### Why this shape?

Data systems often need:

- Kafka for messages/events.
- NiFi for moving and transforming data.
- Postgres for relational storage.
- EKS for containerized applications.
- Load balancers for traffic routing.
- Network isolation for safety.
- Tags for cost and ownership.
- Remote state for team workflow.

---

## 12. VPC, Subnets, Routes, NAT, and Security Groups

### VPC

A VPC is your private AWS network.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}
```

Plain meaning:

> “Create a private network named demo-data-platform-vpc.”

### Subnets

A subnet is a smaller section of the VPC.

Public subnets hold things that need internet-facing access, such as public load balancers.

Private subnets hold servers and EKS nodes.

```hcl
resource "aws_subnet" "private" {
  for_each = local.private_subnets_by_az

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}
```

Plain meaning:

> “For each private subnet in my map, create a subnet in that Availability Zone.”

### Internet Gateway

An Internet Gateway lets public subnets talk to the internet.

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}
```

### NAT Gateway

A NAT Gateway lets private servers reach the internet for updates, but the internet cannot start a connection back to those private servers.

Example use:

- Kafka server downloads patches.
- EKS worker node pulls container images.
- NiFi downloads packages.

### Route Table

A route table is like a road sign.

It tells traffic where to go.

Example:

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

Meaning:

> “For internet traffic, go through the Internet Gateway.”

### Security Group

A security group is a virtual firewall.

Example:

```hcl
resource "aws_security_group" "alb" {
  name   = "${local.name_prefix}-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Meaning:

- Allow web traffic on port 80 from the internet.
- Allow outbound traffic.

Important ports:

| System | Port | Purpose |
|---|---:|---|
| HTTP | 80 | Web traffic |
| HTTPS | 443 | Secure web traffic |
| Kafka | 9092 | Kafka client traffic |
| NiFi demo | 8080 | NiFi web UI demo |
| NiFi secure | 8443 | NiFi secure UI |
| Postgres | 5432 | Database traffic |
| Kubernetes API | 443 | EKS control plane API |

---

## 13. Kafka on EC2

Kafka is a message system.

Middle school analogy:

> Kafka is like a school mailbox system. One app drops messages into a topic. Other apps pick messages up later.

### Why 3 Kafka brokers?

Kafka usually runs as a cluster.

A broker is one Kafka server.

Three brokers help with:

- Availability.
- Replication.
- Surviving one server failure.

### Terraform example

```hcl
resource "aws_instance" "kafka" {
  count = var.kafka_broker_count

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.kafka_instance_type
  subnet_id              = element([for subnet in aws_subnet.private : subnet.id], count.index)
  vpc_security_group_ids = [aws_security_group.data_services.id]

  user_data = templatefile("${path.module}/user_data/kafka.sh", {
    broker_id = count.index + 1
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-kafka-${count.index + 1}"
    Role = "kafka-broker"
  })
}
```

### How to read it

- `count = var.kafka_broker_count` creates multiple brokers.
- `ami` chooses the operating system image.
- `instance_type` chooses server size.
- `subnet_id` places the broker in a private subnet.
- `vpc_security_group_ids` attaches firewall rules.
- `user_data` runs setup commands on first boot.
- `tags` labels the instance.

### Real production note

Running Kafka yourself on EC2 gives you control, but you own more work:

- Patching.
- Monitoring.
- Disk management.
- Broker replacement.
- Security hardening.
- Backups and disaster recovery.

For production, also evaluate Amazon MSK, the managed Kafka service.

---

## 14. NiFi on EC2

NiFi moves data from place to place.

Middle school analogy:

> NiFi is like a set of conveyor belts in a grocery warehouse. It picks up data boxes, checks them, changes them, and sends them to the next place.

Example uses:

- Read files from S3.
- Send messages to Kafka.
- Read from Postgres.
- Call APIs.
- Route bad records to an error queue.

### Terraform example

```hcl
resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.nifi_instance_type
  subnet_id              = values(aws_subnet.private)[0].id
  vpc_security_group_ids = [aws_security_group.data_services.id]
  user_data              = file("${path.module}/user_data/nifi.sh")

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-nifi"
    Role = "nifi"
  })
}
```

### Production note

For real production NiFi:

- Use TLS.
- Use authentication.
- Store flow files on durable disks.
- Use multiple NiFi nodes if high availability is required.
- Monitor disk usage carefully.
- Avoid exposing the NiFi UI directly to the internet.

---

## 15. Postgres on EC2 and the RDS Alternative

Postgres is a relational database.

Middle school analogy:

> Postgres is like a very organized spreadsheet system with rules, indexes, users, and backups.

### Postgres on EC2

You can install Postgres directly on an EC2 server.

```hcl
resource "aws_instance" "postgres" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.postgres_instance_type
  subnet_id              = values(aws_subnet.private)[1].id
  vpc_security_group_ids = [aws_security_group.data_services.id]
  user_data              = templatefile("${path.module}/user_data/postgres.sh", {
    db_password = var.db_password
  })

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-postgres-ec2"
    Role = "postgres"
  })
}
```

### Pros of Postgres on EC2

- Full control.
- Can install custom extensions.
- Can tune the operating system.
- Can follow strict custom patch rules.

### Cons of Postgres on EC2

- You manage backups.
- You manage patching.
- You manage failover.
- You manage disk growth.
- You must test restores.

### RDS alternative

RDS is AWS-managed relational database service.

```hcl
resource "aws_db_instance" "postgres" {
  identifier             = "${local.name_prefix}-postgres-rds"
  engine                 = "postgres"
  instance_class         = var.rds_instance_class
  allocated_storage      = 50
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.data_services.id]
  username               = var.db_username
  password               = var.db_password
  skip_final_snapshot    = true
}
```

### EC2 vs RDS trade-off

| Choice | Best When | Main Trade-Off |
|---|---|---|
| Postgres on EC2 | You need deep OS control or unusual extensions. | You own more operations work. |
| RDS Postgres | You want AWS to handle backups, patching, recovery, and common database admin tasks. | Less OS-level control. |

---

## 16. Load Balancers: ALB, Target Group, Listener, Health Check

A load balancer is a traffic director.

Middle school analogy:

> A load balancer is like a school front desk. Visitors come to one front desk, and the desk sends each person to the right classroom.

### ALB

ALB means Application Load Balancer.

It works well for HTTP and HTTPS web traffic.

```hcl
resource "aws_lb" "nifi" {
  name               = "${local.short_name}-nifi-alb"
  load_balancer_type = "application"
  subnets            = [for subnet in aws_subnet.public : subnet.id]
  security_groups    = [aws_security_group.alb.id]
}
```

### Target Group

A target group is the list of places the ALB can send traffic.

```hcl
resource "aws_lb_target_group" "nifi" {
  name     = "${local.short_name}-nifi-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/nifi"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}
```

### Listener

A listener waits for traffic on a port.

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.nifi.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nifi.arn
  }
}
```

### Health Check

A health check asks:

> “Is this server healthy enough to receive traffic?”

If health checks fail, the load balancer stops sending traffic to that target.

---

## 17. EKS Cluster: Kubernetes on AWS

EKS means Elastic Kubernetes Service.

Kubernetes runs containers.

Middle school analogy:

> Kubernetes is like a school principal for containers. It decides where each classroom activity should happen, checks if it is healthy, and replaces it if it breaks.

### EKS has two big parts

| Part | Meaning |
|---|---|
| Control plane | AWS-managed Kubernetes brain. |
| Worker nodes | EC2 servers that run your pods. |

### EKS cluster Terraform example

```hcl
resource "aws_eks_cluster" "main" {
  name     = local.name_prefix
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = [for subnet in aws_subnet.private : subnet.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }
}
```

### Managed node group

```hcl
resource "aws_eks_node_group" "platform" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-platform"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [for subnet in aws_subnet.private : subnet.id]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 5
  }

  instance_types = ["m7i.large"]
}
```

### Why IAM roles are needed

EKS needs IAM permissions.

- The cluster role lets the EKS control plane manage AWS resources it needs.
- The node role lets EC2 worker nodes join the cluster and pull container images.

---

## 18. Multi-Tenant EKS Deep Dive

Multi-tenant means multiple teams, applications, or customers share one EKS cluster.

### Apartment-building analogy

Imagine one big apartment building.

- The building is the EKS cluster.
- Each apartment is a namespace.
- The front desk rules are RBAC.
- The utility limits are resource quotas.
- The walls between apartments are network policies.
- Special reserved floors are dedicated node groups.

### The real-world problem it solves

Without multi-tenancy, a company may create many clusters.

Example:

```text
Team 1 cluster
Team 2 cluster
Team 3 cluster
...
Team 15 cluster
```

That can create problems:

- Higher cost.
- More upgrades.
- More security policies to repeat.
- More monitoring setups.
- More cluster add-ons to manage.
- More GitLab/GitHub pipelines.
- More IAM roles.
- More duplicated work.

With one shared cluster:

```text
One EKS cluster
├── namespace team-a
├── namespace team-b
├── namespace team-c
└── namespace platform
```

You can reduce repeated work.

But there is a warning:

> Sharing a cluster is only safe if you build guardrails.

### The four core tools

This tutorial builds four tenant tools in Terraform.

#### Tool 1: Namespaces

A namespace is like a room inside the cluster.

```hcl
resource "kubernetes_namespace_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name = each.key

    labels = {
      tenant = each.key
    }
  }
}
```

#### Tool 2: ResourceQuota and LimitRange

A ResourceQuota says how much a namespace can use.

```hcl
resource "kubernetes_resource_quota_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "tenant-quota"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.quota_requests_cpu
      "requests.memory" = each.value.quota_requests_memory
      "limits.cpu"      = each.value.quota_limits_cpu
      "limits.memory"   = each.value.quota_limits_memory
      "pods"            = each.value.quota_pods
    }
  }
}
```

Plain meaning:

> “Team A cannot use the whole cluster by accident.”

A LimitRange sets default request and limit values for containers.

```hcl
resource "kubernetes_limit_range_v1" "tenant" {
  for_each = var.tenants

  metadata {
    name      = "tenant-default-limits"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  spec {
    limit {
      type = "Container"

      default = {
        cpu    = each.value.default_cpu_limit
        memory = each.value.default_memory_limit
      }

      default_request = {
        cpu    = each.value.default_cpu_request
        memory = each.value.default_memory_request
      }
    }
  }
}
```

#### Tool 3: RBAC

RBAC means Role-Based Access Control.

Middle school analogy:

> RBAC is like school permission slips. A student may enter their classroom, but not the principal’s office.

```hcl
resource "kubernetes_role_v1" "tenant_admin" {
  for_each = var.tenants

  metadata {
    name      = "tenant-admin"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  rule {
    api_groups = ["", "apps", "batch", "networking.k8s.io"]
    resources  = ["pods", "services", "deployments", "jobs", "cronjobs", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}
```

A RoleBinding attaches the role to a group.

```hcl
resource "kubernetes_role_binding_v1" "tenant_admin" {
  for_each = var.tenants

  metadata {
    name      = "tenant-admin-binding"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = each.value.admin_group
    api_group = "rbac.authorization.k8s.io"
  }

  role_ref {
    kind      = "Role"
    name      = kubernetes_role_v1.tenant_admin[each.key].metadata[0].name
    api_group = "rbac.authorization.k8s.io"
  }
}
```

#### Tool 4: NetworkPolicy

NetworkPolicy controls pod-to-pod traffic.

Middle school analogy:

> NetworkPolicy is like hallway rules. Students can visit approved rooms, but cannot wander everywhere.

Default deny policy:

```hcl
resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = var.tenants

  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.tenant[each.key].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}
```

This says:

> “By default, do not allow incoming pod traffic in this namespace unless another policy allows it.”

### Important EKS note

NetworkPolicy needs a network plugin that enforces NetworkPolicy. Do not assume policy objects work until you confirm your EKS networking add-on supports and enforces them.

---

## 19. Dedicated Worker Pools, Taints, and Tolerations

Some tenants need their own worker nodes.

Reasons:

- Security separation.
- Noisy workload isolation.
- Special CPU or memory needs.
- GPU workloads.
- Different patching windows.
- Different cost tracking.

### Dedicated node group

```hcl
resource "aws_eks_node_group" "tenant" {
  for_each = {
    for name, tenant in var.tenants : name => tenant
    if tenant.dedicated_nodes
  }

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-${each.key}"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [for subnet in aws_subnet.private : subnet.id]

  labels = {
    tenant = each.key
  }

  taint {
    key    = "tenant"
    value  = each.key
    effect = "NO_SCHEDULE"
  }
}
```

### What is a taint?

A taint is a “keep out” sign on a node.

It says:

> “Do not schedule normal pods here.”

### What is a toleration?

A toleration is a special pass that lets a pod use a tainted node.

Example pod spec:

```yaml
tolerations:
  - key: "tenant"
    operator: "Equal"
    value: "tenant-a"
    effect: "NoSchedule"
nodeSelector:
  tenant: "tenant-a"
```

Middle school analogy:

- Taint = locked classroom door.
- Toleration = key card.
- Node selector = map that says which classroom to use.

---

## 20. Pro File Structure

This tutorial includes a professional two-phase structure.

```text
aws-terraform-middle-school-tutorial/
├── README.md
└── terraform/
    ├── 01-aws-infra/
    │   ├── versions.tf
    │   ├── providers.tf
    │   ├── backend.tf.example
    │   ├── variables.tf
    │   ├── locals.tf
    │   ├── data.tf
    │   ├── network.tf
    │   ├── security_groups.tf
    │   ├── ec2_kafka_nifi_postgres.tf
    │   ├── alb.tf
    │   ├── rds_alternative.tf
    │   ├── iam_eks.tf
    │   ├── eks.tf
    │   ├── outputs.tf
    │   ├── terraform.tfvars.example
    │   └── user_data/
    │       ├── kafka.sh
    │       ├── nifi.sh
    │       └── postgres.sh
    │
    ├── 02-k8s-tenants/
    │   ├── versions.tf
    │   ├── providers.tf
    │   ├── backend.tf.example
    │   ├── variables.tf
    │   ├── tenants.tf
    │   └── terraform.tfvars.example
    │
    └── k8s-app-examples/
        └── tenant-a-app.yaml
```

### Why split into two phases?

Phase 1 creates AWS things:

- VPC.
- EC2.
- Load balancer.
- EKS cluster.
- EKS node groups.

Phase 2 creates Kubernetes things inside EKS:

- Namespaces.
- Quotas.
- LimitRanges.
- RBAC.
- NetworkPolicies.

This split is cleaner because Kubernetes resources need the EKS cluster to exist first.

---

## 21. Backend Block and Remote State

A backend tells Terraform where to store state.

Example:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "data-platform/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

Plain meaning:

- Store state in S3.
- Store it at a specific key path.
- Use DynamoDB to lock it.
- Encrypt it.

### Why remote state matters

If two engineers run Terraform at the same time from two laptops, they can step on each other.

Remote state plus locking helps prevent that.

### Important

Create the S3 bucket and DynamoDB lock table before using the backend block.

For first-time learners, you can leave the backend file as `.example` and use local state while practicing.

---

## 22. Outputs

Outputs print useful values after `terraform apply`.

Example:

```hcl
output "nifi_alb_dns_name" {
  description = "DNS name of the NiFi Application Load Balancer."
  value       = aws_lb.nifi.dns_name
}
```

After apply, Terraform may show:

```text
nifi_alb_dns_name = "demo-nifi-alb-123456.us-east-1.elb.amazonaws.com"
```

Outputs are useful for:

- Copying URLs.
- Feeding another Terraform project.
- Debugging.
- CI/CD pipelines.

---

## 23. Full Command Workflow

### Before you start

Install:

- Terraform.
- AWS CLI.
- kubectl.
- An AWS account with permissions.

Set AWS credentials by using one of these:

```bash
aws configure
```

Or use AWS SSO:

```bash
aws sso login --profile your-profile-name
```

### Phase 1: AWS infrastructure

```bash
cd terraform/01-aws-infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`.

Then run:

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

### Connect kubectl to EKS

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name demo-data-platform-dev
```

Check nodes:

```bash
kubectl get nodes
```

### Phase 2: Kubernetes tenants

```bash
cd ../02-k8s-tenants
cp terraform.tfvars.example terraform.tfvars
```

Edit the remote state settings and tenant values.

Then run:

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Check namespaces:

```bash
kubectl get namespaces
kubectl get resourcequota -n tenant-a
kubectl get limitrange -n tenant-a
kubectl get networkpolicy -n tenant-a
```

### Deploy example tenant app

```bash
kubectl apply -f ../k8s-app-examples/tenant-a-app.yaml
kubectl get pods -n tenant-a
```

### Destroy when finished

Destroy Kubernetes tenant objects first:

```bash
cd terraform/02-k8s-tenants
terraform destroy
```

Then destroy AWS infrastructure:

```bash
cd ../01-aws-infra
terraform destroy
```

---

## 24. Recap

You learned:

- Terraform is like a LEGO instruction sheet for AWS.
- `init` gets tools ready.
- `plan` previews changes.
- `apply` builds the infrastructure.
- State is Terraform’s memory.
- Declarative means you describe the end result.
- `.tf` files use blocks, labels, arguments, and nested blocks.
- CIDR numbers describe IP address neighborhoods.
- Tags help with finding, cost, automation, and ownership.
- VPCs, subnets, routes, NAT, and security groups are the network foundation.
- Kafka, NiFi, and Postgres can run on EC2.
- RDS can reduce database operations work.
- ALBs route web traffic to healthy targets.
- EKS runs Kubernetes containers on AWS.
- Multi-tenant EKS uses namespaces, quotas, RBAC, network policies, and dedicated node pools.

---

## 25. One-Page Glossary

| Term | Simple Meaning |
|---|---|
| Terraform | Tool that builds cloud infrastructure from code. |
| `.tf` file | Terraform configuration file. |
| Provider | Plugin that lets Terraform talk to a system like AWS. |
| Resource | A thing Terraform creates or manages. |
| Data source | A thing Terraform reads but does not create. |
| Variable | Input value. |
| Output | Printed result. |
| Local | Helper value inside Terraform. |
| State | Terraform’s memory of what it manages. |
| Backend | Where Terraform stores state. |
| VPC | Private AWS network. |
| Subnet | Smaller network inside a VPC. |
| Public subnet | Subnet with a route to the internet. |
| Private subnet | Subnet without direct inbound internet access. |
| Internet Gateway | Door from a VPC to the internet. |
| NAT Gateway | Lets private servers go out to the internet safely. |
| Route table | Network road sign. |
| Security group | Virtual firewall. |
| EC2 | AWS virtual server. |
| AMI | Server image. |
| Kafka | Event/message platform. |
| NiFi | Data flow and movement tool. |
| Postgres | Relational database. |
| RDS | AWS-managed database service. |
| ALB | Application Load Balancer. |
| Target group | Group of backend servers for a load balancer. |
| Listener | Load balancer port rule. |
| Health check | Test to see if a target is healthy. |
| EKS | AWS-managed Kubernetes. |
| Kubernetes | Container orchestration system. |
| Pod | Smallest deployable unit in Kubernetes. |
| Namespace | Separate room inside a Kubernetes cluster. |
| ResourceQuota | Namespace resource budget. |
| LimitRange | Default CPU/memory guardrails. |
| RBAC | Permission system in Kubernetes. |
| NetworkPolicy | Pod traffic rules. |
| Node group | Group of EC2 worker nodes for EKS. |
| Taint | Keep-out sign on a node. |
| Toleration | Pass that lets a pod use a tainted node. |

---

## 26. Official References

Use official docs when you update this tutorial:

- Terraform overview: https://developer.hashicorp.com/terraform
- Terraform language docs: https://developer.hashicorp.com/terraform/language
- Terraform backends: https://developer.hashicorp.com/terraform/language/backend
- Terraform outputs: https://developer.hashicorp.com/terraform/language/values/outputs
- Terraform variables: https://developer.hashicorp.com/terraform/language/block/variable
- AWS Provider docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- AWS default tags tutorial: https://developer.hashicorp.com/terraform/tutorials/aws/aws-default-tags
- AWS VPC docs: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- AWS security groups: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html
- AWS RDS docs: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Welcome.html
- Amazon EKS docs: https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html
- EKS best practices: https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html
- EKS tenant isolation: https://docs.aws.amazon.com/eks/latest/best-practices/tenant-isolation.html
- EKS load balancing: https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html
