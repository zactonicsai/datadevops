# GitLab CI/CD Infrastructure Pipeline Template

A reusable, modular GitLab CI/CD pipeline for provisioning and deploying with
**AWS + Terraform + kubectl/EKS + Helm + Ansible** (and optional **Kafka**).
Anyone can adopt it by editing one variables file.

## Why this layout

The pipeline is split into small `include` files under `ci/includes/`, each owning
one concern. The root `.gitlab-ci.yml` only wires them together and declares the
stage order. This means:

- You customize behavior in **one place** (`ci/includes/00-variables.yml`).
- You can enable/disable whole tools with `ENABLE_*` flags.
- You can reference these includes **remotely** from a central template repo, so
  many projects share one source of truth.

## Directory structure

```
.
├── .gitlab-ci.yml                  # Root orchestrator (includes + stages only)
├── ci/
│   ├── includes/                   # Modular pipeline phases (THE pipeline)
│   │   ├── 00-variables.yml        # ← PRIMARY customization surface
│   │   ├── 01-workflow.yml         # When pipelines run + reusable rule/base jobs
│   │   ├── 10-prerequisites.yml    # Runner checks, tool install + version pinning, auth smoke tests
│   │   ├── 20-validation.yml       # fmt/validate/lint/security (read-only)
│   │   ├── 30-terraform.yml        # init/plan/apply/destroy/drift (remote state + lock)
│   │   ├── 40-kubernetes.yml       # EKS auth + kubectl diff/apply/smoke
│   │   ├── 50-helm.yml             # template/deploy/rollback
│   │   ├── 60-ansible.yml          # check (dry-run) + run
│   │   ├── 70-kafka.yml            # topic validate/list/apply
│   │   ├── 90-debug.yml            # manual diagnostics (never auto-run)
│   │   └── 99-cleanup.yml          # teardown + state cleanup (double-gated)
│   ├── templates/                  # (optional) extra job templates to share
│   └── scripts/                    # Shell helpers called by jobs
│       ├── prerequisites/          # install-tools.sh, verify-versions.sh
│       ├── validation/             # validate-k8s.sh, validate-kafka.sh
│       ├── debug/                  # ad-hoc diagnostic scripts
│       └── cleanup/                # ad-hoc cleanup scripts
├── terraform/
│   ├── backend/                    # ONE-TIME bootstrap of S3 bucket + DynamoDB lock
│   ├── backend.tf                  # Empty s3 backend (configured at init time by CI)
│   ├── modules/                    # Reusable TF modules
│   └── environments/{dev,staging,prod}/  # Per-env roots + tfvars (state isolation)
├── kubernetes/
│   ├── manifests/                  # Raw YAML
│   └── kustomize/{base,overlays/{dev,prod}}/
├── helm/
│   ├── charts/my-app/              # Chart skeleton
│   └── values/{dev,prod}.yaml      # Per-env values
├── ansible/
│   ├── ansible.cfg, playbooks/, roles/, inventory/, group_vars/
├── kafka/
│   ├── topics/topics.yml           # Declarative topics
│   └── config/                     # client.properties examples
├── config/
│   ├── aws/                        # OIDC + account notes (non-secret)
│   └── eks/                        # aws-auth ConfigMap example
└── docs/
    ├── ONBOARDING.md
    └── VARIABLES.md
```

## Pipeline phases (stages)

| Stage           | Purpose                                                        | Auto/Manual |
|-----------------|----------------------------------------------------------------|-------------|
| `prerequisites` | Verify runner, install + pin tool versions, smoke-test auth    | auto on MR  |
| `validate`      | fmt, validate, lint, security scan — read-only                 | auto on MR  |
| `plan`          | `terraform plan`, `helm template`, `kubectl diff`, ansible `--check` | auto    |
| `build`         | Build/package artifacts (images, bundles) — add your jobs      | auto        |
| `deploy`        | Apply infra + workloads                                        | manual gate |
| `test`          | Post-deploy smoke/integration                                  | auto after deploy |
| `debug`         | Dump diagnostics for AWS/k8s/helm/terraform                    | manual only |
| `cleanup`       | Teardown + release state locks                                 | manual + `ALLOW_DESTROY` |

## Quick start

1. **Bootstrap remote state once** (local apply):
   ```bash
   cd terraform/backend
   cp terraform.tfvars.example terraform.tfvars   # edit names
   terraform init && terraform apply
   ```
2. **Set protected CI/CD variables** in GitLab → Settings → CI/CD → Variables:
   - `AWS_ROLE_ARN` (OIDC, recommended) **or** `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`
   - For Ansible: `ANSIBLE_SSH_PRIVATE_KEY` (File), `ANSIBLE_VAULT_PASSWORD_FILE` (File)
   - For Kafka SASL: `KAFKA_SASL_USERNAME`, `KAFKA_SASL_PASSWORD`
3. **Edit `ci/includes/00-variables.yml`**: cluster name, region, state bucket,
   chart path, tool versions, and `ENABLE_*` toggles.
4. **Open an MR** — prerequisites + validation + plan run automatically.
5. **Merge / run the manual `deploy` jobs** to apply.

## Reuse model

**Option A — copy the repo** and edit `00-variables.yml`. Best when teams want to
diverge.

**Option B — central template repo** (recommended for many projects). In each
consuming project's `.gitlab-ci.yml`:

```yaml
include:
  - project: 'platform/gitlab-pipeline-template'
    ref: v1.0.0
    file:
      - '/ci/includes/01-workflow.yml'
      - '/ci/includes/10-prerequisites.yml'
      - '/ci/includes/20-validation.yml'
      - '/ci/includes/30-terraform.yml'
      - '/ci/includes/40-kubernetes.yml'
      - '/ci/includes/50-helm.yml'
      - '/ci/includes/60-ansible.yml'
      - '/ci/includes/90-debug.yml'
      - '/ci/includes/99-cleanup.yml'

# Override only what differs:
variables:
  EKS_CLUSTER_NAME: "team-a-cluster"
  TF_ROOT: "terraform/environments/dev"
  HELM_CHART_PATH: "helm/charts/team-a-app"
```

## Safety design

- **No secrets in the repo.** AWS auth uses OIDC role assumption; kubeconfig is
  generated at runtime from EKS; Ansible/Kafka secrets come from protected CI vars.
- **Destroy is double-gated:** requires `ALLOW_DESTROY=true` *and* a manual click.
- **Plan → apply uses the saved plan artifact**, so apply does exactly what was reviewed.
- **State is isolated per environment** via `TF_STATE_KEY_PREFIX/<env>/terraform.tfstate`
  with DynamoDB locking.
- **Tool versions are pinned and verified** in `prerequisites` before any real work.
