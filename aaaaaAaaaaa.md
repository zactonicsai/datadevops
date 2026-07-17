# Terraform in GitLab Pipelines Without the Built-in OpenTofu Component

**A complete, beginner-friendly tutorial: plain Terraform jobs you write yourself, GitLab-managed state, manual apply & destroy stages, and secure AWS access with roles and policies**

*Written in plain, easy-to-understand language — but complete enough for real production use. Up to date as of mid-2026.*

---

## Table of Contents

1. [Background: What Are All These Things?](#1-background-what-are-all-these-things)
2. [Why "Without the Built-in Component"? (And What Changed in GitLab)](#2-why-without-the-built-in-component)
3. [Step-by-Step Setup: Your Hand-Written Pipeline](#3-step-by-step-setup-your-hand-written-pipeline)
4. [Deep Dive: How State Management Really Works](#4-deep-dive-how-state-management-really-works)
5. [AWS Connectivity: OIDC vs Access Keys](#5-aws-connectivity-oidc-vs-access-keys)
6. [AWS IAM Roles and Policies: Doing Permissions Right](#6-aws-iam-roles-and-policies-doing-permissions-right)
7. [Pipeline Design Best Practices](#7-pipeline-design-best-practices)
8. [Options Compared: Pros and Cons](#8-options-compared-pros-and-cons)
9. [Security Best Practices Checklist](#9-security-best-practices-checklist)
10. [Common Problems and Fixes](#10-common-problems-and-fixes)
11. [Glossary](#11-glossary)

---

## 1. Background: What Are All These Things?

Before we build anything, let's make sure every word makes sense. If you already know the basics, skip ahead to Section 2.

### What is Infrastructure as Code (IaC)?

Imagine you're building a LEGO castle. You could build it by hand, piece by piece, from memory. But what if you had to build 10 identical castles? Or rebuild it exactly after your little brother knocked it over?

The smart move is to **write down the instructions**. Then anyone (or any machine) can build the exact same castle, every time.

**Infrastructure as Code** is exactly that, but for cloud computers. Instead of clicking buttons in the AWS website to create servers, databases, and networks by hand, you *write the instructions in a file*. A tool then reads the file and builds everything for you — the same way, every time.

### What is Terraform?

**Terraform** is the most popular Infrastructure as Code tool. You write files ending in `.tf` that describe what you want:

```hcl
resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-cool-bucket-2026"
}
```

This says: "I want an S3 bucket (a storage folder in AWS) named `my-cool-bucket-2026`." Terraform reads it and creates it in AWS.

### The Three Magic Commands

Terraform has a simple rhythm, like "ready, set, go":

| Command | What it does | Kid-friendly version |
|---|---|---|
| `init` | Downloads plugins and connects to your state storage | "Unpack the toolbox" |
| `plan` | Shows what *would* change, without changing anything | "Show me the blueprint" |
| `apply` | Actually makes the changes in AWS | "Okay, build it!" |
| `destroy` | Deletes everything it created | "Tear it all down" |

### What is "State"? (Super Important!)

After Terraform builds your stuff, it needs to **remember what it built**. It writes this memory into a file called the **state file** (`terraform.tfstate`).

Think of state like a **class attendance sheet**. The teacher (Terraform) checks the sheet to know who's present (what already exists in AWS), who's new (what to create), and who left (what to delete).

Why does state matter so much?

- **Without it, Terraform is lost.** It won't know it already made your bucket and might make duplicates or fail.
- **It contains secrets.** Passwords and keys can end up in the state file in plain text. It must be stored somewhere safe — never in your Git repository!
- **Two people can't edit it at once.** If two pipelines write to state at the same time, the file gets corrupted — like two kids writing on the same attendance sheet at once. The fix is **state locking**: one at a time, please.

### What is GitLab CI/CD?

**GitLab** is a website where teams store code. **CI/CD** (Continuous Integration / Continuous Delivery) is GitLab's built-in robot assistant. Every time you push code, the robot runs jobs for you: test, build, deploy.

You control the robot with one file in your repository: **`.gitlab-ci.yml`**. It lists **stages** (like "validate", "plan", "apply") and **jobs** inside those stages.

A **manual stage** means the robot stops and waits for a human to press a ▶ button before continuing. This is perfect for `apply` and `destroy` — you never want a robot changing or deleting infrastructure without a human saying "yes, do it."

### What is AWS, and What Are IAM Roles & Policies?

**AWS (Amazon Web Services)** is a huge collection of rentable computers and services. Its permission system is called **IAM (Identity and Access Management)**:

- A **policy** is a written list of rules: "You may create S3 buckets. You may NOT delete databases." (Like rules posted on a classroom wall.)
- A **role** is like a **hall pass** with those rules attached. You *temporarily assume the role*, use it, and hand it back.
- **OIDC (OpenID Connect)** lets GitLab prove its identity to AWS *without a password*. GitLab shows AWS a signed, short-lived ID badge (a token); AWS checks the signature and hands over a temporary hall pass. No long-lived passwords to steal!

Now you have the vocabulary. One quick history lesson, then we build.

---

## 2. Why "Without the Built-in Component"?

A little context so you understand the landscape in 2026:

- In 2023, HashiCorp changed Terraform's license from open source to the more restrictive **BSL**. The community forked it into **OpenTofu**.
- Because of that license change, **GitLab removed its built-in Terraform CI/CD templates (`Terraform.gitlab-ci.yml`) and the `gitlab-terraform` helper script in GitLab 18.0**, and now points people at its **OpenTofu CI/CD component** instead.

But you may not want (or be able to use) that component. Common, perfectly good reasons:

- **Your company standardized on HashiCorp Terraform**, not OpenTofu (support contracts, HCP integration, audited toolchains).
- **Self-managed / air-gapped GitLab** that can't pull components from gitlab.com's catalog.
- **You want full control and zero magic.** Components hide details behind wrapper scripts (`gitlab-tofu`). Writing the jobs yourself means every flag is visible, debuggable, and yours.
- **Learning.** Hand-writing the pipeline teaches you what actually happens.

**Good news:** GitLab's **managed state backend was never removed** and works with plain Terraform just fine — it's an ordinary Terraform `http` backend. Everything the component does, we can do by hand in ~60 lines of YAML. That's this tutorial.

---

## 3. Step-by-Step Setup: Your Hand-Written Pipeline

We're going to build a pipeline that:

1. **Validates** your code (checks formatting and mistakes)
2. **Plans** the changes and saves the blueprint as an artifact
3. **Applies** only when a human clicks a button (**manual stage**)
4. **Destroys** only when a human clicks a different button (**manual stage**)
5. Stores state safely **inside GitLab** (encrypted, versioned, locked) — configured by hand, no wrapper
6. Logs into AWS **without any stored passwords**, using OIDC

### Step 0: What You Need

- A GitLab account (GitLab.com free tier works) and a project (repository)
- An AWS account where you're allowed to create IAM roles
- Maintainer access on the GitLab project

### Step 1: Create the AWS Side (OIDC Trust + Role + Policy)

We must teach AWS to trust GitLab. Do this once per AWS account.

**1a. Create the OIDC identity provider in AWS**

AWS Console: **IAM → Identity providers → Add provider**

- Provider type: **OpenID Connect**
- Provider URL: `https://gitlab.com` (or your self-hosted URL, e.g. `https://gitlab.mycompany.com` — it must be reachable by AWS over HTTPS)
- Audience: `https://gitlab.com` (must exactly match the `aud` we set in the pipeline later)

This registers GitLab's ID-badge printer with the AWS security office, so AWS can verify badges are genuine.

**1b. Create an IAM role that GitLab can assume**

Create a role (e.g., `gitlab-terraform-role`) with this **trust policy**. The trust policy answers: *who may use this hall pass?*

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
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
          "gitlab.com:sub": "project_path:mygroup/myproject:ref_type:branch:ref:main"
        }
      }
    }
  ]
}
```

Replace `111122223333` with your AWS account number and `mygroup/myproject` with your GitLab project path.

**Why the `sub` condition matters (a lot):** without it, *any* GitLab project could try to use your role. This line says: "Only pipelines from *this exact project*, on the *main branch*, may assume this role." A hall pass that works for one specific student only.

**1c. Attach a permissions policy to the role**

Start small. This example lets the role manage S3 buckets only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageProjectBuckets",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketTagging",
                 "s3:GetBucketLocation", "s3:ListBucket", "s3:GetBucketTagging",
                 "s3:PutBucketVersioning", "s3:GetBucketVersioning",
                 "s3:GetBucketPolicy", "s3:GetBucketAcl",
                 "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration"],
      "Resource": "arn:aws:s3:::my-team-*"
    }
  ]
}
```

Notice `Resource`: the role can only touch buckets whose names start with `my-team-`. That's **least privilege**: exactly the permissions needed, nothing more. (Much more in Section 6.)

### Step 2: Write Your Terraform Code

In your GitLab project, create:

**`main.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  # "http" means: my state lives on an HTTP server. GitLab IS that server.
  # We leave this block empty and pass the details at init time in CI,
  # so nothing secret or environment-specific is hard-coded here.
  backend "http" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "demo" {
  bucket = "my-team-demo-bucket-2026"

  tags = {
    ManagedBy   = "Terraform"
    Environment = "dev"
    Project     = "gitlab-tutorial"
  }
}
```

**`.gitignore`**

```
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
```

(State and plan files must never enter Git — they can contain secrets.)

### Step 3: Write the Pipeline (`.gitlab-ci.yml`) — the Heart of This Tutorial

No components, no wrappers. Every line visible:

```yaml
stages: [validate, plan, apply, cleanup]

# ---------------------------------------------------------------
# Variables shared by all jobs
# ---------------------------------------------------------------
variables:
  TF_STATE_NAME: "default"     # one state per environment; e.g. "production"
  TF_ADDRESS: "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/${TF_STATE_NAME}"
  TF_IN_AUTOMATION: "true"     # tells Terraform it's running in CI (cleaner output)
  AWS_ROLE_ARN: "arn:aws:iam::111122223333:role/gitlab-terraform-role"
  AWS_DEFAULT_REGION: "us-east-1"

# ---------------------------------------------------------------
# Default image + backend init for every job
# hashicorp/terraform images are Alpine-based; we add the AWS CLI
# in jobs that need to talk to AWS.
# ---------------------------------------------------------------
default:
  image:
    name: hashicorp/terraform:1.12    # PIN the version. Never "latest".
    entrypoint: [""]                  # the image's entrypoint would swallow our script
  before_script:
    - terraform init
        -input=false
        -backend-config="address=${TF_ADDRESS}"
        -backend-config="lock_address=${TF_ADDRESS}/lock"
        -backend-config="unlock_address=${TF_ADDRESS}/lock"
        -backend-config="username=gitlab-ci-token"
        -backend-config="password=${CI_JOB_TOKEN}"
        -backend-config="lock_method=POST"
        -backend-config="unlock_method=DELETE"
        -backend-config="retry_wait_min=5"

# ---------------------------------------------------------------
# Reusable AWS login via OIDC — no stored passwords anywhere.
# GitLab mints a short-lived signed token (id_tokens), and we trade
# it with AWS STS for temporary credentials (~1 hour lifetime).
# ---------------------------------------------------------------
.aws_oidc_auth:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com          # must match the IAM provider's audience
  before_script:
    - apk add --no-cache aws-cli jq    # tiny installs on the Alpine image
    - >
      CREDS=$(aws sts assume-role-with-web-identity
      --role-arn "${AWS_ROLE_ARN}"
      --role-session-name "gitlab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
      --web-identity-token "${GITLAB_OIDC_TOKEN}"
      --duration-seconds 3600
      --output json)
    - export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
    - export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
    - export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
    # then run the same init as the default before_script:
    - terraform init
        -input=false
        -backend-config="address=${TF_ADDRESS}"
        -backend-config="lock_address=${TF_ADDRESS}/lock"
        -backend-config="unlock_address=${TF_ADDRESS}/lock"
        -backend-config="username=gitlab-ci-token"
        -backend-config="password=${CI_JOB_TOKEN}"
        -backend-config="lock_method=POST"
        -backend-config="unlock_method=DELETE"
        -backend-config="retry_wait_min=5"

# ---------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------

validate:
  stage: validate
  script:
    - terraform fmt -check -recursive   # is the code neatly formatted?
    - terraform validate                # is the code even valid?

plan:
  stage: plan
  extends: .aws_oidc_auth
  script:
    - terraform plan -input=false -out=plan.tfplan
    - terraform show -no-color plan.tfplan > plan.txt   # human-readable copy
  artifacts:
    paths:
      - plan.tfplan
      - plan.txt
    expire_in: 7 days          # plans can contain secrets — don't keep forever
  environment:
    name: production
    action: prepare

apply:
  stage: apply
  extends: .aws_oidc_auth
  when: manual                  # <<< A HUMAN must click ▶
  allow_failure: false
  script:
    - terraform apply -input=false plan.tfplan   # apply the SAVED plan exactly
  dependencies:
    - plan                      # pull the plan artifact from the plan job
  environment:
    name: production
    action: start
  resource_group: production    # never two applies to prod at once
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH   # only from main

destroy:
  stage: cleanup
  extends: .aws_oidc_auth
  when: manual                  # <<< A HUMAN must click ▶
  script:
    - terraform destroy -input=false -auto-approve
  environment:
    name: production
    action: stop
  resource_group: production
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

**Reading this file like a story:**

1. **`TF_ADDRESS`** is built from GitLab's own predefined variables — it points at *this project's* state storage inside GitLab. Change `TF_STATE_NAME` to keep separate states like `dev` and `production`.
2. **The `init` flags are the whole "GitLab-managed state" trick.** We tell Terraform: state lives at this URL; lock it with an HTTP `POST` to `/lock`; unlock with `DELETE`; log in with the job's automatic short-lived password `CI_JOB_TOKEN`. GitLab handles encryption, versioning, and locking on its side. That's it — no wrapper script needed.
3. **`.aws_oidc_auth`** (the dot makes it a hidden, reusable template) requests a GitLab ID token and trades it with AWS for **temporary credentials that expire in one hour**. Note it overrides `before_script`, so it repeats the init — GitLab doesn't merge the default and the override, it replaces it. (A cleaner trick for big pipelines: put the init into a small shell script in your repo and call it from both places.)
4. **`plan`** saves two artifacts: the machine-readable `plan.tfplan` (which apply will execute) and a human-readable `plan.txt` (which reviewers can read from the job page without special tools).
5. **`apply` has `when: manual`.** In the pipeline view it shows a ▶ button. Nothing happens until a human clicks. When clicked, it applies **the saved plan file** — so what was reviewed is *exactly* what runs. If the world changed since the plan (someone else applied first), Terraform refuses with a "stale plan" error. That's a feature, not a bug.
6. **`destroy` is also manual**, in its own `cleanup` stage — tearing down infrastructure is always a deliberate human decision.
7. **`resource_group: production`** makes GitLab queue pipelines so two applies never run against production at the same time — a second lock layer on top of state locking.

### Step 4: Push and Watch It Run

```bash
git add main.tf .gitignore .gitlab-ci.yml
git commit -m "Terraform pipeline: manual apply/destroy, GitLab state, OIDC"
git push origin main
```

In GitLab go to **Build → Pipelines**:

```
validate ✅ → plan ✅ → apply ▶ (waiting) → destroy ▶ (waiting)
```

1. Open the **plan** job log (or download `plan.txt`). Look for `Plan: 1 to add, 0 to change, 0 to destroy.`
2. Happy? Click ▶ on **apply**. Watch the bucket appear in AWS.
3. Check your state: **Operate → Terraform states** in the left sidebar — you'll see the state file, every version, and which job changed it.
4. Done experimenting? Click ▶ on **destroy** to remove the bucket.

🎉 **You now have a complete, production-shaped pipeline with zero built-in components.** Everything from here is deeper understanding, options, and best practices.

### Optional Step 5: Same idea with the OpenTofu binary (still no component)

If you prefer OpenTofu's license but still want hand-written jobs, only two things change: the image and the command name.

```yaml
default:
  image:
    name: ghcr.io/opentofu/opentofu:1.10
    entrypoint: [""]
# ...and replace every `terraform` with `tofu`. All backend flags are identical.
```

### Option B (Step 6): Store State in AWS S3 Instead of GitLab

Since your Terraform manages **only AWS**, keeping the state *in AWS itself* is a very natural choice: one cloud holds both your infrastructure and its memory, your IAM roles already exist there, and your state doesn't depend on GitLab being up. Here's the complete swap.

**6a. Create the state bucket (one time, by hand or a tiny bootstrap config)**

There's a chicken-and-egg here: Terraform needs the bucket to store state, but the bucket must exist *before* Terraform's first run. So create it once outside the main pipeline — via the console, or these CLI commands:

```bash
aws s3api create-bucket --bucket my-team-terraform-state-111122223333 \
  --region us-east-1

# Versioning = your undo button for state disasters. Non-negotiable.
aws s3api put-bucket-versioning \
  --bucket my-team-terraform-state-111122223333 \
  --versioning-configuration Status=Enabled

# Encrypt everything at rest
aws s3api put-bucket-encryption \
  --bucket my-team-terraform-state-111122223333 \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

# State must NEVER be public
aws s3api put-public-access-block \
  --bucket my-team-terraform-state-111122223333 \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

(Adding your AWS account number to the bucket name is a common trick, because S3 bucket names must be unique across *all* of AWS worldwide.)

**Good news for 2026:** you do **not** need the old DynamoDB lock table anymore. Terraform 1.10+ supports **native S3 locking** — it writes a temporary `.tflock` file next to your state. One flag turns it on: `use_lockfile = true`.

**6b. Change the backend in `main.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  backend "s3" {}   # details injected at init time, same trick as before

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

**6c. Add state-bucket permissions to your IAM role**

The pipeline's role now needs access to the state bucket too. Add this statement to its policy:

```json
{
  "Sid": "TerraformStateAccess",
  "Effect": "Allow",
  "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": [
    "arn:aws:s3:::my-team-terraform-state-111122223333",
    "arn:aws:s3:::my-team-terraform-state-111122223333/production/*"
  ]
}
```

Note the `/production/*` path: each environment gets its own **key prefix** in the bucket (`production/terraform.tfstate`, `dev/terraform.tfstate`), and each environment's role can only reach its own path. `DeleteObject` is needed because native locking creates and removes the `.tflock` file. If you used KMS encryption, also grant `kms:Decrypt` and `kms:GenerateDataKey` on that key.

**6d. Rewire the pipeline — and mind the ordering!**

Here's the one big difference from the GitLab backend: with S3, **`terraform init` itself talks to AWS**. So AWS login must happen **before** init — the order inside `before_script` matters. The `CI_JOB_TOKEN` backend flags disappear entirely.

```yaml
stages: [validate, plan, apply, cleanup]

variables:
  TF_IN_AUTOMATION: "true"
  AWS_ROLE_ARN: "arn:aws:iam::111122223333:role/gitlab-terraform-role"
  AWS_DEFAULT_REGION: "us-east-1"
  TF_STATE_BUCKET: "my-team-terraform-state-111122223333"
  TF_STATE_KEY: "production/terraform.tfstate"

default:
  image:
    name: hashicorp/terraform:1.12
    entrypoint: [""]

# AWS login FIRST, then init against S3 — order matters!
.aws_auth_and_init:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  before_script:
    - apk add --no-cache aws-cli jq
    - >
      CREDS=$(aws sts assume-role-with-web-identity
      --role-arn "${AWS_ROLE_ARN}"
      --role-session-name "gitlab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
      --web-identity-token "${GITLAB_OIDC_TOKEN}"
      --duration-seconds 3600
      --output json)
    - export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .Credentials.AccessKeyId)
    - export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .Credentials.SecretAccessKey)
    - export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .Credentials.SessionToken)
    - terraform init
        -input=false
        -backend-config="bucket=${TF_STATE_BUCKET}"
        -backend-config="key=${TF_STATE_KEY}"
        -backend-config="region=${AWS_DEFAULT_REGION}"
        -backend-config="use_lockfile=true"
        -backend-config="encrypt=true"

validate:
  stage: validate
  script:
    - terraform init -input=false -backend=false   # no state needed to validate!
    - terraform fmt -check -recursive
    - terraform validate

plan:
  stage: plan
  extends: .aws_auth_and_init
  script:
    - terraform plan -input=false -out=plan.tfplan
    - terraform show -no-color plan.tfplan > plan.txt
  artifacts:
    paths: [plan.tfplan, plan.txt]
    expire_in: 7 days
  environment:
    name: production
    action: prepare

apply:
  stage: apply
  extends: .aws_auth_and_init
  when: manual                  # <<< human clicks ▶
  allow_failure: false
  script:
    - terraform apply -input=false plan.tfplan
  dependencies: [plan]
  environment:
    name: production
    action: start
  resource_group: production
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

destroy:
  stage: cleanup
  extends: .aws_auth_and_init
  when: manual                  # <<< human clicks ▶
  script:
    - terraform destroy -input=false -auto-approve
  environment:
    name: production
    action: stop
  resource_group: production
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

**What changed vs the GitLab-backend version, in one glance:**

| | GitLab-managed state | S3 state |
|---|---|---|
| Backend block | `backend "http" {}` | `backend "s3" {}` |
| Init credentials | `CI_JOB_TOKEN` (automatic) | AWS credentials — so **auth before init** |
| Locking | HTTP lock endpoints | `use_lockfile=true` (native `.tflock`) |
| `validate` job | Needed backend init flags | Can skip backend entirely (`-backend=false`) |
| Extra IAM | none | State-bucket (+ KMS) permissions on the role |
| Bootstrap | nothing | Create the bucket once, outside the pipeline |

Everything else — the manual apply/destroy gates, plan artifacts, `resource_group`, OIDC trust policy — stays exactly the same. One small trade to know about: state versions and the unlock button no longer appear under GitLab's *Operate → Terraform states* UI; your history lives in S3 object versions instead, and a stuck lock is cleared with `terraform force-unlock <lock-id>` (the error message prints the ID).

---

## 4. Deep Dive: How State Management Really Works

### Where can state live? Your main choices

1. **GitLab-managed state (what we used)** — GitLab stores it, encrypts it at rest, versions every change, locks it during runs, and gates access with your project's normal permissions. Available on Free, Premium, and Ultimate, on GitLab.com and self-managed.
2. **AWS S3 backend** — state lives in an S3 bucket you own. Modern Terraform (1.10+) supports **native S3 locking** with `use_lockfile = true`, so the classic extra DynamoDB lock table is no longer required for new setups.
3. **Hosted platforms** (HCP Terraform, Spacelift, Scalr, env0…) — they manage state *and* runs.
4. **Local state** — a file on your laptop. Fine for a 10-minute experiment; never for teams or CI. If the laptop dies, your infrastructure's memory dies with it.

### GitLab state: the useful details

- **Viewing:** *Operate → Terraform states* shows each state, every version, who/what changed it. You can download versions, lock/unlock manually, and delete states.
- **Multiple states per project:** the state name is part of the URL (`.../terraform/state/<name>`). Use one per environment: `dev`, `staging`, `production`. Small separate states = smaller blast radius and faster plans.
- **Working locally against the same state:** run the same `terraform init -backend-config=...` on your laptop, but use your username and a **Personal Access Token** (with `api` scope) as the password instead of `CI_JOB_TOKEN`. Same state everywhere; no laptop-vs-CI drift.
- **Reading another project's outputs:** GitLab state works as a `terraform_remote_state` data source, so your "app" project can read outputs (like a VPC ID) from your "network" project.
- **Stuck locks:** if a job dies mid-run, the state can stay locked. Fix in the UI: *Operate → Terraform states → ⋮ → Unlock*.
- **A real gotcha with `-backend-config` flags:** backend settings can get cached into the plan and carried into apply, occasionally causing lock weirdness. If you hit this, switch from flags to the equivalent **environment variables** (`TF_HTTP_ADDRESS`, `TF_HTTP_LOCK_ADDRESS`, `TF_HTTP_UNLOCK_ADDRESS`, `TF_HTTP_USERNAME`, `TF_HTTP_PASSWORD`, `TF_HTTP_LOCK_METHOD`, `TF_HTTP_UNLOCK_METHOD`) set in `variables:` — the backend reads them automatically and your `init` shrinks to just `terraform init -input=false`. Many teams prefer this style from day one.
- **Disaster-recovery thought:** GitLab state is encrypted with keys tied to your GitLab instance. If GitLab is down and your Terraform code *is what runs GitLab*, you can't read the state to fix GitLab. Chicken-and-egg! For that special bootstrap infrastructure, keep state elsewhere (e.g., S3) or keep exported backups.

### Golden rules of state (tattoo these on your brain)

1. **Never commit `terraform.tfstate` to Git.** It holds secrets in plain text.
2. **Always use locking.** Our HTTP backend flags enable it.
3. **One state per environment.** Don't mix dev and prod in one file.
4. **Never hand-edit state.** Use `terraform state mv` / `state rm` / `import` for surgery.
5. **Keep versioning on** so you can roll back a bad state (GitLab does this automatically).

---

## 5. AWS Connectivity: OIDC vs Access Keys

Two ways a pipeline can prove itself to AWS.

### Option A: Static access keys (the old way)

Create an IAM user, generate `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, paste them into GitLab **Settings → CI/CD → Variables** (masked + protected). Terraform's AWS provider picks them up automatically — no other pipeline changes.

**Pros**

- Dead simple; working in 5 minutes
- Works on any GitLab version, any runner

**Cons**

- Keys **never expire** unless you rotate them — a stolen key works forever
- Anyone with enough project access could exfiltrate them via a malicious job
- You must build (and remember!) a rotation process
- Fails most security audits in 2026

### Option B: OIDC / ID tokens (the modern way — what we built)

GitLab mints a short-lived signed token (`id_tokens:` keyword); the job trades it with AWS STS for temporary credentials that expire in about an hour.

**Pros**

- **No long-lived secrets exist anywhere.** Nothing to steal, nothing to rotate.
- Fine-grained trust: AWS restricts by project, branch, tag, or environment via the token's `sub` claim
- CloudTrail shows exactly which pipeline assumed the role
- Documented best practice from both GitLab and AWS

**Cons**

- More setup (identity provider + trust policy)
- Trust-policy conditions are easy to get subtly wrong — test them
- Self-managed GitLab must be reachable by AWS over HTTPS (to fetch signing keys); tricky in air-gapped setups (where an instance-profile runner, below, is the usual answer)

**Verdict:** use OIDC unless you physically can't. Keep static keys for throwaway experiments only.

### Bonus options

- **Self-hosted runners on EC2/EKS with instance profiles:** the runner machine itself holds an IAM role; jobs inherit credentials with *zero* pipeline configuration and no dependency on AWS reaching GitLab. Excellent for air-gapped GitLab. Caution: every job on that runner shares those permissions — dedicate runners per team/permission level.
- **Assume-role chaining:** one "landing" role that may assume per-environment roles (`dev-role`, `prod-role`). Clean for multi-account AWS organizations.

---

## 6. AWS IAM Roles and Policies: Doing Permissions Right

### The big idea: least privilege

Give the pipeline the *minimum* permissions for its job. If it only builds S3 buckets and EC2 servers, it must not be able to delete IAM users or read every database.

Why? If your pipeline is ever tricked (malicious merge request, compromised dependency, leaked token), the attacker gets *exactly* the pipeline's permissions. Small permissions = small disaster. Admin permissions = total disaster.

### A practical permission strategy

1. **List the AWS actions your code actually needs.** Tools like `iamlive` or IAM Access Analyzer can record the API calls made during plan/apply and draft a policy for you.
2. **Split read vs write.** Give `plan` a **read-only role** (plan only *reads* AWS to compare against state) and `apply`/`destroy` a **write role**. Two `.aws_oidc_auth`-style blocks with two different `AWS_ROLE_ARN`s — easy with our hand-written pipeline.
3. **Scope resources with ARNs and conditions.** `"Resource": "arn:aws:s3:::my-team-*"` beats `"Resource": "*"` every day.
4. **Use permissions boundaries** if the pipeline creates IAM roles itself, so it can never create a role more powerful than the boundary allows. (Blocks the classic "pipeline creates an admin role, then assumes it" escalation.)
5. **Separate AWS accounts per environment** (dev account, prod account) — the strongest wall AWS offers; assume a different role per account.
6. **Add organization-level deny guardrails** (Service Control Policies), e.g. "no one may delete CloudTrail logs — not even admins."

### Example: a stricter trust policy for a prod-only apply role

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/gitlab.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "gitlab.com:aud": "https://gitlab.com",
        "gitlab.com:sub": "project_path:mygroup/myproject:ref_type:branch:ref:main"
      }
    }
  }]
}
```

Pair this with GitLab **protected branches** and **protected environments** (Premium+) so only approved humans can even click apply — then GitLab *and* AWS both enforce the rule.

---

## 7. Pipeline Design Best Practices

### The plan-file pattern (non-negotiable)

Always `plan -out=plan.tfplan` → save as artifact → `apply plan.tfplan`. The human approves *exactly* what runs. If state changed in between, apply errors out — the safety system working as intended.

### Manual gates done well

- `when: manual` on `apply` and `destroy` — always.
- `allow_failure: false` on apply so later stages don't sneak past a skipped apply.
- Use **GitLab environments** (`environment: name: production`) — you get deployment history ("who deployed what, when") and can attach **protected environment approvals** so, say, two seniors must approve prod applies before the button even becomes clickable.
- `resource_group: production` queues concurrent pipelines — no simultaneous prod applies.

### Merge-request flow (how teams actually work day to day)

- **On merge requests:** run `fmt`, `validate`, security scans, and a **speculative plan** (plan only, read-only role, no artifact needed). Reviewers see in the MR exactly what infrastructure will change — a preview before publishing.
- **On main:** plan again, then the manual apply.
- **Destroy jobs:** many teams include destroy only for ephemeral/dev environments, or gate it behind an explicit variable (`if: $DESTROY == "true"` on a manually triggered pipeline), so nobody fat-fingers production away.

Example rules for a speculative MR plan:

```yaml
mr_plan:
  stage: plan
  extends: .aws_oidc_auth_readonly     # a second auth block with the read-only role
  script:
    - terraform plan -input=false
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
```

(Remember to loosen that role's trust policy `sub` to allow branches, e.g. `...:ref_type:branch:ref:*` — read-only, so the risk is low.)

### Other habits that pay off

- **Pin versions of everything:** Terraform version, provider versions (`~> 6.0`), Docker image tags. "latest" today may break next Tuesday.
- **Deduplicate the init:** put the `terraform init ...` into `scripts/tf-init.sh` in your repo and call it from every job — one place to change, no drift between jobs. (This is you writing your own tiny wrapper — the same idea as `gitlab-terraform`, but fully yours.)
- **Scheduled drift detection:** a nightly scheduled pipeline that runs `plan`; if it shows changes, someone edited AWS by hand ("click-ops") and your code no longer matches reality. Alert on it.
- **Scan your IaC:** add `checkov`, `tfsec`/`trivy`, or GitLab's IaC scanning as a validate-stage job to catch "S3 bucket is public" *before* apply.
- **Cache providers** to speed up init:

  ```yaml
  variables:
    TF_PLUGIN_CACHE_DIR: "$CI_PROJECT_DIR/.terraform.d/plugin-cache"
  cache:
    key: terraform-plugins
    paths: [.terraform.d/plugin-cache]
  ```

- **Version shared modules** in GitLab's Terraform Module Registry instead of copy-pasting between projects.
- **Don't re-run stale apply jobs.** Apply must execute the plan from the *same pipeline/commit*; after new commits, run a fresh pipeline.

---

## 8. Options Compared: Pros and Cons

### Hand-written jobs (this tutorial) vs GitLab's OpenTofu component

| | Hand-written (ours) | OpenTofu CI/CD component |
|---|---|---|
| Transparency | Every flag visible and debuggable | Wrapper (`gitlab-tofu`) hides details |
| Tool choice | Terraform **or** OpenTofu, any version/image | OpenTofu-focused |
| Air-gapped / self-managed | Works anywhere (mirror the Docker image) | Needs access to the component catalog |
| Maintenance | You update YAML when things change | GitLab maintains the templates for you |
| Setup effort | ~60 lines of YAML (once) | A few `include:` lines |
| Best for | Terraform shops, air-gapped, control-lovers, learners | Teams happy on OpenTofu wanting minimum YAML |

### Terraform vs OpenTofu (both work with everything in this tutorial)

| | Terraform (HashiCorp) | OpenTofu (Linux Foundation) |
|---|---|---|
| License | BSL (restricted) | MPL-2.0 (fully open source) |
| Compatibility | — | Near-total; same `.tf` files, same backends |
| Extra features | Stacks, HCP integration | Built-in **state encryption**, early variable evaluation |
| Command | `terraform` | `tofu` |

### State backend: GitLab-managed vs S3

| | GitLab-managed state | AWS S3 backend |
|---|---|---|
| Setup | A handful of init flags/env vars | Create bucket, versioning, encryption, `use_lockfile = true` |
| Locking | Built-in via HTTP lock endpoints | Native lockfile (TF 1.10+); DynamoDB only for legacy setups |
| Access control | GitLab project permissions + job token | IAM policies |
| History/UI | Friendly UI: versions, who changed what, unlock button | S3 versioning, no friendly UI |
| Gotchas | Chicken-and-egg if this state describes GitLab's own infra | You must secure the bucket yourself (block public access!) |
| Best for | Teams living in GitLab (most readers) | AWS-heavy orgs; GitLab-bootstrap infra |

### Manual gates: three strength levels

1. **`when: manual`** — free, simple; anyone who can run pipelines can click. The minimum bar.
2. **+ Protected branches** — nothing reaches main (and thus the apply button) without review.
3. **+ Protected environments with approvals (Premium/Ultimate)** — named approvers must sign off before the job can even start; full audit trail. Use all three for production.

### DIY GitLab pipeline vs hosted platforms (HCP Terraform, Spacelift, Scalr, env0…)

- **DIY GitLab:** free/cheap, one tool, full control; you maintain YAML and policies yourself.
- **Hosted platforms:** built-in policy engines (OPA/Sentinel), drift detection, RBAC, cost estimation; extra cost and an extra vendor. Start DIY; consider a platform at dozens-of-workspaces scale.

---

## 9. Security Best Practices Checklist

- ☐ **OIDC, not static keys** for AWS auth
- ☐ Trust policies pinned to **project + branch (+ environment)** via the `sub` claim
- ☐ **Least-privilege IAM**; separate read-only (plan) and write (apply) roles
- ☐ **State never in Git**; `.gitignore` covers `*.tfstate*`, `*.tfplan`, `.terraform/`
- ☐ **State encrypted + versioned + locked** (GitLab does all three server-side)
- ☐ **Plan artifacts expire** (`expire_in`) and artifact access is restricted — plans can contain secrets
- ☐ Sensitive CI/CD variables are **masked** and **protected**
- ☐ **Protected branch** on main; **protected environment** on production
- ☐ `apply` and `destroy` are **manual** and restricted to the default branch
- ☐ **IaC scanning** (checkov/trivy/GitLab SAST-IaC) on every MR
- ☐ **Versions pinned** (Terraform, providers, Docker images)
- ☐ **Scheduled drift detection** exists and alerts
- ☐ Secrets come from a manager (GitLab variables, AWS Secrets Manager, Vault/OpenBao) — never hard-coded in `.tf`
- ☐ Production runners are **dedicated**, not shared with untrusted projects

---

## 10. Common Problems and Fixes

**"Error acquiring the state lock"**
A previous job died holding the lock. *Operate → Terraform states → your state → Unlock*, then investigate why the job died before re-running.

**`apply` says the saved plan is stale**
State changed between plan and apply (someone else applied first). The safety system working. Run a fresh pipeline.

**AWS: "Not authorized to perform sts:AssumeRoleWithWebIdentity"**
Almost always a trust-policy mismatch. Check: the audience string matches `aud` *exactly*; the `sub` pattern matches your real project path and branch (case-sensitive!); the provider URL is correct.

**Pipeline works on main, fails on feature branches**
Your trust policy pins `ref:main` — branches can't assume the role. Correct design! Give MR pipelines a separate read-only role with a looser `sub` pattern.

**`before_script` from `.aws_oidc_auth` seems to skip the init**
Remember: an `extends` block's `before_script` **replaces** the default one; GitLab doesn't merge them. That's why our auth block repeats the init (or use the shared `tf-init.sh` script trick).

**"Backend configuration changed"**
You changed the state name or backend settings. Run `terraform init -migrate-state` deliberately, or `-reconfigure` if the old backend is truly irrelevant. Never guess with state migration.

**Locking acts strangely in CI (can't lock/unlock)**
Backend flags cached in the plan can cause this. Switch from `-backend-config=` flags to the `TF_HTTP_*` environment variables (Section 4).

**Two pipelines fighting each other on prod**
Add `resource_group:` to apply/destroy jobs so GitLab serializes them.

**Old tutorials mention `Terraform.gitlab-ci.yml` or `gitlab-terraform`**
Both were removed in GitLab 18.0. Our hand-written jobs replace them one-for-one.

---

## 11. Glossary

- **Artifact** — a file a CI job saves and hands to later jobs (our `plan.tfplan`).
- **Backend** — where Terraform stores state (GitLab HTTP, S3, local…).
- **BSL** — Business Source License; Terraform's restrictive 2023 license that led to OpenTofu and GitLab dropping its Terraform templates.
- **CI_JOB_TOKEN** — a short-lived password GitLab auto-creates for each job; how the pipeline may read/write your state.
- **Drift** — real AWS no longer matches your code (someone clicked around in the console).
- **HCL** — the language of `.tf` files.
- **IAM** — AWS's permission system (users, roles, policies).
- **Least privilege** — granting only the permissions actually needed.
- **Lock** — the "one at a time" rule on state that prevents corruption.
- **Manual job** — a CI job that waits for a human to press ▶.
- **OIDC** — passwordless, short-lived identity proof between systems.
- **Plan file** — the saved blueprint (`-out=plan.tfplan`) that apply executes exactly.
- **Protected branch/environment** — GitLab settings restricting who may push/deploy.
- **resource_group** — GitLab keyword that queues jobs so only one runs against an environment at a time.
- **State** — Terraform's memory of what it built; the most precious file in the system.
- **STS** — AWS Security Token Service; hands out temporary credentials.
- **Trust policy** — the part of an IAM role that says *who* may assume it.

---

## Wrap-Up

You now have, with zero built-in components or wrapper scripts:

1. A working hand-written pipeline: **validate → plan → manual apply → manual destroy**
2. **GitLab-managed state** — encrypted, versioned, and locked — configured yourself with a few init flags (or `TF_HTTP_*` variables)
3. **Passwordless AWS access** via OIDC, with a role locked to your exact project and branch
4. **Least-privilege roles and policies**, plus the strategy to keep them tight
5. Clear-eyed trade-offs: Terraform vs OpenTofu, GitLab vs S3 state, simple vs strict approval gates

The single most important habit: **humans approve changes; robots execute exactly what was approved.** Every technique here — plan artifacts, manual stages, protected environments, scoped roles — exists to enforce that one sentence.

Happy building! 🏗️
