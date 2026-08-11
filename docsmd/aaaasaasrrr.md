# Deploying Keycloak on AWS with Terraform
### A complete, beginner-friendly guide

---

## Table of Contents

1. [What Are We Building?](#1-what-are-we-building)
2. [Background: The Words You Need to Know](#2-background-the-words-you-need-to-know)
3. [Before You Start: The Checklist](#3-before-you-start-the-checklist)
4. [Step-by-Step: Your First Deployment](#4-step-by-step-your-first-deployment)
5. [Understanding Every File](#5-understanding-every-file)
6. [Best Practices](#6-best-practices)
7. [Design Choices: Pros and Cons](#7-design-choices-pros-and-cons)
8. [Troubleshooting](#8-troubleshooting)
9. [Day-2 Operations](#9-day-2-operations)
10. [Glossary](#10-glossary)

---

## 1. What Are We Building?

Imagine your company has ten different apps: an HR portal, a wiki, a
dashboard, a ticketing system, and so on. Without a central login system,
every one of those apps needs its own username and password. That is ten
passwords for every employee, ten places for a hacker to attack, and ten
lists to update when someone leaves the company.

**Keycloak** solves this. It is a single "front desk" for logins. Every app
asks Keycloak "is this person allowed in?" instead of checking passwords
itself. This is called **Single Sign-On** (SSO) — log in once, get into
everything.

Keycloak needs somewhere to store its data: the list of users, which apps
exist, who belongs to which group. That storage is a **PostgreSQL database**.

So our architecture is two pieces:

```
                    Internet
                       |
                       v
        ┌──────────────────────────────┐
        │   Load Balancer (EXISTS)     │  <- handles HTTPS, you already have it
        │   listens on port 443        │
        └──────────────┬───────────────┘
                       │ plain HTTP, port 8080
                       │ (safe: inside your private network)
                       v
        ┌──────────────────────────────┐
        │   EC2 Instance               │  <- WE CREATE THIS
        │   running Keycloak           │
        │   (a virtual computer)       │
        └──────────────┬───────────────┘
                       │ PostgreSQL protocol, port 5432
                       v
        ┌──────────────────────────────┐
        │   RDS PostgreSQL             │  <- WE CREATE THIS
        │   (the database)             │
        └──────────────────────────────┘
```

**We create only the two boxes marked "WE CREATE THIS."** Everything else —
the network, the firewalls, the load balancer, the permission roles — already
exists in your AWS account, and we simply point at it by ID.

Why does that matter? Because in most real companies, a networking team owns
the VPC and a security team owns the firewall rules. If your Terraform tried
to create those, it would either fail (no permission) or, worse, succeed and
overwrite someone else's work. Consuming existing resources is the normal,
professional pattern.

---

## 2. Background: The Words You Need to Know

Read this section once. You do not need to memorize it — come back when a
term confuses you.

### Terraform

Terraform is **infrastructure as code**. Instead of clicking around the AWS
website to create servers, you write a text file describing what you want,
and Terraform builds it.

Think of it like a recipe versus cooking from memory. If you cook from
memory, you might forget the salt on Tuesday. If you follow a written recipe,
Tuesday's dinner is identical to Monday's. Terraform files are the recipe for
your infrastructure.

The magic word is **declarative**. You do not write "create a server, then
create a database, then connect them." You write "I want a server and a
database that are connected," and Terraform figures out the order.

**Terraform state** is a file (usually `terraform.tfstate`) where Terraform
records what it built. This is how it knows the difference between "create a
new database" and "change the existing database." Losing the state file is
genuinely bad — Terraform forgets everything it made and will try to build
duplicates.

### AWS Concepts

| Term | Plain-English meaning |
|---|---|
| **EC2** | A virtual computer you rent by the hour. |
| **RDS** | A managed database. AWS handles backups, patching, and failover for you. |
| **VPC** | Your own private network inside AWS, isolated from other customers. |
| **Subnet** | A slice of your VPC. *Public* subnets can reach the internet directly; *private* ones cannot. |
| **Availability Zone (AZ)** | A separate physical data center. Putting things in two AZs means one building can burn down and you stay online. |
| **Security Group** | A firewall attached to a resource. Says "port 8080 may be opened, but only from this other thing." |
| **IAM Role / Instance Profile** | A badge you give a server so it can call AWS services without you storing passwords on it. |
| **Load Balancer (ALB)** | Sits in front of servers, spreads traffic across them, and terminates HTTPS. |
| **Target Group** | The list of servers a load balancer sends traffic to. |
| **Secrets Manager** | An encrypted vault for passwords. Applications read from it at runtime. |
| **KMS** | The key service that encrypts your disks and secrets. |
| **SSM Session Manager** | Lets you open a terminal on a server through AWS, with no SSH keys and no open port 22. |

### Keycloak Concepts

| Term | Plain-English meaning |
|---|---|
| **Realm** | An isolated tenant. Users in realm A cannot see realm B. The built-in `master` realm is only for administering Keycloak itself. |
| **Client** | One application that trusts Keycloak for login. |
| **User** | A person. |
| **Role** | A label like `admin` or `viewer` that grants permissions. |
| **OIDC / OAuth 2.0 / SAML** | The standard languages apps use to ask Keycloak "who is this?" |

---

## 3. Before You Start: The Checklist

### Software on your laptop

```bash
# Check what you have. If any command is "not found", install it.
terraform version   # need 1.9 or newer
aws --version       # need AWS CLI v2
jq --version        # used to read JSON output
```

Install links:
- Terraform: https://developer.hashicorp.com/terraform/install
- AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

### AWS access

```bash
# Prove your credentials work and you're in the right account.
aws sts get-caller-identity
```

You should see your account number and user/role ARN. If you get an error,
run `aws configure` or set up SSO with `aws configure sso`.

### The pre-existing resources you must gather

This is the important part. Collect these seven values before writing
anything. Each command below prints what you need.

**1. VPC ID**
```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`].Value|[0]}' \
  --output table
```

**2 & 3. Subnet IDs** — one private subnet for the server, two (in different
AZs) for the database.
```bash
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=vpc-YOUR-VPC-ID \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch}' \
  --output table
```
Pick subnets where `Public` is `False`.

**4 & 5. Security Group IDs**
```bash
aws ec2 describe-security-groups \
  --filters Name=vpc-id,Values=vpc-YOUR-VPC-ID \
  --query 'SecurityGroups[].{ID:GroupId,Name:GroupName,Desc:Description}' \
  --output table
```

You need two groups, and their rules must be correct:

| Group | Required inbound rule | Required outbound rule |
|---|---|---|
| **App SG** (on EC2) | TCP 8080 **from the load balancer's SG** | TCP 5432 **to the DB SG**, plus 443 to the internet for downloads |
| **DB SG** (on RDS) | TCP 5432 **from the App SG** | none needed |

> **Critical:** the source of a rule should be *another security group's ID*,
> not a CIDR like `0.0.0.0/0`. This is called SG-referencing and it means the
> rule keeps working even when IP addresses change.

**6. Target Group ARN**
```bash
aws elbv2 describe-target-groups \
  --query 'TargetGroups[].{Name:TargetGroupName,ARN:TargetGroupArn,Port:Port,HealthPath:HealthCheckPath}' \
  --output table
```
The target group's health check path should be `/health/ready` on port 8080.
Fix it if not:
```bash
aws elbv2 modify-target-group \
  --target-group-arn arn:aws:...:targetgroup/... \
  --health-check-path /health/ready \
  --health-check-port 8080 \
  --matcher HttpCode=200
```

**7. IAM Instance Profile name**
```bash
aws iam list-instance-profiles \
  --query 'InstanceProfiles[].InstanceProfileName' --output table
```

The role inside it needs two things:
- The AWS-managed policy `AmazonSSMManagedInstanceCore` (so you can get a
  shell without SSH).
- An inline policy allowing `secretsmanager:GetSecretValue` on the Keycloak
  secret.

If you need to add the second one, here is the policy JSON. Note the
wildcard suffix — Secrets Manager appends six random characters to every
secret ARN.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:us-east-1:ACCOUNT-ID:secret:keycloak-prod-db-credentials-*"
    }
  ]
}
```

Attach it:
```bash
aws iam put-role-policy \
  --role-name YOUR-ROLE-NAME \
  --policy-name KeycloakSecretRead \
  --policy-document file://secret-policy.json
```

---

## 4. Step-by-Step: Your First Deployment

We will deploy the **development** environment first. It is cheap, it has no
deletion protection, and you can throw it away when you are done learning.

### Step 1 — Put the files in a folder

```bash
mkdir -p ~/keycloak-infra && cd ~/keycloak-infra
# copy main.tf, variables.tf, outputs.tf, user_data.sh.tftpl,
# and the two .tfvars.example files here
ls -1
```

You should see:
```
dev.tfvars.example
main.tf
outputs.tf
terraform.tfvars.example
user_data.sh.tftpl
variables.tf
```

### Step 2 — Protect yourself from committing secrets

```bash
cat > .gitignore <<'EOF'
*.tfvars
!*.tfvars.example
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl.bak
crash.log
EOF
```

Then start tracking the folder:
```bash
git init && git add . && git commit -m "Initial Keycloak infrastructure"
```

### Step 3 — Fill in your real values

```bash
cp dev.tfvars.example dev.tfvars
```

Open `dev.tfvars` in your editor and replace every `<REPLACE-ME>` with the
IDs you gathered in section 3. A filled-in example:

```hcl
aws_region  = "us-east-1"
name_prefix = "keycloak-dev"

vpc_id             = "vpc-0a1b2c3d4e5f67890"
instance_subnet_id = "subnet-0aaa111bbb222ccc3"

db_subnet_ids = [
  "subnet-0aaa111bbb222ccc3",   # us-east-1a
  "subnet-0ddd444eee555fff6",   # us-east-1b  <- MUST be a different AZ
]

instance_security_group_ids = ["sg-0app111222333444"]
db_security_group_ids       = ["sg-0db0555666777888"]
target_group_arn            = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/keycloak-dev-tg/abc123def456"

iam_instance_profile_name = "keycloak-instance-profile"
keycloak_hostname         = "auth-dev.example.com"
```

Verify no placeholders remain:
```bash
grep -n "REPLACE-ME\|<YOUR\|<ACCOUNT" dev.tfvars
# Should print nothing.
```

### Step 4 — Initialize Terraform

```bash
terraform init
```

This downloads the AWS provider (a plugin, about 600 MB) into a hidden
`.terraform/` folder and creates `.terraform.lock.hcl`, which pins exact
provider versions so your teammates get identical behavior.

Expected output ends with:
```
Terraform has been successfully initialized!
```

**Commit the lock file.** It is not a secret, and it is what guarantees
reproducibility.

### Step 5 — Check the syntax

```bash
terraform fmt      # auto-formats the files to standard style
terraform validate # checks for syntax and type errors
```

`validate` should say `Success! The configuration is valid.` It does **not**
talk to AWS — it only checks the code itself.

### Step 6 — Preview what will happen

```bash
terraform plan -var-file=dev.tfvars -out=dev.tfplan
```

This is the most important command in Terraform. It calls AWS to read
current reality, compares it to your files, and prints the difference —
**without changing anything.**

Read the output carefully. You are looking for:

```
Plan: 6 to add, 0 to change, 0 to destroy.
```

The six resources are:
1. `random_password.keycloak_db`
2. `aws_secretsmanager_secret.keycloak_db`
3. `aws_secretsmanager_secret_version.keycloak_db`
4. `aws_db_subnet_group.keycloak`
5. `aws_db_instance.keycloak`
6. `aws_instance.keycloak`

(Plus `aws_lb_target_group_attachment.keycloak` if you set a target group.)

> **Rule to live by:** if a plan says `destroy` and you did not ask for a
> destroy, stop and investigate. Something is wrong.

### Step 7 — Apply

```bash
terraform apply dev.tfplan
```

Because we saved the plan to a file, Terraform applies exactly that plan with
no second confirmation prompt. This eliminates the risk that reality changed
between plan and apply.

**This takes 10–15 minutes.** RDS is the slow part — AWS is provisioning
storage, installing PostgreSQL, and taking an initial snapshot. Go get coffee.

Success looks like:
```
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

Outputs:

db_endpoint = "keycloak-dev-db.abc123.us-east-1.rds.amazonaws.com:5432"
instance_id = "i-0123456789abcdef0"
keycloak_url = "https://auth-dev.example.com"
...
```

### Step 8 — Watch the server finish booting

The EC2 instance exists, but Keycloak takes another 3–5 minutes to download,
build, and start. Connect and watch:

```bash
# Open a shell — no SSH key, no bastion, no open port 22.
aws ssm start-session --target $(terraform output -raw instance_id)
```

Once inside:
```bash
sudo tail -f /var/log/cloud-init-output.log
```

You are waiting for `Keycloak bootstrap complete`. Then check the service:

```bash
sudo systemctl status keycloak
# Active: active (running)   <- what you want

curl -s localhost:8080/health/ready
# {"status": "UP", "checks": []}
```

### Step 9 — Confirm the load balancer sees it

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$(grep target_group_arn dev.tfvars | cut -d'"' -f2)" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

You want `State: healthy`. If it says `unhealthy`, jump to
[Troubleshooting](#8-troubleshooting).

### Step 10 — Log in and secure the admin account

Get your temporary password:
```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo cat /root/keycloak-bootstrap-password.txt
```

Open `https://auth-dev.example.com/admin` in a browser and sign in with
username `admin` and that password.

**Now do these three things immediately:**

1. **Create a real admin user.** Go to the `master` realm → Users → Add user.
   Give it a strong password, then Role Mapping → assign `admin`.

2. **Delete the bootstrap admin.** Log out, log back in as your new user,
   delete the `admin` account.

3. **Remove the bootstrap file** so it cannot recreate the temp account:
   ```bash
   aws ssm start-session --target $(terraform output -raw instance_id)
   sudo rm /etc/keycloak/bootstrap.env /root/keycloak-bootstrap-password.txt
   sudo systemctl restart keycloak
   ```

### Step 11 — Create a working realm

Never put real users in the `master` realm. It exists only to administer
Keycloak.

In the admin console: click the realm dropdown (top-left) → **Create realm** →
name it something like `company` → Create.

Inside your new realm:
- **Realm settings → Login**: turn on "Forgot password" and "Remember me";
  turn OFF "User registration" unless you truly want open self-signup.
- **Authentication → Policies → OTP Policy**: consider requiring two-factor
  authentication.
- **Clients → Create client**: one per application. Choose OpenID Connect.
  Set valid redirect URIs to exact paths (`https://app.example.com/callback`),
  never `*`.

### Step 12 — Tear it down (dev only)

```bash
terraform destroy -var-file=dev.tfvars
```

Type `yes` when prompted. Takes about 8 minutes. Your VPC, security groups,
load balancer, and IAM role are untouched — Terraform only destroys what it
created.

---

## 5. Understanding Every File

### `main.tf` — the resources

**The `terraform` block** pins versions. `required_version = ">= 1.9.0"` stops
someone on Terraform 0.14 from corrupting your state. `version = "~> 6.0"` on
the AWS provider means "any 6.x, but never 7.0" — because major versions
introduce breaking changes.

**The `data "aws_ssm_parameter" "al2023"` block** is clever. AWS publishes the
current Amazon Linux 2023 AMI ID at a fixed SSM path. By reading it instead of
hard-coding `ami-0abc123`, you always get a patched image. The trade-off: your
plan output can change when AWS publishes a new AMI, which will show as an
instance replacement. In production, some teams pin a specific AMI and update
it deliberately.

**`random_password` + `aws_secretsmanager_secret`** together mean no human
ever sees or types the database password. Terraform generates it, stores it
encrypted, and the EC2 instance fetches it at boot using its IAM role.

> ⚠️ **Important caveat:** the generated password *is* stored in plaintext
> inside `terraform.tfstate`. This is a known Terraform limitation. It is why
> remote state in an encrypted S3 bucket with restricted access is not
> optional for production.

**`aws_db_subnet_group`** is RDS's way of asking "which subnets may I use?"
It requires at least two in different AZs even for a single-AZ database,
because AWS wants the option to fail over later.

**`aws_db_instance`** — a few lines deserve explanation:

- `max_allocated_storage` turns on **storage autoscaling**. If the disk fills
  past 90%, AWS grows it automatically. Without this, a full disk means an
  outage at 3 a.m.
- `publicly_accessible = false` — a Keycloak database should never be
  reachable from the internet. Not once, not for debugging.
- `skip_final_snapshot = false` means "take a snapshot before destroying."
  In production this is your last line of defence against a fat-fingered
  `terraform destroy`.
- The `lifecycle { ignore_changes = [password] }` block lets Secrets Manager
  rotate the password later without Terraform trying to change it back.

**`aws_instance`** — note `metadata_options { http_tokens = "required" }`.
This forces IMDSv2. The original IMDSv1 could be tricked by a server-side
request forgery bug into handing an attacker your instance's AWS credentials;
IMDSv2 requires a session token that SSRF cannot obtain. Always set this.

`user_data_replace_on_change = true` means editing the bootstrap script
replaces the whole instance rather than leaving a running server with stale
config. This is the **immutable infrastructure** pattern: servers are cattle,
not pets. You never patch them in place; you replace them.

### `variables.tf` — the inputs

Every variable has a `description`. This is not decoration — `terraform-docs`
generates documentation from these, and your future self will thank you.

Variables with **no default are required**. This is deliberate. There is no
sensible default for "which VPC," so Terraform should refuse to run without
one rather than guess.

The `validation` blocks catch mistakes early. The one on `db_subnet_ids`
rejects a single subnet with a clear message, instead of letting you wait
ten minutes for a cryptic AWS API error.

### `terraform.tfvars` — the values

Terraform automatically loads a file named exactly `terraform.tfvars`. We use
named files (`dev.tfvars`, `prod.tfvars`) with `-var-file=` instead, because
that makes it impossible to accidentally apply dev values to production.

**These files must never reach git.** They contain your account structure,
which is reconnaissance material for an attacker.

### `user_data.sh.tftpl` — the bootstrap script

`.tftpl` means "Terraform template." Terraform substitutes `${variable}`
placeholders before handing the script to AWS.

Note the doubled dollar signs: `$${KC_VERSION}` in the template becomes
`${KC_VERSION}` in the final script. The doubling escapes it so *Terraform*
ignores it and *bash* handles it.

`set -euxo pipefail` at the top makes the script fail loudly:
- `-e` exit on any error
- `-u` exit if an undefined variable is used
- `-x` print every command (this is what makes the log readable)
- `-o pipefail` catch failures in the middle of a pipeline

The `kc.sh build` step is a Keycloak-specific optimization. It pre-compiles
configuration into the distribution so that `kc.sh start --optimized` boots in
seconds instead of a minute, and so that a config typo fails at build time
rather than at 3 a.m.

---

## 6. Best Practices

### Security

**Never commit secrets.** Add `*.tfvars` and `*.tfstate` to `.gitignore`
before your first commit, not after. Run `git-secrets` or `gitleaks` in CI as
a backstop.

**Use Secrets Manager, not variables, for passwords.** If a password is a
Terraform variable, it ends up in your shell history, your CI logs, and your
state file. Generating it inside Terraform and storing it in Secrets Manager
limits exposure to just the state file.

**Encrypt your remote state and lock down access.** The state file contains
the database password in plaintext. Treat the S3 bucket like a password vault:
SSE-KMS encryption, bucket versioning on, public access blocked, and an IAM
policy allowing only the deployment role.

**Reference security groups, not CIDRs.** `source = sg-abc123` survives IP
changes; `source = 10.0.1.0/24` does not.

**Turn on IMDSv2.** Already done in `main.tf`, but check any other instances
you own.

**Prefer SSM Session Manager over SSH.** No key pairs to lose, no port 22 to
scan, and every session is logged to CloudTrail. That is why `key_pair_name`
defaults to `null` here.

**Rotate the database password.** Set up automatic rotation in Secrets
Manager on a 30–90 day schedule. Because Keycloak reads the secret at boot,
rotation requires an instance restart — plan for it, or move to a connection
pooler like RDS Proxy that handles rotation transparently.

### Reliability

**Use remote state with locking.** Local state on a laptop means one lost
laptop equals lost infrastructure knowledge, and two engineers applying at
once means corruption. Terraform 1.10+ supports native S3 locking with
`use_lockfile = true`, which replaced the old DynamoDB table requirement.

**Enable Multi-AZ in production.** It roughly doubles database cost but turns
an AZ failure from a multi-hour outage into a 60-second blip.

**Keep deletion protection on.** `db_deletion_protection = true` means a
`terraform destroy` in production fails safely instead of erasing your user
directory.

**Test your restores.** A backup you have never restored is a hypothesis, not
a backup. Restore a snapshot into a scratch environment once a quarter.

### Operations

**Always plan before apply, and always read the plan.** Save it with `-out`
and apply the saved file. This closes the window where reality changes between
the two commands.

**Separate state per environment.** Different state files (or different S3
keys) for dev, staging, and prod. A mistake in dev then cannot reach prod.

**Tag everything.** The `default_tags` block in the provider applies your tags
to every resource automatically. Without tags, your AWS bill is an
unattributable mystery.

**Pin your versions.** `~> 6.0` for providers, `>= 1.9.0` for Terraform, and
commit `.terraform.lock.hcl`. A surprise provider upgrade during an incident
is a bad day.

**Run security scanning in CI.** `tfsec`, `checkov`, or `trivy config` catch
unencrypted volumes and open security groups before they reach AWS:
```bash
trivy config .
```

### Keycloak specifically

**Never use the `master` realm for real users.** It is the admin realm.
Compromising a user there compromises everything.

**Set `hostname` and `hostname-strict=true`.** Without a fixed hostname,
Keycloak trusts the incoming `Host` header, which enables host-header
injection attacks against password-reset links.

**Set `proxy-headers=xforwarded`.** Without it, Keycloak thinks requests are
HTTP and generates broken redirect URLs. Note the older `proxy=edge` option
is deprecated — use `proxy-headers`.

**Use exact redirect URIs on clients.** A wildcard like
`https://app.example.com/*` lets an attacker who finds an open redirect steal
authorization codes.

**Set short access-token lifespans.** Five minutes is typical. Refresh tokens
carry the long-lived session; access tokens should expire fast because they
cannot be revoked once issued.

---

## 7. Design Choices: Pros and Cons

### EC2 versus ECS Fargate versus EKS

| | **EC2 (this guide)** | **ECS Fargate** | **EKS (Kubernetes)** |
|---|---|---|---|
| **Pros** | Simplest to understand. Full OS access for debugging. Cheapest at small scale. Easy to reason about. | No servers to patch. Scales automatically. Container image is your artifact. | Best autoscaling and clustering. Portable across clouds. |
| **Cons** | You own OS patching. Scaling is manual. One instance is a single point of failure. | Slower cold starts. Harder to debug — no shell by default. Container knowledge required. | Steep learning curve. ~$75/month for the control plane alone. Massive overkill for one app. |
| **Choose when** | You are learning, or you run one or two Keycloak nodes. | You already run containers and want zero server management. | You already run a Kubernetes platform. |

**Recommendation:** start with EC2 as shown here. Move to Fargate when you
outgrow it. Reach for EKS only if you already have a Kubernetes team.

### RDS versus Aurora versus self-hosted PostgreSQL

| | **RDS PostgreSQL (this guide)** | **Aurora PostgreSQL** | **PostgreSQL on EC2** |
|---|---|---|---|
| **Pros** | Predictable pricing. Simple mental model. Multi-AZ failover in ~60s. Plenty fast for Keycloak. | Failover in <30s. Up to 15 read replicas. Storage grows automatically to 128 TB. Serverless v2 scales to near-zero. | Total control. Cheapest raw compute. |
| **Cons** | Failover takes ~60s. Read replicas lag more. | Costs 20–30% more at the same instance size. Overkill for Keycloak's modest load. | *You* handle backups, patching, failover, and monitoring. |
| **Choose when** | Almost always, for Keycloak. | You need sub-30s failover or many read replicas. | Effectively never — the operational burden is not worth it. |

**Recommendation:** RDS PostgreSQL. Keycloak's database load is small — it is
mostly reads of user records. Aurora's strengths are wasted here.

### Single instance versus Auto Scaling Group

| | **Single instance (this guide)** | **ASG with 2+ nodes** |
|---|---|---|
| **Pros** | Simple. Cheap. No cluster configuration. | Survives instance failure. Rolling updates with zero downtime. Handles more load. |
| **Cons** | Instance failure means total outage until it reboots. Patching means downtime. | Requires cache clustering config (`--cache=ispn` and a JGroups discovery method). More moving parts. |
| **Choose when** | Dev, staging, or internal tools where 10 minutes of downtime is acceptable. | Production login for customer-facing apps. |

**Recommendation:** deploy the single instance first to learn the system.
Then convert to an ASG behind the same load balancer once you understand the
pieces. Multi-node Keycloak needs `KC_CACHE=ispn` with JDBC_PING discovery so
the nodes find each other through the database.

### Secrets Manager versus SSM Parameter Store

| | **Secrets Manager (this guide)** | **SSM Parameter Store (SecureString)** |
|---|---|---|
| **Pros** | Built-in automatic rotation. Cross-region replication. Native RDS integration. | Free for standard parameters. Simpler API. |
| **Cons** | $0.40/secret/month plus API call charges. | No built-in rotation — you write the Lambda yourself. |
| **Choose when** | Production credentials that need rotation. | Non-rotating config values, or tight budgets. |

**Recommendation:** Secrets Manager for the database password. Forty cents a
month is not the place to economize on credentials.

### Local state versus remote state

| | **Local** | **Remote (S3)** |
|---|---|---|
| **Pros** | Zero setup. Works offline. | Team-shareable. Locking prevents corruption. Versioned, so you can roll back. Encrypted at rest. |
| **Cons** | One laptop away from disaster. No locking. Secrets sit unencrypted on disk. | Requires bucket setup. Slight latency on every command. |
| **Choose when** | A five-minute experiment you will destroy. | Everything else. |

**Recommendation:** remote state for anything that outlives the afternoon.
Setup instructions are in the commented `backend` block in `main.tf`.

---

## 8. Troubleshooting

### `terraform init` fails: "Failed to query available provider packages"

Network or proxy problem. Check you can reach `registry.terraform.io`. Behind
a corporate proxy, set `HTTPS_PROXY`.

### `terraform plan` fails: "InvalidSubnetID.NotFound"

The subnet does not exist, or it is in a different region than `aws_region`.
Subnet IDs are region-specific. Verify:
```bash
aws ec2 describe-subnets --subnet-ids subnet-xxxxx --region us-east-1
```

### `terraform apply` fails: "DBSubnetGroupDoesNotCoverEnoughAZs"

Your two `db_subnet_ids` are in the same availability zone. Check:
```bash
aws ec2 describe-subnets --subnet-ids subnet-aaa subnet-bbb \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone}' --output table
```
The `AZ` column must show two different values.

### `terraform apply` fails: "InvalidParameterValue: The parameter MasterUsername is not a valid ..."

`db_username` is a reserved word. PostgreSQL on RDS forbids `postgres`,
`admin`, `rdsadmin`, and a few others. Use something like `kcadmin`.

### Apply succeeded but the target group says `unhealthy`

Work through these in order:

**1. Is Keycloak actually running?**
```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo systemctl status keycloak
sudo journalctl -u keycloak -n 100 --no-pager
```

**2. Does it respond locally?**
```bash
curl -v localhost:8080/health/ready
```
If this works but the ALB disagrees, the problem is the security group.

**3. Does the app SG allow 8080 from the ALB SG?**
```bash
aws ec2 describe-security-groups --group-ids sg-YOUR-APP-SG \
  --query 'SecurityGroups[].IpPermissions'
```
You need an entry with `FromPort: 8080` and a `UserIdGroupPairs` referencing
the load balancer's security group.

**4. Is the health check path right?**
```bash
aws elbv2 describe-target-groups --target-group-arns arn:... \
  --query 'TargetGroups[].{Path:HealthCheckPath,Port:HealthCheckPort}'
```
Should be `/health/ready` and `8080` (or `traffic-port`).

### Keycloak will not start: "Failed to obtain JDBC connection"

The instance cannot reach the database.

```bash
# From the instance:
DB=$(aws secretsmanager get-secret-value --secret-id ... --query SecretString --output text | jq -r .host)
timeout 5 bash -c "cat < /dev/null > /dev/tcp/$DB/5432" && echo OPEN || echo BLOCKED
```

If `BLOCKED`, the DB security group is not allowing 5432 from the app security
group. Fix:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-YOUR-DB-SG \
  --protocol tcp --port 5432 \
  --source-group sg-YOUR-APP-SG
```

### Cloud-init failed and I cannot tell why

```bash
sudo cat /var/log/cloud-init-output.log
```

Because the script uses `set -x`, the last command printed before the error is
the one that failed. Common causes: the instance has no route to the internet
(no NAT gateway) so the Keycloak download failed, or the IAM role lacks
`secretsmanager:GetSecretValue`.

Test the IAM permission directly:
```bash
aws secretsmanager get-secret-value --secret-id $(terraform output -raw db_secret_arn)
```
`AccessDeniedException` confirms the policy is missing.

### Login page loads but redirects go to `http://` instead of `https://`

`proxy-headers=xforwarded` is missing or the ALB is not sending
`X-Forwarded-Proto`. Verify the config file on the instance:
```bash
sudo grep -E "proxy|hostname" /etc/keycloak/keycloak.conf
```

### "We are sorry... invalid parameter: redirect_uri"

The redirect URI your app sent does not exactly match one registered on the
client. Check the client's **Valid redirect URIs** in the admin console.
Trailing slashes matter.

### `terraform destroy` fails on the database

Deletion protection is on. That is the feature working correctly. To really
delete it, set `db_deletion_protection = false` in your tfvars, run
`terraform apply` to update the setting, then destroy.

---

## 9. Day-2 Operations

### Upgrading Keycloak

1. Read the release notes and the [upgrade guide](https://www.keycloak.org/docs/latest/upgrading/).
2. Take a manual database snapshot:
   ```bash
   aws rds create-db-snapshot \
     --db-instance-identifier keycloak-prod-db \
     --db-snapshot-identifier keycloak-pre-upgrade-$(date +%Y%m%d)
   ```
3. Bump `keycloak_version` in your tfvars.
4. `terraform plan -var-file=prod.tfvars -out=upgrade.tfplan`
5. Confirm the plan replaces the instance (expected — `user_data` changed).
6. Apply. Keycloak runs its own database migrations on first start.

### Upgrading PostgreSQL

Major version upgrades cause downtime. Snapshot first, change
`db_engine_version`, then apply during a maintenance window with
`apply_immediately = true` temporarily.

### Backups

RDS automated backups run daily in your `db_backup_window` and are kept for
`db_backup_retention_days`. Also export realm configuration periodically, since
that is not something you want to reconstruct by hand:

```bash
sudo -u keycloak /opt/keycloak-dist/bin/kc.sh export \
  --dir /tmp/kc-export --users same_file
aws s3 cp /tmp/kc-export s3://your-backup-bucket/keycloak/$(date +%F)/ --recursive
```

### Monitoring

Watch these CloudWatch metrics:

| Metric | Alarm when |
|---|---|
| `AWS/RDS CPUUtilization` | > 80% for 15 min |
| `AWS/RDS FreeStorageSpace` | < 20% |
| `AWS/RDS DatabaseConnections` | approaching your `db-pool-max-size` × node count |
| `AWS/ApplicationELB UnHealthyHostCount` | > 0 |
| `AWS/EC2 StatusCheckFailed` | > 0 |

Keycloak also exposes Prometheus metrics at `/metrics` on port 8080 because we
set `metrics-enabled=true`.

### Scaling up

To grow the database, change `db_instance_class` and apply. AWS does this with
a brief failover — under a minute on Multi-AZ, several minutes on single-AZ.

To add Keycloak nodes, convert `aws_instance` into an
`aws_launch_template` + `aws_autoscaling_group`, and add these to
`keycloak.conf`:
```
cache=ispn
cache-stack=jdbc-ping
```
JDBC_PING lets the nodes discover each other through the shared database, which
avoids needing multicast in a VPC.

---

## 10. Glossary

**AMI** — Amazon Machine Image. The template a virtual machine boots from.

**ARN** — Amazon Resource Name. The globally unique ID of any AWS resource.

**Availability Zone** — a distinct physical data center within a region.

**Bootstrap admin** — the temporary Keycloak account created on first start of
an empty database. Delete it after creating a real admin.

**Client (Keycloak)** — an application registered with Keycloak.

**Declarative** — describing the desired end state rather than the steps.

**Drift** — when real infrastructure no longer matches your Terraform files,
usually because someone changed it by hand.

**Idempotent** — running it twice has the same effect as running it once.

**IMDSv2** — the hardened version of the EC2 metadata service. Requires a
session token, blocking SSRF-based credential theft.

**Immutable infrastructure** — replacing servers instead of modifying them.

**Multi-AZ** — running a standby database in a second data center for
automatic failover.

**OIDC** — OpenID Connect. The modern standard for "who is this user?"

**Realm (Keycloak)** — an isolated tenant with its own users and clients.

**SSO** — Single Sign-On. Log in once, access many applications.

**State (Terraform)** — the file recording what Terraform has built.

**Target group** — the list of backends a load balancer routes to.

**tfvars** — a file supplying values for Terraform variables.

**VPC** — Virtual Private Cloud. Your isolated network inside AWS.

---

## Further Reading

- Terraform AWS provider: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- Keycloak server configuration: https://www.keycloak.org/server/configuration
- Keycloak all-config reference: https://www.keycloak.org/server/all-config
- AWS RDS best practices: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html
- AWS Well-Architected Framework: https://aws.amazon.com/architecture/well-architected/
