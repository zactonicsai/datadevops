# Upgrading the Python Version of an AWS Lambda Function

*A complete, beginner-friendly guide — current as of July 2026*

---

## Table of Contents

1. [What This Guide Is About (Background)](#1-background)
2. [Quick Start: Upgrade One Function in 10 Minutes](#2-quick-start)
3. [Why You Have to Do This (Deprecation Explained)](#3-why)
4. [Which Python Version Should You Pick?](#4-which-version)
5. [The Four Ways to Upgrade (Options + Pros/Cons)](#5-options)
6. [Step-by-Step: The Safe Production Method](#6-safe-method)
7. [Gotchas & Breaking Changes to Watch For](#7-gotchas)
8. [Finding Every Function That Needs Upgrading](#8-finding)
9. [Testing, Rollout, and Rollback Best Practices](#9-best-practices)
10. [Key Dates Reference Table](#10-dates)
11. [Glossary](#11-glossary)

---

<a name="1-background"></a>
## 1. What This Guide Is About (Background)

### What is AWS Lambda?

**AWS Lambda** is a service that runs your code without you having to manage any servers. You write a function (a small block of code), upload it, and AWS runs it whenever something triggers it — an API call, a file upload, a scheduled timer, etc. You only pay for the time your code actually runs. This is called **serverless** computing.

### What is a "runtime"?

A **runtime** is the language environment your code runs inside. It bundles three things together:

1. The **operating system** (a version of Amazon Linux)
2. The **programming language version** (for example, Python 3.12)
3. Some **built-in libraries** (like a copy of the AWS SDK)

Every Python version gets its own runtime with a unique **identifier**, like `python3.12` or `python3.13`. When people say "upgrade the Python version of a Lambda," they mean **change the runtime identifier** from an old one (like `python3.9`) to a newer one (like `python3.13`).

### Why can't AWS just upgrade it for me automatically?

AWS *does* automatically apply small **patch** updates (like Python 3.12.1 → 3.12.2). These are safe and rarely break anything.

But AWS will **never** move you from one **major** version to another (like 3.9 → 3.12) on its own. Why? Because major version jumps can change how the language behaves and could break your code. AWS calls this a **customer-driven operation** — meaning *you* have to decide to do it and test it. This guide is about that manual jump.

> **Analogy:** Automatic patches are like your phone installing a small security fix overnight. A major version upgrade is like moving from iOS 16 to iOS 18 — you want to back things up and check your apps still work before committing.

---

<a name="2-quick-start"></a>
## 2. Quick Start: Upgrade One Function in 10 Minutes

Let's upgrade a single, simple function from an old Python version to **Python 3.13** using the AWS Console. This is the fastest way to see the whole process end-to-end. (For production systems, use the [safer method in Section 6](#6-safe-method) instead.)

### Before you start, you need:

- An AWS account with permission to edit Lambda functions
- A Lambda function currently on an old Python runtime (e.g., `python3.9`)
- 10 minutes

### Step 1 — Open the function

1. Sign in to the [AWS Console](https://console.aws.amazon.com/).
2. In the search bar at the top, type **Lambda** and click the Lambda service.
3. Click **Functions** in the left menu.
4. Click the name of the function you want to upgrade.

### Step 2 — Check the current runtime

Scroll down to the **Runtime settings** panel. You'll see something like:

```
Runtime:  Python 3.9
Handler:  lambda_function.lambda_handler
```

Note the current version. This is what we're changing.

### Step 3 — Read your code for problems (quick scan)

Before switching, open the **Code** tab and skim your function for anything in the [Gotchas list](#7-gotchas). The most common one: if your code imports `distutils`, it will break on Python 3.12+. If you see `import distutils` anywhere, stop and read Section 7 first.

For a simple function with no unusual imports, you're usually fine to continue.

### Step 4 — Change the runtime

1. In the **Runtime settings** panel, click **Edit**.
2. Under **Runtime**, open the dropdown and select **Python 3.13**.
3. Leave **Handler** and **Architecture** unchanged.
4. Click **Save**.

### Step 5 — Test it

1. Go to the **Test** tab.
2. If you already have a test event, click **Test**. If not, create one that mimics a real trigger, then click **Test**.
3. Check the **Execution results**. Look for `Status: Succeeded` and confirm the output is what you expect.

### Step 6 — Watch it in production for a bit

Open the **Monitor** tab and keep an eye on the **Errors** and **Duration** graphs for the next few invocations (or the next day for low-traffic functions). If errors spike, switch the runtime back to the old version the same way — *as long as the old runtime isn't fully blocked yet* (see [dates](#10-dates)).

**That's the whole loop.** Change runtime → test → monitor. Everything else in this guide is about doing this *safely at scale* and *avoiding the traps*.

---

<a name="3-why"></a>
## 3. Why You Have to Do This (Deprecation Explained)

### What "deprecation" means

When the people who maintain Python declare a version **end-of-life (EOL)**, they stop releasing security fixes for it. Once that happens, AWS can't keep the runtime safe either, so AWS **deprecates** it. Deprecation is not unique to Lambda — you'd face the same forced upgrade on any platform.

### Deprecation happens in stages, not all at once

This is the single most important thing to understand. A runtime doesn't die overnight. It goes through **four phases**:

| Phase | When | What happens to you |
|---|---|---|
| **Notice period** | At least 180 days before deprecation | AWS emails you and shows warnings in the Health Dashboard and Trusted Advisor. Nothing breaks yet. |
| **Deprecation** | The deprecation date | AWS stops sending security patches. You can no longer change the runtime **in the Console**, but you *can* still create/update via CLI, SAM, or CloudFormation. |
| **Block create** | At least 30 days after deprecation | You can no longer **create new** functions on that runtime by any method. Existing functions still work and can still be updated. |
| **Block update** | At least 60 days after deprecation | You can no longer **update the code or config** of existing functions. This is the hard deadline. |

### The one thing that never stops

**Your functions keep running forever.** Even years after a runtime is deprecated and fully blocked, AWS does **not** stop invoking your function. Execution is never blocked.

So why upgrade at all? Because a deprecated runtime:

- Gets **no security patches** — you're running unpatched code, a real risk.
- Is no longer eligible for **AWS technical support**.
- Can eventually **break on its own** — for example, an expired TLS certificate can suddenly cause failures.
- **Locks you out of changes** — once "block update" hits, you can't fix a bug or tweak config without first upgrading anyway. It's far better to upgrade calmly on your schedule than in a panic when something breaks.

> **AWS extended the warning window.** AWS now gives at least **180 days** of notice (up from 60), and has been pushing the block-create and block-update dates further out in response to customer feedback. You get more breathing room than you used to — but the clock still runs.

---

<a name="4-which-version"></a>
## 4. Which Python Version Should You Pick?

As of July 2026, these are the Python runtimes Lambda supports, newest first:

| Runtime | Operating System | Supported until (deprecation date) | Notes |
|---|---|---|---|
| `python3.14` | Amazon Linux 2023 | Jun 30, 2029 | Newest; latest language features |
| `python3.13` | Amazon Linux 2023 | Jun 30, 2029 | **Recommended default** — long support + strong performance |
| `python3.12` | Amazon Linux 2023 | Oct 31, 2028 | Rock-solid, widely adopted, safe choice |
| `python3.11` | Amazon Linux 2 | Jun 30, 2027 | Older OS (AL2); avoid for new upgrades |
| `python3.10` | Amazon Linux 2 | Oct 31, 2026 | Older OS (AL2); **deprecating soon** |

*(Python 3.9 and 3.8 are already deprecated. Their function-create and function-update blocks land on **Aug 31, 2026** and **Sep 30, 2026** respectively.)*

### The simple recommendation

- **Pick `python3.13`** if you want the longest support window plus better performance. This is the best default for most people.
- **Pick `python3.12`** if you value maximum stability and the widest community/library track record. It's a very common, safe landing spot.
- **Avoid `python3.10` and `python3.11`** as upgrade targets. They run on the older **Amazon Linux 2** operating system (which itself reaches end of life on June 30, 2026), and they deprecate sooner — you'd just be upgrading again shortly.

### Why the operating system matters

Notice that 3.12, 3.13, and 3.14 run on **Amazon Linux 2023 (AL2023)**, while 3.10 and 3.11 run on the older **Amazon Linux 2 (AL2)**. Jumping to an AL2023 runtime gets you onto the modern OS in the same move, so you don't have to migrate twice. If you use container images, this OS change matters more — see the [gotchas](#7-gotchas).

> **Rule of thumb:** Don't upgrade to a version that's itself close to deprecation. Jump as far forward as your code and libraries safely allow. For most, that's 3.13.

---

<a name="5-options"></a>
## 5. The Four Ways to Upgrade (Options + Pros/Cons)

There is no single "right" tool. Which you choose depends on **how many functions** you have and **how they were deployed**. Here are the four main approaches.

### Option A — AWS Console (click-through)

Change the runtime dropdown by hand, exactly as in the [Quick Start](#2-quick-start).

**Pros**
- Easiest to understand; no tools to install.
- Great for learning and for one-off functions.
- Immediate visual feedback.

**Cons**
- **Does not scale** — painful beyond a handful of functions.
- Manual = easy to make mistakes or miss functions.
- Changes aren't recorded in version control, so they can drift from your infrastructure code.
- **Blocked at the deprecation date** — once a runtime is deprecated, the Console won't let you touch it even though the CLI still can.

**Best for:** A single function, or first-time learning.

---

### Option B — AWS CLI (command line)

Use a terminal command to update the runtime. The core command is:

```bash
aws lambda update-function-configuration \
  --function-name my-function \
  --runtime python3.13
```

You can also script this to loop over many functions.

**Pros**
- **Scriptable** — loop over dozens of functions.
- Works **after the deprecation date** when the Console is blocked (until the "block update" phase).
- Easy to combine with the [discovery commands](#8-finding) to find and fix in one pass.

**Cons**
- If your functions are managed by **Infrastructure as Code** (see Option C), a manual CLI change causes **drift** — your next IaC deploy will overwrite it. In that case, change the IaC instead.
- You must handle testing and rollback yourself.
- No built-in code fixes — it only changes the runtime label, not your code.

**Best for:** Functions **not** managed by IaC, or bulk changes across many functions/regions.

---

### Option C — Infrastructure as Code (CloudFormation, SAM, CDK, Terraform)

If your functions were **defined in code** (a template or script that AWS runs to build your infrastructure), the runtime is written in that file. You upgrade by editing **one line** and redeploying.

For example, in an **AWS SAM** or **CloudFormation** template:

```yaml
Resources:
  MyFunction:
    Type: AWS::Serverless::Function
    Properties:
      Handler: lambda_function.lambda_handler
      Runtime: python3.13      # <-- change this line (was python3.9)
```

In **AWS CDK (Python)**:

```python
my_function = _lambda.Function(
    self, "MyFunction",
    runtime=_lambda.Runtime.PYTHON_3_13,   # <-- change this
    handler="lambda_function.lambda_handler",
    code=_lambda.Code.from_asset("src"),
)
```

Then redeploy (e.g., `sam deploy`, `cdk deploy`, or `terraform apply`).

**Pros**
- **The correct method if you already use IaC.** The change is tracked, reviewable, and repeatable.
- No drift — your template is the source of truth.
- Easy to roll out through your normal pull-request and pipeline process.
- One place to change; deploy to every environment consistently.

**Cons**
- Requires that your functions are *already* defined in IaC (you can't retrofit this in five minutes).
- Still doesn't fix **code-level** breaking changes — you edit those separately.
- A careless template change can affect many functions at once, so review carefully.

**Best for:** Any team already using SAM, CloudFormation, CDK, or Terraform. **This is the recommended long-term approach.**

> **Important:** If your functions are managed by IaC, **do not** change the runtime in the Console or CLI. Change it in the template and redeploy. Otherwise your next deployment silently reverts the runtime.

---

### Option D — AWS Transform custom (automated, agent-driven)

**AWS Transform custom** is an AWS tool that uses automation to upgrade Lambda functions for you — including rewriting code for breaking changes and running your tests. It has a built-in transformation named `AWS/python-version-upgrade`.

It can even run **non-interactively** for bulk/CI use. For example:

```bash
atx custom def exec -p . -n AWS/python-version-upgrade \
  --configuration "validationCommands=pytest,additionalPlanContext=The target Python version to upgrade to is Python 3.13" \
  -x -t
```

This tells the agent to target Python 3.13 and run `pytest` to validate afterward.

**Pros**
- **Built for scale** — designed for upgrading hundreds or thousands of functions.
- Attempts to **fix code**, not just flip the runtime label.
- Can run **headless in CI/CD** with no human in the loop.
- Generates a step-by-step plan you can review before it acts.

**Cons**
- More to learn and set up than a one-line change.
- Overkill for a few functions.
- You should still **review** its changes and test — automation isn't a guarantee of correctness.

**Best for:** Large organizations with many functions across many accounts and regions.

---

### Quick decision guide

| Your situation | Use this |
|---|---|
| One function, or just learning | **Option A** (Console) |
| A few functions, not in IaC | **Option B** (CLI) |
| Functions defined in SAM/CFN/CDK/Terraform | **Option C** (edit IaC) — *recommended* |
| Hundreds/thousands of functions | **Option D** (AWS Transform custom) |

---

<a name="6-safe-method"></a>
## 6. Step-by-Step: The Safe Production Method

The Quick Start changes the live function directly — fine for learning, risky for production. For anything that matters, use **versions and aliases** so you can flip traffic gradually and roll back instantly. Here's the full safe procedure.

### The idea in one sentence

Publish the upgraded function as a new immutable **version**, point an **alias** at it gradually (a few percent of traffic at first), watch for errors, then shift the rest — and if anything goes wrong, point the alias back at the old version instantly.

### Step 1 — Inventory and read the code

1. Confirm the function's current runtime and handler.
2. Read the code against the [Gotchas list](#7-gotchas). Fix any breaking-change issues **in the code first** (for example, replace `distutils` usage).
3. Check your dependencies. If you package libraries in a **Lambda layer** or deployment zip, some may need rebuilding for the new Python version and OS — especially anything with compiled/native parts (see gotchas).

### Step 2 — Set up your test data

Make sure you have realistic test events that exercise the important paths through your function. If you don't have automated tests, this is the moment to at least assemble a few good sample events.

### Step 3 — Deploy the upgrade to a non-production copy first

Never make the new Python version the very first thing production sees. Deploy the change to a **dev or staging** version of the function and run your tests there. If you use IaC, this means deploying the edited template to a non-prod stack.

### Step 4 — Publish a new version

A **version** is a frozen snapshot of your function's code and configuration. Once published, it never changes, which is what makes rollback reliable.

```bash
# After updating the runtime (via CLI or IaC), publish a version:
aws lambda publish-version \
  --function-name my-function \
  --description "Python 3.13 upgrade"
```

Note the version number it returns (e.g., `7`). Your old, known-good version (e.g., `6`) stays untouched.

### Step 5 — Shift traffic gradually with an alias

An **alias** is a named pointer (like `live`) that you aim at a version. You can split traffic between two versions by percentage, so only a small slice hits the new one at first.

```bash
# Send 10% of traffic to the new version (7), 90% stays on the old (6):
aws lambda update-alias \
  --function-name my-function \
  --name live \
  --function-version 6 \
  --routing-config AdditionalVersionWeights={"7"=0.10}
```

Watch the **Monitor** tab (errors, duration, throttles). If it's healthy, raise the weight — 25%, 50%, 100%.

```bash
# Once confident, send everything to the new version:
aws lambda update-alias \
  --function-name my-function \
  --name live \
  --function-version 7
```

### Step 6 — Roll back instantly if needed

If errors climb, point the alias straight back at the old version. No redeploy, no waiting:

```bash
aws lambda update-alias \
  --function-name my-function \
  --name live \
  --function-version 6
```

> **Critical timing warning:** You can only roll back to the old runtime **while it still accepts updates**. After a deprecated runtime hits its **"block update"** date, you **cannot go back**. Do your upgrades (and keep your rollback option open) *before* that deadline — check the [dates table](#10-dates).

### Step 7 — Clean up

Once the new version has run cleanly in production for a while, you're done. Optionally delete very old unused versions to keep things tidy (and to stop old runtimes from showing up in deprecation scans).

---

<a name="7-gotchas"></a>
## 7. Gotchas & Breaking Changes to Watch For

Changing the runtime dropdown is easy. The real work is making sure your **code and libraries** still behave. Here are the traps, roughly in order of how often they bite people.

### 7.1 `distutils` was removed in Python 3.12

This is the **number-one** cause of broken upgrades. The `distutils` module was deleted from the standard library in Python 3.12. If your code — or any library you depend on — does `import distutils`, it will fail on 3.12, 3.13, and 3.14.

**Fix:**
- Replace `distutils` with `setuptools` or `packaging` (for version parsing, use the `packaging` library).
- Update or replace old dependencies that still rely on `distutils`.
- Search your whole codebase *and* your dependencies for `distutils` before upgrading.

### 7.2 Native / compiled dependencies must be rebuilt

Libraries with compiled C parts (common examples include `numpy`, `pandas`, `psycopg2`, `Pillow`, and anything with a binary wheel) are built **for a specific Python version and operating system**. A package built for Python 3.9 on Amazon Linux 2 may not load on Python 3.13 on Amazon Linux 2023.

**Fix:**
- Rebuild your deployment package / Lambda layer using the **target** Python version and an **Amazon Linux 2023** environment.
- For pip installs, make sure you're pulling wheels that match the new Python version and architecture (`x86_64` vs `arm64`).
- Test that every import actually loads after the upgrade, not just that the function deploys.

### 7.3 Amazon Linux 2 → Amazon Linux 2023 (OS change)

Moving from 3.9/3.10/3.11 (Amazon Linux 2) up to 3.12+ (Amazon Linux 2023) also changes the **operating system** underneath. Most functions won't notice, but you may hit differences if your code:

- Shells out to system commands or expects specific system libraries to be present.
- Relies on a particular OpenSSL/TLS version or certificate behavior.
- Uses a **container image** — the base image changes, and the package manager switches (AL2023 uses `microdnf`/`dnf` rather than the older `yum` conventions). You must rebuild your container from the new base image.

**Fix:** Rebuild container images from the AL2023 base image. For zip-based functions, verify any system-level assumptions still hold.

### 7.4 JSON / Unicode handling differences

Some upgrades surface subtle changes in how strings and JSON are encoded (for example, Unicode handling in responses). If downstream systems are strict about byte-for-byte output, test that your serialized responses still match expectations.

**Fix:** Compare actual output before and after on representative inputs; don't assume identical bytes.

### 7.5 Other standard-library removals and deprecations

Beyond `distutils`, Python periodically removes long-deprecated modules and features across versions. If you're jumping several versions at once (say 3.8 → 3.13), you're crossing several years of changes. Read the official Python "What's New" notes for each version between your source and target.

**Fix:** Skim the "What's New in Python 3.x" changelogs for every version you're skipping over, focusing on the *Removed* and *Deprecated* sections.

### 7.6 The runtime label isn't the same as the runtime *version*

Don't confuse the **runtime identifier** (`python3.13`, which you choose) with the **runtime version** (the specific patch AWS ships and updates automatically). You control the major version; AWS handles patches. When building dependencies, bundle them yourself so an automatic patch update can't surprise you.

### 7.7 IaC drift (repeat of the earlier warning, because it burns people)

If a function is managed by CloudFormation/SAM/CDK/Terraform and you change the runtime in the Console or CLI, your **next deployment will overwrite it** back to whatever the template says. Always change the runtime in the source-of-truth template for IaC-managed functions.

### 7.8 The included AWS SDK version can change

The Python runtime ships with a copy of the AWS SDK (`boto3`/`botocore`), and its version differs between runtimes. If your code depends on a specific SDK version, **bundle your own** copy in the deployment package rather than relying on the runtime's built-in one.

---

<a name="8-finding"></a>
## 8. Finding Every Function That Needs Upgrading

Before you can upgrade, you need to know *what* to upgrade. In a real account, functions are scattered across regions and maybe multiple accounts.

### Method 1 — AWS CLI, one region at a time

List every function on a specific runtime in one region:

```bash
aws lambda list-functions \
  --region us-east-1 \
  --query "Functions[?Runtime=='python3.9']"
```

Repeat for **each region** and **each account** — the CLI doesn't search across regions automatically.

### Method 2 — AWS Trusted Advisor

Trusted Advisor has a built-in check, **"AWS Lambda Functions Using Deprecated Runtimes,"** in the **Security** category. It:

- Gives you at least **180 days** of advance notice.
- Scans **all versions**, including `$LATEST` and published versions.
- Updates automatically as your functions' status changes.
- Can send you **weekly email** summaries if you turn that on in Trusted Advisor preferences.

### Method 3 — AWS Health Dashboard

The Health Dashboard shows deprecation notifications on your **account health** page under "Other notifications," starting at least 180 days out. The **Affected resources** tab lists the `$LATEST` versions using the runtime. (Note: these notifications expire 90 days after the runtime is deprecated, so don't rely on them as your only tracker.)

### Method 4 — Email

AWS emails your account's **primary contact** at least 180 days before deprecation, listing affected functions. Make sure that contact email is one someone actually reads.

> **Tip:** The cleanest way to make a deprecation warning disappear is sometimes to **delete a function or version you no longer use.** Don't upgrade dead code — remove it.

---

<a name="9-best-practices"></a>
## 9. Testing, Rollout, and Rollback Best Practices

These practices apply no matter which upgrade option you chose.

### Test thoroughly before touching production

- Run the upgraded function against realistic inputs in a **non-production** environment first.
- Verify **every import loads** and every critical code path runs — not just that it deploys.
- Compare outputs before vs. after for anything downstream systems depend on.

### Roll out in phases, worst-consequence functions last

Prioritize by how critical the function is, and give the important ones the most testing and the slowest rollout:

- **Critical functions:** longest lead time, extensive testing, gradual traffic shifting.
- **Important functions:** upgrade on your normal release cadence (e.g., quarterly).
- **Non-critical functions:** upgrade promptly once you've validated the approach.

### Always keep a rollback path

- Use **versions and aliases** (Section 6) so rollback is an instant pointer change, not a redeploy.
- Remember the hard limit: **once a deprecated runtime hits "block update," you can't roll back to it.** Finish upgrades before that date.

### Keep a migration calendar

- Track each runtime's deprecation, block-create, and block-update dates ([table below](#10-dates)).
- Watch AWS deprecation announcements — dates are "subject to change" and AWS has been *extending* them, but you should plan to the published dates.

### Bundle your dependencies

- Include the libraries your code uses (and the AWS SDK, if you depend on a specific version) in your deployment package or a layer. This protects you from surprises when AWS applies automatic patch updates to the runtime.

### Prefer Infrastructure as Code

- If you're doing this by hand today, this upgrade is a good prompt to move your functions into IaC. Future upgrades become a one-line, reviewable, repeatable change instead of a manual scramble.

---

<a name="10-dates"></a>
## 10. Key Dates Reference Table

**Currently supported Python runtimes** (as of July 2026; dates are AWS's forecasts and subject to change):

| Runtime | OS | Deprecation | Block create | Block update |
|---|---|---|---|---|
| `python3.14` | AL2023 | Jun 30, 2029 | Jul 31, 2029 | Aug 31, 2029 |
| `python3.13` | AL2023 | Jun 30, 2029 | Jul 31, 2029 | Aug 31, 2029 |
| `python3.12` | AL2023 | Oct 31, 2028 | Nov 30, 2028 | Jan 10, 2029 |
| `python3.11` | AL2 | Jun 30, 2027 | Jul 31, 2027 | Aug 31, 2027 |
| `python3.10` | AL2 | Oct 31, 2026 | Nov 30, 2026 | Jan 15, 2027 |

**Already-deprecated Python runtimes** — upgrade these now:

| Runtime | Deprecated on | Block create | Block update |
|---|---|---|---|
| `python3.9` | Dec 15, 2025 | Aug 31, 2026 | Sep 30, 2026 |
| `python3.8` | Oct 14, 2024 | Aug 31, 2026 | Sep 30, 2026 |
| `python3.7` | Dec 4, 2023 | (blocked) | Sep 30, 2026 |
| `python3.6` and older | 2022 or earlier | (blocked) | (blocked) |

**Also note:** Amazon Linux 2 reaches end of life on **June 30, 2026**, which is why AL2-based runtimes (3.10, 3.11) are best avoided as upgrade targets. Python **3.15** is expected around **November 2026**.

> Always confirm against the live AWS page before big migrations: *Lambda runtimes* in the AWS Lambda Developer Guide.

---

<a name="11-glossary"></a>
## 11. Glossary

- **Runtime** — The bundled OS + language version + built-in libraries your function runs on.
- **Runtime identifier** — The label for a runtime, e.g., `python3.13`. You choose this.
- **Runtime version** — The specific patch level of a runtime that AWS updates automatically. Different from the identifier.
- **Deprecation** — The point where AWS stops patching a runtime because the language version is end-of-life.
- **End-of-life (EOL)** — When the language maintainers stop supporting a version.
- **Block create / Block update** — Later deprecation stages where AWS stops letting you create or update functions on that runtime. Invocation is never blocked.
- **Version** — An immutable, numbered snapshot of a function's code and config. The basis for reliable rollback.
- **Alias** — A named pointer (like `live`) to a version. Can split traffic across two versions by percentage.
- **Infrastructure as Code (IaC)** — Defining your cloud resources in files (CloudFormation, SAM, CDK, Terraform) rather than clicking in the Console.
- **Drift** — When the live configuration no longer matches your IaC definition, usually because someone changed it manually.
- **Amazon Linux 2 (AL2) / Amazon Linux 2023 (AL2023)** — The two operating systems Lambda runtimes run on. AL2023 is the modern one; AL2 is being retired.
- **Lambda layer** — A separate package of libraries you attach to functions, so you don't bundle the same dependencies into every function.
- **AWS Transform custom** — An AWS automation tool that can upgrade runtimes and rewrite code for you at scale.

---

*End of guide.*
