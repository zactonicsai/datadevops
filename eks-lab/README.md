# EKS Lab: Web App → Kafka → NiFi → S3

A small, cheap, **teaching** lab you can build in about 30 minutes and destroy
in about 20. Two versions of the same thing:

- `cli/` — one shell script per step, so you see every AWS API call
- `terraform/` — the same infrastructure declared in HCL

Build it with the shell scripts first (you learn what each piece *is*), then
build it again with Terraform (you learn how to make it repeatable).

---

## What you are building

```
   ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
   │  Web app │────▶│  Kafka   │────▶│   NiFi   │────▶│    S3    │
   │ (browser)│     │ (queue)  │     │ (mover)  │     │ (storage)│
   └──────────┘     └──────────┘     └──────────┘     └──────────┘
        │                                  ▲
        │                                  │ writes with a temporary
        │                                  │ AWS identity (IRSA) —
        │                                  │ no access keys anywhere
        │
        │           ┌──────────┐
        └───────────│ Keycloak │  logins (optional in this lab)
                    └──────────┘
                    ┌──────────┐
                    │ Grafana  │  watches all of the above
                    └──────────┘
```

**The story, in one sentence:** you type a message into a web page, it lands on
a Kafka queue, NiFi picks it up and saves it as a file in S3.

**Why each piece exists:**

| Piece | What it is | Why it is here |
|---|---|---|
| **Web app** | 40 lines of Python with a text box | Something that *produces* data |
| **Kafka** | A conveyor belt for messages | A buffer, so a slow consumer never loses data |
| **NiFi** | Drag-and-drop data mover | The thing that reads Kafka and writes S3 |
| **S3** | Object storage | The final destination |
| **Keycloak** | Identity provider | Shows how apps share one login |
| **Grafana** | Dashboards | Shows how you watch a running system |

---

## What this costs

The whole point of a lab is that it is cheap and you delete it. Rough numbers
for `us-east-1`, at the defaults:

| Item | Per hour | Per day if you forget |
|---|---|---|
| EKS control plane | $0.10 | $2.40 |
| 2 × t3.large **SPOT** | ~$0.05 | ~$1.20 |
| NAT gateway (`use_nat = true`) | $0.045 | $1.08 |
| EBS disks (~20 GiB) | ~$0.002 | $0.05 |
| S3, CloudWatch | pennies | pennies |
| **Total** | **≈ $0.20** | **≈ $4.75** |

**Three ways to spend less:**

1. **Destroy it when you stop.** This is 95% of the savings. `./cli/destroy/destroy-all.sh`
2. **Set `USE_NAT=false`** (shell) or `use_nat = false` (Terraform). Saves ~$33/month.
   Nodes then sit in public subnets with public IPs — still firewalled by
   security groups, but directly addressable. Acceptable for a throwaway lab,
   never for production.
3. **Delete just the node group overnight** and rebuild in the morning.
   That is exactly why node groups are their own layer.

> The S3 bucket has a lifecycle rule that deletes objects after 7 days, and the
> CloudWatch log group has 7-day retention, so even a forgotten lab stops
> accumulating storage charges.

---

## Before you start

You need:

```bash
aws --version        # v2
kubectl version --client
helm version         # only for the monitoring step
terraform version    # only for the Terraform version
```

And working credentials:

```bash
aws sts get-caller-identity     # must print your account — if not, stop here
```

**Strongly recommended:** restrict the lab to your own IP address.

```bash
export MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "$MY_IP"
```

---

## Version A — the shell scripts

Each script does **exactly one thing**. Run them in order. Every script tells
you what comes next.

```bash
cd cli

./01-create-vpc.sh              # the private network
./02-create-networking.sh       # subnets, gateways, routes      (~3 min)
./03-create-iam.sh              # the two roles
./04-create-security-groups.sh  # the firewalls
./05-create-cluster.sh          # the Kubernetes control plane   (~13 min)
./06-create-launch-template.sh  # the recipe for a worker machine
./07-create-nodegroup.sh        # the worker machines            (~5 min)
./08-create-s3-and-irsa.sh      # the bucket + NiFi's AWS identity
./09-install-addons.sh          # storage driver, metrics        (~3 min)

./10-launch-keycloak.sh         # apps from here down
./11-launch-kafka.sh
./12-launch-nifi.sh             # slowest app, ~3 min
./13-launch-webapp.sh
./14-launch-grafana.sh          # optional, and the heaviest

./15-create-nifi-flow.sh        # prints the click-by-click flow guide
./16-verify.sh                  # checks every link in the chain
```

### How the scripts pass information to each other

There is no magic. Script 01 writes the VPC id into a file called
`cli/.lab-state`, and script 02 reads it:

```bash
$ cat cli/.lab-state
export ACCOUNT_ID="111122223333"
export VPC_ID="vpc-0a1b2c3d"
export SUBNET_PUB_A="subnet-0aaa"
...
```

This is a hand-rolled version of what Terraform calls **state**. Seeing it as a
plain text file makes the Terraform version much easier to understand: it is
the same idea, with locking, versioning and dependency tracking added.

If you want to start completely over: `rm cli/.lab-state` (after destroying).

### The two meanings of "launch template"

You asked for launch templates for the apps, and there is a naming collision
worth clearing up:

- **`06-create-launch-template.sh`** creates a real **EC2 launch template** —
  an AWS object describing what a virtual machine should look like (disk size,
  encryption, metadata settings). Node groups use it.
- **`10-` to `14-launch-*.sh`** launch the *applications* using **Kubernetes
  manifests**. Those are templates too, but for containers, not machines.

Different layer, same word. The scripts are named to make the distinction
obvious as you read them.

---

## Version B — Terraform

Same infrastructure, declared instead of scripted.

```bash
cd terraform

./apply-all.sh          # runs all five layers in order

# ...or one layer at a time, which is the real workflow:
cd 01-vpc
terraform init
terraform plan  -var-file=../dev.tfvars -out=tfplan
terraform apply tfplan
```

### The five layers

| Layer | Contains | Changes how often |
|---|---|---|
| `01-vpc` | VPC, subnets, routes, NAT, S3 endpoint | Almost never |
| `02-iam-sg` | Cluster role, node role, security groups | Rarely |
| `03-cluster` | EKS control plane, S3 bucket, IRSA roles, add-ons | Occasionally |
| `04-nodegroup` | Launch template + managed node group | Often (resize, upgrade) |
| `05-apps` | Keycloak, Kafka, NiFi, web app, monitoring | Constantly |

**Why split them at all?** Three reasons that matter:

1. **Blast radius.** Each layer has its own state file. A mistake in the apps
   layer cannot delete your VPC, because Terraform can only destroy what is in
   *its own* state.
2. **Speed.** A 40-resource plan takes seconds and gets read carefully. A
   600-resource plan takes minutes and gets skimmed.
3. **Cost.** You can `terraform destroy` layer 4 every evening to stop paying
   for EC2, and rebuild it in the morning, without touching anything else.

Layers connect through `terraform_remote_state`, which is **read-only**:

```hcl
data "terraform_remote_state" "vpc" {
  backend = "local"
  config  = { path = "../01-vpc/terraform.tfstate" }
}
# then: data.terraform_remote_state.vpc.outputs.vpc_id
```

### Everything environment-specific lives in `dev.tfvars`

To make a staging environment, copy the file and change the numbers:

```bash
cp dev.tfvars stage.tfvars
# edit: bigger CIDR, ON_DEMAND nodes, more replicas
terraform apply -var-file=../stage.tfvars
```

**The `.tf` code never changes between environments.** That is the entire
design goal. If you find yourself editing a `.tf` file to make stage work,
add a variable instead.

### Two Terraform gotchas in this lab

- **`05-apps` needs a live cluster at *plan* time**, not just apply time,
  because `kubernetes_manifest` validates against the real API server. So
  layers 1–4 must exist before you can even plan layer 5. That is why it is a
  separate layer with its own `terraform init`.
- **State is local here** (`terraform.tfstate` files on disk) to keep the lab
  simple. For any real team, uncomment the S3 backend block at the top of each
  `main.tf`. Local state means no locking, no history, and no sharing.

---

## Build the NiFi flow

The infrastructure is automatic; the flow is worth doing by hand once, because
seeing the boxes and arrows is how NiFi makes sense.

Run `./cli/15-create-nifi-flow.sh` — it prints the steps with **your** bucket
name and Kafka address already filled in. The short version:

1. `kubectl -n lab port-forward svc/nifi 8443:8443`, open `https://localhost:8443/nifi`
2. Controller Settings → add **Kafka3ConnectionService** → set bootstrap servers → **enable it**
3. Add a **ConsumeKafka** processor → point it at that service and your topic
4. Add a **PutS3Object** processor → set bucket and region, **leave credentials empty**
5. Drag an arrow from ConsumeKafka to PutS3Object on the `success` relationship
6. Auto-terminate `success` and `failure` on PutS3Object
7. Press Start

**Why "leave credentials empty" is the interesting step.** The NiFi pod already
has temporary AWS credentials, injected by Kubernetes because its service
account is annotated with an IAM role. NiFi's AWS library finds them
automatically. If you paste an access key into that box instead, you have just
created the long-lived secret that this whole mechanism exists to eliminate.

Prove it yourself:

```bash
kubectl -n lab exec nifi-0 -- env | grep AWS_ROLE_ARN
# AWS_ROLE_ARN=arn:aws:iam::111122223333:role/ekslab-nifi-irsa
```

---

## Test the whole pipeline

```bash
# terminal 1
kubectl -n lab port-forward svc/webapp 8000:80
# browse to http://localhost:8000 and send a message

# terminal 2 — did Kafka receive it?
kubectl -n lab exec -it kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic messages --from-beginning

# terminal 3 — did it reach S3? (allow ~10 seconds)
aws s3 ls s3://$(cd terraform/03-cluster && terraform output -raw s3_bucket)/ --recursive
```

Or just run `./cli/16-verify.sh`, which checks every link in order and tells
you which one broke.

---

## Destroying it

**Do this.** An idle lab still costs about $4/day.

```bash
./cli/destroy/destroy-all.sh          # shell version
./terraform/destroy-all.sh            # Terraform version
```

### Why the order matters

Destroy is creation in reverse, and skipping the order produces confusing
`DependencyViolation` errors:

```
  apps       → releases load balancers and EBS volumes
  node group → stops the EC2 spend
  cluster    → stops the $0.10/hour
  IAM + S3   → roles must have policies DETACHED before deletion
  networking → NAT gateway before subnets (it lives in one)
  VPC        → last, and only once it is empty
```

The individual scripts (`d1-` … `d6-`) let you stop part way — for example,
run `d2` only, to delete the nodes overnight and keep everything else.

### If the VPC will not delete

Something is still inside it, usually a load balancer or a network interface
that takes a few minutes to clear:

```bash
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=vpc-xxxx --output table
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='vpc-xxxx']" --output table
```

Wait five minutes and re-run `d6-destroy-vpc.sh`.

### Confirm nothing is left

```bash
aws eks list-clusters
aws ec2 describe-vpcs --filters Name=tag:Lab,Values=ekslab
aws ec2 describe-addresses          # an UNATTACHED Elastic IP is billed hourly
aws s3 ls | grep ekslab
```

---

## The safety choices, and why

Everything below is free. There is no reason not to do it, even in a lab —
and doing it in a lab is how it becomes a habit.

| Choice | What it prevents |
|---|---|
| **No port 22 anywhere; SSM instead** | No SSH keys to lose. Shell access is logged in CloudTrail. |
| **IMDSv2 required, hop limit 1** | A compromised pod cannot steal the *node's* AWS credentials |
| **IRSA per application** | NiFi can write to one bucket. Nothing else can. |
| **Node role kept minimal** | If IRSA breaks, it fails loudly instead of silently using node permissions |
| **`runAsNonRoot: true`** | A container escape starts as an unprivileged user |
| **Encrypted EBS and S3** | Data at rest is unreadable if a disk is recovered |
| **S3 public access blocked** | The single most common cloud data leak, prevented in one line |
| **`requests` and `limits` on every pod** | One greedy pod cannot starve the node and take everything down |
| **Startup probes on Java apps** | Kubernetes stops killing slow-booting apps mid-boot in a loop |
| **`WaitForFirstConsumer` on the StorageClass** | No disk created in one AZ while its pod runs in another |
| **Generated passwords in Secrets** | No credentials in any file you might commit |
| **Everything tagged `Lab=ekslab`** | You can always find and delete what you created |

**Where this lab deliberately differs from production**, so you are not
surprised later:

| Lab shortcut | Production answer |
|---|---|
| Keycloak `start-dev` with an in-pod database | RDS + the Keycloak Operator |
| NiFi single-user login | Keycloak OIDC (see the main tutorial, Part 13) |
| One Kafka broker | Three brokers, replication factor 3, or Amazon MSK |
| Public EKS API endpoint | Private endpoint + VPN/bastion |
| Self-signed certificates | ACM or an internal CA with cert-manager |
| Local Terraform state | S3 backend with locking and versioning |
| `pip install` at pod startup | A properly built container image |
| `force_destroy = true` on the bucket | Never, on anything with real data |

---

## When something breaks

Debug **in order**. The first failure is the real problem; everything after it
is a symptom.

```
Can Terraform/aws reach AWS?     → credentials
   ↓
Does the AWS resource exist?     → earlier script or layer
   ↓
Can kubectl reach the cluster?   → aws eks update-kubeconfig
   ↓
Are the nodes Ready?             → kubectl get nodes
   ↓
Is the pod Scheduled?            → resources, taints, PVC zone
   ↓
Did the image pull?              → kubectl describe pod
   ↓
Did the container start?         → kubectl logs --previous
   ↓
Can traffic reach it?            → Service, endpoints, port-forward
```

The three commands that answer most questions:

```bash
kubectl -n lab describe pod <name>      # read the EVENTS at the bottom
kubectl -n lab logs <name> --previous   # what it said just before it died
kubectl get events -A --sort-by='.lastTimestamp' | tail -30
```

Common ones in this lab:

| Symptom | Cause | Fix |
|---|---|---|
| Pod `Pending` forever | Not enough CPU/memory on 2 nodes | `NODE_DESIRED=3`, or skip Grafana |
| PVC `Pending` | EBS CSI driver missing | Run `09-install-addons.sh` |
| NiFi blank page after login | Host header not in `NIFI_WEB_PROXY_HOST` | Add the hostname you are using |
| NiFi cannot write to S3 | Service account annotation missing, or pod started before it | `kubectl -n lab rollout restart statefulset/nifi` |
| Web app cannot reach Kafka | Wrong advertised listener | Check `KAFKA_ADVERTISED_LISTENERS` matches the pod's DNS name |
| Node never joins | IAM policies or subnet routing | `aws ssm start-session --target i-xxx` then `sudo nodeadm debug` |
| `terraform destroy` hangs on the VPC | Load balancer still present | Delete the apps namespace first |

---

## Suggested learning path

1. Run the shell scripts once, reading each before you run it.
2. Break something deliberately: `kubectl -n lab delete pod kafka-0` and watch
   Kubernetes rebuild it.
3. Run `./cli/destroy/destroy-all.sh`.
4. Build the exact same thing with Terraform and compare the two.
5. Change one value in `dev.tfvars` (say `node_desired = 3`) and watch what
   `terraform plan` proposes. This is the single most useful Terraform habit.
6. Destroy it again.
