
# Adding a node group to an existing EKS cluster (AWS CLI)

## The big-picture analogy first

Think of your EKS **cluster** as the brain of a robot factory. The brain knows what should happen, but it has no hands. A **node group** is a set of identical worker robots (EC2 servers) that actually do the work. You already built the brain; now you’re hiring a crew of workers and plugging them in.

A **managed node group** means AWS babysits those workers for you: it groups them in an Auto Scaling group, replaces broken ones, and drains them politely during updates. Every managed node is provisioned as part of an Amazon EC2 Auto Scaling group that’s managed for you by Amazon EKS, and every resource runs within your AWS account. 

## Tools you need installed in your shell

- **AWS CLI v2** — the main tool. Everything below is `aws eks ...`. (If you’re in AWS CloudShell, it’s already there.)
- **kubectl** — optional but strongly recommended, to check that the workers actually showed up.
- That’s it. You do **not** need eksctl for this; the question asks for plain AWS CLI.

Check versions:

```bash
aws --version        # want aws-cli/2.x
kubectl version --client
```

## Information you must gather before running anything

You need five pieces of info. Three are non-negotiable; the worker robots literally cannot start without them.

1. **Cluster name** — which brain you’re attaching to.
1. **Node IAM role ARN** — a permission badge for the workers. The EKS worker node kubelet daemon makes calls to AWS APIs on your behalf, and worker nodes receive permissions for these API calls through an IAM instance profile; before you can launch worker nodes and register them into a cluster, you must create an IAM role for those worker nodes. 
1. **Subnets** — which parts of your network the workers live in.
1. **Scaling numbers** — min / max / desired count.
1. **Instance type + AMI type** — what kind of machine, and what OS image.

### Step 1 — Confirm the cluster exists and note its version

```bash
aws eks list-clusters --region us-east-1

aws eks describe-cluster \
  --name MY_CLUSTER \
  --region us-east-1 \
  --query 'cluster.{version:version,status:status}'
```

Why this matters: you can only create a node group for your cluster that is equal to the current Kubernetes version for the cluster.  The workers must speak the same version as the brain.

### Step 2 — Find your subnets

```bash
aws eks describe-cluster \
  --name MY_CLUSTER \
  --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.subnetIds'
```

You can reuse these or pick a subset (often the private ones). Note: if you put workers in a **public** subnet, the subnet must have MapPublicIpOnLaunch set to true for the instances to successfully join a cluster.  If you use **private** subnets, you must ensure they can access Amazon ECR for pulling container images, either by connecting a NAT gateway to the route table of the subnet or by adding the AWS PrivateLink VPC endpoints.  Otherwise the workers boot but can’t download anything and silently fail.

### Step 3 — Create the Node IAM role (skip if you already have one)

This is the part people forget. The role needs three managed policies attached.

First, a trust file that says “EC2 servers may wear this badge”:

```bash
cat > node-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
```

Create the role and attach the policies:

```bash
aws iam create-role \
  --role-name eksNodeRole \
  --assume-role-policy-document file://node-trust-policy.json

aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```

In plain terms: policy one lets the worker talk to EKS, policy two lets it pull container images from ECR, policy three lets it set up pod networking. Grab the ARN for the next step:

```bash
aws iam get-role --role-name eksNodeRole --query 'Role.Arn' --output text
```

## The latest AMI type options (this is the part that changed recently)

The `--ami-type` flag picks the operating system image. **This is the most important “latest options” detail**, because the old default is gone: Amazon EKS stopped publishing EKS-optimized Amazon Linux 2 (AL2) AMIs on November 26, 2025; AL2023 and Bottlerocket based AMIs are available for all supported Kubernetes versions including 1.33 and higher.  And any newly created managed node groups in clusters on version 1.30 or newer will automatically default to using AL2023 as the node operating system. 

The current valid values include AL2023_x86_64_STANDARD, AL2023_ARM_64_STANDARD, AL2023_x86_64_NEURON, AL2023_x86_64_NVIDIA, AL2023_ARM_64_NVIDIA, the BOTTLEROCKET family (x86_64, ARM_64, plus FIPS and NVIDIA variants), and the WINDOWS Core/Full 2019–2025 types. 

Quick chooser:

- **General workloads, Intel/AMD** → `AL2023_x86_64_STANDARD`
- **Cheaper / Graviton ARM** → `AL2023_ARM_64_STANDARD` (match this with ARM instances like `m7g.large`)
- **GPU workloads** → `AL2023_x86_64_NVIDIA`
- **Locked-down container-only OS** → `BOTTLEROCKET_x86_64`. Bottlerocket includes only the essential software to run containers, which improves resource usage, reduces security threats, and lowers management overhead. 

One gotcha worth knowing if pods misbehave after launch: AL2023 requires IMDSv2 by default, and for managed node groups not using a launch template, the default metadata hop count is set to 1.  That can break apps relying on node metadata unless you use IRSA or a launch template raising the hop limit.

## Step 4 — Capacity type and scaling

`--capacity-type` is `ON_DEMAND` (stable, full price) or `SPOT` (cheap, can be reclaimed). If you go Spot, it’s recommended to specify multiple values for instanceTypes. 

Scaling note: if you use the Kubernetes Cluster Autoscaler, you shouldn’t change the desiredSize value directly, as this can cause the Cluster Autoscaler to suddenly scale up or scale down. 

## Step 5 — Run the command

Basic on-demand group:

```bash
aws eks create-nodegroup \
  --cluster-name MY_CLUSTER \
  --nodegroup-name MY_NODEGROUP \
  --node-role arn:aws:iam::111122223333:role/eksNodeRole \
  --subnets subnet-aaa subnet-bbb subnet-ccc \
  --scaling-config minSize=2,maxSize=5,desiredSize=2 \
  --instance-types m6i.large \
  --ami-type AL2023_x86_64_STANDARD \
  --capacity-type ON_DEMAND \
  --disk-size 50 \
  --region us-east-1
```

Fuller version with labels, taints, update control, and **node auto-repair** (a newer feature where node auto repair continuously monitors the health of nodes and automatically reacts to detected problems and replaces nodes when possible ):

```bash
aws eks create-nodegroup \
  --cluster-name MY_CLUSTER \
  --nodegroup-name app-spot-arm \
  --node-role arn:aws:iam::111122223333:role/eksNodeRole \
  --subnets subnet-aaa subnet-bbb \
  --scaling-config minSize=2,maxSize=10,desiredSize=3 \
  --instance-types m7g.large m7g.xlarge \
  --ami-type AL2023_ARM_64_STANDARD \
  --capacity-type SPOT \
  --disk-size 50 \
  --update-config maxUnavailablePercentage=33 \
  --node-repair-config enabled=true \
  --labels role=app,team=payments \
  --taints 'key=dedicated,value=payments,effect=NO_SCHEDULE' \
  --tags Owner=platform,Env=prod \
  --region us-east-1
```

A couple of flag notes. `--disk-size` default is 20 GiB for Linux and Bottlerocket, and 50 GiB for Windows.  And a critical rule if you ever add `--launch-template`: if you specify launchTemplate, then don’t specify diskSize, and don’t specify SubnetId in your launch template, or the node group deployment will fail.  The launch template and these direct flags are mutually exclusive for the same settings.

Tip for getting the syntax exactly right:

```bash
aws eks create-nodegroup --generate-cli-skeleton > ng.json
# edit ng.json, then:
aws eks create-nodegroup --cli-input-json file://ng.json
```

## Step 6 — Watch it come up

Creation takes a few minutes. Poll the status:

```bash
aws eks describe-nodegroup \
  --cluster-name MY_CLUSTER \
  --nodegroup-name MY_NODEGROUP \
  --region us-east-1 \
  --query 'nodegroup.status'
```

Wait for `ACTIVE` (it passes through `CREATING` first). Or block until done:

```bash
aws eks wait nodegroup-active \
  --cluster-name MY_CLUSTER \
  --nodegroup-name MY_NODEGROUP \
  --region us-east-1
```

Then confirm the workers joined the brain:

```bash
aws eks update-kubeconfig --name MY_CLUSTER --region us-east-1
kubectl get nodes -o wide
```

You should see your new nodes in `Ready` state. If they never appear, it’s almost always (1) subnet has no route to ECR/internet, or (2) the node IAM role is missing one of the three policies.

## One-line mental summary

Gather **cluster name + node role ARN + subnets**, pick an **AL2023 or Bottlerocket AMI type** (AL2 is retired), set **min/max/desired**, run `aws eks create-nodegroup`, then `aws eks wait nodegroup-active` and `kubectl get nodes` to verify.

Want me to turn this into a single ready-to-run script with your actual cluster name and region filled in, or generate the `--cli-input-json` skeleton pre-filled?
## First, the one fork in the road

Where your nodes live decides how `curl` can reach them:

- If your nodes are in **public** subnets (with public IPs) → you can `curl` the node’s own IP directly (Option A below). This is the most literal “connect to the node instance via curl.”
- If your nodes are in **private** subnets (the recommended setup I mentioned earlier) → the internet (and AWS CloudShell) can’t see the node’s IP. Use a **LoadBalancer** (Option B) or **port-forward** (Option C) instead.

All three end the same way: `curl` → `hello world`.

## Step 7 — Deploy the hello-world app onto your nodes

Plain terms: a **Deployment** is “please keep N copies of this little program running,” and Kubernetes will place those copies on your worker nodes. We’ll use `http-echo`, a one-trick program whose only job is to reply with whatever text you give it.

Create the file:

```bash
cat > hello.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: hello
          image: hashicorp/http-echo      # you can pin a tag, e.g. :0.2.3
          args:
            - "-text=hello world"          # <-- the words curl will get back
            - "-listen=:5678"              # the port the program listens on
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  type: NodePort                           # change to LoadBalancer for Option B
  selector:
    app: hello
  ports:
    - port: 80                             # the service's own port
      targetPort: 5678                     # forwards to the container's port
      nodePort: 30080                      # the door opened on every node (30000–32767)
EOF
```

Apply it and confirm the copies actually landed on your new node group:

```bash
kubectl apply -f hello.yaml

kubectl get pods -l app=hello -o wide      # NODE column = which worker it's on
kubectl get svc hello                      # shows the NodePort mapping
```

A **Service** is a stable front desk: pods come and go, but the Service’s address stays put and forwards traffic to whichever pods are alive. A **NodePort** Service opens the same numbered door (here `30080`) on *every* node, so hitting any node on that port reaches the app.

-----

## Option A — curl the node instance directly (public nodes)

This is the literal “connect to the node instance via curl.” Two things must be true: the node has a public IP, and its firewall (security group) lets your computer in on port `30080`.

**A1. Get a node’s public address:**

```bash
kubectl get nodes -o wide
```

Look at the `EXTERNAL-IP` column. If it says `<none>`, your nodes are private → skip to Option B or C.

**A2. Find the security group that node uses.** Grab one instance ID, then read its security group:

```bash
NODE_INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=MY_NODEGROUP" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region us-east-1)

aws ec2 describe-instances --instance-ids $NODE_INSTANCE \
  --query 'Reservations[].Instances[].SecurityGroups' --region us-east-1
```

**A3. Open the door for *your* IP only** (not the whole internet):

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 authorize-security-group-ingress \
  --group-id sg-REPLACE_WITH_NODE_SG \
  --protocol tcp --port 30080 \
  --cidr ${MY_IP}/32 \
  --region us-east-1
```

The `/32` means “exactly this one address.” A security group is a bouncer; by default it turns away unexpected visitors, so we explicitly let yourself in.

**A4. Knock on the door:**

```bash
curl http://<NODE_EXTERNAL_IP>:30080
# -> hello world
```

-----

## Option B — curl a public URL (works for private nodes too, most robust)

Change the Service type to `LoadBalancer` (edit `hello.yaml`, set `type: LoadBalancer`, remove the `nodePort` line), then:

```bash
kubectl apply -f hello.yaml
kubectl get svc hello -w        # wait until EXTERNAL-IP changes from <pending> to a hostname
```

AWS builds a load balancer in front of your nodes (takes ~2–3 minutes). Then from anywhere:

```bash
curl http://<EXTERNAL-IP-hostname>
# -> hello world
```

A load balancer is a public receptionist with its own address that quietly passes calls to your private workers, so you never need to touch node IPs or firewalls. (Small note: a load balancer costs a little money while it exists.)

-----

## Option C — port-forward (always works, no firewall changes)

Best when nodes are private and you just want proof it works from your shell:

```bash
kubectl port-forward svc/hello 8080:80
```

Leave that running, open a second shell:

```bash
curl http://localhost:8080
# -> hello world
```

`port-forward` builds a private tunnel from your laptop straight into the cluster through the Kubernetes API, so no node IP or security-group rule is involved.

-----

## Optional Step 9 — actually log *into* the node and curl from on the box

If by “connect to the node instance” you meant getting a shell **on the EC2 server itself** and curling locally, use SSM Session Manager (no SSH keys, no open ports needed).

One extra permission is required — the node role I set up earlier didn’t include it:

```bash
aws iam attach-role-policy --role-name eksNodeRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

Then start a shell on a node and curl the NodePort from inside it:

```bash
aws ssm start-session --target $NODE_INSTANCE --region us-east-1

# now you're ON the node:
curl http://localhost:30080
# -> hello world
```

Because a NodePort listens on every node’s own network, `localhost:30080` from on the box reaches the app. One caveat from earlier research: if you chose a **Bottlerocket** AMI, the OS deliberately ships with no shell — Bottlerocket images don’t include an SSH server or a shell  — so you’d land in its special admin/control container rather than a normal Linux prompt. AL2023 gives you a regular shell.

## Cleanup when you’re done

```bash
kubectl delete -f hello.yaml     # removes the app + service (+ load balancer if used)

# if you opened the firewall in Option A, close it again:
aws ec2 revoke-security-group-ingress \
  --group-id sg-REPLACE_WITH_NODE_SG \
  --protocol tcp --port 30080 --cidr ${MY_IP}/32 --region us-east-1
```

## Where this leaves you

Full arc: create node group → `kubectl get nodes` shows workers `Ready` → `kubectl apply -f hello.yaml` puts the app on them → expose via NodePort / LoadBalancer / port-forward → `curl` returns `hello world`.

Want me to bundle everything from both turns — node-group creation plus this hello-world test — into one runnable `.sh` script with placeholders (cluster name, region, subnets) marked clearly at the top?