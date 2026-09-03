# EKS with Terraform — everything from local files (no chart/manifest downloads at apply time)

This tutorial provisions the full stack on AWS with Terraform: two EKS
clusters (Keycloak on *platform*, Kafka + Kafka UI on *data*), RDS for
Keycloak, ACM certificates, Route 53 records and ALBs. The important
difference from a typical setup: **Terraform never fetches a Helm chart or a
manifest from the internet.** Every chart, CRD, operator manifest and IAM
policy is a file in this folder. The *only* network pulls at `apply` time are
container images, done by the EKS nodes.

```
terraform/eks/
├── charts/                        vendored Helm charts (directories, not URLs)
│   ├── aws-load-balancer-controller/    1.11.0 (controller v2.11.0)
│   ├── strimzi-kafka-operator/          0.45.0
│   └── kafka-ui/                        1.6.5  (app v1.5.0)
├── manifests/keycloak-operator/   Keycloak Operator 26.3.0 CRDs + Deployment
├── iam/                           LB-controller IAM policy JSON
├── modules/eks-cluster/           reusable EKS cluster (control plane, nodes, IRSA, EBS CSI, LBC role)
├── scripts/                       vendor.sh (refresh files), mirror-providers.sh, package.sh
└── *.tf                           root: VPC, 2 clusters, DNS/certs, Keycloak, Kafka, Kafka UI
```

---

## Part 1 – Step-by-step

### Step 1: Prerequisites
* Terraform ≥ 1.6, AWS CLI v2 (used by the Kubernetes providers for `aws eks get-token`), an AWS account with admin rights.
* An existing **public Route 53 hosted zone** (e.g. `example.com`).
* (Optional, for a fully offline `init`) run `scripts/mirror-providers.sh` once while online and copy `.terraformrc.example` to `~/.terraformrc`. Provider binaries are the one thing Terraform itself must download; the mirror makes that a one-time step.

### Step 2: Configure
```bash
cd terraform/eks
cp terraform.tfvars.example terraform.tfvars   # edit: zone name, passwords, client secret, allowed CIDRs
```
Secrets can also be passed as `TF_VAR_keycloak_admin_password=…` environment variables.

### Step 3: Apply
```bash
terraform init          # offline if the provider mirror is configured
terraform plan
terraform apply         # ~25–35 minutes (EKS ×2, RDS, Kafka rollout)
```
Outputs show `https://kafka-ui.<zone>`, `https://auth.<zone>` and the `aws eks update-kubeconfig` commands.

### Step 4: Verify
```bash
curl https://auth.example.com/realms/kafka/.well-known/openid-configuration | jq .issuer
# -> "https://auth.example.com/realms/kafka"   (must equal output issuer_uri)
open https://kafka-ui.example.com               # login alice / alice123
```

### Step 5: Produce messages
Kafka is internal-only. Run the client inside the data cluster:
```bash
$(terraform output -raw kubeconfig_commands | jq -r .data)
kubectl -n kafka run producer --rm -it --image=python:3.12-slim -- bash -c \
  "pip -q install confluent-kafka && python - <<'PY'
from confluent_kafka import Producer; import json
p=Producer({'bootstrap.servers':'my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092'})
[p.produce('orders', key=f'k{i}', value=json.dumps({'i':i}).encode()) for i in range(10)]; p.flush(); print('sent')
PY"
```

### Step 6: Destroy
```bash
terraform destroy
```
Kafka PVCs use `Retain`; delete leftover EBS volumes manually if you want a clean account.

---

## Part 2 – Background: why "local files only"?

* **Reproducibility** – a chart repository can change or disappear; a file in git cannot.
* **Air-gapped / restricted networks** – many corporate CI runners can reach AWS APIs and a private container registry, but not GitHub Pages or quay.io Helm repos.
* **Auditability** – security review sees exactly what will be applied.
* **Speed** – no repo index refreshes.

How each component is loaded:

| Component | Normal way | Here |
|-----------|-----------|------|
| AWS Load Balancer Controller | `helm repo add eks https://aws.github.io/eks-charts` | `helm_release.chart = "./charts/aws-load-balancer-controller"` (directory) |
| Strimzi operator | `oci://quay.io/strimzi-helm/…` | `./charts/strimzi-kafka-operator` |
| Kafka UI | `https://ui.charts.kafbat.io` | `./charts/kafka-ui` |
| Keycloak Operator | `kubectl apply -f https://raw.githubusercontent.com/…` | `kubectl_file_documents` reading `./manifests/keycloak-operator/*.yml` |
| LBC IAM policy | `curl` from GitHub | `file("./iam/aws-load-balancer-controller-policy.json")` |
| EKS cluster | `terraform-aws-modules/eks` from the registry | local module `./modules/eks-cluster` (raw `aws_*` resources) |
| VPC | `terraform-aws-modules/vpc` | raw `aws_vpc`, `aws_subnet`, … in `network.tf` |
| Keycloak CRs, Kafka CRs, topics | YAML files | `yamlencode()` in HCL — values come from variables/locals, so no drift between Keycloak issuer and Kafka UI issuer |

Images still come from registries (`quay.io/keycloak`, `ghcr.io/kafbat`, `quay.io/strimzi`, ECR for the LB controller). To make those private too, mirror them to ECR and override `var.images` plus the `image` values of the vendored charts.

---

## Part 3 – Settings explained (file by file)

### `versions.tf` / `providers.tf`
Six providers, all pinned. Each cluster gets its own aliased `kubernetes`, `helm` and `kubectl` provider using the EKS endpoint + CA from the module and `aws eks get-token` for auth. Resources choose a cluster with `provider = kubernetes.platform` / `kubernetes.data`.

### `network.tf`
One VPC, 3 AZs, public subnets tagged `kubernetes.io/role/elb` (internet-facing ALBs), private subnets tagged `kubernetes.io/role/internal-elb` (internal ALBs) — the LB controller discovers subnets by these tags. Nodes live in private subnets; one NAT gateway gives them egress for image pulls and for Kafka UI to reach Keycloak's public ALB.

### `modules/eks-cluster`
| Resource | Why |
|----------|-----|
| `aws_eks_cluster` with `API_AND_CONFIG_MAP` auth and `bootstrap_cluster_creator_admin_permissions` | The identity running Terraform is cluster-admin without editing `aws-auth`. |
| `aws_eks_node_group` (AL2023) | Managed nodes, private subnets. |
| `aws_iam_openid_connect_provider` | Enables IRSA (pods assume IAM roles via service-account tokens). |
| `aws_eks_addon` `aws-ebs-csi-driver` + role | Kafka PVCs on gp3. |
| `aws_iam_role.lbc` + policy from the local JSON | The controller creates ALBs, target groups, security groups. |

### `dns-certs.tf`
One ACM certificate with `auth.<zone>` + `kafka-ui.<zone>` SANs, validated by Route 53 CNAMEs Terraform creates. The ALBs reference its ARN.

### `lb-controller.tf`
Installs the controller on both clusters from the local chart with `serviceAccount.create=false` (Terraform makes the SA with the IRSA annotation). Also a default `gp3` StorageClass on the data cluster.

### `keycloak.tf`
| Setting | Why |
|---------|-----|
| `aws_db_instance` (Postgres 16, gp3, encrypted, 7-day backups) + SG allowing 5432 from the platform cluster SG | Keycloak needs a durable DB. |
| CRDs applied with `server_side_apply = true` | The Keycloak CRDs exceed the 256 KB annotation limit of client-side apply. |
| Operator manifests with `override_namespace = "keycloak"` | Upstream files omit `metadata.namespace`. |
| `Keycloak` CR: `hostname.hostname = https://auth.<zone>`, `strict = true`, `http.httpEnabled`, `proxy.headers = xforwarded`, `bootstrapAdmin.user.secret` | Issuer = this URL; TLS terminates at the ALB; admin from a Secret. |
| `wait_for status.conditions[0].status == True` | Terraform blocks until the operator reports Ready before creating the ingress/realm. |
| Ingress with `wait_for_load_balancer` → `aws_route53_record` CNAME to the ALB hostname | No ExternalDNS needed; Terraform owns the record. |
| `KeycloakRealmImport` with `placeholders.KAFKA_UI_CLIENT_SECRET` | The operator substitutes the client secret from a Kubernetes Secret, so the realm YAML never contains it. Users come from `var.test_users`. |
| `time_sleep` 90 s | Lets the new DNS record propagate before Kafka UI validates the issuer. |

### `kafka.tf`
Strimzi from the local chart; 3 controllers + 3 brokers (100 Gi gp3 each, zone anti-affinity); internal `plain` and `tls` listeners; RF 3 / min ISR 2; topics from `var.topics`. `wait_for status.conditions[0].type == Ready` with a 25-minute timeout.

### `kafka-ui.tf`
Local chart, image tag from `var.images`, client secret via `existingSecret`, OIDC `issuer-uri = local.issuer_uri`, RBAC roles, `forward-headers-strategy = framework`, ALB ingress with `inbound-cidrs` restriction and sticky sessions (2 replicas). A `kubernetes_ingress_v1` data source reads the ALB hostname for the Route 53 CNAME.

---

## Part 4 – Options, pros and cons

| Decision | Chosen | Alternative | Trade-off |
|----------|--------|-------------|-----------|
| Charts as directories in git | yes | `.tgz` files, or a private ChartMuseum/OCI registry | Directories diff nicely in code review; `.tgz` is smaller; a private registry scales across many repos but is one more service. |
| Operator manifests via `kubectl` provider | yes | `kubernetes_manifest` | `kubernetes_manifest` needs CRDs at plan time → two applies; `kubectl_manifest` handles CRD-then-CR in one. |
| No registry modules (raw resources) | yes | `terraform-aws-modules/eks` + `vpc` | Raw resources = zero downloads and full transparency, but more code to maintain; the community modules cover far more edge cases. |
| DNS records by Terraform | yes | ExternalDNS | Fewer controllers and IAM roles; but records only update on `apply`. |
| Secrets as variables → k8s Secrets | yes | External Secrets Operator + Secrets Manager | Simpler and offline; ESO gives rotation without re-apply. |
| Provider mirror | optional | normal registry access | Mirror makes `init` offline; must be refreshed when bumping versions. |
| Two clusters | yes | one cluster, two namespaces | Isolation of identity from data; single cluster is cheaper (`platform_nodes` can be shrunk to 1 node for labs). |

### Best practices
* Bump versions only through `scripts/vendor.sh` and record them in `charts/VERSIONS.md`.
* Keep `terraform.tfvars` and `providers-mirror/` out of git (already in `.gitignore`).
* Use the S3 backend (commented in `versions.tf`) for shared state.
* Mirror images to ECR for a truly closed network and set `var.images` + chart `image.*` values.
* `kafka_ui_alb_scheme = "internal"` + VPN for production.

---

## Part 5 – Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `helm_release` error "chart not found" | Relative path wrong / chart dir missing | `ls terraform/eks/charts/<name>/Chart.yaml`; re-run `scripts/vendor.sh`. |
| CRD apply fails with "metadata.annotations: Too long" | Client-side apply on huge CRDs | Ensure `server_side_apply = true` (already set). |
| `kubectl_manifest.keycloak` times out | DB unreachable / image pull | `kubectl -n keycloak get keycloak keycloak -o yaml`; check RDS SG and pod logs. |
| Kafka UI Helm release times out | Issuer not resolvable yet or cert not ready | Wait for DNS; `kubectl -n kafka logs deploy/kafka-ui`; re-run `apply` (idempotent). |
| ACM validation stuck | Zone is not the authoritative one | Confirm `route53_zone_name` NS records match the registrar. |
| ALB not created | LB controller lacks subnet tags/IAM | Check tags in `network.tf`; `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. |
| `terraform init` tries the network | No mirror config | Copy `.terraformrc.example` → `~/.terraformrc` with the absolute mirror path. |
