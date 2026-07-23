# AWS EKS + KEDA + Two Web Servers + Strimzi Kafka + Two-Node NiFi

This is a step-by-step Terraform tutorial written in plain language. It creates
an Amazon EKS cluster and then places several applications inside it.

Think of EKS as an apartment building:

- The **VPC** is the fenced property.
- The **subnets** are different sections of the property.
- The **EKS worker nodes** are apartment buildings.
- **Pods** are the rooms where applications live.
- A Kubernetes **Service** is the front desk that knows which room to call.
- **KEDA** watches activity and opens or closes more application rooms.
- **Strimzi** is a robot manager that builds and maintains Kafka.
- **Terraform state** is the checklist showing what Terraform already built.

## What this project creates

1. A VPC with two public and two private subnets in two Availability Zones.
2. One NAT Gateway so private EKS nodes can download container images.
3. An EKS 1.35 control plane with private worker nodes.
4. A managed node group that starts with four `m6i.large` nodes.
5. Core EKS add-ons, including the Amazon EBS CSI driver for persistent disks.
6. Metrics Server so Kubernetes can measure pod CPU and memory.
7. KEDA 2.20.1.
8. Two separate small NGINX web-server Deployments with hello pages.
9. A KEDA `ScaledObject` for each web Deployment.
10. Strimzi 1.1.0 and a three-node Kafka 4.3.0 KRaft cluster.
11. Apache NiFi 2.10.0 as a two-pod Kubernetes-aware cluster.
12. A Linux EC2 test runner managed through AWS Systems Manager Session Manager.
13. A toolbox pod and scripts that test web, KEDA, Kafka, NiFi, storage, DNS,
    and basic cluster health.

## Important cost warning

This lab is not free. EKS charges for the control plane. EC2 nodes, the NAT
Gateway, public IPv4 addresses, EBS volumes, logs, and network traffic also cost
money. Run `./scripts/destroy-all.sh` when finished. Read `docs/COST-NOTES.md`.

## Security choices used here

- EKS worker nodes are in private subnets.
- The Linux test runner has **no inbound security-group rules**.
- You connect to the runner with Session Manager instead of SSH.
- The EKS public API endpoint is limited to your detected public IP address.
- The EKS private API endpoint is also enabled for the in-VPC test runner.
- EKS control-plane logs are enabled.
- Kubernetes Secrets are encrypted with a customer-managed KMS key.
- Workloads use CPU and memory requests and limits.
- NiFi is exposed only as a ClusterIP service in this tutorial.

The NiFi web interface uses HTTP only inside the cluster for easy learning.
That is **not** a production security design. Production NiFi should use TLS,
OIDC or another approved identity provider, secure secrets, NetworkPolicies,
and a reviewed ingress path.

## Folder map

```text
aws-eks-keda-nifi-strimzi-tutorial/
├── README.md
├── ARCHITECTURE.md
├── VERSION-NOTES.md
├── config/
│   └── project.env.example
├── docs/
├── helm/
├── kubectl/
├── scripts/
└── terraform/
    ├── 01-network/
    ├── 02-eks/
    ├── 03-metrics-server/
    ├── 04-keda/
    ├── 05-http-app/
    ├── 06-strimzi-operator/
    ├── 07-kafka-cluster/
    ├── 08-nifi-cluster/
    ├── 09-test-runner/
    └── 10-test-tools/
```

Every numbered Terraform folder owns a separate local `terraform.tfstate` file.
Later folders read earlier state files with `terraform_remote_state` when they
need VPC or EKS values. See `DIRECTORY-STRUCTURE.txt` for the complete file tree
and `VALIDATION-NOTES.md` for the checks performed before packaging.

## Tools needed on your computer

Install these before starting:

- Terraform 1.8 or newer
- AWS CLI version 2
- kubectl
- Helm 3
- Bash, `curl`, and `jq`
- AWS credentials with permission to create VPC, IAM, EKS, EC2, KMS, CloudWatch,
  and EKS add-on resources

Run the checker:

```bash
./scripts/check-prerequisites.sh
```

## Step 1: Set AWS credentials

Use an AWS CLI profile, AWS IAM Identity Center, or environment credentials.
Verify the identity:

```bash
aws sts get-caller-identity
```

Do not use the AWS root user for this lab.

## Step 2: Create the local settings file

```bash
cp config/project.env.example config/project.env
```

Open `config/project.env` and review the region, project name, and node sizes.

## Step 3: Preview the work

```bash
./scripts/plan-all.sh
```

The plan script writes logs under `logs/`. On the first run it can plan only the
network because later folders read local state from earlier folders. After the
network and EKS exist, run the script again to preview the remaining layers.

## Step 4: Build everything

```bash
./scripts/apply-all.sh
```

The script performs these actions in order:

1. Builds networking.
2. Builds EKS and the node group.
3. Creates a private kubeconfig under `.kube/config`.
4. Installs Metrics Server.
5. Installs KEDA.
6. Creates both hello web applications and KEDA scaling rules.
7. Installs the Strimzi operator.
8. Creates Kafka.
9. Creates the two-node NiFi cluster.
10. Creates the SSM-only EC2 test runner.
11. Creates the toolbox pod and test permissions.
12. Runs the local verification script.

## Step 5: Check the cluster with AWS CLI and kubectl

```bash
source config/project.env
aws eks describe-cluster \
  --region "$AWS_REGION" \
  --name "${PROJECT_NAME}-${ENVIRONMENT}" \
  --query 'cluster.status'

KUBECONFIG="$PWD/.kube/config" kubectl get nodes -o wide
KUBECONFIG="$PWD/.kube/config" kubectl get pods -A
KUBECONFIG="$PWD/.kube/config" kubectl get pvc -A
```

## Step 6: Test the hello web service

Use port forwarding from your computer:

```bash
KUBECONFIG="$PWD/.kube/config" \
  kubectl port-forward -n web service/hello-web 8088:80
```

Open `http://localhost:8088` in a browser. Refresh several times. You should see
responses from server A and server B because the Service balances traffic.

## Step 7: Watch KEDA

In one terminal:

```bash
KUBECONFIG="$PWD/.kube/config" kubectl get scaledobject,hpa -n web -w
```

In another terminal:

```bash
./scripts/load-test.sh
```

KEDA uses CPU information from Metrics Server. The two Deployments begin with
one pod each and can grow to five pods each. KEDA scales pods, not EC2 worker
nodes. This tutorial starts with enough worker capacity; add Karpenter or the
Kubernetes Cluster Autoscaler for production-style node scaling.

## Step 8: Check Kafka

```bash
KUBECONFIG="$PWD/.kube/config" kubectl get kafka,kafkanodepool,kafkatopic -n kafka
KUBECONFIG="$PWD/.kube/config" kubectl get pods -n kafka
```

The automated test writes a message to `tutorial-topic` and reads it back.

## Step 9: Check NiFi

```bash
KUBECONFIG="$PWD/.kube/config" kubectl get pods,service,pvc -n nifi
KUBECONFIG="$PWD/.kube/config" kubectl port-forward -n nifi service/nifi 8080:8080
```

Open `http://localhost:8080/nifi/`.

The two NiFi pods coordinate leader election with Kubernetes Lease objects.
Each pod receives its own gp3 EBS volume.

## Step 10: Run all tests from your computer

```bash
./scripts/run-tests-local.sh
```

## Step 11: Run tests from the Linux test runner

Start a Session Manager shell:

```bash
./scripts/run-tests-ssm.sh
```

Inside the test runner, run:

```bash
sudo /usr/local/bin/eks-tutorial-test.sh
```

The runner can reach the private EKS API endpoint and VPC-CNI pod IPs. Service
DNS checks run through the toolbox pod because Kubernetes ClusterIP addresses
exist inside the cluster network. The runner does not accept SSH or any other
inbound network connection.

## Step 12: Destroy the lab

```bash
./scripts/destroy-all.sh
```

Destroy order is the reverse of build order. This matters because Kubernetes
volumes and load-related resources should be removed before the EKS cluster and
VPC disappear.

If `RETAIN_APPLICATION_VOLUMES=true`, some EBS volumes can remain after destroy.
Use the AWS CLI to find them:

```bash
aws ec2 describe-volumes \
  --region "$AWS_REGION" \
  --filters "Name=tag:Project,Values=$PROJECT_NAME"
```

## Direct command-line examples

Terraform in one folder after its earlier layers exist:

```bash
source config/project.env
export TF_VAR_cluster_name="${PROJECT_NAME}-${ENVIRONMENT}"
export TF_VAR_kubeconfig_path="$PWD/.kube/config"

cd terraform/04-keda
terraform init
terraform plan
terraform apply
```

Helm inspection:

```bash
KUBECONFIG="$PWD/.kube/config" helm list -A
KUBECONFIG="$PWD/.kube/config" helm status keda -n keda
KUBECONFIG="$PWD/.kube/config" helm status strimzi-cluster-operator -n strimzi-system
```

kubectl inspection:

```bash
KUBECONFIG="$PWD/.kube/config" kubectl describe scaledobject hello-server-a -n web
KUBECONFIG="$PWD/.kube/config" kubectl logs -n keda deployment/keda-operator
KUBECONFIG="$PWD/.kube/config" kubectl logs -n strimzi-system deployment/strimzi-cluster-operator
KUBECONFIG="$PWD/.kube/config" kubectl get events -A --sort-by=.lastTimestamp
```

## Official references

- Amazon EKS: https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html
- EKS Kubernetes versions: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
- Terraform AWS provider: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- Terraform Kubernetes provider: https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs
- Terraform Helm provider: https://registry.terraform.io/providers/hashicorp/helm/latest/docs
- KEDA: https://keda.sh/docs/2.20/
- Metrics Server: https://github.com/kubernetes-sigs/metrics-server
- Strimzi: https://strimzi.io/docs/operators/latest/
- Apache NiFi administration guide: https://nifi.apache.org/nifi-docs/administration-guide.html

See `docs/TROUBLESHOOTING.md` for common errors.
