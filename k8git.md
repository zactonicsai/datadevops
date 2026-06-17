# GitLab Setup Runbook — Multi-Tenant EKS (Flux + agentk)

Operational companion to `README.md` / `PATTERNS.md`. Covers every GitLab-side
step needed to stand up the platform: group/project structure, the agent, Flux,
per-tenant onboarding, CI/CD pipelines, and the full troubleshooting catalogue.

Two paths are given for each setup task: **Web console** (Operate → … in the
GitLab UI) and **CLI** (`glab` + `kubectl` + `flux`). Use whichever fits; they
produce the same result.

> Conventions used throughout
> 
> - GitLab host: `gitlab.example.com` (self-managed or gitlab.com — noted where it matters)
> - Top group: `platform`, plus one group per tenant (`tenant-a`, `tenant-b`)
> - Agent name: `eks-shared`, lives in the `platform/platform-addons` project
> - Cluster namespaces for platform tooling: `flux-system`, `gitlab` (agentk)

-----

## 0. Collect this before you start

Have these in hand; most pipeline failures trace back to one of them being wrong,
missing, or scoped incorrectly. Keep them in your password manager, **not** in Git.

### 0.1 GitLab account / instance facts

|Item                               |How to get it                                                           |Why needed                                                                     |
|-----------------------------------|------------------------------------------------------------------------|-------------------------------------------------------------------------------|
|GitLab version                     |Help → Help, or `GET /api/v4/version`, or `glab api version`            |agentk image tag must match the instance; Flux integration needs ≥ 16.1        |
|Tier (Free/Premium/Ultimate)       |Admin → Subscription                                                    |`user_access` UI, protected environments, and some compliance features are paid|
|`kasAddress` (KAS endpoint)        |Shown when you register an agent; gitlab.com uses `wss://kas.gitlab.com`|agentk connects to it                                                          |
|Instance vs group runners available|Settings → CI/CD → Runners                                              |pipelines won’t run without an available runner                                |

### 0.2 Tokens & secrets (record scope + expiry for each)

|Secret                         |Scope                                             |Used by                              |Notes                                                                |
|-------------------------------|--------------------------------------------------|-------------------------------------|---------------------------------------------------------------------|
|Agent access token             |(issued by agent registration)                    |agentk install                       |One per agent; rotate by re-registering                              |
|Personal access token (PAT)    |`api`                                             |`glab` CLI, Flux CLI bootstrap       |Prefer a short-lived token; never commit                             |
|Deploy token — platform repo   |`read_repository`                                 |Flux `gitlab-platform-token` secret  |Read-only                                                            |
|Deploy token — each tenant repo|`read_repository`                                 |Flux `gitlab-tenant-<x>-token` secret|One per tenant, read-only                                            |
|CI/CD variable `GITOPS_TOKEN`  |`write_repository` (project or group access token)|`update:manifest` job                |Masked + protected                                                   |
|Registry credentials           |—                                                 |Kaniko build / pull secrets          |GitLab Container Registry is automatic in-pipeline (`$CI_REGISTRY_*`)|

### 0.3 AWS / cluster facts (cross-checked from infra-eks outputs)

|Item                               |Source                         |Why needed                                              |
|-----------------------------------|-------------------------------|--------------------------------------------------------|
|EKS cluster name                   |`terraform output cluster_name`|agentk + kubeconfig context                             |
|Cluster endpoint + CA              |`terraform output`             |only if you bypass agentk for bootstrap                 |
|Region                             |`infra-eks/variables.tf`       |CLI commands                                            |
|Node-group labels/taints per tenant|`eks.tf`                       |must match tenant pod `nodeSelector`/tolerations exactly|
|Pod Identity SA names              |`pod-identity.tf`              |must match `serviceAccountName` in tenant manifests     |

### 0.4 Naming map (fill in once, reuse everywhere)

```
GitLab group : tenant-a              k8s namespace : tenant-a-prod
GitLab repo  : tenant-a/apps         node label    : tenant=tenant-a
impersonation: gitlab:tenant-a       node taint    : tenant=tenant-a:NoSchedule
Flux source  : tenant-a-apps         deploy SA     : tenant-a-deployer
deploy token : gitlab-tenant-a-token pod IAM SA    : tenant-a-app
```

**Gotcha G-3 (naming-map drift — the most common cause of “applied but not
running”):** every value in the row above appears in at least two places (a
GitLab/Flux manifest and a Kubernetes object), and they must match **character
for character**. The frequent breakages: the pod’s `nodeSelector`/toleration
don’t equal the node group’s label/taint (pod stays `Pending` with
`untolerated taint`); the `serviceAccountName` doesn’t equal the Pod Identity SA
(`CreateContainerConfigError`); Flux’s `targetNamespace` doesn’t equal the
namespace the RBAC grants (apply `forbidden`). Fix: keep this row as the single
source of truth and diff against it before debugging anything else. Detailed
triage in 6.2 step 3–5.

-----

## 1. Create the group & project structure

### 1.1 Web console

1. **Groups → New group** → name `platform`. Repeat for each tenant group
   (`tenant-a`, `tenant-b`).
1. Inside `platform`: **New project → Create blank project** twice → `infra-eks`
   and `platform-addons`. Initialize with a README so the default branch exists.
1. Inside each tenant group: **New project** → `apps`.
1. Optional shared group: `shared/helm-charts`.
1. For each project: **Settings → Repository → Protected branches** → protect
   `main` (allow merge: Maintainers; allow push: No one). This forces MRs.

### 1.2 CLI (`glab`)

```bash
# Authenticate once
glab auth login --hostname gitlab.example.com   # paste a PAT with `api` scope

# Groups
glab api groups --method POST -f name=platform -f path=platform
glab api groups --method POST -f name=tenant-a -f path=tenant-a
glab api groups --method POST -f name=tenant-b -f path=tenant-b

# Projects (namespace_id = the group's numeric id from `glab api groups`)
PLATFORM_ID=$(glab api "groups/platform" | jq .id)
glab api projects --method POST -f name=infra-eks       -f namespace_id=$PLATFORM_ID -f initialize_with_readme=true
glab api projects --method POST -f name=platform-addons -f namespace_id=$PLATFORM_ID -f initialize_with_readme=true

TA_ID=$(glab api "groups/tenant-a" | jq .id)
glab api projects --method POST -f name=apps -f namespace_id=$TA_ID -f initialize_with_readme=true
```

**Gotcha G-1 (group/path mismatch):** the agent config `ci_access.projects[].id`
uses the **full path** (`tenant-a/apps`), not the numeric id. If you rename a
group later, the agent config silently stops matching that project — update both.

-----

## 2. Push the repository contents

Map the bundle directories to the projects (each becomes that repo’s root):

|Bundle dir        |GitLab project            |Default branch|
|------------------|--------------------------|--------------|
|`infra-eks/`      |`platform/infra-eks`      |`main`        |
|`platform-addons/`|`platform/platform-addons`|`main`        |
|`tenant-a-apps/`  |`tenant-a/apps`           |`main`        |

```bash
# Example for platform-addons
cd platform-addons
git init -b main
git remote add origin https://gitlab.example.com/platform/platform-addons.git
git add . && git commit -m "platform addons: agent config, flux, tenancy, network"
git push -u origin main
```

**Gotcha G-2 (agent config path is exact):** the agent config MUST live at
`.gitlab/agents/<AGENT_NAME>/config.yaml` in the **agent’s project**
(`platform-addons` here). A file at the repo root, or under a differently-named
agent folder, is ignored with no error. Verify after push:
`glab api "projects/platform%2Fplatform-addons/repository/files/.gitlab%2Fagents%2Feks-shared%2Fconfig.yaml?ref=main"`
should return content, not 404.

-----

## 3. Register & install the agent (agentk)

This is the linchpin: agentk is the only thing that lets the cluster talk to
GitLab. Get this wrong and every later step appears broken.

### 3.1 Web console

1. In `platform/platform-addons`: **Operate → Kubernetes clusters → Connect a
   cluster (agent)**.
1. Select the existing config (`eks-shared`, since you pushed
   `.gitlab/agents/eks-shared/config.yaml`) → **Register**.
1. Copy the **agent access token** and **kasAddress** shown — they are displayed
   **once**. Store immediately.
1. GitLab shows a Helm install command. You can run it, or use the Flux-driven
   install in 3.2 (recommended, so agentk itself is GitOps-managed).

### 3.2 CLI install (Flux-managed agentk)

```bash
# Point kubectl at the cluster (direct, just for bootstrap)
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Install Flux first (it will manage agentk and everything else)
flux install            # or: flux bootstrap gitlab ... (see section 4)

# Install agentk via its Helm chart, injecting the token from step 3.1
helm repo add gitlab https://charts.gitlab.io
helm upgrade --install eks-shared gitlab/gitlab-agent \
  --namespace gitlab --create-namespace \
  --set config.token="$AGENT_TOKEN" \
  --set config.kasAddress="$KAS_ADDRESS"
```

### 3.3 Verify the agent is connected

- **Web:** Operate → Kubernetes clusters → the agent shows a green
  **Connected** status with a recent “last contact”.
- **CLI:**

```bash
kubectl -n gitlab get pods           # agentk pod Running
kubectl -n gitlab logs deploy/eks-shared-gitlab-agent | tail -20
# Healthy logs show: "Starting" then "Connected to ..." with no auth errors.
```

**Gotcha G-4 (token/kasAddress swap or stale):** the two most common agentk
failures are (a) pasting the token with a trailing newline, and (b) using a
`kasAddress` from a different instance. On gitlab.com it is `wss://kas.gitlab.com`;
self-managed uses your own host. Symptom: agentk pod CrashLoopBackOff or logs
repeating `rpc error: code = Unauthenticated`. Fix: re-register, re-copy, redeploy.

**Gotcha G-5 (egress blocked):** agentk needs **outbound** 443/wss to KAS. If
your nodes sit in private subnets, the NAT gateway must allow it (it does in the
`vpc.tf` config). No inbound rule is needed — that’s the whole point of the
tunnel. Symptom: logs show dial timeouts. Check the NAT route + any egress
firewall/SG.

**Info to collect if agent won’t connect:** agentk pod logs (`-n gitlab`), the
exact `kasAddress`, GitLab version, whether the token was rotated, and the
node’s outbound connectivity (`kubectl -n gitlab exec ... -- wget -qO- https://kas...`).

-----

## 4. Bootstrap Flux against GitLab

Flux does the reconciliation; agentk just wires + accelerates it. Two ways to
seed Flux’s own config.

### 4.1 `flux bootstrap gitlab` (Flux owns its install in a GitLab repo)

```bash
export GITLAB_TOKEN=<PAT with api scope>
flux bootstrap gitlab \
  --owner=platform \
  --repository=platform-addons \
  --branch=main \
  --path=clusters/eks-shared \
  --deploy-token-auth        # creates a deploy token automatically
# On self-managed add: --hostname=gitlab.example.com
```

This writes Flux’s components + a sync pointing at the repo path, and commits
them back to `platform-addons`.

### 4.2 Apply the platform root directly (simplest; matches the bundle)

```bash
# Create the read-only deploy-token secrets Flux's GitRepository objects expect
kubectl -n flux-system create secret generic gitlab-platform-token \
  --from-literal=username=gitlab-deploy \
  --from-literal=password="$PLATFORM_DEPLOY_TOKEN"
kubectl -n flux-system create secret generic gitlab-tenant-a-token \
  --from-literal=username=gitlab-deploy \
  --from-literal=password="$TENANT_A_DEPLOY_TOKEN"

# Apply the root once; Flux reconciles tenancy -> network -> tenant-sources
kubectl apply -f platform-addons/flux/platform-sync.yaml
```

### 4.3 Verify reconciliation

```bash
flux get sources git -A          # platform-addons + tenant-a-apps = Ready
flux get kustomizations -A       # tenancy, network, tenant-sources, tenant-a-apps = Ready
kubectl get ns                   # tenant-a-prod exists
kubectl -n tenant-a-prod get resourcequota,limitrange,rolebinding
```

**Gotcha G-6 (deploy token username):** GitLab deploy tokens have a generated or
chosen **username** that is NOT `oauth2`. Flux’s `secretRef` needs the real
username in the `username` key. Symptom: `GitRepository` stuck `Not Ready` with
`authentication required` / `403`. Fix: recreate the secret with the correct
username (check Settings → Repository → Deploy tokens).

**Gotcha G-7 (HTTPS vs SSH URL):** the bundle’s `GitRepository` uses an `https://`
URL + token secret. If you switch to an `ssh://` URL you must instead provide an
SSH key + `known_hosts` in the secret. Mixing them (https URL, ssh secret) fails
with a confusing handshake error.

**Gotcha G-8 (reconcile interval lag):** Flux polls on `interval` (5–10m in the
bundle). agentk makes GitLab pushes near-instant, but if agentk is down Flux
falls back to the slow poll and changes seem to “take minutes”. Force it:
`flux reconcile source git platform-addons` then
`flux reconcile kustomization tenancy --with-source`.

**Info to collect if Flux won’t sync:** `flux get all -A`, the failing object’s
events (`kubectl -n flux-system describe gitrepository <name>`), the deploy-token
username + scope, and the exact repo URL in the manifest vs the real project path.

-----

## 5. CI/CD configuration (variables, runners, environments)

### 5.1 Variables to set (per project or at group level)

Set at the **group** level when shared, **project** level when tenant-specific.
Settings → CI/CD → Variables.

|Variable        |Where                |Flags            |Value                                         |
|----------------|---------------------|-----------------|----------------------------------------------|
|`GITOPS_TOKEN`  |tenant `apps` project|Masked, Protected|project/group access token, `write_repository`|
|`KUBE_CONTEXT`  |tenant `apps` project|(plain)          |`platform/platform-addons:eks-shared`         |
|`AWS_REGION`    |`infra-eks`          |(plain)          |e.g. `eu-west-1`                              |
|TF backend creds|`infra-eks`          |Masked, Protected|OIDC role preferred over static keys          |

**Gotcha G-9 (Protected variable + unprotected branch):** a variable marked
**Protected** is injected ONLY on protected branches/tags. If your pipeline runs
on a feature branch and can’t see `GITOPS_TOKEN`, that’s why. Either run the
deploy job only on `main` (the bundle does) or unset Protected.

**Gotcha G-10 (Masked value rules):** masking requires the value to meet GitLab’s
rules (base64-ish, no newlines, min length). A token that fails masking is stored
**unmasked** and can leak into logs. Verify the “Masked” toggle actually stuck.

### 5.2 Runners

- gitlab.com: shared runners exist by default (Linux). Confirm the project has
  minutes available (Free tier is limited).
- Self-managed: register at least one runner with the `docker` or `kubernetes`
  executor. The bundle’s jobs need: Kaniko (build), `alpine`+`yq` (bump),
  `bitnami/kubectl` (verify).

```bash
# Check runners available to a project
glab api "projects/tenant-a%2Fapps/runners"
```

**Gotcha G-11 (no runner / wrong tags):** “This job is stuck because there are no
active runners” = no runner matches the job’s `tags:`. The bundle jobs use no
tags, so any untagged-enabled runner works. If your runners are tag-restricted,
add matching `tags:` to the jobs or enable “Run untagged jobs” on the runner.

### 5.3 Environments (for the agentk-tunneled deploy/verify)

The `KUBE_CONTEXT` only works if the agent has authorized the project via
`ci_access` in `config.yaml`. The tenant project must be listed there.

**Gotcha G-12 (ci_access missing the project):** if `tenant-a/apps` is not under
`ci_access.projects` in the agent config, `kubectl config use-context` fails with
`context not found` or the call is denied. This is separate from `user_access`
(which only governs the UI). Add the project, push config, wait for agentk to
reload (~30s).

-----

## 6. The pipelines — what each stage does and how it can fail

The bundle’s `.gitlab-ci.yml` has two shapes: infra (in `infra-eks`) and app (in
each tenant repo). Below: purpose, success signal, and the realistic failures.

### 6.1 Infra pipeline (`infra-eks`)

```
validate → plan → apply(manual, main only)
```

|Stage        |Success signal        |Common failure → fix                                                              |
|-------------|----------------------|----------------------------------------------------------------------------------|
|`tf:validate`|fmt clean, validate OK|fmt diff → run `terraform fmt` locally and commit                                 |
|`tf:plan`    |plan artifact produced|state lock held → another run in progress; wait or `force-unlock` carefully (G-13)|
|`tf:apply`   |apply complete        |manual gate not triggered (G-14); IAM perms on the CI role insufficient           |

**Gotcha G-13 (state lock):** with S3-native locking (`use_lockfile = true`), a
killed job can leave a lock. `terraform force-unlock <ID>` ONLY after confirming
no other apply is running, or you risk state corruption.

**Gotcha G-14 (manual job looks “skipped”):** `when: manual` jobs sit as
**blocked/manual**, not failed. Someone with deploy rights must click ▶ in the
pipeline. On a protected branch only protected-environment members can.

### 6.2 App pipeline (tenant `apps`)

```
build:image → update:manifest → verify:rollout
```

|Stage            |Success signal                           |Common failure → fix                                         |
|-----------------|-----------------------------------------|-------------------------------------------------------------|
|`build:image`    |image pushed to `$CI_REGISTRY_IMAGE:$SHA`|Kaniko can’t push → registry perms / `CI_REGISTRY_*` (G-15)  |
|`update:manifest`|new commit on `apps/main` with bumped tag|push rejected → `GITOPS_TOKEN` scope/branch protection (G-16)|
|`verify:rollout` |`rollout status` returns success         |context/impersonation/scheduling (G-12, G-3, G-17)           |

**Gotcha G-15 (Kaniko + registry auth):** Kaniko reads `$CI_REGISTRY`,
`$CI_REGISTRY_USER`, `$CI_REGISTRY_PASSWORD` automatically inside GitLab CI. If
you overrode the image or run Kaniko oddly, it may not pick up creds → `401 unauthorized` on push. Ensure the job runs in GitLab CI context and the project’s
**Container Registry** feature is enabled (Settings → General → Visibility).

**Gotcha G-16 (bot commit loops / push rejected):** the `update:manifest` job
pushes back to the same repo. Two failure modes:

- Push rejected: `GITOPS_TOKEN` lacks `write_repository`, or `main` is protected
  against the token’s user. Use a **project access token** with Maintainer role,
  or allow that token to push to protected `main`.
- Infinite pipeline loop: the bump commit re-triggers the pipeline. The bundle
  appends `[skip ci]` to the commit message to prevent this — keep it.

**Gotcha G-17 (rollout never completes — the big one):** `verify:rollout` hangs
then times out. Walk this order:

1. Did Flux apply the new image? `flux get kustomization tenant-a-apps` Ready +
   recent. If not → section 4 gotchas.
1. Is a pod pending? `kubectl -n tenant-a-prod get pods`. `Pending` →
   describe it.
1. `FailedScheduling` with “node(s) had untolerated taint” → the pod’s
   `nodeSelector`/tolerations don’t match the node group’s label/taint. This is
   Gotcha G-3 — the naming-map row is inconsistent.
1. `Pending` with “exceeded quota” → the `ResourceQuota` is too small or the pod
   omits `requests`. Raise quota (platform repo) or add requests.
1. `CreateContainerConfigError` referencing a service account → the Pod Identity
   SA name in the manifest doesn’t match `pod-identity.tf`.

-----

## 7. Per-scenario GitLab procedures

Each scenario from `PATTERNS.md`, expressed as concrete GitLab actions.

### Scenario 1 — Onboard tenant-c

1. **infra-eks** (MR → apply): add `tenant_c` node group + Pod Identity. Merge,
   then run the manual `tf:apply`.
1. **platform-addons** (MR → auto-reconcile): add `tenancy/tenant-c.yaml`,
   `tenancy/rbac-tenant-c.yaml`, `network/cnp-tenant-c.yaml`,
   `flux/tenants/tenant-c.yaml`; add `tenant-c/apps` to BOTH `ci_access` and
   `user_access` in `.gitlab/agents/eks-shared/config.yaml`. Merge.
1. **GitLab admin:** create group `tenant-c` + project `apps`; create a
   `read_repository` deploy token → make the `gitlab-tenant-c-token` secret in
   `flux-system`; map the `gitlab:tenant-c` group membership.
1. **Verify:** `flux get kustomizations -A` shows `tenant-c-apps` Ready; push a
   test commit to `tenant-c/apps` and watch `verify:rollout`.

**Info to collect for onboarding:** the new tenant’s group path, the deploy-token
username, the subnet CIDRs assigned in `vpc.tf`, and confirmation the node-group
label/taint matches the naming map.

### Scenario 2 — Traffic spike / autoscaling

No GitLab change. Confirm HPA + node-group autoscaling: `kubectl -n tenant-a-prod get hpa`, `kubectl get nodes -l tenant=tenant-a`. If pods pend at the quota
ceiling, that’s the intended signal — raise the quota via a platform-addons MR
(tenant cannot do this themselves; see G-18).

### Scenario 3 — Compromised pod containment

Mostly cluster-side. GitLab’s role: audit. Use the project’s **Operate →
Kubernetes** view (powered by agentk `user_access`) to inspect tenant-a-prod only.
Rotate the tenant’s deploy token (Settings → Repository → Deploy tokens → revoke

- recreate → update the `flux-system` secret).

### Scenario 4 — Tenant attempts privilege escalation

Verifiable in GitLab + cluster: a tenant MR adding a `ClusterRoleBinding` will
merge in their repo but Flux’s apply (under `tenant-a-deployer` SA) is denied —
visible as the `tenant-a-apps` Kustomization going `Not Ready` with a forbidden
error. `flux get kustomization tenant-a-apps` then
`kubectl -n flux-system describe kustomization tenant-a-apps` shows the RBAC
denial. This is expected and is the control working.

**Gotcha G-18 (tenant can’t self-serve quota — by design):** tenants will ask why
their MR to edit `ResourceQuota` “does nothing”. The `tenant-developer` Role omits
`resourcequotas`, and those manifests live in `platform-addons` which they can’t
write to. Route quota changes through a platform MR. Document this so it’s not
mistaken for a bug.

-----

## 8. Gotcha quick-index

Fast lookup by symptom. Full detail in the section noted.

|#   |Symptom                                    |Root cause                               |Section  |
|----|-------------------------------------------|-----------------------------------------|---------|
|G-1 |Agent stops matching a project after rename|config uses full path, not id            |1.2      |
|G-2 |Agent config “ignored”, no error           |wrong file path/name                     |2        |
|G-3 |Flux applied but pod won’t schedule        |naming-map inconsistency (label/taint/SA)|0.4 / 6.2|
|G-4 |agentk CrashLoop / Unauthenticated         |bad token or kasAddress                  |3.3      |
|G-5 |agentk dial timeout                        |egress to KAS blocked                    |3.3      |
|G-6 |GitRepository 403 / auth required          |deploy-token username wrong              |4.3      |
|G-7 |Git handshake error                        |https URL + ssh secret mismatch          |4.3      |
|G-8 |Changes take minutes                       |poll fallback (agentk down)              |4.3      |
|G-9 |Job can’t see a variable                   |Protected var on unprotected branch      |5.1      |
|G-10|Secret leaks into logs                     |value failed masking rules               |5.1      |
|G-11|Job stuck, no runner                       |no runner matches tags                   |5.2      |
|G-12|`context not found` in CI                  |project missing from `ci_access`         |5.3      |
|G-13|Plan blocked on lock                       |stale state lock                         |6.1      |
|G-14|Apply “skipped”                            |manual gate not clicked                  |6.1      |
|G-15|Kaniko 401 on push                         |registry creds/feature disabled          |6.2      |
|G-16|Push rejected / pipeline loop              |GITOPS_TOKEN scope / missing `[skip ci]` |6.2      |
|G-17|`verify:rollout` times out                 |scheduling/quota/SA chain                |6.2      |
|G-18|Tenant quota MR “does nothing”             |by design — platform-owned               |7        |

-----

## 9. Diagnostic command cheat-sheet

Copy-paste block for triage. Run top-to-bottom; the first failing layer is your
culprit.

```bash
### --- GitLab side ---
glab api version                                    # instance version
glab api "projects/platform%2Fplatform-addons"      # project reachable?
glab ci status                                      # latest pipeline state (in repo dir)
glab ci view                                        # interactive pipeline/job logs

### --- Agent layer ---
kubectl -n gitlab get pods
kubectl -n gitlab logs deploy/eks-shared-gitlab-agent --tail=50
#   look for: "Connected", absence of "Unauthenticated"/"dial tcp ... timeout"

### --- Flux layer ---
flux check                                          # controllers healthy
flux get sources git -A                             # all GitRepository Ready?
flux get kustomizations -A                          # all Kustomization Ready?
flux events --for Kustomization/tenant-a-apps       # what failed, when
flux reconcile kustomization tenant-a-apps --with-source   # force a sync

### --- Workload layer ---
kubectl get nodes -l tenant=tenant-a --show-labels  # node group present + labelled
kubectl -n tenant-a-prod get pods
kubectl -n tenant-a-prod describe pod <name>        # FailedScheduling / quota / SA errors
kubectl -n tenant-a-prod get events --sort-by=.lastTimestamp | tail -20

### --- Isolation spot-checks ---
kubectl -n tenant-a-prod get resourcequota,limitrange,role,rolebinding
kubectl get ciliumnetworkpolicy -A
kubectl auth can-i create clusterrolebinding \
  --as=system:serviceaccount:tenant-a-prod:tenant-a-deployer   # expect: no
```

-----

## 10. Escalation template — info to attach to any ticket

When a pipeline or sync issue can’t be resolved locally, collect ALL of the
following before escalating. Missing items are the #1 cause of slow resolution.

```
== Environment ==
GitLab host + version:
Tier (Free/Premium/Ultimate):
gitlab.com or self-managed:
Agent name + project path:
EKS cluster name + region + k8s version:

== What failed ==
Repo + branch:
Pipeline URL + job name:
Stage that failed (build/update/verify/tf-*):
Exact error text (paste, don't paraphrase):
First time it failed vs last time it worked:
Recent changes (MRs merged, tokens rotated, version bumps):

== Layer evidence (from section 9) ==
glab ci status output:
agentk pod status + last 50 log lines:
flux get sources + kustomizations output:
kubectl describe of the stuck pod (if rollout failed):
relevant events (sorted):

== Identity / secrets sanity (values redacted, confirm scope only) ==
Agent token rotated recently? (y/n):
Deploy token scope + username correct? (y/n):
GITOPS_TOKEN scope + Protected/Masked flags:
ci_access lists the affected project? (y/n):

== Naming-map check (section 0.4) ==
Confirm these match exactly for the affected tenant:
  node label / pod nodeSelector:
  node taint / pod toleration:
  pod IAM SA / serviceAccountName:
  flux targetNamespace / actual namespace:
```

-----

## 11. Maintenance & rotation notes

- **Token expiry** is the silent killer. PATs, deploy tokens, and project access
  tokens all expire. Calendar a rotation; a dead deploy token makes Flux go
  `Not Ready` with no obvious “expired” wording (it reads as auth failure, G-6).
- **GitLab upgrades:** keep agentk’s image within one minor of the instance.
  After a GitLab upgrade, bump the agent chart and redeploy.
- **EKS version upgrades** are an `infra-eks` concern, not GitLab — but the
  `bitnami/kubectl` image tag in `verify:rollout` should track the cluster
  version to avoid client-skew warnings.
- **Audit trail:** every change flows through MRs + Flux, so `git log` on the
  platform and tenant repos plus Flux events is your full deployment history —
  no separate CD-tool audit log to reconcile.