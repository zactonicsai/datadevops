**Latest version: Strimzi 1.1.0** (released June 27, 2026). Key facts: it supports Apache Kafka 4.3.0, 4.2.1, and 4.2.0 (Kafka 4.1.x support removed), and from Strimzi 1.0.0 the only supported CRD API version is v1.  It’s KRaft-only (ZooKeeper support ended at 0.45) and needs Kubernetes 1.30+, so EKS 1.30 or newer.

Here’s everything external to AWS you’d reference:

**Container images (quay.io)** — the 1.1.0 release ships these images: 

- `quay.io/strimzi/operator:1.1.0` (cluster/topic/user operators)
- `quay.io/strimzi/kafka:1.1.0-kafka-4.3.0` (also 4.2.1, 4.2.0 tags)
- `quay.io/strimzi/kafka-bridge` (optional HTTP bridge)
- `quay.io/strimzi/kaniko-executor`, `quay.io/strimzi/maven-builder`, `quay.io/strimzi/buildah` (only if using KafkaConnect Build)
- `quay.io/strimzi/drain-cleaner:1.6.0` and `quay.io/strimzi/access-operator:0.3.0` — both included in the installation files 

**Install artifacts (github.com / strimzi.io)**

- Helm chart: `oci://quay.io/strimzi-helm/strimzi-kafka-operator` or repo `https://strimzi.io/charts/` — it bootstraps the Deployment, ClusterRoles, bindings, ServiceAccounts, and CRDs 
- Raw YAML alternative: `strimzi-cluster-operator-1.1.0.yaml` and `strimzi-crds-1.1.0.yaml` from GitHub releases; the release archive (strimzi-1.1.0.*) contains the install/cluster-operator files and an examples folder with sample custom resources 

**Terraform (registry.terraform.io)**

- Providers: `hashicorp/aws`, `hashicorp/helm` (for the chart), `hashicorp/kubernetes`, optionally `gavinbunney/kubectl` for applying Kafka/KafkaNodePool CRs
- Modules: `terraform-aws-modules/eks/aws`, `terraform-aws-modules/vpc/aws`

**Ansible (galaxy.ansible.com + pypi.org)**

- Collections: `kubernetes.core`, `amazon.aws`, `community.general`
- Python libs: `kubernetes`, `boto3`, `botocore`, `PyYAML`, `jsonpatch`

**Optional but standard companions**

- AWS Load Balancer Controller chart from `https://aws.github.io/eks-charts` (for NLB external listeners)
- Monitoring: `prometheus-community` Helm repo (kube-prometheus-stack), Grafana images from docker.io; Strimzi’s examples folder has ready-made metrics configs and dashboards
- CLIs for pipelines: kubectl (dl.k8s.io), helm (get.helm.sh)

**Best practices for this stack**

1. Set up an **ECR pull-through cache** for quay.io so nodes never pull directly from the internet, and pin images by SHA digest.
1. Terraform owns infra + operator (EKS, VPC, gp3 StorageClass via EBS CSI addon, helm_release for Strimzi); Ansible owns day-2 config (KafkaTopic, KafkaUser, rebalances via kubernetes.core.k8s).
1. Use **KafkaNodePool** resources (required now), KRaft mode, 3 AZs with `rack` awareness on `topology.kubernetes.io/zone`, pod anti-affinity, and persistent-claim storage on gp3.
1. Deploy Drain Cleaner so node upgrades don’t violate min.insync.replicas, and Cruise Control for rebalancing.
1. Install CRDs before any Kafka CRs (separate Terraform apply stage or the crds YAML first) — and note the v1-only API if migrating from pre-1.0.

Want me to draft the actual Terraform module layout or the Ansible playbook structure next?