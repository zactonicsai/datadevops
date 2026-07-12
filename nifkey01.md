# Apache NiFi + Keycloak on AWS: The Complete Step-by-Step Tutorial

**Goal:** Stand up Apache NiFi (a data-flow tool) on AWS, protected by Keycloak (a login/single-sign-on server), reachable from any web browser at a real domain name like `https://nifi.example.com` — and then automate the whole thing with Terraform, Ansible, and a pre-baked base image (AMI).

**Versions used (latest as of mid-2026):**

| Software | Version | Why this version |
|---|---|---|
| Apache NiFi | 2.10.0 | Latest 2.x release; the 1.x line ended at 1.28 |
| Keycloak | 26.6.x | Current supported major release |
| Java | OpenJDK 21 | Required by NiFi 2.x and Keycloak 26 |
| PostgreSQL (RDS) | 16 | Keycloak's database |
| OS | Ubuntu 24.04 LTS | Long-term-support Linux |
| Terraform | 1.9+ | Infrastructure as Code |
| Ansible | 2.17+ | Configuration management |
| Packer | 1.11+ | Base image (AMI) building |

---

## Table of Contents

1. [Background: What are all these things?](#1-background-what-are-all-these-things)
2. [The architecture we are building](#2-the-architecture-we-are-building)
3. [Part A — Step-by-step manual setup with the AWS CLI](#3-part-a--step-by-step-setup-with-the-aws-cli)
4. [Part B — Deep dive: every AWS service explained (what & why)](#4-part-b--deep-dive-every-aws-service-explained)
5. [Part C — Building a base image (AMI) with Packer](#5-part-c--building-a-base-image-ami-with-packer)
6. [Part D — Automating infrastructure with Terraform](#6-part-d--automating-infrastructure-with-terraform)
7. [Part E — Configuring servers with Ansible](#7-part-e--configuring-servers-with-ansible)
8. [Best practices checklist](#8-best-practices-checklist)
9. [Options, pros and cons](#9-options-pros-and-cons)
10. [Troubleshooting guide](#10-troubleshooting-guide)

---

# 1. Background: What are all these things?

Before touching any commands, let's make sure every word in the title makes sense. Think of this section as the "vocabulary lesson."

## 1.1 What is Apache NiFi?

Apache NiFi is like a **conveyor-belt factory for data**. Imagine a factory where boxes (data) arrive on trucks (files, APIs, message queues), get opened, sorted, relabeled, and shipped back out to different warehouses (databases, cloud storage, other systems). NiFi lets you build that factory **by dragging and dropping boxes and arrows in a web browser** — no heavy programming required.

Key NiFi ideas:

- **FlowFile** – one "box" of data moving through the system (the content plus labels called *attributes*).
- **Processor** – one machine on the conveyor belt that does a job (e.g., `GetFile` reads files, `PutS3Object` uploads to Amazon S3).
- **Connection / Queue** – the conveyor belt between machines; boxes wait here if the next machine is busy.
- **Process Group** – a whole section of the factory bundled into one box, so big flows stay tidy.
- **Provenance** – NiFi's "security camera footage": a complete history of what happened to every piece of data. Great for audits.

NiFi 2.x (what we use) is a big modernization over 1.x: it requires Java 21, removed hundreds of old components, is **secure (HTTPS) by default**, and added things like Python-based processors and much better performance.

## 1.2 What is Keycloak?

Keycloak is an **identity provider (IdP)** — a dedicated "front desk security guard" program. Instead of every application keeping its own list of usernames and passwords (dangerous and messy), all apps send visitors to Keycloak. Keycloak checks who they are, and hands them a **signed digital badge (a token)** that apps can trust.

Keycloak gives you, for free and open source:

- **Single Sign-On (SSO):** log in once, use many apps.
- **OpenID Connect (OIDC) and SAML:** the two standard "languages" for login. We will use **OIDC** because that is what NiFi speaks best.
- **User management:** self-registration, password policies, email verification.
- **Multi-factor authentication (MFA):** one-time codes, passkeys, etc.
- **Federation:** it can also connect to Active Directory/LDAP, Google, GitHub, etc., so you don't even have to store passwords yourself.

## 1.3 What is OpenID Connect (OIDC), in plain language?

OIDC is the standardized conversation between an app (NiFi) and an identity provider (Keycloak). The flow, called the **Authorization Code Flow**, works like a wristband system at a concert:

1. You walk up to NiFi. NiFi says: "I don't know you — go see the security desk (Keycloak)." Your browser is redirected to Keycloak's login page.
2. You show Keycloak your username + password (and maybe an MFA code). Keycloak never shows your password to NiFi. **This is the whole point** — only one system ever handles passwords.
3. Keycloak sends your browser back to NiFi with a one-time **authorization code** (a claim ticket).
4. NiFi, behind the scenes (server-to-server), trades the code plus its own **client secret** for an **ID token** — a cryptographically signed JSON document (a JWT) saying "this is alice@example.com, verified by Keycloak at 10:32."
5. NiFi verifies the token's signature against Keycloak's published public keys and lets you in as `alice@example.com`.

Words you will see in the configs later:

- **Realm** – a self-contained "universe" of users and apps inside Keycloak. We'll create one called `nifi-realm`.
- **Client** – an application registered with Keycloak (NiFi will be a client).
- **Client ID / Client Secret** – the app's own username/password for talking to Keycloak.
- **Redirect URI** – the exact address Keycloak is allowed to send users back to. This is a security allow-list — if it's wrong, login breaks (the most common setup error!).
- **Discovery URL** – a well-known address (`.../.well-known/openid-configuration`) where Keycloak publishes all its endpoints, so NiFi only needs one URL to configure everything.
- **Claims** – the fields inside the token (email, name, groups). NiFi uses one claim (usually `email`) as the user's identity.

## 1.4 Authentication vs. Authorization (two different questions)

- **Authentication (AuthN):** *Who are you?* → Handled by **Keycloak** via OIDC.
- **Authorization (AuthZ):** *What are you allowed to do?* → Handled by **NiFi's internal policies** (its `authorizers.xml` and the Policies UI). Keycloak proves you are `alice@example.com`; NiFi then decides whether Alice may view or edit flows.

Keeping these two ideas separate will make every config file below make sense.

## 1.5 What is AWS, and the "big three" building blocks we use?

Amazon Web Services (AWS) is a cloud provider: instead of buying physical servers, you rent virtual ones by the hour. The pieces we use:

- **EC2 (Elastic Compute Cloud):** virtual servers ("instances"). We run NiFi on one and Keycloak on another.
- **VPC (Virtual Private Cloud):** your own private, fenced-off section of Amazon's network — you choose the IP ranges, the subnets, and what can talk to what.
- **ALB (Application Load Balancer):** a smart traffic director that receives HTTPS from browsers and forwards it to your servers, based on the hostname requested.
- **Route 53:** AWS's DNS service — turns names like `nifi.example.com` into the ALB's address.
- **ACM (AWS Certificate Manager):** free, auto-renewing TLS certificates so the browser shows the padlock 🔒.
- **RDS (Relational Database Service):** managed databases. Keycloak needs PostgreSQL; RDS runs and backs it up for us.
- **IAM (Identity and Access Management):** permissions *inside AWS* (who/what may call which AWS APIs). Not to be confused with Keycloak, which handles *your application's* users.
- **Secrets Manager / SSM Parameter Store:** safes for passwords and secrets so they never sit in plain-text files.

## 1.6 Terraform, Ansible, Packer — and why we use all three

These three tools split the work exactly the way a construction project does:

| Tool | Analogy | Job | Language |
|---|---|---|---|
| **Packer** | Prefabricated wall panels | Bakes a reusable machine image (AMI) with Java, NiFi, Keycloak binaries pre-installed | JSON/HCL template |
| **Terraform** | The architect + crane | Creates the AWS *infrastructure*: VPC, subnets, EC2, ALB, DNS, certificates | HCL (`.tf` files) |
| **Ansible** | The finishing crew | Configures software *on* the servers: writes `nifi.properties`, creates the Keycloak realm, starts services | YAML playbooks |

**Why not just click around the AWS console?** Because clicking is not repeatable, not reviewable, and not recoverable. With code:

- You can rebuild the whole environment in minutes after a disaster.
- Every change is in Git — you can see who changed what and roll back.
- Dev, staging, and prod are guaranteed identical.
- New team members read the code instead of tribal knowledge.

This philosophy is called **Infrastructure as Code (IaC)** and it is *the* core modern best practice.

**Why a base image (AMI)?** Downloading and installing NiFi (a ~1.5 GB download) on every new server at boot time is slow (10+ minutes) and fragile (what if the download site is slow or your version disappears?). Instead we bake it **once** into a "golden image." New servers then boot in ~1 minute already containing everything, and every server is byte-for-byte identical. This is called **immutable infrastructure** — to upgrade, you bake a new image and replace servers rather than patching them in place.

---

# 2. The architecture we are building

```
                            INTERNET
                               │
                    (users' web browsers)
                               │
              https://nifi.example.com      https://auth.example.com
                               │                     │
                        ┌──────▼─────────────────────▼──────┐
        Route 53 DNS ──▶│   Application Load Balancer (ALB) │  TLS cert from ACM
                        │        (public subnets, x2 AZs)   │
                        └──────┬─────────────────────┬──────┘
                               │ HTTPS 8443          │ HTTP 8080
        ═══════════════════════╪═════════════════════╪═════════ VPC 10.0.0.0/16
                        ┌──────▼──────┐       ┌──────▼──────┐
                        │  NiFi EC2   │──OIDC▶│ Keycloak EC2│    (private subnets)
                        │ (t3.xlarge) │ token │ (t3.medium) │
                        └─────────────┘ calls └──────┬──────┘
                                                     │ 5432
                                              ┌──────▼──────┐
                                              │ RDS Postgres│    (private subnets)
                                              │ (Keycloak DB)│
                                              └─────────────┘
              NAT Gateway (public subnet) ◀── outbound internet for private servers
```

How a login actually flows through this picture:

1. Browser asks Route 53: "where is `nifi.example.com`?" → gets the ALB's IP.
2. Browser opens HTTPS to the ALB. The ALB presents the ACM certificate (padlock 🔒).
3. ALB forwards the request to the **NiFi instance** on port 8443.
4. NiFi sees no session → redirects the browser to `https://auth.example.com/realms/nifi-realm/...` — which is **the same ALB**, routed by hostname to the **Keycloak instance**.
5. User logs in at Keycloak; browser is redirected back to NiFi with a code.
6. NiFi calls Keycloak **directly inside the VPC** (server-to-server) to exchange the code for tokens.
7. NiFi verifies the token, creates a session, and shows the flow canvas. 🎉

Design decisions baked into this diagram (each explained fully in Part B):

- **Servers live in private subnets** — they have no public IP at all. Only the ALB is public. This dramatically shrinks the attack surface.
- **One ALB, two hostnames** — host-based routing sends `nifi.*` to NiFi and `auth.*` to Keycloak. One load balancer is cheaper than two.
- **Two Availability Zones (AZs)** — an ALB *requires* at least two; it also positions you for high availability later.
- **NAT Gateway** — lets the private servers download OS updates without being reachable from the internet.
- **RDS for Keycloak** — Keycloak's memory-only dev database loses everything on restart; production demands a real database.

---

# 3. Part A — Step-by-step setup with the AWS CLI

This is the "do it once by hand" walkthrough so you understand every moving part. Parts C–E then automate it. Every command includes *what it does* and *why*.

> **Convention:** we use region `us-east-1`, domain `example.com`, and shell variables (`VPC_ID`, etc.) that carry IDs from one step to the next. Run these in one terminal session. Replace `example.com` with a domain you actually own.

## Step 0 — Prerequisites

1. **An AWS account** with billing enabled.
2. **A registered domain.** You can buy one in Route 53 (Console → Route 53 → Registered domains) or use one from any registrar (GoDaddy, Namecheap…). If it's external, you'll point its nameservers at Route 53 in Step 4.
3. **AWS CLI v2 installed and configured:**

```bash
# Install (Linux)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials (creates ~/.aws/credentials)
aws configure
#   AWS Access Key ID:     <from IAM>
#   AWS Secret Access Key: <from IAM>
#   Default region name:   us-east-1
#   Default output format: json

# Sanity check — should print your account ID
aws sts get-caller-identity
```

> **Best practice:** never use the account *root* user's keys. Create an IAM user or (better) use IAM Identity Center / SSO with short-lived credentials. Root is for billing emergencies only.

```bash
# Variables used throughout
export AWS_REGION=us-east-1
export DOMAIN=example.com
export NIFI_HOST=nifi.$DOMAIN
export AUTH_HOST=auth.$DOMAIN
```

## Step 1 — Create the network (VPC, subnets, routing)

**What:** a VPC is your private slice of AWS's network. We carve it into 4 subnets across 2 Availability Zones: 2 **public** (for the ALB and NAT gateway) and 2 **private** (for NiFi, Keycloak, and the database).

**Why 4 subnets / 2 AZs:** an AZ is an independent data center; the ALB requires subnets in at least two AZs, and RDS requires a "subnet group" spanning two. Public vs. private separation means your servers are *physically unreachable* from the internet — the single most valuable security decision in this whole build.

```bash
# 1.1 The VPC itself — 10.0.0.0/16 gives us 65,536 private IP addresses
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=nifi-vpc}]' \
  --query 'Vpc.VpcId' --output text)

# Enable DNS support so instances get names & can resolve RDS endpoints
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# 1.2 Four subnets: /24 = 256 addresses each (plenty)
PUB_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-a}]' \
  --query 'Subnet.SubnetId' --output text)
PUB_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=public-b}]' \
  --query 'Subnet.SubnetId' --output text)
PRIV_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-a}]' \
  --query 'Subnet.SubnetId' --output text)
PRIV_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.12.0/24 \
  --availability-zone ${AWS_REGION}b \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=private-b}]' \
  --query 'Subnet.SubnetId' --output text)

# 1.3 Internet Gateway — the VPC's "front door" to the internet
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=nifi-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# 1.4 NAT Gateway — outbound-only internet for the PRIVATE subnets
#     (needs a static public "Elastic IP" and must live in a PUBLIC subnet)
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP_ALLOC \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID   # takes ~2 min

# 1.5 Route tables — the traffic rules
# Public route table: "anything not local (0.0.0.0/0) → Internet Gateway"
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_A
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_B

# Private route table: "anything not local → NAT Gateway" (outbound only)
PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=private-rt}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_A
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_B
```

**What just happened, in one sentence each:**
- *VPC* — a fenced network with the address range 10.0.0.0–10.0.255.255.
- *Subnets* — four rooms in the fence, two per data center (AZ).
- *Internet Gateway* — the door that lets public subnets talk to the internet both ways.
- *NAT Gateway* — a one-way valve: private servers can reach out (updates, downloads), the internet cannot reach in.
- *Route tables* — signs on each room's wall saying where non-local traffic goes.

## Step 2 — Security Groups (the firewalls)

**What:** a Security Group (SG) is a stateful firewall attached to a resource. "Stateful" means if a request is allowed in, the reply is automatically allowed back out.

**Why this design:** we chain SGs by *reference* instead of IP addresses: "NiFi accepts 8443 **only from the ALB's SG**." Even inside the VPC, nothing can talk to NiFi except the load balancer. This is **least privilege** networking and it survives IP changes because it follows identity, not addresses.

```bash
# 2.1 ALB SG — accepts HTTPS (and HTTP for redirect) from the whole internet
ALB_SG=$(aws ec2 create-security-group --group-name nifi-alb-sg \
  --description "ALB: public HTTPS" --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0      # only to redirect to 443

# 2.2 NiFi SG — 8443 only from ALB
NIFI_SG=$(aws ec2 create-security-group --group-name nifi-app-sg \
  --description "NiFi app" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $NIFI_SG \
  --protocol tcp --port 8443 --source-group $ALB_SG

# 2.3 Keycloak SG — 8080 from ALB, AND 8080 from NiFi
#     (NiFi exchanges tokens with Keycloak server-to-server inside the VPC)
KC_SG=$(aws ec2 create-security-group --group-name keycloak-sg \
  --description "Keycloak" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $KC_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG
aws ec2 authorize-security-group-ingress --group-id $KC_SG \
  --protocol tcp --port 8080 --source-group $NIFI_SG

# 2.4 Database SG — Postgres 5432 only from Keycloak
DB_SG=$(aws ec2 create-security-group --group-name keycloak-db-sg \
  --description "Keycloak Postgres" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $DB_SG \
  --protocol tcp --port 5432 --source-group $KC_SG
```

> **Notice: no SSH (port 22) anywhere.** We will administer instances with **AWS Systems Manager Session Manager**, which tunnels shell access through the AWS API with full IAM control and audit logging. No open ports, no key files to lose. (Details in Step 5.)

## Step 3 — TLS certificate with ACM

**What:** ACM issues free certificates that the ALB uses to serve HTTPS. **Why:** browsers require valid TLS; ACM certs auto-renew forever, so you never have a midnight "certificate expired" outage.

```bash
# One certificate covering both hostnames (SANs)
CERT_ARN=$(aws acm request-certificate \
  --domain-name "$NIFI_HOST" \
  --subject-alternative-names "$AUTH_HOST" \
  --validation-method DNS \
  --query 'CertificateArn' --output text)
```

**DNS validation:** ACM asks you to prove domain ownership by creating a special CNAME record. If your zone is in Route 53 (next step), you can add it in one click in the console, or:

```bash
# See the validation records ACM wants
aws acm describe-certificate --certificate-arn $CERT_ARN \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord'
# Create those CNAMEs in Route 53 (Step 4 shows record creation), then wait:
aws acm wait certificate-validated --certificate-arn $CERT_ARN
```

> **Why DNS validation, not email:** DNS validation is automatable and lets ACM renew silently forever. Email validation requires a human every renewal. Always choose DNS.

## Step 4 — DNS with Route 53

**What:** a *hosted zone* is your domain's DNS database in AWS.

```bash
# Create the hosted zone (skip if the domain was bought in Route 53 — it exists already)
ZONE_ID=$(aws route53 create-hosted-zone --name $DOMAIN \
  --caller-reference "nifi-$(date +%s)" \
  --query 'HostedZone.Id' --output text)

# If the domain is registered elsewhere: copy the 4 NS servers into your registrar
aws route53 get-hosted-zone --id $ZONE_ID --query 'DelegationSet.NameServers'
```

We'll add the actual `nifi.` and `auth.` records **after** the ALB exists (Step 7), because they must point at it.

## Step 5 — IAM role for the instances (SSM access)

**What:** an *instance profile* gives an EC2 machine its own AWS identity — no access keys on disk. **Why:** it enables Session Manager shell access and lets instances read secrets, following the golden rule *"roles, not keys."*

```bash
cat > trust.json << 'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole" }] }
EOF

aws iam create-role --role-name nifi-instance-role \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name nifi-instance-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name nifi-instance-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name nifi-instance-profile --role-name nifi-instance-role
```

Later, to get a shell on any instance (replace the instance ID):

```bash
aws ssm start-session --target i-0123456789abcdef0
```

## Step 6 — The database (RDS PostgreSQL) and secrets

**What:** a managed PostgreSQL for Keycloak. **Why RDS:** automated backups, patching, failover option, encryption — all the boring-but-critical database chores done for you. **Why Keycloak needs it:** without a real DB, Keycloak's dev mode stores users in a throwaway file — a restart would delete every account.

```bash
# 6.1 Generate & store the DB password in Secrets Manager (never in files/repos!)
DB_PASS=$(aws secretsmanager get-random-password \
  --password-length 32 --exclude-punctuation --query 'RandomPassword' --output text)
aws secretsmanager create-secret --name nifi/keycloak-db-password \
  --secret-string "$DB_PASS"

# 6.2 RDS needs a "subnet group" telling it which private subnets it may use
aws rds create-db-subnet-group \
  --db-subnet-group-name keycloak-db-subnets \
  --db-subnet-group-description "Keycloak DB private subnets" \
  --subnet-ids $PRIV_A $PRIV_B

# 6.3 The database instance
aws rds create-db-instance \
  --db-instance-identifier keycloak-db \
  --engine postgres --engine-version 16.6 \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 --storage-type gp3 \
  --db-name keycloak \
  --master-username keycloak --master-user-password "$DB_PASS" \
  --db-subnet-group-name keycloak-db-subnets \
  --vpc-security-group-ids $DB_SG \
  --no-publicly-accessible \
  --storage-encrypted \
  --backup-retention-period 7

aws rds wait db-instance-available --db-instance-identifier keycloak-db  # ~8 min

DB_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier keycloak-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
```

Flags worth understanding: `--no-publicly-accessible` (no public IP — only reachable inside the VPC), `--storage-encrypted` (encryption at rest with KMS), `--backup-retention-period 7` (7 days of point-in-time restore).

## Step 7 — Launch the EC2 instances

**What:** two Ubuntu 24.04 servers in the private subnets. **Why the sizes:** NiFi is a Java data engine that loves RAM → `t3.xlarge` (4 vCPU / 16 GB) is a sane floor for real work. Keycloak mostly idles between logins → `t3.medium` (2 vCPU / 4 GB).

```bash
# 7.1 Find the current official Ubuntu 24.04 AMI via SSM public parameter
#     (never hard-code AMI IDs — they differ per region and go stale)
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)

# 7.2 NiFi instance
NIFI_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.xlarge \
  --subnet-id $PRIV_A --security-group-ids $NIFI_SG \
  --iam-instance-profile Name=nifi-instance-profile \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,Encrypted=true}' \
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nifi}]' \
  --query 'Instances[0].InstanceId' --output text)

# 7.3 Keycloak instance
KC_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.medium \
  --subnet-id $PRIV_A --security-group-ids $KC_SG \
  --iam-instance-profile Name=nifi-instance-profile \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
  --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=keycloak}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $NIFI_ID $KC_ID
```

Two flags that are pure best practice:
- `--metadata-options HttpTokens=required` — enforces **IMDSv2**, blocking a classic credential-theft attack (SSRF against the metadata service).
- `Encrypted=true` on the disks — EBS encryption at rest, free and transparent.

## Step 8 — The Application Load Balancer

**What:** one ALB with an HTTPS listener that routes **by hostname**: `auth.example.com` → Keycloak target group, everything else (`nifi.example.com`) → NiFi target group.

```bash
# 8.1 The ALB itself — in the PUBLIC subnets
ALB_ARN=$(aws elbv2 create-load-balancer --name nifi-alb \
  --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_ZONE=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

# 8.2 Target groups — "which servers, which port, and how to health-check them"
# NiFi speaks HTTPS on 8443 (NiFi 2.x requires TLS). The ALB does NOT verify the
# instance's self-signed cert — that's fine and normal for ALB→target traffic.
NIFI_TG=$(aws elbv2 create-target-group --name nifi-tg \
  --protocol HTTPS --port 8443 --vpc-id $VPC_ID --target-type instance \
  --health-check-protocol HTTPS --health-check-path /nifi/ \
  --matcher HttpCode=200-399 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Keycloak listens on plain HTTP 8080; the ALB terminates TLS for it.
KC_TG=$(aws elbv2 create-target-group --name keycloak-tg \
  --protocol HTTP --port 8080 --vpc-id $VPC_ID --target-type instance \
  --health-check-protocol HTTP --health-check-path /realms/master \
  --matcher HttpCode=200-399 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Sticky sessions for NiFi (its UI keeps per-node state; essential if you cluster later)
aws elbv2 modify-target-group-attributes --target-group-arn $NIFI_TG \
  --attributes Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie

aws elbv2 register-targets --target-group-arn $NIFI_TG --targets Id=$NIFI_ID
aws elbv2 register-targets --target-group-arn $KC_TG  --targets Id=$KC_ID

# 8.3 Listeners
# HTTPS 443: default action → NiFi; add a host rule for Keycloak
HTTPS_LISTENER=$(aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn=$NIFI_TG \
  --query 'Listeners[0].ListenerArn' --output text)

aws elbv2 create-rule --listener-arn $HTTPS_LISTENER --priority 10 \
  --conditions Field=host-header,Values=$AUTH_HOST \
  --actions Type=forward,TargetGroupArn=$KC_TG

# HTTP 80: permanent redirect to HTTPS (never serve the apps over HTTP)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'
```

## Step 9 — DNS records pointing at the ALB

**What:** Route 53 **alias A records** — a special AWS record type that points a name directly at an AWS resource. **Why alias, not CNAME:** aliases are free to query, work at the zone apex, and track the ALB's changing IPs automatically.

```bash
cat > records.json << EOF
{ "Changes": [
  { "Action": "UPSERT", "ResourceRecordSet": {
      "Name": "$NIFI_HOST", "Type": "A",
      "AliasTarget": { "HostedZoneId": "$ALB_ZONE",
        "DNSName": "$ALB_DNS", "EvaluateTargetHealth": true } } },
  { "Action": "UPSERT", "ResourceRecordSet": {
      "Name": "$AUTH_HOST", "Type": "A",
      "AliasTarget": { "HostedZoneId": "$ALB_ZONE",
        "DNSName": "$ALB_DNS", "EvaluateTargetHealth": true } } }
] }
EOF
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID \
  --change-batch file://records.json
```

## Step 10 — Install and configure Keycloak (on the Keycloak instance)

Open a shell on the box: `aws ssm start-session --target $KC_ID`, then:

```bash
# 10.1 Java 21 + Keycloak
sudo apt-get update && sudo apt-get install -y openjdk-21-jre-headless unzip
cd /opt
sudo curl -LO https://github.com/keycloak/keycloak/releases/download/26.6.4/keycloak-26.6.4.zip
sudo unzip -q keycloak-26.6.4.zip && sudo mv keycloak-26.6.4 keycloak
sudo useradd -r -s /usr/sbin/nologin keycloak
sudo chown -R keycloak:keycloak /opt/keycloak

# 10.2 Production config — /opt/keycloak/conf/keycloak.conf
sudo tee /opt/keycloak/conf/keycloak.conf << EOF
db=postgres
db-url=jdbc:postgresql://<DB_ENDPOINT>:5432/keycloak
db-username=keycloak
db-password=<DB_PASS from Secrets Manager>

# Public address users see (the ALB hostname)
hostname=https://auth.example.com

# We sit behind an ALB that terminates TLS:
http-enabled=true
proxy-headers=xforwarded

health-enabled=true
EOF
```

**The three lines that make or break a reverse-proxy setup:**
- `hostname=https://auth.example.com` — Keycloak builds every login URL and token `issuer` from this. If wrong, tokens say the wrong issuer and NiFi rejects them.
- `http-enabled=true` — allow plain HTTP *inside the VPC only*, because the ALB already did TLS.
- `proxy-headers=xforwarded` — trust the `X-Forwarded-Proto/For/Host` headers the ALB adds, so Keycloak knows the *user's* connection was HTTPS and generates `https://` URLs.

```bash
# 10.3 Build optimized server & create a bootstrap admin, then a systemd service
sudo -u keycloak /opt/keycloak/bin/kc.sh build

sudo tee /etc/systemd/system/keycloak.service << 'EOF'
[Unit]
Description=Keycloak
After=network.target
[Service]
User=keycloak
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=admin
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=CHANGE_ME_ONCE
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now keycloak
```

> The bootstrap admin variables create a **temporary** admin on first boot. Log in once, create your real permanent admin account, delete the bootstrap one, and remove the environment lines. Do not leave bootstrap credentials in the unit file.

### 10.4 Create the realm, client, and a user

Browse to `https://auth.example.com` → **Administration Console** → log in.

1. **Create realm:** top-left realm dropdown → *Create realm* → name `nifi-realm`.
   *Why a new realm and not `master`?* The `master` realm governs Keycloak itself; apps and humans belong in their own realm — clean separation, safer blast radius.
2. **Create client:** Clients → *Create client*
   - Client type: **OpenID Connect**; Client ID: `nifi`
   - **Client authentication: ON** → this makes it a *confidential* client that gets a **client secret**. NiFi is a server, it can keep a secret — always use confidential clients for server-side apps.
   - Standard flow: ON (that's the Authorization Code Flow). Direct access grants: OFF (password-in-API flow; deprecated, disable it).
   - **Valid redirect URIs:** `https://nifi.example.com/nifi-api/access/oidc/callback`
   - **Valid post logout redirect URIs:** `https://nifi.example.com/nifi-api/access/oidc/logoutCallback`
   - Web origins: `https://nifi.example.com`
   > These exact paths are NiFi 2.x's OIDC endpoints. A single wrong character here produces Keycloak's infamous `Invalid parameter: redirect_uri` error.
3. Copy the secret: Clients → nifi → **Credentials** tab → *Client Secret*.
4. **Create a user:** Users → *Create user* → username `alice`, **email `alice@example.com` (fill it in — NiFi will identify her by email!)**, mark email verified → Credentials tab → set password (temporary OFF).

## Step 11 — Install and configure NiFi (on the NiFi instance)

`aws ssm start-session --target $NIFI_ID`, then:

```bash
# 11.1 Java 21 + NiFi 2.10.0
sudo apt-get update && sudo apt-get install -y openjdk-21-jre-headless unzip
cd /opt
sudo curl -LO https://dlcdn.apache.org/nifi/2.10.0/nifi-2.10.0-bin.zip
sudo unzip -q nifi-2.10.0-bin.zip && sudo mv nifi-2.10.0 nifi
sudo useradd -r -s /usr/sbin/nologin nifi
sudo chown -R nifi:nifi /opt/nifi
```

### 11.2 Edit `/opt/nifi/conf/nifi.properties`

```properties
# --- Web/HTTPS (NiFi 2.x is HTTPS-only for non-localhost) ---
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443

# CRITICAL behind a load balancer: allow-list the public hostname the
# browser uses, or NiFi rejects requests with "invalid host header"
nifi.web.proxy.host=nifi.example.com

# --- OIDC login via Keycloak ---
nifi.security.user.oidc.discovery.url=https://auth.example.com/realms/nifi-realm/.well-known/openid-configuration
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=<the client secret from step 10.4>
# Which token claim becomes the NiFi username — email is the common, stable choice
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.additional.scopes=email,profile
```

NiFi 2.x auto-generates a self-signed keystore/truststore on first start for its own 8443 listener — the ALB accepts it, so you don't need to manage instance certs (the *public* cert is ACM's, at the ALB).

### 11.3 Edit `/opt/nifi/conf/authorizers.xml` — the authorization side

Remember: Keycloak proves *who*; this file decides *what they may do*. We tell NiFi's file-based authorizer that Alice is the first admin:

```xml
<userGroupProvider>
    <identifier>file-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
    <property name="Users File">./conf/users.xml</property>
    <property name="Initial User Identity 1">alice@example.com</property>
</userGroupProvider>

<accessPolicyProvider>
    <identifier>file-access-policy-provider</identifier>
    <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
    <property name="User Group Provider">file-user-group-provider</property>
    <property name="Authorizations File">./conf/authorizations.xml</property>
    <property name="Initial Admin Identity">alice@example.com</property>
</accessPolicyProvider>
```

> **Gotchas:** the identity string must match the token claim **exactly, case-sensitively** (`alice@example.com`). And NiFi only reads *Initial Admin Identity* when `users.xml`/`authorizations.xml` don't exist yet — if you change it later, delete those two generated files and restart.

Also comment out / remove the `single-user-provider` blocks in both `authorizers.xml` and `login-identity-providers.xml` context (NiFi uses OIDC when the discovery URL is set).

### 11.4 systemd service and start

```bash
sudo tee /etc/systemd/system/nifi.service << 'EOF'
[Unit]
Description=Apache NiFi
After=network.target
[Service]
Type=forking
User=nifi
ExecStart=/opt/nifi/bin/nifi.sh start
ExecStop=/opt/nifi/bin/nifi.sh stop
LimitNOFILE=50000
TimeoutStartSec=300
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload && sudo systemctl enable --now nifi
# Watch it come up (~1-2 min):
sudo tail -f /opt/nifi/logs/nifi-app.log
```

## Step 12 — Test the login 🎉

1. Browse to `https://nifi.example.com/nifi` → you're redirected to the Keycloak login page at `auth.example.com`.
2. Log in as `alice` → redirected back → the NiFi canvas loads, top-right shows `alice@example.com`.
3. In NiFi: hamburger menu → **Policies** — as initial admin, Alice can now grant other Keycloak users access.

If anything fails, jump to the [troubleshooting guide](#10-troubleshooting-guide) — the answer is almost certainly one of six classic mistakes listed there.

---

# 4. Part B — Deep dive: every AWS service explained

Part A moved fast. Here is the *why* behind each service, in depth.

## 4.1 VPC — Virtual Private Cloud

**What it is:** a logically isolated virtual network. Nothing in your VPC can be reached by anyone else's VPC or the internet unless you explicitly open a path. You define its private IP range with **CIDR notation**: `10.0.0.0/16` means "the first 16 bits are fixed" → addresses `10.0.0.0`–`10.0.255.255` (65,536 of them).

**Key sub-concepts:**
- **Subnet** = a slice of the VPC's range, pinned to exactly one Availability Zone. A `/24` = 256 addresses (AWS reserves 5 per subnet).
- **Public subnet** = a subnet whose route table has a route to an **Internet Gateway**. Resources there *may* get public IPs.
- **Private subnet** = no IGW route. Even if the security group allowed it, the internet packets simply have no road to travel.
- **Route table** = per-subnet rules: "traffic for 10.0.0.0/16 stays local; traffic for 0.0.0.0/0 (everything else) goes to X."
- **Internet Gateway (IGW)** = two-way door to the internet, free, fully managed.
- **NAT Gateway** = one-way valve for private subnets: outbound requests get translated to the NAT's public IP; unsolicited inbound is impossible. Costs ~$32/month + data — the main "hidden cost" of this design (see §9 for cheaper options).

**Why we designed it this way:** the *only* internet-facing thing is the ALB. If NiFi or Keycloak had a vulnerability, an attacker on the internet still has no route to it except through the ALB on 443. This "public edge, private core" pattern is the standard three-tier AWS architecture and the top recommendation of the AWS Well-Architected Framework's security pillar.

**Best practices:** don't use the default VPC for real workloads; pick CIDRs that won't overlap with your office/VPN networks (avoid the ultra-common 192.168.0.0/16); tag everything; keep at least 2 AZs.

## 4.2 Security Groups vs. Network ACLs

Two firewall layers exist; we used **Security Groups**:

| | Security Group | Network ACL |
|---|---|---|
| Attaches to | Instance/ENI (the resource) | Subnet (the room) |
| Stateful? | Yes — replies auto-allowed | No — must allow both directions |
| Rules | Allow only | Allow **and** Deny |
| Can reference other SGs? | **Yes** (killer feature) | No, only CIDRs |
| Typical use | Everything | Rare: coarse subnet-level blocks |

The SG-references-SG trick (`--source-group $ALB_SG`) gives you **identity-based** firewalling: "whatever wears the ALB badge may enter," regardless of IPs. Best practices: one SG per role, never `0.0.0.0/0` inbound except on the public ALB, describe every rule, and prefer SSM over opening port 22.

## 4.3 EC2 — instances, AMIs, EBS, metadata

- **Instance types:** letters = family (`t` burstable general, `m` general, `c` compute, `r` memory-heavy), number = generation, suffix = variant (`g` = Graviton/ARM, cheaper). NiFi guidance: it's JVM + disk-heavy; give it ≥16 GB RAM, gp3 volumes, and set NiFi's JVM heap (`conf/bootstrap.conf`, e.g. `-Xms8g -Xmx8g`) to roughly half the RAM, leaving the rest for OS disk cache.
- **AMI (Amazon Machine Image):** the frozen disk snapshot + metadata an instance boots from. We look AMIs up via SSM public parameters because IDs differ per region and rotate as patches ship.
- **EBS (Elastic Block Store):** network-attached SSD disks. `gp3` is the modern default (independent size/IOPS/throughput knobs). Always encrypt — it's free and invisible.
- **User data:** a script that runs on first boot (cloud-init) — how Terraform will inject per-environment config into our pre-baked image.
- **Instance metadata service (IMDS):** `http://169.254.169.254` inside every instance serves its identity and role credentials. **IMDSv2** (`HttpTokens=required`) demands a session token first, defeating SSRF-based credential theft. Non-negotiable best practice.

## 4.4 ALB — Application Load Balancer

An ALB is a **Layer-7** (HTTP-aware) load balancer. Because it reads the HTTP request, it can route by **host header** (our trick: one ALB, two apps), by path, and it can terminate TLS, redirect HTTP→HTTPS, health-check targets, and stick sessions.

Concepts:
- **Listener** = "I accept protocol X on port Y" + rules.
- **Rule** = condition (host = `auth.example.com`) → action (forward to target group). Rules are evaluated by priority; the default action catches the rest.
- **Target group** = a set of backends + port + protocol + **health check**. Unhealthy targets stop receiving traffic automatically.
- **Stickiness** = a cookie that pins a user to one target. Needed for NiFi if you ever run more than one node, because UI session state is per-node.
- **X-Forwarded-\* headers** = the ALB tells the backend the original client IP (`X-Forwarded-For`), protocol (`X-Forwarded-Proto`), and host. This is exactly what Keycloak's `proxy-headers=xforwarded` consumes.

**Why ALB→NiFi is HTTPS but ALB→Keycloak is HTTP:** NiFi 2.x *refuses* to serve plain HTTP on a non-localhost interface, so the ALB re-encrypts to it (the ALB does not validate the backend's self-signed cert — by design). Keycloak happily serves HTTP when told a proxy handles TLS, so we keep it simple. Both are fine because ALB↔instance traffic never leaves your VPC; re-encrypting to Keycloak too is a hardening option for strict compliance (see §9).

**Best practices:** modern TLS policy (`ELBSecurityPolicy-TLS13-1-2-2021-06`), HTTP→HTTPS 301 redirect, enable ALB access logs to S3 in production, consider AWS WAF in front for internet-exposed admin UIs.

## 4.5 Route 53 — DNS

DNS is the internet's phone book. Route 53 pieces:
- **Hosted zone** — your domain's record database (~$0.50/mo).
- **Record types:** `A` (name→IPv4), `CNAME` (name→another name, not allowed at the domain apex), and Route 53's special **Alias** record — behaves like an A record but points at an AWS resource by name, tracks its IP changes, works at the apex, and queries are free. Always use Alias for ALBs.
- **TTL** — how long resolvers cache an answer (aliases inherit sensible values automatically).
- **Registration vs. hosting** are separate: you can register anywhere and host DNS in Route 53 by pointing the registrar's NS records at the 4 Route 53 nameservers.

## 4.6 ACM — Certificate Manager

TLS certificates prove to browsers that `nifi.example.com` is really you, enabling the encrypted padlock. ACM issues them **free**, and because AWS controls both the cert and the ALB, it **renews and deploys automatically forever** — eliminating the classic expired-cert outage. Constraints worth knowing: ACM public certs can only be *used* on AWS-managed endpoints (ALB, CloudFront, API Gateway) — you can't export the private key to install on an EC2 box; that's another reason TLS terminates at the ALB. One cert can cover many names (SANs) or wildcards (`*.example.com`).

## 4.7 RDS — managed PostgreSQL

RDS runs the database engine for you: automated daily backups + 5-minute point-in-time recovery, minor-version patching, storage autoscaling, optional **Multi-AZ** standby with automatic failover, and encryption. Keycloak stores realms, clients, users, and sessions here — it is the *only* stateful part of the Keycloak tier, which is what would let you run multiple Keycloak nodes later. Best practices: private subnets only, SG locked to Keycloak, `db.t4g.*` (Graviton) for cheap small instances, turn on deletion protection and Multi-AZ in production.

## 4.8 IAM, SSM, and Secrets Manager

- **IAM** answers "which AWS API calls may this human/machine make?" Policies are JSON allow/deny documents attached to users, groups, and **roles**. Roles are assumable identities with auto-rotating temporary credentials — instances get them via **instance profiles**, which is why our servers have zero stored keys.
- **SSM Session Manager** replaces SSH: shell sessions ride the AWS API, gated by IAM, optionally logged keystroke-by-keystroke to CloudWatch/S3. No inbound ports, no key sprawl.
- **Secrets Manager** stores secrets encrypted with KMS, offers rotation, and audit-logs every read. Cheaper cousin: **SSM Parameter Store** (`SecureString`) — fine for most cases, free tier. The rule that matters: *no secret ever appears in Git, user data, or AMIs.* Terraform/Ansible will *read* from these stores at deploy time.

## 4.9 CloudWatch (brief but important)

CloudWatch collects metrics (CPU, ALB target health, RDS connections), logs (install the CloudWatch agent to ship `nifi-app.log`), and alarms (e-mail/Slack when the target group has 0 healthy hosts). Minimum production set: an alarm on each target group's `HealthyHostCount`, one on RDS `FreeStorageSpace`, and one on NiFi instance `CPUUtilization`.

---

# 5. Part C — Building a base image (AMI) with Packer

## 5.1 Why bake an image?

| | Install at boot ("configure on launch") | Golden AMI (bake once) |
|---|---|---|
| Boot-to-ready time | 10–20 min | ~1–2 min |
| Reliability | Depends on download mirrors at boot | Everything already on disk |
| Consistency | Versions can drift between launches | Byte-identical every launch |
| Auto Scaling friendliness | Poor (slow scale-out) | Excellent |
| Security scanning | Hard | Scan the image once, before release |

The recipe: **Packer** launches a temporary EC2 instance, runs your install steps (here: an Ansible playbook), snapshots the disk into an AMI, and terminates the temp instance. The AMI contains *software* but **no configuration and no secrets** — those are applied at launch (user data / Ansible), so one image serves dev, staging, and prod.

## 5.2 Packer template — `nifi-ami.pkr.hcl`

```hcl
packer {
  required_plugins {
    amazon  = { source = "github.com/hashicorp/amazon",  version = ">= 1.3" }
    ansible = { source = "github.com/hashicorp/ansible", version = ">= 1.1" }
  }
}

variable "aws_region"       { default = "us-east-1" }
variable "nifi_version"     { default = "2.10.0" }
variable "keycloak_version" { default = "26.6.4" }

source "amazon-ebs" "nifi_base" {
  region        = var.aws_region
  instance_type = "t3.large"
  ssh_username  = "ubuntu"

  # Always build from the latest patched Ubuntu 24.04
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"]   # Canonical's official AWS account
    most_recent = true
  }

  ami_name = "nifi-keycloak-base-${var.nifi_version}-{{timestamp}}"
  tags = {
    Name             = "nifi-keycloak-base"
    NiFiVersion      = var.nifi_version
    KeycloakVersion  = var.keycloak_version
    BuiltBy          = "packer"
  }

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
    delete_on_termination = true
  }
}

build {
  sources = ["source.amazon-ebs.nifi_base"]

  # Run the "bake" Ansible playbook against the temp instance
  provisioner "ansible" {
    playbook_file = "./ansible/bake.yml"
    extra_arguments = [
      "-e", "nifi_version=${var.nifi_version}",
      "-e", "keycloak_version=${var.keycloak_version}",
    ]
  }

  # Best practice: scrub logs, ssh host keys, machine-id so every
  # instance launched from this AMI is a clean, unique machine
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean --logs",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -rf /tmp/* /var/tmp/*",
    ]
  }
}
```

The bake playbook (`ansible/bake.yml`) installs Java 21, downloads and unpacks NiFi and Keycloak to `/opt`, creates service users and systemd unit files, **but leaves the services disabled and the config files as templates** — Part E's "configure" playbook fills those in per environment.

## 5.3 Build it

```bash
packer init nifi-ami.pkr.hcl
packer validate nifi-ami.pkr.hcl
packer build nifi-ami.pkr.hcl
#  ==> amazon-ebs.nifi_base: AMI: ami-0abc123def456...
```

**Best practices for image pipelines:** rebuild on a schedule (e.g., monthly) to pick up OS patches; tag images with versions and Git commit; scan with Amazon Inspector or Trivy before promoting; keep the last few AMIs for rollback; never bake secrets, host keys, or environment-specific hostnames into the image. (AWS's managed alternative is **EC2 Image Builder** — same idea, more AWS-native, less portable than Packer.)

---

# 6. Part D — Automating infrastructure with Terraform

## 6.1 How Terraform thinks

You write **declarative** `.tf` files describing the end state ("there shall be a VPC, an ALB…"). Terraform compares that with its **state file** (its memory of what it built) and computes a **plan** — create/change/destroy exactly what's needed. Core loop:

```bash
terraform init      # download providers, connect state backend
terraform plan      # show the diff — ALWAYS read it
terraform apply     # execute (asks for confirmation)
terraform destroy   # tear everything down
```

**Best practices up front:** keep state in a **remote backend** (S3 with locking) — never on a laptop; pin provider versions; one *workspace/state per environment*; put nothing secret in `.tf` files or state you can avoid; run `plan` in CI on every pull request.

## 6.2 Project layout

```
terraform/
├── backend.tf        # remote state config
├── providers.tf      # AWS provider + versions
├── variables.tf      # inputs (domain, ami_id, sizes…)
├── network.tf        # VPC, subnets, IGW, NAT, routes
├── security.tf       # security groups
├── dns_certs.tf      # Route 53 + ACM (+ auto-validation!)
├── database.tf       # RDS + Secrets Manager
├── compute.tf        # IAM role, EC2 instances (from the Packer AMI)
├── alb.tf            # ALB, target groups, listeners, rules
└── outputs.tf        # URLs, IDs printed after apply
```

## 6.3 The code (condensed but complete-in-spirit)

```hcl
# ---------- backend.tf ----------
terraform {
  required_version = ">= 1.9"
  backend "s3" {
    bucket       = "mycompany-terraform-state"
    key          = "nifi/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true          # S3-native state locking (no DynamoDB needed)
    encrypt      = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

# ---------- variables.tf ----------
variable "domain"        { type = string }                 # example.com
variable "ami_id"        { type = string }                 # from Packer
variable "nifi_instance_type"     { default = "t3.xlarge" }
variable "keycloak_instance_type" { default = "t3.medium" }
locals {
  nifi_host = "nifi.${var.domain}"
  auth_host = "auth.${var.domain}"
}

# ---------- network.tf ----------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "nifi-vpc" }
}

data "aws_availability_zones" "azs" { state = "available" }

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.azs.names[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 11}.0/24"
  availability_zone = data.aws_availability_zones.azs.names[count.index]
  tags = { Name = "private-${count.index}" }
}

resource "aws_internet_gateway" "igw" { vpc_id = aws_vpc.main.id }

resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0", gateway_id = aws_internet_gateway.igw.id }
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0", nat_gateway_id = aws_nat_gateway.nat.id }
}
resource "aws_route_table_association" "pub" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "priv" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------- security.tf (SG-to-SG references, same design as Part A) ----------
resource "aws_security_group" "alb" {
  name = "nifi-alb-sg"  vpc_id = aws_vpc.main.id
  ingress { from_port = 443 to_port = 443 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80  to_port = 80  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0   to_port = 0   protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_security_group" "nifi" {
  name = "nifi-app-sg"  vpc_id = aws_vpc.main.id
  ingress { from_port = 8443 to_port = 8443 protocol = "tcp" security_groups = [aws_security_group.alb.id] }
  egress  { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_security_group" "keycloak" {
  name = "keycloak-sg"  vpc_id = aws_vpc.main.id
  ingress { from_port = 8080 to_port = 8080 protocol = "tcp"
            security_groups = [aws_security_group.alb.id, aws_security_group.nifi.id] }
  egress  { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_security_group" "db" {
  name = "keycloak-db-sg"  vpc_id = aws_vpc.main.id
  ingress { from_port = 5432 to_port = 5432 protocol = "tcp"
            security_groups = [aws_security_group.keycloak.id] }
}

# ---------- dns_certs.tf — the part Terraform makes MUCH nicer than the CLI ----------
data "aws_route53_zone" "main" { name = var.domain }

resource "aws_acm_certificate" "cert" {
  domain_name               = local.nifi_host
  subject_alternative_names = [local.auth_host]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

# Auto-create the DNS validation records — zero manual clicking
resource "aws_route53_record" "cert_validation" {
  for_each = { for dvo in aws_acm_certificate.cert.domain_validation_options :
               dvo.domain_name => dvo }
  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60
}
resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- database.tf ----------
resource "random_password" "db" { length = 32  special = false }

resource "aws_secretsmanager_secret" "db" { name = "nifi/keycloak-db-password" }
resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}

resource "aws_db_subnet_group" "kc" {
  name       = "keycloak-db-subnets"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_instance" "keycloak" {
  identifier              = "keycloak-db"
  engine                  = "postgres"
  engine_version          = "16.6"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  storage_type            = "gp3"
  db_name                 = "keycloak"
  username                = "keycloak"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.kc.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  publicly_accessible     = false
  storage_encrypted       = true
  backup_retention_period = 7
  skip_final_snapshot     = false
  final_snapshot_identifier = "keycloak-db-final"
  deletion_protection     = true
}

# ---------- compute.tf ----------
resource "aws_iam_role" "instance" {
  name = "nifi-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole",
                   Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
# Allow instances to READ the DB secret (least-privilege inline policy)
resource "aws_iam_role_policy" "secrets" {
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "secretsmanager:GetSecretValue",
                   Resource = aws_secretsmanager_secret.db.arn }]
  })
}
resource "aws_iam_instance_profile" "instance" {
  name = "nifi-instance-profile"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "keycloak" {
  ami                    = var.ami_id            # <-- the Packer AMI
  instance_type          = var.keycloak_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  metadata_options { http_tokens = "required" }   # IMDSv2
  root_block_device { volume_size = 30 volume_type = "gp3" encrypted = true }
  tags = { Name = "keycloak", Role = "keycloak", Env = "prod" }
}

resource "aws_instance" "nifi" {
  ami                    = var.ami_id
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  metadata_options { http_tokens = "required" }
  root_block_device { volume_size = 100 volume_type = "gp3" encrypted = true }
  tags = { Name = "nifi", Role = "nifi", Env = "prod" }
}

# ---------- alb.tf ----------
resource "aws_lb" "main" {
  name               = "nifi-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "nifi" {
  name        = "nifi-tg"
  port        = 8443
  protocol    = "HTTPS"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check { protocol = "HTTPS" path = "/nifi/" matcher = "200-399" }
  stickiness   { type = "lb_cookie" enabled = true }
}
resource "aws_lb_target_group" "keycloak" {
  name     = "keycloak-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check { protocol = "HTTP" path = "/realms/master" matcher = "200-399" }
}

resource "aws_lb_target_group_attachment" "nifi" {
  target_group_arn = aws_lb_target_group.nifi.arn
  target_id        = aws_instance.nifi.id
}
resource "aws_lb_target_group_attachment" "keycloak" {
  target_group_arn = aws_lb_target_group.keycloak.arn
  target_id        = aws_instance.keycloak.id
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.cert.certificate_arn
  default_action { type = "forward" target_group_arn = aws_lb_target_group.nifi.arn }
}
resource "aws_lb_listener_rule" "keycloak" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10
  condition { host_header { values = [local.auth_host] } }
  action    { type = "forward" target_group_arn = aws_lb_target_group.keycloak.arn }
}
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect { protocol = "HTTPS" port = "443" status_code = "HTTP_301" }
  }
}

# ---------- Route 53 records ----------
resource "aws_route53_record" "app" {
  for_each = toset([local.nifi_host, local.auth_host])
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = each.value
  type     = "A"
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# ---------- outputs.tf ----------
output "nifi_url"     { value = "https://${local.nifi_host}/nifi" }
output "keycloak_url" { value = "https://${local.auth_host}" }
output "nifi_instance_id"     { value = aws_instance.nifi.id }
output "keycloak_instance_id" { value = aws_instance.keycloak.id }
output "db_endpoint"  { value = aws_db_instance.keycloak.address }
```

## 6.4 Run it

```bash
cd terraform
terraform init
terraform plan  -var domain=example.com -var ami_id=ami-0abc123def456
terraform apply -var domain=example.com -var ami_id=ami-0abc123def456
```

Notice what Terraform bought us over the CLI script: automatic ordering via dependencies, ACM validation records created *automatically*, a reviewable plan, idempotency (run `apply` twice → no changes), and one-command teardown.

---

# 7. Part E — Configuring servers with Ansible

## 7.1 How Ansible thinks

Ansible SSHes (or, for us, tunnels over **SSM**) into machines and applies **idempotent** tasks described in YAML **playbooks**. Idempotent = "make it so": running twice changes nothing the second time. Key words: **inventory** (which hosts, in which groups), **role** (a reusable bundle of tasks/templates/handlers for one job, e.g. `nifi`), **template** (a Jinja2 file with `{{ variables }}`), **handler** (a task like "restart nifi" triggered only when something actually changed), **vault** (encrypted variable files — though we pull secrets from AWS instead).

## 7.2 Layout & dynamic inventory

```
ansible/
├── ansible.cfg
├── inventory/aws_ec2.yml          # dynamic inventory — discovers instances by tag
├── group_vars/
│   ├── all.yml                    # domain, versions, shared vars
│   ├── role_nifi.yml
│   └── role_keycloak.yml
├── bake.yml                       # used by Packer (installs binaries)
├── site.yml                       # runtime configuration
└── roles/
    ├── nifi/{tasks,templates,handlers}/
    └── keycloak/{tasks,templates,handlers}/
```

Dynamic inventory (`inventory/aws_ec2.yml`) means you never hand-maintain IP lists — Ansible asks AWS "who has tag Role=nifi?" (the tags Terraform set!):

```yaml
plugin: amazon.aws.aws_ec2
regions: [us-east-1]
filters:
  instance-state-name: running
  tag:Env: prod
keyed_groups:
  - key: tags.Role          # creates groups: role_nifi, role_keycloak
    prefix: role
```

And `ansible.cfg` to ride over SSM (no SSH ports needed — matches our locked-down SGs):

```ini
[defaults]
inventory = inventory/aws_ec2.yml
[ssm_connection]
# use community.aws.aws_ssm connection per-group:
#   ansible_connection=community.aws.aws_ssm
#   ansible_aws_ssm_bucket_name=my-ssm-transfer-bucket
```

## 7.3 The Keycloak role (highlights)

`roles/keycloak/templates/keycloak.conf.j2` — the same file we wrote by hand, now templated:

```jinja
db=postgres
db-url=jdbc:postgresql://{{ db_endpoint }}:5432/keycloak
db-username=keycloak
db-password={{ db_password }}
hostname=https://auth.{{ domain }}
http-enabled=true
proxy-headers=xforwarded
health-enabled=true
```

`roles/keycloak/tasks/main.yml`:

```yaml
- name: Fetch DB password from AWS Secrets Manager (never stored in the repo)
  set_fact:
    db_password: "{{ lookup('amazon.aws.aws_secret', 'nifi/keycloak-db-password') }}"
  no_log: true

- name: Render keycloak.conf
  template:
    src: keycloak.conf.j2
    dest: /opt/keycloak/conf/keycloak.conf
    owner: keycloak
    mode: "0600"
  notify: restart keycloak          # handler fires ONLY if the file changed

- name: Ensure Keycloak is enabled and running
  systemd: { name: keycloak, state: started, enabled: true }

# --- Declarative realm/client setup via community.general keycloak modules ---
- name: Create nifi-realm
  community.general.keycloak_realm:
    auth_keycloak_url: "http://localhost:8080"
    auth_realm: master
    auth_username: "{{ kc_admin_user }}"
    auth_password: "{{ kc_admin_password }}"
    id: nifi-realm
    realm: nifi-realm
    enabled: true

- name: Create the NiFi OIDC client
  community.general.keycloak_client:
    auth_keycloak_url: "http://localhost:8080"
    auth_realm: master
    auth_username: "{{ kc_admin_user }}"
    auth_password: "{{ kc_admin_password }}"
    realm: nifi-realm
    client_id: nifi
    protocol: openid-connect
    public_client: false                    # confidential -> has a secret
    standard_flow_enabled: true
    direct_access_grants_enabled: false
    redirect_uris:
      - "https://nifi.{{ domain }}/nifi-api/access/oidc/callback"
    attributes:
      post.logout.redirect.uris: "https://nifi.{{ domain }}/nifi-api/access/oidc/logoutCallback"
    web_origins: ["https://nifi.{{ domain }}"]
  register: nifi_client

- name: Store the generated client secret in SSM Parameter Store for the NiFi role
  community.aws.ssm_parameter:
    name: /nifi/oidc-client-secret
    value: "{{ nifi_client.end_state.secret }}"
    string_type: SecureString
  no_log: true
```

This is the payoff of automation: **even the Keycloak realm and client are code** — rebuild the server and the realm reappears identically.

## 7.4 The NiFi role (highlights)

`roles/nifi/templates/nifi.properties.j2` (only the lines we manage — in practice you template the whole file or use `lineinfile`):

```jinja
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
nifi.web.proxy.host=nifi.{{ domain }}

nifi.security.user.oidc.discovery.url=https://auth.{{ domain }}/realms/nifi-realm/.well-known/openid-configuration
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret={{ oidc_client_secret }}
nifi.security.user.oidc.claim.identifying.user=email
nifi.security.user.oidc.additional.scopes=email,profile
```

`roles/nifi/tasks/main.yml`:

```yaml
- name: Fetch OIDC client secret from SSM
  set_fact:
    oidc_client_secret: "{{ lookup('amazon.aws.aws_ssm', '/nifi/oidc-client-secret') }}"
  no_log: true

- name: Render nifi.properties
  template: { src: nifi.properties.j2, dest: /opt/nifi/conf/nifi.properties,
              owner: nifi, mode: "0600" }
  notify: restart nifi

- name: Render authorizers.xml with the initial admin
  template: { src: authorizers.xml.j2, dest: /opt/nifi/conf/authorizers.xml,
              owner: nifi, mode: "0600" }
  notify: restart nifi

- name: Ensure NiFi is enabled and running
  systemd: { name: nifi, state: started, enabled: true }
```

`roles/nifi/handlers/main.yml`:

```yaml
- name: restart nifi
  systemd: { name: nifi, state: restarted }
- name: restart keycloak
  systemd: { name: keycloak, state: restarted }
```

## 7.5 `site.yml` and running it

```yaml
- hosts: role_keycloak
  become: true
  roles: [keycloak]

- hosts: role_nifi
  become: true
  roles: [nifi]
```

```bash
cd ansible
ansible-galaxy collection install amazon.aws community.aws community.general
ansible-playbook site.yml -e domain=example.com \
  -e db_endpoint=$(terraform -chdir=../terraform output -raw db_endpoint)
```

**The full pipeline, end to end:**

```
git push ─▶ Packer build (new AMI) ─▶ terraform apply (infra + AMI id)
                                          │
                                          ▼
                              ansible-playbook site.yml
                          (config, realm, client, secrets)
                                          │
                                          ▼
                         https://nifi.example.com  🔒 login via Keycloak
```

---

# 8. Best practices checklist

**Network & access**
- ✅ Apps in **private subnets**; only the ALB is internet-facing.
- ✅ Security groups reference **other security groups**, not IPs; no `0.0.0.0/0` except ALB 80/443.
- ✅ **No SSH** — SSM Session Manager with IAM control and session logging.
- ✅ **IMDSv2 required** on every instance.
- ✅ HTTP→HTTPS 301 redirect; modern TLS policy (TLS 1.2/1.3 only).
- ✅ Consider **AWS WAF** on the ALB for an internet-exposed admin UI (rate limiting, IP allow-lists, managed rules).

**Identity & secrets**
- ✅ Dedicated Keycloak **realm** (never put apps in `master`); **confidential** OIDC client; *Direct Access Grants off*.
- ✅ Exact-match **redirect URIs** — no wildcards in production.
- ✅ All secrets in **Secrets Manager / SSM SecureString**; instances read them via **IAM roles** (no keys on disk, nothing in Git).
- ✅ Delete the Keycloak bootstrap admin after first login; enforce MFA for admins; shorten token lifetimes if defaults feel long.
- ✅ NiFi identity claim = `email`; NiFi's own **policies** (authorization) managed deliberately — initial admin, then grant least privilege in the UI (or map Keycloak **groups** to NiFi groups for scale).

**Data & durability**
- ✅ RDS: encrypted, private, automated backups, deletion protection; **Multi-AZ** for production.
- ✅ EBS encryption everywhere; size NiFi's disk for its repositories (content/provenance grow!). For serious use, mount separate gp3 volumes for NiFi's `content_repository`, `flowfile_repository`, and `provenance_repository`.
- ✅ JVM heap set explicitly in NiFi's `bootstrap.conf` (≈ half of RAM).

**Automation & operations**
- ✅ Everything is code: Packer (image), Terraform (infra, remote locked state), Ansible (config, realm/client included).
- ✅ Immutable images rebuilt monthly; AMIs scanned and versioned.
- ✅ CloudWatch alarms on target-group health, RDS storage, CPU; ship `nifi-app.log` and `keycloak` journal to CloudWatch Logs.
- ✅ Tag every resource (`Name`, `Env`, `Role`, `Owner`, `CostCenter`) — tags drive the dynamic inventory *and* the AWS bill breakdown.
- ✅ Test restores, not just backups.

---

# 9. Options, pros and cons

Every architecture is a set of choices. Here are the main forks in the road and when to take the other path.

## 9.1 Keycloak vs. Amazon Cognito (vs. paid IdPs)

| | Keycloak (this tutorial) | Amazon Cognito | Okta / Entra ID / Auth0 |
|---|---|---|---|
| Cost | Free software; you pay the EC2/RDS | Free tier, then per-MAU | Per-user subscription |
| Ops burden | **You run it** (patching, upgrades) | Zero — fully managed | Zero |
| Features | Very deep (flows, federation, themes) | Narrower, improving | Deep, enterprise-grade |
| Data control | Total (self-hosted) | In AWS | In vendor cloud |
| Lock-in | None | AWS | Vendor |

**Take Cognito** if you're all-in on AWS and want zero servers. **Take Keycloak** for full control, on-prem parity, rich login flows, or no per-user fees. NiFi's OIDC config is identical either way — only the discovery URL and client change.

## 9.2 Single NiFi instance vs. NiFi cluster

- **Single instance (this tutorial):** simple, cheap, fine for team-scale flows. Risk: one AZ/instance failure = downtime (mitigate with EBS snapshots + fast Terraform rebuild).
- **Cluster (3+ nodes + ZooKeeper/Kubernetes):** horizontal scale and node-failure tolerance, but real added complexity (state management, load-balanced connections, sticky sessions mandatory). Start single; cluster when data volume or uptime requirements force it.

## 9.3 EC2 + AMI (this tutorial) vs. containers (ECS/EKS)

- **EC2 + golden AMI:** conceptually simple, great for stateful heavyweight apps like NiFi, easiest to reason about.
- **ECS Fargate / EKS:** better bin-packing, rolling deploys, and the official `apache/nifi` and `keycloak/keycloak` Docker images; but persistent volumes for NiFi's repositories and clustering add non-trivial complexity. If your org already runs Kubernetes, use it; if not, EC2 is a perfectly modern choice here.

## 9.4 ALB vs. NLB, and TLS depth

- **ALB (chosen):** host/path routing, HTTP redirects, WAF, stickiness — everything a browser app wants.
- **NLB:** Layer-4, ultra-low latency, static IPs, TLS passthrough. Choose it only if you need **end-to-end TLS without termination** (e.g., NiFi client-certificate/mTLS logins, or site-to-site NiFi traffic).
- **TLS depth options:** (a) terminate at ALB, HTTP inside (Keycloak leg — simplest); (b) terminate + **re-encrypt** to targets (NiFi leg — ALB→8443); (c) full passthrough via NLB (strictest, most work). Regulated environments often mandate (b) everywhere: just switch Keycloak to HTTPS on the instance and flip its target group to HTTPS.

## 9.5 NAT Gateway vs. cheaper egress

NAT GW ≈ $32/mo + $0.045/GB. Alternatives: a tiny self-managed **NAT instance** (cheap, but you babysit it), **VPC endpoints** for S3/SSM/Secrets Manager (removes much NAT traffic and is a security win regardless), or — for dev only — putting instances in public subnets with strict SGs (not recommended for prod).

## 9.6 Where users live: Keycloak DB vs. federation

Keycloak can *be* the user database (this tutorial), or **federate** to LDAP/Active Directory (enterprise standard — passwords stay in AD), or **broker** logins from Google/GitHub/another OIDC IdP ("Login with Google" on the Keycloak page). Federation/brokering are pure Keycloak configuration — nothing in NiFi or AWS changes.

## 9.7 Terraform vs. alternatives

- **Terraform/OpenTofu (chosen):** the industry default, huge ecosystem, cloud-agnostic HCL. (OpenTofu is the open-source fork — near drop-in.)
- **CloudFormation / CDK:** AWS-native; CDK lets you write infra in Python/TypeScript. Great if AWS-only and developer-centric.
- **Pulumi:** general-purpose languages + multi-cloud.
The concepts in Part D transfer to all of them.

---

# 10. Troubleshooting guide

The six classic failures, their symptoms, and fixes:

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Keycloak page shows **"Invalid parameter: redirect_uri"** | Redirect URI in the client ≠ what NiFi sent | Client → Valid redirect URIs must be exactly `https://nifi.<domain>/nifi-api/access/oidc/callback` |
| 2 | NiFi returns **"System Error… invalid host header"** or blank page via the ALB | `nifi.web.proxy.host` missing/wrong | Set `nifi.web.proxy.host=nifi.<domain>` (add `:443` variant too if needed), restart NiFi |
| 3 | Login loops forever between NiFi and Keycloak, or "Issuer mismatch" in `nifi-user.log` | Keycloak `hostname`/proxy headers wrong → issuer in token ≠ discovery URL | In `keycloak.conf`: `hostname=https://auth.<domain>`, `proxy-headers=xforwarded`, `http-enabled=true`; restart |
| 4 | You log in successfully but NiFi says **"Unable to view the user interface… Untrusted proxy / No applicable policies"** | AuthN worked, AuthZ didn't: identity ≠ Initial Admin Identity | Check `nifi-user.log` for the exact identity string NiFi saw; make `Initial Admin Identity` match it character-for-character; delete `conf/users.xml` + `conf/authorizations.xml`; restart |
| 5 | NiFi log: **cannot reach discovery URL / connection timed out** | NiFi instance can't reach Keycloak (SG or DNS) | Keycloak SG must allow 8080 from NiFi SG **and** the discovery URL goes via the ALB (443 from NiFi outbound is fine through NAT/ALB); test with `curl -v https://auth.<domain>/realms/nifi-realm/.well-known/openid-configuration` from the NiFi box |
| 6 | ALB target shows **unhealthy** | Health check path/protocol mismatch, service not up, or SG blocks ALB→instance | `sudo systemctl status nifi keycloak`; confirm TG protocol (NiFi=HTTPS:8443, KC=HTTP:8080) and that the instance SG allows that port *from the ALB SG* |

Handy diagnostic commands:

```bash
# Target health at a glance
aws elbv2 describe-target-health --target-group-arn $NIFI_TG
aws elbv2 describe-target-health --target-group-arn $KC_TG

# What identity did NiFi extract from the token? (on the NiFi box)
sudo grep -i "identity\|oidc" /opt/nifi/logs/nifi-user.log | tail -20

# Is DNS resolving to the ALB?
dig +short nifi.example.com

# Is the cert valid and covering both names?
openssl s_client -connect nifi.example.com:443 -servername nifi.example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -dates
```

---

# Wrap-up

You now have, end to end:

1. **A mental model** — NiFi does data flows, Keycloak does identity, OIDC is the handshake, AWS provides the fenced network, the front door (ALB + ACM + Route 53), and the muscle (EC2 + RDS).
2. **A manual build** (Part A) — every AWS CLI command with its reasoning.
3. **The deep "why"** (Part B) — each service, its concepts, and its best practices.
4. **Full automation** — Packer golden AMI (Part C) → Terraform infrastructure (Part D) → Ansible configuration including the Keycloak realm and client as code (Part E).
5. **Judgment tools** — best-practice checklist, the major architecture trade-offs, and a troubleshooting table for the six failures everyone hits.

Natural next steps: map Keycloak **groups** into NiFi policies, add **MFA/passkeys** in Keycloak, add **AWS WAF** and ALB access logs, move to **Multi-AZ RDS**, and wire the Packer→Terraform→Ansible chain into a CI/CD pipeline (GitHub Actions or CodePipeline) so a `git push` ships the whole stack.

*Version note: commands and file paths target NiFi 2.10.0 and Keycloak 26.6.x (current as of July 2026). Both projects only support their latest release — check nifi.apache.org/download and keycloak.org/downloads and substitute the newest version numbers when you build.*
