# Keycloak on AWS with Terraform — The Complete Beginner's Tutorial

**Reading level:** middle school. No experience assumed.
**Last checked:** July 2026. All versions and best practices verified against current releases.

---

## Table of contents

| File | What's in it |
|---|---|
| **00-START-HERE.md** (you are here) | Big picture, vocabulary, prerequisites, and your first deployment step by step |
| [01-network-line-by-line.md](01-network-line-by-line.md) | Every line of `01-network.tf` explained |
| [02-database-line-by-line.md](02-database-line-by-line.md) | Every line of `02-database.tf` explained |
| [03-keycloak-line-by-line.md](03-keycloak-line-by-line.md) | Every line of `03-keycloak.tf` explained |
| [04-verify-and-destroy.md](04-verify-and-destroy.md) | AWS CLI commands to check every resource, and to delete everything by hand if Terraform gets stuck |
| [05-gitlab-pipeline.md](05-gitlab-pipeline.md) | Running all of this automatically from GitLab CI/CD |
| [06-make-it-configurable.md](06-make-it-configurable.md) | Turning hard-coded values into knobs; swapping the database connection, the network access, and the certificate |
| [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md) | Real problems in this exact code and how to fix them |
| [08-glossary-and-reference.md](08-glossary-and-reference.md) | Dictionary, command cheat sheet, costs, troubleshooting |

**If you only read one thing:** read this file, run the 12 steps, then come back for the rest.

---

## Part 1 — What are we actually building?

### The one-sentence version

We are building a **login system for your apps**, running on **Amazon's computers**, and we are building it by **writing a description of it in a file** instead of clicking buttons on a website.

### The three pieces

Imagine you are building a small shop.

| Real-world thing | Our thing | File |
|---|---|---|
| The land, the fence, the front gate, the locks | The network (VPC, subnets, firewalls, permission badges) | `01-network.tf` |
| The filing cabinet in the locked back office | The database (RDS PostgreSQL) | `02-database.tf` |
| The shop itself, with a cashier at the counter | The Keycloak server (EC2 + Docker) | `03-keycloak.tf` |

You must build them in that order. You cannot put a filing cabinet on land you don't own, and you cannot open a shop with no filing cabinet.

### What is Keycloak?

Keycloak is a free program that handles **logging in**.

Without Keycloak, every app you write needs its own username/password code, its own "forgot password" email, its own "log in with Google" button. That's a lot of repeated work, and every copy is a chance to get security wrong.

With Keycloak, all of your apps say: *"Hey Keycloak, is this person allowed in?"* Keycloak handles passwords, two-factor codes, Google/Facebook/Microsoft login, and password resets. Your apps just trust Keycloak's answer.

This is called **SSO** (Single Sign-On) and **IAM** (Identity and Access Management).

### What is Terraform?

Terraform is a program that reads a text file describing what you want, and then makes it real in the cloud.

Compare:

| Clicking in the AWS website | Writing Terraform |
|---|---|
| Takes 45 minutes of clicking | Takes 4 minutes of typing `terraform apply` |
| You forget what you clicked last month | The file *is* the record |
| Rebuilding it in another region = 45 more minutes | Change one word, run again |
| Two people build it two different ways | Everyone gets exactly the same thing |
| Deleting it = hunting down 20 things | `terraform destroy` |

This idea has a name: **Infrastructure as Code (IaC)**. Your infrastructure lives in Git, gets code-reviewed, and has a history — just like real code.

### The picture

```
                        THE INTERNET
                             |
                     (only YOUR home IP
                      is allowed through)
                             |
                             v
  +===================================================================+
  |  VPC  10.42.0.0/16   "your own private neighborhood in AWS"       |
  |                                                                   |
  |   +---------------------------------------------------------+     |
  |   |  PUBLIC SUBNET  10.42.1.0/24        (has a road out)     |     |
  |   |                                                          |     |
  |   |     +------------------------------------------+         |     |
  |   |     |  EC2 instance  "t4g.small"               |         |     |
  |   |     |  Amazon Linux 2023 (ARM)                 |         |     |
  |   |     |    +--------------------------------+    |         |     |
  |   |     |    | Docker container: Keycloak     |    |         |     |
  |   |     |    | listening on 8443 (HTTPS)      |    |         |     |
  |   |     |    +--------------------------------+    |         |     |
  |   |     |  Elastic IP = permanent address          |         |     |
  |   |     +------------------------------------------+         |     |
  |   +---------------------------------|-----------------------+     |
  |                                     |  port 5432 only,             |
  |                                     |  and only from the           |
  |                                     |  Keycloak firewall group     |
  |                                     v                              |
  |   +---------------------------------------------------------+     |
  |   |  PRIVATE SUBNETS 10.42.11.0/24 + 10.42.12.0/24           |     |
  |   |  NO road to the internet at all                          |     |
  |   |                                                          |     |
  |   |     +------------------------------------------+         |     |
  |   |     |  RDS PostgreSQL 18                       |         |     |
  |   |     |  encrypted disk, TLS required            |         |     |
  |   |     +------------------------------------------+         |     |
  |   +---------------------------------------------------------+     |
  +===================================================================+

     Off to the side, not inside the VPC:
       * Secrets Manager  -> holds the database password + admin password
       * IAM role         -> the badge the EC2 wears to read that one secret
```

### Why this shape is the safe shape

1. **The database has no door to the internet.** Not a locked door — *no door*. The private subnet has no route to the internet gateway. Even if someone learned the database password, there is no path to use it.
2. **The firewall rule points at a group, not an address.** The database allows connections from "anything wearing the Keycloak badge," not from "IP 10.42.1.57". Replace the server, get a new IP, rule still works.
3. **Nobody types a password anywhere.** Terraform invents a 32-character password, hands it to AWS Secrets Manager, and the server reads it at boot using its badge. The password is never in your code, your shell history, or your Git repo.
4. **Only your home IP can reach the login page.** `my_ip_cidr` is a whitelist of exactly one address.

---

## Part 2 — Vocabulary you need first

Read these once. You'll see them constantly.

| Word | Middle-school meaning |
|---|---|
| **AWS** | Amazon's rental computers. You rent by the hour. |
| **Region** | Which city the computers are in. `us-east-1` = Northern Virginia. |
| **Availability Zone (AZ)** | One building inside that city. `us-east-1a`, `us-east-1b`. Two buildings = if one floods, you're still up. |
| **VPC** | Virtual Private Cloud. Your own fenced-off neighborhood inside AWS. Nobody else's servers are in it. |
| **Subnet** | One street inside your neighborhood. Lives in exactly one AZ. |
| **CIDR** | A way to write a range of addresses. `10.42.0.0/16` means "all addresses starting with 10.42". `/32` means exactly one address. |
| **Public subnet** | A street with a road leading out to the internet. |
| **Private subnet** | A street with **no** road out. Deliberately. |
| **Internet Gateway (IGW)** | The gate in the fence that connects your VPC to the internet. |
| **Route table** | The road signs. "Anything addressed outside → go to the gate." |
| **Security Group (SG)** | A firewall wrapped around one resource. Says who may knock and on which door (port). |
| **Port** | A numbered door on a computer. 22 = SSH, 443/8443 = HTTPS, 5432 = PostgreSQL. |
| **EC2** | One rented virtual computer. |
| **AMI** | The disk image an EC2 starts from — like a factory-fresh OS install. |
| **Elastic IP (EIP)** | A public address that stays yours even if you reboot. |
| **RDS** | A database that Amazon babysits: backups, patches, failover. |
| **IAM** | The permissions system. Who is allowed to do what. |
| **IAM Role** | A badge a *machine* wears. No password involved. |
| **Instance Profile** | The lanyard that lets an EC2 wear an IAM role. |
| **Secrets Manager** | An encrypted vault for passwords. |
| **user_data** | A script that runs once, as root, the very first time a server boots. |
| **Docker container** | An app packed in a box with everything it needs. Runs the same everywhere. |
| **systemd** | The thing on Linux that starts programs at boot and restarts them if they crash. |
| **Terraform state** | Terraform's memory file. Maps "what I wrote" to "what actually exists in AWS". |
| **HCL** | The language Terraform files are written in. |
| **Provider** | The plugin that teaches Terraform how to talk to AWS. |
| **Resource** | A thing Terraform creates and owns. |
| **Data source** | A question Terraform asks AWS. Read-only, creates nothing. |
| **Variable** | A knob you can turn without editing the main code. |
| **Output** | A value Terraform prints when it's done. |
| **TLS / SSL** | The lock on the padlock icon. Scrambles traffic so nobody can read it in transit. |
| **Certificate** | The ID card a server shows to prove it is who it claims to be. |

---

## Part 3 — Before you start: the checklist

You need **all six** of these. Skipping one is the #1 cause of "it didn't work."

### 1. An AWS account with billing set up

Sign up at aws.amazon.com. Yes, it wants a credit card.

### 2. A billing alarm (do this first, seriously)

```bash
# Turn on cost tracking, then create an alarm at $20/month
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Project,Status=Active

aws cloudwatch put-metric-alarm \
  --alarm-name "billing-over-20-usd" \
  --namespace "AWS/Billing" \
  --metric-name EstimatedCharges \
  --dimensions Name=Currency,Value=USD \
  --statistic Maximum \
  --period 21600 \
  --evaluation-periods 1 \
  --threshold 20 \
  --comparison-operator GreaterThanThreshold \
  --region us-east-1
```

> **Note:** billing metrics only exist in `us-east-1`, no matter where your stuff runs. That is not a typo.

### 3. The AWS CLI, installed and logged in

```bash
# macOS
brew install awscli
# Windows
winget install Amazon.AWSCLI
# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

aws --version          # want v2.x
aws configure          # paste your access key + secret + region
aws sts get-caller-identity   # proves you're logged in
```

That last command should print your account number. If it errors, nothing else in this tutorial will work.

### 4. Terraform (or OpenTofu)

```bash
# macOS
brew install terraform
# Windows
winget install Hashicorp.Terraform
# Linux (Debian/Ubuntu)
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

terraform version      # want 1.10.0 or newer
```

> **Terraform or OpenTofu?** In 2023 HashiCorp changed Terraform's license from open-source to "BSL" (you may use it, but not to build a competing product). The community forked the last open version and named it **OpenTofu**, now run by the Linux Foundation. The commands are identical — `tofu plan` instead of `terraform plan`. GitLab removed its built-in Terraform CI/CD templates in GitLab 18.0 because of that license change and now recommends OpenTofu. For learning on your own laptop either is fine. For a GitLab pipeline, see [05-gitlab-pipeline.md](05-gitlab-pipeline.md) — the answer there is OpenTofu.

### 5. `jq` and `curl`

```bash
brew install jq        # or: sudo apt install jq
```

`jq` reads JSON. AWS speaks JSON. You'll use it constantly.

### 6. Your public IP address

```bash
curl -s https://checkip.amazonaws.com
```

Write down the answer and add `/32`. Example: `73.15.204.88/32`. This is the *only* address that will be allowed to reach your Keycloak.

> Home internet addresses change every few weeks. When Keycloak suddenly "stops working," check this first.

---

## Part 4 — Your first deployment, step by step

Follow these 12 steps in order. Expect **15–20 minutes**, mostly waiting on the database.

### Step 1 — Make a folder and put the files in it

```bash
mkdir -p ~/keycloak-aws && cd ~/keycloak-aws
# copy 01-network.tf, 02-database.tf, 03-keycloak.tf into this folder
ls
# 01-network.tf  02-database.tf  03-keycloak.tf
```

> **Why one folder?** Terraform reads *every* `.tf` file in the current folder and glues them into one big configuration. The numbers in the filenames are for *humans* — Terraform figures out the real order from the dependencies between resources. `02-database.tf` can use `aws_subnet.private_a` from `01-network.tf` with no imports and no includes.

### Step 2 — Create your settings file

Do **not** edit the `.tf` files. Create a new file called `terraform.tfvars`. Terraform loads it automatically and its values override the defaults.

```hcl
# terraform.tfvars — your personal settings

aws_region   = "us-east-1"
project_name = "keycloak-demo"
environment  = "dev"

# From: curl -s https://checkip.amazonaws.com
my_ip_cidr = "73.15.204.88/32"

# Cheapest settings that still work
db_instance_class = "db.t4g.micro"
instance_type     = "t4g.small"
db_multi_az       = false
```

Now protect it, because it identifies your home:

```bash
cat > .gitignore <<'EOF'
*.tfvars
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl.bak
crash.log
EOF
```

> **Why ignore `*.tfstate`?** The state file contains your database password **in plain text**. It must never reach GitHub or GitLab. [05-gitlab-pipeline.md](05-gitlab-pipeline.md) shows where it should live instead.

### Step 3 — Initialize

```bash
terraform init
```

What just happened:
- Terraform read `required_providers` and downloaded the AWS plugin (~600 MB) into `.terraform/`
- It wrote `.terraform.lock.hcl`, which pins the *exact* plugin versions with checksums

> **Commit `.terraform.lock.hcl` to Git.** It guarantees your teammate and your pipeline get the identical provider you tested with. This is a best practice people skip and regret.

Expected ending: `Terraform has been successfully initialized!`

### Step 4 — Check the formatting and the grammar

```bash
terraform fmt      # auto-fixes spacing and alignment
terraform validate # checks for typos and missing arguments
```

`validate` does **not** talk to AWS. It only checks that your code makes sense. `Success! The configuration is valid.` is what you want.

### Step 5 — Look before you leap

```bash
terraform plan -out=tfplan
```

This *does* talk to AWS, but only to read. It prints a preview:

```
Plan: 32 to add, 0 to change, 0 to destroy.
```

Symbols to know:

| Symbol | Meaning |
|---|---|
| `+` | will be created |
| `-` | will be **destroyed** |
| `~` | will be changed in place |
| `-/+` | will be destroyed and rebuilt (⚠️ data loss risk) |
| `(known after apply)` | AWS decides this value, Terraform can't know it yet |

**Read the plan every single time.** A `-/+` on `aws_db_instance` means your database is about to be deleted and recreated. That is how people lose data.

`-out=tfplan` saves the plan to a file so the apply does *exactly* what you reviewed, even if something changed in the meantime.

### Step 6 — Build it

```bash
terraform apply tfplan
```

Because you passed a saved plan, it does not ask for confirmation — you already approved it in step 5.

Timeline:

| Time | What's happening |
|---|---|
| 0:00–0:30 | VPC, subnets, route tables, security groups, IAM — all instant and all free |
| 0:30–8:00 | **RDS database.** This is the slow part. Amazon is provisioning a real server, formatting encrypted storage, and installing PostgreSQL. Go get a snack. |
| 8:00–8:30 | Secrets Manager entries |
| 8:30–9:00 | EC2 instance launches, Elastic IP attaches |
| 9:00–14:00 | **Inside the EC2**, invisible to Terraform: installing Docker, reading secrets, downloading certificates, building the Keycloak image, starting the container |

> **Important:** `terraform apply` says "Apply complete!" as soon as the EC2 *exists*. It has **no idea** whether Keycloak actually started. That takes another 4–6 minutes. Don't panic when the URL doesn't load immediately.

### Step 7 — Read the outputs

```bash
terraform output
```

You get something like:

```
keycloak_url               = "https://54.211.99.10:8443"
keycloak_admin_console     = "https://54.211.99.10:8443/admin"
keycloak_public_ip         = "54.211.99.10"
db_endpoint                = "keycloak-demo-db.abc123.us-east-1.rds.amazonaws.com"
ssm_shell_command          = "aws ssm start-session --target i-0abc123..."
get_admin_password_command = "aws secretsmanager get-secret-value --secret-id ..."
```

### Step 8 — Watch the server finish setting itself up

```bash
# Get a shell without SSH and without any key file
aws ssm start-session --target $(terraform output -raw keycloak_instance_id)
```

> **What is SSM Session Manager?** AWS's "shell through the front door" service. A little agent on the server dials *out* to AWS; you connect *to* AWS. No inbound port 22, no key file to lose, and every session can be logged. This is the modern replacement for SSH and it's why `ssh_key_name` defaults to empty.

Once you're in:

```bash
sudo tail -f /var/log/keycloak-bootstrap.log
```

You'll see the eight steps tick past. Wait for:

```
=== Bootstrap complete. Keycloak starting on https://54.211.99.10:8443 ===
```

Then confirm the container is alive:

```bash
sudo docker ps
sudo docker logs keycloak --tail 50
sudo systemctl status keycloak
```

Look for `Keycloak 26.7.0 ... started in 24.5s. Listening on: http://0.0.0.0:8080 and https://0.0.0.0:8443`.

Type `exit` to leave.

### Step 9 — Get your admin password

```bash
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw keycloak_admin_secret_name) \
  --query SecretString --output text | jq .
```

```json
{
  "username": "kcadmin",
  "password": "Xk9#mP2vQ!wR8nL4tY6zA1sD"
}
```

### Step 10 — Log in

Open the `keycloak_admin_console` URL in your browser.

Your browser will scream: **"Your connection is not private" / NET::ERR_CERT_AUTHORITY_INVALID**.

**This is expected and it is not a bug.** The server made its own ID card (a "self-signed certificate"). Your browser trusts ID cards issued by ~150 official authorities, and "some server in Virginia" is not one of them. The traffic *is* encrypted; the browser just can't verify *who* it's talking to.

Click **Advanced → Proceed anyway**.

Then log in with the username and password from step 9.

> Fixing this properly — getting a real, green-padlock certificate — is [06-make-it-configurable.md § Swap 3](06-make-it-configurable.md).

### Step 11 — Prove the database connection is real

In the Keycloak admin console: **Users → Add user**, create a user, save.

Then in a terminal:

```bash
aws rds describe-db-instances \
  --db-instance-identifier keycloak-demo-db \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,StorageEncrypted,PubliclyAccessible,MultiAZ]' \
  --output table
```

You want `available`, `true` for encrypted, `false` for publicly accessible. That user you created is now rows inside that private database, and Keycloak reached it over TLS through a firewall rule that names a security group instead of an IP.

### Step 12 — Turn it off when you're done

```bash
terraform destroy
```

Type `yes`. Takes 5–10 minutes (RDS is slow to delete too).

Then double-check nothing survived:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=keycloak-demo" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
```

All three should be empty (`[]`). An unattached Elastic IP costs about **$3.60/month for doing nothing** — that's AWS's way of discouraging address hoarding.

If `destroy` gets stuck, [04-verify-and-destroy.md](04-verify-and-destroy.md) has the manual cleanup commands for every single resource.

---

## Part 5 — What does this cost?

Prices are `us-east-1`, on-demand, mid-2026. Always confirm with the AWS Pricing Calculator.

| Thing | Setting | Per month |
|---|---|---|
| EC2 | `t4g.small`, always on | ~$12.10 |
| Root disk | 20 GB gp3 | ~$1.60 |
| RDS | `db.t4g.micro`, single-AZ | ~$12.40 |
| RDS storage | 20 GB gp3 | ~$2.30 |
| RDS backups | 20 GB, 7 days | free (equal to your DB size is free) |
| Elastic IP | attached to a running instance | free |
| Secrets Manager | 2 secrets | ~$0.80 |
| VPC, subnets, IGW, SGs, IAM, route tables | — | **free** |
| Performance Insights | 7-day retention | **free** |
| Data transfer out | first 100 GB | free |
| **Total** | | **≈ $29/month** |

Ways to cut it:

| Change | Saves | Costs you |
|---|---|---|
| `db_multi_az = false` (already the default) | ~$12 | No automatic failover |
| Stop the EC2 at night (`aws ec2 stop-instances`) | ~$6 | Not available at night; Elastic IP starts billing while stopped |
| Stop RDS (auto-restarts after 7 days) | ~$12 | Same |
| `t4g.micro` EC2 (1 GB RAM) | ~$6 | Keycloak may run out of memory. Not recommended. |
| `terraform destroy` between sessions | everything | 15 min to rebuild |

**The cheapest habit: destroy it when you're not using it.** That's the whole point of Infrastructure as Code — rebuilding is one command.

---

## Part 6 — The mental model that makes Terraform click

Terraform is not a script. Scripts say *"do this, then do that."* Terraform is **declarative**: you describe the finished result and Terraform figures out the steps.

Every run, it compares three things:

```
   WHAT YOU WROTE          WHAT TERRAFORM
   (.tf files)             REMEMBERS
        |                  (terraform.tfstate)
        |                        |
        +-----------+------------+
                    |
                    v
             compare all three
                    ^
                    |
            WHAT ACTUALLY EXISTS
              (real AWS API)
```

- In your files but not in reality → **create**
- In reality but not in your files → **destroy**
- In both but different → **change**
- In both and identical → leave alone

This is why:
- Running `apply` twice in a row does nothing the second time (this is called **idempotence**)
- Deleting a resource block *deletes the real thing* — that's not a "forget," that's an "erase"
- **Losing the state file is a disaster.** Terraform forgets it owns 32 things and tries to build them all again. Protect the state file like a password.

### The dependency graph

You never tell Terraform the order. It reads references and builds a graph.

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id     # <-- this reference IS the ordering instruction
}
```

Because the gateway mentions `aws_vpc.main.id`, Terraform knows the VPC comes first. Everything with no dependency between it runs in parallel (10 at a time by default). That's why 32 resources take 9 minutes instead of 32 sequential waits.

`depends_on` is the manual override for the rare case where the dependency is real but invisible — like "the EC2 must not boot until the database exists," which Terraform can't infer because the connection happens inside a shell script.

---

## Part 7 — What to read next

| If you want to... | Go to |
|---|---|
| Understand every single line | [01](01-network-line-by-line.md), [02](02-database-line-by-line.md), [03](03-keycloak-line-by-line.md) |
| Check your work with AWS CLI | [04-verify-and-destroy.md](04-verify-and-destroy.md) |
| Clean up when Terraform is stuck | [04-verify-and-destroy.md § Manual destruction](04-verify-and-destroy.md) |
| Automate it in GitLab | [05-gitlab-pipeline.md](05-gitlab-pipeline.md) |
| Change the DB connection, the network, or the certificate | [06-make-it-configurable.md](06-make-it-configurable.md) |
| Know what's broken in this code | [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md) |
| Look something up fast | [08-glossary-and-reference.md](08-glossary-and-reference.md) |
# `01-network.tf` — Every Line Explained

[← Back to START HERE](00-START-HERE.md) | [Next: the database →](02-database-line-by-line.md)

This file builds the **land**: the private network, the streets, the gate, the firewalls, and the permission badges. Everything here is **free** except nothing — literally all of it is free. VPCs, subnets, security groups, IAM roles and route tables cost $0.

---

## Section 1 — The `terraform` block

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

| Line | What it does |
|---|---|
| `terraform {` | Settings for Terraform itself, not for AWS. There can be only one of these per folder. |
| `required_version = ">= 1.9.0"` | Refuse to run on Terraform older than 1.9.0. Stops a teammate with an ancient version from corrupting your state file. |
| `required_providers {` | The list of plugins to download. |
| `source = "hashicorp/aws"` | Short for `registry.terraform.io/hashicorp/aws` — the official AWS plugin. |
| `version = "~> 5.70"` | The **pessimistic constraint**: allow 5.70, 5.71, 5.99… but never 6.0. |
| `random` | A tiny provider that generates random passwords and IDs. Used in `02` and `03`. |

### Understanding `~>` (the squiggly arrow)

| You write | Allowed | Blocked |
|---|---|---|
| `~> 5.70` | 5.70, 5.71, 5.99 | 6.0 |
| `~> 5.70.0` | 5.70.0, 5.70.9 | 5.71.0 |
| `>= 5.70` | 5.70, 6.0, 9.9 | nothing |
| `= 5.70.0` | exactly 5.70.0 | everything else |

**Why block 6.0?** Major version numbers mean "we broke something on purpose." AWS provider v6 changed things this code relies on — for example, `data.aws_region.current.name` is deprecated in favor of `.region`, and this file uses `.name` in three places. Pinning `~> 5.70` means your pipeline won't break itself overnight.

**Pros and cons of version pinning:**

| Style | Pro | Con |
|---|---|---|
| `~> 5.70` (used here) | Auto-gets bug fixes, blocks breaking changes | Minor releases still occasionally surprise you |
| `= 5.70.1` | Perfectly reproducible | You must manually chase security fixes |
| No constraint | Always newest | Your build breaks on a random Tuesday |

**Best practice:** use `~>` in the code **and** commit `.terraform.lock.hcl`. The constraint says what's *allowed*; the lock file records what you *actually tested with*. Belt and suspenders.

### How to upgrade later

```bash
terraform init -upgrade                 # get newest allowed by the constraint
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64 \
  -platform=windows_amd64              # record checksums for every OS your team uses
terraform plan                          # confirm nothing unexpected changed
```

That multi-platform lock step matters if you develop on a Mac and your CI runs Linux. Without it, CI fails with a checksum error.

---

## Section 2 — The `provider` block

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
```

| Line | What it does |
|---|---|
| `provider "aws" {` | Configures the AWS plugin. |
| `region = var.aws_region` | Which AWS city to build in. Reads the variable, so you change it from `terraform.tfvars`. |
| `default_tags { tags = {...} }` | **Automatically stamps these three labels on every taggable resource.** |

### Why `default_tags` is one of the best features in the AWS provider

Without it you'd write `tags = { Project = "..." }` on all 32 resources and forget on four of them. With it:

- **Finding things:** `aws ec2 describe-instances --filters "Name=tag:Project,Values=keycloak-demo"`
- **Cost tracking:** AWS Cost Explorer can group your bill by the `Project` tag
- **Safe cleanup:** you can confidently delete everything tagged `ManagedBy=terraform`
- **Audit:** an untagged resource in your account is a red flag — somebody clicked instead of coding

Resource-level `tags` blocks *merge* with the defaults; they don't replace them. So `aws_vpc.main` ends up with all four tags: `Project`, `ManagedBy`, `Environment`, and `Name`.

### Where does Terraform get AWS credentials?

Not from this file — never put keys in a `.tf` file. It searches in this order:

1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables
2. `~/.aws/credentials` (what `aws configure` writes)
3. IAM role on the EC2/ECS/Lambda it's running on
4. Web identity token (this is how GitLab CI does it — see [05](05-gitlab-pipeline.md))

**Best practice for 2026:** don't use long-lived access keys at all. Use AWS IAM Identity Center (`aws sso login`) on your laptop and OIDC federation in CI.

### Making it configurable: multiple regions at once

```hcl
provider "aws" {
  alias  = "backup"
  region = "us-west-2"
}

resource "aws_s3_bucket" "dr" {
  provider = aws.backup     # this one resource goes to Oregon
  bucket   = "my-dr-bucket"
}
```

---

## Section 3 — Variables

```hcl
variable "aws_region" {
  description = "Which AWS datacenter region to build in."
  type        = string
  default     = "us-east-1"
}
```

Every variable has three parts worth caring about:

| Part | Purpose |
|---|---|
| `description` | Shows up in `terraform plan` errors and in generated docs. Always write one. |
| `type` | `string`, `number`, `bool`, `list(string)`, `map(string)`, `object({...})`. Catches typos early. |
| `default` | Makes it optional. **No default = Terraform stops and asks you.** |

### The five ways to set a variable (highest priority wins)

| Priority | How | Example |
|---|---|---|
| 1 (wins) | `-var` on the command line | `terraform apply -var="my_ip_cidr=1.2.3.4/32"` |
| 2 | `-var-file` | `terraform apply -var-file=prod.tfvars` |
| 3 | `*.auto.tfvars` (alphabetical) | `prod.auto.tfvars` |
| 4 | `terraform.tfvars` | the file you made in step 2 |
| 5 | `TF_VAR_` environment variable | `export TF_VAR_my_ip_cidr="1.2.3.4/32"` |
| 6 (loses) | `default` in the variable block | |

> **Wait — environment variables are *lower* priority than `terraform.tfvars`?** Yes, and it surprises everyone. `TF_VAR_` is the weakest source except for defaults. Remember it or you'll spend an hour debugging.

### The validation block

```hcl
variable "my_ip_cidr" {
  description = "YOUR public IP with /32 on the end. Only this IP can reach Keycloak."
  type        = string
  default     = "68.32.112.68/32"

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must look like 1.2.3.4/32"
  }
}
```

- `cidrhost("10.0.0.0/16", 0)` returns the first address in that range. If the input isn't a valid CIDR, it throws an error.
- `can(...)` catches that error and returns `false` instead of crashing.
- So the condition means: **"can this string be parsed as a network range?"**

You get a clear message at plan time instead of a confusing AWS API error 20 seconds into an apply. Cheap to write, saves real time.

**A stricter version** that also blocks the classic security disaster:

```hcl
validation {
  condition     = can(cidrhost(var.my_ip_cidr, 0)) && var.my_ip_cidr != "0.0.0.0/0"
  error_message = "Refusing 0.0.0.0/0 — that opens Keycloak to the entire internet."
}
```

### ⚠️ Danger: a real IP address is hard-coded as the default

```hcl
default = "68.32.112.68/32"
```

That is somebody's actual home internet address, sitting in a file you might push to Git. Two problems:

1. **It leaks personal information** — an IP maps to a city and an internet provider.
2. **It's a footgun** — if you forget to override it, your firewall lets in a stranger's house and locks out yours.

**Fix:** remove the default so Terraform *forces* you to supply it.

```hcl
variable "my_ip_cidr" {
  description = "Your public IP with /32. Get it from: curl -s https://checkip.amazonaws.com"
  type        = string
  # no default -> Terraform will refuse to run until you provide it
}
```

### The other variables

```hcl
variable "project_name" { default = "keycloak-demo" }
variable "environment"  { default = "dev" }
variable "vpc_cidr"     { default = "10.42.0.0/16" }
```

**`project_name`** gets glued into nearly every resource name using string interpolation: `"${var.project_name}-vpc"` becomes `keycloak-demo-vpc`. This is what lets you run dev and prod in one account without collisions.

**`vpc_cidr` — how to pick one.** Only three ranges are legal for private networks (RFC 1918):

| Range | Size | Notes |
|---|---|---|
| `10.0.0.0/8` | 16.7 million | What big companies use. `10.42.0.0/16` is a slice of it. |
| `172.16.0.0/12` | 1 million | **Docker's default bridge is `172.17.0.0/16`** — avoid this range on Docker hosts |
| `192.168.0.0/16` | 65 thousand | Your home router uses this. Avoid it, or your VPN will conflict. |

`10.42.0.0/16` gives you 65,536 addresses, and 42 is unlikely to collide with a corporate network. Good choice.

**The rule that actually matters: never overlap.** If you ever want to peer this VPC with another one, or connect it to an office network, overlapping ranges make it impossible. Pick a number nobody else is using and write it down.

---

## Section 4 — Data sources (asking AWS questions)

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
```

`data` blocks **read**; they never create or cost anything.

| Data source | Question it asks | Used for |
|---|---|---|
| `aws_availability_zones` | "Which buildings are working in this region right now?" | Placing subnets without hard-coding `us-east-1a` |
| `aws_caller_identity` | "Whose credentials am I using?" | Account ID, for locking IAM policies to your account |
| `aws_region` | "Which region am I in?" | Building ARNs and download URLs |

**Why this beats hard-coding.** If you wrote `availability_zone = "us-east-1a"` and moved to `eu-west-1`, everything breaks. With the data source, `names[0]` is just "the first working AZ here," whatever region you're in.

> **The gotcha:** the *order* of `names` is not guaranteed forever, and AZ names are shuffled per account (your `us-east-1a` is a different building than mine). For a lab that's fine. For production, pin them explicitly or use AZ IDs (`use1-az1`), which *are* stable across accounts.

---

## Section 5 — The VPC

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}
```

### Anatomy of a `resource` block

```
resource "aws_vpc" "main" {
   ^        ^        ^
   |        |        +-- YOUR nickname. Used in code: aws_vpc.main.id
   |        +----------- the TYPE, defined by the provider
   +-------------------- the keyword
```

The full address `aws_vpc.main` must be unique in the whole configuration.

### The two DNS lines are not optional

| Setting | What breaks without it |
|---|---|
| `enable_dns_support = true` | Nothing inside the VPC can look up any name at all |
| `enable_dns_hostnames = true` | **RDS endpoints don't resolve.** Keycloak gets "unknown host" and dies. |

RDS gives you a name like `keycloak-demo-db.abc123.us-east-1.rds.amazonaws.com`, never a raw IP — because the IP changes during failover and maintenance. If the VPC can't turn names into numbers, your app can't reach its database. This is a top-5 "why won't it connect" cause.

---

## Section 6 — The Internet Gateway

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}
```

One line does everything: `vpc_id = aws_vpc.main.id`.

- It **attaches** the gateway to your VPC.
- It **creates the dependency**: Terraform now knows the VPC must exist first.

An IGW is free, horizontally scaled by AWS, and has no bandwidth cap. **It does not by itself let traffic flow** — a route table must point at it (Section 8). An IGW with no route is a gate with no road leading to it.

### IGW vs NAT Gateway — the money question

| | Internet Gateway | NAT Gateway |
|---|---|---|
| Direction | in **and** out | out only |
| Needs a public IP on the instance | yes | no |
| Price | **free** | ~$32/month + $0.045/GB |
| Use for | public subnets | private subnets that need to download updates |

This design deliberately has **no NAT Gateway**. The database never needs to download anything, so it doesn't need internet access, so we don't pay $32/month for a thing we'd only use to feel safe. Good engineering.

---

## Section 7 — Subnets

```hcl
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1)   # 10.42.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-a"
    Tier = "public"
  }
}
```

### The `cidrsubnet()` function, explained slowly

```
cidrsubnet(prefix, newbits, netnum)
          ^        ^        ^
          |        |        +-- which slice to take
          |        +----------- how many bits to add to the mask
          +-------------------- the range to cut up
```

`cidrsubnet("10.42.0.0/16", 8, 1)`:
1. Start with `/16`, add 8 bits → `/24`
2. A `/24` holds 256 addresses
3. Take slice number 1 → `10.42.1.0/24`

| Call | Result | Used by |
|---|---|---|
| `cidrsubnet(var.vpc_cidr, 8, 1)` | `10.42.1.0/24` | public |
| `cidrsubnet(var.vpc_cidr, 8, 11)` | `10.42.11.0/24` | private A |
| `cidrsubnet(var.vpc_cidr, 8, 12)` | `10.42.12.0/24` | private B |

**Why the gap between 1 and 11?** Room to grow. Slices 2–10 are reserved for future public subnets, 13+ for future private ones. Address planning with deliberate gaps is a habit that saves painful renumbering later.

**Why use the function instead of typing `10.42.1.0/24`?** Change `vpc_cidr` to `10.99.0.0/16` and all three subnets follow automatically. Hard-coded strings would silently point at the wrong network.

### AWS steals 5 addresses from every subnet

A `/24` gives you 251 usable addresses, not 256:

| Address | Taken by |
|---|---|
| `10.42.1.0` | network address |
| `10.42.1.1` | AWS router |
| `10.42.1.2` | AWS DNS |
| `10.42.1.3` | reserved for the future |
| `10.42.1.255` | broadcast |

Plenty for us. Worth knowing before you make a `/28` subnet and wonder why 11 addresses vanished.

### `map_public_ip_on_launch`

| Subnet | Value | Meaning |
|---|---|---|
| public | `true` | Anything launched here gets a public IP automatically |
| private A and B | `false` | Never, ever hand out a public IP here |

Setting it explicitly to `false` on the private subnets is **defense in depth** — the default is already `false`, but writing it down means a future edit can't silently flip it, and a reader knows it was a decision, not an accident.

### Why two private subnets?

```hcl
availability_zone = data.aws_availability_zones.available.names[0]   # private_a
availability_zone = data.aws_availability_zones.available.names[1]   # private_b
```

**RDS refuses to start with fewer than two subnets in two different AZs.** Even a single-AZ database requires it, because AWS wants a place to fail over to if you ever flip `multi_az = true`.

With `multi_az = false` (our default) the standby subnet sits empty — costing nothing. It's a parking space you're required to own.

### Pros and cons of this subnet layout

| | Pro | Con |
|---|---|---|
| 1 public + 2 private | Simple, cheap, database is genuinely unreachable | Single public subnet = single AZ for the app; if that AZ dies, Keycloak is down |
| Add a second public subnet | Enables a load balancer and multi-AZ Keycloak | More resources to reason about |
| No NAT Gateway | Saves $32/month | Private instances can't download patches (we don't have any, so fine) |

**Upgrade path:** when you add a load balancer (see [06](06-make-it-configurable.md)), you'll need `public_b` too, because ALBs require two AZs — exactly like RDS.

---

## Section 8 — Route tables

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-rt-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

A route table is a list of road signs. It's read most-specific-first:

| Destination | Target | Note |
|---|---|---|
| `10.42.0.0/16` | `local` | **Invisible — AWS adds it automatically and you cannot remove it.** This is why every subnet can talk to every other subnet in the VPC. |
| `0.0.0.0/0` | the IGW | "Everything else, go out the gate" |

`0.0.0.0/0` means "any address in the world." It's called the **default route**.

The **association** is a separate resource because it's a many-to-one relationship: many subnets, one table. Without an association, a route table exists and does absolutely nothing.

### The private route table — the most important thing in this file

```hcl
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-rt-private" }
}
```

**Look at what isn't there.** No `route` block. No `0.0.0.0/0`. Only the invisible `local` route.

Consequences:
- The database can talk to anything inside `10.42.0.0/16` ✅
- The database cannot reach the internet ❌
- The internet cannot reach the database ❌
- Malware on the database cannot phone home ❌
- Cost: **$0** (a NAT Gateway would be $32/month)

This is *network-level* security, which is stronger than firewall-level security. A security group is a rule that could be misconfigured. A missing route is a road that was never built.

### What if the private subnet DOES need AWS services?

Say you later want the database to push logs to S3 without internet access. Three options:

| Option | Cost | Notes |
|---|---|---|
| NAT Gateway | ~$32/mo + data | Simple, works for everything, expensive |
| **Gateway VPC Endpoint** (S3, DynamoDB) | **free** | Adds a route to a special prefix list. Use this. |
| Interface VPC Endpoint (everything else) | ~$7.20/mo each | A private IP inside your subnet that speaks to an AWS service |

The comment at the top of the file mentions "optional VPC endpoints (disabled by default)" — this is what it means.

---

## Section 9 — Security groups (the firewalls)

```hcl
resource "aws_security_group" "keycloak" {
  name        = "${var.project_name}-keycloak-sg"
  description = "Allow admin console and SSH from one IP only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-keycloak-sg" }

  lifecycle {
    create_before_destroy = true
  }
}
```

### Security group facts you must internalize

1. **Default deny.** An empty SG blocks everything inbound. You only ever write *allow* rules — there is no such thing as a deny rule in a security group. (For deny rules you need a Network ACL, which is a different, rarely-needed tool.)
2. **Stateful.** If you allow a connection *in*, the reply is automatically allowed *out*. You don't write a matching return rule. (Network ACLs are stateless and *do* need both — a classic source of confusion.)
3. **Additive.** If a resource has three SGs, it gets the union of all their allow rules.
4. **They wrap resources, not subnets.** Two instances in the same subnet can have completely different firewalls.

### `lifecycle { create_before_destroy = true }`

Normally Terraform destroys the old thing then creates the new one. That's a gap of downtime, and it fails outright if something else still references the old resource.

`create_before_destroy` flips the order: build the new one, move the references, then delete the old one.

> **⚠️ Bug here:** `create_before_destroy` combined with a *fixed* `name` fails, because for a moment two security groups would need the same name and AWS forbids that. The fix is to use `name_prefix` instead of `name`. See [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md) — this affects three resources in this project.

### The rules

```hcl
resource "aws_vpc_security_group_ingress_rule" "keycloak_https" {
  security_group_id = aws_security_group.keycloak.id
  description       = "Keycloak HTTPS from my IP"
  cidr_ipv4         = var.my_ip_cidr
  from_port         = 8443
  to_port           = 8443
  ip_protocol       = "tcp"
}
```

| Argument | Meaning |
|---|---|
| `security_group_id` | Which firewall to attach this rule to |
| `cidr_ipv4` | **Who** may connect. `73.15.204.88/32` = exactly one address. |
| `from_port` / `to_port` | The port range. Same number twice = one port. |
| `ip_protocol` | `tcp`, `udp`, `icmp`, or `-1` for all |
| `description` | Shows in the console. Future-you will be grateful. |

### ⭐ Best practice alert: separate rule resources

Older Terraform code puts `ingress { ... }` blocks *inside* the `aws_security_group` resource. This code uses standalone `aws_vpc_security_group_ingress_rule` resources instead. That's the current recommended pattern, for good reasons:

| Inline blocks (old) | Separate resources (new, used here) |
|---|---|
| Terraform deletes any rule it didn't create | Coexists with rules added by other tools |
| Changing one rule shows a confusing diff of the whole SG | Each rule is its own line in the plan |
| Can't add a description per rule cleanly | Each rule carries its own description |
| One giant resource | Each rule has its own ID, easy to import or target |

**Never mix the two styles on one security group.** They fight, and the inline block wins by deleting the standalone rules on every apply.

### The three inbound rules

| Rule | Port | Why | Should you keep it? |
|---|---|---|---|
| `keycloak_https` | 8443 | The actual admin console over TLS | **Yes** |
| `keycloak_http` | 8080 | Plain, unencrypted HTTP for first-boot debugging | **Delete it once things work.** The file even says so. Passwords over 8080 travel in clear text. |
| `keycloak_ssh` | 22 | SSH | **Delete it.** SSM Session Manager (set up in the IAM section) gives you a shell with no open port at all. |

Deleting the HTTP and SSH rules is a two-line change and it removes two-thirds of your attack surface. Do it.

### The egress rule

```hcl
resource "aws_vpc_security_group_egress_rule" "keycloak_all_out" {
  security_group_id = aws_security_group.keycloak.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

`-1` means "every protocol, every port." The server genuinely needs this at boot: it downloads OS packages from Amazon's repos, pulls the Keycloak image from `quay.io`, fetches the RDS certificate bundle, and talks to Secrets Manager and SSM.

| | Pro | Con |
|---|---|---|
| Wide-open egress (here) | Boot always works | If the server is compromised, the attacker can send your data anywhere |
| Locked-down egress | Data exfiltration is much harder | You must enumerate every endpoint; a missed one = mysterious boot failure |

For production, the mature answer is: keep wide egress during boot, then use **VPC endpoints** for the AWS services and narrow egress to just `443` afterwards.

### ⭐ The single best line in this whole project

```hcl
resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
  security_group_id            = aws_security_group.database.id
  description                  = "Postgres from Keycloak instances only"
  referenced_security_group_id = aws_security_group.keycloak.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
```

Notice: **`referenced_security_group_id`, not `cidr_ipv4`.**

The rule reads: *"Allow port 5432 from anything wearing the Keycloak security group."*

| Approach | What happens when you replace the server |
|---|---|
| `cidr_ipv4 = "10.42.1.57/32"` | New server, new IP, **database refuses it**. You debug for an hour. |
| `cidr_ipv4 = "10.42.1.0/24"` | Works, but now *anything* on that street can reach the DB |
| `referenced_security_group_id` ✅ | Works forever. Only Keycloak members get in, no matter their IP. |

This is called **security-group referencing**, and it is the single most important AWS networking habit to learn. It scales to autoscaling groups, containers, and Lambda without a single edit.

### The weird database egress rule

```hcl
resource "aws_vpc_security_group_egress_rule" "db_none" {
  security_group_id = aws_security_group.database.id
  cidr_ipv4         = "127.0.0.1/32"
  ip_protocol       = "-1"
}
```

`127.0.0.1` is "myself." So this rule allows the database to connect to... itself. Which is useless. Which is the point.

**Why not just have no egress rule?** Because the AWS API creates a default `allow all` egress rule when a security group is born. If Terraform doesn't manage *some* egress rule, that wide-open default sticks around. Defining a deliberately useless one replaces it.

Remember: security groups are stateful, so the database can still *reply* to Keycloak. Replies aren't new connections and aren't subject to egress rules.

---

## Section 10 — IAM (the permission badges)

This is the part beginners skip and attackers love.

```hcl
resource "random_id" "suffix" {
  byte_length = 3
}
```

Generates 3 random bytes → 6 hex characters like `a3f9c1`. Used to make names unique.

**Why?** IAM role names and Secrets Manager secret names are *global-ish* and sticky. Delete a secret and the name is reserved for up to 30 days. Without a random suffix, `terraform destroy && terraform apply` fails with "a resource with that name already exists."

`random_id` is generated once and stored in state. It stays the same across applies — it only changes if you taint it or if its `keepers` change.

### The trust policy — who may wear the badge

```hcl
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "AllowEC2ToAssume"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
```

Every IAM role has **two** policies, and mixing them up is the classic beginner mistake:

| Policy | Question it answers |
|---|---|
| **Trust policy** (`assume_role_policy`) | *Who is allowed to wear this badge?* |
| **Permission policy** (attached separately) | *What can the badge do?* |

This trust policy says only the EC2 service may assume the role. A human with your credentials cannot. A Lambda cannot.

**Why `aws_iam_policy_document` instead of `jsonencode({...})` or a heredoc?**

| Approach | Pro | Con |
|---|---|---|
| `aws_iam_policy_document` ✅ | Terraform validates the structure; syntax errors caught at plan time; merges cleanly | Slightly more verbose |
| `jsonencode({...})` | Compact, native HCL | No IAM-specific validation |
| Raw heredoc JSON string | Copy-pasteable from AWS docs | One missing comma = a runtime failure 30 seconds into apply |

### The role

```hcl
resource "aws_iam_role" "keycloak" {
  name               = "${var.project_name}-keycloak-role-${random_id.suffix.hex}"
  description        = "Least privilege role for the Keycloak EC2 instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}
```

`.json` converts the policy document object into the JSON string AWS expects.

### Attaching the AWS-managed SSM policy

```hcl
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

This one managed policy is what enables `aws ssm start-session` — a shell in your browser or terminal with **no SSH key and no open port 22**.

| | Pro | Con |
|---|---|---|
| AWS-managed policy | AWS keeps it current as SSM adds features; battle-tested | Broader than strictly necessary; AWS can change it without telling you |
| Hand-written equivalent | Exactly the permissions you audited | ~15 actions to maintain; break one and SSM silently stops working |

The file's comment gets this right: this is the one managed policy worth attaching.

### ⭐ The least-privilege custom policy

```hcl
data "aws_iam_policy_document" "read_db_secret" {
  statement {
    sid = "ReadOnlyTheKeycloakDbSecret"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/db-*"
    ]
  }
}
```

Decode that ARN (Amazon Resource Name):

```
arn:aws:secretsmanager:us-east-1:123456789012:secret:keycloak-demo/db-*
 |   |        |            |          |          |         |
 |   |        |            |          |          |         +-- name pattern
 |   |        |            |          |          +------------ resource type
 |   |        |            |          +----------------------- YOUR account only
 |   |        |            +---------------------------------- this region only
 |   |        +----------------------------------------------- this service only
 |   +-------------------------------------------------------- AWS partition
 +------------------------------------------------------------ it's an ARN
```

**Compare to what beginners write:**

| Written as | Grants access to |
|---|---|
| `resources = ["*"]` | Every secret in your entire account 💀 |
| `resources = ["arn:...:secret:*"]` | Every secret in this region |
| This code ✅ | Only secrets named `keycloak-demo/db-*` in your account and region |

The `*` at the end is required, not sloppy: Secrets Manager appends 6 random characters to every secret ARN (`...secret:keycloak-demo/db-credentials-a3f9c1-AbC123`). Without the wildcard, nothing matches.

**Two actions only.** Note what's absent: no `PutSecretValue` (can't overwrite), no `DeleteSecret` (can't destroy), no `ListSecrets` (can't even enumerate what exists). If someone breaks into the web server, the worst they get is a database password to a database they'd still need network access to reach.

### The instance profile

```hcl
resource "aws_iam_instance_profile" "keycloak" {
  name = "${var.project_name}-keycloak-profile-${random_id.suffix.hex}"
  role = aws_iam_role.keycloak.name
}
```

An EC2 instance cannot attach to a role directly. It needs this wrapper. Nobody knows exactly why AWS designed it this way; just remember: **role for permissions, instance profile to hand it to an EC2.**

### How the badge actually works at runtime

```
1. EC2 boots
2. AWS puts temporary credentials at http://169.254.169.254/latest/meta-data/iam/...
   (a magic link-local address that only exists inside the instance)
3. The AWS CLI on the box finds them automatically
4. Credentials auto-rotate every ~6 hours
5. Nothing is ever stored on disk
```

That address, `169.254.169.254`, is the **Instance Metadata Service (IMDS)**. Remember it — the `metadata_options` block in `03-keycloak.tf` exists entirely to protect it.

---

## Section 11 — The RDS subnet group

```hcl
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnets"
  description = "Private subnets for the Keycloak database"
  subnet_ids  = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = { Name = "${var.project_name}-db-subnets" }
}
```

RDS doesn't take a list of subnets directly. It takes a *named group* of them. This resource just says "these two private streets are where databases may live."

The two-AZ requirement is enforced here — pass one subnet and Terraform fails at apply with a clear error.

> Same `name` vs `name_prefix` issue as the security groups. See [07](07-known-bugs-and-fixes.md).

---

## Section 12 — Outputs

```hcl
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}
```

Outputs do three jobs:

1. **Print useful values** after apply
2. **Feed other modules** if you turn this into reusable code
3. **Feed other Terraform states** via `terraform_remote_state`

```bash
terraform output                     # everything, pretty-printed
terraform output vpc_id              # one value, with quotes
terraform output -raw vpc_id         # one value, no quotes — for scripts
terraform output -json | jq .        # machine-readable
```

That `-raw` form is what makes this work:

```bash
aws ec2 describe-vpcs --vpc-ids $(terraform output -raw vpc_id)
```

### Note on sensitive outputs

```hcl
output "db_password" {
  value     = random_password.db.result
  sensitive = true      # prints as <sensitive> instead of the value
}
```

`sensitive = true` hides it from the terminal — but it is **still in plain text in the state file**. Marking things sensitive is politeness, not security. Encrypting the state file is security.

---

## Quick reference: what this file created

| Resource | Count | Cost |
|---|---|---|
| VPC | 1 | free |
| Internet Gateway | 1 | free |
| Subnets | 3 | free |
| Route tables + associations | 2 + 3 | free |
| Security groups | 2 | free |
| Security group rules | 5 | free |
| IAM role, policy, attachments, instance profile | 5 | free |
| DB subnet group | 1 | free |
| **Total** | **~23** | **$0.00** |

[← Back to START HERE](00-START-HERE.md) | [Next: the database →](02-database-line-by-line.md)
# `02-database.tf` — Every Line Explained

[← Previous: the network](01-network-line-by-line.md) | [Next: Keycloak →](03-keycloak-line-by-line.md)

This file builds the **filing cabinet**: a managed PostgreSQL database where Keycloak stores every user, realm, client, role and session. It also generates the password and hides it in a vault.

**This is the expensive file** — about $15/month of the ~$29 total.

---

## First: why a database at all?

Keycloak is a Java program. Java programs forget everything when they restart. So every user account, every group, every "log in with Google" setting has to be written down somewhere permanent.

Keycloak supports PostgreSQL, MySQL, MariaDB, Oracle, and MS SQL Server. It also ships with an embedded H2 database for demos.

> **Never use the embedded H2 database for anything real.** It lives inside the container. Restart the container the wrong way and every user you created is gone. Keycloak's own docs say it's for development only.

### Why RDS instead of running PostgreSQL on the EC2?

| | PostgreSQL on your EC2 | Amazon RDS (this) |
|---|---|---|
| Price | Free (shares the server) | ~$15/month |
| Backups | You write a cron job | Automatic, daily, point-in-time recovery |
| Patching | You do it, on a Saturday | Automatic in a maintenance window |
| Failover | None; server dies, data dies | Optional automatic standby |
| Encrypted disk | You configure LUKS | One line: `storage_encrypted = true` |
| Blast radius | App crash can take the DB with it | Separate machine, separate failure |
| Monitoring | You install it | Performance Insights included free |

For learning, the $15 buys you the correct architecture. Separating the app from the data is the single most valuable structural habit in this entire project.

---

## Section 1 — Variables

```hcl
variable "db_engine_version" {
  description = "PostgreSQL major.minor version. 18.3 is current on RDS as of mid-2026."
  type        = string
  default     = "18.3"
}
```

> **📌 Version note (verified July 2026):** RDS now offers **18.4** (released May 2026), along with 17.10, 16.14, 15.18 and 14.23. PostgreSQL 18 arrived on RDS in November 2025. `18.3` still works but is one patch behind.

### The three ways to pin a database version

| You write | Behaviour | Pro | Con |
|---|---|---|---|
| `"18.3"` | Exactly 18.3 | Perfectly reproducible | You must manually bump for security patches |
| `"18"` ⭐ | Latest 18.x available | AWS picks the newest patched minor at create time | The exact version differs between two applies months apart |
| `"18.4"` | Exactly 18.4 | Current best patch | Same manual-bump problem |

**Recommended:** use `"18"` together with `auto_minor_version_upgrade = true`. AWS picks a good current minor at creation and quietly patches you during the maintenance window. Security fixes land without you doing anything.

```hcl
variable "db_engine_version" {
  description = "PostgreSQL major version. Use '18' to let AWS pick the newest patch level."
  type        = string
  default     = "18"
}
```

> **Careful:** if you pin `"18.3"` and let auto-upgrade move you to 18.4, the next `terraform plan` will show a diff trying to *downgrade* you. That's confusing and it fails. Either use the major-only form, or add `lifecycle { ignore_changes = [engine_version] }`.

### Instance class

```hcl
variable "db_instance_class" {
  description = <<-EOT
    Size of the database server.
    db.t4g.micro  - cheapest, ARM Graviton, ~2 vCPU burst / 1 GB RAM. Fine for a lab.
    db.t4g.small  - 2 GB RAM. Better if you expect real users.
    db.m7g.large  - production-grade.
  EOT
  type        = string
  default     = "db.t4g.micro"
}
```

**`<<-EOT ... EOT` is a heredoc** — a multi-line string. The `-` means "strip the leading indentation," so the text lines up nicely in code without dragging spaces into the value.

**Reading an instance name:**

```
db.t4g.micro
|   |   |
|   |   +-- size within the family
|   +------ family: t=burstable, m=balanced, r=memory-heavy; 4=generation; g=Graviton(ARM)
+---------- it's a database instance
```

| Class | vCPU | RAM | ~$/month | Good for |
|---|---|---|---|---|
| `db.t4g.micro` | 2 burst | 1 GB | ~$12 | Lab, under ~50 users |
| `db.t4g.small` | 2 burst | 2 GB | ~$25 | Small production |
| `db.t4g.medium` | 2 burst | 4 GB | ~$50 | Real production |
| `db.m7g.large` | 2 steady | 8 GB | ~$120 | Serious production |

**What "burstable" means.** A `t`-class instance earns CPU credits while idle and spends them when busy. Run flat-out for hours and you exhaust the credits, then get throttled to a baseline (10–20% of a core) and everything crawls. Fine for a login server that's idle most of the time; dangerous for constant load.

**Why Graviton (`g`)?** ARM chips designed by AWS. Roughly 20% cheaper and often faster than the Intel equivalent. There's no downside for a managed database — you never see the CPU. (For EC2 it matters: your Docker images must be ARM-compatible. Keycloak's official image is multi-arch, so it's fine.)

### Storage, name, username

```hcl
variable "db_allocated_storage" { default = 20 }
variable "db_name"              { default = "keycloak" }
variable "db_username"          { default = "kcadmin" }
```

- **20 GB** is the minimum billable size for gp3. Keycloak with a few thousand users uses well under 1 GB. You're paying the floor either way.
- **`db_name`** is the database *inside* the PostgreSQL server. One server can hold many databases.
- **`db_username`** — the comment is correct: `postgres`, `admin`, and `rdsadmin` are reserved and RDS will reject them. `kcadmin` is fine.

### The booleans

```hcl
variable "db_multi_az"              { default = false }
variable "db_backup_retention_days" { default = 7 }
variable "db_deletion_protection"   { default = false }
```

**`db_multi_az`** — the big one:

| | `false` (default here) | `true` |
|---|---|---|
| Cost | 1× | **2×** |
| If the AZ fails | You're down until you restore a backup | Automatic failover in 60–120 seconds |
| During maintenance | ~5 minutes of downtime | Near-zero (patch standby, fail over, patch old primary) |
| Use for | Labs, dev | Anything real |

**`db_backup_retention_days = 7`** — this also enables **point-in-time recovery**. RDS continuously ships the transaction log, so you can restore to any second within the window, not just to a nightly snapshot. Setting it to `0` disables backups *and* PITR. Backup storage equal to your database size is free.

**`db_deletion_protection = false`** — with `true`, AWS refuses to delete the database even if Terraform asks. `terraform destroy` fails with a confusing error and you have to disable it manually first.

| | Pro | Con |
|---|---|---|
| `false` (lab) | `terraform destroy` just works | One typo can delete production |
| `true` (prod) | Saves you from yourself | Two-step teardown, and you'll forget why destroy failed |

**Best practice:** wire it to the environment so it's automatic.

```hcl
locals {
  is_production = var.environment == "prod"
}

resource "aws_db_instance" "keycloak" {
  deletion_protection       = local.is_production
  skip_final_snapshot       = !local.is_production
  backup_retention_period   = local.is_production ? 30 : 7
  multi_az                  = local.is_production
}
```

---

## Section 2 — Password generation

```hcl
resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}
```

| Line | Meaning |
|---|---|
| `length = 32` | 32 characters. With ~90 possible characters each, that's roughly 200 bits of entropy — unguessable by any computer that will ever exist. |
| `special = true` | Include punctuation |
| `override_special` | Use *only* these punctuation marks |
| `min_*` | Guarantee at least 2 of each category |

**Why restrict the punctuation?** RDS forbids `/`, `@`, `"`, and spaces in master passwords, because those characters break connection strings. `@` separates user from host; `/` separates host from database name.

> **⚠️ This list is still too permissive.** It includes `$`, `%`, `&` and `#`, which cause real, hard-to-debug breakage later in `03-keycloak.tf`:
> - `%` is a **systemd specifier** — systemd tries to expand `%s` and mangles the password
> - `$` is a **systemd variable marker** — same problem
> - `#` starts a **comment** in some property-file parsers
>
> See [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md) for the full explanation. The safe list is:
> ```hcl
> override_special = "!*()-_=+[]{}:?"
> ```

### Where does the password live?

| Place | Is the password there? |
|---|---|
| Your `.tf` files | ❌ No |
| Your shell history | ❌ No |
| Your Git repo | ❌ No |
| Secrets Manager | ✅ Yes, encrypted |
| **The Terraform state file** | ⚠️ **YES, IN PLAIN TEXT** |

That last row is the one people miss. `random_password` stores its result in state so it stays stable across runs. Anyone who reads `terraform.tfstate` reads your database password.

**Therefore:**
- `terraform.tfstate` goes in `.gitignore` — always
- In a team, state goes in an encrypted remote backend ([05-gitlab-pipeline.md](05-gitlab-pipeline.md))
- Restrict who can read the state bucket the same way you'd restrict who can read the password

---

## Section 3 — Secrets Manager

```hcl
resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.project_name}/db-credentials-${random_id.suffix.hex}"
  description             = "Keycloak RDS PostgreSQL master credentials"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}-db-credentials" }
}
```

### The name is load-bearing

`keycloak-demo/db-credentials-a3f9c1`

Look back at the IAM policy in `01-network.tf`:

```
arn:aws:secretsmanager:...:secret:${var.project_name}/db-*
```

The `/db-` in the middle is **not decoration**. If you rename this secret to `keycloak-demo/database-creds`, the IAM policy stops matching, the EC2 can't read it, and the server boots into a cryptic AccessDenied at step 3 of 8.

Slashes in secret names are just naming convention — they create folder-like grouping in the console.

### `recovery_window_in_days = 0`

Secrets Manager normally *soft-deletes*: the secret is scheduled for deletion 7–30 days out, and the name stays reserved that whole time.

| Value | Behaviour | Use when |
|---|---|---|
| `0` | Delete immediately and free the name | Learning — lets you destroy/apply repeatedly |
| `7` | 7-day grace period | Staging |
| `30` | 30-day grace period | **Production.** A deleted production credential is recoverable. |

Without `0`, running `terraform destroy` then `terraform apply` fails with *"You can't create this secret because a secret with this name is already scheduled for deletion."* This is why the `random_id` suffix exists too — belt and braces.

### The secret's contents

```hcl
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "postgres"
    host     = aws_db_instance.keycloak.address
    port     = 5432
    dbname   = var.db_name
  })
}
```

The **secret** is the container; the **version** is the contents. Secrets Manager keeps a history of versions so you can roll back a bad rotation.

`jsonencode()` turns an HCL map into a JSON string:

```json
{"username":"kcadmin","password":"Xk9...","engine":"postgres","host":"keycloak-demo-db.abc.us-east-1.rds.amazonaws.com","port":5432,"dbname":"keycloak"}
```

**Those six keys are not arbitrary.** They are the exact field names AWS's own rotation Lambdas expect. Use them and you can turn on automatic password rotation later without changing a thing.

Note the ordering trick: this resource references `aws_db_instance.keycloak.address`, so Terraform automatically creates the database *first*, then writes the secret with the real hostname in it.

### ⭐ Making it better: automatic rotation

```hcl
resource "aws_secretsmanager_secret_rotation" "db" {
  secret_id           = aws_secretsmanager_secret.db.id
  rotation_lambda_arn = aws_lambda_function.rotate.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

AWS publishes ready-made rotation Lambdas for RDS PostgreSQL in the Serverless Application Repository. Every 30 days it generates a new password, updates RDS, and stores the new version. Keycloak needs a restart or a connection-pool refresh to pick it up — which is why the `ignore_changes = [password]` lifecycle rule further down matters.

---

## Section 4 — The parameter group

```hcl
resource "aws_db_parameter_group" "keycloak" {
  name        = "${var.project_name}-pg18-params"
  family      = "postgres18"
  description = "Keycloak tuning for PostgreSQL 18"
  ...
}
```

A parameter group is the database's settings file (`postgresql.conf`), managed by AWS. You can't SSH into RDS to edit config files, so this is how you change settings.

**`family = "postgres18"` must match your engine version's major number.** Set `engine_version = "17.10"` with `family = "postgres18"` and apply fails.

### ⭐ `rds.force_ssl = 1` — the most valuable line in this file

```hcl
parameter {
  name  = "rds.force_ssl"
  value = "1"
}
```

Without it, a client can connect in plain text and PostgreSQL happily accepts. The password and every query cross the network readable.

With it, PostgreSQL **refuses** any non-TLS connection. This is not a suggestion to clients — it's enforcement at the server.

> **Note:** in PostgreSQL 15+ on RDS this parameter is a *static* parameter for some engine families, meaning it needs a reboot to take effect. If you add it to an existing database, reboot it.

### `log_min_duration_statement = 1000`

Log any query that takes longer than 1000 milliseconds.

| Value | Effect |
|---|---|
| `-1` | Log nothing (default) |
| `0` | Log **every** query — huge log volume, real performance hit |
| `1000` ✅ | Log only the slow ones |

When the login page suddenly takes 8 seconds, this log tells you which query to blame.

### `max_connections = 150`

```hcl
parameter {
  name         = "max_connections"
  value        = "150"
  apply_method = "pending-reboot"
}
```

**`apply_method` is the important part here.** RDS parameters come in two kinds:

| Kind | `apply_method` | When it takes effect |
|---|---|---|
| Dynamic | `immediate` (default) | Right away, no downtime |
| Static | `pending-reboot` | Only after a reboot |

`max_connections` is static. If you don't say `pending-reboot`, Terraform tries to apply it immediately, AWS rejects it, and apply fails.

**Where does 150 come from?** RDS's default is a formula based on RAM: roughly `DBInstanceClassMemory / 9531392`. On a 1 GB `db.t4g.micro` that's about 112. Keycloak's pool is configured for max 20 connections per node, so 150 leaves plenty of headroom for 2–3 Keycloak nodes plus your own `psql` sessions.

**The trap:** every connection costs ~10 MB of RAM on the server. Setting `max_connections = 1000` on a 1 GB instance doesn't give you 1000 connections — it gives you an out-of-memory crash.

---

## Section 5 — The database instance

### Engine

```hcl
resource "aws_db_instance" "keycloak" {
  identifier = "${var.project_name}-db"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  auto_minor_version_upgrade = true
```

`identifier` is the DNS-ish name AWS uses. It appears in the endpoint hostname and must be unique in your account+region.

**`auto_minor_version_upgrade = true`** lets AWS move you 18.3 → 18.4 during the maintenance window.

| | Pro | Con |
|---|---|---|
| `true` ✅ | Security patches apply automatically | A brief restart happens on AWS's schedule |
| `false` | Total control | You will forget, and run a vulnerable database for two years |

Major versions (18 → 19) are **never** automatic. Those change behaviour and need testing.

### Storage

```hcl
  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_encrypted     = true
```

| Type | Baseline IOPS | Notes |
|---|---|---|
| `gp2` (old) | 3 per GB → 60 IOPS at 20 GB | Slow at small sizes |
| `gp3` ✅ | **3000 flat**, regardless of size | Same price, 50× the performance at 20 GB |
| `io2` | Up to 256,000, you pay per IOPS | Expensive; for heavy workloads |

`gp3` at small sizes is a straight free upgrade. Always use it.

**`max_allocated_storage = 100`** (that's `20 * 5`) enables **storage autoscaling**: if the disk hits ~90% full, RDS grows it automatically, up to 100 GB, with no downtime. You only pay for what's allocated. This prevents the classic 3 a.m. "disk full, database read-only" page.

**`storage_encrypted = true`** — encryption at rest with a KMS key. It is **free** and there is **no performance cost**.

> **The one-way door:** you cannot enable encryption on an existing unencrypted RDS instance. You'd have to snapshot, copy the snapshot with encryption, and restore. Always turn it on at creation. Always.

Add `kms_key_id` if you want your own customer-managed key instead of the AWS-managed default — needed for cross-account snapshot sharing and for compliance frameworks that require key rotation control.

### Credentials

```hcl
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
```

The password goes straight from the `random_password` resource into RDS. It never touches a variable file or your terminal.

> Also available: `manage_master_user_password = true`, which hands password management entirely to AWS. AWS creates the secret, rotates it, and you never see it. It's newer and cleaner — but then Keycloak has to read AWS's generated secret name, which changes the IAM policy and the bootstrap script. Worth knowing about; the explicit approach here is easier to follow.

### Networking

```hcl
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]

  publicly_accessible = false
```

### ⭐⭐ `publicly_accessible = false` — the most important line in this file

| Setting | What AWS does |
|---|---|
| `true` | Gives the database a **public IP** and a publicly resolvable DNS name |
| `false` ✅ | Private IP only. The hostname resolves only inside the VPC. |

Publicly accessible RDS instances are one of the most common serious cloud misconfigurations. Combined with a lazy security group (`0.0.0.0/0` on 5432), it means anyone on the internet can attempt to log in to your database. Scanners find these within minutes of creation.

Here, three separate layers say no:
1. `publicly_accessible = false` — no public address exists
2. The private subnets have no route to the internet gateway
3. The security group only allows the Keycloak security group

Any one of those alone would stop an attacker. All three is how you sleep at night.

### Backups and maintenance

```hcl
  backup_retention_period = var.db_backup_retention_days
  backup_window           = "07:00-08:00"
  maintenance_window      = "Mon:08:30-Mon:09:30"
  copy_tags_to_snapshot   = true
```

**All times are UTC.** `07:00-08:00 UTC` is 2–3 a.m. US Central — deliberately chosen for low traffic. Adjust for your users.

Backups cause a brief I/O pause on single-AZ instances. On Multi-AZ, the snapshot comes from the standby and users notice nothing.

The windows must not overlap, and the maintenance window has to be at least 30 minutes.

`copy_tags_to_snapshot = true` means your `Project` and `Environment` tags follow the snapshots, so your cost reports stay accurate and cleanup scripts can find old snapshots.

### Monitoring

```hcl
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]
```

**Performance Insights** is a graph of "what is the database waiting on?" broken down by SQL statement, user, and wait event. It answers "why is it slow" faster than anything else. **7 days of retention is free.** Longer retention costs money. There is no reason not to turn this on.

**`enabled_cloudwatch_logs_exports`** ships the PostgreSQL log and the upgrade log to CloudWatch Logs, where they survive the instance. Without this, logs live only on the instance and vanish with it. CloudWatch Logs charges about $0.50/GB ingested — pennies for a small database.

### Deletion behaviour

```hcl
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = true
  final_snapshot_identifier = null
```

**`skip_final_snapshot = true`** means: when this database is deleted, **do not** take a farewell backup. The data is gone forever, instantly.

| | For learning | For production |
|---|---|---|
| `skip_final_snapshot` | `true` — destroy is fast and free | **`false`** |
| `final_snapshot_identifier` | `null` | `"keycloak-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"` |

Production version:

```hcl
skip_final_snapshot       = false
final_snapshot_identifier = "${var.project_name}-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
```

The timestamp is required because snapshot names must be unique — reuse one and the delete fails.

### The lifecycle rule

```hcl
  lifecycle {
    ignore_changes = [password]
  }
```

Translation: *"If the real password in AWS stops matching what I have in state, don't fix it."*

Without this, the moment you enable automatic rotation, every `terraform plan` would want to reset the password back to its original value — undoing the rotation and breaking your app.

Other lifecycle rules worth knowing:

```hcl
lifecycle {
  prevent_destroy = true                      # terraform refuses to delete this, ever
  ignore_changes  = [password, engine_version]
  create_before_destroy = true
  replace_triggered_by = [aws_instance.x.id]  # rebuild me when that changes
}
```

`prevent_destroy = true` on a production database is a very good idea. It turns an accidental `terraform destroy` into an error message instead of a résumé-updating event.

---

## Section 6 — Outputs

```hcl
output "db_endpoint" {
  value = aws_db_instance.keycloak.address
}
```

**`.address` vs `.endpoint`** — a trap worth knowing:

| Attribute | Returns |
|---|---|
| `.address` | `keycloak-demo-db.abc123.us-east-1.rds.amazonaws.com` |
| `.endpoint` | `keycloak-demo-db.abc123.us-east-1.rds.amazonaws.com**:5432**` |

`.endpoint` includes the port. Paste it into a JDBC URL that already has `:5432` and you get `...com:5432:5432/keycloak`, which fails with a confusing parse error. This file correctly uses `.address` and adds the port separately.

### The JDBC URL output

```hcl
output "db_jdbc_url" {
  value = "jdbc:postgresql://${aws_db_instance.keycloak.address}:${aws_db_instance.keycloak.port}/${var.db_name}?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem"
}
```

Broken apart:

| Piece | Meaning |
|---|---|
| `jdbc:postgresql://` | Java's driver prefix |
| `keycloak-demo-db...com` | the host |
| `:5432` | the port |
| `/keycloak` | the database name |
| `?sslmode=verify-full` | **the security setting** |
| `&sslrootcert=...` | which certificate authority to trust |

### ⭐ The `sslmode` ladder — know these five words

| Mode | Encrypts? | Checks the certificate is valid? | Checks the hostname matches? |
|---|---|---|---|
| `disable` | ❌ | ❌ | ❌ |
| `require` | ✅ | ❌ | ❌ |
| `verify-ca` | ✅ | ✅ | ❌ |
| **`verify-full`** ✅ | ✅ | ✅ | ✅ |

**Why `require` is not good enough.** `require` encrypts the traffic but accepts *any* certificate. An attacker who can redirect your DNS or sit on the network path presents their own certificate, your client accepts it, and they read everything while forwarding it to the real database. That's a **man-in-the-middle** attack, and `require` does not stop it.

`verify-full` checks that the certificate was signed by a CA you trust *and* that the name on it matches the host you asked for. That's the whole point of TLS.

This is why `03-keycloak.tf` downloads `rds-ca.pem` at boot — `verify-full` needs a trust anchor, and Amazon's RDS certificate authority isn't in the default Java truststore.

**This project gets this right, and most tutorials don't.** It's genuinely the difference between "we use SSL" and "we use SSL correctly."

---

## Quick reference: what this file created

| Resource | Cost/month |
|---|---|
| `random_password` | free (local) |
| Secrets Manager secret + version | ~$0.40 |
| DB parameter group | free |
| **RDS instance** `db.t4g.micro` | ~$12.40 |
| 20 GB gp3 storage | ~$2.30 |
| 7 days of backups | free |
| Performance Insights (7 days) | free |
| CloudWatch log export | ~$0.10 |
| **Total** | **≈ $15.20** |

[← Previous: the network](01-network-line-by-line.md) | [Next: Keycloak →](03-keycloak-line-by-line.md)
# `03-keycloak.tf` — Every Line Explained

[← Previous: the database](02-database-line-by-line.md) | [Next: verify & destroy →](04-verify-and-destroy.md)

This file builds the **shop**: a virtual computer, a permanent address, and a startup script that installs and configures Keycloak from nothing.

This is the most complicated file, because it contains two languages at once: Terraform (HCL) on the outside, and a Bash script on the inside.

---

## Section 1 — Variables

```hcl
variable "keycloak_version" {
  description = "Keycloak release. 26.7.0 is the current supported release (July 2026)."
  type        = string
  default     = "26.7.0"
}
```

> **📌 Verified July 2026:** Keycloak 26.7.0 (released July 2026) is the current supported release. 26.6 reached end-of-life on 9 July 2026. Keycloak only actively supports the latest release, so staying current is not optional — 26.7.0 fixed a batch of CVEs including an admin-role privilege escalation and an OIDC redirect-URI parameter-pollution flaw.

**Always pin an exact version. Never use `latest`.**

| Tag | Pro | Con |
|---|---|---|
| `26.7.0` ✅ | Reproducible; you know what you're running | You must bump it deliberately |
| `26.7` | Gets patch fixes | Slightly less reproducible |
| `latest` | Always newest | A rebuild six months from now silently installs a different major version with breaking config changes |

### Instance type

```hcl
variable "instance_type" {
  description = <<-EOT
    EC2 size. Keycloak is a Java app and wants RAM more than CPU.
    t4g.small  - 2 GB RAM, ARM Graviton. Minimum that runs comfortably.
    t4g.medium - 4 GB RAM. Recommended.
    t4g.large  - 8 GB RAM. Production single node.
  EOT
  type        = string
  default     = "t4g.small"
}
```

Keycloak runs on the JVM. The JVM reserves a chunk of memory up front and is unhappy in cramped spaces.

| Type | RAM | ~$/month | Verdict |
|---|---|---|---|
| `t4g.micro` | 1 GB | ~$6 | ❌ Keycloak will get OOM-killed |
| `t4g.small` | 2 GB | ~$12 | ✅ Works. Tight but fine for a lab. |
| `t4g.medium` | 4 GB | ~$24 | ✅ Comfortable |
| `t4g.large` | 8 GB | ~$49 | Production single node |

> **The `g` matters.** `t4g` = ARM/Graviton. `t3` = Intel. The AMI lookup below fetches the **arm64** image, so switching to `t3.small` without also changing the AMI parameter gives you `InvalidParameterValue: The architecture 'arm64' is not supported`. If you change one, change both.

### The rest

```hcl
variable "keycloak_admin_user" { default = "kcadmin" }
variable "ssh_key_name"        { default = "" }
variable "root_volume_size"    { default = 20 }
```

**`ssh_key_name = ""`** is deliberate and good: no SSH key at all. You get a shell through SSM Session Manager instead. See how the empty string is handled further down.

**20 GB root volume** breaks down roughly as: OS ~3 GB, Docker + images ~2 GB, logs and headroom the rest. Don't go below 10 GB — Docker image builds will fail with "no space left on device," which is an annoying thing to debug through a boot log.

---

## Section 2 — Finding the operating system image

```hcl
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}
```

An **AMI** (Amazon Machine Image) is the disk image an instance starts from. Every AMI has an ID like `ami-0abc123def456`.

The problem: **AMI IDs are different in every region and change every time Amazon patches the image.** Hard-code one and your code works in exactly one region until Amazon retires that image.

The fix: AWS publishes the current ID in a public SSM Parameter Store path. This data source reads it, so you always launch the newest patched Amazon Linux 2023 for ARM, in whatever region you're building in.

Decoding the path:

```
/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64
                                     |      |            |       |
                                     |      |            |       +-- CPU architecture
                                     |      |            +---------- default kernel
                                     |      +----------------------- it's an AMI
                                     +------------------------------ Amazon Linux 2023
```

Swap `arm64` for `x86_64` if you switch to an Intel instance type.

| | Pro | Con |
|---|---|---|
| SSM parameter lookup ✅ | Always current, always region-correct, no maintenance | The AMI ID can change between plan and apply, showing a diff you didn't expect |
| Hard-coded AMI ID | Perfectly reproducible | Stale, insecure, region-locked |
| `data "aws_ami"` with filters | Flexible, works for custom images | More code; a bad filter silently picks the wrong image |

> **Real-world note:** because the AMI ID changes when Amazon patches, a `terraform plan` months later may show your EC2 instance needs replacing. That's Terraform correctly noticing the world moved. If you don't want surprise replacements, add `lifecycle { ignore_changes = [ami] }` and upgrade deliberately.

---

## Section 3 — The Keycloak admin password

```hcl
resource "random_password" "keycloak_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*-_=+"
  ...
}

resource "aws_secretsmanager_secret" "keycloak_admin" {
  name                    = "${var.project_name}/db-keycloak-admin-${random_id.suffix.hex}"
  recovery_window_in_days = 0
}
```

Same pattern as the database password. But look closely at the name:

```
keycloak-demo/db-keycloak-admin-a3f9c1
              ^^^^
```

**`db-`?** This is not a database credential. It's the web console admin password.

The reason is a shortcut: the IAM policy in `01-network.tf` only allows reading secrets matching `${var.project_name}/db-*`. By squeezing `db-` into this name, the existing policy covers it without a second statement.

| | Pro | Con |
|---|---|---|
| Reuse the `db-` prefix (as written) | Zero extra IAM code | Misleading name; a future reader assumes it's a DB secret and may "fix" it, silently breaking boot |

**The honest fix** — one extra statement, clear names:

```hcl
data "aws_iam_policy_document" "read_secrets" {
  statement {
    sid     = "ReadKeycloakSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/db-*",
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}/admin-*",
    ]
  }
}
```

Then rename the secret to `${var.project_name}/admin-console-${random_id.suffix.hex}`.

---

## Section 4 — The Elastic IP

```hcl
resource "aws_eip" "keycloak" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-keycloak-eip" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip_association" "keycloak" {
  instance_id   = aws_instance.keycloak.id
  allocation_id = aws_eip.keycloak.id
}
```

A normal EC2 public IP is **temporary**. Stop and start the instance and you get a different one. Every bookmark breaks, and — worse here — the TLS certificate was generated for the *old* address.

An Elastic IP is a public address you reserve and keep.

| Line | Why |
|---|---|
| `domain = "vpc"` | The modern kind. (`"standard"` was EC2-Classic, retired in 2022.) |
| `depends_on = [aws_internet_gateway.main]` | An EIP is useless without a path to the internet. This forces the correct order — Terraform can't infer it because there's no direct reference. |

**Why is the association a separate resource?** Because the EIP must exist *before* the instance boots — the bootstrap script bakes `aws_eip.keycloak.public_ip` into the certificate and the Keycloak config. If the EIP were an argument on the instance, you'd have a circular dependency.

Order of operations:
1. EIP is allocated → its address is now known
2. Instance is created, with that address baked into `user_data`
3. Instance boots and starts configuring itself
4. `aws_eip_association` attaches the address

> **⚠️ Subtle race:** steps 3 and 4 overlap. For the first ~30 seconds the instance has a *different*, auto-assigned public IP, while its config already refers to the Elastic IP. This is harmless here because the config only uses the address as a *name*, not to bind a socket. But if you extend the script to fetch a Let's Encrypt certificate at boot, that validation will fail against the wrong address. See [06](06-make-it-configurable.md).

### 💰 Elastic IP billing trap

| State | Cost |
|---|---|
| Attached to a **running** instance | free |
| Attached to a **stopped** instance | ~$3.60/month |
| Not attached to anything | ~$3.60/month |

AWS charges for idle addresses to discourage hoarding. **After `terraform destroy`, always confirm no EIPs survived** — see [04-verify-and-destroy.md](04-verify-and-destroy.md).

---

## Section 5 — The bootstrap script

```hcl
locals {
  user_data = <<-BOOTSTRAP
#!/bin/bash
...
  BOOTSTRAP
}
```

### What is `locals`?

A named value computed once and reused. Think of it as a constant.

| | `variable` | `local` |
|---|---|---|
| Set from outside | ✅ yes | ❌ no |
| Can be computed from other values | ❌ no | ✅ yes |
| Referenced as | `var.name` | `local.name` |

### What is `user_data`?

A script AWS runs **once**, **as root**, the **first time** the instance boots. It's how a blank server turns itself into a configured one with no human involved. This is often called *bootstrapping* or *cloud-init*.

### ⚠️ The two-language problem

Inside that heredoc, **Terraform interpolates first, Bash runs second.**

| Syntax | Who handles it | Result |
|---|---|---|
| `${var.db_name}` | **Terraform**, at plan time | Replaced with `keycloak` before AWS ever sees it |
| `$DB_USER` | **Bash**, at boot time | Terraform ignores it (no braces) |
| `${DB_USER}` | ⚠️ **Terraform** | Terraform tries to find a variable called `DB_USER`, fails, and errors |
| `$${DB_USER}` | Escaped | Terraform emits a literal `${DB_USER}` for Bash |

**This script survives only because it consistently writes `$DB_USER` without braces.** If you edit it and add braces out of habit, you get a confusing plan-time error. Remember this rule:

> **In Terraform heredocs: no curly braces on bash variables.**

The same applies to `%{` — that's Terraform's directive syntax. A bash `printf "%{...}"` would need `%%{`.

---

### The script, step by step

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/keycloak-bootstrap.log | logger -t keycloak-bootstrap) 2>&1
```

| Flag | Meaning |
|---|---|
| `-e` | Exit immediately if any command fails. Without this, a failed download leaves you with a half-configured server that *looks* fine. |
| `-u` | Error on undefined variables. Catches typos. |
| `-x` | Print every command before running it. Makes the log readable. |
| `-o pipefail` | A pipeline fails if *any* stage fails, not just the last one |

The `exec` line sends all output to both a log file and the system journal, so you can read it two ways after the fact. This is genuinely good scripting practice — most tutorials skip it and then can't debug.

#### Step 1/8 — Install packages

```bash
dnf update -y
dnf install -y docker jq awscli tar gzip openssl
systemctl enable --now docker
```

`dnf` is the package manager on Amazon Linux 2023 (the successor to `yum`). `-y` means "answer yes to everything" — required, since nobody is at the keyboard.

`systemctl enable --now docker` does two things: start Docker now, **and** start it automatically on every future boot. Forgetting `enable` is why some servers work until the first reboot.

#### Step 2/8 — Make directories

```bash
mkdir -p /opt/keycloak/conf
```

`-p` creates parent directories and doesn't complain if they already exist. `/opt` is the standard Linux location for add-on software.

#### Step 3/8 — Read the secrets

```bash
export AWS_DEFAULT_REGION="${data.aws_region.current.name}"

DB_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${aws_secretsmanager_secret.db.name}" \
  --query SecretString --output text)
DB_USER=$(echo "$DB_SECRET" | jq -r .username)
DB_PASS=$(echo "$DB_SECRET" | jq -r .password)
```

**This is the payoff for all that IAM work in `01-network.tf`.** There are no credentials in this script. The AWS CLI finds the instance's role automatically through the metadata service, gets temporary keys, and calls Secrets Manager. The IAM policy allows exactly this one call on exactly these secrets.

- `$( ... )` = command substitution: run it, capture the output
- `--query SecretString --output text` = pull one field out, unquoted
- `jq -r .username` = read the `username` key from the JSON; `-r` strips the quotes

#### Step 4/8 — Download Amazon's certificate authority

```bash
curl -fsSL -o /opt/keycloak/conf/rds-ca.pem \
  "https://truststore.pki.rds.amazonaws.com/${data.aws_region.current.name}/${data.aws_region.current.name}-bundle.pem"
chmod 644 /opt/keycloak/conf/rds-ca.pem
```

| Flag | Meaning |
|---|---|
| `-f` | Fail loudly on HTTP errors (without it, curl saves the 404 page as your certificate) |
| `-s` | Silent |
| `-S` | ...but still show errors |
| `-L` | Follow redirects |

This is what makes `sslmode=verify-full` possible. Java's default truststore doesn't include Amazon's RDS certificate authority, so without this file Keycloak can't verify the database's identity and refuses to connect.

`chmod 644` = owner can write, everyone can read. A public certificate is *supposed* to be readable — it's a public key, not a secret.

#### Step 5/8 — Make a self-signed certificate

```bash
PUBLIC_IP="${aws_eip.keycloak.public_ip}"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
  -keyout /opt/keycloak/conf/server.key.pem \
  -out /opt/keycloak/conf/server.crt.pem \
  -days 3650 \
  -subj "/CN=$PUBLIC_IP" \
  -addext "subjectAltName=IP:$PUBLIC_IP"
```

| Flag | Meaning |
|---|---|
| `-x509` | Make a finished certificate, not a request to be signed by someone else |
| `-newkey rsa:2048` | Generate a fresh 2048-bit RSA key |
| `-nodes` | "No DES" — don't password-protect the key (a service can't type a passphrase at boot) |
| `-sha256` | Modern signature algorithm |
| `-days 3650` | Valid for 10 years |
| `-subj "/CN=$PUBLIC_IP"` | The name on the certificate |
| `-addext "subjectAltName=IP:..."` | **Required.** Browsers have ignored Common Name since ~2017 and only read Subject Alternative Name. |

**Why your browser complains.** A certificate is an ID card. Browsers trust cards issued by ~150 recognised authorities. This card was issued by the server to itself — like a hand-drawn driver's licence. The encryption is real and strong; the *identity* is unverified.

| | Self-signed (here) | Real CA certificate |
|---|---|---|
| Cost | free | free with Let's Encrypt / ACM |
| Setup | 1 command | needs a domain name |
| Browser | scary warning | green padlock |
| Encryption strength | identical | identical |
| Stops man-in-the-middle | ❌ no | ✅ yes |
| API clients / mobile apps | usually refuse to connect | work |

Fine for a lab you access alone. **Not acceptable for real users** — training people to click through certificate warnings destroys the entire value of TLS. [06-make-it-configurable.md § Swap 3](06-make-it-configurable.md) shows three ways to fix it.

#### Step 6/8 — Write `keycloak.conf`

```bash
cat > /opt/keycloak/conf/keycloak.conf <<KCCONF
db=postgres
db-url=jdbc:postgresql://${aws_db_instance.keycloak.address}:5432/${var.db_name}?sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem
db-username=$DB_USER
db-password=$DB_PASS
db-pool-initial-size=5
db-pool-min-size=5
db-pool-max-size=20
...
KCCONF
```

**`cat > file <<MARKER`** writes everything up to `MARKER` into the file. Because `KCCONF` is unquoted, Bash expands `$DB_USER` and `$DB_PASS` as it writes — so the real values land in the file.

Every Keycloak setting explained:

| Setting | Meaning | Trade-offs |
|---|---|---|
| `db=postgres` | Which database driver | `postgres`, `mysql`, `mariadb`, `oracle`, `mssql`, `dev-file` (never in prod) |
| `db-url=...` | Full JDBC URL with TLS enforced | See the `sslmode` table in [02](02-database-line-by-line.md) |
| `db-username` / `db-password` | Credentials, pulled from the vault at boot | |
| `db-pool-initial-size=5` | Open 5 connections at startup | Higher = faster first request, more idle DB load |
| `db-pool-min-size=5` | Never drop below 5 | Keeps latency low during quiet periods |
| `db-pool-max-size=20` | Never exceed 20 | Must be ≤ the database's `max_connections` divided by the number of Keycloak nodes |
| `http-enabled=true` | Also listen on plain HTTP 8080 | **Turn this off** once HTTPS works |
| `http-port=8080` / `https-port=8443` | Ports | Ports below 1024 need root; 8443 avoids that |
| `https-certificate-file` / `-key-file` | The PEM cert and key | Keycloak also accepts a Java keystore |
| `hostname=https://$PUBLIC_IP:8443` | The public address Keycloak believes it has | Keycloak puts this in redirect URLs and tokens. **Get it wrong and login loops forever.** |
| `hostname-strict=false` | Accept requests whose Host header doesn't match | Convenient behind proxies; slightly looser security |
| `health-enabled=true` | Adds `/health/ready` and `/health/live` | Needed for load balancer health checks |
| `metrics-enabled=true` | Adds `/metrics` in Prometheus format | Free observability |
| `log=console` | Log to stdout | Correct for containers — Docker captures stdout |
| `log-level=INFO` | Verbosity | `DEBUG` for troubleshooting; it's very noisy |

> **`hostname` is the #1 cause of Keycloak pain.** Keycloak generates absolute URLs for redirects. If it thinks it lives at `https://1.2.3.4:8443` but you reach it at `https://login.example.com`, the browser gets bounced to the wrong place and you get an infinite redirect loop or "invalid redirect_uri". Behind a load balancer, this must be the *public* name and you must also set `proxy-headers=xforwarded`.

```bash
chown -R 1000:1000 /opt/keycloak/conf
chmod 600 /opt/keycloak/conf/keycloak.conf
```

Inside the official Keycloak image the app runs as UID 1000, not root. The files must be readable by that numeric ID (the container doesn't know your host's usernames — only numbers cross the boundary).

`chmod 600` = only the owner may read. Correct: this file contains the database password.

#### Step 7/8 — Build an optimized image

```bash
cat > /opt/keycloak/Dockerfile <<EOF
FROM quay.io/keycloak/keycloak:${var.keycloak_version}
COPY --chown=1000:1000 conf/ /opt/keycloak/conf/
RUN /opt/keycloak/bin/kc.sh build
EOF

cd /opt/keycloak
docker build -t optimized-keycloak .
```

Keycloak has two modes:

| Mode | What happens at startup | Startup time |
|---|---|---|
| Default | Reads config, re-augments the Quarkus app, then starts | 60–90 seconds |
| **Optimized** (`--optimized`) | Config was already baked in at build time | 15–25 seconds |

`kc.sh build` does the expensive work once, during `docker build`, instead of on every container start. This is Keycloak's officially recommended production pattern.

**Build-time vs run-time settings** — this trips people up constantly:

| Baked in at build (`kc.sh build`) | Read at every start |
|---|---|
| `db` (which driver) | `db-url`, `db-username`, `db-password` |
| `health-enabled`, `metrics-enabled` | `hostname` |
| `features` | `https-certificate-file` |
| `cache` | `log-level` |

Change a build-time setting and you **must** rebuild the image. Change a run-time setting and a restart is enough.

> **⚠️ Security problem here:** `COPY conf/` copies `keycloak.conf` — **including the database password** — into a Docker image layer. Anyone who can run `docker history` or `docker save` on this box can extract it. It's mitigated by the fact that the image never leaves the instance, but it's still a bad habit. See [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md) for the fix (copy only build-time settings; pass secrets as environment variables at run time).

#### Step 8/8 — The systemd service

```bash
cat > /etc/systemd/system/keycloak.service <<UNIT
[Unit]
Description=Keycloak Docker Service
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always
RestartSec=15
ExecStartPre=-/usr/bin/docker rm -f keycloak
ExecStart=/usr/bin/docker run --name keycloak \\
  --ulimit nofile=102642:102642 \\
  -p 8080:8080 -p 8443:8443 \\
  -v /opt/keycloak/conf:/opt/keycloak/conf:ro \\
  -e KC_BOOTSTRAP_ADMIN_USERNAME=$KC_ADMIN_USER \\
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=$KC_ADMIN_PASS \\
  -e JAVA_OPTS_APPEND="-Xms512m -Xmx1024m" \\
  optimized-keycloak \\
  start --optimized
ExecStop=/usr/bin/docker stop keycloak

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now keycloak
```

**systemd** is Linux's service manager: it starts things at boot, restarts them when they crash, and tracks their logs.

| Directive | Meaning |
|---|---|
| `After=docker.service` | Start after Docker (ordering only) |
| `Requires=docker.service` | If Docker fails, this fails too (dependency) |
| `TimeoutStartSec=0` | Never give up waiting for startup |
| `Restart=always` | Crashed? Start it again. Forever. |
| `RestartSec=15` | Wait 15 seconds between attempts, so a crash loop doesn't melt the CPU |
| `ExecStartPre=-...` | Run before the main command. **The leading `-` means "ignore failure"** — the first boot has no container to remove, and that's fine. |
| `ExecStart=` | The actual command |
| `ExecStop=` | Graceful shutdown |
| `WantedBy=multi-user.target` | Start at boot, once the network is up |

Docker flags:

| Flag | Purpose |
|---|---|
| `--name keycloak` | Predictable name for `docker logs keycloak` |
| `--ulimit nofile=102642:102642` | Raise the open-file limit. Keycloak's docs specify this — the JVM plus many sockets exceeds the default 1024. |
| `-p 8080:8080 -p 8443:8443` | Map host ports to container ports |
| `-v /opt/keycloak/conf:/opt/keycloak/conf:ro` | Mount the config folder **read-only** into the container |
| `-e KC_BOOTSTRAP_ADMIN_*` | The temporary admin account, created only on the very first start |
| `-e JAVA_OPTS_APPEND="-Xms512m -Xmx1024m"` | JVM heap: start at 512 MB, cap at 1 GB |
| `start --optimized` | Skip re-augmentation, use the baked-in build |

**Why cap the heap at 1 GB on a 2 GB machine?** The JVM's heap is not its total memory — add metaspace, thread stacks, and native buffers and you're near 1.5 GB. Leave room for the OS and Docker or the kernel's OOM killer terminates Java at the worst possible moment.

> **⚠️ Two real bugs in this unit file.** The unquoted heredoc expands `$KC_ADMIN_PASS` into the file, which means (a) the password sits in plaintext in `/etc/systemd/system/keycloak.service`, and (b) if the password contains `%` or `$` — both of which the generator allows — systemd misinterprets them and the service fails to start with an obscure error. Fixes in [07-known-bugs-and-fixes.md](07-known-bugs-and-fixes.md).

### `KC_BOOTSTRAP_ADMIN_*` — what these actually do

These create a **temporary** admin account, and only on the *very first* startup against an empty database. After that they're ignored.

**Best practice:** log in, create a real named admin user with a strong password, then delete the bootstrap account. Keycloak's own documentation says the bootstrap admin is for initial setup only.

---

## Section 6 — The EC2 instance

```hcl
resource "aws_instance" "keycloak" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type

  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.keycloak.name

  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  user_data                   = local.user_data
  user_data_replace_on_change = true
```

### The conditional expression

```hcl
key_name = var.ssh_key_name != "" ? var.ssh_key_name : null
```

This is a **ternary**: `condition ? value_if_true : value_if_false`.

Read it as: *"If `ssh_key_name` is not empty, use it. Otherwise, use nothing."*

Setting an argument to `null` is Terraform's way of saying "pretend I didn't write this line." You can't pass an empty string to `key_name` — AWS rejects it — so this pattern makes the argument genuinely optional.

### ⭐ `user_data_replace_on_change = true`

**This is the most consequential single line in the file.**

`user_data` only runs on the *first* boot. So if you edit the bootstrap script, an existing instance will never see the change.

| Setting | What happens when you edit the script |
|---|---|
| `false` (default) | Terraform updates the stored `user_data` attribute. The running server keeps its old config forever. You are now confused. |
| `true` ✅ | **Terraform destroys the instance and creates a new one**, which boots and runs the new script |

| | Pro | Con |
|---|---|---|
| `true` | Your code and your server always match | Every script edit = a few minutes of downtime and a fresh disk |
| `false` | No surprise replacements | Silent drift between code and reality |

For a single-node lab, `true` is correct and honest. For production, you'd move to an Auto Scaling Group with a launch template and rolling replacement — same idea, no downtime.

**Because the disk is wiped on replacement, nothing important may live on it.** That's exactly why the database is a separate RDS instance and the passwords are in Secrets Manager. This architecture makes the server *disposable*, which is the goal. The industry term is **cattle, not pets**.

### The root volume

```hcl
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }
```

| Setting | Why |
|---|---|
| `gp3` | 3000 IOPS baseline, cheaper than gp2 |
| `encrypted = true` | Encryption at rest, free, zero performance cost |
| `delete_on_termination = true` | Don't leave orphan disks quietly billing you |

Orphaned EBS volumes are one of the most common sources of mystery AWS charges. `true` is the right default here.

### ⭐ IMDSv2 — a genuinely important security block

```hcl
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
```

Remember `169.254.169.254`, the metadata service that hands out the instance's temporary IAM credentials?

**The attack (IMDSv1):** an app on your server has an SSRF bug — it fetches any URL a user supplies. An attacker asks it to fetch `http://169.254.169.254/latest/meta-data/iam/security-credentials/`. The server obediently fetches it and returns your AWS credentials to the attacker. This is exactly how the 2019 Capital One breach happened: 100 million records.

**The defence (IMDSv2):**

| Setting | What it does |
|---|---|
| `http_tokens = "required"` | You must first `PUT` to get a session token, then include it in the GET. **SSRF bugs can only make GET requests**, so the attack breaks. |
| `http_put_response_hop_limit = 1` | The token response can only travel 1 network hop, so it can't escape to a container or another host |
| `instance_metadata_tags = "enabled"` | Lets the instance read its own tags — handy for scripts |

> **⚠️ Watch out with Docker:** a hop limit of `1` means processes *inside a Docker container* on the bridge network cannot reach IMDS, because Docker's NAT adds a hop. It works here because the AWS CLI calls all happen on the host during bootstrap. But if you later switch Keycloak to **RDS IAM authentication** (see [06](06-make-it-configurable.md)), Keycloak-in-a-container will need IMDS and you must raise this to `2`. Raising it slightly weakens the protection — a real trade-off to make consciously.

### Monitoring and dependencies

```hcl
  monitoring = false

  depends_on = [
    aws_db_instance.keycloak,
    aws_secretsmanager_secret_version.db,
    aws_secretsmanager_secret_version.keycloak_admin,
  ]
```

`monitoring = false` = basic CloudWatch (5-minute samples, free). `true` = detailed monitoring (1-minute samples, ~$2.10/month per instance).

**The `depends_on` is essential and Terraform could not have figured it out.** The instance's *code* doesn't reference the database — the *bootstrap script* does, at runtime, inside a string. Terraform can't read intent inside a Bash script. Without this block, Terraform would happily launch the EC2 in parallel with the database, and the script would fail at step 3 trying to read a secret that doesn't exist yet.

> **Rule of thumb:** you need `depends_on` whenever the real dependency happens at *runtime* rather than through a *reference*. If you can write `aws_thing.x.id`, use the reference — it's self-documenting. If you can't, use `depends_on`.

---

## Section 7 — Outputs

```hcl
output "keycloak_url"           { value = "https://${aws_eip.keycloak.public_ip}:8443" }
output "keycloak_admin_console" { value = "https://${aws_eip.keycloak.public_ip}:8443/admin" }
output "keycloak_public_ip"     { value = aws_eip.keycloak.public_ip }
output "keycloak_instance_id"   { value = aws_instance.keycloak.id }
```

### The clever ones

```hcl
output "get_admin_password_command" {
  value = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.keycloak_admin.name} --query SecretString --output text | jq ."
}

output "ssm_shell_command" {
  value = "aws ssm start-session --target ${aws_instance.keycloak.id}"
}
```

These output **ready-to-paste commands** with the IDs already filled in. It's a small touch that makes the project pleasant to use — no hunting for instance IDs in the console.

```hcl
output "allowed_source_ip" {
  value = var.my_ip_cidr
}
```

Echoing back the whitelist is smart. When Keycloak stops working three weeks later, this immediately reminds you what IP is allowed — and your ISP probably gave you a new one.

---

## The complete boot timeline

```
T+0:00  terraform apply finishes creating the EC2
T+0:10  AWS starts the virtual machine
T+0:40  Amazon Linux 2023 finishes booting
T+0:45  cloud-init begins running user_data
T+0:50  [1/8] dnf update + install docker, jq, awscli, openssl   (~90s)
T+2:20  [2/8] mkdir                                              (instant)
T+2:21  [3/8] read 2 secrets via the IAM role                    (~3s)
T+2:24  [4/8] download the RDS CA bundle                         (~2s)
T+2:26  [5/8] generate the self-signed certificate               (~1s)
T+2:27  [6/8] write keycloak.conf                                (instant)
T+2:28  [7/8] docker pull + kc.sh build                          (~150s)
T+5:00  [8/8] write the systemd unit, enable, start
T+5:05  container starts, Keycloak connects to Postgres
T+5:10  Keycloak runs its database migrations (first boot only)  (~40s)
T+5:50  "Keycloak 26.7.0 started in 22.1s"
T+5:51  https://<EIP>:8443/admin is live
```

**Total: about 6 minutes after `terraform apply` says "complete".** If it's been 10 minutes and nothing works, go read `/var/log/keycloak-bootstrap.log` via SSM — the failing step will be obvious because of `set -x`.

---

## Quick reference: what this file created

| Resource | Cost/month |
|---|---|
| `random_password` (admin) | free |
| Secrets Manager secret + version | ~$0.40 |
| Elastic IP (attached) | free |
| **EC2 `t4g.small`** | ~$12.10 |
| 20 GB gp3 root volume | ~$1.60 |
| **Total** | **≈ $14.10** |

[← Previous: the database](02-database-line-by-line.md) | [Next: verify & destroy →](04-verify-and-destroy.md)
