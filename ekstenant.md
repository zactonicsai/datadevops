# Multi-Tenant Amazon EKS: A Complete Defense-in-Depth Guide

## Background: What Are We Actually Trying to Do?

Imagine an apartment building. One building (the EKS cluster), but many tenants (teams or applications). Each tenant gets their own apartment (namespace), their own keys (RBAC), their own walls (network policies), and lives on their own floor (node groups). You don't want the tenant on floor 3 wandering into the apartment on floor 5, reading their mail, or using their electricity.

In Kubernetes terms, **multi-tenancy** means running multiple workloads that belong to different teams, customers, or trust levels inside one cluster while keeping them separated. The two big goals are:

- **Defense in depth**: Don't rely on one wall. Use many layers. If a burglar gets past the front door, there's still a locked apartment door, then a locked bedroom door. If one security control fails, another catches the problem.
- **Least privilege**: Give every person and program only the keys they absolutely need, and nothing more. The janitor doesn't get keys to the bank vault.

Your four applications, Kafka, NiFi, OpenSearch, and Postgres, are all "stateful" (they remember data on disk). They are heavy, they have different security needs, and they really shouldn't share the same machines or be able to talk to each other unless you explicitly allow it. That makes them a great example for strict isolation.

Let me walk through every layer.

---

## Layer 1: Naming Conventions

### What it is
A naming convention is just an agreed-upon way to name things so the name itself tells you what it is. Like naming files `2024-tax-return.pdf` instead of `document1.pdf`.

### Why it matters for security
Names don't enforce anything by themselves, but consistent names make your security rules (RBAC, network policies) reliable and easy to audit. If every Kafka thing starts with `kafka-`, you can write one rule that targets `kafka-*` and trust it catches everything.

### A suggested pattern

```
<tenant>-<environment>-<purpose>
```

Examples: `kafka-prod-broker`, `nifi-prod-app`, `opensearch-prod-data`, `postgres-prod-db`.

For labels (Kubernetes tags attached to objects), use a structured set:

```yaml
labels:
  tenant: kafka
  environment: prod
  app.kubernetes.io/name: kafka
  app.kubernetes.io/managed-by: platform-team
  data-classification: confidential
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Makes RBAC and network policy rules predictable and auditable | Purely conventional, enforces nothing on its own |
| Easy for humans to spot mistakes ("why is a postgres pod in the kafka namespace?") | Requires discipline; one typo breaks automation |
| Enables automated policy tools to select resources by label | Renaming later is painful |

A name is a label on a door, not a lock. It helps you find the right door to lock, but you still have to install the lock.

---

## Layer 2: Namespaces

### What it is
A **namespace** is a virtual folder inside your cluster. It groups related objects (pods, services, secrets) and creates a soft boundary. Think of it as one apartment in the building.

### Why it matters
Namespaces are the foundation that most other controls attach to. RBAC, network policies, and resource quotas all commonly operate per-namespace. Give each tenant its own namespace.

### Example: create namespaces for each tenant

```bash
kubectl create namespace kafka-prod
kubectl create namespace nifi-prod
kubectl create namespace opensearch-prod
kubectl create namespace postgres-prod

# Label them so policies and humans can target them
kubectl label namespace kafka-prod tenant=kafka data-classification=confidential
kubectl label namespace postgres-prod tenant=postgres data-classification=restricted
```

### Add Resource Quotas (stop one tenant eating all the food)

A **ResourceQuota** caps how much CPU, memory, and storage a namespace can consume. This prevents a "noisy neighbor", one tenant accidentally (or maliciously) using all the cluster's resources and starving everyone else. This is a security control too: resource exhaustion is a denial-of-service attack.

```yaml
# kafka-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: kafka-quota
  namespace: kafka-prod
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 80Gi
    limits.cpu: "40"
    limits.memory: 160Gi
    persistentvolumeclaims: "10"
    pods: "50"
```

```bash
kubectl apply -f kafka-quota.yaml
```

### Add LimitRanges (set default portion sizes)

A **LimitRange** sets default and maximum sizes for individual pods, so nobody can deploy one giant pod that swallows the whole quota.

```yaml
# kafka-limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: kafka-limits
  namespace: kafka-prod
spec:
  limits:
  - default:
      cpu: "2"
      memory: 4Gi
    defaultRequest:
      cpu: "500m"
      memory: 1Gi
    max:
      cpu: "8"
      memory: 32Gi
    type: Container
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Natural attachment point for RBAC, quotas, network policies | **Not a hard security boundary by itself**, a compromised pod can still reach the node and the network |
| Cheap, built-in, no extra cost | Some resources are cluster-wide (nodes, PersistentVolumes, CRDs) and ignore namespaces |
| Resource quotas prevent noisy-neighbor denial of service | Doesn't isolate the kernel; a container escape crosses namespaces |

**Critical point**: A namespace is a logical boundary, not a security sandbox. The Kubernetes project itself says namespaces alone are not sufficient to isolate untrusted or hostile tenants. That's exactly why we add the layers below, and why for strong isolation we put different tenants on different nodes.

---

## Layer 3: RBAC (Role-Based Access Control)

### What it is
RBAC decides **who can do what** in the cluster. "Who" is a user or a program (a ServiceAccount). "What" is verbs like get, list, create, delete on resources like pods or secrets.

Two key pairings:
- **Role** + **RoleBinding** = permissions inside ONE namespace.
- **ClusterRole** + **ClusterRoleBinding** = permissions across the WHOLE cluster.

Think of a Role as a keycard that only opens doors on one floor, and a ClusterRole as a master key for the whole building. You want to hand out floor-specific keycards almost always, and master keys almost never.

### Background: ServiceAccounts and IRSA

Every pod runs as a **ServiceAccount** (a robot identity). On EKS, you connect that Kubernetes identity to an AWS IAM role using **IRSA (IAM Roles for Service Accounts)** or the newer **EKS Pod Identity**. This means a Kafka pod can be granted access to a specific S3 bucket without giving that power to NiFi pods. This is least privilege reaching all the way from Kubernetes into AWS.

### Example: a least-privilege Role for the Kafka team

This Role lets the Kafka team manage their own workloads but **not** read secrets cluster-wide or touch other namespaces.

```yaml
# kafka-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: kafka-prod
  name: kafka-operator
rules:
- apiGroups: ["", "apps"]
  resources: ["pods", "services", "configmaps", "statefulsets", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]   # read only, and only in THIS namespace
```

```yaml
# kafka-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kafka-team-binding
  namespace: kafka-prod
subjects:
- kind: Group
  name: "kafka-team"          # comes from your IAM/OIDC identity provider
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: kafka-operator
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f kafka-role.yaml
kubectl apply -f kafka-rolebinding.yaml
```

### Connecting AWS users to Kubernetes groups

Modern EKS uses **access entries** (the replacement for the old `aws-auth` ConfigMap) to map an IAM role to a Kubernetes group.

```bash
aws eks create-access-entry \
  --cluster-name my-cluster \
  --principal-arn arn:aws:iam::111122223333:role/KafkaTeamRole \
  --kubernetes-groups kafka-team \
  --type STANDARD
```

### Example: Pod Identity (modern IRSA) so only Kafka pods reach their S3 bucket

```bash
# 1. Create an IAM role the Kafka pods will assume (trust policy points to EKS Pod Identity)
aws iam create-role \
  --role-name kafka-s3-role \
  --assume-role-policy-document file://pod-identity-trust.json

# 2. Attach a tight policy: only ONE bucket
aws iam put-role-policy \
  --role-name kafka-s3-role \
  --policy-name kafka-bucket-only \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:PutObject"],
      "Resource": "arn:aws:s3:::kafka-prod-data/*"
    }]
  }'

# 3. Associate that role with the Kafka ServiceAccount in the kafka-prod namespace
aws eks create-pod-identity-association \
  --cluster-name my-cluster \
  --namespace kafka-prod \
  --service-account kafka-sa \
  --role-arn arn:aws:iam::111122223333:role/kafka-s3-role
```

Now a NiFi pod literally cannot touch the Kafka bucket, because NiFi's ServiceAccount is tied to a different IAM role.

### Verify least privilege with `kubectl auth can-i`

```bash
# Check what the Kafka service account can do
kubectl auth can-i delete pods \
  --as=system:serviceaccount:kafka-prod:kafka-sa -n kafka-prod
# expected: yes

kubectl auth can-i get secrets -n postgres-prod \
  --as=system:serviceaccount:kafka-prod:kafka-sa
# expected: no  <-- this is the wall working
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Fine-grained, the core of least privilege for both K8s and AWS | Easy to misconfigure; over-broad ClusterRoles are a top mistake |
| Auditable; you can prove who can do what | Doesn't control network traffic (a pod with no API permissions can still send packets) |
| IRSA/Pod Identity extends least privilege into AWS services | Managing many roles across many teams adds operational overhead |
| `auth can-i` lets you test rules before trusting them | Group membership lives in your identity provider, which must also be secured |

**Golden rules**: Never bind anyone to the built-in `cluster-admin` unless truly necessary. Avoid wildcards (`*`) in verbs and resources. Prefer Roles over ClusterRoles. Give each tenant its own ServiceAccount, never share one.

---

## Layer 4: Network Policies

### What it is
By default in Kubernetes, **every pod can talk to every other pod**. That's like an apartment building where every door is unlocked and any tenant can walk into any other apartment. A **NetworkPolicy** is a firewall rule that says which pods may talk to which, on which ports.

### Critical EKS detail
The default Amazon VPC CNI does **not** enforce NetworkPolicy on its own historically, you needed something like Calico or Cilium. Newer versions of the VPC CNI **do** support native NetworkPolicy enforcement, but you must explicitly turn it on. If you write a policy and the feature isn't enabled, the policy is silently ignored, a dangerous false sense of security.

```bash
# Enable native network policy support on the VPC CNI add-on
aws eks update-addon \
  --cluster-name my-cluster \
  --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}'
```

### Step 1: Default deny everything (start locked)

The best practice is "default deny", block all traffic first, then open only what's needed. This is least privilege applied to the network.

```yaml
# default-deny-all.yaml  (apply one per tenant namespace)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: postgres-prod
spec:
  podSelector: {}            # selects every pod in the namespace
  policyTypes:
  - Ingress
  - Egress                   # deny both incoming AND outgoing by default
```

### Step 2: Allow only what each app needs

**Postgres**: should only accept connections from NiFi and OpenSearch (say those need the database), on port 5432, and nothing else.

```yaml
# postgres-allow.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-clients
  namespace: postgres-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          tenant: nifi
    - namespaceSelector:
        matchLabels:
          tenant: opensearch
    ports:
    - protocol: TCP
      port: 5432
```

**Kafka**: brokers must talk to each other (peer traffic) and accept producers/consumers from NiFi.

```yaml
# kafka-allow.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka-allow
  namespace: kafka-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: kafka
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: kafka   # broker-to-broker within namespace
    - namespaceSelector:
        matchLabels:
          tenant: nifi                      # NiFi produces/consumes
    ports:
    - protocol: TCP
      port: 9092
  egress:
  - to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: kafka
    ports:
    - protocol: TCP
      port: 9092
```

Always remember to **allow DNS egress** (port 53) in your egress policies, or pods won't be able to resolve service names and everything breaks.

```yaml
  egress:
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

```bash
kubectl apply -f default-deny-all.yaml
kubectl apply -f postgres-allow.yaml
kubectl apply -f kafka-allow.yaml
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Stops lateral movement, if one pod is hacked, it can't freely reach others | Native VPC CNI enforcement must be explicitly enabled or policies do nothing |
| "Default deny" is true least privilege for traffic | Easy to lock yourself out (forgetting DNS is the classic mistake) |
| Selectors by label/namespace map cleanly to your tenants | Standard NetworkPolicy can't filter by hostname/URL or do Layer 7 rules |
| Works per-namespace, fitting the tenant model | More pods and policies means more rules to maintain and test |

For richer needs (Layer 7 rules, encryption between pods, DNS-based egress), **Cilium** is a popular upgrade that adds those capabilities on top of standard NetworkPolicy.

---

## Layer 5: Taints, Tolerations, and Node Isolation

This is the layer that gives your stateful apps **physically separate machines**, the strongest practical isolation in a single cluster.

### The concepts in plain terms

- **Taint**: a "Keep Out" sign you put on a node (a worker machine). By default, no pod is allowed to land there.
- **Toleration**: a special pass you give to a pod that says "I'm allowed past that Keep Out sign."
- **NodeSelector / Node Affinity**: a pod's stated preference or requirement for which nodes it wants ("I want to run on Kafka nodes").

Taints repel; tolerations admit; affinity attracts. Used together, they let you say: *"Only Kafka pods run on Kafka nodes, and Kafka pods run only on Kafka nodes."* That two-way lock is exactly what you want for tenant isolation.

Why this matters for security: namespaces and RBAC don't stop a **container escape** (a hacker breaking out of the container onto the underlying machine). If Kafka and Postgres share a node and Kafka is compromised, the attacker is now on the same machine as Postgres. Putting each sensitive tenant on its own node group means a node-level compromise stays contained to that one tenant.

### Step 1: Create a dedicated managed node group per tenant

Each node group can have its own instance type, its own labels, and its own taints. Notice we also place each group in **specific subnets**, more on that in the subnet section.

```bash
# Kafka node group: memory + fast disk, tainted so only Kafka lands here
aws eks create-nodegroup \
  --cluster-name my-cluster \
  --nodegroup-name kafka-ng \
  --node-role arn:aws:iam::111122223333:role/KafkaNodeRole \
  --subnets subnet-0aaa1111 subnet-0bbb2222 \
  --instance-types r6i.2xlarge \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --labels tenant=kafka,workload=kafka \
  --taints '[{"key":"tenant","value":"kafka","effect":"NO_SCHEDULE"}]'

# Postgres node group: separate role, separate subnets, its own taint
aws eks create-nodegroup \
  --cluster-name my-cluster \
  --nodegroup-name postgres-ng \
  --node-role arn:aws:iam::111122223333:role/PostgresNodeRole \
  --subnets subnet-0ccc3333 subnet-0ddd4444 \
  --instance-types r6i.xlarge \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --labels tenant=postgres,workload=postgres \
  --taints '[{"key":"tenant","value":"postgres","effect":"NO_SCHEDULE"}]'
```

Do the same for `nifi-ng` and `opensearch-ng`. **Give each node group its own IAM node role**, so a compromised Kafka node has different (and minimal) AWS permissions than a Postgres node, least privilege at the machine level.

### Understanding the three taint effects

- `NoSchedule`: new pods without the matching pass won't be placed here.
- `PreferNoSchedule`: try to avoid, but allowed if nowhere else fits (soft).
- `NoExecute`: as above, **and** evicts any pod already running that lacks the pass.

### Step 2: Give the pod a matching toleration AND a nodeSelector

The toleration alone only lets the pod *past* the sign, it doesn't *force* it onto Kafka nodes. Add a `nodeSelector` (or required node affinity) so Kafka pods are pinned to Kafka nodes only. Both halves together create the two-way lock.

```yaml
# Inside the Kafka StatefulSet pod template
spec:
  template:
    spec:
      nodeSelector:
        tenant: kafka              # MUST run on kafka-labeled nodes
      tolerations:
      - key: "tenant"
        operator: "Equal"
        value: "kafka"
        effect: "NoSchedule"       # allowed past the kafka "Keep Out" sign
      containers:
      - name: kafka
        image: kafka:latest
```

### Stronger version: require affinity so pods can't drift

```yaml
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: tenant
                operator: In
                values: ["kafka"]
        # Spread brokers across nodes so losing one node doesn't kill the quorum
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: kafka
            topologyKey: kubernetes.io/hostname
```

### Step 3: Verify

```bash
# See the taint on the nodes
kubectl get nodes -l tenant=kafka -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'

# Confirm Kafka pods are only on Kafka nodes
kubectl get pods -n kafka-prod -o wide
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Strongest single-cluster isolation, separate machines contain container escapes | More node groups means higher cost (you can't bin-pack tenants tightly) |
| Per-node-group IAM roles extend least privilege to the AWS layer | Taint without nodeSelector only repels others; pods can still wander elsewhere |
| Lets you size hardware per app (memory for Kafka, fast disk for Postgres) | Operational complexity: more groups to patch, scale, and monitor |
| `NoExecute` can forcibly evict stray pods | Capacity fragmentation, idle headroom in each group wastes money |

### Hard isolation note: Bottlerocket and runtime sandboxes
For higher security, run a hardened, container-optimized OS like **Bottlerocket** on your nodes (smaller attack surface, immutable root filesystem). For truly untrusted workloads, consider sandboxed runtimes, but for your four trusted internal apps, dedicated node groups plus Bottlerocket is the sweet spot.

---

## Layer 6: Pod Security Standards (the missing piece)

### What it is
**Pod Security Standards (PSS)** enforce safe pod settings, like blocking pods from running as root, blocking privileged containers, and blocking access to the host filesystem. These are applied per-namespace via labels. This stops a tenant from deploying a pod that's configured to break out onto the node in the first place.

Three levels: **privileged** (no restrictions), **baseline** (blocks known-bad), **restricted** (hardened, the goal for most apps).

```bash
# Enforce the "restricted" standard on the postgres namespace
kubectl label namespace postgres-prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

If a tenant tries to deploy a root or privileged pod into that namespace, the API server rejects it. Note that some stateful apps need specific tweaks (filesystem permissions), so test `baseline` first if `restricted` blocks a legitimate need, and prefer fixing the pod's securityContext over loosening the namespace.

### Example secure pod settings for your apps

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: postgres
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Built into Kubernetes, no add-on needed | Only three preset levels; no custom rules |
| Stops the root cause of many escapes (privileged/root pods) | Stateful apps may need exceptions, requiring care |
| Per-namespace, fits the tenant model | For custom policy you need Kyverno or OPA Gatekeeper instead |

For richer, custom rules ("all images must come from our private registry", "every pod must have a tenant label"), add a **policy engine** like **Kyverno** or **OPA Gatekeeper**.

---

## Layer 7: Load Balancing for Tenants

### Background
When traffic comes from outside the cluster (or from other internal systems) into your apps, it usually arrives through a load balancer. On EKS, the **AWS Load Balancer Controller** creates AWS load balancers automatically from Kubernetes objects:

- A Kubernetes **Service** of type LoadBalancer (or annotations) → **Network Load Balancer (NLB)**, Layer 4, great for TCP traffic like Kafka and Postgres.
- A Kubernetes **Ingress** → **Application Load Balancer (ALB)**, Layer 7, great for HTTP/HTTPS like OpenSearch Dashboards or NiFi's web UI.

### Tenant separation principle
Give each tenant its **own** load balancer rather than sharing one. Separate LBs mean separate security groups, separate access logs, separate TLS certificates, and a smaller blast radius if one is misconfigured. Use **internal** load balancers (not internet-facing) unless a service genuinely must be exposed to the public internet, almost none of these four should be.

### Example: internal NLB for Kafka (Layer 4, TCP)

```yaml
# kafka-nlb.yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka-bootstrap
  namespace: kafka-prod
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal      # NOT public
    service.beta.kubernetes.io/aws-load-balancer-subnets: subnet-0priv1,subnet-0priv2
    service.beta.kubernetes.io/aws-load-balancer-security-groups: sg-kafka-nlb
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: kafka
  ports:
  - port: 9092
    targetPort: 9092
    protocol: TCP
```

### Example: internal ALB with TLS for OpenSearch Dashboards (Layer 7, HTTPS)

```yaml
# opensearch-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: opensearch-dashboards
  namespace: opensearch-prod
  annotations:
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:111122223333:certificate/abc
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/security-groups: sg-opensearch-alb
    alb.ingress.kubernetes.io/subnets: subnet-0priv1,subnet-0priv2
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: opensearch-dashboards
            port:
              number: 5601
```

### Pros and Cons of per-tenant load balancers

| Pros | Cons |
|------|------|
| Separate security groups and TLS certs per tenant, tight blast radius | More load balancers means higher AWS cost |
| Separate access logs simplify auditing | More resources to manage and monitor |
| NLB for TCP apps (Kafka/Postgres), ALB for web UIs (OpenSearch/NiFi), right tool per job | Requires the AWS Load Balancer Controller installed and configured |
| Internal scheme keeps data services off the public internet | TargetGroupBinding/security group rules need care to avoid open ports |

**Per-app guidance**: Kafka and Postgres → NLB (TCP). NiFi web UI and OpenSearch Dashboards → ALB (HTTPS with TLS termination). Always terminate TLS and use a modern SSL policy.

---

## Layer 8: Subnet and VPC Best Practices

### Background: the three-tier subnet model
A **VPC** is your private network in AWS. A **subnet** is a slice of that network living in one Availability Zone (AZ, a separate physical data center). The standard secure layout has three tiers:

1. **Public subnets**: only internet-facing load balancers and NAT gateways live here. They have a route to the internet.
2. **Private subnets**: your worker nodes and pods live here. No direct inbound from the internet. Outbound goes through a NAT gateway.
3. **Isolated/database subnets**: the most sensitive data stores, with **no internet route at all**, in or out. They reach AWS services through VPC endpoints instead.

### Key practices

**Always span at least 3 AZs.** Put each node group's subnets across multiple AZs so losing one data center doesn't take down a tenant. This also lets Kafka and OpenSearch spread replicas for durability.

**Keep nodes in private subnets.** Worker nodes should never sit in public subnets. The Kubernetes API endpoint itself can be made private too.

**Plan for IP exhaustion.** The VPC CNI gives each pod a real VPC IP address. Stateful apps with many replicas eat IPs fast. Use large subnet CIDR ranges (for example /20 or bigger), or use **custom networking** to put pods in **secondary CIDR** ranges separate from the node IPs. Running out of IPs silently stops pods from starting.

**Use VPC endpoints, not the internet, for AWS services.** This keeps traffic to S3, ECR, and others on the AWS private network, faster, cheaper, and it means your isolated subnets need no internet route at all.

```bash
# Gateway endpoint for S3 (free), so isolated subnets reach S3 privately
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids rtb-0private1 rtb-0private2

# Interface endpoint for pulling images from ECR privately
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0abc123 \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.us-east-1.ecr.dkr \
  --subnet-ids subnet-0priv1 subnet-0priv2 \
  --security-group-ids sg-endpoints
```

### Per-tenant subnet separation
You can place each node group in **dedicated private subnets** and attach **security groups** scoped per tenant. Combined with **Security Groups for Pods** (where the VPC CNI assigns an EC2 security group directly to specific pods), you get AWS-native, VPC-level firewalling per tenant, complementing your Kubernetes NetworkPolicies. Two firewalls (AWS SG + K8s NetworkPolicy) is defense in depth.

```bash
# Example: a SecurityGroupPolicy attaching a tenant SG to Postgres pods
cat <<'EOF' | kubectl apply -f -
apiVersion: vpcresources.k8s.aws/v1beta1
kind: SecurityGroupPolicy
metadata:
  name: postgres-sg-policy
  namespace: postgres-prod
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  securityGroups:
    groupIds:
      - sg-postgres-pods
EOF
```

### Pros and Cons

| Pros | Cons |
|------|------|
| Three-tier model keeps sensitive data with no internet path at all | More subnets and route tables to design and maintain |
| Multi-AZ subnets give resilience and replica spread | Multi-AZ NAT and cross-AZ traffic add cost |
| VPC endpoints keep AWS traffic private, cheaper, more secure | Interface endpoints have an hourly charge |
| Security Groups for Pods add an AWS-level firewall per tenant | IP planning is essential; CNI uses real VPC IPs and can exhaust them |

---

## Putting It All Together: Per-App Summary

| App | Node group | Load balancer | Key isolation notes |
|-----|-----------|---------------|---------------------|
| **Kafka** | `kafka-ng`, memory-optimized (r-family), tainted `tenant=kafka` | Internal **NLB** on 9092 | Pod anti-affinity to spread brokers across AZs; network policy allows broker-to-broker + NiFi only |
| **NiFi** | `nifi-ng`, general purpose, tainted `tenant=nifi` | Internal **ALB** (HTTPS) for web UI | Egress policy allows talking to Kafka, Postgres, OpenSearch; tight ingress on UI |
| **OpenSearch** | `opensearch-ng`, memory + fast disk, tainted `tenant=opensearch` | Internal **ALB** (HTTPS) for Dashboards | Anti-affinity for data nodes across AZs; restricted PSS with needed fsGroup |
| **Postgres** | `postgres-ng`, memory-optimized, tainted `tenant=postgres` | Internal **NLB** on 5432 | Place in isolated subnets; network policy allows only NiFi + OpenSearch; most restrictive RBAC and SG |

### The full defense-in-depth stack, from outside in

1. **VPC and subnets**: nodes in private subnets, data in isolated subnets, multi-AZ, VPC endpoints, no public exposure.
2. **Security groups + Security Groups for Pods**: AWS-level firewall per tenant.
3. **Node groups + taints/tolerations + affinity**: each tenant on its own machines with its own IAM node role.
4. **Hardened OS (Bottlerocket)**: minimal attack surface on each node.
5. **Namespaces + quotas + LimitRanges**: logical separation and noisy-neighbor protection.
6. **Pod Security Standards (restricted)**: no root, no privileged, no host access.
7. **RBAC + IRSA/Pod Identity**: least privilege for humans and pods, into AWS too.
8. **Network policies (default deny)**: least-privilege pod-to-pod traffic.
9. **Per-tenant load balancers with TLS**: separate certs, logs, and blast radius.
10. **Audit and monitoring** (the layer you should add next): enable EKS control plane audit logs, GuardDuty for EKS, and consider runtime threat detection.

Each layer assumes the one outside it might fail. That is the whole idea of defense in depth: no single wall has to be perfect, because there's always another wall behind it.

