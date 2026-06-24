# Kubernetes Enterprise Training: Stateful Workloads (Kafka, Keycloak, OpenSearch, NiFi)

## Module 1: Kubernetes Foundations for Enterprise Clusters
- Cluster architecture: control plane HA, etcd sizing, multi-master topology
- Node pools and workload isolation (system, stateful, compute pools)
- Namespaces, resource quotas, and limit ranges per tenant/app
- RBAC design and service account strategy
- Cluster sizing and capacity planning for stateful workloads

# Lesson 1: Introduction & Standing Up a Working Cluster

**Kubernetes Enterprise Training — Stateful Workloads (Kafka, Keycloak, OpenSearch, NiFi)**

---

## About This Lesson

| | |
|---|---|
| **Duration** | 3–4 hours (1 hr concepts, 2–3 hrs hands-on) |
| **Format** | Lecture + guided lab |
| **Audience** | Cloud platform engineers, SREs, DevOps engineers |
| **Outcome** | Each participant has a running, multi-node cluster they can `kubectl` into, with the foundations the later workload lessons depend on |

### Prerequisites

- Comfortable on a Linux command line (ssh, editing files, environment variables)
- Basic containers/Docker familiarity (images, registries, `docker run`)
- A workstation running macOS, Linux, or Windows with WSL2
- For the cloud track: an account on your org's chosen provider (AWS/GCP/Azure) with permission to create clusters, or sandbox credentials supplied by the instructor

### What You'll Be Able to Do Afterward

By the end of this lesson you will:

1. Explain what a Kubernetes cluster is made of and why each piece matters for stateful enterprise workloads.
2. Stand up a working multi-node cluster (local for learning, managed for the real environment).
3. Configure `kubectl` and verify cluster health.
4. Deploy and expose a trivial test workload to confirm the cluster is functional end to end.
5. Understand the design decisions that the Kafka, Keycloak, OpenSearch, and NiFi lessons will build on.

---

## Part 1 — Concepts (≈ 1 hour)

### 1.1 Why Kubernetes for These Workloads

Kafka, Keycloak, OpenSearch, and NiFi are all **stateful, clustered, long-running** services. They have things in common that shape every decision in this course:

- They keep data on disk and care deeply about **storage** (durability, IOPS, not losing a volume when a pod moves).
- They run as a **set of cooperating members** that need stable network identities (broker-0, broker-1…).
- They need **controlled, ordered** startup, scaling, and upgrades — you can't just kill them all and restart.
- They are **security-sensitive**: Keycloak *is* your identity provider; the others must integrate with it.

Kubernetes gives us a consistent control plane to run all four with the same operational model: declarative config, self-healing, rolling updates, and a rich operator ecosystem. The trade-off is that running *stateful* software on Kubernetes is meaningfully harder than running stateless web apps, which is exactly why this course exists.

> **Key framing for the whole course:** we are not just "deploying apps." We are building a *platform* that a cloud team can operate, support, and maintain over years.

### 1.2 Cluster Anatomy

A Kubernetes cluster has two planes.

**Control plane** — the brain. Manages cluster state and makes scheduling decisions:

- **kube-apiserver** — the front door. Everything (`kubectl`, controllers, nodes) talks to the API server.
- **etcd** — the database. Stores all cluster state as key-value data. Losing etcd means losing the cluster, so it gets special backup/HA treatment (covered in the reliability lesson).
- **kube-scheduler** — decides which node a new pod runs on.
- **kube-controller-manager** — runs the control loops that drive actual state toward desired state.

**Worker nodes** — where your workloads actually run:

- **kubelet** — the agent on each node that starts/stops containers and reports health.
- **container runtime** — typically containerd; actually runs the containers.
- **kube-proxy** — handles in-cluster networking/service routing.

**Add-ons that make a cluster usable** (not in the core but effectively required):

- **CNI plugin** (e.g., Calico, Cilium) — pod-to-pod networking and network policy.
- **CoreDNS** — in-cluster DNS; how pods find services by name.
- **CSI driver** — connects Kubernetes to your storage backend (critical for our stateful workloads).

### 1.3 Core Objects You'll Use Constantly

| Object | What it is | Why it matters here |
|--------|-----------|---------------------|
| **Pod** | Smallest deployable unit; one or more containers | The thing that actually runs Kafka/etc. |
| **Deployment** | Manages stateless replica sets | Good for stateless front-ends, *not* for brokers |
| **StatefulSet** | Manages pods with stable identity + storage | The backbone of Kafka, OpenSearch, NiFi |
| **Service** | Stable network endpoint for a set of pods | How clients reach the workload |
| **Namespace** | Logical partition of the cluster | We isolate each workload/tenant |
| **ConfigMap / Secret** | Non-secret / secret configuration | App config and credentials |
| **PersistentVolumeClaim** | A request for storage | How a pod gets durable disk |

We will go deep on StatefulSets and storage in Lessons 2–3; for now just know that **StatefulSets + PersistentVolumeClaims** are the reason these workloads survive a pod restart with their data intact.

### 1.4 Cluster Topology Choices for Enterprise

A few decisions we are making up front, and the reasoning (each is expanded in later lessons):

- **At least 3 control-plane nodes** in production for HA and etcd quorum. (Local learning clusters use 1 — that's fine for now.)
- **Separate node pools** for system components vs. stateful data workloads, so a noisy app can't starve the control plane and so we can put storage-optimized hardware where it's needed.
- **Spread across availability zones** so the loss of one zone doesn't take down a Kafka cluster or an OpenSearch index.
- **Managed Kubernetes** (EKS/GKE/AKS) for the real environment — let the cloud provider run the control plane and etcd backups, while your team focuses on the workloads.

---

## Part 2 — Lab (≈ 2–3 hours)

We provide **two tracks**. Do **Track A** during class to learn quickly on your laptop. Use **Track B** when you're ready to build the cluster your team will actually operate.

> **Instructor note:** everyone should complete Track A. Track B is done either as a follow-along on shared sandbox credentials or as homework, depending on your org's setup.

---

### Track A — Local Multi-Node Cluster with kind

`kind` (Kubernetes IN Docker) runs a real multi-node cluster as Docker containers. It's the fastest way to get a *genuine* multi-node cluster for learning. (`minikube` is an equally valid alternative; instructions for it are in the Appendix.)

#### A.1 Install the tools

Install **Docker**, **kubectl**, and **kind**. Pick the block for your OS.

**macOS (Homebrew):**
```bash
brew install kubectl kind
# Docker Desktop must be installed and running:
# https://www.docker.com/products/docker-desktop/
```

**Linux (x86_64):**
```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Docker (if not present): follow https://docs.docker.com/engine/install/
```

**Windows:** install Docker Desktop with the WSL2 backend, then run the Linux commands above inside your WSL2 distro.

Verify:
```bash
docker --version
kubectl version --client
kind version
```

#### A.2 Define a multi-node cluster

Create a file named `kind-cluster.yaml`. This defines one control-plane node and three workers — deliberately mirroring the "separate the workers" idea from Part 1, and giving us enough nodes to later demonstrate spreading workloads.

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: enterprise-training
nodes:
  - role: control-plane
    # Expose an ingress-friendly port mapping for later lessons
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
```

#### A.3 Create the cluster

```bash
kind create cluster --config kind-cluster.yaml
```

This pulls the node image and boots the cluster (a few minutes the first time). `kind` automatically points your `kubectl` at the new cluster.

#### A.4 Verify it works

```bash
# Are all nodes Ready?
kubectl get nodes -o wide

# Are the control-plane components healthy?
kubectl get pods -n kube-system

# What's the cluster-wide picture?
kubectl cluster-info
```

You should see one `control-plane` node and three `worker` nodes, all in `Ready` state. If any node is `NotReady`, give it 30–60 seconds and re-run; the CNI may still be initializing.

Skip ahead to **Part 3 — Smoke Test**, which is the same for both tracks.

---

### Track B — Managed Cluster (the real environment)

This is what your team will actually run. We show **AWS EKS** in full; **GKE** and **AKS** quick-starts are in the Appendix. The same Kubernetes concepts apply across all three — only the provisioning commands differ.

> **Cost & cleanup warning:** a managed cluster with real worker nodes costs money per hour. Note the teardown step (B.6) and run it when you're done unless this is your permanent training environment.

#### B.1 Install the tooling

```bash
# kubectl (see Track A.1 for your OS)

# AWS CLI v2 — https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
aws --version

# eksctl — the official EKS provisioning tool
# macOS:
brew install eksctl
# Linux:
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

eksctl version
```

Authenticate the AWS CLI with your sandbox or org credentials:
```bash
aws configure        # enter access key, secret, region (e.g. us-east-1)
aws sts get-caller-identity   # confirm you're authenticated
```

#### B.2 Define the cluster as code

Create `eks-cluster.yaml`. Note how this encodes the **enterprise topology decisions** from Part 1: multiple AZs, a dedicated system node group, and a separate node group for stateful workloads.

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: enterprise-training
  region: us-east-1
  version: "1.30"

# Spread across 3 AZs for high availability
availabilityZones:
  - us-east-1a
  - us-east-1b
  - us-east-1c

# IAM roles for service accounts — needed later for storage/secrets integration
iam:
  withOIDC: true

managedNodeGroups:
  # System / platform components
  - name: system
    instanceType: t3.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 3
    volumeSize: 50
    labels:
      workload-type: system
    tags:
      Environment: training

  # Stateful workloads (Kafka, OpenSearch, etc.) — bigger, with a taint so only
  # explicitly-tolerating pods land here. We'll use this in later lessons.
  - name: stateful
    instanceType: m5.xlarge
    desiredCapacity: 3
    minSize: 3
    maxSize: 6
    volumeSize: 200
    labels:
      workload-type: stateful
    taints:
      - key: workload-type
        value: stateful
        effect: NoSchedule
    tags:
      Environment: training

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver   # the CSI driver our PVCs will use
```

#### B.3 Create the cluster

```bash
eksctl create cluster -f eks-cluster.yaml
```

This provisions the VPC, control plane, node groups, and add-ons. **It typically takes 15–20 minutes** — a good moment for a break or for the Part 1 Q&A. `eksctl` writes the cluster credentials into your kubeconfig automatically when it finishes.

#### B.4 Point kubectl at the cluster (if needed)

If you're on a fresh machine or `eksctl` didn't update your config:
```bash
aws eks update-kubeconfig --name enterprise-training --region us-east-1
```

#### B.5 Verify

```bash
kubectl get nodes -o wide --show-labels
kubectl get pods -n kube-system
kubectl cluster-info
```

You should see ~5 nodes across three AZs, labeled `workload-type=system` and `workload-type=stateful`. Confirm the EBS CSI driver pods are running:
```bash
kubectl get pods -n kube-system | grep ebs-csi
```

#### B.6 Teardown (when finished)

```bash
eksctl delete cluster -f eks-cluster.yaml
```
Verify in the AWS console that the CloudFormation stacks, node groups, and load balancers are gone so you're not billed for stragglers.

---

## Part 3 — Smoke Test (both tracks)

A cluster isn't "working" until you've run something on it and reached it. We'll deploy a tiny web server, expose it, and confirm traffic flows.

> **Note for Track B users:** because we tainted the `stateful` node group, this test pod will land on the `system` nodes automatically — exactly the behavior we want. No changes needed.

#### 3.1 Create a namespace

We never dump workloads into `default`. Namespacing is the first habit of an enterprise cluster.

```bash
kubectl create namespace smoke-test
```

#### 3.2 Deploy a test workload

```bash
kubectl create deployment hello \
  --image=nginxinc/nginx-unprivileged:stable \
  --replicas=2 \
  -n smoke-test
```

Watch the pods come up:
```bash
kubectl get pods -n smoke-test -w
# Ctrl-C once both show Running
```

#### 3.3 Expose it as a Service

```bash
kubectl expose deployment hello \
  --port=80 --target-port=8080 \
  --type=ClusterIP \
  -n smoke-test
```

#### 3.4 Reach the workload

The portable way to test, regardless of track or cloud, is port-forwarding:

```bash
kubectl port-forward -n smoke-test service/hello 8080:80
```

Then in another terminal (or your browser at `http://localhost:8080`):
```bash
curl -s http://localhost:8080 | head -n 5
```

You should get the nginx welcome HTML. **That round trip — pod scheduled, service routing, traffic served — confirms your cluster is genuinely functional.**

#### 3.5 Inspect what you built

A few commands worth internalizing now, because you'll use them constantly when debugging Kafka/OpenSearch later:

```bash
# Describe a pod (events at the bottom are gold for troubleshooting)
kubectl describe pod -n smoke-test -l app=hello

# View logs
kubectl logs -n smoke-test -l app=hello --tail=20

# See where pods landed (which node)
kubectl get pods -n smoke-test -o wide

# Everything in the namespace at a glance
kubectl get all -n smoke-test
```

#### 3.6 Clean up the smoke test

```bash
kubectl delete namespace smoke-test
```
(This removes the deployment, service, and pods in one shot — another reason we namespaced it.)

---

## Wrap-Up

### What you accomplished

- Built a real multi-node Kubernetes cluster — locally with `kind` and/or as a managed EKS cluster encoding enterprise topology (multi-AZ, separated node groups, CSI driver).
- Configured and verified `kubectl` access.
- Deployed, exposed, reached, and inspected a workload end to end.
- Established two habits we'll keep all course: **namespacing everything** and **verifying health before moving on**.

### How this connects to the rest of the course

- **Lesson 2 (Storage)** builds directly on the CSI driver you installed — StorageClasses and PersistentVolumeClaims are next, and they're the prerequisite for every stateful workload.
- **Lesson 3 (Networking)** expands the Service you created into Ingress and in-cluster DNS, which is how clients will reach Kafka and Keycloak.
- The **separated `stateful` node group and taint** you configured in Track B is where Kafka and OpenSearch pods will be scheduled in later lessons.

### Check yourself

1. Why is a StatefulSet, not a Deployment, the right choice for Kafka brokers?
2. What does the CSI driver do, and why did we install it before deploying any stateful workload?
3. In Track B, why did we taint the `stateful` node group, and what was the effect on the smoke-test pods?
4. What single command shows you recent events for a misbehaving pod?

### Troubleshooting quick reference

| Symptom | First thing to check |
|---------|---------------------|
| Node stuck `NotReady` | CNI pods in `kube-system`; wait 60s and re-check |
| Pod stuck `Pending` | `kubectl describe pod` → events; usually scheduling/resources/taints |
| Pod `CrashLoopBackOff` | `kubectl logs <pod>`; app misconfiguration |
| `kubectl` can't connect | kubeconfig context: `kubectl config current-context` |
| EKS create fails | IAM permissions and region quotas; read the CloudFormation event |

---

## Appendix

### A. Local cluster with minikube (alternative to kind)

```bash
# Install (macOS)
brew install minikube

# Start a multi-node cluster
minikube start --nodes 3 --cpus 2 --memory 4096

# Verify
kubectl get nodes
```
Note: multi-node minikube has some networking caveats vs. a single node; `kind` is generally the smoother multi-node local experience.

### B. GKE quick-start

```bash
gcloud container clusters create enterprise-training \
  --region us-central1 \
  --num-nodes 1 \
  --machine-type e2-standard-4 \
  --release-channel regular

gcloud container clusters get-credentials enterprise-training --region us-central1
kubectl get nodes
```

### C. AKS quick-start

```bash
az group create --name enterprise-training-rg --location eastus

az aks create \
  --resource-group enterprise-training-rg \
  --name enterprise-training \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --generate-ssh-keys

az aks get-credentials --resource-group enterprise-training-rg --name enterprise-training
kubectl get nodes
```

### D. kubectl quality-of-life setup

```bash
# Shell alias
echo 'alias k=kubectl' >> ~/.bashrc && source ~/.bashrc

# Bash completion (Linux)
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

# Set a default namespace for the current context (saves typing -n everywhere)
kubectl config set-context --current --namespace=<your-namespace>
```

### E. Glossary

- **Control plane** — the components that manage cluster state (API server, etcd, scheduler, controller manager).
- **Node** — a machine (VM or physical) that runs workloads.
- **CNI** — Container Network Interface; the plugin providing pod networking.
- **CSI** — Container Storage Interface; the plugin connecting Kubernetes to storage backends.
- **StatefulSet** — controller for stateful pods with stable identity and storage.
- **Taint / Toleration** — a mechanism to keep pods off certain nodes unless they explicitly tolerate the taint.
- **kubeconfig** — the file holding cluster connection details and credentials for `kubectl`.

---

*End of Lesson 1. Next: **Lesson 2 — Storage for Stateful Workloads.***


## Module 2: Storage for Stateful Workloads
- StorageClasses, CSI drivers, and dynamic provisioning
- PersistentVolume/PersistentVolumeClaim lifecycle and reclaim policies
- StatefulSets vs Deployments: when and why
- Volume expansion, snapshots, and storage performance tiers (IOPS/throughput)
- Local vs network-attached storage tradeoffs for Kafka and OpenSearch

## Module 3: Networking & Service Exposure
- CNI selection and network policy enforcement
- Service types, headless services for StatefulSets, and DNS
- Ingress controllers, load balancers, and external traffic
- mTLS, service mesh overview (Istio/Linkerd) for inter-service security
- Cross-AZ/region networking and latency considerations

## Module 4: Security & Compliance Baseline
- Pod Security Standards and admission control (OPA/Gatekeeper, Kyverno)
- Secrets management (external secrets, Vault integration, encryption at rest)
- Image scanning, signing, and trusted registries
- Network segmentation and zero-trust principles
- Audit logging and compliance reporting

## Module 5: Operators & Lifecycle Management
- Operator pattern fundamentals and the Operator Lifecycle Manager
- Helm vs Operators vs raw manifests: selection criteria
- GitOps workflows (ArgoCD/Flux) for declarative deployments
- Upgrade strategies and rollback procedures

## Module 6: Kafka on Kubernetes
- Deploying with Strimzi operator: brokers, KRaft/ZooKeeper, topics
- Storage layout, partition placement, and rack awareness
- Listeners, authentication (SASL/mTLS), and authorization (ACLs)
- Scaling brokers, rebalancing (Cruise Control), and rolling updates
- Monitoring lag, throughput, and broker health; disaster recovery

## Module 7: Keycloak on Kubernetes
- Deploying with the Keycloak operator in HA mode
- External database configuration and connection pooling
- Realm/client management as code and import/export strategy
- High availability, caching (Infinispan), and session replication
- TLS, reverse proxy setup, and integration with cluster RBAC/OIDC

## Module 8: OpenSearch on Kubernetes
- Deploying with the OpenSearch operator: master, data, coordinating nodes
- Shard/replica strategy, index lifecycle management (ISM)
- Resource tuning: heap, JVM, and node roles
- Security plugin: users, roles, TLS, and fine-grained access control
- Snapshot/restore, cluster scaling, and hot-warm-cold architecture

## Module 9: NiFi on Kubernetes
- Deploying NiFi clusters (NiFiKop operator) and state management
- Flow versioning with NiFi Registry and promotion across environments
- Securing NiFi: TLS, authentication via Keycloak/OIDC, policies
- Scaling, load distribution, and back-pressure handling
- Integrating NiFi with Kafka and OpenSearch in data pipelines

## Module 10: Observability
- Metrics stack (Prometheus, Grafana) and per-workload dashboards
- Centralized logging (Fluent Bit/Fluentd → OpenSearch/Loki)
- Distributed tracing fundamentals
- Alerting strategy, SLOs/SLIs, and on-call runbooks
- Resource utilization analysis and right-sizing

## Module 11: Reliability, Backup & Disaster Recovery
- Backup strategies per workload (Velero, app-native snapshots)
- Multi-AZ and multi-region resilience patterns
- PodDisruptionBudgets, affinity/anti-affinity, and topology spread
- DR testing, RTO/RPO definition, and restore drills
- Chaos engineering basics

## Module 12: Operations, Maintenance & Cost
- Cluster and node upgrade procedures (zero-downtime)
- Autoscaling: HPA, VPA, and Cluster Autoscaler tuning
- Capacity reviews, resource governance, and cost optimization (FinOps)
- Incident response, troubleshooting playbooks, and escalation paths
- Documentation standards and team handoff practices

## Module 13: Capstone
- End-to-end deployment of all four workloads on a hardened cluster
- Build a data pipeline: NiFi → Kafka → OpenSearch, secured by Keycloak
- Simulate failures, perform recovery, and execute an upgrade cycle

tted course document (with durations, labs, and prerequisites per module), or adjust the depth/scope for a specific audience or timeframe?