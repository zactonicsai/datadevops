# AWS vs. Azure — Side-by-Side Guide

The easiest way to learn AWS and Azure together is to think of them as two companies selling many of the **same building blocks but giving them different names**.

## Quick bullet-point comparison

* **AWS VPC = Azure VNet** — your private network in the cloud. ([AWS Documentation][1])
* **AWS Subnet = Azure Subnet** — a smaller IP-address section inside the VPC/VNet. ([AWS Documentation][1])
* **AWS Security Group = Azure Network Security Group (NSG)** — firewall-like rules controlling traffic.
* **AWS Route Table = Azure Route Table/UDR** — tells network traffic where to go. Azure automatically creates many basic routes between VNet subnets. ([Microsoft Learn][2])
* **AWS Internet Gateway = Azure's built-in Internet routing + Public IP model** — Azure networking does not require you to attach an AWS-style Internet Gateway to every VNet.
* **AWS NAT Gateway = Azure NAT Gateway** — lets private systems reach outside networks without giving those systems public IP addresses. ([Microsoft Learn][3])
* **Amazon EKS = Azure AKS** — managed Kubernetes.
* **Amazon ECR = Azure Container Registry (ACR)** — stores Docker/container images.
* **AWS Elastic Load Balancing = Azure Load Balancer/Application Gateway** — distributes traffic across servers or Kubernetes workloads. ([AWS Documentation][4])
* **AWS CodePipeline + CodeBuild = Azure Pipelines** — automate build, test, container creation, and deployment. ([AWS Documentation][5])
* **AWS IAM = Microsoft Entra ID + Azure RBAC** — controls who can do what.
* **AWS CloudWatch = Azure Monitor** — logs, metrics, alerts, and troubleshooting.
* **AWS Auto Scaling/EKS Auto Mode = Azure Cluster Autoscaler/AKS Automatic** — adds or removes compute when demand changes. EKS Auto Mode can automatically create and remove cluster compute, while AKS supports Cluster Autoscaler and newer node auto-provisioning options. ([AWS Documentation][6])
* **Terraform works with both**, which is a major reason companies use it for multi-cloud environments.

---

# 1. Main service comparison

| What you need                       | AWS                                | Azure                                                    |
| ----------------------------------- | ---------------------------------- | -------------------------------------------------------- |
| Private cloud network               | **VPC**                            | **VNet**                                                 |
| Network section                     | Subnet                             | Subnet                                                   |
| Network firewall                    | Security Group                     | Network Security Group                                   |
| Routing                             | Route Table                        | Route Table / UDR                                        |
| Private outbound Internet           | NAT Gateway                        | NAT Gateway                                              |
| Kubernetes                          | EKS                                | AKS                                                      |
| Kubernetes automatic infrastructure | EKS Auto Mode                      | AKS Automatic / Node Auto-Provisioning                   |
| Container registry                  | ECR                                | ACR                                                      |
| VM                                  | EC2                                | Azure VM                                                 |
| VM scaling                          | Auto Scaling Group                 | VM Scale Set                                             |
| TCP/UDP load balancing              | NLB                                | Azure Load Balancer                                      |
| HTTP/HTTPS load balancing           | ALB                                | Application Gateway / Application Gateway for Containers |
| Kubernetes ingress                  | ALB / AWS Load Balancer Controller | AKS App Routing / Application Gateway                    |
| CI/CD pipeline                      | CodePipeline                       | Azure Pipelines                                          |
| Build system                        | CodeBuild                          | Azure Pipelines jobs                                     |
| Monitoring                          | CloudWatch                         | Azure Monitor                                            |
| DNS                                 | Route 53                           | Azure DNS                                                |
| Permissions                         | IAM                                | Entra ID + Azure RBAC                                    |
| Secrets                             | Secrets Manager                    | Key Vault                                                |
| Infrastructure as Code              | CloudFormation                     | ARM/Bicep                                                |
| Multi-cloud IaC                     | Terraform                          | Terraform                                                |

For Kubernetes specifically, AWS has increasingly moved management into **EKS Auto Mode**, where compute, load balancing, and EBS storage can be handled automatically. Azure similarly offers **AKS Automatic**, while AKS Standard lets you explicitly configure Cluster Autoscaler, node pools, networking, and other infrastructure. ([AWS Documentation][7])

---

# 2. Networking: VPC vs. VNet

Think of a cloud network like a **school building**.

The VPC or VNet is the entire school.

A subnet is one hallway.

A security group or NSG is the security guard.

A route table is the hallway sign saying:

> Cafeteria → this way
> Gym → that way
> Internet → exit here

AWS calls the main network a **VPC**. Azure calls it a **VNet**. An AWS subnet belongs to one Availability Zone. Both systems use CIDR ranges such as `10.10.0.0/16` to define available private addresses. ([AWS Documentation][1])

A common production design looks like this:

```text
                    INTERNET
                       |
              +----------------+
              | Load Balancer  |
              +----------------+
                       |
        +-----------------------------+
        |         VPC / VNet          |
        |                             |
        |  AZ/Zone 1       AZ/Zone 2  |
        |                             |
        | Public subnet   Public subnet
        |                             |
        | Private subnet  Private subnet
        |      |               |      |
        |   Kubernetes      Kubernetes |
        |     nodes            nodes   |
        |                             |
        |     Database / services     |
        +-----------------------------+
```

For EKS, AWS requires the cluster networking to use VPC subnets, and EKS cluster subnets must span at least two Availability Zones. ([AWS Documentation][8])

---

# 3. AWS VPC example

Let's create this network:

```text
VPC
10.10.0.0/16

Public subnet A
10.10.1.0/24

Public subnet B
10.10.2.0/24

Private subnet A
10.10.11.0/24

Private subnet B
10.10.12.0/24
```

AWS CLI uses commands such as `create-vpc`, `create-subnet`, route tables, and gateways to build the network. ([AWS Documentation][9])

### Set variables

```bash
export AWS_REGION=us-east-1
```

### Create the VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.10.0.0/16 \
  --region $AWS_REGION \
  --query 'Vpc.VpcId' \
  --output text)

echo $VPC_ID
```

Think of:

```text
10.10.0.0/16
```

as saying:

> "AWS, reserve a large private block of addresses for my network."

Enable useful DNS features:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames '{"Value":true}'
```

---

# 4. AWS public subnets

Create one subnet in each Availability Zone:

```bash
PUBLIC_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.10.1.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' \
  --output text)

PUBLIC_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.10.2.0/24 \
  --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' \
  --output text)
```

Now create an Internet Gateway:

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID
```

In AWS, a subnet normally becomes a **public subnet because its route table has a route to an Internet Gateway**. AWS route tables control where traffic from subnets goes. ([AWS Documentation][1])

Create the public route table:

```bash
PUBLIC_RT=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' \
  --output text)

aws ec2 create-route \
  --route-table-id $PUBLIC_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID
```

Associate it:

```bash
aws ec2 associate-route-table \
  --route-table-id $PUBLIC_RT \
  --subnet-id $PUBLIC_SUBNET_1

aws ec2 associate-route-table \
  --route-table-id $PUBLIC_RT \
  --subnet-id $PUBLIC_SUBNET_2
```

The route:

```text
0.0.0.0/0 → Internet Gateway
```

basically means:

> "Anything that isn't inside my network can go toward the Internet."

---

# 5. AWS private subnets

Create private subnets:

```bash
PRIVATE_SUBNET_1=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.10.11.0/24 \
  --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' \
  --output text)

PRIVATE_SUBNET_2=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.10.12.0/24 \
  --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' \
  --output text)
```

A production Kubernetes design commonly puts worker nodes in **private subnets** while a public ALB/NLB lives in appropriate load-balancer subnets. AWS's EKS guidance supports public or private load balancers and recommends appropriately designed VPC networking. ([AWS Documentation][10])

Private nodes that need outbound Internet access can normally use a NAT Gateway.

```text
Private Node
     |
     v
Private Subnet
     |
     v
NAT Gateway
     |
     v
Internet Gateway
     |
     v
Internet
```

---

# 6. Azure networking equivalent

Now build approximately the same thing in Azure.

The big network is called a **VNet**.

First create a Resource Group:

```bash
az group create \
  --name demo-rg \
  --location eastus
```

Then create the VNet:

```bash
az network vnet create \
  --resource-group demo-rg \
  --name demo-vnet \
  --address-prefixes 10.20.0.0/16 \
  --subnet-name public-subnet-1 \
  --subnet-prefixes 10.20.1.0/24
```

Microsoft's current Azure CLI supports creating a VNet and initial subnet in one command this way. ([Microsoft Learn][11])

Add another subnet:

```bash
az network vnet subnet create \
  --resource-group demo-rg \
  --vnet-name demo-vnet \
  --name public-subnet-2 \
  --address-prefixes 10.20.2.0/24
```

Add AKS/private subnets:

```bash
az network vnet subnet create \
  --resource-group demo-rg \
  --vnet-name demo-vnet \
  --name aks-subnet-1 \
  --address-prefixes 10.20.10.0/23
```

Azure's command for adding subnets is `az network vnet subnet create`. ([Microsoft Learn][12])

---

# 7. Important AWS vs. Azure networking difference

This is one area that often confuses AWS engineers moving into Azure.

AWS heavily teaches:

```text
Public Subnet
Private Subnet
Internet Gateway
NAT Gateway
Route Table
```

Azure networking works somewhat differently because Azure automatically provides system routing between VNet subnets. You add route tables when you want to override or customize those routes. ([Microsoft Learn][2])

Also, as of **March 31, 2026**, new Azure VNets using current APIs default toward private-subnet behavior without implicit default outbound Internet connectivity. Microsoft recommends using an explicit outbound method such as Azure NAT Gateway when Internet egress is required. ([Microsoft Learn][13])

So today's Azure design looks increasingly similar conceptually to good AWS private-subnet design:

```text
Private workload
      |
      v
Azure subnet
      |
      v
NAT Gateway
      |
      v
Public IP
      |
      v
Internet
```

---

# 8. Security Group vs. NSG

AWS:

```text
Security Group
```

Azure:

```text
Network Security Group
```

Think of both as a security guard checking network traffic.

For example:

```text
Allow HTTPS 443
Allow HTTP 80
Deny unwanted traffic
```

AWS example:

```bash
aws ec2 create-security-group \
  --group-name web-sg \
  --description "Web server security group" \
  --vpc-id $VPC_ID
```

Then:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 443 \
  --cidr 10.0.0.0/8
```

AWS CLI defines `authorize-security-group-ingress` as the operation for adding inbound Security Group rules. ([AWS Documentation][14])

Azure equivalent:

```bash
az network nsg create \
  --resource-group demo-rg \
  --name web-nsg
```

Then:

```bash
az network nsg rule create \
  --resource-group demo-rg \
  --nsg-name web-nsg \
  --name AllowHTTPS \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 443
```

Conceptually:

```text
AWS                            Azure

Security Group                Network Security Group
      |                                |
      v                                v
Is port 443 allowed?          Is port 443 allowed?
      |                                |
     YES                              YES
      |                                |
      v                                v
Application receives traffic
```

---

# 9. Kubernetes: EKS vs. AKS

This is one of the closest comparisons.

| Kubernetes concept              | AWS                                    | Azure                           |
| ------------------------------- | -------------------------------------- | ------------------------------- |
| Managed Kubernetes              | EKS                                    | AKS                             |
| Worker machines                 | EC2 nodes                              | Azure VM/VMSS nodes             |
| Group of workers                | Node Group / NodePool                  | Node Pool                       |
| Modern automatic infrastructure | EKS Auto Mode                          | AKS Automatic                   |
| Container registry              | ECR                                    | ACR                             |
| L4 service                      | NLB                                    | Standard Load Balancer          |
| HTTP ingress                    | ALB                                    | Application Gateway/App Routing |
| Pod autoscaling                 | Kubernetes HPA                         | Kubernetes HPA                  |
| Node autoscaling                | Auto Mode/Karpenter/Cluster Autoscaler | Cluster Autoscaler/NAP          |

EKS Auto Mode automatically creates and deletes EC2 compute as workloads need capacity and builds on Karpenter. AKS Cluster Autoscaler watches for pods that cannot be scheduled and adds nodes; it can later remove unneeded nodes. ([AWS Documentation][6])

---

# 10. AWS EKS Auto Mode

For a newer AWS deployment, **EKS Auto Mode is worth learning** because AWS can manage much more of the cluster infrastructure.

With Auto Mode enabled, AWS can manage:

```text
EC2 nodes
Node scaling
Load balancers
EBS storage
Networking components
```

The current EKS CLI configuration has switches for managed compute, managed load balancing, and managed block storage. ([AWS Documentation][7])

A simplified cluster definition looks like:

```bash
aws eks create-cluster \
  --region us-east-1 \
  --cli-input-json '{
    "name": "demo-eks",
    "version": "1.35",
    "roleArn": "arn:aws:iam::ACCOUNT:role/AmazonEKSAutoClusterRole",

    "resourcesVpcConfig": {
      "subnetIds": [
        "subnet-private1",
        "subnet-private2"
      ],
      "endpointPublicAccess": true,
      "endpointPrivateAccess": true
    },

    "computeConfig": {
      "enabled": true,
      "nodeRoleArn":
        "arn:aws:iam::ACCOUNT:role/AmazonEKSAutoNodeRole",
      "nodePools": [
        "general-purpose",
        "system"
      ]
    },

    "kubernetesNetworkConfig": {
      "elasticLoadBalancing": {
        "enabled": true
      }
    },

    "storageConfig": {
      "blockStorage": {
        "enabled": true
      }
    },

    "accessConfig": {
      "authenticationMode": "API"
    }
  }'
```

The example structure follows AWS's current Auto Mode CLI model. AWS requires separate cluster and node IAM roles for Auto Mode. ([AWS Documentation][7])

Connect `kubectl`:

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name demo-eks
```

Then:

```bash
kubectl get nodes
```

---

# 11. Azure AKS with autoscaling

Azure makes this particular setup shorter.

```bash
az aks create \
  --resource-group demo-rg \
  --name demo-aks \
  --node-count 2 \
  --vm-set-type VirtualMachineScaleSets \
  --load-balancer-sku standard \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 6 \
  --generate-ssh-keys
```

That says:

```text
Start nodes = 2
Minimum nodes = 2
Maximum nodes = 6
```

AKS can automatically increase or decrease the node count between the configured minimum and maximum. Microsoft's current documented CLI uses `--enable-cluster-autoscaler`, `--min-count`, and `--max-count`. ([Microsoft Learn][15])

Get credentials:

```bash
az aks get-credentials \
  --resource-group demo-rg \
  --name demo-aks
```

Then:

```bash
kubectl get nodes
```

---

# 12. Two different kinds of autoscaling

This is very important.

You can scale:

```text
PODS
```

and you can scale:

```text
NODES
```

They are **not the same thing**.

Imagine a pizza restaurant.

A pod is a cook.

A node is a kitchen.

If customers arrive, Kubernetes can first hire more cooks:

```text
2 pods
   ↓
5 pods
```

But eventually the kitchen becomes full.

Then cluster autoscaling adds another kitchen:

```text
2 nodes
   ↓
3 nodes
   ↓
4 nodes
```

AWS EKS supports Kubernetes HPA, and EKS Auto Mode can automatically add compute when pods do not fit. Azure AKS similarly supports HPA plus node-level Cluster Autoscaler or newer node auto-provisioning. ([AWS Documentation][16])

---

# 13. Pod autoscaling works almost exactly the same

Once you are inside Kubernetes, AWS and Azure become much more similar.

For example:

```bash
kubectl autoscale deployment web-app \
  --cpu-percent=60 \
  --min=2 \
  --max=10
```

This means:

```text
Minimum pods: 2
Maximum pods: 10

CPU < target
   ↓
Maybe reduce pods

CPU > 60%
   ↓
Add pods
```

Or use YAML:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler

metadata:
  name: web-hpa

spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app

  minReplicas: 2
  maxReplicas: 10

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

AKS documentation uses this same Kubernetes HPA model. ([Microsoft Learn][17])

One difference to remember: the Kubernetes Metrics Server is not automatically present in every manually created EKS configuration, so verify it before using CPU-based HPA. AWS now also supports Metrics Server as an EKS add-on. ([AWS Documentation][18])

---

# 14. Kubernetes load balancing

This is where Kubernetes makes AWS and Azure look almost identical.

Create:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: web-service

spec:
  type: LoadBalancer

  selector:
    app: web

  ports:
    - port: 80
      targetPort: 8080
```

Apply it:

```bash
kubectl apply -f service.yaml
```

On **EKS Auto Mode**, a Kubernetes Service of type `LoadBalancer` can automatically provision an AWS Network Load Balancer. No separate load-balancer controller installation is required for that Auto Mode behavior. ([AWS Documentation][19])

On **AKS**, a Service of type `LoadBalancer` creates/configures an Azure Load Balancer and external IP. Current AKS deployments use the Standard Load Balancer SKU. ([Microsoft Learn][20])

So the same:

```bash
kubectl apply -f service.yaml
```

might cause this:

```text
AWS

Internet
   |
   v
AWS NLB
   |
   v
Kubernetes Service
   |
   +---- Pod
   |
   +---- Pod
   |
   +---- Pod
```

while Azure creates:

```text
Azure

Internet
   |
   v
Azure Standard Load Balancer
   |
   v
Kubernetes Service
   |
   +---- Pod
   |
   +---- Pod
   |
   +---- Pod
```

---

# 15. HTTP load balancing

There is another important distinction.

A normal L4 load balancer mostly thinks about:

```text
IP
Port
TCP
UDP
```

An application load balancer understands things such as:

```text
https://company.com/api
https://company.com/login
https://company.com/images
```

AWS normally uses an **Application Load Balancer** for this kind of HTTP/HTTPS routing. EKS Auto Mode can create an ALB from Kubernetes Ingress resources. ([AWS Documentation][21])

Azure provides application-aware ingress options including Application Gateway/Application Gateway for Containers and AKS application-routing capabilities. Current Azure CLI includes AKS application load-balancer and application-routing commands. ([Microsoft Learn][22])

---

# 16. DevOps pipeline architecture

A good pipeline should look almost identical conceptually.

## AWS

```text
Developer
    |
    v
GitHub / Git repository
    |
    v
CodePipeline
    |
    v
CodeBuild
    |
    +---- Compile
    |
    +---- Unit tests
    |
    +---- Security tests
    |
    +---- docker build
    |
    v
ECR
    |
    v
CodePipeline EKS Deploy
    |
    v
EKS
    |
    v
Pods
```

AWS CodePipeline is designed to model automated release stages, and AWS provides a native EKS deployment action. The EKS deploy action can work with both public and private EKS clusters. ([AWS Documentation][5])

## Azure

```text
Developer
    |
    v
Azure Repos / GitHub
    |
    v
Azure Pipelines
    |
    +---- Compile
    |
    +---- Unit tests
    |
    +---- Security tests
    |
    +---- docker build
    |
    v
ACR
    |
    v
AKS Deployment
    |
    v
AKS
    |
    v
Pods
```

Azure Pipelines supports YAML pipelines for building, testing, configuring, and deploying applications. ([Microsoft Learn][23])

---

# 17. AWS container registry

Create an ECR repository:

```bash
aws ecr create-repository \
  --repository-name hello-app \
  --region us-east-1
```

Login:

```bash
aws ecr get-login-password \
  --region us-east-1 |
docker login \
  --username AWS \
  --password-stdin \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

Build:

```bash
docker build -t hello-app .
```

Tag:

```bash
docker tag hello-app:latest \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/hello-app:latest
```

Push:

```bash
docker push \
  ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/hello-app:latest
```

AWS's current CodePipeline EKS workflow expects a working image repository such as ECR before deployment. ([AWS Documentation][24])

---

# 18. Azure container registry

Azure equivalent:

```bash
az acr create \
  --resource-group demo-rg \
  --name demoregistry123 \
  --sku Basic
```

Login:

```bash
az acr login \
  --name demoregistry123
```

Build:

```bash
docker build -t hello-app .
```

Tag:

```bash
docker tag hello-app:latest \
  demoregistry123.azurecr.io/hello-app:latest
```

Push:

```bash
docker push \
  demoregistry123.azurecr.io/hello-app:latest
```

Then AKS pulls the image from ACR rather than EKS pulling it from ECR.

---

# 19. AWS CodeBuild example

Create a file:

```text
buildspec.yml
```

Example:

```yaml
version: 0.2

phases:

  pre_build:
    commands:
      - echo Logging into ECR

  build:
    commands:
      - echo Running tests
      - ./gradlew test

      - echo Building Docker image
      - docker build -t hello-app .

  post_build:
    commands:
      - echo Pushing image
      - docker push $ECR_IMAGE
```

CodeBuild acts as the build/test action inside CodePipeline. ([AWS Documentation][25])

The overall pipeline might contain:

```text
SOURCE
   |
   v
BUILD
   |
   v
TEST
   |
   v
PUSH IMAGE
   |
   v
DEPLOY
```

AWS also supports:

```bash
aws codepipeline create-pipeline \
  --cli-input-json file://pipeline.json
```

The `pipeline.json` file normally defines your source, build, and deployment stages.

---

# 20. Azure Pipelines YAML

Azure usually places the pipeline definition in:

```text
azure-pipelines.yml
```

For example:

```yaml
trigger:
  - main

pool:
  vmImage: ubuntu-latest

stages:

  - stage: Build
    jobs:
      - job: BuildApplication
        steps:

          - script: ./gradlew test
            displayName: Run tests

          - script: |
              docker build \
                -t $(ACR_NAME).azurecr.io/hello-app:$(Build.BuildId) .
            displayName: Build image


  - stage: Deploy
    jobs:
      - job: DeployAKS
        steps:

          - script: |
              kubectl apply -f kubernetes/
            displayName: Deploy to AKS
```

Azure uses YAML pipelines as a standard way to describe build and deployment workflows. ([Microsoft Learn][26])

You can create a pipeline from the command line with Azure DevOps CLI:

```bash
az devops configure \
  --defaults \
  organization=https://dev.azure.com/MYORG \
  project=MYPROJECT
```

Then:

```bash
az pipelines create \
  --name hello-app-pipeline \
  --repository MY-REPOSITORY \
  --branch main \
  --yml-path azure-pipelines.yml
```

Azure DevOps CLI supports programmatic creation and execution of YAML pipelines. ([Microsoft Learn][27])

Run it:

```bash
az pipelines run \
  --name hello-app-pipeline
```

---

# 21. Complete flow comparison

| Stage                   | AWS                                      | Azure                           |
| ----------------------- | ---------------------------------------- | ------------------------------- |
| Developer pushes code   | GitHub                                   | GitHub/Azure Repos              |
| Pipeline detects change | CodePipeline                             | Azure Pipelines                 |
| Compile                 | CodeBuild                                | Pipeline Agent                  |
| Unit test               | CodeBuild                                | Pipeline Agent                  |
| Security scan           | CodeBuild/tools                          | Pipeline tasks/tools            |
| Docker build            | CodeBuild                                | Pipeline Agent                  |
| Store container         | ECR                                      | ACR                             |
| Deploy                  | CodePipeline EKS action / kubectl / Helm | Azure Pipeline / kubectl / Helm |
| Kubernetes              | EKS                                      | AKS                             |
| Pods scale              | HPA                                      | HPA                             |
| Nodes scale             | EKS Auto Mode                            | AKS Cluster Autoscaler/NAP      |
| Load balancing          | NLB/ALB                                  | Standard LB/Application Gateway |
| Monitor                 | CloudWatch                               | Azure Monitor                   |

AWS provides a specific CodePipeline EKS deploy workflow, while Azure Pipelines uses stages/tasks and can run Azure CLI or Kubernetes deployment commands. ([AWS Documentation][24])

---

# 22. A good production design

For either cloud, I would organize a Kubernetes application roughly like this:

```text
                    USERS
                      |
                     HTTPS
                      |
             +------------------+
             |  Load Balancer   |
             +------------------+
                      |
             --------------------
             |                  |
          Zone A             Zone B
             |                  |
       +------------+     +------------+
       | K8s Node   |     | K8s Node   |
       +------------+     +------------+
         |       |           |       |
       Pod      Pod         Pod      Pod
         \       |           |       /
          \------+-----------+------/
                     |
                  Service
                     |
               Internal APIs
                     |
                Database
```

The important idea is:

```text
Load Balancer
      ↓
Kubernetes Service
      ↓
Pods
      ↓
Nodes
      ↓
Multiple Zones
```

AWS EKS requires VPC networking and supports multi-AZ designs, while AKS supports multiple node pools, Availability Zones, HPA, Cluster Autoscaler, and other scaling approaches. ([AWS Documentation][8])

---

# 23. What happens during heavy traffic?

Suppose normally you have:

```text
2 nodes
2 pods
```

Traffic increases.

HPA sees CPU climbing:

```text
2 pods
 ↓
4 pods
 ↓
8 pods
```

Eventually Kubernetes says:

```text
I do not have enough space
for another pod.
```

Now the node autoscaler reacts.

AWS EKS Auto Mode:

```text
2 EC2 nodes
     ↓
3 nodes
     ↓
4 nodes
```

Azure AKS Cluster Autoscaler:

```text
2 VMSS nodes
     ↓
3 nodes
     ↓
4 nodes
```

When demand falls, pods can scale down and unnecessary nodes can later be removed. EKS Auto Mode automatically creates and consolidates compute; AKS Cluster Autoscaler monitors unschedulable pods and underused nodes. ([AWS Documentation][6])

---

# 24. One major advantage of Kubernetes

Your application YAML can often stay nearly identical.

For example:

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: hello-app

spec:
  replicas: 2

  selector:
    matchLabels:
      app: hello-app

  template:
    metadata:
      labels:
        app: hello-app

    spec:
      containers:

        - name: hello-app
          image: IMAGE_NAME

          ports:
            - containerPort: 8080

          resources:

            requests:
              cpu: 100m
              memory: 128Mi

            limits:
              cpu: 500m
              memory: 512Mi
```

Then this:

```yaml
apiVersion: v1
kind: Service

metadata:
  name: hello-service

spec:
  type: LoadBalancer

  selector:
    app: hello-app

  ports:

    - port: 80
      targetPort: 8080
```

The Kubernetes objects remain essentially cloud-neutral.

The cloud-specific parts become things such as:

```text
AWS

VPC
EKS
IAM
ECR
ALB/NLB
CloudWatch
```

versus:

```text
Azure

VNet
AKS
Entra/RBAC
ACR
Azure Load Balancer
Azure Monitor
```

---

# 25. Where Terraform fits

For teams supporting both AWS and Azure, I would strongly separate the layers like this:

```text
Git Repository
      |
      +-----------------------+
      |                       |
      v                       v
   Terraform               Helm
      |                       |
      v                       v
Cloud Infrastructure    Kubernetes Apps
```

Terraform handles:

```text
VPC/VNet
Subnets
Security Groups/NSGs
IAM/RBAC
EKS/AKS
Registries
DNS
Load-balancer infrastructure
```

Helm/Kubernetes handles:

```text
Deployments
Services
Ingress
ConfigMaps
Secrets references
HPA
PodDisruptionBudgets
Kafka
NiFi
Keycloak
application services
```

This approach also makes moving workloads between EKS and AKS much easier because the Kubernetes layer changes less.

---

# 26. Simple mental cheat sheet

| Say this in AWS    | Think this in Azure |
| ------------------ | ------------------- |
| VPC                | VNet                |
| Security Group     | NSG                 |
| IAM                | Entra ID / RBAC     |
| EC2                | VM                  |
| Auto Scaling Group | VM Scale Set        |
| EKS                | AKS                 |
| ECR                | ACR                 |
| ALB                | Application Gateway |
| NLB                | Azure Load Balancer |
| Route 53           | Azure DNS           |
| CloudWatch         | Azure Monitor       |
| CodePipeline       | Azure Pipelines     |
| Secrets Manager    | Key Vault           |
| CloudFormation     | Bicep/ARM           |

## The biggest thing to remember

Don't try to memorize every AWS and Azure product name first.

Remember this flow:

```text
NETWORK
   ↓
SUBNETS
   ↓
SECURITY
   ↓
CLUSTER
   ↓
NODES
   ↓
PODS
   ↓
SERVICE
   ↓
LOAD BALANCER
   ↓
DNS
```

Then add:

```text
Git
 ↓
CI/CD Pipeline
 ↓
Build
 ↓
Test
 ↓
Container Registry
 ↓
Kubernetes
 ↓
Autoscaling
 ↓
Monitoring
```

That architecture is fundamentally the same whether the labels on the boxes say **AWS** or **Azure**. The implementation details—especially IAM, network routing, load-balancer integrations, and pipeline tooling—are where the clouds differ. ([AWS Documentation][7])

If you'd like to turn this into a hands-on lab, a useful next step would be a **complete AWS EKS vs. Azure AKS project with matching Terraform files, AWS CLI/Azure CLI setup scripts, Docker hello-world app, Kubernetes YAML, HPA, load balancing, CI/CD pipeline files, test scripts, and destroy scripts** arranged side-by-side in one directory structure.

[1]: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html?utm_source=chatgpt.com "What is Amazon VPC? - Amazon Virtual Private Cloud"
[2]: https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview?utm_source=chatgpt.com "Azure virtual network traffic routing"
[3]: https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview?utm_source=chatgpt.com "What Is Azure NAT Gateway?"
[4]: https://docs.aws.amazon.com/eks/latest/best-practices/load-balancing.html?utm_source=chatgpt.com "Load Balancing - Amazon EKS"
[5]: https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome.html?utm_source=chatgpt.com "What is AWS CodePipeline? - AWS ..."
[6]: https://docs.aws.amazon.com/eks/latest/userguide/autoscaling.html?utm_source=chatgpt.com "Scale cluster compute with Karpenter and Cluster Autoscaler"
[7]: https://docs.aws.amazon.com/eks/latest/userguide/automode-get-started-cli.html "Create an EKS Auto Mode Cluster with the AWS CLI - Amazon EKS"
[8]: https://docs.aws.amazon.com/eks/latest/userguide/network-reqs.html?utm_source=chatgpt.com "View Amazon EKS networking requirements for VPC and ..."
[9]: https://docs.aws.amazon.com/cli/latest/reference/ec2/create-vpc.html?utm_source=chatgpt.com "create-vpc — AWS CLI 2.36.9 Command Reference"
[10]: https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html?utm_source=chatgpt.com "Route application and HTTP traffic with Application Load ..."
[11]: https://learn.microsoft.com/en-us/cli/azure/network/vnet?view=azure-cli-latest&utm_source=chatgpt.com "az network vnet"
[12]: https://learn.microsoft.com/en-us/cli/azure/network/vnet/subnet?view=azure-cli-latest&utm_source=chatgpt.com "az network vnet subnet"
[13]: https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access?utm_source=chatgpt.com "Default Outbound Access in Azure - Virtual Network"
[14]: https://docs.aws.amazon.com/cli/latest/reference/ec2/authorize-security-group-ingress.html?utm_source=chatgpt.com "authorize-security-group-ingress"
[15]: https://learn.microsoft.com/en-us/azure/aks/cluster-autoscaler "Use the Cluster Autoscaler in Azure Kubernetes Service (AKS) - Azure Kubernetes Service | Microsoft Learn"
[16]: https://docs.aws.amazon.com/eks/latest/userguide/horizontal-pod-autoscaler.html?utm_source=chatgpt.com "Scale pod deployments with Horizontal Pod Autoscaler"
[17]: https://learn.microsoft.com/en-us/azure/aks/tutorial-kubernetes-scale "Kubernetes on Azure tutorial - Scale applications in Azure Kubernetes Service (AKS) - Azure Kubernetes Service | Microsoft Learn"
[18]: https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html?utm_source=chatgpt.com "View resource usage with the Kubernetes Metrics Server"
[19]: https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-nlb.html?utm_source=chatgpt.com "Use Service Annotations to configure Network Load ..."
[20]: https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard "Use a Public Standard Load Balancer in Azure Kubernetes Service (AKS) - Azure Kubernetes Service | Microsoft Learn"
[21]: https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-alb.html?utm_source=chatgpt.com "Create an IngressClass to configure an Application Load ..."
[22]: https://learn.microsoft.com/en-us/cli/azure/aks?view=azure-cli-latest "az aks | Microsoft Learn"
[23]: https://learn.microsoft.com/en-us/azure/devops/pipelines/create-first-pipeline?view=azure-devops&utm_source=chatgpt.com "Create your first pipeline - Azure Pipelines"
[24]: https://docs.aws.amazon.com/codepipeline/latest/userguide/tutorials-eks-deploy.html "Tutorial: Deploy to Amazon EKS with CodePipeline - AWS CodePipeline"
[25]: https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodeBuild.html?utm_source=chatgpt.com "AWS CodeBuild build and test action reference"
[26]: https://learn.microsoft.com/en-us/azure/devops/pipelines/customize-pipeline?view=azure-devops&utm_source=chatgpt.com "Customize your pipeline - Azure Pipelines"
[27]: https://learn.microsoft.com/en-us/azure/devops/pipelines/get-started/manage-pipelines-with-azure-cli?view=azure-devops "Manage pipelines with the Azure DevOps CLI - Azure Pipelines | Microsoft Learn"
