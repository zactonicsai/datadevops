Setting up Karpenter involves a multi-step process that bridges your Kubernetes cluster with AWS APIs. Karpenter works by bypassing traditional Auto Scaling Groups (ASGs), instead provisioning EC2 instances directly based on pending pod requirements.
High-Level Prerequisites
 * EKS Cluster: Kubernetes 1.25+.
 * Tools: aws CLI, kubectl, helm, and eksctl (for managing infrastructure).
 * IAM Permissions: Karpenter needs permissions to manage EC2 instances (create/terminate) and interact with EKS.
Step-by-Step Setup Guide
1. Setup IAM Infrastructure
Karpenter needs an IAM role to launch nodes.
 * Create the Controller Role: Use eksctl or CloudFormation to create the IAM role that the Karpenter controller will assume via IRSA (IAM Roles for Service Accounts) or EKS Pod Identity.
 * Create Node Role: Create an IAM role for the worker nodes themselves (often named KarpenterNodeRole), which includes policies for ECR, SSM, and CNI access.
2. Install Karpenter via Helm
 * Add the Repository:
   helm repo add karpenter https://charts.karpenter.sh
helm repo update

 * Deploy: Install the controller into your cluster (typically in the karpenter namespace). Ensure you set the clusterName and clusterEndpoint values correctly.
3. Define the EC2NodeClass
This object specifies AWS-specific configurations, such as subnets, security groups, and the IAM node role.
 * Example:
   apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: "KarpenterNodeRole-${CLUSTER_NAME}"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${CLUSTER_NAME}"

4. Define the NodePool
The NodePool defines the "what" and "how" of your nodes (e.g., allowed instance types, capacity types like Spot/On-Demand, and TTL settings).
 * Example:
   apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot"]

Key Operational Tips
 * Do Not Mix Autoscalers: Disable or scale your existing Cluster Autoscaler to 0 if you are moving to Karpenter. Running both will cause conflicts as they compete to manage the same pods.
 * Consolidation: Enable consolidation in your NodePool to allow Karpenter to automatically terminate underutilized nodes and replace them with cheaper or more efficient ones.
 * Verification: Deploy a test pod (e.g., busybox) with a resource request to see if Karpenter correctly provisions a new node within ~60 seconds.
Would you like me to provide a specific Terraform snippet for the IAM setup, or are you planning to manage this via eksctl?
