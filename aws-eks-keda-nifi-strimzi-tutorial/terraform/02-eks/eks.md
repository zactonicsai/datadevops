# 02 - EKS Cluster, IAM Roles, and Cluster Security

This folder creates the EKS control plane, managed worker nodes, encryption,
AWS identity roles, OIDC integration, and core EKS add-ons.

The cluster uses the private subnets created by `01-network`.

## Companion guides

- [EKS-CLUSTER-IAM-ROLE-README.md](EKS-CLUSTER-IAM-ROLE-README.md) explains `iam-cluster.tf`.
- [EKS-NODE-IAM-ROLE-README.md](EKS-NODE-IAM-ROLE-README.md) explains `iam-nodes.tf`.
- [EBS-CSI-IAM-ROLE-README.md](EBS-CSI-IAM-ROLE-README.md) explains `ebs-csi-iam.tf`.
- [OIDC-README.md](OIDC-README.md) explains `oidc.tf` and pod identity trust.
- [EKS-CLUSTER-SECURITY-GROUP-README.md](EKS-CLUSTER-SECURITY-GROUP-README.md) explains the AWS-managed primary EKS security group.

## Simple picture

```text
AWS EKS service
      |
      | assumes cluster IAM role
      v
EKS control plane ---- primary EKS security group ---- worker nodes
                                                    |
                                                    | assume node IAM role
                                                    v
                                             AWS APIs and ECR

EBS CSI controller pod
      |
      | uses OIDC web identity
      v
EBS CSI IAM role ---- creates and attaches EBS volumes
```

## Public and private API access

The cluster has both endpoint types enabled:

- The private endpoint lets resources inside the VPC reach the Kubernetes API.
- The public endpoint lets your approved workstation CIDR reach the API.

The public endpoint is restricted by `public_access_cidrs`. Use your public IP
with `/32` instead of opening the API to the whole internet.

## Run this layer

The network layer must already be applied.

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Configure `kubectl`:

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name "$(terraform output -raw cluster_name)"
```

A simpler command from the project root is:

```bash
./scripts/update-kubeconfig.sh
```

Test the cluster:

```bash
kubectl get nodes -o wide
kubectl get pods -A
aws eks describe-cluster \
  --region us-east-1 \
  --name "$(terraform output -raw cluster_name)" \
  --query 'cluster.status' \
  --output text
```
