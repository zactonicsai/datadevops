# Kafka + Kafka UI + Keycloak on a local `kind` cluster with Terraform

This tutorial builds the whole stack on your laptop, but on **Kubernetes**
instead of Docker Compose, using **Terraform** so that a single `terraform apply`
creates the cluster and everything inside it. It is the local rehearsal of the
EKS layout (same Strimzi, same Kafka UI chart, same Keycloak settings).

```
terraform apply
   │
   ├─ kind cluster "kafka-dev"  (1 node, host ports 80 / 29092 / 29093 mapped)
   │     ├─ ingress-nginx            http://*.localtest.me  → services
   │     ├─ CoreDNS rewrite          keycloak.localtest.me  → ingress (from inside pods)
   │     ├─ keycloak  (ns keycloak)  realm "kafka" imported from a ConfigMap
   │     ├─ strimzi operator + Kafka "my-cluster" (ns kafka)  + KafkaTopic CRs
   │     └─ kafka-ui  (Helm)         OIDC login against Keycloak, RBAC
   └─ outputs: URLs, bootstrap address, kubeconfig
```

Everything lives in the `terraform/` folder.

---

## Part 1 – Step-by-step

### Step 1: Install the tools
| Tool | Check |
|------|-------|
| Docker Desktop / Docker Engine (running) | `docker ps` |
| Terraform ≥ 1.5 | `terraform version` |
| kubectl (optional, for poking around) | `kubectl version --client` |

You do **not** need the `kind` CLI — the Terraform kind provider talks to
Docker directly.

### Step 2: Free port 80 (or pick another)
The cluster maps host port **80** to the ingress. If something already uses
it, override: `terraform apply -var http_host_port=8000` — URLs then become
`http://kafka-ui.localtest.me:8000`. (On Linux, binding port 80 from Docker
usually works without root because Docker itself runs as root.)

### Step 3: Apply
```bash
cd terraform
terraform init
terraform apply          # ~5–8 min on first run (image pulls)
```
Terraform prints the URLs at the end:
```
kafka_ui_url    = "http://kafka-ui.localtest.me"
keycloak_url    = "http://keycloak.localtest.me  (admin / admin)"
kafka_bootstrap = "localhost:29092"
kubeconfig      = "export KUBECONFIG=/…/terraform/kubeconfig"
```
`*.localtest.me` is a public DNS name that always resolves to `127.0.0.1`,
so **no hosts-file editing** is required this time.

### Step 4: Log in
Open http://kafka-ui.localtest.me → Keycloak login → **alice / alice123**
(admin) or **bob / bob123** (viewer).

### Step 5: Send test messages
```bash
cd ../client
python producer.py -b localhost:29092
python consumer.py -b localhost:29092 -t orders
```

### Step 6: Look inside (optional)
```bash
export KUBECONFIG=$(pwd)/../terraform/kubeconfig
kubectl get pods -A
kubectl get kafka,kafkatopic -n kafka
```

### Step 7: Tear down
```bash
terraform destroy      # deletes the kind cluster (and all data) in ~30 s
```

---

## Part 2 – Background

* **kind** ("Kubernetes in Docker") runs a whole Kubernetes node as one Docker
  container. It is the standard way to test Kubernetes manifests locally.
* **Terraform** describes infrastructure as code. Here it uses four
  *providers*: `kind` (creates the cluster), `helm` (installs charts),
  `kubernetes` (plain resources like Deployments, Ingresses, ConfigMaps) and
  `kubectl` (applies custom resources such as Strimzi's `Kafka` whose CRDs do
  not exist until the operator is installed — the plain `kubernetes` provider
  cannot plan those).
* **ingress-nginx** is the in-cluster reverse proxy; kind exposes it on the
  host through the port mapping, exactly like an ALB does on EKS.

---

## Part 3 – File-by-file: what each setting does

### `kind.tf`
| Setting | Why |
|---------|-----|
| `extra_port_mappings 80 → var.http_host_port` | Your browser reaches ingress-nginx on `localhost`. |
| `30092 → 29092`, `30093 → 29093` | Kafka's NodePort listener (bootstrap + broker 0) reaches your laptop, so the Python client can connect. |
| `node-labels: ingress-ready=true` | ingress-nginx's `nodeSelector` targets this node so its `hostPort` binds where the mapping is. |
| `kubeconfig_path = ./kubeconfig` | All other providers read this file; it is git-ignored. |

### `ingress.tf`
| Setting | Why |
|---------|-----|
| `controller.hostPort.enabled` | Binds 80/443 directly on the node container → matches the kind port mapping. |
| `ingressClassResource.default = true` | Ingresses without a class still get served. |
| **CoreDNS `rewrite`** | The key trick. From inside a pod, `keycloak.localtest.me` would resolve to `127.0.0.1` (the pod's own loopback). The rewrite sends it to the ingress controller Service instead, so Kafka UI and your browser use the **same** issuer URL — the OIDC issuer check passes. |
| `kubernetes_config_map_v1_data` with `force = true` | Patches kind's existing CoreDNS ConfigMap instead of owning it. |

### `keycloak.tf`
| Setting | Why |
|---------|-----|
| `args = ["start-dev", "--import-realm"]` | Dev mode (H2 in-memory DB) + load the realm from `/opt/keycloak/data/import`. |
| ConfigMap from `files/realm-kafka.json.tftpl` | `templatefile()` injects the client secret and the Kafka UI redirect URL so nothing is hard-coded twice. |
| `KC_HOSTNAME = http://keycloak.localtest.me` | Becomes the token `iss`; must equal Kafka UI's `issuer-uri`. |
| `KC_PROXY_HEADERS = xforwarded`, `KC_HTTP_ENABLED = true` | Keycloak is behind ingress-nginx over HTTP. |
| Readiness probe `/health/ready:9000` + `wait_for_rollout` | Terraform waits until Keycloak is actually up before installing Kafka UI (which validates the issuer at boot). |
| Ingress annotation `proxy-buffer-size: 128k` | Keycloak responses carry large headers; nginx's default 4k buffer causes 502s. |

### `kafka.tf`
| Setting | Why |
|---------|-----|
| Strimzi via `oci://quay.io/strimzi-helm` | Operator installs CRDs and manages the cluster. |
| `KafkaNodePool` with `roles: [controller, broker]`, 1 replica, 5 Gi PVC | Smallest KRaft cluster; kind's default `standard` StorageClass provides the volume. `deleteClaim: true` cleans up on destroy. |
| listener `plain` 9092 internal | Used by Kafka UI. |
| listener `external` type `nodeport` with `advertisedHost: localhost`, `advertisedPort: 29093` | Kafka tells clients "connect to broker 0 at localhost:29093", which kind maps back into the cluster. Without `advertisedHost` clients would be told the node's Docker-internal IP. |
| all replication factors = 1 | One broker. |
| `kubectl_manifest` + `depends_on` | Guarantees CRDs exist before the CRs are applied. |
| `for_each = var.topics` | Topics are a Terraform variable; add one by editing `variables.tf` (or `-var`). |

### `kafka-ui.tf`
| Setting | Why |
|---------|-----|
| `existingSecret` | Client secret injected as `AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET` env var; never in the values YAML. |
| `yamlApplicationConfig.auth.oauth2.client.keycloak.*` | Same OIDC settings as the Compose/EKS docs; `issuer-uri` computed from the same locals as `KC_HOSTNAME`, so they cannot drift. |
| `rbac.roles` | `kafka-admin` → everything, `kafka-viewer` → read-only. |
| `server.forward-headers-strategy = framework` | Behind ingress, so redirect URIs are built from `X-Forwarded-*`. |
| `depends_on` Keycloak, its Ingress, the CoreDNS patch, the Kafka CR | Ordering: Kafka UI would crash-loop if the issuer isn't resolvable and ready. |

### `variables.tf` / `outputs.tf`
Change `http_host_port`, `kafka_host_port`, `domain`, secrets, topics or
pinned versions without touching the resource files. Outputs give you the
URLs, bootstrap address and kubeconfig export line.

---

## Part 4 – Options, pros and cons

| Decision | Chosen | Alternative | Trade-off |
|----------|--------|-------------|-----------|
| Local Kubernetes | **kind** | minikube, k3d, Docker Desktop K8s | kind is fastest to create/destroy and has a Terraform provider; k3d is similar (Terraform provider exists); minikube adds a VM layer. |
| DNS for `*.localtest.me` | public wildcard → 127.0.0.1 | hosts-file entries, `nip.io`/`sslip.io` | Zero setup, but requires internet for DNS. Offline? use hosts entries and `-var domain=…`. |
| In-cluster reachability of Keycloak | **CoreDNS rewrite** | `hostAliases` on the Kafka UI pod, or explicit `token-uri`/`jwk-set-uri` pointing at the Service | Rewrite is one place and works for every pod; hostAliases needs the ingress Service IP; explicit URIs skip issuer validation. |
| Custom resources | **`kubectl` provider** | `kubernetes_manifest` | `kubernetes_manifest` needs the CRD at *plan* time → fails on a fresh cluster in one apply; `kubectl_manifest` applies at *apply* time. |
| Keycloak | plain Deployment, dev mode | Keycloak Operator, Helm chart with PostgreSQL | Dev mode = no DB, fast, data lost on restart; use the operator manifests (as in the EKS doc) when you want parity. |
| Kafka exposure | NodePort listener via kind port mapping | Port-forward (`kubectl port-forward`) | NodePort survives Terraform runs and needs no extra terminal; port-forward only works for a single broker with tricks. |
| One `apply` for cluster + workloads | yes | Two Terraform roots (cluster, then workloads) | One root is convenient locally; splitting avoids provider-configuration-from-resource warnings and is the recommended pattern for real environments. |

### Best practices kept here
* Everything version-pinned in `var.versions`.
* Secrets are variables (mark them `sensitive`, pass via `terraform.tfvars` — git-ignored — or env `TF_VAR_kafka_ui_client_secret`).
* Hostnames/URLs derived once in `locals.tf`; Keycloak issuer and Kafka UI issuer can't diverge.
* Explicit `depends_on` for startup ordering (CRDs → CRs, Keycloak → Kafka UI).
* `terraform destroy` leaves nothing behind (cluster, PVCs, kubeconfig).

---

## Part 5 – Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `apply` fails creating the kind cluster: port already allocated | Port 80 / 29092 in use | `-var http_host_port=8000` or `-var kafka_host_port=39092`. |
| Kafka UI Helm release times out | Keycloak not reachable from the pod | `kubectl -n kafka logs deploy/kafka-ui`; check `kubectl -n kube-system get cm coredns -o yaml` contains the rewrite; `kubectl -n kafka exec deploy/kafka-ui -- curl -s http://keycloak.localtest.me/realms/kafka/.well-known/openid-configuration`. |
| Browser can't open `*.localtest.me` | Corporate DNS blocks it / offline | Add `127.0.0.1 kafka-ui.localtest.me keycloak.localtest.me` to hosts, or use `-var domain=…` with hosts entries. |
| Keycloak 502 through ingress | Header buffer | Confirm the `proxy-buffer-size` annotation is present. |
| Python client: connected to bootstrap but times out producing | Broker advertised the wrong address | Broker 0 must advertise `localhost:29093`; check `kubectl -n kafka get kafka my-cluster -o yaml` → `status.listeners`. |
| Provider warning "configuration derived from resource" on first plan | Providers read the kubeconfig the kind resource creates | Expected in the single-root layout; ignore, or split into two roots. |
| Re-applying after `terraform destroy` fails on kubeconfig | Stale `kubeconfig` file | `rm terraform/kubeconfig` and re-apply. |
