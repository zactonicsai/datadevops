# Keycloak on AWS with RDS — Build & Support Reference

**Document type:** Architecture + runbook template
**Target platform:** AWS (single region, multi-AZ)
**Keycloak version:** 26.7.x (latest stable as of July 2026)
**Database:** Amazon RDS for PostgreSQL 17.x
**Last reviewed:** 2026-07-27
**Owner:** `<TEAM_NAME>` · **On-call rota:** `<PAGER_LINK>`

---

## 0. How to use this document

This is written to do two jobs at once:

1. **Rebuild** — someone with AWS access but no prior knowledge of this system can follow Part 2 top to bottom and end up with a working Keycloak.
2. **Support** — someone woken at 3 a.m. can jump to Part 8 (monitoring), Part 9 (runbooks), or Part 10 (troubleshooting) and fix things without reading anything else.

Everything is explained from first principles, so read Part 1 if the words "identity provider" or "VPC" are new to you. If they're not, skip to Part 2.

### Fill these in before you start

Every command and config in this doc uses these placeholders. Write your real values here once, and the rest of the document becomes *your* document.

| Placeholder | Meaning | Your value |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | 12-digit AWS account number | |
| `<REGION>` | AWS region, e.g. `eu-west-1` | |
| `<ENV>` | `dev`, `stage`, or `prod` | |
| `<DOMAIN>` | Public domain, e.g. `auth.example.com` | |
| `<VPC_CIDR>` | Private IP range, e.g. `10.40.0.0/16` | |
| `<KC_VERSION>` | Keycloak image tag, e.g. `26.7.0` | |
| `<DB_NAME>` | Database name, e.g. `keycloak` | |
| `<PROJECT>` | Name prefix for all resources, e.g. `kc` | |

**Naming convention used throughout:** `<PROJECT>-<ENV>-<resource>`, e.g. `kc-prod-alb`, `kc-prod-rds`, `kc-prod-ecs-svc`. Stick to it. Half of supporting a system is being able to guess the name of the thing you're looking for.

---

# PART 1 — Background: what all of this actually is

## 1.1 What is Keycloak?

Imagine a school where every classroom has its own lock and its own key. Students end up carrying twenty keys, and when a student leaves, someone has to go around collecting all twenty. Now imagine instead a single front desk: you show your ID once, the desk gives you a badge, and every classroom door reads the badge. One place to issue badges, one place to revoke them.

Keycloak is that front desk for software. It is an **identity and access management (IAM) server** — an open-source project, originally from Red Hat, that handles:

- **Authentication** — proving *who you are* (password, one-time code, passkey, corporate login).
- **Authorization** — deciding *what you're allowed to do* (roles, groups, permissions).
- **Single sign-on (SSO)** — log in once, access many applications.
- **Federation** — letting people log in with Google, Microsoft Entra ID, an LDAP directory, or a partner's identity system.
- **Standard protocols** — OpenID Connect (OIDC), OAuth 2.0, and SAML 2.0, so almost any application can integrate without custom code.

Your applications never see or store passwords. They just redirect the user to Keycloak, and Keycloak hands back a signed **token** (a small, tamper-evident JSON document) saying "this is Alice, she's in the `finance` group, this token expires in 5 minutes."

### Vocabulary you'll see constantly

| Term | Plain-English meaning |
|---|---|
| **Realm** | An isolated tenant inside Keycloak. Its own users, its own login page, its own signing keys. `master` is the built-in admin realm — **never put real users in it.** |
| **Client** | An application that trusts Keycloak. Your web app, your mobile app, your API. |
| **Client scope / mapper** | Rules for what extra information gets put into the token. |
| **User federation** | Reading users from an external directory (LDAP/Active Directory) instead of storing them in Keycloak. |
| **Identity provider (IdP)** | An *external* login source Keycloak delegates to (Google, Okta, a partner's SAML server). |
| **Session** | The record that "Alice is currently logged in." |
| **Token** | The signed badge handed to applications. Access token (short-lived), refresh token (longer), ID token (identity info). |
| **Bootstrap admin** | A temporary first admin account used only to create the real admin accounts. |

## 1.2 Why does Keycloak need a database?

Keycloak is **stateless-ish by design**: the containers themselves store almost nothing permanent. Everything durable lives in the database — realms, users, credentials, clients, roles, groups, signing keys, and (from Keycloak 25 onward) user sessions.

This is the single most important architectural fact in this document, and it has two consequences:

- **You can kill and replace Keycloak containers freely.** Nothing is lost. That's what makes autoscaling and rolling deploys safe.
- **The database is the single point of truth and the single point of failure.** If RDS is down, Keycloak is down. Every design decision in Part 5 about backups, Multi-AZ, and connection pooling flows from this.

## 1.3 What is Amazon RDS?

Running a database yourself means installing PostgreSQL on a server, patching it, configuring replication, writing backup scripts, testing restores, and monitoring disk space at 2 a.m. **Amazon RDS (Relational Database Service)** is AWS doing that for you: you choose an engine and a size, and AWS handles the operating system, patching, automated backups, point-in-time recovery, failover to a standby, and monitoring.

You give up some control — no `sudo` on the database host, no arbitrary extensions, no custom `postgresql.conf` (you use *parameter groups* instead) — in exchange for not having a full-time DBA.

**We use PostgreSQL** because it is the best-tested database for Keycloak, is what upstream CI runs against, and is what almost every production Keycloak deployment uses. Keycloak 26.4+ requires **PostgreSQL 13 or newer**; we target 17.x.

## 1.4 The AWS building blocks in one paragraph each

| Service | What it is, in plain terms |
|---|---|
| **VPC** | Your own private network inside AWS. Nothing gets in or out except through doors you explicitly open. |
| **Subnet** | A slice of that network pinned to one Availability Zone. *Public* subnets can reach the internet directly; *private* subnets cannot. |
| **Availability Zone (AZ)** | A physically separate data centre in the region. Spreading across AZs is how you survive one building's failure. |
| **Internet Gateway / NAT Gateway** | The front door (inbound+outbound for public subnets) and the one-way service exit (outbound only, for private subnets). |
| **Security Group** | A stateful firewall attached to a resource. Default: deny everything. You allow specific ports from specific sources. |
| **ALB (Application Load Balancer)** | The public receptionist. Terminates HTTPS, checks health, and spreads traffic across your Keycloak containers. |
| **ECS + Fargate** | Runs your containers. ECS is the scheduler ("keep 3 copies running"); Fargate means AWS supplies the servers so you never patch an EC2 instance. |
| **ECR** | Your private Docker image registry. |
| **RDS** | The managed PostgreSQL database described above. |
| **Secrets Manager** | Encrypted storage for passwords, with rotation and audit logging. Containers fetch secrets at start-up; passwords never appear in config files or Terraform state. |
| **ACM** | Free, auto-renewing TLS certificates for the load balancer. |
| **Route 53** | DNS. Maps `auth.example.com` to the load balancer. |
| **KMS** | The key manager. Encrypts RDS storage, secrets, logs, and backups. |
| **CloudWatch** | Logs, metrics, dashboards, and alarms. |
| **WAF** | A web firewall in front of the ALB — rate limiting and bad-request blocking. |
| **IAM** | Who/what is allowed to call which AWS API. |

## 1.5 The reference architecture

```
                            Internet
                                │
                         ┌──────▼───────┐
                         │  Route 53    │  auth.example.com  (ALIAS → ALB)
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │   AWS WAF    │  rate limit + managed rule sets
                         └──────┬───────┘
┌───────────────────────────────┼──────────────────────────────────────────┐
│ VPC 10.40.0.0/16              │                                          │
│                        ┌──────▼───────┐                                  │
│  PUBLIC SUBNETS        │     ALB      │  :443 HTTPS (ACM cert)           │
│  10.40.0.0/24  (AZ-a)  │ internet-    │  :80  → 301 redirect to :443     │
│  10.40.1.0/24  (AZ-b)  │ facing       │                                  │
│                        └──────┬───────┘                                  │
│                               │ HTTP :8080  (inside VPC only)            │
│         ┌─────────────────────┼─────────────────────┐                    │
│         │                     │                     │                    │
│  ┌──────▼──────┐       ┌──────▼──────┐       ┌──────▼──────┐             │
│  │ Keycloak    │◄─────►│ Keycloak    │◄─────►│ Keycloak    │  :7800      │
│  │ task (AZ-a) │ ispn  │ task (AZ-b) │ ispn  │ task (AZ-c) │  Infinispan │
│  └──────┬──────┘       └──────┬──────┘       └──────┬──────┘             │
│  PRIVATE APP SUBNETS  10.40.10.0/24, .11.0/24, .12.0/24                  │
│         │                     │                     │                    │
│         └─────────────────────┼─────────────────────┘                    │
│                               │ TCP :5432                                │
│                        ┌──────▼───────┐                                  │
│  PRIVATE DATA SUBNETS  │  RDS         │  Primary (AZ-a)                  │
│  10.40.20.0/24 …       │  PostgreSQL  │  ── sync replication ──►         │
│                        │  Multi-AZ    │  Standby (AZ-b)                  │
│                        └──────────────┘                                  │
│                                                                          │
│  VPC Endpoints: ECR-api, ECR-dkr, S3(gw), Logs, Secrets Manager, KMS     │
│  NAT Gateway (one per AZ) in public subnets for outbound egress          │
└──────────────────────────────────────────────────────────────────────────┘
        │                    │                     │
   Secrets Manager       CloudWatch              ECR
   (DB + admin creds)    (logs/metrics)     (Keycloak image)
```

### Reading the diagram: the request path

1. A user visits `https://auth.example.com`. Route 53 resolves it to the ALB.
2. WAF inspects the request and drops abusive traffic.
3. The ALB terminates TLS (decrypts the HTTPS) and forwards plain HTTP on port 8080 to a healthy Keycloak task inside the private network.
4. Keycloak checks its in-memory cache, then reads or writes RDS on port 5432.
5. Keycloak returns the login page or token. The ALB re-encrypts it back to the user.

Two things to note now, because they cause most of the misconfiguration bugs later:

- **TLS stops at the ALB.** Keycloak receives plain HTTP and must be *told* the original request was HTTPS, or every URL it generates will start with `http://` and logins will break. That's what `KC_PROXY_HEADERS=xforwarded` does.
- **The tasks talk to each other on port 7800.** That's Infinispan, Keycloak's distributed cache. They find each other by writing their addresses into a table in RDS (`JGROUPSPING`) — this is the `jdbc-ping` discovery mechanism, and it is the default from Keycloak 26 onward.

---

# PART 2 — Step-by-step: build one working environment

This part builds a complete, production-shaped `prod` environment from an empty AWS account. Follow it in order; each step depends on the previous one. **Expect 60–90 minutes**, most of which is waiting for RDS and certificate validation.

Everything here uses the AWS CLI so it's copy-pasteable and reviewable. Part 11 has the Terraform equivalent — **for anything beyond a throwaway sandbox, use Terraform, not these commands.** The CLI version exists so you can see exactly what is being created and why.

## Prerequisites

- AWS CLI v2 configured with admin-ish permissions: `aws sts get-caller-identity`
- Docker installed (to build/push the image)
- A registered domain with its DNS in Route 53, or the ability to add a CNAME record
- `jq` and `psql` installed locally (helpful, not required)

Set your shell variables — every command below uses them:

```bash
export AWS_REGION=<REGION>
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT=kc
export ENV=prod
export PREFIX="${PROJECT}-${ENV}"
export DOMAIN=<DOMAIN>
export KC_VERSION=26.7.0
export DB_NAME=keycloak
```

---

## Step 1 — Network foundation (VPC, subnets, gateways)

**Why:** Keycloak holds every credential in your organisation. It must not sit on a network reachable from the internet. We build three tiers: public (load balancer only), private-app (containers), private-data (database).

```bash
# 1.1 Create the VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.40.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc}]" \
  --query 'Vpc.VpcId' --output text)

# DNS support is REQUIRED — RDS endpoints and VPC endpoints resolve via DNS
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# 1.2 Nine subnets: 3 tiers × 3 AZs
AZS=($(aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[0:3].ZoneName' --output text))

create_subnet () {  # $1=cidr  $2=az  $3=name
  aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $1 --availability-zone $2 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$3}]" \
    --query 'Subnet.SubnetId' --output text
}

PUB_A=$(create_subnet  10.40.0.0/24  ${AZS[0]} ${PREFIX}-public-a)
PUB_B=$(create_subnet  10.40.1.0/24  ${AZS[1]} ${PREFIX}-public-b)
PUB_C=$(create_subnet  10.40.2.0/24  ${AZS[2]} ${PREFIX}-public-c)
APP_A=$(create_subnet  10.40.10.0/24 ${AZS[0]} ${PREFIX}-app-a)
APP_B=$(create_subnet  10.40.11.0/24 ${AZS[1]} ${PREFIX}-app-b)
APP_C=$(create_subnet  10.40.12.0/24 ${AZS[2]} ${PREFIX}-app-c)
DAT_A=$(create_subnet  10.40.20.0/24 ${AZS[0]} ${PREFIX}-data-a)
DAT_B=$(create_subnet  10.40.21.0/24 ${AZS[1]} ${PREFIX}-data-b)
DAT_C=$(create_subnet  10.40.22.0/24 ${AZS[2]} ${PREFIX}-data-c)

# 1.3 Internet gateway, attached to the VPC
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# 1.4 Public route table → IGW
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-rt-public}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
for S in $PUB_A $PUB_B $PUB_C; do
  aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $S
  aws ec2 modify-subnet-attribute --subnet-id $S --map-public-ip-on-launch
done

# 1.5 One NAT gateway per AZ (see the note below on cost)
for i in 0 1 2; do
  PUB=(${PUB_A} ${PUB_B} ${PUB_C}); APP=(${APP_A} ${APP_B} ${APP_C})
  EIP=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
  NAT=$(aws ec2 create-nat-gateway --subnet-id ${PUB[$i]} --allocation-id $EIP \
        --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT
  RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
       --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id $RT \
    --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT
  aws ec2 associate-route-table --route-table-id $RT --subnet-id ${APP[$i]}
done
```

> **Cost warning:** three NAT gateways cost roughly **$100/month** before data charges. In `dev`, use one NAT gateway shared by all AZs (cheaper, but an AZ failure takes out egress). Data subnets get **no** route to a NAT gateway at all — RDS does not need internet access.

**Best practice — VPC endpoints.** Add interface endpoints so container image pulls, log writes, and secret fetches never leave the AWS network. This improves security *and* cuts NAT data-processing charges, often paying for itself.

```bash
for SVC in ecr.api ecr.dkr logs secretsmanager kms; do
  aws ec2 create-vpc-endpoint --vpc-id $VPC_ID \
    --service-name com.amazonaws.${AWS_REGION}.${SVC} \
    --vpc-endpoint-type Interface \
    --subnet-ids $APP_A $APP_B $APP_C \
    --security-group-ids $SG_VPCE   # created in Step 2
done
# S3 is a free gateway endpoint — ECR stores image layers in S3, so this one matters
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --vpc-endpoint-type Gateway --route-table-ids $RT_PUB
```

---

## Step 2 — Security groups (the firewall rules)

**Why:** Security groups are the layer that makes the diagram real. The rule to internalise: **each tier only accepts traffic from the tier directly above it**, and you reference other security groups by ID rather than by IP range, so the rules stay correct as IPs change.

```bash
mk_sg () { aws ec2 create-security-group --vpc-id $VPC_ID \
  --group-name "$1" --description "$2" --query GroupId --output text; }

SG_ALB=$(mk_sg   ${PREFIX}-sg-alb  "Public HTTPS to ALB")
SG_TASK=$(mk_sg  ${PREFIX}-sg-task "Keycloak Fargate tasks")
SG_DB=$(mk_sg    ${PREFIX}-sg-db   "RDS PostgreSQL")
SG_VPCE=$(mk_sg  ${PREFIX}-sg-vpce "VPC interface endpoints")

# ALB: open to the world on 443 and 80 (80 only to redirect)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ALB \
  --protocol tcp --port 80  --cidr 0.0.0.0/0

# Tasks: HTTP from the ALB only
aws ec2 authorize-security-group-ingress --group-id $SG_TASK \
  --protocol tcp --port 8080 --source-group $SG_ALB
# Tasks: management/health port from the ALB only
aws ec2 authorize-security-group-ingress --group-id $SG_TASK \
  --protocol tcp --port 9000 --source-group $SG_ALB
# Tasks: Infinispan cluster traffic from other tasks (self-referencing rule)
aws ec2 authorize-security-group-ingress --group-id $SG_TASK \
  --protocol tcp --port 7800-7801 --source-group $SG_TASK

# RDS: PostgreSQL from the tasks only. Nothing else. Ever.
aws ec2 authorize-security-group-ingress --group-id $SG_DB \
  --protocol tcp --port 5432 --source-group $SG_TASK

# VPC endpoints: HTTPS from the tasks
aws ec2 authorize-security-group-ingress --group-id $SG_VPCE \
  --protocol tcp --port 443 --source-group $SG_TASK
```

### Port reference — pin this to the wall

| Port | Protocol | Purpose | Source | Destination |
|---|---|---|---|---|
| 443 | HTTPS | Public traffic | `0.0.0.0/0` | ALB |
| 80 | HTTP | Redirect to 443 only | `0.0.0.0/0` | ALB |
| 8080 | HTTP | Keycloak application | `sg-alb` | tasks |
| 9000 | HTTP | Health + metrics (management interface) | `sg-alb` | tasks |
| 7800–7801 | TCP | Infinispan / JGroups cluster | `sg-task` (self) | tasks |
| 5432 | TCP | PostgreSQL | `sg-task` | RDS |

> **Common mistake:** forgetting the self-referencing rule on 7800. The cluster will *appear* to work — each task runs fine alone — but caches never sync, so a user logs in on task A and appears logged out on task B. Symptom: intermittent "invalid session" or repeated login prompts.

---

## Step 3 — RDS for PostgreSQL

**Why now:** RDS takes 10–20 minutes to provision (longer for Multi-AZ), so start it before you need it.

```bash
# 3.1 Subnet group — tells RDS which subnets it may live in
aws rds create-db-subnet-group \
  --db-subnet-group-name ${PREFIX}-db-subnets \
  --db-subnet-group-description "Keycloak data tier" \
  --subnet-ids $DAT_A $DAT_B $DAT_C

# 3.2 Parameter group — PostgreSQL settings we want to override
aws rds create-db-parameter-group \
  --db-parameter-group-name ${PREFIX}-pg17 \
  --db-parameter-group-family postgres17 \
  --description "Keycloak tuning"

aws rds modify-db-parameter-group \
  --db-parameter-group-name ${PREFIX}-pg17 \
  --parameters \
    "ParameterName=rds.force_ssl,ParameterValue=1,ApplyMethod=pending-reboot" \
    "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate" \
    "ParameterName=log_connections,ParameterValue=1,ApplyMethod=immediate" \
    "ParameterName=log_disconnections,ParameterValue=1,ApplyMethod=immediate"

# 3.3 The instance itself.
#     --manage-master-user-password lets RDS create AND rotate the password
#     in Secrets Manager. You never see or handle it.
aws rds create-db-instance \
  --db-instance-identifier ${PREFIX}-rds \
  --db-name $DB_NAME \
  --engine postgres \
  --engine-version 17.4 \
  --db-instance-class db.m6g.large \
  --allocated-storage 100 \
  --max-allocated-storage 500 \
  --storage-type gp3 \
  --storage-encrypted \
  --master-username kcadmin \
  --manage-master-user-password \
  --multi-az \
  --db-subnet-group-name ${PREFIX}-db-subnets \
  --vpc-security-group-ids $SG_DB \
  --db-parameter-group-name ${PREFIX}-pg17 \
  --backup-retention-period 30 \
  --preferred-backup-window 02:00-03:00 \
  --preferred-maintenance-window sun:03:30-sun:04:30 \
  --auto-minor-version-upgrade \
  --deletion-protection \
  --enable-performance-insights \
  --performance-insights-retention-period 7 \
  --monitoring-interval 60 \
  --monitoring-role-arn arn:aws:iam::${ACCOUNT_ID}:role/rds-monitoring-role \
  --enable-cloudwatch-logs-exports '["postgresql","upgrade"]' \
  --copy-tags-to-snapshot

aws rds wait db-instance-available --db-instance-identifier ${PREFIX}-rds

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier ${PREFIX}-rds \
  --query 'DBInstances[0].Endpoint.Address' --output text)

DB_SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier ${PREFIX}-rds \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

echo "DB endpoint: $DB_ENDPOINT"
echo "DB secret:   $DB_SECRET_ARN"
```

### Why each of those flags

| Flag | Reason |
|---|---|
| `--multi-az` | AWS keeps a synchronous standby in another AZ and fails over automatically in 60–120s. **Non-negotiable in prod** — if Keycloak's DB is down, every login in your organisation fails. |
| `--storage-encrypted` | Encryption at rest via KMS. Cannot be enabled later without a snapshot-restore; enable it on day one. |
| `--manage-master-user-password` | RDS owns the password in Secrets Manager and rotates it. Removes the worst class of credential leak (passwords in Terraform state or CI logs). |
| `rds.force_ssl=1` | Rejects any unencrypted connection. Combined with `verify-full` on the client, this stops in-VPC eavesdropping. |
| `--backup-retention-period 30` | Enables automated backups and point-in-time recovery to any second in the last 30 days. Setting this to `0` disables PITR entirely. |
| `--deletion-protection` | Someone will eventually run `terraform destroy` against the wrong workspace. |
| `--max-allocated-storage` | Storage autoscaling. Running out of disk is one of the few ways to hard-fail an RDS instance. |
| `--enable-performance-insights` | When logins get slow, this is how you find the slow query in minutes rather than hours. |
| `db.m6g.large` | Graviton (ARM) — roughly 20% cheaper than equivalent Intel classes at similar performance. |

---

## Step 4 — Secrets

RDS already created the database password secret. You need one more: the **bootstrap admin** credentials for the very first login.

```bash
ADMIN_PW=$(aws secretsmanager get-random-password \
  --require-each-included-type --password-length 32 \
  --exclude-characters '"@/\' --query RandomPassword --output text)

ADMIN_SECRET_ARN=$(aws secretsmanager create-secret \
  --name ${PREFIX}/keycloak/bootstrap-admin \
  --description "Temporary Keycloak bootstrap admin - delete after real admins exist" \
  --secret-string "{\"username\":\"bootstrap-admin\",\"password\":\"${ADMIN_PW}\"}" \
  --query ARN --output text)
```

> **Security note:** In Keycloak 26 the variables are `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD`. The old `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` names are deprecated. These credentials are only consulted when the `master` realm is first created; they are ignored on every later start. Create your real named admin accounts, then delete this account and this secret (Step 9).

---

## Step 5 — TLS certificate and DNS

```bash
CERT_ARN=$(aws acm request-certificate \
  --domain-name $DOMAIN \
  --validation-method DNS \
  --key-algorithm RSA_2048 \
  --query CertificateArn --output text)

# Read the CNAME record ACM wants, then create it in Route 53
aws acm describe-certificate --certificate-arn $CERT_ARN \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'

# ...create that CNAME in your hosted zone, then:
aws acm wait certificate-validated --certificate-arn $CERT_ARN
```

**Best practice:** use DNS validation, not email validation. DNS-validated certificates renew themselves forever with no human involvement; email validation eventually expires at the worst possible moment because the listed contact left the company.

---

## Step 6 — Container image

You *can* run `quay.io/keycloak/keycloak:26.7.0` unmodified. You *should* build your own image on top of it, for three reasons:

1. **Faster, more predictable starts.** Running `kc.sh build` at image-build time and starting with `--optimized` skips a 20–40 second augmentation step on every single container start.
2. **Custom themes and providers** (your login page branding, custom authenticators) have to be baked in.
3. **You control the base image and can scan it.** Pulling directly from a public registry at deploy time makes your deployment depend on someone else's uptime.

Create `Dockerfile`:

```dockerfile
# ---- build stage: bake in build-time options ----
FROM quay.io/keycloak/keycloak:26.7.0 AS builder

# Build-time options must be fixed here so we can start with --optimized.
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn
ENV KC_CACHE_STACK=jdbc-ping

# Optional: custom theme / SPI providers
# COPY themes/acme-theme.jar /opt/keycloak/providers/

RUN /opt/keycloak/bin/kc.sh build

# ---- runtime stage ----
FROM quay.io/keycloak/keycloak:26.7.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# RDS TLS chain, so the JDBC driver can verify the server certificate
ADD --chown=keycloak:root \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  /opt/keycloak/conf/rds-ca.pem

WORKDIR /opt/keycloak
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]
```

Build and push:

```bash
aws ecr create-repository --repository-name ${PROJECT}/keycloak \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE \
  --encryption-configuration encryptionType=KMS

REPO=${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${PROJECT}/keycloak
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO%%/*}
docker build -t ${REPO}:${KC_VERSION}-1 .
docker push ${REPO}:${KC_VERSION}-1
```

> **Best practice:** immutable tags (`26.7.0-1`, `26.7.0-2`) rather than `latest`. When you're debugging an incident at 3 a.m., you must be able to answer "which exact image is running?" with certainty.

---

## Step 7 — Load balancer

```bash
ALB_ARN=$(aws elbv2 create-load-balancer --name ${PREFIX}-alb \
  --type application --scheme internet-facing \
  --subnets $PUB_A $PUB_B $PUB_C --security-groups $SG_ALB \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Target group. NOTE the health check port: 9000, not 8080.
TG_ARN=$(aws elbv2 create-target-group --name ${PREFIX}-tg \
  --protocol HTTP --port 8080 --vpc-id $VPC_ID --target-type ip \
  --health-check-protocol HTTP \
  --health-check-port 9000 \
  --health-check-path /health/ready \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Sticky sessions are a safety net, not the primary mechanism —
# Infinispan replication is. But they reduce cross-node chatter.
aws elbv2 modify-target-group-attributes --target-group-arn $TG_ARN \
  --attributes \
    Key=deregistration_delay.timeout_seconds,Value=60 \
    Key=stickiness.enabled,Value=true \
    Key=stickiness.type,Value=lb_cookie \
    Key=stickiness.lb_cookie.duration_seconds,Value=3600

# HTTPS listener with a modern TLS policy
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# HTTP listener that only redirects
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions '[{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}]'

# Access logs to S3 — required for most audit regimes
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $ALB_ARN \
  --attributes \
    Key=access_logs.s3.enabled,Value=true \
    Key=access_logs.s3.bucket,Value=${PREFIX}-alb-logs \
    Key=routing.http.drop_invalid_header_fields.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=60
```

> **The single most important line in this step** is `--health-check-port 9000`. Since Keycloak 25, health and metrics endpoints live on a separate **management interface** on port 9000, not on 8080. Pointing the health check at `8080/health/ready` returns 404, every target is marked unhealthy, and the service never stabilises. This is the most common Keycloak-on-ECS failure.

Now point DNS at it:

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_ZONE=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
# Create a Route 53 ALIAS A-record for $DOMAIN → $ALB_DNS / $ALB_ZONE
```

Use an **ALIAS** record, not a CNAME: it's free to query, works at the zone apex, and follows the ALB if its IPs change.

---

## Step 8 — ECS cluster, task definition, and service

### 8.1 IAM roles

Two distinct roles, and mixing them up is a classic mistake:

- **Execution role** — used by the *ECS agent*, before your container starts, to pull the image and fetch secrets.
- **Task role** — used by *your application code* at runtime to call AWS APIs.

```bash
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam create-role --role-name ${PREFIX}-ecs-exec --assume-role-policy-document "$TRUST"
aws iam attach-role-policy --role-name ${PREFIX}-ecs-exec \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Least-privilege secret access: exactly these two secrets, nothing else
aws iam put-role-policy --role-name ${PREFIX}-ecs-exec \
  --policy-name read-keycloak-secrets --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],
  "Resource":["${DB_SECRET_ARN}","${ADMIN_SECRET_ARN}"]},
 {"Effect":"Allow","Action":["kms:Decrypt"],
  "Resource":"arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/*",
  "Condition":{"StringEquals":{"kms:ViaService":"secretsmanager.${AWS_REGION}.amazonaws.com"}}}
]}
JSON
)"

aws iam create-role --role-name ${PREFIX}-ecs-task --assume-role-policy-document "$TRUST"
# Task role needs almost nothing. Add SES/S3 permissions only if you use them.
```

### 8.2 Log group and cluster

```bash
aws logs create-log-group --log-group-name /ecs/${PREFIX}-keycloak
aws logs put-retention-policy --log-group-name /ecs/${PREFIX}-keycloak --retention-in-days 90

aws ecs create-cluster --cluster-name ${PREFIX}-cluster \
  --settings name=containerInsights,value=enhanced \
  --capacity-providers FARGATE FARGATE_SPOT
```

### 8.3 Task definition

This is the heart of the deployment. Save as `taskdef.json` (substitute your values):

```json
{
  "family": "kc-prod-keycloak",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "4096",
  "runtimePlatform": { "cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX" },
  "executionRoleArn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/kc-prod-ecs-exec",
  "taskRoleArn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/kc-prod-ecs-task",
  "containerDefinitions": [
    {
      "name": "keycloak",
      "image": "<AWS_ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/kc/keycloak:26.7.0-1",
      "essential": true,
      "command": ["start", "--optimized"],
      "portMappings": [
        { "containerPort": 8080, "protocol": "tcp", "name": "http" },
        { "containerPort": 9000, "protocol": "tcp", "name": "management" },
        { "containerPort": 7800, "protocol": "tcp", "name": "jgroups" }
      ],
      "environment": [
        { "name": "KC_DB",            "value": "postgres" },
        { "name": "KC_DB_URL",        "value": "jdbc:postgresql://<DB_ENDPOINT>:5432/keycloak?ssl=true&sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem" },
        { "name": "KC_DB_POOL_INITIAL_SIZE", "value": "5" },
        { "name": "KC_DB_POOL_MIN_SIZE",     "value": "5" },
        { "name": "KC_DB_POOL_MAX_SIZE",     "value": "20" },

        { "name": "KC_HOSTNAME",        "value": "https://auth.example.com" },
        { "name": "KC_HOSTNAME_STRICT", "value": "true" },
        { "name": "KC_HTTP_ENABLED",    "value": "true" },
        { "name": "KC_PROXY_HEADERS",   "value": "xforwarded" },

        { "name": "KC_CACHE",       "value": "ispn" },
        { "name": "KC_CACHE_STACK", "value": "jdbc-ping" },

        { "name": "KC_HEALTH_ENABLED",  "value": "true" },
        { "name": "KC_METRICS_ENABLED", "value": "true" },
        { "name": "KC_LOG",             "value": "console" },
        { "name": "KC_LOG_CONSOLE_OUTPUT", "value": "json" },
        { "name": "KC_LOG_LEVEL",       "value": "info" },

        { "name": "JAVA_OPTS_APPEND",
          "value": "-XX:MaxRAMPercentage=70 -Djava.net.preferIPv4Stack=true" }
      ],
      "secrets": [
        { "name": "KC_DB_USERNAME",
          "valueFrom": "<DB_SECRET_ARN>:username::" },
        { "name": "KC_DB_PASSWORD",
          "valueFrom": "<DB_SECRET_ARN>:password::" },
        { "name": "KC_BOOTSTRAP_ADMIN_USERNAME",
          "valueFrom": "<ADMIN_SECRET_ARN>:username::" },
        { "name": "KC_BOOTSTRAP_ADMIN_PASSWORD",
          "valueFrom": "<ADMIN_SECRET_ARN>:password::" }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL",
          "exec 3<>/dev/tcp/127.0.0.1/9000 && echo -e 'GET /health/ready HTTP/1.1\\r\\nHost: localhost\\r\\nConnection: close\\r\\n\\r\\n' >&3 && cat <&3 | grep -q '\"status\": \"UP\"'"],
        "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 90
      },
      "ulimits": [{ "name": "nofile", "softLimit": 65536, "hardLimit": 65536 }],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/kc-prod-keycloak",
          "awslogs-region": "<REGION>",
          "awslogs-stream-prefix": "keycloak"
        }
      }
    }
  ]
}
```

```bash
aws ecs register-task-definition --cli-input-json file://taskdef.json
```

> **Note on the container health check:** the Keycloak image is distroless-ish and ships with no `curl` or `wget`. The bash `/dev/tcp` trick above is the standard workaround. Alternatively, add `curl` in your Dockerfile's build stage.

### 8.4 The service

```bash
aws ecs create-service \
  --cluster ${PREFIX}-cluster \
  --service-name ${PREFIX}-keycloak \
  --task-definition kc-prod-keycloak \
  --desired-count 3 \
  --launch-type FARGATE \
  --platform-version LATEST \
  --network-configuration "awsvpcConfiguration={subnets=[$APP_A,$APP_B,$APP_C],securityGroups=[$SG_TASK],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=keycloak,containerPort=8080" \
  --health-check-grace-period-seconds 180 \
  --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}" \
  --enable-execute-command \
  --propagate-tags SERVICE
```

Key choices:

- **`desired-count 3`** — one per AZ. Two is the minimum for HA; three means you survive one AZ failure *and* one rolling deploy at the same time.
- **`health-check-grace-period-seconds 180`** — Keycloak runs database migrations on first start. Without a grace period, the ALB kills the task before it finishes and you get a crash loop.
- **`deploymentCircuitBreaker` with rollback** — a bad image automatically reverts instead of taking down logins.
- **`assignPublicIp=DISABLED`** — this is only possible because you created VPC endpoints and NAT gateways in Step 1.

### 8.5 Autoscaling

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/${PREFIX}-cluster/${PREFIX}-keycloak \
  --min-capacity 3 --max-capacity 12

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/${PREFIX}-cluster/${PREFIX}-keycloak \
  --policy-name cpu-target-60 --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 60.0,
    "PredefinedMetricSpecification": {"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},
    "ScaleInCooldown": 300, "ScaleOutCooldown": 60 }'
```

> **Scale-in caution:** Keycloak's distributed cache keeps two copies of each session by default. Removing many nodes at once can lose sessions (users get logged out). The 300-second scale-in cooldown gives the cluster time to rebalance. Never scale in more than one task at a time in prod.

---

## Step 9 — First login and hardening

```bash
# Watch it come up
aws ecs describe-services --cluster ${PREFIX}-cluster --services ${PREFIX}-keycloak \
  --query 'services[0].{running:runningCount,desired:desiredCount,status:status}'

aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].TargetHealth.State'

curl -sf https://$DOMAIN/health/ready   # via management port config, or check internally
```

Then, in order:

1. Open `https://<DOMAIN>/admin` and log in with the bootstrap admin from Step 4.
2. **Create a new realm** for your applications (e.g. `acme`). Never use `master` for real users.
3. In `master`, create **named admin accounts** for each human administrator, with strong passwords and OTP required.
4. **Delete the bootstrap admin user** and then delete the Secrets Manager secret.
5. In the new realm, set the **Login** tab options: require SSL = `all requests`, brute-force detection = ON, "forgot password" = as required by policy.
6. Configure **SMTP** (Amazon SES) on the realm so password resets and email verification work.
7. Enable **Events** → save login events and admin events, with an expiry that matches your audit policy.
8. Create your first **client** and confirm an application can complete a login.

### Verification checklist

- [ ] `https://<DOMAIN>` serves the Keycloak welcome page over a valid certificate
- [ ] All 3 targets show `healthy` in the target group
- [ ] `http://<DOMAIN>` redirects to HTTPS with a 301
- [ ] Logging in on one browser, then killing that task, keeps you logged in (cluster works)
- [ ] `SELECT count(*) FROM jgroupsping;` in RDS returns the number of running tasks
- [ ] CloudWatch log group is receiving JSON-formatted logs
- [ ] An RDS snapshot exists and a test restore has been done (do this once, now, not during an incident)
- [ ] Bootstrap admin deleted; named admins have MFA
- [ ] Alarms from Part 8 are created and routed to a real pager

---

# PART 3 — AWS service reference

One section per service: what it does here, how it's configured, and what to watch. This is the part you read when someone asks "why does this resource exist?"

## 3.1 Service inventory

| # | Service | Resource name | Purpose | Blast radius if it fails |
|---|---|---|---|---|
| 1 | VPC | `<PREFIX>-vpc` | Network isolation | Total outage |
| 2 | Subnets (9) | `<PREFIX>-{public,app,data}-{a,b,c}` | AZ + tier separation | One AZ |
| 3 | Internet Gateway | `<PREFIX>-igw` | Inbound internet | Total outage |
| 4 | NAT Gateway (3) | per-AZ | Outbound from private subnets | Image pulls, SES, external IdPs fail |
| 5 | VPC Endpoints | ECR×2, S3, Logs, SecretsMgr, KMS | Private AWS API access | Falls back to NAT (cost + latency) |
| 6 | Security Groups (4) | `<PREFIX>-sg-{alb,task,db,vpce}` | Firewall | Outage or exposure |
| 7 | ALB | `<PREFIX>-alb` | TLS termination, routing, health | Total outage |
| 8 | ACM certificate | `<DOMAIN>` | TLS cert | Browser errors, total outage |
| 9 | Route 53 record | `<DOMAIN>` | DNS | Total outage |
| 10 | WAF Web ACL | `<PREFIX>-waf` | Rate limiting, filtering | Increased abuse risk |
| 11 | ECR repository | `<PROJECT>/keycloak` | Image storage | Cannot deploy or scale out |
| 12 | ECS cluster | `<PREFIX>-cluster` | Container orchestration | Total outage |
| 13 | ECS service + task def | `<PREFIX>-keycloak` | The application | Total outage |
| 14 | Application Auto Scaling | target-tracking on CPU | Capacity | Degraded under load |
| 15 | RDS instance | `<PREFIX>-rds` | All persistent state | **Total outage** |
| 16 | RDS subnet/parameter group | `<PREFIX>-db-subnets`, `<PREFIX>-pg17` | DB placement + tuning | Config drift |
| 17 | Secrets Manager (2) | DB creds, bootstrap admin | Credentials | Tasks fail to start |
| 18 | KMS keys | RDS, secrets, logs, ECR | Encryption | Everything encrypted becomes unreadable |
| 19 | IAM roles (3) | exec, task, rds-monitoring | Permissions | Tasks fail to start |
| 20 | CloudWatch Logs | `/ecs/<PREFIX>-keycloak` | Application logs | Blind during incidents |
| 21 | CloudWatch Alarms | see Part 8 | Detection | Silent failures |
| 22 | S3 bucket | `<PREFIX>-alb-logs` | ALB access logs | Audit gap |
| 23 | AWS Backup (optional) | `<PREFIX>-backup-plan` | Cross-account snapshot copies | Ransomware/deletion risk |
| 24 | SES (optional) | verified domain identity | Password-reset emails | Users can't self-serve resets |

## 3.2 Amazon VPC

**Design rules used here:**

- `/16` for the VPC, `/24` per subnet. That's 251 usable IPs per subnet — plenty, since each Fargate task consumes exactly one ENI and therefore one IP.
- Three tiers, three AZs. The data tier has **no route to a NAT gateway**, which means RDS is unreachable from and cannot reach the internet, no matter what someone misconfigures later.
- `enableDnsHostnames` and `enableDnsSupport` both **on** — required for RDS endpoints, VPC endpoints, and ECS service discovery to resolve.

**IP planning worksheet:**

| Tier | Sizing rule |
|---|---|
| Public | Small. Only the ALB's ENIs (2 per AZ) and NAT gateways live here. |
| App | `max_tasks / num_AZs × 2`. The ×2 covers rolling deploys where old and new tasks coexist. |
| Data | Small, but leave room for read replicas and future services. |

## 3.3 ECS on Fargate

**Why Fargate rather than EC2:** no servers to patch, no cluster capacity to manage, per-second billing, and each task gets its own kernel-level isolation boundary. For an identity server — the highest-value target in your estate — not having a shared host that another workload could escape into is a real security benefit.

**Sizing guidance** (start here, then measure):

| Environment | vCPU / Memory | Tasks | Rough capacity |
|---|---|---|---|
| dev | 1024 / 2048 | 1 | Functional testing only |
| stage | 2048 / 4096 | 2 | Load testing |
| prod (small) | 2048 / 4096 | 3 | ~50–150 logins/sec |
| prod (large) | 4096 / 8192 | 6+ | ~300+ logins/sec |

**Memory rules:**
- Keycloak needs **at least 1.3 GB** of container memory; 2 GB is a realistic floor and 4 GB is comfortable.
- Set `-XX:MaxRAMPercentage=70`. The JVM's default heap sizing does not respect container limits well in every configuration, and an OOM-killed container is indistinguishable at first glance from a crash loop.
- Cache size scales with active sessions. Roughly 1–2 KB per session per copy; with `owners=2` and 100,000 sessions that's ~400 MB across the cluster.

**Deployment settings that matter:**

| Setting | Value | Why |
|---|---|---|
| `minimumHealthyPercent` | 100 | Never drop below full capacity during a deploy |
| `maximumPercent` | 200 | Allows a full parallel set of new tasks |
| `deploymentCircuitBreaker.rollback` | true | Auto-revert bad deploys |
| `healthCheckGracePeriodSeconds` | 180 | DB migrations on first boot |
| `enableExecuteCommand` | true | `aws ecs execute-command` for live debugging (audited via CloudTrail) |

**Rolling updates and Keycloak versions:** Keycloak supports rolling updates between patch releases of the same minor version without downtime. Across *minor* versions, check the upgrade guide — some releases change the cache protocol or database schema and require the documented procedure (see Part 9.3).

## 3.4 Application Load Balancer

| Setting | Value | Reason |
|---|---|---|
| Scheme | `internet-facing` | Public login endpoint |
| Listener 443 | HTTPS, ACM cert | Encryption in transit |
| Listener 80 | 301 redirect | Never serve auth over HTTP |
| SSL policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` | TLS 1.2 minimum, 1.3 preferred |
| Target type | `ip` | Required for `awsvpc` Fargate networking |
| Health check | `HTTP :9000 /health/ready` | **Management port, not 8080** |
| Deregistration delay | 60s | Lets in-flight logins finish |
| Idle timeout | 60s | Above the 30s default only if you have slow IdP callbacks |
| `drop_invalid_header_fields` | true | Blocks header-smuggling attempts |
| Access logs | enabled → S3 | Audit and forensics |
| Stickiness | `lb_cookie`, 1h | Reduces cache chatter; not a correctness requirement |

**`/health/ready` vs `/health/live`:**
- **live** = "the process is running." Use it for the *container* health check — a failing liveness check should restart the task.
- **ready** = "the process is running *and* can reach the database." Use it for the *load balancer* — a task that can't reach RDS should stop receiving traffic but shouldn't necessarily be killed.

**Do not expose port 9000 publicly.** `/metrics` on the management port reveals operational detail. It is reachable only from the ALB security group, and no ALB listener rule routes to it.

## 3.5 Amazon RDS for PostgreSQL

### Configuration baseline

| Setting | dev | prod | Notes |
|---|---|---|---|
| Engine version | 17.x | 17.x | Keycloak 26.4+ requires PostgreSQL ≥ 13 |
| Instance class | `db.t4g.micro` | `db.m6g.large`+ | Graviton, ~20% cheaper |
| Multi-AZ | off | **on** | Automatic failover in 60–120s |
| Storage | 20 GB gp3 | 100 GB gp3, autoscale to 500 | gp3 gives baseline 3000 IOPS |
| Encryption | on | on | Cannot be added later in place |
| Backup retention | 1 day | **30 days** | 0 disables point-in-time recovery |
| Backup window | off-peak | 02:00–03:00 UTC | Avoid peak login times |
| Maintenance window | any | Sun 03:30–04:30 | Multi-AZ patches the standby first |
| Deletion protection | off | **on** | |
| Performance Insights | off | on, 7+ days | |
| Enhanced Monitoring | off | 60s | OS-level metrics |
| Log exports | — | `postgresql`, `upgrade` | Into CloudWatch |
| `rds.force_ssl` | 1 | 1 | Rejects unencrypted connections |
| IAM DB auth | optional | optional | See "passwordless" note below |

### Sizing the connection pool — the calculation people get wrong

PostgreSQL's `max_connections` on RDS defaults to roughly `LEAST({DBInstanceClassMemory/9531392}, 5000)`. Your total demand is:

```
tasks × KC_DB_POOL_MAX_SIZE  +  headroom for admin tools and migrations
```

With 12 tasks (the autoscaling max) × 20 = **240 connections**, plus ~20 for operations = 260. A `db.m6g.large` (8 GB) allows roughly 850, so there's plenty of room. But if you scale to 40 tasks on a `db.t4g.medium`, you will exhaust connections and every login will fail with a pool-timeout error.

**Rule:** whenever you raise `max-capacity` on the ECS autoscaler, recheck this arithmetic.

### Schema and growth

Keycloak creates ~95 tables via Liquibase on first start. The tables that grow are:

| Table | Grows with | Management |
|---|---|---|
| `user_entity`, `credential`, `user_attribute` | Number of users | Permanent |
| `user_session`, `client_session` (persistent sessions) | Active logins | Expire automatically |
| `event_entity` | Login events | Set an expiration on the realm's Events config |
| `admin_event_entity` | Admin actions | Same |
| `offline_user_session` | Offline tokens | Expire per client settings |
| `jgroupsping` | Number of running nodes | Self-cleaning |

> **Most common "database keeps growing" cause:** event logging enabled with no expiration. Set **Realm Settings → Sessions/Events → Expiration** and it self-manages.

### Passwordless database access (optional, recommended for high-security)

RDS supports IAM database authentication: the task role requests a short-lived (15-minute) token instead of using a static password. It removes stored database passwords entirely. The trade-off is a per-connection token fetch and a lower connection-rate limit, which matters if your pool churns. Most deployments keep managed password rotation instead — simpler, and rotation already removes the long-lived-secret risk.

## 3.6 Secrets Manager and KMS

**What is stored:**

| Secret | Created by | Rotation |
|---|---|---|
| `rds!db-…` (master creds) | RDS `--manage-master-user-password` | Automatic, managed by RDS |
| `<PREFIX>/keycloak/bootstrap-admin` | You, in Step 4 | **Delete after Step 9** |
| `<PREFIX>/keycloak/smtp` (if using SES SMTP) | You | Manual or Lambda |

**How the values reach the container:** the `secrets` block in the task definition. The ECS agent (using the *execution role*) fetches the value before the container starts and injects it as an environment variable. The value never appears in the task definition, in Terraform state, or in the ECS console.

The `:username::` suffix in `valueFrom` extracts a single JSON key from the secret. The syntax is `<arn>:<json-key>:<version-stage>:<version-id>` — the trailing colons are required even when empty.

**KMS:** use customer-managed keys (CMKs) rather than AWS-managed ones for RDS, secrets, and logs when you need key-level audit and independent rotation. The cost is $1/key/month plus API calls. Grant the execution role `kms:Decrypt` restricted with a `kms:ViaService` condition, as shown in Step 8.1.

## 3.7 CloudWatch

**Logs:** `KC_LOG_CONSOLE_OUTPUT=json` makes logs machine-parseable so CloudWatch Logs Insights queries work properly. Keycloak 26.5+ also supports OpenTelemetry for logs and metrics if you're consolidating observability elsewhere.

Useful Logs Insights queries:

```sql
-- Failed logins by IP, last hour
fields @timestamp, ipAddress, username, error
| filter type = "LOGIN_ERROR"
| stats count() as failures by ipAddress
| sort failures desc | limit 20

-- Slow requests
fields @timestamp, @message
| filter @message like /took [0-9]{4,}ms/
| sort @timestamp desc

-- Startup failures across all tasks
fields @timestamp, @logStream, @message
| filter @message like /ERROR|Failed to start|FATAL/
| sort @timestamp desc | limit 50
```

**Metrics:** with `KC_METRICS_ENABLED=true`, Prometheus-format metrics are served on `:9000/metrics`. To get them into CloudWatch, run the ADOT (AWS Distro for OpenTelemetry) collector as a sidecar container scraping `localhost:9000/metrics`. Alternatively, scrape into Amazon Managed Prometheus.

## 3.8 AWS WAF

Attach a Web ACL to the ALB with:

| Rule | Purpose |
|---|---|
| `AWSManagedRulesCommonRuleSet` | Broad OWASP-style protections |
| `AWSManagedRulesKnownBadInputsRuleSet` | Known exploit payloads |
| `AWSManagedRulesAmazonIpReputationList` | Known malicious sources |
| Rate-based rule: 2000 req / 5 min / IP | Blunt DoS protection |
| Rate-based rule scoped to `/realms/*/protocol/openid-connect/token`: 100 / 5 min / IP | Credential stuffing |

> Start every managed rule group in **count mode** for a week and review the logs before switching to block. Managed rules can and do false-positive on SAML POST bodies and long JWTs.

Keycloak's own **brute-force detection** (Realm Settings → Security Defenses) is the second layer: it locks individual accounts after N failures. Use both — WAF stops volume, Keycloak stops targeted attacks.

## 3.9 Amazon SES (email)

Keycloak sends email for password resets, email verification, and admin notifications. Configure per realm under **Realm Settings → Email**:

| Field | Value |
|---|---|
| Host | `email-smtp.<REGION>.amazonaws.com` |
| Port | `587` |
| Encryption | StartTLS |
| Authentication | on, with SES SMTP credentials from Secrets Manager |
| From | `no-reply@<DOMAIN>` (domain must be verified in SES) |

Move the SES account out of the sandbox before go-live, or only verified addresses receive mail. Configure SPF, DKIM, and DMARC on the sending domain — password-reset emails that land in spam generate a lot of support tickets.

---

# PART 4 — Keycloak configuration reference

## 4.1 Build-time vs run-time options — the concept that trips everyone up

Keycloak (Quarkus-based since v17) splits configuration in two:

- **Build-time options** decide what code is compiled into the server: which database driver, whether health/metrics endpoints exist, which features are enabled. Changing one requires re-running `kc.sh build`.
- **Run-time options** are read at start: URLs, credentials, hostnames, pool sizes.

If you set a build-time option only as an environment variable and start with `--optimized`, **it is silently ignored**. If you don't use `--optimized`, Keycloak re-runs the build step on every container start, adding 20–40 seconds to boot.

**The rule:** bake build-time options into the Dockerfile (Step 6), run with `--optimized`, pass everything else as environment variables.

| Build-time (Dockerfile) | Run-time (env vars) |
|---|---|
| `KC_DB` | `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD` |
| `KC_HEALTH_ENABLED` | `KC_HOSTNAME`, `KC_HOSTNAME_ADMIN` |
| `KC_METRICS_ENABLED` | `KC_PROXY_HEADERS`, `KC_HTTP_ENABLED` |
| `KC_CACHE`, `KC_CACHE_STACK` | `KC_DB_POOL_*`, `KC_LOG_*` |
| `KC_FEATURES` | `KC_BOOTSTRAP_ADMIN_*` |
| `KC_TRANSACTION_XA_ENABLED` | `KC_SPI_*` provider settings |

## 4.2 Complete environment variable reference

Every variable can also be given as a CLI flag (`KC_DB_URL` → `--db-url`) or in `conf/keycloak.conf` (`db-url=`). Environment variables win.

### Database

| Variable | Example | Notes |
|---|---|---|
| `KC_DB` | `postgres` | Build-time |
| `KC_DB_URL` | `jdbc:postgresql://host:5432/keycloak?ssl=true&sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem` | Full JDBC URL; TLS params matter |
| `KC_DB_USERNAME` | from secret | |
| `KC_DB_PASSWORD` | from secret | |
| `KC_DB_POOL_INITIAL_SIZE` | `5` | Connections opened at start |
| `KC_DB_POOL_MIN_SIZE` | `5` | Keep warm; avoids reconnect storms |
| `KC_DB_POOL_MAX_SIZE` | `20` | Per task — see the pool arithmetic in 3.5 |
| `KC_TRANSACTION_XA_ENABLED` | `false` | Non-XA is faster; only enable if you need two-phase commit |

### Hostname (v2 — Keycloak 26 syntax)

Hostname configuration was completely rewritten in Keycloak 26. The old `KC_HOSTNAME_URL`, `KC_HOSTNAME_PORT`, `KC_HOSTNAME_PATH`, and `KC_PROXY` options are **gone**.

| Variable | Value | Notes |
|---|---|---|
| `KC_HOSTNAME` | `https://auth.example.com` | **Now a full URL**, not a bare hostname |
| `KC_HOSTNAME_ADMIN` | `https://admin-auth.example.com` | Only if the admin console has its own URL |
| `KC_HOSTNAME_STRICT` | `true` | Refuses to infer hostnames from request headers — set `true` in prod |
| `KC_HOSTNAME_BACKCHANNEL_DYNAMIC` | `false` | `true` only if internal clients call Keycloak on a different internal URL |

> **Why this matters:** the hostname determines the `issuer` claim in every token and every URL in the OIDC discovery document (`/.well-known/openid-configuration`). If it's wrong, clients reject tokens with "issuer mismatch" — and changing it later invalidates every issued token.

### Proxy / TLS termination

| Variable | Value | Notes |
|---|---|---|
| `KC_HTTP_ENABLED` | `true` | Allows plain HTTP from the ALB inside the VPC |
| `KC_PROXY_HEADERS` | `xforwarded` | Use `xforwarded` for ALB. (`forwarded` is for RFC 7239 proxies.) |
| `KC_HTTP_PORT` | `8080` | Default |
| `KC_HTTP_MANAGEMENT_PORT` | `9000` | Default; health + metrics |

> **Security requirement:** only trust proxy headers when a proxy you control is the *only* path to the container. That's exactly why the task security group accepts 8080 solely from the ALB security group. If a container were directly reachable, an attacker could spoof `X-Forwarded-For` and defeat brute-force protection and IP logging.

### Clustering and cache

| Variable | Value | Notes |
|---|---|---|
| `KC_CACHE` | `ispn` | Infinispan distributed cache; build-time |
| `KC_CACHE_STACK` | `jdbc-ping` | **Default since Keycloak 26.** Nodes register in the `JGROUPSPING` table. UDP multicast does not work on AWS. |
| `KC_CACHE_CONFIG_FILE` | `cache-ispn.xml` | Only if you need to change `owners`, timeouts, or use an external Infinispan |
| `jgroups.bind.port` | `7800` | Default cluster port |

**Why `jdbc-ping`:** ECS `awsvpc` networking gives every task a private IP but no multicast. Tasks need another way to discover each other. `jdbc-ping` uses the database they already share. `dns-ping` is the alternative (with ECS Service Connect / Cloud Map), but `jdbc-ping` has fewer moving parts and is the upstream default.

**Cache `owners` setting:** by default each session is stored on 2 nodes. Losing one node loses nothing; losing two simultaneously can lose sessions. If you run 6+ tasks and can afford the memory, raising `owners` to 3 increases resilience.

### Health, metrics, logging

| Variable | Value |
|---|---|
| `KC_HEALTH_ENABLED` | `true` (build-time) |
| `KC_METRICS_ENABLED` | `true` (build-time) |
| `KC_LOG` | `console` |
| `KC_LOG_CONSOLE_OUTPUT` | `json` |
| `KC_LOG_LEVEL` | `info` (use `org.keycloak:debug` sparingly — it is very chatty) |

Endpoints on port 9000: `/health`, `/health/live`, `/health/ready`, `/health/started`, `/metrics`.

### Bootstrap and features

| Variable | Notes |
|---|---|
| `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` | Only used when `master` realm is created |
| `KC_FEATURES` | Comma-separated, e.g. `token-exchange,admin-fine-grained-authz`. Build-time. Preview features are not covered by backwards-compatibility guarantees. |
| `JAVA_OPTS_APPEND` | `-XX:MaxRAMPercentage=70` |

## 4.3 Realm-level configuration checklist

Infrastructure is only half the job. These are set in the admin console (and should be exported to version control — see 9.6):

**Security defenses**
- [ ] Brute force detection: ON, permanent lockout OFF, max failures 10, wait 1 min, max wait 15 min
- [ ] Require SSL: `all requests`
- [ ] Password policy: length ≥ 12, not username, not email, plus a breach check if available
- [ ] Hashing: leave at the current Keycloak default (it is updated as guidance changes)

**Tokens and sessions**
- [ ] Access token lifespan: 5 minutes (short — this is the blast radius of a stolen token)
- [ ] SSO session idle: 30 minutes; SSO session max: 10 hours
- [ ] Refresh token rotation: ON
- [ ] Revoke refresh token: ON

**Clients**
- [ ] Confidential clients where the app can keep a secret; public clients + PKCE for SPAs and mobile
- [ ] Valid redirect URIs are **exact** — never `https://app.example.com/*` with a bare wildcard on the host
- [ ] Web origins set explicitly, not `*`
- [ ] Standard flow ON, implicit flow **OFF**, direct access grants OFF unless specifically needed

**Operational**
- [ ] Login events + admin events saved, with expiration set
- [ ] Email/SMTP configured and tested
- [ ] Realm keys rotation policy understood (see 9.5)
- [ ] MFA required for all `master` realm administrators

---

# PART 5 — Options and trade-offs

The architecture above is one defensible choice. Here is what you're choosing between, so you can justify it or deviate deliberately.

## 5.1 Compute platform

| Option | Pros | Cons | Choose when |
|---|---|---|---|
| **ECS Fargate** *(this doc)* | No servers to patch; per-second billing; strong task isolation; simplest HA story | Slightly higher per-vCPU cost; 60–90s cold start; no GPU/host tuning | Default choice for most teams |
| ECS on EC2 | Cheaper at steady high scale; Reserved/Savings Plans; host-level control | You patch and manage the hosts; capacity planning | >70% steady utilisation, cost-sensitive |
| EKS + Keycloak Operator | Best-in-class Keycloak lifecycle (the Operator handles rolling upgrades, realm imports, CRs for clients); portable | Kubernetes is a large operational commitment for one application | You already run EKS |
| EC2 + Auto Scaling Group | Familiar; full control | You own the OS, the JVM, the packaging, and the deploys | Regulatory constraint against containers |
| App Runner / Lambda | — | Keycloak needs a persistent clustered JVM; not viable | Never |

> **If you already run Kubernetes, use EKS and the Keycloak Operator.** It is the best-supported deployment path upstream and it removes most of Part 9's manual work. This document targets ECS because it's the lowest-overhead option for teams who don't already have a cluster.

## 5.2 Database

| Option | Pros | Cons | Choose when |
|---|---|---|---|
| **RDS PostgreSQL Multi-AZ** *(this doc)* | Simple, well-trodden, cheapest managed HA, 60–120s failover | Standby is idle capacity you pay for | Default |
| RDS Multi-AZ DB cluster (2 readable standbys) | Faster failover (~35s), two readable standbys | More expensive, fewer instance classes | Failover time is critical |
| Aurora PostgreSQL | Faster failover, storage autoscaling to 128 TB, cheap read replicas, Global Database for multi-region DR | ~20–30% more expensive; Keycloak is a small-data workload that rarely needs it | Multi-region DR, or you standardise on Aurora |
| Aurora Serverless v2 | Scales to near-zero for dev | Cold-scale latency; unpredictable cost | Dev/test only |
| Self-managed PostgreSQL on EC2 | Full control | You are now a DBA; you own backups and failover | Almost never |

**Reality check:** Keycloak's dataset is small (typically well under 50 GB even with millions of users) and the workload is read-heavy with short transactions. A plain Multi-AZ RDS instance is sufficient for the overwhelming majority of deployments. Reach for Aurora when you need its *DR* features, not for performance.

## 5.3 Load balancer

| Option | Pros | Cons |
|---|---|---|
| **ALB** *(this doc)* | Layer 7 routing, WAF integration, path-based rules, ACM, access logs | TLS terminates at the LB (usually fine) |
| NLB | Lowest latency; passthrough TLS to Keycloak; static IPs | No WAF; no L7 routing; you manage certs on Keycloak |
| NLB → ALB | Static IPs *and* WAF | Two hops, two bills |
| CloudFront → ALB | Global edge, DDoS absorption, caching for static theme assets | Extra latency for dynamic auth traffic; more complex cache rules |

**End-to-end TLS:** if your compliance regime forbids plaintext even inside the VPC, terminate TLS at Keycloak instead. Set `KC_HTTPS_CERTIFICATE_FILE`/`KC_HTTPS_CERTIFICATE_KEY_FILE`, set the ALB target group protocol to HTTPS, and drop `KC_HTTP_ENABLED`. You then own certificate distribution and rotation into the containers, which is a genuine ongoing cost.

## 5.4 Session storage

| Option | Pros | Cons |
|---|---|---|
| **Embedded Infinispan + persistent sessions in RDS** *(this doc, and the KC 26 default)* | No extra infrastructure; sessions survive full cluster restart | Extra DB writes; cluster must form correctly |
| Embedded Infinispan, memory-only | Fastest | All users logged out on a full restart |
| External Infinispan / Data Grid | Required for active-active multi-site; decouples session lifetime from Keycloak restarts | A second distributed system to operate |

Keycloak 26.7 introduces a **preview** of simplified multi-cluster HA that does not require an external cache. If multi-region active-active is on your roadmap, track that feature rather than building an external Infinispan cluster now.

## 5.5 Region strategy

| Option | RTO / RPO | Cost | Complexity |
|---|---|---|---|
| **Single region, Multi-AZ** *(this doc)* | Minutes / near-zero within region; region loss = outage | Baseline | Low |
| Warm standby, second region | ~30–60 min / seconds (Aurora Global) | +50–70% | Medium |
| Active-active multi-region | Near-zero | +100% | High — needs external Infinispan and careful token/issuer design |

Be honest about the requirement. A full AWS region failure is rare; an active-active identity layer is expensive and introduces failure modes of its own. Most organisations are correctly served by single-region Multi-AZ plus a tested cross-region backup restore.

---

# PART 6 — Security baseline

## 6.1 Non-negotiables

| # | Control | Where implemented |
|---|---|---|
| 1 | Keycloak tasks in private subnets, no public IP | Step 8.4 `assignPublicIp=DISABLED` |
| 2 | RDS in isolated subnets, no route to internet | Step 1 (no NAT route on data tier) |
| 3 | Database reachable only from task security group | Step 2 |
| 4 | TLS 1.2+ enforced at the edge | Step 7 SSL policy |
| 5 | TLS enforced to the database | `rds.force_ssl=1` + `sslmode=verify-full` |
| 6 | Encryption at rest everywhere (RDS, secrets, logs, ECR, S3) | KMS |
| 7 | No credentials in code, config, or Terraform state | Secrets Manager injection |
| 8 | Automatic credential rotation | RDS managed master password |
| 9 | Bootstrap admin deleted after setup | Step 9 |
| 10 | MFA on all `master` realm admins | Realm config |
| 11 | Brute-force protection on | Realm config |
| 12 | WAF with rate limiting | Part 3.8 |
| 13 | Audit logs retained (ALB access, Keycloak events, CloudTrail) | Parts 3.4, 3.7, 4.3 |
| 14 | Image scanning on push | ECR `scanOnPush` |
| 15 | Least-privilege IAM, separate exec and task roles | Step 8.1 |

## 6.2 Things that are commonly got wrong

- **`master` realm used for application users.** It is the administrative realm. Compromise of a user there can mean compromise of everything. One realm per tenant or environment; users belong in those.
- **Wildcard redirect URIs.** `https://*.example.com/*` allows any subdomain — including one an attacker gets control of — to receive authorization codes. Always list exact URIs.
- **Long access-token lifespans.** "It's easier than handling refresh" costs you a wide window when a token leaks. Keep access tokens at 5 minutes and use refresh token rotation.
- **Admin console exposed to the whole internet.** Restrict `/admin` by ALB listener rule to your corporate CIDRs, or publish it on a separate internal ALB with `KC_HOSTNAME_ADMIN`.
- **Trusting `X-Forwarded-For` while the container is directly reachable.** Header spoofing then defeats IP-based lockouts.
- **No tested restore.** An untested backup is a hope, not a control. Part 9.2 exists for this reason.

## 6.3 Compliance mapping (starting points)

| Requirement | Evidence in this design |
|---|---|
| Encryption at rest | KMS on RDS, Secrets Manager, CloudWatch Logs, ECR, S3 |
| Encryption in transit | ACM/TLS 1.2+ at ALB; `rds.force_ssl` to database |
| Access logging | ALB access logs, CloudTrail, Keycloak admin + login events |
| Least privilege | Scoped IAM roles, security-group-to-security-group rules |
| Backup & recovery | 30-day PITR, cross-region snapshot copy, tested restore runbook |
| Change management | Terraform in version control, PR review, immutable image tags |
| Vulnerability management | ECR scan on push, monthly patch cadence (Part 9.4) |

---

# PART 7 — Deployment pipeline

## 7.1 Principles

- **Infrastructure as code.** The CLI commands in Part 2 are for understanding. Real environments are Terraform, in Git, applied by CI.
- **Immutable images.** One image, one tag, promoted unchanged through dev → stage → prod.
- **No manual console changes in prod.** If it isn't in code, it will be lost at the next rebuild and nobody will know why prod differs from stage.

## 7.2 Pipeline stages

```
 ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌─────────┐   ┌──────────┐
 │  Git    │──►│  Build   │──►│   Scan   │──►│  Deploy │──►│  Verify  │
 │  push   │   │  image   │   │  image   │   │  dev    │   │  smoke   │
 └─────────┘   └──────────┘   └──────────┘   └─────────┘   └────┬─────┘
                                                                 │
 ┌──────────┐   ┌─────────┐   ┌──────────┐   ┌─────────┐        │
 │  Verify  │◄──│ Deploy  │◄──│  Manual  │◄──│ Deploy  │◄───────┘
 │  prod    │   │  prod   │   │ approval │   │ stage   │
 └──────────┘   └─────────┘   └──────────┘   └─────────┘
```

## 7.3 GitHub Actions example

```yaml
name: deploy-keycloak
on:
  push:
    tags: ['v*']

permissions:
  id-token: write      # OIDC federation to AWS — no static keys
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.push.outputs.image }}
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<AWS_ACCOUNT_ID>:role/gha-keycloak-deploy
          aws-region: <REGION>
      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr
      - name: Build and push
        id: push
        run: |
          IMAGE=${{ steps.ecr.outputs.registry }}/kc/keycloak:${GITHUB_REF_NAME}
          docker build -t $IMAGE .
          docker push $IMAGE
          echo "image=$IMAGE" >> $GITHUB_OUTPUT
      - name: Wait for ECR scan and fail on CRITICAL
        run: |
          aws ecr wait image-scan-complete \
            --repository-name kc/keycloak --image-id imageTag=${GITHUB_REF_NAME}
          CRIT=$(aws ecr describe-image-scan-findings \
            --repository-name kc/keycloak --image-id imageTag=${GITHUB_REF_NAME} \
            --query 'imageScanFindings.findingSeverityCounts.CRITICAL' --output text)
          [ "$CRIT" = "None" ] || { echo "Critical CVEs: $CRIT"; exit 1; }

  deploy-prod:
    needs: build
    environment: production      # requires manual approval
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::<AWS_ACCOUNT_ID>:role/gha-keycloak-deploy
          aws-region: <REGION>
      - name: Roll out new task definition
        run: |
          aws ecs register-task-definition \
            --cli-input-json "$(jq --arg img '${{ needs.build.outputs.image }}' \
              '.containerDefinitions[0].image=$img' taskdef.json)"
          aws ecs update-service --cluster kc-prod-cluster \
            --service kc-prod-keycloak --task-definition kc-prod-keycloak
          aws ecs wait services-stable \
            --cluster kc-prod-cluster --services kc-prod-keycloak
      - name: Smoke test
        run: |
          curl -fsS https://<DOMAIN>/realms/master/.well-known/openid-configuration \
            | jq -e '.issuer == "https://<DOMAIN>/realms/master"'
```

**Use OIDC federation**, not long-lived IAM access keys in CI secrets. It is one of the highest-value security changes available for a modest amount of setup.

---

# PART 8 — Observability: what to watch and what to alarm on

## 8.1 The four questions a dashboard must answer

1. Can users log in right now? → ALB 5xx rate, target health count, `/health/ready`
2. Is it fast? → ALB target response time p95/p99
3. Will it still work in an hour? → CPU/memory, DB connections, storage, cache size
4. Is anyone attacking it? → login failure rate, WAF blocks, brute-force lockouts

## 8.2 Alarms

| # | Alarm | Metric | Threshold | Severity | First action |
|---|---|---|---|---|---|
| 1 | No healthy targets | `HealthyHostCount` (ALB) | `< 1` for 1 min | **P1 page** | Runbook 9.1 |
| 2 | Degraded capacity | `HealthyHostCount` | `< 2` for 5 min | P2 | Check task stop reasons |
| 3 | 5xx from Keycloak | `HTTPCode_Target_5XX_Count` | `> 10` in 5 min | **P1 page** | Check logs + DB |
| 4 | Slow responses | `TargetResponseTime` p95 | `> 2s` for 5 min | P2 | Performance Insights |
| 5 | DB CPU | `CPUUtilization` (RDS) | `> 80%` for 10 min | P2 | Find slow queries |
| 6 | DB connections | `DatabaseConnections` | `> 80%` of max | P2 | Pool arithmetic, 3.5 |
| 7 | DB storage | `FreeStorageSpace` | `< 20%` | P2 | Autoscaling should handle; verify |
| 8 | DB memory | `FreeableMemory` | `< 15%` | P2 | Resize instance |
| 9 | Replica lag / failover | `EventSubscription` on RDS failover | any | **P1 page** | Runbook 9.7 |
| 10 | Task CPU | ECS `CPUUtilization` | `> 80%` for 10 min | P3 | Autoscaler should act |
| 11 | Task memory | ECS `MemoryUtilization` | `> 85%` for 10 min | P2 | OOM risk — raise memory |
| 12 | Certificate expiry | ACM `DaysToExpiry` | `< 30` | P2 | Should auto-renew; investigate |
| 13 | Login failure spike | Logs metric filter on `LOGIN_ERROR` | `> 100` in 5 min | P2 | Possible credential stuffing |
| 14 | Deployment failure | ECS deployment circuit breaker event | any | P2 | Check rolled-back version |
| 15 | Backup failure | RDS event category `backup` | any | P2 | Runbook 9.2 |

Example alarm:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name ${PREFIX}-no-healthy-targets \
  --alarm-description "Keycloak has no healthy targets - logins are failing" \
  --namespace AWS/ApplicationELB --metric-name HealthyHostCount \
  --dimensions Name=TargetGroup,Value=<tg-suffix> Name=LoadBalancer,Value=<alb-suffix> \
  --statistic Minimum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions arn:aws:sns:<REGION>:<AWS_ACCOUNT_ID>:${PREFIX}-p1
```

> `--treat-missing-data breaching` matters. If the metric stops arriving entirely — which is exactly what a total failure looks like — the default (`missing`) leaves the alarm silent.

## 8.3 Keycloak metrics worth graphing

From `:9000/metrics` (Prometheus format), once scraped:

| Metric | Meaning |
|---|---|
| `keycloak_logins_total` (by realm, provider) | Successful logins |
| `keycloak_failed_login_attempts_total` | Failures — spikes indicate attack |
| `keycloak_registrations_total` | Self-registrations |
| `vendor_agroal_active_count` | Active DB connections from the pool |
| `vendor_agroal_awaiting_count` | Threads waiting for a connection — **should be 0** |
| `vendor_cache_manager_*_number_of_entries` | Session cache size |
| `jvm_memory_used_bytes{area="heap"}` | Heap usage |
| `http_server_requests_seconds` | Latency histogram by endpoint |

`vendor_agroal_awaiting_count` above zero is the earliest reliable signal that your connection pool is undersized.

---

# PART 9 — Operational runbooks

Each runbook is written to be executed under pressure by someone who did not build the system.

## 9.1 RUNBOOK: Keycloak is down (no healthy targets)

**Symptom:** alarm #1 or #3; users report login failures.

```bash
# 1. Is the service running what you think it is?
aws ecs describe-services --cluster kc-prod-cluster --services kc-prod-keycloak \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,taskDef:taskDefinition}'

# 2. Why did tasks stop? This is usually the answer.
aws ecs list-tasks --cluster kc-prod-cluster --service-name kc-prod-keycloak \
  --desired-status STOPPED --query 'taskArns[0:5]' --output text \
 | xargs -n1 -I{} aws ecs describe-tasks --cluster kc-prod-cluster --tasks {} \
     --query 'tasks[0].{stopped:stoppedReason,exit:containers[0].exitCode,reason:containers[0].reason}'

# 3. Recent errors in logs
aws logs tail /ecs/kc-prod-keycloak --since 30m --filter-pattern 'ERROR'

# 4. Is the database up and reachable?
aws rds describe-db-instances --db-instance-identifier kc-prod-rds \
  --query 'DBInstances[0].{status:DBInstanceStatus,az:AvailabilityZone,multiAz:MultiAZ}'
aws cloudwatch get-metric-statistics --namespace AWS/RDS \
  --metric-name DatabaseConnections --dimensions Name=DBInstanceIdentifier,Value=kc-prod-rds \
  --start-time $(date -u -d '30 min ago' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 300 --statistics Maximum
```

**Decision tree:**

| Finding | Cause | Action |
|---|---|---|
| `OutOfMemoryError` / exit 137 | Memory limit too low | Raise task memory, redeploy |
| `CannotPullContainerError` | ECR/network problem | Check VPC endpoints, NAT, ECR policy |
| `ResourceInitializationError: secrets` | Execution role or KMS permission | Check IAM policy from 8.1 |
| `Connection refused` to DB / pool timeout | RDS down, SG changed, or pool exhausted | Check RDS status; check SG rules |
| Tasks healthy but ALB says unhealthy | Health check misconfigured | Confirm health check is port **9000**, path `/health/ready` |
| Deployment rolled back automatically | Bad image | Identify last-good tag, redeploy it |

**Emergency capacity bump:**

```bash
aws ecs update-service --cluster kc-prod-cluster --service kc-prod-keycloak --desired-count 6
```

**Emergency rollback:**

```bash
# List revisions, pick the last known good
aws ecs list-task-definitions --family-prefix kc-prod-keycloak --sort DESC --max-items 5
aws ecs update-service --cluster kc-prod-cluster --service kc-prod-keycloak \
  --task-definition kc-prod-keycloak:<N> --force-new-deployment
aws ecs wait services-stable --cluster kc-prod-cluster --services kc-prod-keycloak
```

## 9.2 RUNBOOK: Backup and restore

**What is backed up automatically:** RDS takes a daily snapshot in the backup window and continuously ships transaction logs, giving **point-in-time recovery to any second within the retention period** (30 days here).

**What is NOT backed up automatically:** nothing else needs to be. Keycloak containers are stateless. Your Terraform state and realm exports are your infrastructure backup.

### Manual snapshot (take one before every upgrade)

```bash
aws rds create-db-snapshot \
  --db-instance-identifier kc-prod-rds \
  --db-snapshot-identifier kc-prod-pre-upgrade-$(date +%Y%m%d-%H%M)
aws rds wait db-snapshot-completed --db-snapshot-identifier <id>
```

### Cross-region / cross-account copies (ransomware and deletion protection)

Use AWS Backup with a vault in a second account. Automated RDS backups live in the same account and region; if that account is compromised, so are they.

### Point-in-time restore

**Important:** you cannot restore *in place*. RDS creates a **new instance**, and you then repoint the application.

```bash
# 1. Restore to a new instance at a chosen timestamp
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier kc-prod-rds \
  --target-db-instance-identifier kc-prod-rds-restored \
  --restore-time 2026-07-27T09:15:00Z \
  --db-subnet-group-name kc-prod-db-subnets \
  --vpc-security-group-ids <SG_DB> \
  --multi-az --no-publicly-accessible

aws rds wait db-instance-available --db-instance-identifier kc-prod-rds-restored

# 2. Verify the data BEFORE cutting over
#    (from a bastion or an ECS exec session)
psql -h <restored-endpoint> -U kcadmin -d keycloak \
  -c "SELECT count(*) FROM user_entity; SELECT name FROM realm;"

# 3. Cut over: update KC_DB_URL in the task definition, redeploy
# 4. Once confident, rename instances so the endpoint is stable long-term
```

**Restore time expectation:** 20–45 minutes for a 100 GB instance. Include this number in your RTO commitments, and **rehearse it quarterly** — the rehearsal is what turns a documented procedure into a real capability.

### Realm configuration backup

Database backups cover realms too, but a human-readable export in Git is invaluable for reviewing changes and rebuilding into a fresh environment:

```bash
TASK=$(aws ecs list-tasks --cluster kc-prod-cluster --service-name kc-prod-keycloak \
  --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster kc-prod-cluster --task $TASK --container keycloak \
  --interactive --command "/opt/keycloak/bin/kc.sh export --dir /tmp/export --users skip"
# then copy the files out and commit them
```

> Export with `--users skip` for configuration backups. Full user exports contain credential hashes and must be treated as secrets.

## 9.3 RUNBOOK: Upgrading Keycloak

**Cadence:** Keycloak ships roughly four minor releases per year; only the latest major line receives security fixes. Plan to stay within one or two minor versions of current.

**Procedure:**

1. Read the [upgrade guide](https://www.keycloak.org/docs/latest/upgrading/) for **every** version between yours and the target. Never skip intermediate release notes.
2. Restore the latest prod snapshot into a stage database and upgrade **stage** first. This is the only meaningful test.
3. Take a manual snapshot of prod (9.2).
4. Build the new image with the same Dockerfile, new base tag.
5. Deploy to prod. ECS rolling deployment with `minimumHealthyPercent=100` and the circuit breaker enabled.
6. Watch: target health, 5xx rate, error logs, and a real login.

**Critical constraints:**

- **Database migrations are one-way.** Once the new version has migrated the schema, older versions cannot read it. Rollback means restore-from-snapshot, not just redeploying the old image. This is why step 3 is not optional.
- **Rolling upgrades work between patch versions** of the same minor. Some minor upgrades change the cache protocol; the release notes will say so, and in that case you need a brief maintenance window (scale to 0, deploy, scale up) rather than a rolling deploy.
- **Check `KC_FEATURES`.** Preview features can be renamed, promoted, or removed between minors.

**Rollback plan (write it down before you start):**

```
1. aws ecs update-service --task-definition <previous-revision> --force-new-deployment
2. If schema was migrated: restore snapshot from step 3 into a new instance,
   repoint KC_DB_URL, redeploy previous image.
3. Expected data loss: everything since the snapshot. Communicate to stakeholders.
```

## 9.4 RUNBOOK: Patching and maintenance cadence

| What | Frequency | How |
|---|---|---|
| Base image / OS CVEs | Monthly, or immediately for critical | Rebuild image, redeploy |
| Keycloak minor version | Quarterly | Runbook 9.3 |
| RDS minor version | Automatic in maintenance window | `--auto-minor-version-upgrade` |
| RDS major version | Annually, planned | Test in stage; requires a longer window |
| TLS certificate | Automatic | ACM DNS validation |
| DB master password | Automatic | RDS managed rotation |
| Realm signing keys | Annually or per policy | Runbook 9.5 |
| Restore rehearsal | Quarterly | Runbook 9.2 |
| IAM/security-group review | Quarterly | Manual audit |

## 9.5 RUNBOOK: Rotating realm signing keys

Realm keys sign every token. Rotating them is safe **if done in the right order**, because Keycloak publishes both old and new public keys in the JWKS endpoint during the overlap.

1. Realm Settings → Keys → Providers → **Add** a new `rsa-generated` provider with a **higher priority** than the current one.
2. New tokens are now signed with the new key; the old key remains published, so existing tokens still validate.
3. Wait longer than your maximum token lifetime (access token + refresh token max). Typically 24 hours is safe.
4. Set the old provider to `passive` (still validates, no longer signs) for another interval.
5. Delete the old provider.

**Do not delete the old key immediately** — every unexpired token signed with it becomes invalid at once, logging out your entire user base.

## 9.6 RUNBOOK: Adding a new application (client)

1. In the target realm: Clients → Create client.
2. Choose the type:
   - **Confidential** (server-side web app, backend service) — has a client secret, store it in Secrets Manager.
   - **Public + PKCE** (SPA, mobile) — no secret, PKCE required.
3. Set **exact** valid redirect URIs and web origins. No wildcards on the host portion.
4. Standard flow ON; implicit flow OFF; direct access grants OFF unless there's a documented reason.
5. Add the client scopes and protocol mappers the app needs — nothing more. Tokens are sent over the network and stored by clients; every extra claim is extra exposure.
6. Test with the discovery document: `https://<DOMAIN>/realms/<realm>/.well-known/openid-configuration`.
7. Commit the realm export to Git.

## 9.7 RUNBOOK: RDS failover

**What happens automatically:** in a Multi-AZ deployment, AWS detects the primary's failure and promotes the standby. The DNS endpoint is updated. Total time is typically 60–120 seconds.

**What you do:**

1. Confirm from RDS events that a failover occurred (`aws rds describe-events --duration 60`).
2. Keycloak tasks will log connection errors during the switch. The pool reconnects automatically. **If tasks are stuck** after the failover completes, force a new deployment to recycle connections.
3. Check that `HealthyHostCount` recovered.
4. Verify a real login.
5. Afterwards: read the RDS event log for the cause. Repeated failovers indicate an underlying problem (storage, memory pressure) that needs fixing rather than tolerating.

**Reducing the impact:** the JDBC connection pool's `KC_DB_POOL_MIN_SIZE` keeps warm connections, which shortens recovery. Some teams add `?targetServerType=primary&connectTimeout=5&socketTimeout=30` to the JDBC URL to fail fast rather than hang.

## 9.8 RUNBOOK: Scaling for a known traffic event

For a predictable surge (a launch, a marketing campaign, first day of term):

```bash
# 24h before: raise the floor so you aren't waiting on scale-out
aws application-autoscaling register-scalable-target \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/kc-prod-cluster/kc-prod-keycloak \
  --min-capacity 6 --max-capacity 20

# Recheck the DB pool arithmetic! 20 tasks x 20 connections = 400.
# Resize RDS if needed — this requires a maintenance window.
```

Also consider raising the RDS instance class ahead of time; scaling the database is the slow part and cannot be done instantly.

---

# PART 10 — Troubleshooting guide

## 10.1 Symptom → cause table

| Symptom | Likely cause | Fix |
|---|---|---|
| Infinite redirect loop at login | `KC_HOSTNAME` doesn't match the browser URL, or proxy headers not trusted | Set `KC_HOSTNAME=https://<DOMAIN>` (full URL) and `KC_PROXY_HEADERS=xforwarded` |
| Login page loads but CSS/JS 404s | Hostname or relative-path mismatch | Same as above; check `KC_HTTP_RELATIVE_PATH` if you set one |
| "HTTPS required" error | Realm `Require SSL` is on but Keycloak thinks the request is HTTP | `KC_PROXY_HEADERS=xforwarded` |
| Tokens rejected by clients: "issuer mismatch" | `KC_HOSTNAME` changed, or differs between tasks | Make it identical everywhere; clients must refresh discovery |
| User logged in on one request, logged out on the next | Cluster not forming — cache not shared | Check SG rule on 7800 (self-referencing); check `jgroupsping` table |
| Targets never become healthy | Health check pointed at 8080 instead of 9000 | Change target group health check port to 9000 |
| Tasks crash-loop on first deploy | Migration exceeds health-check grace period | Raise `healthCheckGracePeriodSeconds` to 180–300 |
| `ResourceInitializationError ... secretsmanager` | Execution role lacks `GetSecretValue` or `kms:Decrypt` | Fix policy (8.1); note it's the **execution** role, not the task role |
| `CannotPullContainerError` | No route to ECR | Check NAT gateway route, VPC endpoints, and that `assignPublicIp` isn't required |
| DB pool timeouts under load | `pool_max_size × tasks` exceeds `max_connections` | Recompute (3.5); lower pool or resize RDS |
| Exit code 137 | Container OOM-killed | Raise memory; set `-XX:MaxRAMPercentage=70` |
| Slow logins, high DB CPU | Missing index / event table bloat / undersized instance | Performance Insights; set event expiration; resize |
| Password reset emails not arriving | SES sandbox, or SPF/DKIM failing | Move SES out of sandbox; verify DNS records |
| Admin console loads blank | `KC_HOSTNAME_ADMIN` mismatch, or a proxy stripping headers | Align admin hostname config |
| Everything worked, then broke after a deploy | Build-time option set as env var while running `--optimized` | Move it into the Dockerfile and rebuild |

## 10.2 Diagnostic commands

```bash
# Get a shell inside a running task (audited via CloudTrail)
TASK=$(aws ecs list-tasks --cluster kc-prod-cluster \
  --service-name kc-prod-keycloak --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster kc-prod-cluster --task $TASK \
  --container keycloak --interactive --command "/bin/bash"

# Inside the container:
curl -s localhost:9000/health/ready | jq
curl -s localhost:9000/metrics | grep agroal
/opt/keycloak/bin/kc.sh show-config          # what config is actually active

# Verify cluster membership from the database
psql -h <DB_ENDPOINT> -U kcadmin -d keycloak \
  -c "SELECT cluster_name, own_addr FROM jgroupsping;"
# Row count should equal running task count.

# Check the public contract
curl -s https://<DOMAIN>/realms/master/.well-known/openid-configuration | jq '.issuer, .jwks_uri'

# Recent ECS service events (often states the problem in plain English)
aws ecs describe-services --cluster kc-prod-cluster --services kc-prod-keycloak \
  --query 'services[0].events[0:10].[createdAt,message]' --output table
```

## 10.3 Escalation

| Level | When | Contact |
|---|---|---|
| L1 | Alarms 10–15, single-task issues | `<TEAM_CHANNEL>` |
| L2 | Alarms 1–9, cluster or DB issues | `<ONCALL_ROTA>` |
| L3 | Data loss, suspected compromise, failed restore | `<SECURITY_CONTACT>` + AWS Support (Business/Enterprise) |
| Vendor | Suspected Keycloak bug | GitHub issues, or Red Hat support if using Red Hat build of Keycloak |

---

# PART 11 — Terraform skeleton

Directory layout:

```
infrastructure/
├── modules/
│   ├── network/          # VPC, subnets, gateways, endpoints
│   ├── security/         # security groups, KMS keys
│   ├── database/         # RDS, subnet group, parameter group
│   ├── keycloak/         # ECS cluster, task def, service, autoscaling
│   └── edge/             # ALB, ACM, Route 53, WAF
├── envs/
│   ├── dev/  { main.tf, terraform.tfvars, backend.tf }
│   ├── stage/
│   └── prod/
└── README.md
```

`envs/prod/main.tf`:

```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
  backend "s3" {
    bucket       = "acme-tfstate"
    key          = "keycloak/prod/terraform.tfstate"
    region       = "<REGION>"
    encrypt      = true
    use_lockfile = true          # S3-native locking; DynamoDB no longer needed
  }
}

locals {
  project = "kc"
  env     = "prod"
  prefix  = "kc-prod"
  tags = {
    Project     = "keycloak"
    Environment = "prod"
    ManagedBy   = "terraform"
    Owner       = "<TEAM_NAME>"
    CostCenter  = "<CC>"
    DataClass   = "confidential"
  }
}

module "network" {
  source             = "../../modules/network"
  prefix             = local.prefix
  cidr               = "10.40.0.0/16"
  az_count           = 3
  nat_gateway_per_az = true
  tags               = local.tags
}

module "security" {
  source = "../../modules/security"
  prefix = local.prefix
  vpc_id = module.network.vpc_id
  tags   = local.tags
}

module "database" {
  source                  = "../../modules/database"
  prefix                  = local.prefix
  subnet_ids              = module.network.data_subnet_ids
  security_group_ids      = [module.security.db_sg_id]
  engine_version          = "17.4"
  instance_class          = "db.m6g.large"
  allocated_storage       = 100
  max_allocated_storage   = 500
  multi_az                = true
  backup_retention_period = 30
  deletion_protection     = true
  kms_key_arn             = module.security.rds_kms_key_arn
  tags                    = local.tags
}

module "edge" {
  source          = "../../modules/edge"
  prefix          = local.prefix
  vpc_id          = module.network.vpc_id
  public_subnets  = module.network.public_subnet_ids
  domain_name     = "<DOMAIN>"
  hosted_zone_id  = "<ZONE_ID>"
  alb_sg_id       = module.security.alb_sg_id
  health_check_port = 9000
  health_check_path = "/health/ready"
  enable_waf      = true
  tags            = local.tags
}

module "keycloak" {
  source              = "../../modules/keycloak"
  prefix              = local.prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.app_subnet_ids
  security_group_ids  = [module.security.task_sg_id]
  target_group_arn    = module.edge.target_group_arn

  image               = "<AWS_ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/kc/keycloak:26.7.0-1"
  cpu                 = 2048
  memory              = 4096
  desired_count       = 3
  min_capacity        = 3
  max_capacity        = 12

  hostname            = "https://<DOMAIN>"
  db_url              = "jdbc:postgresql://${module.database.endpoint}:5432/keycloak?ssl=true&sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem"
  db_secret_arn       = module.database.master_secret_arn
  bootstrap_admin_secret_arn = aws_secretsmanager_secret.bootstrap_admin.arn

  log_retention_days  = 90
  tags                = local.tags
}

output "keycloak_url" {
  value = "https://<DOMAIN>"
}

output "db_endpoint" {
  value     = module.database.endpoint
  sensitive = true
}
```

**Terraform practices for this stack:**

- **Never** put passwords in variables or state. Use `--manage-master-user-password` on RDS (creates the secret outside Terraform) and reference secrets by ARN.
- Use `ignore_changes = [desired_count]` on the ECS service so autoscaling and Terraform don't fight.
- Use `lifecycle { prevent_destroy = true }` on the RDS instance and KMS keys.
- Separate state files per environment. One blast radius per apply.
- Run `terraform plan` in CI on every PR and require review before apply.

---

# PART 12 — Cost

Illustrative monthly figures for a `prod` environment in a US region, on-demand pricing, July 2026. **Verify with the AWS Pricing Calculator** — prices change and vary by region.

| Component | Configuration | ~USD / month |
|---|---|---|
| ECS Fargate | 3 tasks × 2 vCPU / 4 GB, 24×7 | 180 |
| RDS PostgreSQL | `db.m6g.large` Multi-AZ | 340 |
| RDS storage | 100 GB gp3 Multi-AZ | 30 |
| RDS backups | 100 GB beyond free tier | 10 |
| ALB | 1 ALB + modest LCU usage | 25 |
| NAT Gateways | 3 × $0.045/hr + data | 105 |
| VPC endpoints | 5 interface endpoints × 3 AZs | 110 |
| CloudWatch | logs + metrics + alarms | 40 |
| Secrets Manager | 2 secrets + API calls | 2 |
| KMS | 4 CMKs + requests | 6 |
| WAF | Web ACL + rules + requests | 25 |
| Route 53 | hosted zone + queries | 2 |
| ECR | ~10 GB storage | 1 |
| Data transfer | modest | 20 |
| **Total (prod)** | | **~$900** |

**Where the money actually goes:** RDS Multi-AZ and the networking layer (NAT + endpoints) together are over half the bill, and neither is the application.

**Cost reduction options, in order of value:**

| Change | Saving | Trade-off |
|---|---|---|
| Compute Savings Plan (1yr) on Fargate | ~20–30% of compute | Commitment |
| RDS Reserved Instance (1yr) | ~30–40% of RDS | Commitment |
| Single NAT gateway | ~$70 | AZ failure kills egress |
| Drop interface endpoints, use NAT | ~$110 minus extra NAT data | Traffic leaves the VPC; slightly weaker posture |
| Graviton everywhere (already applied) | ~20% | None meaningful |
| dev/stage: single-AZ, `db.t4g.micro`, 1 task, scheduled shutdown | ~$700 across both | Not production-representative |
| Fargate Spot for dev/stage | ~70% of that compute | Interruptions — never for prod |

**Non-prod scheduling:** stopping dev and stage outside working hours (ECS desired-count 0, RDS stopped — note RDS auto-starts after 7 days) typically saves 60–70% on those environments.

---

# PART 13 — Appendices

## A. Environment variable quick card

```bash
# --- Database ---
KC_DB=postgres                          # build-time
KC_DB_URL=jdbc:postgresql://HOST:5432/keycloak?ssl=true&sslmode=verify-full&sslrootcert=/opt/keycloak/conf/rds-ca.pem
KC_DB_USERNAME=<secret>
KC_DB_PASSWORD=<secret>
KC_DB_POOL_INITIAL_SIZE=5
KC_DB_POOL_MIN_SIZE=5
KC_DB_POOL_MAX_SIZE=20

# --- Hostname (v2 syntax, Keycloak 26+) ---
KC_HOSTNAME=https://auth.example.com    # FULL URL
KC_HOSTNAME_STRICT=true

# --- Proxy ---
KC_HTTP_ENABLED=true
KC_PROXY_HEADERS=xforwarded

# --- Cluster ---
KC_CACHE=ispn                           # build-time
KC_CACHE_STACK=jdbc-ping                # build-time; default in KC 26

# --- Observability ---
KC_HEALTH_ENABLED=true                  # build-time
KC_METRICS_ENABLED=true                 # build-time
KC_LOG=console
KC_LOG_CONSOLE_OUTPUT=json
KC_LOG_LEVEL=info

# --- Bootstrap (first start only) ---
KC_BOOTSTRAP_ADMIN_USERNAME=<secret>
KC_BOOTSTRAP_ADMIN_PASSWORD=<secret>

# --- JVM ---
JAVA_OPTS_APPEND=-XX:MaxRAMPercentage=70

# --- Start command ---
kc.sh start --optimized
```

## B. Migration notes for older Keycloak versions

If you inherit a deployment written against Keycloak 22–25, these are the breaking changes you'll hit:

| Old | New (26.x) |
|---|---|
| `KC_PROXY=edge` | **Removed.** Use `KC_PROXY_HEADERS=xforwarded` |
| `KC_HOSTNAME=auth.example.com` | Now a full URL: `https://auth.example.com` |
| `KC_HOSTNAME_URL`, `_PORT`, `_PATH`, `_STRICT_BACKCHANNEL` | Removed in hostname v2 |
| `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` | `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` |
| Health on `:8080/health` | Management interface on `:9000/health` (since 25) |
| Custom `cache-ispn-jdbc-ping.xml` | `KC_CACHE_STACK=jdbc-ping` is built in and default |
| In-memory sessions | Persistent user sessions in the database by default |
| PostgreSQL 12 | Minimum PostgreSQL 13 from Keycloak 26.4 |

## C. Glossary

| Term | Definition |
|---|---|
| **AZ** | Availability Zone — an isolated data centre within an AWS region |
| **Agroal** | The JDBC connection pool Keycloak uses; prefix of its metrics |
| **CIDR** | Notation for an IP range, e.g. `10.40.0.0/16` |
| **ENI** | Elastic Network Interface — a virtual NIC; each Fargate task gets one |
| **Infinispan** | The distributed in-memory cache Keycloak uses for sessions |
| **JGroups** | The clustering/messaging library Infinispan uses; `jdbc-ping` is a JGroups discovery protocol |
| **JWKS** | JSON Web Key Set — the public keys clients use to verify token signatures |
| **Liquibase** | The tool Keycloak uses to create and migrate its database schema |
| **OIDC** | OpenID Connect — the identity layer on top of OAuth 2.0 |
| **PITR** | Point-in-time recovery |
| **PKCE** | Proof Key for Code Exchange — protects public clients from code interception |
| **Quarkus** | The Java framework Keycloak has been built on since v17 |
| **RTO / RPO** | Recovery Time Objective (how long until restored) / Recovery Point Objective (how much data you can lose) |
| **SAML** | An older XML-based federation protocol, still widely used by enterprise software |
| **SPI** | Service Provider Interface — Keycloak's extension mechanism |

## D. Reference links

| Topic | URL |
|---|---|
| Keycloak server configuration | https://www.keycloak.org/server/configuration |
| All configuration options | https://www.keycloak.org/server/all-config |
| Hostname configuration | https://www.keycloak.org/server/hostname |
| Reverse proxy setup | https://www.keycloak.org/server/reverseproxy |
| Health checks | https://www.keycloak.org/observability/health |
| Clustering / caching | https://www.keycloak.org/server/caching |
| Upgrading guide | https://www.keycloak.org/docs/latest/upgrading/ |
| Release notes | https://www.keycloak.org/docs/latest/release_notes/ |
| Container image | https://quay.io/repository/keycloak/keycloak |
| RDS PostgreSQL user guide | https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html |
| ECS best practices | https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/ |
| AWS Well-Architected | https://aws.amazon.com/architecture/well-architected/ |

## E. Document maintenance

This document is only useful if it stays true.

| Trigger | Update |
|---|---|
| Any infrastructure change | The affected Part, in the same PR as the Terraform change |
| Keycloak version upgrade | Header, Part 4, Appendix B |
| New alarm or runbook | Parts 8 and 9 |
| Incident post-mortem | Part 10, with the new symptom and fix |
| Quarterly review | Everything — confirm commands still run and links still resolve |

**Review log**

| Date | Reviewer | Change |
|---|---|---|
| 2026-07-27 | | Initial version — Keycloak 26.7, PostgreSQL 17 |
| | | |
