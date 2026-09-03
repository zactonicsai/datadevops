# Kafka + Kafka UI on Amazon EKS with an external Keycloak (also on EKS)

This tutorial moves the local Docker Compose setup to AWS. Kafka and Kafka UI
run in one EKS cluster; Keycloak runs **externally** — in its own EKS cluster
(a shared identity platform many apps use) — and Kafka UI talks to it over
HTTPS by a public DNS name. All manifests referenced here are in the `k8s/`
folder.

```
                 ┌──────────── EKS "platform" cluster ───────────┐
  Browser ──https──▶ ALB ──▶ Keycloak pods (operator) ──▶ RDS Postgres│
     │           └──────────────────────────────────────────────┘
     │  auth.example.com
     │
     │  kafka-ui.example.com          ┌──────────── EKS "data" cluster ──────────────┐
     └──────https──▶ ALB ──▶ Kafka UI pods ──9092──▶ Strimzi Kafka (3 brokers, 3 ctrl)│
                              │                                                       │
                              └── https ──▶ auth.example.com (token exchange, JWKS)  │
                                          └──────────────────────────────────────────┘
```

**Why does this fix the hostname problem from the local setup?** Both the
browser and the Kafka UI pod reach Keycloak by the *same* public name
(`auth.example.com`) over TLS, so `issuer-uri` matches the token issuer and no
hosts-file tricks are needed.

---

## Part 1 – Step-by-step

### Step 0: Prerequisites (both clusters)
| Tool / add-on | Purpose | Install hint |
|---------------|---------|--------------|
| `eksctl`, `kubectl`, `helm` | CLI tooling | brew / official installers |
| **AWS Load Balancer Controller** | Turns `Ingress` (class `alb`) into ALBs | `helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system` (needs IRSA) |
| **ExternalDNS** | Creates Route 53 records from ingress hostnames | `helm install external-dns …` with Route 53 IRSA policy |
| **ACM certificates** | TLS for `auth.example.com` and `kafka-ui.example.com` | ACM console, DNS-validated |
| **EBS CSI driver + `gp3` StorageClass** | Persistent volumes for Kafka (data cluster) | EKS add-on |
| **External Secrets Operator** | Sync AWS Secrets Manager → k8s Secrets | `helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace` |

Create the clusters (example):
```bash
eksctl create cluster --name platform --region us-east-1 --nodes 2 --node-type m6i.large
eksctl create cluster --name data     --region us-east-1 --nodes 3 --node-type m6i.xlarge
```

### Step 1: Keycloak on the *platform* cluster

1. **Database** – create an RDS PostgreSQL instance in the same VPC; allow port
   5432 from the EKS node/pod security group. Keycloak needs a real DB —
   never the dev H2 database in AWS.
2. **Operator** – install the Keycloak Operator (CRDs + deployment) into
   namespace `keycloak`.
3. **Secrets** – `kubectl apply -f k8s/keycloak-cluster/01-keycloak-db-secret.yaml`
   (in real life, an `ExternalSecret` from Secrets Manager).
4. **Keycloak + Ingress** – `kubectl apply -f k8s/keycloak-cluster/02-keycloak.yaml`

   The settings that matter for Kafka UI:

   | Setting | Value | Why |
   |---------|-------|-----|
   | `hostname.hostname` | `https://auth.example.com` | This string becomes the `iss` claim in every token. Kafka UI's `issuer-uri` must equal `https://auth.example.com/realms/kafka`. |
   | `hostname.strict` | `true` | Refuse requests that arrive under any other name — prevents issuer confusion. |
   | `http.httpEnabled` | `true` | The ALB terminates TLS and forwards plain HTTP to the pod. |
   | `proxy.headers` | `xforwarded` | Trust the ALB's `X-Forwarded-Proto/For` so Keycloak builds `https://` links and sees real client IPs. |
   | Ingress `alb.ingress.kubernetes.io/scheme` | `internet-facing` | Users' browsers must reach the login page. Make it `internal` only if all users are on VPN/Direct Connect **and** private DNS resolves for both browsers and the data cluster. |
   | ALB health check | `/health/ready` on port `9000` | Keycloak 25+ serves health on the management port. |

5. **Realm** – `kubectl apply -f k8s/keycloak-cluster/03-realm-import.yaml`.
   It creates realm `kafka`, roles `kafka-admin`/`kafka-viewer`, client
   `kafka-ui` with redirect URI `https://kafka-ui.example.com/*`, and the
   realm-role → `roles` claim mapper. Set the client secret by editing the
   file or by defining `KAFKA_UI_CLIENT_SECRET` as an env var on the
   Keycloak CR (`spec.additionalOptions` / `spec.unsupported.podTemplate`),
   which the import substitutes.
6. Verify: `curl https://auth.example.com/realms/kafka/.well-known/openid-configuration`
   — the `issuer` field must read exactly `https://auth.example.com/realms/kafka`.
7. Store the client secret in Secrets Manager so the data cluster can fetch it:
   ```bash
   aws secretsmanager create-secret --name kafka-ui/keycloak-client \
     --secret-string '{"client-secret":"<the secret>"}'
   ```

### Step 2: Kafka on the *data* cluster (Strimzi)

```bash
kubectl config use-context data
helm install strimzi-kafka-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  -n kafka --create-namespace
kubectl apply -f k8s/kafka-cluster/01-kafka-strimzi.yaml
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=600s -n kafka
kubectl apply -f k8s/kafka-cluster/02-topics.yaml
```

What the Strimzi manifest sets and why:

| Setting | Value | Why |
|---------|-------|-----|
| `KafkaNodePool` ×2 (controller, broker) | 3 + 3 | KRaft mode; controllers separate from brokers so broker load can't stall metadata. |
| `storage.class` | `gp3` | EBS gp3: cheaper and faster baseline than gp2. `deleteClaim: false` keeps data if the CR is deleted. |
| `podAntiAffinity` on zone | required | One broker per AZ → survive an AZ outage. |
| listener `plain` 9092 `internal` | no TLS | In-cluster only; Kafka UI connects here. |
| listener `tls` 9093 `internal` | mTLS | For in-cluster apps that need encryption/auth. |
| `min.insync.replicas: 2`, RF 3 | | Durability: a write is acked only when 2 of 3 replicas have it. |
| `auto.create.topics.enable: false` | | Topics are declared as `KafkaTopic` CRs (GitOps-friendly). |

In-cluster bootstrap address: `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092`.

### Step 3: Kafka UI on the *data* cluster

1. **Secret** – `kubectl apply -f k8s/kafka-cluster/03-kafka-ui-external-secret.yaml`
   creates Secret `kafka-ui-keycloak` containing
   `AUTH_OAUTH2_CLIENT_KEYCLOAK_CLIENTSECRET`, synced from Secrets Manager
   (IRSA role needs `secretsmanager:GetSecretValue` on that secret).
2. **Helm** –
   ```bash
   helm repo add kafbat-ui https://ui.charts.kafbat.io
   helm upgrade --install kafka-ui kafbat-ui/kafka-ui -n kafka -f k8s/kafka-cluster/04-kafka-ui-values.yaml
   ```
3. Browse to `https://kafka-ui.example.com` → Keycloak login → topics.

The values-file settings explained:

| Setting | Value | Why |
|---------|-------|-----|
| `existingSecret` | `kafka-ui-keycloak` | Injects the client secret as an env var; keeps it out of the values file / git. |
| `bootstrapServers` | `…kafka-bootstrap.kafka.svc.cluster.local:9092` | Strimzi's stable bootstrap Service. |
| `issuer-uri` | `https://auth.example.com/realms/kafka` | Public HTTPS issuer of the external Keycloak — identical for browser and pod. |
| `server.forward-headers-strategy: framework` | | Kafka UI is behind the ALB (TLS offload). Without this it would build an `http://` redirect URI and Keycloak would reject it. |
| `rbac.roles` | admins / viewers | Maps Keycloak realm roles to permissions (see `kafka-ui-keycloak-setup.md`). |
| `ingress` class `alb`, `scheme: internal` | | Internal ALB reachable from the corporate network/VPN; switch to `internet-facing` if needed. |
| `healthcheck-path: /actuator/health` | | Kafka UI's Spring Boot health endpoint. |
| `replicaCount: 2` | | HA; sessions are in-memory, so enable ALB **sticky sessions** (`alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true`) or keep 1 replica. |

### Step 4: Test with the Python client

Kafka is not exposed outside the cluster by default. Two options:

* **Run the producer inside the cluster** (quickest):
  ```bash
  kubectl run producer -n kafka --rm -it --image=python:3.12-slim -- bash
  pip install confluent-kafka && cat > p.py <<'EOF'
  # paste client/producer.py here
  EOF
  python p.py -b my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092
  ```
* **Expose an external listener** – uncomment the `external` listener in
  `01-kafka-strimzi.yaml` (internal NLB, TLS). Then from a VPN-connected
  laptop:
  ```bash
  kubectl get secret my-cluster-cluster-ca-cert -n kafka -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
  python producer.py -b <nlb-bootstrap-host>:9094   # add security.protocol=SSL, ssl.ca.location=ca.crt to the Producer config
  ```

---

## Part 2 – Background: the pieces that are new on AWS

* **EKS** runs Kubernetes for you (control plane managed; you provide nodes).
* **Strimzi** is a Kubernetes operator: you describe the Kafka cluster as
  YAML and it creates pods, storage, certificates and rolling restarts.
  It is the standard way to run Kafka on Kubernetes.
* **Keycloak Operator** does the same for Keycloak, including realm imports.
* **ALB Ingress** – AWS Load Balancer Controller creates an Application Load
  Balancer with an ACM certificate; pods receive plain HTTP. This "TLS
  termination at the edge" is why both apps must be told to trust
  `X-Forwarded-*` headers.
* **IRSA (IAM Roles for Service Accounts)** lets a pod (External Secrets,
  the LB controller, ExternalDNS) call AWS APIs without static keys.
* **RDS** – managed PostgreSQL for Keycloak's state.

---

## Part 3 – How Kafka UI reaches the external Keycloak

| Path | Route | Notes |
|------|-------|-------|
| Browser → Keycloak | Internet (or VPN) → `auth.example.com` ALB | Must be reachable by every user. |
| Kafka UI pod → Keycloak | Pod → NAT Gateway → public ALB `auth.example.com` | Simplest. Egress from the data cluster's security group to 443 must be allowed (it is by default). |
| Kafka UI pod → Keycloak (private) | Internal ALB + VPC peering / Transit Gateway + Route 53 private hosted zone, **or** AWS PrivateLink | Same DNS name must resolve to the private ALB inside the data VPC *and* to something browsers can reach (split-horizon DNS). More secure, more moving parts. |
| Browser → Kafka UI | `kafka-ui.example.com` ALB | Internal + VPN recommended; the UI can produce/delete data. |

Rule of thumb: whatever the `issuer-uri` string is, `curl` it from inside a
Kafka UI pod **and** from a user's laptop; both must return the discovery
document with the same `issuer`.

---

## Part 4 – Options, pros and cons

| Decision | Chosen here | Alternative | Trade-off |
|----------|-------------|-------------|-----------|
| Kafka on EKS | **Strimzi** (self-managed, KRaft) | **Amazon MSK** (managed) | Strimzi: full control, cheaper at scale, portable. MSK: no ops, IAM auth, but Kafka UI then needs the MSK IAM auth plugin or SASL/SCRAM. |
| Keycloak deployment | **Keycloak Operator** | Helm chart (codecentric `keycloakx`, Bitnami) | Operator handles realm imports and rolling config; Helm charts are more customizable but you own the wiring. |
| Keycloak location | **Separate EKS cluster** | Same cluster, own namespace | Separate cluster isolates identity from data workloads and lets other apps share it; same cluster is cheaper and simpler (then use the in-cluster Service URL only if browsers also see that name — usually still go via the public ALB). |
| Secrets | **Secrets Manager + External Secrets** | Sealed Secrets, SOPS, plain k8s Secrets | Secrets Manager rotates and audits; ESO adds an operator. Plain Secrets in git are unacceptable. |
| Exposure | **Internal ALBs + VPN** for Kafka UI, **public ALB** for Keycloak | Everything public | Least exposure for the tool that can delete topics; login page usually needs to be public anyway. |
| Kafka client access | In-cluster only | Strimzi `loadbalancer`/`ingress`/`nodeport` listeners with TLS | External listeners cost one NLB per broker (loadbalancer type) or need an ingress controller with TLS passthrough. |
| Broker security | PLAINTEXT internal listener | SASL/OAUTHBEARER against Keycloak (`strimzi-kafka-oauth`) | Strimzi ships native Keycloak OAuth support: `authentication: { type: oauth, validIssuerUri: https://auth.example.com/realms/kafka, jwksEndpointUri: … }` — then clients (and Kafka UI) authenticate to the *broker* with Keycloak tokens too. |

### Best practices checklist
* Pin image versions (`kafbat/kafka-ui:vX.Y`, `keycloak:26.x`, Kafka `3.9.0`) — never `latest` in production.
* `hostname.strict: true` on Keycloak and an exact `issuer-uri` on Kafka UI.
* One AZ per broker, `min.insync.replicas = RF − 1`.
* Enable Kafka UI **audit** logging (`auditConfig`) to see who produced/deleted what.
* Restrict the Kafka UI ALB with security groups or WAF; it is an admin tool.
* Back up RDS (automated snapshots) — losing the Keycloak DB means re-creating every user.
* Use Karpenter or managed node groups with `topologySpreadConstraints` so Kafka pods get scheduled after a node loss.
* Set `PodDisruptionBudget`s (Strimzi creates one for Kafka; add one for Kafka UI).

---

## Part 5 – Troubleshooting on EKS

| Symptom | Cause | Fix |
|---------|-------|-----|
| Kafka UI pod `CrashLoopBackOff`, log says issuer unreachable | No egress to Keycloak (NAT/SG/NetworkPolicy) or DNS | `kubectl exec` into a pod and `curl` the discovery URL; check NAT gateway and any NetworkPolicy. |
| Keycloak error *Invalid redirect_uri* with `http://…` | Kafka UI built an http redirect because it didn't trust the ALB headers | `server.forward-headers-strategy: framework` (already in values). |
| Login works but Keycloak links show `http://` or wrong host | `proxy.headers` / `hostname` not set on Keycloak | Set `hostname.hostname: https://auth.example.com` and `proxy.headers: xforwarded`. |
| ALB target unhealthy for Keycloak | Health path/port wrong | `/health/ready` on port 9000 and `health-enabled: true`. |
| Random logouts with 2 Kafka UI replicas | Sessions are per-pod | Enable ALB stickiness or scale to 1. |
| Ingress created but no DNS record | ExternalDNS lacks Route 53 rights / wrong zone | Check ExternalDNS logs and its IRSA policy. |
| `KafkaTopic` stuck `NotReady` | Topic Operator can't reach brokers / RF > brokers | `kubectl describe kafkatopic …`; ensure `replicas ≤ broker count`. |
| ExternalSecret `SecretSyncedError` | IRSA role can't read the secret | Grant `secretsmanager:GetSecretValue` on the secret ARN to the ESO service-account role. |
