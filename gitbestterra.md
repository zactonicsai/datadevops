# Managing Terraform / OpenTofu State in GitLab CI/CD: A Complete Tutorial (2025–2026)

## TL;DR

- **For teams already on GitLab, the GitLab-managed HTTP state backend is the fastest, cheapest starting point** — free, integrated, encrypted at rest, versioned, with automatic locking and `CI_JOB_TOKEN` auth — but its Lockbox encryption ties decryption to your GitLab instance and it does not support Terraform workspaces, so at large scale or for multi-cloud tooling access, a cloud object-storage backend (S3 + native lockfile, Azure Blob, or GCS) is the more robust choice.
- **The single most important 2025–2026 change: GitLab removed its Terraform CI/CD templates, the `gitlab-terraform` helper script, and the `terraform-images` in GitLab 18.0** (available starting May 15, 2025) because of HashiCorp’s BSL license switch. Per GitLab’s deprecation notice, “GitLab won’t be able to update the terraform binary in the job images to any version that is licensed under BSL.” The officially recommended replacement is the **OpenTofu CI/CD component** (`gitlab.com/components/opentofu`) with the `gitlab-tofu` wrapper. Terraform still works, but you must self-host your own image.
- **Regardless of backend, apply the same non-negotiables:** enable locking, encrypt state, keep secrets out of state, isolate environments with separate state files, gate `apply` behind a manual/protected environment, prefer OIDC `id_tokens` over long-lived cloud keys, and never commit `.tfstate` to Git.

## Key Findings

1. **GitLab-managed state uses the Terraform HTTP backend protocol.** You point Terraform/OpenTofu at `${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/<name>`, authenticate with `gitlab-ci-token` + `${CI_JOB_TOKEN}` in CI (or username + PAT with `api` scope locally). It provides encryption in transit (HTTPS) and at rest (Lockbox gem, key derived from `db_key_base` + project ID), versioning, and lock/unlock via POST/DELETE.
1. **It does NOT support Terraform workspaces.** You separate environments by using different **named states** in the URL (`.../state/dev` vs `.../state/prod`), not `terraform workspace`. 
1. **S3 native locking (`use_lockfile = true`) has replaced DynamoDB.** It was experimental in Terraform v1.10.0 (released 2024-11-27) and became generally available in v1.11.0 (released 2025-02-27); per HashiCorp’s S3 backend docs, “DynamoDB-based locking is deprecated and will be removed in a future minor version.” OpenTofu added native S3 locking in 1.10 as well.
1. **Azure Blob and GCS lock automatically** — Azure via blob leases, GCS via object generation numbers — with no extra lock resource to manage.
1. **The apply gate matters more than the backend.** GitLab’s `resource_group` serializes concurrent applies; `when: manual` + protected environments provide human approval and an audit trail.
1. **OIDC (`id_tokens`) is the modern auth standard** — it replaces stored AWS/Azure/GCP keys with short-lived, per-job credentials scoped by claims like `project_path`, `ref`, and `aud`.

## Details

### 1. Background: the BSL/OpenTofu shift and what changed in GitLab

In **August 2023, HashiCorp relicensed Terraform** (and Vault, Consul, Nomad, etc.) from the open-source **MPL 2.0 to the Business Source License (BSL) 1.1** — source-available, but restricting use in products that compete with HashiCorp. A vendor/community coalition forked the last MPL version (Terraform 1.5.6) into **OpenTofu**, now a Linux Foundation project under MPL 2.0. OpenTofu 1.6 shipped January 2024 as a drop-in replacement;  by 2026 it has diverged with features like native state encryption. **IBM completed its acquisition of HashiCorp on February 27, 2025** (at $35.00/share in cash, roughly $6.4B enterprise value), per IBM’s newsroom release “IBM Completes Acquisition of HashiCorp.”

**Practical impact for GitLab users:**

- For normal internal use — running `terraform apply` in your own pipelines against your own cloud — **the BSL changes nothing legally.** The restriction only bites if you build a competing commercial/hosted offering. 
- GitLab’s legal analysis concluded it could not continue shipping the BSL-licensed Terraform binary in its CI templates. So GitLab **deprecated the Terraform CI/CD templates (announced in GitLab 16.9, tracked in issue #438010) and removed them, the `gitlab-terraform` helper script, and the `terraform-images` container images in GitLab 18.0** (available starting May 15, 2025). GitLab’s rationale: “GitLab won’t be able to update the terraform binary in the job images to any version that is licensed under BSL. To continue using Terraform, clone the templates and Terraform image, and maintain them as needed.”
- The **GitLab-managed state backend itself was NOT removed** — only the templates, helper, and images.
- **Recommended replacement:** per GitLab’s deprecation notice, “As an alternative we recommend using the new OpenTofu CI/CD component on GitLab.com or the new OpenTofu CI/CD template on GitLab Self-Managed.” The component uses the `gitlab-tofu` CLI wrapper (a thin wrapper around `tofu`) and works with both OpenTofu and Terraform state backends.
- If you must stay on Terraform, GitLab keeps a separate `gitlab-org/terraform-images` project you can fork and self-host, or pin to an older GitLab release ref.

> **Decision:** For greenfield GitLab pipelines in 2026, adopt the OpenTofu component. OpenTofu is the lower-risk default (open governance, no license overhang) and the officially supported GitLab path. Migration from Terraform is cheap because state format and HCL are shared.

-----

### 2. Approach A — GitLab-managed Terraform/OpenTofu state (HTTP backend)

**How it works.** GitLab implements the Terraform HTTP backend. Each project can hold multiple named states, visible under **Operate > Terraform states**.

**Backend block (leave empty; configure at init):**

```hcl
# backend.tf
terraform {
  backend "http" {}
}
```

**`terraform init` with backend-config flags (local machine):**

```bash
PROJECT_ID="<gitlab-project-id>"
TF_USERNAME="<gitlab-username>"
TF_PASSWORD="<gitlab-personal-access-token>"   # PAT needs the `api` scope
TF_ADDRESS="https://gitlab.com/api/v4/projects/${PROJECT_ID}/terraform/state/my-state"

tofu init \
  -backend-config=address=${TF_ADDRESS} \
  -backend-config=lock_address=${TF_ADDRESS}/lock \
  -backend-config=unlock_address=${TF_ADDRESS}/lock \
  -backend-config=username=${TF_USERNAME} \
  -backend-config=password=${TF_PASSWORD} \
  -backend-config=lock_method=POST \
  -backend-config=unlock_method=DELETE \
  -backend-config=retry_wait_min=5
```

**In CI, authenticate with `CI_JOB_TOKEN`.** GitLab recommends setting the HTTP backend via `TF_HTTP_*` environment variables rather than `-backend-config` flags, because flags get cached into the plan output and passed to apply, which can break locking in CI jobs. 

**Manual pipeline (no component) — GitLab-managed state:**

```yaml
# .gitlab-ci.yml
variables:
  TF_ROOT: "${CI_PROJECT_DIR}/terraform"
  TF_STATE_NAME: "production"
  TF_ADDRESS: "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/terraform/state/${TF_STATE_NAME}"

image:
  name: ghcr.io/opentofu/opentofu:1.10.8
  entrypoint: [""]

stages: [validate, plan, apply]

cache:
  key: "opentofu-${CI_COMMIT_REF_SLUG}"
  paths: [ "${TF_ROOT}/.terraform/" ]

before_script:
  - cd ${TF_ROOT}
  - export TF_HTTP_ADDRESS="${TF_ADDRESS}"
  - export TF_HTTP_LOCK_ADDRESS="${TF_ADDRESS}/lock"
  - export TF_HTTP_UNLOCK_ADDRESS="${TF_ADDRESS}/lock"
  - export TF_HTTP_USERNAME="gitlab-ci-token"
  - export TF_HTTP_PASSWORD="${CI_JOB_TOKEN}"
  - export TF_HTTP_LOCK_METHOD="POST"
  - export TF_HTTP_UNLOCK_METHOD="DELETE"
  - export TF_HTTP_RETRY_WAIT_MIN="5"
  - tofu init

validate:
  stage: validate
  script:
    - tofu fmt -check -recursive
    - tofu validate

plan:
  stage: plan
  script:
    - tofu plan -out=plan.cache
    - tofu show -json plan.cache > plan.json
  artifacts:
    access: 'developer'          # keep plan file away from Guest role
    paths: [ "${TF_ROOT}/plan.cache" ]
    reports:
      terraform: "${TF_ROOT}/plan.json"

apply:
  stage: apply
  script:
    - tofu apply -auto-approve plan.cache
  dependencies: [ plan ]
  resource_group: production      # serialize applies — critical for state safety
  environment:
    name: production
  rules:
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      when: manual                # human gate before apply
```

**Recommended: the OpenTofu CI/CD component.** As of mid-2026 the current release is **4.7.0** with a default OpenTofu version of **1.12.1** (available options include 1.12.x, 1.11.x, 1.10.8, 1.9.3); images are published at `registry.gitlab.com/components/opentofu/gitlab-opentofu` with tags like `4.7.0-opentofu1.12.1`. Because these move fast, always confirm the latest at `gitlab.com/components/opentofu` releases before pinning.

```yaml
# .gitlab-ci.yml — recommended, component-based
include:
  - component: gitlab.com/components/opentofu/validate-plan-apply@4.7.0
    inputs:
      version: 4.7.0                 # must match the include tag (workaround for issue #438275)
      opentofu_version: 1.12.1
      root_dir: terraform/
      state_name: production
      stages: [validate, build, deploy]

stages: [validate, build, deploy]
```

The component README confirms the version requirement: “The version must currently be specified explicitly as an input, to find the correctly associated images. This can be removed once <https://gitlab.com/gitlab-org/gitlab/-/issues/438275> is solved.”

**Apply gating in the component:** the `apply` job is **manual by default** — its `apply_rules` default is `[{ if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH, when: manual }]`. There is no working `auto_apply` boolean input (blocked by a GitLab nesting-inputs bug, issue #438722); to change gating you override `apply_rules`. To auto-apply, drop `when: manual`; to keep the human gate, leave it. The component also exposes `environment_name`, `environment_url`, and state auto-encryption inputs (`auto_encryption`, `auto_encryption_passphrase`) for encrypting state and plan with a passphrase from a masked/protected CI variable.

**Roles required:** Maintainer/Owner to lock, unlock, and write (`apply`); Developer to read (`plan -lock=false`). 

**Pros:**

- **Free and built in** — no extra cloud account, bucket, or lock table; setup in minutes vs. hours for S3 + IAM + DynamoDB. 
- **Integrated auth** via `CI_JOB_TOKEN` (short-lived, automatic); access governed by GitLab roles.
- **Encrypted at rest** (Lockbox) and in transit (HTTPS); **automatic versioning** and rollback; **automatic locking**.
- **MR integration** shows plan diffs to reviewers; usable as a remote-state data source across projects.

**Cons:**

- **Tied to GitLab availability.** Lockbox decryption needs the instance online and the `db_key_base`. If GitLab itself is bootstrapped by this state, an outage becomes a chicken-and-egg disaster-recovery problem.  Mitigate by backing up bootstrap dependencies separately or using an independent GitLab instance.
- **No customer-managed encryption keys** — encryption uses GitLab’s internal keys, not your KMS.
- **No Terraform workspaces** — use named states per environment instead.
- **Storage/size limits** — admins can set a per-state-file-version size limit (self-managed); GitLab.com enforces platform API limits. Large-scale, dozens-of-states setups may outgrow it.
- **Cross-tool / cross-project access is clunkier** — other tools that expect S3/GCS need extra token plumbing; reaching state from another project requires token configuration. 
- **Plan files are not encrypted by default** and are visible to the Guest role — set `access: 'developer'` on artifacts and/or keep projects private. 

-----

### 3. Approach B — Cloud object-storage backends

#### B1. AWS S3 with native locking (`use_lockfile`)

```hcl
# backend.tf — modern S3 backend, no DynamoDB
terraform {
  backend "s3" {
    bucket       = "mycompany-terraform-state"
    key          = "prod/networking/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true          # SSE; add kms_key_id for CMK
    use_lockfile = true          # native S3 locking (Terraform 1.11+/OpenTofu 1.10+)
  }
}
```

The lock is a `.tflock` object written next to the state via an S3 conditional write (`If-None-Match`); conflicts surface as an HTTP 412 `PreconditionFailed` with the lock holder. **Prerequisite:** enable **bucket versioning** (for rollback/backups) and block public access. Migration from DynamoDB is a no-downtime change: add `use_lockfile = true` alongside `dynamodb_table` temporarily, then remove the DynamoDB argument and `terraform init -reconfigure`.

**Partial config for per-environment backends (recommended):**

```hcl
# backend.tf
terraform { backend "s3" {} }
```

```hcl
# backend-config/prod.hcl
bucket       = "mycompany-terraform-state"
key          = "prod/app/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

```bash
terraform init -backend-config=backend-config/prod.hcl
```

**Least-privilege IAM** needs `s3:ListBucket` on the bucket and `s3:GetObject`/`s3:PutObject`/`s3:DeleteObject` on both the state key and the `.tflock` object (HashiCorp’s S3 backend docs specify these three actions are required on the lock file when `use_lockfile` is set).

**Pros:** mature, battle-tested; fine-grained IAM; S3 versioning + AWS Backup for recovery; CloudTrail audit trail; native locking removes the DynamoDB moving part (cheaper, simpler); accessible from any tool.
**Cons:** extra AWS setup (bootstrap bucket, IAM policies); credential management (mitigate with OIDC); a chicken-and-egg bootstrap for the bucket itself (keep bootstrap state small/local or manual); native locking lacks the per-lock audit logging some teams built on DynamoDB.

#### B2. Azure Blob Storage (`azurerm`)

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "terraform-state-rg"
    storage_account_name = "mycompanytfstate"
    container_name       = "tfstate"
    key                  = "prod/infrastructure.terraform.tfstate"
    use_azuread_auth     = true   # prefer Entra ID / managed identity over account keys
  }
}
```

Locking is automatic via **blob leases** — no separate lock resource. Enable **blob versioning** and **soft delete** (e.g., 30-day retention). Use a dedicated resource group and Azure RBAC (`Storage Blob Data Contributor`) instead of storage-account keys.

**Pros:** automatic lease locking; native encryption at rest; versioning + soft-delete recovery; tight Azure/Entra integration.
**Cons:** leases have a fixed duration — a crashed apply can leave a lock you must break (`az storage blob lease break`); extra Azure setup; credential management.

#### B3. Google Cloud Storage (`gcs`)

```hcl
terraform {
  backend "gcs" {
    bucket = "mycompany-terraform-state"
    prefix = "prod/networking"
  }
}
```

```bash
gcloud storage buckets create gs://mycompany-terraform-state \
  --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://mycompany-terraform-state --versioning
```

Locking is automatic via object generation numbers/preconditions. Encryption at rest is on by default; add a CMEK if required. Use uniform bucket-level access, not fine-grained ACLs.

**Pros:** automatic locking; encryption by default; object versioning for history; simple setup.
**Cons:** GCP-specific; still requires credential management (use OIDC/Workload Identity Federation).

-----

### 4. Approach C — HCP Terraform (Terraform Cloud) as the backend from GitLab CI

Use the `cloud` block; HCP Terraform stores state, locks it, and can run remotely with policy (Sentinel) and RBAC. 

```hcl
# main.tf
terraform {
  cloud {
    organization = "your-org"
    workspaces { name = "app-production" }
  }
}
```

```yaml
# .gitlab-ci.yml
default:
  image: { name: hashicorp/terraform:1.7.0, entrypoint: [""] }
  before_script:
    - |
      cat > ~/.terraformrc <<EOF
      credentials "app.terraform.io" {
        token = "$TF_API_TOKEN"     # masked/protected CI variable; or TF_TOKEN_app_terraform_io
      }
      EOF
variables:
  TF_IN_AUTOMATION: "true"
apply:
  stage: apply
  script: [ "cd infrastructure", "terraform init -input=false", "terraform apply -auto-approve" ]
  resource_group: production        # avoid HCP API rate-limit collisions
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
```

Use separate workspace-scoped **team tokens** for staging vs. production (`TF_API_TOKEN_STAGING` / `_PRODUCTION`).  Note GitLab’s old Terraform templates were built around GitLab-managed state, so with HCP you write plain custom jobs.

**Pros:** fully managed state + remote execution; policy-as-code (Sentinel/OPA), RBAC, SSO, audit trail, run history UI; strong governance.
**Cons:** SaaS dependency and cost; vendor lock-in; API rate limits under high concurrency (serialize with `resource_group`); Sentinel does not run against OpenTofu. 

-----

### 5. Anti-patterns to avoid

- **Local state left in the working directory.** Can’t be shared, no locking, lost if the machine dies. Fine only for throwaway learning.
- **Committing `.tfstate` to Git.** Three fatal problems:
1. **Secrets in plaintext.** State stores resource attributes verbatim — DB passwords, API keys, private keys, connection strings — and Git preserves them in history *forever*, even after deletion.  Git repos are not encrypted at rest.
1. **No locking.** Two `terraform apply` runs corrupt state or duplicate resources;  concurrent commits create merge conflicts on an unmergeable JSON blob.
1. **Stale-state risk.** Running against an out-of-date checked-in state drifts infrastructure from reality. 
- **Fix / prevention:** always use a remote backend with locking; add a Terraform `.gitignore` (`*.tfstate`, `*.tfstate.*`, `**/.terraform/*`, `*.tfvars` with secrets);  keep secrets in a secret manager (Vault/OpenBao, cloud Secrets Manager) and reference via data sources; if state was already committed, `git rm --cached` and **rotate every exposed credential**. 

-----

### 6. Cross-cutting best practices

**State locking in concurrent pipelines.** Multiple MRs, or a plan overlapping an in-progress apply, cause lock contention. All major backends lock automatically (S3 lockfile/DynamoDB, Azure leases, GCS generations, GitLab HTTP, HCP). Additionally:

- Use GitLab `resource_group: <env>` to serialize apply jobs so only one runs at a time per environment.
- Use `-lock-timeout=<n>m` so back-to-back jobs queue rather than fail.
- Clear stale locks deliberately: `terraform force-unlock <LOCK_ID>` (verify no job is running first), or for GitLab-managed state via **Operate > Terraform states**, `glab opentofu state unlock <name>`, or `DELETE .../state/:name/lock`.

**Encryption — at rest, in transit, and secrets.** Enable server-side encryption on every backend (S3 SSE/KMS, Azure SSE/CMK, GCS default/CMEK, GitLab Lockbox); all use HTTPS in transit. Because state holds secrets in plaintext regardless of backend, also: minimize secrets in state (secret managers + `sensitive` outputs), and consider **OpenTofu’s native state & plan encryption** (added in 1.7) for KMS-backed client-side encryption without an external workflow — a genuine OpenTofu advantage over Terraform.

**Separate states per environment.** Two strategies:

- **Separate state files / directories per env** (`environments/{dev,staging,prod}/` each with its own `backend.tf`). Preferred for long-lived, diverging environments:  minimal blast radius, per-environment access control and backends, explicit config, easy audit.  Downside: some code duplication (mitigate with shared modules).
- **Workspaces** (one config, multiple states via `terraform.workspace`). Good for near-identical environments with few differences; downside: conditional logic gets messy, weaker isolation, easy to apply to the wrong workspace. Note the **GitLab HTTP backend doesn’t support workspaces** — use named states instead.
- Decision heuristic: same resources across envs → workspaces OK; different resource sets or different owners → separate directories/backends; >50 resources or catastrophic-if-destroyed prod → separate directories.  Also split by **blast radius** (network vs. compute vs. stateful data stores) not just environment.

**Pipeline structure: validate → plan → apply.** Store the plan as an artifact and apply *that exact plan* in the next job so apply matches what was reviewed. Publish `terraform show -json` output as a `reports: terraform:` artifact to render the diff in the MR.  Keep the plan artifact access at `developer`, not public (plan files aren’t encrypted and can leak secrets).

**Manual approval gate for apply.** A blocking manual job plus a protected environment:

```yaml
stages: [plan, approve, apply]

plan:
  stage: plan
  script:
    - cd $TF_ROOT
    - tofu init && tofu plan -out=tfplan
    - tofu show -no-color tfplan > plan.txt
  artifacts:
    access: 'developer'
    paths: [ "$TF_ROOT/tfplan", "$TF_ROOT/plan.txt" ]
    expire_in: 7 days
  rules: [ { if: '$CI_COMMIT_BRANCH == "main"' } ]

approve:
  stage: approve
  script: [ 'echo "Approved by $GITLAB_USER_LOGIN at $(date)"' ]
  when: manual
  allow_failure: false           # blocks the apply stage until approved
  rules: [ { if: '$CI_COMMIT_BRANCH == "main"' } ]

apply:
  stage: apply
  script: [ "cd $TF_ROOT", "tofu apply -auto-approve tfplan" ]
  environment: { name: production }
  resource_group: production
  needs:
    - { job: plan, artifacts: true }
    - { job: approve, artifacts: false }
  rules: [ { if: '$CI_COMMIT_BRANCH == "main"' } ]
```

For stronger control, use **protected environments** with required approvers/approval rules so only authorized users can run the production apply — this also produces the audit trail auditors (SOC 2 / ISO 27001) expect.  Keep the approval window short so plans don’t go stale.

**Access controls & least privilege.**

- **Masked + protected CI/CD variables** for any secret; protect variables so they’re only exposed on protected branches/tags. 
- **OIDC `id_tokens` over long-lived keys.** GitLab issues a short-lived JWT per job; the cloud exchanges it for temporary credentials via `AssumeRoleWithWebIdentity`.  Scope the IAM trust policy with `sub` (`project_path:...:ref:main`), `aud`, and `namespace_id`/`project_id` conditions so only specific projects/branches can assume the role.

```yaml
apply:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  script:
    - >
      export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s"
      $(aws sts assume-role-with-web-identity
      --role-arn "$AWS_ROLE_ARN"
      --role-session-name "gitlab-${CI_PIPELINE_ID}"
      --web-identity-token "$GITLAB_OIDC_TOKEN"
      --duration-seconds 3600
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
      --output text))
    - tofu init && tofu apply -auto-approve plan.cache
```

(Use `CI_JOB_JWT_V2` only on very old GitLab; the `id_tokens:` block is the current mechanism.)  Lock production state backends to read-only for most users; restrict write to the CI role and break-glass identities. Separate IAM roles per environment.

**Backup, recovery, and migration.**

- Enable **versioning** on the state store (S3 versioning, Azure blob versioning + soft delete, GCS object versioning, GitLab’s built-in versioning) — this is your rollback mechanism. Verify recovery by actually restoring an old version at least once.
- **Migrate between backends** with `terraform init -migrate-state`  (copies state to a new backend) vs. `-reconfigure` (discards init’s cached backend record without copying). Migrating to/from GitLab-managed state uses the same `-migrate-state` flow with the HTTP `-backend-config` flags shown earlier; answer `yes` when prompted to copy. 
- For GitLab self-managed, admins can back the state store with object storage (recommended for clustered deployments to avoid split state) and migrate local→object storage.

**Drift detection with scheduled pipelines.** Run `terraform plan -detailed-exitcode` on a GitLab **schedule** (`rules: - if: $CI_PIPELINE_SOURCE == "schedule"`). Exit code `0` = no drift, `1` = error, `2` = drift;  alert (e.g., Slack webhook) on `2`.

```yaml
drift-detection:
  stage: validate
  rules: [ { if: '$CI_PIPELINE_SOURCE == "schedule"' } ]
  script:
    - cd ${TF_ROOT} && tofu init
    - |
      set +e
      tofu plan -detailed-exitcode -no-color 2>&1 | tee plan-output.txt
      EXIT=$?
      set -e
      if [ $EXIT -eq 2 ]; then
        curl -X POST "$SLACK_WEBHOOK" -H "Content-Type: application/json" \
          -d "{\"text\":\"Drift detected in ${CI_PROJECT_NAME}: ${CI_PIPELINE_URL}\"}"
      fi
  artifacts:
    paths: [ "${TF_ROOT}/plan-output.txt" ]
    expire_in: 7 days
```

Cadence: daily (or hourly for critical prod), weekly for lower environments;  schedule outside business hours since drift checks consume the same runner/lock capacity as real applies.  Use `lifecycle.ignore_changes` to suppress expected noise (autoscaling counts, managed fields). Prefer `terraform/tofu apply -refresh-only` over the deprecated `refresh` command when reconciling. 

## Recommendations

**Stage 1 — Start here (most teams already on GitLab):** Adopt the **OpenTofu CI/CD component** with **GitLab-managed state**, one **named state per environment** (`dev`/`staging`/`prod`), plan-as-artifact, and a **manual apply gate** on the default branch. This gets you locking, encryption, versioning, and MR plan diffs with essentially zero infra. Set plan artifact `access: 'developer'` and use masked/protected variables.

**Stage 2 — Harden:** Replace any long-lived cloud keys with **OIDC `id_tokens`** scoped by `project_path`/`ref`. Add a **protected environment** with required approvers for production. Add a **scheduled drift-detection** pipeline alerting on exit code 2. Turn on component **state auto-encryption** (passphrase from a protected/masked variable) if plan/state sensitivity is a concern.

**Move to a cloud backend (S3 native lockfile / Azure Blob / GCS) when any of these thresholds hit:**

- You manage **dozens of states** or state files approach GitLab’s size limits.
- Non-GitLab tooling (Atlantis, Spacelift, ad-hoc `terraform` runs, other CI) needs direct state access.
- You require **customer-managed encryption keys (KMS/CMK)** for compliance.
- Your **disaster-recovery model can’t tolerate** state decryption depending on GitLab being online (e.g., GitLab itself is provisioned by this state).
- Use **S3 + `use_lockfile = true`** (drop DynamoDB) as the default AWS choice; enable bucket versioning + KMS + public-access block; least-privilege IAM on state key and `.tflock`.

**Choose HCP Terraform** only if you specifically need Sentinel policy-as-code, remote execution, or a managed governance/RBAC layer and accept the SaaS cost and lock-in — serialize applies with `resource_group` to dodge API rate limits.

**Always, regardless of choice:** never commit state to Git; keep secrets in a secret manager, not in state or `.tfvars`; isolate environments and split by blast radius; enable versioning and test a restore; require human approval before production apply.

**Benchmarks that should change your approach:** if drift is detected frequently → tighten IAM to block console changes and increase check frequency; if lock contention is common → confirm `resource_group` serialization and `-lock-timeout`; if you’re a managed-service/SaaS vendor building on the IaC engine → the BSL matters, standardize on OpenTofu; if legal/procurement requires OSI-approved open source → OpenTofu (MPL 2.0), not Terraform (BSL).

## Caveats

- **Version specifics move fast.** The OpenTofu component’s latest release (4.7.0) and default OpenTofu version (1.12.1) are current as of mid-2026 but change frequently — check `gitlab.com/components/opentofu` releases before pinning. (Independent verification in available sources only reliably confirmed up to release 4.3.0 / OpenTofu 1.11.4, so treat the 4.7.0 / 1.12.1 figures as needing a live check.) The component currently requires you to pass `version:` explicitly (a documented workaround for GitLab issue #438275).
- **S3 native locking maturity:** `use_lockfile` was experimental in Terraform v1.10.0 (2024-11-27) and GA from v1.11.0 (2025-02-27); it is available in OpenTofu 1.10+. On older CLI versions you still need DynamoDB. Some older tutorials still describe it as “experimental” — verify against your exact CLI version.
- **GitLab-managed state DR** genuinely depends on the instance and `db_key_base`; treat the bootstrap-dependency warning as a hard constraint, not a footnote.
- **Terraform vs OpenTofu commands** are largely interchangeable (`terraform`/`tofu`), and state format is shared, but features have diverged since the fork (OpenTofu: native state encryption; Terraform: Stacks, Sentinel). Verify provider/module compatibility before migrating production. 
- Several code patterns here are drawn from vendor engineering blogs (OneUptime, Spacelift, Scalr) and community tutorials; treat them as starting templates and validate against the official GitLab, HashiCorp, and OpenTofu docs for your versions. Where blogs describe forward-looking deprecations (e.g., eventual full removal of DynamoDB locking arguments), those are announced intentions, not completed removals.