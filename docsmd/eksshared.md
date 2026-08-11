# Multi-Tenant EKS + GitLab Reference Architecture

A production reference for one shared EKS cluster, multiple GitLab repositories
(infra / platform / per-tenant apps), and network isolation enforced at both the
**node-group** and **pod** layers.

Versions pinned to current stable (mid-2026):

|Component                         |Version                           |
|----------------------------------|----------------------------------|
|EKS / Kubernetes                  |`1.33` (module supports 1.30–1.34)|
|`terraform-aws-modules/eks`       |`~> 21.0`                         |
|`terraform-aws-modules/vpc`       |`~> 5.13`                         |
|Cilium CNI (network policy engine)|`1.17.x`                          |
|Argo CD                           |`3.x`                             |
|Karpenter (optional)              |`1.x`                             |

-----

## 1. Repository topology (the “different repos” model)

GitOps best practice is to **separate what provisions the cluster from what runs
on it**, and to give each tenant its own app repo so blast radius and RBAC follow
repo boundaries.

```
gitlab.example.com/
├── platform/
│   ├── infra-eks            ← Terraform: VPC, EKS, node groups, IRSA/Pod Identity
│   │                          (cluster admins only; runs terraform plan/apply)
│   └── platform-addons      ← GitOps root: Argo CD, Cilium, ingress, quotas,
│                              namespaces, NetworkPolicies, tenant onboarding
│
├── tenant-a/
│   └── apps                 ← Argo CD Application(s); only deploys into ns tenant-a-*
├── tenant-b/
│   └── apps                 ← only deploys into ns tenant-b-*
└── shared/
    └── helm-charts          ← internal chart library (versioned, reused by tenants)
```

**Why three layers, not one:**

- `infra-eks` changes are rare, high-risk, and need cloud credentials. Keep them
  behind protected branches + manual `apply` jobs.
- `platform-addons` is the **app-of-apps** root. It owns namespaces, quotas, and
  network policy — the things tenants must *not* control.
- Tenant repos can only touch their own namespaces. Argo CD `AppProject` +
  GitLab repo permissions enforce this twice (in-cluster and in-VCS).

Mapping to the request: *common cluster* = `infra-eks`; *different repos for node
groups and apps* = `infra-eks` defines node groups, tenant repos define apps;
*isolated network by node groups and pods* = node-group taints/labels +
Cilium `CiliumNetworkPolicy`.

-----

## 2. The four isolation layers

Multi-tenancy on EKS is layered. Each layer below is necessary; none alone is
sufficient.

|Layer         |Mechanism                                                                       |Stops                                                 |
|--------------|--------------------------------------------------------------------------------|------------------------------------------------------|
|**Identity**  |IAM + EKS Pod Identity, RBAC, Argo CD `AppProject`                              |Tenant A reading Tenant B’s AWS secrets / k8s objects |
|**Scheduling**|Node-group labels + taints + `nodeSelector`/tolerations (or Karpenter NodePools)|Tenant pods landing on the wrong nodes                |
|**Network**   |Cilium default-deny + per-namespace `CiliumNetworkPolicy`                       |Pod-to-pod traffic across tenants, CoreDNS enumeration|
|**Resource**  |`ResourceQuota` + `LimitRange`                                                  |One tenant starving the cluster (noisy neighbor)      |


> **Soft vs hard multi-tenancy.** Everything here is *soft* multi-tenancy
> (shared cluster, trusted-ish tenants — internal teams or a SaaS where you
> control all workloads). If tenants are mutually hostile / run untrusted code,
> namespaces alone do **not** isolate the kernel — add sandboxing (gVisor /
> Kata / Firecracker, or EKS Auto Mode managed nodes per tenant) or go
> cluster-per-tenant.

-----

## 3. Files in this repo

```
infra-eks/
  versions.tf          provider + module version pins
  vpc.tf               VPC with tagged subnets, isolated per-tenant subnet groups
  eks.tf               shared cluster + per-tenant managed node groups
  pod-identity.tf      Pod Identity associations (replaces IRSA)
  variables.tf
  outputs.tf

platform-addons/
  root-app.yaml        app-of-apps that bootstraps everything below
  argocd/
    appproject-tenant-a.yaml   AppProject scoping tenant-a
  tenancy/
    namespace-tenant-a.yaml
    resourcequota-tenant-a.yaml
    limitrange-tenant-a.yaml
  network/
    cilium-default-deny.yaml
    cnp-tenant-a.yaml          CiliumNetworkPolicy: same-tenant + DNS + ingress only

tenant-a-apps/
  application.yaml     Argo CD Application (tenant-scoped)

.gitlab-ci.yml         pipelines: infra plan/apply + tenant image build → GitOps bump
```

See `PATTERNS.md` for the same content reorganized **by Kubernetes pattern** and
**by multi-tenancy concern**, plus the four worked scenarios.