# 01 - AWS Network Layer

This folder builds the private AWS network used by the EKS tutorial.

Think of the network as a small neighborhood:

- The **VPC** is the fence around the neighborhood.
- A **subnet** is a street inside the neighborhood.
- The **Internet Gateway** is the public front gate.
- The **NAT Gateway** is a guarded exit for private computers.
- A **route table** is a set of road signs that tells traffic where to go.

The EKS control plane and worker nodes use the private subnets. Public subnets
hold internet-facing network helpers such as the NAT Gateway.

## Companion guides

Read these files for a simple explanation of each network resource:

1. [VPC-README.md](VPC-README.md) explains `vpc.tf`.
2. [SUBNETS-README.md](SUBNETS-README.md) explains `subnets.tf`.
3. [INTERNET-GATEWAY-README.md](INTERNET-GATEWAY-README.md) explains `internet_gateway.tf`.
4. [NAT-GATEWAY-README.md](NAT-GATEWAY-README.md) explains `nat_gateway.tf`.
5. [ROUTE-TABLES-README.md](ROUTE-TABLES-README.md) explains `routes.tf`.

## Build order

Terraform works out most dependencies automatically, but the network is easier
to understand in this order:

```text
VPC
 ├── Public subnet 1 ── Internet Gateway ── Internet
 ├── Public subnet 2
 ├── Private subnet 1 ── NAT Gateway ─────── Internet
 └── Private subnet 2 ── NAT Gateway ─────── Internet
```

## Run this layer

From this directory:

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Show the network IDs after apply:

```bash
terraform output
```

## Test the network

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$(terraform output -raw vpc_id)"

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

## Why this layer runs first

The EKS folder reads this folder's local `terraform.tfstate` file. It needs the
VPC ID and private subnet IDs before it can create the cluster.

Do not move or delete `terraform.tfstate` while later layers still use it.
