# Terraform in GitLab Pipelines: The Complete Beginner-Friendly Tutorial

**Setting up Terraform/OpenTofu in GitLab CI/CD with managed state, manual apply & destroy stages, and secure AWS access**

*Written in plain, easy-to-understand language — but complete enough for real production use. Up to date as of mid-2026.*

---

## Table of Contents

1. [Background: What Are All These Things?](#1-background-what-are-all-these-things)
2. [Important 2026 Update You Must Know First](#2-important-2026-update-you-must-know-first)
3. [Step-by-Step Setup: Your First Working Pipeline](#3-step-by-step-setup-your-first-working-pipeline)
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

Before we build anything, let's make sure every word makes sense. If you already know the basics, skip to Section 2.

### What is Infrastructure as Code (IaC)?

Imagine you're building a LEGO castle. You could build it by hand, piece by piece, from memory. But what if you had to build 10 identical castles? Or rebuild it exactly after your little brother knocked it over?

The smart move is to **write down the instructions**. Then anyone (or any machine) can build the exact same castle, every time.

**Infrastructure as Code** is exactly that, but for cloud computers. Instead of clicking buttons in the AWS website to create servers, databases, and networks by hand, you *write the instructions in a file*. A tool then reads the file and builds everything for you — the same way, every time.

### What is Terraform (and OpenTofu)?

**Terraform** is the most popular tool for Infrastructure as Code. You write files ending in `.tf` that describe what you want:

```hcl
resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-cool-bucket-2026"
}
```

This says: "I want an S3 bucket (a storage folder in AWS) named `my-cool-bucket-2026`." Terraform reads it and creates it in AWS.

**OpenTofu** is a free, open-source copy of Terraform. In 2023, the company behind Terraform (HashiCorp) changed its license to a more restrictive one (called BSL). The community responded by creating OpenTofu — it works almost exactly the same, uses the same `.tf` files, and is the version **GitLab now officially supports and recommends**. In this tutorial the commands work for both; where it matters, we'll point it out.

### The Three Magic Commands

Terraform/OpenTofu has a simple rhythm, like "ready, set, go":

| Command | What it does | Kid-friendly version |
|---|---|---|
| `init` | Downloads plugins and connects to your state storage | "Unpack the toolbox" |
| `plan` | Shows what *would* change, without changing anything | "Show me the blueprint of what you'll do" |
| `apply` | Actually makes the changes in AWS | "Okay, build it!" |
| `destroy` | Deletes everything it created | "Tear it all down" |

### What is "State"? (Super Important!)

Here's the tricky part. After Terraform builds your stuff, it needs to **remember what it built**. It writes this memory into a file called the **state file** (`terraform.tfstate`).

Think of state like a **class attendance sheet**. The teacher (Terraform) checks the sheet to know who's present (what exists in AWS), who's new (what to create), and who left (what to delete).

Why does state matter so much?

- **Without it, Terraform is lost.** It won't know it already made your bucket, and might make a duplicate or fail.
- **It contains secrets.** Passwords, keys, and private info can end up in the state file in plain text. It must be stored somewhere safe — never in your Git repository!
- **Two people can't edit it at once.** If two pipelines run at the same time and both write to state, the file gets corrupted — like two kids writing on the same attendance sheet at the same time. The fix is **state locking**: one at a time, please.

### What is GitLab CI/CD?

**GitLab** is a website where teams store code (like Google Docs, but for programmers). **CI/CD** (Continuous Integration / Continuous Delivery) is GitLab's built-in robot assistant. Every time you push code, the robot can automatically run jobs for you: test the code, build it, deploy it.

You control the robot with one file in your repository: **`.gitlab-ci.yml`**. It lists **stages** (like "validate", "plan", "apply") and **jobs** inside those stages.

A **manual stage** means the robot stops and waits for a human to press a button before continuing. This is perfect for `apply` and `destroy` — you never want a robot deleting your infrastructure without a human saying "yes, do it."

### What is AWS, and What Are IAM Roles & Policies?

**AWS (Amazon Web Services)** is a huge collection of rentable computers and services. To use it safely, AWS has a permission system called **IAM (Identity and Access Management)**:

- A **policy** is a written list of rules: "You may create S3 buckets. You may NOT delete databases." (Like the rules posted on a classroom wall.)
- A **role** is like a **hall pass** with those rules attached. You don't carry the permissions all the time — you *temporarily assume the role*, use it, and hand it back.
- **OIDC (OpenID Connect)** is a way for GitLab to prove its identity to AWS *without a password*. GitLab shows AWS a signed, short-lived ID badge (a token), AWS checks the signature, and hands over a temporary hall pass. No long-lived passwords to steal!

Now you have all the vocabulary. Let's talk about one important recent change, then build the real thing.

---

## 2. Important 2026 Update You Must Know First

If you read older tutorials (before 2025), they will tell you to use GitLab's built-in template `Terraform.gitlab-ci.yml` and the `gitlab-terraform` helper script. **Don't.** Here's why:

- Because of Terraform's license change (BSL), **GitLab removed its built-in Terraform CI/CD templates and the `gitlab-terraform` wrapper in GitLab 18.0**.
- The **recommended replacement is the official OpenTofu CI/CD component**, which uses a wrapper CLI called **`gitlab-tofu`**.
- Good news: **GitLab-managed state still works with both Terraform and OpenTofu.** The state backend didn't change.
- Also new-ish: modern Terraform (1.10+) and OpenTofu (1.9+/1.10+) support **native S3 state locking with lockfiles**, so the old "S3 + DynamoDB table" pattern is no longer required if you use an S3 backend. (More in Section 8.)

**Bottom line for 2026:** For a fresh setup, use **OpenTofu + the official OpenTofu CI/CD component + GitLab-managed state + OIDC to AWS**. That's exactly what we'll build. If your company requires HashiCorp Terraform specifically, everything in this tutorial still applies — you'll just maintain your own Terraform Docker image and write the jobs by hand (we show that too).

---

## 3. Step-by-Step Setup: Your First Working Pipeline

We're going to build a pipeline that:

1. **Validates** your code (checks for typos and mistakes)
2. **Plans** the changes (shows the blueprint)
3. **Applies** only when a human clicks a button (**manual stage**)
4. **Destroys** only when a human clicks a different button (**manual stage**)
5. Stores state safely **inside GitLab** (encrypted, versioned, locked)
6. Logs into AWS **without any stored passwords**, using OIDC

### Step 0: What You Need

- A GitLab account (GitLab.com free tier works) and a project (repository)
- An AWS account where you're allowed to create IAM roles
- Maintainer access on the GitLab project

### Step 1: Create the AWS Side (OIDC Trust + Role + Policy)

We must teach AWS to trust GitLab. Do this once per AWS account.

**1a. Create the OIDC identity provider in AWS**

In the AWS Console: **IAM → Identity providers → Add provider**

- Provider type: **OpenID Connect**
- Provider URL: `https://gitlab.com` (or your self-hosted GitLab URL, e.g. `https://gitlab.mycompany.com`)
- Audience: `https://gitlab.com` (must match the `aud` we'll set in the pipeline later)

This is like registering GitLab's ID-badge printer with the AWS security office, so AWS can verify badges are real.

**1b. Create an IAM role that GitLab can assume**

Create a role (e.g., `gitlab-terraform-role`) with this **trust policy**. The trust policy answers: *who is allowed to use this hall pass?*

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

**Why the `sub` condition matters (a lot):** without it, *any* GitLab project could try to use your role. This line says: "Only pipelines from *this exact project*, running on the *main branch*, may assume this role." That's like a hall pass that only works for one specific student.

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
                 "s3:GetBucketPolicy", "s3:GetBucketAcl", "s3:GetEncryptionConfiguration",
                 "s3:PutEncryptionConfiguration"],
      "Resource": "arn:aws:s3:::my-team-*"
    }
  ]
}
```

Notice the `Resource` line: the role can only touch buckets whose names start with `my-team-`. This is **least privilege**: give exactly the permissions needed, nothing more. (Much more on this in Section 6.)

### Step 2: Write Your Terraform/OpenTofu Code

In your GitLab project, create these files.

**`main.tf`**

```hcl
terraform {
  required_version = ">= 1.8"

  # The backend block is intentionally almost empty.
  # GitLab's gitlab-tofu wrapper fills in the details automatically
  # using CI/CD variables (address, username, password, lock settings).
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
    ManagedBy   = "OpenTofu"
    Environment = "dev"
    Project     = "gitlab-tutorial"
  }
}
```

**What's happening here?**

- `backend "http" {}` — this tells Terraform/OpenTofu "my state lives on an HTTP server." GitLab *is* that server. The wrapper script injects the exact URL and credentials during the pipeline, so you don't hard-code anything.
- The `aws_s3_bucket` resource is our simple test — one storage bucket.

### Step 3: Write the Pipeline (`.gitlab-ci.yml`)

This is the heart of the tutorial. Create `.gitlab-ci.yml` at the root of your repository:

```yaml
# Use GitLab's official OpenTofu CI/CD component as a base.
# It provides ready-made job templates (.opentofu:*) that use the
# gitlab-tofu wrapper, which auto-configures the GitLab state backend.
include:
  - component: gitlab.com/components/opentofu/full-pipeline@~latest
    inputs:
      version: latest            # component version
      opentofu_version: 1.10.6   # pin your tofu version! (see best practices)
      root_dir: .                # where your .tf files live
      state_name: default        # name of the state file in GitLab

stages: [validate, test, build, deploy, cleanup]

# ---- AWS login via OIDC (no stored passwords!) ---------------------
# Every job that talks to AWS gets a short-lived ID token from GitLab,
# then trades it for temporary AWS credentials.
.aws_oidc_auth:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com          # must match the IAM provider audience
  variables:
    AWS_ROLE_ARN: arn:aws:iam::111122223333:role/gitlab-terraform-role
    AWS_DEFAULT_REGION: us-east-1
  before_script:
    - >
      export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s"
      $(aws sts assume-role-with-web-identity
      --role-arn "${AWS_ROLE_ARN}"
      --role-session-name "gitlab-${CI_PROJECT_ID}-${CI_PIPELINE_ID}"
      --web-identity-token "${GITLAB_OIDC_TOKEN}"
      --duration-seconds 3600
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
      --output text))

# ---- Jobs ----------------------------------------------------------

fmt:
  extends: [.opentofu:fmt]        # checks code formatting

validate:
  extends: [.opentofu:validate]   # checks code is valid

plan:
  extends: [.opentofu:plan, .aws_oidc_auth]
  environment:
    name: production
    action: prepare
  # Produces a plan file artifact that apply will reuse — this guarantees
  # what you approved is exactly what gets applied.

apply:
  extends: [.opentofu:apply, .aws_oidc_auth]
  when: manual                    # <<< A HUMAN must click "Run"
  environment:
    name: production
    action: start
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH   # only from main

destroy:
  stage: cleanup
  extends: [.opentofu:destroy, .aws_oidc_auth]
  when: manual                    # <<< A HUMAN must click "Run"
  environment:
    name: production
    action: stop
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

**Note:** the component's job images include the `gitlab-tofu` wrapper; if the base image lacks the AWS CLI, add `apk add --no-cache aws-cli` (or use an image that includes it) at the start of `before_script`.

**Reading this file like a story:**

1. `include: component:` — we borrow GitLab's official, maintained job templates instead of writing everything from scratch. Less code for us to maintain and it stays up to date.
2. `.aws_oidc_auth` — a reusable block (the dot means "hidden template"). It asks GitLab for an ID token (`id_tokens`), then trades it with AWS (`assume-role-with-web-identity`) for **temporary credentials that expire in 1 hour**.
3. `plan` runs automatically on every push to main and saves its result as an **artifact** (a saved file passed between jobs).
4. `apply` has `when: manual`. In the GitLab pipeline screen, it appears with a ▶ play button. Nothing happens until someone clicks it. When clicked, it applies **the saved plan file**, not a fresh plan — so what was reviewed is exactly what runs.
5. `destroy` is also `when: manual`, in its own `cleanup` stage, so tearing things down is always a deliberate human choice.

### Step 4: Push and Watch It Run

```bash
git add main.tf .gitlab-ci.yml
git commit -m "Add OpenTofu pipeline with manual apply/destroy"
git push origin main
```

Now in GitLab go to **Build → Pipelines**. You'll see:

```
validate ✅ → plan ✅ → apply ▶ (waiting) → destroy ▶ (waiting)
```

1. Click the **plan** job and read its log. You'll see something like `Plan: 1 to add, 0 to change, 0 to destroy.` That's the blueprint.
2. Happy with it? Click ▶ on **apply**. Watch the bucket get created.
3. Check your state: **Operate → Terraform states** in the left sidebar. You'll see your state file, its versions, and who changed it.
4. Done experimenting? Click ▶ on **destroy** to delete the bucket.

🎉 **That's a complete, production-shaped pipeline.** Everything after this point is deeper understanding, options, and best practices.

### Step 4b: The Same Pipeline Without the Component (Plain Terraform)

If your company must use HashiCorp Terraform (not OpenTofu), or you want full control, here is the hand-written version. Note that you configure the HTTP backend yourself using GitLab's predefined variables:

```yaml
stages: [validate, plan, apply, cleanup]

variables:
  TF_STATE_NAME: default
  TF_ADDRESS: "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/${TF_STATE_NAME}"

default:
  image:
    name: hashicorp/terraform:1.12    # pin the version!
    entrypoint: [""]
  before_script:
    - terraform init
        -backend-config="address=${TF_ADDRESS}"
        -backend-config="lock_address=${TF_ADDRESS}/lock"
        -backend-config="unlock_address=${TF_ADDRESS}/lock"
        -backend-config="username=gitlab-ci-token"
        -backend-config="password=${CI_JOB_TOKEN}"
        -backend-config="lock_method=POST"
        -backend-config="unlock_method=DELETE"
        -backend-config="retry_wait_min=5"

validate:
  stage: validate
  script:
    - terraform fmt -check -recursive
    - terraform validate

plan:
  stage: plan
  extends: [.aws_oidc_auth]           # same auth block as before
  script:
    - terraform plan -out=plan.tfplan
  artifacts:
    paths: [plan.tfplan]
    expire_in: 7 days

apply:
  stage: apply
  extends: [.aws_oidc_auth]
  when: manual
  script:
    - terraform apply -input=false plan.tfplan   # apply the SAVED plan
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

destroy:
  stage: cleanup
  extends: [.aws_oidc_auth]
  when: manual
  script:
    - terraform destroy -auto-approve -input=false
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
```

**Key details worth memorizing:**

- `CI_JOB_TOKEN` is a short-lived password GitLab generates for every job. It's how the pipeline is allowed to read/write your state. You never create or store it.
- `lock_method=POST` / `unlock_method=DELETE` enable **state locking** over HTTP — GitLab locks the state while a job uses it.
- `terraform apply plan.tfplan` (with the plan file!) is the professional move. `terraform apply` without a file would re-plan at apply time, and the world may have changed since your review.
- One caution about plan files: they can contain secret values in readable form. Set `expire_in`, and restrict who can download job artifacts in project settings.

---

## 4. Deep Dive: How State Management Really Works

### Where can state live? Your main choices

1. **GitLab-managed state (what we used)** — GitLab stores it, encrypts it at rest, versions every change, locks it during runs, and controls access with the same permissions as your project. Works on Free, Premium, and Ultimate tiers, on GitLab.com and self-managed.
2. **AWS S3 backend** — state lives in an S3 bucket you own. Modern Terraform (1.10+) and OpenTofu support **native S3 locking** with `use_lockfile = true`, so the classic DynamoDB lock table is no longer needed for new setups.
3. **Terraform Cloud / HCP, Spacelift, Scalr, env0, etc.** — hosted platforms that manage state *and* runs for you.
4. **Local state** — the file sits on your laptop. Fine for a 10-minute experiment. Never for teams, never for CI. If your laptop dies, your infrastructure's memory dies with it.

### GitLab state: the useful details

- **Viewing:** *Operate → Terraform states* shows each state, every version, and which pipeline/job changed it. You can download old versions, lock/unlock manually, and delete states.
- **Multiple states per project:** the state name is part of the URL (`.../terraform/state/<name>`). Use one state per environment: `dev`, `staging`, `production`. Small, separate states = smaller blast radius when something goes wrong, and faster plans.
- **Using state locally too:** you can `tofu init` on your laptop against the same GitLab backend using a Personal Access Token as the password. Same state everywhere, no drift between laptop and CI.
- **Reading another project's outputs:** GitLab-managed state can be used as a `terraform_remote_state` data source, so your "app" project can read outputs (like a VPC ID) from your "network" project.
- **Stuck locks:** if a job is killed mid-run, the state may stay locked. Fix it in the UI (*Operate → Terraform states → ⋮ → Unlock*) — much friendlier than hunting DynamoDB entries.
- **A backend-config gotcha:** prefer environment variables (`TF_HTTP_ADDRESS`, `TF_HTTP_PASSWORD`, etc.) or the wrapper over long `-backend-config=` flags; cached backend flags in plan output have caused locking problems in CI.
- **Disaster-recovery thought:** GitLab state is encrypted with keys tied to your GitLab instance. If GitLab is down and your infrastructure *is what runs GitLab*, you can't read the state to fix it. Chicken-and-egg! For that special bootstrap infrastructure, keep state elsewhere (e.g., S3) or keep exported backups.

### Golden rules of state (tattoo these on your brain)

1. **Never commit `terraform.tfstate` to Git.** Add it to `.gitignore`. State holds secrets in plain text.
2. **Always use locking.** GitLab's backend does it automatically.
3. **One state per environment.** Don't put dev and prod in one state file.
4. **Never hand-edit state.** Use `terraform state mv`, `state rm`, `import` commands if you must do surgery.
5. **Keep versioning on** so you can roll back a bad state change (GitLab does this for you).

---

## 5. AWS Connectivity: OIDC vs Access Keys

There are two ways a pipeline can prove itself to AWS.

### Option A: Static access keys (the old way)

Create an IAM user, generate `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, paste them into GitLab **Settings → CI/CD → Variables** (masked + protected).

**Pros**

- Dead simple; works in 5 minutes
- Works even on very old GitLab versions

**Cons**

- The keys **never expire** unless you rotate them — a stolen key works forever
- Anyone with Maintainer access can potentially exfiltrate them
- You must build a rotation process (and humans forget)
- Fails most security audits in 2026

### Option B: OIDC / ID tokens (the modern way — what we built)

GitLab mints a short-lived signed JWT (`id_tokens:` keyword). The job trades it with AWS STS for temporary credentials that expire in about an hour.

**Pros**

- **No long-lived secrets exist anywhere.** Nothing to steal, nothing to rotate.
- Fine-grained trust: AWS can restrict by project, branch, tag, environment (via the token's `sub` claim)
- CloudTrail logs show exactly which pipeline assumed the role
- It's the documented best practice from both GitLab and AWS

**Cons**

- More setup steps (identity provider + trust policy)
- Trust-policy conditions are easy to get subtly wrong (test them!)
- Self-managed GitLab must be reachable by AWS over HTTPS to fetch signing keys

**Verdict:** Use OIDC unless you physically cannot. Reserve static keys for quick throwaway experiments.

### Bonus options

- **Self-hosted GitLab runners on EC2/EKS with instance profiles:** the runner machine itself has an IAM role; jobs inherit credentials with zero configuration. Great security, but every job on that runner shares those permissions — so dedicate runners per team/permission level.
- **Assume-role chaining:** one "landing" role that can assume per-environment roles (`dev-role`, `prod-role`). Nice for multi-account AWS organizations.

---

## 6. AWS IAM Roles and Policies: Doing Permissions Right

### The big idea: least privilege

Give the pipeline the *minimum* permissions to do its job. If the pipeline only builds S3 buckets and EC2 servers, it should not be able to delete IAM users or read every database.

Why? If your pipeline is ever tricked (a malicious merge request, a compromised dependency, a leaked token), the attacker gets *exactly* the pipeline's permissions. Small permissions = small disaster. Admin permissions = total disaster.

### A practical permission strategy

1. **Start by writing your Terraform code, then list the AWS actions it needs.** Tools like `iamlive` or IAM Access Analyzer can record which API calls happen during a plan/apply and generate a policy for you.
2. **Split read vs write.** Give the `plan` job a **read-only role** (plan only *reads* AWS to compare against state) and the `apply`/`destroy` jobs a **write role**. In the trust policy, you can even require the `environment` claim so the write role only works for jobs in the protected `production` environment.
3. **Scope resources with ARNs and conditions.** `"Resource": "arn:aws:s3:::my-team-*"` beats `"Resource": "*"` every day.
4. **Use permissions boundaries** if the pipeline creates IAM roles itself, so it can never create a role more powerful than the boundary allows. (This stops the classic "pipeline creates admin role, assumes it" escalation.)
5. **Separate AWS accounts per environment** (dev account, prod account) — the strongest wall AWS offers. The pipeline assumes a different role in each account.
6. **Add deny guardrails at the organization level** (Service Control Policies), e.g. "no one may delete CloudTrail logs, ever, not even admins."

### Example: a tighter trust policy for a prod-only apply role

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

Pair this with GitLab **protected branches** and **protected environments** (Premium+) so only approved humans can even click the apply button — now both GitLab *and* AWS enforce the rule.

---

## 7. Pipeline Design Best Practices

### The plan-file pattern (non-negotiable)

Always `plan -out=plan.tfplan` → save as artifact → `apply plan.tfplan`. This guarantees the human approved *exactly* what runs. If someone merges another change between your review and your click, the apply still runs the reviewed plan (and will error if state moved — which is what you want).

### Manual gates done well

- `when: manual` on `apply` and `destroy` — always.
- Add `allow_failure: false` if later stages depend on apply completing.
- Use **GitLab environments** (`environment: name: production`) — you get a deployment history, "who deployed what when," and can attach **protected environment approvals** so, say, two seniors must approve prod applies.
- Consider `resource_group: production` on apply jobs, so two pipelines can never apply to production at the same time (GitLab queues them). This complements state locking.

### Merge-request flow (how teams actually work day to day)

- On **merge requests**: run `fmt`, `validate`, security scans, and a **speculative plan** (plan only, read-only role). Reviewers see in the MR exactly what infrastructure will change — like a preview of edits before publishing.
- On **main branch**: run plan again, then the manual apply.
- Destroy jobs: many teams only include the destroy job for ephemeral/dev environments, or hide it behind a pipeline variable (`if: $DESTROY == "true"` with a manual pipeline run), so no one fat-fingers production away.

### Other habits that pay off

- **Pin versions of everything**: OpenTofu/Terraform version, provider versions (`~> 6.0`), and Docker images. "latest" today may break next Tuesday.
- **Add a scheduled drift-detection pipeline**: a nightly `plan` on a schedule; if it shows changes, someone edited AWS by hand ("click-ops") and your code no longer matches reality. Alert on it.
- **Scan your IaC**: add `checkov`, `tfsec`/`trivy`, or GitLab's IaC scanning (part of SAST) as a test-stage job to catch things like "S3 bucket is public" *before* apply.
- **Cache plugins** (`.terraform` providers directory) to speed up `init`.
- **Keep modules in GitLab's Terraform Module Registry** and version them, instead of copy-pasting code between projects.
- **`GIT_STRATEGY` + artifacts note:** apply must run from the same commit as plan; GitLab does this naturally within a single pipeline — avoid re-running old apply jobs after new commits.

---

## 8. Options Compared: Pros and Cons

### Terraform vs OpenTofu

| | Terraform (HashiCorp) | OpenTofu (Linux Foundation) |
|---|---|---|
| License | BSL (restricted; competing services can't use it) | MPL-2.0 (fully open source) |
| GitLab support | Templates removed in 18.0; DIY | **Official CI/CD component, actively maintained** |
| Features | Stacks, HCP integration | State **encryption**, early variable/locals evaluation, `exclude` in for_each; near-total compatibility |
| Best for | Shops standardized on HashiCorp/HCP | New GitLab-based setups (recommended path) |

### State backend: GitLab-managed vs S3

| | GitLab-managed state | AWS S3 backend |
|---|---|---|
| Setup | Nearly zero — wrapper autoconfigures | Create bucket, enable versioning/encryption, set `use_lockfile = true` |
| Locking | Built-in (HTTP lock) | Native lockfile (TF 1.10+/OpenTofu); DynamoDB only for legacy |
| Access control | GitLab project permissions + job token | IAM policies |
| Versioning/UI | Built-in UI with history & who-changed-what | S3 versioning (no friendly UI) |
| Gotchas | Chicken-and-egg if state describes GitLab's own infra; state tied to GitLab availability | You must secure the bucket yourself (block public access!); one more AWS thing to manage |
| Best for | Teams living in GitLab (most readers of this tutorial) | AWS-heavy orgs, GitLab-bootstrap infra, existing S3 workflows |

### Manual gates: `when: manual` vs protected environments vs MR approvals

- **`when: manual`** — free, simple; anyone who can run pipelines can click. Minimum bar.
- **Protected environments + approvals (Premium/Ultimate)** — named approvers must sign off before the deploy job runs; audit trail included. Best for production.
- **Merge-request approvals + only running apply on main** — code review is your gate; combine with protected branches so nothing reaches main un-reviewed. Use *all three* for production if you can.

### DIY GitLab pipeline vs hosted TACOS (Terraform Cloud, Spacelift, Scalr, env0…)

- **DIY GitLab (this tutorial):** free/cheap, everything in one tool, full control; you maintain the YAML and policies yourself.
- **Hosted platforms:** built-in policy engines (OPA/Sentinel), fancy drift detection, RBAC, cost estimation; extra cost, extra vendor, extra place permissions live.

Start DIY; consider a platform when you're juggling dozens of workspaces and teams.

---

## 9. Security Best Practices Checklist

- ☐ **OIDC, not static keys** for AWS auth
- ☐ Trust policies pinned to **project + branch (+ environment)** via `sub` claim
- ☐ **Least-privilege IAM**, separate read-only (plan) and write (apply) roles
- ☐ **State never in Git**; `.gitignore` includes `*.tfstate*` and `.terraform/`
- ☐ **State encrypted + versioned + locked** (GitLab does all three)
- ☐ **Plan artifacts expire** and artifact access is restricted (plans can contain secrets)
- ☐ CI/CD variables that are sensitive are **masked** and **protected**
- ☐ **Protected branches** on main; **protected environment** on production
- ☐ `apply` and `destroy` are **manual**, on default branch only
- ☐ **IaC scanning** (checkov/trivy/GitLab SAST-IaC) runs on every MR
- ☐ **Versions pinned** (tool, providers, images, component)
- ☐ **Scheduled drift detection** pipeline exists and alerts
- ☐ Secrets come from a manager (GitLab CI variables, AWS Secrets Manager, Vault/OpenBao) — **never hard-coded in `.tf` files**
- ☐ Runners for prod are **separate/dedicated**, not shared with untrusted projects

---

## 10. Common Problems and Fixes

**"Error acquiring the state lock"**
A previous job died holding the lock. Go to *Operate → Terraform states → your state → Unlock*. Then investigate why the job died before re-running.

**`apply` says the saved plan is stale**
State changed between plan and apply (someone else applied first). That's the safety system working. Re-run the pipeline to get a fresh plan.

**AWS says "Not authorized to perform sts:AssumeRoleWithWebIdentity"**
Almost always a trust-policy mismatch. Check: audience string matches `aud` exactly; `sub` pattern matches your real project path/branch (case-sensitive!); the OIDC provider URL has no trailing slash issues.

**Pipeline works on main, fails on branches**
Your trust policy pins `ref:main` — feature branches can't assume the role. Correct design! Give MR pipelines a separate read-only role with a looser `sub` (e.g., `project_path:mygroup/myproject:ref_type:branch:ref:*`).

**"Backend configuration changed"**
You switched state name or backend settings. Run `init -migrate-state` deliberately, or `-reconfigure` if you know the old backend is irrelevant. Never guess — state migration deserves your full attention.

**Two pipelines fighting each other**
Add `resource_group:` to apply jobs so GitLab serializes them.

**Old tutorials reference `Terraform.gitlab-ci.yml` / `gitlab-terraform`**
Removed in GitLab 18.0. Translate to the OpenTofu component (`gitlab-tofu`) or the hand-written jobs in Step 4b.

---

## 11. Glossary

- **Artifact** — a file a CI job saves and passes to later jobs (our `plan.tfplan`).
- **Backend** — where Terraform stores state (GitLab HTTP, S3, local…).
- **BSL** — Business Source License; the restrictive license Terraform switched to in 2023, prompting OpenTofu.
- **Drift** — when real AWS resources no longer match your code (someone clicked around in the console).
- **HCL** — HashiCorp Configuration Language, the syntax of `.tf` files.
- **IAM** — AWS's permission system (users, roles, policies).
- **Least privilege** — granting only the permissions actually needed.
- **Lock** — a "one at a time" rule on the state file to prevent corruption.
- **Manual job** — a CI job that waits for a human to press ▶.
- **OIDC** — OpenID Connect; passwordless, short-lived identity proof between systems.
- **Plan file** — the saved blueprint (`-out=plan.tfplan`) that apply executes exactly.
- **Protected branch/environment** — GitLab settings restricting who can push/deploy.
- **State** — Terraform's memory of what it built; the most precious file in the whole system.
- **STS** — AWS Security Token Service; hands out temporary credentials.
- **Trust policy** — the part of an IAM role that says *who* may assume it.

---

## Wrap-Up

You now have:

1. A working pipeline: **validate → plan → manual apply → manual destroy**
2. **GitLab-managed state** with encryption, versioning, and locking — set up automatically
3. **Passwordless AWS access** via OIDC with a role locked to your exact project and branch
4. **Least-privilege policies** and the strategy to keep them tight
5. The judgment to choose between OpenTofu/Terraform, GitLab/S3 state, and simple/strict approval gates

The single most important habit: **humans approve changes; robots execute exactly what was approved.** Everything in this tutorial — plan artifacts, manual stages, protected environments, scoped roles — exists to enforce that one sentence.

Happy building! 🏗️
