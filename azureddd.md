# Part 2 — Building a Real CI/CD Pipeline on AKS

### Artifactory + Jenkins + Bitbucket + Jira + Coverity + Java Spring Boot → Docker images

**Companion to:** *Deploying AKS with the Azure CLI — A Complete Beginner's Tutorial*
**Last checked:** August 2026
**Reading level:** Middle school. Every tool is explained before it's used.
**Time:** ~90 minutes for the hands-on part (Artifactory and Jenkins are slow to start)
**Cost:** This needs a bigger cluster than Part 1 — budget roughly $5–15 if you build it, play, and delete it the same day.

> **A note on "covert":** I've read this as **Coverity**, the static code analysis tool (now owned by Black Duck, formerly Synopsys). Because "coverage" is also a reasonable reading, [Section 8](#8-quality-gates-coverage-coverity-sonarqube-and-image-scanning) covers **both** — JaCoCo code coverage *and* Coverity static analysis. Use whichever you meant; the pipeline has a stage for each.

---

## Table of contents

1. [The big picture: what a CI/CD pipeline actually is](#1-the-big-picture-what-a-cicd-pipeline-actually-is)
2. [Meet the tools](#2-meet-the-tools)
3. [Prepare the cluster](#3-prepare-the-cluster)
4. [Step-by-step: deploy Artifactory on AKS](#4-step-by-step-deploy-artifactory-on-aks)
5. [Step-by-step: deploy Jenkins on AKS](#5-step-by-step-deploy-jenkins-on-aks)
6. [The Java Spring Boot app: source, compiler, and Dockerfile](#6-the-java-spring-boot-app-source-compiler-and-dockerfile)
7. [How to build Docker images inside Kubernetes (the big decision)](#7-how-to-build-docker-images-inside-kubernetes-the-big-decision)
8. [Quality gates: coverage, Coverity, SonarQube, and image scanning](#8-quality-gates-coverage-coverity-sonarqube-and-image-scanning)
9. [The complete Jenkinsfile](#9-the-complete-jenkinsfile)
10. [Wiring up Bitbucket](#10-wiring-up-bitbucket)
11. [Wiring up Jira](#11-wiring-up-jira)
12. [The Bitbucket Pipelines alternative (no Jenkins)](#12-the-bitbucket-pipelines-alternative-no-jenkins)
13. [Deploying the app to AKS from the pipeline](#13-deploying-the-app-to-aks-from-the-pipeline)
14. [Options and trade-offs](#14-options-and-trade-offs)
15. [Production best practices](#15-production-best-practices)
16. [Troubleshooting](#16-troubleshooting)
17. [Cost and sizing](#17-cost-and-sizing)
18. [Cheat sheet](#18-cheat-sheet)
19. [Clean up](#19-clean-up)

---

## 1. The big picture: what a CI/CD pipeline actually is

### The problem

Imagine a class project where twelve people edit the same essay. Without rules, you get chaos: someone's paragraph overwrites someone else's, nobody knows which copy is the real one, and the version you print is broken.

Software teams have this problem times a thousand. **CI/CD** is the set of rules and robots that fix it.

- **CI = Continuous Integration.** Every time anyone changes the code, a robot immediately grabs it, compiles it, runs the tests, and shouts if anything broke. Small breaks get caught in minutes instead of weeks.
- **CD = Continuous Delivery/Deployment.** If everything passed, the same robot packages the app and ships it to a server automatically.

### The assembly line you're about to build

```
   Developer types code
          │
          │ git push  (commit message says "PROJ-42 fix login bug")
          ▼
  ┌───────────────┐
  │   BITBUCKET   │  Stores the source code. Sends a webhook ("hey, new code!")
  └───────┬───────┘
          │
          ▼
  ┌────────────────────────────────────────────────────┐
  │  JENKINS  (running inside your AKS cluster)        │
  │                                                    │
  │  Spins up a throwaway agent Pod, which runs:       │
  │                                                    │
  │   1. Checkout      git clone the code              │
  │   2. Compile       Maven + JDK 21 → .class files   │
  │   3. Unit test     JUnit + JaCoCo coverage report  │
  │   4. SonarQube     code smells, coverage gate      │
  │   5. Coverity      deep static security analysis   │
  │   6. Package       → app.jar                       │
  │   7. Image build   BuildKit → Docker image         │
  │   8. Push          → ARTIFACTORY (and/or ACR)      │
  │   9. Scan image    Trivy / Xray                    │
  │  10. Deploy        helm upgrade → AKS namespace    │
  │  11. Notify JIRA   build + deployment info         │
  │                                                    │
  │  Then the agent Pod is deleted. Nothing left over. │
  └──────┬──────────────────────────┬──────────────────┘
         │                          │
         ▼                          ▼
  ┌──────────────┐          ┌──────────────┐
  │ ARTIFACTORY  │          │     JIRA     │
  │ (also on AKS)│          │  ticket now  │
  │              │          │  shows the   │
  │ • .jar files │          │  build ✅ and │
  │ • Docker imgs│          │  deployment  │
  │ • Helm charts│          └──────────────┘
  │ • Maven cache│
  └──────┬───────┘
         │ AKS pulls the image
         ▼
  ┌──────────────────────┐
  │  Your Spring Boot    │
  │  app, running in AKS │
  └──────────────────────┘
```

**The one sentence version:** code goes in one end, a running, tested, scanned application comes out the other, and Jira tells everyone what happened.

---

## 2. Meet the tools

| Tool | In one sentence | Analogy |
|---|---|---|
| **Bitbucket** | Stores source code with full history; Atlassian's competitor to GitHub | The library that keeps every draft of the essay |
| **Jenkins** | The automation robot that runs jobs when things happen | The factory foreman with a clipboard |
| **Artifactory** | A warehouse for *build outputs* — .jar files, Docker images, Helm charts — and a cache for downloads | The stockroom, plus the school supply closet |
| **Jira** | Tracks tickets, bugs, and who's working on what | The class assignment board |
| **Maven** | Downloads Java libraries and runs the compiler in a standard way | The recipe and the shopping list |
| **JDK (javac)** | The actual Java compiler | The oven |
| **Spring Boot** | A framework that makes a Java web app run with one command | A pre-built kitchen so you don't plumb the sink yourself |
| **JUnit + JaCoCo** | Runs tests; measures what % of code the tests touched | The taste test and the checklist of which dishes you tasted |
| **SonarQube** | Scores code quality and enforces a "quality gate" | The rubric your teacher grades against |
| **Coverity** | Deep static analysis that finds security bugs without running the code | The building inspector who reads the blueprints |
| **BuildKit** | Builds Docker images (no Docker daemon needed) | The machine that seals the lunchbox |
| **Trivy / JFrog Xray** | Scans finished images for known vulnerabilities | The metal detector at the door |
| **Helm** | Packages and installs Kubernetes apps | The IKEA flat-pack instructions |

### Two words you'll see constantly

- **Artifact** — any file your build produces. A `.jar`, a `.war`, a Docker image, a `.zip`. Artifactory's whole job is storing these.
- **Agent (or executor)** — a temporary worker that actually runs a build. On Kubernetes, each agent is a **Pod** that's created for one build and deleted afterward. That's the magic: infinite clean build machines, and you pay for them only while they run.

---

## 3. Prepare the cluster

Part 1's one-node cluster is too small. Jenkins, Artifactory, PostgreSQL, and build agents together need real memory.

### 3.1 Create a properly sized cluster

```bash
export RESOURCE_GROUP="rg-cicd-demo"
export CLUSTER_NAME="aks-cicd-demo"
export LOCATION="eastus"
export ACR_NAME="acrcicddemo$RANDOM"     # must be globally unique, lowercase, no dashes

az group create --name $RESOURCE_GROUP --location $LOCATION

az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --tier free \
  --node-count 2 \
  --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME --overwrite-existing
kubectl get nodes
```

> **Why `Standard_D4s_v5`?** 4 vCPU / 16 GB each. Artifactory alone wants ~4 GB, Jenkins ~2 GB, and build agents want 2–4 GB apiece. Two of these nodes is the realistic floor for a demo.

### 3.2 Add a dedicated node pool for build agents (recommended)

Builds are bursty and greedy. Keep them off the nodes running Jenkins and Artifactory.

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME \
  --name buildpool --mode User \
  --node-vm-size Standard_D4s_v5 \
  --node-count 1 \
  --enable-cluster-autoscaler --min-count 0 --max-count 4 \
  --node-taints workload=builds:NoSchedule \
  --labels workload=builds
```

Two things happened here:

- **`--min-count 0`** — when nobody is building, this pool shrinks to **zero nodes** and costs nothing.
- **`--node-taints`** — a taint is a "keep out" sign. Nothing runs on these nodes unless it carries a matching **toleration**. Your Jenkins agent Pods will carry one; Artifactory won't. That's how you guarantee separation.

**Want it even cheaper?** Add `--priority Spot --eviction-policy Delete --spot-max-price -1` to that command. Build agents are the *perfect* Spot workload — if a node is evicted mid-build, Jenkins just retries. Never put Artifactory or the Jenkins controller on Spot.

### 3.3 Install Helm

**Helm** is the package manager for Kubernetes. Instead of writing 400 lines of YAML for Jenkins, you install a **chart** — a pre-written, configurable package.

```bash
# macOS
brew install helm
# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# (Azure Cloud Shell already has it)

helm version    # need 3.17+ for the JFrog charts
```

### 3.4 Create an Azure Container Registry (optional but recommended)

Even if you use Artifactory as your main registry, having ACR attached to the cluster makes image pulls trivially authenticated.

```bash
az acr create -g $RESOURCE_GROUP -n $ACR_NAME --sku Basic
az aks update -g $RESOURCE_GROUP -n $CLUSTER_NAME --attach-acr $ACR_NAME
```

`--attach-acr` grants your cluster's managed identity the `AcrPull` role, so AKS can pull images with **no imagePullSecret at all**. This one command removes an entire category of "ImagePullBackOff" pain.

### 3.5 Create namespaces

A **namespace** is a folder inside the cluster. Keep tools separate from apps.

```bash
kubectl create namespace artifactory
kubectl create namespace jenkins
kubectl create namespace dev
kubectl create namespace staging
```

### 3.6 Check your storage classes

Artifactory and Jenkins both need disks that survive Pod restarts.

```bash
kubectl get storageclass
```

You'll see `default`, `managed-csi`, `managed-csi-premium`, `azurefile-csi`, and friends. Use **`managed-csi-premium`** for anything database-like — Artifactory on a standard HDD-backed disk is miserably slow.

---

## 4. Step-by-step: deploy Artifactory on AKS

### 4.1 What Artifactory is, before you install it

When your build runs `mvn package`, Maven downloads ~200 library files from the internet. Every build. From every agent. That is slow, wastes bandwidth, and breaks entirely when the internet hiccups or a library gets deleted from the public repo.

Artifactory solves three problems at once:

1. **Remote repository (a cache/proxy).** Point Maven at Artifactory instead of Maven Central. First download is slow; every download after that is local and instant. It also means your builds keep working even if Maven Central is down.
2. **Local repository (your stuff).** Where *your* built `.jar` files and Docker images live, with full version history and metadata about which build produced them.
3. **Virtual repository.** One URL that transparently searches your local repos first, then the remote caches. Developers configure one address and never think about it again.

It's a **universal** repository: Maven, npm, PyPI, NuGet, Go, Helm, and Docker all in one system.

### 4.2 Which Artifactory edition?

| Edition | Docker registry support? | Cost | Good for |
|---|---|---|---|
| **Artifactory OSS** | ❌ No | Free | Maven/Gradle only |
| **JFrog Container Registry (JCR)** | ✅ Yes (Docker + Helm) | Free | Learning, small teams |
| **Artifactory Pro** | ✅ Yes, all package types | Paid (30-day trial) | Most companies |
| **Enterprise / Cloud** | ✅ + HA, replication, Xray | Paid | Large orgs |
| **JFrog Cloud (SaaS)** | ✅ | Paid subscription | Teams who don't want to run it |

This tutorial uses the **Pro trial** (grab a free trial license from jfrog.com) because it supports Docker repositories. Substitute JCR if you want zero cost.

### 4.3 Install it

```bash
helm repo add jfrog https://charts.jfrog.io
helm repo update
helm search repo jfrog/artifactory --versions | head -5
```

Artifactory needs two secrets you generate yourself:

- **Master key** — encrypts stored credentials
- **Join key** — lets microservices inside the platform trust each other

**Generate them once and save them somewhere safe.** If you lose the master key after storing encrypted secrets, those secrets are unrecoverable.

```bash
export MASTER_KEY=$(openssl rand -hex 32)
export JOIN_KEY=$(openssl rand -hex 32)
echo "MASTER_KEY=$MASTER_KEY"   # <- copy these into your password manager
echo "JOIN_KEY=$JOIN_KEY"
```

Create a values file:

```bash
cat > artifactory-values.yaml << 'EOF'
artifactory:
  # Pull the Pro image (supports Docker repositories). For free JCR, use:
  #   image:
  #     repository: releases-docker.jfrog.io/jfrog/artifactory-jcr
  persistence:
    enabled: true
    size: 50Gi
    storageClassName: managed-csi-premium
  resources:
    requests:
      cpu: "1"
      memory: 4Gi
    limits:
      cpu: "2"
      memory: 6Gi
  javaOpts:
    xms: "2g"
    xmx: "4g"

postgresql:
  enabled: true          # bundled DB — fine for a demo, NOT for production
  persistence:
    size: 20Gi
    storageClassName: managed-csi-premium

nginx:
  enabled: true
  https:
    enabled: false       # HTTP only for this demo; see the TLS note below
  service:
    type: LoadBalancer
EOF
```

Install:

```bash
helm upgrade --install artifactory jfrog/artifactory \
  --namespace artifactory --create-namespace \
  --set artifactory.masterKey=$MASTER_KEY \
  --set artifactory.joinKey=$JOIN_KEY \
  -f artifactory-values.yaml \
  --timeout 15m
```

> ⚠️ **TLS gotcha (current behavior):** starting with chart version **107.161.x**, the chart **no longer auto-generates a self-signed TLS certificate**. With the default `nginx.https.enabled=true`, a fresh install **fails** unless you either supply your own certificate with `--set nginx.tlsSecretName=<name>`, opt into a chart-generated self-signed cert with `--set nginx.generateSelfSignedCert=true` (dev/test only), or disable HTTPS as this demo does. In production, supply a real certificate — cert-manager with Let's Encrypt is the usual answer.

Watch it come up (this genuinely takes several minutes):

```bash
kubectl -n artifactory get pods -w
kubectl -n artifactory rollout status statefulset/artifactory
kubectl -n artifactory logs -f artifactory-0 -c artifactory
```

Get the address:

```bash
kubectl -n artifactory get svc
export ART_IP=$(kubectl -n artifactory get svc artifactory-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Artifactory: http://$ART_IP"
```

Open it in a browser. Default login is `admin` / `password` — **change it immediately** in the onboarding wizard, then apply your trial license.

### 4.4 Create the repositories you need

In the Artifactory UI: **Administration → Repositories → Create a Repository**.

| Create this | Type | Name | Purpose |
|---|---|---|---|
| Maven | Remote | `maven-remote` | Caches Maven Central |
| Maven | Local | `libs-release-local` | Your released `.jar` files |
| Maven | Local | `libs-snapshot-local` | Your in-progress `.jar` files |
| Maven | Virtual | `maven-virtual` | Combines all three — this is the URL you give Maven |
| Docker | Local | `docker-local` | Your built images |
| Docker | Remote | `docker-remote` | Caches Docker Hub |
| Docker | Virtual | `docker-virtual` | The single Docker URL |
| Helm | Local | `helm-local` | Your Helm charts |

**Docker repository addressing** matters and confuses everyone. There are two modes:

- **Subdomain** (`docker-local.artifactory.mycompany.com`) — cleanest, needs a wildcard DNS entry and wildcard certificate.
- **Repository path** (`artifactory.mycompany.com/docker-local/myimage:1.0`) — no DNS work, and what this tutorial assumes.

### 4.5 Point Maven at Artifactory

Create `settings.xml` — this tells Maven "never talk to the internet directly, always go through Artifactory."

```xml
<settings>
  <servers>
    <server>
      <id>central</id>
      <username>${env.ARTIFACTORY_USER}</username>
      <password>${env.ARTIFACTORY_TOKEN}</password>
    </server>
    <server>
      <id>snapshots</id>
      <username>${env.ARTIFACTORY_USER}</username>
      <password>${env.ARTIFACTORY_TOKEN}</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>central</id>
      <name>Artifactory virtual repo</name>
      <url>http://artifactory-nginx.artifactory.svc.cluster.local/artifactory/maven-virtual</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
</settings>
```

Note the URL: `artifactory-nginx.artifactory.svc.cluster.local`. That's Kubernetes' internal DNS name — build agents reach Artifactory **inside** the cluster, so the traffic never leaves the virtual network. Faster and safer.

Store this as a Kubernetes ConfigMap so agents can mount it:

```bash
kubectl -n jenkins create configmap maven-settings --from-file=settings.xml
```

### 4.6 Create a token for CI to use

In Artifactory: **Administration → User Management → Access Tokens → Generate Token**, scoped to a dedicated `ci-user` with permission to deploy to `libs-*-local` and `docker-local`.

**Never use the `admin` account in a pipeline.** If that token leaks, the attacker owns your entire artifact store.

---

## 5. Step-by-step: deploy Jenkins on AKS

### 5.1 How Jenkins on Kubernetes works

Old-school Jenkins ran on one big server that slowly filled up with junk from a hundred different projects — "works on the build server" became its own class of bug.

On Kubernetes there are two parts:

- **Controller** — one long-running Pod. It holds the web UI, job configuration, credentials, and build history. It does *not* run builds.
- **Agents** — Pods created on demand. Jenkins reads your `Jenkinsfile`, sees you asked for a Pod with a Maven container and a BuildKit container, creates exactly that Pod, runs the build in it, collects the results, and **deletes the Pod**.

Every build therefore starts from a guaranteed-clean machine. There is no leftover state, and idle capacity costs nothing.

### 5.2 Install Jenkins

```bash
helm repo add jenkins https://charts.jenkins.io
helm repo update
```

Create the values file. This uses **JCasC** (Jenkins Configuration as Code) — instead of clicking through the UI and hoping you remember what you did, the entire configuration lives in this file, in version control.

```bash
cat > jenkins-values.yaml << 'EOF'
controller:
  adminUser: admin
  # adminPassword: leave unset -> chart generates one; retrieve it from the Secret

  resources:
    requests:
      cpu: "1"
      memory: 2Gi
    limits:
      cpu: "2"
      memory: 4Gi

  serviceType: LoadBalancer      # use ClusterIP + Ingress in production

  installPlugins:
    - kubernetes:latest
    - workflow-aggregator:latest
    - git:latest
    - configuration-as-code:latest
    - credentials-binding:latest
    # --- Bitbucket ---
    - cloudbees-bitbucket-branch-source:latest
    # --- Jira ---
    - atlassian-jira-software-cloud:latest
    # --- Quality / security ---
    - sonar:latest
    - jacoco:latest
    - blackduck-security-scan:latest
    # --- Java build tooling ---
    - pipeline-maven:latest
    - junit:latest
    # --- Artifactory ---
    - artifactory:latest

  JCasC:
    defaultConfig: true
    configScripts:
      pod-templates: |
        jenkins:
          clouds:
            - kubernetes:
                name: "aks"
                namespace: "jenkins"
                jenkinsUrl: "http://jenkins.jenkins.svc.cluster.local:8080"
                jenkinsTunnel: "jenkins-agent.jenkins.svc.cluster.local:50000"
                containerCapStr: "10"
                templates:
                  - name: "default"
                    namespace: "jenkins"
                    label: "default"
                    yamlMergeStrategy: "merge"

persistence:
  enabled: true
  size: 20Gi
  storageClass: managed-csi-premium

agent:
  enabled: true
  resources:
    requests:
      cpu: "500m"
      memory: 1Gi
    limits:
      cpu: "2"
      memory: 4Gi

rbac:
  create: true

serviceAccount:
  create: true
  name: jenkins
EOF
```

Install:

```bash
helm upgrade --install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  -f jenkins-values.yaml \
  --timeout 15m

kubectl -n jenkins rollout status statefulset/jenkins
```

Get in:

```bash
kubectl -n jenkins get secret jenkins \
  -o jsonpath="{.data.jenkins-admin-password}" | base64 --decode; echo

export JENKINS_IP=$(kubectl -n jenkins get svc jenkins \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Jenkins: http://$JENKINS_IP:8080"
```

> 🔒 **Do not leave this on a public LoadBalancer.** A Jenkins controller open to the internet is one of the most reliably exploited things in all of DevOps. For anything beyond a 30-minute demo, use `serviceType: ClusterIP` plus an Ingress with authentication, or just reach it privately: `kubectl -n jenkins port-forward svc/jenkins 8080:8080` and browse to `http://localhost:8080`.

### 5.3 Give Jenkins permission to deploy

Jenkins needs to run `kubectl` and `helm` against the `dev` and `staging` namespaces. Grant **only** that — not cluster-admin.

```bash
cat > jenkins-deploy-rbac.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-deployer
  namespace: dev
rules:
  - apiGroups: ["", "apps", "networking.k8s.io", "autoscaling", "batch"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-deployer
  namespace: dev
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: jenkins
roleRef:
  kind: Role
  name: jenkins-deployer
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f jenkins-deploy-rbac.yaml
# Repeat for the staging namespace by changing "namespace: dev"
```

### 5.4 Add credentials

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials.** Create these:

| ID | Kind | What it is |
|---|---|---|
| `bitbucket-creds` | Username + password | Bitbucket username + **app password** (never your real password) |
| `artifactory-creds` | Username + password | The `ci-user` and its access token |
| `sonarqube-token` | Secret text | SonarQube token |
| `coverity-creds` | Username + password | Coverity Connect user + password |
| `coverity-url` | Secret text | e.g. `https://coverity.mycompany.com` |
| `jira-cloud-creds` | Secret text (OAuth) | Generated by the Jenkins for Jira app |
| `acr-creds` | Username + password | Only if pushing to ACR without managed identity |

> **Better still:** store real secrets in **Azure Key Vault** and pull them in with the Secrets Store CSI driver + workload identity, so nothing sensitive lives in Jenkins at all. See [Section 15](#15-production-best-practices).

---

## 6. The Java Spring Boot app: source, compiler, and Dockerfile

### 6.1 The repository layout

```
my-spring-app/
├── src/
│   ├── main/java/com/example/demo/DemoApplication.java
│   └── test/java/com/example/demo/DemoApplicationTests.java
├── pom.xml
├── Dockerfile
├── Jenkinsfile
├── bitbucket-pipelines.yml      (only if using Bitbucket Pipelines instead)
├── coverity.yaml
├── helm/
│   └── my-spring-app/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           └── service.yaml
└── .dockerignore
```

### 6.2 `pom.xml` — the build recipe

**Maven** reads this file to know which libraries to download, which Java version to compile against, and which plugins to run.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.4.2</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>my-spring-app</artifactId>
  <version>1.0.0-SNAPSHOT</version>

  <properties>
    <java.version>21</java.version>   <!-- LTS: 17, 21, and 25 are the long-support choices -->
    <sonar.coverage.jacoco.xmlReportPaths>
      ${project.build.directory}/site/jacoco/jacoco.xml
    </sonar.coverage.jacoco.xmlReportPaths>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>  <!-- gives /actuator/health -->
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
        <configuration>
          <layers><enabled>true</enabled></configuration>  <!-- enables layered jars, see 6.4 -->
        </configuration>
      </plugin>

      <!-- Code coverage measurement -->
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>0.8.12</version>
        <executions>
          <execution><goals><goal>prepare-agent</goal></goals></execution>
          <execution>
            <id>report</id><phase>test</phase>
            <goals><goal>report</goal></goals>
          </execution>
          <execution>
            <id>coverage-gate</id><phase>verify</phase>
            <goals><goal>check</goal></goals>
            <configuration>
              <rules>
                <rule>
                  <element>BUNDLE</element>
                  <limits>
                    <limit>
                      <counter>LINE</counter>
                      <value>COVEREDRATIO</value>
                      <minimum>0.60</minimum>   <!-- fail the build under 60% -->
                    </limit>
                  </limits>
                </rule>
              </rules>
            </configuration>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>

  <!-- Publish built jars to Artifactory -->
  <distributionManagement>
    <repository>
      <id>central</id>
      <url>http://artifactory-nginx.artifactory.svc.cluster.local/artifactory/libs-release-local</url>
    </repository>
    <snapshotRepository>
      <id>snapshots</id>
      <url>http://artifactory-nginx.artifactory.svc.cluster.local/artifactory/libs-snapshot-local</url>
    </snapshotRepository>
  </distributionManagement>
</project>
```

**About Java versions:** stick to **LTS** (Long Term Support) releases — 17, 21, and 25. Non-LTS releases lose support in six months, which is a bad foundation for a production service. Spring Boot 3.x requires Java 17 or newer.

**Maven vs Gradle:**

| | Maven | Gradle |
|---|---|---|
| Config file | `pom.xml` (XML, verbose, rigid) | `build.gradle(.kts)` (code, flexible) |
| Learning curve | Gentle — one right way to do things | Steeper — many right ways |
| Speed | Slower, but very predictable | Faster (incremental builds, build cache) |
| Best for | Standard apps, big teams, less surprise | Big multi-module projects, custom logic |

Either works. Maven's predictability makes it the safer default for a first pipeline.

### 6.3 The Dockerfile — the naive version, then the good one

**The version most people write first:**

```dockerfile
FROM eclipse-temurin:21-jdk
COPY target/my-spring-app-1.0.0-SNAPSHOT.jar app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
```

This works, and it's bad. The image carries a full JDK (~450 MB) when running only needs a JRE, it runs as **root**, and every code change re-uploads the entire jar — including 60 MB of unchanged dependencies.

**The version you should use — multi-stage + layered jar:**

```dockerfile
# syntax=docker/dockerfile:1.7

# ---------- STAGE 1: build ----------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /workspace

# Copy the dependency list alone first. If pom.xml hasn't changed,
# Docker reuses the cached dependency download - a huge time saver.
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -s /root/.m2/settings.xml dependency:go-offline

COPY src ./src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -s /root/.m2/settings.xml clean package -DskipTests

# Split the fat jar into layers that change at different speeds
RUN java -Djarmode=layertools -jar target/*.jar extract --destination extracted

# ---------- STAGE 2: runtime ----------
FROM eclipse-temurin:21-jre-alpine AS runtime

RUN addgroup -S spring && adduser -S spring -G spring
WORKDIR /app

# Order matters: least-likely-to-change first.
COPY --from=build --chown=spring:spring /workspace/extracted/dependencies/ ./
COPY --from=build --chown=spring:spring /workspace/extracted/spring-boot-loader/ ./
COPY --from=build --chown=spring:spring /workspace/extracted/snapshot-dependencies/ ./
COPY --from=build --chown=spring:spring /workspace/extracted/application/ ./

USER spring:spring
EXPOSE 8080

ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s \
  CMD wget -qO- http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java","org.springframework.boot.loader.launch.JarLauncher"]
```

Why each trick matters:

- **Multi-stage** — the JDK, Maven, and all source code stay in stage 1 and are thrown away. Only the JRE and the app ship. Image drops from ~700 MB to ~200 MB.
- **Layered jar** — your code changes hourly; your dependencies change monthly. Splitting them means a code-only change re-uploads ~2 MB instead of ~60 MB. Deploys get dramatically faster.
- **Non-root user** — if someone breaks into your container, they land as `spring`, not `root`. Many clusters block root containers outright via Pod Security Standards.
- **`MaxRAMPercentage`** — without this, older JVMs read the *host's* memory, not the container limit, then get OOM-killed at 3 a.m. This tells the JVM to use 75% of its container limit.
- **`--mount=type=cache`** — a BuildKit feature that persists the Maven cache between builds without baking it into the image.

`.dockerignore` (stops you from shipping junk and busting the cache):

```
target/
.git/
.idea/
*.iml
.mvn/wrapper/maven-wrapper.jar
```

### 6.4 A serious alternative for Java: Jib

**Jib** (from Google) builds optimized container images for Java apps **without a Dockerfile and without a container runtime at all**. It's a Maven/Gradle plugin.

```xml
<plugin>
  <groupId>com.google.cloud.tools</groupId>
  <artifactId>jib-maven-plugin</artifactId>
  <version>3.4.4</version>
  <configuration>
    <from><image>eclipse-temurin:21-jre-alpine</image></from>
    <to>
      <image>artifactory.mycompany.com/docker-local/my-spring-app</image>
      <tags><tag>${project.version}</tag></tags>
    </to>
    <container>
      <user>1000:1000</user>
      <ports><port>8080</port></ports>
      <jvmFlags><jvmFlag>-XX:MaxRAMPercentage=75.0</jvmFlag></jvmFlags>
    </container>
  </configuration>
</plugin>
```

Then in the pipeline it's just `mvn jib:build`.

| | Jib | Dockerfile + BuildKit |
|---|---|---|
| Needs a builder container in CI | ❌ No | ✅ Yes |
| Needs privileged/root | ❌ Never | Only for some modes |
| Layer optimization | ✅ Automatic and excellent | Manual, but you control it |
| Reproducible builds | ✅ By default | Requires effort |
| Works for non-Java | ❌ Java only | ✅ Anything |
| Custom OS packages in the image | ❌ Hard | ✅ Easy |

**Honest take:** for a pure Java Spring Boot service, **Jib is often the better choice** — simpler, faster, safer, and no builder infrastructure. Use a Dockerfile when you need OS-level packages, a non-Java sidecar process, or a build shape Jib can't express. The pipeline in Section 9 shows the Dockerfile path because it's the general-purpose skill; a Jib variant is included as a comment.

---

## 7. How to build Docker images inside Kubernetes (the big decision)

This is the part of the tutorial that has changed most recently, and where old blog posts will actively mislead you.

### The core problem

Kubernetes runs containers. It does **not** build them. So how does a build agent — which is itself a container — build a container?

For years there were two answers, both flawed:

1. **Mount the host's Docker socket** (`/var/run/docker.sock`) into the build Pod. This gives the build **root on the node**. Any malicious `Dockerfile` in any pull request owns your cluster. Do not do this.
2. **Docker-in-Docker (DinD)** — run a privileged Docker daemon inside the build Pod. Better isolation than the socket, but `privileged: true` is still a very large security hole.

Then Kaniko arrived and became the standard answer. **Kaniko is now archived.** Google archived the repository in June 2025, and Chainguard maintains a fork focused on security patches rather than new features. Tutorials recommending Kaniko as the default are out of date; downstream projects have been migrating to Buildah and BuildKit.

### Your options today

| Option | How it works | Privileges needed | Pros | Cons |
|---|---|---|---|---|
| **BuildKit (rootless)** ⭐ | Docker's modern build engine, runs as a Pod or daemonset | Rootless mode; some clusters need seccomp/AppArmor tweaks | Fastest, best caching, multi-arch, actively developed, standard `Dockerfile` support | Rootless setup has sharp edges on locked-down clusters |
| **Buildah** ⭐ | Red Hat's daemonless builder | Rootless with `chroot` isolation; sometimes needs `vfs` storage driver | Actively maintained, CNCF ecosystem, Dockerfile-compatible | `vfs` mode is slow; privilege requirements vary by cluster |
| **ACR Tasks** (`az acr build`) ⭐ | You send the build context to Azure; **Azure builds it outside your cluster** | **None in-cluster** | Zero build infrastructure to secure or maintain, no privileged Pods anywhere, cheap | Azure-only, less control, must upload the build context |
| **Jib** | Maven/Gradle plugin, no container runtime | **None** | Simplest and safest for Java | Java only, no Dockerfile |
| **Cloud Native Buildpacks** (`pack`, or `spring-boot:build-image`) | Detects your app type and builds an image with no Dockerfile | Usually needs a daemon or a builder service | No Dockerfile to maintain, sensible security defaults | Less control, opaque when it goes wrong |
| **Docker-in-Docker** | Privileged Docker daemon in the Pod | `privileged: true` ❌ | Familiar, works everywhere | Serious security risk; avoid in shared clusters |
| **Kaniko** | Userspace layer snapshotting | Non-root | Was the standard for years | **Archived June 2025** — no new features; only community/Chainguard fork patches |

### The recommendation

- **Java-only shop?** Use **Jib**. Skip this whole problem.
- **Mixed languages on Azure?** Use **`az acr build`** (ACR Tasks). Your cluster never builds anything, so there's nothing privileged to secure. This is the pragmatic winner for most AKS teams.
- **Need in-cluster builds** (air-gapped, cost, or policy)? Use **rootless BuildKit**, with **Buildah** as the fallback if BuildKit fights your cluster's security policies.
- **Already on Kaniko?** It still runs. Plan a migration; don't panic today.

### The ACR Tasks one-liner, for perspective

```bash
az acr build \
  --registry $ACR_NAME \
  --image my-spring-app:$BUILD_NUMBER \
  --file Dockerfile .
```

That single command uploads your context, builds the image on Azure's infrastructure, and pushes it to your registry. No BuildKit Pod, no privileges, no daemon. When people say "the best code is the code you don't write," this is what they mean.

---

## 8. Quality gates: coverage, Coverity, SonarQube, and image scanning

A **quality gate** is a rule that stops a build when the code isn't good enough. Without gates, "we'll fix the tests later" becomes "we have no tests."

### 8.1 JaCoCo — code coverage

**Coverage** answers one question: when your tests ran, what percentage of your code lines actually executed? If your tests only ever touch 20% of the code, the other 80% is untested — you just don't know it yet.

Configured in the `pom.xml` above. The `check` goal fails the build below 60%.

⚠️ **Coverage is a floor, not a goal.** 100% coverage with meaningless assertions proves nothing. A team chasing a coverage number will write tests that execute code without checking results. Use it to catch *untested* code, not to score people.

### 8.2 SonarQube — code quality and the gate

SonarQube looks at your whole codebase and reports bugs, "code smells," duplication, complexity, and security hotspots. Its **quality gate** is the pass/fail summary, typically set to "new code must be 80% covered and have zero new blocker issues."

```groovy
stage('SonarQube') {
  steps {
    container('maven') {
      withSonarQubeEnv('sonarqube') {
        sh 'mvn -B sonar:sonar -Dsonar.projectKey=my-spring-app'
      }
    }
  }
}
stage('Quality Gate') {
  steps {
    timeout(time: 10, unit: 'MINUTES') {
      waitForQualityGate abortPipeline: true
    }
  }
}
```

You can run SonarQube in the cluster too:

```bash
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm upgrade --install sonarqube sonarqube/sonarqube \
  --namespace sonarqube --create-namespace \
  --set persistence.enabled=true
```

### 8.3 Coverity — deep static analysis

**Coverity** (Black Duck, formerly Synopsys) is a different animal from SonarQube. It builds a full structural model of your program and traces how data flows through it across files and libraries, which lets it find defects that only appear when several components interact — the kind of bug no linter catches. It covers 20+ languages including Java, C, and C++, and maps findings to security and functional-safety standards.

**How Coverity works, in three steps:**

1. **`cov-build`** wraps your normal compile (`mvn package`) and records everything the compiler does into an intermediate directory.
2. **`cov-analyze`** studies that recording and finds defects.
3. **`cov-commit-defects`** uploads the results to **Coverity Connect**, the server where teams triage findings.

**Option A — the Jenkins plugin (recommended).** The **Black Duck Security Scan** plugin drives Coverity through Black Duck's Bridge CLI:

```groovy
stage('Coverity SAST') {
  steps {
    container('maven') {
      withCredentials([usernamePassword(
          credentialsId: 'coverity-creds',
          usernameVariable: 'COVERITY_USER',
          passwordVariable: 'COVERITY_PASSPHRASE')]) {
        security_scan(
          product: 'coverity',
          coverity_project_name: 'my-spring-app',
          coverity_stream_name: "my-spring-app-${env.BRANCH_NAME}",
          coverity_build_command: 'mvn -B clean package -DskipTests',
          coverity_clean_command: 'mvn -B clean',
          mark_build_status: 'FAILURE'   // FAILURE | UNSTABLE | SUCCESS
        )
      }
    }
  }
}
```

Useful details from the plugin's documentation: project and stream names are **mandatory for freestyle and standard pipeline jobs** but optional for multibranch jobs (it infers them); `mark_build_status` controls whether policy violations fail the build or merely mark it unstable; and it can post **pull request comments** automatically, filtered by impact (HIGH by default), when given an SCM token.

**Option B — raw CLI**, if you're not using the plugin:

```groovy
stage('Coverity SAST') {
  steps {
    container('coverity') {
      sh '''
        export PATH=$PATH:/opt/coverity/bin
        cov-build --dir idir mvn -B clean package -DskipTests
        cov-analyze --dir idir --all --strip-path $WORKSPACE
        cov-commit-defects --dir idir \
          --url $COVERITY_URL \
          --stream my-spring-app-${BRANCH_NAME} \
          --user $COVERITY_USER --password $COVERITY_PASSPHRASE
      '''
    }
  }
}
```

**Practical warnings:**

- Coverity is **commercial and licensed**. You need a license server reachable from your build Pods, and the analysis container needs the Coverity Analysis tools baked into it — the image will be several GB.
- Analysis is **slow** — minutes to hours on large codebases. Run it nightly or on pull requests to `main`, not on every commit to every feature branch. The pipeline in Section 9 does exactly this.
- The initial run will report a wall of findings. Triage them once, mark false positives, and enforce "no *new* defects" from then on. Trying to fix everything on day one guarantees the team turns the gate off.

**SonarQube vs Coverity:** they overlap but aren't substitutes. Sonar is fast, cheap, and great at everyday quality and coverage gates. Coverity is slow, expensive, and finds deep cross-component security defects that Sonar misses. Regulated industries (automotive, medical, aerospace) usually require Coverity or equivalent; most web teams run Sonar alone.

### 8.4 Scan the finished image

Compiled code isn't the only risk — your base image ships hundreds of OS packages, any of which might have a known CVE.

```groovy
stage('Image Scan') {
  steps {
    container('trivy') {
      sh '''
        trivy image --exit-code 1 --severity HIGH,CRITICAL \
          --ignore-unfixed $IMAGE_FULL
      '''
    }
  }
}
```

`--ignore-unfixed` matters: without it you'll fail builds over vulnerabilities that have no patch available, which teaches everyone to ignore the scanner.

If you have **JFrog Xray**, it scans everything in Artifactory continuously and can block downloads of any artifact that violates policy — a stronger position than scanning once at build time. Azure's equivalent is **Microsoft Defender for Containers**.

---

## 9. The complete Jenkinsfile

This is the whole pipeline. Read the comments — this is the payoff for everything above.

```groovy
pipeline {

  // Define the build agent as a Kubernetes Pod with several containers.
  // All containers share the same workspace volume, so `mvn` output in one
  // is visible to the image builder in another.
  agent {
    kubernetes {
      yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    build: my-spring-app
spec:
  # Land on the dedicated build node pool (see section 3.2)
  nodeSelector:
    workload: builds
  tolerations:
    - key: "workload"
      operator: "Equal"
      value: "builds"
      effect: "NoSchedule"

  securityContext:
    runAsNonRoot: true
    runAsUser: 1000

  containers:
    # --- Java compile + test ---
    - name: maven
      image: maven:3.9-eclipse-temurin-21
      command: ["sleep"]
      args: ["infinity"]
      resources:
        requests: { cpu: "1", memory: "2Gi" }
        limits:   { cpu: "2", memory: "4Gi" }
      volumeMounts:
        - name: maven-settings
          mountPath: /root/.m2/settings.xml
          subPath: settings.xml
        - name: maven-cache
          mountPath: /root/.m2/repository

    # --- Container image build (rootless BuildKit) ---
    - name: buildkit
      image: moby/buildkit:v0.19.0-rootless
      command: ["sleep"]
      args: ["infinity"]
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile: { type: Unconfined }
        appArmorProfile: { type: Unconfined }
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      resources:
        requests: { cpu: "1", memory: "2Gi" }
        limits:   { cpu: "2", memory: "4Gi" }

    # --- Image vulnerability scanning ---
    - name: trivy
      image: aquasec/trivy:latest
      command: ["sleep"]
      args: ["infinity"]

    # --- Deploy to the cluster ---
    - name: helm
      image: alpine/helm:3.16.3
      command: ["sleep"]
      args: ["infinity"]

  volumes:
    - name: maven-settings
      configMap:
        name: maven-settings
    - name: maven-cache
      persistentVolumeClaim:
        claimName: maven-cache-pvc     # shared dependency cache across builds
"""
    }
  }

  options {
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '30'))
    disableConcurrentBuilds(abortPrevious: true)
    timestamps()
  }

  environment {
    ARTIFACTORY_URL  = 'http://artifactory-nginx.artifactory.svc.cluster.local/artifactory'
    DOCKER_REGISTRY  = 'artifactory.mycompany.com'      // external hostname for pushes
    DOCKER_REPO      = 'docker-local'
    APP_NAME         = 'my-spring-app'

    // Immutable, traceable tag: git short SHA + build number. NEVER ':latest'.
    GIT_SHORT        = "${env.GIT_COMMIT?.take(7) ?: 'nogit'}"
    IMAGE_TAG        = "${env.BUILD_NUMBER}-${GIT_SHORT}"
    IMAGE_FULL       = "${DOCKER_REGISTRY}/${DOCKER_REPO}/${APP_NAME}:${IMAGE_TAG}"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_COMMIT_MSG = sh(script: 'git log -1 --pretty=%B', returnStdout: true).trim()
          echo "Branch: ${env.BRANCH_NAME}  Commit: ${env.GIT_COMMIT}"
          // Jira issue keys live in the branch name or commit message, e.g. PROJ-42
        }
      }
    }

    stage('Compile') {
      steps {
        container('maven') {
          sh 'mvn -B -s /root/.m2/settings.xml clean compile'
        }
      }
    }

    stage('Unit Tests + Coverage') {
      steps {
        container('maven') {
          sh 'mvn -B -s /root/.m2/settings.xml test'
        }
      }
      post {
        always {
          junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
          jacoco(
            execPattern: 'target/jacoco.exec',
            classPattern: 'target/classes',
            sourcePattern: 'src/main/java',
            minimumLineCoverage: '60',
            changeBuildStatus: true
          )
        }
      }
    }

    // Fast quality checks run on every commit...
    stage('SonarQube') {
      steps {
        container('maven') {
          withSonarQubeEnv('sonarqube') {
            sh "mvn -B -s /root/.m2/settings.xml sonar:sonar -Dsonar.projectKey=${APP_NAME}"
          }
        }
      }
    }

    stage('Quality Gate') {
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    // ...but slow deep analysis only where it earns its cost.
    stage('Coverity SAST') {
      when {
        anyOf {
          branch 'main'
          branch 'release/*'
          changeRequest target: 'main'
        }
      }
      steps {
        container('maven') {
          withCredentials([usernamePassword(
              credentialsId: 'coverity-creds',
              usernameVariable: 'COVERITY_USER',
              passwordVariable: 'COVERITY_PASSPHRASE')]) {
            security_scan(
              product: 'coverity',
              coverity_project_name: "${APP_NAME}",
              coverity_stream_name: "${APP_NAME}-${env.BRANCH_NAME}",
              coverity_build_command: 'mvn -B clean package -DskipTests',
              coverity_clean_command: 'mvn -B clean',
              mark_build_status: 'FAILURE'
            )
          }
        }
      }
    }

    stage('Package') {
      steps {
        container('maven') {
          sh 'mvn -B -s /root/.m2/settings.xml package -DskipTests'
          archiveArtifacts artifacts: 'target/*.jar', fingerprint: true
        }
      }
    }

    stage('Publish JAR to Artifactory') {
      steps {
        container('maven') {
          withCredentials([usernamePassword(
              credentialsId: 'artifactory-creds',
              usernameVariable: 'ARTIFACTORY_USER',
              passwordVariable: 'ARTIFACTORY_TOKEN')]) {
            sh 'mvn -B -s /root/.m2/settings.xml deploy -DskipTests'
          }
        }
      }
    }

    stage('Build & Push Image') {
      steps {
        container('buildkit') {
          withCredentials([usernamePassword(
              credentialsId: 'artifactory-creds',
              usernameVariable: 'ARTIFACTORY_USER',
              passwordVariable: 'ARTIFACTORY_TOKEN')]) {
            sh '''
              mkdir -p /home/user/.docker
              AUTH=$(echo -n "$ARTIFACTORY_USER:$ARTIFACTORY_TOKEN" | base64 -w 0)
              cat > /home/user/.docker/config.json <<EOF
{ "auths": { "${DOCKER_REGISTRY}": { "auth": "${AUTH}" } } }
EOF
              buildctl-daemonless.sh build \
                --frontend dockerfile.v0 \
                --local context=. \
                --local dockerfile=. \
                --opt build-arg:APP_VERSION=${IMAGE_TAG} \
                --output type=image,name=${IMAGE_FULL},push=true \
                --export-cache type=inline \
                --import-cache type=registry,ref=${DOCKER_REGISTRY}/${DOCKER_REPO}/${APP_NAME}:buildcache
            '''
          }
        }
        // --- Alternative 1: Jib (no builder container needed at all) ---
        // container('maven') { sh "mvn -B jib:build -Djib.to.image=${IMAGE_FULL}" }
        //
        // --- Alternative 2: ACR Tasks (Azure builds it, nothing privileged in-cluster) ---
        // container('azcli') { sh "az acr build -r ${ACR_NAME} -t ${APP_NAME}:${IMAGE_TAG} ." }
      }
    }

    stage('Scan Image') {
      steps {
        container('trivy') {
          sh '''
            trivy image --exit-code 1 --severity HIGH,CRITICAL \
              --ignore-unfixed --no-progress ${IMAGE_FULL}
          '''
        }
      }
    }

    stage('Deploy to dev') {
      when { anyOf { branch 'develop'; branch 'main' } }
      steps {
        container('helm') {
          sh '''
            helm upgrade --install ${APP_NAME} ./helm/my-spring-app \
              --namespace dev \
              --set image.repository=${DOCKER_REGISTRY}/${DOCKER_REPO}/${APP_NAME} \
              --set image.tag=${IMAGE_TAG} \
              --atomic --timeout 5m --wait
          '''
        }
      }
      post {
        success {
          // Tell Jira a deployment happened
          jiraSendDeploymentInfo(
            site: 'mycompany.atlassian.net',
            environmentId: 'dev-1',
            environmentName: 'dev',
            environmentType: 'development'
          )
        }
      }
    }

    stage('Approve production') {
      when { branch 'main' }
      steps {
        timeout(time: 24, unit: 'HOURS') {
          input message: "Deploy ${IMAGE_TAG} to staging?", ok: 'Ship it'
        }
      }
    }

    stage('Deploy to staging') {
      when { branch 'main' }
      steps {
        container('helm') {
          sh '''
            helm upgrade --install ${APP_NAME} ./helm/my-spring-app \
              --namespace staging \
              --set image.repository=${DOCKER_REGISTRY}/${DOCKER_REPO}/${APP_NAME} \
              --set image.tag=${IMAGE_TAG} \
              --set replicaCount=3 \
              --atomic --timeout 10m --wait
          '''
        }
      }
      post {
        success {
          jiraSendDeploymentInfo(
            site: 'mycompany.atlassian.net',
            environmentId: 'staging-1',
            environmentName: 'staging',
            environmentType: 'staging'
          )
        }
      }
    }
  }

  post {
    always {
      // Send build result (pass/fail) to any Jira issue keyed in the branch or commit
      jiraSendBuildInfo site: 'mycompany.atlassian.net'
    }
    failure {
      echo "Build failed: ${env.BUILD_URL}"
      // slackSend / emailext here
    }
    cleanup {
      cleanWs()
    }
  }
}
```

### The shared Maven cache PVC

The `maven-cache-pvc` referenced above saves several minutes per build by not re-downloading dependencies:

```bash
cat > maven-cache-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: maven-cache-pvc
  namespace: jenkins
spec:
  accessModes:
    - ReadWriteMany        # many agents share it, so it must be RWX
  storageClassName: azurefile-csi
  resources:
    requests:
      storage: 20Gi
EOF
kubectl apply -f maven-cache-pvc.yaml
```

> **Why `azurefile-csi`?** Azure **Disks** are `ReadWriteOnce` — one Pod at a time. Azure **Files** supports `ReadWriteMany`, which is what parallel build agents need. It's slower per-operation than a disk, so if concurrency is low, an alternative is to skip the shared PVC and lean on Artifactory's remote repository cache instead.

### Key pipeline ideas worth internalizing

- **Immutable tags.** `IMAGE_TAG` is build number + git SHA. Never `:latest`. With `:latest`, you cannot answer "what code is running in production right now?", and rollbacks become guesswork.
- **Fail fast, cheap first.** Compile → unit tests → Sonar → *then* the slow, expensive Coverity scan, and only on important branches. Don't spend eight minutes of analysis on code that doesn't compile.
- **`--atomic` on helm upgrade.** If the deployment doesn't become healthy, Helm automatically rolls back. Without it, a bad deploy leaves you in a half-broken state.
- **`disableConcurrentBuilds(abortPrevious: true)`.** If someone pushes three commits in a minute, only the newest matters. This cancels the stale runs and saves a lot of compute.
- **Manual `input` gate before staging.** Continuous *delivery* means always ready to ship; a human still decides *when*.

---

## 10. Wiring up Bitbucket

### 10.1 Bitbucket Cloud vs Data Center

- **Bitbucket Cloud** (`bitbucket.org`) — Atlassian-hosted SaaS. Uses **app passwords** or API tokens, not your account password.
- **Bitbucket Data Center** — self-hosted behind your firewall. Uses HTTP access tokens or SSH keys.

The Jenkins plugin (`cloudbees-bitbucket-branch-source`) handles both.

### 10.2 Create an app password (Cloud)

Bitbucket → your avatar → **Personal settings → App passwords → Create app password**. Grant `Repositories: Read`, `Pull requests: Read`, and `Webhooks: Read and write`. Copy it immediately — you can't see it again. Store it in Jenkins as `bitbucket-creds`.

### 10.3 Create a Multibranch Pipeline

**New Item → Multibranch Pipeline.**

- **Branch Sources → Add source → Bitbucket**
- Credentials: `bitbucket-creds`
- Owner: your workspace ID; Repository: your repo
- **Behaviors:** Discover branches, Discover pull requests from origin, Discover pull requests from forks (choose "Merging the pull request with the current target branch revision" so you test the *merged* result, not the stale branch)
- **Build Configuration:** by Jenkinsfile, script path `Jenkinsfile`
- **Scan Multibranch Pipeline Triggers:** every 1 day as a safety net (webhooks are primary)

Jenkins now scans the repo, finds every branch with a `Jenkinsfile`, and creates a job for each one automatically. New branch → new job. Deleted branch → job disappears.

### 10.4 Webhooks — push instead of poll

Without a webhook, Jenkins polls: "any changes? any changes?" every few minutes. Wasteful and slow. A **webhook** flips it around — Bitbucket calls Jenkins the instant something happens.

If Jenkins is reachable from Bitbucket Cloud, the plugin can auto-register the webhook. Otherwise, in Bitbucket: **Repository settings → Webhooks → Add webhook**:

- URL: `https://jenkins.mycompany.com/bitbucket-scmsource-hook/notify`
- Triggers: Repository push, Pull request created/updated/merged

> **The classic failure:** Jenkins is on a private LoadBalancer or `ClusterIP`, so Bitbucket Cloud literally cannot reach it, and nothing ever triggers. Fixes: expose Jenkins through an Ingress with a public hostname and TLS, put it behind Azure Front Door, or use Bitbucket Data Center inside the same network. This is the single most common "why isn't my pipeline running" cause.

### 10.5 Branch strategy

Two mainstream choices:

| | **Trunk-based** | **Git Flow** |
|---|---|---|
| Branches | `main` + very short-lived feature branches | `main`, `develop`, `feature/*`, `release/*`, `hotfix/*` |
| Merge frequency | Many times a day | Weekly or per release |
| Pros | Fewer merge conflicts, faster feedback, simpler CI | Clear release staging, good for versioned/on-prem products |
| Cons | Requires strong tests and feature flags | Complex, long-lived branches drift and conflict |

For a service deployed continuously to AKS, **trunk-based** is the better fit and is what most high-performing teams use.

Also configure **branch permissions** on `main`: require a pull request, require the Jenkins build to pass, require at least one approval. A pipeline that reports failures nobody is required to act on is just expensive decoration.

---

## 11. Wiring up Jira

The goal: a developer opens ticket **PROJ-42** and sees, right there in the ticket, which commits, which builds, and which deployments relate to it — with no one typing status updates by hand.

### 11.1 How the link works

There are two halves:

1. **On the Jira side:** install the **Jenkins for Jira** app from the Atlassian Marketplace. It creates a secure connection and generates OAuth credentials.
2. **On the Jenkins side:** install the **Atlassian Jira Software Cloud** plugin (already in the Helm values above). Configure your Jira site and paste in those credentials under **Manage Jenkins → Atlassian Jira Cloud**.

### 11.2 The magic ingredient: issue keys

The integration works by **finding Jira issue keys in branch names and commit messages.** No key, no data — the plugin simply won't send anything.

So the team convention must be:

```bash
git checkout -b feature/PROJ-42-add-login-endpoint
git commit -m "PROJ-42 add /login endpoint with validation"
```

### 11.3 The pipeline steps

Two steps do the work:

```groovy
// Send build results (which stage, pass/fail, link back to Jenkins)
post { always { jiraSendBuildInfo site: 'mycompany.atlassian.net' } }

// Send deployment events (which environment, when, what version)
jiraSendDeploymentInfo(
  site: 'mycompany.atlassian.net',
  environmentId: 'prod-1',
  environmentName: 'production',
  environmentType: 'production'   // development | testing | staging | production
)
```

By default the plugin reads the branch name to find issue keys. You can override it:

```groovy
jiraSendBuildInfo site: 'mycompany.atlassian.net', branch: 'PROJ-42-awesome-feature'
```

Or target specific issues explicitly on a deployment:

```groovy
jiraSendDeploymentInfo site: 'mycompany.atlassian.net',
  environmentId: 'us-prod-1', environmentName: 'us-prod-1',
  environmentType: 'production', issueKeys: ['PROJ-42', 'PROJ-43']
```

There's also an **advanced setting to send builds automatically** — enable "Sends builds automatically" under Manage Jenkins → Atlassian Jira Cloud, and you don't need the explicit step in every Jenkinsfile. Handy when you have fifty pipelines and don't want to edit them all.

### 11.4 Smart commits

With Bitbucket connected to Jira, commit messages can *drive* Jira:

```bash
git commit -m "PROJ-42 #time 3h #comment fixed the null check #resolve"
```

That one commit logs 3 hours of work, adds a comment, and transitions the ticket to Resolved. Powerful — and worth agreeing on as a team before someone accidentally closes fifteen tickets.

### 11.5 What you actually get

Open PROJ-42 in Jira and the right-hand development panel shows the branch, the commits, the pull request, the Jenkins build (green or red), and which environments the code has reached. Nobody writes a status update. Release notes generate themselves.

---

## 12. The Bitbucket Pipelines alternative (no Jenkins)

If you're already all-in on Atlassian, you might not need Jenkins at all. **Bitbucket Pipelines** is CI built into Bitbucket Cloud — you add one YAML file and it runs.

`bitbucket-pipelines.yml`:

```yaml
image: maven:3.9-eclipse-temurin-21

definitions:
  caches:
    maven: ~/.m2/repository
  steps:
    - step: &build-test
        name: Build and test
        caches: [maven]
        script:
          - mvn -B clean verify
        artifacts:
          - target/*.jar
          - target/site/jacoco/**
        after-script:
          - pipe: atlassian/checkstyle-report:0.3.0

pipelines:
  pull-requests:
    '**':
      - step: *build-test
      - step:
          name: SonarCloud scan
          script:
            - pipe: sonarsource/sonarcloud-scan:2.0.0

  branches:
    main:
      - step: *build-test
      - step:
          name: Build and push image to ACR
          services: [docker]           # Bitbucket gives you a Docker service
          script:
            - export IMAGE=$ACR_NAME.azurecr.io/my-spring-app:$BITBUCKET_BUILD_NUMBER
            - echo $ACR_PASSWORD | docker login $ACR_NAME.azurecr.io -u $ACR_USER --password-stdin
            - docker build -t $IMAGE .
            - docker push $IMAGE
      - step:
          name: Deploy to AKS
          deployment: staging          # gives you Bitbucket's deployment tracking + Jira link
          script:
            - pipe: microsoft/azure-aks-deploy:1.0.2
              variables:
                AZURE_APP_ID: $AZURE_APP_ID
                AZURE_PASSWORD: $AZURE_PASSWORD
                AZURE_TENANT_ID: $AZURE_TENANT_ID
                AKS_CLUSTER_NAME: $AKS_CLUSTER_NAME
                AKS_RESOURCE_GROUP: $AKS_RESOURCE_GROUP
                KUBECTL_COMMAND: 'apply'
                KUBECTL_ARGUMENTS: '-f k8s/ -n staging'
```

### Jenkins vs Bitbucket Pipelines

| | **Jenkins on AKS** | **Bitbucket Pipelines** |
|---|---|---|
| Setup effort | High — you run and patch it | Almost none |
| Cost model | Your cluster's compute | Per build-minute |
| Flexibility | Unlimited (1,800+ plugins) | Limited to what pipes and images allow |
| Air-gapped / private network builds | ✅ Native | ❌ Awkward (needs self-hosted runners) |
| Enterprise tools (Coverity, license servers) | ✅ Easy — full control of the agent image | Harder |
| Maintenance burden | You own upgrades, plugin CVEs, backups | Atlassian owns it |
| Jira integration | Good (via plugin) | Excellent (native) |

**Rule of thumb:** small-to-mid teams on Bitbucket Cloud with standard needs → **Pipelines**. Teams with enterprise scanning tools, private networks, complex multi-repo builds, or existing Jenkins investment → **Jenkins**.

---

## 13. Deploying the app to AKS from the pipeline

The Helm chart your pipeline installs. `helm/my-spring-app/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0        # never drop below full capacity during a deploy
      maxSurge: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
        version: {{ .Values.image.tag | quote }}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: app
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          # Spring Boot Actuator gives you these endpoints for free
          startupProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            failureThreshold: 30
            periodSeconds: 5           # allows up to 150s for a slow JVM start
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            periodSeconds: 10
          volumeMounts:
            - name: tmp
              mountPath: /tmp          # needed because the root FS is read-only
      volumes:
        - name: tmp
          emptyDir: {}
      {{- if .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml .Values.imagePullSecrets | nindent 8 }}
      {{- end }}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Release.Name }}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: {{ .Release.Name }}
```

**Why a `startupProbe` separate from `livenessProbe`:** the JVM can take 30+ seconds to boot. Without a startup probe, the liveness probe fires during startup, decides the app is dead, and kills it — forever, in a loop. The startup probe gives generous time to boot, and only after it passes do the fast liveness checks begin. This bites nearly every team deploying Java to Kubernetes for the first time.

### Letting AKS pull from Artifactory

Your cluster needs credentials for a private registry:

```bash
kubectl -n dev create secret docker-registry artifactory-pull \
  --docker-server=artifactory.mycompany.com \
  --docker-username=ci-user \
  --docker-password='<token>'
```

Then in `values.yaml`:

```yaml
imagePullSecrets:
  - name: artifactory-pull
```

**Or skip all of that** by pushing to ACR instead, since `--attach-acr` (Section 3.4) made pulls automatic with no secret at all.

### A better deployment model: GitOps

The pipeline above **pushes** to the cluster: Jenkins holds credentials and runs `helm upgrade`. That works, but it means CI has write access to production.

**GitOps** inverts it. Jenkins' last step just commits the new image tag to a Git repo. An agent inside the cluster (**Argo CD** or **Flux**) watches that repo and pulls changes in.

| | Push (Jenkins deploys) | GitOps (cluster pulls) |
|---|---|---|
| Cluster credentials in CI | ✅ Required | ❌ Not needed |
| Drift detection | ❌ None | ✅ Continuous — manual changes get reverted |
| Audit trail | Jenkins logs | Git history — every change is a commit |
| Rollback | Re-run an old job | `git revert` |
| Setup complexity | Lower | Higher |

For production on AKS, GitOps is where most teams end up. AKS even offers Flux as a managed extension (`az k8s-configuration flux create`).

---

## 14. Options and trade-offs

### 14.1 Artifact repository

| | **Artifactory** | **Azure Container Registry** | **Nexus Repository** | **GitHub/Bitbucket packages** |
|---|---|---|---|---|
| Package types | Everything (Docker, Maven, npm, PyPI, Helm, Go, NuGet…) | Docker/OCI + Helm only | Most major types | Limited |
| Remote caching/proxy | ✅ Excellent | ⚠️ Cache rules only | ✅ Good | ❌ |
| Cost | Free OSS/JCR; Pro is expensive | Cheap, pay per GB | Free OSS; Pro paid | Included |
| Ops burden | High if self-hosted | ❌ None (managed) | Medium | None |
| Security scanning | Xray (extra license) | Defender for Containers | IQ Server (extra) | Basic |
| AKS integration | Needs pull secrets | ✅ `--attach-acr`, zero secrets | Needs pull secrets | Needs secrets |

**Honest recommendation for an Azure shop:** use **ACR for container images** (cheap, managed, zero-friction auth with AKS) and **Artifactory or Nexus for everything else** (Maven caching is where they truly shine). Running Artifactory Pro purely as a Docker registry on Azure is usually paying twice for something ACR does better.

### 14.2 CI/CD orchestrator

| | Jenkins | GitHub Actions | Azure Pipelines | GitLab CI | Argo Workflows / Tekton |
|---|---|---|---|---|---|
| Kubernetes-native | Via plugin | Via self-hosted runners | Via agents | Via runners | ✅ Born there |
| Plugin ecosystem | Enormous (1,800+) | Large and growing | Good | Good | Small |
| Hosted option | ❌ Self-host (or CloudBees) | ✅ | ✅ | ✅ | ❌ |
| Learning curve | Medium (Groovy) | Low (YAML) | Low (YAML) | Low (YAML) | High |
| Maintenance | High — you own plugin CVEs | None | None | Low-to-none | Medium |
| Enterprise tool support | Best in class | Good | Good | Good | DIY |

**Jenkins' honest weakness in 2026:** the plugin ecosystem is its superpower and its liability. Plugins are its most common source of security advisories, and upgrades occasionally break jobs. If your needs are ordinary and your code is on GitHub or Azure DevOps, a hosted YAML system is less work. Choose Jenkins when you need enterprise tool integrations (Coverity, license servers), private-network builds, or you already have hundreds of jobs in it.

---

## 15. Production best practices

### Security

- **No `docker.sock` mounts. No privileged build Pods.** This is the single highest-value rule here. Use ACR Tasks, Jib, or rootless BuildKit/Buildah.
- **Never run Jenkins on a public LoadBalancer.** Ingress + TLS + SSO (Entra ID via the OIDC plugin), or private access only.
- **Secrets from Azure Key Vault**, injected with the Secrets Store CSI driver and workload identity — not typed into the Jenkins credential store, and never in a `Jenkinsfile`.
- **Dedicated, least-privilege service accounts.** Jenkins gets `Role` bindings in `dev`/`staging`, not `cluster-admin`. The Artifactory CI user can deploy to two repos, not administer the platform.
- **Sign your images** with **cosign** and enforce the signatures at admission time (Ratify + Azure Policy). Then "only images our pipeline built can run here" becomes a rule, not a hope.
- **Generate an SBOM** (`syft`, or `trivy sbom`) per build and store it in Artifactory next to the image. When the next Log4Shell lands, you answer "are we affected?" in minutes.
- **Separate registries or repos per environment**, and **promote** artifacts between them rather than rebuilding. The bytes you tested must be the exact bytes you ship.

### Reliability

- **Back up Jenkins' home volume** — it holds all job config, credentials, and history. Better: keep everything in JCasC + Jenkinsfiles in Git so the controller is disposable.
- **Use an external PostgreSQL** for Artifactory in production (Azure Database for PostgreSQL Flexible Server). The bundled chart database is for demos.
- **Set resource requests and limits on every build container.** An unbounded Maven build will happily eat a whole node.
- **Pin plugin and image versions.** `:latest` in `installPlugins` is convenient for a tutorial and a liability in production — a surprise plugin update can break every job at once.
- **PodDisruptionBudgets** on the app, so cluster upgrades don't take your last replica.

### Pipeline design

- **Keep the whole pipeline in the repo** (`Jenkinsfile`), not in the Jenkins UI. Pipeline changes then get reviewed like code.
- **Build once, deploy many.** The same image artifact flows dev → staging → prod. Rebuilding per environment means you're testing something you never shipped.
- **Fail fast.** Cheapest checks first.
- **Target 10 minutes** for the commit-to-feedback loop. Past ~15 minutes, developers context-switch and stop paying attention to results. Move slow scans to nightly or PR-only.
- **Extract shared logic into a Jenkins Shared Library** once you have more than a few similar services, so twelve teams aren't maintaining twelve copies of the same 200-line Jenkinsfile.

---

## 16. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent Pod stuck `Pending` | No node tolerates the build taint, or requests exceed node capacity | `kubectl -n jenkins describe pod <name>` and read Events; check the buildpool autoscaler `max-count` |
| Jenkins agent never connects | `jenkinsUrl` / `jenkinsTunnel` wrong in the cloud config | They must be the in-cluster service DNS names, e.g. `jenkins-agent.jenkins.svc.cluster.local:50000` |
| Artifactory Pod `CrashLoopBackOff` on install | Master/join key mismatch, or PVC won't bind | `kubectl -n artifactory logs artifactory-0 -c artifactory`; verify a valid `storageClassName` |
| Artifactory install fails immediately on a fresh install | Chart 107.161.x+ no longer auto-generates the nginx TLS cert | Set `nginx.tlsSecretName`, or `nginx.generateSelfSignedCert=true` (dev), or `nginx.https.enabled=false` |
| `ImagePullBackOff` in `dev` | No pull secret for Artifactory | Create the `docker-registry` secret and reference it in `imagePullSecrets`; or push to ACR with `--attach-acr` |
| BuildKit fails with a permission/seccomp error | Cluster security policy blocks rootless mode | Add `seccompProfile: Unconfined` + `appArmorProfile: Unconfined`, or switch to Buildah or `az acr build` |
| Maven downloads everything, every build | Cache PVC not mounted, or `settings.xml` not applied | Confirm both volume mounts exist and `-s /root/.m2/settings.xml` is on every `mvn` call |
| Bitbucket push doesn't trigger a build | Bitbucket Cloud can't reach a private Jenkins | Expose Jenkins via public Ingress + TLS, or use a self-hosted Bitbucket, or fall back to SCM polling |
| Nothing appears in Jira | No issue key in the branch name or commit message | Rename the branch to include `PROJ-42`, or pass `branch:`/`issueKeys:` explicitly to the step |
| Coverity stage fails with exit status 1 | Wrong `COVERITY_URL` (404 from the Connect API), network block, or the Connect server is down | Verify the URL from inside a build Pod with `curl`; confirm the Coverity install directory is set under Manage Jenkins → System |
| Spring Boot pod restarts forever | Liveness probe firing during a slow JVM startup | Add a `startupProbe` with a generous `failureThreshold` |
| Java pod OOMKilled at odd times | JVM sized against the host, not the container limit | Set `-XX:MaxRAMPercentage=75.0` |
| `helm upgrade` hangs then fails | New pods never become Ready | You used `--atomic --wait`, so it correctly rolled back; check the app's own logs and probes |

Universal first moves:

```bash
kubectl -n <ns> get pods
kubectl -n <ns> describe pod <pod>          # read the Events section
kubectl -n <ns> logs <pod> -c <container> --previous
kubectl -n <ns> get events --sort-by=.metadata.creationTimestamp
```

---

## 17. Cost and sizing

Rough monthly estimate for a demo-sized setup in East US (verify against the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) — prices change):

| Item | Sizing | Rough cost/month |
|---|---|---|
| AKS control plane | Free tier | $0 |
| 2 × `Standard_D4s_v5` (tools) | Always on | ~$280 |
| Build pool, autoscaled 0→4 | ~2 hours/day, Spot | ~$10–20 |
| Premium SSD (Artifactory 50 GB + PG 20 GB + Jenkins 20 GB) | | ~$25 |
| Azure Files (Maven cache 20 GB) | | ~$3 |
| Load balancers + public IPs | 2 services | ~$10 |
| ACR Basic | | ~$5 |
| **Total** | | **~$330/month** |

Ways to cut it substantially:

1. **Build agents on Spot with `min-count 0`.** Idle build capacity should cost nothing.
2. **Use ACR + ACR Tasks instead of self-hosted Artifactory** — removes ~$100/month of always-on compute plus the Pro license and the operational burden.
3. **Use SaaS** (JFrog Cloud, or Bitbucket Pipelines instead of Jenkins) if your team is small. Self-hosting is cheap in license terms and expensive in engineer-hours.
4. **`az aks stop` non-production clusters overnight and on weekends** — roughly a 60% reduction on dev compute.
5. **One shared tooling cluster** for Jenkins/Artifactory across all teams, with per-team namespaces, instead of a copy per project.

---

## 18. Cheat sheet

```bash
# --- Helm basics ---
helm repo add <name> <url> && helm repo update
helm search repo <name> --versions
helm upgrade --install <release> <chart> -n <ns> --create-namespace -f values.yaml
helm list -A
helm history <release> -n <ns>
helm rollback <release> <revision> -n <ns>
helm uninstall <release> -n <ns>

# --- Artifactory ---
kubectl -n artifactory get pods
kubectl -n artifactory logs -f artifactory-0 -c artifactory
kubectl -n artifactory rollout status statefulset/artifactory
docker login artifactory.mycompany.com -u ci-user
docker push artifactory.mycompany.com/docker-local/my-spring-app:1.0.0

# --- Jenkins ---
kubectl -n jenkins get secret jenkins -o jsonpath="{.data.jenkins-admin-password}" | base64 -d
kubectl -n jenkins port-forward svc/jenkins 8080:8080     # private access
kubectl -n jenkins get pods                               # watch agents appear/vanish
kubectl -n jenkins logs -f <agent-pod> -c maven

# --- Maven / Java ---
mvn -B clean verify                       # compile + test + coverage gate
mvn -B package -DskipTests                # build the jar only
mvn -B deploy                             # publish to Artifactory
mvn -B jib:build -Djib.to.image=<image>   # build+push an image, no Docker
mvn dependency:tree                       # why is that library here?

# --- Image build alternatives ---
az acr build -r <acr> -t <app>:<tag> .                    # Azure builds it
buildctl-daemonless.sh build --frontend dockerfile.v0 \
  --local context=. --local dockerfile=. \
  --output type=image,name=<image>,push=true              # BuildKit
buildah bud -t <image> . && buildah push <image>          # Buildah

# --- Deploy / verify ---
helm upgrade --install my-spring-app ./helm/my-spring-app -n dev \
  --set image.tag=$TAG --atomic --wait
kubectl -n dev rollout status deployment/my-spring-app
kubectl -n dev rollout undo deployment/my-spring-app
kubectl -n dev get pods -o wide
```

---

## 19. Clean up

Everything in this tutorial lives in one resource group.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
az group exists --name $RESOURCE_GROUP     # should become: false
```

If you only want to remove the tools but keep the cluster:

```bash
helm uninstall jenkins -n jenkins
helm uninstall artifactory -n artifactory
kubectl delete namespace jenkins artifactory dev staging
# PVCs sometimes survive namespace deletion - check for orphaned disks:
kubectl get pvc -A
```

> 💸 Orphaned **PersistentVolumeClaims** keep billing for their Azure managed disks long after the Pods are gone. Always check `kubectl get pvc -A` after tearing down a stateful app.

---

## Where to go next

**Official docs:**

- JFrog Artifactory Helm installation: <https://jfrog.com/help/r/jfrog-installation-setup-documentation/install-artifactory-with-helm-charts>
- JFrog Helm charts repo: <https://github.com/jfrog/charts>
- Jenkins Helm chart: <https://github.com/jenkinsci/helm-charts>
- Jenkins Kubernetes plugin: <https://plugins.jenkins.io/kubernetes/>
- Atlassian Jira Software Cloud plugin: <https://plugins.jenkins.io/atlassian-jira-software-cloud/>
- Bitbucket Branch Source plugin: <https://plugins.jenkins.io/cloudbees-bitbucket-branch-source/>
- Black Duck Security Scan (Coverity) pipeline steps: <https://www.jenkins.io/doc/pipeline/steps/blackduck-security-scan/>
- Coverity SAST product docs: <https://www.blackduck.com/static-analysis-tools-sast/coverity.html>
- BuildKit: <https://github.com/moby/buildkit>
- Jib: <https://github.com/GoogleContainerTools/jib>
- ACR Tasks: <https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview>
- Spring Boot container best practices: <https://docs.spring.io/spring-boot/reference/packaging/container-images/index.html>

**Suggested progression:**

1. Get the pipeline green end-to-end with the simplest possible app.
2. Replace the Dockerfile stage with **Jib** and compare build times — you'll probably keep Jib.
3. Add **Argo CD** and convert the deploy stage to GitOps.
4. Add **cosign** signing plus admission enforcement.
5. Add a **Jenkins Shared Library** so a new service needs a 15-line Jenkinsfile, not 250.
6. Add **progressive delivery** (Argo Rollouts or Flagger) for canary releases with automatic rollback on bad metrics.

**And once more:** delete the resource group when you're done.
