# The Complete Guide to Fixing Network Problems in AWS EKS

*A step-by-step tutorial using the AWS CLI and kubectl*

---

## Part 0: What This Guide Is About

Imagine your app is a house. For someone to visit your house, a lot of things
have to work:

1. The house has to have an address (an **IP address**)
2. The street has to exist and connect to other streets (**subnets** and **route tables**)
3. The front door has to be unlocked (**security groups**)
4. The visitor has to be able to look up your address in the phone book (**DNS**)
5. The mail carrier has to know which houses on the street are accepting mail (**target groups**)
6. There has to be a receptionist out front directing traffic (**load balancer**)

When you say *"my app is down"* or *"connection timed out"*, what you really
mean is **one of those six things is broken**. This guide teaches you how to
check each one, in order, using commands you type into a terminal.

### Background: What is EKS?

**Kubernetes** is software that runs your applications inside little boxes
called **containers**. It decides which computer runs which container, restarts
things when they crash, and lets containers talk to each other.

**EKS (Elastic Kubernetes Service)** is Amazon's version of Kubernetes where
Amazon runs the "brain" (called the **control plane**) for you, and you provide
the "muscle" (the worker computers, called **nodes**).

Here is the whole system, top to bottom:

```
                        THE INTERNET
                             |
                             v
                  +---------------------+
                  |   Load Balancer     |   <- receptionist
                  |   (ALB or NLB)      |
                  +---------------------+
                             |
                             v
                  +---------------------+
                  |   Target Group      |   <- list of who's accepting mail
                  +---------------------+
                             |
                             v
        +--------------------------------------------+
        |             VPC (your private network)     |
        |                                            |
        |   +--------------+      +--------------+   |
        |   |  Subnet A    |      |  Subnet B    |   |
        |   |              |      |              |   |
        |   |  +--------+  |      |  +--------+  |   |
        |   |  |  EC2   |  |      |  |  EC2   |  |   |  <- worker nodes
        |   |  |  Node  |  |      |  |  Node  |  |   |
        |   |  | +----+ |  |      |  | +----+ |  |   |
        |   |  | |Pod | |  |      |  | |Pod | |  |   |  <- your app
        |   |  | +----+ |  |      |  | +----+ |  |   |
        |   |  +--------+  |      |  +--------+  |   |
        |   +--------------+      +--------------+   |
        +--------------------------------------------+
```

### Vocabulary Cheat Sheet

| Word | Simple meaning |
|---|---|
| **VPC** | Your own private network inside AWS. Like a gated neighborhood. |
| **Subnet** | A street inside that neighborhood. |
| **Public subnet** | A street with a road to the internet (via an Internet Gateway). |
| **Private subnet** | A street with no direct road to the internet. |
| **Route table** | The road map that says "to get to X, go this way." |
| **Internet Gateway (IGW)** | The main gate letting traffic in and out of the neighborhood. |
| **NAT Gateway** | A one-way gate. Private houses can go out, but strangers can't come in. |
| **Security Group (SG)** | The lock on the door. Says who is allowed in and out. **Stateful.** |
| **NACL** | A guard at the end of the street. Says who is allowed on the street. **Stateless.** |
| **ENI** | Elastic Network Interface — a virtual network card. Every IP lives on one. |
| **Pod** | The smallest unit in Kubernetes. Usually one running copy of your app. |
| **Node** | An EC2 virtual computer that runs pods. |
| **Service** | A stable name + IP that points to a changing set of pods. |
| **Target group** | The load balancer's list of "who should get traffic." |
| **CoreDNS** | The phone book inside your cluster. |

### Stateful vs. Stateless — the single most confusing thing

This trips up almost everyone, so learn it now.

**Security Groups are stateful.** If you allow traffic *in*, the reply is
automatically allowed *out*. You don't have to write a rule for the reply.

> Like a phone call: if you let someone call you, you're obviously allowed to
> talk back.

**NACLs are stateless.** If you allow traffic *in*, you must **separately**
allow the reply *out*. If you forget, the request arrives but the answer never
comes back — you get a mysterious timeout.

> Like mailing letters: letting mail in doesn't mean you're allowed to mail
> anything back. You need a second rule.

This is why a huge percentage of "it just times out" bugs are missing NACL
**ephemeral port** rules (ports 1024–65535 for the return traffic).

---

## Part 1: Setup — Do This Once Before You Start

### Step 1.1: Install the tools

You need three programs.

```bash
# AWS CLI v2 (Linux x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# kubectl - talks to Kubernetes
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# jq - makes JSON output readable
sudo apt-get install -y jq     # or: brew install jq
```

Check they work:

```bash
aws --version      # want aws-cli/2.x
kubectl version --client
jq --version
```

> **Note on versions:** AWS CLI v1 is in maintenance mode and does not get new
> features. Always use **v2**. If `aws --version` says `aws-cli/1.x`, upgrade.

### Step 1.2: Log in to AWS

```bash
aws configure
# It will ask for:
#   AWS Access Key ID
#   AWS Secret Access Key
#   Default region name      -> e.g. us-east-1
#   Default output format    -> json
```

Verify it worked:

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-name"
}
```

If you get an error here, nothing else in this guide will work. Fix this first.

### Step 1.3: Connect kubectl to your cluster

```bash
# List your clusters
aws eks list-clusters --region us-east-1
```

```json
{
    "clusters": ["my-app-cluster"]
}
```

Now connect:

```bash
aws eks update-kubeconfig --region us-east-1 --name my-app-cluster
```

Test it:

```bash
kubectl get nodes
```

```
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-1-45.ec2.internal     Ready    <none>   5d    v1.31.0
ip-10-0-2-88.ec2.internal     Ready    <none>   5d    v1.31.0
```

If a node says `NotReady`, that node has a problem — jump to **Part 6, Issue 1**.

### Step 1.4: Save variables so you don't retype things

```bash
export REGION=us-east-1
export CLUSTER=my-app-cluster
export NS=default            # your Kubernetes namespace
export APP=my-web-app        # your deployment/pod name prefix
```

---

## Part 2: The One Complete Worked Example

Before all the theory, let's walk through **one real problem from start to
finish**. This is the pattern you will repeat forever.

### The scenario

> Your teammate says: *"The website at `https://shop.example.com` returns
> **504 Gateway Timeout**. It worked yesterday."*

A **504** means: the load balancer is alive and answered you, but **it couldn't
get a reply from the app behind it.** So the load balancer is fine. Something
between the load balancer and the pod is broken.

We will now go down the chain, layer by layer.

---

### Step 2.1: Is the pod even running?

```bash
kubectl get pods -n $NS -o wide
```

```
NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE
my-web-app-7d4f8b9c5-abcde    1/1     Running   0          2h    10.0.1.132   ip-10-0-1-45.ec2.internal
my-web-app-7d4f8b9c5-fghij    0/1     Running   14         2h    10.0.2.201   ip-10-0-2-88.ec2.internal
```

**Read this carefully.** The second pod says `0/1` under READY and has restarted
**14 times**. `0/1` means "0 out of 1 containers are ready." The pod is running
but Kubernetes has decided it is **not healthy**, so it is removed from service.

> **Key idea:** `STATUS: Running` does **not** mean healthy. `READY` is the
> column that matters.

### Step 2.2: Why is it not ready?

```bash
kubectl describe pod my-web-app-7d4f8b9c5-fghij -n $NS
```

Scroll to the bottom, to the `Events:` section:

```
Events:
  Type     Reason     Age                   From     Message
  ----     ------     ----                  ----     -------
  Warning  Unhealthy  2m (x42 over 2h)      kubelet  Readiness probe failed: Get "http://10.0.2.201:8080/healthz": dial tcp 10.0.2.201:8080: connect: connection refused
  Warning  BackOff    30s (x18 over 1h)     kubelet  Back-off restarting failed container
```

**Translation:** Kubernetes tried to visit `http://10.0.2.201:8080/healthz` and
the pod said *"connection refused."*

**"Connection refused" is very different from "timed out."** Learn this:

| Error | What it means | Likely cause |
|---|---|---|
| **Connection refused** | Something *answered* and said "no." | App isn't listening on that port. App crashed. Wrong port number. |
| **Connection timed out** | Nothing answered at all. Silence. | Firewall blocking (SG/NACL), wrong route, wrong IP. |
| **No such host / NXDOMAIN** | The name couldn't be looked up. | DNS problem. Typo in the name. |
| **Connection reset** | A connection started then was killed. | App crashed mid-request. Idle timeout. |

Since we got **refused**, this is *not* a firewall problem. The app itself isn't
listening.

### Step 2.3: Look at the app's own logs

```bash
kubectl logs my-web-app-7d4f8b9c5-fghij -n $NS --previous
```

The `--previous` flag shows logs from the **crashed** container, not the new
one. This is essential for crash loops.

```
2026-07-19T09:14:22Z Starting server...
2026-07-19T09:14:22Z Connecting to database at db.internal:5432
2026-07-19T09:14:52Z FATAL: could not connect to database: dial tcp: i/o timeout
2026-07-19T09:14:52Z exiting
```

**Now we know the real story.** The web app isn't broken — it can't reach the
**database**, so it exits, so its health check fails, so the load balancer
pulls it out, so you get a 504.

This is extremely common: **the error you see is three layers away from the
actual cause.**

### Step 2.4: Test the database connection from inside the cluster

Start a temporary debug pod. This gives you a Linux shell *inside* the cluster
network:

```bash
kubectl run netdebug --rm -it --image=nicolaka/netshoot -- /bin/bash
```

> `nicolaka/netshoot` is a container image packed with network tools (dig, curl,
> nc, tcpdump, traceroute). `--rm` deletes it when you exit.

Inside that shell:

```bash
# 1. Can we resolve the DNS name?
dig +short db.internal
```

```
10.0.3.55
```

DNS works. Now:

```bash
# 2. Can we open a TCP connection to port 5432?
nc -zv 10.0.3.55 5432 -w 5
```

```
nc: connect to 10.0.3.55 port 5432 (tcp) timed out: Operation now in progress
```

**Timed out** — not refused. Per our table above, that means **a firewall is
silently dropping the packets.** Now we go check security groups.

Exit the debug pod:

```bash
exit
```

### Step 2.5: Find which security group the pod uses

In EKS with the default VPC CNI plugin, each pod gets a **real VPC IP address**
from the subnet, attached to the node's network card (ENI). So the pod inherits
the **node's** security group unless you use Security Groups for Pods.

Find the node's security group:

```bash
# Get the node name from Step 2.1, then find its instance ID
aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=private-dns-name,Values=ip-10-0-2-88.ec2.internal" \
  --query 'Reservations[].Instances[].[InstanceId,SecurityGroups]' \
  --output json
```

```json
[
    [
        "i-0abc123def456789a",
        [
            {
                "GroupId": "sg-0aaa111bbb222ccc3",
                "GroupName": "eks-node-sg"
            }
        ]
    ]
]
```

So our pods send traffic **from** `sg-0aaa111bbb222ccc3`.

### Step 2.6: Find the database's security group

```bash
aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=private-ip-address,Values=10.0.3.55" \
  --query 'Reservations[].Instances[].[InstanceId,SecurityGroups[].GroupId]' \
  --output json
```

```json
[
    [
        "i-0db9876543210fedc",
        ["sg-0ddd444eee555fff6"]
    ]
]
```

### Step 2.7: Check the database's inbound rules — the actual bug

```bash
aws ec2 describe-security-groups \
  --region $REGION \
  --group-ids sg-0ddd444eee555fff6 \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json
```

```json
[
    {
        "IpProtocol": "tcp",
        "FromPort": 5432,
        "ToPort": 5432,
        "UserIdGroupPairs": [
            {
                "GroupId": "sg-0999xxx888yyy777z",
                "Description": "old node group"
            }
        ],
        "IpRanges": []
    }
]
```

**There it is.** The database allows port 5432 from `sg-0999xxx888yyy777z` —
but our nodes are in `sg-0aaa111bbb222ccc3`. Somebody replaced the node group
yesterday, the new nodes got a new security group, and nobody updated the
database's rule.

### Step 2.8: Fix it

```bash
aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id sg-0ddd444eee555fff6 \
  --protocol tcp \
  --port 5432 \
  --source-group sg-0aaa111bbb222ccc3 \
  --group-owner 123456789012
```

```json
{
    "Return": true,
    "SecurityGroupRules": [
        {
            "SecurityGroupRuleId": "sgr-0123456789abcdef0",
            "GroupId": "sg-0ddd444eee555fff6",
            "IsEgress": false,
            "IpProtocol": "tcp",
            "FromPort": 5432,
            "ToPort": 5432,
            "ReferencedGroupInfo": {"GroupId": "sg-0aaa111bbb222ccc3"}
        }
    ]
}
```

> **Best practice:** Notice we allowed **a security group**, not an IP range.
> This is called a *security group reference*. It automatically follows the
> instances even when their IPs change. Never hardcode `0.0.0.0/0` for a
> database.

### Step 2.9: Verify the fix, end to end

```bash
# Restart the broken pods so they retry the DB connection
kubectl rollout restart deployment/my-web-app -n $NS
kubectl rollout status deployment/my-web-app -n $NS
```

```
deployment "my-web-app" successfully rolled out
```

```bash
kubectl get pods -n $NS
```

```
NAME                          READY   STATUS    RESTARTS   AGE
my-web-app-6c9d7f8a4-klmno    1/1     Running   0          45s
my-web-app-6c9d7f8a4-pqrst    1/1     Running   0          40s
```

Both `1/1`. Now check the load balancer sees them as healthy:

```bash
aws elbv2 describe-target-health \
  --region $REGION \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-app-tg/abc123 \
  --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' \
  --output table
```

```
-------------------------------------------
|          DescribeTargetHealth           |
+---------------+--------+----------------+
|  10.0.1.132   |  8080  |  healthy       |
|  10.0.2.201   |  8080  |  healthy       |
+---------------+--------+----------------+
```

Final check from the outside:

```bash
curl -o /dev/null -s -w "HTTP %{http_code} in %{time_total}s\n" https://shop.example.com
```

```
HTTP 200 in 0.184s
```

**Fixed.** 🎉

---

### What you just learned — the universal method

```
1. Look at the ERROR TYPE      -> refused vs timeout vs DNS vs reset
2. Start CLOSEST TO THE APP    -> pod first, not load balancer first
3. Read EVENTS and LOGS        -> they name the real problem
4. TEST from inside the cluster-> netshoot pod, dig + nc
5. Follow the SECURITY GROUP chain -> source SG must be allowed on dest SG
6. FIX with one CLI command
7. VERIFY at every layer going back up
```

Memorize this loop. Everything below is just detail on each step.

---

## Part 3: The Complete Diagnostic Checklist

Run these in order. Each section tells you what "good" looks like.

### Layer 1 — The Pod

```bash
# Overall status + which node + which IP
kubectl get pods -n $NS -o wide

# Full detail: events, probes, image, volumes
kubectl describe pod <POD_NAME> -n $NS

# Current logs
kubectl logs <POD_NAME> -n $NS --tail=100

# Logs from the crashed instance (critical for CrashLoopBackOff)
kubectl logs <POD_NAME> -n $NS --previous

# All containers in a multi-container pod
kubectl logs <POD_NAME> -n $NS --all-containers=true

# What ports does the container claim to expose?
kubectl get pod <POD_NAME> -n $NS -o jsonpath='{.spec.containers[*].ports}' | jq

# Environment variables (often holds wrong hostnames)
kubectl exec <POD_NAME> -n $NS -- env | sort
```

**What good looks like:** `READY 1/1`, `STATUS Running`, `RESTARTS 0`, no
`Warning` events.

**Pod status decoder:**

| Status | Meaning | First command to run |
|---|---|---|
| `Pending` | Not scheduled onto a node yet | `kubectl describe pod` → check Events for "Insufficient" or "no IP" |
| `ContainerCreating` | Stuck pulling image or attaching network | `kubectl describe pod` → look for CNI or ImagePull errors |
| `CrashLoopBackOff` | Starts, dies, repeats | `kubectl logs --previous` |
| `ImagePullBackOff` | Can't download the container image | ECR permissions, or no NAT gateway for private subnets |
| `Running` but `0/1` | Alive but failing health checks | `kubectl describe pod` → Readiness probe message |
| `Terminating` (stuck) | Won't shut down | finalizers, or a hung process |
| `Error` / `Evicted` | Killed | Node ran out of memory or disk |

### Layer 2 — The Service (Kubernetes' internal load balancer)

A **Service** gives your pods one stable name and IP. Behind it sits an
**Endpoints** (or **EndpointSlice**) object — the list of pod IPs currently
considered healthy.

```bash
kubectl get svc -n $NS
kubectl describe svc <SERVICE_NAME> -n $NS

# THE most important check: are there any endpoints?
kubectl get endpoints <SERVICE_NAME> -n $NS
kubectl get endpointslices -n $NS -l kubernetes.io/service-name=<SERVICE_NAME>
```

Good:

```
NAME         ENDPOINTS                             AGE
my-web-app   10.0.1.132:8080,10.0.2.201:8080       5d
```

Bad:

```
NAME         ENDPOINTS   AGE
my-web-app   <none>      5d
```

**`<none>` means the Service matches zero pods.** Almost always a **label
selector mismatch**. Compare:

```bash
# What labels does the Service look for?
kubectl get svc <SERVICE_NAME> -n $NS -o jsonpath='{.spec.selector}' | jq
# {"app":"my-web-app"}

# What labels do the pods actually have?
kubectl get pods -n $NS --show-labels
# NAME  ... LABELS
# ...       app=my-webapp,pod-template-hash=7d4f8b9c5
```

`my-web-app` vs `my-webapp` — one hyphen. That's the bug. Fix the selector or
the pod labels so they match exactly.

**The other Service trap: `targetPort`.**

```bash
kubectl get svc <SERVICE_NAME> -n $NS -o jsonpath='{.spec.ports}' | jq
```

```json
[{"port": 80, "targetPort": 8080, "protocol": "TCP"}]
```

- `port` = the port the Service listens on
- `targetPort` = the port **on the pod** it forwards to

If your app listens on 3000 but `targetPort` says 8080, you get connection
refused. Confirm what the app actually listens on:

```bash
kubectl exec <POD_NAME> -n $NS -- netstat -tlnp 2>/dev/null || \
kubectl exec <POD_NAME> -n $NS -- ss -tlnp
```

```
State   Recv-Q  Send-Q  Local Address:Port   Peer Address:Port
LISTEN  0       128           0.0.0.0:3000        0.0.0.0:*
```

> **Trap within the trap:** if it says `127.0.0.1:3000` instead of
> `0.0.0.0:3000`, the app is only listening to *itself*. Nothing outside the
> container can reach it. Fix the app config to bind to `0.0.0.0`.

### Layer 3 — DNS

Inside Kubernetes, DNS is handled by **CoreDNS**. Names follow this pattern:

```
<service>.<namespace>.svc.cluster.local
                |
        e.g.  my-web-app.default.svc.cluster.local
```

Check CoreDNS is alive:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

```
NAME                       READY   STATUS    RESTARTS   AGE
coredns-5d78c9869d-4xk2p   1/1     Running   0          5d
coredns-5d78c9869d-9wm7t   1/1     Running   0          5d
```

You should have **at least 2**. If you have 0, all name lookups fail
cluster-wide.

Test resolution from inside:

```bash
kubectl run dnstest --rm -it --image=nicolaka/netshoot -- /bin/bash

# Internal service
dig +short my-web-app.default.svc.cluster.local
# 172.20.145.33

# Kubernetes API itself
dig +short kubernetes.default.svc.cluster.local
# 172.20.0.1

# External name (tests internet path too)
dig +short amazonaws.com

# Which DNS server is the pod using?
cat /etc/resolv.conf
```

```
search default.svc.cluster.local svc.cluster.local cluster.local ec2.internal
nameserver 172.20.0.10
options ndots:5
```

`nameserver 172.20.0.10` should equal the kube-dns Service IP:

```bash
kubectl get svc -n kube-system kube-dns
```

Read CoreDNS logs if lookups fail:

```bash
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

For **AWS-side (Route 53) DNS**, check the public record:

```bash
# Find the hosted zone
aws route53 list-hosted-zones --query 'HostedZones[].[Id,Name]' --output table

# List records in it
aws route53 list-resource-record-sets \
  --hosted-zone-id Z1234567890ABC \
  --query "ResourceRecordSets[?Name=='shop.example.com.']" \
  --output json
```

```json
[
    {
        "Name": "shop.example.com.",
        "Type": "A",
        "AliasTarget": {
            "HostedZoneId": "Z35SXDOTRQ7X7K",
            "DNSName": "dualstack.my-alb-123456.us-east-1.elb.amazonaws.com.",
            "EvaluateTargetHealth": true
        }
    }
]
```

Confirm that DNS name actually resolves and matches your load balancer:

```bash
dig +short shop.example.com
nslookup my-alb-123456.us-east-1.elb.amazonaws.com
```

> **Important:** Load balancer IPs **change over time**. Never point an `A`
> record at a hardcoded ALB IP. Always use an **Alias** record (as above) or a
> `CNAME`.

**VPC-level DNS switches.** If nothing in the VPC can resolve names:

```bash
aws ec2 describe-vpc-attribute --vpc-id vpc-0abc123 --attribute enableDnsSupport --region $REGION
aws ec2 describe-vpc-attribute --vpc-id vpc-0abc123 --attribute enableDnsHostnames --region $REGION
```

Both must be `true`:

```json
{"EnableDnsSupport": {"Value": true}, "VpcId": "vpc-0abc123"}
```

Turn on if needed:

```bash
aws ec2 modify-vpc-attribute --vpc-id vpc-0abc123 --enable-dns-support "{\"Value\":true}"
aws ec2 modify-vpc-attribute --vpc-id vpc-0abc123 --enable-dns-hostnames "{\"Value\":true}"
```

### Layer 4 — The Node (EC2)

```bash
kubectl get nodes -o wide
kubectl describe node <NODE_NAME>
```

Look at the `Conditions` block:

```
Conditions:
  Type             Status  Reason                       Message
  ----             ------  ------                       -------
  MemoryPressure   False   KubeletHasSufficientMemory   kubelet has sufficient memory
  DiskPressure     False   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure      False   KubeletHasSufficientPID      kubelet has sufficient PID
  Ready            True    KubeletReady                 kubelet is posting ready status
```

You want `Ready: True` and every `Pressure: False`.

Now inspect the EC2 instance behind the node:

```bash
# Find the instance
aws ec2 describe-instances \
  --region $REGION \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,SubnetId,State.Name,SecurityGroups[0].GroupId,InstanceType]' \
  --output table
```

```
--------------------------------------------------------------------------------------------------
|                                       DescribeInstances                                        |
+----------------------+-------------+-------------------+---------+----------------------+------+
|  i-0abc123def456789a |  10.0.1.45  |  subnet-0aaa111   | running |  sg-0aaa111bbb222ccc3| m5.large |
|  i-0def456abc789012b |  10.0.2.88  |  subnet-0bbb222   | running |  sg-0aaa111bbb222ccc3| m5.large |
+----------------------+-------------+-------------------+---------+----------------------+------+
```

Check the node's own status checks (is the hardware/network okay?):

```bash
aws ec2 describe-instance-status \
  --region $REGION \
  --instance-ids i-0abc123def456789a \
  --query 'InstanceStatuses[].[InstanceStatus.Status,SystemStatus.Status]' \
  --output table
```

Both should say `ok`.

Look at the network cards (ENIs) attached — this tells you IP capacity:

```bash
aws ec2 describe-network-interfaces \
  --region $REGION \
  --filters "Name=attachment.instance-id,Values=i-0abc123def456789a" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,PrivateIpAddresses[].PrivateIpAddress]' \
  --output json
```

```json
[
    ["eni-0111aaa", ["10.0.1.45", "10.0.1.132", "10.0.1.187"]],
    ["eni-0222bbb", ["10.0.1.201", "10.0.1.244"]]
]
```

> **Why this matters:** With the AWS VPC CNI, **every pod uses a real VPC IP**.
> Each instance type supports a limited number of ENIs and IPs per ENI. An
> `m5.large` supports 3 ENIs × 10 IPs = 29 usable pod IPs. Run out and new pods
> sit in `Pending` forever with the message *"failed to assign an IP address."*

Formula: `max pods = (ENIs × (IPs per ENI − 1)) + 2`

Look up your instance type's limits:

```bash
aws ec2 describe-instance-types \
  --region $REGION \
  --instance-types m5.large \
  --query 'InstanceTypes[].NetworkInfo.[MaximumNetworkInterfaces,Ipv4AddressesPerInterface]' \
  --output table
```

### Layer 5 — The VPC, Subnets, and Routes

```bash
# What VPC is the cluster in?
aws eks describe-cluster --region $REGION --name $CLUSTER \
  --query 'cluster.resourcesVpcConfig' --output json
```

```json
{
    "subnetIds": ["subnet-0aaa111", "subnet-0bbb222", "subnet-0ccc333"],
    "securityGroupIds": ["sg-0cluster111"],
    "clusterSecurityGroupId": "sg-0eks-managed222",
    "vpcId": "vpc-0abc123",
    "endpointPublicAccess": true,
    "endpointPrivateAccess": true,
    "publicAccessCidrs": ["0.0.0.0/0"]
}
```

List all subnets with their free IP counts:

```bash
aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,AvailableIpAddressCount,MapPublicIpOnLaunch]' \
  --output table
```

```
-----------------------------------------------------------------------------------
|                                 DescribeSubnets                                 |
+------------------+---------------+-------------+---------+---------------------+
|  subnet-0aaa111  |  10.0.1.0/24  |  us-east-1a |   198   |  False              |
|  subnet-0bbb222  |  10.0.2.0/24  |  us-east-1b |     3   |  False              |
|  subnet-0ccc333  |  10.0.3.0/24  |  us-east-1c |   241   |  True               |
+------------------+---------------+-------------+---------+---------------------+
```

> **Red flag:** `subnet-0bbb222` has only **3** free IPs. Pods will start failing
> to schedule there. Add a bigger CIDR or a new subnet.

Check the route table for a subnet — this decides where traffic can go:

```bash
aws ec2 describe-route-tables \
  --region $REGION \
  --filters "Name=association.subnet-id,Values=subnet-0aaa111" \
  --query 'RouteTables[].Routes' \
  --output json
```

A **private** subnet should look like:

```json
[
    [
        {"DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local", "State": "active"},
        {"DestinationCidrBlock": "0.0.0.0/0", "NatGatewayId": "nat-0abc123", "State": "active"}
    ]
]
```

A **public** subnet should look like:

```json
[
    [
        {"DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local", "State": "active"},
        {"DestinationCidrBlock": "0.0.0.0/0", "GatewayId": "igw-0xyz789", "State": "active"}
    ]
]
```

**Rules to remember:**
- `local` route = traffic inside the VPC. Always present, can't be removed.
- `0.0.0.0/0 → igw-*` = public subnet (direct internet).
- `0.0.0.0/0 → nat-*` = private subnet (outbound-only internet).
- **No `0.0.0.0/0` at all** = fully isolated. Image pulls from Docker Hub and
  ECR will fail unless you have VPC endpoints.
- Any route in state `blackhole` = it points at a deleted gateway. **Broken.**

Check the NAT gateway is actually healthy:

```bash
aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=vpc-id,Values=vpc-0abc123" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,NatGatewayAddresses[0].PublicIp]' \
  --output table
```

State must be `available`. A NAT gateway **must live in a public subnet** — a
very common mistake is putting it in a private one, which breaks all outbound
traffic.

Check the internet gateway is attached:

```bash
aws ec2 describe-internet-gateways \
  --region $REGION \
  --filters "Name=attachment.vpc-id,Values=vpc-0abc123" \
  --query 'InternetGateways[].[InternetGatewayId,Attachments[0].State]' \
  --output table
```

Should say `available`.

### Layer 6 — Security Groups

```bash
# Show all rules in a readable table
aws ec2 describe-security-groups \
  --region $REGION \
  --group-ids sg-0aaa111bbb222ccc3 \
  --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(`,`,IpRanges[].CidrIp),join(`,`,UserIdGroupPairs[].GroupId)]' \
  --output table
```

```
-------------------------------------------------------------------------
|                        DescribeSecurityGroups                         |
+------+-------+-------+------------------+---------------------------+
|  tcp |  443  |  443  |  None            |  sg-0eks-managed222        |
|  tcp |  1025 | 65535 |  None            |  sg-0eks-managed222        |
|  -1  |  None |  None |  None            |  sg-0aaa111bbb222ccc3      |
+------+-------+-------+------------------+---------------------------+
```

Also check **outbound**:

```bash
aws ec2 describe-security-groups \
  --region $REGION \
  --group-ids sg-0aaa111bbb222ccc3 \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json
```

Default is allow-all out:

```json
[{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]
```

If someone tightened egress and forgot port 443, nodes can't reach the EKS
control plane and **all nodes go NotReady**.

**Required EKS security group rules:**

| Direction | Source/Dest | Port | Why |
|---|---|---|---|
| Node **inbound** | Cluster SG | 443 | Control plane → kubelet |
| Node **inbound** | Cluster SG | 10250 | `kubectl exec`, `logs`, metrics |
| Node **inbound** | Node SG (itself) | all | Pod-to-pod across nodes |
| Node **inbound** | Node SG | 53 TCP+UDP | CoreDNS between nodes |
| Node **outbound** | 0.0.0.0/0 | 443 | Reach EKS API, ECR, S3 |
| Cluster **inbound** | Node SG | 443 | Nodes → control plane |
| Node **inbound** | ALB SG | app port | Load balancer → pods |

Add a missing rule:

```bash
# Allow all traffic between nodes (pod-to-pod)
aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id sg-0aaa111bbb222ccc3 \
  --protocol -1 \
  --source-group sg-0aaa111bbb222ccc3

# Allow the ALB to reach pods on port 8080
aws ec2 authorize-security-group-ingress \
  --region $REGION \
  --group-id sg-0aaa111bbb222ccc3 \
  --protocol tcp --port 8080 \
  --source-group sg-0alb999
```

Remove a bad rule:

```bash
aws ec2 revoke-security-group-ingress \
  --region $REGION \
  --group-id sg-0ddd444 \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
```

### Layer 7 — NACLs (the stateless street guard)

```bash
aws ec2 describe-network-acls \
  --region $REGION \
  --filters "Name=association.subnet-id,Values=subnet-0aaa111" \
  --query 'NetworkAcls[].[NetworkAclId,Entries]' \
  --output json
```

```json
[
    [
        "acl-0abc123",
        [
            {"RuleNumber": 100, "Protocol": "-1", "RuleAction": "allow", "Egress": false, "CidrBlock": "0.0.0.0/0"},
            {"RuleNumber": 32767, "Protocol": "-1", "RuleAction": "deny", "Egress": false, "CidrBlock": "0.0.0.0/0"},
            {"RuleNumber": 100, "Protocol": "-1", "RuleAction": "allow", "Egress": true, "CidrBlock": "0.0.0.0/0"},
            {"RuleNumber": 32767, "Protocol": "-1", "RuleAction": "deny", "Egress": true, "CidrBlock": "0.0.0.0/0"}
        ]
    ]
]
```

That is the **default NACL** — allow everything. Good.

**How NACLs are evaluated:** rules run in number order, **lowest first**, and
the **first match wins**. Rule 32767 (`deny all`) is the fallback.

The classic bug:

```json
{"RuleNumber": 100, "Protocol": "6", "PortRange": {"From": 443, "To": 443}, "RuleAction": "allow", "Egress": false}
{"RuleNumber": 32767, "Protocol": "-1", "RuleAction": "deny", "Egress": true}
```

Inbound 443 is allowed, but **outbound is denied**. Because NACLs are stateless,
the reply can never leave. The request arrives, the app answers, and the answer
is silently thrown away → **timeout with no logs anywhere.**

Fix by allowing **ephemeral ports** outbound:

```bash
aws ec2 create-network-acl-entry \
  --region $REGION \
  --network-acl-id acl-0abc123 \
  --rule-number 200 \
  --protocol tcp \
  --port-range From=1024,To=65535 \
  --cidr-block 0.0.0.0/0 \
  --rule-action allow \
  --egress
```

> **Best practice:** Use security groups for your rules. Leave NACLs at the
> default allow-all unless you have a compliance requirement. NACLs are blunt,
> stateless, and cause exactly this kind of invisible failure.

### Layer 8 — Target Groups

The target group is the load balancer's list of "who gets traffic."

```bash
# List all target groups
aws elbv2 describe-target-groups \
  --region $REGION \
  --query 'TargetGroups[].[TargetGroupName,Protocol,Port,TargetType,VpcId,HealthCheckPath,HealthCheckPort]' \
  --output table
```

```
--------------------------------------------------------------------------------------
|                                DescribeTargetGroups                                |
+---------------+------+------+----------+--------------+-------------+-------------+
|  my-app-tg    | HTTP | 8080 |  ip      | vpc-0abc123  |  /healthz   | traffic-port |
+---------------+------+------+----------+--------------+-------------+-------------+
```

**The health check — this is where most 502/503/504 errors come from:**

```bash
aws elbv2 describe-target-health \
  --region $REGION \
  --target-group-arn <TG_ARN> \
  --output json
```

Unhealthy example:

```json
{
    "TargetHealthDescriptions": [
        {
            "Target": {"Id": "10.0.1.132", "Port": 8080},
            "TargetHealth": {
                "State": "unhealthy",
                "Reason": "Target.Timeout",
                "Description": "Request timed out"
            }
        }
    ]
}
```

**Decoding target health reasons:**

| Reason | Plain English | Fix |
|---|---|---|
| `Target.Timeout` | LB got no answer at all | Security group doesn't allow LB → pod on that port |
| `Target.ResponseCodeMismatch` | App answered, but wrong status code | Health check expects 200, app returns 302/401. Adjust `--matcher` or the path |
| `Target.NotRegistered` | Not in the list | Service/Ingress annotation issue; controller didn't register it |
| `Target.FailedHealthChecks` | Failed repeatedly | Check the path exists: `kubectl exec ... curl localhost:8080/healthz` |
| `Target.DeregistrationInProgress` | Being removed | Normal during a deploy |
| `Elb.InternalError` | AWS-side issue | Check ALB subnets have free IPs |
| `Target.InvalidState` | Instance is stopping/terminated | Node is being replaced |

Test the health check yourself, from inside the pod:

```bash
kubectl exec <POD_NAME> -n $NS -- curl -sv http://localhost:8080/healthz
```

```
< HTTP/1.1 200 OK
{"status":"ok"}
```

If that works but the LB still times out, it's a **security group** problem, not
an app problem.

Adjust health check settings:

```bash
aws elbv2 modify-target-group \
  --region $REGION \
  --target-group-arn <TG_ARN> \
  --health-check-path /healthz \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200-299
```

> **`TargetType` matters a lot in EKS.**
> - `ip` mode = the LB talks **directly to pod IPs**. Faster, one less hop.
>   Requires the LB security group to reach the **node** SG on the pod port.
> - `instance` mode = the LB talks to a **NodePort** on the EC2 node, which then
>   forwards. Requires the node SG to allow ports 30000–32767 from the LB.
>
> Most modern EKS setups use `ip` mode. Check with the annotation
> `alb.ingress.kubernetes.io/target-type: ip`.

### Layer 9 — Load Balancers

```bash
aws elbv2 describe-load-balancers \
  --region $REGION \
  --query 'LoadBalancers[].[LoadBalancerName,DNSName,Scheme,Type,State.Code,join(`,`,AvailabilityZones[].SubnetId)]' \
  --output table
```

```
------------------------------------------------------------------------------------------------------------
|                                        DescribeLoadBalancers                                             |
+-------------+-------------------------------------------------+----------------+-------+--------+-------+
| my-alb      | my-alb-123456.us-east-1.elb.amazonaws.com        | internet-facing| application | active | subnet-0ccc333,subnet-0ddd444 |
+-------------+-------------------------------------------------+----------------+-------+--------+-------+
```

- `Scheme: internet-facing` → must be in **public** subnets.
- `Scheme: internal` → in private subnets, only reachable from inside the VPC.
- `State.Code` must be `active`. `provisioning` = wait. `failed` = check the events.

Check the listeners (what ports it accepts):

```bash
aws elbv2 describe-listeners \
  --region $REGION \
  --load-balancer-arn <LB_ARN> \
  --query 'Listeners[].[Port,Protocol,SslPolicy,DefaultActions[0].TargetGroupArn]' \
  --output table
```

Check the routing rules:

```bash
aws elbv2 describe-rules \
  --region $REGION \
  --listener-arn <LISTENER_ARN> \
  --output json
```

Check the LB's security group:

```bash
aws elbv2 describe-load-balancers \
  --region $REGION \
  --load-balancer-arns <LB_ARN> \
  --query 'LoadBalancers[0].SecurityGroups'
```

Then confirm that SG allows 80/443 in from the internet:

```bash
aws ec2 describe-security-groups --region $REGION --group-ids sg-0alb999 \
  --query 'SecurityGroups[0].IpPermissions' --output json
```

> **ALB subnet requirement:** an ALB needs **at least 2 subnets in 2 different
> Availability Zones**, each with **at least 8 free IP addresses**. If you don't
> meet this, ALB creation silently fails. Check with the `describe-subnets`
> command from Layer 5.

**Required subnet tags for auto-discovery:**

```bash
aws ec2 describe-subnets --region $REGION --subnet-ids subnet-0ccc333 \
  --query 'Subnets[0].Tags' --output json
```

```json
[
    {"Key": "kubernetes.io/role/elb", "Value": "1"},
    {"Key": "kubernetes.io/cluster/my-app-cluster", "Value": "shared"}
]
```

- Public subnets need `kubernetes.io/role/elb = 1`
- Private subnets need `kubernetes.io/role/internal-elb = 1`

Missing these is the #1 reason an Ingress gets created but **no ALB ever
appears**. Add them:

```bash
aws ec2 create-tags --region $REGION \
  --resources subnet-0ccc333 \
  --tags Key=kubernetes.io/role/elb,Value=1
```

### Layer 10 — Ingress and the Controller

```bash
kubectl get ingress -n $NS
kubectl describe ingress <INGRESS_NAME> -n $NS
```

```
Name:             my-app-ingress
Address:          my-alb-123456.us-east-1.elb.amazonaws.com
Rules:
  Host             Path  Backends
  ----             ----  --------
  shop.example.com /     my-web-app:80 (10.0.1.132:8080,10.0.2.201:8080)
Events:
  Type    Reason                  Age   From     Message
  ----    ------                  ----  -----    -------
  Normal  SuccessfullyReconciled  2m    ingress  Successfully reconciled
```

**If `Address:` is empty**, the controller failed. Read its logs:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

Common messages and meanings:

```
couldn't auto-discover subnets: unable to resolve at least one subnet
   -> missing kubernetes.io/role/elb tags

AccessDenied: User is not authorized to perform: elasticloadbalancing:CreateLoadBalancer
   -> the controller's IAM role is missing permissions

InvalidSubnet: not enough free IP addresses
   -> subnets too full
```

Check the controller is even installed and running:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Layer 11 — The VPC CNI (pod networking plugin)

```bash
# Is the CNI running on every node?
kubectl get daemonset -n kube-system aws-node
```

```
NAME       DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   AGE
aws-node   2         2         2       2            2           5d
```

`DESIRED` must equal `READY`. If not:

```bash
kubectl logs -n kube-system -l k8s-app=aws-node --tail=100
```

Key error to recognize:

```
failed to assign an IP address to container
ipamd: no available IP addresses
```

That means the subnet is out of IPs, or the node hit its ENI limit.

Check CNI settings:

```bash
kubectl describe daemonset aws-node -n kube-system | grep -A2 -E "WARM_IP_TARGET|ENABLE_PREFIX_DELEGATION|MINIMUM_IP_TARGET"
```

> **Best practice — prefix delegation:** Turning on
> `ENABLE_PREFIX_DELEGATION=true` lets each ENI hand out a `/28` block (16 IPs)
> at once instead of one at a time. This raises pods-per-node dramatically
> (an `m5.large` goes from 29 to 110). Enable it:
>
> ```bash
> kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
> ```
>
> **Pro:** far more pods per node, fewer nodes, lower cost.
> **Con:** IPs are reserved in blocks, so a fragmented subnet wastes addresses.
> Requires Nitro-based instances.

Check the CNI addon version:

```bash
aws eks describe-addon --region $REGION --cluster-name $CLUSTER --addon-name vpc-cni \
  --query 'addon.[addonVersion,status]' --output table

# See what's available
aws eks describe-addon-versions --addon-name vpc-cni \
  --kubernetes-version 1.31 \
  --query 'addons[0].addonVersions[0:3].addonVersion'
```

### Layer 12 — Network Policies

Network policies are Kubernetes-level firewalls between pods. **If any policy
selects a pod, that pod switches to default-deny** for the direction covered.

```bash
kubectl get networkpolicies --all-namespaces
kubectl describe networkpolicy <NAME> -n $NS
```

```
Spec:
  PodSelector: app=my-web-app
  Allowing ingress traffic:
    From:
      PodSelector: app=frontend
    Ports: 8080/TCP
  Policy Types: Ingress
```

This means: **only** pods labeled `app=frontend` can reach `my-web-app` on 8080.
Everything else — including your debug pod and health checks — is blocked.

> **Gotcha:** Network policies only work if enforcement is enabled. On EKS you
> need either the VPC CNI's built-in network policy support
> (`ENABLE_NETWORK_POLICY=true`) or Calico/Cilium. Without one, policies exist
> in the API but do nothing — which is its own kind of confusing.

---

## Part 4: A Complete Problem Catalog

### Issue 1 — Node stuck in `NotReady`

**Symptoms:** `kubectl get nodes` shows `NotReady`. Pods on it get evicted.

**Causes and fixes:**

1. **Node can't reach the EKS API (port 443 outbound blocked)**
   ```bash
   aws ec2 describe-security-groups --region $REGION --group-ids <NODE_SG> \
     --query 'SecurityGroups[0].IpPermissionsEgress' --output json
   ```
   Fix:
   ```bash
   aws ec2 authorize-security-group-egress --region $REGION \
     --group-id <NODE_SG> --protocol tcp --port 443 --cidr 0.0.0.0/0
   ```

2. **Private cluster endpoint but no route/VPC endpoint**
   ```bash
   aws eks describe-cluster --region $REGION --name $CLUSTER \
     --query 'cluster.resourcesVpcConfig.[endpointPrivateAccess,endpointPublicAccess]'
   ```
   If private-only, you need VPC endpoints for EC2, ECR, S3, STS:
   ```bash
   aws ec2 describe-vpc-endpoints --region $REGION \
     --filters "Name=vpc-id,Values=vpc-0abc123" \
     --query 'VpcEndpoints[].[ServiceName,State]' --output table
   ```

3. **CNI crashed**
   ```bash
   kubectl get pods -n kube-system -l k8s-app=aws-node -o wide
   kubectl logs -n kube-system <aws-node-pod>
   ```

4. **Node ran out of disk**
   ```bash
   kubectl describe node <NODE> | grep -i pressure
   ```

5. **IAM role missing** — the node role needs
   `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`,
   `AmazonEC2ContainerRegistryReadOnly`:
   ```bash
   aws iam list-attached-role-policies --role-name <NODE_ROLE_NAME>
   ```

### Issue 2 — Pod stuck in `Pending`

```bash
kubectl describe pod <POD> -n $NS | tail -20
```

| Event message | Meaning | Fix |
|---|---|---|
| `Insufficient cpu/memory` | No node has room | Scale nodes, or lower resource requests |
| `failed to assign an IP address` | Subnet or ENI exhausted | Enable prefix delegation, add subnets |
| `node(s) had untolerated taint` | Node is reserved | Add a toleration |
| `didn't match node selector` | No node has the required label | Fix nodeSelector, or label a node |
| `no nodes available` | Cluster has zero ready nodes | See Issue 1 |
| `pod has unbound PersistentVolumeClaim` | Storage not ready | Check the EBS CSI driver |

### Issue 3 — `CrashLoopBackOff`

```bash
kubectl logs <POD> -n $NS --previous
kubectl describe pod <POD> -n $NS
```

Network-related causes:
- Can't reach a database or API → check SGs (see Part 2)
- Can't resolve a DNS name → check CoreDNS
- Binding to a port already in use (with `hostNetwork: true`)
- Wrong environment variable pointing to a dead endpoint

### Issue 4 — `ImagePullBackOff`

```bash
kubectl describe pod <POD> -n $NS | grep -A5 Events
```

| Message | Cause | Fix |
|---|---|---|
| `no such host` for `*.ecr.amazonaws.com` | Private subnet with no NAT and no ECR VPC endpoint | Add NAT gateway or ECR endpoints |
| `denied: not authorized` | Node IAM role lacks ECR read | Attach `AmazonEC2ContainerRegistryReadOnly` |
| `manifest unknown` | Wrong image tag | Fix the tag |
| `i/o timeout` | Egress 443 blocked | Open egress |

Create ECR VPC endpoints for a private cluster:

```bash
aws ec2 create-vpc-endpoint --region $REGION --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.$REGION.ecr.dkr \
  --vpc-endpoint-type Interface \
  --subnet-ids subnet-0aaa111 subnet-0bbb222 \
  --security-group-ids sg-0aaa111bbb222ccc3 \
  --private-dns-enabled

aws ec2 create-vpc-endpoint --region $REGION --vpc-id vpc-0abc123 \
  --service-name com.amazonaws.$REGION.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids rtb-0private111
```

> ECR stores the actual image layers in **S3**, so you need the S3 gateway
> endpoint too. Forgetting this is a classic mistake.

### Issue 5 — Service has no endpoints

Covered in Layer 2. Checklist:
1. Label selector matches pod labels **exactly**
2. Pods are `READY 1/1` (not-ready pods are excluded)
3. Correct namespace
4. `targetPort` matches the container's real port

### Issue 6 — Pod-to-pod traffic fails across nodes

```bash
# From pod A, hit pod B's IP directly
kubectl exec <POD_A> -n $NS -- curl -m 5 http://<POD_B_IP>:8080/
```

Causes:
- Node SG doesn't allow traffic **from itself** → add the self-referencing rule
- NACL blocks the pod CIDR range
- Network policy denying it
- Pods in different VPCs without peering

### Issue 7 — Can't reach the internet from a pod

```bash
kubectl run nettest --rm -it --image=nicolaka/netshoot -- /bin/bash
curl -sI https://aws.amazon.com | head -1
dig +short google.com
```

Checklist:
1. Route table has `0.0.0.0/0 → nat-*` (private) or `→ igw-*` (public)
2. NAT gateway state is `available` and it lives in a **public** subnet
3. NAT gateway's subnet route table has `0.0.0.0/0 → igw-*`
4. SG egress allows 443/80
5. NACL allows outbound **and** inbound ephemeral ports 1024–65535
6. Internet gateway is attached

### Issue 8 — ALB returns 502 / 503 / 504

| Code | Meaning | Where to look |
|---|---|---|
| **502 Bad Gateway** | App returned something malformed, or closed the connection | App logs; check keep-alive timeout > ALB idle timeout |
| **503 Service Unavailable** | **No healthy targets at all** | `describe-target-health` — everything is unhealthy or the group is empty |
| **504 Gateway Timeout** | App too slow or unreachable | SG rules; app performance; raise ALB idle timeout |
| **460** | Client hung up before the LB replied | Usually harmless |
| **463** | Bad `X-Forwarded-For` header | Malformed client request |

Enable ALB access logs to see real data:

```bash
aws elbv2 modify-load-balancer-attributes \
  --region $REGION --load-balancer-arn <LB_ARN> \
  --attributes Key=access_logs.s3.enabled,Value=true \
               Key=access_logs.s3.bucket,Value=my-alb-logs-bucket
```

Fix a 502 caused by timeout mismatch:

```bash
# ALB idle timeout must be LOWER than your app's keep-alive timeout
aws elbv2 modify-load-balancer-attributes \
  --region $REGION --load-balancer-arn <LB_ARN> \
  --attributes Key=idle_timeout.timeout_seconds,Value=60
```

### Issue 9 — DNS fails intermittently

Symptoms: works 9 times, fails the 10th. Random `i/o timeout` on lookups.

Causes and fixes:

1. **Too few CoreDNS replicas**
   ```bash
   kubectl scale deployment coredns -n kube-system --replicas=3
   ```

2. **`ndots:5` causing lookup storms.** With `ndots:5`, looking up
   `api.example.com` first tries `api.example.com.default.svc.cluster.local`,
   then `.svc.cluster.local`, then `.cluster.local`, then `.ec2.internal`, and
   *finally* the real name — 5 queries per lookup. Fix by using a fully
   qualified name with a trailing dot (`api.example.com.`) or lowering ndots in
   the pod spec:
   ```yaml
   dnsConfig:
     options:
       - name: ndots
         value: "2"
   ```

3. **VPC DNS rate limit.** AWS limits each ENI to **1024 packets/second** to the
   VPC DNS resolver. Bursty apps hit this. Fix with **NodeLocal DNSCache**,
   which puts a DNS cache on every node.

4. **Conntrack race condition** on older kernels — mitigated by NodeLocal
   DNSCache or `single-request-reopen`.

### Issue 10 — Intermittent timeouts under load

```bash
# Check for dropped packets due to network limits
kubectl exec <POD> -n $NS -- cat /proc/net/softnet_stat
```

Causes:
- **Instance bandwidth limits** — smaller instances get burst credits that run out
- **Conntrack table full**:
  ```bash
  kubectl exec <POD> -n $NS -- sysctl net.netfilter.nf_conntrack_count
  kubectl exec <POD> -n $NS -- sysctl net.netfilter.nf_conntrack_max
  ```
- **NAT gateway port exhaustion** — one NAT supports ~55,000 concurrent
  connections *per destination*. Watch the CloudWatch metric
  `ErrorPortAllocation`.
- **SNAT exhaustion** — many pods sharing one node IP

### Issue 11 — Cross-account / cross-VPC failures

```bash
# Check peering connections
aws ec2 describe-vpc-peering-connections --region $REGION \
  --query 'VpcPeeringConnections[].[VpcPeeringConnectionId,Status.Code,RequesterVpcInfo.CidrBlock,AccepterVpcInfo.CidrBlock]' \
  --output table

# Check Transit Gateway attachments
aws ec2 describe-transit-gateway-attachments --region $REGION --output table
```

Both VPCs need routes pointing at each other. **Overlapping CIDR blocks make
peering impossible** — this is the most common blocker.

---

## Part 5: The Ultimate Debug Script

Save this as `eks-netcheck.sh`, run `chmod +x eks-netcheck.sh`, then
`./eks-netcheck.sh my-app-cluster us-east-1`.

```bash
#!/usr/bin/env bash
set -uo pipefail

CLUSTER="${1:?usage: $0 <cluster-name> [region]}"
REGION="${2:-us-east-1}"

hr() { printf '\n=== %s ===\n' "$1"; }

hr "CLUSTER"
aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.[name,status,version,platformVersion]' --output table

VPC=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "VPC: $VPC"

hr "SUBNETS (watch AvailableIpAddressCount)"
aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,AvailableIpAddressCount]' \
  --output table

hr "ROUTE TABLES (look for blackhole)"
aws ec2 describe-route-tables --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[].Routes[?State==`blackhole`]' --output json

hr "NAT GATEWAYS"
aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=vpc-id,Values=$VPC" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table

hr "NODES"
kubectl get nodes -o wide

hr "NOT-READY PODS"
kubectl get pods -A --field-selector=status.phase!=Running -o wide

hr "SERVICES WITH ZERO ENDPOINTS"
kubectl get endpoints -A | awk '$3=="<none>"'

hr "COREDNS"
kubectl get pods -n kube-system -l k8s-app=kube-dns

hr "VPC CNI"
kubectl get daemonset -n kube-system aws-node

hr "UNHEALTHY LOAD BALANCER TARGETS"
for TG in $(aws elbv2 describe-target-groups --region "$REGION" \
    --query 'TargetGroups[].TargetGroupArn' --output text); do
  BAD=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[?TargetHealth.State!=`healthy`].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output text)
  [ -n "$BAD" ] && { echo "TG: $TG"; echo "$BAD"; }
done

hr "RECENT WARNING EVENTS"
kubectl get events -A --field-selector type=Warning \
  --sort-by=.lastTimestamp | tail -25

hr "DONE"
```

---

## Part 6: Comparing Your Options (Pros and Cons)

### Networking mode

| Option | Pros | Cons | Use when |
|---|---|---|---|
| **VPC CNI** (default) | Pods get real VPC IPs; security groups and VPC Flow Logs work natively; lowest latency | Consumes VPC IP space fast; pods-per-node limits | Almost always. It's the default for good reason. |
| **VPC CNI + prefix delegation** | 3–4× more pods per node; fewer nodes; lower cost | Reserves /28 blocks; needs Nitro instances | Dense workloads, large clusters |
| **Custom networking** | Pods use a separate secondary CIDR, saving primary IP space | Complex setup; loses one ENI per node | You've run out of RFC1918 space |
| **Cilium / Calico** | Rich network policies, eBPF performance, observability | Extra component to operate; you lose native SG-per-pod | You need strict pod-level policy |

### Load balancer type

| Option | Pros | Cons | Use when |
|---|---|---|---|
| **ALB (Application)** | Path/host routing, WAF, TLS termination, OIDC auth | HTTP/HTTPS only; higher latency | Web apps, APIs |
| **NLB (Network)** | Extreme throughput, static IPs, TCP/UDP, ultra-low latency | No path routing, no WAF | gRPC, databases, gaming, anything non-HTTP |
| **NLB + IP targets** | Preserves client IP; skips kube-proxy | More IPs consumed | Need real client IPs |
| **CLB (Classic)** | — | **Legacy. Don't use.** | Never for new work |

### Health check strategy

| Option | Pros | Cons |
|---|---|---|
| **Shallow** (`/healthz` returns 200 always) | Fast, no false negatives | Won't detect a broken database |
| **Deep** (checks DB, cache, etc.) | Catches real failures | A DB blip takes down every pod at once |
| **Split** (liveness shallow, readiness deep) | **Best of both.** Liveness restarts truly dead pods; readiness pulls unhealthy ones from the LB without restarting | Slightly more config |

> **Best practice:** Use the split approach. Liveness = "is the process alive?"
> Readiness = "can I serve traffic right now?" Never make liveness deep — a
> slow dependency will cause a cluster-wide restart storm.

### Where to enforce firewall rules

| Option | Pros | Cons |
|---|---|---|
| **Security groups** | Stateful (no return-rule headaches); reference other SGs; audited | Node-level by default |
| **Security groups for Pods** | Per-pod SGs; great for compliance | Reduces pods per node significantly; needs branch-ENI-capable instances |
| **Network policies** | Portable Kubernetes-native; label-based | Needs an enforcement engine; no AWS-resource awareness |
| **NACLs** | Subnet-wide blast shield | **Stateless** — causes invisible timeouts. Avoid unless required. |

---

## Part 7: Best Practices Summary

**Design**
- Use `/16` VPCs with `/20` or larger subnets. Running out of IPs is the most
  common scaling wall in EKS.
- Spread across **at least 3 Availability Zones**.
- Put nodes in **private** subnets; load balancers in **public** subnets.
- Enable **prefix delegation** from day one.
- Tag subnets correctly (`kubernetes.io/role/elb` and `/internal-elb`).

**Security**
- Reference **security groups**, never CIDR blocks, for internal traffic.
- Leave NACLs at default allow-all unless compliance forces otherwise.
- Never open `0.0.0.0/0` on a database port.
- Restrict `publicAccessCidrs` on the EKS endpoint to your office/VPN range.

**Reliability**
- Run **3+ CoreDNS replicas** and deploy **NodeLocal DNSCache**.
- Use split liveness/readiness probes.
- Always use **Alias records**, never hardcoded LB IPs.
- Set `terminationGracePeriodSeconds` longer than the target group's
  deregistration delay so in-flight requests finish.

**Observability — turn these on before you need them**

```bash
# VPC Flow Logs — see every accepted/rejected packet
aws ec2 create-flow-logs --region $REGION \
  --resource-type VPC --resource-ids vpc-0abc123 \
  --traffic-type ALL \
  --log-destination-type cloud-watch-logs \
  --log-group-name /aws/vpc/flowlogs \
  --deliver-logs-permission-arn arn:aws:iam::123456789012:role/flowlogsRole

# EKS control plane logs
aws eks update-cluster-config --region $REGION --name $CLUSTER \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

Then query flow logs for rejected traffic:

```bash
aws logs filter-log-events --region $REGION \
  --log-group-name /aws/vpc/flowlogs \
  --filter-pattern '[version, account, eni, source, destination, srcport, destport="5432", protocol, packets, bytes, windowstart, windowend, action="REJECT", flowlogstatus]' \
  --start-time $(($(date +%s) - 3600))000
```

> `action="REJECT"` in flow logs is **direct proof** that a security group or
> NACL blocked the traffic. This is the fastest way to confirm a firewall bug.

---

## Part 8: Quick Reference Card

```bash
# ---------- POD ----------
kubectl get pods -n $NS -o wide
kubectl describe pod <POD> -n $NS
kubectl logs <POD> -n $NS --previous
kubectl exec <POD> -n $NS -- ss -tlnp

# ---------- SERVICE / DNS ----------
kubectl get endpoints <SVC> -n $NS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl run t --rm -it --image=nicolaka/netshoot -- dig +short <NAME>

# ---------- NODE ----------
kubectl get nodes -o wide
aws ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,SubnetId,State.Name]' --output table

# ---------- SUBNET ----------
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC>" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailableIpAddressCount]' --output table

# ---------- ROUTES ----------
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=<SUBNET>" \
  --query 'RouteTables[].Routes' --output json

# ---------- SECURITY GROUP ----------
aws ec2 describe-security-groups --group-ids <SG> --query 'SecurityGroups[0].IpPermissions' --output json
aws ec2 authorize-security-group-ingress --group-id <SG> --protocol tcp --port <PORT> --source-group <SRC_SG>

# ---------- NACL ----------
aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=<SUBNET>" --output json

# ---------- TARGET GROUP ----------
aws elbv2 describe-target-health --target-group-arn <TG_ARN> --output table

# ---------- LOAD BALANCER ----------
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,DNSName,State.Code]' --output table
aws elbv2 describe-listeners --load-balancer-arn <LB_ARN> --output table

# ---------- ROUTE 53 ----------
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> --output json

# ---------- EVENTS ----------
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -20
```

### The 60-second triage flow

```
Connection problem reported
         |
         v
  What is the exact error?
         |
    +----+----+----------------+------------------+
    |         |                |                  |
 REFUSED   TIMEOUT          DNS FAIL          RESET
    |         |                |                  |
    v         v                v                  v
App not   Firewall         CoreDNS /          App crashed /
listening (SG, NACL,       Route 53 /         idle timeout
or wrong   route)          resolv.conf              |
  port        |                |                    v
    |         v                v              Check app logs
    v    describe-        dig from            + LB idle timeout
kubectl   security-       netshoot pod
exec ss   groups
-tlnp     + flow logs
          (REJECT)
```

---

*End of guide. Work top to bottom, trust the error type, and always verify each
layer before moving to the next.*
