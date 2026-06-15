Pure AWS CLI: EKS Cluster + Hello Page (No eksctl)

This builds everything with raw aws commands — IAM roles, VPC, control plane, node group, and the app.

Step 0: Install Tools

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
aws --version

# kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.31/2024-12-12/bin/linux/amd64/kubectl
chmod +x kubectl && sudo mv kubectl /usr/local/bin


Step 1: Configure & Set Variables

aws configure   # enter keys, region, output format
aws sts get-caller-identity   # verify

export AWS_REGION=us-east-1
export CLUSTER_NAME=demo-cluster
export K8S_VERSION=1.31
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)


Step 2: Create the Cluster IAM Role

cat <<'EOF' > cluster-trust.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name eksClusterRole \
  --assume-role-policy-document file://cluster-trust.json

aws iam attach-role-policy \
  --role-name eksClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

export CLUSTER_ROLE_ARN=$(aws iam get-role --role-name eksClusterRole --query Role.Arn --output text)


Step 3: Create the Node IAM Role

cat <<'EOF' > node-trust.json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name eksNodeRole \
  --assume-role-policy-document file://node-trust.json

for POLICY in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly; do
  aws iam attach-role-policy \
    --role-name eksNodeRole \
    --policy-arn arn:aws:iam::aws:policy/$POLICY
done

export NODE_ROLE_ARN=$(aws iam get-role --role-name eksNodeRole --query Role.Arn --output text)


Step 4: Create the VPC (CloudFormation)

EKS needs a VPC with properly tagged subnets. AWS provides an official template:

aws cloudformation create-stack \
  --region $AWS_REGION \
  --stack-name eks-vpc \
  --template-url https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml

# Wait until complete (~3 min)
aws cloudformation wait stack-create-complete \
  --region $AWS_REGION --stack-name eks-vpc


Extract the subnet and security group IDs:

export SUBNET_IDS=$(aws cloudformation describe-stacks \
  --region $AWS_REGION --stack-name eks-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SubnetIds'].OutputValue" \
  --output text)

export SECURITY_GROUP=$(aws cloudformation describe-stacks \
  --region $AWS_REGION --stack-name eks-vpc \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroups'].OutputValue" \
  --output text)

echo "Subnets: $SUBNET_IDS"
echo "SG:      $SECURITY_GROUP"


Step 5: Create the EKS Control Plane

# Convert comma-separated subnets into the format the CLI expects
SUBNET_ARG=$(echo $SUBNET_IDS | tr ',' ' ')
aws eks create-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --kubernetes-version $K8S_VERSION \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config \
    subnetIds=$(echo $SUBNET_IDS),securityGroupIds=$SECURITY_GROUP,endpointPublicAccess=false,endpointPrivateAccess=true

aws eks create-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --kubernetes-version $K8S_VERSION \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config subnetIds=$(echo $SUBNET_IDS),securityGroupIds=$SECURITY_GROUP

# Wait for ACTIVE (~10 min)
aws eks wait cluster-active --region $AWS_REGION --name $CLUSTER_NAME


Step 6: Create the Managed Node Group (2 Nodes)

aws eks create-nodegroup \
  --region $AWS_REGION \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name standard-workers \
  --node-role $NODE_ROLE_ARN \
  --subnets $(echo $SUBNET_IDS | tr ',' ' ') \
  --instance-types t3.medium \
  --scaling-config minSize=2,maxSize=2,desiredSize=2

# Wait until ACTIVE (~3–5 min)
aws eks wait nodegroup-active \
  --region $AWS_REGION \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name standard-workers


Step 7: Connect kubectl & Verify

aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

kubectl get nodes
# Two nodes should report STATUS Ready


Step 8: Deploy the Hello Page

cat <<'EOF' > hello-deploy.yaml
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
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "<!DOCTYPE html><html><head><title>Hello EKS</title></head><body style='font-family:sans-serif;text-align:center;padding-top:100px;'><h1>Hello from EKS 👋</h1><p>Served by pod: $HOSTNAME</p></body></html>" > /usr/share/nginx/html/index.html;
            nginx -g 'daemon off;'
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  type: LoadBalancer
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl apply -f hello-deploy.yaml


Step 9: Get the Access URL & Test

kubectl get svc hello --watch    # Ctrl+C once EXTERNAL-IP appears

export HELLO_URL="http://$(kubectl get svc hello -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Access your page at: $HELLO_URL"

curl $HELLO_URL
for i in {1..6}; do curl -s $HELLO_URL | grep "Served by"; done


Step 10: Cleanup (Reverse Order)

# 1. Remove the app (deletes the load balancer)
kubectl delete -f hello-deploy.yaml

# 2. Delete the node group
aws eks delete-nodegroup --region $AWS_REGION \
  --cluster-name $CLUSTER_NAME --nodegroup-name standard-workers
aws eks wait nodegroup-deleted --region $AWS_REGION \
  --cluster-name $CLUSTER_NAME --nodegroup-name standard-workers

# 3. Delete the cluster
aws eks delete-cluster --region $AWS_REGION --name $CLUSTER_NAME
aws eks wait cluster-deleted --region $AWS_REGION --name $CLUSTER_NAME

# 4. Delete the VPC stack
aws cloudformation delete-stack --region $AWS_REGION --stack-name eks-vpc

# 5. Detach policies and delete IAM roles
aws iam detach-role-policy --role-name eksClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name eksClusterRole

for POLICY in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly; do
  aws iam detach-role-policy --role-name eksNodeRole \
    --policy-arn arn:aws:iam::aws:policy/$POLICY
done
aws iam delete-role --role-name eksNodeRole


Notes

	•	The default type: LoadBalancer provisions a Classic Load Balancer. EKS automatically discovers the public subnets via the kubernetes.io/role/elb tags set by the CloudFormation template.
	•	aws eks wait calls block until each resource is ready — useful for scripting, but each step must finish before the next.
	•	Always delete in reverse order; deleting the VPC before the load balancer/nodes will fail due to dependencies.
	•	Confirm the latest supported EKS version and matching kubectl URL before running.