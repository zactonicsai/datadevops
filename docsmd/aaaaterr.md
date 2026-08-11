# Terraform + GitLab Pipelines on AWS (EKS Edition)

**A complete, plain-English guide — with Keycloak, Kafka, NiFi, a Java API, and a React web app as the example system.**

Written for Terraform **1.14.x** (or OpenTofu 1.10.x) and GitLab **18.x**, as of July 2026.

---

## Table of contents

1. [What we are building](#1-what-we-are-building)
2. [Background: the words you need to know](#2-background-the-words-you-need-to-know)
3. [Step-by-step: your very first working pipeline](#3-step-by-step-your-very-first-working-pipeline)
4. [How to lay out the whole repo (the "layer cake")](#4-how-to-lay-out-the-whole-repo-the-layer-cake)
5. [The full production `.gitlab-ci.yml`](#5-the-full-production-gitlab-ciyml)
6. [Partial apply: changing only some AWS resources](#6-partial-apply-changing-only-some-aws-resources)
7. [Partial destroy: deleting only some AWS resources](#7-partial-destroy-deleting-only-some-aws-resources)
8. [Reconfigure: fixing and moving the backend](#8-reconfigure-fixing-and-moving-the-backend)
9. [The example apps in Terraform](#9-the-example-apps-in-terraform)
10. [Best practices checklist](#10-best-practices-checklist)
11. [Pros and cons of the big choices](#11-pros-and-cons-of-the-big-choices)
12. [Tips, gotchas, and error messages decoded](#12-tips-gotchas-and-error-messages-decoded)
13. [Cheat sheet](#13-cheat-sheet)

---

## 1. What we are building

Imagine a small city. That is your AWS account.

| Part of the city | Real thing | Why it exists |
|---|---|---|
| Roads and land | **VPC**, subnets, NAT gateway | Everything else sits on this |
| Apartment building | **EKS** (Kubernetes) | Runs our containers |
| Front door guard | **Keycloak** | Checks who you are, hands out login tokens |
| Post office | **Kafka** (Amazon MSK) | Apps drop messages here, other apps pick them up |
| Sorting machine | **Apache NiFi** | Moves and reshapes data between systems |
| The shop | **Java API** | Business logic, reads/writes Kafka, checks Keycloak tokens |
| The shop window | **React web app** | What people see in the browser |

Terraform is the **blueprint** for the city. GitLab is the **construction crew** that follows the blueprint automatically.

Here is the whole picture:

```
Browser
   │
   ▼
CloudFront + S3  ────────────►  React web app (static files)
   │  /api/*
   ▼
ALB (AWS Load Balancer)
   │
   ▼
┌──────────────── EKS cluster ────────────────┐
│                                              │
│   Java API pods  ──► Keycloak pods           │
│        │                  │                  │
│        │                  ▼                  │
│        │             RDS Postgres            │
│        ▼                                     │
│   NiFi StatefulSet                           │
│        │                                     │
└────────┼─────────────────────────────────────┘
         ▼
   Amazon MSK (Kafka)
```

---

## 2. Background: the words you need to know

### 2.1 What is Terraform?

Terraform is a tool that reads text files you write and then creates real cloud resources.

You write **what you want**, not **how to make it**. That is called *declarative*.

```hcl
resource "aws_s3_bucket" "web" {
  bucket = "acme-react-web-prod"
}
```

You never tell it "call the AWS API, then wait, then check." You just say "I want this bucket." Terraform figures out the steps.

### 2.2 The three files/ideas that matter most

**1. Configuration (`.tf` files)** — your wish list. This lives in Git.

**2. State (`terraform.tfstate`)** — Terraform's notebook. It writes down "the bucket I made is really called `acme-react-web-prod` and its ID is X." Without the notebook, Terraform forgets everything it built and would try to build it all again.

> ⚠️ **State is the most important thing in this whole guide.** Lose it and you are in trouble. Leak it and you may leak secrets. Protect it like a password.

**3. Providers** — plugins that know how to talk to a specific cloud. `hashicorp/aws` knows AWS. `hashicorp/kubernetes` and `hashicorp/helm` know Kubernetes.

### 2.3 The two commands you will run forever

| Command | What it does | Analogy |
|---|---|---|
| `terraform plan` | Compares your wish list to the real world and prints what it *would* change | Writing a shopping list |
| `terraform apply` | Actually makes the changes | Going shopping |

`plan` is safe. `apply` is not. That difference is the whole reason pipelines exist.

### 2.4 What is a "backend"?

The **backend** is where the state notebook is stored.

- **Local backend** — a file on your laptop. Fine for learning. Terrible for teams.
- **Remote backend** — a shared place everyone uses. On AWS this is an **S3 bucket**.

A remote backend also gives you **locking**. Locking is a bathroom door lock: while one person is inside (running apply), nobody else can get in. Without it, two pipelines running at once can shred your state file.

> 🆕 **Latest info (important):** Old tutorials tell you to create a DynamoDB table for locking. **You do not need that anymore.** Terraform 1.10 added native S3 locking, 1.11 made it generally available, and the `dynamodb_table` setting is now deprecated and will be removed. Use `use_lockfile = true` instead. It creates a small `.tflock` file next to your state in the same bucket.

### 2.5 What is GitLab CI/CD?

GitLab CI/CD reads a file called `.gitlab-ci.yml` in your repo. That file describes **jobs**. Jobs run inside Docker containers on machines called **runners**.

Key words:

| Word | Meaning |
|---|---|
| **Stage** | A group of jobs that run at the same time (e.g. `validate`, `plan`, `apply`) |
| **Job** | One unit of work, e.g. "run terraform plan for prod" |
| **Artifact** | A file a job saves so a later job can use it |
| **Rules** | The "if" that decides whether a job runs |
| **Environment** | A named place you deploy to (`dev`, `staging`, `prod`) |
| **Manual job** | A job with a ▶ button — a human must click it |
| **Resource group** | A queue that stops two jobs from running at once |

### 2.6 The golden pipeline shape

Almost every good Terraform pipeline looks like this:

```
Merge Request opened
  ├─ fmt / validate / lint / security scan   (fast, automatic)
  └─ plan  ──► saves plan file as artifact, shows summary in the MR

Merge to main
  ├─ plan again (automatic)
  └─ apply  ──► MANUAL button, uses the SAVED plan file
```

**The single most important rule:** `apply` must use the exact plan file that `plan` produced. If you re-plan inside apply, a human approved one thing and the machine did another. That is how outages happen.

---

## 3. Step-by-step: your very first working pipeline

We will build one small thing end to end: **an S3 bucket + CloudFront for the React app**. Once this works, everything else is the same pattern repeated.

Time needed: about 45 minutes.

### Step 1 — Make the state bucket (one time, by hand)

Chicken-and-egg problem: Terraform needs a bucket to store state, but you use Terraform to make buckets. So we make this one bucket by hand, once, and never touch it again.

```bash
export AWS_REGION=eu-west-1
export STATE_BUCKET=acme-tf-state-eu-west-1

# Create the bucket
aws s3api create-bucket \
  --bucket "$STATE_BUCKET" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

# Versioning = every save keeps the old copy. This is your undo button.
aws s3api put-bucket-versioning \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

# Encrypt everything at rest
aws s3api put-bucket-encryption \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'

# Block all public access. State files must NEVER be public.
aws s3api put-public-access-block \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

> 💡 **Tip:** Turn on versioning **before** you ever write state to it. Versioning is what lets you roll back a corrupted state file.

### Step 2 — Let GitLab log in to AWS *without* passwords

Do **not** put `AWS_ACCESS_KEY_ID` in GitLab variables. Long-lived keys leak, and they never expire.

Instead use **OIDC**. Think of it like a hall pass: GitLab gives the job a short signed note that says "this job really is from project 1234 on branch main." AWS reads the note and hands back credentials that die in one hour.

**2a. Create the identity provider in AWS (one time):**

```bash
aws iam create-open-id-connect-provider \
  --url "https://gitlab.com" \
  --client-id-list "https://gitlab.com" \
  --thumbprint-list "0000000000000000000000000000000000000000"
```

> For self-hosted GitLab, use your own URL. AWS now verifies OIDC thumbprints automatically for well-known providers, but the field is still required — pull the real thumbprint if your security team asks for it.

**2b. Create the role Terraform will use. This trust policy is the security boundary — read it carefully:**

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::111122223333:oidc-provider/gitlab.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "gitlab.com:aud": "https://gitlab.com"
      },
      "StringLike": {
        "gitlab.com:sub": "project_path:acme/platform-infra:ref_type:branch:ref:main"
      }
    }
  }]
}
```

That `sub` line means: **only the `main` branch of `acme/platform-infra` may become this role.** A fork, a random branch, or another project gets nothing.

> 🔐 **Best practice:** make **two** roles.
> - `gitlab-terraform-plan` — read-only (`ReadOnlyAccess` + write to the state bucket). Allowed from any branch.
> - `gitlab-terraform-apply` — full power. Allowed **only** from `main` and only from protected environments.

**2c. Store the role ARNs as GitLab CI/CD variables** (Settings → CI/CD → Variables), and tick **Protected** on the apply role:

```
AWS_PLAN_ROLE_ARN   = arn:aws:iam::111122223333:role/gitlab-terraform-plan
AWS_APPLY_ROLE_ARN  = arn:aws:iam::111122223333:role/gitlab-terraform-apply   [Protected]
AWS_REGION          = eu-west-1
```

### Step 3 — Write the Terraform

Create this folder structure:

```
platform-infra/
└── stacks/
    └── 50-frontend/
        ├── versions.tf
        ├── backend.tf
        ├── variables.tf
        ├── main.tf
        └── outputs.tf
```

**`versions.tf`** — pin everything. Never let versions float.

```hcl
terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Repo        = "acme/platform-infra"
      Stack       = "50-frontend"
      CostCenter  = "platform"
    }
  }
}
```

> 💡 `default_tags` puts these tags on **every** resource automatically. Your finance team will love you.

**`backend.tf`** — note it is almost empty. This is called a **partial backend**. The real values come from the pipeline, so the same code works for dev, staging, and prod.

```hcl
terraform {
  backend "s3" {
    # Everything else is passed in with -backend-config at init time.
    encrypt      = true
    use_lockfile = true   # native S3 locking. No DynamoDB needed.
  }
}
```

**`config/prod.s3.tfbackend`** — the missing values for prod:

```hcl
bucket = "acme-tf-state-eu-west-1"
key    = "prod/50-frontend/terraform.tfstate"
region = "eu-west-1"
```

**`config/dev.s3.tfbackend`**:

```hcl
bucket = "acme-tf-state-eu-west-1"
key    = "dev/50-frontend/terraform.tfstate"
region = "eu-west-1"
```

**`variables.tf`**:

```hcl
variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
}

variable "environment" {
  type        = string
  description = "dev | staging | prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "web_bucket_name" {
  type        = string
  description = "S3 bucket that holds the built React app."
}
```

**`main.tf`** — the React app hosting:

```hcl
# The bucket that holds index.html, main.js, etc.
resource "aws_s3_bucket" "web" {
  bucket = var.web_bucket_name
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Enabled"
  }
}

# CloudFront reaches into the private bucket using this identity.
resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.web_bucket_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  comment             = "React web app - ${var.environment}"

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policy: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # React Router: unknown paths must still load index.html
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Only this CloudFront distribution may read the bucket.
data "aws_iam_policy_document" "web" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web.json
}
```

**`outputs.tf`**:

```hcl
output "web_bucket" {
  description = "Bucket the CI job uploads the React build into."
  value       = aws_s3_bucket.web.id
}

output "cloudfront_domain" {
  description = "Public URL of the web app."
  value       = aws_cloudfront_distribution.web.domain_name
}

output "cloudfront_distribution_id" {
  description = "Needed for cache invalidation after a deploy."
  value       = aws_cloudfront_distribution.web.id
}
```

**`config/prod.tfvars`**:

```hcl
aws_region      = "eu-west-1"
environment     = "prod"
web_bucket_name = "acme-react-web-prod"
```

### Step 4 — Write the pipeline

Create `.gitlab-ci.yml` at the repo root:

```yaml
# ---------------------------------------------------------------
# Minimal but correct Terraform pipeline. We grow this in Part 5.
# ---------------------------------------------------------------
image:
  name: hashicorp/terraform:1.14
  entrypoint: [""]

variables:
  STACK_DIR: stacks/50-frontend
  TF_ENV: prod
  # Wait up to 5 minutes for the state lock instead of failing instantly.
  TF_CLI_ARGS_plan: "-lock-timeout=300s"
  TF_CLI_ARGS_apply: "-lock-timeout=300s"
  TF_IN_AUTOMATION: "true"     # quieter output, no "run terraform apply" hints

stages:
  - validate
  - plan
  - apply

# ---- Reusable login-to-AWS snippet -----------------------------
.aws_oidc: &aws_oidc
  - apk add --no-cache aws-cli jq
  - >
    export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s"
    $(aws sts assume-role-with-web-identity
    --role-arn "${TF_ROLE_ARN}"
    --role-session-name "gitlab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
    --web-identity-token "${GITLAB_OIDC_TOKEN}"
    --duration-seconds 3600
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
    --output text))
  - aws sts get-caller-identity   # prove who we are, in the log

.tf_base:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  before_script:
    - *aws_oidc
    - cd "${STACK_DIR}"
    # -reconfigure is critical in CI. See Part 8 for why.
    - terraform init -reconfigure -input=false
        -backend-config="../../config/${TF_ENV}.s3.tfbackend"

# ---- Stage 1: cheap checks -------------------------------------
fmt:
  stage: validate
  script:
    - terraform fmt -check -recursive -diff
  before_script: []          # no AWS needed for formatting

validate:
  stage: validate
  extends: .tf_base
  script:
    - terraform validate
  variables:
    TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN

# ---- Stage 2: plan ---------------------------------------------
plan:
  stage: plan
  extends: .tf_base
  variables:
    TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN
  script:
    - terraform plan -input=false
        -var-file="../../config/${TF_ENV}.tfvars"
        -out=tfplan.bin
    # Human-readable copy for the job log and for reviewers
    - terraform show -no-color tfplan.bin > tfplan.txt
    # Machine-readable copy that GitLab renders in the MR widget
    - terraform show -json tfplan.bin > tfplan.json
  artifacts:
    when: always
    expire_in: 7 days
    paths:
      - ${STACK_DIR}/tfplan.bin
      - ${STACK_DIR}/tfplan.txt
    reports:
      terraform: ${STACK_DIR}/tfplan.json

# ---- Stage 3: apply --------------------------------------------
apply:
  stage: apply
  extends: .tf_base
  variables:
    TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN
  environment:
    name: prod/frontend
    url: https://$CLOUDFRONT_DOMAIN
  # Only one apply for this environment at a time. Queue the rest.
  resource_group: prod-frontend
  # A human must press ▶
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  script:
    # Note: we apply the SAVED plan. No new plan is made here.
    - terraform apply -input=false tfplan.bin
  dependencies:
    - plan
```

### Step 5 — Run it

1. Push to a branch and open a Merge Request. `fmt`, `validate`, and `plan` run. Open the MR — GitLab shows a box saying "Terraform: 6 to add, 0 to change, 0 to destroy."
2. Read the plan output. Does it match what you expect?
3. Merge to `main`. The pipeline runs again.
4. Press ▶ on the `apply` job.
5. Watch AWS create the bucket and CloudFront distribution (CloudFront takes 3–5 minutes).

🎉 **That is a complete, safe, production-shaped Terraform pipeline.** Everything else in this guide is the same idea, just bigger.

### Step 6 — Deploy the actual React files

Terraform makes the *container*. A separate job fills it. Add this to the React app's own repo:

```yaml
deploy-web:
  stage: deploy
  image: node:22-alpine
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  script:
    - npm ci
    - npm run build
    - apk add --no-cache aws-cli
    - *aws_oidc
    - aws s3 sync dist/ "s3://${WEB_BUCKET}/" --delete
      --cache-control "public,max-age=31536000,immutable"
      --exclude "index.html"
    # index.html must never be cached, or users get stale apps
    - aws s3 cp dist/index.html "s3://${WEB_BUCKET}/index.html"
      --cache-control "no-cache,no-store,must-revalidate"
    - aws cloudfront create-invalidation
      --distribution-id "${CF_DIST_ID}" --paths "/index.html"
  environment:
    name: prod/web
```

> 💡 **Best practice: keep infrastructure and application deploys in separate pipelines.** Terraform changes are rare and scary. App deploys are frequent and boring. Don't make your team run a Terraform apply just to ship a CSS fix.

---

## 4. How to lay out the whole repo (the "layer cake")

### 4.1 The big decision: one state or many?

You *could* put the VPC, EKS, Kafka, Keycloak, NiFi, the API, and the web app all in one folder with one state file. **Don't.**

Why not? Because a single `terraform plan` would then have to check ~400 resources against AWS every time you want to change one Helm value. That takes 6+ minutes. And one bad apply can hurt everything at once.

Instead, cut the system into **layers (also called stacks)**. Slowest-and-scariest at the bottom, fastest-and-safest at the top.

```
platform-infra/
├── .gitlab-ci.yml
├── config/
│   ├── dev.s3.tfbackend      dev.tfvars
│   ├── staging.s3.tfbackend  staging.tfvars
│   └── prod.s3.tfbackend     prod.tfvars
├── modules/                          # reusable building blocks
│   ├── eks-cluster/
│   ├── msk-cluster/
│   ├── keycloak-helm/
│   ├── nifi-helm/
│   └── irsa-role/
└── stacks/
    ├── 10-network/     # VPC, subnets, NAT, route tables, VPC endpoints
    ├── 20-eks/         # EKS control plane, node groups, addons, OIDC provider
    ├── 30-data/        # MSK (Kafka), RDS Postgres for Keycloak, EFS for NiFi
    ├── 40-platform/    # Helm: ALB controller, external-dns, cert-manager,
    │                   #       Keycloak, NiFi, Kafka UI
    └── 50-apps/        # ECR repos, Java API release, React S3 + CloudFront
```

Each stack has **its own state file**:

```
s3://acme-tf-state-eu-west-1/
  prod/10-network/terraform.tfstate
  prod/20-eks/terraform.tfstate
  prod/30-data/terraform.tfstate
  prod/40-platform/terraform.tfstate
  prod/50-apps/terraform.tfstate
```

### 4.2 How layers talk to each other

Layer 20 needs the VPC ID from layer 10. Two ways:

**Option A — remote state data source (simple, tight coupling):**

```hcl
# stacks/20-eks/data.tf
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "acme-tf-state-eu-west-1"
    key    = "${var.environment}/10-network/terraform.tfstate"
    region = var.aws_region
  }
}

module "eks" {
  source     = "../../modules/eks-cluster"
  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}
```

**Option B — look it up by tag (loose coupling, my preference):**

```hcl
data "aws_vpc" "main" {
  tags = {
    Name        = "acme-${var.environment}"
    ManagedBy   = "terraform"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Tier = "private" }
}
```

| | Remote state | Tag lookup |
|---|---|---|
| **Pro** | Exact, typed, fails loudly if missing | No permission to read other states needed; layers stay independent |
| **Pro** | Easy to trace where a value came from | Works even if a layer is managed by another team or by ClickOps |
| **Con** | Upper layer needs S3 read on lower layer's state (a security hole if states hold secrets) | Silently picks the wrong thing if tags are sloppy |
| **Con** | Renaming an output breaks other stacks | Needs strict tagging discipline |

> 💡 **Tip:** use tag lookup across *team* boundaries and remote state within a team. And **never put secrets in outputs** — anything in an output is in the state file in plain text.

### 4.3 Environments: folders, workspaces, or accounts?

| Approach | How | Pros | Cons | Verdict |
|---|---|---|---|---|
| **Separate AWS accounts** | prod, staging, dev are different account IDs | Strongest blast-radius protection; billing is clean; a bad IAM policy in dev can't reach prod | More setup (AWS Organizations, SSO) | ✅ **Do this** for anything real |
| **Backend config files** (what we used) | Same code, different `-backend-config` + `-var-file` | Explicit; easy to read; environments can differ | A few more files | ✅ **Do this** |
| **Terraform workspaces** | `terraform workspace select prod` | One command; no extra files | All environments share one backend; easy to apply to prod thinking you're in dev; `terraform.workspace` conditionals get ugly fast | ⚠️ Fine for short-lived preview environments, poor for prod |
| **Copy-pasted folders per env** | `envs/prod/`, `envs/dev/` with duplicated code | Total freedom | Code drifts; you fix a bug in one and forget the others | ❌ Avoid |

---

## 5. The full production `.gitlab-ci.yml`

Now the real thing. This version handles **five stacks × three environments**, plus targeted apply, targeted destroy, and drift detection.

### 5.1 Should you use the GitLab OpenTofu component instead?

GitLab retired the old Terraform CI/CD templates and replaced them with the **OpenTofu CI/CD component**. It gives you `fmt`, `validate`, `plan`, `apply`, `destroy`, drift detection, policy enforcement, plan encryption, and the GitLab-managed HTTP state backend — for about six lines of YAML.

```yaml
include:
  - component: $CI_SERVER_FQDN/components/opentofu/full-pipeline@2.2.0
    inputs:
      version: 2.2.0
      opentofu_version: 1.10.0
      root_dir: stacks/20-eks
      state_name: prod-eks
      auto_define_backend: true

stages: [validate, test, build, deploy, cleanup]
```

| | Component | Hand-written YAML (below) |
|---|---|---|
| **Pro** | Very little to write; maintained by GitLab; drift detection and policy checks built in | Total control; works with plain Terraform, not just OpenTofu; easy to add custom steps |
| **Con** | Opinionated; harder to bend to unusual needs; it is **OpenTofu**, not HashiCorp Terraform | You maintain it; more lines to get right |

> 💡 **Tip:** learn the hand-written version first so you understand what the component is doing for you. Then switch if it fits.

### 5.2 The hand-written pipeline

```yaml
# =================================================================
# .gitlab-ci.yml — multi-stack, multi-environment Terraform on AWS
# =================================================================

variables:
  TF_VERSION: "1.14.9"
  TF_IN_AUTOMATION: "true"
  TF_INPUT: "false"
  TF_CLI_ARGS_init: "-reconfigure -input=false"
  TF_CLI_ARGS_plan: "-lock-timeout=300s"
  TF_CLI_ARGS_apply: "-lock-timeout=300s"
  TF_CLI_ARGS_destroy: "-lock-timeout=300s"
  # Filled in by the user when running a manual targeted job. See Part 6.
  TF_TARGETS:
    value: ""
    description: "Space-separated addresses for a targeted run, e.g. 'module.nifi module.kafka_ui'. Leave empty for a full run."

stages:
  - validate
  - security
  - plan
  - apply
  - targeted        # partial apply / partial destroy, always manual
  - drift

default:
  image:
    name: hashicorp/terraform:${TF_VERSION}
    entrypoint: [""]
  interruptible: true
  retry:
    max: 2
    when:
      - runner_system_failure
      - stuck_or_timeout_failure

# -----------------------------------------------------------------
# Building blocks
# -----------------------------------------------------------------
.aws_login: &aws_login
  - apk add --no-cache aws-cli jq curl
  - >
    export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s"
    $(aws sts assume-role-with-web-identity
    --role-arn "${TF_ROLE_ARN}"
    --role-session-name "gl-${CI_PROJECT_ID}-${CI_PIPELINE_ID}-${CI_JOB_ID}"
    --web-identity-token "${GITLAB_OIDC_TOKEN}"
    --duration-seconds 3600
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
    --output text))
  - aws sts get-caller-identity

.tf:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  cache:
    # Cache providers to save 30-60s per job. Key on the lock file so a
    # provider upgrade busts the cache automatically.
    key:
      files:
        - ${STACK}/.terraform.lock.hcl
    paths:
      - ${STACK}/.terraform/providers
    policy: pull-push
  before_script:
    - *aws_login
    - cd "${STACK}"
    - terraform init -backend-config="${CI_PROJECT_DIR}/config/${TF_ENV}.s3.tfbackend"
    - terraform version

# -----------------------------------------------------------------
# 1. VALIDATE — fast, no cloud access
# -----------------------------------------------------------------
fmt:
  stage: validate
  script:
    - terraform fmt -check -recursive -diff .

lint:
  stage: validate
  image:
    name: ghcr.io/terraform-linters/tflint:latest
    entrypoint: [""]
  script:
    - tflint --init
    - tflint --recursive --format compact

validate:
  stage: validate
  extends: .tf
  parallel:
    matrix:
      - STACK: [stacks/10-network, stacks/20-eks, stacks/30-data,
                stacks/40-platform, stacks/50-apps]
  variables:
    TF_ENV: dev
    TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_DEV
  script:
    - terraform validate

# -----------------------------------------------------------------
# 2. SECURITY — scan the code before it becomes real
# -----------------------------------------------------------------
checkov:
  stage: security
  image:
    name: bridgecrew/checkov:latest
    entrypoint: [""]
  script:
    - checkov -d . --framework terraform --compact
        --output cli --output junitxml --output-file-path console,checkov.xml
        --soft-fail-on LOW,MEDIUM
  artifacts:
    when: always
    reports:
      junit: checkov.xml

trivy-iac:
  stage: security
  image:
    name: aquasec/trivy:latest
    entrypoint: [""]
  script:
    - trivy config --exit-code 1 --severity HIGH,CRITICAL .

# -----------------------------------------------------------------
# 3. PLAN — one job per stack, per environment
# -----------------------------------------------------------------
.plan_template:
  stage: plan
  extends: .tf
  variables:
    TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN
  script:
    - |
      TARGET_ARGS=""
      if [ -n "${TF_TARGETS}" ]; then
        for t in ${TF_TARGETS}; do TARGET_ARGS="${TARGET_ARGS} -target=${t}"; done
        echo "⚠️  TARGETED PLAN — only: ${TF_TARGETS}"
      fi
      terraform plan ${TARGET_ARGS} \
        -var-file="${CI_PROJECT_DIR}/config/${TF_ENV}.tfvars" \
        -out=tfplan.bin
    - terraform show -no-color tfplan.bin | tee tfplan.txt
    - terraform show -json tfplan.bin > tfplan.json
    # Print a one-line summary so reviewers don't have to scroll
    - |
      jq -r '[.resource_changes[]?.change.actions[]?]
             | group_by(.) | map({(.[0]): length}) | add' tfplan.json
  artifacts:
    when: always
    expire_in: 30 days
    paths:
      - ${STACK}/tfplan.bin
      - ${STACK}/tfplan.txt
    reports:
      terraform: ${STACK}/tfplan.json

plan:prod:network:
  extends: .plan_template
  variables: { STACK: stacks/10-network, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD }

plan:prod:eks:
  extends: .plan_template
  variables: { STACK: stacks/20-eks, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD }

plan:prod:data:
  extends: .plan_template
  variables: { STACK: stacks/30-data, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD }

plan:prod:platform:
  extends: .plan_template
  variables: { STACK: stacks/40-platform, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD }

plan:prod:apps:
  extends: .plan_template
  variables: { STACK: stacks/50-apps, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD }

# -----------------------------------------------------------------
# 4. APPLY — manual, protected, queued, in dependency order
# -----------------------------------------------------------------
.apply_template:
  stage: apply
  extends: .tf
  when: manual
  allow_failure: false
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual
    - when: never
  script:
    - terraform apply tfplan.bin
    - terraform output -json > outputs.json
  artifacts:
    paths:
      - ${STACK}/outputs.json

apply:prod:network:
  extends: .apply_template
  needs: [plan:prod:network]
  dependencies: [plan:prod:network]
  resource_group: prod-10-network
  environment: { name: prod/network }
  variables: { STACK: stacks/10-network, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD }

apply:prod:eks:
  extends: .apply_template
  needs: [plan:prod:eks, apply:prod:network]
  dependencies: [plan:prod:eks]
  resource_group: prod-20-eks
  environment: { name: prod/eks }
  variables: { STACK: stacks/20-eks, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD }

apply:prod:data:
  extends: .apply_template
  needs: [plan:prod:data, apply:prod:eks]
  dependencies: [plan:prod:data]
  resource_group: prod-30-data
  environment: { name: prod/data }
  variables: { STACK: stacks/30-data, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD }

apply:prod:platform:
  extends: .apply_template
  needs: [plan:prod:platform, apply:prod:data]
  dependencies: [plan:prod:platform]
  resource_group: prod-40-platform
  environment: { name: prod/platform }
  variables: { STACK: stacks/40-platform, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD }

apply:prod:apps:
  extends: .apply_template
  needs: [plan:prod:apps, apply:prod:platform]
  dependencies: [plan:prod:apps]
  resource_group: prod-50-apps
  environment: { name: prod/apps, url: https://app.acme.example }
  variables: { STACK: stacks/50-apps, TF_ENV: prod,
               TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD }

# -----------------------------------------------------------------
# 5. DRIFT DETECTION — scheduled, read-only, alerts if reality changed
# -----------------------------------------------------------------
drift:prod:
  stage: drift
  extends: .tf
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule" && $DRIFT_CHECK == "true"
  parallel:
    matrix:
      - STACK: [stacks/10-network, stacks/20-eks, stacks/30-data,
                stacks/40-platform, stacks/50-apps]
  variables:
    TF_ENV: prod
    TF_ROLE_ARN: $AWS_PLAN_ROLE_ARN_PROD
  script:
    # exit code 2 = "there are changes" = drift
    - |
      set +e
      terraform plan -detailed-exitcode -lock=false \
        -var-file="${CI_PROJECT_DIR}/config/prod.tfvars" -out=drift.bin
      CODE=$?
      set -e
      if [ $CODE -eq 2 ]; then
        echo "🚨 DRIFT DETECTED in ${STACK}"
        terraform show -no-color drift.bin
        exit 1
      fi
      echo "✅ ${STACK} matches the code."
```

> 💡 **Why `-lock=false` in drift detection?** Drift jobs are read-only and run on a schedule. You don't want a nightly check to block someone's real apply.

### 5.3 Set up the schedule

GitLab → Build → Pipeline schedules → New schedule.
Cron: `0 6 * * 1-5`. Add variable `DRIFT_CHECK = true`.

Now every weekday at 6am, GitLab tells you if someone changed something in the AWS console by hand.

---

## 6. Partial apply: changing only some AWS resources

This is one of the two things you asked about, so let's go deep.

### 6.1 What "partial apply" means

Normally `terraform apply` reconciles **everything** in the stack. Sometimes you want it to touch **only NiFi** and leave Kafka, Keycloak, and the API alone.

There are **four** ways to do it. They are not equally good.

---

### Method 1 — Split into stacks *(best; you already did this)*

By putting NiFi in `stacks/40-platform` and Kafka in `stacks/30-data`, running `apply` on 40 already leaves 30 untouched.

Take it further: give each big component its own stack.

```
stacks/
  40-platform-controllers/   # ALB controller, external-dns, cert-manager
  41-keycloak/
  42-kafka-ui/
  43-nifi/
```

**Pros:** No special flags. Plans stay honest and complete. Blast radius is a real, permanent wall.
**Cons:** More state files to manage; cross-stack wiring needed; more pipeline YAML.

**Verdict: this is the answer 80% of the time.** Reach for the other methods only when this isn't practical.

---

### Method 2 — Feature flags with `count` *(best for on/off)*

Add a switch to each component.

```hcl
# stacks/40-platform/variables.tf
variable "enable_nifi" {
  type        = bool
  default     = true
  description = "Set false to remove NiFi entirely."
}

variable "enable_kafka_ui" {
  type    = bool
  default = true
}

variable "nifi_node_count" {
  type    = number
  default = 3
}
```

```hcl
# stacks/40-platform/nifi.tf
module "nifi" {
  count  = var.enable_nifi ? 1 : 0
  source = "../../modules/nifi-helm"

  namespace       = "data-platform"
  node_count      = var.nifi_node_count
  storage_class   = "gp3"
  oidc_issuer_url = "https://auth.acme.example/realms/platform"
  oidc_client_id  = "nifi"
  kafka_bootstrap = data.aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}
```

Now a "partial apply" is just a normal, complete, honest apply with a different variable:

```bash
terraform apply -var="enable_nifi=false"
```

**Pros:** The plan is always complete and truthful. Reviewable in Git. Repeatable. No state weirdness. Works perfectly in a pipeline.
**Cons:** You must plan the flags in advance. Note the `[0]` index you now need when referencing: `module.nifi[0].service_name`.

> 💡 **Tip:** prefer `for_each` over `count` when you have a *set* of things. With `count`, removing the middle item renumbers everything after it, and Terraform destroys and recreates them. With `for_each`, each item has a stable name key.
>
> ```hcl
> variable "enabled_components" {
>   type    = set(string)
>   default = ["keycloak", "nifi", "kafka-ui"]
> }
>
> module "helm_app" {
>   for_each = var.enabled_components
>   source   = "../../modules/helm-app"
>   name     = each.key
> }
> ```
> Removing `"nifi"` from that set removes only NiFi. Nothing else moves.

---

### Method 3 — `-target` *(the escape hatch; use rarely)*

```bash
# Plan only NiFi
terraform plan -target=module.nifi -out=nifi.tfplan

# Apply that plan
terraform apply nifi.tfplan
```

You can target several things:

```bash
terraform plan \
  -target=module.nifi \
  -target=module.kafka_ui \
  -target=aws_security_group.nifi \
  -out=partial.tfplan
```

**Address syntax cheat sheet:**

| You want | Address |
|---|---|
| One resource | `aws_msk_cluster.main` |
| One item in a `count` list | `module.nifi[0]` |
| One item in a `for_each` map | `module.helm_app["nifi"]` |
| A whole module and everything inside it | `module.keycloak` |
| A nested module | `module.platform.module.nifi` |
| A resource inside a module | `module.nifi.helm_release.this` |

**How Terraform actually behaves with `-target`:** it includes your target **and everything your target depends on**. So targeting `module.nifi` will also plan the security group, IAM role, and EFS file system NiFi needs — because NiFi can't exist without them. It does **not** include things that depend on NiFi.

**Pros:**
- Instant. No code changes.
- Excellent for breaking a circular dependency during first-time bootstrap.
- Excellent for recovering when one resource failed and the rest applied fine.

**Cons — and these are serious:**
- ⚠️ **The plan is a lie.** Terraform prints a big warning: *"Resource targeting is in effect… The plan will not include actions for resources not matching the target."* Real drift elsewhere stays hidden.
- ⚠️ Your state can end up in a state no config file describes. The next full apply may then do surprising things.
- ⚠️ Outputs are only refreshed for targeted resources.
- ⚠️ It hides bad module design. If you *need* `-target` every week, your stacks are wrong. Fix the stacks.
- ⚠️ HashiCorp's own docs call this an exceptional, not routine, tool.

> 🚫 **Rule for your team:** `-target` in a pipeline must always be a **manual job**, must log loudly, and must be followed by a **full plan** to prove nothing was left inconsistent.

**Putting it in GitLab safely:**

```yaml
targeted-apply:prod:
  stage: targeted
  extends: .tf
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  resource_group: prod-40-platform   # shares the queue with normal applies
  environment: { name: prod/platform }
  variables:
    STACK: stacks/40-platform
    TF_ENV: prod
    TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD
    TF_TARGETS:
      value: ""
      description: "REQUIRED. Space-separated, e.g. 'module.nifi module.kafka_ui'"
  script:
    - |
      if [ -z "${TF_TARGETS}" ]; then
        echo "❌ TF_TARGETS is empty. Use the normal apply job for full runs."
        exit 1
      fi
      echo "════════════════════════════════════════════════"
      echo "⚠️  TARGETED APPLY"
      echo "   Targets : ${TF_TARGETS}"
      echo "   By      : ${GITLAB_USER_LOGIN}"
      echo "   Stack   : ${STACK} (${TF_ENV})"
      echo "   This plan is PARTIAL. Drift elsewhere is invisible."
      echo "════════════════════════════════════════════════"
      ARGS=""
      for t in ${TF_TARGETS}; do ARGS="${ARGS} -target=${t}"; done
      terraform plan ${ARGS} \
        -var-file="${CI_PROJECT_DIR}/config/${TF_ENV}.tfvars" \
        -out=targeted.bin
      terraform show -no-color targeted.bin
      terraform apply targeted.bin
    # Immediately prove the stack is still whole
    - |
      echo "── Post-check: full plan ──"
      set +e
      terraform plan -detailed-exitcode \
        -var-file="${CI_PROJECT_DIR}/config/${TF_ENV}.tfvars"
      CODE=$?
      set -e
      [ $CODE -eq 2 ] && echo "⚠️  Stack is NOT fully converged. Run a full apply soon."
      exit 0
```

To run it: open the pipeline → find `targeted-apply:prod` → click the ⚙ next to ▶ → **Run job with variables** → set `TF_TARGETS` to `module.nifi` → Run.

> 💡 **Tip:** `resource_group: prod-40-platform` is shared with `apply:prod:platform` on purpose. It means a targeted apply and a full apply can never run at the same time and corrupt state.

---

### Method 4 — `-replace` (rebuild one thing without touching anything else)

Sometimes a resource exists but is broken. A NiFi node is wedged. A launch template needs a fresh rollout.

```bash
terraform plan -replace="module.nifi[0].kubernetes_stateful_set.nifi" -out=r.bin
terraform apply r.bin
```

This is the modern replacement for `terraform taint`, which is deprecated. `-replace` is better because the destroy-and-recreate shows up **in the plan**, so a human can approve it before anything happens.

Combine with `-target` when you must be surgical:

```bash
terraform plan \
  -target=module.nifi \
  -replace="module.nifi[0].kubernetes_stateful_set.nifi" \
  -out=r.bin
```

---

### 6.2 Which method for which situation?

| Situation | Use |
|---|---|
| "We deploy NiFi to dev but not to staging" | **Feature flag** (`count` / `for_each`) |
| "The Kafka team ships on their own schedule" | **Separate stack** |
| "Apply failed halfway; the ALB controller applied, cert-manager didn't" | **`-target`** to finish, then full plan |
| "Chicken-and-egg: the Kubernetes provider needs the EKS cluster that doesn't exist yet" | **`-target=module.eks`** first, then full apply. (Better long term: split into two stacks.) |
| "One NiFi pod's PVC is corrupt" | **`-replace`** |
| "I want to test one small change fast" | **Separate stack**, or accept the 3-minute plan |

> ⚠️ **The chicken-and-egg case deserves a warning.** People commonly write:
> ```hcl
> provider "kubernetes" {
>   host = module.eks.cluster_endpoint   # doesn't exist on first run!
> }
> ```
> This forces `-target` forever. **The correct fix is to split EKS creation (stack 20) from Kubernetes/Helm resources (stack 40).** Providers should be configured from data sources or remote state, not from resources in the same apply.

---

## 7. Partial destroy: deleting only some AWS resources

Destroying is the scariest operation there is. Let's make it safe.

### 7.1 The four ways to remove things

| Way | Deletes from AWS? | Removes from state? | Use when |
|---|---|---|---|
| Delete the code + apply | ✅ Yes | ✅ Yes | Normal, permanent removal |
| Feature flag → `false` + apply | ✅ Yes | ✅ Yes | Temporary or per-environment removal |
| `terraform destroy -target=...` | ✅ Yes | ✅ Yes | Emergency / quick cleanup |
| `terraform state rm` or `removed` block | ❌ **No** | ✅ Yes | Handing a resource to another team or stack |

---

### Method 1 — Feature flag *(safest, fully reviewable)*

Merge a change to `config/dev.tfvars`:

```hcl
enable_nifi = false
```

The normal pipeline then plans it. The MR widget shows "0 to add, 0 to change, 14 to destroy." A reviewer sees exactly what dies. Merge, then press ▶.

**This is the best way to do a partial destroy in a pipeline.** It goes through code review, it is recorded in Git history, and the plan is complete and honest.

---

### Method 2 — Delete the code

Same thing, but you remove `nifi.tf` from the repo. Terraform sees resources in state that aren't in config and plans to destroy them.

---

### Method 3 — `terraform destroy -target` *(emergency lever)*

```bash
# ALWAYS plan first. Never run bare `terraform destroy`.
terraform plan -destroy -target=module.nifi -out=destroy.tfplan

# Read every single line of this
terraform show -no-color destroy.tfplan

# Only then
terraform apply destroy.tfplan
```

> ⚠️ Note the shape: `plan -destroy` then `apply`. Running `terraform destroy -target=X` directly does the same thing but prompts you interactively — which won't work in CI and gives you no artifact to review.

**Important behaviour:** targeted destroy removes your target **and everything that depends on it**. Destroying `aws_vpc.main` would take the entire environment with it. Destroying `module.nifi` takes NiFi's ingress, service, PVCs, and IAM role.

**Pros:** fast; needs no code change.
**Cons:** not reviewed in Git; the code still says NiFi should exist, so **the very next full apply will build it back**. That surprise catches people constantly.

> 💡 **Rule:** if you use targeted destroy, you must *also* merge a code change (or flag change) in the same hour, or your infrastructure will resurrect itself.

**In GitLab, with real guard rails:**

```yaml
targeted-destroy:prod:
  stage: targeted
  extends: .tf
  when: manual
  allow_failure: false
  rules:
    # prod destroys only from the default branch, never from an MR
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
  resource_group: prod-40-platform
  environment:
    name: prod/platform
    action: prepare
  variables:
    STACK: stacks/40-platform
    TF_ENV: prod
    TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_PROD
    TF_TARGETS:
      value: ""
      description: "REQUIRED. e.g. 'module.nifi'"
    CONFIRM_DESTROY:
      value: "no"
      description: "Type the exact word: DESTROY-PROD"
  script:
    - |
      if [ "${CONFIRM_DESTROY}" != "DESTROY-PROD" ]; then
        echo "❌ Refusing. Set CONFIRM_DESTROY=DESTROY-PROD to proceed."
        exit 1
      fi
      if [ -z "${TF_TARGETS}" ]; then
        echo "❌ TF_TARGETS is empty. I will not destroy an entire stack."
        exit 1
      fi
      ARGS=""
      for t in ${TF_TARGETS}; do ARGS="${ARGS} -target=${t}"; done

      terraform plan -destroy ${ARGS} \
        -var-file="${CI_PROJECT_DIR}/config/${TF_ENV}.tfvars" \
        -out=destroy.bin
      terraform show -no-color destroy.bin | tee destroy.txt

      # Refuse to nuke protected things, whatever the operator typed
      terraform show -json destroy.bin \
        | jq -r '.resource_changes[]
                 | select(.change.actions | index("delete"))
                 | .type' | sort -u > types.txt
      cat types.txt
      for forbidden in aws_msk_cluster aws_db_instance aws_rds_cluster \
                       aws_s3_bucket aws_efs_file_system aws_eks_cluster; do
        if grep -qx "$forbidden" types.txt; then
          echo "🛑 BLOCKED: this plan would delete a ${forbidden}."
          echo "   Stateful resources must be removed by a reviewed MR."
          exit 1
        fi
      done

      echo "Destroying: ${TF_TARGETS}"
      terraform apply destroy.bin
  artifacts:
    when: always
    paths: [ "${STACK}/destroy.txt" ]
```

That job needs **three** independent things to go wrong before data dies: someone must click ▶, type `DESTROY-PROD`, name a target, and the target must not be a database. Also protect the `prod/*` environment (Settings → CI/CD → Protected environments) so only release managers can press it.

---

### Method 4 — Remove from state *without* deleting from AWS

You are moving Kafka out of `30-data` into its own stack. You do **not** want the real MSK cluster deleted — you just want this state file to stop tracking it.

**Modern way — the `removed` block (Terraform 1.7+). Reviewable in Git:**

```hcl
# stacks/30-data/removed.tf
removed {
  from = module.msk

  lifecycle {
    destroy = false   # "forget it, don't delete it"
  }
}
```

Apply that, and the plan says *"module.msk will no longer be managed by Terraform, but will not be destroyed."* Then delete the `removed` block in a follow-up MR, and import the cluster into the new stack.

**Old way — a manual command (works, but leaves no Git trace):**

```bash
terraform state list | grep msk           # see the exact addresses
terraform state rm 'module.msk.aws_msk_cluster.this'
```

**Then adopt it in the new stack using an `import` block:**

```hcl
# stacks/31-kafka/import.tf
import {
  to = module.msk.aws_msk_cluster.this
  id = "arn:aws:kafka:eu-west-1:111122223333:cluster/acme-prod/abc-123"
}
```

Run `terraform plan`. It should say **"0 to add, 0 to change, 0 to destroy"** and one import. If it wants to *change* anything, your new config doesn't match reality yet — fix the config, don't apply.

> 💡 **Tip:** `terraform plan -generate-config-out=generated.tf` writes a first draft of the resource block for you from the real AWS resource. Great starting point, but always clean it up by hand.
>
> 🆕 Terraform 1.14 adds `terraform query` and `*.tfquery.hcl` "list resources," which can discover existing AWS resources in bulk and generate import-ready config. Very useful when adopting a hand-built account.

---

### 7.2 Locks that stop accidents before they happen

Put these on anything holding data:

```hcl
resource "aws_msk_cluster" "main" {
  cluster_name = "acme-${var.environment}"
  # ...

  lifecycle {
    prevent_destroy = true    # Terraform hard-errors on any plan that deletes this
  }
}

resource "aws_db_instance" "keycloak" {
  identifier                = "keycloak-${var.environment}"
  deletion_protection       = true    # AWS-side lock, independent of Terraform
  skip_final_snapshot       = false
  final_snapshot_identifier = "keycloak-${var.environment}-final"
  backup_retention_period   = 30

  lifecycle {
    prevent_destroy = true
  }
}
```

Belt **and** braces:
- `prevent_destroy` — Terraform refuses to even make the plan.
- `deletion_protection` — AWS refuses even if someone bypasses Terraform.

> ⚠️ **Gotcha:** `prevent_destroy` also blocks *replacement*. If you change an immutable field (like MSK's `kafka_version` in some cases), Terraform wants to replace, and `prevent_destroy` stops it. You then temporarily comment it out. That is annoying **on purpose** — it forces a conscious decision.

Also add an **AWS SCP or IAM deny** so the pipeline role literally cannot call `DeleteDBCluster`, `DeleteCluster` (MSK/EKS), or `DeleteBucket` in prod. Guard rails in code can be edited. Guard rails in IAM cannot be edited by the pipeline itself.

---

### 7.3 Ephemeral review environments (destroy done *right*)

The one place automatic destroy is genuinely good: per-MR preview environments.

```yaml
review:deploy:
  stage: apply
  extends: .tf
  rules:
    - if: $CI_MERGE_REQUEST_IID
  variables:
    STACK: stacks/60-review
    TF_ENV: dev
    TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_DEV
    TF_WORKSPACE: mr-$CI_MERGE_REQUEST_IID
  environment:
    name: review/$CI_MERGE_REQUEST_IID
    url: https://mr-$CI_MERGE_REQUEST_IID.dev.acme.example
    on_stop: review:destroy
    auto_stop_in: 2 days
  script:
    - terraform workspace select -or-create "mr-${CI_MERGE_REQUEST_IID}"
    - terraform apply -auto-approve
        -var-file="${CI_PROJECT_DIR}/config/dev.tfvars"
        -var="namespace=mr-${CI_MERGE_REQUEST_IID}"

review:destroy:
  stage: apply
  extends: .tf
  when: manual
  rules:
    - if: $CI_MERGE_REQUEST_IID
      when: manual
  variables:
    STACK: stacks/60-review
    TF_ENV: dev
    TF_ROLE_ARN: $AWS_APPLY_ROLE_ARN_DEV
    GIT_STRATEGY: none        # branch may already be deleted
  environment:
    name: review/$CI_MERGE_REQUEST_IID
    action: stop
  script:
    - terraform workspace select "mr-${CI_MERGE_REQUEST_IID}"
    - terraform destroy -auto-approve
        -var-file="${CI_PROJECT_DIR}/config/dev.tfvars"
        -var="namespace=mr-${CI_MERGE_REQUEST_IID}"
    - terraform workspace select default
    - terraform workspace delete "mr-${CI_MERGE_REQUEST_IID}"
```

`auto_stop_in: 2 days` is the money-saver: forgotten review environments delete themselves. This is one of the few good uses of Terraform **workspaces** — each MR gets its own state, but they all share one backend and one config.

> 💡 Review environments should deploy **into an existing dev EKS cluster** as a new namespace — not spin up a whole new cluster. A per-MR EKS cluster takes 15 minutes and costs a fortune.

---

## 8. Reconfigure: fixing and moving the backend

"Reconfigure" trips up almost everyone at some point. Let's untangle it.

### 8.1 What `terraform init` actually does

`terraform init` does three separate jobs:

1. Downloads providers (`aws`, `kubernetes`, `helm`) into `.terraform/providers/`
2. Downloads modules into `.terraform/modules/`
3. **Sets up the backend** and writes a small file at `.terraform/terraform.tfstate` that remembers *"my state lives in bucket X, key Y."*

Step 3 is the one that causes trouble. That local memory file can disagree with what you're asking for today.

### 8.2 The three init flags you must know

| Flag | What it does | The mental picture |
|---|---|---|
| `-reconfigure` | **Throw away** the remembered backend settings. Use the new ones. **Do not copy any state.** | "Forget the old address book. Here's a new one. Leave the old house alone." |
| `-migrate-state` | Use the new backend settings, and **copy the existing state** from the old backend to the new one. | "We're moving house. Bring the furniture." |
| `-upgrade` | Re-check provider and module versions against your constraints and update the lock file. | "Get newer tools." |

> 🔑 **This is the single most important sentence in this section:**
> **`-reconfigure` = forget and start fresh. `-migrate-state` = move the data.**
> Getting these backwards either wipes your CI's link to state (harmless, annoying) or writes your state to the wrong place (bad).

### 8.3 Why CI pipelines almost always need `-reconfigure`

Three very common CI problems, all solved by the same flag:

**Problem A — cached `.terraform` directory.**
You cache `.terraform/` to speed jobs up. That cache contains yesterday's backend memory pointing at `dev`. Today's job is `prod`. Terraform gets confused and either errors or, worse, uses the wrong state.

**Problem B — one repo, many environments.**
The same `stacks/20-eks` folder is init'ed with `dev.s3.tfbackend` in one job and `prod.s3.tfbackend` in the next. Without `-reconfigure`, the second job sees a mismatch.

**Problem C — interactive prompt in a non-interactive job.**
Terraform notices the change and asks *"Do you want to copy existing state to the new backend?"* Nobody is there to type "yes." The job hangs until it times out.

**The fix, applied globally:**

```yaml
variables:
  TF_CLI_ARGS_init: "-reconfigure -input=false"
```

`TF_CLI_ARGS_init` is an environment variable Terraform reads and appends to every `terraform init`. Set it once and every job in your pipeline is protected.

> 💡 **Best practice: only cache `.terraform/providers`, never all of `.terraform/`.** Providers are big and safe to cache. The backend memory file is small and dangerous to cache. Look back at the `.tf` cache block in Part 5 — it caches exactly `${STACK}/.terraform/providers` and nothing else.

### 8.4 Real reconfigure scenarios, with commands

#### Scenario A — Switching environments locally

```bash
cd stacks/20-eks

# Work on dev
terraform init -reconfigure -backend-config=../../config/dev.s3.tfbackend
terraform plan -var-file=../../config/dev.tfvars

# Switch to prod — MUST reconfigure
terraform init -reconfigure -backend-config=../../config/prod.s3.tfbackend
terraform plan -var-file=../../config/prod.tfvars
```

Forget the `-reconfigure` and you get:

```
Error: Backend configuration changed

A change in the backend configuration has been detected...
```

#### Scenario B — Moving state to a new bucket (a real migration)

Company renames the state bucket from `acme-tf-state` to `acme-tf-state-eu-west-1`.

```bash
# 0. SAFETY FIRST: take a copy you can restore from
terraform state pull > backup-$(date +%Y%m%d-%H%M).tfstate

# 1. Edit config/prod.s3.tfbackend to the new bucket name

# 2. Migrate — this COPIES the state to the new place
terraform init -migrate-state -backend-config=../../config/prod.s3.tfbackend
#    Terraform asks: "Do you want to copy existing state to the new backend?"
#    Type: yes

# 3. Prove nothing changed
terraform plan -var-file=../../config/prod.tfvars
#    Expected: "No changes. Your infrastructure matches the configuration."

# 4. Only after that plan is clean, delete the old bucket's copy
```

> ⚠️ **Never run `-migrate-state` in a pipeline.** Migrations need a human watching. Do them from a laptop with the backup in hand, then push the config change so CI picks up the new location with `-reconfigure`.

#### Scenario C — Adding native S3 locking (removing DynamoDB)

This is a very common 2026 migration.

**Before:**
```hcl
terraform {
  backend "s3" {
    bucket         = "acme-tf-state-eu-west-1"
    key            = "prod/20-eks/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"   # ❌ deprecated
  }
}
```

**Step 1 — run both at once for a transition period.** This lets old and new Terraform versions coexist while everyone upgrades:
```hcl
    dynamodb_table = "terraform-locks"
    use_lockfile   = true
```
```bash
terraform init -reconfigure
```

**Step 2 — once everyone is on Terraform ≥ 1.11, drop DynamoDB:**
```hcl
terraform {
  backend "s3" {
    bucket       = "acme-tf-state-eu-west-1"
    key          = "prod/20-eks/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true      # ✅ native S3 locking
    kms_key_id   = "arn:aws:kms:eu-west-1:111122223333:key/abc-123"
  }
}
```
```bash
terraform init -reconfigure
terraform plan     # must show no changes
```

**Step 3 — delete the DynamoDB table.** One less thing to pay for and secure.

#### Scenario D — A stuck lock

A runner was killed mid-apply. Now every job fails:

```
Error: Error acquiring the state lock
Lock Info:
  ID:        7f3a...
  Path:      acme-tf-state-eu-west-1/prod/20-eks/terraform.tfstate
  Operation: OperationTypeApply
  Who:       root@runner-abc
  Created:   2026-07-31 09:14:02 UTC
```

```bash
# 1. FIRST: make absolutely sure no apply is really running.
#    Check the GitLab pipeline. Check with your team. Ask out loud.
# 2. Then break the lock with the ID from the error:
terraform force-unlock 7f3a-...
```

> ⚠️ **Force-unlocking while an apply is genuinely running will corrupt your state.** Verify twice. This is why `resource_group:` matters — it prevents the double-run that makes stuck locks common.

Prevention: set `-lock-timeout=300s` (jobs wait politely instead of failing) and always set a job `timeout:` shorter than your patience.

#### Scenario E — Provider upgrade

```bash
# Update the constraint in versions.tf first, e.g. "~> 6.5"
terraform init -upgrade
terraform plan          # read this carefully — provider upgrades change defaults
git add .terraform.lock.hcl
git commit -m "chore: bump aws provider to 6.5"
```

> 💡 **Always commit `.terraform.lock.hcl`.** It pins exact provider versions *and their checksums*, so CI, your laptop, and your teammate's laptop all use identical binaries. Add multi-platform hashes so Mac laptops and Linux runners agree:
> ```bash
> terraform providers lock \
>   -platform=linux_amd64 \
>   -platform=linux_arm64 \
>   -platform=darwin_arm64
> ```

### 8.5 Reconfigure decision table

| Your situation | Command |
|---|---|
| Every CI job, always | `init -reconfigure -input=false` |
| Switching dev ↔ prod locally | `init -reconfigure -backend-config=...` |
| Moving state to a new bucket/key | `init -migrate-state` (locally, with a backup) |
| Adding `use_lockfile = true` | `init -reconfigure` |
| Bumping provider versions | `init -upgrade` then commit the lock file |
| `.terraform` looks broken | `rm -rf .terraform && terraform init -reconfigure` |
| Local → remote backend, first time | `init -migrate-state`, answer `yes` |

---

## 9. The example apps in Terraform

Now the fun part: what Keycloak, Kafka, NiFi, the Java API, and React actually look like in code.

### 9.1 Stack 20 — EKS

```hcl
# stacks/20-eks/main.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "acme-${var.environment}"
  kubernetes_version = "1.33"

  vpc_id     = data.aws_vpc.main.id
  subnet_ids = data.aws_subnets.private.ids

  # Private API endpoint + a narrow public one for the CI runner
  endpoint_private_access = true
  endpoint_public_access  = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # Modern access control. Do NOT use the old aws-auth ConfigMap.
  authentication_mode = "API"

  access_entries = {
    gitlab_ci = {
      principal_arn = var.gitlab_apply_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    platform_team = {
      principal_arn = "arn:aws:iam::111122223333:role/PlatformEngineer"
      policy_associations = {
        edit = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true, before_compute = true }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
    aws-efs-csi-driver     = { most_recent = true }
  }

  eks_managed_node_groups = {
    # General workloads: Keycloak, Java API, controllers
    general = {
      instance_types = ["m7i.large"]
      min_size       = 3
      max_size       = 10
      desired_size   = 3
      capacity_type  = "ON_DEMAND"
    }

    # NiFi: memory-hungry, needs stable nodes, gets its own pool
    data = {
      instance_types = ["r7i.xlarge"]
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      capacity_type  = "ON_DEMAND"

      labels = { workload = "data-platform" }
      taints = [{
        key    = "workload"
        value  = "data-platform"
        effect = "NO_SCHEDULE"
      }]
    }
  }
}
```

> 💡 **Why the taint on the `data` node group?** A taint is a "keep out" sign. Only pods that explicitly tolerate it can land there. It stops a random web pod from stealing memory NiFi needs.

### 9.2 Stack 30 — Kafka (MSK) and Keycloak's database

```hcl
# stacks/30-data/msk.tf
resource "aws_msk_cluster" "main" {
  cluster_name           = "acme-${var.environment}"
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 3

  broker_node_group_info {
    instance_type   = var.environment == "prod" ? "kafka.m7g.large" : "kafka.t3.small"
    client_subnets  = data.aws_subnets.private.ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 1000

        provisioned_throughput {
          enabled           = true
          volume_throughput = 250
        }
      }
    }
  }

  client_authentication {
    sasl { iam = true }        # IAM auth: no Kafka passwords to manage
    unauthenticated = false
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.msk.arn
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "kafka_bootstrap_iam" {
  value = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}
```

```hcl
# stacks/30-data/keycloak-db.tf
resource "aws_db_instance" "keycloak" {
  identifier     = "keycloak-${var.environment}"
  engine         = "postgres"
  engine_version = "16.4"
  instance_class = var.environment == "prod" ? "db.r7g.large" : "db.t4g.micro"

  allocated_storage     = 50
  max_allocated_storage = 500
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = "keycloak"
  username = "keycloak"

  # AWS creates and rotates the password. It never touches Terraform state.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.keycloak_db.id]
  multi_az               = var.environment == "prod"

  backup_retention_period   = 30
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "keycloak-${var.environment}-final"

  lifecycle {
    prevent_destroy = true
  }
}
```

> 🔐 **`manage_master_user_password = true` is a big deal.** Without it, the password would sit in your state file in plain text forever. With it, AWS Secrets Manager owns the password and Terraform only ever sees the secret's ARN. Do this for every database.

### 9.3 Stack 40 — Keycloak, NiFi, and the platform controllers

Providers here are configured from **data sources**, not from resources — this is what lets stack 40 exist independently of stack 20.

```hcl
# stacks/40-platform/providers.tf
data "aws_eks_cluster" "main" {
  name = "acme-${var.environment}"
}

data "aws_eks_cluster_auth" "main" {
  name = data.aws_eks_cluster.main.name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
```

**Keycloak:**

```hcl
resource "helm_release" "keycloak" {
  count = var.enable_keycloak ? 1 : 0

  name             = "keycloak"
  namespace        = "identity"
  create_namespace = true
  repository       = "https://charts.bitnami.com/bitnami"
  chart            = "keycloak"
  version          = "24.4.9"      # pin it. never use "latest".
  timeout          = 900
  atomic           = true          # roll back automatically if it fails
  wait             = true

  values = [yamlencode({
    replicaCount = var.environment == "prod" ? 3 : 1
    production   = true
    proxyHeaders = "xforwarded"

    postgresql = { enabled = false }   # we use RDS

    externalDatabase = {
      host                     = data.aws_db_instance.keycloak.address
      port                     = 5432
      database                 = "keycloak"
      user                     = "keycloak"
      existingSecret           = kubernetes_secret.keycloak_db[0].metadata[0].name
      existingSecretPasswordKey = "password"
    }

    ingress = {
      enabled          = true
      ingressClassName = "alb"
      hostname         = "auth.${var.base_domain}"
      annotations = {
        "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"     = "ip"
        "alb.ingress.kubernetes.io/certificate-arn" = data.aws_acm_certificate.main.arn
        "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      }
    }

    resources = {
      requests = { cpu = "500m", memory = "1Gi" }
      limits   = { memory = "2Gi" }
    }
  })]
}
```

> 💡 **`atomic = true` + `wait = true` is the best Helm setting pair.** If the release doesn't become healthy, Helm rolls it back and Terraform fails the job — instead of leaving you with a half-broken Keycloak and a green pipeline.

**Configuring Keycloak itself** (realms, clients for NiFi/API/React) with the Keycloak provider:

```hcl
provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_user
  password  = var.keycloak_admin_password   # from AWS Secrets Manager, see 10.4
  url       = "https://auth.${var.base_domain}"
}

resource "keycloak_realm" "platform" {
  realm                 = "platform"
  enabled               = true
  ssl_required          = "all"
  access_token_lifespan = "10m"
}

# The React app: public client, no secret (browsers can't keep secrets)
resource "keycloak_openid_client" "web" {
  realm_id                     = keycloak_realm.platform.id
  client_id                    = "acme-web"
  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  pkce_code_challenge_method   = "S256"
  valid_redirect_uris          = ["https://app.${var.base_domain}/*"]
  web_origins                  = ["https://app.${var.base_domain}"]
}

# The Java API: bearer-only, it just validates tokens
resource "keycloak_openid_client" "api" {
  realm_id              = keycloak_realm.platform.id
  client_id             = "acme-api"
  access_type           = "BEARER-ONLY"
}

# NiFi: confidential client with a secret
resource "keycloak_openid_client" "nifi" {
  realm_id            = keycloak_realm.platform.id
  client_id           = "nifi"
  access_type         = "CONFIDENTIAL"
  valid_redirect_uris = ["https://nifi.${var.base_domain}/nifi-api/access/oidc/callback"]
}
```

**NiFi** — a StatefulSet with persistent storage, logging in via Keycloak:

```hcl
resource "helm_release" "nifi" {
  count = var.enable_nifi ? 1 : 0

  name             = "nifi"
  namespace        = "data-platform"
  create_namespace = true
  repository       = "https://cetic.github.io/helm-charts"
  chart            = "nifi"
  version          = "1.2.1"
  timeout          = 1200          # NiFi is slow to start. Be patient.
  atomic           = true

  values = [yamlencode({
    replicaCount = var.nifi_node_count

    # Only schedule onto the tainted data node group
    nodeSelector = { workload = "data-platform" }
    tolerations = [{
      key      = "workload"
      operator = "Equal"
      value    = "data-platform"
      effect   = "NoSchedule"
    }]

    auth = {
      oidc = {
        enabled            = true
        discoveryUrl       = "https://auth.${var.base_domain}/realms/platform/.well-known/openid-configuration"
        clientId           = "nifi"
        clientSecret       = keycloak_openid_client.nifi.client_secret
        claimIdentifyingUser = "email"
      }
      admins = var.nifi_admin_emails
    }

    persistence = {
      enabled      = true
      storageClass = "gp3"
      # NiFi keeps FIVE separate repositories. Size them separately.
      dataStorage         = { size = "50Gi" }
      flowfileRepoStorage = { size = "20Gi" }
      contentRepoStorage  = { size = "200Gi" }
      provenanceRepoStorage = { size = "50Gi" }
      logStorage          = { size = "10Gi" }
    }

    zookeeper = { enabled = true, replicaCount = 3 }

    ingress = {
      enabled     = true
      className   = "alb"
      hosts       = [{ name = "nifi.${var.base_domain}" }]
      annotations = {
        "alb.ingress.kubernetes.io/scheme"          = "internal"
        "alb.ingress.kubernetes.io/certificate-arn" = data.aws_acm_certificate.main.arn
      }
    }

    resources = {
      requests = { cpu = "2", memory = "8Gi" }
      limits   = { memory = "12Gi" }
    }
  })]

  depends_on = [helm_release.keycloak]
}
```

> ⚠️ **Big NiFi warning:** those PVCs hold your flow definitions and in-flight data. Deleting the Helm release does **not** always delete PVCs — and sometimes it does, depending on the chart. Before any NiFi destroy, export the flow definition and snapshot the EBS volumes. Treat NiFi as stateful, like a database.

**IAM for the pods (Pod Identity — the modern way, simpler than IRSA):**

```hcl
resource "aws_iam_role" "nifi" {
  name = "nifi-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "nifi_kafka" {
  role = aws_iam_role.nifi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = data.aws_msk_cluster.main.arn
      },
      {
        Effect = "Allow"
        Action = ["kafka-cluster:*Topic*", "kafka-cluster:WriteData",
                  "kafka-cluster:ReadData"]
        Resource = "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/acme-${var.environment}/*/ingest.*"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "nifi" {
  cluster_name    = data.aws_eks_cluster.main.name
  namespace       = "data-platform"
  service_account = "nifi"
  role_arn        = aws_iam_role.nifi.arn
}
```

> 💡 The topic ARN ends in `ingest.*`. NiFi can only touch topics starting with `ingest.` — not the API's topics. **Least privilege, all the way down.**

### 9.4 Stack 50 — the Java API

```hcl
resource "aws_ecr_repository" "api" {
  name                 = "acme/java-api"
  image_tag_mutability = "IMMUTABLE"    # a tag can never be overwritten

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "helm_release" "java_api" {
  name      = "java-api"
  namespace = "apps"
  chart     = "../../charts/java-api"

  values = [yamlencode({
    image = {
      repository = aws_ecr_repository.api.repository_url
      tag        = var.api_image_tag       # set by the app pipeline
    }
    replicaCount = 3

    serviceAccount = { name = "java-api" }

    env = {
      SPRING_PROFILES_ACTIVE = var.environment
      KAFKA_BOOTSTRAP_SERVERS = data.aws_msk_cluster.main.bootstrap_brokers_sasl_iam
      KAFKA_SECURITY_PROTOCOL = "SASL_SSL"
      KAFKA_SASL_MECHANISM    = "AWS_MSK_IAM"
      OIDC_ISSUER_URI = "https://auth.${var.base_domain}/realms/platform"
      OIDC_AUDIENCE   = "acme-api"
    }

    # Spring Boot Actuator health endpoints
    livenessProbe  = { httpGet = { path = "/actuator/health/liveness",  port = 8080 } }
    readinessProbe = { httpGet = { path = "/actuator/health/readiness", port = 8080 } }

    resources = {
      requests = { cpu = "500m", memory = "1Gi" }
      limits   = { memory = "2Gi" }
    }
  })]
}
```

> 💡 **Note `var.api_image_tag`.** Terraform does **not** build the Java app. The Java repo's pipeline builds the image, pushes to ECR, and then either (a) triggers this pipeline with the new tag, or (b) — better — a GitOps tool like Argo CD or Flux watches ECR and rolls the deployment itself. **Terraform is for infrastructure; a deployment tool is for app versions.** Mixing them means every code deploy runs a Terraform apply against your whole platform. Don't.

### 9.5 Full dependency order

```
10-network   VPC, subnets, NAT, endpoints
     ↓
20-eks       EKS cluster, node groups, addons, Pod Identity agent
     ↓
30-data      MSK (Kafka), RDS (Keycloak DB), KMS keys, EFS
     ↓
40-platform  ALB controller → external-dns → cert-manager
             → Keycloak → Keycloak realms/clients
             → NiFi → Kafka UI
     ↓
50-apps      ECR repos, Java API, React S3 + CloudFront
```

The `needs:` chain in Part 5's pipeline enforces exactly this order.

---

## 10. Best practices checklist

### 10.1 State
- ✅ Remote S3 backend with **versioning** and **KMS encryption** on
- ✅ `use_lockfile = true` (not DynamoDB — it's deprecated)
- ✅ Block all public access on the state bucket
- ✅ One state file per layer per environment
- ✅ Separate AWS accounts for prod / staging / dev
- ✅ `resource_group:` on every apply job
- ✅ `-lock-timeout=300s` everywhere
- ❌ Never commit `.tfstate` or `.tfstate.backup` to Git
- ❌ Never let anyone `terraform apply` from a laptop against prod

### 10.2 Pipeline
- ✅ `plan` on merge requests; `apply` only on the default branch
- ✅ Apply the **saved plan file**, never re-plan inside apply
- ✅ `when: manual` on every prod apply
- ✅ Protected environments so only approvers can press ▶
- ✅ `TF_CLI_ARGS_init: "-reconfigure -input=false"` globally
- ✅ Publish `artifacts:reports:terraform` so reviewers see the summary in the MR
- ✅ Pin the Terraform image tag (`hashicorp/terraform:1.14.9`, never `:latest`)
- ✅ Scheduled drift detection with `-detailed-exitcode`
- ✅ Cache only `.terraform/providers`, keyed on `.terraform.lock.hcl`
- ❌ Never `-auto-approve` in prod
- ❌ Never store long-lived AWS keys — use OIDC

### 10.3 Code
- ✅ Pin `required_version` and every provider version
- ✅ Commit `.terraform.lock.hcl` with multi-platform hashes
- ✅ `default_tags` on the AWS provider
- ✅ `description` on every variable and output
- ✅ `validation` blocks on variables that can be typo'd
- ✅ `prevent_destroy` on databases, MSK, EKS, EFS, S3 data buckets
- ✅ Version your modules (`?ref=v1.4.0`), never point at `main`
- ✅ Prefer `for_each` over `count` for sets of things
- ✅ `moved` blocks when you rename resources, so Terraform doesn't destroy/recreate:
  ```hcl
  moved {
    from = aws_msk_cluster.kafka
    to   = aws_msk_cluster.main
  }
  ```
- ❌ Never configure a provider from a resource in the same stack

### 10.4 Secrets
- ✅ Use `manage_master_user_password` for RDS
- ✅ Read secrets from AWS Secrets Manager / SSM at plan time
- ✅ Use **ephemeral resources** (Terraform 1.10+) so secrets never enter state:
  ```hcl
  ephemeral "aws_secretsmanager_secret_version" "kc_admin" {
    secret_id = "keycloak/admin"
  }

  provider "keycloak" {
    url      = "https://auth.${var.base_domain}"
    username = "admin"
    password = ephemeral.aws_secretsmanager_secret_version.kc_admin.secret_string
  }
  ```
- ✅ Mark GitLab variables **Masked** and **Protected**
- ❌ Never put a secret in a `variable` default, a `.tfvars` in Git, or an `output`
- ❌ Remember: **anything in state is readable by anyone with state access.** Restrict the bucket accordingly.

### 10.5 Security scanning
Add these to the `security` stage: **tflint** (bad HCL), **Checkov** or **tfsec/Trivy** (insecure settings), **Infracost** (cost of the change, posted to the MR), and **OPA/Conftest or Sentinel** (org policy, e.g. "no public S3 buckets, ever").

---

## 11. Pros and cons of the big choices

### Terraform vs OpenTofu

| | HashiCorp Terraform | OpenTofu |
|---|---|---|
| License | BUSL (source-available) | MPL 2.0 (true open source) |
| Market share | Still the majority (~71% per CNCF Q1 2026 data) | Growing quickly |
| GitLab support | Old templates now retired | **First-class CI/CD component**, actively maintained |
| Unique features | Stacks, list resources / `terraform query`, actions block | Native state encryption, early variable evaluation |
| Verdict | Safe default; best ecosystem and docs | Great if you want the GitLab component or need client-side state encryption |

Commands are nearly identical (`tofu` instead of `terraform`), so switching later is cheap.

### GitLab-managed state vs S3 backend

| | GitLab-managed (HTTP backend) | S3 backend |
|---|---|---|
| Setup | Almost zero — GitLab hosts it | Bootstrap a bucket once |
| Auth | GitLab tokens, already there | AWS IAM / OIDC |
| Locking | Built in | `use_lockfile = true` |
| Encryption | At rest by GitLab; plan encryption optional | KMS, your key, your control |
| Access from outside GitLab | Awkward | Normal AWS tooling works |
| Compliance | State lives with your CI vendor | State lives in your own AWS account |
| Verdict | Great for small teams and getting started fast | ✅ Better for regulated AWS shops — **use this** |

### Monolithic state vs layered stacks

| | One big state | Layered stacks |
|---|---|---|
| Plan speed | 5–15 min | 20–90 sec each |
| Blast radius | Everything | One layer |
| Cross-references | Direct, easy | Needs remote state or data lookups |
| Onboarding | One folder to learn | More structure to explain |
| Parallel team work | Constant lock fights | Teams work independently |
| Verdict | Only for tiny projects | ✅ Use layers for anything real |

### `-target` vs feature flags vs separate stacks

| | `-target` | Feature flag | Separate stack |
|---|---|---|---|
| Speed to implement | Instant | ~30 min | ~2 hours |
| Reviewable in Git | ❌ No | ✅ Yes | ✅ Yes |
| Plan is complete/honest | ❌ No | ✅ Yes | ✅ Yes |
| Repeatable | ❌ No | ✅ Yes | ✅ Yes |
| Risk of hidden drift | 🔴 High | 🟢 None | 🟢 None |
| Good for | Emergencies, bootstrap | On/off per environment | Permanent separation |

### MSK vs Strimzi (Kafka on EKS)

| | Amazon MSK | Strimzi on EKS |
|---|---|---|
| Ops burden | AWS patches, scales, monitors | You do all of it |
| Cost | Higher per broker | Cheaper on raw compute |
| Auth | IAM (no passwords to manage) | mTLS / SCRAM — you manage certs |
| Terraform | `aws_msk_cluster` — simple | Helm + CRDs — more moving parts |
| Portability | AWS-only | Runs anywhere |
| Version control | AWS-approved versions only | Any version, any config |
| Verdict | ✅ **Start here.** IAM auth alone is worth it | Choose when you need exotic tuning or multi-cloud |

### Keycloak on EKS vs Amazon Cognito

| | Keycloak on EKS | Cognito |
|---|---|---|
| Features | Full OIDC/SAML, fine-grained authz, themes, federation | Simpler, fewer knobs |
| Ops | You run and patch it; needs RDS | Fully managed |
| Cost | EC2 + RDS | Per monthly active user |
| Portability | Runs anywhere | AWS-only |
| Verdict | Choose when you need SAML federation, custom flows, or portability — which is why it's in this example | Choose for simple consumer login |

---

## 12. Tips, gotchas, and error messages decoded

### Error messages you *will* hit

**`Error: Backend configuration changed`**
→ Add `-reconfigure` to your `init`. See Part 8.3.

**`Error: Error acquiring the state lock`**
→ Something else is running, or a job died. Check the pipeline first, then `terraform force-unlock <ID>`. Add `-lock-timeout=300s` to prevent it.

**`Error: Instance cannot be destroyed ... has lifecycle.prevent_destroy set`**
→ Working as designed. Someone tried to delete a database. Stop and think. If it's genuinely intended, remove the flag in a reviewed MR.

**`Error: Provider configuration not present`**
→ You removed a provider block but resources using it are still in state. Add the provider back, apply the destroy, *then* remove the block.

**`Error: Kubernetes cluster unreachable`**
→ Usually the chicken-and-egg problem, or the CI runner isn't allowed to reach a private EKS endpoint. Check `endpoint_public_access_cidrs` and that the runner's egress IP is in it.

**`Error: creating EKS Node Group: ... Instances failed to join the kubernetes cluster`**
→ Nine times out of ten: private subnets have no route to the internet (missing NAT gateway) or missing VPC endpoints for ECR/S3/STS.

**`Warning: Resource targeting is in effect`**
→ Your plan is incomplete. Fine for one job. Never end the day on it — run a full plan after.

### Practical tips

**Read the plan properly.** Learn these symbols:
```
  +  create
  -  destroy
  ~  update in place            ← usually safe
-/+  destroy and then create    ← ⚠️ DOWNTIME. Read this line carefully.
+/-  create then destroy        ← create_before_destroy; safer
  <= read (data source)
```
Any `-/+` on a database, MSK cluster, or EFS is a stop-and-discuss moment.

**Make the plan summary loud in CI:**
```bash
terraform show -json tfplan.bin \
  | jq -r '[.resource_changes[]? | select(.change.actions != ["no-op"])]
           | "\(length) changes: "
             + ([.[] | .change.actions[]] | group_by(.) 
                | map("\(.[0])=\(length)") | join(" "))'
```

**Fail the pipeline automatically if a plan deletes something in prod:**
```bash
DELETES=$(terraform show -json tfplan.bin \
  | jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length')
if [ "$DELETES" -gt 0 ] && [ "$TF_ENV" = "prod" ]; then
  echo "🛑 Plan deletes ${DELETES} resource(s) in prod. Needs a second approver."
  exit 1
fi
```

**Speed up big EKS plans:**
```bash
terraform plan -parallelism=30      # default is 10
```
Watch for AWS API rate limits (`ThrottlingException`) — if you see them, dial it back.

**Refresh is slow?** Sometimes you know nothing changed outside Terraform:
```bash
terraform plan -refresh=false     # much faster, but can miss real drift
```
Use it for iteration speed, never for the plan you actually apply.

**Set a job timeout.** EKS creation takes ~15 min, NiFi ~10 min, CloudFront ~5 min. Give apply jobs `timeout: 1h`, not the default 60 min shared with everything else.

**Set `interruptible: true` on plan jobs** so pushing a new commit cancels the old plan. Set it to **`false`** on apply jobs — you never want an apply killed halfway.

**Watch out for `helm_release` + `atomic`.** If a chart fails and rolls back, Terraform's state may not match what's in the cluster. Re-run the plan before assuming.

**Version your modules:**
```hcl
module "eks" {
  source = "git::https://gitlab.com/acme/tf-modules.git//eks?ref=v2.3.0"
}
```
Never `?ref=main`. Your Friday afternoon should not depend on what someone merged at 4pm.

**Bootstrapping a brand-new environment from zero** legitimately needs `-target`, once:
```bash
terraform apply -target=module.vpc
terraform apply -target=module.eks
terraform apply                    # everything else
```
Then never touch `-target` for that stack again. (Or split the stacks and skip this entirely.)

**Keep a `terraform state pull > backup.tfstate` step before any risky apply.** It costs two seconds and has saved many weekends.

---

## 13. Cheat sheet

### Everyday commands

```bash
# Setup
terraform init -reconfigure -backend-config=config/prod.s3.tfbackend
terraform init -migrate-state          # moving state (locally, with backup!)
terraform init -upgrade                # bump providers

# Checks
terraform fmt -recursive -diff
terraform validate
terraform plan -var-file=config/prod.tfvars -out=tfplan.bin
terraform show -no-color tfplan.bin
terraform show -json tfplan.bin | jq .

# Apply
terraform apply tfplan.bin             # ✅ the saved plan
terraform apply -auto-approve          # ❌ never in prod

# Partial apply
terraform plan -target=module.nifi -out=p.bin && terraform apply p.bin
terraform plan -replace=module.nifi[0].helm_release.this -out=p.bin
terraform apply -var="enable_nifi=false"          # ✅ preferred

# Partial destroy
terraform plan -destroy -target=module.nifi -out=d.bin
terraform show -no-color d.bin         # READ IT ALL
terraform apply d.bin

# State surgery
terraform state list
terraform state show module.nifi.helm_release.this
terraform state pull > backup.tfstate
terraform state rm module.msk          # forget, don't delete
terraform state mv module.old module.new
terraform force-unlock <LOCK_ID>

# Drift
terraform plan -detailed-exitcode      # 0=none 1=error 2=changes
```

### Address syntax

```
aws_s3_bucket.web                       resource
aws_s3_bucket.web["prod"]               for_each item
module.nifi                             whole module
module.nifi[0]                          count item
module.helm_app["nifi"]                 for_each module
module.platform.module.nifi             nested module
module.nifi.helm_release.this           resource inside module
```

### GitLab CI variables worth knowing

| Variable | Use |
|---|---|
| `$CI_COMMIT_BRANCH` | Gate applies to `main` |
| `$CI_DEFAULT_BRANCH` | Don't hardcode `main` |
| `$CI_MERGE_REQUEST_IID` | Review environment naming |
| `$CI_PIPELINE_SOURCE` | `"schedule"` for drift jobs |
| `$GITLAB_USER_LOGIN` | Log who pressed ▶ |
| `$CI_ENVIRONMENT_NAME` | Pass into tags |

### Terraform env vars for CI

| Variable | Value |
|---|---|
| `TF_IN_AUTOMATION` | `"true"` |
| `TF_INPUT` | `"false"` |
| `TF_CLI_ARGS_init` | `"-reconfigure -input=false"` |
| `TF_CLI_ARGS_plan` | `"-lock-timeout=300s"` |
| `TF_CLI_ARGS_apply` | `"-lock-timeout=300s"` |
| `TF_VAR_<name>` | Sets `var.<name>` — handy for secrets |
| `TF_WORKSPACE` | Selects a workspace without a command |
| `TF_LOG` | `DEBUG` when things go weird (⚠️ verbose, may log secrets) |

### The four rules to remember

1. **State is sacred.** Remote, versioned, encrypted, locked, backed up.
2. **Apply the plan you reviewed.** Save it as an artifact; never re-plan inside apply.
3. **`-target` is an ambulance, not a bus.** Use flags and stack splits for routine work.
4. **`-reconfigure` = forget the old backend. `-migrate-state` = move the data.** Never confuse them.

---

*Terraform 1.14.x / OpenTofu 1.10.x · GitLab 18.x · AWS provider 6.x · July 2026*
