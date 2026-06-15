# Terraform State Locking on AWS with GitLab — The Complete Plain-English Guide

This guide explains how Terraform keeps your infrastructure safe using a “lock,” how the newest method works (no DynamoDB needed), how to set it all up in GitLab, every trap people fall into, and how to fix things when they break.

Everything is explained in simple terms first, then backed up with real commands and examples you can copy.

-----

## Table of Contents

1. [The Big Picture (read this first)](#1-the-big-picture)
1. [What is Terraform “state”?](#2-what-is-terraform-state)
1. [What is a “lock” and why do we need it?](#3-what-is-a-lock)
1. [The old way vs. the new way](#4-old-way-vs-new-way)
1. [How the new S3 lock actually works](#5-how-the-new-lock-works)
1. [Step-by-step setup from scratch](#6-step-by-step-setup)
1. [Giving permission: the IAM policy explained](#7-iam-policy)
1. [Migrating from the old DynamoDB way](#8-migrating)
1. [Putting it in a GitLab pipeline](#9-gitlab-pipeline)
1. [GitLab Runner versions explained](#10-gitlab-runner-versions)
1. [Finding and deleting a stuck lock](#11-finding-and-deleting-a-lock)
1. [Every gotcha (the traps people fall into)](#12-gotchas)
1. [Troubleshooting guide](#13-troubleshooting)
1. [Quick cheat sheet](#14-cheat-sheet)

-----

<a name="1-the-big-picture"></a>

## 1. The Big Picture

Imagine you and your friends share **one** LEGO city. There’s a notebook that lists exactly which bricks are placed where. Terraform is like a robot that reads that notebook and builds or changes the city to match.

Now imagine two friends try to rebuild the city **at the same time**, both following the notebook. They’d bump into each other, knock things over, and the notebook would end up wrong. Total chaos.

A **lock** is the fix. It’s like a rule that says: *“Only one person may touch the city at a time. Everyone else waits their turn.”*

This guide is about how that lock works on Amazon Web Services (AWS), and how to run it automatically with GitLab.

-----

<a name="2-what-is-terraform-state"></a>

## 2. What is Terraform “state”?

**Terraform** is a tool that builds cloud infrastructure (servers, databases, networks) by reading a text file you write. You describe what you *want*, and Terraform makes it real.

To do its job, Terraform keeps a **save file** called the **state file** (named `terraform.tfstate`). Think of it exactly like a save file in a video game:

- It remembers everything Terraform has already built.
- It maps “the thing I wrote in my config” to “the real thing running in AWS.”
- Without it, Terraform would have no memory and would get hopelessly confused.

**Where does the state file live?** For a team, you don’t keep it on your laptop (laptops get lost, and teammates can’t see it). You keep it in a shared online folder. On AWS, that shared folder is called an **S3 bucket**.

> **Simple definition — S3 bucket:** A giant, reliable online folder from Amazon where you can store files. “S3” stands for “Simple Storage Service.”

So: **the state file is your save file, and it lives in an S3 bucket so the whole team shares one copy.**

-----

<a name="3-what-is-a-lock"></a>

## 3. What is a “lock” and why do we need it?

A **lock** is a temporary “Do Not Disturb” sign. While one person runs Terraform, the lock goes up. Anyone else who tries to run Terraform sees the sign and is told to wait.

You’ve seen this idea before:

- A **bathroom door** with an “Occupied” slider. One person at a time.
- **Google Docs** showing “Someone else is editing.” It stops you from overwriting each other.

**Why it matters so much:** if two people change the state file at the same time, you can get:

- A **corrupted state file** (the save file becomes garbage).
- **Duplicate resources** (two databases when you wanted one).
- **Missing infrastructure** (things deleted by accident).
- **Unpredictable environments** (nobody knows what’s really running).

These are expensive, scary problems. The lock prevents all of them. That’s why **you should never turn locking off** to “make the error go away” (more on that in the gotchas section).

-----

<a name="4-old-way-vs-new-way"></a>

## 4. The Old Way vs. The New Way

There are two ways to do the lock on AWS. Knowing both helps, because the internet is full of old tutorials.

### The OLD way: DynamoDB

For years, you needed **two** AWS things:

1. An **S3 bucket** to hold the state file.
1. A separate **DynamoDB table** just to hold the lock.

> **Simple definition — DynamoDB:** A separate Amazon database. In the old setup, it acted like a sign-out clipboard hanging next to the LEGO city — a whole separate object you had to build, watch, and pay for.

This worked, but it was annoying: an extra service to set up, extra permissions to manage, and an extra bill to pay.

### The NEW way: S3-native locking (`use_lockfile`)

Newer Terraform can do the lock **using only the S3 bucket** — no DynamoDB at all. You just flip one switch (`use_lockfile = true`), and Terraform handles the lock by creating a tiny lock file right next to your save file.

**Why the new way is better:**

- **Simpler** — one AWS thing instead of two. One less moving part to break.
- **Cheaper** — you stop paying for the DynamoDB table.
- **Less permission setup** — Terraform only needs permission to use S3, not DynamoDB too.
- **No “drift”** — in the old way, people sometimes deleted the DynamoDB table by accident and broke locking. Can’t happen if there’s no table.

### Which Terraform version do I need?

This is important and people get it wrong:

- The lock-file feature first appeared as an **experiment in Terraform 1.10**.
- It became **fully official (generally available) in Terraform 1.11**.
- **Use Terraform 1.11 or newer.** That’s the version you actually want.

The old DynamoDB settings still work for now, but they are **deprecated** — meaning Terraform officially discourages them and will **remove** them in a future version. So new projects should use the S3-native way.

> **Heads up:** “Terraform” here means the **command-line tool version**, not your AWS account or your GitLab version. The Terraform CLI version is what decides whether `use_lockfile` works.

-----

<a name="5-how-the-new-lock-works"></a>

## 5. How the New S3 Lock Actually Works

Here’s the trick, step by step, like a story:

1. You run a Terraform command (like `terraform apply`).
1. Terraform tries to create a small file in your S3 bucket. This file sits right next to your state file and ends in **`.tflock`**. Think of it as hanging a “I’m using this right now” sign on the door.
1. Terraform uses a special S3 ability called a **conditional write** — basically it tells S3, *“Only create this sign if no sign is already there.”*
1. **If no sign exists:** S3 creates it. Terraform now “has the lock” and starts working.
1. **If a sign already exists:** S3 refuses. Terraform sees this and knows someone else is busy, so it waits (or shows the lock error).
1. When Terraform finishes, it **deletes** the `.tflock` file — the sign comes down, and the next person can go.

> **Why bucket “versioning” matters here:** Versioning means S3 keeps a history of every change to a file instead of throwing the old version away. This makes the lock safe and reliable, and it protects your state file if something goes wrong. **Always turn versioning on.** This is non-negotiable.

-----

<a name="6-step-by-step-setup"></a>

## 6. Step-by-Step Setup From Scratch

We’ll do this in the right order. You can’t point Terraform at a bucket that doesn’t exist yet, so first we **create the bucket**, then we **tell Terraform to use it**.

### Step 1 — Create the S3 bucket (with versioning and encryption)

Put this in a file (for example `bootstrap.tf`). This builds the bucket itself.

```hcl
# This creates the online folder that will hold your save file.
resource "aws_s3_bucket" "state" {
  bucket = "my-terraform-state-bucket"   # must be globally unique across all of AWS
}

# Versioning = keep a history of every change. REQUIRED for safe locking.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encryption = scramble the file so only authorized people can read it.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# Lock the front door: never let this bucket be public.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Run it:

```bash
terraform init
terraform apply
```

> **Chicken-and-egg note:** The very first time, this `bootstrap.tf` uses a *local* state file on your computer (because the bucket doesn’t exist yet). That’s fine and normal. Some teams create the bucket by hand in the AWS console instead — also fine. The point is: **the bucket must exist before the next step.**

### Step 2 — Tell Terraform to use the bucket *and* the new lock

In your **main** project, add a `backend` block. The `backend` is just Terraform’s way of saying “here’s where my save file lives.”

```hcl
terraform {
  required_version = ">= 1.11.0"   # force everyone onto a version that supports the new lock

  backend "s3" {
    bucket       = "my-terraform-state-bucket"
    key          = "prod/terraform.tfstate"   # the file's path/name inside the bucket
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true                        # THE NEW LOCK. No DynamoDB needed.
  }
}
```

Then run:

```bash
terraform init
```

That’s it. You now have remote state **and** locking with a single AWS service.

> **What does `required_version` do?** It refuses to run if someone uses an old Terraform. This matters because an old Terraform would silently ignore `use_lockfile` and run **with no lock at all** — exactly the chaos we’re trying to prevent. Pinning the version is like a height-requirement sign at a ride: if you’re not tall enough, you can’t get on.

### Step 3 — Test that the lock works

Open two terminal windows. In the first, start a long apply. In the second, try to run another Terraform command at the same time. The second one should be blocked by the lock. If it is, congratulations — locking works.

-----

<a name="7-iam-policy"></a>

## 7. Giving Permission: The IAM Policy Explained

> **Simple definition — IAM:** “Identity and Access Management.” It’s the AWS system of **permission slips**. Nobody (and no robot) can touch anything in AWS unless a permission slip says they’re allowed.

For the new lock, the good news is the permission slip is **short**, because everything is just S3 (no DynamoDB permissions needed).

Terraform needs to be allowed to:

- **List** the bucket (see what’s inside).
- **Read** the state file (`GetObject`).
- **Write** the state file and the lock file (`PutObject`).
- **Delete** the lock file when done (`DeleteObject`).

Here’s the policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListTheBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::my-terraform-state-bucket"
    },
    {
      "Sid": "ReadWriteStateAndLock",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-terraform-state-bucket/prod/terraform.tfstate*"
    }
  ]
}
```

**Read the tricky part slowly:** the `*` at the end of `terraform.tfstate*` is doing real work. It means the rule covers both:

- `terraform.tfstate` (your save file), **and**
- `terraform.tfstate.tflock` (the lock sign)

If you forget that `*`, Terraform can read/write your state but **can’t create the lock**, and you’ll get permission errors. (See troubleshooting.)

> **If you used KMS encryption** (we did, with `aws:kms` above), you must **also** grant permission to use the encryption key: `kms:Encrypt`, `kms:Decrypt`, and `kms:GenerateDataKey` on that key. Forgetting this is a super common mistake — Terraform will complain it can’t read the state even though the S3 permissions look fine.

-----

<a name="8-migrating"></a>

## 8. Migrating From the Old DynamoDB Way

Already using DynamoDB and want to switch? The clever part is you can run **both locks at once** during the switch, so nothing breaks. Do it in stages.

### Stage 1 — Add the new lock next to the old one

Keep your `dynamodb_table` line and add `use_lockfile = true`. Now both locks run together (belt and suspenders).

```hcl
terraform {
  required_version = ">= 1.11.0"
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-table"   # OLD — keep for now, during the switch
    use_lockfile   = true                      # NEW — turn it on
  }
}
```

Apply the change:

```bash
terraform init -reconfigure
```

> `-reconfigure` tells Terraform “my backend settings changed, please re-read them.” Use it whenever you edit the `backend` block.

Now run a normal `plan` and `apply` and make sure everything behaves. **Do this on a test/staging project first, never production first.**

### Stage 2 — Remove the old DynamoDB line

Once you trust the new lock, delete the `dynamodb_table` line. This also clears the annoying deprecation warnings.

```hcl
terraform {
  required_version = ">= 1.11.0"
  backend "s3" {
    bucket       = "my-terraform-state-bucket"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

Re-init again:

```bash
terraform init -reconfigure
```

### Stage 3 — Clean up

Once **every** project has moved over, you can safely delete the old DynamoDB table. Don’t delete it earlier, or projects still using it will break.

-----

<a name="9-gitlab-pipeline"></a>

## 9. Putting It in a GitLab Pipeline

> **Simple definition — GitLab pipeline:** An assembly line of automatic steps. Instead of you typing Terraform commands by hand, GitLab runs them for you whenever you push code. Each step is called a **job**.

Here’s the important idea: **the lock itself needs nothing special in GitLab.** Your pipeline never mentions `.tflock` or DynamoDB. Terraform handles the lock invisibly. What the pipeline *does* need is to make sure two jobs don’t run Terraform at the same time, and that jobs wait politely instead of crashing.

Here’s a complete `.gitlab-ci.yml` with comments:

```yaml
stages:
  - validate
  - plan
  - apply

variables:
  TF_IN_AUTOMATION: "true"   # tells Terraform "you're in a robot, don't print fancy hints"

# --- PLAN: figure out what will change ---
terraform_plan:
  stage: plan
  image: hashicorp/terraform:1.11      # <-- THIS sets the Terraform version. Must be 1.11+
  resource_group: ${CI_ENVIRONMENT_NAME}_terraform   # the "one job at a time" rule (see below)
  environment:
    name: ${CI_ENVIRONMENT_NAME}
  script:
    - terraform init -input=false
    - terraform plan -out=plan.tfplan -lock-timeout=10m   # wait up to 10 min for the lock
  artifacts:
    paths: [plan.tfplan]
    expire_in: 1 hour

# --- APPLY: actually make the changes ---
terraform_apply:
  stage: apply
  image: hashicorp/terraform:1.11
  resource_group: ${CI_ENVIRONMENT_NAME}_terraform
  interruptible: false   # NEVER kill a running apply — this is the #1 cause of stuck locks
  environment:
    name: ${CI_ENVIRONMENT_NAME}
  script:
    - terraform init -input=false
    - terraform apply -input=false -lock-timeout=15m plan.tfplan
  dependencies: [terraform_plan]
  when: manual           # a human must click "play" before real changes happen

# --- UNLOCK: an emergency button you only use when a lock gets stuck ---
terraform_unlock:
  stage: apply
  image: hashicorp/terraform:1.11
  resource_group: ${CI_ENVIRONMENT_NAME}_terraform
  rules:
    - if: '$LOCK_ID'     # this job only appears if you give it a LOCK_ID
      when: manual
  script:
    - terraform init -input=false
    - terraform force-unlock -force "$LOCK_ID"
```

### The three settings doing the real work

1. **`resource_group`** — This is GitLab’s “one job at a time” rule for a given environment. If two pipelines run at once, GitLab makes them take turns instead of both grabbing Terraform together. It’s like a single-stall bathroom: only one person inside, others wait in line.
1. **`-lock-timeout`** — Without this, if the lock is busy, Terraform gives up **instantly** and the job fails. With it (say `15m`), Terraform **waits up to 15 minutes** for its turn. Two jobs back-to-back will queue politely instead of erroring out.
1. **`interruptible: false`** — This stops GitLab from **canceling** a running apply (for example, when newer code is pushed). Why it matters: if a job is killed *in the middle* of an apply, Terraform never gets to take its “Do Not Disturb” sign down — so the lock stays up forever. That’s a **stuck lock**, the most common headache. Never let an apply be interrupted.

-----

<a name="10-gitlab-runner-versions"></a>

## 10. GitLab Runner Versions Explained

> **Simple definition — GitLab Runner:** The actual worker that does the jobs. GitLab (the website) decides *what* needs to be done; the **Runner** is the machine/robot that *does* it. The pipeline is the to-do list; the Runner is the worker checking items off.

People often ask: *“What Runner version do I need for Terraform S3 locking?”* Here’s the honest, important answer:

### The Runner version is NOT what unlocks the feature

The thing that decides whether `use_lockfile` works is the **Terraform version**, and that comes from the **container image** in your job (the `image: hashicorp/terraform:1.11` line above), **not** from the Runner.

So the rule is:

- **Terraform image:** must be **1.11 or newer**. This is the one that actually matters for locking.
- **GitLab Runner:** just needs to be reasonably modern. The pipeline features we use (`resource_group`, `rules`, `interruptible`) have existed for years, so any current Runner already supports them.

### What version rule SHOULD you follow for the Runner?

The official guidance from GitLab: For compatibility reasons, the GitLab Runner major.minor version should stay in sync with the GitLab major and minor version. Older runners may still work with newer GitLab versions, and vice versa, but features may not be available or work properly if a version difference exists.

In plain terms:

- **Match your Runner to your GitLab server.** If your GitLab is version `17.10`, your Runner should also be around `17.10`. Think of it like a board game: the rulebook (GitLab) and the players (Runners) should be using the same edition, or some rules won’t make sense.
- Backward compatibility is guaranteed between minor version updates, but sometimes a minor GitLab update adds a feature that needs the Runner on the same minor version. So don’t let them drift far apart.
- **If you host your own Runner but your code lives on GitLab.com:** keep the Runner updated to the latest version, because GitLab.com is updated continuously. GitLab.com always moves forward, so your Runner should too.

### Two ways to get a Runner

1. **GitLab-hosted (SaaS) runners** — GitLab runs and updates them for you. You don’t manage versions at all. Easiest option; great for most teams.
1. **Self-managed runners** — you install and run them yourself, so **you** are responsible for keeping the version in sync. You have complete control over self-managed runners.

### A small but real install gotcha (newer Runners)

If you install a **specific** (not latest) Runner version on Linux, newer packaging is stricter. As of GitLab Runner v17.7.1, when you install a specific version that isn’t the latest, you must also explicitly install the matching `gitlab-runner-helper-images` package for that same version. If you don’t, you’ll hit a “broken packages / unmet dependencies” error. The fix is to install both at the same pinned version:

```bash
sudo apt install gitlab-runner=17.7.1-1 gitlab-runner-helper-images=17.7.1-1
```

### Bottom line for this project

- Don’t stress about the Runner version unlocking anything — it doesn’t.
- Keep the Runner roughly in step with your GitLab server version.
- Make sure the **Terraform image in your jobs is 1.11+** — that’s the version that actually controls S3-native locking.

-----

<a name="11-finding-and-deleting-a-lock"></a>

## 11. Finding and Deleting a Stuck Lock

Sometimes the “Do Not Disturb” sign gets left up by accident — usually because a job was killed mid-run, a laptop went to sleep, or the network dropped. Now nobody can run Terraform. Here’s how to safely take the sign down.

### Step 1 — Read the error. It tells you a lot.

When you’re blocked, Terraform prints something like:

```
Error: Error acquiring the state lock

Lock Info:
  ID:        12345abc-6789-def0-1234-56789abcdef0
  Path:      my-terraform-state-bucket/prod/terraform.tfstate
  Operation: OperationTypeApply
  Who:       jordan@jordans-laptop
  Created:   2026-06-15 14:32:01 +0000 UTC
```

Look at:

- **`Who`** — who’s holding it?
- **`Created`** — how long ago? If it was made **hours** ago but applies normally take **minutes**, the lock is almost certainly stuck (stale).
- **`ID`** — you’ll need this to unlock.

### Step 2 — STOP and check before you unlock

**Do not yank a lock someone is actively using.** Ask yourself:

- Is a teammate running Terraform right now?
- Is there a GitLab pipeline still running that holds the lock?

If someone is genuinely mid-apply, ripping the lock away can corrupt the state. Only continue if you’re confident the lock is truly abandoned.

### Step 3 — Try the polite way first: `force-unlock`

From inside your project folder:

```bash
terraform force-unlock 12345abc-6789-def0-1234-56789abcdef0
```

Use the exact ID from the error. This is the recommended, cleanest method. It removes the lock the proper way.

### Step 4 — If that fails, delete the lock file directly

Because the new lock is just a file in S3, you can delete it by hand. (With the old DynamoDB way you had to delete a database record — more annoying.)

```bash
# Optional: confirm the lock file is really there
aws s3 ls s3://my-terraform-state-bucket/prod/
# look for: terraform.tfstate.tflock

# Delete the lock file (take the sign down)
aws s3 rm s3://my-terraform-state-bucket/prod/terraform.tfstate.tflock
```

Because versioning is on, you’ll often see a “delete marker” appear — that’s normal and expected.

### Doing it from a GitLab pipeline instead

Use the `terraform_unlock` job from the pipeline above. Go to **CI/CD → Pipelines → Run pipeline**, add a variable named `LOCK_ID` set to the ID from the error, and run it.

**Why the job runs `terraform init` first:** a pipeline job starts in a fresh, empty container. It has no memory of your backend yet. Without `init`, `force-unlock` fails with a backend error. So always `init` before unlocking.

-----

<a name="12-gotchas"></a>

## 12. Every Gotcha (The Traps People Fall Into)

These are the mistakes that bite real teams. Read them once and save yourself hours.

### Gotcha 1: Turning off locking to “fix” the error

Tempted to add `-lock=false`? **Don’t.** It doesn’t fix anything — it just removes the safety rail. Two people can now wreck the state at the same time. This is the single worst thing you can do. Fix the *real* cause instead.

### Gotcha 2: Killing a running apply

If a job is canceled mid-apply, the lock never comes down → stuck lock. Always set `interruptible: false` on your apply job, and never enable “auto-cancel running pipelines” for applies.

### Gotcha 3: Forgetting versioning on the bucket

The new lock relies on S3 versioning to behave safely. No versioning = unreliable locking and no safety net for your state. **Always enable versioning.**

### Gotcha 4: Forgetting the `*` in the IAM policy

If your policy covers `terraform.tfstate` but not `terraform.tfstate*`, Terraform can read state but **can’t create the lock file**. You’ll get confusing “access denied” errors only when locking. The `*` covers the `.tflock` file too.

### Gotcha 5: Forgetting KMS permissions

If your bucket uses KMS encryption, S3 permissions alone aren’t enough. You also need `kms:Decrypt`, `kms:Encrypt`, and `kms:GenerateDataKey` on the key. Symptom: “access denied” reading state even though S3 looks correct.

### Gotcha 6: Old Terraform version silently ignoring the lock

If someone runs Terraform **older than 1.10**, the `use_lockfile` line is ignored and they run **with no lock**. Scary, because there’s no error — just silent risk. Pin `required_version = ">= 1.11.0"` so old versions are blocked.

### Gotcha 7: No `-lock-timeout` in CI

Without it, back-to-back jobs fail instantly the moment they hit a busy lock. Add `-lock-timeout=10m` (or similar) so jobs **wait their turn** instead of crashing.

### Gotcha 8: No `resource_group` in CI

Without it, two pipelines can run Terraform at the exact same time and collide. `resource_group` forces them to take turns.

### Gotcha 9: Following old tutorials

Lots of guides online still say “create a DynamoDB table.” Many of those predate Terraform 1.10. For new projects on 1.11+, the lock file is the supported path and DynamoDB is deprecated. Don’t follow stale advice.

### Gotcha 10: Migrating production first

Always test the migration on a non-production (staging/dev) project first. Confirm locking works there before touching anything important.

### Gotcha 11: Letting Runner and GitLab versions drift far apart

If your self-managed Runner is many versions behind your GitLab server, some pipeline features may misbehave. Keep them roughly in sync (see Section 10).

### Gotcha 12: Deleting the DynamoDB table too early during migration

If even one project still references the old table, deleting it breaks that project. Remove the table only after **everything** has moved to the lock file.

-----

<a name="13-troubleshooting"></a>

## 13. Troubleshooting Guide

Find your symptom, apply the fix.

### “Error acquiring the state lock”

Someone (or some job) holds the lock.

1. Read `Who` and `Created` in the error.
1. If it’s recent and someone’s working — **wait**.
1. If it’s stale (hours old, nobody active) — `terraform force-unlock <ID>`.
1. If that fails — delete the `.tflock` file from S3 directly (Section 11).

### “force-unlock” itself fails

Usually the backend can’t be reached, or the job didn’t run `init`.

1. Make sure you ran `terraform init` first (especially in CI).
1. Check your AWS credentials are valid in this environment.
1. As a last resort, delete the lock file directly:
   `aws s3 rm s3://YOUR-BUCKET/PATH/terraform.tfstate.tflock`

### “Access Denied” but only around locking

Your IAM policy probably misses the lock file.

1. Confirm the resource is `.../terraform.tfstate*` (with the `*`), not just `.../terraform.tfstate`.
1. Confirm `s3:PutObject` and `s3:DeleteObject` are allowed (needed to create and remove the lock).

### “Access Denied” reading the state, S3 looks fine

Likely a **KMS** problem.

1. Add `kms:Decrypt`, `kms:Encrypt`, `kms:GenerateDataKey` on the encryption key.
1. Confirm the role is actually allowed to use *that specific* key.

### Locking seems to do nothing / two runs happen at once

Probably an old Terraform, or the bucket lacks versioning.

1. Run `terraform version` — must be **1.11+**.
1. Add `required_version = ">= 1.11.0"` to block old versions.
1. Enable S3 bucket versioning.

### CI jobs keep failing instantly on the lock

1. Add `-lock-timeout=10m` (or more) to your plan/apply commands so they wait.
1. Add `resource_group` so jobs queue instead of colliding.

### Locks keep getting stuck after CI runs

Almost always a canceled/timed-out apply.

1. Set `interruptible: false` on the apply job.
1. Disable auto-cancel for pipelines that apply.
1. Make sure runners don’t time out shorter than a real apply takes.

### `terraform init` errors after changing the backend block

You edited backend settings without re-reading them.

- Run `terraform init -reconfigure` (or `-migrate-state` if you’re moving state).

### GitLab Runner won’t install a specific version (broken packages)

On v17.7.1+, you must install the matching helper package too:

```bash
sudo apt install gitlab-runner=17.7.1-1 gitlab-runner-helper-images=17.7.1-1
```

### Pipeline features behaving oddly

Check that your Runner version is roughly in sync with your GitLab server version (Section 10). A big gap can cause features to misbehave.

-----

<a name="14-cheat-sheet"></a>

## 14. Quick Cheat Sheet

**The modern backend block:**

```hcl
terraform {
  required_version = ">= 1.11.0"
  backend "s3" {
    bucket       = "my-terraform-state-bucket"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

**Find the lock file:**

```bash
aws s3 ls s3://my-terraform-state-bucket/prod/
```

**Unlock (preferred):**

```bash
terraform force-unlock <LOCK_ID>
```

**Unlock (last resort):**

```bash
aws s3 rm s3://my-terraform-state-bucket/prod/terraform.tfstate.tflock
```

**Re-read backend after editing it:**

```bash
terraform init -reconfigure
```

**The non-negotiable rules:**

- Terraform **1.11+** for `use_lockfile`.
- Bucket **versioning ON**.
- IAM resource ends in **`terraform.tfstate*`** (covers the lock).
- Add **KMS** permissions if the bucket is KMS-encrypted.
- In CI: **`resource_group`** + **`-lock-timeout`** + **`interruptible: false`**.
- Keep **Runner version** roughly in sync with your **GitLab server**.
- **Never** use `-lock=false`.

-----

*The whole point of locking is to remove a moving part and protect your team from corrupting shared infrastructure. The new S3-native method does this with one AWS service instead of two — fewer things to break, less to pay for, and a lock you can literally see and delete as a file.*