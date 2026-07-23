# Keycloak on AWS: A Complete Beginner's Tutorial

**Build a real login server on Amazon Web Services, locked so only YOUR computer can reach it.**

Version of this guide: July 2026
Keycloak version: **26.7.0** (the current supported release)
PostgreSQL version: **18.3** (the newest available on Amazon RDS)

---

## Table of Contents

1. [What Are We Building?](#1-what-are-we-building)
2. [Background: What Is Keycloak and Why Should You Care?](#2-background-what-is-keycloak-and-why-should-you-care)
3. [Background: The AWS Pieces Explained](#3-background-the-aws-pieces-explained)
4. [Before You Start: The Checklist](#4-before-you-start-the-checklist)
5. [**THE ONE EXAMPLE**: Build It Start to Finish](#5-the-one-example-build-it-start-to-finish)
6. [What Just Happened? Every File Explained](#6-what-just-happened-every-file-explained)
7. [The AWS CLI Version (The Long Way)](#7-the-aws-cli-version-the-long-way)
8. [Tearing It All Down](#8-tearing-it-all-down)
9. [What Does This Cost?](#9-what-does-this-cost)
10. [Security Best Practices](#10-security-best-practices)
11. [Pros and Cons of Every Choice We Made](#11-pros-and-cons-of-every-choice-we-made)
12. [Troubleshooting](#12-troubleshooting)
13. [Where to Go Next](#13-where-to-go-next)
14. [Glossary](#14-glossary)

---

## 1. What Are We Building?

Imagine you're building a website. You need a login page. You need "forgot my
password" emails. You need "Sign in with Google." You need to make sure only
teachers can see the grade book and only students can see their own grades.

Writing all that yourself takes months, and if you get one part wrong, someone
steals everybody's passwords.

**Keycloak** is free software that does all of it for you. It's the login desk
of your application. You hand it the job of "who is this person and what are
they allowed to do," and you go back to building the fun parts of your app.

In this tutorial, you will put Keycloak on Amazon's cloud. Here's the picture:

```
                        THE INTERNET
                             |
                             |   Only ONE IP address gets through:
                             |   68.32.112.68  (that's you)
                             |
                    +--------v---------+
                    |  Security Group  |   <-- a firewall
                    |  ports 8443, 22  |
                    +--------+---------+
                             |
    +------------------------|--------------------------------+
    |  YOUR PRIVATE NETWORK (VPC)   10.42.0.0/16               |
    |                        |                                 |
    |   PUBLIC ROOM          |                                 |
    |   10.42.1.0/24         |                                 |
    |   +--------------------v-----------------+               |
    |   |   EC2 Instance (t4g.small)           |               |
    |   |   Amazon Linux 2023 + Java 21        |               |
    |   |   Keycloak 26.7.0                    |               |
    |   |   Elastic IP: never changes          |               |
    |   +--------------------+-----------------+               |
    |                        |                                 |
    |                        | port 5432, TLS required         |
    |                        | (firewall allows this ONE path) |
    |                        |                                 |
    |   PRIVATE ROOMS        v                                 |
    |   10.42.11.0/24  +------------------+                    |
    |   10.42.12.0/24  |  RDS PostgreSQL  |                    |
    |                  |  version 18.3    |                    |
    |                  |  NO public IP    |                    |
    |                  |  NO internet     |                    |
    |                  +------------------+                    |
    +----------------------------------------------------------+

    Off to the side, not in the network:

    +------------------+          +------------------------+
    | Secrets Manager  |          |  IAM Role              |
    | - DB password    | <------- |  "read ONLY these two  |
    | - Admin password |          |   secrets, nothing     |
    +------------------+          |   else in the account" |
                                  +------------------------+
```

**The big idea:** the database is completely sealed off. It has no public
address and no route to the internet. The only thing in the entire world that
can talk to it is the Keycloak server sitting one room over. And the only
thing that can talk to Keycloak is your home computer.

That is called **defense in depth**: layers of protection, so that one mistake
does not become a disaster.

---

## 2. Background: What Is Keycloak and Why Should You Care?

### The problem Keycloak solves

Every app needs to answer two questions:

| Question | Fancy word | Example |
|---|---|---|
| Who are you? | **Authentication** | "This is Maria, she typed the right password" |
| What may you do? | **Authorization** | "Maria is a teacher, so she can edit grades" |

Doing this badly is the single most common way apps get hacked. Storing
passwords in plain text, forgetting to expire sessions, not rate-limiting login
attempts, missing two-factor auth — these are the boring mistakes that leak
millions of accounts.

### What you get for free

Keycloak, one install, gives you all of this:

- **Single Sign-On (SSO)** — log in once, use five different apps
- **Social login** — "Sign in with Google / GitHub / Facebook"
- **Two-factor authentication** — the six-digit code from your phone app
- **User self-service** — sign-up, password reset, profile editing
- **LDAP / Active Directory sync** — pull in your school or company directory
- **Roles and groups** — teacher, student, admin
- **Standard protocols** — OpenID Connect, OAuth 2.0, SAML 2.0

### A quick history

| Year | What happened |
|---|---|
| 2014 | Red Hat starts Keycloak as an open-source project |
| 2018 | Becomes the standard free choice for self-hosted identity |
| 2023 | Joins the Cloud Native Computing Foundation (CNCF) |
| 2024 | Version 26.0 arrives; the old WildFly engine is retired in favour of Quarkus, which starts far faster |
| 2026 | Version 26.7 is current, with SCIM user provisioning and simpler multi-cluster setups |

### The protocols in one paragraph each

**OpenID Connect (OIDC)** is the modern standard. When you click "Sign in with
Google," your app sends you to Google, Google checks who you are, and sends you
back holding a **JWT** — a digitally signed slip of paper that says "this is
Maria, she's a teacher, and this slip expires in five minutes." Your app checks
the signature and trusts it. This is what you'll use 90% of the time.

**OAuth 2.0** is about permission rather than identity. It's how you let a
photo-printing site read your Google Photos *without* handing over your Google
password. OIDC is actually built on top of OAuth 2.0.

**SAML 2.0** is the older XML-based version. It's clunkier, but universities,
governments and big enterprises run on it, so Keycloak speaks it too.

### Why not just pay someone?

| Option | Cost | Good | Bad |
|---|---|---|---|
| **Keycloak (this guide)** | ~$33/mo of servers | Free software, your data, unlimited users, runs anywhere | You patch it, you back it up, you fix it at 2am |
| **AWS Cognito** | Free to 10k users, then ~$0.0055/user | AWS handles everything | Locked to AWS, the admin UI is rough |
| **Auth0 / Okta** | Free to 25k, then ~$0.02+/user | Best-in-class polish | Gets very expensive fast; your users live in their database |
| **Build it yourself** | "Free" | Total control | You will get security wrong. Everyone does. Don't. |

**Rule of thumb:** under 5,000 users and you want zero maintenance, use a hosted
service. Over 50,000 users, or you have data-residency rules, or you just want
to learn how this works — self-host Keycloak.

---

## 3. Background: The AWS Pieces Explained

Let's use a building analogy the whole way through.

### VPC — your own building

A **Virtual Private Cloud** is your private slice of Amazon's data center. You
get your own address range (`10.42.0.0/16`, which is 65,536 addresses) that
nobody else can see or use.

> `10.42.0.0/16` is called **CIDR notation**. The `/16` means "the first 16
> bits are fixed." So every address starts `10.42.` and the last two numbers
> are yours to hand out. A `/24` gives you 256 addresses. A `/32` means exactly
> one — which is why your home IP is written `68.32.112.68/32`.

### Subnets — rooms inside the building

A **subnet** is a slice of the VPC, and each one lives in one **Availability
Zone** (a physical data center building). We create three:

| Subnet | Range | Zone | Who lives there | Has internet? |
|---|---|---|---|---|
| public-a | 10.42.1.0/24 | us-east-1a | Keycloak | Yes |
| private-a | 10.42.11.0/24 | us-east-1a | Database | **No** |
| private-b | 10.42.12.0/24 | us-east-1b | Database standby | **No** |

Why two private subnets when we only have one database? Because **RDS refuses
to launch otherwise.** Amazon insists you have room in a second building so it
can move the database there if the first building loses power. You don't have
to *use* it — but you have to *have* it.

### Internet Gateway — the front door

The **IGW** is the door to the street. Attach one to the VPC, then add a road
sign in the public subnet's route table saying "for anywhere outside, go to the
IGW." The private subnets get no such sign, which is exactly why the database
cannot reach the internet and the internet cannot reach it.

### Security Groups — the bouncer

A **security group** is a firewall wrapped around one specific resource. Two
things make them nicer than old-fashioned firewalls:

**They're stateful.** If you allow a request in, the reply automatically gets
back out. You never write "and also let the answer through" rules.

**They can point at each other.** This is the trick worth remembering. Our
database rule doesn't say "allow 10.42.1.55." It says:

> Allow port 5432 from anything wearing the *Keycloak security group*.

Now if the Keycloak server dies and a new one launches with a totally different
IP, the rule still works. If you add three more Keycloak servers behind a load
balancer, they all work. You never touch the firewall again. **This is the AWS
best practice** and it's what our code does.

### EC2 — a computer you rent

**Elastic Compute Cloud** is a virtual machine. Ours:

- **t4g.small** — 2 virtual CPUs, 2 GB of RAM
- **Graviton (ARM)** — Amazon's own chips. About 20% cheaper than Intel for
  the same work, and Java runs on them perfectly.
- **Amazon Linux 2023** — Amazon's own Linux, patched and free

The `t` family is **burstable**. It idles at a low CPU level and earns
"credits," then spends them when it gets busy. Perfect for a login server,
which is quiet most of the time and briefly busy at 8am when everyone signs in.

### RDS — a database somebody else babysits

**Relational Database Service** runs PostgreSQL for you. Amazon handles:

- Installing and patching it
- Nightly backups, kept for 7 days
- Point-in-time restore (rewind to any second in the last 7 days)
- Automatic failover to the standby (if you enable Multi-AZ)
- Encrypting the disk

You could run PostgreSQL yourself on an EC2 instance for maybe $10/month less.
Almost nobody should. The first time a disk fails at 3am you'll understand why.

### IAM — permission badges

**Identity and Access Management** decides who can do what. Two ideas:

- A **role** is a badge with permissions attached
- A **policy** is the list of what the badge unlocks

Our EC2 instance wears a badge that allows exactly two things:

1. Read the two specific secrets whose names start with `keycloak-demo/db-`
2. Talk to Systems Manager so you can get a shell without SSH

That's it. Not "read all secrets." Not `s3:*`. This is **least privilege**: give
the minimum needed, nothing more. If someone breaks into the server, the badge
they steal is nearly worthless.

### Secrets Manager — the safe

Passwords should never live in a file you can `cat`, in your shell history, or
in a Git repository. **Secrets Manager** keeps them encrypted, logs every read
in CloudTrail, and hands them out only to whoever holds the right IAM badge.

Our servers fetch the database password at boot time, use it, and never write
it anywhere you could accidentally commit.

### Elastic IP — a phone number that doesn't change

Stop and start an EC2 instance and it gets a brand new public IP. Your bookmark
breaks, your DNS breaks, your TLS certificate stops matching. An **Elastic IP**
is an address you reserve and keep.

**Money warning:** since February 2024 Amazon charges about **$3.60/month for
every public IPv4 address**, attached or not. An Elastic IP you forget to
release after deleting the server keeps costing that forever. The destroy
scripts release it first for exactly this reason.

---

## 4. Before You Start: The Checklist

### You need

- [ ] An AWS account ([sign up free](https://aws.amazon.com/free/))
- [ ] A credit card on that account (AWS requires one even for free tier)
- [ ] A terminal — Mac Terminal, Linux shell, or Windows WSL2/Git Bash
- [ ] About 30 minutes
- [ ] Willingness to spend roughly **$1 per day** while it's running

### Install the tools

**AWS CLI** — the command-line way to control AWS:

```bash
# macOS
brew install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Verify
aws --version     # want v2.x
```

**Terraform** — describe your infrastructure as code:

```bash
# macOS
brew install terraform

# Linux
wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Verify
terraform version   # want 1.9 or newer
```

**jq** — reads JSON in the shell:

```bash
brew install jq          # macOS
sudo apt install jq      # Debian/Ubuntu
sudo dnf install jq      # Fedora/Amazon Linux
```

### Connect the CLI to your account

Never use your root account for daily work. Make an IAM user:

1. AWS Console → IAM → Users → **Create user**
2. Name it `terraform-admin`
3. Attach the policy `AdministratorAccess`
   *(For learning this is fine. For a real job, narrow it down.)*
4. Open the user → Security credentials → **Create access key** → choose CLI
5. Copy both the key ID and the secret — the secret is shown **once**

```bash
aws configure
# AWS Access Key ID:     AKIA................
# AWS Secret Access Key: ....................................
# Default region name:   us-east-1
# Default output format: json
```

Test it:

```bash
aws sts get-caller-identity
```

You should see your account number. If you see an error, your keys are wrong.

### Confirm your IP address

This whole setup hinges on locking access to **your** IP:

```bash
curl -s https://checkip.amazonaws.com
```

If that prints something other than `68.32.112.68`, your address changed. Most
home internet uses **dynamic IPs** that rotate every few days. Just update
`my_ip_cidr` and re-apply — it takes about ten seconds.

### Turn on a billing alarm (do this now, seriously)

1. Console → **Billing** → **Budgets** → **Create budget**
2. Choose **Cost budget**, set it to **$50/month**
3. Add an email alert at 80%

This has saved more students from a $900 surprise than any other single step.

---

## 5. THE ONE EXAMPLE: Build It Start to Finish

Everything above was background. Here is the actual build, start to finish.

### Step 1 — Get the files

```bash
unzip keycloak-aws.zip
cd keycloak-aws
ls
```

```
README.md
terraform/
  01-network.tf
  02-database.tf
  03-keycloak.tf
  terraform.tfvars.example
scripts/
  01-create-network.sh
  02-create-database.sh
  03-create-keycloak.sh
  91-destroy-network.sh
  92-destroy-database.sh
  93-destroy-keycloak.sh
  00-destroy-all.sh
```

### Step 2 — Set your options

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` in any editor. The one line that must be right:

```hcl
my_ip_cidr = "68.32.112.68/32"
```

That is already filled in for you. If `curl -s https://checkip.amazonaws.com`
gave you something else, change it. **Keep the `/32`** — it means "exactly this
one address."

### Step 3 — Initialize Terraform

```bash
terraform init
```

This downloads the AWS plugin. Expect:

```
Terraform has been successfully initialized!
```

### Step 4 — Preview what will happen

```bash
terraform plan
```

Terraform prints a dry run — nothing is created yet. You'll see roughly
**30 resources** marked with a green `+`. Skim it. Look for:

```
+ resource "aws_db_instance" "keycloak" {
    + engine         = "postgres"
    + engine_version = "18.3"
    + publicly_accessible = false     <-- THE important one
  }
```

**Always run `plan` before `apply`.** In a real job, `plan` is what you paste
into a pull request so a teammate can catch the mistake before it's live.

### Step 5 — Build it

```bash
terraform apply
```

Type `yes` when prompted.

**This takes 10-15 minutes.** The database is the slow part. Get a snack.

You'll see lines like:

```
aws_vpc.main: Creating...
aws_vpc.main: Creation complete after 2s
aws_db_instance.keycloak: Still creating... [4m30s elapsed]
aws_instance.keycloak: Creation complete after 32s
```

### Step 6 — Read the outputs

When it finishes:

```
Apply complete! Resources: 31 added, 0 changed, 0 destroyed.

Outputs:

allowed_source_ip = "68.32.112.68/32"
db_endpoint = "keycloak-demo-db.abc123.us-east-1.rds.amazonaws.com"
get_admin_password_command = "aws secretsmanager get-secret-value --secret-id ..."
keycloak_admin_console = "https://54.211.98.4:8443/admin"
keycloak_public_ip = "54.211.98.4"
ssm_shell_command = "aws ssm start-session --target i-0abc123..."
```

Get them back any time with `terraform output`.

### Step 7 — Wait for Keycloak to finish booting

Terraform is done, but the server is still setting itself up: installing Java,
downloading Keycloak, creating ~90 database tables. **Give it 3-6 minutes.**

Watch it live:

```bash
aws ssm start-session --target $(terraform output -raw keycloak_instance_id) \
  --document-name AWS-StartInteractiveCommand \
  --parameters 'command="sudo tail -f /var/log/keycloak-bootstrap.log"'
```

Wait for `=== Bootstrap complete ===`. Press `Ctrl+C` to stop watching.

### Step 8 — Get your password

```bash
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw keycloak_admin_secret_name 2>/dev/null || echo "keycloak-demo/db-keycloak-admin") \
  --query SecretString --output text | jq .
```

Or simply run the command Terraform handed you:

```bash
terraform output -raw get_admin_password_command
```

You'll get:

```json
{
  "username": "kcadmin",
  "password": "Xy7#mK2$pQ9!wR4nL8&z"
}
```

### Step 9 — Log in

```bash
open $(terraform output -raw keycloak_admin_console)      # macOS
xdg-open $(terraform output -raw keycloak_admin_console)  # Linux
```

**Your browser will show a scary red warning.** That is expected and correct.
The certificate is self-signed — the server vouched for itself instead of a
trusted authority vouching for it. Click **Advanced** → **Proceed anyway**.

*(Section 10 explains how to get a real certificate.)*

Log in with `kcadmin` and the password from Step 8. You're in.

### Step 10 — Prove the lock works

This is the fun part. Ask a friend on different internet, or use your phone
with WiFi turned **off**, to open the same URL.

It will **hang and time out**. Not "access denied" — the packets never arrive
at all. The security group drops them silently before anything is listening.

That is your firewall doing its job.

### Step 11 — Make something real

Let's create a login for a fake app:

1. Top-left dropdown → **Create realm** → name it `myapp` → **Create**

   > A **realm** is a completely separate universe of users. The `master`
   > realm is for administering Keycloak itself. Never put real application
   > users in `master` — always make a new realm.

2. Left menu → **Clients** → **Create client**
   - Client ID: `my-web-app`
   - Click **Next**
   - Turn **Standard flow** ON
   - Click **Next**
   - Valid redirect URIs: `http://localhost:3000/*`
   - **Save**

3. Left menu → **Users** → **Add user**
   - Username: `student1`
   - Email verified: ON
   - **Create**
   - **Credentials** tab → **Set password** → pick one → Temporary: **OFF**

4. Test it. Open a private browser window and visit:

```
https://YOUR_IP:8443/realms/myapp/protocol/openid-connect/auth?client_id=my-web-app&redirect_uri=http://localhost:3000/&response_type=code&scope=openid
```

You'll get a real login page. Sign in as `student1`. It bounces you to
`localhost:3000` with `?code=abcd1234...` on the end. That code is what your
app would trade for a JWT.

**You just built a working identity provider.**

### Step 12 — Turn it off when you're done

```bash
cd terraform
terraform destroy
```

Type `yes`. About 10 minutes later, billing stops. See Section 8 for the backup
CLI method if this ever fails.

---

## 6. What Just Happened? Every File Explained

### `01-network.tf` — the land

Builds, in this order:

1. **VPC** with DNS enabled (RDS gives you a hostname, so DNS must work)
2. **Internet Gateway** attached to it
3. **Three subnets** — one public, two private in different zones
4. **Two route tables** — public gets an internet road sign, private gets none
5. **Two security groups** — Keycloak's (open to your IP) and the database's
   (open only to Keycloak's group)
6. **IAM role + policy + instance profile** — the least-privilege badge
7. **DB subnet group** — tells RDS which private rooms it may use

The line worth staring at:

```hcl
resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.keycloak.id   # <-- not an IP
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
```

`referenced_security_group_id` instead of `cidr_ipv4` is what makes this survive
server replacement.

**Cost: $0.00.** VPCs, subnets, security groups, route tables, internet
gateways and IAM are all free.

### `02-database.tf` — the filing cabinet

1. Generates a **32-character random password**
2. Creates a **parameter group** with `rds.force_ssl = 1`
3. Creates the **RDS instance**, PostgreSQL 18.3, encrypted, private
4. Stores the credentials in **Secrets Manager**

The safety settings, and what each one buys you:

| Setting | Value | Why |
|---|---|---|
| `publicly_accessible` | `false` | No internet endpoint exists. The single most important line. |
| `storage_encrypted` | `true` | Disk encrypted at rest. Free. Cannot be turned on later without a rebuild. |
| `rds.force_ssl` | `1` | Postgres *refuses* unencrypted connections |
| `backup_retention_period` | `7` | A week of nightly backups + point-in-time restore |
| `auto_minor_version_upgrade` | `true` | Security patches (18.3→18.4) apply themselves |

**`sslmode=verify-full`** in the connection string is worth explaining. There
are levels:

- `disable` — no encryption at all
- `require` — encrypted, but doesn't check who you're talking to
- `verify-ca` — checks the certificate is signed by someone you trust
- `verify-full` — also checks the hostname matches ✅ **we use this**

Only `verify-full` stops a man-in-the-middle attack. It needs the RDS
certificate bundle, which the bootstrap script downloads to
`/opt/keycloak/conf/rds-ca.pem`.

### `03-keycloak.tf` — the app

1. Looks up the **newest Amazon Linux 2023 ARM image** (never hard-code an AMI
   ID — they go stale in weeks and differ per region)
2. Generates the **admin password**, stores it in Secrets Manager
3. Reserves an **Elastic IP** *before* launching, because the bootstrap script
   needs to bake the address into Keycloak's config and TLS certificate
4. Writes a **user-data script** that runs as root on first boot
5. Launches the **EC2 instance**
6. **Attaches** the Elastic IP

The user-data script does eight things:

| Step | What | Why |
|---|---|---|
| 1 | Install Java 21 | Keycloak 26.x requires exactly this version |
| 2 | Create a `keycloak` user | If the app is compromised, the attacker isn't root |
| 3 | Download Keycloak 26.7.0 | Straight from GitHub releases |
| 4 | Fetch secrets | Uses the IAM role — no password in the script |
| 5 | Download the RDS CA bundle | Makes `verify-full` possible |
| 6 | Generate a TLS keystore | So HTTPS works at all |
| 7 | Write `keycloak.conf` | Mode `0600`, readable only by the service user |
| 8 | `kc.sh build` then start | Pre-compiles config; saves ~30s on every restart |

Two hardening choices in the instance itself:

```hcl
metadata_options {
  http_tokens = "required"        # forces IMDSv2
}
```

**IMDSv2 matters.** Every EC2 instance has a magic address, `169.254.169.254`,
that hands out the instance's temporary AWS credentials. In the old version
(IMDSv1), any plain HTTP GET returned them. So if an attacker tricked your web
app into fetching a URL of their choosing (an **SSRF** attack), they could make
it fetch that address and steal your credentials. IMDSv2 requires a PUT request
with a special header first — something SSRF tricks can't do. Always require it.

```hcl
root_block_device {
  encrypted = true
}
```

Free, and means a stolen disk snapshot is unreadable.

---

## 7. The AWS CLI Version (The Long Way)

The `scripts/` folder does the same job with raw AWS CLI commands. Why bother?

**Pros of the CLI scripts**

- You see every single API call — great for learning
- No extra tool to install
- Easy to drop into an existing shell pipeline
- Works when Terraform is broken or unavailable

**Cons**

- No **state file**, so nothing knows what already exists
- Re-running creates duplicates instead of updating
- You handle dependency order and waiting yourself
- No `plan` — no preview before you commit
- ~450 lines of shell versus ~40 lines of Terraform for the same thing

**Verdict:** learn with the scripts, work with Terraform.

### Running them

```bash
cd scripts
chmod +x *.sh

./01-create-network.sh     # ~1 minute
./02-create-database.sh    # ~10 minutes (RDS is slow)
./03-create-keycloak.sh    # ~2 minutes
```

Each script appends what it made to `keycloak-state.env`:

```bash
cat keycloak-state.env
```

```bash
export VPC_ID='vpc-0abc123'
export PUBLIC_SUBNET_ID='subnet-0def456'
export KEYCLOAK_SG_ID='sg-0ghi789'
export DB_ENDPOINT='keycloak-demo-db-a1b2c3.abc.us-east-1.rds.amazonaws.com'
export PUBLIC_IP='54.211.98.4'
...
```

That file is this project's hand-rolled version of a Terraform state file. It's
how the later scripts and the destroy scripts find things again.

Override any default with an environment variable:

```bash
AWS_DEFAULT_REGION=us-west-2 \
PROJECT=my-keycloak \
MY_IP_CIDR=203.0.113.5/32 \
INSTANCE_TYPE=t4g.medium \
  ./01-create-network.sh
```

### Terraform vs. CLI, side by side

Creating the VPC:

**Terraform** — declares the goal:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}
```

**CLI** — commands the steps:

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.42.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
```

Run the Terraform twice: nothing happens, because the goal is already met.
Run the CLI twice: you get two VPCs. That difference — **declarative** versus
**imperative** — is the whole reason Terraform exists.

---

## 8. Tearing It All Down

**The most important section in this document.** Forgetting to destroy is how
students end up with a $400 bill.

### The normal way

```bash
cd terraform
terraform destroy
```

Type `yes`. Takes about 10 minutes.

### The backup way

Sometimes `terraform destroy` fails — a corrupted state file, someone deleted
something by hand in the console, a dependency AWS won't release. That's what
the destroy scripts are for.

```bash
cd scripts
./00-destroy-all.sh          # runs all three in the right order
```

Or one layer at a time:

```bash
./93-destroy-keycloak.sh     # EC2 + Elastic IP
./92-destroy-database.sh     # RDS + parameter group
./91-destroy-network.sh      # VPC + IAM
```

Note the numbering: **93, 92, 91**. Backwards on purpose. You must destroy in
reverse order of creation, because things depend on the things underneath them.

### Why the order is strict

```
  You CANNOT delete...            until you first delete...
  ----------------------------------------------------------
  a VPC                           everything inside it
  a subnet                        every instance and ENI in it
  a security group                every group that references it
  an IAM role                     the instance profile holding it
  a DB parameter group            the database using it
```

The trickiest one is that our two security groups reference **each other**. AWS
refuses to delete either while the other points at it. The fix, which
`91-destroy-network.sh` does:

1. Strip **all rules** from **all** groups (breaks the circular reference)
2. *Then* delete the groups

Skip step 1 and you'll be stuck deleting them by hand in the console.

### Things people forget and then pay for

| Leftover | Cost if forgotten |
|---|---|
| Unattached Elastic IP | ~$3.60/month |
| RDS final snapshot | ~$0.095/GB/month |
| Old EBS volumes | ~$0.08/GB/month |
| CloudWatch log groups | ~$0.50/GB/month |

Verify you're clean:

```bash
# Any instances left?
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=keycloak-demo" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId'

# Any databases left?
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'

# Any idle IPs? (these are the sneaky ones)
aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AssociationId]' --output table

# Any snapshots?
aws rds describe-db-snapshots --snapshot-type manual \
  --query 'DBSnapshots[].DBSnapshotIdentifier'
```

All empty = you're done. Check Cost Explorer tomorrow to be sure; billing data
lags about 24 hours.

### If a delete refuses

```bash
# What's still holding the VPC hostage?
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Desc:Description,Status:Status}' \
  --output table
```

Usually it's an **ENI** (network card) from a just-terminated instance that
hasn't been released yet. Wait two minutes and try again. The scripts already
retry automatically.

---

## 9. What Does This Cost?

All figures are **us-east-1**, on-demand, July 2026. Other regions run 10-30%
higher.

### The setup in this guide

| What | Spec | Per month | Per day |
|---|---|---|---|
| EC2 instance | t4g.small, 730 hrs | $12.26 | $0.41 |
| EC2 root disk | 20 GB gp3 | $1.60 | $0.05 |
| Public IPv4 | 1 address | $3.60 | $0.12 |
| RDS instance | db.t4g.micro | $12.41 | $0.41 |
| RDS storage | 20 GB gp3 | $2.30 | $0.08 |
| RDS backups | 7 days, under 20 GB | **$0.00** | $0.00 |
| Secrets Manager | 2 secrets | $0.80 | $0.03 |
| Data transfer out | ~1 GB | $0.09 | $0.00 |
| VPC, subnets, SGs, IAM, IGW | — | **$0.00** | $0.00 |
| **TOTAL** | | **~$33.06** | **~$1.10** |

### Ways to spend less

| Change | Saves | Trade-off |
|---|---|---|
| Destroy it every night | ~$25/mo | 15 min to rebuild each morning |
| `t4g.micro` instead of `small` | $6.13/mo | 1 GB RAM. Java will be unhappy. |
| Drop backups to 1 day | ~$0 | Almost no savings; don't bother |
| 1-year Savings Plan | ~30% | Committed for a year |
| 3-year Reserved Instance | ~60% | Committed for three years |
| Spot instance for EC2 | ~70% | AWS can kill it with 2 min notice |
| **Free tier (new accounts)** | up to $30/mo | Only for 12 months, `t4g.micro` only |

**The single best move for a learning project:** run the destroy script every
evening. Rebuilding is one command and 15 minutes. A stack that runs 4 hours a
day instead of 24 costs about **$6/month**.

### Free tier, if your account is under 12 months old

- 750 hrs/month of `t4g.micro` EC2 — covers one instance all month
- 750 hrs/month of `db.t4g.micro` RDS — covers one database all month
- 20 GB of RDS storage
- 30 GB of EBS storage

Switch both to `micro` in `terraform.tfvars` and you'll pay roughly **$4/month**
(the IPv4 charge and Secrets Manager aren't covered).

### What production actually costs

If this were a real service with 10,000 users:

| What | Spec | Per month |
|---|---|---|
| 2× EC2 (high availability) | t4g.medium | $49.06 |
| Application Load Balancer | 1, with ACM cert | $16.43 |
| RDS Multi-AZ | db.t4g.small × 2 | $49.64 |
| RDS storage | 100 GB gp3 | $11.50 |
| Route 53 hosted zone | 1 | $0.50 |
| ACM certificate | public | **$0.00** |
| CloudWatch | logs + alarms | ~$10.00 |
| **TOTAL** | | **~$137/month** |

Compare: Auth0 for 10,000 monthly active users runs roughly **$1,500/month**.
Self-hosting saves a lot of money — and costs you engineering hours instead.

### Check what you're actually spending

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-07-01,End=2026-07-31 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table
```

---

## 10. Security Best Practices

### What this guide already does right

| Practice | How |
|---|---|
| **Least privilege** | IAM policy names two actions and one ARN pattern |
| **No public database** | `publicly_accessible = false`, private subnets, no internet route |
| **Encryption at rest** | Both the EBS volume and RDS storage |
| **Encryption in transit** | `rds.force_ssl=1` plus `sslmode=verify-full` |
| **No hardcoded secrets** | Everything generated and stored in Secrets Manager |
| **Network segmentation** | Public and private subnets, separated by route tables |
| **SG-to-SG rules** | Firewall references groups, not fragile IP addresses |
| **IMDSv2 required** | Blocks the classic SSRF credential-theft attack |
| **Non-root service user** | Keycloak runs as `keycloak`, not `root` |
| **Restricted file mode** | `keycloak.conf` is `0600` |
| **No SSH keys needed** | SSM Session Manager instead |
| **Automatic patching** | RDS minor versions apply themselves |

### What you MUST fix before real use

**1. Get a real TLS certificate.**

The self-signed cert is fine for a lab and unacceptable in production. Users
trained to click through certificate warnings are users who will click through
a real attack. Two options:

*Option A — Application Load Balancer + ACM (recommended)*

```
Browser --HTTPS--> ALB (free ACM cert) --HTTP--> EC2 :8080
```

ACM certificates cost nothing and renew themselves. The ALB is ~$16/month.

*Option B — Let's Encrypt with certbot*

Free, but you need a real DNS name and you must handle renewal yourself.

**2. Put it behind a load balancer.** One EC2 instance means one reboot equals
downtime for everyone. Two instances behind an ALB, in different Availability
Zones, is the minimum for anything people depend on.

**3. Turn on Multi-AZ for the database.**

```hcl
db_multi_az = true
```

Doubles the database cost. Gives you automatic failover in about 60 seconds
when a data center has a bad day.

**4. Turn on deletion protection.**

```hcl
db_deletion_protection = true
```

Stops a tired 5pm `terraform destroy` from deleting production.

**5. Require MFA for admins.** In Keycloak: Authentication → Required Actions →
enable **Configure OTP**. Then Authentication → Flows → make OTP required in
the browser flow.

**6. Store Terraform state remotely.**

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "keycloak/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

Local state means: only you can run it, no history, and it's gone if your
laptop dies. **Also: state files contain secrets in plaintext.** Never, ever
commit one to Git.

**7. Set up monitoring.**

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name keycloak-cpu-high \
  --metric-name CPUUtilization --namespace AWS/EC2 \
  --statistic Average --period 300 --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2
```

Keycloak exposes health endpoints too: `/health/ready` and `/health/live`.

**8. Rotate secrets.** Secrets Manager can rotate RDS passwords automatically
on a schedule using a Lambda function. Set it to 30 days.

### The security checklist

```
Network
  [x] Database in private subnets, no internet route
  [x] Security groups reference groups, not IPs
  [x] Admin access limited to one IP
  [ ] VPC Flow Logs enabled              <-- add for production
  [ ] AWS WAF in front of the ALB        <-- add for production

Identity
  [x] IAM role scoped to two actions, one ARN
  [x] No long-lived access keys on the instance
  [x] IMDSv2 required
  [ ] MFA on all AWS console users       <-- do this today
  [ ] CloudTrail enabled                 <-- do this today

Data
  [x] Encrypted at rest (EBS + RDS)
  [x] Encrypted in transit (force_ssl + verify-full)
  [x] Secrets in Secrets Manager
  [x] 7 days of automated backups
  [ ] Backups tested by actually restoring one   <-- an untested backup
                                                     is not a backup
Application
  [x] Runs as a non-root user
  [x] Config file mode 0600
  [x] Automatic minor version patching
  [ ] Real TLS certificate               <-- required for production
  [ ] MFA required for Keycloak admins   <-- required for production
  [ ] Brute-force detection enabled      <-- Realm Settings > Security Defenses
```

---

## 11. Pros and Cons of Every Choice We Made

### EC2 vs. ECS Fargate vs. EKS

| | EC2 (what we did) | ECS Fargate | EKS (Kubernetes) |
|---|---|---|---|
| Cost | $12/mo | ~$18/mo | $73/mo control plane + nodes |
| Difficulty | Easy | Medium | Hard |
| You patch the OS | Yes | No | Sort of |
| Autoscaling | Manual | Built in | Excellent |
| Best for | Learning, small deployments | Production without a k8s team | Large orgs already on k8s |

We chose EC2 because you can SSH in, read the logs, and *see* what's happening.
That's the whole point of a tutorial.

### RDS vs. PostgreSQL on EC2 vs. Aurora Serverless

| | RDS (what we did) | Self-managed on EC2 | Aurora Serverless v2 |
|---|---|---|---|
| Cost | $12/mo | ~$8/mo | $43/mo minimum |
| Backups | Automatic | You write them | Automatic |
| Patching | Automatic | You do it | Automatic |
| Failover | One setting | You build it | Automatic |
| Scales to zero | No | No | Yes (v2 can idle at 0 ACU) |

RDS is the right answer for almost everyone. The $4/month you'd save
self-managing evaporates the first time you spend a Saturday on a failed disk.

### t4g (ARM) vs. t3 (Intel)

| | t4g Graviton | t3 Intel |
|---|---|---|
| Price | $12.26/mo | $15.18/mo |
| Performance | Often better for Java | Baseline |
| Software support | Excellent in 2026 | Universal |

ARM used to mean compatibility headaches. In 2026 it doesn't — Java, Node,
Python and Go all run natively. Take the 20% discount.

### Single AZ vs. Multi-AZ

| | Single AZ (what we did) | Multi-AZ |
|---|---|---|
| Cost | $12.41/mo | $24.82/mo |
| Downtime if AZ fails | Hours | ~60 seconds |
| Data loss | Restore from backup | None |

For a lab, single AZ. For anything with real users, Multi-AZ. The moment
someone would be upset if it were down, pay the money.

### Terraform vs. CloudFormation vs. CDK vs. Pulumi

| | Terraform | CloudFormation | CDK | Pulumi |
|---|---|---|---|---|
| Language | HCL | YAML/JSON | TypeScript/Python | TypeScript/Python/Go |
| Multi-cloud | Yes | AWS only | AWS only | Yes |
| Job market | Largest | AWS shops | Growing | Small |
| Learning curve | Medium | Medium | Steep if new to coding | Medium |

Terraform is the most portable and the most hireable. If you're all-in on AWS
and already write TypeScript, CDK is genuinely lovely.

### Self-signed vs. ACM vs. Let's Encrypt

| | Self-signed (what we did) | ACM + ALB | Let's Encrypt |
|---|---|---|---|
| Cost | Free | Free cert, $16/mo ALB | Free |
| Browser warning | **Yes** | No | No |
| Auto-renewal | N/A | Yes | You configure it |
| Needs a domain | No | Yes | Yes |

We used self-signed because it works with a bare IP and no domain purchase. For
anything real, use ACM.

---

## 12. Troubleshooting

### "Cannot reach the Keycloak URL"

Work through this in order:

```bash
# 1. Has your IP changed? (most common cause by far)
curl -s https://checkip.amazonaws.com
terraform output allowed_source_ip
# If they differ, update terraform.tfvars and run: terraform apply

# 2. Is the instance running?
aws ec2 describe-instances --instance-ids $(terraform output -raw keycloak_instance_id) \
  --query 'Reservations[0].Instances[0].State.Name'

# 3. Is Keycloak running on it?
aws ssm start-session --target $(terraform output -raw keycloak_instance_id) \
  --document-name AWS-StartInteractiveCommand \
  --parameters 'command="sudo systemctl status keycloak"'

# 4. Did the bootstrap finish?
aws ssm start-session --target $(terraform output -raw keycloak_instance_id) \
  --document-name AWS-StartInteractiveCommand \
  --parameters 'command="sudo tail -50 /var/log/keycloak-bootstrap.log"'
```

### "Keycloak won't start"

Get a shell and look:

```bash
aws ssm start-session --target $(terraform output -raw keycloak_instance_id)
sudo journalctl -u keycloak -n 100 --no-pager
```

| Error in the log | Cause | Fix |
|---|---|---|
| `Connection refused` to the DB | Security group or RDS not ready | Check the SG rule; wait for RDS |
| `password authentication failed` | Secret wasn't read correctly | Check the IAM role is attached |
| `Unable to find hostname` | `hostname=` not set | Already handled in our config |
| `Address already in use` | Something else on 8443 | `sudo ss -tlnp \| grep 8443` |
| `OutOfMemoryError` | Instance too small | Move to `t4g.medium` |

### "terraform apply fails"

| Message | Meaning | Fix |
|---|---|---|
| `InvalidParameterValue: engine version` | 18.3 retired in your region | `aws rds describe-db-engine-versions --engine postgres` and pick a listed version |
| `UnauthorizedOperation` | Your IAM user lacks permission | Attach `AdministratorAccess` while learning |
| `InvalidKeyPair.NotFound` | `ssh_key_name` names a key that doesn't exist | Set it to `""` and use SSM |
| `AddressLimitExceeded` | You have 5 Elastic IPs already | Release unused ones, or ask AWS to raise the limit |
| `DBSubnetGroupDoesNotCoverEnoughAZs` | Only one AZ given | Our code uses two; check your region has two |

### "terraform destroy fails"

```bash
# Try again — many failures are just timing
terraform destroy

# Still stuck? Use the CLI backup
cd ../scripts && ./00-destroy-all.sh

# Nuclear option: remove the item from state and delete it by hand
terraform state list
terraform state rm aws_instance.keycloak
# then delete it in the AWS console
```

### "The database is slow"

```bash
# Check CPU
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=keycloak-demo-db \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Average
```

On a `t4g.micro`, the usual cause is **exhausted CPU credits**. Burstable
instances earn credits while idle and spend them under load; run out and you're
throttled hard. Move up to `db.t4g.small` or switch to an `m7g` class.

Also check Performance Insights in the RDS console — it's on and free for 7
days of history.

### Useful log locations

```bash
/var/log/keycloak-bootstrap.log     # our setup script
/var/log/cloud-init-output.log      # everything user-data printed
/var/log/keycloak/keycloak.log      # Keycloak itself
sudo journalctl -u keycloak -f      # live systemd log
```

---

## 13. Where to Go Next

### Learn Keycloak properly

- Build a small app that logs in through it. Try the
  [keycloak-js](https://www.keycloak.org/securing-apps/javascript-adapter)
  adapter with a React page.
- Add **Sign in with GitHub**: Identity Providers → GitHub → paste a client ID
  and secret from a GitHub OAuth app.
- Turn on two-factor: Authentication → Required Actions → Configure OTP.
- Make custom roles and test them: create `teacher` and `student`, assign them,
  and look at how they appear inside the JWT.
- Theme the login page: copy `themes/keycloak` to `themes/mytheme` and edit it.

### Learn AWS properly

- Rebuild this with an **Application Load Balancer** and a real ACM certificate
- Move the EC2 instance into an **Auto Scaling Group** across two AZs
- Add **CloudWatch alarms** for CPU, memory and the Keycloak health endpoint
- Set up **VPC Flow Logs** and read them
- Try **AWS Backup** for scheduled, cross-region backup copies

### Learn Terraform properly

- Convert this into **modules** so you can call it once per environment
- Use **workspaces** for dev/staging/prod from the same code
- Move state to **S3 with DynamoDB locking**
- Run `terraform plan` automatically on pull requests in **GitHub Actions**
- Try `terraform import` to bring hand-built resources under management

### Good reading

- [Keycloak Server Guide](https://www.keycloak.org/guides) — dense but complete
- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/) — the six pillars every AWS design is judged against
- [Terraform Best Practices](https://www.terraform-best-practices.com/)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/) — the ten mistakes that cause most breaches

---

## 14. Glossary

**AMI** — Amazon Machine Image. A snapshot of an operating system used as the
starting template for a new server.

**ARN** — Amazon Resource Name. The full unique ID of any AWS thing, like
`arn:aws:s3:::my-bucket`. IAM policies use these to name exactly what a
permission applies to.

**Availability Zone (AZ)** — one physical data center within a region. Regions
have three or more. Spreading across AZs is how you survive one building
failing.

**CIDR** — the `10.0.0.0/16` way of writing a block of IP addresses. The number
after the slash says how many leading bits are fixed; bigger number means
smaller block.

**EBS** — Elastic Block Store. Virtual hard drives for EC2 instances.

**ENI** — Elastic Network Interface. A virtual network card. These sometimes
linger after an instance dies and block a VPC from being deleted.

**IAM** — Identity and Access Management. AWS's permission system.

**IdP** — Identity Provider. A service that vouches for who someone is.
Keycloak is one.

**IMDS** — Instance Metadata Service. The `169.254.169.254` address where an
EC2 instance learns about itself, including its temporary credentials. Always
require version 2.

**JWT** — JSON Web Token. A digitally signed slip of paper carrying claims like
"this is Maria, she's a teacher, expires in 5 minutes." Pronounced "jot."

**Least privilege** — the rule that every account gets the minimum permission
needed and nothing more.

**Multi-AZ** — running a copy of your database in a second Availability Zone,
so a failure fails over automatically.

**OIDC** — OpenID Connect. The modern login protocol, built on OAuth 2.0.

**Realm** — in Keycloak, a completely separate universe of users, roles and
clients. Two realms cannot see each other.

**Security Group** — a stateful firewall attached to a resource. Can reference
other security groups as sources.

**SSRF** — Server-Side Request Forgery. An attack where you trick a server into
fetching a URL you chose. IMDSv2 exists to defeat it.

**Subnet** — a slice of a VPC living in one Availability Zone.

**Terraform state** — the file recording what Terraform has built, so it knows
what to change next time. Contains secrets; never commit it.

**VPC** — Virtual Private Cloud. Your own isolated network inside AWS.

---

## Quick Reference Card

```bash
# ---------- BUILD ----------
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set my_ip_cidr
terraform init
terraform plan
terraform apply

# ---------- USE ----------
terraform output                               # all the URLs and IDs
terraform output -raw get_admin_password_command
aws ssm start-session --target $(terraform output -raw keycloak_instance_id)

# ---------- FIX ----------
curl -s https://checkip.amazonaws.com          # did my IP change?
terraform apply                                # re-apply after editing tfvars

# ---------- DESTROY ----------
terraform destroy                              # normal
cd ../scripts && ./00-destroy-all.sh           # backup, CLI-based

# ---------- VERIFY IT'S GONE ----------
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```

**Costs about $1.10/day. Destroy it when you're not using it.**

---

*Written July 2026. Keycloak 26.7.0, PostgreSQL 18.3, Terraform 1.9+, AWS CLI v2.*
