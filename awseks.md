Good — now the goal becomes: **put a tiny “hello world” web server onto the node group you just built, then reach it with `curl` and get the words back.** I’ll continue the step numbers from before.

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