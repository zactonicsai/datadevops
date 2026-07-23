# Running Keycloak on an AWS Auto Scaling Group (2 Instances)

A complete, beginner-friendly guide using the official Keycloak Docker image.

---

## Part 0: What Are We Even Building?

Imagine your school has a single hall pass system. Instead of every teacher keeping their own list of who is allowed where, there is **one office** that checks your ID and hands out passes. Every teacher just trusts the pass.

**Keycloak is that office.** It is an open-source "identity provider." Apps send users to Keycloak to log in, Keycloak checks the password (or Google login, or a company directory), and then hands the app a signed digital pass called a **token**.

### Why not just one server?

If the office has one clerk and that clerk goes home sick, nobody gets a pass. Nobody logs in. Your whole company stops.

So we run **two clerks** (two servers). If one dies, the other keeps working. AWS **Auto Scaling Group (ASG)** is the manager that makes sure exactly two clerks are always on duty — if one quits, it hires a replacement automatically.

### The pieces we will build

| Piece | Real-world job | AWS service |
|---|---|---|
| The front desk that splits traffic | Sends users to whichever clerk is free | Application Load Balancer (ALB) |
| The two clerks | Actually run Keycloak | EC2 instances in an ASG |
| The filing cabinet | Stores users, passwords, settings | RDS PostgreSQL |
| The hiring rulebook | "Always keep 2 clerks, here's how to train them" | Launch Template + ASG |
| The ID badge | Proves the website is really yours (HTTPS) | ACM certificate |

> **Critical concept:** The two Keycloak servers do **not** each have their own database. They **share one database**. That is what makes them interchangeable. A user created on Server A instantly exists on Server B, because both are reading the same filing cabinet.

### Architecture diagram (text version)

```
                    Internet
                       |
                  [Route 53 DNS]
                  auth.example.com
                       |
              [Application Load Balancer]  <- public subnets
                   HTTPS :443
                    /         \
                   /           \
        [EC2 #1 Keycloak]   [EC2 #2 Keycloak]  <- private subnets
             :8080               :8080          (Auto Scaling Group, min=2)
                   \             /
                    \           /
                  [RDS PostgreSQL]           <- private subnets
                    Multi-AZ, :5432
```

---

## Part 1: Prerequisites — Get These Ready First

Do not skip this. Missing one of these is the #1 reason people get stuck.

### 1.1 Accounts and access

- **An AWS account** with billing enabled. This setup costs roughly **$90–150/month** in `us-east-1` (2× t3.medium ≈ $60, RDS db.t3.small Multi-AZ ≈ $50, ALB ≈ $18). Use the AWS Pricing Calculator for your region.
- **An IAM user or role** with permissions for: EC2, Auto Scaling, Elastic Load Balancing, RDS, Secrets Manager, ACM, Route 53, CloudWatch Logs, and IAM (to create roles).
- **AWS CLI v2 installed and configured.** Test it:

  ```bash
  aws sts get-caller-identity
  ```

  If that prints your account number, you are good. If not, run `aws configure`.

### 1.2 Networking (VPC)

You need a VPC spanning **at least two Availability Zones**. An AZ is a separate data center building. Two AZs means a fire in one building does not take you down.

You need **four subnets minimum**:

| Subnet type | Count | What goes here | Internet access |
|---|---|---|---|
| Public | 2 (one per AZ) | Load balancer | Yes, via Internet Gateway |
| Private | 2 (one per AZ) | EC2 instances + RDS | Outbound only, via NAT Gateway |

> **Why private subnets for Keycloak?** So nobody on the internet can reach your servers directly. All traffic must go through the load balancer, which is the only public door.

> **NAT Gateway warning:** A NAT Gateway costs about **$32/month plus data charges**. It is needed so your private instances can download the Docker image. If you are just testing and want to save money, you can put the instances in public subnets with public IPs instead — but never do this in production.

The default VPC in a new AWS account already has public subnets in multiple AZs, which works for a test run.

### 1.3 A domain name

Keycloak **strongly prefers HTTPS**. Modern versions will refuse to serve the admin console over plain HTTP from a remote address. You need:

- A domain you control (e.g., `example.com`), ideally in Route 53.
- A subdomain planned for Keycloak, e.g., `auth.example.com`.
- An **ACM certificate** for that name (free, and auto-renewing).

Request the certificate now, because DNS validation takes a few minutes:

```bash
aws acm request-certificate \
  --domain-name auth.example.com \
  --validation-method DNS \
  --region us-east-1
```

Then go to **ACM → your certificate → Create records in Route 53** to finish validation. Wait until status is **Issued**.

> **Region gotcha:** The certificate must be in the **same region** as your ALB.

### 1.4 An EC2 key pair (optional but recommended)

For SSH debugging. Better still, use **AWS Systems Manager Session Manager**, which needs no key and no open SSH port. This guide uses SSM.

### 1.5 Decide your version

Check the current stable tag at `quay.io/keycloak/keycloak`. **Never use `:latest`** — a surprise upgrade at 3 a.m. will ruin your week. Pin an exact version like `26.0.7`. Throughout this guide, substitute your chosen version wherever you see `KC_VERSION`.

---

## Part 2: The Step-by-Step Setup (Follow Along)

We will build one working example end to end. Explanations for *why* come in Part 3.

Set these shell variables first so you can copy-paste the rest:

```bash
export AWS_REGION=us-east-1
export VPC_ID=vpc-xxxxxxxx
export PRIVATE_SUBNET_1=subnet-aaaaaaa
export PRIVATE_SUBNET_2=subnet-bbbbbbb
export PUBLIC_SUBNET_1=subnet-ccccccc
export PUBLIC_SUBNET_2=subnet-ddddddd
export CERT_ARN=arn:aws:acm:us-east-1:123456789012:certificate/xxxx
export KC_VERSION=26.0.7
export DOMAIN=auth.example.com
```

---

### Step 1: Create the Security Groups

A **security group** is a firewall. Think of it as a bouncer with a guest list. We create three, and they reference each other so only the right traffic flows.

```bash
# 1. Load balancer SG — open to the world on 443
ALB_SG=$(aws ec2 create-security-group \
  --group-name keycloak-alb-sg \
  --description "Keycloak ALB" \
  --vpc-id $VPC_ID --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

# 2. Instance SG — only accepts traffic FROM the ALB
APP_SG=$(aws ec2 create-security-group \
  --group-name keycloak-app-sg \
  --description "Keycloak instances" \
  --vpc-id $VPC_ID --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG

# Cluster gossip between the two Keycloak nodes (JGroups)
aws ec2 authorize-security-group-ingress --group-id $APP_SG \
  --protocol tcp --port 7800 --source-group $APP_SG

# 3. Database SG — only accepts traffic FROM the instances
DB_SG=$(aws ec2 create-security-group \
  --group-name keycloak-db-sg \
  --description "Keycloak RDS" \
  --vpc-id $VPC_ID --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id $DB_SG \
  --protocol tcp --port 5432 --source-group $APP_SG

echo "ALB_SG=$ALB_SG APP_SG=$APP_SG DB_SG=$DB_SG"
```

**What just happened:** We built a chain. The internet can only talk to the ALB. The ALB can only talk to the instances. The instances can only talk to the database. Nobody can skip a link.

> **Best practice:** Notice we used `--source-group` instead of IP ranges. This means "allow anything wearing this badge," which keeps working even when instances are replaced and get new IPs.

Save these three IDs. You will need them repeatedly.

---

### Step 2: Create the Database (RDS PostgreSQL)

First, generate a strong password and store it in **Secrets Manager** — never type passwords into user data scripts.

```bash
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

aws secretsmanager create-secret \
  --name keycloak/db-password \
  --secret-string "$DB_PASSWORD" \
  --region $AWS_REGION
```

Also create a temporary admin password for the Keycloak console:

```bash
KC_ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

aws secretsmanager create-secret \
  --name keycloak/admin-password \
  --secret-string "$KC_ADMIN_PASSWORD" \
  --region $AWS_REGION
```

Now the DB subnet group and the database:

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name keycloak-db-subnets \
  --db-subnet-group-description "Keycloak DB" \
  --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2

aws rds create-db-instance \
  --db-instance-identifier keycloak-db \
  --db-instance-class db.t3.small \
  --engine postgres \
  --engine-version 16.4 \
  --allocated-storage 20 \
  --storage-type gp3 \
  --storage-encrypted \
  --master-username keycloak \
  --master-user-password "$DB_PASSWORD" \
  --db-name keycloak \
  --vpc-security-group-ids $DB_SG \
  --db-subnet-group-name keycloak-db-subnets \
  --multi-az \
  --backup-retention-period 7 \
  --no-publicly-accessible
```

This takes **10–15 minutes**. Multi-AZ means AWS keeps a hot standby copy in the other building and fails over automatically.

Get the endpoint when it is ready:

```bash
aws rds wait db-instance-available --db-instance-identifier keycloak-db

DB_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier keycloak-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo $DB_HOST
```

> **Why PostgreSQL?** Keycloak officially supports PostgreSQL, MySQL/MariaDB, Oracle, and SQL Server. PostgreSQL is the most commonly tested and the default choice in Keycloak's own docs.

> **Never use the embedded H2 database.** Keycloak's dev mode ships with H2 stored on local disk. Each instance would have its own separate copy, users would randomly disappear depending on which server answered, and everything is lost when an instance is replaced.

---

### Step 3: Create the IAM Role for the Instances

The instances need permission to read the secrets and to be managed by SSM.

```bash
cat > trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role --role-name keycloak-instance-role \
  --assume-role-policy-document file://trust-policy.json

# Managed policies for SSM access and CloudWatch logs
aws iam attach-role-policy --role-name keycloak-instance-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam attach-role-policy --role-name keycloak-instance-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

Now a narrow policy for just our two secrets. Replace `ACCOUNT_ID`:

```bash
cat > secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": [
      "arn:aws:secretsmanager:${AWS_REGION}:ACCOUNT_ID:secret:keycloak/db-password-*",
      "arn:aws:secretsmanager:${AWS_REGION}:ACCOUNT_ID:secret:keycloak/admin-password-*"
    ]
  }]
}
EOF

aws iam put-role-policy --role-name keycloak-instance-role \
  --policy-name keycloak-secrets-read \
  --policy-document file://secrets-policy.json

aws iam create-instance-profile --instance-profile-name keycloak-instance-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name keycloak-instance-profile \
  --role-name keycloak-instance-role
```

> **Best practice:** Notice the policy names two specific secrets, not `"Resource": "*"`. This is **least privilege** — give exactly the access needed and nothing more. If someone breaks into the instance, they cannot read your other secrets.

---

### Step 4: Write the User Data Script

**User data** is a script AWS runs automatically the very first time an instance boots. It is how a blank server turns itself into a Keycloak server with no human involved. This is the heart of the whole setup, so let us go through it carefully.

Create `user-data.sh`:

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

########################################
# CONFIGURATION — edit these
########################################
KC_VERSION="26.0.7"
DB_HOST="REPLACE_WITH_RDS_ENDPOINT"
DB_NAME="keycloak"
DB_USER="keycloak"
AWS_REGION="us-east-1"
KC_HOSTNAME="auth.example.com"

########################################
# 1. Install Docker
########################################
dnf update -y
dnf install -y docker awscli jq
systemctl enable --now docker

########################################
# 2. Fetch secrets from Secrets Manager
########################################
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id keycloak/db-password \
  --region "$AWS_REGION" \
  --query SecretString --output text)

KC_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id keycloak/admin-password \
  --region "$AWS_REGION" \
  --query SecretString --output text)

########################################
# 3. Find this instance's private IP
#    (needed for cluster communication)
########################################
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

########################################
# 4. Wait for the database to accept connections
########################################
for i in $(seq 1 30); do
  if timeout 3 bash -c "</dev/tcp/${DB_HOST}/5432" 2>/dev/null; then
    echo "Database reachable"; break
  fi
  echo "Waiting for database... attempt $i"; sleep 10
done

########################################
# 5. Run Keycloak
########################################
docker run -d \
  --name keycloak \
  --restart unless-stopped \
  --network host \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}" \
  -e KC_DB_USERNAME="${DB_USER}" \
  -e KC_DB_PASSWORD="${DB_PASSWORD}" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}" \
  -e KC_HOSTNAME="https://${KC_HOSTNAME}" \
  -e KC_HTTP_ENABLED=true \
  -e KC_HTTP_PORT=8080 \
  -e KC_PROXY_HEADERS=xforwarded \
  -e KC_HEALTH_ENABLED=true \
  -e KC_METRICS_ENABLED=true \
  -e KC_CACHE=ispn \
  -e KC_CACHE_STACK=tcp \
  -e JAVA_OPTS_APPEND="-Djgroups.bind.address=${PRIVATE_IP} -Xms512m -Xmx1536m" \
  "quay.io/keycloak/keycloak:${KC_VERSION}" \
  start --optimized=false

echo "User data script finished"
```

#### Line-by-line: what every part does

**`set -euxo pipefail`** — Four safety switches. `-e` stops on the first error instead of blundering forward. `-u` errors on undefined variables (catches typos). `-x` prints each command as it runs. `pipefail` catches errors in the middle of a pipe. Without these, a failed step is silent and you get a mysteriously broken server.

**`exec > >(tee /var/log/user-data.log …)`** — Copies all output to a log file. When something breaks, this file is your first stop. Read it with SSM:

```bash
aws ssm start-session --target i-xxxxxxxx
sudo cat /var/log/user-data.log
```

**Fetching secrets from Secrets Manager** — The password is never written in the user data itself. This matters because **user data is not secret**: anyone with `ec2:DescribeInstanceAttribute` permission, or anyone who gets a shell on the box, can read it with a single curl to the metadata service. Secrets Manager keeps the password behind an IAM permission check and lets you rotate it later without editing the launch template.

**The instance metadata token (IMDSv2)** — The two-step `PUT` then `GET` is the modern, secure way to read metadata. The old one-step version (IMDSv1) was vulnerable to a trick where an attacker makes your app fetch the metadata URL on their behalf. Always use v2.

**The database wait loop** — On a cold start, RDS might still be booting. Without this loop, Keycloak starts, fails to connect, and the container exits. The loop retries for up to five minutes.

Now the Keycloak environment variables — the most important part:

| Variable | Plain-English meaning |
|---|---|
| `KC_DB=postgres` | Use PostgreSQL, not the built-in toy database |
| `KC_DB_URL` | The address of the shared filing cabinet |
| `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` | Creates the first admin account on first boot only |
| `KC_HOSTNAME=https://auth.example.com` | The public address. Keycloak stamps this into tokens and login links |
| `KC_HTTP_ENABLED=true` | Allow plain HTTP **on the private network only** — the ALB handles the real HTTPS |
| `KC_PROXY_HEADERS=xforwarded` | "Trust the `X-Forwarded-*` headers from the load balancer" |
| `KC_HEALTH_ENABLED=true` | Turns on `/health/ready`, which the ALB uses to check if the server is alive |
| `KC_CACHE=ispn` + `KC_CACHE_STACK=tcp` | Turn on clustering so the two servers share login sessions |
| `-Djgroups.bind.address` | Tells the clustering system which network address to use |
| `-Xms512m -Xmx1536m` | Java memory limits. Keep max **below** the instance RAM or Linux will kill the process |

> **The `KC_PROXY_HEADERS` trap.** The ALB terminates HTTPS and forwards plain HTTP to your instance. Without this setting, Keycloak thinks the user arrived over insecure HTTP and generates redirect URLs starting with `http://`. Users get redirect loops, or the browser blocks mixed content. This one line fixes the single most common Keycloak-behind-a-load-balancer bug.

> **The `--network host` choice.** Clustering (JGroups) needs each node to advertise a real, reachable IP. With Docker's default bridge network, the container advertises an internal `172.17.x.x` address that the other instance cannot reach, and clustering silently fails. Host networking avoids that. The tradeoff is slightly less container isolation — acceptable here since the only thing on the instance is Keycloak.

> **`start` vs `start-dev`.** Never use `start-dev` outside your laptop. It enables the H2 database, disables HTTPS requirements, and turns off caching. It is a development toy.

> **What is `--optimized=false`?** Keycloak can pre-build an optimized image where configuration is baked in, making startup much faster. With `--optimized=false`, it does that build work at every startup, adding roughly 30–60 seconds. For production, see the custom image option in Part 3.

---

### Step 5: Create the Launch Template

A **launch template** is the recipe card. It tells the ASG exactly how to build each instance.

```bash
# Fill in the real values, then base64-encode
sed -i "s|REPLACE_WITH_RDS_ENDPOINT|$DB_HOST|" user-data.sh
sed -i "s|auth.example.com|$DOMAIN|" user-data.sh
USER_DATA_B64=$(base64 -w0 user-data.sh)

# Latest Amazon Linux 2023 AMI
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

aws ec2 create-launch-template \
  --launch-template-name keycloak-lt \
  --version-description v1 \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"t3.medium\",
    \"IamInstanceProfile\": {\"Name\": \"keycloak-instance-profile\"},
    \"SecurityGroupIds\": [\"$APP_SG\"],
    \"UserData\": \"$USER_DATA_B64\",
    \"MetadataOptions\": {\"HttpTokens\": \"required\", \"HttpPutResponseHopLimit\": 2},
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {\"VolumeSize\": 20, \"VolumeType\": \"gp3\", \"Encrypted\": true}
    }],
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"keycloak\"}]
    }]
  }"
```

**Key settings explained:**

- **`t3.medium`** — 2 vCPU, 4 GB RAM. Keycloak is a Java app and 2 GB is uncomfortably tight. Do not go smaller.
- **`HttpTokens: required`** — Forces IMDSv2. Blocks the metadata-theft attack class entirely.
- **`HttpPutResponseHopLimit: 2`** — Containers are one network hop away from the host. The default of 1 blocks them from reading metadata. This is a classic gotcha.
- **`Encrypted: true`** — Disk encryption at rest, free and no reason to skip.

> **Best practice: version your templates.** Launch templates are immutable and versioned. Never edit in place — create version 2, test it on one instance, then update the ASG. This gives you a one-command rollback.

---

### Step 6: Create the Load Balancer and Target Group

```bash
# Target group — the list of healthy backends
TG_ARN=$(aws elbv2 create-target-group \
  --name keycloak-tg \
  --protocol HTTP --port 8080 \
  --vpc-id $VPC_ID \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path /health/ready \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Sticky sessions
aws elbv2 modify-target-group-attributes \
  --target-group-arn $TG_ARN \
  --attributes \
    Key=stickiness.enabled,Value=true \
    Key=stickiness.type,Value=lb_cookie \
    Key=stickiness.lb_cookie.duration_seconds,Value=3600 \
    Key=deregistration_delay.timeout_seconds,Value=60

# The load balancer itself
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name keycloak-alb \
  --subnets $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 \
  --security-groups $ALB_SG \
  --scheme internet-facing --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# HTTPS listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn=$CERT_ARN \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# HTTP listener that just redirects to HTTPS
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions '{"Type":"redirect","RedirectConfig":{"Protocol":"HTTPS","Port":"443","StatusCode":"HTTP_301"}}'
```

**Health check explained:** Every 30 seconds the ALB asks each instance "are you ready?" at `/health/ready`. Two good answers in a row and the instance starts receiving traffic. Three bad answers and it is cut off. This is what makes failure invisible to users.

> **Why `/health/ready` and not `/`?** The root path returns a redirect, which the ALB may interpret as unhealthy. `/health/ready` returns a proper 200 and — importantly — only after Keycloak has actually connected to the database. It is a *real* readiness signal.

> **Why sticky sessions?** The login flow is multi-step: show form → submit password → maybe do 2FA → redirect back. Keycloak's cluster does replicate this state, but keeping one user on one server during login is faster and avoids edge cases. The cookie expires after an hour.

> **`deregistration_delay`** — When an instance is being removed, the ALB waits 60 seconds for in-flight requests to finish instead of cutting them off mid-login. The default 300 seconds makes deployments feel slow.

---

### Step 7: Create the Auto Scaling Group

This is the manager that keeps exactly two servers running.

```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name keycloak-asg \
  --launch-template LaunchTemplateName=keycloak-lt,Version='$Latest' \
  --min-size 2 --max-size 4 --desired-capacity 2 \
  --vpc-zone-identifier "$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --default-instance-warmup 300 \
  --tags "Key=Name,Value=keycloak,PropagateAtLaunch=true"
```

**Each setting decoded:**

- **`min-size 2`** — The promise. Never fewer than two, ever. If one dies, a replacement launches within seconds.
- **`max-size 4`** — Room to grow under load without runaway costs.
- **`vpc-zone-identifier` with two subnets** — The ASG spreads instances across AZs automatically. Instance 1 in AZ-a, instance 2 in AZ-b. A whole data center can fail and you survive.
- **`health-check-type ELB`** — This is subtle but crucial. The default (`EC2`) only checks whether the virtual machine is powered on. If Keycloak crashes but Linux keeps running, EC2 checks say "fine!" while users see errors. `ELB` means the ASG trusts the load balancer's application-level health check and replaces genuinely broken instances.
- **`health-check-grace-period 300`** — Give a new instance five minutes to install Docker, pull the image, and start Java before judging it. Too short and you get an infinite loop of instances being killed during startup.

Watch it come to life:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names keycloak-asg \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]' \
  --output table
```

---

### Step 8: Point DNS at the Load Balancer

```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

ALB_ZONE=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

cat > dns.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${DOMAIN}",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ALB_ZONE}",
        "DNSName": "${ALB_DNS}",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_ZONE_ID \
  --change-batch file://dns.json
```

An **alias record** is Route 53's special pointer to AWS resources. It is free and updates automatically if the ALB's IPs change.

---

### Step 9: Verify Everything Works

**Check target health** — both should say `healthy` after ~5 minutes:

```bash
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' --output table
```

**Check HTTPS responds:**

```bash
curl -I https://$DOMAIN/
```

**Log in.** Open `https://auth.example.com/admin` in a browser. Username `admin`, password from Secrets Manager:

```bash
aws secretsmanager get-secret-value --secret-id keycloak/admin-password \
  --query SecretString --output text
```

**The real test — prove failover works:**

1. Log in to the admin console.
2. Terminate one instance:
   ```bash
   aws ec2 terminate-instances --instance-ids i-xxxxxxxx
   ```
3. Refresh the browser. **You should still be logged in.**
4. Watch the ASG launch a replacement:
   ```bash
   watch -n 10 'aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names keycloak-asg \
     --query "AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState]" --output table'
   ```

If your session survived, clustering and the shared database are both working correctly. **This is the moment you know you built it right.**

---

## Part 3: Deeper Background and Options

### 3.1 Why Docker at all?

| Approach | Pros | Cons |
|---|---|---|
| **Docker image** (this guide) | Same image everywhere; version pinned by tag; no Java install; simple rollback | Extra Docker layer; slower cold start |
| **Bare install** (unzip Keycloak) | One less layer; marginally faster | Must manage Java; harder reproducibility |
| **Custom AMI** (bake with Packer) | Fastest boot (~60s), no download at startup | Rebuild pipeline needed for every update |
| **EKS / ECS** | Best orchestration, rolling updates built in | Much steeper learning curve and cost |

For two instances, Docker on EC2 is the sweet spot. If you grow past ~10 nodes, look at EKS with the Keycloak Operator.

### 3.2 The optimized custom image (recommended for production)

Instead of `--optimized=false` doing build work at every boot, bake the config in once:

```dockerfile
FROM quay.io/keycloak/keycloak:26.0.7 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_CACHE=ispn
ENV KC_CACHE_STACK=tcp
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.0.7
COPY --from=builder /opt/keycloak/ /opt/keycloak/
ENTRYPOINT ["/opt/keycloak/bin/kc.sh", "start", "--optimized"]
```

Push to **Amazon ECR**, then change the user data to pull your image and drop the build-time variables. Startup drops from ~90 seconds to ~25.

> **The rule:** Build-time options (`KC_DB`, `KC_HEALTH_ENABLED`, `KC_CACHE`) go in the Dockerfile. Runtime options (`KC_DB_URL`, passwords, `KC_HOSTNAME`) stay as environment variables — they change per environment.

### 3.3 How clustering actually works

Keycloak uses **Infinispan**, a distributed cache. When you log in, a session object is created and replicated so any node can serve you.

Nodes find each other via **JGroups**. Our `KC_CACHE_STACK=tcp` uses TCPPING, which needs to know peer addresses. In an ASG, IPs change constantly, so the robust option is the **JDBC_PING** discovery protocol: nodes write their address into a database table and read each other's entries. Since we already have a shared database, this works perfectly with no extra infrastructure.

To enable it, add a cache config file to your custom image and set `KC_CACHE_CONFIG_FILE`. Check the Keycloak clustering documentation for the current XML for your version — this detail changes between releases.

> **Alternative: skip clustering entirely.** Set `KC_CACHE=local` and rely on sticky sessions. Simpler, but if a node dies its users are logged out. Fine for internal tools, not for customer-facing login.

### 3.4 Scaling policies

Keycloak is CPU-bound during login (password hashing is deliberately slow). Scale on CPU:

```bash
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name keycloak-asg \
  --policy-name keycloak-cpu-target \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {"PredefinedMetricType": "ASGAverageCPUUtilization"},
    "TargetValue": 60.0
  }'
```

> **Do not scale on request count.** A logged-in user validating a token is nearly free; a user typing a password costs 100× more CPU. Request count would mislead you badly.

### 3.5 Rolling out updates safely

To upgrade the Keycloak version:

1. Create launch template **version 2** with the new tag.
2. Trigger an instance refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name keycloak-asg \
  --preferences '{"MinHealthyPercentage": 100, "InstanceWarmup": 300}'
```

`MinHealthyPercentage: 100` means AWS launches the new instance **before** removing the old one — zero downtime.

> **Before any major version upgrade: snapshot the database.** Keycloak runs schema migrations on startup and they are not reversible. `aws rds create-db-snapshot --db-instance-identifier keycloak-db --db-snapshot-identifier pre-upgrade-$(date +%F)`

### 3.6 Security checklist

- [ ] Rotate the bootstrap admin password immediately after first login, and create named admin accounts instead of sharing one.
- [ ] Enable MFA on all admin accounts (Authentication → Required Actions → Configure OTP).
- [ ] Restrict the admin console: create an ALB listener rule allowing `/admin/*` only from your office IP range.
- [ ] Set `KC_HOSTNAME_ADMIN` to a separate internal hostname if you want the admin console fully off the public internet.
- [ ] Turn on ALB access logs to S3, and enable AWS WAF with rate-based rules to blunt credential-stuffing attacks.
- [ ] Enable RDS deletion protection: `aws rds modify-db-instance --db-instance-identifier keycloak-db --deletion-protection`
- [ ] Set up automatic rotation for the DB password in Secrets Manager.

### 3.7 Logging and monitoring

Ship container logs to CloudWatch by adding to the `docker run` command:

```
--log-driver=awslogs \
--log-opt awslogs-region=us-east-1 \
--log-opt awslogs-group=/keycloak/app \
--log-opt awslogs-create-group=true
```

Alarms worth creating: unhealthy target count > 0, RDS CPU > 80%, RDS free storage < 5 GB, ALB 5xx rate spike, ASG instances in service < 2.

Keycloak also exposes Prometheus metrics at `/metrics` when `KC_METRICS_ENABLED=true`.

---

## Part 4: Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Targets stuck `unhealthy` | Keycloak not started, or wrong health path | SSM in, `docker logs keycloak`, check `/var/log/user-data.log` |
| Redirect loop on login | Missing `KC_PROXY_HEADERS=xforwarded` | Add it and refresh instances |
| "HTTPS required" error | `KC_HOSTNAME` not set to the `https://` URL | Fix the variable |
| Container exits immediately | Database unreachable | Check DB security group allows 5432 from app SG |
| Sessions lost when hitting different nodes | Clustering not forming | Verify port 7800 open within app SG; check logs for JGroups view size |
| Can't read secrets in user data | IAM or metadata hop limit | Verify instance profile attached and `HttpPutResponseHopLimit: 2` |
| ASG kills instances in a loop | Grace period too short | Raise `health-check-grace-period` to 300–600 |
| Admin password not working | Bootstrap only applies on an **empty** database | Reset via `kc.sh` inside the container |

**The universal first debugging move:**

```bash
aws ssm start-session --target i-xxxxxxxx
sudo tail -100 /var/log/user-data.log
sudo docker logs --tail 100 keycloak
```

---

## Part 5: Cleanup

Delete in this order to avoid dependency errors:

```bash
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name keycloak-asg --force-delete
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
sleep 60
aws elbv2 delete-target-group --target-group-arn $TG_ARN
aws ec2 delete-launch-template --launch-template-name keycloak-lt
aws rds delete-db-instance --db-instance-identifier keycloak-db --skip-final-snapshot
aws rds delete-db-subnet-group --db-subnet-group-name keycloak-db-subnets
# Security groups last — they have dependencies
aws ec2 delete-security-group --group-id $DB_SG
aws ec2 delete-security-group --group-id $APP_SG
aws ec2 delete-security-group --group-id $ALB_SG
```

Do not forget the NAT Gateway if you created one — it bills whether you use it or not.

---

## Summary

You built a system where:

- **Two servers** share **one database**, so they are interchangeable.
- A **load balancer** hides the servers behind one HTTPS address and only sends traffic to healthy ones.
- An **Auto Scaling Group** guarantees two servers always exist and automatically replaces failures.
- **User data** turns a blank Linux box into a running Keycloak node with zero human steps.
- **Secrets Manager** keeps passwords out of scripts and code.
- Instances live in **private subnets** across **two Availability Zones**.

The single most important idea: **treat servers as disposable.** Any instance can be destroyed at any moment and the system heals itself, because all the valuable state lives in the database, not on the disk.
