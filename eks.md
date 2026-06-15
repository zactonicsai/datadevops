Complete Step-by-Step: EKS Cluster + Hello Page via AWS CLI

This sets up everything from scratch using AWS CLI + eksctl + kubectl.

Step 0: Install Tools

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version

# eksctl
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.31/2024-12-12/bin/linux/amd64/kubectl
chmod +x kubectl && sudo mv kubectl /usr/local/bin

# helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh && ./get_helm.sh


Step 1: Configure AWS Credentials

aws configure
# AWS Access Key ID:     <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name:   us-east-1
# Default output format: json

# Verify
aws sts get-caller-identity


Step 2: Set Environment Variables

export AWS_REGION=us-east-1
export CLUSTER_NAME=demo-cluster
export K8S_VERSION=1.31
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)


Step 3: Create the Two-Node Cluster

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --version $K8S_VERSION \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 2 \
  --managed \
  --with-oidc


Takes ~15–20 minutes. Creates VPC, subnets, control plane, and the managed node group.

Step 4: Connect kubectl & Verify Nodes

aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

kubectl get nodes
# NAME                          STATUS   ROLES    AGE   VERSION
# ip-192-168-x-x.ec2.internal   Ready    <none>   2m    v1.31.x
# ip-192-168-y-y.ec2.internal   Ready    <none>   2m    v1.31.x


Step 5: Deploy the Hello HTML Page

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


Step 6: Get the Access URL

# Wait ~2 min for the load balancer to provision
kubectl get svc hello --watch
# Press Ctrl+C once EXTERNAL-IP appears

# Capture the URL
export HELLO_URL="http://$(kubectl get svc hello -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "Access your page at: $HELLO_URL"


Step 7: Test It

# Open in browser, or test via curl
curl $HELLO_URL

# Hit it repeatedly to see load balancing across pods
for i in {1..6}; do curl -s $HELLO_URL | grep "Served by"; done


Step 8: Inspect (Optional)

# Pods and which node each runs on
kubectl get pods -o wide

# Service details
kubectl describe svc hello

# View the underlying AWS load balancer
aws elb describe-load-balancers --region $AWS_REGION \
  --query "LoadBalancerDescriptions[].DNSName"


Step 9: Cleanup (Avoid Charges)

# Delete the service first so the load balancer is removed
kubectl delete -f hello-deploy.yaml

# Delete the entire cluster (VPC, nodes, control plane)
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION


Notes

	•	The default type: LoadBalancer provisions a Classic Load Balancer (CLB). For an NLB, add annotation service.beta.kubernetes.io/aws-load-balancer-type: "nlb" under the Service metadata.
	•	EXTERNAL-IP stays <pending> for ~2 minutes during provisioning — this is normal.
	•	Confirm the latest supported EKS version and update K8S_VERSION plus the kubectl download URL accordingly.
	•	Always delete the Service before the cluster, otherwise the orphaned load balancer may keep incurring charges.