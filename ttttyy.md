Here's a layout that holds up well for Keycloak specifically, where realm config churns constantly but network/DB barely move.

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