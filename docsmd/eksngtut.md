# Tutorial: Kafka (Strimzi 1.1.0) on an Existing EKS Cluster — Step by Step, Under the Hood

This tutorial walks the demo build from the companion guide, but explains **what each step actually does**: the Kubernetes/Kafka internals, the exact resources that appear or change in your AWS account, the **AWS CLI** way to do the same thing, the **AWS Console** click-path, and how to verify. It ends with the part everyone struggles with: **connecting to Kafka over the private network**.

**Every step follows the same template:**

> Goal → Internals (what really happens) → What changed in AWS → AWS CLI way → AWS Console way → Verify

Assumptions: existing EKS cluster named `demo` (v1.30+), three private subnets in three AZs, admin access to the cluster, region `eu-west-1`.

---

## The target architecture

```
                        AWS Account
┌───────────────────────────────────────────────────────────────┐
│  VPC (existing)                                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │
│  │ AZ-a private │  │ AZ-b private │  │ AZ-c private │  subnets │
│  │  node kafka-1│  │  node kafka-2│  │  node kafka-3│          │
│  │  ┌─────────┐ │  │  ┌─────────┐ │  │  ┌─────────┐ │          │
│  │  │Kafka pod│ │  │  │Kafka pod│ │  │  │Kafka pod│ │ dual-role│
│  │  │ +EBS gp3│ │  │  │ +EBS gp3│ │  │  │ +EBS gp3│ │ (ctrl+brk)│
│  │  └─────────┘ │  │  └─────────┘ │  │  └─────────┘ │          │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         └────────── internal NLBs (step 9) ─┘   ◄── VPN / EC2  │
│                                                    clients     │
│  EKS control plane (existing, untouched)                       │
│  ECR pull-through cache  ◄──────────── quay.io (first pull)    │
└───────────────────────────────────────────────────────────────┘
  strimzi ns: operator (Helm)      kafka ns: Kafka/KafkaNodePool CRs
```

---

## Step 0 — Pre-flight: read the existing cluster

**Goal:** confirm the cluster can host Strimzi 1.1.0 and that *you* can administer it, before creating anything.

**Internals:** two independent auth systems are in play. AWS IAM decides whether you may call the EKS API (`DescribeCluster`); Kubernetes RBAC — fed by **EKS access entries** (or the legacy `aws-auth` ConfigMap) — decides what your IAM identity may do *inside* the cluster. Terraform's `kubernetes`/`helm` providers use the second system, which is why a purely-AWS-admin identity can still get `Unauthorized` from Kubernetes.

**What changes in AWS:** nothing — read-only.

**AWS CLI way:**

```bash
aws eks describe-cluster --name demo \
  --query 'cluster.{version:version,endpoint:endpoint,vpc:resourcesVpcConfig.vpcId,subnets:resourcesVpcConfig.subnetIds}'
# version must be >= 1.30 (Strimzi 1.1.0 requirement)

aws eks list-access-entries --cluster-name demo          # is your role/user listed?
aws eks list-addons --cluster-name demo                  # is aws-ebs-csi-driver already there? (affects Step 3)

aws ec2 describe-subnets --subnet-ids subnet-aaa subnet-bbb subnet-ccc \
  --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock}'
# MUST show three DIFFERENT AvailabilityZone values
```

**AWS Console way:** EKS → Clusters → `demo` → **Overview** tab (Kubernetes version) → **Networking** tab (VPC + subnets, note the AZs) → **Access** tab (access entries — find your role) → **Add-ons** tab (check for EBS CSI).

**Verify (Kubernetes side):**

```bash
aws eks update-kubeconfig --name demo --region eu-west-1
kubectl auth can-i create namespace          # must print "yes"
kubectl get crd | grep strimzi.io            # must print NOTHING (else: CRD-ownership concern from the guide)
```

---

## Step 1 — Node IAM role (the identity your EC2 workers will wear)

**Goal:** an IAM role that lets EC2 instances join the cluster, manage pod networking, and pull images.

**Internals:** EC2 instances can't hold credentials directly — they assume a role through an **instance profile** (for managed node groups, EKS creates/uses the profile for you from the role you supply). On the node, the kubelet and the VPC CNI plugin sign AWS API calls with these credentials via the instance metadata service (IMDSv2). Three managed policies map to three jobs: `AmazonEKSWorkerNodePolicy` (describe cluster / register), `AmazonEKS_CNI_Policy` (allocate ENIs + secondary IPs for pods), `AmazonEC2ContainerRegistryReadOnly` (pull images). We add one **inline** policy because the pull-through cache in Step 4 needs two actions the managed policy lacks.

**What changes in AWS:**
- IAM → 1 role (`demo-kafka-nodes`) with a trust policy for `ec2.amazonaws.com`
- 3 managed policy attachments + 1 inline policy
- (At Step 2, EKS silently adds an instance profile wrapping this role)

**AWS CLI way:**

```bash
cat > trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "ec2.amazonaws.com" },
                  "Action": "sts:AssumeRole" }] }
EOF
aws iam create-role --role-name demo-kafka-nodes --assume-role-policy-document file://trust.json

for p in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
  aws iam attach-role-policy --role-name demo-kafka-nodes \
    --policy-arn arn:aws:iam::aws:policy/$p
done

cat > ptc.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Action": ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"],
                  "Resource": "arn:aws:ecr:eu-west-1:*:repository/quay/*" }] }
EOF
aws iam put-role-policy --role-name demo-kafka-nodes \
  --policy-name ecr-pull-through-cache --policy-document file://ptc.json
```

**AWS Console way:** IAM → Roles → **Create role** → Trusted entity: *AWS service* → Use case: **EC2** → Next → search and tick the three managed policies → Name `demo-kafka-nodes` → Create. Then open the role → Permissions → **Add permissions → Create inline policy** → JSON tab → paste the `ptc.json` statement → name `ecr-pull-through-cache`.

**Verify:** `aws iam list-attached-role-policies --role-name demo-kafka-nodes` shows 3; `aws iam list-role-policies` shows the inline one.

---

## Step 2 — The managed node group (compute appears)

**Goal:** three `m7i.large` nodes, one per AZ, labeled `workload=kafka`, attached to the existing cluster.

**Internals — what "create node group" really triggers:**
1. EKS creates a **launch template** on your behalf (AL2023 AMI, user data) and an **Auto Scaling Group** spanning your 3 subnets with min=max=desired=3. ASG's AZ-balancing places one instance per subnet → one per AZ.
2. Each instance boots AL2023; **`nodeadm`** reads the embedded `NodeConfig` (cluster name, API endpoint, CA, DNS IP) from user data and configures containerd + kubelet.
3. kubelet performs **TLS bootstrap** against the API server; because this is a *managed* group, EKS auto-creates an **access entry of type `EC2_LINUX`** for the node role — no `aws-auth` editing.
4. The node registers; DaemonSets (`aws-node` CNI, `kube-proxy`) schedule onto it; the CNI attaches extra **ENIs** and secondary IPs so future pods get real VPC IPs.
5. Your `workload=kafka` label is applied by kubelet at registration — it's how Step 6's nodeAffinity will find these nodes.

**What changes in AWS:**
- EKS: node group object + auto-created access entry
- EC2: 1 launch template, 1 Auto Scaling Group, **3 instances**, extra ENIs per instance, root EBS volumes
- The instances join the **cluster security group** automatically (broker↔broker and control-plane↔kubelet traffic just works)

**AWS CLI way:**

```bash
aws eks create-nodegroup \
  --cluster-name demo \
  --nodegroup-name kafka-demo \
  --node-role arn:aws:iam::<ACCOUNT_ID>:role/demo-kafka-nodes \
  --subnets subnet-aaa subnet-bbb subnet-ccc \
  --instance-types m7i.large \
  --ami-type AL2023_x86_64_STANDARD \
  --scaling-config minSize=3,maxSize=3,desiredSize=3 \
  --update-config maxUnavailable=1 \
  --labels workload=kafka

aws eks wait nodegroup-active --cluster-name demo --nodegroup-name kafka-demo   # blocks until ready
```

**AWS Console way:** EKS → Clusters → `demo` → **Compute** tab → **Add node group** → Name `kafka-demo`, select role `demo-kafka-nodes` → Next → AMI type *Amazon Linux 2023 (x86_64)*, instance type `m7i.large`, size 3/3/3 → Next → tick exactly your three private subnets → Next → (Kubernetes labels: add `workload=kafka`) → Create. Watch status on the Compute tab turn *Active*.

**Verify:**

```bash
kubectl get nodes -L workload,topology.kubernetes.io/zone
# 3 Ready nodes, label workload=kafka, three DIFFERENT zone values
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName,`kafka-demo`)].Instances[].AvailabilityZone'
```

---

## Step 3 — EBS CSI driver via Pod Identity (Kubernetes gets hands for EBS)

**Goal:** let a pod in the cluster create/attach/delete EBS volumes — the machinery behind every Kafka PVC.

**Internals — the Pod Identity credential flow (the modern replacement for IRSA):**
1. The **`eks-pod-identity-agent`** addon runs a DaemonSet listening on the link-local address `169.254.170.23` on every node.
2. You create an **association**: (namespace `kube-system`, ServiceAccount `ebs-csi-controller-sa`) ⇒ IAM role `demo-ebs-csi`. The role's trust policy names the principal `pods.eks.amazonaws.com` — static, no OIDC-provider lookups, which is exactly why it's the easy path on an *existing* cluster.
3. When the EBS CSI controller pod starts, EKS injects `AWS_CONTAINER_CREDENTIALS_FULL_URI` pointing at the agent; the AWS SDK inside the pod calls it, the agent exchanges the pod's projected ServiceAccount token via `eks-auth:AssumeRoleForPodIdentity`, and hands back temporary credentials scoped to `AmazonEBSCSIDriverPolicy`.
4. The **CSI split**: a *controller* Deployment (talks to the EC2 API: `CreateVolume`, `AttachVolume`) and a *node* DaemonSet (formats/mounts the disk on the host). Kubernetes' external-provisioner/attacher sidecars translate PVC events into those gRPC calls.

**What changes in AWS:**
- 2 EKS **add-ons** (`eks-pod-identity-agent`, `aws-ebs-csi-driver`)
- 1 IAM role (`demo-ebs-csi`) + `AmazonEBSCSIDriverPolicy` attachment
- 1 **Pod Identity association** object on the cluster
- (No volumes yet — that's Step 7)

**AWS CLI way:**

```bash
aws eks create-addon --cluster-name demo --addon-name eks-pod-identity-agent

cat > pi-trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "pods.eks.amazonaws.com" },
                  "Action": ["sts:AssumeRole", "sts:TagSession"] }] }
EOF
aws iam create-role --role-name demo-ebs-csi --assume-role-policy-document file://pi-trust.json
aws iam attach-role-policy --role-name demo-ebs-csi \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

aws eks create-pod-identity-association --cluster-name demo \
  --namespace kube-system --service-account ebs-csi-controller-sa \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/demo-ebs-csi

aws eks create-addon --cluster-name demo --addon-name aws-ebs-csi-driver
aws eks wait addon-active --cluster-name demo --addon-name aws-ebs-csi-driver
```

**AWS Console way:** EKS → `demo` → **Add-ons** → *Get more add-ons* → tick **EKS Pod Identity Agent** → install. Then EKS → `demo` → **Access** tab → *Pod Identity associations* → **Create** → namespace `kube-system`, SA `ebs-csi-controller-sa`, role `demo-ebs-csi` (the wizard can even create the role with the right trust for you). Finally Add-ons → *Get more add-ons* → **Amazon EBS CSI Driver** → install.

**Verify:**

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver   # controller + one node pod per node
kubectl -n kube-system get pods -l app.kubernetes.io/name=eks-pod-identity-agent
aws eks list-pod-identity-associations --cluster-name demo
```

---

## Step 4 — StorageClass + ECR pull-through cache (rules, not resources)

**Goal:** define *how* volumes get built (gp3/XFS/right AZ) and *where* images come from (inside AWS).

**Internals:**
- A **StorageClass is lazy** — creating it changes nothing in AWS. It's a recipe the CSI driver reads later. The key line is `volumeBindingMode: WaitForFirstConsumer`: the PVC stays `Pending` until the scheduler has placed the pod, then the volume is created **in that pod's AZ**. (With `Immediate`, EBS picks an AZ first and pods can deadlock in zones with no capacity.)
- A **pull-through cache rule is also lazy**. On the *first* pull of `<acct>.dkr.ecr.eu-west-1.amazonaws.com/quay/strimzi/kafka:1.1.0-kafka-4.3.0`, ECR checks the `quay/` prefix, fetches from `quay.io`, **auto-creates** a private repo `quay/strimzi/kafka`, stores the layers, and serves them. Later pulls never leave AWS; ECR keeps cached tags refreshed from upstream. This is why the node role needed `ecr:BatchImportUpstreamImage` + `ecr:CreateRepository`.

**What changes in AWS:** 1 ECR pull-through cache rule now; ECR repositories under `quay/…` appear *later, on first pull*. The StorageClass lives only in the cluster.

**AWS CLI way:**

```bash
aws ecr create-pull-through-cache-rule \
  --ecr-repository-prefix quay --upstream-registry-url quay.io

# StorageClass has no AWS CLI — it's a Kubernetes object:
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gp3-kafka }
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete            # demo; prod = Retain
parameters:
  type: gp3
  encrypted: "true"
  csi.storage.k8s.io/fstype: xfs
EOF
```

**AWS Console way:** ECR → **Private registry** → *Pull through cache* → **Add rule** → Registry: *Quay* → prefix `quay` → Save. (StorageClass: no console page — but you *can* watch the resulting PVCs/pods later under EKS → `demo` → **Resources** tab.)

**Verify:** `aws ecr describe-pull-through-cache-rules` · `kubectl get sc gp3-kafka -o yaml`.

---

## Step 5 — Install the Strimzi operator (teach the cluster the word "Kafka")

**Goal:** run the controller that will build and babysit Kafka clusters.

**Internals — what one `helm install` actually registers:**
1. **CRDs**: `kafkas`, `kafkanodepools`, `kafkatopics`, `kafkausers`, `kafkarebalances`, … — new REST endpoints in the API server (`/apis/kafka.strimzi.io/v1/...`). From Strimzi 1.0.0 these serve **v1 only**.
2. **RBAC**: ClusterRoles + RoleBindings scoped so the operator may act in the `kafka` namespace (because we set `watchNamespaces=[kafka]` — least privilege).
3. **Deployment** `strimzi-cluster-operator` (1 replica) in `strimzi`. It opens **watch** connections (informers) on the CRDs and on the Secrets/ConfigMaps/Pods it owns, and runs a reconcile loop: *observe → diff desired vs actual → act*. Nothing else happens until a `Kafka` CR exists.

**What changes in AWS:** nothing directly. Indirectly: the operator image pull creates the first `quay/strimzi/operator` cached repo in ECR (if you pointed the chart's image registry at the cache).

**CLI way (no AWS CLI here — Helm *is* the CLI):**

```bash
helm install strimzi-cluster-operator \
  oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --version 1.1.0 --namespace strimzi --create-namespace \
  --set watchNamespaces={kafka}
kubectl create namespace kafka
```

**Console way:** none for Helm/CRDs. Observability substitute: EKS → `demo` → **Resources** → Deployments (namespace `strimzi`) to see the operator pod; CloudWatch → Log groups if you've enabled container logging.

**Verify:**

```bash
kubectl -n strimzi get deploy strimzi-cluster-operator      # READY 1/1
kubectl get crd | grep kafka.strimzi.io                     # ~10 CRDs
kubectl api-resources --api-group=kafka.strimzi.io          # confirms v1 endpoints
```

---

## Step 6 — Apply the Kafka CRs (the interesting part)

**Goal:** hand the operator two documents — a `KafkaNodePool` (3 dual-role nodes) and a `Kafka` (cluster config) — and watch a full Kafka cluster materialize.

**Internals — the reconcile cascade, in order:**
1. Operator sees the `Kafka` CR appear (watch event), validates it against the linked node pool (`strimzi.io/cluster` label).
2. **PKI first**: it generates two CAs as Secrets — `demo-cluster-ca-cert` (server side) and `demo-clients-ca-cert` — then per-node certificates with SANs for every internal DNS name a client might use.
3. **Per-node config**: one ConfigMap per Kafka node containing its rendered `server.properties` (node ID, roles, listeners, rack from the zone label).
4. **StrimziPodSets, not StatefulSets**: Strimzi runs its own pod controller so it can restart/replace *individual* brokers in a safe order (StatefulSets can't). Pods `demo-dual-role-0/1/2` are created with your affinity rules → one per node → one per AZ.
5. **Storage chain fires**: each pod's PVC (from the node pool `storage` block) binds via `WaitForFirstConsumer` → CSI controller calls EC2 **`CreateVolume`** in that pod's AZ with `type=gp3, encrypted` → **`AttachVolume`** to the node → node plugin formats **XFS** and mounts it at `/var/lib/kafka`.
6. **KRaft bootstrap**: the three controllers (same pods, dual role) form a **Raft quorum** over the replicated `__cluster_metadata` log, elect a leader, brokers register with the quorum, and partitions/ISR state now live in Raft — no ZooKeeper anywhere.
7. **Services**: `demo-kafka-bootstrap` (ClusterIP clients dial first) and `demo-kafka-brokers` (headless; gives each broker a stable DNS name — these names are what brokers *advertise*, which matters enormously in Step 9).
8. **Entity Operator** pod starts; its Topic Operator watches `KafkaTopic` CRs and creates `demo-events` via the Admin API.
9. Operator flips the CR's status condition `Ready=True` — the exact thing the Ansible `wait_condition` gates on.

**What changes in AWS:**
- EC2/EBS: **3 gp3 volumes** (20 GiB, encrypted), one per AZ, attached to the nodes; tagged `kubernetes.io/created-for/pvc/name=data-0-demo-dual-role-N` and `CSIVolumeName=pvc-…` (that's how you find them)
- ECR: `quay/strimzi/kafka` repo appears on first pull

**CLI way:** it's the Ansible playbook from the guide (`ansible-playbook site.yml`); raw equivalent is `kubectl apply -f` on the two rendered YAMLs. **AWS CLI is for observing the side effects:**

```bash
aws ec2 describe-volumes \
  --filters Name=tag:kubernetes.io/cluster/demo,Values=owned Name=tag-key,Values=CSIVolumeName \
  --query 'Volumes[].{az:AvailabilityZone,size:Size,type:VolumeType,state:State,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}'
```

**Console way:** EC2 → **Volumes** → filter tag `kubernetes.io/cluster/demo` → see three 20 GiB gp3 volumes in three AZs, state *in-use*. EKS → `demo` → **Resources** → Pods (namespace `kafka`) to watch the pods come up.

**Verify:**

```bash
kubectl -n kafka get kafka demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'   # True
kubectl -n kafka get pods -o wide -l strimzi.io/cluster=demo        # 3 kafka pods on 3 nodes + entity-operator
kubectl -n kafka get kafkanodepool dual-role -o jsonpath='{.status.nodeIds}'   # e.g. [0,1,2] — needed in Step 9
kubectl -n kafka exec demo-dual-role-0 -- \
  ./bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status   # KRaft leader + followers
```

---

## Step 7 — First produce/consume (inside the cluster)

**Goal:** prove the data path with zero networking complexity.

**Internals:** the console producer dials `demo-kafka-bootstrap:9092` (ClusterIP). Any broker answers the **Metadata** request with the full broker list *as advertised addresses* — here, the headless per-broker DNS names — and the client then opens direct connections to each partition leader. **Remember this two-phase dance; it is the whole story of Step 9.**

```bash
kubectl -n kafka run producer -it --rm \
  --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-console-producer.sh --bootstrap-server demo-kafka-bootstrap:9092 --topic demo-events
# type a few lines, Ctrl-C

kubectl -n kafka run consumer -it --rm \
  --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server demo-kafka-bootstrap:9092 \
  --topic demo-events --from-beginning
```

---

# Step 8 — Connecting to Kafka on the PRIVATE network

## 8.0 The concept that breaks everyone: advertised listeners

Kafka is not HTTP. A client uses your bootstrap address **once**, receives the cluster metadata, and from then on connects to **each broker's advertised address directly** (partition leaders live on specific brokers). Consequences:

- One tunnel/proxy to the bootstrap **cannot** work: the client will next try `demo-dual-role-1.demo-kafka-brokers…:9092`, which your laptop can't resolve or reach. This is why naive `kubectl port-forward` or a single SSM tunnel fails mid-handshake.
- Any "from outside the pod network" access needs **a routable address per broker** — which is exactly what a Strimzi `type: loadbalancer` listener provides: **one internal NLB per broker + one for bootstrap**, with the NLB DNS names pushed into each broker's `advertised.listeners` *and its TLS certificate SANs* by the operator.

## 8.1 Add an internal-NLB listener

Add a third listener to the `Kafka` CR (or set `external_listener_enabled`-style vars in the Ansible template) and re-apply:

```yaml
      - name: privnlb
        port: 9094
        type: loadbalancer                 # Strimzi creates Service type=LoadBalancer per broker + bootstrap
        tls: true                          # private ≠ trusted: keep TLS on
        configuration:
          bootstrap:
            annotations: &nlb
              service.beta.kubernetes.io/aws-load-balancer-type: "nlb"       # legacy CCM path → NLB
              service.beta.kubernetes.io/aws-load-balancer-internal: "true"  # PRIVATE: no public IPs
          brokers:                         # per-broker Services need the same annotations
            - broker: 0
              annotations: *nlb
            - broker: 1
              annotations: *nlb
            - broker: 2
              annotations: *nlb            # broker IDs from Step 6's `.status.nodeIds`
```

**Internals:** each `Service type=LoadBalancer` is picked up by the **AWS cloud controller** (these legacy annotations work with no extra controller installed): it provisions an **internal NLB**, registers the *instances* as targets on an auto-assigned **NodePort**, and health-checks it. `kube-proxy` routes NLB→NodePort→the one broker pod. Strimzi then reads each hostname from Service status, sets it as that broker's `advertised.listeners` for port 9094, re-issues broker certs including the NLB names as SANs, and performs a rolling restart. If you standardized on the **AWS Load Balancer Controller** instead, swap the annotations for `aws-load-balancer-type: "external"` + `nlb-target-type: ip` + `scheme: internal` — NLB targets pods directly, one hop fewer.

**What changes in AWS:** **4 internal NLBs** (bootstrap + 3 brokers), 4 target groups, listeners on 9094, health checks. Security-group-wise, traffic arrives at the nodes' NodePorts — the cluster security group must allow the *client's* source (see 8.5).

**AWS CLI way (inspect):**

```bash
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?Scheme==`internal`].{name:LoadBalancerName,dns:DNSName,state:State.Code}'
aws elbv2 describe-target-health --target-group-arn <tg-arn>    # targets must be "healthy"
```

**Console way:** EC2 → **Load balancers** → four new NLBs, Scheme *internal* → Target groups tab → health status. (Creation itself has no console path — it's driven by the Kubernetes Services.)

**Get the client-facing bootstrap address:**

```bash
kubectl -n kafka get kafka demo \
  -o jsonpath='{.status.listeners[?(@.name=="privnlb")].bootstrapServers}'
# e.g. internal-a1b2…elb.eu-west-1.amazonaws.com:9094
```

## 8.2 TLS material for clients (one command)

Strimzi signed the listener with its own CA, so clients need that CA cert — nothing else (no client certs; demo has no mTLS):

```bash
kubectl -n kafka get secret demo-cluster-ca-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
```

`client.properties` (Kafka ≥2.7 accepts a PEM truststore directly — no keytool):

```properties
security.protocol=SSL
ssl.truststore.type=PEM
ssl.truststore.location=/home/ec2-user/ca.crt
```

## 8.3 From an EC2 host in the same VPC (the reliable baseline)

**Internals:** an internal NLB's DNS name resolves (even from the public internet) to **private IPs** — but only VPC-internal (or VPN-connected) sources can *route* to them. A small EC2 box in any private subnet is therefore the canonical Kafka client seat. Reach its shell with **SSM Session Manager** (no SSH keys, no inbound ports — the instance's SSM agent dials *out*).

```bash
# a) tiny client host (reuses the node role for simplicity — it already has SSM? No: add it)
aws iam attach-role-policy --role-name demo-kafka-nodes \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.micro --subnet-id subnet-aaa \
  --iam-instance-profile Name=<instance-profile-of-demo-kafka-nodes> \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=kafka-client}]'

# b) open a shell on it (Console: EC2 → instance → Connect → Session Manager)
aws ssm start-session --target i-0abc123

# c) on the host: Java + Kafka CLI, then produce/consume over TLS
sudo dnf install -y java-17-amazon-corretto
curl -sLO https://downloads.apache.org/kafka/4.3.0/kafka_2.13-4.3.0.tgz && tar xzf kafka_2.13-4.3.0.tgz
BOOTSTRAP=<value from 8.1>
kafka_2.13-4.3.0/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP \
  --command-config client.properties --list
kafka_2.13-4.3.0/bin/kafka-console-producer.sh --bootstrap-server $BOOTSTRAP \
  --producer.config client.properties --topic demo-events
```

*(Prod hygiene: give the client its own minimal role instead of borrowing the node role; the borrow keeps the demo to one IAM object.)*

## 8.4 From your laptop: AWS Client VPN (the "it just works" path)

**Internals:** Client VPN is a managed OpenVPN endpoint. Once connected, your laptop gets an IP from the VPN CIDR, routes into the VPC, and — because internal-NLB DNS resolves publicly to private IPs — the *same* bootstrap string and `ca.crt` from 8.1/8.2 work unchanged. Every per-broker NLB is reachable, so the advertised-listeners dance completes normally.

**AWS CLI recipe (condensed but complete):**

```bash
# 1) server + client certs (easy-rsa), import server cert
aws acm import-certificate --certificate fileb://server.crt \
  --private-key fileb://server.key --certificate-chain fileb://ca.crt   # note the returned ARN

# 2) endpoint (mutual-cert auth; split-tunnel so only VPC traffic uses the VPN)
aws ec2 create-client-vpn-endpoint \
  --client-cidr-block 172.16.0.0/22 \
  --server-certificate-arn <acm-arn> \
  --authentication-options Type=certificate-authentication,MutualAuthentication={ClientRootCertificateChainArn=<acm-arn>} \
  --connection-log-options Enabled=false \
  --vpc-id vpc-xxxx --security-group-ids sg-cluster \
  --split-tunnel

# 3) attach to a subnet, authorize, (route auto-added for the subnet's VPC)
aws ec2 associate-client-vpn-target-network --client-vpn-endpoint-id cvpn-… --subnet-id subnet-aaa
aws ec2 authorize-client-vpn-ingress --client-vpn-endpoint-id cvpn-… \
  --target-network-cidr 10.0.0.0/16 --authorize-all-groups

# 4) download the .ovpn profile, append client cert+key, open in AWS VPN Client
aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id cvpn-… --output text > demo.ovpn
```

**Console way:** VPC → **Client VPN endpoints** → Create (same fields as above) → *Target network associations* tab → Associate → *Authorization rules* tab → Add `10.0.0.0/16` → **Download client configuration** button → connect with the AWS Client VPN app. Then run the exact 8.3 client commands from your laptop.

## 8.5 Security-group checklist + what does NOT work

```bash
# Allow client sources to reach the brokers' NodePorts behind the NLBs
# (simplest correct demo rule: allow VPC + VPN CIDRs to the cluster SG on the NodePort range)
aws ec2 authorize-security-group-ingress --group-id sg-cluster \
  --protocol tcp --port 30000-32767 --cidr 10.0.0.0/16
aws ec2 authorize-security-group-ingress --group-id sg-cluster \
  --protocol tcp --port 30000-32767 --cidr 172.16.0.0/22        # the Client VPN CIDR
```

*(Console: EC2 → Security groups → cluster SG → Inbound rules → Edit. Tighten the port range in prod by pinning NodePorts or using LB-Controller `ip` targets + SG rules on 9094.)*

**Explicitly not viable, and why:**
- `kubectl port-forward svc/demo-kafka-bootstrap 9092` — metadata succeeds, then the client dials in-cluster broker DNS and dies (8.0).
- A single SSM **port-forwarding** tunnel to the bootstrap NLB — same failure; per-broker tunnels + `/etc/hosts` spoofing of every advertised name can work but is a party trick, not a workflow. Use SSM to get a *shell* (8.3), not a tunnel.

---

## Step 9 — Teardown reminder

Order matters (data pods first, infra last): `kubectl -n kafka delete kafkatopic --all` → `kubectl -n kafka delete kafka demo --wait` (operator deletes pods; `deleteClaim: true` + `Delete` reclaim removes the EBS volumes) → delete the extra NLB Services go with it automatically → `helm uninstall` / `terraform destroy` → delete the Client VPN endpoint and client EC2 host if you made them. Verify in the console that **EC2 → Volumes** and **Load balancers** are empty of `demo` leftovers — orphaned NLBs and EBS volumes are the classic silent demo bill.

---

## Recap: what exists in AWS when you're done (before teardown)

| AWS service | Resources | Created by |
|---|---|---|
| IAM | `demo-kafka-nodes` (+3 managed, 1 inline), `demo-ebs-csi` | Steps 1, 3 |
| EC2 | launch template, ASG, 3 × m7i.large, ENIs | Step 2 |
| EKS | node group, access entry, 2 add-ons, pod-identity association | Steps 2–3 |
| ECR | pull-through rule + auto-created `quay/strimzi/*` repos | Steps 4–5 |
| EBS | 3 × 20 GiB gp3 encrypted volumes (one per AZ) | Step 6 |
| ELB | 4 internal NLBs + target groups | Step 8.1 |
| VPC | Client VPN endpoint + association (optional) | Step 8.4 |

Everything Kubernetes-side (operator, CRDs, pods, services, secrets, topics) lives *inside* the cluster and shows up in AWS only as the compute, disks, and load balancers above.
