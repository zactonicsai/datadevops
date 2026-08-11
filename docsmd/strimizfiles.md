# Setting Up an EKS Node Group and the Strimzi Cluster Operator
### A step-by-step guide, explained simply

**True airgap Strimzi (no internet, no helm, bucket files only)**

**Bucket must contain (prepared offline):**
- Edited Strimzi release (images mirrored to your ECR, all `quay.io/strimzi` replaced + `STRIMZI_KAFKA_IMAGES` / `STRIMZI_*_IMAGES` env vars updated in operator Deployment)
- Internal-only Kafka CR (no external listener)
- Tarball or `load-strimzi.sh` + YAMLs

**In airgap (aws cli + kubectl only):**

```bash
aws s3 cp s3://your-bucket/strimzi-airgap.tar.gz /tmp/
tar -xzf /tmp/strimzi-airgap.tar.gz -C /tmp/strimzi

kubectl create namespace kafka

kubectl apply -f /tmp/strimzi/install/cluster-operator/ -n kafka

kubectl apply -f /tmp/strimzi/examples/kafka/kafka-single-node.yaml -n kafka   # or your edited internal CR

kubectl wait kafka/my-cluster --for=condition=Ready -n kafka --timeout=300s
```

**Pre-reqs (EKS private airgap):**
- S3 + ECR VPC endpoints enabled
- Node IAM role has ECR pull perms for strimzi/* repos
- If image pull fails: create `docker-registry` secret with `aws ecr get-login-password` and reference it in operator Deployment + Kafka CR pod templates

All files local from bucket. No external URLs or updates.


---

## The Big Rule for This Whole Guide (Read This First)

Before we do anything, here is one rule that applies to **every single step**:

> **You are never allowed to run a file straight from the internet.**
> Every file you need (configuration files, installation files, etc.) must first be:
> 1. **Downloaded from the official latest release** of the project.
> 2. **Saved into your own local GitHub repository** (your own private copy).
> 3. **Security-scanned** (checked for viruses, secrets, and known problems).
> 4. **Used only from that local copy** when you actually do the step.

**Why does this matter?** Think of it like food safety. You don't eat food a stranger hands you on the street without checking it. Instead, you bring it into your own kitchen, inspect it, make sure it's safe, and *then* you eat it. Running files straight from the internet is like eating the street food. Mirroring them locally and scanning them first is like inspecting it in your own kitchen. If the original website ever gets hacked or disappears, your safe local copy still works exactly the same.

We'll set up that "kitchen" in Step 0, and every step after that will follow the rule.

---

## What We're Building (The Simple Version)

Imagine your **EKS Cluster** is a brand-new restaurant building that's already been built. It has a manager, but it has **no workers and no kitchen equipment yet**. Right now it can't actually cook anything.

- A **Node Group** is the group of *workers* (computers) we hire so the restaurant can actually do work.
- **Strimzi** is a *special helper* we install. Its job is to set up and babysit **Apache Kafka**, which is a system for moving huge amounts of messages/data around. Strimzi is the expert employee who knows how to run the Kafka equipment so you don't have to do it by hand.
- The **Strimzi Cluster Operator** is the "brain" of that helper. Once it's installed, you can just tell it "I want a Kafka" and it builds and maintains it for you.

So the order is: **hire workers (Node Group) → install the expert helper (Strimzi Operator)**. You can't install the helper first, because there'd be no workers for it to stand on.

---

## What You Need Before You Start (Checklist)

- An **existing EKS Cluster** that is already running.
- The **AWS CLI** installed and logged in (this is the tool that lets your computer talk to AWS).
- **`kubectl`** installed (this is the tool that lets you give commands to your cluster).
- **`eksctl`** installed (a tool that makes creating Node Groups much easier).
- A **GitHub account** and the **`git`** tool installed.
- A **security scanner** installed. We'll use two free, common ones:
  - **Trivy** — scans files for known security problems and viruses.
  - **gitleaks** — scans files for accidentally leaked passwords/secrets.

> 💡 *If you don't have these yet, install them first. The rest of the guide assumes they're ready.*

---

## Step 0: Build Your "Safe Kitchen" (Local GitHub Mirror Repo)

**Goal:** Create the one local repository where every downloaded file will live and be scanned before use.

**Why:** This is the home base for the Big Rule above. Every later step puts its files here first.

1. **Make a new repository on GitHub** named something like `eks-strimzi-mirror`. Keep it **private**.

2. **Download it to your computer** (this is called "cloning"):
   ```bash
   git clone https://github.com/<your-username>/eks-strimzi-mirror.git
   cd eks-strimzi-mirror
   ```

3. **Make folders to stay organized.** Each step gets its own folder:
   ```bash
   mkdir -p nodegroup strimzi scans
   ```
   - `nodegroup/` → files for hiring workers
   - `strimzi/` → files for the Strimzi helper
   - `scans/` → the "inspection reports" from our security scanner

**What "done" looks like:** You have an empty, private repo on your computer with three folders inside it.

---

## Step 1: Create a Reusable "Scan-Then-Save" Habit

**Goal:** Make a simple checklist you'll repeat for *every* file before you trust it.

**Why:** Instead of explaining scanning over and over, we define it once here. Every step will say "now do the Scan-Then-Save check," and you'll do these four things:

> **The Scan-Then-Save Check** ✅
> 1. **Download** the file from the official *latest release* into the right folder.
> 2. **Scan it for viruses/problems** with Trivy:
>    ```bash
>    trivy fs --scanners vuln,misconfig,secret ./<folder> > scans/<name>-scan.txt
>    ```
> 3. **Scan it for leaked secrets** with gitleaks:
>    ```bash
>    gitleaks detect --source ./<folder> --no-git --report-path scans/<name>-secrets.txt
>    ```
> 4. **Read the reports.** If they're clean, you're good. If they flag something serious, **stop** and fix it before continuing.

Then, once it passes, you **commit** (save) it to your local repo:
```bash
git add .
git commit -m "Add and scan files for <step name>"
git push
```

**What "done" looks like:** You understand the four-step check. We'll use it in Steps 3 and 5.

> 🔁 *From here on, "run the Scan-Then-Save Check" means: do these four things, confirm it's clean, then commit.*

---

## Step 2: Point `kubectl` at Your Existing Cluster

**Goal:** Make sure your command tool is talking to the *right* cluster before you change anything.

**Why:** This is like making sure you've walked into the *correct* restaurant before you start hiring people. Changing the wrong cluster would be a big mistake.

1. **Connect to your cluster** (replace the name and region with yours):
   ```bash
   aws eks update-kubeconfig --name <your-cluster-name> --region <your-region>
   ```

2. **Check that it worked.** This asks the cluster "who's there?":
   ```bash
   kubectl get nodes
   ```

**What "done" looks like:** The command runs without errors. You'll probably see **"No resources found"** — that's expected! It means the cluster is real but has **no workers yet**. That's exactly the problem we fix next.

---

## Step 3: Get and Scan Your Node Group Configuration File

**Goal:** Prepare the file that describes the workers we want to hire — and make it safe — *before* we use it.

**Why the Big Rule applies:** Even configuration files can contain mistakes or hidden bad settings. We mirror it locally and scan it first.

1. **Create the Node Group config file** inside your `nodegroup/` folder. This file is a set of instructions for `eksctl`. Save it as `nodegroup/nodegroup.yaml`:
   ```yaml
   apiVersion: eksctl.io/v1alpha5
   kind: ClusterConfig

   metadata:
     name: <your-cluster-name>      # must match your existing cluster
     region: <your-region>          # e.g. us-east-1

   managedNodeGroups:
     - name: strimzi-workers
       instanceType: m5.large       # the "size" of each worker computer
       desiredCapacity: 3           # start with 3 workers
       minSize: 2                   # never go below 2
       maxSize: 5                   # never go above 5
       volumeSize: 50               # 50 GB of storage each
   ```

   > 📝 *Plain-English translation: "Hire a group of 3 medium-sized worker computers for my cluster. Don't let the group shrink below 2 or grow past 5. Give each one 50 GB of storage."*

2. **Run the Scan-Then-Save Check** (from Step 1) on the `nodegroup/` folder:
   ```bash
   trivy fs --scanners vuln,misconfig,secret ./nodegroup > scans/nodegroup-scan.txt
   gitleaks detect --source ./nodegroup --no-git --report-path scans/nodegroup-secrets.txt
   ```
   Read both reports in the `scans/` folder. If clean, commit:
   ```bash
   git add .
   git commit -m "Add and scan node group config"
   git push
   ```

**What "done" looks like:** Your `nodegroup.yaml` is saved in your repo, the scan reports are clean, and everything is committed.

---

## Step 4: Create the Node Group (Hire the Workers)

**Goal:** Actually create the workers, using the **local, scanned file** from Step 3.

**Why this is the key moment for the Big Rule:** Notice we point at our **local file**, not a web link. This is the rule in action.

1. **Run the command using your local file:**
   ```bash
   eksctl create nodegroup --config-file=./nodegroup/nodegroup.yaml
   ```
   This takes several minutes. AWS is building real computers behind the scenes. ☕

2. **Check that your workers showed up:**
   ```bash
   kubectl get nodes
   ```

**What "done" looks like:** This time you see a list of nodes (probably 3) with a status of **`Ready`**. Your restaurant now has workers! 🎉

---

## Step 5: Get and Scan the Strimzi Operator Files

**Goal:** Download the **latest release** of the Strimzi installation files into your repo and make them safe — *before* installing.

**Why the Big Rule applies (extra important here):** These files will be given real power inside your cluster. You must *never* install them straight from the internet. Mirror, scan, then use locally.

1. **Find the latest Strimzi release version.** Go to the official Strimzi releases page on GitHub and note the newest version number (for example, `0.45.0`). We'll call it `<VERSION>`.

   > ⚠️ *Always use the actual latest version number you find — don't guess. The example numbers here are just placeholders.*

2. **Download the official installation file** for that version into your `strimzi/` folder:
   ```bash
   curl -L -o strimzi/strimzi-cluster-operator.yaml \
     https://github.com/strimzi/strimzi-kafka-operator/releases/download/<VERSION>/strimzi-cluster-operator-<VERSION>.yaml
   ```
   > 📝 *We're downloading and saving the file. We are NOT installing it yet. Big difference.*

3. **Run the Scan-Then-Save Check** on the `strimzi/` folder:
   ```bash
   trivy fs --scanners vuln,misconfig,secret ./strimzi > scans/strimzi-scan.txt
   gitleaks detect --source ./strimzi --no-git --report-path scans/strimzi-secrets.txt
   ```
   Read both reports. Strimzi is trusted software, so a clean scan is expected. If anything serious shows up, stop and investigate before continuing.

4. **Save it to your repo:**
   ```bash
   git add .
   git commit -m "Add and scan Strimzi <VERSION> operator files"
   git push
   ```

**What "done" looks like:** The Strimzi installation file lives safely in your repo, the scan reports are clean, and it's committed.

---

## Step 6: Make a Home for Strimzi (Create a Namespace)

**Goal:** Create a labeled "section" of the cluster just for Kafka stuff.

**Why:** A **namespace** is like giving Kafka its own room in the building instead of letting it spread its things everywhere. It keeps everything tidy and separate.

1. **Create a namespace called `kafka`:**
   ```bash
   kubectl create namespace kafka
   ```

**What "done" looks like:** Running `kubectl get namespaces` shows `kafka` in the list.

---

## Step 7: Install the Strimzi Cluster Operator (From Your Local File)

**Goal:** Install the "brain" — using the **local, scanned file** from Step 5.

**Why this is the rule in action again:** We apply our *own local copy*, not a web link.

1. **Install it from your local file into the `kafka` namespace:**
   ```bash
   kubectl apply -f ./strimzi/strimzi-cluster-operator.yaml -n kafka
   ```
   > 📝 *Plain-English translation: "Hey cluster, set up the Strimzi helper using these exact instructions I already checked, and put it in the `kafka` room."*

**What "done" looks like:** The command prints a list of things being created (roles, deployments, etc.) without errors.

---

## Step 8: Confirm Strimzi Is Alive and Working

**Goal:** Make sure the operator actually started up correctly.

**Why:** Installing something and it *working* are two different things. We verify, just like checking that a new employee actually showed up for their first day.

1. **Watch the operator start up:**
   ```bash
   kubectl get pods -n kafka
   ```
   A **pod** is basically one running piece of a program. You're looking for a pod with a name starting with `strimzi-cluster-operator`.

2. **Wait until its status says `Running` and it shows `1/1` ready.** If it says `ContainerCreating` or `Pending`, just wait a minute and run the command again.

3. **(Optional) Peek at its logs** to confirm it's happy:
   ```bash
   kubectl logs deployment/strimzi-cluster-operator -n kafka
   ```

**What "done" looks like:** You see the `strimzi-cluster-operator` pod with status **`Running`** and **`1/1`**. 🎉

---

## 🎉 You Did It! Here's What You Accomplished

1. You built a **safe local repo** (your "kitchen") for all your files.
2. You created a rule that **every file is scanned and used locally**, never run straight from the internet.
3. You **hired workers** by creating a Node Group.
4. You safely **installed the Strimzi Cluster Operator**, the brain that can now build and manage Kafka for you.

---

## What Comes Next (Not Required Today)

You now have the *operator* installed, but you don't have an actual *Kafka* running yet. The next thing you'd normally do is create a **Kafka custom resource** — a small file where you tell the operator "please build me a Kafka with these settings." Following the Big Rule, you'd write or download that file, save it to your repo, scan it, and then apply it from your local copy. But that's a separate adventure for another day.

The section below explains *what that Kafka will need* in order to actually move messages around — so you know what you're aiming for.

---

## What Kafka Needs to Send and Receive Messages

Think of Kafka like a **post office** for computer programs. One program drops off a message, and another program picks it up. For that post office to work, a bunch of pieces all have to be in place. Here's the full list, grouped by what each part does.

### 🖥️ The workers and their storage (the building and its filing cabinets)
- **Worker nodes that are `Ready`** — these are the computers from your Node Group (Step 4). The post office runs *on* them, so they need enough power (CPU and memory) to handle the work.
- **Persistent storage** — Kafka writes every message down on disk, like keeping a paper copy in a filing cabinet. On AWS this means **EBS-backed storage** that *stays* even if a worker restarts. Without it, restarting a worker would throw away all the mail. 📁

### 📮 The Kafka cluster itself (the post office staff)
- **A running Kafka cluster** — created by telling the Strimzi operator to build one (the "next phase" file mentioned above).
- **Several brokers, usually 3** — a **broker** is one postal worker. Having 3 means if one gets sick, the other two keep the mail moving and nothing is lost. 🧑‍🤝‍🧑
- **A coordination layer** — the brokers need a way to agree on who's in charge and who has which mail. This is either **KRaft** (the modern, built-in way) or **ZooKeeper** (the older way). Think of it as the staff schedule that keeps everyone on the same page.

### 📬 Topics (the labeled mailboxes)
- **At least one topic** — a **topic** is a labeled mailbox. Messages are always dropped into a topic and picked up from a topic. No mailbox means there's nowhere to put the mail.
- **Partitions** — these split one busy mailbox into several slots so mail can be sorted faster (more partitions = more speed).
- **A replication factor (e.g. 3)** — this means every message is copied into 3 places, so losing one filing cabinet doesn't lose the message.

### 🌐 Networking (the doors, hallways, and address)
- **Listeners** — these are the **doors** on each broker that programs knock on to connect. Strimzi sets these up for you in the Kafka file.
- **A way for clients to reach the brokers:**
  - If your programs live *inside* the cluster → an internal Kubernetes **Service** (a hallway connecting rooms).
  - If your programs live *outside* the cluster → an external route like a **LoadBalancer**, **NodePort**, or **Ingress** (a public front door with a street address).
- **Open ports / security group rules** — AWS has to actually *allow* traffic on Kafka's doors. If the security rules block those ports, it's like locking the doors — nobody gets in or out. 🚪

### 🔒 Permission and safety (ID checks — optional but normal)
- **Authentication** — proving *who* a program is, using a **TLS certificate** or a **username and password (SASL)**. Like showing ID at the door.
- **Authorization (ACLs)** — rules about *what each program is allowed to do*, such as "this program may drop mail in Mailbox A but may not read Mailbox B."

### 📨 The clients (the people actually mailing and collecting letters)
- **A producer** — the program that *sends* messages (drops mail off).
- **A consumer** — the program that *receives* messages (picks mail up).

### 🧾 The short version
Put simply, for Kafka to send and receive messages you need: **`Ready` worker nodes with real storage → a running Kafka cluster with a few brokers and their coordination layer → at least one topic to hold the mail → open doors (listeners) and a path clients can reach → and finally a producer and a consumer to actually send and pick up the messages.**

---

## Quick Troubleshooting Tips

- **`kubectl get nodes` shows nothing after Step 4?** Wait a few more minutes — AWS may still be building the computers. Then check again.
- **A scan report flags something?** Don't panic. Open the report in the `scans/` folder and read what it found. Many findings are low-severity notes. Only *serious* (high/critical) issues should make you stop and fix things.
- **The Strimzi pod is stuck on `Pending`?** This often means your workers don't have enough room. Make sure your Node Group from Step 4 is `Ready` and big enough.
- **Used the wrong cluster by accident?** Re-run the Step 2 command with the correct cluster name before doing anything else.
