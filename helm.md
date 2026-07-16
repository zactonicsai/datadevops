# The Complete Helm Tutorial: From Zero to Air-Gapped AWS EKS

**Covering:** Helm fundamentals · Offline / air-gapped usage · AWS EKS · Web servers & load balancers · Karpenter scale-to-zero on a work-hours schedule · Kafka with Strimzi · Apache NiFi · Monitoring, cert-manager, and more

**Last verified:** July 2026 (Helm 4.2.x / 3.21.x, Karpenter v1 API ~1.13, Strimzi 1.1.x with Kafka 4.1 KRaft, Apache NiFi 2.x)

---

## Table of Contents

1. [Background: What Problem Does Helm Solve?](#1-background-what-problem-does-helm-solve)
2. [How Helm Works — The Core Concepts](#2-how-helm-works--the-core-concepts)
3. [Step-by-Step: Your First Helm Deployment (Simple Web Server)](#3-step-by-step-your-first-helm-deployment)
4. [Deep Dive: Anatomy of a Helm Chart](#4-deep-dive-anatomy-of-a-helm-chart)
5. [Helm Versions: v3 vs v4, and What's New](#5-helm-versions-v3-vs-v4)
6. [Helm Offline / Air-Gapped: Complete Guide](#6-helm-offline--air-gapped-complete-guide)
7. [AWS EKS Setup (Online Bootstrap + Air-Gapped Notes)](#7-aws-eks-setup)
8. [Example 1: Web Server + AWS Load Balancers on EKS](#8-example-1-web-server--aws-load-balancers-on-eks)
9. [Example 2: Karpenter — Autoscaling and Scale-to-Zero on Work Hours](#9-example-2-karpenter--autoscaling-and-scale-to-zero-on-work-hours)
10. [Example 3: Kafka on EKS with Strimzi](#10-example-3-kafka-on-eks-with-strimzi)
11. [Example 4: Apache NiFi on EKS](#11-example-4-apache-nifi-on-eks)
12. [More Essential Charts: cert-manager, Monitoring, KEDA](#12-more-essential-charts)
13. [Best Practices Summary](#13-best-practices-summary)
14. [Troubleshooting Cheat Sheet](#14-troubleshooting-cheat-sheet)
15. [Glossary](#15-glossary)

---

# 1. Background: What Problem Does Helm Solve?

## 1.1 First, a 60-second Kubernetes refresher

Kubernetes (often written **K8s**) is a system that runs your applications inside **containers** (lightweight, portable boxes that hold your app and everything it needs) across a fleet of machines called **nodes**. You tell Kubernetes what you want by writing **YAML manifests** — text files that describe things like:

- **Deployment** — "run 3 copies of my web server"
- **Service** — "give those copies one stable network address"
- **Ingress** — "route web traffic from the outside world to that service"
- **ConfigMap / Secret** — "here is my app's configuration and passwords"
- **PersistentVolumeClaim (PVC)** — "give my app some disk space that survives restarts"

You apply these files with `kubectl apply -f file.yaml`, and Kubernetes makes reality match the file.

## 1.2 The problem: YAML sprawl

A *real* application is never one YAML file. A production web app might need 10–20 manifests. Kafka needs dozens. Now imagine:

- You need the **same app in dev, staging, and prod**, with different sizes, hostnames, and passwords. Do you copy-paste 20 files three times and hand-edit each? That's how mistakes happen.
- You want to **upgrade** the app. Which of the 20 files changed? What was running before? How do you **roll back** if it breaks?
- You want to **share** your app setup with another team, or install someone else's app (Kafka, Prometheus, NiFi). Do you email zip files of YAML around?

## 1.3 The solution: a package manager for Kubernetes

Think of how software gets installed on other systems:

| Platform | Package manager | Package format |
|---|---|---|
| Ubuntu Linux | `apt` | `.deb` |
| macOS | `brew` | formula |
| Python | `pip` | wheel |
| Windows | `winget` / `choco` | installer |
| **Kubernetes** | **`helm`** | **chart** |

**Helm is the package manager for Kubernetes.** It is a CNCF **graduated** project (the highest maturity level, same tier as Kubernetes itself) and the de-facto standard way to package, configure, install, upgrade, and roll back applications on Kubernetes.

A Helm package is called a **chart**. A chart contains:

1. **Templates** — your YAML manifests with placeholders (variables) in them
2. **Values** — a file of default settings that fill in those placeholders
3. **Metadata** — name, version, description, dependencies

When you install a chart, Helm combines *templates + your values*, renders final YAML, sends it to Kubernetes, and records the result as a **release** — a named, versioned installation that you can upgrade, inspect, and roll back.

## 1.4 Why this matters for offline / secure environments

Many organizations (government, defense, banking, healthcare, industrial plants, ships, remote sites) run **air-gapped** or **restricted-egress** networks: the Kubernetes cluster has **no path to the public internet**. That breaks the two things Helm-based installs normally reach out for:

1. **Charts** — normally downloaded from public chart repositories (like `https://charts.bitnami.com`) or OCI registries (`oci://public.ecr.aws/...`)
2. **Container images** — the actual software, normally pulled by the cluster from Docker Hub, quay.io, ghcr.io, public ECR, etc.

The good news: **Helm was designed to work fully offline.** A chart is just a `.tgz` file. Images are just blobs you can mirror into a private registry. Section 6 of this tutorial is a complete, step-by-step recipe for doing this correctly — and every example after it (web server, Karpenter, Kafka, NiFi) includes its **offline variant**.

---

# 2. How Helm Works — The Core Concepts

Before typing commands, let's build a clear mental model. Helm has five key nouns:

## 2.1 Chart
A **chart** is the package: a folder (or a `.tgz` archive of that folder) with a required layout:

```
mychart/
├── Chart.yaml          # metadata: name, version, appVersion, dependencies
├── values.yaml         # default configuration values
├── charts/             # dependency charts ("subcharts") live here
├── templates/          # the Kubernetes YAML templates
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── _helpers.tpl    # reusable template snippets
│   └── NOTES.txt       # message printed after install
└── .helmignore         # files to exclude when packaging
```

## 2.2 Values
**Values** are the knobs. `values.yaml` inside the chart holds defaults; you override them at install time with `--values myfile.yaml` (a file) or `--set key=value` (inline). Example:

```yaml
# values.yaml
replicaCount: 2
image:
  repository: nginx
  tag: "1.27"
service:
  type: ClusterIP
  port: 80
```

## 2.3 Templates
**Templates** are Kubernetes YAML with Go template syntax (`{{ ... }}`) that pulls from values:

```yaml
# templates/deployment.yaml (excerpt)
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: web
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

At install time, Helm renders this into plain YAML: `replicas: 2`, `image: "nginx:1.27"`.

## 2.4 Release
A **release** is one installed instance of a chart in a cluster, with a name you choose. You can install the *same chart many times* under different release names (e.g., `blog-nginx` and `shop-nginx`). Helm stores each release's full state (rendered manifests, values used, chart version) as a **Secret** in the cluster namespace, one per **revision**. Every `helm upgrade` creates a new revision; `helm rollback` returns to an earlier one. This is Helm's "undo history."

```
Release "myweb"
 ├── revision 1  (install,  chart 1.0.0, values A)
 ├── revision 2  (upgrade,  chart 1.1.0, values A)
 └── revision 3  (rollback → contents of revision 1)
```

## 2.5 Repository / Registry
Where charts live:

- **Classic HTTP chart repository** — a web server hosting an `index.yaml` plus `.tgz` files. Used with `helm repo add` / `helm install repo/chart`.
- **OCI registry** *(the modern standard)* — charts stored in the same kind of registry as container images (ECR, Harbor, GHCR, Docker Hub). Used with `oci://` URLs: `helm install myrel oci://registry.example.com/charts/nginx --version 1.2.3`. **OCI is the recommended approach today**, and it is *especially* convenient offline because your private image registry can hold your charts too — one system to mirror, one system to secure.

## 2.6 What actually happens on `helm install` (the pipeline)

```
you run: helm install myweb ./mychart -f prod-values.yaml
                 │
                 ▼
 1. LOAD      Read Chart.yaml, values.yaml, templates/, subcharts
 2. MERGE     defaults ← chart values ← -f files ← --set flags   (rightmost wins)
 3. RENDER    Run Go templating → plain Kubernetes YAML
 4. VALIDATE  Check YAML against the cluster's known API schemas
 5. APPLY     Send objects to the Kubernetes API (in a smart order:
              Namespaces → ServiceAccounts → ConfigMaps/Secrets →
              ... → Deployments → Ingress, so dependencies exist first)
 6. RECORD    Save release revision 1 as a Secret in the namespace
 7. (WAIT)    With --wait, block until pods are Ready
 8. NOTES     Print templates/NOTES.txt to the user
```

Two crucial facts fall out of this:

- **Helm is client-side only** (since v3 removed the old "Tiller" server). The `helm` binary talks directly to the Kubernetes API using your normal kubeconfig credentials and RBAC. There is nothing to install *in* the cluster for Helm itself. This is a big win for secure environments — no privileged in-cluster agent.
- **Helm never pulls container images.** Helm only submits YAML. The **kubelet on each node** pulls images. This is *the* key insight for air-gapped work: making `helm install` work offline (charts) and making *pods start* offline (images) are two separate problems you must solve separately.

## 2.7 The everyday command set

| Command | What it does |
|---|---|
| `helm create mychart` | Scaffold a new chart skeleton |
| `helm lint ./mychart` | Check a chart for problems |
| `helm template myrel ./mychart` | Render YAML locally **without** touching the cluster (great for review/audit) |
| `helm install myrel ./mychart -n ns --create-namespace` | Install |
| `helm upgrade myrel ./mychart -f new.yaml` | Upgrade (add `--install` to "install if missing") |
| `helm list -A` | List releases in all namespaces |
| `helm status myrel` | Show release status |
| `helm get values myrel` | Show the values a release was installed with |
| `helm get manifest myrel` | Show the exact YAML Helm applied |
| `helm history myrel` | Show revisions |
| `helm rollback myrel 2` | Roll back to revision 2 |
| `helm uninstall myrel` | Remove the release and its resources |
| `helm package ./mychart` | Build `mychart-1.0.0.tgz` |
| `helm pull repo/chart --version 1.2.3` | **Download a chart as .tgz (the offline workhorse)** |
| `helm push chart.tgz oci://reg/charts` | Push a chart to an OCI registry |
| `helm show values repo/chart` | Print a chart's default values |
| `helm search repo kafka` | Search added repositories |

---

# 3. Step-by-Step: Your First Helm Deployment

Per the plan: **start with one complete, simple, step-by-step example**, then go deep. We'll build and install a tiny NGINX web server chart from scratch. This works on *any* Kubernetes cluster (EKS, minikube, kind, k3s) and needs nothing from the internet except the `nginx` image (offline variant noted at the end).

## Step 0 — Install the Helm CLI

Helm is a single static binary. Pick one:

```bash
# macOS
brew install helm

# Windows
winget install Helm.Helm

# Linux (script)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Linux (manual — this is also EXACTLY how you install on an offline machine:
# download the .tar.gz on a connected machine, carry it across, then:)
tar -zxvf helm-v4.2.0-linux-amd64.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm

helm version   # verify
```

> **Which version?** As of mid-2026, **Helm v4 is the current stable line** (v4.2.x); **Helm v3 (v3.21.x) is in maintenance** — bug fixes until July 2026 and security fixes until November 2026. New installs should use v4; everything in this tutorial works on both, and differences are called out in Section 5. Download binaries from the GitHub releases page for `helm/helm`.

Verify you can reach your cluster (Helm uses your kubeconfig):

```bash
kubectl get nodes
```

## Step 1 — Scaffold a chart

```bash
helm create hello-web
```

Helm generates a working chart that, by default, deploys NGINX. Look inside:

```bash
hello-web/
├── Chart.yaml
├── values.yaml
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── serviceaccount.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── _helpers.tpl
│   ├── NOTES.txt
│   └── tests/test-connection.yaml
└── charts/
```

## Step 2 — Understand and trim `Chart.yaml`

```yaml
apiVersion: v2            # chart API version (v2 = Helm 3/4 charts)
name: hello-web
description: My first Helm chart — a simple web server
type: application         # "application" or "library"
version: 0.1.0            # version of the CHART (bump on every chart change)
appVersion: "1.27"        # version of the APP inside (informational)
```

> **`version` vs `appVersion`:** `version` is the chart packaging version (SemVer, drives upgrades). `appVersion` just documents which app version the chart ships by default. They move independently.

## Step 3 — Set your values

Edit `values.yaml` (only the parts we care about):

```yaml
replicaCount: 2

image:
  repository: nginx          # for offline: my-registry.internal/mirror/nginx
  tag: "1.27"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP            # we'll switch this to LoadBalancer on EKS later
  port: 80

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

## Step 4 — Preview before you touch the cluster (always do this)

```bash
helm lint ./hello-web                 # static checks
helm template demo ./hello-web       # render full YAML to your terminal
helm install demo ./hello-web --dry-run --debug   # render + validate against cluster
```

`helm template` is your best friend in secure environments: security teams can **review the exact YAML** that will be applied, with zero cluster access.

## Step 5 — Install

```bash
helm install demo ./hello-web --namespace web --create-namespace
```

Output ends with the chart's `NOTES.txt` — instructions for reaching the app. Check it:

```bash
helm list -n web
kubectl get pods,svc -n web
```

You should see 2 `demo-hello-web-*` pods `Running` and a ClusterIP service. Test it:

```bash
kubectl -n web port-forward svc/demo-hello-web 8080:80
# open http://localhost:8080 → "Welcome to nginx!"
```

## Step 6 — Upgrade

Change `replicaCount: 3` in `values.yaml` (or don't edit the file and use `--set`):

```bash
helm upgrade demo ./hello-web -n web --set replicaCount=3
kubectl get pods -n web        # now 3 pods
helm history demo -n web       # revision 2 exists
```

## Step 7 — Roll back

```bash
helm rollback demo 1 -n web    # back to 2 replicas
helm history demo -n web       # revision 3 = "Rollback to 1"
```

## Step 8 — Package and uninstall

```bash
helm package ./hello-web            # → hello-web-0.1.0.tgz  (a portable chart!)
helm uninstall demo -n web
```

That `.tgz` file is the unit you carry into an air-gapped network. `helm install demo ./hello-web-0.1.0.tgz` works identically to installing from the folder — no internet, no repository, nothing else required.

> **Offline variant of this example:** the only external dependency is the `nginx` image. Mirror it to your private registry (Section 6.4) and set `image.repository: my-registry.internal/mirror/nginx`. Done — the chart itself is already fully offline.

---

# 4. Deep Dive: Anatomy of a Helm Chart

Now that you've shipped one, let's understand every moving part properly.

## 4.1 The template language

Helm templates use Go's `text/template` plus the [Sprig](http://masterminds.github.io/sprig/) function library plus Helm-specific additions. The essentials:

### Built-in objects

| Object | Contains |
|---|---|
| `.Values` | merged values (defaults + your overrides) |
| `.Release.Name`, `.Release.Namespace`, `.Release.Revision` | info about this release |
| `.Chart.Name`, `.Chart.Version`, `.Chart.AppVersion` | Chart.yaml fields |
| `.Capabilities.KubeVersion`, `.Capabilities.APIVersions` | what the target cluster supports |
| `.Files` | access to non-template files bundled in the chart |
| `.Template.Name` | path of the current template |

### Common patterns you'll read and write

```yaml
# defaults and fallbacks
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"

# conditionals
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
...
{{- end }}

# loops
env:
{{- range $key, $val := .Values.extraEnv }}
  - name: {{ $key }}
    value: {{ $val | quote }}
{{- end }}

# indentation-safe inclusion of a values block
resources:
  {{- toYaml .Values.resources | nindent 2 }}

# required values (fail fast with a clear message)
host: {{ required "You must set ingress.host!" .Values.ingress.host }}

# helpers defined in _helpers.tpl
labels:
  {{- include "hello-web.labels" . | nindent 4 }}
```

> **Whitespace control:** `{{-` trims whitespace/newlines to the left, `-}}` to the right. Most template bugs are indentation bugs; `helm template` + your eyes are the fix, and `nindent` is safer than `indent`.

### `_helpers.tpl` — DRY for templates

Files starting with `_` are never rendered as manifests; they hold named snippets:

```yaml
{{/* Common labels */}}
{{- define "hello-web.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

## 4.2 Dependencies (subcharts)

A chart can depend on other charts — e.g., your app chart depends on a PostgreSQL chart:

```yaml
# Chart.yaml
dependencies:
  - name: postgresql
    version: "16.x.x"
    repository: "oci://registry-1.docker.io/bitnamicharts"   # or https:// repo, or "file://../local-chart"
    condition: postgresql.enabled          # toggle from values
```

```bash
helm dependency update ./mychart   # downloads deps into charts/ and writes Chart.lock
helm dependency build ./mychart   # rebuilds charts/ exactly from Chart.lock (reproducible)
```

You configure a subchart from the parent's values under a key matching its name:

```yaml
postgresql:
  enabled: true
  auth:
    database: appdb
```

> **Offline note:** once `charts/` is populated and you `helm package`, the dependencies are **inside the .tgz**. A packaged umbrella chart is completely self-contained — perfect for air-gap transfer. `file://` repositories also let you vendor dependencies with zero network at build time.

## 4.3 Hooks — running jobs at lifecycle moments

Annotate any resource (usually a `Job`) to run it at a specific moment:

```yaml
metadata:
  annotations:
    "helm.sh/hook": pre-upgrade        # also: pre-install, post-install, pre-delete, post-delete, pre-rollback, post-rollback, test
    "helm.sh/hook-weight": "0"         # ordering among hooks
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

Classic use: database schema migration as a `pre-upgrade` hook. `helm test <release>` runs resources with the `test` hook — many public charts ship connectivity tests.

## 4.4 Values files strategy (the professional pattern)

Never fork a chart just to change settings. Layer values files instead:

```
values.yaml            # chart defaults (inside the chart — don't edit vendor charts)
values-common.yaml     # your org-wide overrides (registry URLs, labels, proxies)
values-prod.yaml       # environment-specific (sizes, hostnames, storage classes)
```

```bash
helm upgrade --install app ./chart \
  -f values-common.yaml -f values-prod.yaml \
  --set-string image.tag=2026.07.1        # last one wins
```

Precedence (lowest → highest): chart `values.yaml` → `-f` files left-to-right → `--set/--set-string/--set-file`.

## 4.5 Chart quality checklist (best practices)

- ✅ Every image reference built from `registry` + `repository` + `tag` values (air-gap friendly), ideally supporting a **global registry override** (`global.imageRegistry`) like Bitnami charts do.
- ✅ `resources` requests/limits configurable; sane defaults set.
- ✅ Labels via the standard `app.kubernetes.io/*` set in a helper.
- ✅ `helm lint` clean; CI runs `helm template` against a schema validator (e.g., `kubeconform`).
- ✅ `values.schema.json` provided so bad values fail fast at install time.
- ✅ No secrets committed in `values.yaml` — use `--set-file`, external secret operators, or SOPS-encrypted values files.
- ✅ SemVer discipline: bump chart `version` on **every** change.
- ✅ `NOTES.txt` tells the operator how to reach and verify the app.

---

# 5. Helm Versions: v3 vs v4

A quick orientation, because you will meet both in the wild in 2026:

| Topic | Helm v3 (3.21.x) | Helm v4 (4.x, current stable) |
|---|---|---|
| Status | Maintenance: bug fixes until Jul 2026, security fixes until Nov 2026 | Active development (4.2.0 May 2026; 4.3.0 due Sep 2026) |
| In-cluster server | None (Tiller was removed back in v3.0) | None |
| Chart format | `apiVersion: v2` charts | Same v2 charts work; adds next-gen chart features |
| OCI registries | Supported (GA since 3.8) | Supported, increasingly the default distribution method |
| Release storage | Secrets in namespace | Same model |
| Key changes in v4 | — | Modernized SDK/CLI internals, improved plugin system (with security fixes around plugin loading), updated Kubernetes client libraries, groundwork for new chart capabilities; some flag/behavior cleanups |

**Practical guidance:**

- New environments: standardize on **v4** and mirror the v4 binary into your offline artifact store.
- Existing v3 automation: keep working, but plan migration — v3 security fixes end **November 2026**. An out-of-support Helm eventually breaks against newer Kubernetes API versions because it stops receiving client-library updates.
- Version skew: keep your Helm release recent relative to your Kubernetes version; Helm publishes a version-skew policy tying each Helm minor to a range of supported Kubernetes minors.
- Both versions are a **single static binary** — trivially easy to carry into an air gap and to pin/verify by checksum.

---

# 6. Helm Offline / Air-Gapped: Complete Guide

This is the heart of the tutorial. We'll define the problem precisely, then give a repeatable recipe.

## 6.1 The two-artifact problem (memorize this)

Installing anything with Helm requires exactly **two kinds of artifacts**, fetched by **two different actors**:

```
┌───────────────────────────────────────────────────────────────┐
│  ARTIFACT 1: THE CHART (.tgz)                                 │
│  Fetched by: the `helm` CLI on YOUR workstation/bastion       │
│  From: chart repo (https) or OCI registry                     │
│  Offline fix: helm pull → carry .tgz → install from file,     │
│               or host a private chart repo / OCI registry     │
├───────────────────────────────────────────────────────────────┤
│  ARTIFACT 2: THE CONTAINER IMAGES                             │
│  Fetched by: the KUBELET on every cluster node                │
│  From: Docker Hub, quay.io, ghcr.io, public ECR, etc.         │
│  Offline fix: mirror images into a private registry the       │
│               nodes CAN reach, and point the chart's values   │
│               at that registry                                │
└───────────────────────────────────────────────────────────────┘
```

Most "Helm doesn't work offline!" incidents are actually **Artifact 2** failures: the install succeeds (Helm applied YAML fine), then pods sit in `ImagePullBackOff` because nodes can't reach Docker Hub. Always solve both halves.

## 6.2 Your options for each half — with pros and cons

### Hosting charts inside the air gap

| Option | How it works | Pros | Cons |
|---|---|---|---|
| **A. Plain .tgz files** (no server) | `helm pull` online → copy files → `helm install ./chart.tgz` | Zero infrastructure; easiest to audit; perfect for small scale and one-off transfers | No central catalog; version management is "a folder of files"; teams must share files manually |
| **B. OCI registry (recommended)** — Harbor, private ECR, Nexus, Artifactory, `registry:2` | `helm push chart.tgz oci://reg/charts/...` → `helm install oci://reg/charts/name --version x` | **One system stores charts AND images**; auth, TLS, RBAC, replication, vuln scanning (Harbor); modern standard | You must run/operate a registry (but you need one for images anyway) |
| **C. Classic HTTP chart repo** — ChartMuseum, Nexus, S3+`index.yaml`, any web server | `helm repo add internal https://...` | Familiar `helm repo` UX; ChartMuseum is tiny | Second system to run besides your image registry; classic repos are gradually giving way to OCI |
| **D. Git/GitOps bundle** | Vendor charts into a Git repo; Argo CD/Flux render them | Fits GitOps audit trails | Not a Helm-native distribution channel; still need images mirrored |

**Best practice:** B (OCI) for organizations, A (.tgz) for the initial bootstrap and for tiny setups. In AWS, **ECR supports OCI Helm charts natively**, so an air-gapped-VPC EKS design can use a private ECR reachable through a VPC interface endpoint — no internet at all.

### Hosting images inside the air gap

| Option | Pros | Cons |
|---|---|---|
| **Private ECR** (+ VPC endpoints) | Managed, IAM-integrated, EKS nodes auth natively; also stores Helm charts | AWS-only; per-region; you still must copy images in |
| **Harbor** | Rich UI, RBAC, replication, Trivy scanning, chart+image in one, proxy-cache mode | You operate it (HA, storage, upgrades) |
| **Nexus / Artifactory** | One tool for many formats (npm, pip, images, charts) | Licensing/complexity |
| **`registry:2` (Docker Distribution)** | 5-minute setup, tiny | Bare-bones: no UI, minimal auth |

### Moving artifacts across the gap

| Method | Notes |
|---|---|
| `docker save` / `ctr images export` → tar → `docker load` | Classic; fine for a handful of images |
| **`crane` / `skopeo` copy to tar/dir** | No Docker daemon needed; preserves multi-arch manifests properly; scriptable — **recommended** |
| **Harbor/ECR replication over an approved one-way link** | For recurring syncs where a controlled path exists |
| `helm pull` for charts | Charts are tiny; a USB stick holds thousands |

> **Multi-arch warning:** `docker save` exports only the architecture your machine pulled. If your cluster runs Graviton (arm64) and your laptop is x86, use `crane copy` or `skopeo copy --all` to move the **full multi-arch manifest list**, or explicitly pull `--platform linux/arm64`.

## 6.3 Recipe part 1 — capture charts on the connected side

```bash
# Classic repo example (kube-prometheus-stack)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm pull prometheus-community/kube-prometheus-stack --version 75.0.0
#  → kube-prometheus-stack-75.0.0.tgz

# OCI example (Karpenter)
helm pull oci://public.ecr.aws/karpenter/karpenter --version 1.13.0
#  → karpenter-1.13.0.tgz

# Verify provenance when available
helm pull repo/chart --version X --verify        # checks .prov signature
sha256sum *.tgz > SHA256SUMS                      # record checksums for transfer audit
```

> Pin **exact versions** always. "latest" is not reproducible and not auditable.

## 6.4 Recipe part 2 — discover every image a chart needs

The reliable, no-guessing method: **render the chart and grep the images**.

```bash
helm template audit ./kube-prometheus-stack-75.0.0.tgz \
  -f your-values.yaml \
  | grep -E '^\s+image:' | sed 's/.*image: *//; s/"//g' | sort -u
```

Notes that save you pain:

- Render with the **same values you'll use in production** — enabling/disabling features changes the image list.
- Some images are *not* in templates: operator-managed apps (Strimzi, NiFiKop) spawn pods whose images are set by the **operator's defaults/environment**, and some charts reference images inside ConfigMaps or CRDs. Check the project's release notes — good operators (Strimzi does this) publish the full image list per release. Belt-and-braces: after a test install on a connected staging cluster, run
  `kubectl get pods -A -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}' | sort -u`
- Don't forget **init containers** and **sidecars** (the jsonpath above misses initContainers; add a second pass with `.spec.initContainers[*]`).

## 6.5 Recipe part 3 — mirror images

Using `crane` (from go-containerregistry; single binary, no daemon):

```bash
REG=123456789012.dkr.ecr.us-east-1.amazonaws.com    # or my-registry.internal:5000

# If there IS a one-way controlled path (registry reachable from connected side):
while read img; do
  crane copy "$img" "$REG/mirror/${img#*/}"
done < images.txt

# If there is NO path (true air gap): export to tarballs
while read img; do
  safe=$(echo "$img" | tr '/:' '__')
  crane pull --format=oci "$img" "out/${safe}.tar"    # preserves digests; use skopeo copy --all for multi-arch lists
done < images.txt
# ...carry `out/` across on approved media, then on the inside:
while read img; do
  safe=$(echo "$img" | tr '/:' '__')
  crane push "out/${safe}.tar" "$REG/mirror/${img#*/}"
done < images.txt
```

Same with `skopeo` if you prefer: `skopeo copy --all docker://src docker-archive:file.tar` and `skopeo copy --all docker-archive:file.tar docker://dest`.

**Registry-path convention:** keep the upstream path under a `mirror/` prefix (`.../mirror/nginx`, `.../mirror/strimzi/operator`). Your values overrides become mechanical, and provenance stays obvious.

## 6.6 Recipe part 4 — push charts to your internal OCI registry

```bash
# ECR: repository must exist first, and login uses an ECR token
aws ecr create-repository --repository-name charts/kube-prometheus-stack
aws ecr get-login-password --region us-east-1 \
  | helm registry login --username AWS --password-stdin $REG

helm push kube-prometheus-stack-75.0.0.tgz oci://$REG/charts

# Later, from inside the air gap:
helm install monitoring oci://$REG/charts/kube-prometheus-stack --version 75.0.0 \
  -n monitoring --create-namespace -f values-offline.yaml
```

(For Harbor/Nexus: `helm registry login my-registry.internal` with its credentials; everything else is identical.)

## 6.7 Recipe part 5 — the offline values overlay

Create one `values-offline.yaml` per chart that redirects **every image** to your mirror. Well-built charts make this easy with a global setting:

```yaml
# Bitnami-style charts
global:
  imageRegistry: my-registry.internal/mirror
  security:
    allowInsecureImages: true   # some Bitnami charts verify origin registries; needed when redirecting

# kube-prometheus-stack-style charts (per-component)
grafana:
  image: { registry: my-registry.internal/mirror, repository: grafana/grafana }
prometheus:
  prometheusSpec:
    image: { registry: my-registry.internal/mirror, repository: prometheus/prometheus }
```

If nodes need credentials for the registry, also set `imagePullSecrets` (not needed for ECR on EKS — nodes authenticate via IAM automatically).

## 6.8 Alternative for recurring needs: a pull-through / proxy cache

If your environment is *restricted* rather than truly air-gapped (an approved egress path exists), a **proxy cache** saves enormous effort:

- **Harbor proxy-cache projects** or **Nexus proxy repos** front Docker Hub/quay/ghcr; first pull goes out, everything after is served locally.
- **ECR pull-through cache rules** do the same natively in AWS for Docker Hub, ghcr, quay, Kubernetes registry, etc.
- Configure containerd on nodes (or just your values files) to use the mirror hostnames.

**Pros:** no manual image lists; always current. **Cons:** not acceptable for true air gaps; first-pull latency; you must still pin versions for reproducibility; egress path must be tightly scoped.

## 6.9 Security best practices for offline Helm (the checklist)

1. **Pin everything**: chart versions, image tags — and prefer **digests** (`image@sha256:...`) inside the gap for immutability.
2. **Verify before transfer**: `sha256sum` manifests for all artifacts; chart `--verify` where `.prov` files exist; `cosign verify` for signed images (Strimzi, Karpenter, and most CNCF projects sign with cosign now).
3. **Scan before transfer**: run Trivy/Grype on every image on the connected side; re-scan inside if you run Harbor+Trivy.
4. **Render-and-review**: security review of `helm template` output (it's plain YAML) is much easier than reviewing templates. Store rendered output alongside the release ticket.
5. **Least-privilege installs**: Helm uses your kubeconfig RBAC — create a namespaced service account per team; don't install everything as cluster-admin. (Cluster-scoped charts like operators with CRDs do need elevated rights — isolate those pipelines.)
6. **No secrets in values files at rest**: SOPS/age-encrypted values, `--set-file` from a vault-fetched temp file, or External Secrets Operator inside the cluster.
7. **Record the SBOM trail**: many projects publish SBOMs (Strimzi publishes SPDX SBOMs per release); carry them across with the images to satisfy supply-chain audits.
8. **Practice the update path**: air gaps rot. Schedule a monthly "sync run" (new chart versions, CVE-driven image updates) with the same scripted pipeline — never ad-hoc.

## 6.10 One reusable bundle script

```bash
#!/usr/bin/env bash
# bundle.sh — run on the CONNECTED side; produces bundle/ ready for transfer
set -euo pipefail
BUNDLE=bundle; mkdir -p $BUNDLE/{charts,images}

# 1) charts.txt lines:  <name> <version> <source>
#    e.g.  karpenter 1.13.0 oci://public.ecr.aws/karpenter/karpenter
while read -r name ver src; do
  case "$src" in
    oci://*) helm pull "$src" --version "$ver" -d $BUNDLE/charts ;;
    *)       helm repo add "tmp-$name" "$src" >/dev/null
             helm pull "tmp-$name/$name" --version "$ver" -d $BUNDLE/charts ;;
  esac
done < charts.txt

# 2) render every chart with prod values → images.txt
: > $BUNDLE/images.txt
for c in $BUNDLE/charts/*.tgz; do
  helm template x "$c" ${VALUES:+-f $VALUES} 2>/dev/null \
   | grep -E 'image:' | sed 's/.*image: *//; s/"//g'
done | sort -u >> $BUNDLE/images.txt
echo ">> REVIEW $BUNDLE/images.txt and append operator-managed images manually!"

# 3) export images
while read -r img; do
  crane pull --format=oci "$img" "$BUNDLE/images/$(echo "$img" | tr '/:' '__').tar"
done < $BUNDLE/images.txt

# 4) integrity manifest
( cd $BUNDLE && find . -type f -exec sha256sum {} \; > SHA256SUMS )
echo "Bundle ready: $(du -sh $BUNDLE)"
```

---

# 7. AWS EKS Setup

All remaining examples run on **Amazon EKS** (Elastic Kubernetes Service — AWS's managed Kubernetes). Background you need:

- **Control plane**: AWS runs the Kubernetes masters for you.
- **Data plane**: your EC2 worker nodes (managed node groups, or Karpenter-provisioned nodes, or Fargate).
- **IAM ↔ Kubernetes bridge**: *Pod Identity* (current recommended) or *IRSA* (IAM Roles for Service Accounts) let individual pods (like the load-balancer controller or Karpenter) call AWS APIs with least privilege.
- **Private clusters**: EKS supports fully private endpoints. For no-internet VPCs you add **VPC interface endpoints** for `ecr.api`, `ecr.dkr`, `s3` (gateway), `ec2`, `sts`, `eks`, `elasticloadbalancing`, plus `eks-auth` for Pod Identity — then nodes can join, pull from private ECR, and controllers can call AWS APIs with zero internet.

## 7.1 Create a cluster (connected bootstrap shown; do this from a bastion for private VPCs)

Using `eksctl` (the simplest CLI; itself installable as a single offline binary):

```yaml
# cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: demo
  region: us-east-1
  version: "1.33"
iam:
  withOIDC: true                  # enables IRSA
addons:
  - name: eks-pod-identity-agent  # enables Pod Identity (recommended auth for controllers)
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
managedNodeGroups:
  - name: system                  # small always-on pool for system pods & controllers
    instanceType: m6i.large
    desiredCapacity: 2
    privateNetworking: true
```

```bash
eksctl create cluster -f cluster.yaml
aws eks update-kubeconfig --name demo --region us-east-1
kubectl get nodes
```

> **Air-gapped EKS notes:** (1) Use `privateCluster: { enabled: true }` in eksctl or Terraform equivalents; (2) EKS add-on images come from AWS's regional ECR automatically via your `ecr.dkr` endpoint; (3) everything *you* install (controllers below) must come from **your** private ECR per Section 6; (4) keep a small **managed node group** for system controllers even when using Karpenter — Karpenter can't schedule its own controller onto nodes it hasn't created yet (chicken-and-egg).

## 7.2 Point of order: what we'll install with Helm

| Component | Chart source (online) | Purpose |
|---|---|---|
| AWS Load Balancer Controller | `oci://public.ecr.aws/eks-charts/aws-load-balancer-controller` (also classic `https://aws.github.io/eks-charts`) | Creates ALBs/NLBs from Ingress/Service |
| Karpenter | `oci://public.ecr.aws/karpenter/karpenter` | Node autoscaling, scale-to-zero |
| Strimzi | `oci://quay.io/strimzi-helm/strimzi-kafka-operator` (also `https://strimzi.io/charts/`) | Kafka operator |
| NiFi | community charts / NiFiKop operator (Section 11) | Data-flow engine |
| KEDA | `https://kedacore.github.io/charts` | Workload autoscaling incl. **cron schedules** |
| cert-manager, kube-prometheus-stack | jetstack / prometheus-community repos | TLS + monitoring |

For each: `helm pull` → mirror images → push chart to private ECR → install with `values-offline.yaml`, exactly per Section 6.

---

# 8. Example 1: Web Server + AWS Load Balancers on EKS

**Goal:** run NGINX behind real AWS load balancers, both ways it's done in practice.

## 8.1 Background: how Kubernetes traffic meets AWS load balancers

Two mechanisms, two AWS load balancer types:

| Kubernetes object | AWS LB created | Layer | Typical use |
|---|---|---|---|
| `Service` with `type: LoadBalancer` | **NLB** (Network Load Balancer) | L4 (TCP/UDP) | Non-HTTP protocols, Kafka, raw TCP, extreme throughput |
| `Ingress` (class `alb`) | **ALB** (Application Load Balancer) | L7 (HTTP/HTTPS) | Websites/APIs: host/path routing, TLS termination, WAF, OIDC auth |

Both are created by the **AWS Load Balancer Controller** — a pod in your cluster that watches Services/Ingresses and calls AWS APIs to build the LBs. (Without it, legacy in-tree code can make old Classic LBs — don't rely on that.)

## 8.2 Install the AWS Load Balancer Controller (Helm)

**IAM first** (the controller needs AWS permissions — Pod Identity shown):

```bash
CLUSTER=demo; REGION=us-east-1; ACCT=$(aws sts get-caller-identity --query Account --output text)

# Official IAM policy for the controller (download once; vendor it for offline)
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json

aws iam create-role --role-name eks-albc --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"pods.eks.amazonaws.com"},
  "Action":["sts:AssumeRole","sts:TagSession"]}]}'
aws iam attach-role-policy --role-name eks-albc \
  --policy-arn arn:aws:iam::$ACCT:policy/AWSLoadBalancerControllerIAMPolicy

aws eks create-pod-identity-association --cluster-name $CLUSTER \
  --namespace kube-system --service-account aws-load-balancer-controller \
  --role-arn arn:aws:iam::$ACCT:role/eks-albc
```

**Then Helm** (online form):

```bash
helm install aws-load-balancer-controller \
  oci://public.ecr.aws/eks-charts/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller
```

**Offline form** (after mirroring per Section 6):

```bash
helm pull oci://public.ecr.aws/eks-charts/aws-load-balancer-controller --version 1.13.3   # connected side
# mirror image public.ecr.aws/eks/aws-load-balancer-controller:v2.13.x → $REG/mirror/eks/aws-load-balancer-controller
helm push aws-load-balancer-controller-1.13.3.tgz oci://$REG/charts

helm install aws-load-balancer-controller oci://$REG/charts/aws-load-balancer-controller \
  --version 1.13.3 -n kube-system \
  --set clusterName=$CLUSTER \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set image.repository=$REG/mirror/eks/aws-load-balancer-controller
```

Verify: `kubectl -n kube-system get deploy aws-load-balancer-controller` → `2/2 READY`.

## 8.3 Variant A — NLB via Service (simplest possible public web server)

Reuse the `hello-web` chart from Section 3, with EKS-specific values:

```yaml
# values-eks-nlb.yaml
replicaCount: 3
image:
  repository: my-registry.internal/mirror/nginx   # or just "nginx" if online
  tag: "1.27"
service:
  type: LoadBalancer
  port: 80
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external            # hand to LB Controller
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip       # route straight to pod IPs
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing   # or "internal" for private
```

(If you built `hello-web` with `helm create`, add `annotations: {{- toYaml .Values.service.annotations | nindent 4 }}` under the Service metadata if not present.)

```bash
helm upgrade --install web ./hello-web -n web --create-namespace -f values-eks-nlb.yaml
kubectl get svc -n web -w      # EXTERNAL-IP becomes an NLB DNS name in ~2 min
curl http://<nlb-dns-name>/
```

**What happened:** the controller saw the Service, created an NLB, made target groups pointing at your pod IPs, and wired listeners on port 80. Deleting the release deletes the NLB. Infrastructure as chart values.

## 8.4 Variant B — ALB via Ingress (the production HTTP pattern)

```yaml
# values-eks-alb.yaml
replicaCount: 3
image: { repository: my-registry.internal/mirror/nginx, tag: "1.27" }
service:
  type: ClusterIP        # ALB targets pods directly; no NLB needed
  port: 80
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing        # "internal" for private apps
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/abc-123
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /
  hosts:
    - host: web.example.internal
      paths:
        - path: /
          pathType: Prefix
```

```bash
helm upgrade --install web ./hello-web -n web -f values-eks-alb.yaml
kubectl get ingress -n web    # ADDRESS = ALB DNS name
```

Point DNS (Route 53 alias, or your internal DNS in the air gap) at the ALB name. You now have HTTPS, host/path routing, and a place to attach WAF — all declared in a values file.

**Pros/cons recap:** NLB/Service = simplest, any protocol, lowest latency; one LB per service (costly at scale). ALB/Ingress = one LB shared across many apps (use `alb.ingress.kubernetes.io/group.name` to share), TLS/WAF/auth features; HTTP(S) only. Air-gapped note: both work in fully private VPCs with `scheme: internal` — the controller only needs the `elasticloadbalancing`, `ec2` VPC endpoints.

---

# 9. Example 2: Karpenter — Autoscaling and Scale-to-Zero on Work Hours

## 9.1 Background: what Karpenter is and why it replaced Cluster Autoscaler

Old world (**Cluster Autoscaler**): you pre-define Auto Scaling Groups of a fixed instance type; the autoscaler nudges the group size up/down. Slow (minutes), rigid (one instance type per group), wasteful bin-packing.

New world (**Karpenter**, created by AWS, now a CNCF project and the default scaler in EKS Auto Mode): a controller watches for **pending pods** (pods that can't fit anywhere) and directly launches the *cheapest right-sized EC2 instance* that fits them — typically in well under a minute. When nodes are empty or underutilized, it **consolidates**: drains and deletes them, or replaces them with cheaper ones. It works from two CRDs:

- **`NodePool`** (`karpenter.sh/v1`) — *what kinds of nodes may exist*: instance categories/sizes, capacity type (Spot/On-Demand), architecture, limits, and **disruption rules** (the key to time-based behavior).
- **`EC2NodeClass`** (`karpenter.k8s.aws/v1`) — *AWS specifics*: AMI family, subnets, security groups, IAM role, user data.

**Scale-to-zero is native:** if a NodePool's pods all disappear, Karpenter deletes all its nodes — down to zero EC2 instances, zero cost. When pods appear again, capacity returns in ~1 minute.

## 9.2 Install Karpenter with Helm

Prereqs (once): a node IAM role + instance profile for Karpenter nodes, an IAM role for the controller (Pod Identity/IRSA), subnet & SG tags `karpenter.sh/discovery: <cluster>`, and an SQS interruption queue for Spot notices. The `karpenter-provider-aws` repo ships CloudFormation/Terraform for all of this (`getting-started` guide) — vendor those files for offline use.

Online install:

```bash
helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.13.0 -n karpenter --create-namespace \
  --set settings.clusterName=$CLUSTER \
  --set settings.interruptionQueue=Karpenter-$CLUSTER \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi
```

**Offline install:**

```bash
# Connected side: chart + images (controller image lives in public.ecr.aws/karpenter/controller)
helm pull oci://public.ecr.aws/karpenter/karpenter --version 1.13.0
helm template k karpenter-1.13.0.tgz --set settings.clusterName=x | grep image:   # capture exact digest
# mirror → $REG/mirror/karpenter/controller ; push chart → oci://$REG/charts

# Inside:
helm install karpenter oci://$REG/charts/karpenter --version 1.13.0 \
  -n karpenter --create-namespace \
  --set settings.clusterName=$CLUSTER \
  --set settings.interruptionQueue=Karpenter-$CLUSTER \
  --set controller.image.repository=$REG/mirror/karpenter/controller \
  --set controller.image.digest=""      # clear digest pin if your mirror re-tags; prefer copying by digest so you can keep it
```

> **Where does Karpenter run?** On your small static managed node group (or Fargate) — never on nodes it manages, or it can consolidate itself out of existence. Air-gapped nodes also need the **AMI available privately**: AL2023 EKS-optimized AMIs are referenced via SSM parameters; in isolated regions/partitions, pin `amiSelectorTerms` to an AMI ID you've copied in.

## 9.3 A general-purpose NodePool + EC2NodeClass

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
    - alias: al2023@latest        # air gap: use - id: ami-0abc123... instead
  role: KarpenterNodeRole-demo
  subnetSelectorTerms:
    - tags: { karpenter.sh/discovery: demo }
  securityGroupSelectorTerms:
    - tags: { karpenter.sh/discovery: demo }
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: general
spec:
  template:
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]        # prefer spot, fall back
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      expireAfter: 720h                        # recycle nodes monthly (security hygiene)
  limits:
    cpu: "200"                                 # hard cap: never more than 200 vCPU total
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
      - nodes: "10%"                           # normally: disrupt ≤10% at a time
```

Apply, then create load and watch nodes appear:

```bash
kubectl apply -f nodepool.yaml
kubectl create deployment inflate --image=$REG/mirror/pause:3.9 --replicas=0
kubectl set resources deployment inflate --requests=cpu=1
kubectl scale deployment inflate --replicas=20
kubectl get nodeclaims -w        # instances appear in ~40-60s
kubectl scale deployment inflate --replicas=0
# → nodes drain and terminate; NodePool reaches zero nodes
```

That is scale-to-zero **on demand**. Now let's make it happen **on a work-hours schedule**, which needs one more idea.

## 9.4 The key insight for time-based scale-to-zero

Karpenter reacts to **pods**, not to clocks. A NodePool goes to zero only when no pods require its nodes. So "scale to zero outside work hours" is a two-part design — and this is the architecture used in practice:

```
Part A (workloads): something scales the PODS to 0 at 19:00 and back at 07:00
        → best tool: KEDA's cron scaler (or a scheduled CronJob patching replicas)
Part B (nodes):     Karpenter sees empty nodes → consolidates → EC2 count = 0
        → plus Karpenter DISRUPTION BUDGET SCHEDULES to control *when*
          consolidation is allowed, so nodes are never churned mid-workday
```

### Part A — KEDA cron scaler (recommended)

KEDA (Kubernetes Event-Driven Autoscaling, a CNCF graduated project, installed via Helm) can drive any Deployment's replica count from schedules and dozens of other triggers:

```bash
# online: helm repo add kedacore https://kedacore.github.io/charts
# offline: pull chart 2.x, mirror ghcr.io/kedacore/* images, as per Section 6
helm install keda kedacore/keda -n keda --create-namespace
```

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: web-workhours
  namespace: apps
spec:
  scaleTargetRef:
    name: web                  # the Deployment to control
  minReplicaCount: 0           # ← allows true zero
  maxReplicaCount: 10
  cooldownPeriod: 300
  triggers:
    - type: cron
      metadata:
        timezone: America/Chicago     # KEDA cron IS timezone-aware
        start: "0 7 * * 1-5"          # Mon–Fri 07:00 → scale up
        end: "0 19 * * 1-5"           # Mon–Fri 19:00 → scale down
        desiredReplicas: "3"
```

Outside the window, KEDA sets replicas to `minReplicaCount: 0`. Apply this pattern (or one ScaledObject per app) to everything running on the business-hours NodePool.

### Part B — a dedicated NodePool with schedule-aware disruption

Give business-hours workloads their own NodePool via taints/labels, and shape *when* Karpenter may disrupt with **budget schedules**:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: workhours
spec:
  template:
    metadata:
      labels: { pool: workhours }
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: default }
      taints:
        - key: pool
          value: workhours
          effect: NoSchedule            # only workloads that tolerate it land here
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
  limits:
    cpu: "100"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    budgets:
      # During US-Central work hours (13:00 UTC = 07:00 CST... adjust for your offset/DST),
      # allow ZERO underutilization/drift disruption — no churn while people work.
      - nodes: "0"
        schedule: "0 13 * * 1-5"       # cron, ALWAYS UTC — timezones are NOT supported here
        duration: 12h
        reasons: ["Underutilized", "Drifted"]
      # Empty-node cleanup is allowed at any time (safe: nothing is running on them)
      - nodes: "100%"
        reasons: ["Empty"]
      # Overnight/weekends: default budget lets consolidation run freely
      - nodes: "50%"
```

And the workloads that belong to this pool get:

```yaml
# in your app chart's values
nodeSelector: { pool: workhours }
tolerations:
  - { key: pool, value: workhours, effect: NoSchedule }
```

### The daily rhythm you get

```
07:00 local  KEDA start trigger → Deployments 0 → N replicas → pods Pending
07:01        Karpenter launches right-sized (Spot-first) nodes → pods Running
07:00–19:00  Budget "nodes: 0" blocks consolidation churn; Empty cleanup still allowed
19:00 local  KEDA end trigger → replicas → 0 → nodes become EMPTY
19:00–19:05  Karpenter WhenEmptyOrUnderutilized + Empty budget 100% → all nodes terminated
overnight    EC2 cost for this pool: $0.00
```

### Gotchas & best practices for scale-to-zero

- **Karpenter budget `schedule` is UTC only** (no timezone field) — convert carefully and mind daylight-saving shifts; KEDA's cron *does* support `timezone`, so let KEDA own the local-time logic.
- **Stragglers pin nodes**: one DaemonSet-only node is fine (DaemonSets don't block scale-down), but a forgotten `kubectl run` pod or a PDB with `maxUnavailable: 0` will keep a node alive all night. Audit with `kubectl get pods -A --field-selector spec.nodeName=<node>`.
- **`terminationGracePeriod`** on the NodePool (e.g., `48h`) bounds how long a stuck drain can block.
- **Don't scale system controllers to zero** — keep Karpenter, LB controller, CoreDNS, KEDA on the static system node group.
- **First-morning latency**: cold start is ~1–2 min (node boot + image pulls). Pre-warm by setting the KEDA `start` a few minutes before humans arrive; in the air gap, a local registry makes image pulls fast and reliable.
- **Alternative to KEDA**: a plain Kubernetes `CronJob` running `kubectl scale deployment ... --replicas=0` at 19:00 and back at 07:00 — zero new components (nice for minimal air gaps), but no HPA integration, timezone handling is the CronJob's `timeZone` field, and you must RBAC the job's service account.
- **Offline images for this section**: `public.ecr.aws/karpenter/controller`, `ghcr.io/kedacore/keda`, `ghcr.io/kedacore/keda-metrics-apiserver`, `ghcr.io/kedacore/keda-admission-webhooks`, plus your apps.

---

# 10. Example 3: Kafka on EKS with Strimzi

## 10.1 Background: Kafka, and why you want an operator

**Apache Kafka** is a distributed event-streaming platform: producers write ordered streams of records into **topics** (split into **partitions**, replicated across **brokers**); consumers read them independently at their own pace. It's the backbone for log pipelines, event-driven microservices, IoT ingestion, and NiFi/Spark/Flink data flows.

Kafka is famously stateful and operationally fussy: broker identities, persistent storage, certificates, rolling restarts in the right order, partition rebalancing, version upgrades. Running it "by hand" on Kubernetes is a part-time job. The **operator pattern** fixes this: an operator is a controller that encodes an expert admin's knowledge and continuously reconciles your declared intent.

**Strimzi** is the CNCF operator for Kafka. You write small YAML custom resources — `Kafka`, `KafkaNodePool`, `KafkaTopic`, `KafkaUser`, `KafkaConnect`, `KafkaMirrorMaker2`, `KafkaBridge` — and Strimzi's operators build and babysit everything: pods, storage, TLS certs, users/ACLs, rolling upgrades, Cruise Control rebalancing.

**State of the art (2026):**
- Strimzi crossed **1.0** — its CRDs are now the stable `v1` API (old `v1beta2`/`v1alpha1` are removed; if upgrading an old install, convert CRs first).
- Kafka **4.x runs in KRaft mode only** — ZooKeeper is gone; cluster metadata is managed by Kafka's own Raft **controller** nodes, declared via `KafkaNodePool` resources.
- Strimzi signs containers with cosign and publishes SBOMs — useful for your air-gap supply-chain audit.

## 10.2 Install the Strimzi operator with Helm

Online:

```bash
helm install strimzi oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  -n kafka --create-namespace \
  --set watchAnyNamespace=false      # operator watches its own namespace (least privilege)
```

**Offline** — Strimzi's images are numerous but well-documented (each GitHub release lists the exact `quay.io/strimzi/...` images: `operator`, `kafka` (per Kafka version), `bridge`, `maven-builder`, drain-cleaner, access-operator). Mirror them all, then:

```bash
helm install strimzi oci://$REG/charts/strimzi-kafka-operator \
  --version 1.1.0 -n kafka --create-namespace \
  --set defaultImageRegistry=$REG/mirror \
  --set image.registry=$REG/mirror
```

> The chart exposes `defaultImageRegistry`/`defaultImageRepository` style values precisely for air-gapped installs — the operator then spawns Kafka pods from your mirror automatically. Always `helm show values` the exact chart version you pulled to confirm key names before the transfer.

Verify: `kubectl -n kafka get pods` → `strimzi-cluster-operator-... Running`.

## 10.3 Declare a Kafka cluster (KRaft, production-shaped but small)

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: controller
  namespace: kafka
  labels: { strimzi.io/cluster: my-kafka }
spec:
  replicas: 3
  roles: [controller]                  # KRaft metadata quorum
  storage:
    type: persistent-claim
    size: 20Gi
    class: gp3                          # EBS CSI storage class
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: broker
  namespace: kafka
  labels: { strimzi.io/cluster: my-kafka }
spec:
  replicas: 3
  roles: [broker]
  storage:
    type: persistent-claim
    size: 200Gi
    class: gp3
  resources:
    requests: { cpu: "1", memory: 4Gi }
    limits: { memory: 4Gi }
  template:                             # pin brokers to a dedicated Karpenter pool if you like
    pod:
      tolerations: [{ key: pool, value: kafka, effect: NoSchedule }]
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: my-kafka
  namespace: kafka
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
spec:
  kafka:
    version: 4.1.0
    listeners:
      - name: internal                  # in-cluster clients, TLS
        port: 9093
        type: internal
        tls: true
      - name: external                  # clients outside the cluster → one NLB
        port: 9094
        type: loadbalancer
        tls: true
        configuration:
          annotations:
            service.beta.kubernetes.io/aws-load-balancer-scheme: internal
    config:
      default.replication.factor: 3
      min.insync.replicas: 2
      offsets.topic.replication.factor: 3
  entityOperator:                       # enables KafkaTopic + KafkaUser CRs
    topicOperator: {}
    userOperator: {}
```

```bash
kubectl apply -f kafka-cluster.yaml
kubectl -n kafka get kafka my-kafka -w        # wait for READY=True
kubectl -n kafka get pods                     # 3 controllers + 3 brokers + entity-operator
```

Notice what you did **not** do: create StatefulSets, Services, certificates, JKS/PEM stores, or broker configs. The operator generated all of it (a full internal CA and per-broker certs included).

## 10.4 Topics and users as YAML

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: orders
  namespace: kafka
  labels: { strimzi.io/cluster: my-kafka }
spec:
  partitions: 12
  replicas: 3
  config:
    retention.ms: 604800000        # 7 days
    cleanup.policy: delete
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: orders-app
  namespace: kafka
  labels: { strimzi.io/cluster: my-kafka }
spec:
  authentication: { type: tls }     # operator mints a client cert into a Secret
  authorization:
    type: simple
    acls:
      - resource: { type: topic, name: orders }
        operations: [Read, Write, Describe]
```

Client bootstrap address: `my-kafka-kafka-bootstrap.kafka.svc:9093`; the client cert lives in Secret `orders-app`, the cluster CA in `my-kafka-cluster-ca-cert`. Quick smoke test:

```bash
kubectl -n kafka run producer -ti --rm \
  --image=$REG/mirror/strimzi/kafka:latest-kafka-4.1.0 \
  -- bin/kafka-console-producer.sh \
     --bootstrap-server my-kafka-kafka-bootstrap:9092 --topic orders
```

## 10.5 Strimzi best practices (incl. air gap)

- **Storage**: install the **EBS CSI driver add-on** and use `gp3`; one PVC per broker; never `ephemeral` storage in prod.
- **Spread**: brokers across AZs (Strimzi sets sane topology spread; verify with `kubectl get pods -o wide`). Cross-AZ replication traffic costs money — budget for it.
- **Don't scale Kafka to zero** with the Section 9 trick — brokers hold data and quorum. Put Kafka on an always-on or business-critical NodePool with `nodes: "0"` disruption budgets during work hours, PDBs (Strimzi creates them), and let **Strimzi Drain Cleaner** coordinate safe node drains with Karpenter consolidation.
- **Upgrades**: bump the operator chart first (Helm), then `spec.kafka.version` — the operator orchestrates the rolling upgrade. Offline: mirror the *new* Kafka images before bumping.
- **Connect in the air gap**: `KafkaConnect` with `spec.build` normally *downloads connector jars* — that breaks offline. Instead pre-build a Connect image containing your connectors on the connected side, mirror it, and reference it via `spec.image`.
- **Monitoring**: enable `metricsConfig` (JMX Prometheus exporter) and scrape with kube-prometheus-stack (Section 12); import Strimzi's bundled Grafana dashboards.

---

# 11. Example 4: Apache NiFi on EKS

## 11.1 Background

**Apache NiFi** is a visual data-flow platform: you drag **processors** (GetFile, ConsumeKafka, TransformJSON, PutS3Object, …) onto a canvas and wire them into pipelines with built-in back-pressure, provenance (full audit trail of every piece of data — a big reason regulated/secure sites love it), retry, and clustering. Typical pairing: **NiFi consumes from/produces to Kafka**, doing ingestion, enrichment, and routing between systems.

**NiFi 2.x** (current major line) modernized the platform: Java 21, Python-based processors, flow definitions as JSON, and — important for Kubernetes — **native Kubernetes clustering**: NiFi nodes can use Kubernetes leases/ConfigMaps for leader election and cluster state, removing the embedded-ZooKeeper headache that made old NiFi-on-K8s painful.

## 11.2 Your Helm options for NiFi — honest pros and cons

NiFi has **no single official Apache Helm chart with the maturity of Strimzi**, so choose deliberately:

| Option | What it is | Pros | Cons |
|---|---|---|---|
| **A. NiFiKop operator** (Konpyūta/community NiFi operator, installed via Helm) | Operator + `NifiCluster`/`NifiDataflow` CRDs | Operator-managed lifecycle, rolling config, dataflow-as-code | Community-maintained; verify current NiFi 2.x support level before committing |
| **B. Community Helm charts for NiFi 2.x** (several on Artifact Hub; the once-popular `cetic/nifi` targets NiFi 1.x and has gone stale) | Templated StatefulSet + Services | Plain Helm UX; easy to read and fork | Quality varies; you own upgrades; check chart activity & NiFi version |
| **C. Your own chart (recommended for air-gapped/secure orgs)** | ~200 lines: StatefulSet, Services, ConfigMap, PVCs around the official `apache/nifi:2.x` image | Full control & auditability (what secure sites want); NiFi 2.x native K8s clustering makes this genuinely simple now | You write and maintain it |

Because this tutorial is aimed at secure environments, here's the shape of **Option C** — a minimal, honest chart.

## 11.3 A minimal NiFi 2.x chart

`values.yaml`:

```yaml
image:
  repository: my-registry.internal/mirror/apache/nifi
  tag: "2.4.0"
replicaCount: 1                 # start single-node; clustering below
persistence:
  size: 50Gi
  storageClass: gp3
auth:
  singleUserCredentialsSecret: nifi-admin   # Secret with username/password keys
service:
  type: ClusterIP
  httpsPort: 8443
ingress:
  enabled: true
  className: alb
  host: nifi.example.internal
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/backend-protocol: HTTPS   # NiFi 2.x is HTTPS-only by default
```

`templates/statefulset.yaml` (core, abbreviated):

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "nifi.fullname" . }}
spec:
  serviceName: {{ include "nifi.fullname" . }}-headless
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: nifi
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports: [{ containerPort: 8443, name: https }]
          env:
            - name: SINGLE_USER_CREDENTIALS_USERNAME
              valueFrom: { secretKeyRef: { name: {{ .Values.auth.singleUserCredentialsSecret }}, key: username } }
            - name: SINGLE_USER_CREDENTIALS_PASSWORD
              valueFrom: { secretKeyRef: { name: {{ .Values.auth.singleUserCredentialsSecret }}, key: password } }
            - name: NIFI_WEB_HTTPS_HOST
              value: "0.0.0.0"
          volumeMounts:
            - { name: data, mountPath: /opt/nifi/nifi-current/state }
            - { name: data, mountPath: /opt/nifi/nifi-current/content_repository, subPath: content }
            - { name: data, mountPath: /opt/nifi/nifi-current/flowfile_repository, subPath: flowfile }
            - { name: data, mountPath: /opt/nifi/nifi-current/provenance_repository, subPath: provenance }
          readinessProbe:
            tcpSocket: { port: 8443 }
            initialDelaySeconds: 60
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: {{ .Values.persistence.storageClass }}
        resources: { requests: { storage: {{ .Values.persistence.size }} } }
```

```bash
kubectl create ns nifi
kubectl -n nifi create secret generic nifi-admin \
  --from-literal=username=admin --from-literal=password='ChangeMe-LongPassword-123!'
helm upgrade --install nifi ./nifi-chart -n nifi
```

Browse `https://nifi.example.internal/nifi` via your internal ALB.

**Scaling to a real cluster (NiFi 2.x on K8s):** set `replicaCount: 3` and add the cluster properties (`nifi.cluster.is.node=true`, Kubernetes leader-election/state providers, proper node TLS certs via cert-manager) — NiFi 2.x's native K8s clustering means no ZooKeeper. Do this as a second iteration once single-node works.

## 11.4 NiFi best practices (incl. air gap)

- **Repositories on fast persistent volumes** — content/flowfile/provenance repos are NiFi's soul; size generously; gp3 with provisioned IOPS for heavy flows.
- **Real TLS + real auth before multi-user use**: single-user mode is for bootstrap; move to OIDC or client-cert auth, certs from cert-manager (Section 12).
- **Air-gap extensions (NARs)**: extra processors are NAR files — vendor them into a custom image (`FROM apache/nifi:2.4.0` + `COPY *.nar /opt/nifi/nifi-current/extensions/`) on the connected side and mirror it, rather than downloading at runtime. Same story as Kafka Connect plugins.
- **Version your flows**: NiFi Registry (or NiFi 2.x flow JSON exports in Git) so the canvas is code-reviewed, not folklore.
- **Connect NiFi→Kafka**: use `ConsumeKafka`/`PublishKafka` processors against `my-kafka-kafka-bootstrap.kafka.svc:9093` with the Strimzi-minted client cert mounted from the `KafkaUser` secret.
- **Don't schedule-scale NiFi to zero** unless flows are genuinely idle-safe — in-flight FlowFiles live on the node's volumes; scale the *ingest sources* instead.

---

# 12. More Essential Charts

The same pull → mirror → push → values-offline pattern applies to the rest of a production stack. The short list:

## 12.1 cert-manager (TLS automation)

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true
```

Offline: mirror `quay.io/jetstack/cert-manager-{controller,webhook,cainjector,startupapichallenge}` images; in a true air gap use a **CA `ClusterIssuer`** (your internal CA cert+key in a Secret) — ACME/Let's Encrypt obviously can't reach out. Issues certs for NiFi, Kafka external listeners, webhooks, and your ALB backends.

## 12.2 kube-prometheus-stack (metrics + dashboards + alerts)

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f values-offline.yaml
```

One chart = Prometheus Operator + Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics. It's the classic air-gap stress test (~10 images across quay.io/registry.k8s.io/docker.io) — your Section 6.10 bundle script earns its keep here. Scrape Strimzi's Kafka metrics and Karpenter's `/metrics`; import the projects' bundled Grafana dashboards (JSON files — vendor them, they're offline-friendly by nature).

## 12.3 Also commonly mirrored

| Chart | Why |
|---|---|
| `metrics-server` | `kubectl top`, HPA baseline |
| `keda` | already used in Section 9 |
| `external-secrets` | sync from AWS Secrets Manager/Vault (works in private VPC via endpoints) |
| `aws-ebs-csi-driver` (or EKS add-on) | persistent volumes for Kafka/NiFi |
| `argo-cd` / `flux2` | GitOps: point them at your **internal** Git + OCI registry and your whole delivery system is air-gap native |

## 12.4 Umbrella chart: shipping your whole platform as ONE artifact

For repeatable air-gapped site installs, wrap everything in an umbrella chart:

```yaml
# platform/Chart.yaml
apiVersion: v2
name: platform
version: 2026.7.0
dependencies:
  - { name: aws-load-balancer-controller, version: 1.13.3, repository: "oci://REG/charts", condition: albc.enabled }
  - { name: karpenter,                    version: 1.13.0, repository: "oci://REG/charts", condition: karpenter.enabled }
  - { name: strimzi-kafka-operator,       version: 1.1.0,  repository: "oci://REG/charts", condition: strimzi.enabled }
  - { name: keda,                         version: 2.17.0, repository: "oci://REG/charts", condition: keda.enabled }
```

`helm dependency build && helm package` → one `.tgz` containing every subchart → one file to carry, one `helm install platform-2026.7.0.tgz -f site-values.yaml` per site. **Pros:** atomic versioning of the whole platform, single transfer artifact. **Cons:** one lockstep upgrade unit; CRD-heavy operators sometimes want separate install ordering (Helm installs CRDs from `crds/` dirs first, but cross-chart CRD dependencies may still need `--no-hooks` staging or two-phase installs). Many teams therefore use **helmfile** or Argo CD "app-of-apps" for orchestration while still sourcing all charts from the internal OCI registry — same offline posture, more flexible sequencing.

---

# 13. Best Practices Summary

**Helm hygiene**
1. Pin chart versions and image tags/digests everywhere; commit lockfiles (`Chart.lock`).
2. `helm template` + lint + kubeconform in CI; store rendered manifests for audit.
3. Layered values files per environment; never edit vendor charts; never commit secrets.
4. `helm upgrade --install --atomic --wait --timeout 10m` in automation — failed upgrades auto-roll back.
5. One release = one app instance; use `-n` namespaces deliberately; RBAC-scope who can install what.

**Offline discipline**
6. Treat charts and images as two problems; solve both, every time.
7. One private OCI registry (ECR/Harbor) for both charts and images; `mirror/` path convention.
8. Scripted, checksummed, scanned, signed bundles — never ad-hoc USB archaeology.
9. Watch for operator-spawned and init-container images your grep missed; verify on a staging cluster.
10. Schedule recurring sync runs; an air gap without a patch pipeline is a CVE museum.

**EKS specifics**
11. Private ECR + VPC endpoints = the cleanest air-gapped EKS story; nodes auth to ECR via IAM (no pull secrets).
12. Keep a small static node group for controllers; Karpenter manages everything else.
13. Scale-to-zero = KEDA cron (timezone-aware) on pods + Karpenter consolidation on nodes + UTC disruption-budget schedules to stop workday churn.
14. Stateful systems (Kafka, NiFi) get always-on pools, PDBs, and drain coordination — never clock-driven zeroing.
15. Cost guardrails: NodePool `limits`, Spot-first `capacity-type`, `expireAfter` for node hygiene.

---

# 14. Troubleshooting Cheat Sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `ImagePullBackOff` after successful install | Artifact-2 problem: nodes can't reach image registry | Check exact image name in `kubectl describe pod`; confirm it points at your mirror; check registry creds/VPC endpoints |
| `helm install` hangs then times out | `--wait` and pods never Ready | Look at pods, not Helm: `kubectl get events -n ns --sort-by=.lastTimestamp` |
| `UPGRADE FAILED: another operation is in progress` | Previous op crashed mid-flight | `helm rollback <rel> <last-good>` or `helm history` then fix stuck `pending-*` state |
| `chart requires kubeVersion >= X` | Old chart vs new cluster (or vice versa) | Pull a compatible chart version; don't `--force` past compatibility gates |
| `no matches for kind ...` | CRDs missing (operator chart not installed first) or removed K8s API | Install CRD-owning chart first; check chart's supported K8s versions |
| OCI push/pull `unauthorized` | Registry login expired (ECR tokens last 12h) | Re-run `aws ecr get-login-password \| helm registry login ...` |
| Karpenter creates no nodes | Discovery tags missing, IAM broken, or requirements unsatisfiable | `kubectl logs -n karpenter deploy/karpenter`; `kubectl describe nodeclaim` |
| Nodes won't scale to zero at night | A pod without a controller, or PDB `maxUnavailable: 0`, pinning a node | List pods on the node; fix PDBs; confirm KEDA actually set replicas=0 |
| Karpenter disrupts during work hours anyway | Budget `schedule` written in local time | Budgets are **UTC**; re-convert (and re-check after DST changes) |
| Strimzi CR "unsupported API version" after upgrade | Pre-1.0 CRs on v1-only CRDs | Follow Strimzi's CRD/CR conversion steps *before* upgrading the operator |
| Bitnami-style chart rejects your mirrored image | Origin-verification guard | `global.security.allowInsecureImages: true` (naming is theirs; it means "non-default registry") |
| `helm template` fine, apply fails | Server-side validation (admission webhooks, policies) | Read the API error; test with `--dry-run=server` |

---

# 15. Glossary

| Term | Meaning |
|---|---|
| **Air gap** | Network with no connectivity to the public internet |
| **ALB / NLB** | AWS Application (L7) / Network (L4) Load Balancer |
| **Chart** | Helm's package: templates + values + metadata |
| **Consolidation** | Karpenter removing/replacing nodes to cut cost |
| **CRD** | Custom Resource Definition — extends the Kubernetes API (e.g., `Kafka`, `NodePool`) |
| **Disruption budget (Karpenter)** | Rules limiting how many nodes Karpenter may disrupt, optionally on a cron schedule (UTC) |
| **ECR** | AWS Elastic Container Registry (holds images *and* OCI Helm charts) |
| **IRSA / Pod Identity** | Mechanisms giving pods scoped AWS IAM permissions |
| **KEDA** | Event-driven autoscaler for workloads; its cron scaler drives time-based replica counts |
| **KRaft** | Kafka's built-in Raft metadata mode (replaces ZooKeeper) |
| **kubelet** | Node agent that (among other things) pulls container images |
| **NodePool / EC2NodeClass** | Karpenter CRDs: node constraints / AWS launch specifics |
| **OCI registry** | Registry speaking the Open Container Initiative protocol; stores images and charts |
| **Operator** | Controller encoding operational expertise for an app (Strimzi, NiFiKop) |
| **PDB** | PodDisruptionBudget — limits voluntary pod evictions |
| **Release / Revision** | An installed chart instance / one version of its history |
| **Values** | Configuration inputs that customize a chart at install time |

---

*End of tutorial. Suggested next steps: run Section 3 on a sandbox cluster today; script Section 6.10 for your artifact pipeline this week; then bring up Sections 8–10 in a connected staging VPC before attempting the first air-gapped install.*
