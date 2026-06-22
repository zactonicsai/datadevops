# EKS node group + hello-world test — background guide

This explains, in plain terms, everything the companion script
(`eks-nodegroup-helloworld.sh`) does and why. Read this once and the script
will make complete sense.

---

## 1. The mental model

Think of your EKS **cluster** as the *brain* of a robot factory. The brain
decides what should happen, but it has no hands. A **node group** is a crew of
identical *worker robots* (EC2 servers) that do the actual work. You already
built the brain (the existing cluster); now you're hiring a crew and plugging
them in.

A **managed node group** means AWS babysits those workers for you: it puts them
in an EC2 Auto Scaling group, replaces broken ones, and drains them politely
during updates. Everything still runs inside *your* AWS account, so you pay
normal EC2 prices for the instances — there's no extra charge for the
"managed" part itself.

---

## 2. What you must know before starting (the inputs)

Workers literally cannot start without these:

1. **Cluster name** — which brain you're attaching to.
2. **Node IAM role** — the permission badge the workers wear (see §4).
3. **Subnets** — which part of the network the workers live in (see §5).
4. **Scaling numbers** — minimum, maximum, and desired worker count.
5. **Instance type + AMI type** — the kind of machine, and the OS image (see §3).

The script's CONFIG block at the top is where you fill these in. If you leave
`SUBNETS` empty, the script borrows the cluster's own subnets automatically.

One hard rule: worker nodes are always created at the **same Kubernetes
version as the cluster**. You can't mix versions at creation time.

---

## 3. The AMI type — the most important "latest" decision

The `--ami-type` flag picks the operating-system image baked onto each worker.
This is the part that changed recently and trips people up:

- **Amazon Linux 2 (AL2) is retired.** AWS stopped publishing new EKS-optimized
  AL2 images in late November 2025. Don't build new node groups on it.
- **AL2023 is now the default** for clusters on Kubernetes 1.30 or newer. It's
  the modern Amazon Linux: newer kernel, `cgroup v2`, and IMDSv2-only by default.
- **Bottlerocket** is a stripped-down, container-only OS — smaller, faster to
  boot, more secure, and self-updating. It has *no shell and no SSH server* by
  design (you reach it through SSM's admin container instead).

### Quick chooser

| You want…                         | Use this `--ami-type`            | Pair with instances like |
|-----------------------------------|----------------------------------|--------------------------|
| General Intel/AMD workloads       | `AL2023_x86_64_STANDARD`         | `m6i.large`, `c6i.*`     |
| Cheaper ARM (Graviton)            | `AL2023_ARM_64_STANDARD`         | `m7g.large`, `c7g.*`     |
| GPU workloads                     | `AL2023_x86_64_NVIDIA`           | `g5.*`, `p4d.*`          |
| Locked-down container-only OS     | `BOTTLEROCKET_x86_64`            | `m6i.large`, etc.        |

There are also ARM/NVIDIA/FIPS/Neuron variants and Windows images (Core/Full,
2019 through 2025). Always match the AMI **architecture** to the instance:
an ARM AMI needs Graviton instances, and vice-versa.

### A gotcha worth remembering

AL2023 enforces **IMDSv2** and, for managed node groups without a launch
template, sets the metadata "hop count" to 1. That can break pods that fetch
node metadata or credentials directly. The fixes are to use IAM Roles for
Service Accounts / EKS Pod Identity, or raise the hop limit via a launch
template.

---

## 4. The Node IAM role — the "permission badge"

Each worker runs an agent (the kubelet) that calls AWS APIs on your behalf. It
gets permission through an IAM role attached to the instance. Three managed
policies are the minimum:

- **AmazonEKSWorkerNodePolicy** — lets the worker talk to the EKS control plane.
- **AmazonEC2ContainerRegistryReadOnly** — lets it pull container images from ECR.
- **AmazonEKS_CNI_Policy** — lets it wire up pod networking.

The script adds a fourth, **AmazonSSMManagedInstanceCore**, when `ENABLE_SSM`
is true, so you can open a shell on a node without SSH keys or open ports.

If workers never show up or sit in `NotReady`, a missing policy here is one of
the two usual culprits (the other is networking, below).

---

## 5. Networking — public vs private subnets

Workers must reach the registry to download container images.

- **Private subnets (recommended):** the workers have no public address. They
  reach the internet/ECR through a **NAT gateway**, or you add **ECR
  PrivateLink endpoints** to the subnet. The upside is they aren't exposed to
  the internet.
- **Public subnets:** the subnet must have `MapPublicIpOnLaunch=true`, or the
  instances won't get an IP and won't join the cluster.

This choice also decides **how you can curl the app** (see §8). From the
internet (or AWS CloudShell, which sits outside your VPC) you simply cannot
reach a private node's IP — so for private nodes you use a LoadBalancer or
port-forward instead.

---

## 6. Capacity type and scaling

- **`ON_DEMAND`** — normal, stable instances at full price.
- **`SPOT`** — spare capacity at a deep discount that AWS can reclaim with a
  short warning. If you choose Spot, list **several instance types** so the
  group can always find capacity.

Scaling caution: if you later add the **Cluster Autoscaler**, don't change
`desiredSize` by hand — the autoscaler manages it, and manual edits can cause it
to suddenly scale up or down.

`--node-repair-config enabled=true` turns on **node auto-repair**: EKS watches
node health and automatically replaces nodes that go bad. (Needs a reasonably
recent AWS CLI; if `create-nodegroup` complains about the flag, set
`NODE_REPAIR="false"` in the config.)

---

## 7. The hello-world app — Kubernetes objects explained

- **Deployment** — a standing instruction: "keep N copies of this program
  running, and replace any that die." We ask for 2 copies.
- **Pod** — one running copy of the program (one container here).
- **Service** — a stable "front desk" address. Pods come and go, but the
  Service's address stays put and forwards traffic to whichever pods are alive.
- **`http-echo`** — a tiny program whose only job is to reply with the text you
  give it (`-text="hello world"`). It listens on port 5678.

Service types you'll meet:

- **NodePort** — opens the *same numbered door* (here 30080, in the allowed
  30000–32767 range) on *every* node. Hit any node on that port and you reach
  the app.
- **LoadBalancer** — AWS builds a public load balancer with its own address in
  front of the nodes. Curl that address from anywhere. (Costs a little while it
  exists.)

---

## 8. Three ways to curl, and when to use each

| Option | Command shape | Reaches | Works with private nodes? | Touches firewall? |
|--------|---------------|---------|---------------------------|-------------------|
| **Port-forward** (6a) | `kubectl port-forward svc/hello 18080:80` then `curl localhost:18080` | a tunnel into the cluster | ✅ yes | ❌ no |
| **LoadBalancer** (6b) | `curl http://<elb-hostname>` | a public AWS load balancer | ✅ yes | ❌ no |
| **Direct NodePort** (6c) | `curl http://<node-public-ip>:30080` | the node instance itself | ❌ no (needs public IP) | ✅ yes (opens it for your IP) |

The script always runs **6a** (the guaranteed proof, works everywhere) and
leaves 6b and 6c behind flags because they touch the network or firewall.

**6c is the most literal "connect to the node instance via curl."** It needs
the node to have a public IP and its security group opened for your address.
The script opens that rule for *just your IP* (`/32`), curls, then closes it
again so nothing is left exposed.

---

## 9. Getting a shell ON a node (the other reading of "connect")

If you meant logging *into* the EC2 box itself, use **SSM Session Manager** (no
SSH keys, no open ports). The script prints the exact command once `ENABLE_SSM`
is on:

```
aws ssm start-session --target <instance-id> --region <region>
# then, on the node:
curl http://localhost:30080      # NodePort listens on the node's own interface
```

Remember: **Bottlerocket has no normal shell** — you'll land in its special
admin/control container, not a regular Linux prompt. AL2023 gives you a normal
shell.

---

## 10. Running it

```bash
chmod +x eks-nodegroup-helloworld.sh

# edit the CONFIG block (CLUSTER_NAME, REGION, etc.), then:
./eks-nodegroup-helloworld.sh

# optional public + direct-node tests: set these in CONFIG first
#   TEST_LOADBALANCER="true"
#   TEST_NODEPORT_DIRECT="true"

# tear the demo down when finished:
./eks-nodegroup-helloworld.sh cleanup
```

The script is **idempotent**: if the IAM role or node group already exists, it
reuses them instead of erroring, so it's safe to run more than once.

---

## 11. Troubleshooting cheat-sheet

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Nodes never appear / `NotReady` | Subnet can't reach ECR, or missing node-role policy | Add NAT/PrivateLink; confirm the 3 core policies |
| `create-nodegroup` fails on `--node-repair-config` | Old AWS CLI | Set `NODE_REPAIR="false"` or upgrade CLI v2 |
| Pods stuck `Pending` | A taint with no matching toleration, or not enough capacity | Remove the taint, or raise `MAX_SIZE` |
| Pods crash with exit code 137 (OOMKilled) on a new OS | AL2023/Bottlerocket use `cgroup v2`; memory accounted differently | Raise the pod's memory limit |
| Can't curl the node IP | Nodes are private, or firewall closed | Use port-forward (6a) or a LoadBalancer (6b) |
| LoadBalancer curl times out at first | It's still warming up / DNS propagating | Wait 2–5 minutes and retry |
