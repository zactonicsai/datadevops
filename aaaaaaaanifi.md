# Building NiFi & Kafka Container Images for AWS EKS
### A Complete Beginner-to-Production Guide (July 2026 Edition)

---

## Table of Contents

**PART 1 — DO IT ONCE (The 60-Minute Walkthrough)**
- [0. What We're Building (Read This First)](#0-what-were-building)
- [1. Prerequisites & Tool Install](#1-prerequisites)
- [2. Step-by-Step: Your First NiFi Image → ECR → EKS](#2-quickstart)

**PART 2 — BACKGROUND (Why Everything Works That Way)**
- [3. Container Images Explained Like You're 12](#3-images-explained)
- [4. What NiFi Actually Is](#4-what-is-nifi)
- [5. What Kafka Actually Is (and KRaft)](#5-what-is-kafka)
- [6. What EKS Actually Is](#6-what-is-eks)

**PART 3 — THE THREE WAYS TO BUILD (Pros & Cons)**
- [7. Option A: AWS CLI (Manual)](#7-option-a-cli)
- [8. Option B: Terraform (Infrastructure as Code)](#8-option-b-terraform)
- [9. Option C: Ansible (Configuration Management)](#9-option-c-ansible)
- [10. Which Should You Pick? Decision Matrix](#10-decision-matrix)

**PART 4 — PRODUCTION HARDENING**
- [11. Building the Kafka Image (Full Detail)](#11-kafka-image)
- [12. Building the NiFi Image (Full Detail)](#12-nifi-image)
- [13. Deploying to EKS: Pods, Nodes, StatefulSets](#13-eks-deployment)
- [14. Patching Strategy](#14-patching)
- [15. Rollback Playbook](#15-rollback)
- [16. Gotchas That Will Bite You](#16-gotchas)
- [17. Security Checklist](#17-security)
- [18. Cost Notes](#18-cost)

---

<a name="0-what-were-building"></a>
## 0. What We're Building (Read This First)

### The One-Sentence Version

> We are going to take two big Java programs — **NiFi** (moves data around) and **Kafka** (a super-fast message mailbox) — pack each one into a **container image** (like a lunchbox with everything it needs), store those lunchboxes in **Amazon ECR** (a fridge), and then run them on **Amazon EKS** (a robot kitchen that keeps them running forever).

### The Picture

```
   YOUR LAPTOP                AWS CLOUD
   ───────────                ─────────

   [Dockerfile]                 ┌──────────────────┐
        │                       │   ECR (Registry) │
        │  docker build         │  ┌────────────┐  │
        ▼                       │  │ nifi:2.10.0│  │
   [Local Image]  ──push──────► │  │ kafka:4.3  │  │
                                │  └─────┬──────┘  │
                                └────────┼─────────┘
                                         │ pull
                                         ▼
                                ┌──────────────────────┐
                                │   EKS CLUSTER 1.36   │
                                │  ┌────────────────┐  │
                                │  │ Node (EC2 VM)  │  │
                                │  │  ┌──────────┐  │  │
                                │  │  │ Pod:NiFi │  │  │
                                │  │  └──────────┘  │  │
                                │  │  ┌──────────┐  │  │
                                │  │  │Pod:Kafka │  │  │
                                │  │  └──────────┘  │  │
                                │  └────────────────┘  │
                                └──────────────────────┘
```

### Versions We Are Using (Verified July 2026)

| Thing | Version | Why This One |
|---|---|---|
| Apache NiFi | **2.10.0** (June 18, 2026) | Latest release. NiFi only actively maintains the newest release — older ones get no security patches. |
| Apache Kafka | **4.3.x** (latest 4.x) | ZooKeeper is **completely gone** as of 4.0. KRaft only. Kafka supports the last 3 minor versions. |
| EKS / Kubernetes | **1.36** | Latest EKS. 1.33 goes end-of-support **July 29, 2026** — nine days from now. Do not start on 1.33. |
| Base OS in image | **Amazon Linux 2023** (AL2023) | AL2 AMIs stopped at EKS 1.32. AL2023 and Bottlerocket are the only choices now. |
| Java | **21 (LTS)** | NiFi 2.x requires Java 21 minimum. Kafka 4.x also wants 17+. Use 21 for both. |

> ⚠️ **Version Warning:** These versions move fast. Before you build, run the version-check commands in [Section 14](#14-patching). Software from six months ago may already be end-of-life.

---

<a name="1-prerequisites"></a>
## 1. Prerequisites & Tool Install

### What You Need Before Starting

| Tool | Minimum Version | What It Does | Check Command |
|---|---|---|---|
| AWS CLI | v2.x | Talks to AWS from your terminal | `aws --version` |
| Docker (or Podman/Finch) | 24+ | Builds images | `docker --version` |
| kubectl | Within 1 minor of 1.36 | Talks to Kubernetes | `kubectl version --client` |
| eksctl | latest | Shortcut tool for making EKS clusters | `eksctl version` |
| Terraform | 1.9+ | Infrastructure as Code (Option B) | `terraform version` |
| Ansible | 2.16+ | Config management (Option C) | `ansible --version` |
| Helm | 3.14+ | Kubernetes package installer | `helm version` |

### Install Everything (macOS / Linux)

```bash
# ---- AWS CLI v2 ----
# macOS
brew install awscli
# Linux (x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# ---- kubectl (matched to EKS 1.36) ----
# Always install kubectl within ONE minor version of your cluster.
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# ---- eksctl ----
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz && sudo mv eksctl /usr/local/bin/

# ---- Helm ----
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ---- Terraform ----
# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# ---- Ansible + AWS collections ----
python3 -m pip install --user ansible boto3 botocore kubernetes
ansible-galaxy collection install amazon.aws community.docker kubernetes.core
```

### Configure AWS Access

**Never use long-lived access keys if you can avoid it.** Use SSO:

```bash
aws configure sso
# SSO start URL: https://your-org.awsapps.com/start
# SSO Region: us-east-1
# Account: <pick yours>
# Role: <pick yours>
# Profile name: my-eks-profile

export AWS_PROFILE=my-eks-profile
aws sts get-caller-identity     # Should print your account + role
```

**Fallback (only if SSO is unavailable):**
```bash
aws configure
# AWS Access Key ID: AKIA...
# AWS Secret Access Key: ...
# Default region: us-east-1
```

> 🔒 **Why SSO is better:** Access keys are like a house key you mailed to someone — if it leaks, it works forever. SSO credentials expire in hours. Attackers who steal them get almost nothing.

### Set Your Working Variables

Put this in a file called `env.sh` and `source env.sh` at the start of every session:

```bash
#!/usr/bin/env bash
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export CLUSTER_NAME="data-platform"
export K8S_VERSION="1.36"
export NIFI_VERSION="2.10.0"
export KAFKA_VERSION="4.3.0"
export SCALA_VERSION="2.13"

echo "Registry: ${ECR_REGISTRY}"
```

---

<a name="2-quickstart"></a>
## 2. Step-by-Step: Your First NiFi Image → ECR → EKS

> **This is the whole thing, start to finish, one time.** Follow it exactly. Understand it later in Part 2. Budget about 60 minutes (EKS cluster creation alone takes ~15).

### Step 2.1 — Make a Project Folder

```bash
mkdir -p ~/data-platform/{nifi,kafka,k8s,terraform,ansible}
cd ~/data-platform
source env.sh
```

**What this does:** Creates folders to keep things tidy. Like separate drawers for socks and shirts.

---

### Step 2.2 — Write the NiFi Dockerfile

Create `~/data-platform/nifi/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7

# ══════════════════════════════════════════════════════════
# STAGE 1: "builder" — download and verify NiFi
# We do this in a throwaway stage so curl, gpg, and the
# .zip file never end up in the final image.
# ══════════════════════════════════════════════════════════
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS builder

ARG NIFI_VERSION=2.10.0
ARG NIFI_BASE_URL=https://archive.apache.org/dist/nifi

RUN dnf install -y tar gzip unzip gnupg2 findutils && dnf clean all

WORKDIR /build

# Download the binary, the signature, and the checksum
RUN curl -fSL "${NIFI_BASE_URL}/${NIFI_VERSION}/nifi-${NIFI_VERSION}-bin.zip" -o nifi.zip \
 && curl -fSL "${NIFI_BASE_URL}/${NIFI_VERSION}/nifi-${NIFI_VERSION}-bin.zip.sha512" -o nifi.zip.sha512

# VERIFY THE CHECKSUM. Never skip this.
# If the file was tampered with in transit, the build fails here.
RUN echo "$(cat nifi.zip.sha512 | awk '{print $1}')  nifi.zip" | sha512sum -c -

RUN unzip -q nifi.zip \
 && mv "nifi-${NIFI_VERSION}" /build/nifi \
 # Strip things we will never use — smaller image, smaller attack surface
 && rm -rf /build/nifi/docs /build/nifi/LICENSE /build/nifi/NOTICE

# ══════════════════════════════════════════════════════════
# STAGE 2: "runtime" — the actual image that ships
# ══════════════════════════════════════════════════════════
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless

ARG NIFI_VERSION=2.10.0
LABEL org.opencontainers.image.title="apache-nifi" \
      org.opencontainers.image.version="${NIFI_VERSION}" \
      org.opencontainers.image.base.name="amazoncorretto:21-al2023-headless" \
      org.opencontainers.image.source="https://github.com/apache/nifi"

ENV NIFI_HOME=/opt/nifi \
    NIFI_PID_DIR=/opt/nifi/run \
    NIFI_LOG_DIR=/opt/nifi/logs \
    JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto

# Create a NON-ROOT user. Kubernetes will refuse to run root
# containers if you set the security policies in Section 17.
RUN dnf install -y shadow-utils procps-ng jq && dnf clean all \
 && groupadd -g 1000 nifi \
 && useradd -u 1000 -g 1000 -m -d /home/nifi -s /sbin/nologin nifi

COPY --from=builder --chown=1000:1000 /build/nifi ${NIFI_HOME}

# Directories that will hold data. In EKS these become
# PersistentVolumes (see Section 13).
RUN mkdir -p ${NIFI_HOME}/{run,logs,conf,state} \
             ${NIFI_HOME}/{content_repository,database_repository,flowfile_repository,provenance_repository} \
 && chown -R 1000:1000 ${NIFI_HOME}

COPY --chown=1000:1000 entrypoint.sh /opt/entrypoint.sh
RUN chmod 0755 /opt/entrypoint.sh

USER 1000:1000
WORKDIR ${NIFI_HOME}

EXPOSE 8443 8080 6342 10443

# Kubernetes uses this to know if the app is alive
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
  CMD curl -sf -k https://localhost:8443/nifi-api/system-diagnostics || exit 1

ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["run"]
```

**Line-by-line, in plain words:**

| Line | What It Means |
|---|---|
| `FROM ... AS builder` | "Start a temporary workshop." Anything left here gets thrown away. |
| `sha512sum -c -` | "Check the fingerprint of the file I downloaded." If someone swapped the file, this fails. **This is your #1 supply-chain defense.** |
| `FROM amazoncorretto:21...` | "Start the real image from Amazon's Java 21." Corretto is AWS's free, patched Java. |
| `COPY --from=builder` | "Take only the finished NiFi folder from the workshop." The zip, curl, and gpg stay behind. |
| `useradd -u 1000` | "Make a normal user, not the admin." If someone breaks into the container, they're a guest, not the landlord. |
| `USER 1000:1000` | "From here on, run as that normal user." |
| `HEALTHCHECK` | "Here's how to tell if I'm alive." Kubernetes restarts me if I stop answering. |
| `--start-period=180s` | "Give me 3 minutes to wake up before you judge me." NiFi is slow to start. |

---

### Step 2.3 — Write the Entrypoint Script

Create `~/data-platform/nifi/entrypoint.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# -e  = stop on any error
# -u  = stop if I use an undefined variable
# -o pipefail = catch errors in the middle of a pipe
# These three lines prevent 90% of silent container failures.

NIFI_HOME="${NIFI_HOME:-/opt/nifi}"
PROPS="${NIFI_HOME}/conf/nifi.properties"

log() { echo "[entrypoint] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

# Helper: set a property in nifi.properties
prop_set() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "${PROPS}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${PROPS}"
  else
    echo "${key}=${value}" >> "${PROPS}"
  fi
}

log "Configuring NiFi ${NIFI_VERSION:-unknown}"

# ── Hostname: in Kubernetes, StatefulSet pods get stable DNS names ──
POD_FQDN="${HOSTNAME}.${NIFI_HEADLESS_SERVICE:-nifi-headless}.${POD_NAMESPACE:-default}.svc.cluster.local"
prop_set "nifi.web.https.host"          "0.0.0.0"
prop_set "nifi.web.https.port"          "8443"
prop_set "nifi.web.proxy.host"          "${NIFI_PROXY_HOSTS:-localhost:8443}"

# ── Clustering (turn on when NIFI_CLUSTERED=true) ──
if [[ "${NIFI_CLUSTERED:-false}" == "true" ]]; then
  log "Cluster mode ON. Node FQDN=${POD_FQDN}"
  prop_set "nifi.cluster.is.node"                       "true"
  prop_set "nifi.cluster.node.address"                  "${POD_FQDN}"
  prop_set "nifi.cluster.node.protocol.port"            "11443"
  prop_set "nifi.cluster.load.balance.host"             "${POD_FQDN}"
  prop_set "nifi.cluster.load.balance.port"             "6342"
  prop_set "nifi.cluster.leader.election.implementation" "KubernetesLeaderElectionManager"
  prop_set "nifi.state.management.provider.cluster"     "kubernetes-provider"
else
  log "Standalone mode"
  prop_set "nifi.cluster.is.node" "false"
fi

# ── Repositories point at mounted volumes ──
prop_set "nifi.flowfile.repository.directory"           "${NIFI_HOME}/flowfile_repository"
prop_set "nifi.content.repository.directory.default"    "${NIFI_HOME}/content_repository"
prop_set "nifi.provenance.repository.directory.default" "${NIFI_HOME}/provenance_repository"
prop_set "nifi.database.directory"                      "${NIFI_HOME}/database_repository"

# ── Sensitive props key MUST come from a Secret, never hardcoded ──
if [[ -n "${NIFI_SENSITIVE_PROPS_KEY:-}" ]]; then
  prop_set "nifi.sensitive.props.key" "${NIFI_SENSITIVE_PROPS_KEY}"
else
  log "FATAL: NIFI_SENSITIVE_PROPS_KEY not set. Refusing to start."
  log "Generate one with: openssl rand -base64 32"
  exit 1
fi

# ── Heap sizing from the container's actual memory limit ──
# Without this, the JVM guesses wrong and gets OOMKilled.
if [[ -n "${NIFI_JVM_HEAP_INIT:-}" ]]; then
  sed -i "s|^java.arg.2=.*|java.arg.2=-Xms${NIFI_JVM_HEAP_INIT}|" "${NIFI_HOME}/conf/bootstrap.conf"
fi
if [[ -n "${NIFI_JVM_HEAP_MAX:-}" ]]; then
  sed -i "s|^java.arg.3=.*|java.arg.3=-Xmx${NIFI_JVM_HEAP_MAX}|" "${NIFI_HOME}/conf/bootstrap.conf"
fi

log "Starting NiFi in foreground"
# 'run' = foreground. NEVER use 'start' (background) in a container —
# the container would exit immediately because PID 1 finished.
exec "${NIFI_HOME}/bin/nifi.sh" run
```

```bash
chmod +x ~/data-platform/nifi/entrypoint.sh
```

> 💡 **Gotcha #1 (the big one):** `nifi.sh start` runs NiFi in the *background* and then exits. In a container, when the main process exits, **the container dies.** Always use `run`, and always `exec` it so NiFi becomes PID 1 and receives shutdown signals properly.

---

### Step 2.4 — Create the ECR Repository

```bash
source env.sh

aws ecr create-repository \
  --repository-name data-platform/nifi \
  --region "${AWS_REGION}" \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE \
  --encryption-configuration encryptionType=AES256
```

**What each flag does:**

| Flag | Plain English | Why It Matters |
|---|---|---|
| `scanOnPush=true` | "Check for known viruses/bugs every time I upload." | Free basic scanning. Catches known CVEs automatically. |
| `IMMUTABLE` | "Once a tag is used, it can never be reused." | **Critical.** Stops someone from silently replacing `v2.10.0` with different code. What you tested is what ships. |
| `AES256` | "Encrypt the stored images." | Encryption at rest, no extra cost. |

> ⚠️ **Gotcha #2:** With `IMMUTABLE`, you **cannot** push `latest` twice. This is intentional and good. Tag with the real version plus a build number: `2.10.0-build.42`.

---

### Step 2.5 — Build and Push the Image

```bash
cd ~/data-platform/nifi
source ../env.sh

# 1. Log in to ECR (token lasts 12 hours)
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# 2. Build for the right CPU architecture!
#    Apple Silicon Macs build arm64 by default — that will NOT run
#    on x86 EKS nodes. Always set --platform explicitly.
docker buildx build \
  --platform linux/amd64 \
  --build-arg NIFI_VERSION="${NIFI_VERSION}" \
  --provenance=true \
  --sbom=true \
  -t "${ECR_REGISTRY}/data-platform/nifi:${NIFI_VERSION}-build.1" \
  --load \
  .

# 3. Push
docker push "${ECR_REGISTRY}/data-platform/nifi:${NIFI_VERSION}-build.1"
```

**Check the scan results:**

```bash
aws ecr describe-image-scan-findings \
  --repository-name data-platform/nifi \
  --image-id imageTag="${NIFI_VERSION}-build.1" \
  --region "${AWS_REGION}" \
  --query 'imageScanFindings.findingSeverityCounts'
```

Expected output (zeros are what you want for CRITICAL/HIGH):
```json
{ "MEDIUM": 2, "LOW": 5 }
```

> ⚠️ **Gotcha #3 — The #1 mistake beginners make:** You build on an M1/M2/M3 Mac, push, and the pod crashes with `exec format error`. That means you built an **arm64** image and tried to run it on **amd64** nodes. Fix: always pass `--platform linux/amd64` (or use Graviton nodes and build arm64 — just be consistent).

---

### Step 2.6 — Create the EKS Cluster

```bash
source ~/data-platform/env.sh

eksctl create cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --version "${K8S_VERSION}" \
  --nodegroup-name data-nodes \
  --node-type m6i.2xlarge \
  --nodes 3 \
  --nodes-min 3 \
  --nodes-max 6 \
  --node-volume-size 100 \
  --node-volume-type gp3 \
  --node-ami-family AmazonLinux2023 \
  --with-oidc \
  --managed \
  --full-ecr-access \
  --alb-ingress-access
```

☕ **This takes 15–20 minutes.** Go get coffee. EKS is building a control plane, a VPC, subnets, security groups, and an EC2 Auto Scaling Group.

**What the flags mean:**

| Flag | Meaning |
|---|---|
| `--version 1.36` | Kubernetes version. Do **not** use 1.33 — support ends July 29, 2026. |
| `--node-type m6i.2xlarge` | 8 vCPU, 32 GB RAM per node. NiFi and Kafka are memory-hungry. |
| `--node-ami-family AmazonLinux2023` | AL2 is gone from EKS 1.33+. AL2023 or Bottlerocket only. |
| `--with-oidc` | Turns on IRSA — lets pods get AWS permissions without secret keys. **Essential.** |
| `--managed` | AWS handles node patching and draining for you. |
| `--node-volume-type gp3` | gp3 is cheaper and faster than gp2. Always pick gp3. |

**Verify:**

```bash
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
kubectl get nodes -o wide
```

You should see 3 nodes with `STATUS=Ready`.

---

### Step 2.7 — Create the Secret NiFi Needs

```bash
kubectl create namespace data-platform

# Generate a strong random key. WRITE THIS DOWN somewhere safe
# (AWS Secrets Manager). If you lose it, encrypted flow config
# is UNRECOVERABLE.
SENSITIVE_KEY="$(openssl rand -base64 32)"
ADMIN_PASSWORD="$(openssl rand -base64 24)"

kubectl create secret generic nifi-secrets \
  --namespace data-platform \
  --from-literal=sensitive-props-key="${SENSITIVE_KEY}" \
  --from-literal=single-user-username="admin" \
  --from-literal=single-user-password="${ADMIN_PASSWORD}"

echo "SAVE THIS PASSWORD: ${ADMIN_PASSWORD}"

# Back it up to AWS Secrets Manager immediately
aws secretsmanager create-secret \
  --name "data-platform/nifi/sensitive-props-key" \
  --secret-string "${SENSITIVE_KEY}" \
  --region "${AWS_REGION}"
```

> 🔴 **Gotcha #4 — The one that ruins weekends:** `nifi.sensitive.props.key` encrypts every password inside your NiFi flow. If a pod restarts with a *different* key, NiFi cannot decrypt its own flow and **will not start**. It must be identical across every node and every restart, forever. Back it up in Secrets Manager on day one.

---

### Step 2.8 — Deploy NiFi to EKS

Create `~/data-platform/k8s/nifi-statefulset.yaml`:

```yaml
# ── Headless Service: gives each pod a stable DNS name ──
apiVersion: v1
kind: Service
metadata:
  name: nifi-headless
  namespace: data-platform
spec:
  clusterIP: None          # "headless" = no load balancing, direct pod DNS
  publishNotReadyAddresses: true   # pods can find each other while starting
  selector:
    app: nifi
  ports:
    - { name: https,        port: 8443,  targetPort: 8443 }
    - { name: cluster,      port: 11443, targetPort: 11443 }
    - { name: loadbalance,  port: 6342,  targetPort: 6342 }
---
# ── Regular Service: what users connect to ──
apiVersion: v1
kind: Service
metadata:
  name: nifi
  namespace: data-platform
spec:
  type: ClusterIP
  selector:
    app: nifi
  ports:
    - { name: https, port: 8443, targetPort: 8443 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nifi
  namespace: data-platform
spec:
  serviceName: nifi-headless
  replicas: 1                    # start with 1; scale up in Section 13
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0               # canary control — see Section 15
  selector:
    matchLabels:
      app: nifi
  template:
    metadata:
      labels:
        app: nifi
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000            # makes mounted volumes writable by our user
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault

      terminationGracePeriodSeconds: 180   # NiFi needs time to flush data

      containers:
        - name: nifi
          # ⬇️ REPLACE <ACCOUNT_ID> with your account number
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/data-platform/nifi:2.10.0-build.1
          imagePullPolicy: IfNotPresent

          env:
            - name: POD_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: NIFI_HEADLESS_SERVICE
              value: "nifi-headless"
            - name: NIFI_CLUSTERED
              value: "false"
            - name: NIFI_PROXY_HOSTS
              value: "localhost:8443,nifi.data-platform.svc.cluster.local:8443"
            - name: NIFI_JVM_HEAP_INIT
              value: "4g"
            - name: NIFI_JVM_HEAP_MAX
              value: "4g"          # Xms == Xmx avoids GC pauses from resizing
            - name: NIFI_SENSITIVE_PROPS_KEY
              valueFrom:
                secretKeyRef: { name: nifi-secrets, key: sensitive-props-key }
            - name: SINGLE_USER_CREDENTIALS_USERNAME
              valueFrom:
                secretKeyRef: { name: nifi-secrets, key: single-user-username }
            - name: SINGLE_USER_CREDENTIALS_PASSWORD
              valueFrom:
                secretKeyRef: { name: nifi-secrets, key: single-user-password }

          ports:
            - { name: https,       containerPort: 8443 }
            - { name: cluster,     containerPort: 11443 }
            - { name: loadbalance, containerPort: 6342 }

          resources:
            requests: { cpu: "2",  memory: "8Gi" }
            limits:   { cpu: "4",  memory: "8Gi" }
            # requests == limits for memory → "Guaranteed" QoS class.
            # This means Kubernetes evicts this pod LAST under pressure.

          # startupProbe: "are you awake yet?" — 20 min max to boot
          startupProbe:
            httpGet: { path: /nifi-api/system-diagnostics, port: 8443, scheme: HTTPS }
            failureThreshold: 60
            periodSeconds: 20

          # livenessProbe: "are you still alive?" — restart if not
          livenessProbe:
            httpGet: { path: /nifi-api/system-diagnostics, port: 8443, scheme: HTTPS }
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 4

          # readinessProbe: "can you take traffic?" — remove from Service if not
          readinessProbe:
            httpGet: { path: /nifi-api/system-diagnostics, port: 8443, scheme: HTTPS }
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 3

          volumeMounts:
            - { name: flowfile,   mountPath: /opt/nifi/flowfile_repository }
            - { name: content,    mountPath: /opt/nifi/content_repository }
            - { name: provenance, mountPath: /opt/nifi/provenance_repository }
            - { name: database,   mountPath: /opt/nifi/database_repository }
            - { name: conf,       mountPath: /opt/nifi/conf }
            - { name: state,      mountPath: /opt/nifi/state }

  # Each pod gets its OWN disks, and they survive pod restarts
  volumeClaimTemplates:
    - metadata: { name: flowfile }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 20Gi } }
    - metadata: { name: content }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 100Gi } }
    - metadata: { name: provenance }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 50Gi } }
    - metadata: { name: database }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 10Gi } }
    - metadata: { name: conf }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 5Gi } }
    - metadata: { name: state }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 5Gi } }
```

**First, create the gp3 StorageClass** (EKS defaults to gp2, which is worse and pricier):

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer   # don't make the disk until a pod is scheduled
allowVolumeExpansion: true                # lets you grow disks later
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
EOF

# Remove the default flag from gp2 so gp3 wins
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

**Make sure the EBS CSI driver is installed** (without it, PVCs hang forever):

```bash
eksctl create addon --name aws-ebs-csi-driver \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --force
```

**Now deploy:**

```bash
# Substitute your real account ID
sed -i "s|<ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" ~/data-platform/k8s/nifi-statefulset.yaml

kubectl apply -f ~/data-platform/k8s/nifi-statefulset.yaml

# Watch it come up (takes 3-5 minutes)
kubectl -n data-platform get pods -w
```

---

### Step 2.9 — Verify It Works

```bash
# 1. Pod should be Running and 1/1 Ready
kubectl -n data-platform get pods

# 2. Check the logs for the startup banner
kubectl -n data-platform logs nifi-0 --tail=50

# 3. Port-forward to your laptop
kubectl -n data-platform port-forward svc/nifi 8443:8443
```

Open **https://localhost:8443/nifi** in a browser. Accept the self-signed cert warning. Log in with `admin` and the password you printed in Step 2.7.

🎉 **You did it.** You built an image, stored it in ECR, and ran it on EKS.

---

### Step 2.10 — Clean Up (If This Was Just a Test)

```bash
kubectl delete namespace data-platform
# PVCs from StatefulSets are NOT auto-deleted — clean manually
kubectl -n data-platform delete pvc --all

eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
```

> 💸 **Cost warning:** An idle EKS cluster costs roughly **$73/month for the control plane** plus EC2 node costs (3× m6i.2xlarge ≈ **$700/month** on-demand) plus EBS. Delete test clusters.

---

# PART 2 — BACKGROUND

<a name="3-images-explained"></a>
## 3. Container Images Explained Like You're 12

### The Lunchbox Analogy

Imagine you're going on a school trip. You could:

1. **Hope the destination has food** → This is installing software directly on a server. It works until the server has a different Java version and everything breaks.
2. **Pack a lunchbox with everything** → This is a **container image**. Sandwich, drink, fork, napkin — all in one sealed box. It works identically at school, at home, or on Mars.

A **container image** is a sealed, read-only package containing:
- The application (NiFi)
- Everything it needs to run (Java 21)
- A minimal operating system (Amazon Linux 2023)
- Configuration files
- A start command

A **container** is what you get when you *open* the lunchbox and start eating — a running instance of the image.

### Layers: The Stack of Transparent Sheets

Images are built in **layers**, like stacking transparencies on an overhead projector:

```
┌──────────────────────────────────┐  ← Layer 5: our entrypoint.sh (2 KB)
├──────────────────────────────────┤  ← Layer 4: NiFi files (1.4 GB)
├──────────────────────────────────┤  ← Layer 3: our user account (1 KB)
├──────────────────────────────────┤  ← Layer 2: Java 21 (180 MB)
└──────────────────────────────────┘  ← Layer 1: Amazon Linux 2023 (120 MB)
```

**Why layers matter enormously:**

- Each `RUN`, `COPY`, or `ADD` in a Dockerfile creates a new layer.
- Layers are **cached**. If layer 1–4 didn't change, rebuilding only redoes layer 5 → build takes 3 seconds instead of 6 minutes.
- Layers are **shared**. If ten images use the same Amazon Linux base, the node downloads it once.
- **Deleting a file in a later layer does NOT shrink the image.** The file is still in the earlier layer, just hidden. This is why we use **multi-stage builds** — the whole builder stage is discarded, not just hidden.

**Order your Dockerfile from least-changing to most-changing:**

```dockerfile
FROM base              # changes monthly
RUN dnf install ...    # changes monthly
COPY dependencies      # changes weekly
COPY app-code          # changes hourly  ← put volatile stuff LAST
```

### Tags vs Digests

| | Example | What It Is | Trust Level |
|---|---|---|---|
| **Tag** | `nifi:2.10.0` | A nickname. Can be moved to point at different content. | 🟡 Medium (🟢 High if ECR is IMMUTABLE) |
| **Digest** | `nifi@sha256:a3f8...` | A fingerprint of the exact bytes. Cannot lie. | 🟢 Absolute |

**Best practice for production:** Pin by digest.

```yaml
image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/data-platform/nifi@sha256:a3f8b2c1...
```

Get the digest:
```bash
aws ecr describe-images \
  --repository-name data-platform/nifi \
  --image-ids imageTag=2.10.0-build.1 \
  --query 'imageDetails[0].imageDigest' --output text
```

> ⚠️ **Never use `:latest` in production.** `latest` means "whatever was pushed most recently." Two nodes can pull `latest` an hour apart and run *different code*. Debugging that is a nightmare.

### Base Image Options — Pros and Cons

| Base Image | Size | Pros | Cons | Use When |
|---|---|---|---|---|
| **amazoncorretto:21-al2023-headless** ⭐ | ~280 MB | AWS-patched Java; matches EKS node OS; free long-term support; `dnf` available for debugging | Bigger than distroless | **Default choice for AWS.** Recommended here. |
| `eclipse-temurin:21-jre-alpine` | ~180 MB | Smallest with a shell | **musl libc** — some Java native libs (Snappy, RocksDB, LZ4) crash or run slowly. Kafka uses these. | Never for Kafka. Risky for NiFi. |
| `gcr.io/distroless/java21` | ~230 MB | Tiny attack surface; no shell = no shell exploits | **No shell** — cannot `kubectl exec` to debug. Painful. | Hardened prod, after you've debugged everything |
| `ubuntu:24.04` + manual JDK | ~500 MB | Familiar; huge package availability | Largest; more CVEs to patch | Only if you need Ubuntu-specific packages |
| `apache/nifi:2.10.0` (official) | ~1.6 GB | Zero build effort; maintained by the NiFi team | Runs as root by default in some versions; you don't control patch cadence; Docker Hub rate limits | Quick demos, not regulated production |

> 🔴 **The Alpine trap:** Alpine uses **musl** instead of **glibc**. Kafka's compression libraries (Snappy, LZ4, Zstd) ship pre-compiled against glibc. On Alpine, they either fail to load or fall back to slow pure-Java paths. You'll see 3-5× worse throughput and blame Kafka. **Do not use Alpine for Kafka.**

### Should You Build Your Own, or Use the Official Image?

| | Build Your Own | Use Official Image |
|---|---|---|
| **Effort** | High initially, low after automation | Near zero |
| **Patch speed** | You patch the day a CVE drops | Wait for upstream (days to weeks) |
| **Compliance** | You control base OS, users, SBOM | Must accept their choices |
| **Non-root** | Guaranteed | Varies by version |
| **Custom NARs/JARs** | Easy — bake them in | Need init containers or volume mounts |
| **Debugging surface** | You choose | Fixed |
| **Best for** | Regulated industries, FedRAMP, banks, healthcare | Startups, POCs, low-compliance shops |

**Middle path (very popular):** Start `FROM apache/nifi:2.10.0` and add your hardening on top.

```dockerfile
FROM apache/nifi:2.10.0
USER root
RUN apt-get update && apt-get upgrade -y && apt-get clean   # patch OS CVEs
COPY --chown=1000:1000 custom-nars/*.nar /opt/nifi/nifi-current/extensions/
USER 1000
```
Pros: much less work, still lets you patch and customize.
Cons: you inherit their base OS choice and image size.

---

<a name="4-what-is-nifi"></a>
## 4. What NiFi Actually Is

### The Post Office Analogy

NiFi is a **smart post office with conveyor belts**. You draw boxes and arrows on a web page, and data flows along them. Each box does one job:
- "Read files from S3"
- "Convert CSV to JSON"
- "Only keep records where amount > 100"
- "Send to Kafka"

You never write code. You drag, drop, and connect.

### Key Vocabulary

| Term | Plain English |
|---|---|
| **FlowFile** | One piece of data + its sticky notes (metadata/attributes). Like an envelope with labels. |
| **Processor** | One machine on the conveyor belt that does one job. |
| **Connection** | The belt between machines. It's actually a **queue** that can hold data if the next machine is busy. |
| **Process Group** | A folder of processors. Keeps big flows organized. |
| **Back Pressure** | "The next belt is full — stop sending." Prevents overload. |
| **Provenance** | A permanent recording of everything that happened to every FlowFile. Great for audits, huge on disk. |
| **NAR** | A NiFi plugin file (`.nar`). Like a browser extension. |

### The Four Repositories (These Are Your Volumes)

NiFi stores state in four separate places. **Each needs its own disk in Kubernetes:**

| Repository | Holds | Size Guide | If You Lose It |
|---|---|---|---|
| **FlowFile Repo** | Where every in-flight file *is* right now | 10–20 GB, needs **fast IOPS** | In-flight data lost. Flow design is fine. |
| **Content Repo** | The actual bytes of your data | 100 GB–2 TB, needs **throughput** | In-flight data lost. |
| **Provenance Repo** | Audit history | 50–500 GB | Audit trail lost. NiFi still runs. |
| **Database Repo** | Users, flow config, component state | 5–10 GB | 🔴 **Catastrophic.** Your flow design is gone. |

> ⚠️ **Gotcha #5:** Beginners mount one big volume for everything. Under load, provenance writes starve the flowfile repo, and throughput drops 10×. **Always use separate PersistentVolumeClaims.** The StatefulSet in Step 2.8 does this correctly.

### NiFi 2.x — What Changed From 1.x

| Change | Impact |
|---|---|
| **Java 21 required** | Java 8/11/17 images will not run NiFi 2.x. |
| **Templates removed** | Use the NiFi Registry / Flow Registry with Git instead. |
| **Many processors deleted** | Deprecated 1.x processors are gone. Flows may not import cleanly. |
| **Python processors** | You can now write processors in Python — big deal for data science teams. |
| **Stateless Process Groups** | Run a group in stateless mode for lower latency. |
| **KubernetesLeaderElectionManager** | Cluster coordination without ZooKeeper. **Use this on EKS.** |
| **Connectors (2.9+)** | New abstraction, plus Troubleshooting mode in 2.9. |
| **Restricted Component auth removed (2.10)** | Authorization model simplified — re-check your policies on upgrade. |

> 🔴 **Gotcha #6 — Migration:** A NiFi 1.x flow will not necessarily import into 2.x. Read the official **Migration Guidance for 2.10.0** on the Apache wiki before you plan an upgrade. Test in a scratch cluster first.

---

<a name="5-what-is-kafka"></a>
## 5. What Kafka Actually Is (and KRaft)

### The Bulletin Board Analogy

Kafka is a **giant bulletin board with numbered sticky notes that never get removed** (until they expire).

- **Producers** pin notes to the board.
- **Consumers** read notes, remembering "I've read up to note #4,281."
- Multiple consumers read the *same* notes independently. Reading doesn't delete them.

That last point is the magic. In a normal message queue, reading a message removes it. In Kafka, ten different teams can each read all the data at their own pace.

### Key Vocabulary

| Term | Plain English |
|---|---|
| **Topic** | A named bulletin board. e.g., `orders`, `clicks`. |
| **Partition** | The board is split into numbered columns so many people can write at once. **More partitions = more parallelism.** |
| **Offset** | The note number. "I've read up to #4,281." |
| **Broker** | One Kafka server. A cluster has several. |
| **Replication Factor** | How many copies of each partition exist. **Use 3 in production.** |
| **Controller** | The node that manages cluster metadata. |
| **KRaft** | Kafka's built-in system for controllers to agree on things. |
| **ISR** | In-Sync Replicas — copies that are fully caught up. |
| **min.insync.replicas** | How many copies must confirm a write. **Set to 2 when RF=3.** |

### KRaft: The Big 2026 Change

Historically, Kafka needed a completely separate system called **ZooKeeper** to store cluster metadata. You had to run, monitor, and debug two distributed systems.

**As of Kafka 4.0 (March 2025), ZooKeeper is completely removed.** Not deprecated — *deleted*. Kafka 4.x runs exclusively in **KRaft** mode, where dedicated controller nodes handle metadata using the Raft consensus protocol internally.

**What this means for you:**

✅ **Good news:**
- One system instead of two. Simpler images, simpler EKS manifests.
- Faster failover and startup.
- Scales to far more partitions.
- KIP-996 "Pre-Vote" reduces unnecessary leader elections from network blips.

⚠️ **Watch out:**
- **The controller is now your most critical component.** If you lose quorum, the whole cluster stops accepting metadata changes.
- **Always use an ODD number of controllers: 3 or 5.** Never 2 or 4 — an even number can deadlock in a split vote.
- Old tools that talked to ZooKeeper (`kafka-topics.sh --zookeeper`) are gone. Use `--bootstrap-server`.
- If you're migrating from an old cluster, **3.9.x is the last version supporting both modes.** You must go 3.9 → migrate to KRaft → then 4.x. You cannot jump straight from a ZooKeeper cluster to 4.x.

### Deployment Modes

| Mode | Description | Pros | Cons |
|---|---|---|---|
| **Combined** | Each node is both broker AND controller | Fewer pods, cheaper, simple | Not recommended for production; a busy broker can starve the controller |
| **Isolated** ⭐ | 3 controller pods + N broker pods | Production standard; controller stays responsive | More pods = more cost |

### Should You Even Run Kafka Yourself?

| Option | Pros | Cons | Best For |
|---|---|---|---|
| **Amazon MSK** (managed) | AWS patches it; no image building; integrated IAM auth; SLA | Higher cost; less version control; MSK lags upstream (3.9 is common there) | Teams without a platform engineer |
| **Strimzi Operator on EKS** ⭐ | Kubernetes-native; handles rolling upgrades, certs, scaling; **Strimzi 1.0 released 2026** with in-place pod resizing | You operate it; learning curve | Teams already on Kubernetes |
| **Raw StatefulSet** (this guide) | Full control; understand every piece | You handle everything: rebalance, certs, upgrades | Learning; unusual requirements |
| **Confluent Platform** | Enterprise support, extra tools | Licensing cost | Enterprises wanting a vendor |

> 💡 **Honest recommendation:** For most teams, **Strimzi** is the right answer for self-managed Kafka on EKS. This guide shows raw StatefulSets so you understand what Strimzi does for you — then use Strimzi in production.

---

<a name="6-what-is-eks"></a>
## 6. What EKS Actually Is

### The Restaurant Analogy

- **Pod** = one dish being cooked. The smallest unit. Usually one container.
- **Node** = one cook (an EC2 virtual machine). Cooks multiple dishes.
- **Cluster** = the whole kitchen.
- **Control Plane** = the head chef, deciding who cooks what. **AWS manages this for you.**
- **kubectl** = the order window where you shout requests.

**EKS = "AWS runs the head chef; you supply the cooks."**

### Node Options

| Option | What It Is | Pros | Cons |
|---|---|---|---|
| **Managed Node Groups** ⭐ | AWS-maintained EC2 group | AWS handles AMI updates & draining; simple | Less control over bootstrap |
| **EKS Auto Mode** | AWS picks and manages nodes entirely | Least operational work; auto-handles rollback of worker nodes | Newer; less control; premium cost |
| **Karpenter** | Smart autoscaler that picks the cheapest fitting instance | Big cost savings; fast scale-up; great bin-packing | Extra component to learn and run |
| **Self-managed nodes** | Your own ASG | Total control | You patch AMIs yourself |
| **Fargate** | Serverless pods, no nodes | No node management | 🔴 **No EBS support** — cannot run NiFi or Kafka |

> 🔴 **Gotcha #7:** **Fargate cannot run NiFi or Kafka.** Fargate does not support persistent EBS volumes (only EFS). Both NiFi and Kafka need block storage with low latency. Use EC2 node groups.

### Workload Types

| Type | Use For | Why |
|---|---|---|
| **Deployment** | Stateless web apps | Pods are interchangeable, random names |
| **StatefulSet** ⭐ | **NiFi and Kafka** | Stable names (`kafka-0`, `kafka-1`), stable DNS, each pod keeps its own disks across restarts |
| **DaemonSet** | One pod per node (log collectors) | Monitoring agents |
| **Job/CronJob** | Run-once or scheduled tasks | Backups, batch |

> 🔴 **Gotcha #8:** Using a **Deployment** for Kafka causes data loss. Deployment pods get random names and can be assigned a *different* volume on restart. Kafka broker identity is tied to its data directory. **StatefulSet is mandatory.**

### EKS 1.36 Notes (July 2026)

- **EKS now supports Kubernetes version rollback** (announced July 1, 2026) — you can revert to the previous minor version within **7 days** of an upgrade. This is a genuine safety net; see [Section 15](#15-rollback).
- **1.33 standard support ends July 29, 2026.** If you're on it, plan now.
- **Ingress NGINX was retired** by upstream Kubernetes in March 2026. No further bug fixes or security patches. Migrate to **Gateway API** or a third-party controller — none are drop-in replacements.
- **AL2 AMIs stopped at 1.32.** Use AL2023 or Bottlerocket.
- **VolumeAttributesClass is GA in 1.34+**. AWS patched CSI sidecars for the beta API only until 1.33 support ends (July 29, 2026).

---

# PART 3 — THE THREE WAYS TO BUILD

<a name="7-option-a-cli"></a>
## 7. Option A: AWS CLI (Manual)

### What It Is
You type commands one at a time. Direct, immediate, no abstraction.

### Complete Working Example

```bash
#!/usr/bin/env bash
# build-and-push.sh — CLI approach, end to end
set -euo pipefail

AWS_REGION="us-east-1"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
APP="${1:?Usage: $0 <nifi|kafka> <version>}"
VERSION="${2:?Usage: $0 <nifi|kafka> <version>}"
BUILD_NUM="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
TAG="${VERSION}-build.${BUILD_NUM}"
REPO="data-platform/${APP}"

echo "═══ 1/6 Ensure repository exists ═══"
aws ecr describe-repositories --repository-names "${REPO}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository \
       --repository-name "${REPO}" --region "${AWS_REGION}" \
       --image-scanning-configuration scanOnPush=true \
       --image-tag-mutability IMMUTABLE \
       --encryption-configuration encryptionType=AES256

echo "═══ 2/6 Login to ECR ═══"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo "═══ 3/6 Build (linux/amd64) ═══"
docker buildx build \
  --platform linux/amd64 \
  --build-arg "$(echo ${APP} | tr a-z A-Z)_VERSION=${VERSION}" \
  --provenance=true --sbom=true \
  -t "${REGISTRY}/${REPO}:${TAG}" \
  --load "./${APP}"

echo "═══ 4/6 Push ═══"
docker push "${REGISTRY}/${REPO}:${TAG}"

echo "═══ 5/6 Wait for vulnerability scan ═══"
aws ecr wait image-scan-complete \
  --repository-name "${REPO}" --image-id imageTag="${TAG}" --region "${AWS_REGION}"

FINDINGS=$(aws ecr describe-image-scan-findings \
  --repository-name "${REPO}" --image-id imageTag="${TAG}" --region "${AWS_REGION}" \
  --query 'imageScanFindings.findingSeverityCounts' --output json)
echo "Findings: ${FINDINGS}"

CRITICAL=$(echo "${FINDINGS}" | jq -r '.CRITICAL // 0')
if [[ "${CRITICAL}" -gt 0 ]]; then
  echo "❌ BLOCKED: ${CRITICAL} CRITICAL vulnerabilities found."
  exit 1
fi

echo "═══ 6/6 Capture immutable digest ═══"
DIGEST=$(aws ecr describe-images \
  --repository-name "${REPO}" --image-ids imageTag="${TAG}" --region "${AWS_REGION}" \
  --query 'imageDetails[0].imageDigest' --output text)

echo "✅ SUCCESS"
echo "   Tag:    ${REGISTRY}/${REPO}:${TAG}"
echo "   Digest: ${REGISTRY}/${REPO}@${DIGEST}"
echo "${REGISTRY}/${REPO}@${DIGEST}" > ".last-image-${APP}"
```

### Set a Lifecycle Policy (Stop Paying for Old Images)

```bash
cat > lifecycle.json << 'EOF'
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Keep last 10 release images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["2.", "4."],
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Delete untagged images after 7 days",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 7
      },
      "action": { "type": "expire" }
    }
  ]
}
EOF

aws ecr put-lifecycle-policy \
  --repository-name data-platform/nifi \
  --lifecycle-policy-text file://lifecycle.json \
  --region "${AWS_REGION}"
```

### Pros & Cons

| ✅ Pros | ❌ Cons |
|---|---|
| Instant feedback — see errors immediately | **No state tracking** — AWS doesn't know what you intended |
| Zero extra tools to learn | **Not repeatable** — humans forget flags |
| Perfect for debugging and exploration | **Configuration drift** — dev and prod diverge silently |
| Easy to script incrementally | **No plan/preview** — you find out after it's broken |
| Best docs and examples online | Hard to code-review a terminal session |
| Great for one-off emergency fixes | No automatic dependency ordering |

**Verdict:** ⭐ Use for **learning, debugging, and emergencies.** Never as your production deployment method.

---

<a name="8-option-b-terraform"></a>
## 8. Option B: Terraform (Infrastructure as Code)

### What It Is
You write a file describing what you *want*. Terraform figures out how to get there, remembers what it made in a **state file**, and shows you a **plan** before changing anything.

### The Blueprint Analogy
The AWS CLI is telling a builder "hammer this nail, now that one." Terraform is handing them a blueprint and letting them figure out the order. Next month you change the blueprint and they only fix the differences.

### Project Structure

```
terraform/
├── versions.tf         # tool + provider versions
├── backend.tf          # where state is stored
├── variables.tf        # inputs
├── ecr.tf              # registries
├── eks.tf              # cluster + nodes
├── irsa.tf             # pod IAM permissions
├── outputs.tf          # what to print
└── envs/
    ├── dev.tfvars
    └── prod.tfvars
```

### `versions.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.60" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.14" }
  }
}
```

> 💡 `~> 5.60` means "5.60 or newer, but not 6.0." This prevents a major version bump from breaking you overnight.

### `backend.tf` — CRITICAL

```hcl
terraform {
  backend "s3" {
    bucket         = "my-org-terraform-state"
    key            = "data-platform/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true    # S3-native locking (TF 1.10+); replaces DynamoDB
  }
}
```

> 🔴 **Gotcha #9:** If you leave state on your laptop (the default), and two people run `terraform apply` simultaneously, **you can destroy production.** Always use a remote backend with locking. Enable S3 versioning on the state bucket so you can recover a corrupted state file.

### `ecr.tf`

```hcl
locals {
  repositories = ["data-platform/nifi", "data-platform/kafka"]
}

resource "aws_ecr_repository" "images" {
  for_each             = toset(local.repositories)
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration     { encryption_type = "AES256" }

  tags = { Project = "data-platform", ManagedBy = "terraform" }
}

resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = aws_ecr_repository.images
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 15 tagged images"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 15
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

### `eks.tf`

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = var.environment == "dev"   # save $$ in dev
  enable_dns_hostnames = true

  # These tags are REQUIRED for load balancers to work
  public_subnet_tags  = { "kubernetes.io/role/elb"          = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.allowed_cidrs   # LOCK THIS DOWN
  enable_irsa                          = true

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true, before_compute = true }
    aws-ebs-csi-driver     = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = 100
    ebs_optimized  = true
  }

  eks_managed_node_groups = {
    # Dedicated nodes for data workloads
    data = {
      min_size       = 3
      max_size       = 9
      desired_size   = 3
      instance_types = ["m6i.2xlarge"]
      capacity_type  = "ON_DEMAND"     # never SPOT for Kafka brokers

      labels = { workload = "data-platform" }

      # Taint keeps other apps off these expensive nodes
      taints = [{
        key    = "workload"
        value  = "data-platform"
        effect = "NO_SCHEDULE"
      }]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }

    # Cheap nodes for everything else
    general = {
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      instance_types = ["m6i.large"]
      capacity_type  = "SPOT"          # fine for stateless
    }
  }
}
```

### `irsa.tf` — Pod Permissions Without Secret Keys

```hcl
# Lets a NiFi pod read/write a specific S3 bucket, with NO access keys
module "nifi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-nifi"

  role_policy_arns = { s3 = aws_iam_policy.nifi_s3.arn }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["data-platform:nifi"]
    }
  }
}

resource "aws_iam_policy" "nifi_s3" {
  name = "${var.cluster_name}-nifi-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
      Resource = [
        "arn:aws:s3:::${var.data_bucket}",
        "arn:aws:s3:::${var.data_bucket}/*"
      ]
    }]
  })
}
```

### Running It

```bash
cd terraform
terraform init
terraform fmt -recursive
terraform validate

# ALWAYS plan first, and SAVE the plan
terraform plan -var-file=envs/prod.tfvars -out=tfplan

# Read the plan carefully. Look for "destroy" lines.
terraform show tfplan | grep -E "will be (destroyed|replaced)"

# Apply the EXACT plan you reviewed
terraform apply tfplan
```

> 🔴 **Gotcha #10:** `terraform apply` without a saved plan file re-plans at apply time. Something may have changed in between. **Always `-out=tfplan` then `apply tfplan`.**

### Pros & Cons

| ✅ Pros | ❌ Cons |
|---|---|
| **Plan before apply** — see exactly what changes | **State file is fragile** — corrupt it and you're in trouble |
| Full history in Git; peer-reviewable | Steep learning curve (HCL, modules, providers) |
| Handles dependency order automatically | Slow for small changes (`plan` takes minutes) |
| Same code → dev, staging, prod | **Drift**: someone clicks in the console, TF wants to undo it |
| Huge module ecosystem | Provider bugs can block you |
| `terraform destroy` cleans up completely | Not great for *inside*-the-cluster app config |

**Verdict:** ⭐⭐⭐ **The right tool for AWS infrastructure** — VPC, EKS, ECR, IAM. Less ideal for application configuration inside Kubernetes.

---

<a name="9-option-c-ansible"></a>
## 9. Option C: Ansible (Configuration Management)

### What It Is
Ansible runs a **list of tasks in order**. Each task is *idempotent* — running it twice does nothing the second time. It's excellent at **procedures**: build, then scan, then push, then deploy, then verify.

### The Recipe Analogy
Terraform is a blueprint ("the house should look like this"). Ansible is a recipe ("preheat oven, mix flour, bake 20 minutes"). Some jobs are blueprints; some are recipes. Building an image is a recipe.

### Project Structure

```
ansible/
├── ansible.cfg
├── inventory/hosts.yml
├── group_vars/all.yml
├── build-images.yml
├── deploy-eks.yml
└── roles/
    ├── image_build/tasks/main.yml
    └── k8s_deploy/tasks/main.yml
```

### `ansible.cfg`

```ini
[defaults]
inventory       = inventory/hosts.yml
host_key_checking = False
stdout_callback = yaml
retry_files_enabled = False
interpreter_python = auto_silent
```

### `group_vars/all.yml`

```yaml
aws_region: us-east-1
cluster_name: data-platform
k8s_namespace: data-platform

nifi_version: "2.10.0"
kafka_version: "4.3.0"
scala_version: "2.13"

build_number: "{{ lookup('env', 'BUILD_NUMBER') | default(ansible_date_time.epoch, true) }}"
target_platform: "linux/amd64"
```

### `build-images.yml`

```yaml
---
- name: Build and publish NiFi & Kafka images to ECR
  hosts: localhost
  connection: local
  gather_facts: true

  vars:
    apps:
      - { name: nifi,  version: "{{ nifi_version }}",  context: ../nifi }
      - { name: kafka, version: "{{ kafka_version }}", context: ../kafka }

  tasks:
    # ── 1. Discover account ──
    - name: Get AWS account ID
      amazon.aws.aws_caller_info:
      register: caller

    - name: Set registry URL
      ansible.builtin.set_fact:
        ecr_registry: "{{ caller.account }}.dkr.ecr.{{ aws_region }}.amazonaws.com"

    # ── 2. Ensure ECR repositories exist (idempotent) ──
    - name: Create ECR repositories
      amazon.aws.ecs_ecr:
        name: "data-platform/{{ item.name }}"
        region: "{{ aws_region }}"
        image_tag_mutability: IMMUTABLE
        scan_on_push: true
        state: present
      loop: "{{ apps }}"
      loop_control: { label: "{{ item.name }}" }

    # ── 3. Log in to ECR ──
    - name: Fetch ECR auth token
      ansible.builtin.command:
        cmd: aws ecr get-login-password --region {{ aws_region }}
      register: ecr_token
      changed_when: false
      no_log: true              # don't print the password to logs

    - name: Docker login
      community.docker.docker_login:
        registry_url: "{{ ecr_registry }}"
        username: AWS
        password: "{{ ecr_token.stdout }}"
      no_log: true

    # ── 4. Build ──
    - name: Build images
      community.docker.docker_image:
        name: "{{ ecr_registry }}/data-platform/{{ item.name }}"
        tag: "{{ item.version }}-build.{{ build_number }}"
        build:
          path: "{{ item.context }}"
          platform: "{{ target_platform }}"
          pull: true            # always refresh the base image
          args:
            "{{ item.name | upper }}_VERSION": "{{ item.version }}"
        source: build
        force_source: true
      loop: "{{ apps }}"
      loop_control: { label: "{{ item.name }}" }

    # ── 5. Push ──
    - name: Push images to ECR
      community.docker.docker_image:
        name: "{{ ecr_registry }}/data-platform/{{ item.name }}"
        tag: "{{ item.version }}-build.{{ build_number }}"
        push: true
        source: local
      loop: "{{ apps }}"
      loop_control: { label: "{{ item.name }}" }

    # ── 6. Wait for scan and enforce a security gate ──
    - name: Wait for ECR scan to complete
      ansible.builtin.command:
        cmd: >
          aws ecr wait image-scan-complete
          --repository-name data-platform/{{ item.name }}
          --image-id imageTag={{ item.version }}-build.{{ build_number }}
          --region {{ aws_region }}
      loop: "{{ apps }}"
      changed_when: false

    - name: Get scan findings
      ansible.builtin.command:
        cmd: >
          aws ecr describe-image-scan-findings
          --repository-name data-platform/{{ item.name }}
          --image-id imageTag={{ item.version }}-build.{{ build_number }}
          --region {{ aws_region }}
          --query imageScanFindings.findingSeverityCounts --output json
      loop: "{{ apps }}"
      register: scans
      changed_when: false

    - name: FAIL if any CRITICAL vulnerabilities
      ansible.builtin.fail:
        msg: "CRITICAL CVEs in {{ item.item.name }}: {{ item.stdout }}"
      when: (item.stdout | from_json).CRITICAL | default(0) | int > 0
      loop: "{{ scans.results }}"
      loop_control: { label: "{{ item.item.name }}" }

    # ── 7. Record immutable digests ──
    - name: Resolve digests
      ansible.builtin.command:
        cmd: >
          aws ecr describe-images
          --repository-name data-platform/{{ item.name }}
          --image-ids imageTag={{ item.version }}-build.{{ build_number }}
          --region {{ aws_region }}
          --query imageDetails[0].imageDigest --output text
      loop: "{{ apps }}"
      register: digests
      changed_when: false

    - name: Write manifest file
      ansible.builtin.copy:
        dest: "./image-manifest.yml"
        mode: "0644"
        content: |
          # Generated {{ ansible_date_time.iso8601 }}
          {% for d in digests.results %}
          {{ d.item.name }}: "{{ ecr_registry }}/data-platform/{{ d.item.name }}@{{ d.stdout }}"
          {% endfor %}

    - name: Show results
      ansible.builtin.debug:
        msg: "{{ lookup('file', './image-manifest.yml') }}"
```

### `deploy-eks.yml`

```yaml
---
- name: Deploy to EKS
  hosts: localhost
  connection: local

  vars_files:
    - ./image-manifest.yml

  tasks:
    - name: Update kubeconfig
      ansible.builtin.command:
        cmd: aws eks update-kubeconfig --name {{ cluster_name }} --region {{ aws_region }}
      changed_when: false

    - name: Ensure namespace exists
      kubernetes.core.k8s:
        api_version: v1
        kind: Namespace
        name: "{{ k8s_namespace }}"
        state: present

    - name: Apply manifests with digest substitution
      kubernetes.core.k8s:
        state: present
        namespace: "{{ k8s_namespace }}"
        definition: "{{ lookup('template', item) | from_yaml_all | list }}"
      loop:
        - templates/nifi-statefulset.yaml.j2
        - templates/kafka-statefulset.yaml.j2

    - name: Wait for NiFi rollout
      kubernetes.core.k8s_info:
        kind: StatefulSet
        name: nifi
        namespace: "{{ k8s_namespace }}"
      register: sts
      until: >
        sts.resources[0].status.readyReplicas | default(0)
        == sts.resources[0].spec.replicas
      retries: 60
      delay: 20

    - name: Smoke test the API
      ansible.builtin.command:
        cmd: >
          kubectl -n {{ k8s_namespace }} exec nifi-0 --
          curl -sf -k https://localhost:8443/nifi-api/system-diagnostics
      changed_when: false
      register: smoke
      failed_when: smoke.rc != 0
```

### Running It

```bash
cd ansible

# Dry run — shows what WOULD change
ansible-playbook build-images.yml --check --diff

# Real run
ansible-playbook build-images.yml
ansible-playbook deploy-eks.yml

# Run only part of it
ansible-playbook build-images.yml --tags build
```

### Pros & Cons

| ✅ Pros | ❌ Cons |
|---|---|
| **YAML is readable** — easier than HCL for beginners | **No state file** — can't detect drift or clean up |
| Excellent for **procedures** (build → scan → push → verify) | No `terraform destroy` equivalent |
| Agentless — just SSH/API, nothing to install on targets | `--check` mode is unreliable for some modules |
| Great for hybrid (EC2 + Kubernetes + on-prem) | Slower than Terraform for large infra |
| Easy to add conditional logic and loops | Weak dependency graph — you manage order manually |
| Huge module library | Debugging Jinja2 templating errors is painful |

**Verdict:** ⭐⭐ **Best for the build pipeline and app deployment.** Weaker than Terraform for creating VPCs/clusters.

---

<a name="10-decision-matrix"></a>
## 10. Which Should You Pick? Decision Matrix

### The Honest Answer: Use All Three, For Different Jobs

```
┌─────────────────────────────────────────────────────────┐
│  TERRAFORM                                              │
│  → VPC, EKS cluster, ECR repos, IAM roles, node groups  │
│  Runs: rarely (weekly/monthly)                          │
└─────────────────────────────────────────────────────────┘
                          ↓ outputs
┌─────────────────────────────────────────────────────────┐
│  ANSIBLE                                                │
│  → Build images, scan, push, deploy manifests, verify   │
│  Runs: often (every commit)                             │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  AWS CLI / kubectl                                      │
│  → Debugging, emergencies, one-off investigation        │
│  Runs: when something is on fire                        │
└─────────────────────────────────────────────────────────┘
```

### Task-by-Task Recommendation

| Task | Best Tool | Second Choice | Never |
|---|---|---|---|
| Create VPC | **Terraform** | CloudFormation | CLI (too many resources) |
| Create EKS cluster | **Terraform** | eksctl | CLI |
| Create ECR repo | **Terraform** | Ansible | — |
| Build container image | **Ansible** or CI | CLI script | Terraform ❌ |
| Push to ECR | **Ansible** or CI | CLI script | Terraform ❌ |
| Deploy K8s manifests | **Helm/Argo CD** | Ansible | Terraform ⚠️ |
| Rolling app update | **kubectl/Argo CD** | Ansible | Terraform ❌ |
| Patch node AMIs | **Terraform** (managed NG) | eksctl | — |
| Emergency rollback | **kubectl** | Ansible | Terraform (too slow) |
| Investigate a crash | **kubectl/CLI** | — | — |

> 🔴 **Anti-pattern:** Using Terraform to manage individual Kubernetes Deployments. Terraform's state model fights Kubernetes' controller model. Every `terraform plan` shows spurious diffs because Kubernetes mutates objects (adds annotations, status fields). Use **Helm** or **Argo CD** for in-cluster resources.

### Comparison Table

| Criterion | AWS CLI | Terraform | Ansible |
|---|---|---|---|
| Learning curve | 🟢 Easy | 🔴 Hard | 🟡 Medium |
| Repeatability | 🔴 Poor | 🟢 Excellent | 🟢 Good |
| Preview changes | 🔴 None | 🟢 `plan` | 🟡 `--check` (partial) |
| Drift detection | 🔴 None | 🟢 Yes | 🔴 None |
| Speed (small change) | 🟢 Seconds | 🔴 Minutes | 🟡 Tens of seconds |
| Teardown | 🔴 Manual | 🟢 `destroy` | 🔴 Manual |
| Procedural logic | 🟡 Bash | 🔴 Awkward | 🟢 Natural |
| K8s app deploys | 🟡 kubectl | 🔴 Poor | 🟢 Good |
| Secrets handling | 🟡 Manual | 🔴 State stores secrets in plaintext! | 🟢 Vault integration |
| Team collaboration | 🔴 Poor | 🟢 Excellent | 🟢 Good |

> 🔴 **Gotcha #11 — Terraform stores secrets in plaintext in state.** If you create an RDS password or a Kubernetes Secret via Terraform, the value sits unencrypted in your state file. Encrypt the S3 bucket, restrict access tightly, and prefer AWS Secrets Manager with `ignore_changes` on the value.

---

# PART 4 — PRODUCTION HARDENING

<a name="11-kafka-image"></a>
## 11. Building the Kafka Image (Full Detail)

### `kafka/Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7

# ══════════════════════════════════════════════════════════
# STAGE 1: download + verify
# ══════════════════════════════════════════════════════════
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS builder

ARG KAFKA_VERSION=4.3.0
ARG SCALA_VERSION=2.13

RUN dnf install -y tar gzip gnupg2 findutils && dnf clean all
WORKDIR /build

RUN curl -fSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" -o kafka.tgz \
 && curl -fSL "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz.sha512" -o kafka.tgz.sha512

# Verify integrity — non-negotiable
RUN echo "$(awk '{print $NF}' kafka.tgz.sha512)  kafka.tgz" | sha512sum -c -

RUN tar -xzf kafka.tgz \
 && mv "kafka_${SCALA_VERSION}-${KAFKA_VERSION}" /build/kafka \
 && rm -rf /build/kafka/site-docs \
 # Remove Windows batch scripts — dead weight on Linux
 && rm -rf /build/kafka/bin/windows

# ══════════════════════════════════════════════════════════
# STAGE 2: runtime
# ══════════════════════════════════════════════════════════
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless

ARG KAFKA_VERSION=4.3.0
LABEL org.opencontainers.image.title="apache-kafka" \
      org.opencontainers.image.version="${KAFKA_VERSION}"

ENV KAFKA_HOME=/opt/kafka \
    PATH="/opt/kafka/bin:${PATH}" \
    JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto

# gcompat NOT needed here because we're on glibc (AL2023), which is
# exactly why we avoid Alpine — Kafka's Snappy/LZ4/Zstd native libs
# are compiled against glibc.
RUN dnf install -y shadow-utils procps-ng jq gzip tar && dnf clean all \
 && groupadd -g 1000 kafka \
 && useradd -u 1000 -g 1000 -m -d /home/kafka -s /sbin/nologin kafka

COPY --from=builder --chown=1000:1000 /build/kafka ${KAFKA_HOME}

RUN mkdir -p /var/lib/kafka/data /var/log/kafka \
 && chown -R 1000:1000 /var/lib/kafka /var/log/kafka ${KAFKA_HOME}

COPY --chown=1000:1000 kafka-entrypoint.sh /opt/kafka-entrypoint.sh
RUN chmod 0755 /opt/kafka-entrypoint.sh

USER 1000:1000
WORKDIR ${KAFKA_HOME}

EXPOSE 9092 9093 9094 9404

ENTRYPOINT ["/opt/kafka-entrypoint.sh"]
```

### `kafka/kafka-entrypoint.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

KAFKA_HOME="${KAFKA_HOME:-/opt/kafka}"
DATA_DIR="${KAFKA_DATA_DIR:-/var/lib/kafka/data}"
CONFIG="${KAFKA_HOME}/config/server.properties"

log() { echo "[kafka-entrypoint] $(date -u +%FT%TZ) $*"; }

# ══ Derive node ID from the StatefulSet pod ordinal ══
# Pod "kafka-broker-2" → ordinal 2 → node.id 102
# This is why StatefulSets matter: the name is STABLE.
POD_NAME="${HOSTNAME}"
ORDINAL="${POD_NAME##*-}"

ROLE="${KAFKA_ROLE:-broker}"        # broker | controller | broker,controller
NODE_ID_BASE="${KAFKA_NODE_ID_BASE:-0}"
NODE_ID=$(( NODE_ID_BASE + ORDINAL ))

log "Pod=${POD_NAME} ordinal=${ORDINAL} role=${ROLE} node.id=${NODE_ID}"

POD_FQDN="${POD_NAME}.${KAFKA_HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.cluster.local"

# ══ Build server.properties from scratch ══
cat > "${CONFIG}" <<EOF
# ── KRaft identity ──
process.roles=${ROLE}
node.id=${NODE_ID}
controller.quorum.voters=${KAFKA_CONTROLLER_QUORUM_VOTERS}

# ── Listeners ──
listeners=${KAFKA_LISTENERS}
advertised.listeners=${KAFKA_ADVERTISED_LISTENERS:-PLAINTEXT://${POD_FQDN}:9092}
listener.security.protocol.map=${KAFKA_LISTENER_SECURITY_PROTOCOL_MAP:-PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT}
controller.listener.names=CONTROLLER
inter.broker.listener.name=${KAFKA_INTER_BROKER_LISTENER_NAME:-PLAINTEXT}

# ── Storage ──
log.dirs=${DATA_DIR}

# ── Durability (production defaults) ──
default.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR:-3}
min.insync.replicas=${KAFKA_MIN_INSYNC_REPLICAS:-2}
offsets.topic.replication.factor=${KAFKA_OFFSETS_TOPIC_RF:-3}
transaction.state.log.replication.factor=${KAFKA_TXN_LOG_RF:-3}
transaction.state.log.min.isr=${KAFKA_TXN_LOG_MIN_ISR:-2}
unclean.leader.election.enable=false

# ── Performance ──
num.network.threads=${KAFKA_NUM_NETWORK_THREADS:-8}
num.io.threads=${KAFKA_NUM_IO_THREADS:-16}
num.partitions=${KAFKA_NUM_PARTITIONS:-6}
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600

# ── Retention ──
log.retention.hours=${KAFKA_LOG_RETENTION_HOURS:-168}
log.segment.bytes=${KAFKA_LOG_SEGMENT_BYTES:-1073741824}
log.retention.check.interval.ms=300000

auto.create.topics.enable=${KAFKA_AUTO_CREATE_TOPICS:-false}
EOF

log "Generated server.properties"

# ══ Format storage ONCE, only if empty ══
# The CLUSTER_ID must be IDENTICAL across every node, forever.
if [[ ! -f "${DATA_DIR}/meta.properties" ]]; then
  log "Formatting storage with cluster.id=${KAFKA_CLUSTER_ID}"
  "${KAFKA_HOME}/bin/kafka-storage.sh" format \
    --cluster-id "${KAFKA_CLUSTER_ID}" \
    --config "${CONFIG}" \
    --ignore-formatted
else
  log "Storage already formatted — skipping"
  EXISTING_ID=$(grep -E '^cluster\.id=' "${DATA_DIR}/meta.properties" | cut -d= -f2 || echo "")
  if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" != "${KAFKA_CLUSTER_ID}" ]]; then
    log "FATAL: disk cluster.id=${EXISTING_ID} but env says ${KAFKA_CLUSTER_ID}"
    log "This volume belongs to a DIFFERENT cluster. Refusing to start."
    exit 1
  fi
fi

# ══ Heap sizing ══
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms4G -Xmx4G}"
export KAFKA_JVM_PERFORMANCE_OPTS="${KAFKA_JVM_PERFORMANCE_OPTS:--XX:+UseG1GC -XX:MaxGCPauseMillis=20 -XX:InitiatingHeapOccupancyPercent=35 -XX:+ExplicitGCInvokesConcurrent}"

log "Starting Kafka ${ROLE} node ${NODE_ID}"
exec "${KAFKA_HOME}/bin/kafka-server-start.sh" "${CONFIG}"
```

> 🔴 **Gotcha #12 — The Kafka heap myth:** Do **not** give Kafka a huge heap. Kafka relies on the **OS page cache** for read performance. A 4–6 GB heap on a 32 GB node is correct — the remaining 26 GB becomes page cache. Giving Kafka a 24 GB heap makes it *slower*, not faster.

> 🔴 **Gotcha #13 — CLUSTER_ID:** Every node must format with the same cluster ID. Generate it **once**:
> ```bash
> docker run --rm <your-kafka-image> kafka-storage.sh random-uuid
> ```
> Store it in a Kubernetes ConfigMap or Secret. If node 3 formats with a different ID, it will never join.

### Kafka StatefulSet (Isolated KRaft Mode)

`k8s/kafka-statefulset.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-cluster-config
  namespace: data-platform
data:
  # Generate ONCE with: kafka-storage.sh random-uuid
  cluster-id: "MkU3OEVBNTcwNTJENDM2Qk"
  # 3 controllers, format: nodeId@host:port
  controller-quorum-voters: "1@kafka-controller-0.kafka-controller-headless.data-platform.svc.cluster.local:9093,2@kafka-controller-1.kafka-controller-headless.data-platform.svc.cluster.local:9093,3@kafka-controller-2.kafka-controller-headless.data-platform.svc.cluster.local:9093"
---
# ══════════ CONTROLLERS (the brain — always 3 or 5) ══════════
apiVersion: v1
kind: Service
metadata:
  name: kafka-controller-headless
  namespace: data-platform
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: { app: kafka, role: controller }
  ports:
    - { name: controller, port: 9093 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka-controller
  namespace: data-platform
spec:
  serviceName: kafka-controller-headless
  replicas: 3                      # ODD NUMBER. Always.
  podManagementPolicy: Parallel
  selector:
    matchLabels: { app: kafka, role: controller }
  template:
    metadata:
      labels: { app: kafka, role: controller }
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true

      tolerations:
        - { key: workload, value: data-platform, effect: NoSchedule }

      # Spread controllers across Availability Zones
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: kafka, role: controller }

      containers:
        - name: kafka
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/data-platform/kafka:4.3.0-build.1
          env:
            - name: POD_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: KAFKA_HEADLESS_SERVICE
              value: "kafka-controller-headless"
            - name: KAFKA_ROLE
              value: "controller"
            - name: KAFKA_NODE_ID_BASE
              value: "1"            # controllers = 1,2,3
            - name: KAFKA_LISTENERS
              value: "CONTROLLER://0.0.0.0:9093"
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: "CONTROLLER:PLAINTEXT"
            - name: KAFKA_CLUSTER_ID
              valueFrom: { configMapKeyRef: { name: kafka-cluster-config, key: cluster-id } }
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              valueFrom: { configMapKeyRef: { name: kafka-cluster-config, key: controller-quorum-voters } }
            - name: KAFKA_HEAP_OPTS
              value: "-Xms1G -Xmx1G"    # controllers need very little heap

          ports:
            - { name: controller, containerPort: 9093 }

          resources:
            requests: { cpu: "1", memory: "2Gi" }
            limits:   { cpu: "2", memory: "2Gi" }

          volumeMounts:
            - { name: data, mountPath: /var/lib/kafka/data }

          readinessProbe:
            tcpSocket: { port: 9093 }
            initialDelaySeconds: 20
            periodSeconds: 10

  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 20Gi } }
---
# ══════════ BROKERS (the muscle) ══════════
apiVersion: v1
kind: Service
metadata:
  name: kafka-broker-headless
  namespace: data-platform
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector: { app: kafka, role: broker }
  ports:
    - { name: plaintext, port: 9092 }
---
apiVersion: v1
kind: Service
metadata:
  name: kafka                       # what clients connect to
  namespace: data-platform
spec:
  type: ClusterIP
  selector: { app: kafka, role: broker }
  ports:
    - { name: plaintext, port: 9092 }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kafka-broker-pdb
  namespace: data-platform
spec:
  maxUnavailable: 1                 # never take down 2 brokers at once
  selector:
    matchLabels: { app: kafka, role: broker }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka-broker
  namespace: data-platform
spec:
  serviceName: kafka-broker-headless
  replicas: 3
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
    rollingUpdate: { partition: 0 }
  selector:
    matchLabels: { app: kafka, role: broker }
  template:
    metadata:
      labels: { app: kafka, role: broker }
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true

      terminationGracePeriodSeconds: 120

      tolerations:
        - { key: workload, value: data-platform, effect: NoSchedule }

      # Never put two brokers on the same node
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels: { app: kafka, role: broker }

      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: { app: kafka, role: broker }

      containers:
        - name: kafka
          image: <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/data-platform/kafka:4.3.0-build.1
          env:
            - name: POD_NAMESPACE
              valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
            - name: KAFKA_HEADLESS_SERVICE
              value: "kafka-broker-headless"
            - name: KAFKA_ROLE
              value: "broker"
            - name: KAFKA_NODE_ID_BASE
              value: "101"          # brokers = 101,102,103 (no clash with controllers)
            - name: KAFKA_LISTENERS
              value: "PLAINTEXT://0.0.0.0:9092"
            - name: KAFKA_CLUSTER_ID
              valueFrom: { configMapKeyRef: { name: kafka-cluster-config, key: cluster-id } }
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              valueFrom: { configMapKeyRef: { name: kafka-cluster-config, key: controller-quorum-voters } }
            - name: KAFKA_HEAP_OPTS
              value: "-Xms4G -Xmx4G"   # small heap, big page cache
            - name: KAFKA_DEFAULT_REPLICATION_FACTOR
              value: "3"
            - name: KAFKA_MIN_INSYNC_REPLICAS
              value: "2"

          ports:
            - { name: plaintext, containerPort: 9092 }

          resources:
            requests: { cpu: "2", memory: "16Gi" }
            limits:   { cpu: "4", memory: "16Gi" }

          volumeMounts:
            - { name: data, mountPath: /var/lib/kafka/data }

          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1"
            initialDelaySeconds: 45
            periodSeconds: 15
            timeoutSeconds: 10
            failureThreshold: 4

          livenessProbe:
            tcpSocket: { port: 9092 }
            initialDelaySeconds: 60
            periodSeconds: 20
            failureThreshold: 5

  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: gp3
        resources: { requests: { storage: 500Gi } }
```

### Verify Kafka Works

```bash
kubectl -n data-platform exec -it kafka-broker-0 -- bash

# List cluster metadata
kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status

# Create a topic
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic test-topic --partitions 6 --replication-factor 3

# Produce
echo "hello world" | kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic test-topic

# Consume
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic test-topic --from-beginning --max-messages 1
```

---

<a name="12-nifi-image"></a>
## 12. Building the NiFi Image (Full Detail)

### Adding Custom Plugins (NARs)

```dockerfile
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless
# ... base setup as before ...

# Bake custom NARs into the image (best practice — immutable)
COPY --chown=1000:1000 custom-nars/*.nar ${NIFI_HOME}/extensions/

# Add the JDBC drivers your flows need
COPY --chown=1000:1000 drivers/postgresql-42.7.4.jar ${NIFI_HOME}/lib/
COPY --chown=1000:1000 drivers/redshift-jdbc42-2.1.0.30.jar ${NIFI_HOME}/lib/
```

| Approach | Pros | Cons |
|---|---|---|
| **Bake into image** ⭐ | Immutable; version-controlled; fast pod start | Rebuild needed for any driver change |
| ConfigMap mount | Change without rebuild | Size limit ~1 MB — too small for JARs |
| Init container from S3 | Update drivers independently | Slower start; a runtime dependency on S3 |
| PVC shared library dir | Flexible | Hard to version; drift between pods |

### NiFi Clustering on EKS

Set `NIFI_CLUSTERED=true` and scale to 3 replicas. NiFi 2.x can use the **KubernetesLeaderElectionManager**, which uses Kubernetes Leases instead of ZooKeeper.

**Required RBAC** — without this, leader election silently fails:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nifi
  namespace: data-platform
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<ACCOUNT_ID>:role/data-platform-nifi
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nifi-leader-election
  namespace: data-platform
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "create", "list", "update", "delete"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "create", "list", "update", "delete", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nifi-leader-election
  namespace: data-platform
subjects:
  - kind: ServiceAccount
    name: nifi
    namespace: data-platform
roleRef:
  kind: Role
  name: nifi-leader-election
  apiGroup: rbac.authorization.k8s.io
```

Then add to the StatefulSet pod spec:
```yaml
      serviceAccountName: nifi
```

> 🔴 **Gotcha #14 — Scaling NiFi down loses data.** When a NiFi cluster node is removed, any FlowFiles queued *on that node* are stranded on its PVC. Before scaling down, **offload the node** through the NiFi UI (Cluster → Disconnect → Offload) so it hands its data to the survivors. There is no automatic version of this. Never just `kubectl scale --replicas=2`.

### Sizing Guide

| Workload | Nodes | CPU/pod | RAM/pod | Heap | Content Repo |
|---|---|---|---|---|---|
| Dev / learning | 1 | 2 | 8 Gi | 4g | 50 Gi |
| Small prod (<1 TB/day) | 3 | 4 | 16 Gi | 8g | 200 Gi |
| Medium (1–10 TB/day) | 5 | 8 | 32 Gi | 16g | 500 Gi |
| Large (>10 TB/day) | 8+ | 16 | 64 Gi | 31g | 1 Ti+ |

> 💡 **Never set NiFi heap above 31 GB.** Above ~32 GB, the JVM turns off "compressed ordinary object pointers" (CompressedOops) and you effectively *lose* memory. 31g is the sweet spot ceiling.

---

<a name="13-eks-deployment"></a>
## 13. Deploying to EKS: Pods, Nodes, StatefulSets

### The Deployment Pipeline

```
git push
   ↓
CI builds image (Ansible/GitHub Actions)
   ↓
ECR scan gate — CRITICAL CVEs block
   ↓
Push, capture DIGEST
   ↓
Update manifest with digest
   ↓
kubectl apply / Argo CD sync
   ↓
Rolling update, one pod at a time
   ↓
Readiness probes gate each step
   ↓
Smoke tests
   ↓
✅ or ROLLBACK
```

### Node Group Strategy

| Node Group | Instance | Capacity | Purpose | Taint |
|---|---|---|---|---|
| `controllers` | m6i.large | ON_DEMAND | Kafka controllers | `workload=kafka-ctrl:NoSchedule` |
| `data` | m6i.2xlarge | ON_DEMAND | Kafka brokers, NiFi | `workload=data-platform:NoSchedule` |
| `general` | m6i.large | SPOT | Monitoring, tooling | none |

> 🔴 **Gotcha #15 — Never use Spot for Kafka brokers or NiFi.** Spot instances get 2 minutes of notice before termination. Kafka partition leadership migration and NiFi FlowFile flushing both take longer. You will lose data. Spot is fine for stateless consumers.

### Storage: Pick the Right Disk

| Volume Type | IOPS | Throughput | Cost | Use For |
|---|---|---|---|---|
| **gp3** ⭐ | 3,000 baseline (up to 16k) | 125 MB/s (up to 1000) | $0.08/GB-mo | Default for everything |
| gp2 | 3 IOPS/GB | Variable | $0.10/GB-mo | Nothing — gp3 is better and cheaper |
| io2 Block Express | Up to 256k | 4,000 MB/s | $0.125/GB-mo + IOPS | Very high-throughput Kafka |
| st1 | Low | 500 MB/s | $0.045/GB-mo | ❌ Not for Kafka — bad latency |
| **EFS** | — | Shared | $0.30/GB-mo | ❌ **Never** for Kafka/NiFi repos — NFS locking breaks them |

> 🔴 **Gotcha #16:** Someone will suggest EFS "so pods can share storage." **Do not.** Kafka log segments and NiFi FlowFile repositories use file locking and `fsync` semantics that NFS handles poorly. You will get corruption. Each pod gets its own EBS volume via `volumeClaimTemplates`.

### Essential Cluster Add-ons

```bash
# Metrics (needed for HPA and kubectl top)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

### Exposing NiFi Externally

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nifi
  namespace: data-platform
  annotations:
    alb.ingress.kubernetes.io/scheme: internal          # internal, not internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:<ACCT>:certificate/<ID>
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    # Sticky sessions — NiFi UI needs them in cluster mode
    alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.type=lb_cookie
spec:
  ingressClassName: alb
  rules:
    - host: nifi.internal.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nifi
                port: { number: 8443 }
```

> ⚠️ **Ingress NGINX was retired by upstream Kubernetes in March 2026** — no more bug fixes or security patches. If you were planning to use it, use the **AWS Load Balancer Controller** (shown above) or **Gateway API** instead. Existing NGINX deployments still run but are a growing security risk, and no alternative is a drop-in replacement.

### Network Policy (Default Deny)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: data-platform
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kafka-internal
  namespace: data-platform
spec:
  podSelector:
    matchLabels: { app: kafka }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: kafka } }
        - podSelector: { matchLabels: { app: nifi } }
      ports:
        - { protocol: TCP, port: 9092 }
        - { protocol: TCP, port: 9093 }
```

> ⚠️ EKS requires the **VPC CNI network policy** feature enabled, or Calico, for NetworkPolicy to actually be enforced. Without it, these YAML files are silently ignored — a dangerous false sense of security. Verify with a test pod.

---

<a name="14-patching"></a>
## 14. Patching Strategy

### The Four Layers That Need Patching

```
┌──────────────────────────────────────────────┐
│ 4. APPLICATION   NiFi 2.10.0 → 2.11.0        │  ← quarterly, planned
├──────────────────────────────────────────────┤
│ 3. RUNTIME       Corretto 21.0.4 → 21.0.5    │  ← monthly, automatic
├──────────────────────────────────────────────┤
│ 2. BASE OS       AL2023 packages / CVEs      │  ← weekly, automatic
├──────────────────────────────────────────────┤
│ 1. NODE / K8S    EKS 1.36, AMI updates       │  ← monthly + 14-mo cycle
└──────────────────────────────────────────────┘
```

**Most teams patch layer 4 and forget layers 1–3. That's where the CVEs live.**

### Layer 2 & 3: Rebuild Weekly (Automated)

The trick is that rebuilding the *same* application version on a *fresh* base image picks up all OS and JVM security fixes for free.

`.github/workflows/weekly-rebuild.yml`:

```yaml
name: Weekly Base Image Refresh

on:
  schedule:
    - cron: '0 6 * * 1'     # Every Monday 06:00 UTC
  workflow_dispatch:

permissions:
  id-token: write            # for OIDC — no stored AWS keys
  contents: read

jobs:
  rebuild:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        app: [nifi, kafka]
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-ecr
          aws-region: us-east-1

      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr

      - name: Build with fresh base
        run: |
          APP_VERSION=$(cat ${{ matrix.app }}/VERSION)
          BUILD_TAG="${APP_VERSION}-build.${{ github.run_number }}"
          docker buildx build \
            --platform linux/amd64 \
            --pull \
            --no-cache-filter builder \
            --provenance=true --sbom=true \
            -t ${{ steps.ecr.outputs.registry }}/data-platform/${{ matrix.app }}:${BUILD_TAG} \
            --push ./${{ matrix.app }}
          echo "BUILD_TAG=${BUILD_TAG}" >> $GITHUB_ENV

      - name: Scan with Trivy (deeper than ECR basic)
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ steps.ecr.outputs.registry }}/data-platform/${{ matrix.app }}:${{ env.BUILD_TAG }}
          severity: CRITICAL,HIGH
          exit-code: '1'
          ignore-unfixed: true    # don't fail on CVEs with no available fix
```

> 💡 `--pull` is the key flag. Without it, Docker reuses a cached base image from three months ago and your "rebuild" patches nothing.

### Layer 1: Node & Kubernetes Patching

**Node AMIs (do this monthly):**

```bash
# Managed node groups handle draining automatically
aws eks update-nodegroup-version \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name data \
  --region "${AWS_REGION}"

# Watch progress
aws eks describe-update --name "${CLUSTER_NAME}" \
  --nodegroup-name data --update-id <ID> --region "${AWS_REGION}"
```

**EKS control plane (every 14 months minimum, but do it sooner):**

```bash
# 1. Check for problems FIRST — EKS gives you upgrade insights
aws eks list-insights --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}"

aws eks describe-insight --cluster-name "${CLUSTER_NAME}" \
  --id <INSIGHT_ID> --region "${AWS_REGION}"

# 2. Find deprecated APIs in your manifests
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis

# 3. Upgrade control plane (~10-15 min, no downtime for workloads)
aws eks update-cluster-version \
  --name "${CLUSTER_NAME}" --kubernetes-version 1.36 --region "${AWS_REGION}"

# 4. THEN upgrade node groups
aws eks update-nodegroup-version --cluster-name "${CLUSTER_NAME}" --nodegroup-name data

# 5. THEN update add-ons
for addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
  aws eks update-addon --cluster-name "${CLUSTER_NAME}" --addon-name $addon --resolve-conflicts PRESERVE
done
```

> 🔴 **Order matters:** control plane **first**, then nodes, then add-ons. Kubernetes supports nodes up to 3 minor versions *behind* the control plane, but **never ahead**. Upgrading nodes first breaks things.

### Application Patching: The Rolling Update

```bash
# Update the image, one pod at a time
kubectl -n data-platform set image statefulset/kafka-broker \
  kafka=<REGISTRY>/data-platform/kafka@sha256:<NEW_DIGEST>

# Watch it
kubectl -n data-platform rollout status statefulset/kafka-broker --timeout=20m
```

**Canary with `partition`** — the safest way to test a new image:

```bash
# 3 brokers (0,1,2). Set partition=2: ONLY kafka-broker-2 updates.
kubectl -n data-platform patch statefulset kafka-broker -p \
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'

kubectl -n data-platform set image statefulset/kafka-broker kafka=<NEW_IMAGE>

# --- Soak test for 24 hours. Watch metrics. ---

# Happy? Roll the rest:
kubectl -n data-platform patch statefulset kafka-broker -p \
  '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'
```

### Patching Approach Comparison

| Strategy | Downtime | Risk | Cost | Complexity |
|---|---|---|---|---|
| **Rolling update** ⭐ | None | 🟡 Medium | 🟢 Low | 🟢 Low |
| **Canary (partition)** ⭐ | None | 🟢 Low | 🟢 Low | 🟡 Medium |
| **Blue/Green** | None | 🟢 Lowest | 🔴 2× infra | 🔴 High |
| **Recreate** | 🔴 Full outage | 🔴 High | 🟢 Low | 🟢 Low |
| **In-place `dnf update`** | None | 🔴 Very high | 🟢 Low | 🟢 Low |

> 🔴 **Never `dnf update` inside a running container.** Containers are supposed to be immutable. Patching one running pod creates a snowflake that doesn't match the image, and the change vanishes on restart. Always rebuild the image.

### Kafka-Specific Upgrade Rules

1. **Upgrade brokers one at a time.** Wait for full ISR recovery between each:
   ```bash
   kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions
   # Must return EMPTY before proceeding to the next broker
   ```
2. **Controllers before brokers.** In KRaft, upgrade the controller quorum first.
3. **No version skipping across major boundaries.** From ZooKeeper-era clusters you must go through **3.9.x** (the last version supporting both modes), migrate metadata to KRaft, *then* move to 4.x. There is no direct path.
4. **Only the last 3 minor versions get patches.** Roughly 12 months of support each, with new minors about every 4 months. Plan a version bump twice a year.

### NiFi-Specific Upgrade Rules

1. **Back up the flow first:**
   ```bash
   kubectl -n data-platform cp nifi-0:/opt/nifi/conf/flow.json.gz ./flow-backup-$(date +%F).json.gz
   ```
2. **Read the Migration Guidance** for your target version on the Apache NiFi wiki. Every 2.x minor has one.
3. **NiFi 2.10 removed Restricted Component Authorization** from the framework — re-verify your authorization policies after upgrading.
4. **Drain queues before upgrading** where possible. Stop source processors, let downstream drain, then upgrade.
5. **Only the latest NiFi release is actively maintained.** There is no LTS. Staying two versions behind means running unpatched software.

### Version Check Script

```bash
#!/usr/bin/env bash
# check-versions.sh — run this monthly
echo "=== EKS Cluster ==="
aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.{Version:version,Platform:platformVersion,Status:status}'

echo "=== Node groups ==="
for ng in $(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --query 'nodegroups[]' --output text); do
  aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "$ng" \
    --query 'nodegroup.{Name:nodegroupName,Version:version,AMI:releaseVersion,Status:status}'
done

echo "=== Add-ons ==="
aws eks list-addons --cluster-name "${CLUSTER_NAME}" --query 'addons[]' --output text | tr '\t' '\n' | \
while read a; do
  aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "$a" \
    --query 'addon.{Name:addonName,Version:addonVersion,Status:status}'
done

echo "=== Running images ==="
kubectl -n data-platform get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'

echo "=== Upgrade insights ==="
aws eks list-insights --cluster-name "${CLUSTER_NAME}" --query 'insights[?insightStatus.status!=`PASSING`]'
```

---

<a name="15-rollback"></a>
## 15. Rollback Playbook

### Rollback Speed by Layer

| What Broke | Method | Time | Data Loss Risk |
|---|---|---|---|
| App image | `kubectl rollout undo` | 2–5 min | 🟢 None |
| App image (canary) | Reset `partition` | 1 min | 🟢 None |
| Helm release | `helm rollback` | 2–5 min | 🟢 None |
| K8s manifests | `kubectl apply` old YAML | 1–3 min | 🟢 None |
| Node group AMI | Launch template version | 10–20 min | 🟡 Low |
| **EKS K8s version** | **`aws eks rollback-cluster-version`** | 15–30 min | 🟡 Low |
| Terraform infra | `git revert` + apply | 10–60 min | 🔴 High |
| Kafka data corruption | Restore from backup | Hours | 🔴 High |

### Level 1: Instant App Rollback

```bash
# See what changed
kubectl -n data-platform rollout history statefulset/nifi

# Go back one revision
kubectl -n data-platform rollout undo statefulset/nifi

# Go to a specific revision
kubectl -n data-platform rollout undo statefulset/nifi --to-revision=3

kubectl -n data-platform rollout status statefulset/nifi --timeout=15m
```

> ⚠️ `rollout undo` only reverses **pod template** changes. It does **not** revert PVC data, ConfigMaps, or Secrets. If the new version migrated data on disk, undo is not enough.

### Level 2: Pin to a Known-Good Digest

```bash
# Keep a file of blessed digests in Git
cat known-good-images.txt
# nifi:  ...@sha256:a1b2c3...
# kafka: ...@sha256:d4e5f6...

kubectl -n data-platform set image statefulset/nifi \
  nifi=<REGISTRY>/data-platform/nifi@sha256:a1b2c3...
```

### Level 3: EKS Kubernetes Version Rollback (New — July 2026)

As of **July 1, 2026**, EKS supports reverting to the previous Kubernetes minor version within **7 days** of an upgrade. This is a real safety net that didn't exist before.

```bash
# Check readiness — EKS runs automated checks on API compatibility,
# version skew, add-on compatibility, and cluster health
aws eks list-insights --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" --query 'insights[?category==`UPGRADE_READINESS`]'

# Perform the rollback
aws eks rollback-cluster-version \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

**Important constraints:**
- **7-day window only.** After that, you cannot roll back.
- For **EKS Auto Mode** clusters, EKS automatically rolls back worker nodes *before* reverting the control plane, honoring your disruption controls.
- Rolling back from a standard-support version to an extended-support version **resumes extended support charges**.
- Available at no additional cost in all EKS regions.

> 💡 **What this changes for you:** You can now validate a new Kubernetes version under real production traffic and back out if it goes wrong. Previously the only option was rebuilding the cluster. Still test in staging first — 7 days is not long.

### Level 4: Node Group Rollback

```bash
# Find the previous launch template version
aws ec2 describe-launch-template-versions \
  --launch-template-id lt-xxxx \
  --query 'LaunchTemplateVersions[*].{Ver:VersionNumber,AMI:LaunchTemplateData.ImageId}'

# Roll back
aws eks update-nodegroup-version \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name data \
  --launch-template id=lt-xxxx,version=3 \
  --force
```

### Level 5: Terraform Rollback

```bash
git revert <bad-commit>
terraform plan -var-file=envs/prod.tfvars -out=rollback.tfplan

# ⚠️ READ THE PLAN. Look for destroys.
terraform show rollback.tfplan | grep -E "will be destroyed"

terraform apply rollback.tfplan
```

> 🔴 **Gotcha #17:** Terraform rollback can **destroy and recreate** resources instead of reverting them. Changing an EKS cluster's name, or a node group's subnet, forces replacement — meaning your cluster is deleted and rebuilt. **Always read the plan output for `must be replaced`.** Add `prevent_destroy` lifecycle blocks on critical resources:
> ```hcl
> lifecycle { prevent_destroy = true }
> ```

### Emergency Runbook

```bash
#!/usr/bin/env bash
# emergency-rollback.sh
set -euo pipefail
NS=data-platform

echo "═══ 1. Snapshot current state for the post-mortem ═══"
kubectl -n $NS get all -o yaml > "incident-$(date +%s).yaml"
kubectl -n $NS describe pods > "incident-pods-$(date +%s).txt"
kubectl -n $NS logs -l app=nifi --tail=1000 --all-containers > "incident-logs-$(date +%s).txt"

echo "═══ 2. Roll back application ═══"
kubectl -n $NS rollout undo statefulset/nifi
kubectl -n $NS rollout undo statefulset/kafka-broker

echo "═══ 3. Wait ═══"
kubectl -n $NS rollout status statefulset/nifi --timeout=15m
kubectl -n $NS rollout status statefulset/kafka-broker --timeout=15m

echo "═══ 4. Verify ═══"
kubectl -n $NS get pods
kubectl -n $NS exec kafka-broker-0 -- \
  kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions

echo "✅ Rollback complete. Review incident-*.yaml before retrying."
```

### Backup Before You Need It

```bash
# Velero — backs up K8s objects AND EBS snapshots
velero install \
  --provider aws --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket my-velero-backups --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1

# Scheduled daily backup, 30-day retention
velero schedule create data-platform-daily \
  --schedule="0 2 * * *" \
  --include-namespaces data-platform \
  --ttl 720h

# Restore
velero restore create --from-backup data-platform-daily-20260720020000
```

**Also back up separately:**
```bash
# NiFi flow definition — small, precious
kubectl -n data-platform cp nifi-0:/opt/nifi/conf/flow.json.gz ./flow-$(date +%F).json.gz
aws s3 cp ./flow-$(date +%F).json.gz s3://my-backups/nifi/

# Kafka cluster ID + config
kubectl -n data-platform get configmap kafka-cluster-config -o yaml > kafka-config-backup.yaml
```

---

<a name="16-gotchas"></a>
## 16. Gotchas That Will Bite You

### The Complete List

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 1 | `nifi.sh start` instead of `run` | Container exits immediately, `CrashLoopBackOff` | Use `exec nifi.sh run` |
| 2 | Pushing `latest` to IMMUTABLE repo | `ImageTagAlreadyExistsException` | Use versioned tags with build numbers |
| 3 | **ARM vs x86 mismatch** | `exec format error` | `docker buildx build --platform linux/amd64` |
| 4 | Lost `sensitive.props.key` | NiFi won't start after restart | Store in Secrets Manager on day one |
| 5 | One volume for all NiFi repos | 10× throughput drop under load | Separate PVC per repository |
| 6 | NiFi 1.x flow into 2.x | Import fails or processors missing | Read Migration Guidance; test in scratch cluster |
| 7 | Fargate for NiFi/Kafka | PVCs never bind, pods stuck `Pending` | Use EC2 managed node groups |
| 8 | Deployment instead of StatefulSet | Kafka data loss, brokers can't find their logs | StatefulSet only |
| 9 | Local Terraform state | Two engineers destroy prod simultaneously | S3 backend + `use_lockfile` |
| 10 | `terraform apply` without saved plan | Applies something you didn't review | `-out=tfplan` then `apply tfplan` |
| 11 | Secrets in Terraform state | Plaintext passwords in S3 | Secrets Manager + `ignore_changes` |
| 12 | Huge Kafka heap | Slower, not faster; long GC pauses | 4–6 GB heap, let page cache use the rest |
| 13 | Mismatched Kafka CLUSTER_ID | Broker never joins, `InconsistentClusterIdException` | Generate once, store in ConfigMap |
| 14 | `kubectl scale` NiFi down | FlowFiles stranded on orphaned PVC | Offload node via UI first |
| 15 | Spot instances for brokers | Data loss on 2-minute termination notice | ON_DEMAND for stateful workloads |
| 16 | EFS for Kafka/NiFi repos | Silent corruption, lock errors | EBS gp3 via `volumeClaimTemplates` |
| 17 | Terraform replaces instead of updates | Cluster destroyed during "rollback" | Read plan for `must be replaced`; use `prevent_destroy` |
| 18 | No `startupProbe` on NiFi | Liveness kills it mid-boot, infinite restart loop | `startupProbe` with `failureThreshold: 60` |
| 19 | `requests` ≠ `limits` for memory | Pod OOMKilled under pressure | Set equal → Guaranteed QoS |
| 20 | JVM ignores container memory limit | OOMKilled at 100% of limit | `-XX:MaxRAMPercentage=75` or explicit `-Xmx` |
| 21 | Even number of KRaft controllers | Split-brain, quorum deadlock | Always 3 or 5 |
| 22 | Missing EBS CSI driver | PVCs stuck `Pending` forever | `eksctl create addon --name aws-ebs-csi-driver` |
| 23 | No subnet tags | ALB/NLB fails to provision | `kubernetes.io/role/elb=1` on public subnets |
| 24 | Deleting namespace leaves PVCs | Surprise EBS bill | `kubectl delete pvc --all` explicitly |
| 25 | kubectl version skew >1 minor | Weird API errors | Keep kubectl within 1 minor of cluster |
| 26 | NetworkPolicy silently ignored | Believing you're protected when you're not | Enable VPC CNI network policy or Calico; test it |
| 27 | Still on EKS 1.33 | **Support ends July 29, 2026** | Upgrade to 1.34+ now |
| 28 | Using Ingress NGINX | **Retired March 2026**, no security patches | Migrate to AWS LB Controller or Gateway API |
| 29 | NiFi heap > 32 GB | Effectively *less* usable memory | Cap at 31g (CompressedOops boundary) |
| 30 | No `terminationGracePeriodSeconds` | Data loss on pod shutdown | 120–180s for NiFi and Kafka |

### Debugging Cheat Sheet

```bash
# Pod won't start — always start here
kubectl -n data-platform describe pod nifi-0 | tail -30

# Logs from a crashed previous container
kubectl -n data-platform logs nifi-0 --previous

# Was it OOMKilled?
kubectl -n data-platform get pod nifi-0 -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# "OOMKilled" → increase memory limit or lower heap

# PVC stuck Pending?
kubectl -n data-platform describe pvc content-nifi-0
kubectl get storageclass
kubectl get pods -n kube-system | grep ebs-csi   # driver installed?

# Node resources
kubectl top nodes
kubectl describe node <name> | grep -A8 "Allocated resources"

# Can't pull image?
kubectl -n data-platform describe pod nifi-0 | grep -A5 Events
# "no basic auth credentials" → node IAM role lacks ECR permissions
aws ecr get-repository-policy --repository-name data-platform/nifi

# Wrong architecture?
docker manifest inspect <IMAGE> | jq '.manifests[].platform'

# DNS broken between pods?
kubectl -n data-platform run -it --rm dbg --image=busybox:1.36 --restart=Never -- \
  nslookup kafka-broker-0.kafka-broker-headless.data-platform.svc.cluster.local

# Kafka cluster health
kubectl -n data-platform exec kafka-broker-0 -- \
  kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status
```

---

<a name="17-security"></a>
## 17. Security Checklist

### Image Security

- [ ] Multi-stage build — no build tools in final image
- [ ] SHA-512 checksum verification on every download
- [ ] Non-root user (UID 1000), `runAsNonRoot: true`
- [ ] `readOnlyRootFilesystem: true` where possible
- [ ] All capabilities dropped
- [ ] ECR `scanOnPush=true` + Trivy/Grype in CI
- [ ] `IMMUTABLE` tags
- [ ] Deploy by **digest**, never `:latest`
- [ ] SBOM generated (`--sbom=true`)
- [ ] Images signed with Cosign; verified at admission
- [ ] Weekly rebuild for base OS CVEs

### Pod Security Context

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: app
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
```

Enforce cluster-wide with Pod Security Admission:
```bash
kubectl label namespace data-platform \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### AWS Security

- [ ] **IRSA or EKS Pod Identity** — never AWS keys in env vars or images
- [ ] EKS API endpoint restricted to known CIDRs
- [ ] Control plane logging enabled (all 5 types)
- [ ] Secrets encrypted with a customer-managed KMS key
- [ ] EBS volumes encrypted
- [ ] Security groups least-privilege
- [ ] GuardDuty EKS Protection on
- [ ] AWS Config rules for compliance drift

### Kafka Security (Production)

```properties
# TLS between everything
listeners=SASL_SSL://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
listener.security.protocol.map=SASL_SSL:SASL_SSL,CONTROLLER:SASL_SSL
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512

ssl.keystore.location=/etc/kafka/secrets/keystore.jks
ssl.truststore.location=/etc/kafka/secrets/truststore.jks
ssl.client.auth=required

# Lock it down
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
allow.everyone.if.no.acl.found=false
super.users=User:admin
```

Use **cert-manager** to issue and auto-rotate certificates:
```bash
helm install cert-manager jetstack/cert-manager -n cert-manager \
  --create-namespace --set crds.enabled=true
```

### NiFi Security

- [ ] HTTPS only (`nifi.web.https.port`), never HTTP in prod
- [ ] OIDC/SAML/LDAP auth — not single-user mode
- [ ] `sensitive.props.key` from a Secret, backed up to Secrets Manager
- [ ] Fine-grained authorization policies per process group
- [ ] `nifi.web.proxy.host` set correctly (or you get a blank page behind ALB)
- [ ] Provenance repo encrypted at rest
- [ ] Audit logs shipped to CloudWatch

### Image Signing with Cosign

```bash
# Sign with keyless OIDC (no key management)
cosign sign --yes "${REGISTRY}/data-platform/nifi@${DIGEST}"

# Verify
cosign verify \
  --certificate-identity-regexp="https://github.com/myorg/.*" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  "${REGISTRY}/data-platform/nifi@${DIGEST}"
```

Enforce at admission with Kyverno:
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-signature
      match:
        any:
          - resources: { kinds: [Pod], namespaces: [data-platform] }
      verifyImages:
        - imageReferences: ["*.dkr.ecr.*.amazonaws.com/data-platform/*"]
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/myorg/*"
```

---

<a name="18-cost"></a>
## 18. Cost Notes

### Rough Monthly Cost (us-east-1, on-demand)

| Component | Config | Est. Cost |
|---|---|---|
| EKS control plane | 1 cluster | ~$73 |
| Data nodes | 3× m6i.2xlarge | ~$700 |
| General nodes | 2× m6i.large (Spot) | ~$40 |
| EBS gp3 | ~2 TB total | ~$160 |
| NAT Gateway | 3 AZs | ~$100 + data |
| ECR storage | 50 GB | ~$5 |
| ALB | 1 internal | ~$20 |
| **Total** | | **~$1,100/mo** |

### Savings Levers

| Lever | Savings | Trade-off |
|---|---|---|
| Graviton (`m7g` instead of `m6i`) | ~20% | Must build arm64 images |
| Spot for stateless tier | ~70% on those nodes | Never for brokers |
| Single NAT gateway in dev | ~$70/mo | No AZ redundancy |
| Karpenter for bin-packing | 20–40% | Extra component to operate |
| Compute Savings Plan (1 yr) | ~30% | Commitment |
| gp3 instead of gp2 | ~20% on storage | None — pure win |
| ECR lifecycle policies | Varies | None — pure win |
| Delete idle dev clusters nightly | ~60% of dev | Startup time |

> 💸 **The #1 surprise bill:** Orphaned EBS volumes. `kubectl delete namespace` does **not** delete PVCs from StatefulSets. Audit monthly:
> ```bash
> aws ec2 describe-volumes --filters Name=status,Values=available \
>   --query 'Volumes[*].{ID:VolumeId,Size:Size,Created:CreateTime}' --output table
> ```

---

## Quick Reference Card

```bash
# ── Setup ──
source env.sh
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# ── Build & Push ──
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker buildx build --platform linux/amd64 -t "${ECR_REGISTRY}/data-platform/nifi:2.10.0-build.N" --push ./nifi

# ── Deploy ──
kubectl apply -f k8s/
kubectl -n data-platform rollout status statefulset/nifi --timeout=20m

# ── Inspect ──
kubectl -n data-platform get pods -o wide
kubectl -n data-platform logs nifi-0 --tail=100 -f
kubectl -n data-platform describe pod nifi-0

# ── Update ──
kubectl -n data-platform set image statefulset/nifi nifi=<REGISTRY>/data-platform/nifi@sha256:<DIGEST>

# ── Rollback ──
kubectl -n data-platform rollout undo statefulset/nifi
aws eks rollback-cluster-version --name "${CLUSTER_NAME}"   # within 7 days

# ── Kafka ops ──
kubectl -n data-platform exec kafka-broker-0 -- kafka-topics.sh --bootstrap-server localhost:9092 --list
kubectl -n data-platform exec kafka-broker-0 -- kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions
kubectl -n data-platform exec kafka-broker-0 -- kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status

# ── Cleanup ──
kubectl delete namespace data-platform
kubectl -n data-platform delete pvc --all
eksctl delete cluster --name "${CLUSTER_NAME}"
```

---

## Your Learning Path

**Week 1 — Get it working**
1. Do Part 1 exactly as written. Don't optimize anything.
2. Break it deliberately: delete a pod, watch it recover.
3. Read every log line during startup.

**Week 2 — Understand it**
4. Read Part 2. Re-read your Dockerfile with new eyes.
5. Add Kafka. Get NiFi publishing to a Kafka topic.
6. Scale NiFi to 3 nodes in cluster mode.

**Week 3 — Automate it**
7. Convert the cluster to Terraform.
8. Convert the build to Ansible or GitHub Actions.
9. Add the vulnerability scan gate.

**Week 4 — Harden it**
10. Add TLS, SASL, NetworkPolicies, Pod Security Admission.
11. Set up Prometheus + Grafana.
12. **Practice a rollback.** Do it on purpose, before you need it.

---

## Reference Links

| Topic | URL |
|---|---|
| NiFi Downloads | https://nifi.apache.org/download/ |
| NiFi Release Notes & Migration Guidance | https://cwiki.apache.org/confluence/display/NIFI/Release+Notes |
| Kafka Releases | https://kafka.apache.org/downloads |
| Kafka Documentation | https://kafka.apache.org/documentation/ |
| EKS Best Practices Guide | https://aws.github.io/aws-eks-best-practices/ |
| EKS Kubernetes Versions | https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html |
| Terraform EKS Module | https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest |
| Strimzi (Kafka Operator) | https://strimzi.io/docs/operators/latest/overview |
| Ansible amazon.aws Collection | https://docs.ansible.com/ansible/latest/collections/amazon/aws/ |

---

*Verified against versions current as of July 20, 2026: NiFi 2.10.0, Kafka 4.3.x, EKS 1.36. These move fast — run `check-versions.sh` before building.*
