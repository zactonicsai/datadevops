# Installing Karpenter on an EXISTING EKS Cluster (`my-cluster`) — Helm Install, Dedicated `karpenter` Namespace, Test Node Group, and On/Off-Hours Scheduling

**Scenario update:** the cluster **already exists** and is named **`my-cluster`**. We will NOT create a cluster. Instead we will:

1. Prepare the existing cluster (discovery tags, Pod Identity agent).
2. Create Karpenter's IAM roles and interruption queue.
3. Create a small **test node group** (`test-baseline`) to host the Karpenter controller and the scheduler CronJobs.
4. **`helm install` Karpenter into a NEW, dedicated `karpenter` namespace** (not `kube-system`).
5. Create a **test NodePool** with tight limits so experiments can't get expensive.
6. Wire up the on/off-hours dependency-ordered scheduler, updated for the new namespace.
7. Test the full off→on cycle safely, then promote to production settings.

**Last verified:** July 2026 · Karpenter v1.13.x (`v1` API) · EKS Pod Identity · Helm 3

---

## Before you start: the namespace decision (know the trade-off you're making)

Karpenter's docs currently *recommend* `kube-system` so the controller's API traffic gets critical-component priority (API Priority and Fairness). Installing into a dedicated **`karpenter`** namespace — as we do here — is fully supported and common in production; teams choose it for cleaner RBAC boundaries, separate resource quotas, easier auditing ("everything in this namespace is Karpenter"), and to keep `kube-system` uncluttered.

Two things you MUST keep consistent when using a custom namespace:

- The **Pod Identity association** (or IRSA trust policy, if you use that) must be scoped to `karpenter:karpenter` — namespace + ServiceAccount — not `kube-system:karpenter`. This is the #1 install failure: the pod starts, gets no AWS credentials, and logs `WebIdentityErr` / `NoCredentialProviders`.
- Every later command (`helm upgrade`, `kubectl logs`, NetworkPolicies) uses `-n karpenter`.

Optionally, restore the API-priority benefit inside the custom namespace by giving the deployment `priorityClassName: system-cluster-critical` (shown in Step 5).

---

## Step 0 — Variables and sanity checks against the existing cluster

```bash
export AWS_REGION="us-east-1"                       # your cluster's region
export CLUSTER_NAME="my-cluster"
export KARPENTER_NAMESPACE="karpenter"              # NEW dedicated namespace
export KARPENTER_VERSION="1.13.0"                   # check the compatibility matrix vs your K8s version
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Sanity: cluster reachable, and note the Kubernetes version (Karpenter 1.13 needs 1.25+)
kubectl version
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.{version:version,vpc:resourcesVpcConfig.vpcId,status:status}'

export VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)

# Also check what's already doing autoscaling — Karpenter must not run NEXT TO Cluster Autoscaler:
kubectl get deploy -A | grep -Ei 'cluster-autoscaler|karpenter' || echo "no existing autoscaler found"
```

> ⚠️ **If Cluster Autoscaler is running**, plan to scale it to 0 after Karpenter is verified (Step 7). Both react to pending pods and will fight over capacity.

---

## Step 1 — Tag the existing networking for discovery

On a brand-new cluster the tooling tags things for you; on an existing cluster **you** must tag the private subnets and the node security group that Karpenter's nodes should use:

```bash
# 1a. Find the private subnets your existing nodes use (adjust the filter to your naming):
aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value,Public:MapPublicIpOnLaunch}' \
  --output table

# 1b. Tag the PRIVATE subnets (repeat/adjust the list):
aws ec2 create-tags --region "${AWS_REGION}" \
  --resources subnet-0aaa111 subnet-0bbb222 subnet-0ccc333 \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"

# 1c. Find and tag the cluster/node security group:
export NODE_SG=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

aws ec2 create-tags --region "${AWS_REGION}" \
  --resources "${NODE_SG}" \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}"
```

> **Why tags instead of hardcoded IDs?** The EC2NodeClass selects by tag (`subnetSelectorTerms`/`securityGroupSelectorTerms`), so adding a subnet later is a tagging operation, not a config change. You *can* select by explicit `id:` instead if your org forbids tag mutation — just know you're signing up to edit the EC2NodeClass whenever networking changes.

---

## Step 2 — IAM: node role, controller role, Pod Identity, interruption queue

**2a. Ensure the Pod Identity agent addon exists** (existing clusters often predate it):

```bash
aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent \
  --region "${AWS_REGION}" 2>/dev/null \
  || aws eks create-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent \
       --region "${AWS_REGION}"

kubectl get ds -n kube-system eks-pod-identity-agent   # wait until DESIRED == READY
```

**2b. Create the node role, controller policy, and SQS interruption queue** using Karpenter's CloudFormation template (same one as for new clusters — it's cluster-agnostic):

```bash
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
  -o karpenter-cfn.yaml

aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file karpenter-cfn.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

This creates `KarpenterNodeRole-my-cluster`, `KarpenterControllerPolicy-my-cluster`, the SQS queue `my-cluster`, and the EventBridge rules that feed Spot-interruption/health events into it.

**2c. Controller role + Pod Identity association — scoped to the NEW namespace.** This is the step that differs from every `kube-system` tutorial:

```bash
# Trust policy for EKS Pod Identity (service principal, not OIDC):
cat > karpenter-controller-trust.json << 'EOF'
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
  --role-name "KarpenterController-${CLUSTER_NAME}" \
  --assume-role-policy-document file://karpenter-controller-trust.json

aws iam attach-role-policy \
  --role-name "KarpenterController-${CLUSTER_NAME}" \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"

# THE critical line: association bound to namespace "karpenter", SA "karpenter"
aws eks create-pod-identity-association \
  --cluster-name "${CLUSTER_NAME}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --service-account karpenter \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterController-${CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

**2d. Authorize Karpenter-launched nodes to join the cluster** via an EKS access entry (modern replacement for editing `aws-auth`):

```bash
aws eks create-access-entry \
  --cluster-name "${CLUSTER_NAME}" \
  --principal-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --type EC2_LINUX \
  --region "${AWS_REGION}"
```

> If your cluster still uses `CONFIG_MAP`-only authentication mode (very old clusters), add the node role to the `aws-auth` ConfigMap instead (`system:bootstrappers`, `system:nodes` groups) — or better, switch the cluster to `API_AND_CONFIG_MAP`.

---

## Step 3 — Create the TEST node group (`test-baseline`)

Karpenter must run on capacity it does not manage, and the on/off scheduler must survive the nightly shutdown. On an existing cluster you may already have a suitable node group — but for testing, a **small, dedicated, clearly-labeled node group** keeps the experiment isolated from existing workloads and trivially removable afterwards.

```bash
eksctl create nodegroup \
  --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --name test-baseline \
  --node-type m6i.large \
  --nodes 2 --nodes-min 2 --nodes-max 3 \
  --node-labels "role=test-baseline" \
  --managed
```

(Equivalent `aws eks create-nodegroup` works too; eksctl is shown for brevity. If you can't add node groups, an existing stable group works — just substitute its label in every `nodeSelector` below.)

Verify:

```bash
kubectl get nodes -l role=test-baseline
# Expect 2 Ready nodes
```

**What lives here:** the Karpenter controller (2 replicas), the scheduler CronJobs, and nothing else. During off-hours these 2 nodes are the only ones left running.

---

## Step 4 — Create the new namespace

```bash
kubectl create namespace "${KARPENTER_NAMESPACE}"

# Optional but recommended labels for policy engines / cost allocation:
kubectl label namespace "${KARPENTER_NAMESPACE}" \
  app.kubernetes.io/managed-by=helm \
  purpose=node-autoscaling
```

(You could let `helm install --create-namespace` do this, but creating it explicitly lets you label/annotate it first and makes the namespace's lifecycle independent of the Helm release — deleting the release won't strand or surprise-delete namespace-scoped extras you add later.)

---

## Step 5 — `helm install` Karpenter into the `karpenter` namespace

```bash
helm registry logout public.ecr.aws 2>/dev/null || true

helm install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set serviceAccount.name=karpenter \
  --set replicas=2 \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set "nodeSelector.role=test-baseline" \
  --set priorityClassName=system-cluster-critical \
  --wait
```

Line-by-line, the parts specific to this scenario:

| Flag | Why it matters here |
|---|---|
| `--namespace karpenter` | The new dedicated namespace. Must match Step 2c's Pod Identity association or the pod gets no credentials. |
| `serviceAccount.name=karpenter` | Ditto — namespace **and** SA name must both match the association. |
| `settings.interruptionQueue=my-cluster` | The SQS queue from Step 2b; without it, Spot/health interruptions kill nodes without draining. |
| `nodeSelector.role=test-baseline` | Pins the controller to the test node group — never onto nodes Karpenter itself manages. |
| `priorityClassName=system-cluster-critical` | Restores the "critical component" scheduling/eviction priority you'd otherwise get from living in `kube-system`. |
| `replicas=2` | Leader-elected HA across the two baseline nodes. |
| `--wait` | Blocks until Ready, so the next step's CRD applies can't race the CRD installation. |

**Verify — all three of these must pass before continuing:**

```bash
# 1. Pods running in the NEW namespace:
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -o wide
#    → 2/2 Running, and the NODE column shows test-baseline nodes

# 2. Credentials actually work (no WebIdentity/NoCredentialProviders errors):
kubectl logs -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter --tail=50 | grep -iE 'error|credential' || echo "logs clean"

# 3. CRDs installed:
kubectl get crds | grep karpenter
#    → ec2nodeclasses.karpenter.k8s.aws, nodepools.karpenter.sh, nodeclaims.karpenter.sh
```

> **Troubleshooting the classic failure:** pod Running but logs full of credential errors → the Pod Identity association namespace/SA doesn't match. Check with:
> `aws eks list-pod-identity-associations --cluster-name ${CLUSTER_NAME} --region ${AWS_REGION}`
> It must show `namespace: karpenter, serviceAccount: karpenter`. Fix the association, then `kubectl rollout restart deploy/karpenter -n ${KARPENTER_NAMESPACE}`.

---

## Step 6 — Test EC2NodeClass and a fenced-in TEST NodePool

Since this is an existing cluster with real workloads, the first NodePool should be **deliberately small and opt-in**: tiny CPU limit, and **tainted** so no existing workload accidentally schedules onto Karpenter capacity before you're ready.

```yaml
# test-nodeclass-pool.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: test
spec:
  role: "KarpenterNodeRole-my-cluster"
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs: { volumeSize: 50Gi, volumeType: gp3, encrypted: true }
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: test
spec:
  template:
    metadata:
      labels: { pool: test }
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: test }
      taints:
        - key: pool
          value: test
          effect: NoSchedule          # only pods that tolerate this land here
      requirements:
        - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
        - { key: karpenter.k8s.aws/instance-category, operator: In, values: ["c", "m", "r"] }
        - { key: karpenter.k8s.aws/instance-generation, operator: Gt, values: ["4"] }
      expireAfter: 720h
      terminationGracePeriod: 30m
  limits:
    cpu: "16"                          # test fence: max 16 vCPU total
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m               # fast feedback while testing
    budgets:
      - nodes: "100%"                  # unrestricted while testing; tighten in prod (Step 8)
```

```bash
kubectl apply -f test-nodeclass-pool.yaml
kubectl get nodepool test -o wide     # READY should become True
```

**Scale-up test** (pods tolerate the taint, so they can only run on the test pool):

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: inflate, namespace: default }
spec:
  replicas: 5
  selector: { matchLabels: { app: inflate } }
  template:
    metadata: { labels: { app: inflate } }
    spec:
      tolerations: [{ key: pool, value: test, effect: NoSchedule }]
      nodeSelector: { pool: test }
      containers:
        - name: pause
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
          resources: { requests: { cpu: "1" } }
EOF

kubectl get nodeclaims -w        # NodeClaim appears; node Ready in ~60-90s
kubectl get nodes -l pool=test
```

**Scale-down test** (the core of the whole on/off mechanism):

```bash
kubectl scale deployment inflate --replicas=0
kubectl get nodeclaims -w        # after ~1m of emptiness: drained, terminated, gone
kubectl delete deployment inflate
```

Watch Karpenter's own narration while this happens:

```bash
kubectl logs -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter -f | grep -iE 'launched|disrupt|terminat|consolidat'
```

---

## Step 7 — (If applicable) retire Cluster Autoscaler

Only after Step 6 passes both directions:

```bash
kubectl -n kube-system scale deploy cluster-autoscaler --replicas=0   # keep the manifest for rollback
```

Migrate workloads gradually: remove the `pool=test` taint (or add a second, untainted `apps` NodePool with real limits), then cordon+drain old ASG nodes at your own pace, or shrink the old node groups and let pending pods flow to Karpenter. **Never run both autoscalers actively at once.**

---

## Step 8 — The on/off-hours scheduler, updated for this setup

Identical machinery to the main tutorial (tier labels on workloads, ordered scripts, two CronJobs), with **three deltas** for this environment — new namespace references, the `test-baseline` nodeSelector, and production budgets on the NodePool once testing is done.

**8a. NodePool budgets for production posture** (replace the test-time `100%`-always):

```yaml
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
    budgets:
      - nodes: "10%"                                   # daytime: gentle
      - { nodes: "0", reasons: ["Underutilized"], schedule: "0 7 * * 1-5", duration: 13h }
      - { nodes: "100%", schedule: "0 20 * * 1-5", duration: 11h }   # off-hours: drain freely
```

**8b. Scheduler resources** — as in the main tutorial (namespace `scale-scheduler`, ServiceAccount, ClusterRole for `deployments|statefulsets` + `/scale`, ConfigMap with `scale-down.sh`/`scale-up.sh`), with the CronJob pod spec pinned to the test node group:

```yaml
        spec:
          serviceAccountName: scale-scheduler
          restartPolicy: Never
          nodeSelector: { role: test-baseline }        # <-- was system-baseline
          containers:
            - name: runner
              image: bitnami/kubectl:1.33              # match your cluster's minor version
              command: ["/bin/sh", "/scripts/scale-down.sh"]   # or scale-up.sh
              volumeMounts: [{ name: scripts, mountPath: /scripts }]
          volumes:
            - name: scripts
              configMap: { name: scale-scripts, defaultMode: 0755 }
```

**8c. Opt in a test app** and rehearse the full cycle end to end:

```bash
kubectl label namespace shop scale-schedule=office-hours   # your tiered test app's namespace

kubectl create job --from=cronjob/nightly-scale-down rehearsal-down -n scale-scheduler
kubectl logs -f job/rehearsal-down -n scale-scheduler      # tiers stop high→low, gated
kubectl get nodeclaims -w                                   # test-pool nodes vanish ~2m later

kubectl create job --from=cronjob/morning-scale-up rehearsal-up -n scale-scheduler
kubectl logs -f job/rehearsal-up -n scale-scheduler        # tiers start low→high, health-gated
```

During the "off" window, `kubectl get nodes` should show **only the 2 `test-baseline` nodes** — that's your entire nighttime EC2 footprint.

---

## What changed vs. the original tutorial — quick reference

| Aspect | Original (new cluster) | This guide (existing `my-cluster`) |
|---|---|---|
| Cluster | Created by eksctl/Terraform | **Pre-existing; untouched** |
| Discovery tags | Applied at creation | **You tag existing subnets + node SG** (Step 1) |
| Pod Identity agent | Installed as cluster addon at creation | **Verified/added to existing cluster** (Step 2a) |
| Namespace | `kube-system` | **New dedicated `karpenter`** (+ `system-cluster-critical` priorityClass to keep critical scheduling priority) |
| Pod Identity association | `kube-system:karpenter` | **`karpenter:karpenter`** — must match or no credentials |
| Node join auth | Handled by tooling | **Explicit access entry** for the node role (Step 2d) |
| Controller placement | `system-baseline` group | **New `test-baseline` group**, isolated and disposable |
| First NodePool | `apps`, 200 vCPU | **`test`, 16 vCPU, tainted `pool=test:NoSchedule`** — opt-in only, can't disturb existing workloads |
| Coexistence | n/a | **Cluster Autoscaler scaled to 0 only after verification** |

## Cleanup (if the test doesn't graduate)

Reverse order, letting finalizers do their jobs:

```bash
kubectl delete nodepool test && kubectl delete ec2nodeclass test   # Karpenter drains & terminates its nodes
helm uninstall karpenter -n "${KARPENTER_NAMESPACE}"
kubectl delete namespace "${KARPENTER_NAMESPACE}" scale-scheduler
aws eks delete-pod-identity-association --cluster-name "${CLUSTER_NAME}" --association-id <id> --region "${AWS_REGION}"
aws iam detach-role-policy --role-name "KarpenterController-${CLUSTER_NAME}" --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"
aws iam delete-role --role-name "KarpenterController-${CLUSTER_NAME}"
aws cloudformation delete-stack --stack-name "Karpenter-${CLUSTER_NAME}" --region "${AWS_REGION}"
eksctl delete nodegroup --cluster "${CLUSTER_NAME}" --name test-baseline --region "${AWS_REGION}"
# Un-tag subnets/SG if desired, and scale Cluster Autoscaler back up if you parked it.
```

---

### The one-paragraph summary

On the existing `my-cluster`: tag its private subnets and node security group with `karpenter.sh/discovery=my-cluster`, make sure the Pod Identity agent addon is present, and create the node role, controller role, access entry, and SQS interruption queue. Stand up a small `test-baseline` managed node group, then `helm install` Karpenter v1.13 into a **new dedicated `karpenter` namespace** — with the Pod Identity association scoped to `karpenter:karpenter` (the step everyone gets wrong), the controller pinned to the test node group, and `system-cluster-critical` priority to compensate for leaving `kube-system`. Fence the first NodePool with a 16-vCPU limit and a `pool=test:NoSchedule` taint so only opt-in workloads touch it, prove both scale-up and empty-node consolidation, and only then retire Cluster Autoscaler and attach the tier-ordered on/off CronJobs (running on `test-baseline`, so they survive the night). Same golden rule as always: the schedule scales pods; Karpenter — and nothing else — handles the nodes.
