#!/usr/bin/env bash
#
# Stand up the whole stack end to end:
#   1. VPC CloudFormation stack
#   2. EKS cluster + node group CloudFormation stack
#   3. kubeconfig wiring
#   4. hello-world deployment (3 pods) + LoadBalancer service
#
# Usage:
#   ./deploy.sh [cluster-name] [region]
#
# Defaults: hello-world-cluster, us-east-1
set -euo pipefail

CLUSTER_NAME="${1:-hello-world-cluster}"
REGION="${2:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VPC_STACK="${CLUSTER_NAME}-vpc"
EKS_STACK="${CLUSTER_NAME}-eks"

echo "==> Cluster: ${CLUSTER_NAME}   Region: ${REGION}"

# --- 1. VPC stack ---
echo "==> [1/4] Deploying VPC stack (${VPC_STACK})..."
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${VPC_STACK}" \
  --template-file "${SCRIPT_DIR}/01-vpc.yaml" \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --no-fail-on-empty-changeset

# --- 2. EKS stack (control plane + node group) ---
# This is the slow part: ~15-20 min for the control plane, then a few more for nodes.
echo "==> [2/4] Deploying EKS stack (${EKS_STACK}). This takes ~15-20 minutes..."
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${EKS_STACK}" \
  --template-file "${SCRIPT_DIR}/02-eks-cluster.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
  --no-fail-on-empty-changeset

# --- 3. kubeconfig ---
echo "==> [3/4] Updating kubeconfig..."
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo "==> Waiting for nodes to register..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# --- 4. Workload ---
echo "==> [4/4] Applying hello-world deployment + service..."
kubectl apply -f "${SCRIPT_DIR}/03-hello-world.yaml"

echo "==> Waiting for the deployment to become available..."
kubectl rollout status deployment/hello-world --timeout=180s

echo
echo "==> Pods:"
kubectl get pods -l app=hello-world -o wide

echo
echo "==> Service (the EXTERNAL-IP hostname may take 2-3 min to populate):"
kubectl get service hello-world

echo
echo "Done. Fetch the load balancer hostname with:"
echo "    kubectl get service hello-world -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo "Then: curl http://<that-hostname>   (refresh to see different pod names)"
