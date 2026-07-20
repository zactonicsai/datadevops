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

**PART 5 — EC2 (NON-KUBERNETES) DEPLOYMENT**
- [19. Why EC2 Instead of EKS? (Background)](#19-ec2-background)
- [20. EC2 Instance Configuration in Detail](#20-ec2-config)

**PART 6 — AUTHENTICATION WITH KEYCLOAK**
- [21. Background: How Authentication Actually Works](#21-auth-background)
- [22. Setting Up Keycloak](#22-keycloak-setup)
- [23. Configuring the Keycloak Realm for NiFi](#23-keycloak-realm)
- [24. Wiring NiFi to Keycloak](#24-nifi-keycloak)

**PART 7 — NIFI FLOW MIGRATION**
- [25. Background: What Is a "Flow" and How Does It Move?](#25-flow-migration-background)
- [26. Worked Example: Migrating a Flow to a New Installation](#26-migration-walkthrough)

**PART 8 — AIR-GAPPED DEPLOYMENT**
- [27. Background: What "Air-Gapped" Actually Means](#27-airgap-background)
- [28. Air-Gapped Architecture on AWS](#28-airgap-architecture)
- [29. Mirroring: Getting Artifacts Across](#29-airgap-mirroring)
- [30. Air-Gapped NiFi Flow Migration (Worked Example)](#30-airgap-nifi-flow)
- [31. Ongoing Air-Gap Operations](#31-airgap-ongoing)

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

**EC2-specific (Part 5):**

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 31 | Instance store is ephemeral | Data gone after stop/replace | EBS for NiFi database repo; RF=3 for Kafka |
| 32 | `delete_on_termination = false` | Orphaned volumes bill forever | Monthly orphan audit |
| 33 | ASG terminates healthy brokers | Data loss during "AZ rebalance" | `protect_from_scale_in`; suspend `AZRebalance` |
| 34 | `nifi.sh run` under systemd | Service reports failed / hangs | Use `start` + `Type=forking` on EC2 (opposite of containers) |
| 35 | NVMe device order varies | Wrong disk mounted after reboot | Map by volume ID via `nvme id-ctrl`, not device path |

**Keycloak / auth (Part 6):**

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 36 | H2 database in production | Corruption, no HA | RDS PostgreSQL Multi-AZ |
| 37 | Redirect URI mismatch | `Invalid redirect_uri`, blank page | Must be `/nifi-api/access/oidc/callback` exactly |
| 38 | JWKS endpoint unreachable | All Kafka auth fails | Keycloak becomes a hard dependency — run HA |

**Flow migration (Part 7):**

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 39 | Sensitive props / NARs / removed processors | Import "works" but nothing runs | Audit all three before migrating |

**Air gap (Part 8):**

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 40 | Incomplete dependency manifest | Blocked at 2 AM on a missing JAR | Test in a no-NAT VPC first |
| 41 | `private_dns_enabled` not set | `ImagePullBackOff`, vague timeouts | Set `true` on every interface endpoint |
| 42 | Endpoint sprawl | ~$117/mo before traffic | Audit; use free S3/DynamoDB gateway endpoints |
| 43 | ECR endpoints without S3 | Auth succeeds, layer pull fails | ECR needs `ecr.api` + `ecr.dkr` + **S3 gateway** |
| 44–48 | Flow reaches outside the enclave | Timeouts on external calls | See the air-gap flow table in Section 30 |
| 49 | Internal CA in only one truststore | `PKIX path building failed` | Import into **both** NiFi truststore and JVM `cacerts` |
| 50 | No internal NTP | OIDC token validation fails | Clock skew breaks Keycloak tokens |

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

# PART 5 — EC2 (NON-KUBERNETES) DEPLOYMENT

<a name="19-ec2-background"></a>
## 19. Why EC2 Instead of EKS? (Background)

### The Two Ways to Run the Same Software

Everything in Parts 1–4 assumed **containers on Kubernetes**. But a huge number of production NiFi and Kafka clusters run the "old-fashioned" way: **directly on EC2 virtual machines**, installed as systemd services.

Neither is wrong. They solve different problems.

### The Apartment vs. House Analogy

- **EKS/containers** = an apartment building. The building manager (Kubernetes) handles plumbing, security, and moves you to a new unit if yours floods. Efficient, but you follow building rules.
- **EC2/systemd** = your own house. Total control over everything. When the pipe bursts at 2 AM, *you* fix it.

### When EC2 Is Actually the Right Answer

| Situation | Why EC2 Wins |
|---|---|
| **Team has no Kubernetes skills** | K8s is a second full-time system to learn and operate. If nobody on your team knows it, EKS adds risk, not safety. |
| **Air-gapped / classified environments** | Far fewer moving parts to mirror. No container registry, no CNI plugins, no CSI drivers, no admission webhooks. |
| **Very high, very stable throughput** | Direct access to instance-store NVMe (`i4i`, `im4gn`) gives Kafka enormous IOPS with no CSI layer in between. |
| **Strict change-control / regulated shops** | A frozen AMI you patched and approved is easier to audit than a dynamic scheduler moving pods around. |
| **Small footprint (1–3 nodes)** | EKS control plane costs $73/month before you run anything. For 3 nodes, that's pure overhead. |
| **Long-lived, rarely-changing clusters** | If the deployment changes twice a year, Kubernetes' orchestration value is mostly wasted. |

### When EKS Wins

| Situation | Why EKS Wins |
|---|---|
| Many services, not just NiFi/Kafka | One platform for everything |
| Frequent deploys | Rolling updates are built in |
| Elastic scaling | Autoscalers respond in minutes |
| Team already runs Kubernetes | Reuse existing skills and tooling |
| Multi-tenant | Namespaces, quotas, network policies |

### The Honest Comparison

| Dimension | EC2 + systemd | EKS + containers |
|---|---|---|
| Learning curve | 🟢 Low (Linux skills transfer) | 🔴 High |
| Time to first cluster | 🟢 ~30 min | 🟡 ~60 min |
| Self-healing | 🔴 ASG replaces the *instance*, slowly | 🟢 Pod restarts in seconds |
| Rolling upgrades | 🔴 You script it | 🟢 Built in |
| Resource efficiency | 🔴 One app per instance | 🟢 Bin-packing |
| Debugging | 🟢 SSH in, everything is familiar | 🟡 `kubectl exec`, layered abstractions |
| Air-gap friendliness | 🟢 Mirror a yum repo and some tarballs | 🔴 Mirror registry + charts + addons + AMIs |
| Cost (small scale) | 🟢 No control plane fee | 🔴 +$73/mo |
| Cost (large scale) | 🔴 Poor packing wastes money | 🟢 Better density |
| Disk performance ceiling | 🟢 Direct NVMe instance store | 🟡 EBS through CSI |
| Config drift risk | 🔴 High without Ansible | 🟢 Low (immutable images) |
| Blast radius of one bad change | 🟢 One instance | 🟡 Can affect whole cluster |

> 💡 **A very common hybrid:** Run **Kafka on EC2** (stateful, stable, benefits from instance-store NVMe) and **NiFi on EKS** (changes often, benefits from rolling deploys). This is a legitimate, widely used architecture — not a compromise.

---

<a name="20-ec2-config"></a>
## 20. EC2 Instance Configuration in Detail

### Choosing Instance Types

| Workload | Recommended | vCPU | RAM | Why |
|---|---|---|---|---|
| **Kafka broker (standard)** | `m6i.2xlarge` / `m7i.2xlarge` | 8 | 32 GB | Balanced; EBS gp3 storage |
| **Kafka broker (high throughput)** ⭐ | `i4i.2xlarge` | 8 | 64 GB | **1.9 TB local NVMe** — huge IOPS, no EBS bottleneck |
| **Kafka broker (Graviton, cheap)** | `im4gn.2xlarge` | 8 | 32 GB | ~20% cheaper; local NVMe; needs arm64 builds |
| **Kafka controller** | `m6i.large` | 2 | 8 GB | Metadata only — tiny workload |
| **NiFi node** | `m6i.2xlarge` | 8 | 32 GB | CPU + memory balanced |
| **NiFi (heavy transformation)** | `c6i.4xlarge` | 16 | 32 GB | Compute-optimized for parsing/encryption |
| **NiFi Registry** | `t3.medium` | 2 | 4 GB | Very light — just a Git-backed metadata store |
| **Keycloak** | `m6i.large` | 2 | 8 GB | Light, but needs HA (2+ instances) |

> 🔴 **Gotcha #31 — Instance store is ephemeral.** `i4i` and `im4gn` NVMe disks are *wiped* when the instance stops or is replaced. For Kafka this is usually acceptable because replication factor 3 means other brokers have copies — the replacement broker re-replicates. But **never** put NiFi's `database_repository` (which holds your flow definition) on instance store. Use EBS for that.

### Storage Layout for a Kafka Broker on EC2

```
/dev/nvme0n1  →  /            8 GB   gp3   OS
/dev/nvme1n1  →  /var/lib/kafka/data   1.9 TB  instance store OR gp3
/dev/nvme2n1  →  /var/log              50 GB   gp3
```

### Storage Layout for a NiFi Node on EC2

**This is the layout that matters most.** Separate disks per repository, exactly like the PVCs in Kubernetes:

```
/dev/nvme0n1  →  /                              20 GB   gp3
/dev/nvme1n1  →  /data/flowfile_repository       50 GB   gp3  (3000 IOPS - latency sensitive)
/dev/nvme2n1  →  /data/content_repository       500 GB   gp3  (throughput sensitive)
/dev/nvme3n1  →  /data/provenance_repository    200 GB   gp3
/dev/nvme4n1  →  /data/database_repository       20 GB   gp3  ⚠️ BACK THIS UP
```

### Complete EC2 Launch Template (Terraform)

```hcl
# ══════════════════════════════════════════════════════════
# Launch template — the "blueprint" for every NiFi instance
# ══════════════════════════════════════════════════════════
resource "aws_launch_template" "nifi" {
  name_prefix   = "nifi-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "m6i.2xlarge"
  key_name      = var.ssh_key_name

  iam_instance_profile { name = aws_iam_instance_profile.nifi.name }

  vpc_security_group_ids = [aws_security_group.nifi.id]

  # ── Root volume ──
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  # ── FlowFile repo: needs LOW LATENCY, high IOPS ──
  block_device_mappings {
    device_name = "/dev/sdb"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      iops                  = 6000       # bumped above the 3000 baseline
      throughput            = 250
      encrypted             = true
      delete_on_termination = false      # survive instance replacement
    }
  }

  # ── Content repo: needs THROUGHPUT ──
  block_device_mappings {
    device_name = "/dev/sdc"
    ebs {
      volume_size           = 500
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 500        # max out throughput
      encrypted             = true
      delete_on_termination = false
    }
  }

  # ── Provenance repo ──
  block_device_mappings {
    device_name = "/dev/sdd"
    ebs {
      volume_size           = 200
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = false
    }
  }

  # ── Database repo (flow definition — most precious) ──
  block_device_mappings {
    device_name = "/dev/sde"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = false
    }
  }

  # ── Force IMDSv2 (blocks SSRF credential theft) ──
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 ONLY
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  monitoring { enabled = true }   # detailed CloudWatch metrics

  user_data = base64encode(templatefile("${path.module}/userdata-nifi.sh", {
    nifi_version   = var.nifi_version
    cluster_name   = var.cluster_name
    s3_artifacts   = var.artifact_bucket
    region         = var.region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "nifi-node"
      Role    = "nifi"
      Cluster = var.cluster_name
    }
  }
}

# ══════════════════════════════════════════════════════════
# Auto Scaling Group — keeps N instances alive
# ══════════════════════════════════════════════════════════
resource "aws_autoscaling_group" "nifi" {
  name                = "nifi-asg"
  min_size            = 3
  max_size            = 5
  desired_capacity    = 3
  vpc_zone_identifier = var.private_subnet_ids

  # Spread across AZs
  availability_zones = null

  launch_template {
    id      = aws_launch_template.nifi.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 600   # NiFi takes ~5 min to become healthy

  target_group_arns = [aws_lb_target_group.nifi.arn]

  # Replace instances one at a time on config change
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 66    # keep 2 of 3 up
      instance_warmup        = 600
    }
  }

  # ⚠️ Protect stateful nodes from random scale-in
  protect_from_scale_in = true

  tag {
    key                 = "Name"
    value               = "nifi-node"
    propagate_at_launch = true
  }
}
```

> 🔴 **Gotcha #32 — `delete_on_termination = false` is a double-edged sword.** It preserves your data when an instance is replaced, which is what you want. But those volumes become **orphaned** and keep billing forever unless you re-attach or delete them. Set a monthly audit (see Section 18's orphan check).

> 🔴 **Gotcha #33 — Auto Scaling Groups are dangerous for stateful apps.** An ASG will happily terminate a healthy Kafka broker to "rebalance across AZs." Set `protect_from_scale_in = true` and `suspended_processes = ["AZRebalance"]`. Many teams skip the ASG entirely for Kafka and use fixed `aws_instance` resources.

### The User Data Script (`userdata-nifi.sh`)

This is what runs on first boot. It's the EC2 equivalent of a Dockerfile + entrypoint.

```bash
#!/usr/bin/env bash
set -euxo pipefail
exec > >(tee /var/log/user-data.log|logger -t user-data) 2>&1
# ↑ Everything below is logged to /var/log/user-data.log AND CloudWatch.
#   Without this line, debugging a failed boot is nearly impossible.

NIFI_VERSION="${nifi_version}"
S3_ARTIFACTS="${s3_artifacts}"
REGION="${region}"

echo "═══ 1. Base packages ═══"
dnf update -y
dnf install -y java-21-amazon-corretto-headless \
               awscli unzip jq nvme-cli amazon-cloudwatch-agent

echo "═══ 2. Kernel tuning for NiFi/Kafka ═══"
cat > /etc/sysctl.d/99-nifi.conf <<'EOF'
# More file handles — NiFi opens thousands
fs.file-max = 2097152

# Network tuning for high-throughput data movement
net.core.somaxconn = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 8192

# Don't swap — swapping kills JVM performance
vm.swappiness = 1
vm.max_map_count = 262144

# Kafka likes lazy dirty-page flushing
vm.dirty_background_ratio = 5
vm.dirty_ratio = 60
EOF
sysctl --system

echo "═══ 3. Raise file/process limits ═══"
cat > /etc/security/limits.d/99-nifi.conf <<'EOF'
nifi soft nofile 65536
nifi hard nofile 200000
nifi soft nproc  65536
nifi hard nproc  65536
EOF

echo "═══ 4. Create the service user ═══"
groupadd -g 1000 nifi || true
useradd -u 1000 -g 1000 -m -d /home/nifi -s /bin/bash nifi || true

echo "═══ 5. Format and mount the data disks ═══"
# NOTE: On Nitro instances, /dev/sdb appears as /dev/nvme1n1 etc.
# Map by SIZE to be safe, since NVMe device order is NOT guaranteed.
mount_disk() {
  local device="$1" mountpoint="$2"
  if ! blkid "$device" >/dev/null 2>&1; then
    mkfs.xfs -f "$device"      # XFS handles large files better than ext4
  fi
  mkdir -p "$mountpoint"
  local uuid
  uuid=$(blkid -s UUID -o value "$device")
  grep -q "$uuid" /etc/fstab || \
    echo "UUID=$uuid $mountpoint xfs defaults,noatime,nodiratime 0 2" >> /etc/fstab
  mount "$mountpoint"
  chown -R nifi:nifi "$mountpoint"
}

mount_disk /dev/nvme1n1 /data/flowfile_repository
mount_disk /dev/nvme2n1 /data/content_repository
mount_disk /dev/nvme3n1 /data/provenance_repository
mount_disk /dev/nvme4n1 /data/database_repository

echo "═══ 6. Fetch NiFi from S3 (NOT the internet) ═══"
# In air-gapped setups this S3 bucket is a VPC endpoint — no internet needed.
aws s3 cp "s3://$${S3_ARTIFACTS}/nifi/nifi-$${NIFI_VERSION}-bin.zip" /tmp/nifi.zip --region "$${REGION}"
aws s3 cp "s3://$${S3_ARTIFACTS}/nifi/nifi-$${NIFI_VERSION}-bin.zip.sha512" /tmp/nifi.zip.sha512 --region "$${REGION}"

# Verify integrity
echo "$(awk '{print $1}' /tmp/nifi.zip.sha512)  /tmp/nifi.zip" | sha512sum -c -

unzip -q /tmp/nifi.zip -d /opt
mv "/opt/nifi-$${NIFI_VERSION}" /opt/nifi
chown -R nifi:nifi /opt/nifi
rm -f /tmp/nifi.zip*

echo "═══ 7. Point repositories at the mounted disks ═══"
PROPS=/opt/nifi/conf/nifi.properties
sed -i "s|^nifi.flowfile.repository.directory=.*|nifi.flowfile.repository.directory=/data/flowfile_repository|" $PROPS
sed -i "s|^nifi.content.repository.directory.default=.*|nifi.content.repository.directory.default=/data/content_repository|" $PROPS
sed -i "s|^nifi.provenance.repository.directory.default=.*|nifi.provenance.repository.directory.default=/data/provenance_repository|" $PROPS
sed -i "s|^nifi.database.directory=.*|nifi.database.directory=/data/database_repository|" $PROPS

echo "═══ 8. Heap sizing — 50% of RAM, capped at 31g ═══"
TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
HEAP_MB=$(( TOTAL_MB / 2 ))
[ "$HEAP_MB" -gt 31744 ] && HEAP_MB=31744   # CompressedOops ceiling
sed -i "s|^java.arg.2=.*|java.arg.2=-Xms$${HEAP_MB}m|" /opt/nifi/conf/bootstrap.conf
sed -i "s|^java.arg.3=.*|java.arg.3=-Xmx$${HEAP_MB}m|" /opt/nifi/conf/bootstrap.conf

echo "═══ 9. Pull secrets from Secrets Manager ═══"
SENSITIVE_KEY=$(aws secretsmanager get-secret-value \
  --secret-id data-platform/nifi/sensitive-props-key \
  --query SecretString --output text --region "$${REGION}")
sed -i "s|^nifi.sensitive.props.key=.*|nifi.sensitive.props.key=$${SENSITIVE_KEY}|" $PROPS

echo "═══ 10. systemd service ═══"
cat > /etc/systemd/system/nifi.service <<'EOF'
[Unit]
Description=Apache NiFi
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=nifi
Group=nifi
Environment="JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto"

ExecStart=/opt/nifi/bin/nifi.sh start
ExecStop=/opt/nifi/bin/nifi.sh stop
ExecReload=/opt/nifi/bin/nifi.sh restart

# Give NiFi time to flush data on shutdown
TimeoutStopSec=180
Restart=on-failure
RestartSec=30

LimitNOFILE=200000
LimitNPROC=65536

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/opt/nifi /data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nifi

echo "═══ 11. CloudWatch agent ═══"
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'EOF'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "DataPlatform/NiFi",
    "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/data/content_repository","/data/flowfile_repository"] },
      "diskio": { "measurement": ["io_time","read_bytes","write_bytes"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/opt/nifi/logs/nifi-app.log",  "log_group_name": "/nifi/app" },
          { "file_path": "/opt/nifi/logs/nifi-user.log", "log_group_name": "/nifi/user" }
        ]
      }
    }
  }
}
EOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s

echo "✅ Bootstrap complete"
```

> 🔴 **Gotcha #34 — `Type=forking` and `nifi.sh start`.** This is the **opposite** of the container rule. On EC2 with systemd you *do* use `start` (background) with `Type=forking`, because systemd tracks the forked PID. In a container you use `run` (foreground). Mixing these up is a classic mistake when porting between the two.

> 🔴 **Gotcha #35 — NVMe device naming is not guaranteed.** On Nitro instances, `/dev/sdb` may show up as `/dev/nvme1n1` *or* `/dev/nvme3n1` — the order can vary across reboots. Production scripts should map by volume ID using `nvme id-ctrl`:
> ```bash
> for dev in /dev/nvme*n1; do
>   vol=$(nvme id-ctrl -v "$dev" | grep -o 'vol[a-z0-9]*' | head -1)
>   echo "$dev = $vol"
> done
> ```

### Ansible Alternative to User Data

User data only runs on first boot. **Ansible can re-run any time**, which makes it far better for ongoing configuration management.

`ansible/roles/nifi_ec2/tasks/main.yml`:

```yaml
---
- name: Install Java 21 and utilities
  ansible.builtin.dnf:
    name:
      - java-21-amazon-corretto-headless
      - unzip
      - jq
      - nvme-cli
    state: present

- name: Apply kernel tuning
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/99-nifi.conf
    reload: true
  loop: "{{ nifi_sysctl | dict2items }}"

- name: Create nifi user
  ansible.builtin.user:
    name: nifi
    uid: 1000
    shell: /bin/bash
    home: /home/nifi

- name: Create and mount data filesystems
  ansible.builtin.include_tasks: mount_disks.yml
  loop: "{{ nifi_data_disks }}"

- name: Download NiFi from internal artifact store
  ansible.builtin.get_url:
    url: "{{ nifi_artifact_base }}/nifi-{{ nifi_version }}-bin.zip"
    dest: /tmp/nifi.zip
    checksum: "sha512:{{ nifi_sha512 }}"     # verifies automatically
    mode: "0644"

- name: Unpack NiFi
  ansible.builtin.unarchive:
    src: /tmp/nifi.zip
    dest: /opt
    remote_src: true
    owner: nifi
    group: nifi
    creates: "/opt/nifi-{{ nifi_version }}"

- name: Symlink current version (enables instant rollback)
  ansible.builtin.file:
    src: "/opt/nifi-{{ nifi_version }}"
    dest: /opt/nifi
    state: link
    force: true
  notify: restart nifi

- name: Template nifi.properties
  ansible.builtin.template:
    src: nifi.properties.j2
    dest: "/opt/nifi-{{ nifi_version }}/conf/nifi.properties"
    owner: nifi
    group: nifi
    mode: "0600"
  notify: restart nifi

- name: Install systemd unit
  ansible.builtin.template:
    src: nifi.service.j2
    dest: /etc/systemd/system/nifi.service
    mode: "0644"
  notify:
    - reload systemd
    - restart nifi

- name: Enable and start NiFi
  ansible.builtin.systemd:
    name: nifi
    enabled: true
    state: started
    daemon_reload: true
```

> 💡 **The symlink trick is the EC2 equivalent of image tags.** Install versions side by side (`/opt/nifi-2.10.0`, `/opt/nifi-2.9.0`) and point `/opt/nifi` at the active one. Rollback becomes: `ln -sfn /opt/nifi-2.9.0 /opt/nifi && systemctl restart nifi` — about 3 seconds.

### EC2 Rolling Upgrade Playbook

```yaml
---
- name: Rolling NiFi upgrade on EC2
  hosts: nifi_nodes
  serial: 1                    # ONE node at a time
  max_fail_percentage: 0       # stop the whole run on first failure

  pre_tasks:
    - name: Disconnect and offload this node from the NiFi cluster
      ansible.builtin.uri:
        url: "https://{{ inventory_hostname }}:8443/nifi-api/controller/cluster/nodes/{{ node_id }}"
        method: PUT
        body_format: json
        body: { node: { nodeId: "{{ node_id }}", status: "OFFLOADING" } }
        headers: { Authorization: "Bearer {{ nifi_token }}" }
        validate_certs: false

    - name: Wait for offload to finish
      ansible.builtin.uri:
        url: "https://{{ inventory_hostname }}:8443/nifi-api/controller/cluster"
        headers: { Authorization: "Bearer {{ nifi_token }}" }
        validate_certs: false
      register: cluster
      until: >
        cluster.json.cluster.nodes
        | selectattr('nodeId','equalto', node_id)
        | map(attribute='status') | first == 'OFFLOADED'
      retries: 60
      delay: 20

  roles:
    - nifi_ec2

  post_tasks:
    - name: Wait for node to rejoin as CONNECTED
      ansible.builtin.uri:
        url: "https://{{ inventory_hostname }}:8443/nifi-api/system-diagnostics"
        validate_certs: false
      register: health
      until: health.status == 200
      retries: 60
      delay: 15
```

### EC2 Patching

```bash
# ── OS patches: use AWS Systems Manager Patch Manager ──
aws ssm create-patch-baseline \
  --name "DataPlatform-AL2023" \
  --operating-system AMAZON_LINUX_2023 \
  --approval-rules 'PatchRules=[{PatchFilterGroup={PatchFilters=[{Key=CLASSIFICATION,Values=[Security]},{Key=SEVERITY,Values=[Critical,Important]}]},ApproveAfterDays=7}]'

# Patch during a maintenance window, one instance at a time
aws ssm create-maintenance-window \
  --name "nifi-patching" --schedule "cron(0 3 ? * SUN *)" \
  --duration 4 --cutoff 1 --allow-unassociated-targets
```

| Patching Approach | Pros | Cons |
|---|---|---|
| **Immutable AMI (bake + replace)** ⭐ | Consistent; tested before deploy; easy rollback | Slower; needs AMI pipeline (Packer) |
| **SSM Patch Manager (in place)** | Simple; no AMI pipeline | Config drift; instances become snowflakes |
| **Ansible-driven** | Full control; ordering; pre/post hooks | You maintain the playbooks |

---

# PART 6 — AUTHENTICATION WITH KEYCLOAK

<a name="21-auth-background"></a>
## 21. Background: How Authentication Actually Works

### Authentication vs. Authorization

These two words look similar and get confused constantly. They are completely different jobs.

| | Question It Answers | Analogy |
|---|---|---|
| **Authentication (AuthN)** | "Who are you?" | Showing your ID at the door |
| **Authorization (AuthZ)** | "What are you allowed to do?" | Your wristband says VIP or General Admission |

**NiFi splits these cleanly:**
- **Authentication** → handed off to Keycloak via OIDC
- **Authorization** → stays inside NiFi (`authorizers.xml`, policies per process group)

This is important: **Keycloak tells NiFi who you are and what groups you're in. NiFi decides what you can touch.**

### The Hotel Key Card Analogy (OIDC in 6 Steps)

```
   YOU              NIFI                    KEYCLOAK
    │                 │                        │
    │──1. visit ─────▶│                        │
    │                 │                        │
    │◀─2. "go see ────│                        │
    │    reception"   │                        │
    │                                          │
    │──3. show ID ────────────────────────────▶│
    │                                          │
    │◀─4. key card (ID token) ─────────────────│
    │                                          │
    │──5. present card ▶│                      │
    │                   │──6. verify signature─▶│
    │                   │◀─ valid ─────────────│
    │◀─ you're in ──────│                      │
```

**The key insight:** NiFi never sees your password. Keycloak vouches for you with a cryptographically signed token that NiFi can verify.

### Why Keycloak and Not Something Else?

| Option | Pros | Cons | Best For |
|---|---|---|---|
| **Keycloak** ⭐ | Free, open source; self-hostable; **works fully air-gapped**; LDAP/AD federation; fine-grained groups | You operate it (HA, DB, upgrades) | Air-gapped, on-prem, regulated |
| **AWS Cognito** | Managed; no ops | Weaker group support; awkward NiFi mapping; AWS-only | AWS-native, internet-connected |
| **Okta / Auth0** | Polished; great support | Costs per user; **SaaS — impossible air-gapped** | Enterprises with budget |
| **Active Directory (LDAP direct)** | Already exists at most companies | No SSO across apps; NiFi handles passwords | Legacy AD shops |
| **NiFi single-user** | Zero setup | 🔴 One account, no audit trail | **Dev only. Never production.** |

> 💡 **For air-gapped environments, Keycloak is essentially the only realistic choice.** Every SaaS identity provider needs internet. Keycloak runs entirely inside your network.

### Keycloak Version Note (July 2026)

The current release is **Keycloak 26.7.0** (July 9, 2026). Keycloak ships **4 minor releases per year**, and **only the latest major version gets active development and security fixes**. Since 26.0, backward compatibility is guaranteed within minor releases for fully-supported features, and breaking changes are opt-in.

**26.7.0 highlights:** SCIM API for automated user provisioning (preview), simplified multi-cluster HA without external caches (preview), and step-up authentication for SAML clients.

> ⚠️ Keycloak patch releases fix a *lot* of CVEs — 26.7.0 alone addressed several privilege-escalation and OIDC issues. **Treat Keycloak patching as high priority.** It is the front door to everything.

---

<a name="22-keycloak-setup"></a>
## 22. Setting Up Keycloak

### Deployment Options

| Option | Pros | Cons |
|---|---|---|
| **Keycloak Operator on EKS** ⭐ | K8s-native; handles HA and upgrades | Needs an external Postgres |
| Helm chart (Bitnami) | Familiar | Less Keycloak-specific logic |
| EC2 + systemd | Simple; good for air-gap | Manual HA setup |
| Docker Compose | Great for dev | Not production |

### Option A: Keycloak on EKS (Operator)

```bash
# 1. Install the operator (version must match your Keycloak version)
kubectl create namespace keycloak
kubectl -n keycloak apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl -n keycloak apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl -n keycloak apply -f \
  https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.7.0/kubernetes/kubernetes.yml
```

```yaml
# keycloak-db-secret.yaml — points at RDS Postgres
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-secret
  namespace: keycloak
stringData:
  username: keycloak
  password: <FROM_SECRETS_MANAGER>
---
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  instances: 2                       # HA — always at least 2
  image: quay.io/keycloak/keycloak:26.7.0

  db:
    vendor: postgres
    host: keycloak-db.abc123.us-east-1.rds.amazonaws.com
    port: 5432
    database: keycloak
    usernameSecret: { name: keycloak-db-secret, key: username }
    passwordSecret: { name: keycloak-db-secret, key: password }

  hostname:
    hostname: https://auth.internal.example.com

  http:
    tlsSecret: keycloak-tls

  proxy:
    headers: xforwarded              # required behind an ALB

  resources:
    requests: { cpu: "1", memory: "1500Mi" }
    limits:   { cpu: "2", memory: "2Gi" }
```

> 🔴 **Gotcha #36 — Keycloak needs a real database.** The embedded H2 database is **dev only**. It cannot do HA and will corrupt under load. Use RDS PostgreSQL with Multi-AZ. Back it up — losing the Keycloak DB means losing every user, client, and role.

### Option B: Keycloak on EC2

```bash
#!/usr/bin/env bash
set -euxo pipefail
KC_VERSION="26.7.0"

dnf install -y java-21-amazon-corretto-headless unzip

# In air-gapped: pull from internal S3/artifact store instead
aws s3 cp "s3://${ARTIFACT_BUCKET}/keycloak/keycloak-${KC_VERSION}.zip" /tmp/kc.zip
unzip -q /tmp/kc.zip -d /opt && mv "/opt/keycloak-${KC_VERSION}" /opt/keycloak

useradd -r -s /sbin/nologin keycloak
chown -R keycloak:keycloak /opt/keycloak

cat > /opt/keycloak/conf/keycloak.conf <<'EOF'
db=postgres
db-url=jdbc:postgresql://keycloak-db.internal:5432/keycloak
db-username=keycloak

hostname=https://auth.internal.example.com
proxy-headers=xforwarded
http-enabled=false
https-certificate-file=/opt/keycloak/conf/tls.crt
https-certificate-key-file=/opt/keycloak/conf/tls.key

health-enabled=true
metrics-enabled=true

# Clustering across EC2 instances
cache=ispn
cache-stack=jdbc-ping
EOF

# Build optimizes the server for your config — do this BEFORE first start
sudo -u keycloak /opt/keycloak/bin/kc.sh build

cat > /etc/systemd/system/keycloak.service <<'EOF'
[Unit]
Description=Keycloak
After=network-online.target

[Service]
User=keycloak
Group=keycloak
Environment="KC_DB_PASSWORD_FILE=/opt/keycloak/conf/db-password"
ExecStart=/opt/keycloak/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=15
LimitNOFILE=102400

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now keycloak
```

> 💡 `kc.sh build` then `start --optimized` is the production pattern. Running plain `kc.sh start` re-builds on every boot, adding 30+ seconds to startup.

---

<a name="23-keycloak-realm"></a>
## 23. Configuring the Keycloak Realm for NiFi

### Step 23.1 — Create the Realm

A **realm** is a self-contained universe of users, groups, and applications. Keep NiFi/Kafka in their own realm, separate from `master` (which is only for Keycloak administration).

```bash
# Get an admin token
KC_URL="https://auth.internal.example.com"
TOKEN=$(curl -sk -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=${KC_ADMIN_PASSWORD}" \
  -d "grant_type=password" | jq -r .access_token)

# Create the realm
curl -sk -X POST "${KC_URL}/admin/realms" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "realm": "data-platform",
    "enabled": true,
    "displayName": "Data Platform",
    "sslRequired": "all",
    "bruteForceProtected": true,
    "permanentLockout": false,
    "maxFailureWaitSeconds": 900,
    "failureFactor": 5,
    "accessTokenLifespan": 900,
    "ssoSessionIdleTimeout": 3600,
    "ssoSessionMaxLifespan": 36000
  }'
```

### Step 23.2 — Create the NiFi Client

```bash
curl -sk -X POST "${KC_URL}/admin/realms/data-platform/clients" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "nifi",
    "name": "Apache NiFi",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "redirectUris": [
      "https://nifi.internal.example.com/nifi-api/access/oidc/callback",
      "https://nifi.internal.example.com/nifi-api/access/oidc/logoutCallback",
      "https://nifi.internal.example.com/nifi/*"
    ],
    "webOrigins": ["https://nifi.internal.example.com"],
    "attributes": {
      "post.logout.redirect.uris": "https://nifi.internal.example.com/nifi/"
    }
  }'

# Retrieve the generated client secret
CLIENT_UUID=$(curl -sk "${KC_URL}/admin/realms/data-platform/clients?clientId=nifi" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

CLIENT_SECRET=$(curl -sk "${KC_URL}/admin/realms/data-platform/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r .value)

echo "NiFi client secret: ${CLIENT_SECRET}"
```

> 🔴 **Gotcha #37 — Redirect URIs must match exactly.** The callback path is `/nifi-api/access/oidc/callback`. A trailing slash, `http` instead of `https`, or the wrong hostname produces `Invalid redirect_uri` and a blank page. This is the single most common Keycloak/NiFi failure.

### Step 23.3 — Add the Groups Claim Mapper

**This is the step everyone forgets.** By default Keycloak does *not* include group membership in the token. Without it, NiFi sees a user with no groups and denies everything.

```bash
curl -sk -X POST "${KC_URL}/admin/realms/data-platform/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "claim.name": "groups",
      "full.path": "false",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true"
    }
  }'
```

> ⚠️ `"full.path": "false"` gives you `nifi-admins`. Setting it `true` gives `/nifi-admins` with a leading slash. **Whatever you choose, NiFi's `authorizers.xml` must match exactly.** Mismatched slashes cause silent authorization failures.

### Step 23.4 — Create Groups and Users

```bash
for g in nifi-admins nifi-developers nifi-readonly; do
  curl -sk -X POST "${KC_URL}/admin/realms/data-platform/groups" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "{\"name\": \"${g}\"}"
done

# Create a user
curl -sk -X POST "${KC_URL}/admin/realms/data-platform/users" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "username": "jane.doe",
    "email": "jane.doe@example.com",
    "firstName": "Jane", "lastName": "Doe",
    "enabled": true, "emailVerified": true,
    "credentials": [{"type":"password","value":"ChangeMe123!","temporary":true}],
    "groups": ["/nifi-admins"]
  }'
```

### Step 23.5 — Federate with Active Directory (Optional but Common)

Most enterprises don't want to manage users twice. Point Keycloak at AD:

```bash
curl -sk -X POST "${KC_URL}/admin/realms/data-platform/components" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "name": "corporate-ad",
    "providerId": "ldap",
    "providerType": "org.keycloak.storage.UserStorageProvider",
    "config": {
      "vendor": ["ad"],
      "connectionUrl": ["ldaps://dc01.corp.internal:636"],
      "usersDn": ["OU=Users,DC=corp,DC=internal"],
      "bindDn": ["CN=svc-keycloak,OU=Service,DC=corp,DC=internal"],
      "bindCredential": ["<PASSWORD>"],
      "usernameLDAPAttribute": ["sAMAccountName"],
      "rdnLDAPAttribute": ["cn"],
      "uuidLDAPAttribute": ["objectGUID"],
      "userObjectClasses": ["person, organizationalPerson, user"],
      "editMode": ["READ_ONLY"],
      "syncRegistrations": ["false"],
      "importEnabled": ["true"]
    }
  }'
```

> 💡 `editMode: READ_ONLY` means Keycloak reads from AD but never writes to it. This is what your AD team will insist on.

### Step 23.6 — Export the Realm (Critical for Air-Gap)

```bash
# Export everything to a JSON file you can carry across the air gap
curl -sk "${KC_URL}/admin/realms/data-platform/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer ${TOKEN}" > realm-data-platform.json
```

Import it on the other side:
```bash
/opt/keycloak/bin/kc.sh import --file realm-data-platform.json
```

---

<a name="24-nifi-keycloak"></a>
## 24. Wiring NiFi to Keycloak

### `nifi.properties` — OIDC Section

```properties
# ══════════ WEB / TLS ══════════
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
nifi.web.http.host=
nifi.web.http.port=
nifi.web.proxy.host=nifi.internal.example.com:443,nifi.internal.example.com
nifi.web.proxy.context.path=

# ══════════ TLS KEYSTORES ══════════
nifi.security.keystore=./conf/keystore.p12
nifi.security.keystoreType=PKCS12
nifi.security.keystorePasswd=<FROM_SECRET>
nifi.security.keyPasswd=<FROM_SECRET>
nifi.security.truststore=./conf/truststore.p12
nifi.security.truststoreType=PKCS12
nifi.security.truststorePasswd=<FROM_SECRET>

# ══════════ AUTHENTICATION: OIDC ══════════
nifi.security.user.authorizer=managed-authorizer
nifi.security.user.login.identity.provider=
nifi.security.allow.anonymous.authentication=false

nifi.security.user.oidc.discovery.url=https://auth.internal.example.com/realms/data-platform/.well-known/openid-configuration
nifi.security.user.oidc.connect.timeout=10 secs
nifi.security.user.oidc.read.timeout=10 secs
nifi.security.user.oidc.client.id=nifi
nifi.security.user.oidc.client.secret=<FROM_SECRET>
nifi.security.user.oidc.preferred.jwsalgorithm=RS256
nifi.security.user.oidc.additional.scopes=openid,profile,email,groups

# Which token claim IS the username
nifi.security.user.oidc.claim.identifying.user=preferred_username
# Which token claim holds group membership
nifi.security.user.oidc.claim.groups=groups

# JDK = trust the system CA store. NIFI = use NiFi's truststore.
# In air-gapped setups with a private CA, use NIFI and import your CA.
nifi.security.user.oidc.truststore.strategy=NIFI
nifi.security.user.oidc.token.refresh.window=60 secs

# ══════════ INITIAL ADMIN ══════════
nifi.security.initial.admin.identity=jane.doe
```

> 💡 **NiFi 2.1.0+ supports a `file://` scheme for the discovery URL.** In split-network environments where the browser must use an external Keycloak URL but NiFi must use an internal one, you can supply a local discovery JSON file instead of fetching it over HTTP. This solves a real air-gap headache.

### `authorizers.xml` — Mapping Keycloak Groups to NiFi Permissions

```xml
<authorizers>
  <!-- Where user/group records live -->
  <userGroupProvider>
    <identifier>file-user-group-provider</identifier>
    <class>org.apache.nifi.authorization.FileUserGroupProvider</class>
    <property name="Users File">./conf/users.xml</property>
    <property name="Initial User Identity 1">jane.doe</property>
    <!-- Cluster nodes authenticate to each other by certificate DN -->
    <property name="Initial User Identity 2">CN=nifi-0.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
    <property name="Initial User Identity 3">CN=nifi-1.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
    <property name="Initial User Identity 4">CN=nifi-2.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
  </userGroupProvider>

  <accessPolicyProvider>
    <identifier>file-access-policy-provider</identifier>
    <class>org.apache.nifi.authorization.FileAccessPolicyProvider</class>
    <property name="User Group Provider">file-user-group-provider</property>
    <property name="Authorizations File">./conf/authorizations.xml</property>
    <property name="Initial Admin Identity">jane.doe</property>
    <!-- EVERY cluster node must be listed, or clustering fails -->
    <property name="Node Identity 1">CN=nifi-0.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
    <property name="Node Identity 2">CN=nifi-1.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
    <property name="Node Identity 3">CN=nifi-2.nifi-headless.data-platform.svc.cluster.local, OU=NIFI</property>
    <!-- Keycloak group that gets admin rights -->
    <property name="Initial Admin Group">nifi-admins</property>
  </accessPolicyProvider>

  <authorizer>
    <identifier>managed-authorizer</identifier>
    <class>org.apache.nifi.authorization.StandardManagedAuthorizer</class>
    <property name="Access Policy Provider">file-access-policy-provider</property>
  </authorizer>
</authorizers>
```

### Kubernetes Secret for OIDC

```bash
kubectl -n data-platform create secret generic nifi-oidc \
  --from-literal=client-id=nifi \
  --from-literal=client-secret="${CLIENT_SECRET}" \
  --from-literal=discovery-url="https://auth.internal.example.com/realms/data-platform/.well-known/openid-configuration"
```

Add to the StatefulSet:
```yaml
            - name: NIFI_OIDC_CLIENT_ID
              valueFrom: { secretKeyRef: { name: nifi-oidc, key: client-id } }
            - name: NIFI_OIDC_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: nifi-oidc, key: client-secret } }
            - name: NIFI_OIDC_DISCOVERY_URL
              valueFrom: { secretKeyRef: { name: nifi-oidc, key: discovery-url } }
```

And in `entrypoint.sh`:
```bash
if [[ -n "${NIFI_OIDC_DISCOVERY_URL:-}" ]]; then
  log "Enabling OIDC authentication"
  prop_set "nifi.security.user.oidc.discovery.url"      "${NIFI_OIDC_DISCOVERY_URL}"
  prop_set "nifi.security.user.oidc.client.id"          "${NIFI_OIDC_CLIENT_ID}"
  prop_set "nifi.security.user.oidc.client.secret"      "${NIFI_OIDC_CLIENT_SECRET}"
  prop_set "nifi.security.user.oidc.claim.identifying.user" "preferred_username"
  prop_set "nifi.security.user.oidc.claim.groups"       "groups"
  prop_set "nifi.security.user.oidc.additional.scopes"  "openid,profile,email,groups"
  prop_set "nifi.security.allow.anonymous.authentication" "false"
  prop_set "nifi.security.user.authorizer"              "managed-authorizer"
fi
```

### Kafka with Keycloak (OAUTHBEARER)

Kafka can also delegate authentication to Keycloak:

```properties
listeners=SASL_SSL://0.0.0.0:9092
sasl.enabled.mechanisms=OAUTHBEARER
sasl.mechanism.inter.broker.protocol=OAUTHBEARER

sasl.oauthbearer.jwks.endpoint.url=https://auth.internal.example.com/realms/data-platform/protocol/openid-connect/certs
sasl.oauthbearer.expected.issuer=https://auth.internal.example.com/realms/data-platform
sasl.oauthbearer.sub.claim.name=preferred_username

listener.name.sasl_ssl.oauthbearer.sasl.server.callback.handler.class=\
  org.apache.kafka.common.security.oauthbearer.OAuthBearerValidatorCallbackHandler

authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
allow.everyone.if.no.acl.found=false
super.users=User:kafka-admin
```

> 🔴 **Gotcha #38 — In air-gapped setups, Kafka must reach the JWKS endpoint.** The broker fetches Keycloak's public signing keys to verify tokens. If Keycloak is unreachable, **every authentication fails**. Keycloak becomes a hard dependency for your data plane. Run it HA, and consider caching JWKS aggressively.

### Troubleshooting Table

| Symptom | Likely Cause | Fix |
|---|---|---|
| Blank white page after login | `nifi.web.proxy.host` missing your hostname | Add hostname **and** hostname:port |
| `Invalid redirect_uri` | Keycloak client URI mismatch | Must include `/nifi-api/access/oidc/callback` exactly |
| Logged in but "Unable to view the flow" | No authorization policy for the user | Set `Initial Admin Identity` or add policies in UI |
| Groups not recognized | Groups claim mapper missing | Add `oidc-group-membership-mapper` (Step 23.3) |
| Group name has a leading `/` | `full.path` is `true` | Set to `false`, or match the slash in authorizers.xml |
| `PKIX path building failed` | NiFi doesn't trust Keycloak's cert | Import CA into truststore; set `truststore.strategy=NIFI` |
| Session drops after ~15 min | Access token lifespan too short | Raise `accessTokenLifespan` in realm settings |
| Works on node 1, fails on node 2 | Nodes not listed in authorizers.xml | Add every `Node Identity` |
| `502 Bad Gateway` from ALB | Sticky sessions off | Enable `stickiness.enabled=true` on target group |

---

# PART 7 — NIFI FLOW MIGRATION

<a name="25-flow-migration-background"></a>
## 25. Background: What Is a "Flow" and How Does It Move?

### The Blueprint Analogy

Your NiFi **flow** is the diagram you drew — the boxes, the arrows, the settings. It is *not* the data flowing through it.

Moving a flow between installations is like moving a **blueprint** to a new construction site. The blueprint moves easily. The half-built house does not.

### What Moves and What Doesn't

| Item | Moves? | Notes |
|---|---|---|
| Processor layout and connections | ✅ Yes | The core of the flow |
| Processor property values | ✅ Yes | Non-sensitive ones travel as plain text |
| Controller service definitions | ✅ Yes | But must be re-enabled on arrival |
| **Passwords / sensitive properties** | ⚠️ **Encrypted** | Only decryptable with the *same* `sensitive.props.key` |
| Parameter Contexts | ✅ Yes | Non-sensitive parameters travel; sensitive ones don't |
| Variables (legacy) | ⚠️ Deprecated | Convert to Parameter Contexts before migrating |
| **Queued FlowFiles (in-flight data)** | ❌ **No** | Data stays behind. Drain first. |
| Provenance history | ❌ No | Audit trail stays with the old cluster |
| Users and policies | ⚠️ Separate | `users.xml` / `authorizations.xml`, or re-created by Keycloak |
| Custom NARs | ❌ No | You must copy the `.nar` files yourself |
| JDBC drivers | ❌ No | Copy the `.jar` files yourself |
| Templates (1.x) | ❌ **Removed in 2.x** | Must convert to Registry flows before upgrading |

> 🔴 **Gotcha #39 — The three things that break every migration:** (1) sensitive properties can't be decrypted on the target, (2) a custom NAR or JDBC driver is missing, (3) the flow used a processor that was removed in 2.x. Check all three *before* you start.

### The Four Migration Methods

| Method | Best For | Difficulty | Sensitive Props |
|---|---|---|---|
| **NiFi Registry / Flow Registry** ⭐ | Ongoing dev→prod promotion | 🟡 Medium setup, easy after | Re-enter on target |
| **Flow definition JSON export** | One-time moves, air-gap transfer | 🟢 Easy | Re-enter on target |
| **Copy `flow.json.gz` wholesale** | Full cluster clone, DR | 🟢 Easy | ✅ Preserved if key matches |
| **NiFi Toolkit CLI** | Automation, CI/CD | 🟡 Medium | Re-enter on target |

---

<a name="26-migration-walkthrough"></a>
## 26. Worked Example: Migrating a Flow to a New Installation

**Scenario:** You have a working flow on an old NiFi 1.28 cluster (`nifi-old.corp.internal`). You need it running on a brand-new NiFi 2.10.0 cluster on EKS, in a network with no internet.

### Phase 1 — Pre-Migration Audit (Do This First)

```bash
# ── 1. Inventory every processor type in use ──
# On the OLD cluster, fetch the flow and list distinct processor types
curl -sk -H "Authorization: Bearer ${OLD_TOKEN}" \
  "https://nifi-old.corp.internal:8443/nifi-api/flow/process-groups/root?recursive=true" \
  | jq -r '.. | .component? // empty | select(.type) | .type' \
  | sort -u > processors-in-use.txt

wc -l processors-in-use.txt
cat processors-in-use.txt
```

**Now check each one against the NiFi 2.x removal list.** Common casualties:

| Removed in 2.x | Replacement |
|---|---|
| `EncryptContent` (PGP mode) | `EncryptContentPGP` / `DecryptContentPGP` |
| Kerberos keytab properties on processors | `KerberosUserService` controller service |
| `PutHDFS` variants with legacy auth | Updated versions with credential services |
| Most `*Nifi Legacy*` components | Modern equivalents |
| **All Templates** | NiFi Registry flows |

```bash
# ── 2. Inventory custom NARs ──
ssh nifi-old "ls -1 /opt/nifi/lib/*.nar /opt/nifi/extensions/*.nar 2>/dev/null" \
  | xargs -n1 basename | sort > nars-old.txt

# Compare against a stock NiFi 2.10.0 install
diff <(sort nars-stock-2.10.0.txt) nars-old.txt | grep '^>' > custom-nars.txt
echo "Custom NARs you must copy:"
cat custom-nars.txt

# ── 3. Inventory JDBC drivers and external JARs ──
ssh nifi-old "ls -1 /opt/nifi/lib/*.jar | grep -iE 'jdbc|driver|ojdbc|mssql|postgres'" \
  > jdbc-drivers.txt

# ── 4. Inventory sensitive properties (you'll re-enter these) ──
curl -sk -H "Authorization: Bearer ${OLD_TOKEN}" \
  "https://nifi-old.corp.internal:8443/nifi-api/flow/process-groups/root?recursive=true" \
  | jq -r '.. | .component? // empty
      | select(.properties)
      | select(.properties | to_entries | any(.value == null))
      | "\(.name) [\(.type | split(".") | last)]"' \
  | sort -u > sensitive-props-to-reenter.txt
```

> 💡 In the NiFi API, sensitive property values come back as `null`. That's how you find them — every `null` property is something you must manually re-enter on the target.

### Phase 2 — Drain the Queues

**In-flight data does not migrate.** Before exporting, empty the pipes.

```bash
# 1. Stop all SOURCE processors (the ones that pull data in)
#    Leave downstream running so queues drain naturally.
curl -sk -X PUT -H "Authorization: Bearer ${OLD_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://nifi-old.corp.internal:8443/nifi-api/flow/process-groups/${PG_ID}" \
  -d '{"id":"'"${PG_ID}"'","state":"STOPPED"}'

# 2. Watch queues empty
watch -n 10 'curl -sk -H "Authorization: Bearer ${OLD_TOKEN}" \
  "https://nifi-old.corp.internal:8443/nifi-api/flow/process-groups/root/status" \
  | jq ".processGroupStatus.aggregateSnapshot | {queued, flowFilesQueued}"'

# 3. Only proceed when flowFilesQueued == 0
```

> ⚠️ If you cannot fully drain (a queue is stuck on a failing processor), export the flow anyway but **document the stranded data**. You may need to replay it from the source system later.

### Phase 3 — Export the Flow

**Method A — Flow Definition JSON (recommended for air-gap):**

```bash
# Find the process group ID you want
curl -sk -H "Authorization: Bearer ${OLD_TOKEN}" \
  "https://nifi-old.corp.internal:8443/nifi-api/flow/process-groups/root" \
  | jq -r '.processGroupFlow.flow.processGroups[] | "\(.id)  \(.component.name)"'

PG_ID="a1b2c3d4-...."

# Download the flow definition
curl -sk -H "Authorization: Bearer ${OLD_TOKEN}" \
  "https://nifi-old.corp.internal:8443/nifi-api/process-groups/${PG_ID}/download?includeReferencedServices=true" \
  -o flow-definition.json

# ↑ includeReferencedServices=true is IMPORTANT — without it, controller
#   services defined OUTSIDE the group are not included and the flow breaks.

jq '.flowContents.name, (.flowContents.processors | length)' flow-definition.json
```

**Method B — NiFi Toolkit CLI (better for automation):**

```bash
# Set up a connection profile
cat > ~/.nifi-cli.config <<EOF
baseUrl=https://nifi-old.corp.internal:8443
keystore=/path/to/keystore.p12
keystoreType=PKCS12
keystorePasswd=<PASSWORD>
truststore=/path/to/truststore.p12
truststoreType=PKCS12
truststorePasswd=<PASSWORD>
EOF

# List process groups
./bin/cli.sh nifi pg-list -p ~/.nifi-cli.config

# Export
./bin/cli.sh nifi pg-get-all-versions -p ~/.nifi-cli.config --processGroupId "${PG_ID}"
./bin/cli.sh registry export-flow-version \
  -p ~/.nifi-cli.config \
  --flowIdentifier "${FLOW_ID}" \
  --outputFile flow-export.json
```

**Method C — Whole-cluster clone (`flow.json.gz`):**

```bash
# This preserves EVERYTHING including encrypted sensitive properties —
# but ONLY works if the target uses the SAME sensitive.props.key.
kubectl -n data-platform cp nifi-0:/opt/nifi/conf/flow.json.gz ./flow.json.gz
```

| Method | Sensitive Props | Selective | Air-Gap Friendly |
|---|---|---|---|
| A: Flow definition JSON | ❌ Must re-enter | ✅ Per process group | ✅ Single file |
| B: Toolkit CLI | ❌ Must re-enter | ✅ Scriptable | ✅ Yes |
| C: `flow.json.gz` | ✅ Preserved (same key) | ❌ All or nothing | ✅ Single file |

### Phase 4 — Prepare the Target

```bash
# ── 1. Copy custom NARs into the new image ──
mkdir -p ~/data-platform/nifi/custom-nars
scp nifi-old:/opt/nifi/extensions/*.nar ~/data-platform/nifi/custom-nars/
scp nifi-old:/opt/nifi/lib/postgresql-*.jar ~/data-platform/nifi/drivers/

# ── 2. Rebuild the image WITH them ──
cat >> ~/data-platform/nifi/Dockerfile <<'EOF'
COPY --chown=1000:1000 custom-nars/*.nar ${NIFI_HOME}/extensions/
COPY --chown=1000:1000 drivers/*.jar     ${NIFI_HOME}/lib/
EOF

docker buildx build --platform linux/amd64 \
  -t "${ECR_REGISTRY}/data-platform/nifi:2.10.0-build.2" --push ~/data-platform/nifi

# ── 3. Deploy the new image ──
kubectl -n data-platform set image statefulset/nifi \
  nifi="${ECR_REGISTRY}/data-platform/nifi:2.10.0-build.2"
kubectl -n data-platform rollout status statefulset/nifi --timeout=20m

# ── 4. Verify the NARs loaded ──
kubectl -n data-platform exec nifi-0 -- ls -1 /opt/nifi/extensions/
kubectl -n data-platform logs nifi-0 | grep -i "loaded.*nar" | tail -20
```

### Phase 5 — Import the Flow

**Via the UI (easiest):**
1. Open the new NiFi at `https://nifi.internal.example.com/nifi`
2. Drag a **Process Group** onto the canvas
3. Click **Browse** → select `flow-definition.json`
4. Name it and click **Add**

**Via the API (scriptable):**

```bash
NEW_TOKEN=$(curl -sk -X POST "https://nifi.internal.example.com/nifi-api/access/token" \
  -d "username=admin&password=${PASSWORD}")

ROOT_PG=$(curl -sk -H "Authorization: Bearer ${NEW_TOKEN}" \
  "https://nifi.internal.example.com/nifi-api/flow/process-groups/root" \
  | jq -r '.processGroupFlow.id')

# Wrap the flow definition in the required envelope
jq '{
  revision: { version: 0 },
  component: {
    position: { x: 100, y: 100 },
    name: "Migrated Flow"
  },
  disconnectedNodeAcknowledged: false,
  versionedFlowSnapshot: .
}' flow-definition.json > import-payload.json

curl -sk -X POST -H "Authorization: Bearer ${NEW_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://nifi.internal.example.com/nifi-api/process-groups/${ROOT_PG}/process-groups" \
  -d @import-payload.json | jq '.id, .component.name'
```

### Phase 6 — Post-Import Checklist

The flow is on the canvas but **it will not run yet**. Work through this list:

```
☐ 1. Re-enter every sensitive property from sensitive-props-to-reenter.txt
     (passwords, API keys, keystore passwords)

☐ 2. Enable all controller services
     Right-click canvas → Configure → Controller Services → enable each
     ⚠️ Order matters: enable dependencies (e.g. SSLContextService) FIRST

☐ 3. Update environment-specific values
     - Hostnames (old DB server → new DB server)
     - File paths (/data/old → /data/new)
     - Kafka bootstrap servers
     - S3 bucket names

☐ 4. Recreate Parameter Contexts
     Sensitive parameters do NOT export. Re-enter them.

☐ 5. Check for invalid processors (⚠️ icon)
     Hover over each to see what's wrong

☐ 6. Verify custom NARs loaded
     Any processor showing as "Ghost" means its NAR is missing

☐ 7. Set up authorization policies
     If using Keycloak groups, assign policies to nifi-developers etc.

☐ 8. Test with a SMALL sample before enabling sources
```

**Automated validation:**

```bash
# List every invalid component and why
curl -sk -H "Authorization: Bearer ${NEW_TOKEN}" \
  "https://nifi.internal.example.com/nifi-api/flow/process-groups/${NEW_PG_ID}?recursive=true" \
  | jq -r '.. | .component? // empty
      | select(.validationStatus == "INVALID")
      | "❌ \(.name): \(.validationErrors | join("; "))"'

# Find ghost processors (missing NARs)
curl -sk -H "Authorization: Bearer ${NEW_TOKEN}" \
  "https://nifi.internal.example.com/nifi-api/flow/process-groups/${NEW_PG_ID}?recursive=true" \
  | jq -r '.. | .component? // empty | select(.extensionMissing == true) | "👻 MISSING NAR: \(.type)"'
```

### Phase 7 — Cutover

```bash
# 1. Start downstream processors first (so they're ready to receive)
# 2. Start ONE source processor with a small batch
# 3. Watch provenance to confirm data flows correctly
curl -sk -H "Authorization: Bearer ${NEW_TOKEN}" \
  -X POST "https://nifi.internal.example.com/nifi-api/provenance" \
  -H "Content-Type: application/json" \
  -d '{"provenance":{"request":{"maxResults":100}}}'

# 4. Compare record counts old vs new for a fixed window
# 5. Only then stop the old cluster's sources permanently
```

> 💡 **Run both in parallel briefly if you can.** Point the new cluster at a test topic/bucket, verify output matches, *then* cut over. This is the safest possible migration.

### Ongoing: Use NiFi Registry Instead

For dev→prod promotion, don't do manual exports every time. Use the **Flow Registry** with a Git backend:

```properties
# In NiFi: register the registry client
# Controller Settings → Registry Clients → Add
# NiFi 2.x supports Git-based Flow Registry Clients directly

# nifi-registry.properties on the registry server
nifi.registry.db.url=jdbc:postgresql://registry-db:5432/nifi_registry
nifi.registry.security.user.oidc.discovery.url=https://auth.internal.example.com/realms/data-platform/.well-known/openid-configuration
nifi.registry.security.user.oidc.client.id=nifi-registry
nifi.registry.security.user.oidc.client.secret=<SECRET>
```

Workflow: right-click a process group → **Version** → **Start version control** → commit to Registry → on prod, **Import from Registry** → later, **Change version** to promote.

> 💡 **NiFi 2.10 added branch creation support for Registry Clients**, so you can do proper feature-branch workflows for flows — develop on a branch, merge to main, promote to prod.

---

# PART 8 — AIR-GAPPED DEPLOYMENT

<a name="27-airgap-background"></a>
## 27. Background: What "Air-Gapped" Actually Means

### The Island Analogy

A normal network is a town with roads to everywhere. You need flour? Drive to the store.

An **air-gapped network is an island with no bridge.** Nothing gets in or out except by boat, on a schedule, after inspection. You need flour? Put it on the manifest, wait for the next boat, and hope you didn't forget the yeast.

**That's the entire challenge:** every single dependency must be identified *before* you need it, carried across deliberately, and stored locally.

### Degrees of Isolation

| Level | Description | Typical Setting |
|---|---|---|
| **Full air gap** | Zero network path. Physical media only (USB, DVD, tape). | Classified, SCIF, nuclear |
| **One-way diode** | Data flows in only, never out. Hardware-enforced. | Defense, intelligence |
| **Restricted egress** | No internet, but internal mirrors reachable | 🟢 **Most common** — banks, healthcare, utilities |
| **Proxy-only** | Internet through an inspecting proxy with an allowlist | Enterprise IT |

> 💡 **Most "air-gapped" AWS projects are actually the third kind:** private subnets with no NAT gateway, reaching AWS services through **VPC endpoints**. This guide focuses there, with notes for true physical air gaps.

### The Dependency Iceberg

This is why air-gap projects fail. You think you need one file. You actually need hundreds.

```
        WHAT YOU THINK YOU NEED
        ┌──────────────────┐
        │  nifi-2.10.0.zip │
        └──────────────────┘
   ═══════════════════════════════  waterline
        WHAT YOU ACTUALLY NEED
   ┌────────────────────────────────────┐
   │ Base container images              │
   │ Java 21 runtime                    │
   │ ~200 OS packages (dnf/yum)         │
   │ Custom NARs                        │
   │ JDBC drivers (Oracle, MSSQL, PG)   │
   │ Kafka + Scala libs                 │
   │ Keycloak + its Postgres driver     │
   │ EKS add-on images (CNI, CoreDNS,   │
   │   kube-proxy, EBS CSI, metrics)    │
   │ Helm charts + their sub-charts     │
   │ Terraform providers (~200 MB)      │
   │ Ansible collections                │
   │ CA certificates                    │
   │ Python/pip wheels                  │
   │ Container base image CVE updates   │
   │   (every single month, forever)    │
   └────────────────────────────────────┘
```

> 🔴 **Gotcha #40 — The forgotten dependency will find you at 2 AM.** A processor needs a JDBC driver you didn't mirror. Terraform needs a provider version you don't have. The pod pulls an init image from `registry.k8s.io`. Build a **complete manifest** first, and test the whole stack in a network-isolated sandbox *before* the real deployment.

---

<a name="28-airgap-architecture"></a>
## 28. Air-Gapped Architecture on AWS

### The Reference Design

```
┌─────────────────────────────────────────────────────────────┐
│  CONNECTED ZONE (has internet)                              │
│                                                             │
│   ┌─────────────┐   downloads    ┌──────────────────────┐  │
│   │  Staging    │───────────────▶│  Artifact Bundle     │  │
│   │  Build Host │                │  (tarball / S3)      │  │
│   └─────────────┘                └──────────┬───────────┘  │
└───────────────────────────────────────────────┼─────────────┘
                                                │
                        ╔═══════════════════════▼═══════════╗
                        ║   TRANSFER (the "boat")           ║
                        ║   S3 cross-account │ DataSync │   ║
                        ║   physical media │ data diode    ║
                        ╚═══════════════════════┬═══════════╝
                                                │
┌───────────────────────────────────────────────▼─────────────┐
│  AIR-GAPPED VPC (no IGW, no NAT)                            │
│                                                             │
│   ┌────────────────────────────────────────────────────┐   │
│   │  INTERNAL REPOSITORIES                             │   │
│   │  ├─ ECR (private, via VPC endpoint)                │   │
│   │  ├─ S3 artifact bucket (via gateway endpoint)      │   │
│   │  ├─ Nexus/Artifactory (yum, maven, helm, pypi)     │   │
│   │  └─ Internal Git (flows, IaC)                      │   │
│   └───────────────────────┬────────────────────────────┘   │
│                           │                                 │
│   ┌───────────────────────▼────────────────────────────┐   │
│   │  WORKLOAD                                          │   │
│   │  EKS cluster (private endpoint only)               │   │
│   │  ├─ NiFi        ├─ Kafka        ├─ Keycloak        │   │
│   └────────────────────────────────────────────────────┘   │
│                                                             │
│   VPC ENDPOINTS (the ONLY way out):                        │
│   ecr.api │ ecr.dkr │ s3 │ sts │ ec2 │ eks │ logs │ ssm    │
└─────────────────────────────────────────────────────────────┘
```

### Required VPC Endpoints

**Without these, nothing works.** No NAT gateway means no route to AWS APIs except through endpoints.

```hcl
locals {
  interface_endpoints = [
    "ecr.api",              # ECR authentication
    "ecr.dkr",              # ECR image pulls
    "sts",                  # IRSA token exchange — REQUIRED
    "ec2",                  # EBS volume attach
    "ec2messages",          # SSM
    "ssm",                  # Systems Manager
    "ssmmessages",          # SSM Session Manager
    "elasticloadbalancing", # ALB controller
    "autoscaling",
    "logs",                 # CloudWatch Logs
    "monitoring",           # CloudWatch Metrics
    "secretsmanager",       # secrets
    "kms",                  # encryption
    "eks",                  # EKS API
    "elasticfilesystem",    # if using EFS
    "sqs", "sns",           # if NiFi uses them
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true            # ⚠️ CRITICAL — see gotcha below

  tags = { Name = "vpce-${each.value}" }
}

# S3 and DynamoDB are GATEWAY endpoints (free, route-table based)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

resource "aws_security_group" "vpce" {
  name   = "vpc-endpoints"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}
```

> 🔴 **Gotcha #41 — `private_dns_enabled = true` is not optional.** Without it, `ecr.us-east-1.amazonaws.com` resolves to a public IP with no route, and image pulls hang until timeout. The symptom is `ImagePullBackOff` with a vague network error. This single flag causes more air-gap debugging hours than anything else.

> 🔴 **Gotcha #42 — Interface endpoints cost money.** Roughly **$7.30/month each**, plus data processing. The list above is ~16 endpoints ≈ **$117/month** before traffic. Audit which you actually need. S3 and DynamoDB gateway endpoints are free — always use those.

> ⚠️ **Gotcha #43 — ECR pulls need BOTH `ecr.api` and `ecr.dkr` AND the S3 gateway endpoint.** ECR stores image layers in S3. With only the two ECR endpoints, authentication succeeds and then layer download fails. This looks baffling until you know.

---

<a name="29-airgap-mirroring"></a>
## 29. Mirroring: Getting Artifacts Across

### Step 29.1 — Build the Manifest (On the Connected Side)

```bash
#!/usr/bin/env bash
# manifest.sh — declare EVERYTHING you need
set -euo pipefail

cat > artifact-manifest.yaml <<'EOF'
versions:
  nifi:      "2.10.0"
  kafka:     "4.3.0"
  scala:     "2.13"
  keycloak:  "26.7.0"
  java:      "21"
  k8s:       "1.36"

apache_artifacts:
  - url: https://archive.apache.org/dist/nifi/2.10.0/nifi-2.10.0-bin.zip
    sha512: https://archive.apache.org/dist/nifi/2.10.0/nifi-2.10.0-bin.zip.sha512
  - url: https://archive.apache.org/dist/nifi/2.10.0/nifi-toolkit-2.10.0-bin.zip
    sha512: https://archive.apache.org/dist/nifi/2.10.0/nifi-toolkit-2.10.0-bin.zip.sha512
  - url: https://archive.apache.org/dist/kafka/4.3.0/kafka_2.13-4.3.0.tgz
    sha512: https://archive.apache.org/dist/kafka/4.3.0/kafka_2.13-4.3.0.tgz.sha512

container_images:
  # base images
  - public.ecr.aws/amazonlinux/amazonlinux:2023
  - public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless
  - quay.io/keycloak/keycloak:26.7.0
  # EKS add-ons — these are pulled by the CLUSTER, easy to forget
  - 602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon-k8s-cni:v1.19.0
  - 602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.11.3
  - 602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/kube-proxy:v1.36.0
  - 602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/aws-ebs-csi-driver:v1.35.0
  - registry.k8s.io/metrics-server/metrics-server:v0.7.2
  # tooling
  - registry.k8s.io/pause:3.10

jdbc_drivers:
  - https://jdbc.postgresql.org/download/postgresql-42.7.4.jar
  - https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre11/mssql-jdbc-12.8.1.jre11.jar

helm_charts:
  - repo: https://aws.github.io/eks-charts
    chart: aws-load-balancer-controller
    version: "1.10.0"
  - repo: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    version: "65.0.0"

terraform_providers:
  - hashicorp/aws ~> 5.60
  - hashicorp/kubernetes ~> 2.31
  - hashicorp/helm ~> 2.14

ansible_collections:
  - amazon.aws
  - community.docker
  - kubernetes.core
  - ansible.posix
EOF

echo "Manifest written. Review before downloading."
```

### Step 29.2 — Download Everything

```bash
#!/usr/bin/env bash
# download-bundle.sh — run on the CONNECTED host
set -euo pipefail

BUNDLE_DIR="./airgap-bundle-$(date +%Y%m%d)"
mkdir -p "${BUNDLE_DIR}"/{apache,images,drivers,charts,terraform,ansible,rpms}

# ══ 1. Apache artifacts + checksums ══
echo "═══ Apache artifacts ═══"
cd "${BUNDLE_DIR}/apache"
for pair in \
  "nifi/2.10.0/nifi-2.10.0-bin.zip" \
  "nifi/2.10.0/nifi-toolkit-2.10.0-bin.zip" \
  "kafka/4.3.0/kafka_2.13-4.3.0.tgz"
do
  base="https://archive.apache.org/dist/${pair}"
  curl -fSLO "${base}"
  curl -fSLO "${base}.sha512"
done

# VERIFY every download before bundling
for f in *.zip *.tgz; do
  echo "$(awk '{print $1}' "${f}.sha512")  ${f}" | sha512sum -c - \
    || { echo "❌ CHECKSUM FAILED: ${f}"; exit 1; }
done
cd -

# ══ 2. Container images ══
echo "═══ Container images ═══"
IMAGES=(
  "public.ecr.aws/amazonlinux/amazonlinux:2023"
  "public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless"
  "quay.io/keycloak/keycloak:26.7.0"
  "registry.k8s.io/metrics-server/metrics-server:v0.7.2"
)

for img in "${IMAGES[@]}"; do
  echo "Pulling ${img}"
  docker pull --platform linux/amd64 "${img}"
  safe=$(echo "${img}" | tr '/:' '__')
  docker save "${img}" | gzip > "${BUNDLE_DIR}/images/${safe}.tar.gz"
done

# ══ 3. JDBC drivers ══
echo "═══ JDBC drivers ═══"
cd "${BUNDLE_DIR}/drivers"
curl -fSLO https://jdbc.postgresql.org/download/postgresql-42.7.4.jar
curl -fSLO https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre11/mssql-jdbc-12.8.1.jre11.jar
sha256sum *.jar > SHA256SUMS
cd -

# ══ 4. Helm charts (with dependencies) ══
echo "═══ Helm charts ═══"
helm repo add eks https://aws.github.io/eks-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm pull eks/aws-load-balancer-controller --version 1.10.0 -d "${BUNDLE_DIR}/charts"
helm pull prometheus-community/kube-prometheus-stack --version 65.0.0 -d "${BUNDLE_DIR}/charts"

# ══ 5. Terraform providers ══
echo "═══ Terraform providers ═══"
mkdir -p "${BUNDLE_DIR}/terraform"
cd "${BUNDLE_DIR}/terraform"
cat > providers.tf <<'EOF'
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.60" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.14" }
  }
}
EOF
# This downloads providers for the TARGET platform into a local mirror
terraform providers mirror -platform=linux_amd64 ./provider-mirror
cd -

# ══ 6. Ansible collections ══
echo "═══ Ansible collections ═══"
for c in amazon.aws community.docker kubernetes.core ansible.posix; do
  ansible-galaxy collection download "$c" -p "${BUNDLE_DIR}/ansible"
done

# ══ 7. OS packages (for EC2 deployments) ══
echo "═══ RPM packages ═══"
# Run inside a matching container to get the right architecture
docker run --rm -v "$(pwd)/${BUNDLE_DIR}/rpms:/out" \
  public.ecr.aws/amazonlinux/amazonlinux:2023 bash -c '
    dnf install -y dnf-plugins-core createrepo_c
    dnf download --resolve --alldeps --destdir=/out \
      java-21-amazon-corretto-headless unzip jq nvme-cli \
      amazon-cloudwatch-agent xfsprogs
    createrepo_c /out
  '

# ══ 8. Seal the bundle ══
echo "═══ Creating bundle ═══"
tar -czf "${BUNDLE_DIR}.tar.gz" "${BUNDLE_DIR}"
sha256sum "${BUNDLE_DIR}.tar.gz" > "${BUNDLE_DIR}.tar.gz.sha256"

# Sign it so the receiving side can verify authenticity
gpg --detach-sign --armor "${BUNDLE_DIR}.tar.gz"

du -sh "${BUNDLE_DIR}.tar.gz"
echo "✅ Bundle ready. Expect 8-15 GB."
```

> 💡 **Expect the bundle to be large.** A full NiFi + Kafka + Keycloak + EKS add-on bundle typically runs **8–15 GB**. Plan your transfer medium accordingly.

### Step 29.3 — Transfer

| Method | Speed | Security | Notes |
|---|---|---|---|
| **S3 cross-account** ⭐ | Fast | 🟢 Good | Bucket policy + KMS; most common for AWS air-gap |
| **AWS DataSync** | Fast | 🟢 Good | For very large or recurring transfers |
| **Physical media (USB/DVD)** | Slow | 🟢 Highest | True air gap; scan on arrival |
| **AWS Snowball** | Very fast for TBs | 🟢 Good | Multi-TB initial seed |
| **Data diode** | Moderate | 🟢 Highest | One-way hardware; defense sector |

```bash
# S3 cross-account transfer
aws s3 cp "${BUNDLE_DIR}.tar.gz" \
  "s3://airgap-transfer-bucket/inbound/" \
  --sse aws:kms --sse-kms-key-id "${KMS_KEY_ID}"

# On the air-gapped side (via S3 gateway endpoint)
aws s3 cp "s3://airgap-transfer-bucket/inbound/${BUNDLE_DIR}.tar.gz" .
sha256sum -c "${BUNDLE_DIR}.tar.gz.sha256"
gpg --verify "${BUNDLE_DIR}.tar.gz.asc"     # verify signature
tar -xzf "${BUNDLE_DIR}.tar.gz"
```

### Step 29.4 — Load Into Internal Repositories

```bash
#!/usr/bin/env bash
# load-bundle.sh — run INSIDE the air-gapped network
set -euo pipefail

BUNDLE_DIR="./airgap-bundle-20260720"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="us-east-1"
ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ══ 1. Load container images into internal ECR ══
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR}"

for tarball in "${BUNDLE_DIR}"/images/*.tar.gz; do
  echo "Loading ${tarball}"
  ORIGINAL=$(gunzip -c "${tarball}" | docker load | sed -n 's/^Loaded image: //p')

  # Re-tag to point at INTERNAL ECR
  # public.ecr.aws/amazoncorretto/amazoncorretto:21 → mirror/amazoncorretto:21
  REPO_PATH="mirror/$(echo "${ORIGINAL}" | sed 's|^[^/]*/||' | cut -d: -f1)"
  TAG=$(echo "${ORIGINAL}" | rev | cut -d: -f1 | rev)

  aws ecr describe-repositories --repository-names "${REPO_PATH}" --region "${REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "${REPO_PATH}" --region "${REGION}" \
         --image-scanning-configuration scanOnPush=true

  docker tag "${ORIGINAL}" "${ECR}/${REPO_PATH}:${TAG}"
  docker push "${ECR}/${REPO_PATH}:${TAG}"
  echo "✅ ${ORIGINAL} → ${ECR}/${REPO_PATH}:${TAG}"
done

# ══ 2. Upload Apache artifacts to internal S3 ══
aws s3 sync "${BUNDLE_DIR}/apache/" "s3://internal-artifacts/apache/" --sse AES256
aws s3 sync "${BUNDLE_DIR}/drivers/" "s3://internal-artifacts/drivers/" --sse AES256

# ══ 3. Publish Helm charts to internal repo (Nexus/Artifactory) ══
for chart in "${BUNDLE_DIR}"/charts/*.tgz; do
  curl -u "${NEXUS_USER}:${NEXUS_PASS}" \
    --upload-file "${chart}" \
    "https://nexus.internal/repository/helm-hosted/$(basename "${chart}")"
done

# ══ 4. Publish RPM repo ══
aws s3 sync "${BUNDLE_DIR}/rpms/" "s3://internal-artifacts/rpm/al2023/" --sse AES256

echo "✅ All artifacts loaded"
```

### Step 29.5 — Point Everything at Internal Sources

**Dockerfile — internal base image:**
```dockerfile
# BEFORE (needs internet):
# FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless

# AFTER (internal mirror):
ARG INTERNAL_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
FROM ${INTERNAL_REGISTRY}/mirror/amazoncorretto:21-al2023-headless AS builder

# BEFORE: RUN curl -fSL https://archive.apache.org/dist/nifi/...
# AFTER:  pull from internal S3 via VPC endpoint
ARG ARTIFACT_BUCKET=internal-artifacts
RUN --mount=type=secret,id=aws,target=/root/.aws/credentials \
    aws s3 cp "s3://${ARTIFACT_BUCKET}/apache/nifi-2.10.0-bin.zip" /build/nifi.zip
```

**dnf/yum — internal repo:**
```bash
cat > /etc/yum.repos.d/internal.repo <<'EOF'
[internal-al2023]
name=Internal AL2023 Mirror
baseurl=https://s3.us-east-1.amazonaws.com/internal-artifacts/rpm/al2023/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-internal
EOF

# Disable ALL default repos so nothing tries to reach the internet
dnf config-manager --disable amazonlinux amazonlinux-source 2>/dev/null || true
```

**Terraform — provider mirror:**
```hcl
# ~/.terraformrc
provider_installation {
  filesystem_mirror {
    path    = "/opt/terraform/provider-mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct { exclude = ["registry.terraform.io/*/*"] }
}
```

**Helm — internal repo:**
```bash
helm repo add internal https://nexus.internal/repository/helm-hosted/
helm repo update
helm install aws-load-balancer-controller internal/aws-load-balancer-controller --version 1.10.0
```

**Ansible — offline collections:**
```bash
ansible-galaxy collection install \
  /opt/bundle/ansible/amazon-aws-*.tar.gz \
  /opt/bundle/ansible/kubernetes-core-*.tar.gz \
  -p /etc/ansible/collections
```

**EKS add-ons — internal image registry:**
```bash
# Override the default images in the VPC CNI DaemonSet
kubectl -n kube-system set image daemonset/aws-node \
  aws-node="${ECR}/mirror/amazon-k8s-cni:v1.19.0"
```

---

<a name="30-airgap-nifi-flow"></a>
## 30. Air-Gapped NiFi Flow Migration (Complete Worked Example)

**Scenario:** A flow was developed on an internet-connected dev cluster. It must now run in a fully air-gapped production enclave.

### Phase A — On the Connected Dev Side

```bash
#!/usr/bin/env bash
# export-flow-bundle.sh
set -euo pipefail

EXPORT_DIR="./flow-bundle-$(date +%Y%m%d)"
mkdir -p "${EXPORT_DIR}"/{flow,nars,drivers,docs}

DEV_NIFI="https://nifi-dev.corp.internal:8443"
TOKEN="${NIFI_TOKEN}"
PG_ID="${1:?Usage: $0 <process-group-id>}"

# ── 1. Export the flow definition ──
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${DEV_NIFI}/nifi-api/process-groups/${PG_ID}/download?includeReferencedServices=true" \
  -o "${EXPORT_DIR}/flow/flow-definition.json"

# ── 2. Extract the dependency list from the flow itself ──
echo "═══ Processor types used ═══"
jq -r '.. | .type? // empty | select(type=="string") | select(test("^org\\.apache\\.nifi|^com\\."))' \
  "${EXPORT_DIR}/flow/flow-definition.json" | sort -u \
  > "${EXPORT_DIR}/docs/component-types.txt"

# ── 3. Find which NAR provides each component ──
echo "═══ Required bundles ═══"
jq -r '.. | .bundle? // empty | "\(.group):\(.artifact):\(.version)"' \
  "${EXPORT_DIR}/flow/flow-definition.json" | sort -u \
  > "${EXPORT_DIR}/docs/required-bundles.txt"
cat "${EXPORT_DIR}/docs/required-bundles.txt"

# ── 4. Copy any NON-STANDARD NARs ──
while IFS=: read -r group artifact version; do
  # Skip bundles that ship with stock NiFi
  if ! grep -q "^${artifact}$" ./stock-nifi-2.10.0-bundles.txt 2>/dev/null; then
    echo "Custom bundle needed: ${artifact}-${version}"
    scp "nifi-dev:/opt/nifi/extensions/${artifact}-${version}.nar" \
        "${EXPORT_DIR}/nars/" 2>/dev/null || \
      echo "⚠️  Could not find ${artifact}-${version}.nar — locate manually"
  fi
done < "${EXPORT_DIR}/docs/required-bundles.txt"

# ── 5. Document sensitive properties that must be re-entered ──
jq -r '.. | select(.properties? != null)
  | . as $c
  | .properties | to_entries[]
  | select(.value == null)
  | "\($c.name // "unknown")  →  \(.key)"' \
  "${EXPORT_DIR}/flow/flow-definition.json" | sort -u \
  > "${EXPORT_DIR}/docs/sensitive-properties-checklist.txt"

echo "═══ You must re-enter these on the target ═══"
cat "${EXPORT_DIR}/docs/sensitive-properties-checklist.txt"

# ── 6. Document environment-specific values needing change ──
jq -r '.. | select(.properties? != null)
  | . as $c
  | .properties | to_entries[]
  | select(.value != null)
  | select(.value | tostring | test("https?://|jdbc:|s3://|:[0-9]{2,5}|/data/|\\.internal|\\.corp"))
  | "\($c.name // "?")  |  \(.key)  =  \(.value)"' \
  "${EXPORT_DIR}/flow/flow-definition.json" | sort -u \
  > "${EXPORT_DIR}/docs/environment-specific-values.txt"

echo "═══ Review these for environment changes ═══"
cat "${EXPORT_DIR}/docs/environment-specific-values.txt"

# ── 7. Copy JDBC drivers referenced by the flow ──
grep -oE '[a-zA-Z0-9._-]+\.jar' "${EXPORT_DIR}/docs/environment-specific-values.txt" \
  | sort -u | while read -r jar; do
    scp "nifi-dev:/opt/nifi/lib/${jar}" "${EXPORT_DIR}/drivers/" 2>/dev/null || true
  done

# ── 8. Write a migration README ──
cat > "${EXPORT_DIR}/docs/MIGRATION-README.md" <<EOF
# Flow Migration Bundle
Generated: $(date -u +%FT%TZ)
Source: ${DEV_NIFI}
Process Group: ${PG_ID}

## Contents
- flow/flow-definition.json    → import into target NiFi
- nars/                        → copy into the target image
- drivers/                     → copy into the target image
- docs/sensitive-properties-checklist.txt  → MUST re-enter manually
- docs/environment-specific-values.txt     → MUST review and update

## Target Requirements
- NiFi version: 2.10.0 or later
- Required bundles: see required-bundles.txt
EOF

# ── 9. Seal and checksum ──
tar -czf "${EXPORT_DIR}.tar.gz" "${EXPORT_DIR}"
sha256sum "${EXPORT_DIR}.tar.gz" > "${EXPORT_DIR}.tar.gz.sha256"
gpg --detach-sign --armor "${EXPORT_DIR}.tar.gz"

echo "✅ Flow bundle ready: ${EXPORT_DIR}.tar.gz"
```

### Phase B — Transfer

```bash
# Scan before transfer (required in most regulated environments)
clamscan -r "${EXPORT_DIR}.tar.gz"

# Transfer via approved channel
aws s3 cp "${EXPORT_DIR}.tar.gz"        s3://airgap-transfer/flows/ --sse aws:kms
aws s3 cp "${EXPORT_DIR}.tar.gz.sha256" s3://airgap-transfer/flows/ --sse aws:kms
aws s3 cp "${EXPORT_DIR}.tar.gz.asc"    s3://airgap-transfer/flows/ --sse aws:kms
```

### Phase C — Inside the Air Gap

```bash
#!/usr/bin/env bash
# import-flow-bundle.sh — run in the air-gapped enclave
set -euo pipefail

BUNDLE="flow-bundle-20260720"

# ── 1. Verify integrity and authenticity ──
sha256sum -c "${BUNDLE}.tar.gz.sha256" || { echo "❌ Checksum mismatch"; exit 1; }
gpg --verify "${BUNDLE}.tar.gz.asc"    || { echo "❌ Signature invalid"; exit 1; }
tar -xzf "${BUNDLE}.tar.gz"

# ── 2. Read the checklist BEFORE doing anything ──
cat "${BUNDLE}/docs/MIGRATION-README.md"
cat "${BUNDLE}/docs/sensitive-properties-checklist.txt"

# ── 3. Add NARs and drivers to the internal image ──
cp "${BUNDLE}"/nars/*.nar    ~/data-platform/nifi/custom-nars/
cp "${BUNDLE}"/drivers/*.jar ~/data-platform/nifi/drivers/

# ── 4. Rebuild the image from INTERNAL sources ──
ECR="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com"
docker buildx build \
  --platform linux/amd64 \
  --build-arg INTERNAL_REGISTRY="${ECR}" \
  --build-arg ARTIFACT_BUCKET=internal-artifacts \
  -t "${ECR}/data-platform/nifi:2.10.0-build.5" \
  --push ~/data-platform/nifi

# ── 5. Deploy ──
kubectl -n data-platform set image statefulset/nifi \
  nifi="${ECR}/data-platform/nifi:2.10.0-build.5"
kubectl -n data-platform rollout status statefulset/nifi --timeout=20m

# ── 6. Confirm NARs loaded ──
kubectl -n data-platform exec nifi-0 -- ls -1 /opt/nifi/extensions/
kubectl -n data-platform logs nifi-0 | grep -iE "loaded|nar" | tail -30

# ── 7. Import the flow ──
NEW_NIFI="https://nifi.airgap.internal"
TOKEN=$(curl -sk -X POST "${NEW_NIFI}/nifi-api/access/token" \
  -d "username=admin&password=${ADMIN_PASSWORD}")

ROOT_PG=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${NEW_NIFI}/nifi-api/flow/process-groups/root" \
  | jq -r '.processGroupFlow.id')

jq '{
  revision: { version: 0 },
  component: { position: { x: 0, y: 0 }, name: "Migrated Production Flow" },
  disconnectedNodeAcknowledged: false,
  versionedFlowSnapshot: .
}' "${BUNDLE}/flow/flow-definition.json" > /tmp/import.json

NEW_PG=$(curl -sk -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  "${NEW_NIFI}/nifi-api/process-groups/${ROOT_PG}/process-groups" \
  -d @/tmp/import.json | jq -r '.id')

echo "✅ Imported as process group ${NEW_PG}"

# ── 8. Validate ──
echo "═══ Ghost processors (missing NARs) ═══"
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${NEW_NIFI}/nifi-api/flow/process-groups/${NEW_PG}?recursive=true" \
  | jq -r '.. | .component? // empty | select(.extensionMissing == true) | "👻 \(.type)"'

echo "═══ Invalid components ═══"
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${NEW_NIFI}/nifi-api/flow/process-groups/${NEW_PG}?recursive=true" \
  | jq -r '.. | .component? // empty
      | select(.validationStatus == "INVALID")
      | "❌ \(.name): \(.validationErrors // [] | join("; "))"'
```

### Phase D — Manual Completion

```
☐ Re-enter every sensitive property from the checklist
☐ Update all environment-specific values (hostnames, buckets, paths)
☐ Recreate Parameter Contexts with air-gap values
☐ Enable controller services in dependency order
☐ Verify zero ghost processors
☐ Verify zero invalid components
☐ Test with a small sample batch
☐ Enable source processors
```

### Air-Gap Specific Flow Gotchas

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 44 | Processor calls an external API | Times out, endless retries | Replace with internal equivalent, or route via internal proxy |
| 45 | `InvokeHTTP` to a public URL | Connection refused | Point at internal service |
| 46 | Flow references a public S3 bucket | Access denied | Mirror to internal bucket, update the path |
| 47 | Missing JDBC driver | Controller service won't enable | Bake the JAR into the image |
| 48 | Schema Registry unreachable | Avro processors fail | Deploy internal registry, or use inline schemas |
| 49 | TLS trust failure to internal CA | `PKIX path building failed` | Import internal CA into NiFi truststore **and** the JVM cacerts |
| 50 | NTP not configured | Token validation fails (clock skew) | Configure internal NTP; Keycloak tokens are time-sensitive |

> 🔴 **Gotcha #49 in detail — this one is subtle.** NiFi has *two* trust stores: `conf/truststore.p12` (for NiFi's own TLS) and the JVM's `cacerts` (used by some libraries and by OIDC discovery). Import your internal CA into **both**:
> ```bash
> keytool -importcert -alias internal-ca -file internal-ca.crt \
>   -keystore /opt/nifi/conf/truststore.p12 -storetype PKCS12
> keytool -importcert -alias internal-ca -file internal-ca.crt \
>   -keystore "${JAVA_HOME}/lib/security/cacerts" -storepass changeit
> ```

---

<a name="31-airgap-ongoing"></a>
## 31. Ongoing Air-Gap Operations

### The Patching Problem

**This is the hardest part of air-gapped operations and the most commonly underestimated.** Every patch requires a full mirror cycle.

```
Week 1: CVE announced
Week 2: Download + verify on connected side
Week 3: Security review + approval
Week 4: Transfer across air gap
Week 5: Test in air-gapped staging
Week 6: Deploy to production
```

Six weeks is a *good* cycle in a regulated air-gapped environment. Compare to hours in a connected one.

### Recommended Cadence

| Layer | Connected Cadence | Realistic Air-Gap Cadence |
|---|---|---|
| Base OS / container images | Weekly | **Monthly** bundle drop |
| NiFi / Kafka / Keycloak | As released | **Quarterly**, unless critical CVE |
| EKS Kubernetes version | Every 6–12 months | **Annually**, before EOL |
| Emergency CVE | Same day | **Expedited path: 3–5 days** |

> 💡 **Define your emergency path in advance.** Write the runbook, get the approvals pre-authorized, and *rehearse it* before a real emergency. An untested emergency process fails when you need it.

### Automated Bundle Refresh

```yaml
# .github/workflows/airgap-bundle.yml (runs on the CONNECTED side)
name: Monthly Air-Gap Bundle

on:
  schedule:
    - cron: '0 2 1 * *'      # 1st of each month
  workflow_dispatch:

jobs:
  bundle:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build bundle
        run: ./scripts/download-bundle.sh

      - name: Scan every image for CVEs
        run: |
          for img in $(yq '.container_images[]' artifact-manifest.yaml); do
            trivy image --severity CRITICAL,HIGH --format json \
              --output "reports/$(echo $img | tr '/:' '__').json" "$img"
          done

      - name: Generate SBOM for the whole bundle
        run: syft dir:./airgap-bundle -o cyclonedx-json > bundle-sbom.json

      - name: Sign the bundle
        run: |
          sha256sum airgap-bundle-*.tar.gz > bundle.sha256
          cosign sign-blob --yes airgap-bundle-*.tar.gz \
            --output-signature bundle.sig

      - name: Stage for transfer
        run: |
          aws s3 cp airgap-bundle-*.tar.gz s3://airgap-transfer/bundles/ --sse aws:kms
          aws s3 cp bundle-sbom.json       s3://airgap-transfer/bundles/ --sse aws:kms
          aws s3 cp bundle.sig             s3://airgap-transfer/bundles/ --sse aws:kms
```

### Air-Gap Readiness Checklist

**Before you start:**
```
☐ Complete dependency manifest written and reviewed
☐ Tested the full stack in a network-isolated sandbox
☐ Every VPC endpoint identified and cost-approved
☐ Internal ECR / S3 / Nexus / Git provisioned
☐ Internal CA established; certs issued
☐ Internal NTP configured (clock skew breaks OIDC)
☐ Internal DNS zones created
☐ Transfer channel approved by security
☐ GPG/Cosign signing keys established on both sides
☐ Scanning process defined for inbound artifacts
```

**Ongoing:**
```
☐ Monthly bundle refresh scheduled and owned by a named person
☐ Emergency CVE path documented AND rehearsed
☐ Internal repo storage monitored (bundles are 10 GB+ each)
☐ Retention policy for old bundles (keep 3, delete the rest)
☐ Quarterly disaster recovery test
☐ Annual EKS version upgrade planned before EOL
```

### Air-Gap Cost Additions

| Item | Est. Monthly |
|---|---|
| VPC interface endpoints (~16) | ~$117 |
| Internal Nexus/Artifactory (m6i.xlarge + 1 TB) | ~$250 |
| S3 artifact storage (500 GB, versioned) | ~$15 |
| ECR storage (mirrored images, 200 GB) | ~$20 |
| Transfer bucket + KMS | ~$10 |
| Staging/build host (connected side) | ~$70 |
| **Air-gap overhead** | **~$480/mo** |

Add that to the ~$1,100/month baseline from Section 18 → roughly **$1,580/month** for an air-gapped data platform.

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

# ── EC2 (systemd) ──
sudo systemctl status nifi
sudo journalctl -u nifi -f --since "10 min ago"
sudo ln -sfn /opt/nifi-2.9.0 /opt/nifi && sudo systemctl restart nifi   # rollback

# ── Keycloak ──
TOKEN=$(curl -sk -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&username=admin&password=${KC_PW}&grant_type=password" | jq -r .access_token)
curl -sk "${KC_URL}/realms/data-platform/.well-known/openid-configuration" | jq .issuer
curl -sk "${KC_URL}/admin/realms/data-platform/partial-export?exportClients=true&exportGroupsAndRoles=true" \
  -H "Authorization: Bearer ${TOKEN}" > realm-backup.json

# ── Flow migration ──
curl -sk -H "Authorization: Bearer ${TOKEN}" \
  "${NIFI}/nifi-api/process-groups/${PG_ID}/download?includeReferencedServices=true" -o flow.json
curl -sk -H "Authorization: Bearer ${TOKEN}" "${NIFI}/nifi-api/flow/process-groups/${PG}?recursive=true" \
  | jq -r '.. | .component? // empty | select(.extensionMissing==true) | "MISSING NAR: \(.type)"'

# ── Air gap ──
docker save IMG | gzip > img.tar.gz          # export
gunzip -c img.tar.gz | docker load           # import
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[*].{Svc:ServiceName,DNS:PrivateDnsEnabled}' --output table

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

**Week 5 — Add identity**
13. Stand up Keycloak with a real Postgres (Part 6).
14. Wire NiFi to it via OIDC. Expect the redirect URI to be wrong the first three times.
15. Map Keycloak groups to NiFi authorization policies.

**Week 6 — Practice migration**
16. Build a flow on one cluster, export it, import it on another (Part 7).
17. Deliberately omit a custom NAR so you see what a ghost processor looks like.
18. Write your own sensitive-properties checklist.

**Week 7+ — Air gap (only if you need it)**
19. Build the dependency manifest (Part 8). It will be longer than you expect.
20. Test the entire stack in a VPC with **no NAT gateway**. This is the real test.
21. Do one full monthly bundle cycle end to end before going live.

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
| Keycloak Documentation | https://www.keycloak.org/documentation |
| Keycloak Releases & CVEs | https://www.keycloak.org/ |
| NiFi Registry / Flow Registry | https://nifi.apache.org/projects/registry/ |
| NiFi REST API Reference | https://nifi.apache.org/docs/nifi-docs/rest-api/ |
| AWS VPC Endpoints Guide | https://docs.aws.amazon.com/vpc/latest/privatelink/ |
| EKS in Air-Gapped Environments | https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html |

---

*Verified against versions current as of July 20, 2026: NiFi 2.10.0, Kafka 4.3.x, EKS 1.36, Keycloak 26.7.0. These move fast — run `check-versions.sh` before building. Keycloak in particular ships frequent security fixes; treat it as high-priority patching since it is the front door to everything else.*
