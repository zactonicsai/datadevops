# Deploying Keycloak on Its Own Node Group in an Existing EKS Cluster

**A complete, beginner-friendly guide using only the AWS CLI and kubectl**

Last checked: 30 July 2026 · Keycloak 26.7.0 · Keycloak CRD `k8s.keycloak.org/v2beta1` · Amazon EKS 1.34–1.36

---

## Table of contents

1. [What we are building (in plain words)](#1-what-we-are-building-in-plain-words)
2. [Background: the words you need to know](#2-background-the-words-you-need-to-know)
3. [Why give Keycloak its own node group?](#3-why-give-keycloak-its-own-node-group)
4. [Before you start: tools, versions, permissions](#4-before-you-start-tools-versions-permissions)
5. [PART A — The full worked example (do this first)](#part-a--the-full-worked-example-do-this-first)
6. [PART B — Deep explanations of every piece](#part-b--deep-explanations-of-every-piece)
7. [PART C — Your options, with pros and cons](#part-c--your-options-with-pros-and-cons)
8. [PART D — Best practices checklist](#part-d--best-practices-checklist)
9. [PART E — Sizing: how big should things be?](#part-e--sizing-how-big-should-things-be)
10. [PART F — Day-2 operations](#part-f--day-2-operations)
11. [PART G — Troubleshooting table](#part-g--troubleshooting-table)
12. [PART H — Common mistakes](#part-h--common-mistakes)
13. [Glossary](#glossary)
14. [Official links](#official-links)

---

## 1. What we are building (in plain words)

Imagine your Kubernetes cluster is a **school building**. Inside it there are many **classrooms** (servers). Students (your apps) get placed into classrooms by a **scheduler** (like a school office that assigns rooms).

Keycloak is the **security office** of the school. It is the thing that checks IDs and hands out badges. If the security office goes down, *nobody* can get into *any* room. So we do not want the security office squeezed into a noisy classroom next to a loud science experiment that eats all the electricity.

So we will:

1. Build a **brand-new wing** of the building, just for the security office. (= a new EKS **managed node group** with its own EC2 machines.)
2. Put a **"Security Staff Only" sign** on that wing. (= a Kubernetes **taint**, which repels other pods.)
3. Give the security office a **key** to that sign. (= a **toleration** on the Keycloak pods.)
4. Also tell the security office **"you must live in that wing"**. (= **node affinity** matching a node **label**.)
5. Give Keycloak a **filing cabinet outside the building** so records survive if a room burns down. (= an **Amazon RDS for PostgreSQL** database.)
6. Put a **front door with a lock** on the street. (= an **Application Load Balancer** with an HTTPS certificate.)

Here is the picture:

```
                        Internet
                            |
                     https://auth.example.com
                            |
                   +--------v---------+
                   |  Application     |   <- ACM TLS certificate lives here
                   |  Load Balancer   |
                   +--------+---------+
                            |
============================|============================ EKS cluster
                            |
   +------------------------v-----------------------+
   |   Node group: keycloak-ng                      |
   |   label: workload=keycloak                     |
   |   taint: dedicated=keycloak:NoSchedule         |
   |                                                |
   |  +----------+   +----------+   +----------+    |
   |  | node AZ-a|   | node AZ-b|   | node AZ-c|    |
   |  | keycloak |   | keycloak |   | keycloak |    |
   |  |  pod 1   |   |  pod 2   |   |  pod 3   |    |
   |  +----------+   +----------+   +----------+    |
   +------------------------+-----------------------+
                            |
   +------------------------|-----------------------+
   |  Node group: default (your other apps)         |
   |  keycloak-operator pod lives here              |
   +------------------------+-----------------------+
                            |
============================|============================
                            |
                    +-------v--------+
                    | Amazon RDS     |
                    | PostgreSQL     |
                    | Multi-AZ       |
                    +----------------+
```

---

## 2. Background: the words you need to know

Read this once. Everything later will make sense.

| Word | What it really means | Everyday analogy |
|---|---|---|
| **Kubernetes (k8s)** | Software that runs your apps across many servers and restarts them when they break. | A shift manager who keeps every station staffed. |
| **EKS** | Amazon's managed Kubernetes. AWS runs the "brain" (control plane); you run the workers. | You rent the building manager; you still hire workers. |
| **Node** | One worker machine. On EKS this is an EC2 virtual server. | One classroom. |
| **Node group** | A *group* of identical nodes that AWS creates and replaces for you. It is backed by an EC2 Auto Scaling group. | A whole wing of identical classrooms. |
| **Managed node group** | A node group where AWS handles the AMI updates and safely drains nodes during upgrades. This is what we use. | The wing where maintenance is included. |
| **Pod** | The smallest running unit — one or more containers that always live together on one node. | One student desk group. |
| **Label** | A sticky note (`key=value`) you attach to a node or pod. Used for *choosing*. | "This wing is Wing B." |
| **Taint** | A repellent on a node. Pods are pushed away unless they explicitly tolerate it. | The "Staff Only" sign. |
| **Toleration** | A pod's permission slip that lets it ignore a specific taint. | The staff keycard. |
| **Node affinity** | A rule on a pod: "only schedule me on nodes with this label." | "You must be in Wing B." |
| **Taint vs affinity** | You need **both**. A taint keeps *others out*. Affinity keeps *you in*. Neither one alone does both. | Sign keeps students out; contract keeps staff in. |
| **AZ (Availability Zone)** | A separate data centre in the same AWS region. | Different buildings on campus. |
| **Operator** | A program inside the cluster that manages a complex app for you using custom resources. | An expert caretaker for one machine. |
| **CRD / CR** | Custom Resource Definition = a new *type* of object. Custom Resource = one *instance* of it. | A form template vs. a filled-in form. |
| **Ingress** | A Kubernetes object that says "send web traffic for this hostname to this service." | The building's front-desk directory. |
| **ALB** | AWS Application Load Balancer. Handles HTTPS and spreads traffic. | The front door with a security scanner. |
| **IAM role** | An AWS identity with permissions. Machines and pods use these instead of passwords. | A job badge with specific door access. |
| **Keycloak** | Open-source identity server: single sign-on, OAuth2/OIDC, SAML, users, MFA. | The security office itself. |
| **Realm** | An isolated tenant inside Keycloak with its own users and apps. | One school's own ID system. |

---

## 3. Why give Keycloak its own node group?

This is the heart of your question, so here is the full reasoning.

**1. Blast radius.** Keycloak is a *dependency of everything*. If a badly written app on the same node leaks memory, the Linux kernel's OOM killer may kill neighbours. Losing Keycloak means every login in your company fails at once. Physical separation removes that risk.

**2. Predictable performance.** Keycloak is a Java app. Java loves steady CPU and steady memory. "Noisy neighbours" (batch jobs, CI runners, video encoding) cause CPU steal and garbage-collection pauses, which show up as slow logins.

**3. Right-sized machines.** Keycloak wants a moderate amount of memory per vCPU and benefits from modern CPUs. Your data-crunching pods may want huge memory or GPUs. One node shape cannot be perfect for both.

**4. Independent lifecycle.** You can upgrade, patch, reboot, or resize Keycloak's nodes without touching anything else — and roll them back independently.

**5. Security and compliance.** Identity systems often sit in a stricter scope for audits (PCI-DSS, SOC 2, ISO 27001). "These specific EC2 instances only run the identity service" is a very easy sentence to write in an audit document. It also lets you attach a narrower IAM role and tighter security groups.

**6. Cost clarity.** Tag the node group and your bill tells you exactly what identity costs.

**Honest downside:** dedicated capacity is less efficient. Three nodes reserved for Keycloak sit partly idle. For a tiny dev cluster this is wasted money — in that case just use labels without taints, or share nodes. Dedication is a **production** practice.

---

## 4. Before you start: tools, versions, permissions

### Tools on your laptop

```bash
aws --version        # need AWS CLI v2 (2.x). v1 is end-of-life.
kubectl version --client
helm version         # only needed if you install the load balancer controller
jq --version         # makes reading JSON output much easier
```

Install notes:
- **AWS CLI v2** — download from AWS docs. Do not use v1.
- **kubectl** — must be within **one minor version** of your cluster. A 1.36 cluster works with kubectl 1.35, 1.36, or 1.37.

### Versions that are current right now (July 2026)

| Thing | Current | Notes |
|---|---|---|
| Keycloak | **26.7.0** (released 9 July 2026) | Keycloak has **no LTS**. Only the newest minor gets security fixes, so plan to upgrade every ~3 months. |
| Keycloak CRD API version | **`k8s.keycloak.org/v2beta1`** | `v2alpha1` still exists but the CRD prints a deprecation warning telling you to migrate. Old blog posts use `v2alpha1` — update it. |
| EKS Kubernetes | 1.34, 1.35, **1.36** on standard support | **1.33 standard support ended 29 July 2026** — if you are on 1.33 you are now in paid extended support. |
| Node OS (AMI family) | **Amazon Linux 2023** (`AL2023_*`) | Amazon Linux 2 is retired for EKS. AL2023 also matters because Kubernetes 1.35+ refuses cgroup v1 nodes. |
| AWS Load Balancer Controller | **v3.x** | Gateway API support went **GA in March 2026**. |
| ingress-nginx | **Retired March 2026** | The upstream project was retired. Do **not** pick it for a new build. Use ALB Ingress or Gateway API. |
| Postgres on RDS | 17.x is a good current major | Always check `aws rds describe-db-engine-versions` for what your region offers today. |

### AWS permissions you need

Your CLI identity needs to be able to do, at minimum:
`eks:*NodegroupType*`, `eks:DescribeCluster`, `eks:CreateNodegroup`, `ec2:*` (subnets, security groups, tags), `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole`, `rds:*`, `acm:RequestCertificate`, `route53:ChangeResourceRecordSets`.

Inside the cluster you need to be a cluster admin (able to create namespaces, CRDs, and ClusterRoles).

### Sanity check first

```bash
aws sts get-caller-identity        # who am I?
kubectl auth can-i create clusterrole   # should print: yes
```

---

# PART A — The full worked example (do this first)

Do these steps in order. Every command is real. Replace only the values in **Step 0**.

> **Cost warning:** this creates 3 EC2 instances, one Multi-AZ RDS instance, and one ALB. Expect roughly **$300–450/month** in `us-east-1` at these sizes. Step A13 shows how to delete everything.

---

## Step 0 — Set your variables

Run this in one terminal and keep that terminal open. Every later command reuses these.

```bash
# ---- things you MUST change ----
export CLUSTER=my-cluster                 # your existing EKS cluster name
export REGION=us-east-1
export KC_HOSTNAME=auth.example.com       # the DNS name users will type
export HOSTED_ZONE_ID=Z0123456789ABCDEFGH # your Route 53 zone for example.com

# ---- things you can leave alone ----
export NG_NAME=keycloak-ng
export NODE_ROLE_NAME=eks-keycloak-node-role
export NS=keycloak
export KC_VERSION=26.7.0
export DB_ID=keycloak-db
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Account $ACCOUNT_ID, cluster $CLUSTER in $REGION"
```

**Why an environment variable?** It is a named box holding a value. Typing `$CLUSTER` later means "whatever I put in that box." It prevents typos and makes the whole guide copy-pasteable.

---

## Step 1 — Look at the cluster you already have

Never build on top of something you have not inspected.

```bash
aws eks describe-cluster \
  --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.{name:name,status:status,k8sVersion:version,vpc:resourcesVpcConfig.vpcId,clusterSG:resourcesVpcConfig.clusterSecurityGroupId,endpointPublic:resourcesVpcConfig.endpointPublicAccess,oidc:identity.oidc.issuer}' \
  --output table
```

Write down four things from the output — you will need them:

- **`status`** must be `ACTIVE`. If it says `UPDATING`, wait.
- **`k8sVersion`** — if this is 1.33 or lower, upgrade the cluster before adding nodes, because nodes must never be *newer* than the control plane.
- **`vpc`** — the network your nodes must join.
- **`clusterSG`** — the **cluster security group**. This is important: EKS automatically attaches this security group to managed node group instances. Later we allow the database to accept connections from this security group, and that is how Keycloak reaches Postgres.

Save two of them into variables:

```bash
export VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

export CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

echo "VPC=$VPC_ID  ClusterSG=$CLUSTER_SG"
```

Now connect `kubectl` to the cluster:

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes
```

You should see your existing nodes. If you get a connection error, your cluster endpoint may be private-only — in that case run these commands from a bastion host or VPN inside the VPC.

---

## Step 2 — Find the right subnets (this is where most people go wrong)

A **subnet** is a slice of the VPC that lives in exactly one Availability Zone. Nodes must go in **private** subnets (no direct route from the internet). The load balancer goes in **public** subnets. Getting these backwards is the single most common mistake.

The easiest and safest method: copy the subnets an existing working node group already uses.

```bash
aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION"
```

Pick one name from that list, then:

```bash
export EXISTING_NG=<paste-a-nodegroup-name-here>

aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$EXISTING_NG" --region "$REGION" \
  --query 'nodegroup.{subnets:subnets,role:nodeRole,ami:amiType,types:instanceTypes,ver:version}' \
  --output json
```

Those `subnets` are known-good. Confirm each one is private and note its AZ:

```bash
aws ec2 describe-subnets --region "$REGION" \
  --subnet-ids subnet-aaaa1111 subnet-bbbb2222 subnet-cccc3333 \
  --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,freeIPs:AvailableIpAddressCount,autoPublicIP:MapPublicIpOnLaunch}' \
  --output table
```

Read the output carefully:

- **`autoPublicIP` should be `False`** for node subnets. `True` means it is a public subnet.
- **`freeIPs`** must be healthy. Every pod gets a real VPC IP address with the default AWS VPC CNI, so pods eat IPs fast. If a subnet shows fewer than ~50 free IPs, you will hit `failed to assign an IP address to container` errors. Fix that *before* creating nodes.
- **`az`** — you want **three different AZs**. That is how you survive one data centre failing.

Set them:

```bash
export SUBNET_A=subnet-aaaa1111   # e.g. us-east-1a
export SUBNET_B=subnet-bbbb2222   # e.g. us-east-1b
export SUBNET_C=subnet-cccc3333   # e.g. us-east-1c
```

If you prefer to discover subnets by tag instead (EKS tags them when it creates them):

```bash
aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
            "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,freeIPs:AvailableIpAddressCount}' \
  --output table
```

> **Tag requirement for load balancers:** private subnets need the tag `kubernetes.io/role/internal-elb=1`; public subnets need `kubernetes.io/role/elb=1`. Without these tags the AWS Load Balancer Controller in Step A7 cannot find where to put the ALB and will silently fail. Add a missing tag with:
> ```bash
> aws ec2 create-tags --region "$REGION" --resources subnet-xxxx \
>   --tags Key=kubernetes.io/role/elb,Value=1
> ```

---

## Step 3 — Create the IAM role for the nodes

Every node needs an AWS **badge** so it can register with EKS and pull container images.

**Option 1 (recommended): reuse the existing node role.** If the role from Step A2 works for your other node groups, reuse it. Fewer moving parts.

```bash
export NODE_ROLE_ARN=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$EXISTING_NG" --region "$REGION" \
  --query 'nodegroup.nodeRole' --output text)
echo "$NODE_ROLE_ARN"
```

**Option 2: create a dedicated role** (better isolation — a compromised app on another node group cannot use Keycloak's node permissions):

```bash
# 3a. The trust policy: WHO is allowed to wear this badge? Answer: EC2 instances.
cat > node-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# 3b. Create the role
aws iam create-role \
  --role-name "$NODE_ROLE_NAME" \
  --assume-role-policy-document file://node-trust-policy.json \
  --description "EKS worker node role for the Keycloak dedicated node group"

# 3c. Attach the minimum required managed policies
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly

# 3d. Optional but very useful: lets you open a shell on a node without SSH keys
aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

export NODE_ROLE_ARN=$(aws iam get-role --role-name "$NODE_ROLE_NAME" \
  --query 'Role.Arn' --output text)
echo "$NODE_ROLE_ARN"
```

**What each policy does, in plain words:**

| Policy | Plain meaning |
|---|---|
| `AmazonEKSWorkerNodePolicy` | "I am allowed to introduce myself to the cluster and describe my own network." |
| `AmazonEC2ContainerRegistryPullOnly` | "I may download container images from ECR." Prefer this over the older `...ReadOnly` — it is narrower, which is the whole point of least privilege. |
| `AmazonSSMManagedInstanceCore` | "An admin may open a session on me through AWS Systems Manager." Lets you debug without opening port 22 to anyone. |
| `AmazonEKS_CNI_Policy` | Networking permissions. **Only attach this to the node role if your VPC CNI addon does *not* have its own role.** Modern clusters give the `aws-node` service account its own role via EKS Pod Identity or IRSA, which is more secure. Check with: `aws eks describe-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --region "$REGION" --query 'addon.serviceAccountRoleArn'`. If that prints an ARN, do **not** attach the CNI policy to the node role. |

---

## Step 4 — Create the dedicated managed node group

This is the main event. Read the explanation under the command before you run it.

```bash
aws eks create-nodegroup \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG_NAME" \
  --region "$REGION" \
  --node-role "$NODE_ROLE_ARN" \
  --subnets "$SUBNET_A" "$SUBNET_B" "$SUBNET_C" \
  --instance-types m7i.large \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --disk-size 50 \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 \
  --update-config maxUnavailable=1 \
  --labels workload=keycloak,tier=identity \
  --taints 'key=dedicated,value=keycloak,effect=NO_SCHEDULE' \
  --tags "Name=$CLUSTER-$NG_NAME,Service=keycloak,Team=identity,Environment=prod,k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/$CLUSTER=owned"
```

### Every flag, explained

| Flag | What it does | Why this value |
|---|---|---|
| `--nodegroup-name` | The group's name. | Include the purpose. Names are permanent — you cannot rename a node group. |
| `--node-role` | The IAM badge from Step A3. | Nodes cannot join the cluster without it. |
| `--subnets` | Which network slices, and therefore which AZs. | Three AZs = survive one data centre outage. |
| `--instance-types` | The EC2 machine shape. `m7i.large` = 2 vCPU, 8 GiB RAM. | "m" = balanced CPU:memory, which suits Java. You may list several types (e.g. `m7i.large m6i.large`) so AWS can substitute when one is scarce. |
| `--ami-type` | The node operating system image. | `AL2023_x86_64_STANDARD` is current. Use `AL2023_ARM_64_STANDARD` for Graviton (see Part C). |
| `--capacity-type` | `ON_DEMAND` or `SPOT`. | **On-demand for identity.** Spot instances can be reclaimed with 2 minutes' notice. Losing login for everyone to save a few dollars is a bad trade. |
| `--disk-size` | Root EBS volume in GiB. | 50 GiB. Keycloak stores almost nothing on disk, but container images plus logs plus the kubelet's own data fill 20 GiB faster than you expect. |
| `--scaling-config` | min / max / desired node count. | `min=3` guarantees one node per AZ even at idle. `max=6` gives headroom for a login storm. |
| `--update-config` | How aggressively AWS replaces nodes during an upgrade. | `maxUnavailable=1` = replace one node at a time. Safe. You can use `maxUnavailablePercentage=33` instead, but never both. |
| `--labels` | Sticky notes on every node. | `workload=keycloak` is what our node-affinity rule will match. |
| `--taints` | The "Staff Only" sign. | Note the **CLI spelling is `NO_SCHEDULE`** (screaming snake case). In Kubernetes YAML the same thing is `NoSchedule`. Mixing these up is a classic error. |
| `--tags` | AWS tags on the AWS resources (for billing and autoscaler discovery). | These are **AWS tags**, which are a *different thing* from **Kubernetes labels**. Tags help your bill and the Cluster Autoscaler; labels help the scheduler. |

### Watch it being built

Creating a node group takes about 3–5 minutes. Rather than refreshing manually, let the CLI block until it is done:

```bash
aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION"

echo "Node group is ACTIVE"
```

If it fails, get the reason:

```bash
aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION" \
  --query 'nodegroup.{status:status,health:health.issues}' --output json
```

Common failure messages and their real cause:

| Message | Real cause |
|---|---|
| `NodeCreationFailure: Instances failed to join the kubernetes cluster` | Nodes have no route to the EKS API. Usually a missing NAT gateway, a missing VPC endpoint, or the wrong subnets. |
| `AccessDenied` on the node role | You forgot `AmazonEKSWorkerNodePolicy`, or your own identity lacks `iam:PassRole`. |
| `InsufficientFreeAddresses` | The subnet ran out of IPs. Pick a bigger subnet. |
| `Unsupported AMI type` | Your control plane version does not offer that AMI type. Check the cluster version. |

---

## Step 5 — Prove the nodes are correct

Do not trust; verify. Three checks.

**Check 1 — the nodes exist and carry the label:**

```bash
kubectl get nodes -l workload=keycloak \
  -o custom-columns='NAME:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,STATUS:.status.conditions[-1].type'
```

Expect three nodes, in three different zones, all `Ready`.

**Check 2 — the taint really landed:**

```bash
kubectl get nodes -l workload=keycloak \
  -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
```

You should see `dedicated=keycloak:NoSchedule` on each. Note it prints as `NoSchedule` here even though you typed `NO_SCHEDULE` in the CLI — that is expected and correct.

**Check 3 — the sign actually works.** Launch a pod with no toleration and confirm it is refused:

```bash
kubectl run taint-test --image=public.ecr.aws/docker/library/busybox:1.36 \
  --restart=Never --command -- sleep 3600

kubectl get pod taint-test -o wide
```

It should land on one of your *other* nodes, never on a `keycloak-ng` node. To make the test strict, force it to try:

```bash
kubectl run taint-test2 --image=public.ecr.aws/docker/library/busybox:1.36 \
  --restart=Never --overrides='{"spec":{"nodeSelector":{"workload":"keycloak"}}}' \
  --command -- sleep 3600

kubectl describe pod taint-test2 | tail -5
```

You want to see an event like `0/N nodes are available: 3 node(s) had untolerated taint {dedicated: keycloak}`. **That message is success** — the fence is real.

Clean up the test:

```bash
kubectl delete pod taint-test taint-test2 --ignore-not-found
```

---

## Step 6 — Create the PostgreSQL database

Keycloak keeps users, realms, clients, and sessions in a relational database. **Run the database outside the cluster.** A pod is disposable; your user directory is not.

**6a. A security group for the database.** Think of a security group as a guest list for a door.

```bash
export DB_SG=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name keycloak-db-sg \
  --description "Postgres access for Keycloak pods" \
  --vpc-id "$VPC_ID" \
  --query 'GroupId' --output text)
echo "DB security group: $DB_SG"
```

**6b. Allow only the cluster's nodes in, on only the Postgres port.**

```bash
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$DB_SG" \
  --protocol tcp --port 5432 \
  --source-group "$CLUSTER_SG"
```

Read that carefully: the source is a **security group**, not an IP range. This means "any instance wearing the cluster security group badge may knock on port 5432." Nodes come and go with new IPs; the badge stays constant. This is far better than hardcoding CIDRs.

**6c. A DB subnet group** tells RDS which AZs it may live in.

```bash
aws rds create-db-subnet-group \
  --region "$REGION" \
  --db-subnet-group-name keycloak-db-subnets \
  --db-subnet-group-description "Private subnets for the Keycloak database" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" "$SUBNET_C"
```

**6d. Pick a Postgres version that exists in your region today.**

```bash
aws rds describe-db-engine-versions \
  --region "$REGION" --engine postgres \
  --query 'reverse(sort_by(DBEngineVersions,&EngineVersion))[:8].EngineVersion' \
  --output table
```

Choose a recent major (17.x is a good pick as of mid-2026) and set it:

```bash
export PG_VERSION=17.5   # replace with a version from the list above
```

**6e. Create the database.**

```bash
aws rds create-db-instance \
  --region "$REGION" \
  --db-instance-identifier "$DB_ID" \
  --db-instance-class db.m7g.large \
  --engine postgres \
  --engine-version "$PG_VERSION" \
  --allocated-storage 100 \
  --storage-type gp3 \
  --storage-encrypted \
  --db-name keycloak \
  --master-username kcadmin \
  --manage-master-user-password \
  --multi-az \
  --backup-retention-period 14 \
  --preferred-backup-window 03:00-04:00 \
  --db-subnet-group-name keycloak-db-subnets \
  --vpc-security-group-ids "$DB_SG" \
  --no-publicly-accessible \
  --auto-minor-version-upgrade \
  --deletion-protection \
  --enable-performance-insights \
  --copy-tags-to-snapshot \
  --tags Key=Service,Value=keycloak Key=Team,Value=identity
```

| Flag | Why it matters |
|---|---|
| `--multi-az` | AWS keeps a hot standby in another AZ and fails over automatically in ~60–120 seconds. Roughly doubles cost. **Worth it for identity.** |
| `--storage-encrypted` | Encryption at rest. Free. Cannot be enabled later without a snapshot-restore, so do it now. |
| `--manage-master-user-password` | AWS generates the password, stores it in **Secrets Manager**, and can rotate it. You never see or type it. Far better than inventing your own. |
| `--no-publicly-accessible` | No internet-facing endpoint. Non-negotiable. |
| `--deletion-protection` | Stops a tired engineer from deleting your entire user directory. |
| `--backup-retention-period 14` | 14 days of point-in-time recovery. Backups are your real safety net. |
| `db.m7g.large` | Graviton (ARM) — usually cheaper per unit of performance. The database engine is AWS's, so ARM is invisible to you here. |

**6f. Wait, then collect the connection details.**

```bash
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DB_ID"

export DB_HOST=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

export DB_SECRET_ARN=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

echo "DB host:   $DB_HOST"
echo "DB secret: $DB_SECRET_ARN"
```

This takes 10–15 minutes for Multi-AZ. Use the time to read Part B.

Now read the generated password out of Secrets Manager:

```bash
export DB_USER=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$DB_SECRET_ARN" --query SecretString --output text | jq -r .username)

export DB_PASS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$DB_SECRET_ARN" --query SecretString --output text | jq -r .password)

echo "DB user: $DB_USER  (password captured, not printed)"
```

> **A note on secrets:** copying a password into a shell variable and then into a Kubernetes Secret is fine for a first deployment, but the password now exists in your shell history and in etcd. The production pattern is the **External Secrets Operator** or the **Secrets Store CSI driver**, which pull directly from Secrets Manager and refresh automatically. See Part D.

---

## Step 7 — Make sure you have an ingress controller (ALB)

**Skip this step if you already run the AWS Load Balancer Controller.** Check:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get ingressclass
```

If you see the deployment and an `alb` ingress class, jump to Step A8.

### Why not ingress-nginx?

The upstream Kubernetes project **retired ingress-nginx in March 2026**. Existing installs keep working, but there are no more bug fixes or security patches. For a *new* identity deployment — the most security-sensitive thing you run — that is not an acceptable foundation. Use the AWS Load Balancer Controller instead.

### 7a. Create the IAM policy the controller needs

```bash
curl -o alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

export ALB_POLICY_ARN=$(aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-iam-policy.json \
  --query 'Policy.Arn' --output text)

echo "$ALB_POLICY_ARN"
```

If it already exists, fetch the ARN instead:

```bash
export ALB_POLICY_ARN=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy
```

### 7b. Give the controller pod an AWS identity, using EKS Pod Identity

A pod is not an EC2 instance, so it cannot use the node's badge safely — that would give *every* pod on the node the same permissions. **EKS Pod Identity** gives one specific Kubernetes service account its own IAM role. It is the newer, simpler alternative to IRSA (no OIDC provider juggling, all pure CLI).

```bash
# Install the agent that makes Pod Identity work
aws eks create-addon --cluster-name "$CLUSTER" --region "$REGION" \
  --addon-name eks-pod-identity-agent

aws eks wait addon-active --cluster-name "$CLUSTER" --region "$REGION" \
  --addon-name eks-pod-identity-agent
```

Now a trust policy that says "pods may wear this badge":

```bash
cat > pod-identity-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
EOF

aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file://pod-identity-trust.json

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn "$ALB_POLICY_ARN"

# Bind the role to one exact service account in one exact namespace
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER" --region "$REGION" \
  --namespace kube-system \
  --service-account aws-load-balancer-controller \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/AmazonEKSLoadBalancerControllerRole"
```

The last command is the important one. It means: *only* the service account named `aws-load-balancer-controller`, *only* in the `kube-system` namespace, may use these load-balancer permissions. Nothing else in the cluster can.

### 7c. Install the controller

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=2

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller
```

> If your controller version predates Pod Identity support, use IRSA instead: create an OIDC provider with `aws iam create-open-id-connect-provider`, then annotate the service account with `eks.amazonaws.com/role-arn`. Pod Identity is preferred on new clusters.

### 7d. Request the TLS certificate

```bash
export CERT_ARN=$(aws acm request-certificate \
  --region "$REGION" \
  --domain-name "$KC_HOSTNAME" \
  --validation-method DNS \
  --query 'CertificateArn' --output text)

# Wait a few seconds, then read the DNS record ACM wants you to create
sleep 15
aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json
```

Create that CNAME record in Route 53 (substitute the Name and Value you just got):

```bash
cat > acm-validation.json <<'EOF'
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "_PASTE_NAME_HERE",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{ "Value": "_PASTE_VALUE_HERE" }]
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch file://acm-validation.json

aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN"
echo "Certificate validated: $CERT_ARN"
```

**Why DNS validation?** ACM proves you own the domain by asking you to publish a secret record. Once validated, ACM **renews the certificate automatically forever** as long as the record stays. No more expired-certificate outages at 2 a.m.

---

## Step 8 — Install the Keycloak Operator

An **operator** is a small program that lives in your cluster and knows how to run one specific application properly. Instead of you hand-writing a StatefulSet, a Service, cluster-cache configuration, health probes, and an upgrade procedure, you write a short `Keycloak` object and the operator builds all of it.

```bash
kubectl create namespace "$NS"
```

The official install uses Kustomize. We add a tiny overlay so everything lands in *our* namespace rather than `default`:

```bash
mkdir -p keycloak-operator && cd keycloak-operator

cat > kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NS
resources:
  - github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=$KC_VERSION
EOF

kubectl apply -k .
cd ..
```

Verify:

```bash
kubectl -n "$NS" rollout status deployment/keycloak-operator --timeout=180s
kubectl get crd | grep keycloak
```

You should see two new CRDs:

```
keycloakrealmimports.k8s.keycloak.org
keycloaks.k8s.keycloak.org
```

Confirm which API version is current — this matters, because most blog posts on the internet are out of date:

```bash
kubectl get crd keycloaks.k8s.keycloak.org \
  -o jsonpath='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
```

Output will show `v2beta1` as the storage version and `v2alpha1` as deprecated. **Use `v2beta1`.**

> **Where should the operator run?** Leave it on your general node group. It is a tiny controller (~100 MiB) and it does not benefit from dedicated hardware. Keeping it off the tainted nodes also means the operator can still act if the Keycloak nodes are unhealthy — a useful separation.

> **Namespace scope:** this install watches only its own namespace. For a cluster-wide operator, use `.../cluster-wide?ref=26.7.0` instead. One-namespace scope is the safer default.

---

## Step 9 — Store the database credentials in the cluster

```bash
kubectl -n "$NS" create secret generic keycloak-db-secret \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASS"
```

Confirm the keys exist without printing the values:

```bash
kubectl -n "$NS" get secret keycloak-db-secret -o jsonpath='{.data}' | jq 'keys'
# ["password","username"]
```

> Kubernetes Secrets are only **base64-encoded**, not encrypted, unless you enable **envelope encryption with a KMS key** on the cluster. Anyone with read access to Secrets in this namespace can read this password. See Part D for the hardening steps.

---

## Step 10 — Deploy Keycloak, pinned to your node group

This is the file that ties everything together. Read the annotations below it before applying.

```bash
cat > keycloak-cr.yaml <<EOF
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: keycloak
  namespace: $NS
spec:
  # ---------- size ----------
  instances: 3
  image: quay.io/keycloak/keycloak:$KC_VERSION

  # ---------- database ----------
  db:
    vendor: postgres
    host: $DB_HOST
    port: 5432
    database: keycloak
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
    poolMinSize: 5
    poolInitialSize: 5
    poolMaxSize: 20

  # ---------- how users reach it ----------
  hostname:
    hostname: https://$KC_HOSTNAME
  http:
    httpEnabled: true          # ALB terminates TLS; pod speaks plain HTTP inside the VPC
  proxy:
    headers: xforwarded        # trust X-Forwarded-* headers, which is what an ALB sends
  ingress:
    enabled: false             # we create our own ALB Ingress in Step 12

  # ---------- only accept traffic from the ingress controller ----------
  networkPolicy:
    enabled: true

  # ---------- resources ----------
  resources:
    requests:
      cpu: "1"
      memory: 1750Mi
    limits:
      cpu: "2"
      memory: 2Gi

  # ---------- THE PART THAT PINS PODS TO YOUR NODE GROUP ----------
  scheduling:
    tolerations:
      - key: dedicated
        operator: Equal
        value: keycloak
        effect: NoSchedule
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: workload
                  operator: In
                  values: ["keycloak"]
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: keycloak

  # ---------- upgrades: the helper Job needs the same permissions ----------
  update:
    strategy: Auto
    scheduling:
      tolerations:
        - key: dedicated
          operator: Equal
          value: keycloak
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: workload
                    operator: In
                    values: ["keycloak"]
EOF

kubectl apply -f keycloak-cr.yaml
```

### The four scheduling pieces, and why you need all of them

**1. `tolerations` — the keycard.**
Your nodes carry `dedicated=keycloak:NoSchedule`. Without this toleration, Keycloak pods are repelled by your own node group and sit `Pending` forever. The `effect` here is spelled `NoSchedule` (Kubernetes style), *not* `NO_SCHEDULE` (AWS CLI style).

**2. `affinity.nodeAffinity` — the contract.**
A toleration only says "I *may* go there." It does not say "I must." Without affinity, the scheduler is free to place Keycloak on your general node group. `requiredDuringSchedulingIgnoredDuringExecution` means "hard requirement at placement time."

> ⚠️ **Important gotcha, verified against the 26.7.0 CRD:** the Keycloak resource's `scheduling` block supports exactly four fields — `affinity`, `tolerations`, `topologySpreadConstraints`, and `priorityClassName`. **There is no `nodeSelector` field.** Many tutorials suggest `nodeSelector`; it will be rejected or silently dropped. Use `nodeAffinity` as shown. (You *can* reach `nodeSelector` through `spec.unsupported.podTemplate`, but as the name warns, that path is unsupported and skips validation.)

**3. `topologySpreadConstraints` — do not put all eggs in one basket.**
`maxSkew: 1` across `topology.kubernetes.io/zone` means the pod counts per zone can differ by at most one. With 3 pods and 3 zones you get exactly one per zone. `DoNotSchedule` makes it a hard rule. This is what turns "3 replicas" into "3 replicas that actually survive an AZ failure."

**4. `update.scheduling` — the upgrade trap.**
When you change the image, the operator runs a temporary **Job** to compare configurations and decide whether a zero-downtime rolling update is safe. That Job is a separate pod. If you only put tolerations on the *server* pods, the Job cannot be scheduled onto your tainted nodes, and your upgrade silently hangs. Giving `update.scheduling` the same tolerations and affinity fixes it. This bites people constantly; it is why the field exists.

### Other fields worth understanding

| Field | Explanation |
|---|---|
| `instances: 3` | Three pods. Keycloak forms a distributed Infinispan cache across them, so a pod dying does not log everyone out. Never run 1 in production. |
| `image` | Pinning the exact tag makes deployments reproducible. If you omit it, you get the operator's default — fine, but less predictable. |
| `http.httpEnabled: true` | The ALB does the HTTPS work. Inside the VPC, pod traffic is plain HTTP. If your compliance rules require encryption *inside* the cluster too, provide `http.tlsSecret` instead and set the ALB `backend-protocol` to HTTPS. |
| `proxy.headers: xforwarded` | Tells Keycloak "you are behind a proxy; the real client IP and scheme are in the `X-Forwarded-*` headers." **An ALB sends `X-Forwarded-*`, not RFC 7239 `Forwarded`** — so `xforwarded` is the correct value here. Get this wrong and you get infinite redirect loops or wrong IPs in your audit log. |
| `hostname.hostname` | Must exactly match the name users type. Keycloak stamps this into tokens and redirect URLs. A mismatch is the #1 cause of "it half works." |
| `networkPolicy.enabled: true` | Restricts who can talk to the pods directly. Important: because you trust forwarded headers, you must ensure nothing can bypass the ALB and spoof them. |
| `db.poolMaxSize: 20` | Each pod opens up to 20 DB connections; 3 pods = up to 60. Check your RDS `max_connections` (a `db.m7g.large` allows several hundred) and keep total pods × poolMaxSize comfortably below it. |
| `update.strategy: Auto` | Lets the operator use a rolling update when it can prove that is safe, and a full restart when it cannot. Keycloak 26.6+ supports zero-downtime *patch* updates within the same minor stream. |

### Watch it come up

```bash
kubectl -n "$NS" get keycloak keycloak -w
```

Then check the conditions — this is the operator's own report card:

```bash
kubectl -n "$NS" get keycloaks/keycloak -o go-template='{{range .status.conditions}}CONDITION: {{.type}}{{"\n"}}  STATUS: {{.status}}{{"\n"}}  MESSAGE: {{.message}}{{"\n"}}{{end}}'
```

You are aiming for:

```
CONDITION: Ready
  STATUS: true
CONDITION: HasErrors
  STATUS: false
CONDITION: RollingUpdate
  STATUS: false
```

First boot takes 2–4 minutes because Keycloak runs database schema migrations.

If it is stuck, in this order:

```bash
kubectl -n "$NS" get pods
kubectl -n "$NS" describe pod keycloak-0 | tail -30      # scheduling problems appear in Events
kubectl -n "$NS" logs keycloak-0 --tail=100              # DB problems appear here
kubectl -n "$NS" logs deployment/keycloak-operator --tail=100
```

---

## Step 11 — Prove the pods landed on the right nodes

This is the verification that answers your original question.

```bash
kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase' -l app=keycloak
```

Now cross-check that every one of those node names appears in your dedicated group:

```bash
echo "--- Nodes in the keycloak node group ---"
kubectl get nodes -l workload=keycloak -o name

echo "--- Nodes actually hosting Keycloak pods ---"
kubectl -n "$NS" get pods -l app=keycloak -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u
```

The second list must be a subset of the first. If any pod is on another node, your affinity is wrong.

And confirm the zone spread actually happened:

```bash
for p in $(kubectl -n "$NS" get pods -l app=keycloak -o name); do
  node=$(kubectl -n "$NS" get "$p" -o jsonpath='{.spec.nodeName}')
  zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
  echo "$p -> $node -> $zone"
done
```

Three different zones = you did it right.

---

## Step 12 — Add a PodDisruptionBudget

A **PodDisruptionBudget (PDB)** is a promise: "when you drain nodes for maintenance, never take me below this many healthy pods." Without one, a node upgrade can evict all three Keycloak pods at once and take down every login in your company. The operator does not create this for you.

```bash
cat > keycloak-pdb.yaml <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: keycloak-pdb
  namespace: $NS
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: keycloak
EOF

kubectl apply -f keycloak-pdb.yaml
kubectl -n "$NS" get pdb
```

With `instances: 3` and `minAvailable: 2`, only one pod may be voluntarily evicted at a time. Combined with `--update-config maxUnavailable=1` on the node group, node upgrades become genuinely safe.

> Do not set `minAvailable` equal to your replica count — that blocks *all* drains and your node upgrades will hang forever.

---

## Step 13 — Expose Keycloak through the ALB

```bash
export KC_SERVICE=$(kubectl -n "$NS" get svc -l app=keycloak -o jsonpath='{.items[0].metadata.name}')
echo "Keycloak service: $KC_SERVICE"   # usually keycloak-service
```

```bash
cat > keycloak-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: $NS
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    alb.ingress.kubernetes.io/certificate-arn: $CERT_ARN
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/backend-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /realms/master
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: '15'
    alb.ingress.kubernetes.io/healthy-threshold-count: '2'
    alb.ingress.kubernetes.io/unhealthy-threshold-count: '3'
    alb.ingress.kubernetes.io/load-balancer-attributes: >-
      routing.http2.enabled=true,
      idle_timeout.timeout_seconds=90,
      routing.http.drop_invalid_header_fields.enabled=true
    alb.ingress.kubernetes.io/target-group-attributes: >-
      stickiness.enabled=true,
      stickiness.type=lb_cookie,
      deregistration_delay.timeout_seconds=30
    alb.ingress.kubernetes.io/tags: Service=keycloak,Team=identity
spec:
  ingressClassName: alb
  rules:
    - host: $KC_HOSTNAME
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $KC_SERVICE
                port:
                  number: 8080
EOF

kubectl apply -f keycloak-ingress.yaml
```

### Key annotations explained

| Annotation | Meaning |
|---|---|
| `scheme: internet-facing` | Public ALB. Use `internal` if Keycloak should only be reachable from inside your network/VPN. |
| `target-type: ip` | The ALB sends traffic **straight to pod IPs**, skipping the node's kube-proxy hop. Lower latency, and it makes health checks reflect real pod health. Strongly preferred over `instance`. |
| `ssl-redirect: '443'` | Any HTTP request is redirected to HTTPS. Never serve an identity system over plain HTTP. |
| `ssl-policy: ...TLS13...` | Enforces modern TLS. Old policies still allow TLS 1.0/1.1, which fails most audits. |
| `healthcheck-path: /realms/master` | A cheap endpoint that only responds once Keycloak is truly serving. If your service also publishes port 9000, `/health/ready` on port 9000 is the more precise choice — check with `kubectl -n $NS get svc $KC_SERVICE -o yaml` to see which ports exist. |
| `stickiness.enabled=true` | Sends a returning browser back to the same pod. Keycloak 26 does not *require* this (the distributed cache handles it), but it reduces cross-pod cache lookups and speeds up logins. |
| `deregistration_delay=30` | On pod shutdown, the ALB waits 30 s to finish in-flight requests before cutting the target. Prevents 502s during deploys. |
| `drop_invalid_header_fields=true` | Blocks header-smuggling tricks. Especially relevant since you are trusting forwarded headers. |

### Point DNS at the ALB

```bash
# Wait for the ALB to be provisioned (1-3 minutes)
kubectl -n "$NS" get ingress keycloak -w
```

```bash
export ALB_DNS=$(kubectl -n "$NS" get ingress keycloak \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

export ALB_ZONE=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].CanonicalHostedZoneId" --output text)

cat > kc-dns.json <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$KC_HOSTNAME",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "$ALB_ZONE",
        "DNSName": "$ALB_DNS",
        "EvaluateTargetHealth": true
      }
    }
  }]
}
EOF

aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://kc-dns.json
```

An **alias record** is an AWS-specific record type that points at an AWS resource. It is free to query, and it follows the ALB if its IPs change. Always prefer an alias over a CNAME for an ALB.

Verify the target group is healthy:

```bash
export TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName,'keycloak')].TargetGroupArn | [0]" --output text)

aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{target:Target.Id,port:Target.Port,state:TargetHealth.State,reason:TargetHealth.Reason}' \
  --output table
```

All three should read `healthy`. If they read `unhealthy`, the health check path or port is wrong — that is the fix 90% of the time.

---

## Step 14 — Log in and immediately harden

The operator generated a random admin account for you:

```bash
kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n "$NS" get secret keycloak-initial-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

Open `https://auth.example.com` and sign in.

**Do these four things before you tell anyone the URL:**

1. **Create your own admin user** in the `master` realm, give it the `admin` role, log in as that user, then **delete the temporary account**. The bootstrap account is meant to be thrown away.
2. **Turn on MFA for the master realm.** Authentication → Required Actions → enable *Configure OTP*, and add an OTP step to the browser flow. An identity server whose own admin has only a password is a single point of catastrophic failure.
3. **Restrict the admin console.** Best practice is to serve `/admin` on a *separate internal* hostname behind your VPN, so it is never reachable from the public internet.
4. **Change the temporary account's password** if you cannot delete it yet.

End-to-end test:

```bash
curl -sS "https://$KC_HOSTNAME/realms/master/.well-known/openid-configuration" | jq '.issuer'
```

The `issuer` must print exactly `https://auth.example.com/realms/master`. If it prints an internal address or an ALB hostname instead, your `hostname` or `proxy.headers` setting is wrong.

---

## Step 15 — How to remove everything (in the right order)

Order matters. Deleting in the wrong sequence leaves orphaned AWS resources you keep paying for.

```bash
# 1. Delete the Ingress FIRST so the controller deletes the ALB for you
kubectl -n "$NS" delete ingress keycloak

# 2. Keycloak, then the operator, then the namespace
kubectl -n "$NS" delete keycloak keycloak
kubectl delete namespace "$NS"

# 3. The node group
aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION"
aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION"

# 4. The database (deletion protection must be removed first)
aws rds modify-db-instance --region "$REGION" --db-instance-identifier "$DB_ID" \
  --no-deletion-protection --apply-immediately
aws rds delete-db-instance --region "$REGION" --db-instance-identifier "$DB_ID" \
  --final-db-snapshot-identifier "$DB_ID-final-$(date +%Y%m%d)"

# 5. Leftovers
aws rds delete-db-subnet-group --region "$REGION" --db-subnet-group-name keycloak-db-subnets
aws ec2 delete-security-group --region "$REGION" --group-id "$DB_SG"
aws iam detach-role-policy --role-name "$NODE_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam delete-role --role-name "$NODE_ROLE_NAME"
```

**If you delete the Ingress last (or never), the ALB is orphaned** and bills you forever. Always delete Kubernetes objects that create AWS resources *before* tearing down the cluster pieces around them.


---

# PART B — Deep explanations of every piece

Now that it works, here is what is actually happening underneath.

## B1. What a managed node group really is

When you run `aws eks create-nodegroup`, AWS builds three layers for you:

1. An **EC2 Launch Template** — the blueprint: which AMI, which instance type, which disk, which security groups, and a bootstrap script that joins the node to your cluster.
2. An **EC2 Auto Scaling Group (ASG)** — the machine that keeps "desired count" instances alive. If an instance dies, the ASG replaces it within minutes without anyone being paged.
3. An **EKS Nodegroup object** — AWS's own record that connects the ASG to your cluster, adds your labels and taints to the kubelet's registration arguments, and knows how to do a *safe* rolling upgrade (cordon → drain → respect PDBs → terminate → launch replacement).

That third layer is the reason to prefer managed node groups. Doing safe drains yourself is genuinely hard.

**Labels and taints are applied at kubelet registration.** That is why a label set via `aws eks update-nodegroup-config` applies immediately to existing nodes (EKS patches them), but a change to instance type or AMI requires nodes to be replaced.

## B2. How the scheduler actually decides

When a Keycloak pod is created, the scheduler runs two phases:

**Phase 1 — Filtering.** It throws out every node that cannot possibly work:
- Not enough free CPU or memory for the pod's *requests*
- Node has a taint the pod does not tolerate ← **your taint acts here**
- Node does not match required node affinity ← **your affinity acts here**
- Node has no free pod slots or IP addresses
- Topology spread constraints would be violated ← **your spread rule acts here**

**Phase 2 — Scoring.** Among survivors, it ranks by spare capacity, image locality, and preferred affinities, then picks the winner.

Understanding this explains the two failure modes precisely:
- Taint but no affinity → the pod is *allowed* on your nodes but may also be placed elsewhere.
- Affinity but no toleration → your nodes pass affinity but fail the taint filter, leaving **zero** candidates. The pod stays `Pending` with `untolerated taint`.

## B3. Requests vs. limits (the most misunderstood thing in Kubernetes)

- **Request** = the reservation. The scheduler subtracts this from a node's capacity. It is what *guarantees* you resources.
- **Limit** = the ceiling. Exceeding a CPU limit gets you throttled (slowed). Exceeding a memory limit gets your container **killed** (OOMKilled) — there is no graceful degradation for memory.

For Java apps like Keycloak the standard advice is:

- **Set memory request = memory limit.** This puts the pod in the `Guaranteed` QoS class, so it is the *last* thing evicted when a node runs short. It also makes memory behaviour predictable.
- **Set a CPU request but a higher CPU limit.** Keycloak's startup and its periodic token-signing work are bursty. Let it borrow idle CPU.

Keycloak's container image sizes the JVM heap as a **percentage of the container memory limit**, not a fixed number. So raising the memory limit automatically gives the JVM a bigger heap. This is why you must always set a memory limit — without one, the JVM's idea of "available memory" becomes the whole node, and it will happily grow until the kernel kills it.

## B4. Why the database must be outside the cluster

Keycloak stores realms, users, clients, roles, and group memberships in PostgreSQL. That data is the *definition of who is allowed into your company's systems*. Running it in a pod means:

- A node failure risks data loss unless storage is perfectly configured.
- An EBS volume is locked to one AZ, so the pod can only ever be rescheduled in that AZ.
- Backups, point-in-time recovery, failover, minor-version patching, and connection metrics all become your job.

RDS gives you automated backups, Multi-AZ failover, encryption, and Performance Insights for a modest premium. For an identity system this is not a close call.

**Aurora PostgreSQL** is the step up: faster failover, storage that grows on its own, and up to 15 read replicas. Keycloak's own high-availability guides use Aurora across AZs for their reference multi-site architecture.

## B5. How Keycloak clustering works (why 3 replicas is not just "more copies")

Keycloak embeds **Infinispan**, a distributed in-memory cache, for authentication sessions, user sessions, and login-failure counters. The pods find each other using **DNS discovery against the headless Service** the operator creates, then form a cluster and distribute cache entries with replicas.

Consequences that matter for node-group design:

- **Keep pods in the same region and preferably close network-wise.** Cross-AZ latency is fine (single-digit ms). Cross-*region* is not, which is why multi-region Keycloak needs a special architecture rather than just stretching one cluster.
- **A rolling restart is safe** because sessions live on more than one pod.
- **Restarting all pods at once wipes the cache** and logs everyone out. This is exactly what your PDB prevents.
- Keycloak 26.7 previews a **multi-cluster HA v2** mode that removes the need for an external Infinispan server for site-level failover.

## B6. Why the hostname and proxy headers cause so much pain

Keycloak issues tokens containing an `issuer` claim, and generates redirect URLs during login. Both must be the **public** address, not the pod's internal one. But the pod only sees a request arriving on `http://10.0.3.44:8080`.

The ALB adds headers: `X-Forwarded-For`, `X-Forwarded-Proto: https`, `X-Forwarded-Host`. Setting `proxy.headers: xforwarded` tells Keycloak to trust them. Setting `hostname.hostname` tells it the canonical answer regardless.

The security catch: if Keycloak trusts those headers, then **anything that can reach the pod directly can lie about them**. That is why we enabled `networkPolicy` — it restricts direct pod access, so the only path in is through the ALB, which overwrites the headers. Trusting forwarded headers without a network policy is a real vulnerability, not a theoretical one.

## B7. Node group vs. what the pod sees: labels you get for free

Every EKS node automatically carries useful labels you can use in affinity rules without setting anything:

| Label | Example | Use |
|---|---|---|
| `topology.kubernetes.io/zone` | `us-east-1a` | Zone spreading |
| `topology.kubernetes.io/region` | `us-east-1` | Multi-region rules |
| `node.kubernetes.io/instance-type` | `m7i.large` | Require a machine shape |
| `kubernetes.io/arch` | `amd64` / `arm64` | Keep pods off the wrong CPU architecture |
| `eks.amazonaws.com/nodegroup` | `keycloak-ng` | **Pin directly to a node group by name** |
| `eks.amazonaws.com/capacityType` | `ON_DEMAND` / `SPOT` | Keep critical pods off spot |

That means you could pin by node group name instead of a custom label:

```yaml
- key: eks.amazonaws.com/nodegroup
  operator: In
  values: ["keycloak-ng"]
```

**Which is better?** A custom label like `workload=keycloak` is more flexible — you can add a second node group later (say, one for Graviton) and both will match without editing Keycloak. The built-in label is more explicit but couples your app config to an AWS resource name. Prefer the custom label; keep the built-in one in mind for quick debugging.

---

# PART C — Your options, with pros and cons

## C1. How to run the nodes

| Option | How it works | Pros | Cons | Verdict for Keycloak |
|---|---|---|---|---|
| **EKS Managed Node Group** (used above) | AWS creates an ASG, handles AMI patching and safe drains. | Free control layer; labels/taints supported natively; safe rolling upgrades; predictable capacity; works with reserved instances / savings plans. | You pick instance types yourself; scaling needs Cluster Autoscaler or manual changes; reserved capacity sits idle. | ✅ **Best default.** Simple, predictable, auditable. |
| **Self-managed nodes** | You own the launch template and ASG. | Total control: custom AMI, custom kernel, hardened images, exotic networking. | You own patching, draining, and upgrade automation. Real ongoing work. | Only if a compliance rule demands a custom AMI. |
| **Karpenter** | A controller that launches right-sized EC2 instances on demand based on pending pods. | Excellent bin-packing; very fast scale-up; consolidates nodes to cut cost; flexible instance selection. | Another controller to run and understand; nodes are more ephemeral, which needs care with stateful-ish apps; you must set up `NodePool` + disruption budgets. | ✅ Good for large clusters. Pin Keycloak with a dedicated `NodePool` carrying labels+taints, and set conservative disruption budgets. |
| **EKS Auto Mode** | AWS runs Karpenter and core addons for you; you just declare NodePools. | Least operational work; nodes auto-patch and expire on a cycle; scales fast; handles version rollback of nodes automatically. | Extra management fee on top of EC2; less control over AMI and node internals; nodes are replaced regularly (typically ~every 3 weeks), which is a *feature* but demands solid PDBs. | ✅ Great if you want minimum ops. Same pinning idea, expressed as a NodePool with labels and taints. |
| **AWS Fargate** | Each pod gets its own micro-VM. No nodes at all. | Nothing to patch; strong pod isolation; pay only per pod. | No DaemonSets; no privileged containers; slower pod start; higher cost per unit of compute; you select pods by *namespace/label* via Fargate profiles, so "dedicated node group" pinning does not apply; you cannot tune the node. | ⚠️ Workable, but you lose the node-level control this guide is about, and cost is worse at steady state. |

## C2. How to install Keycloak

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Keycloak Operator** (used above) | Official and actively maintained; correct StatefulSet, probes, and cluster cache config by default; first-class fields for DB, hostname, proxy, network policy, ServiceMonitor, tracing; manages upgrades including zero-downtime patch updates; generates the bootstrap admin secret; `KeycloakRealmImport` CR for GitOps-style realm config. | Less knob-turning than Helm — anything not modelled in the CRD needs the explicitly *unsupported* `podTemplate` escape hatch. You must install the CRDs (cluster-admin). | ✅ **Recommended.** The scheduling stanza is exactly what you need for node pinning. |
| **Bitnami Helm chart** | Huge number of values; can bundle PostgreSQL for demos; familiar Helm workflow. | Bitnami changed its public image distribution during 2025, which broke pipelines that pulled `latest` from the old free catalog — you must check current terms and mirror/pin images. Chart-level abstraction can drift behind upstream Keycloak. | ⚠️ Use only if you are already deeply invested in Helm, and mirror the images into ECR. |
| **`codecentric/keycloakx` chart** | Community-maintained, plain and transparent. | Less active; you configure clustering and probes yourself. | For niche needs. |
| **Hand-written StatefulSet** | Complete control, no CRDs, no operator. | You reimplement cache discovery, probes, migrations, and upgrade safety. Easy to get subtly wrong in ways that only show under load. | ❌ Not worth it. |

## C3. How to expose it

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **ALB via Ingress** (used above) | Mature, extremely well documented; native ACM certificate integration; WAF, Shield, and access logs attach directly; path/host routing; OIDC auth at the edge if wanted. | AWS-specific annotations; one ALB per Ingress unless you use `group.name` to share. | ✅ **Best default today.** |
| **ALB via Gateway API** | The successor to Ingress; **GA in AWS Load Balancer Controller since March 2026**; cleaner separation between platform team (Gateway) and app team (HTTPRoute); more expressive routing. | Newer, so fewer examples and less institutional muscle memory; needs Gateway API CRDs installed. | ✅ Choose this for greenfield builds you expect to keep for years. |
| **NLB with TLS passthrough** | End-to-end TLS to the pod; needed for **mTLS** client-certificate authentication; layer 4 means very low latency. | You manage certificates inside the cluster; no layer-7 features (no WAF, no path routing, no header rewriting). | Use when mTLS is a hard requirement. |
| **ingress-nginx** | Familiar to everyone; portable across clouds. | **Retired by upstream Kubernetes in March 2026** — no further security patches. | ❌ Do not choose for a new identity deployment. |

## C4. Database options

| Option | Pros | Cons |
|---|---|---|
| **RDS PostgreSQL Multi-AZ** (used above) | Managed backups, automatic failover, encryption, Performance Insights. Simple and predictable pricing. | Failover takes ~60–120 s. Storage must be sized in advance. |
| **Aurora PostgreSQL** | Faster failover (often <30 s), auto-growing storage, up to 15 replicas, global database option. Used in Keycloak's own reference HA architecture. | Higher cost; I/O-based billing can surprise you. |
| **Aurora Serverless v2** | Scales capacity with load; cheap when idle. | Cold-ish scaling behaviour; less predictable latency under spiky auth load. |
| **PostgreSQL in-cluster (e.g. CloudNativePG)** | No AWS dependency; everything in Git; cheap. | *You* now own backup, restore, failover, and upgrades of your identity database. | 
| **MySQL / MariaDB / Oracle / MSSQL** | Supported by Keycloak. | PostgreSQL gets the most testing and community usage. Use it unless your organisation forbids it. |

## C5. Instance type choices for the node group

| Choice | Pros | Cons |
|---|---|---|
| **`m7i.large` / `m6i.large`** (x86, balanced) | Widest compatibility; every container image works; 2 vCPU / 8 GiB fits ~2 Keycloak pods comfortably. | Slightly more expensive per unit of performance than Graviton. |
| **`m7g.large` / `m8g.large`** (Graviton / ARM) | Typically ~20% better price-performance; lower power. Keycloak publishes multi-arch images, so it runs natively. | You must use `--ami-type AL2023_ARM_64_STANDARD`, and **every** sidecar, agent, and custom provider JAR-with-native-bits must also support ARM. Verify before committing. |
| **`c7i` (compute-optimised)** | Better for signature-heavy loads (lots of token issuance). | Less RAM per vCPU; a JVM may feel cramped. |
| **`r7i` (memory-optimised)** | Lots of headroom for large caches / very many concurrent sessions. | You are usually paying for RAM you do not need. |
| **Multiple types in one group** (`m7i.large m6i.large m5.large`) | AWS can substitute when capacity is tight; better spot availability. | All listed types should have similar CPU/RAM so pods behave consistently. |
| **Spot capacity** | 60–90% cheaper. | Two-minute reclaim notice. For an identity service that everything depends on, **use on-demand** — or run a small on-demand group for the baseline plus a spot group for burst, with a PDB protecting the baseline. |

---

# PART D — Best practices checklist

## Node group

- [ ] **Three AZs**, `minSize` ≥ 3 so there is always one node per AZ.
- [ ] `--capacity-type ON_DEMAND` for the identity baseline.
- [ ] **Label + taint** the group; put both a toleration *and* node affinity on the pods.
- [ ] `--ami-type AL2023_*`. Amazon Linux 2 is retired, and Kubernetes 1.35+ refuses cgroup v1 nodes.
- [ ] `--update-config maxUnavailable=1` so upgrades replace one node at a time.
- [ ] Private subnets only, with enough free IP addresses.
- [ ] Tag for cost allocation (`Service`, `Team`, `Environment`) and, if you use it, for Cluster Autoscaler discovery.
- [ ] Use a **dedicated node IAM role** with only `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly` (+ SSM for debugging). Do not attach the CNI policy if the VPC CNI addon has its own role.
- [ ] Keep node minor version ≤ control plane version, never above.
- [ ] Define the node group in **Terraform / CloudFormation / CDK** once you are past the learning stage. CLI commands are great for understanding and terrible for reproducing 18 months later.

## Keycloak

- [ ] `instances: 3` minimum in production.
- [ ] Memory **request = limit**; CPU request lower than limit.
- [ ] Pin the image tag; do not float on `latest`.
- [ ] `topologySpreadConstraints` across zones with `DoNotSchedule`.
- [ ] **`update.scheduling` mirrors `scheduling`** so upgrade Jobs can be scheduled on tainted nodes.
- [ ] A **PodDisruptionBudget** with `minAvailable` *below* the replica count.
- [ ] `proxy.headers: xforwarded` for an ALB **plus** `networkPolicy.enabled: true` so headers cannot be spoofed by bypassing the ALB.
- [ ] `hostname.hostname` exactly matches the public URL.
- [ ] Delete the bootstrap admin after creating your own; enable **MFA** on the admin realm.
- [ ] Serve the **admin console on a separate internal hostname** behind VPN, not on the public URL.
- [ ] Never expose the **management port (9000)** — health and metrics — to the internet.
- [ ] Enable the operator's `serviceMonitor` (on by default when you have Prometheus Operator) and alert on login failure rate, p99 login latency, JVM heap, and DB connection pool saturation.
- [ ] Keep realm configuration in Git and apply it with `KeycloakRealmImport`, so a rebuild is reproducible.
- [ ] Plan a **quarterly upgrade cadence**. Keycloak has no LTS: only the newest minor gets security fixes, and CVEs are published steadily.

## Security

- [ ] Enable **KMS envelope encryption** for Kubernetes Secrets on the cluster.
- [ ] Move the DB password to **External Secrets Operator** or the **Secrets Store CSI driver** so it is pulled from Secrets Manager and rotated, never pasted.
- [ ] RDS: `--storage-encrypted`, `--no-publicly-accessible`, security-group-to-security-group rules only, `--deletion-protection`.
- [ ] Turn on **AWS WAF** on the ALB with rate-based rules on `/realms/*/protocol/openid-connect/token` to blunt credential-stuffing.
- [ ] Enable **ALB access logs** to S3 and Keycloak's own event logging; ship both to CloudWatch or your SIEM.
- [ ] Restrict who can create or edit `Keycloak` CRs — the Keycloak docs are explicit that this is equivalent to namespace-admin power, because it can set the container image.
- [ ] Enable GuardDuty EKS Protection and EKS audit logging (`aws eks update-cluster-config --logging ...`).

## Reliability

- [ ] Multi-AZ database with ≥14 days of backups; **test a restore**, do not assume it works.
- [ ] Export each realm to Git regularly.
- [ ] Write the runbook: "Keycloak is down — what do I check, in what order?"
- [ ] Load-test before go-live; measure logins per second, not just CPU.
- [ ] Practise a node group upgrade in staging with the PDB in place, and confirm no login errors during the drain.

---

# PART E — Sizing: how big should things be?

Keycloak's cost is dominated by **cryptography** — hashing passwords and signing tokens. So the driver is **logins per second**, not the number of users in the database. A realm with 5 million rarely-active users can be smaller than one with 50,000 users who all log in at 9 a.m.

| Environment | Keycloak pods | Requests per pod | Node group | Database |
|---|---|---|---|---|
| **Dev / demo** | 1 | 0.5 vCPU / 1 GiB | 1 × `t3.medium`, no taint | `db.t4g.micro`, single-AZ |
| **Small production** (< 20 logins/s) | 3 | 1 vCPU / 1750 MiB | 3 × `m7i.large`, min 3 / max 6 | `db.m7g.large` Multi-AZ |
| **Medium** (20–100 logins/s) | 3–6 | 2 vCPU / 3 GiB | 3–6 × `m7i.xlarge` | `db.m7g.xlarge` or Aurora |
| **Large** (100+ logins/s) | 6+ | 4 vCPU / 4 GiB | `m7i.2xlarge`, autoscaled | Aurora PostgreSQL with read replicas |

**How to check whether your guess was right:**

```bash
kubectl -n keycloak top pods
kubectl get nodes -l workload=keycloak -o name | xargs -I{} kubectl describe {} \
  | grep -A5 "Allocated resources"
```

Look for: CPU steadily above ~70% of request → scale up. Memory near the limit → raise the limit (which also raises the JVM heap). Nodes showing high "allocated" but low actual usage → your requests are too generous and you are paying for air.

**Rules of thumb:**
- Password grants (`grant_type=password`) and password logins are the most expensive operations, because password hashing is *deliberately* slow.
- Refresh-token exchanges are much cheaper than fresh logins.
- Raising the realm's password-hashing iteration count increases security *and* CPU cost. Budget for it.
- Database load is mostly writes to session tables. If DB CPU is your bottleneck before Keycloak CPU is, look at session persistence settings before buying a bigger instance.

---

# PART F — Day-2 operations

## Scale the node group

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION" \
  --scaling-config minSize=3,maxSize=9,desiredSize=4
```

## Change labels or taints later

```bash
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION" \
  --labels 'addOrUpdateLabels={cost-center=identity}' \
  --taints 'addOrUpdateTaints=[{key=maintenance,value=true,effect=PREFER_NO_SCHEDULE}]'
```

To remove: `--labels 'removeLabels=cost-center'` / `--taints 'removeTaints=[{key=maintenance,value=true,effect=PREFER_NO_SCHEDULE}]'`.

## Upgrade the node AMI (security patches)

```bash
# See what version you are on and what is available
aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" \
  --region "$REGION" --query 'nodegroup.{k8s:version,ami:releaseVersion,status:status}'

# Patch the AMI without changing the Kubernetes version
aws eks update-nodegroup-version \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION"
```

AWS cordons one node, drains it while **respecting your PodDisruptionBudget**, terminates it, and launches a replacement — then repeats. With `maxUnavailable=1` and `minAvailable: 2`, logins keep working throughout. Watch it:

```bash
kubectl get nodes -l workload=keycloak -w
```

If a drain stalls, it is almost always a PDB that cannot be satisfied. Check with `kubectl get pdb -A`.

## Upgrade Kubernetes on the node group (after the control plane)

```bash
aws eks update-nodegroup-version \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" --region "$REGION" \
  --kubernetes-version 1.36
```

Always control plane first, nodes second. EKS also supports **version rollback within 7 days** if an upgrade goes wrong — useful, but do not treat it as a substitute for testing in staging.

## Upgrade Keycloak

```bash
kubectl -n "$NS" patch keycloak keycloak --type merge \
  -p '{"spec":{"image":"quay.io/keycloak/keycloak:26.8.0"}}'

kubectl -n "$NS" get keycloak keycloak -w
```

Before any minor upgrade: read the **upgrading guide** for that release, take an RDS snapshot, and test in staging. Keycloak runs database migrations on start, and migrations are not automatically reversible — the snapshot *is* your rollback plan.

## Rotate the database password

Because you used `--manage-master-user-password`, AWS can rotate it. Rotate, then refresh the Kubernetes Secret and restart the pods:

```bash
aws secretsmanager rotate-secret --region "$REGION" --secret-id "$DB_SECRET_ARN"

export DB_PASS=$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$DB_SECRET_ARN" --query SecretString --output text | jq -r .password)

kubectl -n "$NS" create secret generic keycloak-db-secret \
  --from-literal=username="$DB_USER" --from-literal=password="$DB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" rollout restart statefulset/keycloak
```

The manual restart is exactly the toil that **External Secrets Operator** removes — it watches Secrets Manager and updates the Kubernetes Secret automatically.

---

# PART G — Troubleshooting table

| Symptom | First command to run | Likely cause and fix |
|---|---|---|
| Pod stuck `Pending`, event says `untolerated taint` | `kubectl -n keycloak describe pod keycloak-0` | Toleration missing or misspelled. Remember: `NoSchedule` in YAML, `NO_SCHEDULE` in the AWS CLI. |
| Pod `Pending`, event says `didn't match Pod's node affinity/selector` | `kubectl get nodes --show-labels \| grep workload` | The node label does not exist or the value differs. Verify with `kubectl get nodes -l workload=keycloak`. |
| Pod `Pending`, `0/3 nodes are available: insufficient cpu` | `kubectl describe node <node> \| grep -A8 "Allocated resources"` | Requests too big for the instance type. Either lower requests or use bigger instances. |
| Pod `Pending` and topology spread named in the event | `kubectl get pods -o wide` | Fewer ready nodes than zones. Check all 3 nodes are `Ready`. |
| `ContainerCreating` forever, `failed to assign an IP address` | `aws ec2 describe-subnets --subnet-ids ... --query 'Subnets[].AvailableIpAddressCount'` | Subnet out of IPs. Use bigger subnets, or enable VPC CNI **prefix delegation**. |
| `CrashLoopBackOff`, logs mention connection refused / timeout to Postgres | `kubectl -n keycloak logs keycloak-0 --tail=50` | Security group. The DB SG must allow port 5432 **from the cluster security group**. |
| Logs mention `password authentication failed` | `kubectl -n keycloak get secret keycloak-db-secret -o jsonpath='{.data}' \| jq keys` | Wrong credentials, or the RDS password was rotated after you copied it. Recreate the Secret and restart. |
| Nodes created but never appear in `kubectl get nodes` | `aws eks describe-nodegroup ... --query 'nodegroup.health'` | No network path to the EKS API (missing NAT gateway or VPC endpoints), or the node role lacks `AmazonEKSWorkerNodePolicy`. |
| ALB returns 502 / 503 | `aws elbv2 describe-target-health --target-group-arn "$TG_ARN"` | Health check path or port wrong; or targets still registering (wait 60 s); or pods not ready. |
| ALB never gets created; Ingress has no address | `kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=50` | Missing subnet tags (`kubernetes.io/role/elb=1`), or the controller's IAM permissions are wrong. |
| Login page loads but redirects in a loop | `curl -s https://$KC_HOSTNAME/realms/master/.well-known/openid-configuration \| jq .issuer` | `proxy.headers` missing/wrong, or `hostname.hostname` does not match the public URL. |
| `issuer` shows an internal IP or the ALB DNS name | same as above | Set `hostname.hostname` to the exact public URL. |
| Admin console loads, then 403 on actions | `kubectl -n keycloak logs keycloak-0 \| grep -i hostname` | Hostname/admin-hostname mismatch. |
| Upgrade hangs; a `keycloak-update-job-*` pod is `Pending` | `kubectl -n keycloak get pods \| grep update` | **`spec.update.scheduling` is missing tolerations/affinity.** Add them (Step A10). |
| Node drain never finishes during an AMI upgrade | `kubectl get pdb -A` | A PDB cannot be satisfied — often `minAvailable` equals the replica count. |
| Everyone logged out after a deploy | `kubectl -n keycloak get pods` | All pods restarted simultaneously, wiping the distributed cache. Add/repair the PDB. |
| Certificate stuck `PENDING_VALIDATION` | `aws acm describe-certificate --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions'` | The CNAME record is missing or has a typo. Note ACM's record name usually ends with a dot. |

### Universal debugging order

```bash
# 1. What does Kubernetes think?
kubectl -n keycloak get keycloak,pods,svc,ingress,pdb

# 2. Why is a pod unhappy? (scheduling issues live in Events)
kubectl -n keycloak describe pod keycloak-0 | tail -30

# 3. What does the app itself say?
kubectl -n keycloak logs keycloak-0 --tail=100

# 4. What does the operator say?
kubectl -n keycloak logs deployment/keycloak-operator --tail=100

# 5. What does AWS say?
aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG_NAME" \
  --region "$REGION" --query 'nodegroup.health'

# 6. Recent cluster events, newest last
kubectl -n keycloak get events --sort-by=.lastTimestamp | tail -25
```

---

# PART H — Common mistakes

1. **Taint without affinity.** The classic. Your pods *can* use the dedicated nodes but wander off to others. Always set both.
2. **Using `nodeSelector` in the Keycloak CR.** The `scheduling` block supports only `affinity`, `tolerations`, `topologySpreadConstraints`, and `priorityClassName`. Use `nodeAffinity`.
3. **`NO_SCHEDULE` vs `NoSchedule`.** AWS CLI uses screaming snake case; Kubernetes YAML uses camel case. They must describe the same taint or the toleration will not match.
4. **Copying `apiVersion: v2alpha1` from an old blog post.** Current is **`v2beta1`**; the CRD prints a deprecation warning for the old one.
5. **Forgetting `update.scheduling`.** Your upgrade hangs on a `Pending` Job and it is not obvious why.
6. **No PodDisruptionBudget.** The first node group upgrade takes down all logins, usually during business hours.
7. **`minAvailable` equal to replica count.** The opposite failure: drains block forever and node upgrades never complete.
8. **Node subnets that are public, or LB subnets that lack `kubernetes.io/role/elb=1`.** Nodes get public IPs they should not have, or the ALB is never created and nothing tells you why.
9. **Running the database in a pod because it was easier on day one.** It will be the hardest thing you ever migrate.
10. **`hostname` set to an internal address or the ALB DNS name.** Tokens end up with the wrong `issuer` and every downstream app rejects them.
11. **`proxy.headers` unset behind an ALB.** Redirect loops, plus your audit log records the load balancer's IP for every user.
12. **Trusting forwarded headers without a NetworkPolicy.** Anything in the cluster that can reach the pod can now forge a client IP.
13. **Spot instances for the identity baseline.** You save a little money right up until a capacity reclaim logs out your whole company.
14. **Never upgrading.** Keycloak has **no LTS release**. Only the newest minor gets security fixes, and the release notes are full of CVEs. A year-old Keycloak is an unpatched Keycloak.
15. **Leaving the bootstrap admin account in place.** It is designed to be deleted after you create a real one.
16. **Deleting the cluster or namespace before deleting the Ingress.** The ALB is orphaned and bills you every month until someone notices.
17. **Building all of this by hand and never writing it down.** Move to Terraform/CDK once it works. These CLI commands are for *learning* what the tools do.

---

## Glossary

**Affinity** — a pod's rule about which nodes it will accept. `required...` = hard, `preferred...` = soft.
**AMI** — Amazon Machine Image; the disk image a node boots from.
**ASG** — Auto Scaling Group; keeps a target number of EC2 instances alive.
**Cordon** — mark a node "no new pods."
**CRD / CR** — Custom Resource Definition (new object *type*) / Custom Resource (one *instance*).
**Drain** — evict pods from a node politely, honouring PodDisruptionBudgets.
**Infinispan** — the distributed cache embedded in Keycloak that shares sessions between pods.
**IRSA** — IAM Roles for Service Accounts; the older way to give a pod an AWS identity, via an OIDC provider.
**Pod Identity** — the newer, simpler EKS way to give a service account an AIM role. No OIDC provider needed.
**Kubelet** — the agent on each node that talks to the control plane and starts containers.
**OIDC** — OpenID Connect; the login protocol Keycloak mainly speaks.
**PDB** — PodDisruptionBudget; the minimum healthy pods you promise to keep during voluntary disruption.
**QoS class** — `Guaranteed` (request = limit), `Burstable`, `BestEffort`. Determines eviction order.
**Realm** — an isolated tenant in Keycloak, with its own users, clients, and settings.
**Security group** — a stateful firewall attached to AWS resources; can reference other security groups.
**StatefulSet** — a workload controller giving pods stable names and ordered startup. The operator uses one.
**Taint / Toleration** — the repellent on a node / the permission slip on a pod.
**Topology spread constraint** — a rule that keeps replicas evenly distributed across zones or nodes.

---

## Official links

**Keycloak**
- Operator installation — https://www.keycloak.org/operator/installation
- Basic deployment — https://www.keycloak.org/operator/basic-deployment
- Advanced configuration (the `scheduling` stanza) — https://www.keycloak.org/operator/advanced-configuration
- Sizing CPU and memory — https://www.keycloak.org/high-availability/concepts-memory-and-cpu-sizing
- Multi-cluster HA blueprints — https://www.keycloak.org/high-availability/introduction
- Configuring the hostname — https://www.keycloak.org/server/hostname
- Configuring a reverse proxy — https://www.keycloak.org/server/reverseproxy
- Release notes / upgrading — https://www.keycloak.org/2026/07/keycloak-2670-released
- CRD source — https://github.com/keycloak/keycloak-k8s-resources

**AWS**
- Managed node groups — https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html
- `aws eks create-nodegroup` reference — https://docs.aws.amazon.com/cli/latest/reference/eks/create-nodegroup.html
- EKS best practices guides — https://aws.github.io/aws-eks-best-practices/
- Kubernetes version release notes — https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html
- AWS Load Balancer Controller — https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- EKS Pod Identity — https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html
- RDS for PostgreSQL — https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html

**Kubernetes**
- Taints and tolerations — https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Assigning pods to nodes — https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Topology spread constraints — https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- PodDisruptionBudget — https://kubernetes.io/docs/tasks/run-application/configure-pdb/

