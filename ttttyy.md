# Keycloak on Terraform: dev / stage / prod

A working reference layout for running Keycloak, its PostgreSQL database, its
network and its realm/role configuration across three environments, with the
environment expressed as **data** rather than as copy-pasted code.

---

## 1. Quick start: bring up dev, one layer at a time

Prerequisites: Terraform >= 1.10, AWS credentials, an existing Kubernetes
cluster, an S3 state bucket per environment, and `make`.

### Step 1 - point the backends at your own state buckets

Each layer has `backends/{dev,stage,prod}.hcl`. Replace the placeholder bucket
names:

```hcl
# layers/10-network/backends/dev.hcl
bucket       = "acme-tfstate-dev"      # <- your bucket
key          = "keycloak/10-network/terraform.tfstate"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true                    # S3 native locking, Terraform >= 1.10
```

Also update `state_bucket` in each layer's `vars/dev.tfvars`, since the layers
read each other's outputs through `terraform_remote_state`.

### Step 2 - put the secrets where the code expects them

Nothing secret lives in a `.tfvars` file. Create these first:

```bash
aws secretsmanager create-secret --name kc/dev/db-password              --secret-string '...'
aws secretsmanager create-secret --name kc/dev/admin-password           --secret-string '...'
aws secretsmanager create-secret --name kc/dev/terraform-client-secret  --secret-string '...'
export TF_VAR_db_password="$(aws secretsmanager get-secret-value --secret-id kc/dev/db-password --query SecretString --output text)"
```

### Step 3 - apply the layers in order

```bash
make plan  ENV=dev LAYER=10-network
make apply ENV=dev LAYER=10-network

make plan  ENV=dev LAYER=20-postgres
make apply ENV=dev LAYER=20-postgres

make plan  ENV=dev LAYER=30-keycloak-runtime
make apply ENV=dev LAYER=30-keycloak-runtime
```

### Step 4 - create the Terraform service account inside Keycloak

Layer 40 talks to the Keycloak Admin API, so Keycloak must exist and Terraform
needs an identity. In the `master` realm, create a confidential client called
`terraform` with service accounts enabled, and grant its service account the
`realm-admin` role from `realm-management`. Put its secret in
`kc/dev/terraform-client-secret`.

### Step 5 - apply the realm configuration

```bash
make plan  ENV=dev LAYER=40-realm-config
make apply ENV=dev LAYER=40-realm-config
```

Then repeat the whole sequence with `ENV=stage` and `ENV=prod`. The code does
not change; only the files under `vars/` and `data/` do.

Shortcut for a full stack:

```bash
make plan-all ENV=stage
```

---

## 2. Directory structure and what each part is for

```
terraform/
├── Makefile                     # the only supported entrypoint
├── modules/                     # reusable, environment-agnostic building blocks
│   ├── network/                 # VPC, subnets, NAT, routing
│   ├── postgres/                # RDS PostgreSQL, subnet group, security group
│   ├── keycloak-runtime/        # Keycloak Helm release + credentials secret
│   └── keycloak-realm/          # realm, roles, clients, groups, federation
├── layers/                      # root modules; one state file per (layer x env)
│   ├── 10-network/
│   ├── 20-postgres/
│   ├── 30-keycloak-runtime/
│   └── 40-realm-config/
│       └── data/                # realm config as YAML: common/ + per-env overrides
├── scripts/check-role-parity.sh # CI check: role sets identical in all envs
└── .github/workflows/terraform.yml
```

Every layer has the same shape:

| File | Purpose |
| --- | --- |
| `backend.tf` | Empty `backend "s3" {}` block; filled at `init` time |
| `backends/<env>.hcl` | Which bucket and key this environment's state lives in |
| `vars/common.tfvars` | Values identical in all environments |
| `vars/<env>.tfvars` | The environment's deltas |
| `versions.tf` | Provider versions and provider configuration |
| `main.tf` | Module calls plus guardrail preconditions |

The command the Makefile runs is always:

```bash
terraform init -reconfigure -backend-config=backends/$ENV.hcl
terraform plan -var-file=vars/common.tfvars -var-file=vars/$ENV.tfvars
```

---

## 3. The design decisions, and why

### 3.1 Layers, not one giant state

Each layer is applied separately and has its own state file. Downstream layers
read upstream outputs with `terraform_remote_state`.

- Blast radius: a mistake in realm config cannot destroy a database.
- Speed: changing a redirect URI plans in seconds, not minutes.
- Permissions: the team that edits roles never needs `rds:DeleteDBInstance`.
- Lifecycle: the network changes twice a year; realm config changes weekly.

The cost is ordering. Layers are numbered so the order is obvious, and CI
applies them with `max-parallel: 1`.

### 3.2 Keycloak runtime and realm config must be separate layers

This is the Keycloak-specific decision that matters most.

The `keycloak` provider is configured with a URL and credentials, and it talks
to a live server. If realms live in the same root module as the deployment:

- The first `apply` cannot work: the provider must be configured before
  Keycloak exists.
- A `destroy` breaks halfway through for the same reason.
- Every realm tweak re-reads the entire infrastructure state.

Splitting them means layer 40's provider points at layer 30's output URL, and
`initial_login = false` keeps the plan from authenticating while the graph is
being built.

### 3.3 Environment as data, not as duplicated directories

A common alternative is `environments/dev/`, `environments/stage/`,
`environments/prod/`, each with its own `main.tf`.

| Approach | Pros | Cons |
| --- | --- | --- |
| One root module + `-var-file` (used here) | Impossible for prod to silently miss a resource; a change ships to all envs by construction | Requires discipline about `-var-file`, which the Makefile enforces |
| Directory per environment | Extremely obvious; easy per-env exceptions | Drift is inevitable; a fix applied to dev and stage but not prod is the classic outage |
| Workspaces | Cheapest to set up | Single backend and single credential set; a typo in `workspace select` applies dev values to prod |

Terraform Stacks and tools like Terragrunt solve the same problem. This layout
uses only core Terraform plus `make`, so it works anywhere.

### 3.4 Never name environment files `*.auto.tfvars`

With `dev.tfvars`, `stage.tfvars` and `prod.tfvars` sitting in the same
directory, the `.auto.tfvars` suffix would make Terraform load **all three**
automatically, in lexical order, and prod values would silently leak into a dev
plan. Plain `.tfvars` files loaded with explicit `-var-file` are the only safe
option here. The `.gitignore` also blocks `*.auto.tfvars` outright.

### 3.5 What belongs in `common.tfvars` versus `<env>.tfvars`

Belongs in **common**: project name, owner, engine versions, chart and image
tags, ingress class, client IDs, role definitions, group structure, password
policy, brute-force settings.

Belongs in **per-env**: region and CIDRs, instance sizes and replica counts,
`multi_az` / `deletion_protection` / backup retention, hostnames and redirect
URIs, secret names, log level, token lifespans, and whether seed users exist.

The rule of thumb: if an environment differing from another on this value is
a **feature**, it is per-env. If it would be a **bug**, it is common.

### 3.6 Roles and groups are environment-invariant, by force

`layers/40-realm-config/data/common/roles.yaml` and `groups.yaml` are the
authorisation model. They are loaded identically in all three environments, and
`terraform_data.guardrails` rejects any attempt to override them:

```hcl
precondition {
  condition     = !can(local.overrides.roles) && !can(local.overrides.groups)
  error_message = "Roles and groups are environment invariant."
}
```

A role that exists in stage but not in prod means a permission check that
passed in testing fails in production, or worse, silently grants nothing.
`scripts/check-role-parity.sh` re-verifies this after apply by comparing the
`realm_role_names` output across environments.

Roles are granted to **groups**, never directly to users. Group membership is
what LDAP mappers and the external IdP feed into, and it is what an auditor can
read.

Composite roles are created by a second resource (`keycloak_role.composite`)
that references the base roles. Terraform needs the base role IDs to exist
first, and keeping composites one level deep keeps the dependency graph
readable.

### 3.7 Guardrails use `precondition`, not `check`

A `check` block only emits a **warning**; the apply proceeds. For rules that
must stop a bad plan, use `lifecycle { precondition { ... } }` on a
`terraform_data` resource, which fails the plan. This repo uses preconditions
for:

- prod: multi-AZ, deletion protection, no skipped final snapshot, >= 14 days of
  backups, >= 3 AZs, no single NAT gateway, >= 2 Keycloak replicas
- prod: `ssl_required = all`, no seed users, no self-registration, no localhost
  or host-wildcard redirect URIs
- all: composite roles and group role grants must resolve to a defined role

Plus `variable "environment"` validation restricting it to `dev|stage|prod`, so
a typo cannot create a fourth environment.

### 3.8 Secrets

Three rules:

1. No secret values in any `.tfvars` file. Passwords come from
   `TF_VAR_db_password` injected by CI, or from a
   `aws_secretsmanager_secret_version` data source read at apply time.
2. Keycloak's admin and DB passwords go into a Kubernetes `Secret` that the
   Helm chart references by name (`existingSecret`), not into Helm values,
   where they would sit in the release manifest in plain text.
3. Client secrets that Keycloak generates end up in Terraform state regardless.
   Therefore: encrypted state buckets, versioning on, access logging on, and
   prod state in a separate AWS account from dev and stage.

The `aws_db_instance` uses `ignore_changes = [password]` so that a rotation
performed out-of-band does not show up as permanent drift.

### 3.9 State layout

```
s3://acme-tfstate-<env>/keycloak/<layer>/terraform.tfstate
```

One bucket per environment, ideally one account per environment. That way an
IAM policy, not a code review, is what stops a dev apply from touching prod.

---

## 4. Day-two operations

**Add a role**: edit `data/common/roles.yaml`, add it to a group in
`groups.yaml`, plan all three environments. It ships everywhere or nowhere.

**Add a client**: add it to `data/common/clients.yaml` with flows and scopes,
then add the per-environment URLs to each `data/<env>/overrides.yaml`. The
guardrail rejects an override for a client that does not exist in common.

**Upgrade Keycloak**: bump `keycloak_image_tag` and `chart_version` in
`layers/30-keycloak-runtime/vars/common.tfvars`, or override in
`dev.tfvars` first to soak it, then promote by moving the value to common.
Take a database snapshot before a major-version upgrade; Keycloak runs
schema migrations on start.

**Rotate the DB password**: update the Secrets Manager secret and let the
runtime layer re-read it; the DB resource ignores password drift by design.

**Import an existing realm**: use `import` blocks in layer 40 rather than
`terraform import`, so the intent is reviewable in the pull request.

---

## 5. Known limitations of this reference

- The runtime layer assumes an existing EKS cluster and uses the Bitnami
  Keycloak chart. Swap `modules/keycloak-runtime` for ECS, the Keycloak
  Operator, or plain manifests without touching any other layer.
- Chart values are a subset. Add HA cache configuration (`jgroups`/Infinispan),
  pod disruption budgets and network policies before real production use.
- Authentication flows, required actions, protocol mappers and client scopes
  beyond the built-ins are not modelled; extend `modules/keycloak-realm`.
- Placeholder values (`acme-tfstate-*`, `example.com`, `eu-west-1`) appear
  throughout and must be replaced.


## Directory structure

```
terraform/
├── Makefile                      # single entrypoint: make plan ENV=prod LAYER=20-postgres
├── modules/                      # reusable, env-agnostic; no backend or provider blocks
│   ├── network/
│   ├── postgres/
│   ├── keycloak-runtime/
│   └── keycloak-realm/
└── layers/                       # root modules; one state file per (layer × env)
    ├── 10-network/
    │   ├── main.tf  variables.tf  outputs.tf  versions.tf
    │   ├── backend.tf             # partial config, filled by -backend-config
    │   ├── backends/{dev,stage,prod}.hcl
    │   └── vars/{common,dev,stage,prod}.tfvars
    ├── 20-postgres/               # same shape
    ├── 30-keycloak-runtime/       # same shape
    └── 40-realm-config/
        ├── main.tf  versions.tf
        ├── data/
        │   ├── common/{realms,clients,roles,groups}.yaml
        │   └── {dev,stage,prod}/overrides.yaml
        ├── backends/{dev,stage,prod}.hcl
        └── vars/{common,dev,stage,prod}.tfvars
```

Environment is *data*, not duplicated code. Each layer is applied as `terraform init -backend-config=backends/$ENV.hcl -reconfigure` then `apply -var-file=vars/common.tfvars -var-file=vars/$ENV.tfvars`. Wrap that in the Makefile so the backend and var-file can never be mismatched — that's the one real risk of this shape.

## The decisions that matter

**Split runtime from realm config (layers 30 vs 40).** This is the Keycloak-specific one. The `keycloak` provider needs a reachable Keycloak with admin credentials at *plan* time. If realms live in the same root module as the deployment, your plans break during bootstrap and teardown, and every role tweak re-plans your whole cluster. Layer 40 reads layer 30's URL via `terraform_remote_state`.

**Keep the RBAC model env-invariant.** Roles, composite roles, and client scopes should be byte-identical across dev/stage/prod — a role missing in prod is an outage. Load them from `data/common/*.yaml` with `yamldecode` + `for_each`. Only these belong in env overrides: hostnames and redirect URIs, IdP endpoints, token lifespans, brute-force settings, user federation (local users in dev, LDAP/AD in prod), and dev-only test users.

**Never name env files `*.auto.tfvars`.** With all three sitting in one `vars/` directory, Terraform would auto-load every one of them and prod values would leak into dev plans. Plain `.tfvars` with explicit `-var-file` only.

**No secrets in tfvars.** DB password and Keycloak admin password come from `TF_VAR_*` injected by CI, or a Secrets Manager/Vault data source. Also note that any client secret Terraform generates lands in state — so state buckets need encryption, versioning, and prod ideally in a separate account or subscription.

**Guardrails via validation.** An `environment` variable with a `validation` block restricting it to the three values, used consistently in resource naming and tags, plus preconditions forcing `deletion_protection` and multi-AZ on when `environment == "prod"`.

I can generate a working starter — the Makefile, the partial backend pattern, and a `40-realm-config` that reads roles from YAML — if that's useful.