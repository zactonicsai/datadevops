# Strimzi 1.1.0 on AWS EKS — Terraform + Ansible Build Guide

**Convention used in this document:** every line of code carries an inline `#` comment explaining what it does (the "line-by-line"), and each block is followed by a **Details** note covering the non-obvious design decisions.

---

## 0. Version matrix & external endpoints

| Component | Version | Source (external to AWS) |
|---|---|---|
| Strimzi operator | **1.1.0** | `oci://quay.io/strimzi-helm/strimzi-kafka-operator` |
| Apache Kafka | **4.3.0** (also 4.2.1 / 4.2.0) | baked into `quay.io/strimzi/kafka:1.1.0-kafka-4.3.0` |
| Strimzi Drain Cleaner | 1.6.0 | `oci://quay.io/strimzi-helm/strimzi-drain-cleaner` |
| Kubernetes / EKS | 1.30+ required → use **1.33** | AWS (control plane) |
| CRD API | `kafka.strimzi.io/v1` **only** (v1beta2 removed in 1.0.0) | shipped with the Helm chart |
| Mode | **KRaft only** + **KafkaNodePool required** (ZooKeeper support ended at 0.45) | — |

**Endpoints your build machines / pipeline must reach:**

| Endpoint | Used by | Purpose |
|---|---|---|
| `registry.terraform.io` | Terraform | providers (`aws`, `kubernetes`, `helm`, `kubectl`) + modules (`vpc`, `eks`, `iam`) |
| `quay.io` | Helm/EKS nodes | Strimzi Helm charts (OCI) + all Strimzi container images |
| `github.com` | optional | raw install YAMLs, `examples/` folder (metrics configs, dashboards) |
| `galaxy.ansible.com` | Ansible | `kubernetes.core`, `amazon.aws` collections |
| `pypi.org` | Ansible host | `kubernetes`, `boto3`, `PyYAML`, `jsonpatch` Python libs |
| `dl.k8s.io`, `get.helm.sh` | pipeline | `kubectl`, `helm` binaries |

> **Best practice:** nodes should *not* pull from `quay.io` directly in production — an ECR **pull-through cache** (section 1.6) proxies and caches it inside AWS.

---

## 1. Division of responsibility

```
Terraform  →  everything with AWS state: VPC, EKS, node groups, IAM/IRSA,
              gp3 StorageClass, ECR pull-through cache, Strimzi OPERATOR (Helm)
Ansible    →  everything that is Kafka configuration (day-2, idempotent):
              KafkaNodePool, Kafka, KafkaTopic, KafkaUser, metrics ConfigMap, rebalances
```

Why split here: the operator is infrastructure (installed once, upgraded rarely, owns CRDs); the custom resources are configuration that app teams change weekly. Keeping CRs out of Terraform state avoids `terraform apply` fighting the operator's own reconciliation.

## 2. Repository layout

```
kafka-platform/
├── terraform/
│   ├── versions.tf        # required providers + versions
│   ├── providers.tf       # aws / kubernetes / helm provider wiring
│   ├── variables.tf       # inputs
│   ├── vpc.tf             # 3-AZ VPC
│   ├── eks.tf             # EKS 1.33 + dedicated Kafka node group + EBS CSI
│   ├── storage.tf         # gp3 StorageClass tuned for Kafka
│   ├── ecr.tf             # quay.io pull-through cache
│   ├── strimzi.tf         # Strimzi operator + Drain Cleaner Helm releases
│   └── outputs.tf
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml   # Galaxy collections
    ├── inventory/hosts.ini
    ├── group_vars/all.yml # cluster sizing, versions, topics, users
    ├── site.yml           # the playbook
    └── templates/
        ├── kafka-metrics-cm.yaml.j2
        ├── kafka-nodepools.yaml.j2
        ├── kafka-cluster.yaml.j2
        ├── kafka-topic.yaml.j2
        └── kafka-user.yaml.j2
```

---

# PART 1 — TERRAFORM

## 1.1 `versions.tf`

```hcl
terraform {
  required_version = ">= 1.9.0"                  # locks minimum Terraform CLI; 1.9+ has stable provider-defined functions & better plan output

  required_providers {
    aws = {
      source  = "hashicorp/aws"                  # pulled from registry.terraform.io
      version = "~> 6.0"                         # v6 line; "~>" allows 6.x patch/minor, blocks 7.0 breaking changes
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"           # used ONLY for namespace + StorageClass objects
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"                 # installs the Strimzi operator chart
      version = "~> 3.0"                         # NOTE: v3 changed `kubernetes {}` block to `kubernetes = {}` attribute
    }
    kubectl = {
      source  = "gavinbunney/kubectl"            # OPTIONAL: only if you also want raw CRs applied from TF
      version = "~> 1.19"
    }
  }
}
```

**Details:** pin with `~>` and commit `.terraform.lock.hcl` so every pipeline run resolves identical provider builds. The `kubectl` provider is listed because it applies raw YAML without needing the CRD schema at plan time — useful if you ever move CRs into Terraform — but in this design Ansible owns CRs, so you may delete it.

## 1.2 `providers.tf`

```hcl
provider "aws" {
  region = var.region                            # single source of truth for region, passed everywhere else
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint                                   # EKS API endpoint from the module output
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)   # cluster CA so TLS is verified, not skipped
  exec {                                                                                  # short-lived token instead of static kubeconfig
    api_version = "client.authentication.k8s.io/v1beta1"                                  # exec credential API version kubectl/EKS expect
    command     = "aws"                                                                   # shells out to AWS CLI v2 on the runner
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,         # mints a 15-min IAM-signed token
                   "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {                                  # v3 syntax: attribute object, not a nested block
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
                     "--region", var.region]
    }
  }
}
```

**Details:** the `exec` pattern means no kubeconfig file and no long-lived credentials ever touch disk or state — each apply authenticates with the caller's IAM identity. This works because the EKS module below grants the creator admin access via EKS Access Entries.

## 1.3 `variables.tf`

```hcl
variable "region" {
  type    = string
  default = "eu-west-1"                          # change to your region
}

variable "cluster_name" {
  type    = string
  default = "kafka-prod"                         # reused for VPC, EKS, IAM names
}

variable "eks_version" {
  type    = string
  default = "1.33"                               # Strimzi 1.1.0 requires K8s >= 1.30
}

variable "strimzi_chart_version" {
  type    = string
  default = "1.1.0"                              # pin the operator; upgrades are deliberate, reviewed changes
}

variable "kafka_node_instance_type" {
  type    = string
  default = "m7i.2xlarge"                        # 8 vCPU / 32 GiB — room for broker heap + page cache
}
```

**Details:** everything version-shaped is a pinned variable so an operator upgrade is a one-line PR with a visible plan diff — never an accidental `latest`.

## 1.4 `vpc.tf`

```hcl
data "aws_availability_zones" "available" {
  state = "available"                            # dynamically discovers AZs so the code is region-portable
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"      # community-standard VPC module from the Terraform Registry
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"                           # 65k addresses; EKS pods consume real VPC IPs (VPC CNI)

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)  # exactly 3 AZs → matches Kafka RF=3 / rack awareness
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]           # big /19s: nodes + pod IPs live here
  public_subnets  = ["10.0.96.0/22", "10.0.100.0/22", "10.0.104.0/22"]        # small: only NAT GWs / public LBs

  enable_nat_gateway   = true                    # private nodes need egress to pull from quay.io/ECR
  single_nat_gateway   = false                   # one NAT per AZ — an AZ outage must not kill egress for surviving brokers
  enable_dns_hostnames = true                    # required by EKS

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }  # lets AWS LB Controller place internal NLBs here
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }           # ...and internet-facing LBs here
}
```

**Details:** 3 AZs is the load-bearing decision — Strimzi's `rack` feature (section on the Kafka CR) maps Kafka's `broker.rack` to `topology.kubernetes.io/zone`, and with `min.insync.replicas=2` + RF=3 you survive a full AZ loss with zero data loss.

## 1.5 `eks.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"                            # v21 line (renamed inputs: name / kubernetes_version / addons)

  name               = var.cluster_name          # EKS cluster name
  kubernetes_version = var.eks_version           # 1.33

  vpc_id     = module.vpc.vpc_id                 # place the cluster in the VPC above
  subnet_ids = module.vpc.private_subnets        # nodes + ENIs in private subnets only

  endpoint_public_access                   = true   # convenient for CI; lock down with allowed CIDRs or go private in prod
  enable_cluster_creator_admin_permissions = true   # EKS Access Entry giving the TF caller admin → helm/kubernetes providers work immediately
  enable_irsa                              = true   # creates the OIDC provider → IAM Roles for Service Accounts

  addons = {
    coredns    = {}                               # cluster DNS
    kube-proxy = {}
    vpc-cni    = { before_compute = true }        # CNI must be ready before nodes join, or pods get no IPs
    aws-ebs-csi-driver = {                        # provisions the EBS volumes behind Kafka's PVCs
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn   # IRSA role wired below
    }
  }

  eks_managed_node_groups = {
    system = {                                    # small pool for operator, DNS, monitoring agents
      instance_types = ["m7i.large"]
      ami_type       = "AL2023_x86_64_STANDARD"   # Amazon Linux 2023 (AL2 is deprecated)
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }

    kafka = {                                     # DEDICATED pool for brokers/controllers
      instance_types = [var.kafka_node_instance_type]
      ami_type       = "AL2023_x86_64_STANDARD"
      min_size       = 3                          # one node per AZ minimum
      max_size       = 6
      desired_size   = 3
      subnet_ids     = module.vpc.private_subnets # spread across all 3 AZs
      labels         = { workload = "kafka" }     # target for nodeAffinity in the node pools
      taints = {
        dedicated = {                             # nothing schedules here unless it tolerates the taint
          key    = "dedicated"
          value  = "kafka"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  tags = { project = "kafka-platform" }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.60"

  role_name             = "${var.cluster_name}-ebs-csi"   # IAM role the CSI controller assumes
  attach_ebs_csi_policy = true                            # AWS-managed AmazonEBSCSIDriverPolicy

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn        # trust the cluster's OIDC issuer
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"] # ONLY this SA may assume the role
    }
  }
}
```

**Details:** taint + label on the `kafka` pool is the isolation mechanism — brokers get the whole node's page cache and disk bandwidth, and a noisy app pod can never be co-scheduled. Ansible's node-pool template adds the matching toleration + nodeAffinity. Keep `desired_size` ≥ broker replicas so anti-affinity can place one broker per node.

## 1.6 `storage.tf` + `ecr.tf`

```hcl
resource "kubernetes_storage_class_v1" "gp3_kafka" {
  metadata { name = "gp3-kafka" }                # referenced by name in the KafkaNodePool storage spec

  storage_provisioner    = "ebs.csi.aws.com"     # the CSI addon installed above
  volume_binding_mode    = "WaitForFirstConsumer" # CRITICAL: volume is created in the AZ where the pod lands, not randomly
  allow_volume_expansion = true                  # grow disks online by editing the KafkaNodePool size
  reclaim_policy         = "Retain"              # deleting a PVC must NOT destroy broker data

  parameters = {
    type                        = "gp3"
    iops                        = "4000"         # gp3 lets you buy IOPS independent of size (baseline 3000)
    throughput                  = "250"          # MiB/s; raise for high-throughput clusters
    encrypted                   = "true"         # EBS encryption at rest (KMS default key; set kmsKeyId to pin one)
    "csi.storage.k8s.io/fstype" = "xfs"          # XFS is the standard Kafka filesystem choice
  }
}

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"                 # images become <acct>.dkr.ecr.<region>.amazonaws.com/quay/strimzi/...
  upstream_registry_url = "quay.io"              # public Quay needs no upstream credentials
}
```

**Details:** `WaitForFirstConsumer` is the one setting people miss — with `Immediate`, EBS volumes get created in AZs where no schedulable Kafka node exists and pods deadlock. With the cache rule, the first pull of `quay/strimzi/kafka:1.1.0-kafka-4.3.0` populates ECR and every later pull (node replacement, scaling) stays inside AWS — faster, and immune to quay.io outages or rate limits.

## 1.7 `strimzi.tf`

```hcl
resource "kubernetes_namespace_v1" "strimzi" {
  metadata { name = "strimzi" }                  # operator lives here...
}

resource "kubernetes_namespace_v1" "kafka" {
  metadata { name = "kafka" }                    # ...clusters live here (separate ns = cleaner RBAC + best practice)
}

resource "helm_release" "strimzi_operator" {
  name       = "strimzi-cluster-operator"
  repository = "oci://quay.io/strimzi-helm"      # official OCI registry (alt: https://strimzi.io/charts/)
  chart      = "strimzi-kafka-operator"
  version    = var.strimzi_chart_version         # 1.1.0 — pinned, never floating
  namespace  = kubernetes_namespace_v1.strimzi.metadata[0].name

  values = [yamlencode({
    watchNamespaces = [kubernetes_namespace_v1.kafka.metadata[0].name]  # least privilege: watch ONLY "kafka", not the whole cluster
    resources = {
      requests = { cpu = "200m", memory = "384Mi" }
      limits   = { memory = "512Mi" }            # JVM operator; memory limit yes, CPU limit deliberately omitted (throttling hurts reconcile)
    }
    # To route ALL images through the ECR pull-through cache instead of quay.io,
    # override the chart's image registry values, e.g.:
    # image = { registry = "<ACCOUNT>.dkr.ecr.${var.region}.amazonaws.com/quay" }
    # → check `helm show values` for the full image map (operator + kafka + bridge images).
  })]

  depends_on = [module.eks]                      # never race the control plane / node groups
}

resource "helm_release" "drain_cleaner" {
  name             = "strimzi-drain-cleaner"
  repository       = "oci://quay.io/strimzi-helm"
  chart            = "strimzi-drain-cleaner"
  version          = "1.6.0"                     # matches the version shipped with Strimzi 1.1.0
  namespace        = "strimzi-drain-cleaner"
  create_namespace = true
  depends_on       = [helm_release.strimzi_operator]
}
```

**Details:** the chart installs the CRDs, ClusterRoles, bindings and the operator Deployment in one release — and since Strimzi 1.0.0 those CRDs serve **only `v1`**, so any old `v1beta2` manifests must be converted before this ever runs against a migrated cluster. Drain Cleaner intercepts node drains (`kubectl drain`, managed node group updates, Karpenter) and lets Strimzi move partition leadership first, so rolling nodes never violates `min.insync.replicas`.

## 1.8 `outputs.tf`

```hcl
output "cluster_name"    { value = module.eks.cluster_name }      # consumed by Ansible group_vars
output "region"          { value = var.region }
output "kafka_namespace" { value = kubernetes_namespace_v1.kafka.metadata[0].name }
output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"  # copy-paste for humans/CI
}
```

---

# PART 2 — ANSIBLE

## 2.1 `ansible.cfg` + `inventory/hosts.ini`

```ini
# ansible.cfg
[defaults]
inventory        = inventory/hosts.ini    # default inventory path
host_key_checking = False                 # irrelevant here (no SSH), silences warnings
stdout_callback  = yaml                   # readable task output
```

```ini
# inventory/hosts.ini
[control]
localhost ansible_connection=local        # everything talks to the K8s API from this machine — no SSH targets
```

**Details:** Kubernetes work runs on `localhost` because the modules call the API server directly using your kubeconfig; there are no remote hosts to manage.

## 2.2 `requirements.yml` (Ansible Galaxy — external dependency)

```yaml
collections:
  - name: kubernetes.core                 # k8s / k8s_info / helm modules — the workhorse
    version: ">=5.0.0"
  - name: amazon.aws                      # optional: aws_caller_info, EKS lookups
    version: ">=9.0.0"
```

Install collections **and** the Python libs they require (from pypi.org):

```bash
ansible-galaxy collection install -r requirements.yml
pip install kubernetes boto3 botocore PyYAML jsonpatch
```

## 2.3 `group_vars/all.yml` — the single tuning surface

```yaml
aws_region: eu-west-1                     # must match Terraform var.region
eks_cluster_name: kafka-prod              # must match Terraform var.cluster_name

kafka_namespace: kafka                    # namespace Terraform created & operator watches
kafka_cluster_name: prod                  # metadata.name of the Kafka CR; prefixes every pod/service
kafka_version: "4.3.0"                    # newest Kafka supported by Strimzi 1.1.0

controller_replicas: 3                    # KRaft quorum — always an odd number, one per AZ
broker_replicas: 3                        # >= 3 so RF=3 / min.insync.replicas=2 works
storage_class: gp3-kafka                  # StorageClass Terraform created
controller_storage_size: 50Gi             # KRaft metadata log is small
broker_storage_size: 500Gi                # size for retention + headroom (expandable later)

broker_memory: 16Gi                       # container request AND limit (see Details below)
broker_cpu_request: "4"
broker_jvm_heap: 6g                       # heap deliberately << container memory: Kafka lives on OS page cache

external_listener_enabled: false          # flip to true to add an internal-NLB listener

kafka_topics:                             # desired-state topic list — reviewed via PR
  - { name: orders,   partitions: 12, replicas: 3, retention_ms: 604800000 }
  - { name: payments, partitions: 6,  replicas: 3, retention_ms: 259200000 }

kafka_users:                              # mTLS users + least-privilege ACLs
  - name: orders-service
    acls:
      - { resource: topic, name: orders, operations: [Read, Write, Describe] }
      - { resource: group, name: orders-service, operations: [Read] }
```

**Details:** request = limit for broker memory gives the pod *Guaranteed* QoS — brokers are the last thing the kubelet evicts under node pressure. Heap at ~35–40% of container memory is deliberate: Kafka's real cache is the Linux page cache, and an oversized heap starves it.

## 2.4 `templates/kafka-metrics-cm.yaml.j2`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-metrics                     # referenced by metricsConfig in the Kafka CR
  namespace: "{{ kafka_namespace }}"
  labels:
    app: strimzi
data:
  kafka-metrics-config.yml: |             # JMX→Prometheus mapping rules consumed by the built-in exporter
    lowercaseOutputName: true
    rules:                                # minimal starter rule; replace with Strimzi's full example (URL below)
      - pattern: "kafka.server<type=(.+), name=(.+)><>Value"
        name: "kafka_server_$1_$2"
```

**Details:** don't hand-write these rules — take the maintained full set from the release's examples folder: `https://github.com/strimzi/strimzi-kafka-operator/blob/1.1.0/examples/metrics/kafka-metrics.yaml` (same folder has ready-made Grafana dashboards and PodMonitor manifests for kube-prometheus-stack).

## 2.5 `templates/kafka-nodepools.yaml.j2`

```yaml
apiVersion: kafka.strimzi.io/v1           # v1 is the ONLY API version since Strimzi 1.0.0
kind: KafkaNodePool
metadata:
  name: controller                        # pool of dedicated KRaft controllers
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"   # REQUIRED: binds this pool to the Kafka CR
spec:
  replicas: {{ controller_replicas }}     # 3 → quorum tolerates one AZ/node loss
  roles:
    - controller                          # controllers only — never mix roles in prod
  storage:
    type: jbod                            # JBOD wrapper even for one volume → lets you add volumes later
    volumes:
      - id: 0
        type: persistent-claim            # PVC → EBS via the gp3-kafka StorageClass
        size: "{{ controller_storage_size }}"
        class: "{{ storage_class }}"
        deleteClaim: false                # deleting the cluster CR keeps the disks (belt) — Retain policy is braces
        kraftMetadata: shared             # this volume also stores the KRaft metadata log
  template:
    pod:
      tolerations:                        # allows scheduling onto the tainted Kafka node group
        - key: dedicated
          operator: Equal
          value: kafka
          effect: NoSchedule
      affinity:
        nodeAffinity:                     # ...and REQUIRES landing there
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: workload, operator: In, values: [kafka] }
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: broker
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"
spec:
  replicas: {{ broker_replicas }}
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: "{{ broker_storage_size }}"
        class: "{{ storage_class }}"
        deleteClaim: false
  resources:
    requests: { cpu: "{{ broker_cpu_request }}", memory: "{{ broker_memory }}" }
    limits:   { memory: "{{ broker_memory }}" }   # request==limit → Guaranteed QoS; no CPU limit → no throttling
  jvmOptions:
    -Xms: "{{ broker_jvm_heap }}"         # min heap
    -Xmx: "{{ broker_jvm_heap }}"         # max heap == min heap → no resize pauses
  template:
    pod:
      tolerations:
        - { key: dedicated, operator: Equal, value: kafka, effect: NoSchedule }
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - { key: workload, operator: In, values: [kafka] }
        podAntiAffinity:                  # never two brokers on one node → node loss costs exactly one replica
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  strimzi.io/pool-name: broker
```

**Details:** node pools are mandatory in current Strimzi — sizing, storage, resources and scheduling live *here*, while cluster-wide config lives in the Kafka CR. AZ spreading isn't listed because the `rack` feature below + `WaitForFirstConsumer` volumes already pin brokers to zones; hostname anti-affinity covers the within-AZ case.

## 2.6 `templates/kafka-cluster.yaml.j2`

```yaml
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: "{{ kafka_cluster_name }}"
  namespace: "{{ kafka_namespace }}"
  annotations:
    strimzi.io/node-pools: enabled        # the only supported mode in 1.x — kept explicit for readability
    strimzi.io/kraft: enabled             # ditto (ZooKeeper is gone since 0.46)
spec:
  kafka:
    version: "{{ kafka_version }}"        # 4.3.0; upgrades = change this + roll via operator
    rack:
      topologyKey: topology.kubernetes.io/zone   # sets broker.rack per AZ → replicas spread across AZs, rack-aware fetching
    listeners:
      - name: tls                         # in-cluster listener
        port: 9093
        type: internal
        tls: true                         # operator-managed cluster CA; certs auto-rotated
        authentication:
          type: tls                       # mTLS — KafkaUser secrets carry client certs
{% if external_listener_enabled %}
      - name: external
        port: 9094
        type: loadbalancer                # one NLB for bootstrap + one per broker
        tls: true
        authentication:
          type: tls
        configuration:
          bootstrap:
            annotations: &nlb             # AWS Load Balancer Controller: internal NLB, IP targets
              service.beta.kubernetes.io/aws-load-balancer-type: external
              service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
              service.beta.kubernetes.io/aws-load-balancer-scheme: internal
          brokers:
{% for b in range(broker_replicas) %}
            - broker: {{ b }}             # per-broker Services need the same annotations
              annotations: *nlb
{% endfor %}
{% endif %}
    authorization:
      type: simple                        # enables ACLs so KafkaUser.spec.authorization is enforced
      superUsers:
        - CN=platform-admin               # break-glass identity that bypasses ACLs
    config:
      offsets.topic.replication.factor: 3          # internal topics must also survive an AZ loss
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3                # default for auto/CLI-created topics
      min.insync.replicas: 2                        # with RF=3: tolerate 1 replica down, still acks=all
      auto.create.topics.enable: "false"            # topics come from Git (KafkaTopic), not from producer typos
    metricsConfig:
      type: jmxPrometheusExporter
      valueFrom:
        configMapKeyRef:
          name: kafka-metrics             # the ConfigMap from 2.4
          key: kafka-metrics-config.yml
  entityOperator:
    topicOperator: {}                     # reconciles KafkaTopic CRs
    userOperator: {}                      # reconciles KafkaUser CRs (creates cert/password Secrets)
  cruiseControl: {}                       # enables KafkaRebalance workflows (defaults are fine to start)
```

**Details (external listener caveat):** with node pools, broker IDs are pool-assigned and not guaranteed to be `0..n-1` — the Jinja `range()` loop is fine for a fresh cluster but after scaling operations, list the *actual* IDs (or pin them with the `strimzi.io/next-node-ids` annotation on the pool). The external listener also assumes the AWS Load Balancer Controller is installed (Helm repo `https://aws.github.io/eks-charts` — one more external endpoint).

## 2.7 `templates/kafka-topic.yaml.j2` + `kafka-user.yaml.j2`

```yaml
# kafka-topic.yaml.j2 — rendered once per item in kafka_topics
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: "{{ item.name }}"
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"  # REQUIRED or the Topic Operator ignores it
spec:
  partitions: {{ item.partitions }}       # can only grow, never shrink — start sensible
  replicas: {{ item.replicas }}
  config:
    retention.ms: {{ item.retention_ms }}
    min.insync.replicas: 2                # per-topic guarantee matching the cluster default
```

```yaml
# kafka-user.yaml.j2 — rendered once per item in kafka_users
apiVersion: kafka.strimzi.io/v1
kind: KafkaUser
metadata:
  name: "{{ item.name }}"
  namespace: "{{ kafka_namespace }}"
  labels:
    strimzi.io/cluster: "{{ kafka_cluster_name }}"
spec:
  authentication:
    type: tls                             # User Operator issues a client cert into Secret/{{ item.name }}
  authorization:
    type: simple
    acls:
{% for acl in item.acls %}
      - resource:
          type: {{ acl.resource }}        # topic | group | cluster | transactionalId
          name: "{{ acl.name }}"
          patternType: literal
        operations: {{ acl.operations | to_json }}   # e.g. [Read, Write, Describe]
        host: "*"
{% endfor %}
```

## 2.8 `site.yml` — the playbook

```yaml
- name: Configure Kafka on EKS (Strimzi 1.1.0)
  hosts: control                          # = localhost from the inventory
  connection: local
  gather_facts: false                     # nothing here needs host facts → faster

  pre_tasks:
    - name: Point kubeconfig at the EKS cluster
      ansible.builtin.command: >-
        aws eks update-kubeconfig
        --name {{ eks_cluster_name }} --region {{ aws_region }}
      changed_when: false                 # idempotent config refresh, never reported as a change

    - name: Ensure Strimzi operator is up before touching CRs
      kubernetes.core.k8s_info:
        kind: Deployment
        name: strimzi-cluster-operator
        namespace: strimzi
      register: operator
      failed_when: >-
        operator.resources | length == 0 or
        (operator.resources[0].status.readyReplicas | default(0)) < 1   # hard fail early with a clear message

  tasks:
    - name: Apply Kafka JMX metrics ConfigMap
      kubernetes.core.k8s:
        state: present                    # server-side create-or-update → idempotent
        template: templates/kafka-metrics-cm.yaml.j2

    - name: Apply KafkaNodePools (controller + broker)
      kubernetes.core.k8s:
        state: present
        template: templates/kafka-nodepools.yaml.j2   # multi-doc YAML applies both pools

    - name: Apply Kafka cluster and wait until Ready
      kubernetes.core.k8s:
        state: present
        template: templates/kafka-cluster.yaml.j2
        wait: true                        # block until the operator reports readiness
        wait_condition: { type: Ready, status: "True" }   # the Kafka CR's status condition
        wait_timeout: 1200                # first boot = pull images + provision EBS + roll pods; be generous

    - name: Apply topics
      kubernetes.core.k8s:
        state: present
        template: templates/kafka-topic.yaml.j2
      loop: "{{ kafka_topics }}"          # one CR per entry in group_vars
      loop_control: { label: "{{ item.name }}" }   # clean log lines, no YAML dumps

    - name: Apply users
      kubernetes.core.k8s:
        state: present
        template: templates/kafka-user.yaml.j2
      loop: "{{ kafka_users }}"
      loop_control: { label: "{{ item.name }}" }

    - name: Show bootstrap address
      kubernetes.core.k8s_info:
        api_version: kafka.strimzi.io/v1
        kind: Kafka
        name: "{{ kafka_cluster_name }}"
        namespace: "{{ kafka_namespace }}"
      register: kafka_cr

    - ansible.builtin.debug:
        msg: "{{ kafka_cr.resources[0].status.listeners | default([]) }}"   # prints bootstrapServers per listener
```

**Details:** every task is `state: present` against declarative CRs, so the whole playbook is safely re-runnable — that's the contract that makes Ansible the day-2 tool here. The `wait_condition` on `Ready` is what turns "kubectl apply and hope" into a pipeline gate.

---

# PART 3 — EXECUTION ORDER

```bash
# 1. Infrastructure + operator (from terraform/)
terraform init                                    # downloads providers/modules from registry.terraform.io
terraform plan -out=tfplan                        # review: VPC, EKS, StorageClass, 2 Helm releases
terraform apply tfplan

# 2. One-time Ansible setup (from ansible/)
ansible-galaxy collection install -r requirements.yml   # galaxy.ansible.com
pip install kubernetes boto3 botocore PyYAML jsonpatch  # pypi.org

# 3. Kafka configuration (re-run any time config changes)
ansible-playbook site.yml

# 4. Smoke test from inside the cluster
kubectl -n kafka run producer --rm -it \
  --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server prod-kafka-bootstrap:9092 --topic orders
# (9092 only exists if you add a plaintext internal listener for testing;
#  otherwise use 9093 with the client certs from Secret/orders-service)
```

**CRD ordering note:** the Helm release installs the CRDs, and the playbook's operator pre-check guarantees they exist before any `kafka.strimzi.io/v1` resource is applied — never invert steps 1 and 3.

---

# PART 4 — BEST-PRACTICES CHECKLIST

- [ ] **Pin everything**: chart `1.1.0`, Kafka `4.3.0`, providers via `.terraform.lock.hcl`, collections via `requirements.yml`; upgrades are PRs, never `latest`.
- [ ] **Images through ECR pull-through cache** (`quay.io` upstream) — plus SHA digests if your compliance bar requires it.
- [ ] **v1 CRDs only** since Strimzi 1.0.0 — convert any `v1beta2` manifests *before* upgrading an existing cluster.
- [ ] **KRaft + node pools only** — migrate off ZooKeeper on ≤ 0.45 before ever reaching 1.x.
- [ ] **3 AZs end-to-end**: subnets, node group, `rack.topologyKey`, RF=3, `min.insync.replicas=2`.
- [ ] **Dedicated tainted nodes** for Kafka; hostname pod anti-affinity; Guaranteed QoS on brokers.
- [ ] **gp3 + XFS + WaitForFirstConsumer + Retain + expansion enabled**; `deleteClaim: false`.
- [ ] **Drain Cleaner installed** before your first node-group upgrade, not after the first incident.
- [ ] **Cruise Control on** from day one; scale/rebalance via `KafkaRebalance` CRs, not by hand.
- [ ] **Operator watches one namespace**, runs in its own namespace, one operator per cluster.
- [ ] **mTLS everywhere + `authorization: simple`** with least-privilege ACLs; `auto.create.topics.enable=false`.
- [ ] **Monitoring from the examples folder** (metrics rules, PodMonitors, Grafana dashboards) wired into kube-prometheus-stack.
- [ ] **GitOps the CRs**: topics/users live in `group_vars`, reviewed in PRs, applied idempotently by `site.yml`.
