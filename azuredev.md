# Deploying AKS with the Azure CLI — A Complete Beginner's Tutorial

**Last checked:** August 2026
**Reading level:** Written so a curious middle schooler can follow it. No prior Kubernetes experience needed.
**Time to finish Part 1:** about 30 minutes (most of it is waiting for Azure)
**Cost warning:** This creates real cloud resources that cost real money (usually a few cents to a couple of dollars if you finish and delete in one sitting). Step 11 deletes everything.

---

## Table of contents

1. [The big picture in plain English](#1-the-big-picture-in-plain-english)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [Part 1 — The step-by-step example (do this first)](#3-part-1--the-step-by-step-example-do-this-first)
4. [Part 2 — What each command actually did](#4-part-2--what-each-command-actually-did)
5. [Part 3 — Your options, with pros and cons](#5-part-3--your-options-with-pros-and-cons)
6. [Part 4 — Best practices for a real production cluster](#6-part-4--best-practices-for-a-real-production-cluster)
7. [Part 5 — Day-2 operations: scaling, upgrading, monitoring](#7-part-5--day-2-operations-scaling-upgrading-monitoring)
8. [Part 6 — Troubleshooting the errors you will actually hit](#8-part-6--troubleshooting-the-errors-you-will-actually-hit)
9. [Part 7 — Keeping the bill small](#9-part-7--keeping-the-bill-small)
10. [Command cheat sheet](#10-command-cheat-sheet)
11. [Glossary](#11-glossary)
12. [Where to go next](#12-where-to-go-next)

---

## 1. The big picture in plain English

### What is a container?

Imagine you wrote a program on your laptop. It works great — on *your* laptop. Then you send it to a friend and it breaks, because their computer has a different version of something.

A **container** fixes that. A container is like a lunchbox: you pack your program *plus* everything it needs to run (libraries, settings, tiny operating system pieces) into one sealed box. Anywhere that box is opened, the meal is the same. The most common tool for making these boxes is **Docker**, and the box itself is called a **container image**.

### What is Kubernetes?

One lunchbox is easy. Now imagine you run a website with 400 lunchboxes, and they need to:

- restart automatically when one goes bad,
- get more copies made when lots of visitors show up,
- share traffic evenly between copies,
- be replaced one at a time when you release a new version.

Doing that by hand would be a full-time job. **Kubernetes** (often written **K8s** — "K", eight letters, "s") is the robot that does it for you. It's the *lunchroom manager* for your containers. You hand Kubernetes a written wish list ("I want 3 copies of this app, always running"), and Kubernetes works nonstop to make reality match your wish list. That idea has a name: **desired state**.

Kubernetes has two halves:

| Half | Nickname | What it does | Who runs it in AKS |
|---|---|---|---|
| **Control plane** | The brain | Decides what runs where, stores the wish list, restarts dead things | **Microsoft** runs and patches it for you |
| **Nodes** | The muscles | Actual virtual machines where your containers really run | **You** own them (and pay for them) |

### What is AKS?

**AKS = Azure Kubernetes Service.** It is Kubernetes with Microsoft doing the annoying half.

Setting up a Kubernetes control plane yourself means installing and securing about six finicky components and keeping them patched forever. With AKS, Microsoft runs the control plane, keeps it healthy, and hands you a ready-to-use cluster. You just bring the nodes and your apps.

**Managed like this also exists elsewhere:** EKS on Amazon, GKE on Google. Same idea, different vendor.

### What is the Azure CLI?

**CLI = Command Line Interface.** It's the typed-command way to control Azure, instead of clicking buttons in the web portal. Every command starts with `az`.

Why type commands instead of clicking?

- **Repeatable.** The same commands make the same cluster every time, with no "wait, which box did I check?"
- **Shareable.** You can paste them into a document (like this one) or a script.
- **Automatable.** Scripts can run at 3 a.m. without you.

### What you're about to build

```
        Internet
            |
     [ Public IP + Azure Load Balancer ]        <- Azure creates this for you
            |
 ┌──────────┴───────────────────────────────┐
 │   AKS cluster (myAKSCluster)             │
 │                                          │
 │   Control plane  ← managed by Microsoft, │
 │                    free on Free tier     │
 │                                          │
 │   ┌─ System node pool (nodepool1) ────┐  │  <- runs Kubernetes' own helpers
 │   │   1 virtual machine                │  │
 │   └────────────────────────────────────┘  │
 │   ┌─ User node pool (userpool1) ──────┐   │  <- runs YOUR app
 │   │   1 virtual machine                │   │
 │   │     [pod] [pod]  ← your web app    │   │
 │   └────────────────────────────────────┘  │
 └──────────────────────────────────────────┘
```

---

## 2. What you need before you start

| # | Requirement | How to check / get it |
|---|---|---|
| 1 | **An Azure account with a subscription** | Free accounts include starting credit. Sign up at [azure.microsoft.com](https://azure.microsoft.com/free/). A credit card is required even for free accounts. |
| 2 | **Permission to create things** | You need at least **Contributor** on the subscription or resource group. School/work accounts often don't have this — ask your admin, or use a personal account. |
| 3 | **A terminal with the Azure CLI** | Two choices, below. |
| 4 | **kubectl** | Comes with Cloud Shell; installed in Step 8 if you're local. |
| 5 | **vCPU quota** | New subscriptions sometimes have a low limit. If you hit a quota error, see [Part 6](#8-part-6--troubleshooting-the-errors-you-will-actually-hit). |

### Choice A — Azure Cloud Shell (easiest, recommended for your first time)

Go to [shell.azure.com](https://shell.azure.com) and pick **Bash**. You get a Linux terminal in your browser with `az`, `kubectl`, and `helm` already installed and already logged in. Nothing to install, nothing to break.

- **Pros:** zero setup, always the latest CLI, works on a Chromebook or tablet.
- **Cons:** needs an Azure storage account for saved files, sessions time out after ~20 minutes of no typing, slightly awkward for editing files.

### Choice B — Install the Azure CLI on your own machine

```bash
# Windows (PowerShell as Administrator)
winget install -e --id Microsoft.AzureCLI

# macOS
brew update && brew install azure-cli

# Ubuntu / Debian
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

Then confirm it works and is current:

```bash
az version
az upgrade      # updates the CLI to the newest release
```

> **Version note:** Newer AKS features keep raising the minimum CLI version (some 2026 features want **2.86.0 or later**). If a command says an argument is unrecognized, run `az upgrade` first — that fixes it about half the time.

- **Pros:** your own editor, files persist, no session timeouts, works in scripts and CI/CD.
- **Cons:** you have to keep it updated yourself.

---

## 3. Part 1 — The step-by-step example (do this first)

The goal: **a working cluster running a real web page you can open in a browser.** Understanding comes in Part 2. Just type along for now.

> Every command below is Bash. On Windows PowerShell, replace the line-continuation `\` with a backtick `` ` ``, and set variables with `$RESOURCE_GROUP = "myAKSResourceGroup"` instead of `export`.

### Step 1 — Sign in

```bash
az login
```

A browser window opens. Sign in. When it finishes, your terminal prints a list of your subscriptions.

If you have more than one subscription, pick the one that should be billed:

```bash
# See what you have
az account list --output table

# Choose one (use the SubscriptionId or the name)
az account set --subscription "My Azure Subscription"

# Confirm the choice stuck
az account show --output table
```

### Step 2 — Turn on the AKS service for your subscription

Azure services are switched off in a subscription until they're **registered**. This is a one-time thing per subscription.

```bash
az provider show --namespace Microsoft.ContainerService --query registrationState --output tsv
```

If the answer is not `Registered`:

```bash
az provider register --namespace Microsoft.ContainerService
```

Registration can take a few minutes. Re-run the first command until it says `Registered`.

### Step 3 — Set up variables

Variables mean you type names once instead of ten times, and you don't get typos in the middle of a long command.

```bash
export RESOURCE_GROUP="myAKSResourceGroup"
export CLUSTER_NAME="myAKSCluster"
export LOCATION="eastus"
export USER_NP="userpool1"
```

Pick a `LOCATION` near you: `eastus`, `westus2`, `westeurope`, `northeurope`, `uksouth`, `centralindia`, `southeastasia`, `australiaeast`. See all of them with `az account list-locations --output table`.

> If your terminal closes, these variables disappear. Just paste this block again.

### Step 4 — Create a resource group

A **resource group** is a folder that holds related Azure things. Deleting the folder deletes everything inside it — which is how you'll clean up later.

```bash
az group create --name $RESOURCE_GROUP --location $LOCATION
```

You should see JSON ending with `"provisioningState": "Succeeded"`.

### Step 5 — Create the AKS cluster

This is the main event.

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --tier free \
  --node-count 1 \
  --enable-managed-identity \
  --generate-ssh-keys
```

**This takes 4–10 minutes.** That's normal — Azure is building a control plane, a virtual network, a virtual machine scale set, security rules, and an identity.

Check it landed properly:

```bash
az aks show \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --query provisioningState \
  --output tsv
```

Expected output: `Succeeded`

Line-by-line:

| Flag | What it means |
|---|---|
| `--resource-group` | Which folder to put it in |
| `--name` | Your cluster's name |
| `--tier free` | Free control plane — perfect for learning, **no uptime guarantee** |
| `--node-count 1` | One worker VM. Saves money for a demo. **Production wants 3+.** If you leave this out, AKS gives you 3. |
| `--enable-managed-identity` | The cluster gets its own Azure identity, so there's no password to store. This is the default now, but writing it down makes your intent obvious. |
| `--generate-ssh-keys` | Makes an SSH key pair (at `~/.ssh/`) so you *could* log into a node in an emergency |

### Step 6 — Add a user node pool

A **node pool** is a group of identical worker VMs. AKS gives you a **system** pool by default, which runs Kubernetes' own housekeeping pods. Best practice is to keep your apps *off* the system pool and put them on a **user** pool.

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --name $USER_NP \
  --node-count 1 \
  --mode User
```

Check both pools exist:

```bash
az aks nodepool list \
  --resource-group $RESOURCE_GROUP \
  --cluster-name $CLUSTER_NAME \
  --query "[].{Name:name, Mode:mode, Count:count, VmSize:vmSize}" \
  --output table
```

```
Name        Mode    Count    VmSize
----------  ------  -------  ---------------
nodepool1   System  1        Standard_DS2_v2
userpool1   User    1        Standard_DS2_v2
```

**Why bother?** If a runaway app eats all the memory on the system pool, it can knock out DNS and metrics for the *whole* cluster. Separating them is cheap insurance.

### Step 7 — Get your cluster credentials

Right now your computer doesn't know the cluster exists. This command fetches the connection details and saves them to `~/.kube/config`.

```bash
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME
```

Think of it as adding the cluster's phone number to your contacts.

### Step 8 — Install kubectl (skip if you're in Cloud Shell)

`kubectl` ("cube-cuttle" or "cube-control", people argue) is the tool that talks to Kubernetes itself. `az` talks to *Azure*; `kubectl` talks to *Kubernetes*. Different tools, different jobs.

```bash
sudo az aks install-cli
```

Now test the whole chain:

```bash
kubectl get nodes
```

```
NAME                                STATUS   ROLES    AGE     VERSION
aks-nodepool1-12345678-vmss000000   Ready    <none>   9m      v1.34.4
aks-userpool1-12345678-vmss000000   Ready    <none>   3m      v1.34.4
```

Both `Ready`? Your cluster is alive. 🎉

### Step 9 — Deploy an app

Kubernetes takes its wish list as a **YAML manifest** — a text file describing what you want. Create a file called `demo-app.yaml`:

```bash
cat > demo-app.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-demo
  template:
    metadata:
      labels:
        app: web-demo
    spec:
      nodeSelector:
        kubernetes.io/os: linux
        kubernetes.azure.com/mode: user
      containers:
      - name: web
        image: mcr.microsoft.com/azuredocs/aks-helloworld:v1
        ports:
        - containerPort: 80
        env:
        - name: TITLE
          value: "Hello from my very first AKS cluster"
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web-demo
spec:
  type: LoadBalancer
  selector:
    app: web-demo
  ports:
  - port: 80
    targetPort: 80
EOF
```

Reading the file out loud:

- **Deployment** = "keep 2 copies (`replicas: 2`) of this container running forever."
- **`nodeSelector`** = "only put them on Linux nodes in the *user* pool."
- **`requests`** = the minimum resources Kubernetes reserves; **`limits`** = the ceiling it won't let the container pass.
- **`readinessProbe`** = "don't send traffic to a copy until this page answers."
- **Service type `LoadBalancer`** = "Azure, please give me a public IP address and spread traffic across the copies."
- The `---` separates two objects in one file.

Apply it:

```bash
kubectl apply -f demo-app.yaml
```

Watch the pods start (a **pod** is the smallest unit Kubernetes runs — usually one container):

```bash
kubectl get pods -o wide --watch
```

Press `Ctrl+C` once both show `Running`.

### Step 10 — Test it in a browser

Azure needs a minute or two to hand out a public IP.

```bash
kubectl get service web-demo --watch
```

At first `EXTERNAL-IP` says `<pending>`. When a real IP appears, press `Ctrl+C`.

```
NAME       TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)        AGE
web-demo   LoadBalancer   10.0.146.12    20.51.123.45    80:31234/TCP   2m
```

Grab it and test:

```bash
export IP_ADDRESS=$(kubectl get service web-demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open this in your browser: http://$IP_ADDRESS"
curl http://$IP_ADDRESS
```

Paste the URL into a browser. **You just deployed an app to Kubernetes in the cloud.**

### Step 11 — Delete everything (do not skip this!)

That load balancer and those VMs bill by the hour whether you're looking at them or not.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```

- `--yes` skips the confirmation prompt
- `--no-wait` returns your prompt immediately while Azure deletes in the background

Verify a few minutes later:

```bash
az group exists --name $RESOURCE_GROUP    # should print: false
```

> **Heads up:** AKS also created a *second* resource group named `MC_myAKSResourceGroup_myAKSCluster_eastus`. That's where the VMs and load balancer live. Deleting the first group deletes the `MC_` one too. Never edit the `MC_` group by hand.

---

## 4. Part 2 — What each command actually did

### The two resource groups mystery

You made one resource group; Azure shows two. Why?

| Group | Contains | Who manages it |
|---|---|---|
| `myAKSResourceGroup` | The AKS resource itself (the "remote control") | **You** |
| `MC_myAKSResourceGroup_myAKSCluster_eastus` | VM scale sets, disks, load balancer, network security group, virtual network | **AKS** — hands off |

"MC" stands for *Managed Cluster*. AKS needs full control there, so changing things manually can break upgrades. If you want to name it yourself, use `--node-resource-group myCustomName` at creation time (it can't be changed later).

### `az` versus `kubectl`

This trips up nearly everyone at first:

| Question | Tool | Example |
|---|---|---|
| "Make the cluster bigger" | `az` — this is an *Azure* thing | `az aks scale --node-count 5` |
| "Run more copies of my app" | `kubectl` — this is a *Kubernetes* thing | `kubectl scale deployment web-demo --replicas=5` |
| "Upgrade Kubernetes" | `az` | `az aks upgrade` |
| "Why is my pod crashing?" | `kubectl` | `kubectl describe pod <name>` |

Rule of thumb: **infrastructure = `az`, workloads = `kubectl`.**

### What `get-credentials` really wrote

It appended a cluster entry, a user entry, and a **context** (a cluster + user + namespace combo) to `~/.kube/config`.

```bash
kubectl config get-contexts        # list them
kubectl config current-context     # which one am I aimed at?
kubectl config use-context myAKSCluster
```

Two safety notes:

- Running `get-credentials` again after deleting and recreating a cluster with the same name gives a confusing error. Add `--overwrite-existing`.
- `--admin` gets you a certificate that **bypasses Microsoft Entra ID and RBAC entirely**. It's a break-glass key. Don't hand it out, and don't use it as your everyday login.

### The layers, from big to small

```
Subscription
 └── Resource group
      └── AKS cluster
           └── Node pool (a set of identical VMs)
                └── Node (one VM)
                     └── Pod (usually one container, the smallest schedulable unit)
                          └── Container (your actual program)
```

And the objects you wrote in YAML:

- **Deployment** manages a **ReplicaSet**, which manages **Pods**. Deployments give you rolling updates and rollbacks (`kubectl rollout undo deployment/web-demo`).
- **Service** gives pods a stable address, because pods get new IPs constantly. `ClusterIP` = inside only, `NodePort` = a port on each node, `LoadBalancer` = public IP from Azure.
- **Namespace** = a folder inside the cluster for organizing objects (`kubectl get pods -n kube-system` shows the system's own pods).

---

## 5. Part 3 — Your options, with pros and cons

This is the section that turns "I did the tutorial" into "I can make real decisions."

### 5.1 How to create AKS at all: CLI vs Portal vs IaC

| Method | Best for | Pros | Cons |
|---|---|---|---|
| **Azure CLI** (`az aks create`) | Learning, scripts, quick clusters | Fast, scriptable, easy to paste in docs, full feature coverage | Commands drift out of sync with reality over time; no built-in record of what exists |
| **Azure Portal** (clicking) | Your very first look, or exploring options | Shows every option with explanations, hard to forget a required field | Slow, not repeatable, no history of choices |
| **Bicep / ARM templates** | Azure-only production teams | Declarative, native to Azure, what-if previews, no extra tools | Azure-only, Bicep syntax is another thing to learn |
| **Terraform / OpenTofu** | Multi-cloud production teams | Declarative, huge ecosystem, one language for all clouds | State files must be stored and locked carefully; provider lags new Azure features slightly |
| **`azd` (Azure Developer CLI)** | App developers who want cluster + app + CI in one shot | One command (`azd up`) builds everything from a template | Opinionated; less control over details |

**Honest recommendation:** learn with the CLI (like this tutorial), then move production to Bicep or Terraform. Anything you'll rebuild should live in version control, not in your shell history.

### 5.2 Cluster SKU: Base vs Automatic

This is one of the most important 2026-era choices.

| | **Base SKU** (the classic AKS) | **Automatic SKU** |
|---|---|---|
| What it is | You configure node pools, networking, add-ons, scaling | AKS pre-configures production defaults and manages nodes for you |
| Node management | You choose VM sizes and pool counts | Node auto-provisioning picks and creates nodes based on what your pods need |
| Preconfigured | Very little | Monitoring, Azure Policy, Entra ID integration, autoscaling, security defaults |
| Pricing tier | Free, Standard, or Premium — your choice | Standard tier minimum (no Free tier) |
| Windows containers | Supported | Not supported |
| Custom CNI / BYO networking | Supported | Limited |
| Best for | Teams with specific requirements or existing IaC that manages node pools | Teams who want a production-sane cluster without becoming Kubernetes experts |

Microsoft now positions **AKS Automatic as the recommended production-ready default** for most production workloads. Choose **Base** if you need Windows nodes, unusual networking, or you already have infrastructure code that manages node pools explicitly.

```bash
# Automatic SKU (note: requires a recent Azure CLI and the aks-preview extension for some options)
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --sku automatic
```

### 5.3 Pricing tier: Free vs Standard vs Premium

Tiers apply to the **control plane** (the brain). Your VMs are billed separately either way.

| Tier | Uptime SLA | Node ceiling | Roughly for | Cost |
|---|---|---|---|---|
| **Free** | None — best effort only | Recommended under ~10 nodes for real use | Learning, dev, testing | $0 for the control plane |
| **Standard** | 99.95% with availability zones, 99.9% without | Up to ~5,000 nodes | Production | ~$0.10 per cluster per hour (≈$70/month) — [check current pricing](https://azure.microsoft.com/pricing/details/kubernetes-service/) |
| **Premium** | Same SLA as Standard, plus **Long Term Support** (24 months on an LTS Kubernetes version) | Same as Standard | Regulated or slow-moving enterprises that can't upgrade Kubernetes every year | Higher than Standard |

**Pros and cons in one line each:**

- *Free:* free, and fine for learning — but a control plane hiccup gives you no financial recourse and no priority.
- *Standard:* boring, correct, and the right answer for almost every production cluster.
- *Premium:* buys you *time*, not features. Worth it only if annual Kubernetes upgrades are genuinely impossible for you.

```bash
az aks create ... --tier standard
az aks update --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --tier standard   # change later
```

> Note: AKS Automatic clusters are preconfigured to the Standard tier.

### 5.4 Networking: which CNI?

The **CNI** (Container Network Interface) decides how pods get IP addresses. Pick badly and you'll rebuild the cluster later, because **you cannot change this after creation**.

| Option | How pod IPs work | Pros | Cons |
|---|---|---|---|
| **Azure CNI Overlay** (recommended default) | Pods get IPs from a private overlay range, not your VNet | Barely uses VNet IPs, scales to huge clusters, simple planning | Pods aren't directly reachable from outside the cluster without extra work |
| **Azure CNI (node subnet / "traditional")** | Every pod gets a real VNet IP | Pods are first-class network citizens; easy for legacy systems to reach them | Eats IP addresses fast — you can exhaust a subnet surprisingly quickly |
| **Azure CNI Powered by Cilium** | Overlay or VNet IPs, with eBPF for routing and network policy | Fastest data plane, best-in-class network policy, great observability | Slightly newer; some niche features differ from standard |
| **Kubenet** | Basic routing tables | Very few IPs used | **Legacy — being retired. Don't start here.** |

```bash
az aks create ... \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --network-policy cilium
```

**Plan your IPs before you type.** Rough guide: `IPs needed ≈ nodes × (max pods per node + 1)`. With node autoscaling, size for your maximum node count, not today's count.

### 5.5 Identity and access

| Choice | What it is | Recommendation |
|---|---|---|
| **System-assigned managed identity** | Azure creates and rotates an identity for the cluster | ✅ Default and best for most |
| **User-assigned managed identity** | You create the identity yourself and reuse it | Good when you need to pre-grant permissions before cluster creation |
| **Service principal** | Old-style app ID + secret | ❌ Legacy. Secrets expire and break clusters at 2 a.m. |
| **Microsoft Entra ID + Azure RBAC for Kubernetes** | Real user accounts and Azure role assignments control `kubectl` | ✅ Do this in production; disable local accounts (`--disable-local-accounts`) |
| **Workload Identity** | Pods get Entra identities to call Azure services (Key Vault, Storage) with no secrets | ✅ The modern way for app-to-Azure auth |

```bash
az aks create ... \
  --enable-aad \
  --enable-azure-rbac \
  --disable-local-accounts \
  --enable-oidc-issuer \
  --enable-workload-identity
```

### 5.6 Scaling: three different autoscalers

People mix these up constantly. They solve different problems and work together.

| Scaler | Scales | Trigger | Command |
|---|---|---|---|
| **HPA** (Horizontal Pod Autoscaler) | More **pods** | CPU/memory usage | `kubectl autoscale deployment web-demo --min=2 --max=10 --cpu-percent=70` |
| **Cluster Autoscaler** | More **nodes** in an existing pool | Pods stuck `Pending` with nowhere to fit | `az aks nodepool update --enable-cluster-autoscaler --min-count 1 --max-count 5` |
| **Node Auto Provisioning (NAP)** | Creates whole **new node pools** with the right VM sizes | Pending pods, chooses the cheapest VM that fits | `az aks create ... --node-provisioning-mode Auto` |

- **HPA pros/cons:** instant and cheap; useless if there's no node room left.
- **Cluster Autoscaler pros/cons:** predictable and mature; limited to VM sizes you already picked.
- **NAP (built on Karpenter) pros/cons:** excellent bin-packing and cost savings, picks VM types you'd never think of; newer, and less predictable if you need tightly controlled VM SKUs.

**KEDA** is a fourth option: it scales pods on *events* (queue length, Kafka lag, HTTP requests) instead of CPU, and can scale to zero. Add it with `--enable-keda`.

### 5.7 Node OS: Azure Linux vs Ubuntu vs Windows

| `--os-sku` | Notes |
|---|---|
| `AzureLinux` | Microsoft's own hardened, minimal Linux. Smaller attack surface, faster boot, tightly tested with AKS. **Azure Linux 2.0 has been retired — use Azure Linux 3.** |
| `Ubuntu` | The long-time default. Widest community knowledge and third-party tooling. |
| `Windows2022` / `Windows2025` | Only for Windows containers (classic .NET apps). Much bigger images, slower, more expensive. Windows Server 2022 node pools retire March 2027 — start new work on 2025. |

### 5.8 Spot node pools

**Spot** VMs are Azure's leftover capacity at up to ~90% off, and Azure can evict them with 30 seconds' notice.

- **Pros:** enormous savings for batch jobs, CI runners, dev environments, and stateless workers.
- **Cons:** can vanish at any moment. **Never** run databases, a system pool, or anything stateful on Spot.

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME \
  --name spotpool --priority Spot --eviction-policy Delete \
  --spot-max-price -1 --enable-cluster-autoscaler --min-count 0 --max-count 5
```

### 5.9 Getting traffic in: Service vs Ingress vs Gateway

| Approach | Good for | Trade-off |
|---|---|---|
| `Service type: LoadBalancer` | One app, quick demo (what we used) | One public IP **per service** — expensive and messy at scale |
| **Ingress controller** | Many apps behind one IP with hostname/path routing + TLS | One more component to run and patch |
| **Application Gateway for Containers** | Enterprise L7 with WAF, managed by Azure | Costs more; Azure-specific |
| **Gateway API** | The modern successor to Ingress | Newer; some tools still assume Ingress |

⚠️ **Important 2026 change:** the community **Ingress NGINX project is winding down** (maintenance ended March 2026). If you were planning to standardize on NGINX Ingress, look at the **application routing add-on's Gateway API implementation** or Application Gateway for Containers instead.

---

## 6. Part 4 — Best practices for a real production cluster

### The production checklist

- [ ] **3+ nodes minimum**, spread across **availability zones** (`--zones 1 2 3`)
- [ ] **Standard tier** for the uptime SLA
- [ ] **Separate system and user node pools**; taint the system pool with `CriticalAddonsOnly=true:NoSchedule`
- [ ] **Entra ID + Azure RBAC** on, **local accounts off**
- [ ] **Workload Identity** for app-to-Azure auth; **no secrets in YAML** (use Key Vault + the Secrets Store CSI driver)
- [ ] **Private cluster** (`--enable-private-cluster`) or **API server authorized IP ranges** so the control plane isn't open to the internet
- [ ] **Azure CNI Overlay** with a documented IP plan, plus **network policy** on
- [ ] **Monitoring on**: Container Insights + Managed Prometheus + Managed Grafana
- [ ] **Auto-upgrade channels** set for both Kubernetes and node OS, with **maintenance windows**
- [ ] **Resource requests and limits on every container** — without them, one bad pod takes down a node
- [ ] **Pod Disruption Budgets** so upgrades don't drain your last replica
- [ ] **Multiple replicas** and readiness/liveness probes for anything user-facing
- [ ] **Everything in Infrastructure as Code**, deployed through a pipeline
- [ ] **Backup plan** for persistent volumes (Azure Backup for AKS) and a tested restore

### A more production-shaped create command

```bash
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name $CLUSTER_NAME \
  --location $LOCATION \
  --tier standard \
  --node-count 3 \
  --zones 1 2 3 \
  --node-vm-size Standard_D4ds_v5 \
  --os-sku AzureLinux \
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \
  --network-policy cilium \
  --enable-managed-identity \
  --enable-aad \
  --enable-azure-rbac \
  --disable-local-accounts \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --enable-cluster-autoscaler --min-count 3 --max-count 10 \
  --auto-upgrade-channel stable \
  --node-os-upgrade-channel NodeImage \
  --enable-addons monitoring \
  --generate-ssh-keys
```

Then move the system pool out of the way of your apps:

```bash
az aks nodepool add \
  --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME \
  --name apps --mode User --node-count 3 --zones 1 2 3 \
  --enable-cluster-autoscaler --min-count 3 --max-count 20
```

### Security habits that matter most

1. **Never store secrets in YAML or container images.** Kubernetes `Secret` objects are only base64-encoded — that's encoding, not encryption. Use Azure Key Vault with the Secrets Store CSI driver.
2. **Pin image versions.** `:latest` means "something different every deploy" and makes rollbacks impossible. Use digests or explicit tags.
3. **Scan images** (Microsoft Defender for Containers) and pull from your own **Azure Container Registry**, not random public registries.
4. **Least privilege.** Give humans `Azure Kubernetes Service RBAC Reader` by default; grant write access per-namespace.
5. **Default-deny network policy**, then open only the paths you need.
6. **Patch relentlessly.** Node image upgrades weekly-ish, Kubernetes minor version at least yearly.

### Kubernetes version policy (as of August 2026)

- AKS supports roughly the **three newest minor versions** (currently in the 1.34–1.36 range) with about a **12-month support window** per version.
- **You cannot skip minor versions.** 1.33 → 1.35 must go 1.33 → 1.34 → 1.35.
- **LTS 1.29 is deprecated.** If you're on it, plan a move.
- **Azure Linux 2.0 is retired** (node images removed as of March 31, 2026) — migrate to `AzureLinux` 3.

Never hardcode a version from a tutorial. Ask the API what's real today:

```bash
az aks get-versions --location $LOCATION --output table
az aks get-upgrades --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --output table
```

---

## 7. Part 5 — Day-2 operations: scaling, upgrading, monitoring

### Scaling

```bash
# Nodes (Azure)
az aks scale --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --node-count 3
az aks nodepool scale --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --name $USER_NP --node-count 5

# Turn on the cluster autoscaler for a pool
az aks nodepool update \
  --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --name $USER_NP \
  --enable-cluster-autoscaler --min-count 1 --max-count 8

# Pods (Kubernetes)
kubectl scale deployment web-demo --replicas=5
kubectl autoscale deployment web-demo --min=2 --max=10 --cpu-percent=70
```

### Upgrading

Always do the control plane first, then nodes.

```bash
az aks get-upgrades --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --output table

# Control plane only
az aks upgrade --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
  --kubernetes-version 1.35.x --control-plane-only

# Then each node pool
az aks nodepool upgrade --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME \
  --name $USER_NP --kubernetes-version 1.35.x

# Just the node OS image (security patches, no Kubernetes change)
az aks nodepool upgrade --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME \
  --name $USER_NP --node-image-only
```

Set it and forget it, with a maintenance window so upgrades don't land during your busy hours:

```bash
az aks update --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
  --auto-upgrade-channel stable --node-os-upgrade-channel NodeImage
```

**Auto-upgrade channel pros/cons:** `stable` keeps you patched with no human effort, which is the single best security-hygiene win available — but it *will* restart nodes, so pair it with Pod Disruption Budgets, multiple replicas, and a maintenance window.

### Monitoring

```bash
az aks enable-addons --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --addons monitoring

az aks update --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME \
  --enable-azure-monitor-metrics    # managed Prometheus
```

Quick eyeballing without any add-on:

```bash
kubectl top nodes
kubectl top pods
kubectl get events --sort-by=.metadata.creationTimestamp
```

---

## 8. Part 6 — Troubleshooting the errors you will actually hit

### "Insufficient regional vCPU quota"

Your subscription's VM limit is too low, especially on new/free accounts.

- Try a smaller VM: `--node-vm-size Standard_B2s`
- Try a different region
- Request more quota: Azure Portal → **Quotas** → Compute → select region and VM family → Request increase

### Pod stuck in `Pending`

```bash
kubectl describe pod <pod-name>
```

Read the **Events** at the bottom — the answer is almost always there. Common causes: no node has enough CPU/memory (add nodes or lower `requests`), a `nodeSelector` matches nothing, or a taint blocks scheduling.

### Pod in `ImagePullBackOff` / `ErrImagePull`

Kubernetes can't download the container image. Usually a typo in the image name, a private registry with no credentials, or a tag that doesn't exist. Fix: `az aks update --attach-acr <acr-name>` to grant your cluster pull access to your registry.

### Pod in `CrashLoopBackOff`

The container starts and immediately dies, over and over.

```bash
kubectl logs <pod-name>
kubectl logs <pod-name> --previous     # logs from the crashed attempt — usually the useful one
```

Usually your app's own error: a missing env var, a config file it can't find, a database it can't reach.

### `EXTERNAL-IP` stuck on `<pending>`

Wait 3–5 minutes first — it's often just slow. If it persists, check public IP quota in your subscription and `kubectl describe service web-demo` for events.

### "The connection to the server ... was refused" from kubectl

Your kubeconfig is stale or pointing at a deleted cluster.

```bash
az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --overwrite-existing
kubectl config current-context
```

### "unrecognized arguments" from az

Your CLI is old. `az upgrade`. Some features also need an extension: `az extension add --name aks-preview` (and `az extension update --name aks-preview`).

### Cluster health from the Azure side

```bash
az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --output table
az aks check-network outbound --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
```

---

## 9. Part 7 — Keeping the bill small

**What actually costs money:** the node VMs (usually 80–90% of the bill), managed disks, the load balancer and its public IPs, outbound data transfer, Log Analytics ingestion, and the control plane tier if you're not on Free.

**What's free:** the Free-tier control plane, and Kubernetes itself.

Ways to cut costs, roughly in order of impact:

1. **Right-size your nodes.** Most clusters run VMs 3× larger than their workloads need. Check with `kubectl top nodes` over a week.
2. **Turn on autoscaling** so you're not paying for idle capacity at night.
3. **Use Spot pools** for anything that can be interrupted.
4. **Buy reservations or savings plans** for baseline capacity you know you'll run for a year or three.
5. **Enable the AKS Cost Analysis add-on** (Standard/Premium tiers) to see spend broken down by namespace.
6. **Cap Log Analytics ingestion** — monitoring bills can quietly rival compute bills.
7. **Delete dev clusters at night.** A script that runs `az aks stop` at 7 p.m. and `az aks start` at 8 a.m. cuts dev compute costs roughly in half:

```bash
az aks stop  --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
az aks start --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
```

8. **Set a budget alert** in Azure Cost Management so a mistake pings you on day 2, not on the invoice.

---

## 10. Command cheat sheet

### Setup and cluster lifecycle

```bash
az login                                             # sign in
az account set --subscription "<name-or-id>"         # choose subscription
az group create -n <rg> -l <region>                  # make resource group
az aks create -g <rg> -n <cluster> --node-count 3    # create cluster
az aks list -o table                                 # list clusters
az aks show -g <rg> -n <cluster> -o table            # cluster details
az aks stop / start -g <rg> -n <cluster>             # pause / resume billing on nodes
az aks delete -g <rg> -n <cluster> --yes             # delete cluster
az group delete -n <rg> --yes --no-wait              # delete everything
```

### Node pools

```bash
az aks nodepool list    -g <rg> --cluster-name <cluster> -o table
az aks nodepool add     -g <rg> --cluster-name <cluster> -n pool2 --mode User --node-count 2
az aks nodepool scale   -g <rg> --cluster-name <cluster> -n pool2 --node-count 5
az aks nodepool upgrade -g <rg> --cluster-name <cluster> -n pool2 --node-image-only
az aks nodepool delete  -g <rg> --cluster-name <cluster> -n pool2
```

### Versions and upgrades

```bash
az aks get-versions --location <region> -o table
az aks get-upgrades -g <rg> -n <cluster> -o table
az aks upgrade -g <rg> -n <cluster> --kubernetes-version <ver> --control-plane-only
```

### Connecting

```bash
az aks get-credentials -g <rg> -n <cluster> --overwrite-existing
az aks install-cli
kubectl config get-contexts
```

### Everyday kubectl

```bash
kubectl get nodes / pods / services / deployments      # list things
kubectl get pods -A                                    # across all namespaces
kubectl describe pod <name>                            # detailed status + events
kubectl logs <pod> [-f] [--previous]                   # container logs
kubectl exec -it <pod> -- /bin/sh                      # shell inside a container
kubectl apply -f file.yaml                             # create or update from YAML
kubectl delete -f file.yaml                            # remove what that YAML made
kubectl rollout status deployment/<name>               # watch a rolling update
kubectl rollout undo deployment/<name>                 # roll back
kubectl top nodes / pods                               # resource usage
kubectl port-forward svc/<name> 8080:80                # test privately without a public IP
```

---

## 11. Glossary

| Term | Plain meaning |
|---|---|
| **Container** | Your app packed with everything it needs to run |
| **Image** | The saved blueprint a container is started from |
| **Pod** | Kubernetes' smallest unit — usually one container |
| **Node** | A virtual machine that runs pods |
| **Node pool** | A group of identical nodes |
| **Control plane** | The brain of Kubernetes; managed by Microsoft in AKS |
| **Deployment** | A rule saying "keep N copies of this pod running" |
| **Service** | A stable address that routes traffic to pods |
| **Ingress** | Smart HTTP routing for many apps behind one IP |
| **Namespace** | A folder inside the cluster |
| **Manifest** | A YAML file describing what you want |
| **Desired state** | Your wish list; Kubernetes constantly works to match it |
| **kubeconfig** | The file (`~/.kube/config`) holding your cluster connection details |
| **Resource group** | An Azure folder holding related resources |
| **Managed identity** | An Azure identity with no password for you to leak |
| **CNI** | The plugin that gives pods network addresses |
| **Taint / toleration** | A "keep out" sign on a node, and the pass that ignores it |
| **RBAC** | Role-Based Access Control — who is allowed to do what |
| **Helm** | A package manager for Kubernetes apps ("apt for K8s") |
| **GitOps** | Deploying by pushing to Git; a controller (Flux/Argo) syncs the cluster to match |

---

## 12. Where to go next

**Official documentation (always the most current source):**

- AKS CLI quickstart: <https://learn.microsoft.com/azure/aks/learn/quick-kubernetes-deploy-cli>
- Supported Kubernetes versions and release calendar: <https://learn.microsoft.com/azure/aks/supported-kubernetes-versions>
- Pricing tiers: <https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers>
- AKS baseline reference architecture (the gold standard for production): <https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks>
- AKS release notes on GitHub (weekly changes and deprecations): <https://github.com/Azure/AKS/releases>
- Full `az aks` command reference: <https://learn.microsoft.com/cli/azure/aks>
- Kubernetes' own docs: <https://kubernetes.io/docs/home/>

**A sensible learning path from here:**

1. Redo Part 1 without looking — muscle memory matters.
2. Build your own container image, push it to **Azure Container Registry**, and deploy that instead of the demo image.
3. Add an **Ingress** (or Gateway API) with a real hostname and HTTPS via cert-manager.
4. Add **persistent storage** with Azure Disk or Azure Files.
5. Learn **Helm** to package your app.
6. Rebuild the whole cluster with **Bicep or Terraform** and never click again.
7. Set up **GitOps** with Flux or Argo CD so deployment is just a `git push`.

**Final reminder:** if you followed Part 1 and haven't run Step 11 yet, go run it now.

```bash
az group delete --name $RESOURCE_GROUP --yes --no-wait
```
