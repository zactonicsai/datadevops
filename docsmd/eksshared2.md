# Patterns & Scenarios

The same building blocks from the config files, reorganized two ways the request
asked for: **grouped by Kubernetes pattern**, then **grouped by multi-tenancy
concern**, then four **worked scenarios**.

-----

## Part A — Grouped by Kubernetes pattern

### Pattern 1: Dedicated Nodes (taints + tolerations + labels)

**Files:** `eks.tf` node groups, `tenant-a-apps/application.yaml` pod spec.

Each tenant gets a managed node group with a `tenant=<name>:NoSchedule` taint and
a matching label. Tenant pods carry the toleration + `nodeSelector`. Result: no
two tenants share a host kernel, which closes the gap that namespaces alone
leave open. Karpenter `NodePool` objects can replace static groups when you want
the pinning to drive autoscaling instead.

### Pattern 2: GitOps with Flux + agentk (declarative, pull-based delivery)

**Files:** `platform-addons/flux/platform-sync.yaml`,
`platform-addons/flux/tenants/tenant-a.yaml`,
`platform-addons/.gitlab/agents/eks-shared/config.yaml`,
`.gitlab-ci.yml` `update:manifest` + `verify:rollout` jobs.

The cluster’s desired state lives in Git. CI pushes image tags; Flux reconciles
and reverts drift (`prune: true`, periodic re-apply). agentk connects the cluster
to GitLab over an outbound gRPC tunnel — no public API endpoint — auto-detects
Flux `GitRepository` objects that reference GitLab projects and triggers
immediate reconciliation on push. The Flux root in `platform-sync.yaml` (with
`dependsOn` ordering: tenancy → network → tenant-sources) replaces the Argo CD
app-of-apps: a fresh cluster is one `terraform apply` + Flux/agentk install + one
`kubectl apply` of the root away from fully configured.

### Pattern 3: Sidecar-free network policy (CNI-enforced micro-segmentation)

**Files:** `network/cilium-default-deny.yaml`, `network/cnp-tenant-a.yaml`.

Default-deny clusterwide, then additive allow-lists per tenant selected by the
`tenant=` label. No service mesh required for L3/L4 isolation; add Cilium L7 or a
mesh only if you need mTLS / request-level policy.

### Pattern 4: Quota & LimitRange (capacity fairness)

**Files:** `tenancy/tenant-a.yaml`.

`ResourceQuota` caps a tenant’s total footprint; `LimitRange` supplies per-container
defaults so unbounded pods can’t monopolize a node. Owned by the platform repo.

### Pattern 5: Workload Identity (Pod Identity, least-privilege cloud access)

**Files:** `pod-identity.tf`.

Each namespace+service-account pair maps to one narrowly scoped IAM role. No shared
role, no shared trust policy — cross-tenant credential access is structurally
impossible. Replaces the older IRSA/OIDC approach.

### Pattern 6: Namespace-as-tenant-boundary + Pod Security Standards

**Files:** `tenancy/tenant-a.yaml` namespace labels.

The namespace is the unit of tenancy; every isolation control selects on its
`tenant=` label. `pod-security.kubernetes.io/enforce: restricted` blocks
privileged pods, host mounts, and root containers at admission.

-----

## Part B — Grouped by multi-tenancy concern

|Concern                |Question it answers                         |Controls in this repo                                                                                                                  |
|-----------------------|--------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
|**Compute isolation**  |Can tenant A’s pod run on tenant B’s node?  |Dedicated node groups, taints/tolerations, nodeSelector (Pattern 1)                                                                    |
|**Network isolation**  |Can tenant A reach tenant B’s pods/services?|Cilium default-deny + per-tenant CNP (Pattern 3)                                                                                       |
|**Identity isolation** |Can tenant A use tenant B’s cloud/k8s creds?|Pod Identity scoping + agentk impersonation + RBAC (Patterns 5, 2)                                                                     |
|**Resource isolation** |Can tenant A starve the cluster?            |ResourceQuota + LimitRange (Pattern 4)                                                                                                 |
|**Delivery isolation** |Can tenant A deploy into tenant B’s space?  |Separate GitLab repos + platform-owned Flux source (`targetNamespace` + `serviceAccountName`) + agentk impersonation + RBAC (Pattern 2)|
|**Admission isolation**|Can tenant A run a privileged/root pod?     |Pod Security Standards `restricted`; optionally Kyverno/OPA (Pattern 6)                                                                |

**Optional hardening (add when tenants are untrusted):**

- Kyverno or OPA Gatekeeper policies: require quota per namespace, forbid
  `cluster-admin` binds, restrict registries to your ECR.
- Runtime sandboxing (gVisor / Kata) or one cluster per tenant for hostile
  multi-tenancy — namespaces don’t isolate the Linux kernel.
- Separate prod and non-prod tenants onto different clusters.

-----

## Part C — Worked scenarios

### Scenario 1: Onboard a new tenant (“tenant-c”)

1. **infra-eks:** add a `tenant_c` node group (copy `tenant_b`, new subnets +
   `tenant=tenant-c` taint/label) and a `tenant_c_pod_identity` block. `apply`.
1. **platform-addons:** add `tenancy/tenant-c.yaml` (namespace + quota +
   limitrange), `tenancy/rbac-tenant-c.yaml`, `network/cnp-tenant-c.yaml`, and
   `flux/tenants/tenant-c.yaml` (the platform-owned Flux source pinned to
   tenant-c-prod). Add `tenant-c/apps` to `ci_access`/`user_access` in the agent
   `config.yaml`. Commit → Flux creates everything.
1. **GitLab:** create `tenant-c/apps` repo; map `gitlab:tenant-c` group; add the
   `gitlab-tenant-c-token` deploy-token secret. Done — isolation is enforced at
   compute, network, identity, resource, and delivery layers without touching any
   other tenant.

### Scenario 2: Tenant A’s traffic spikes (autoscaling under a quota)

- HPA scales tenant-a Deployments up to the `ResourceQuota` ceiling.
- The `tenant_a` node group’s cluster-autoscaler (or Karpenter) adds nodes — only
  in tenant-a subnets, only tenant-a-tainted. Tenant B is unaffected: different
  node group, different quota, different subnets.
- If tenant-a hits its quota, *its* pods pend (a billing/upsell signal), rather
  than tenant-a stealing tenant-b capacity.

### Scenario 3: Compromised pod in tenant-a (blast-radius containment)

- **Network:** default-deny + tenant-a CNP means the pod can only talk to other
  tenant-a pods + permitted egress; it cannot scan or reach tenant-b. CoreDNS
  enumeration of other services is blunted.
- **Identity:** Pod Identity grants only tenant-a’s scoped role, so stolen creds
  read only tenant-a’s S3 bucket. There is no shared deploy credential to steal —
  Flux pulls with a read-only, per-tenant deploy token held in-cluster.
- **Compute:** even with a container escape, the host is a tenant-a-only node;
  no tenant-b workload shares that kernel.
- **Admission:** PSS `restricted` blocked the privileged/hostPath tricks that
  make escapes easy in the first place.

### Scenario 4: Tenant A tries to grab cluster-wide power (defence in depth)

- Tenant pushes a `ClusterRoleBinding` to their repo → Flux applies their source
  under the `tenant-a-deployer` service account, which has no cluster-scoped
  rights, so the API server rejects it.
- Tenant edits a manifest to set `namespace: tenant-b-prod` → Flux’s
  `targetNamespace: tenant-a-prod` overrides it, and the tenant RBAC wouldn’t
  permit tenant-b-prod anyway.
- Tenant raises their own `ResourceQuota` → the `tenant-developer` Role omits
  `resourcequotas`, so the apply is denied; quotas live in the platform repo they
  can’t write to.
- Tenant adds a permissive `CiliumNetworkPolicy` → same Role omits
  `ciliumnetworkpolicies`; network policy is platform-owned.
- Tenant’s CI tries `kubectl` against another namespace through the agent → the
  agent impersonates `gitlab:tenant-a`, bound only to tenant-a-prod, so the call
  fails closed.

Each attempt fails at a different control — that’s the point of layering.