For this design, think of **high availability** as “the application keeps working when one server breaks,” and **fault tolerance** as “we have enough copies in different places that one failure does not destroy the service.” On EKS, the most important rule is: **do not put all copies on one worker node or in one Availability Zone.** AWS recommends multiple replicas, Pod Disruption Budgets, and spreading pods across nodes and Availability Zones. ([AWS Documentation][1])

# 1. First: everything you need

* **One EKS cluster** with the Kubernetes API using private access.
* **Three AWS Availability Zones**, such as AZ-A, AZ-B, and AZ-C.
* **Three private subnets**, one in each AZ, for EKS worker nodes.
* Optional **public subnets** if Internet-facing ALBs are required; otherwise use internal load balancers.
* **Managed EKS node groups** so AWS can help replace and upgrade worker nodes.
* A small **system/general node group** for CoreDNS, controllers, web applications, monitoring, and operators.
* A dedicated **Kafka node group** using On-Demand EC2.
* A dedicated **NiFi node group** using On-Demand EC2.
* A dedicated **OpenSearch node group** using On-Demand EC2.
* **EBS CSI Driver** for persistent disks.
* **gp3 encrypted EBS StorageClass** with `WaitForFirstConsumer`.
* **AWS Load Balancer Controller** for ALB/NLB.
* **EKS Pod Identity** for applications that need AWS permissions.
* **CoreDNS**, `kube-proxy`, VPC CNI, Pod Identity Agent, and EBS CSI as managed EKS add-ons where practical.
* **Three or more replicas** for important applications.
* **PodDisruptionBudgets** so upgrades do not kill too many pods at once.
* **Topology spread constraints** so replicas land in different AZs and on different nodes.
* **Readiness, liveness, and startup probes**.
* **Resource requests and limits** so Kubernetes knows how much CPU and memory each application needs.
* **Kafka through Strimzi**, preferably Kafka KRaft rather than adding ZooKeeper just for Kafka.
* **Kafka replication factor 3** and usually `min.insync.replicas=2`.
* **Kafka UI** as an optional internal administration tool.
* **NiFi StatefulSet with three NiFi nodes**.
* **Three ZooKeeper nodes for NiFi**, because NiFi clustering still uses ZooKeeper for cluster coordination/state.
* **OpenSearch with three cluster-manager nodes** in separate AZs, plus data nodes.
* **OpenSearch Dashboards with at least two replicas**.
* **Web front end with at least three replicas**, HPA, PDB, and rolling updates.
* **S3 backups/snapshots** where appropriate.
* **CloudWatch/Prometheus/Grafana/OpenSearch monitoring**.
* **Central logs and alerts**.
* **EKS Access Entries/RBAC** instead of giving everybody cluster-admin.
* **Secrets** for passwords, certificates, Kafka credentials, NiFi credentials, and OpenSearch credentials.
* **Internal DNS and TLS certificates**.
* **Git repository** containing Kubernetes YAML, Helm values, scripts, versions, and upgrade notes.
* For offline operation: **internal Artifactory/ECR**, local Helm packages, copied container images, checksums, SBOMs, and a controlled transfer process.
* A **connected staging cluster** where you install everything first and discover every container image before moving the release into the disconnected network.

AWS requires at least two EKS subnets in different AZs, but three AZs is a better production target. AWS also recommends managed node groups and workload spreading for easier maintenance and availability. ([AWS Documentation][2])

---

# 2. Simple architecture

Think of your system like this:

```text
                         Corporate Users
                               |
                        Internal DNS / TLS
                               |
                      Internal ALB / NLB
                               |
                 +-------------+-------------+
                 |                           |
             Web Frontend                 NiFi UI
              3+ Pods                    3 NiFi Pods
                 |                           |
                 |                      ZooKeeper x3
                 |                           |
                 +-------------+-------------+
                               |
                     Kubernetes Services
                               |
          +--------------------+--------------------+
          |                                         |
       Kafka                                      Search
      Strimzi                                  OpenSearch
   3 Controllers                            3 Managers
   3 Brokers                                3+ Data Nodes
          |                                         |
          +--------------------+--------------------+
                               |
                         EBS gp3 Volumes
                               |
                       Snapshots / S3 Backup


     AZ-A                     AZ-B                     AZ-C
+-------------+          +-------------+          +-------------+
| Worker Node |          | Worker Node |          | Worker Node |
| Kafka 1     |          | Kafka 2     |          | Kafka 3     |
| NiFi 1      |          | NiFi 2      |          | NiFi 3      |
| Search 1    |          | Search 2    |          | Search 3    |
| Web 1       |          | Web 2       |          | Web 3       |
+-------------+          +-------------+          +-------------+
```

The important part is that **Kafka-1, Kafka-2, and Kafka-3 must not all be on the same EC2 machine or in the same AZ**. Kubernetes topology spread constraints were specifically designed to spread pods across failure domains such as nodes and zones. ([Kubernetes][3])

---

# 3. EKS foundation

I recommend **EKS Managed Node Groups** for this design rather than starting with self-managed EC2 workers. Managed node groups make node replacement and version upgrades easier. The Kubernetes control plane and worker nodes are upgraded separately, which is actually useful because it lets you upgrade one layer at a time. ([AWS Documentation][4])

Use variables so the commands are easy to understand:

```bash
export AWS_REGION=us-east-1
export CLUSTER=data-platform-prod

export K8S_VERSION="<your-approved-EKS-version>"

export VPC_ID=vpc-xxxxxxxx
export PRIVATE_A=subnet-aaaaaaaa
export PRIVATE_B=subnet-bbbbbbbb
export PRIVATE_C=subnet-cccccccc

export CLUSTER_SG=sg-xxxxxxxx
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

Do not blindly copy a Kubernetes version from a tutorial. Ask AWS which versions are currently supported:

```bash
aws eks describe-cluster-versions
```

AWS provides this command specifically for discovering the EKS versions currently available. ([AWS Documentation][5])

## Create the EKS cluster IAM role

Create:

```bash
cat > eks-cluster-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

Then:

```bash
aws iam create-role \
  --role-name DataPlatformEKSClusterRole \
  --assume-role-policy-document file://eks-cluster-trust.json

aws iam attach-role-policy \
  --role-name DataPlatformEKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

Get its ARN:

```bash
export CLUSTER_ROLE_ARN=$(
  aws iam get-role \
    --role-name DataPlatformEKSClusterRole \
    --query 'Role.Arn' \
    --output text
)
```

## Create EKS

For a private production cluster:

```bash
aws eks create-cluster \
  --name "$CLUSTER" \
  --region "$AWS_REGION" \
  --kubernetes-version "$K8S_VERSION" \
  --role-arn "$CLUSTER_ROLE_ARN" \
  --resources-vpc-config \
"subnetIds=$PRIVATE_A,$PRIVATE_B,$PRIVATE_C,securityGroupIds=$CLUSTER_SG,endpointPrivateAccess=true,endpointPublicAccess=false"
```

Wait for AWS:

```bash
aws eks wait cluster-active \
  --name "$CLUSTER" \
  --region "$AWS_REGION"
```

Then configure `kubectl`:

```bash
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$CLUSTER"

kubectl get nodes
kubectl get namespaces
```

AWS documents `aws eks update-kubeconfig` as the normal way to connect `kubectl` to EKS. ([AWS Documentation][6])

Because the API endpoint is private, this command must run from somewhere that can reach the VPC—for example an SSM administration EC2 instance, corporate network connected through Direct Connect/VPN, or another approved management system.

---

# 4. Worker node IAM role

Create the EC2 trust policy:

```bash
cat > node-trust.json <<'EOF'
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect":"Allow",
      "Principal":{
        "Service":"ec2.amazonaws.com"
      },
      "Action":"sts:AssumeRole"
    }
  ]
}
EOF
```

Create the role:

```bash
aws iam create-role \
  --role-name DataPlatformEKSNodeRole \
  --assume-role-policy-document file://node-trust.json
```

Attach the basic policies:

```bash
aws iam attach-role-policy \
  --role-name DataPlatformEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
  --role-name DataPlatformEKSNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
```

Those are the current AWS-recommended baseline managed policies for an EKS node role. AWS recommends giving VPC CNI its own workload identity rather than piling its permissions onto every worker node. ([AWS Documentation][7])

Get the ARN:

```bash
export NODE_ROLE_ARN=$(
  aws iam get-role \
    --role-name DataPlatformEKSNodeRole \
    --query 'Role.Arn' \
    --output text
)
```

---

# 5. Separate your node groups

Do not make one giant pile of EC2 servers.

For example:

```text
system-web
    controllers
    CoreDNS
    Kafka operator
    web frontend
    Kafka UI
    OpenSearch Dashboards

kafka
    Kafka controllers
    Kafka brokers

nifi
    NiFi
    ZooKeeper for NiFi

search
    OpenSearch managers
    OpenSearch data
```

A general node group might look like:

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name system-web \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$PRIVATE_A" "$PRIVATE_B" "$PRIVATE_C" \
  --instance-types m7i.large \
  --capacity-type ON_DEMAND \
  --scaling-config minSize=3,maxSize=8,desiredSize=3 \
  --labels workload=general
```

For Kafka:

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name kafka \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$PRIVATE_A" "$PRIVATE_B" "$PRIVATE_C" \
  --instance-types m7i.xlarge \
  --capacity-type ON_DEMAND \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --labels workload=kafka \
  --taints key=workload,value=kafka,effect=NO_SCHEDULE
```

Repeat the pattern for NiFi and OpenSearch.

The taint is basically a sign saying:

> “Do not put ordinary applications here.”

Kafka pods receive a matching toleration saying:

> “I am allowed onto Kafka machines.”

For important persistent applications, I prefer **On-Demand** nodes. Spot is excellent for disposable/stateless workloads, but AWS Spot capacity can be reclaimed, making stateful Kafka/NiFi/OpenSearch operation more complicated.

---

# 6. Storage

Install the EBS CSI driver as an EKS add-on. AWS recommends the EKS add-on version because AWS can manage its lifecycle more easily. ([AWS Documentation][8])

I would create this StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
provisioner: ebs.csi.aws.com

volumeBindingMode: WaitForFirstConsumer

allowVolumeExpansion: true

parameters:
  type: gp3
  encrypted: "true"
```

Apply it:

```bash
kubectl apply -f gp3-storageclass.yaml
```

`WaitForFirstConsumer` is important.

It means Kubernetes waits to see:

```text
Which AZ did Kafka-1 land in?
```

Then it creates that pod's EBS disk in the same AZ.

Remember that an EBS volume belongs to an AZ. This is why **application replication across AZs** is critical. A disk in AZ-A cannot magically become the live disk for a pod running in AZ-C.

---

# 7. The Kubernetes HA pattern

Almost every application should use this basic idea:

```yaml
replicas: 3

topologySpreadConstraints:

  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: my-app

  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: my-app
```

The first rule says:

```text
Spread across Availability Zones.
```

The second says:

```text
Spread across EC2 worker machines.
```

Now protect it with a PodDisruptionBudget:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2

  selector:
    matchLabels:
      app: my-app
```

So if three copies exist:

```text
app-1
app-2
app-3
```

Kubernetes cannot voluntarily shut all three down during maintenance.

PDBs are specifically intended to limit simultaneous voluntary disruptions during operations such as node drains and upgrades. ([Kubernetes][9])

---

# 8. Kafka: use Strimzi

For Kafka on Kubernetes, I recommend **Strimzi**.

Strimzi installs an operator. An operator is like a robot administrator that understands Kafka.

Instead of manually creating Kafka StatefulSets, services, configuration and upgrades, you tell Strimzi:

```text
I want a Kafka cluster.
I want 3 controllers.
I want 3 brokers.
I want persistent disks.
```

Strimzi creates and manages the Kubernetes pieces. The current stable Strimzi release listed by the project is 1.1.0, and its official release bundle includes YAML, CRDs and a Helm package. ([Strimzi][10])

Current Strimzi uses Kafka's **KRaft** architecture, so Kafka itself no longer needs ZooKeeper. KRaft separates controller responsibilities from broker responsibilities and reduces operational complexity. ([Strimzi][11])

## Production layout

I would use:

```text
Kafka Controller 1 -> AZ-A
Kafka Controller 2 -> AZ-B
Kafka Controller 3 -> AZ-C

Kafka Broker 1     -> AZ-A
Kafka Broker 2     -> AZ-B
Kafka Broker 3     -> AZ-C
```

For a smaller environment, three Kafka pods can perform both the controller and broker roles.

## Install Strimzi

Online example:

```bash
kubectl create namespace kafka
```

Using the downloaded Helm package:

```bash
helm upgrade --install strimzi \
  ./strimzi-kafka-operator-1.1.0.tgz \
  --namespace kafka
```

Check:

```bash
kubectl get pods -n kafka
kubectl get crds | grep strimzi
```

Current Strimzi 1.x CRDs use `kafka.strimzi.io/v1`; the project dropped the older beta API versions starting with Strimzi 1.0. ([GitHub][12])

## Example Kafka controller pool

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: controllers

  labels:
    strimzi.io/cluster: production-kafka

spec:
  replicas: 3

  roles:
    - controller

  storage:
    type: persistent-claim
    size: 20Gi
    class: gp3-encrypted
    deleteClaim: false
```

## Example broker pool

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: brokers

  labels:
    strimzi.io/cluster: production-kafka

spec:
  replicas: 3

  roles:
    - broker

  storage:
    type: persistent-claim
    size: 200Gi
    class: gp3-encrypted
    deleteClaim: false
```

Then your Kafka resource can contain settings such as:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: production-kafka

spec:
  kafka:

    config:

      default.replication.factor: 3

      min.insync.replicas: 2

      offsets.topic.replication.factor: 3

      transaction.state.log.replication.factor: 3

      transaction.state.log.min.isr: 2
```

The simple idea is:

```text
Replication factor 3

Message:
    Copy 1 -> Broker A
    Copy 2 -> Broker B
    Copy 3 -> Broker C
```

If Broker B disappears, copies still exist.

Strimzi also provides Cruise Control support for Kafka rebalancing and Drain Cleaner support for safer node drains. Drain Cleaner is particularly useful during EKS node maintenance because it coordinates Kafka pod eviction rather than treating a Kafka broker like an ordinary disposable web pod. ([Strimzi][13])

---

# 9. Kafka UI

Kafka UI is optional but very helpful for administrators.

It lets you look at:

```text
Brokers
Topics
Partitions
Consumer groups
Consumer lag
Messages
Configuration
```

The Provectus Kafka UI project provides a Helm chart and supports configuring Kafka bootstrap servers through Helm values. ([GitHub][14])

Example:

```yaml
yamlApplicationConfig:

  kafka:

    clusters:

      - name: Production

        bootstrapServers:
          production-kafka-kafka-bootstrap.kafka.svc:9092
```

Install from your copied chart:

```bash
helm upgrade --install kafka-ui \
  ./kafka-ui-APPROVED_VERSION.tgz \
  --namespace kafka \
  -f kafka-ui-values.yaml
```

Keep Kafka UI **internal**. Do not expose an unauthenticated Kafka administration screen to the Internet.

---

# 10. NiFi on EKS

NiFi is different from Kafka.

I recommend building a **small internal NiFi Helm chart** rather than depending heavily on a random external NiFi chart.

Your internal chart contains:

```text
StatefulSet
Services
PVC templates
ConfigMaps
Secrets
PDB
Topology rules
Ingress
NiFi configuration
```

For a new deployment, Apache currently lists NiFi **2.11.0**, released August 3, 2026. Apache says NiFi 1.28 was the final 1.x minor series and lists 1.28.1 as end-of-support, recommending migration to NiFi 2. ([Apache NiFi][15])

## NiFi layout

Use:

```text
nifi-0     AZ-A
nifi-1     AZ-B
nifi-2     AZ-C

zookeeper-0    AZ-A
zookeeper-1    AZ-B
zookeeper-2    AZ-C
```

NiFi still uses ZooKeeper for cluster state and coordination. Apache recommends an odd-sized ZooKeeper ensemble such as three or five nodes; three is the normal small production choice. ([Apache NiFi][16])

## NiFi persistent storage

Each NiFi pod can have separate PVCs for:

```text
flowfile_repository
content_repository
provenance_repository
database_repository
state
logs if required
```

Example:

```text
nifi-0
   |
   +-- EBS volume A

nifi-1
   |
   +-- EBS volume B

nifi-2
   |
   +-- EBS volume C
```

Do not treat these as one shared disk.

## Important `nifi.properties`

The generated configuration will contain values similar to:

```properties
nifi.cluster.is.node=true

nifi.cluster.node.protocol.port=11443

nifi.cluster.node.load.balance.port=6342

nifi.zookeeper.connect.string=\
zookeeper-0.zookeeper-headless.nifi.svc.cluster.local:2181,\
zookeeper-1.zookeeper-headless.nifi.svc.cluster.local:2181,\
zookeeper-2.zookeeper-headless.nifi.svc.cluster.local:2181

nifi.web.https.port=8443

nifi.web.proxy.host=nifi.internal.example.com
```

Each pod also needs its own stable hostname:

```text
nifi-0.nifi-headless.nifi.svc.cluster.local
nifi-1.nifi-headless.nifi.svc.cluster.local
nifi-2.nifi-headless.nifi.svc.cluster.local
```

This is one reason a Kubernetes `StatefulSet` is useful: `nifi-0` remains `nifi-0` after a restart.

Apache's NiFi administration guide documents the cluster protocol port, load-balancing port, ZooKeeper connection string, cluster state provider, heartbeat behavior and cluster coordinator election. ([Apache NiFi][16])

---

# 11. Web Frontend

The web frontend is the easiest application because it should normally be **stateless**.

For example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend

spec:
  replicas: 3

  strategy:
    type: RollingUpdate

    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1

  selector:
    matchLabels:
      app: frontend

  template:

    metadata:
      labels:
        app: frontend

    spec:

      topologySpreadConstraints:

        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule

          labelSelector:
            matchLabels:
              app: frontend

      containers:

        - name: frontend

          image: artifactory.corp.local/apps/frontend:1.0.0

          ports:
            - containerPort: 8080

          readinessProbe:
            httpGet:
              path: /health
              port: 8080

          livenessProbe:
            httpGet:
              path: /health
              port: 8080

          resources:

            requests:
              cpu: 100m
              memory: 128Mi

            limits:
              cpu: 500m
              memory: 512Mi
```

Rolling updates gradually replace pods so the application can remain available rather than stopping the whole deployment first. ([Kubernetes][17])

Add:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget

metadata:
  name: frontend-pdb

spec:
  minAvailable: 2

  selector:
    matchLabels:
      app: frontend
```

Then use an internal ALB in front of it.

---

# 12. AWS Load Balancer Controller

AWS recommends Helm for installing the AWS Load Balancer Controller. Current AWS documentation uses controller release `v2.14.1` and Helm chart `1.14.0`; pin the exact version you approve rather than using `latest`. ([AWS Documentation][18])

Online staging machine:

```bash
helm repo add eks https://aws.github.io/eks-charts

helm repo update eks

helm pull eks/aws-load-balancer-controller \
  --version 1.14.0 \
  --destination ./offline/charts
```

Offline:

```bash
helm upgrade --install aws-load-balancer-controller \
  ./offline/charts/aws-load-balancer-controller-1.14.0.tgz \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

One important upgrade detail: AWS notes that `helm install` installs the Load Balancer Controller CRDs, but a later `helm upgrade` does **not automatically upgrade those CRDs**. Treat CRD upgrades as a separate controlled step. ([AWS Documentation][18])

---

# 13. OpenSearch

For real production HA, OpenSearch recommends **three dedicated cluster-manager nodes in three different zones**. ([OpenSearch Documentation][19])

A stronger setup is:

```text
Manager 1 -> AZ-A
Manager 2 -> AZ-B
Manager 3 -> AZ-C

Data 1 -> AZ-A
Data 2 -> AZ-B
Data 3 -> AZ-C

Dashboards 1
Dashboards 2
```

For a small environment, three combined manager/data nodes can save money, but separating the roles gives better isolation.

The OpenSearch project maintains Kubernetes Helm charts for OpenSearch and OpenSearch Dashboards. ([GitHub][20])

Online staging:

```bash
helm repo add opensearch \
  https://opensearch-project.github.io/helm-charts/

helm repo update opensearch
```

Download rather than immediately installing:

```bash
helm pull opensearch/opensearch \
  --version YOUR_APPROVED_VERSION \
  --destination ./offline/charts

helm pull opensearch/opensearch-dashboards \
  --version YOUR_APPROVED_VERSION \
  --destination ./offline/charts
```

A manager values file could conceptually look like:

```yaml
clusterName: production-search

nodeGroup: managers

replicas: 3

roles:
  - cluster_manager

persistence:
  enabled: true

  storageClass: gp3-encrypted

  size: 30Gi

antiAffinity: hard
```

Then a second OpenSearch release/node group provides data nodes with larger disks.

Also configure replica shards. OpenSearch's default cluster setting is one replica, meaning a primary shard normally has another copy. ([OpenSearch Documentation][21])

For backups, use OpenSearch snapshots. OpenSearch supports S3 snapshot repositories through the `repository-s3` plugin. Build that plugin into the approved internal OpenSearch image **before** moving the image into the disconnected environment. ([OpenSearch Documentation][22])

---

# 14. The offline / air-gapped design

This is where many EKS projects become difficult.

Do **not** download random files directly from the production network.

Use two worlds:

```text
                  INTERNET SIDE

              Download Workstation
                      |
                      v
                Security Scan
                      |
                      v
              Connected Test EKS
                      |
                 Test release
                      |
             Find ALL dependencies
                      |
                 Verify hashes
                      |
               Approved Transfer
                      |
================ SECURITY BOUNDARY ================
                      |
                      v
                  OFFLINE SIDE
                      |
               Internal Artifactory
               Internal ECR
               Internal Git
                      |
                      v
                    EKS
```

AWS explicitly supports EKS clusters whose worker nodes have no outbound Internet access. In that design the nodes must pull container images from a registry accessible inside the VPC, and the EKS API must have private endpoint access enabled. ([AWS Documentation][23])

---

# 15. What should be downloaded

Create an offline release directory like:

```text
eks-offline-release/
|
+-- manifest/
|   +-- versions.yaml
|   +-- sha256sums.txt
|   +-- image-list.txt
|   +-- README.md
|
+-- tools/
|   +-- aws/
|   +-- kubectl/
|   +-- helm/
|   +-- jq/
|   +-- yq/
|
+-- charts/
|   +-- aws-load-balancer-controller.tgz
|   +-- strimzi-kafka-operator.tgz
|   +-- kafka-ui.tgz
|   +-- opensearch.tgz
|   +-- opensearch-dashboards.tgz
|   +-- nifi-internal.tgz
|   +-- zookeeper-internal.tgz
|
+-- manifests/
|   +-- storage/
|   +-- kafka/
|   +-- nifi/
|   +-- frontend/
|   +-- opensearch/
|
+-- images/
|   +-- images.tar
|
+-- config/
|   +-- kafka-values.yaml
|   +-- nifi-values.yaml
|   +-- search-values.yaml
|   +-- frontend-values.yaml
|
+-- scripts/
    +-- download.sh
    +-- discover-images.sh
    +-- export-images.sh
    +-- import-images.sh
    +-- verify-no-internet-images.sh
```

---

# 16. Where to get the important pieces

| Component                    | Get it from                           | What you copy                                            |
| ---------------------------- | ------------------------------------- | -------------------------------------------------------- |
| AWS CLI                      | AWS official distribution             | CLI installer                                            |
| kubectl                      | AWS/Kubernetes official distribution  | Matching kubectl binary                                  |
| Helm                         | Helm project                          | Helm binary                                              |
| AWS Load Balancer Controller | AWS EKS Helm chart repository         | Helm `.tgz`, CRDs, IAM policy                            |
| Strimzi                      | Official Strimzi downloads            | release `.zip/.tar.gz`, Helm `.tgz`, CRDs, examples      |
| Kafka images                 | Strimzi Quay registry                 | exact approved Strimzi/Kafka images                      |
| Kafka UI                     | Provectus Kafka UI project/chart repo | Helm chart + image                                       |
| Apache NiFi                  | Apache NiFi downloads                 | NiFi binary + SHA512/signature, or approved built image  |
| ZooKeeper                    | Apache ZooKeeper                      | binary + checksum/signature or approved image            |
| OpenSearch                   | OpenSearch Project Helm repository    | chart + OpenSearch image                                 |
| OpenSearch Dashboards        | OpenSearch Project                    | chart + image                                            |
| EKS add-ons                  | AWS EKS                               | managed add-on versions compatible with your EKS version |

The official Strimzi download page provides the complete release bundle, Helm chart, CRDs and examples, while Apache provides NiFi binaries plus SHA-512 and OpenPGP verification information. ([Strimzi][10])

Helm itself supports downloading a chart with `helm pull` and later installing directly from the local `.tgz` file, which is exactly what you want for an offline environment. ([Helm][24])

---

# 17. The best way to discover every required container image

This step is extremely useful.

Create a small **connected staging EKS cluster**.

Install the exact same charts and configuration you intend to install offline.

Then ask Kubernetes:

```bash
kubectl get pods -A -o json |
jq -r '
  .items[] |
  .spec.initContainers[]?.image,
  .spec.containers[]?.image
' |
sort -u > image-list.txt
```

Example output could contain:

```text
quay.io/strimzi/operator:...
quay.io/strimzi/kafka:...
docker.io/provectuslabs/kafka-ui:...
opensearchproject/opensearch:...
opensearchproject/opensearch-dashboards:...
your-nifi-image:...
```

This is much safer than somebody saying:

> “I think these are all the images.”

You are asking Kubernetes what it actually started.

For Strimzi specifically, the Helm chart supports changing `defaultImageRegistry` and `defaultImageRepository`, which is designed for cases such as copying Strimzi images into your own registry. ([GitHub][25])

---

# 18. Copy container images

On the connected machine:

```bash
docker pull quay.io/strimzi/operator:1.1.0
```

Then export:

```bash
docker save \
  quay.io/strimzi/operator:1.1.0 \
  -o strimzi-operator-1.1.0.tar
```

Transfer the file through your approved process.

Offline:

```bash
docker load \
  -i strimzi-operator-1.1.0.tar
```

Tag it:

```bash
docker tag \
  quay.io/strimzi/operator:1.1.0 \
  artifactory.corp.local/strimzi/operator:1.1.0
```

Push:

```bash
docker login artifactory.corp.local

docker push \
  artifactory.corp.local/strimzi/operator:1.1.0
```

Repeat for every image in `image-list.txt`.

For many images, automate the operation.

---

# 19. Point Strimzi at Artifactory

Your offline Strimzi values can use:

```yaml
defaultImageRegistry: artifactory.corp.local

defaultImageRepository: strimzi

defaultImageTag: "1.1.0"

image:
  registry: artifactory.corp.local
  repository: strimzi
  name: operator
```

Then:

```bash
helm upgrade --install strimzi \
  ./charts/strimzi-kafka-operator-1.1.0.tgz \
  --namespace kafka \
  --create-namespace \
  -f strimzi-offline-values.yaml
```

The current Strimzi Helm chart specifically provides registry/repository overrides for the images the operator creates. ([GitHub][25])

---

# 20. Verify nothing points to the Internet

Before installing into production, render the chart locally:

```bash
helm template strimzi \
  ./charts/strimzi-kafka-operator-1.1.0.tgz \
  -f strimzi-offline-values.yaml \
  > rendered-strimzi.yaml
```

Then search:

```bash
grep -E \
'quay.io|docker.io|ghcr.io|public.ecr.aws' \
rendered-strimzi.yaml
```

You want:

```text
NO RESULTS
```

Do the same for:

```text
Kafka UI
OpenSearch
OpenSearch Dashboards
NiFi
Web frontend
monitoring
backup tools
```

`helm template` is specifically meant to render the Kubernetes manifests locally without installing them, making it useful for this offline inspection step. ([Helm][26])

---

# 21. Private AWS access still requires AWS endpoints

“No Internet” does **not** mean:

```text
No AWS service connectivity.
```

Your worker nodes still need private paths to the AWS services they use.

For a fully private EKS deployment, common VPC endpoints include:

```text
ECR API
ECR Docker registry
S3
EC2
Elastic Load Balancing
EKS
EKS Auth
CloudWatch Logs
STS if using IRSA
SSM if using Session Manager
```

AWS specifically identifies:

```text
com.amazonaws.REGION.ecr.api
com.amazonaws.REGION.ecr.dkr
com.amazonaws.REGION.s3
com.amazonaws.REGION.ec2
com.amazonaws.REGION.elasticloadbalancing
com.amazonaws.REGION.logs
com.amazonaws.REGION.eks
com.amazonaws.REGION.eks-auth
com.amazonaws.REGION.sts
com.amazonaws.REGION.ssm
```

depending on which features you use. ([AWS Documentation][23])

For EKS Pod Identity, `eks-auth` is especially important because the Pod Identity Agent needs it to obtain credentials. ([AWS Documentation][27])

---

# 22. Use EKS Pod Identity

For modern EKS workloads I would normally prefer **EKS Pod Identity** over placing powerful AWS permissions on the EC2 node role.

For example:

```text
OpenSearch backup pod
       |
       v
ServiceAccount: opensearch
       |
       v
Pod Identity
       |
       v
IAM Role
       |
       v
Only allowed S3 snapshot bucket
```

The IAM role trust policy looks like:

```json
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"AllowEksAuthToAssumeRoleForPodIdentity",
      "Effect":"Allow",
      "Principal":{
        "Service":"pods.eks.amazonaws.com"
      },
      "Action":[
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
```

That is the current AWS trust pattern for EKS Pod Identity. ([AWS Documentation][28])

Install the agent:

```bash
aws eks create-addon \
  --cluster-name "$CLUSTER" \
  --addon-name eks-pod-identity-agent
```

Then associate a service account with a role:

```bash
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER" \
  --namespace opensearch \
  --service-account opensearch \
  --role-arn arn:aws:iam::$ACCOUNT_ID:role/OpenSearchSnapshotRole
```

Pod Identity gives each Kubernetes service account only the AWS permissions it requires rather than letting every workload inherit the EC2 node's permissions. ([AWS Documentation][29])

---

# 23. Easy upgrade strategy

This is where the architecture pays off.

Do **not** upgrade all of this at once:

```text
EKS
EC2 nodes
Kafka
Strimzi
NiFi
OpenSearch
Web
```

Treat each as a separate layer.

A safe order is conceptually:

```text
1. Backups
        ↓
2. Test in staging
        ↓
3. Check EKS Upgrade Insights
        ↓
4. EKS control plane
        ↓
5. EKS managed add-ons
        ↓
6. Create/update worker nodes
        ↓
7. Drain nodes gradually
        ↓
8. Strimzi operator
        ↓
9. Kafka
        ↓
10. NiFi
        ↓
11. OpenSearch
        ↓
12. Web applications
```

AWS recommends checking upgrade compatibility and spreading workloads across AZs, using PDBs and topology constraints before EKS upgrades. EKS control-plane minor upgrades happen one minor version at a time. ([AWS Documentation][30])

Example control-plane upgrade:

```bash
aws eks update-cluster-version \
  --name "$CLUSTER" \
  --kubernetes-version NEW_VERSION \
  --region "$AWS_REGION"
```

Then update a managed node group:

```bash
aws eks update-nodegroup-version \
  --cluster-name "$CLUSTER" \
  --nodegroup-name system-web \
  --kubernetes-version NEW_VERSION \
  --no-force
```

Do Kafka separately after EKS is healthy.

Do NiFi separately after Kafka is healthy.

Do OpenSearch separately.

That makes troubleshooting much easier.

---

# 24. Use blue/green node upgrades for the safest upgrades

For the stateful systems, an even safer method is:

```text
OLD Kafka Node Group
        |
        | pods running
        |
        v

Create

NEW Kafka Node Group
        |
        v

Move one Kafka broker
        |
        v

Verify replication
        |
        v

Move next broker
        |
        v

Verify
        |
        v

Delete OLD node group
```

This gives you a clear escape path.

The same idea works for:

```text
NiFi nodes
OpenSearch data nodes
Web nodes
```

---

# 25. What happens when things break?

| Failure                       | Expected response                                    |
| ----------------------------- | ---------------------------------------------------- |
| One web pod dies              | Deployment creates another                           |
| One web EC2 node dies         | Web pods on other AZs keep serving                   |
| One Kafka broker dies         | Replicas on other brokers continue                   |
| One Kafka AZ disappears       | Kafka should maintain quorum if configured correctly |
| One NiFi pod dies             | Other NiFi nodes continue processing their own data  |
| NiFi ZooKeeper node dies      | Remaining ZooKeeper quorum elects/continues          |
| One OpenSearch data node dies | Replica shards on other nodes serve data             |
| One OpenSearch manager dies   | Remaining managers maintain/elect cluster manager    |
| EKS worker dies               | Managed node group replaces capacity                 |
| Application update is bad     | Helm rollback/application rollback                   |
| EKS node upgrade              | PDB/topology rules keep enough replicas alive        |

One important NiFi difference: NiFi does **not** simply make every FlowFile exist on every NiFi node. A disk/AZ failure can therefore make the FlowFiles on that particular node temporarily unavailable. Design sources so data can be replayed when possible, use NiFi cluster load balancing appropriately, and maintain backups/recovery procedures. NiFi's clustering documentation describes node disconnection and explicit offloading/rebalancing of FlowFiles. ([Apache NiFi][16])

---

# 26. My recommended production starting point

For a practical first production design, I would use this:

```text
EKS
  3 Availability Zones
  private API
  private worker nodes

system-web node group
  minimum 3 nodes
  general controllers
  3 web pods
  2 Kafka UI pods
  2 OpenSearch Dashboard pods

Kafka node group
  minimum 3 nodes
  On-Demand
  Strimzi
  3 KRaft controllers
  3 Kafka brokers
  EBS gp3
  replication factor 3
  min ISR 2

NiFi node group
  minimum 3 nodes
  On-Demand
  3 NiFi pods
  EBS gp3 per NiFi
  3 ZooKeeper pods

Search node group
  minimum 3 nodes
  On-Demand
  3 dedicated OpenSearch managers
  3+ OpenSearch data pods
  EBS gp3

Networking
  internal ALB for web UI
  internal ALB/NLB for NiFi
  ClusterIP for internal services
  private EKS endpoint

AWS services
  EBS CSI
  Pod Identity
  Load Balancer Controller
  S3 snapshots/backups
  CloudWatch

HA
  topologySpreadConstraints
  PDBs
  readiness probes
  anti-affinity
  minimum replicas
  multi-AZ

Offline
  connected staging EKS
  pinned versions
  download charts
  discover actual images
  scan
  save images
  approved transfer
  push into Artifactory/ECR
  change all registries
  helm template verification
  install local .tgz files
```

This is more infrastructure than a cheap test cluster, but each piece has a purpose. **Kafka, NiFi and OpenSearch are stateful systems; trying to save money by putting all three copies on one EC2 instance defeats the reason for having three copies.**

The next natural step would be turning this architecture into an actual repository such as `eks-data-platform/` containing the **AWS CLI creation scripts, namespaces, StorageClasses, Strimzi/Kafka configuration, Kafka UI, a three-node NiFi Helm chart, ZooKeeper, web example, OpenSearch Helm values, PodDisruptionBudgets, topology rules, offline download/copy scripts, Artifactory image rewrite scripts, test scripts, upgrade scripts, and a main README explaining every file in middle-school language**.

[1]: https://docs.aws.amazon.com/eks/latest/best-practices/application.html?utm_source=chatgpt.com "Running highly-available applications - Amazon EKS"
[2]: https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html?utm_source=chatgpt.com "View Amazon EKS networking requirements for VPC and ..."
[3]: https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/?utm_source=chatgpt.com "Pod Topology Spread Constraints"
[4]: https://docs.aws.amazon.com/eks/latest/userguide/update-managed-node-group.html?utm_source=chatgpt.com "Update a managed node group for your cluster"
[5]: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html?utm_source=chatgpt.com "Understand the Kubernetes version lifecycle on EKS"
[6]: https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html?utm_source=chatgpt.com "Connect kubectl to an EKS cluster by creating a kubeconfig file"
[7]: https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html?utm_source=chatgpt.com "Amazon EKS node IAM role - AWS Documentation"
[8]: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html?utm_source=chatgpt.com "Use Kubernetes volume storage with Amazon EBS"
[9]: https://kubernetes.io/docs/tasks/run-application/configure-pdb/?utm_source=chatgpt.com "Specifying a Disruption Budget for your Application"
[10]: https://strimzi.io/downloads/ "Downloads"
[11]: https://strimzi.io/docs/operators/latest/deploying?utm_source=chatgpt.com "Deploying and Managing (1.1.0)"
[12]: https://github.com/strimzi/strimzi-kafka-operator/releases?utm_source=chatgpt.com "Releases · strimzi/strimzi-kafka-operator"
[13]: https://strimzi.io/docs/operators/latest/full/deploying?utm_source=chatgpt.com "Deploying and Managing Strimzi"
[14]: https://github.com/provectus/kafka-ui-charts?utm_source=chatgpt.com "provectus/kafka-ui-charts: UI For Apache Kafka Helm Charts"
[15]: https://nifi.apache.org/download/ "Download - Apache NiFi"
[16]: https://nifi.apache.org/docs/nifi-docs/html/administration-guide.html?utm_source=chatgpt.com "NiFi System Administrator's Guide"
[17]: https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/?utm_source=chatgpt.com "Performing a Rolling Update"
[18]: https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html "Install AWS Load Balancer Controller with Helm - Amazon EKS"
[19]: https://docs.opensearch.org/latest/tuning-your-cluster/?utm_source=chatgpt.com "Creating a cluster"
[20]: https://github.com/opensearch-project/helm-charts "GitHub - opensearch-project/helm-charts: :wheel_of_dharma: A community repository for Helm Charts of OpenSearch Project. · GitHub"
[21]: https://docs.opensearch.org/latest/install-and-configure/configuring-opensearch/index-settings/?utm_source=chatgpt.com "Index settings"
[22]: https://docs.opensearch.org/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/?utm_source=chatgpt.com "Take and restore snapshots"
[23]: https://docs.aws.amazon.com/eks/latest/userguide/private-clusters.html "Deploy private clusters with limited internet access - Amazon EKS"
[24]: https://helm.sh/docs/helm/helm_pull/?utm_source=chatgpt.com "helm pull"
[25]: https://github.com/strimzi/strimzi-kafka-operator/blob/main/helm-charts/helm3/strimzi-kafka-operator/values.yaml?utm_source=chatgpt.com "strimzi-kafka-operator/helm-charts/helm3 ..."
[26]: https://helm.sh/docs/helm/helm_template/?utm_source=chatgpt.com "helm template"
[27]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html?utm_source=chatgpt.com "Set up the Amazon EKS Pod Identity Agent"
[28]: https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html?utm_source=chatgpt.com "Create IAM role with trust policy required by EKS Pod Identity"
[29]: https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html?utm_source=chatgpt.com "Learn how EKS Pod Identity grants pods access to ..."
[30]: https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html?utm_source=chatgpt.com "Update existing cluster to new Kubernetes version"
