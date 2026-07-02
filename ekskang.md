# Strimzi 1.1.0 Demo Kafka on an EXISTING EKS Cluster — Node Group & Down

**Scope:** the EKS control plane, VPC and subnets already exist (cluster name: `demo`). This guide builds everything *from the node group down*: dedicated nodes → EBS CSI + storage → ECR cache → Strimzi operator (Terraform) → a demo Kafka cluster, topic, and smoke test (Ansible).

**Convention:** every code line has an inline `#` comment (line-by-line); each block ends with a **Details** note; **Key concerns** are collected in Part 3.

---

## 0. What you deploy (demo sizing)

| Layer | Choice | Why (demo) | Prod difference |
|---|---|---|---|
| Node group | 3 × `m7i.large`, 3 AZs, labeled `workload=kafka` | cheap, one node per AZ | bigger instances + **taint** the pool |
| Kafka topology | **one dual-role node pool** (`controller,broker`) × 3 | fewest pods that still show real replication | separate controller + broker pools |
| Listeners | `plain 9092` + `tls 9093`, no authz | copy-paste console clients | mTLS only + `authorization: simple` |
| Storage | gp3 defaults, 20Gi, `Delete`/`deleteClaim: true` | clean teardown | `Retain` + `deleteClaim: false` |
| Extras | none | minimal moving parts | Cruise Control, Drain Cleaner, metrics, external NLB |

**Prerequisite check (30 seconds, saves an hour):**

```bash
aws eks describe-cluster --name demo --query 'cluster.version'   # MUST be >= 1.30 for Strimzi 1.1.0
kubectl get crd kafkas.kafka.strimzi.io 2>/dev/null              # MUST be empty — see Key Concern #2 if not
```

## 1. Layout

```
kafka-demo/
├── terraform/
│   ├── providers.tf      # data sources for the EXISTING cluster + provider wiring
│   ├── variables.tf
│   ├── nodegroup.tf      # IAM role + managed node group
│   ├── platform.tf       # EBS CSI (Pod Identity), gp3 StorageClass, ECR pull-through cache
│   └── strimzi.tf        # operator Helm release + kafka namespace
└── ansible/
    ├── requirements.yml
    ├── group_vars/all.yml
    ├── site.yml
    └── templates/
        ├── kafka-demo.yaml.j2    # KafkaNodePool + Kafka (multi-doc)
        └── kafka-topic.yaml.j2
```

---

# PART 1 — TERRAFORM (node group & down)

## 1.1 `providers.tf` — attach to the existing cluster

```hcl
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    helm       = { source = "hashicorp/helm",       version = "~> 3.0" }   # v3: kubernetes = {} attribute syntax
  }
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "demo" {
  name = var.cluster_name                          # reads the EXISTING cluster — nothing is created
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.demo.endpoint                                   # existing API endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.demo.certificate_authority[0].data) # verify TLS with the cluster CA
  exec {                                                                                          # 15-min IAM token; no kubeconfig in state
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.demo.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.demo.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}
```

**Details:** `data` (not `resource`) is the entire "cluster already exists" story — Terraform reads endpoint + CA and never touches the control plane. Your IAM identity must already have Kubernetes admin on this cluster (access entry or aws-auth); see Key Concern #1.

## 1.2 `variables.tf`

```hcl
variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "cluster_name" {
  type    = string
  default = "demo"                                 # the EXISTING EKS cluster
}

variable "private_subnet_ids" {
  type        = list(string)                       # pass the cluster's private subnets explicitly
  description = "3 private subnets in 3 different AZs"
}

variable "instance_type" {
  type    = string
  default = "m7i.large"                            # 2 vCPU / 8 GiB — enough for a 3-node demo
}

variable "strimzi_chart_version" {
  type    = string
  default = "1.1.0"                                # pinned operator version
}
```

**Details:** subnets are an explicit input rather than discovered by tags — existing VPCs rarely have predictable tags, and being explicit prevents the #1 demo failure: subnets in fewer than 3 AZs (Key Concern #4).

## 1.3 `nodegroup.tf` — dedicated Kafka nodes on the existing cluster

```hcl
resource "aws_iam_role" "kafka_nodes" {
  name = "${var.cluster_name}-kafka-nodes"         # node instance role for THIS group only
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" } # EC2 instances assume it via instance profile
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # join the cluster
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # VPC CNI can manage ENIs/IPs
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # pull from ECR (incl. cached images)
  ])
  role       = aws_iam_role.kafka_nodes.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "ecr_pull_through" {
  name = "ecr-pull-through-cache"                  # EXTRA perms the managed ReadOnly policy does NOT include
  role = aws_iam_role.kafka_nodes.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"]  # first pull imports + creates the cache repo
      Resource = "arn:aws:ecr:${var.region}:*:repository/quay/*"           # scoped to the quay/ prefix only
    }]
  })
}

resource "aws_eks_node_group" "kafka" {
  cluster_name    = data.aws_eks_cluster.demo.name # attaches to the EXISTING cluster
  node_group_name = "kafka-demo"
  node_role_arn   = aws_iam_role.kafka_nodes.arn
  subnet_ids      = var.private_subnet_ids         # 3 subnets → EKS spreads nodes across the 3 AZs

  ami_type       = "AL2023_x86_64_STANDARD"        # Amazon Linux 2023 (AL2 is EOL for new versions)
  instance_types = [var.instance_type]

  scaling_config {
    desired_size = 3                               # one node per AZ = one broker per AZ
    min_size     = 3
    max_size     = 3                               # demo: fixed size; no autoscaler surprises (Key Concern #6)
  }

  update_config { max_unavailable = 1 }            # AMI updates roll one node at a time — matches min.insync.replicas=2

  labels = { workload = "kafka" }                  # nodeAffinity target in the node pool template

  depends_on = [aws_iam_role_policy_attachment.node_policies]  # role must be complete before nodes register
  tags       = { project = "kafka-demo" }
}
```

**Details:** a *managed* node group auto-registers its role with the cluster's auth (access entry / aws-auth) — no manual mapping. Nodes automatically get the cluster security group, so broker↔broker and operator↔broker traffic works with zero SG changes. Demo skips the `NoSchedule` taint so nothing else can break scheduling; in prod add the taint back plus matching tolerations.

## 1.4 `platform.tf` — storage + image cache

```hcl
# --- EBS CSI driver via EKS Pod Identity (SKIP this whole section if `aws eks list-addons` already shows it) ---

resource "aws_eks_addon" "pod_identity" {
  cluster_name = data.aws_eks_cluster.demo.name
  addon_name   = "eks-pod-identity-agent"          # node agent that vends credentials to pods
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }   # Pod Identity principal — no OIDC provider wiring needed
      Action    = ["sts:AssumeRole", "sts:TagSession"]      # TagSession is required by Pod Identity
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"  # create/attach/delete EBS volumes
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = data.aws_eks_cluster.demo.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"        # the SA the addon ships with
  role_arn        = aws_iam_role.ebs_csi.arn
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = data.aws_eks_cluster.demo.name
  addon_name   = "aws-ebs-csi-driver"
  depends_on   = [aws_eks_addon.pod_identity, aws_eks_pod_identity_association.ebs_csi]  # association must exist first
}

# --- StorageClass tuned for the DEMO (see table in section 0 for prod flips) ---

resource "kubernetes_storage_class_v1" "gp3_kafka" {
  metadata { name = "gp3-kafka" }                  # referenced by the KafkaNodePool

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"  # CRITICAL: create the volume in the AZ the pod lands in (Key Concern #5)
  allow_volume_expansion = true                    # grow later by editing the node pool size
  reclaim_policy         = "Delete"                # DEMO: teardown removes disks; PROD: "Retain"

  parameters = {
    type                        = "gp3"            # baseline 3000 IOPS / 125 MiB/s — free tier of gp3, fine for demo
    encrypted                   = "true"
    "csi.storage.k8s.io/fstype" = "xfs"            # standard Kafka filesystem
  }
}

# --- ECR pull-through cache: nodes pull quay.io images from INSIDE AWS ---

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"                   # <acct>.dkr.ecr.<region>.amazonaws.com/quay/strimzi/...
  upstream_registry_url = "quay.io"                # public registry — no upstream credential secret needed
}
```

**Details:** Pod Identity replaces the older IRSA/OIDC dance — the trust policy is static (`pods.eks.amazonaws.com`) so it works on any existing cluster without looking up its OIDC issuer. The pull-through cache only pays off if images actually route through it — see the Helm values in 1.5 and Key Concern #7.

## 1.5 `strimzi.tf` — the operator

```hcl
resource "kubernetes_namespace_v1" "kafka" {
  metadata { name = "kafka" }                      # demo cluster + CRs live here
}

resource "kubernetes_namespace_v1" "strimzi" {
  metadata { name = "strimzi" }                    # operator isolated in its own namespace (best practice)
}

resource "helm_release" "strimzi" {
  name       = "strimzi-cluster-operator"
  repository = "oci://quay.io/strimzi-helm"        # official OCI chart location
  chart      = "strimzi-kafka-operator"
  version    = var.strimzi_chart_version           # 1.1.0 — pinned; chart also installs the v1 CRDs
  namespace  = kubernetes_namespace_v1.strimzi.metadata[0].name

  values = [yamlencode({
    watchNamespaces = [kubernetes_namespace_v1.kafka.metadata[0].name]  # least privilege: only "kafka"
    resources = {
      requests = { cpu = "100m", memory = "256Mi" }   # demo-sized operator
      limits   = { memory = "384Mi" }                 # no CPU limit — throttling slows reconciliation
    }
    # Route operator + Kafka images through the ECR cache (recommended even for demo):
    # image = { registry = "<ACCOUNT>.dkr.ecr.${var.region}.amazonaws.com/quay" }
    # Run `helm show values oci://quay.io/strimzi-helm/strimzi-kafka-operator --version 1.1.0`
    # to see every image key (kafka, bridge, etc.) that accepts a registry override.
  })]

  depends_on = [aws_eks_node_group.kafka]          # nodes first, so the operator pod has somewhere to run
}
```

**Details:** the chart owns the CRDs — which is why the pre-flight `kubectl get crd` check matters (Key Concern #2). Since Strimzi 1.0.0, those CRDs expose **only `kafka.strimzi.io/v1`**; any `v1beta2` YAML you copy from old blog posts will be rejected.

---

# PART 2 — ANSIBLE (demo Kafka cluster & down)

## 2.1 `requirements.yml` + setup

```yaml
collections:
  - name: kubernetes.core                 # k8s / k8s_info modules
    version: ">=5.0.0"
```

```bash
ansible-galaxy collection install -r requirements.yml   # from galaxy.ansible.com
pip install kubernetes PyYAML jsonpatch                 # from pypi.org (libs the collection needs)
```

## 2.2 `group_vars/all.yml` — everything tunable in one small file

```yaml
aws_region: eu-west-1                     # matches Terraform var.region
eks_cluster_name: demo                    # the EXISTING cluster

kafka_namespace: kafka                    # created by Terraform; watched by the operator
kafka_cluster_name: demo                  # Kafka CR name → pods: demo-kafka-0..2, svc: demo-kafka-bootstrap
kafka_version: "4.3.0"                    # newest Kafka in Strimzi 1.1.0

node_replicas: 3                          # dual-role nodes: 3 = smallest real KRaft quorum + RF=3
storage_class: gp3-kafka
storage_size: 20Gi                        # demo retention; expandable online later

pod_memory: 2Gi                           # request == limit → Guaranteed QoS (last to be evicted)
pod_cpu_request: "500m"
jvm_heap: 1g                              # heap << container memory; Kafka relies on OS page cache

kafka_topics:
  - { name: demo-events, partitions: 6, replicas: 3, retention_ms: 86400000 }   # 1-day retention
```

**Details:** `2Gi` pods on `m7i.large` (≈6.9Gi allocatable) leave headroom for daemonsets; `1g` heap on a 2Gi container follows the "heap ≈ 40–50%, page cache gets the rest" rule scaled down.

## 2.3 `templates/kafka-demo.yaml.j2` — node pool + cluster in one file

```yaml
apiVersion: kafka.strimzi.io/v1           # the ONLY supported API version since Strimzi 1.0.0
kind: KafkaNodePool
metadata:
  name: dual-role                         # DEMO pattern: each node is controller AND broker
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"   # REQUIRED link to the Kafka CR below
spec:
  replicas: {{ node_replicas }}           # 3 → KRaft quorum survives 1 loss; RF=3 possible
  roles:
    - controller                          # dual role = fewest pods for a working cluster
    - broker                              #   (prod: split into two pools — Key Concern #9)
  storage:
    type: jbod                            # JBOD wrapper even for one volume → future volumes possible
    volumes:
      - id: 0
        type: persistent-claim            # PVC → EBS gp3 via the class below
        size: "{{ storage_size }}"
        class: "{{ storage_class }}"
        deleteClaim: true                 # DEMO: PVCs (and disks, via Delete reclaim) vanish with the cluster
        kraftMetadata: shared             # KRaft metadata log shares this volume
  resources:
    requests: { cpu: "{{ pod_cpu_request }}", memory: "{{ pod_memory }}" }
    limits:   { memory: "{{ pod_memory }}" }   # no CPU limit → no throttling during rebalances
  jvmOptions:
    -Xms: "{{ jvm_heap }}"                # fixed heap = no resize pauses
    -Xmx: "{{ jvm_heap }}"
  template:
    pod:
      affinity:
        nodeAffinity:                     # land ONLY on the node group Terraform just created
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: workload, operator: In, values: [kafka] }
        podAntiAffinity:                  # one Kafka pod per node → node loss costs one replica
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  strimzi.io/cluster: "{{ kafka_cluster_name }}"
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: "{{ kafka_cluster_name }}"
  namespace: "{{ kafka_namespace }}"
spec:
  kafka:
    version: "{{ kafka_version }}"
    rack:
      topologyKey: topology.kubernetes.io/zone   # broker.rack = AZ → replicas spread across zones
    listeners:
      - name: plain                       # DEMO ONLY: no TLS/auth → trivial console-client testing
        port: 9092
        type: internal
        tls: false
      - name: tls                         # the listener real apps should use
        port: 9093
        type: internal
        tls: true                         # operator-managed CA, auto-rotated certs
    config:
      offsets.topic.replication.factor: 3          # internal topics also survive an AZ loss
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2                        # RF=3 − 1: acks=all survives one replica down
      auto.create.topics.enable: "false"            # topics come from KafkaTopic CRs, not typos
  entityOperator:
    topicOperator: {}                     # reconciles the KafkaTopic below (userOperator omitted: no auth in demo)
```

**Details:** this is a complete, production-*shaped* demo — real quorum, real replication, real rack awareness — with exactly two deliberate simplifications (dual-role pool, plaintext listener), both flagged with their prod fixes.

## 2.4 `templates/kafka-topic.yaml.j2`

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: "{{ item.name }}"
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"  # without this label the Topic Operator ignores the CR
spec:
  partitions: {{ item.partitions }}       # can only ever grow — never shrink
  replicas: {{ item.replicas }}
  config:
    retention.ms: {{ item.retention_ms }}
    min.insync.replicas: 2
```

## 2.5 `site.yml`

```yaml
- name: Demo Kafka on existing EKS cluster
  hosts: localhost
  connection: local                       # all work is K8s API calls from this machine
  gather_facts: false

  pre_tasks:
    - name: Point kubeconfig at the existing cluster
      ansible.builtin.command: >-
        aws eks update-kubeconfig --name {{ eks_cluster_name }} --region {{ aws_region }}
      changed_when: false                 # config refresh, never a "change"

    - name: Gate on the operator being Ready
      kubernetes.core.k8s_info:
        kind: Deployment
        name: strimzi-cluster-operator
        namespace: strimzi
      register: op
      failed_when: >-
        op.resources | length == 0 or
        (op.resources[0].status.readyReplicas | default(0)) < 1   # fail fast with a clear reason

  tasks:
    - name: Apply node pool + Kafka cluster, wait until Ready
      kubernetes.core.k8s:
        state: present                    # idempotent server-side apply — rerun freely
        template: templates/kafka-demo.yaml.j2    # multi-doc: pool + Kafka in one apply
        wait: true
        wait_condition: { type: Ready, status: "True" }   # operator sets Ready on the Kafka CR
        wait_timeout: 900                 # first boot: image pulls + 3 EBS volumes + pod rollout

    - name: Apply topics
      kubernetes.core.k8s:
        state: present
        template: templates/kafka-topic.yaml.j2
      loop: "{{ kafka_topics }}"
      loop_control: { label: "{{ item.name }}" }   # clean one-line log per topic

    - name: Print bootstrap addresses
      kubernetes.core.k8s_info:
        api_version: kafka.strimzi.io/v1
        kind: Kafka
        name: "{{ kafka_cluster_name }}"
        namespace: "{{ kafka_namespace }}"
      register: kcr

    - ansible.builtin.debug:
        msg: "{{ kcr.resources[0].status.listeners | default([]) }}"  # shows demo-kafka-bootstrap:9092 / :9093
```

---

# PART 3 — KEY CONCERNS (read before `apply`)

**#1 — Your IAM identity vs. the existing cluster.** Terraform's `helm`/`kubernetes` providers act as *you*. If whoever created `demo` never granted your role cluster-admin (EKS access entry, or `aws-auth` on older clusters), every K8s resource fails with `Unauthorized` while the AWS resources succeed — a confusing half-applied state. Verify first: `kubectl auth can-i create namespace`.

**#2 — CRD ownership collisions.** If Strimzi was ever installed on this cluster by hand (`kubectl apply -f strimzi-crds-*.yaml`) or by another team, the Helm release fails with "resource already exists / not owned by this release." Check with `kubectl get crd | grep strimzi`. Fix: adopt them (add Helm's `meta.helm.sh/release-name` annotations) or uninstall the old copy — never run two operators watching the same namespace.

**#3 — v1-only API.** Strimzi 1.x serves only `kafka.strimzi.io/v1`. Most tutorials online still show `v1beta2` and ZooKeeper — both are gone (ZooKeeper support ended at 0.45, KRaft + node pools are the only mode). Copy examples only from the 1.1.0 `examples/` folder.

**#4 — Subnet/AZ math is silent until it isn't.** Pass 3 subnets in 3 *different* AZs. With 2 AZs, everything deploys, then rack awareness puts 2 replicas in one zone — and an AZ outage takes down `min.insync.replicas`. Verify: `aws ec2 describe-subnets --subnet-ids ... --query 'Subnets[].AvailabilityZone'`.

**#5 — EBS volumes are AZ-pinned; pods must follow.** `WaitForFirstConsumer` solves creation-time placement, but afterwards each broker is *gravity-bound* to its volume's AZ. If a node dies and the group can't replace it in that AZ (capacity, or you shrank the group), that broker stays `Pending` forever. This is also why min=desired=3 in the demo.

**#6 — Autoscalers and Kafka don't mix casually.** Cluster Autoscaler/Karpenter will happily drain a broker node to bin-pack; without Drain Cleaner the pod eviction can drop you below `min.insync.replicas` mid-produce. Demo: fixed-size group, no autoscaler. Prod: install Drain Cleaner *and* keep brokers on a non-consolidating pool.

**#7 — The ECR cache only works if images route through it.** Creating the pull-through rule changes nothing by itself: the image *reference* must be `<acct>.dkr.ecr.<region>.amazonaws.com/quay/strimzi/...` (Helm registry override in 1.5), and the *node role* needs `ecr:BatchImportUpstreamImage` + `ecr:CreateRepository` for the first pull (the inline policy in 1.3 — the managed ReadOnly policy does not include them).

**#8 — Demo storage settings are prod foot-guns.** `reclaim_policy: Delete` + `deleteClaim: true` make teardown one command — and make `kubectl delete kafka demo` *destroy all data*. The prod flip is exactly two lines: `Retain` and `deleteClaim: false`.

**#9 — Dual-role nodes are a demo convenience.** Controllers sharing a JVM with brokers means heavy produce load can starve quorum heartbeats. The upgrade path is clean: add a `controller`-only pool, then remove the role from this one (operator handles the migration) — but do it before real traffic, not after.

**#10 — Plaintext 9092 must never leave the demo.** Anything in-cluster can produce/consume with no identity. Prod: delete the `plain` listener, add `authentication: tls` on 9093, `authorization: simple` + `userOperator`, and manage credentials as `KafkaUser` CRs.

**#11 — Upgrade order is operator-first, always.** New Kafka versions arrive *inside* new Strimzi images. Sequence: bump chart 1.1.0 → 1.x (operator rolls pods) → then bump `kafka_version`. Skipping operator versions across many releases is unsupported territory — read each release's notes.

**#12 — Teardown order (see Part 4).** `terraform destroy` while Kafka is still running rips the node group from under stateful pods and can strand ENIs/volumes. Always delete the CRs (Ansible/kubectl) and let PVCs clean up *before* destroying infrastructure.

---

# PART 4 — RUN IT / TEST IT / TEAR IT DOWN

```bash
# 1) Infra + operator
cd terraform
terraform init && terraform apply \
  -var='private_subnet_ids=["subnet-aaa","subnet-bbb","subnet-ccc"]'   # your existing 3 private subnets

# 2) Kafka
cd ../ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml

# 3) Smoke test (two terminals) — plaintext demo listener
kubectl -n kafka run producer -it --rm \
  --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-console-producer.sh --bootstrap-server demo-kafka-bootstrap:9092 --topic demo-events

kubectl -n kafka run consumer -it --rm \
  --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server demo-kafka-bootstrap:9092 \
  --topic demo-events --from-beginning

# 4) Health checks worth knowing
kubectl -n kafka get kafka demo -o jsonpath='{.status.conditions}'     # Ready=True?
kubectl -n kafka get pods -l strimzi.io/cluster=demo -o wide           # one pod per node, 3 AZs?
kubectl -n kafka get pvc                                               # 3 Bound volumes on gp3-kafka?

# 5) Teardown — ORDER MATTERS (Key Concern #12)
kubectl -n kafka delete kafkatopic --all
kubectl -n kafka delete kafka demo --wait                              # operator removes pods; deleteClaim removes PVCs/disks
cd ../terraform && terraform destroy                                   # then the operator, storage class, node group
```

---

# PART 5 — BEST-PRACTICES RECAP (demo → prod delta)

- [ ] Pin versions everywhere (chart `1.1.0`, Kafka `4.3.0`, providers, collections); upgrade operator **before** Kafka.
- [ ] Keep the split: Terraform = infra + operator; Ansible = idempotent CRs with `wait_condition: Ready` as the gate.
- [ ] 3 AZs / 3 nodes / RF=3 / `min.insync.replicas=2` — the demo already teaches the right shape.
- [ ] `WaitForFirstConsumer` + Guaranteed QoS + hostname anti-affinity + rack awareness: non-negotiable in any environment.
- [ ] Route images through the ECR pull-through cache and grant the two extra ECR IAM actions.
- [ ] Prod flips, in order of importance: `Retain`/`deleteClaim:false` → drop `plain`, add mTLS + ACLs + `userOperator` → split controller/broker pools → taint the node group → Drain Cleaner → Cruise Control → metrics ConfigMap + dashboards from the 1.1.0 `examples/` folder.
