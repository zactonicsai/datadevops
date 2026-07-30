**Yes — here’s a complete, cost-effective, middle-school-friendly tutorial** for running Keycloak on AWS EKS Auto Mode (min 1 node, max ~2 nodes), with RDS Postgres **outside** the cluster, offline/Artifactory support, IAM + SSM, and ready-to-run shell scripts.

### Middle-school explanations (types of things)

- **VPC** = your private neighborhood of servers in AWS.  
- **Subnet** = a smaller street inside the neighborhood (private streets keep things safer and cheaper).  
- **RDS Postgres** = a managed database house that lives **outside** the Keycloak neighborhood. Keycloak just talks to it over the private street.  
- **EKS Auto Mode** = Amazon’s “smart robot” that automatically creates and deletes the actual computers (nodes) your apps need. You only say “I want 1–2 computers max.”  
- **Node** = one computer that runs containers.  
- **IAM Role** = a special badge that lets the computers do certain jobs (and we add SSM so you can “remote-control” them safely without opening SSH ports).  
- **Helm** = a recipe book + shopping list for Kubernetes apps.  
- **Artifactory / internal registry** = your private warehouse so nothing needs the public internet after the first download.

**Most cost-effective choices used here**
- Smallest practical RDS: `db.t4g.micro` (or `db.t3.micro`) + gp3 storage + single-AZ.
- EKS Auto Mode with a tight custom NodePool so it can only run ~1–2 small nodes.
- Prefer Graviton (ARM) instances when possible — they are cheaper.
- Keycloak runs as 1 replica first (you can scale later).
- Everything private (no public load balancer required at the start).
- Offline after initial download.

**Order of work (exactly as you asked)**
1. RDS Postgres + subnets (VPC already exists)
2. IAM roles (with SSM)
3. EKS Auto Mode cluster + NodePool (min 1 / max ~2)
4. Keycloak on the nodes (Helm + offline)

---

### Part 0 – What you need ready

- Existing VPC ID  
- At least 2 private subnets in different Availability Zones (for RDS and for EKS)  
- AWS CLI configured, `kubectl`, `helm`, `docker` (or podman)  
- An internal Artifactory / Nexus / private ECR for offline images & charts

---

### Part 1 – RDS Postgres (outside the cluster) + Subnets

**Why first?** Keycloak needs a database before it can start.

**Script: `01-create-rds.sh`**

```bash
#!/bin/bash
set -euo pipefail

# === EDIT THESE ===
VPC_ID="vpc-xxxxxxxx"
PRIVATE_SUBNET_1="subnet-aaaa"   # private subnet AZ-a
PRIVATE_SUBNET_2="subnet-bbbb"   # private subnet AZ-b
DB_IDENTIFIER="keycloak-db"
DB_NAME="keycloak"
DB_USER="keycloak"
DB_PASSWORD="ChangeMeStrongPassword123!"   # store in Secrets Manager later
REGION="us-east-1"
# ==================

# 1. Create DB Subnet Group (tells RDS which private streets to live on)
aws rds create-db-subnet-group \
  --db-subnet-group-name keycloak-db-subnet-group \
  --db-subnet-group-description "Private subnets for Keycloak RDS" \
  --subnet-ids $PRIVATE_SUBNET_1 $PRIVATE_SUBNET_2 \
  --region $REGION

# 2. Create Security Group that only allows Postgres from the future EKS nodes
SG_ID=$(aws ec2 create-security-group \
  --group-name keycloak-rds-sg \
  --description "Allow Postgres from EKS nodes only" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --query 'GroupId' --output text)

echo "RDS Security Group: $SG_ID"
# (You will add the EKS node security group rule later after the cluster exists)

# 3. Create the cheapest practical Postgres
aws rds create-db-instance \
  --db-instance-identifier $DB_IDENTIFIER \
  --db-instance-class db.t4g.micro \
  --engine postgres \
  --engine-version 16.3 \
  --master-username $DB_USER \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage 20 \
  --storage-type gp3 \
  --db-name $DB_NAME \
  --db-subnet-group-name keycloak-db-subnet-group \
  --vpc-security-group-ids $SG_ID \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --storage-encrypted \
  --region $REGION

echo "Waiting for RDS to become available (takes 5–10 min)..."
aws rds wait db-instance-available --db-instance-identifier $DB_IDENTIFIER --region $REGION

ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier $DB_IDENTIFIER \
  --region $REGION \
  --query 'DBInstances[0].Endpoint.Address' --output text)

echo "RDS Endpoint: $ENDPOINT"
echo "Save this endpoint — Keycloak will use it."
```

After the cluster exists you must open port 5432 from the EKS node security group to this RDS SG.

---

### Part 2 – IAM Roles (Cluster + Node) with SSM

**Script: `02-create-iam-roles.sh`**

```bash
#!/bin/bash
set -euo pipefail
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"

# --- Cluster Role (the brain) ---
cat > cluster-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
EOF

aws iam create-role --role-name AmazonEKSAutoClusterRole --assume-role-policy-document file://cluster-trust.json
aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSComputePolicy
aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy
aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy
aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy

# --- Node Role (the workers) + SSM ---
cat > node-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role --role-name AmazonEKSAutoNodeRole --assume-role-policy-document file://node-trust.json
aws iam attach-role-policy --role-name AmazonEKSAutoNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy
aws iam attach-role-policy --role-name AmazonEKSAutoNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
# SSM so you can Session Manager into the nodes without SSH
aws iam attach-role-policy --role-name AmazonEKSAutoNodeRole --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

echo "Cluster Role ARN: arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSAutoClusterRole"
echo "Node Role ARN:    arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSAutoNodeRole"
```

---

### Part 3 – Create EKS Auto Mode cluster (min 1 / max ~2 nodes)

**Script: `03-create-eks-auto.sh`**

```bash
#!/bin/bash
set -euo pipefail

CLUSTER_NAME="keycloak-eks"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSAutoClusterRole"
NODE_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSAutoNodeRole"
SUBNET_1="subnet-aaaa"
SUBNET_2="subnet-bbbb"
# Optional: add a security group if you already have one
# SG_ID="sg-xxxx"

aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --kubernetes-version 1.31 \
  --role-arn $CLUSTER_ROLE \
  --resources-vpc-config "subnetIds=$SUBNET_1,$SUBNET_2,endpointPublicAccess=true,endpointPrivateAccess=true" \
  --compute-config "enabled=true,nodeRoleArn=$NODE_ROLE,nodePools=general-purpose,system" \
  --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true}}' \
  --storage-config '{"blockStorage":{"enabled":true}}' \
  --access-config '{"authenticationMode":"API_AND_CONFIG_MAP"}'

echo "Waiting for cluster to become ACTIVE (10–15 min)..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $REGION

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

echo "Cluster is ready. Now create a tight custom NodePool for cost control."
```

**Custom NodePool for ~1–2 nodes max** (`04-nodepool.yaml`)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: keycloak-small
spec:
  template:
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      requirements:
        - key: "eks.amazonaws.com/instance-category"
          operator: In
          values: ["m", "c", "r", "t"]
        - key: "eks.amazonaws.com/instance-cpu"
          operator: In
          values: ["2", "4"]          # keep nodes small
        - key: "kubernetes.io/arch"
          operator: In
          values: ["amd64", "arm64"]  # prefer arm64 later for cost
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["on-demand"]       # change to ["spot"] for cheaper
  limits:
    cpu: "8"          # roughly max 2 × 4-vCPU nodes
    memory: 16Gi
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
```

Apply it:

```bash
kubectl apply -f 04-nodepool.yaml
```

You can disable the built-in general-purpose pool later if you want only your custom one.

---

### Part 4 – Keycloak on the nodes (Helm + offline / Artifactory)

#### Offline preparation (do this once on a machine that has internet)

**Files you need to download / mirror**

| What | Where to download | What to do for offline |
|------|-------------------|------------------------|
| Official Keycloak image | `quay.io/keycloak/keycloak:26.0` (or latest stable) | `docker pull` → tag → push to your Artifactory / private ECR |
| codecentric Keycloak-X Helm chart (recommended) | https://github.com/codecentric/helm-charts (chart `keycloakx`) | `helm pull codecentric/keycloakx --version 2.x.x` → upload the `.tgz` to Artifactory |
| Bitnami chart (fallback) | charts.bitnami.com | same as above (note: Bitnami images are changing) |

**Script: `05-offline-prep.sh`** (run on internet machine)

```bash
#!/bin/bash
# Run this where you have internet, then copy artifacts to Artifactory

KEYCLOAK_VERSION="26.0.0"
HELM_CHART_VERSION="2.4.0"   # check latest keycloakx

# 1. Pull official image
docker pull quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

# 2. Tag for your internal registry
INTERNAL_REGISTRY="artifactory.yourcompany.com/docker"
docker tag quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} ${INTERNAL_REGISTRY}/keycloak:${KEYCLOAK_VERSION}
docker push ${INTERNAL_REGISTRY}/keycloak:${KEYCLOAK_VERSION}

# 3. Download Helm chart
helm repo add codecentric https://codecentric.github.io/helm-charts
helm pull codecentric/keycloakx --version ${HELM_CHART_VERSION}
# Upload the resulting keycloakx-*.tgz to your Artifactory Helm repo
```

#### Install Keycloak (inside the air-gapped / private environment)

**Script: `06-install-keycloak.sh`**

```bash
#!/bin/bash
set -euo pipefail

NAMESPACE="keycloak"
INTERNAL_REGISTRY="artifactory.yourcompany.com/docker"
KEYCLOAK_VERSION="26.0.0"
RDS_ENDPOINT="keycloak-db.xxxxx.us-east-1.rds.amazonaws.com"   # from Part 1
DB_USER="keycloak"
DB_PASSWORD="ChangeMeStrongPassword123!"
ADMIN_PASSWORD="AdminChangeMe123!"

kubectl create namespace $NAMESPACE || true

# Create secret for DB + admin
kubectl create secret generic keycloak-db-secret \
  --from-literal=username=$DB_USER \
  --from-literal=password=$DB_PASSWORD \
  --from-literal=admin-password=$ADMIN_PASSWORD \
  -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# values-offline.yaml
cat > values-offline.yaml <<EOF
image:
  repository: ${INTERNAL_REGISTRY}/keycloak
  tag: ${KEYCLOAK_VERSION}
  pullPolicy: IfNotPresent

replicas: 1

# External Postgres (RDS outside the cluster)
database:
  vendor: postgres
  hostname: ${RDS_ENDPOINT}
  port: 5432
  database: keycloak
  username: ${DB_USER}
  existingSecret: keycloak-db-secret
  existingSecretKey: password

# Admin user
auth:
  adminUser: admin
  existingSecret: keycloak-db-secret
  passwordKey: admin-password

# Keep it simple & cheap
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 1500m
    memory: 2Gi

service:
  type: ClusterIP

# Optional: later add Ingress when you need public access
ingress:
  enabled: false
EOF

# Install from local chart or from your Artifactory Helm repo
helm upgrade --install keycloak ./keycloakx-*.tgz \
  -n $NAMESPACE \
  -f values-offline.yaml \
  --wait --timeout 10m

echo "Keycloak is installing. Check with:"
echo "kubectl get pods -n keycloak -w"
```

After it is running you can port-forward for testing:

```bash
kubectl port-forward -n keycloak svc/keycloak-keycloakx 8080:80
# then open http://localhost:8080
```

---

### Final checklist & cost notes

1. RDS is running in private subnets → cheapest single-AZ micro instance.  
2. IAM roles created with SSM → you can use Session Manager instead of bastions.  
3. EKS Auto Mode + tight NodePool limits → stays at 1–2 small nodes.  
4. Keycloak uses the official image + external RDS → no extra database pods burning money.  
5. Everything after the first pull lives in your internal Artifactory → true offline.

**Rough monthly cost (us-east-1, 2026 prices, rough)**  
- RDS t4g.micro + 20 GB ≈ $15–20  
- 1–2 small nodes (m6g.large / t4g.medium style) ≈ $30–70  
- EKS control plane ≈ $73  
Total often stays under $150/month if you keep it to one node most of the time.

Would you like me to also give you:
- the exact security-group rule script that opens RDS from the EKS nodes,
- a version that uses Spot instances for even lower cost, or
- an Ingress + TLS setup for production?

Just say the word and I’ll add the next scripts.
